# implement-pr — event handlers

Read by the per-notification sub-agent spawned in SKILL.md Step 6c (or inline if the main loop is handling directly). Context comes from `.context/pr-suite/<ticket-id>/state.md`: PR number, repo, branch, worktree path, ticket ID, plan file path, `last_pushed_sha`.

All git commands run inside the worktree recorded in state.md. `<owner>/<repo>` below is the repo from state.md; `$PR` is the PR number.

## Shared fix cycle

Used by the comment and CI handlers:

1. Implement the fix(es). Commit per logical change:
   ```bash
   git add <specific-files> && git commit -m "fix: <short description> [<TICKET-ID>]"
   ```
2. If any change touches logic (not just docs/comments/prose/test names): invoke `review-pr --local <ticket-id>` — it automatically runs as a **delta review** against `.context/pr-suite/<ticket-id>/last-review.md`, so only the new diff is re-assessed. Fix any ❌ rows and addressable ⚠️ rows before continuing. If all changes are prose-only, skip the review entirely; run the test suite only if code was touched.
3. `git fetch origin && git merge origin/main` — resolve conflicts, `git add` + `git commit` if needed.
4. `git push`, then update `last_pushed_sha:` in state.md with the new HEAD SHA so the resulting `sha` event is recognised as your own push and ignored.

**⚠️ classification:** *addressable* = fully implementable in this PR → fix it. *Intentionally partial* = handled outside this diff by design (follow-up PR, external config/prompt change) → acceptable, don't block.

## `inline` / `review` / `issue` — reviewer comments

A single notification may contain several comment events (the monitor batches per poll). Fix them ALL in **one** fix cycle — one review pass, one merge, one push — then reply to each comment individually.

For each comment:
1. Read the body from the event line; fetch the full body only if the 240-char preview is insufficient: `gh api repos/<owner>/<repo>/pulls/$PR/comments/<id>` (inline), `.../pulls/$PR/reviews/<id>` (review), or `.../issues/comments/<id>` (issue).
2. For `inline` events, `path=` / `line=` locate the code. `review` / `issue` events have no file context.
3. If a comment is ambiguous or would require a significant design change, return it to the main loop to surface to the user rather than guessing.

After the fix cycle, reply per comment. The mechanism depends on the event type:

- **`inline`** — reply in-thread on the inline-comments endpoint. Use `in_reply_to=` from the event line if non-null, else the comment's own id. (JSON via `--input -` avoids shells eating backticks; POSTing to `/comments` with `in_reply_to` works for all sources, including bots whose `/replies` endpoint may 404.)
  ```bash
  gh api "repos/<owner>/<repo>/pulls/$PR/comments" --input - <<'EOF'
  { "body": "Fixed — <one sentence on what was done and where>.", "in_reply_to": <id> }
  EOF
  ```
- **`review`** — the inline `/comments` API rejects review ids; reply as a PR issue comment:
  ```bash
  gh pr comment $PR --body "Addressed review from @<reviewer-login> — <one sentence on what was done and where>."
  ```
- **`issue`** — PR-level comment from a human:
  ```bash
  gh pr comment $PR --body "@<reviewer-login> — <reply>."
  ```

## `ci_fail` — CI check transitioned to fail

1. Fetch the failure log via the `link=` URL from the event:
   ```bash
   gh run view <run-id> --log-failed 2>&1 | head -100
   # or, for a specific job:
   gh api "repos/<owner>/<repo>/actions/jobs/<job-id>/logs" 2>&1 | grep -iE "FAIL|Error|panic|cannot" | head -30
   ```
2. Diagnose the root cause, then run the shared fix cycle.
3. Post: `gh pr comment $PR --body "Fixed CI failure in <job-name> — <one sentence on root cause and fix>."`

If the failure is not fixable in code (flaky test, infra issue), report it back for the user instead of looping. The same check name won't re-fire unless it briefly leaves and re-enters the fail bucket.

## `sha` — HEAD SHA changed

First check state.md: if `new=` equals `last_pushed_sha`, this is your own push — **no-op**.

Otherwise decide whether the push is an automated branch-update / auto-merge (no action) or a developer push (re-review). An automerge commit is a **merge commit (2+ parents) committed by a bot rather than a person**. Detect the bot generically — don't hardcode a vendor list:

```bash
OLD=<old SHA from event>
NEW=<new SHA from event>

# Optional override: only needed if your repo's merge tooling commits under a
# plain user login (not a `[bot]` account). The `[bot]` / web-flow checks below
# already catch kodiakhq[bot], mergify[bot], github-merge-queue[bot],
# dependabot[bot], and GitHub's web-UI merge account.
AUTOMERGE_BOTS="${AUTOMERGE_BOTS:-}"   # e.g. 'ci-merger|release-bot'

is_automerge_committer() {
  local login="$1"
  [ "$login" = "web-flow" ] && return 0
  case "$login" in *'[bot]') return 0 ;; esac
  [ -n "$AUTOMERGE_BOTS" ] && printf '%s' "$login" | grep -qE "^($AUTOMERGE_BOTS)$" && return 0
  return 1
}

WALK_SHA=$NEW
IS_AUTO_MERGE=1
WALK_LIMIT=10
while [ "$WALK_SHA" != "$OLD" ] && [ "$WALK_LIMIT" -gt 0 ]; do
  WALK_DATA=$(gh api "repos/<owner>/<repo>/commits/$WALK_SHA" \
    --jq '{c: .committer.login, p: [.parents[].sha], n: (.parents | length)}')
  WALK_COMMITTER=$(echo "$WALK_DATA" | jq -r .c)
  WALK_PARENT_COUNT=$(echo "$WALK_DATA" | jq -r .n)
  if [ "$WALK_PARENT_COUNT" -lt 2 ] || ! is_automerge_committer "$WALK_COMMITTER"; then
    IS_AUTO_MERGE=0
    break
  fi
  WALK_SHA=$(echo "$WALK_DATA" | jq -r '.p[0]')
  WALK_LIMIT=$((WALK_LIMIT - 1))
done
[ "$WALK_LIMIT" -eq 0 ] && [ "$WALK_SHA" != "$OLD" ] && IS_AUTO_MERGE=0
```

Always sync the worktree: `git pull && git fetch origin`.

If `IS_AUTO_MERGE=1`: no further action. If `IS_AUTO_MERGE=0` (developer push): run `review-pr --local <ticket-id>` (delta), then the shared fix cycle for any ❌ / addressable ⚠️ rows. Stop when clean.

## `behind` — main has moved ahead

```bash
git fetch origin && git merge origin/main --no-edit && git push
```
Resolve conflicts and commit first if needed. Update `last_pushed_sha` in state.md — the follow-up `sha` event will then match it and no-op.

## `restarted`

No action unless recurring — then report it to the main loop.

## After any push — PR title/description

If the scope has meaningfully changed (new scenarios addressed, files added/removed, approach changed), update:
```bash
gh pr edit $PR --title "<updated title>" --body "$(cat <<'EOF'
<updated PR body>
EOF
)"
```
Minor review-comment fixes that don't alter scope don't need this.
