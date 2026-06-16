---
name: implement-pr
description: Implement an approved plan from plan-pr. Reads the plan from .claude/plans/<ticket-id>.md, creates a branch, implements the changes, runs review-pr --local in a loop until clean, then opens the PR. After the PR is up, optionally starts an event-driven monitor (via monitor-pr) and autofixes review comments and CI failures as they arrive.
argument-hint: <ticket-id>
allowed-tools: Bash, Read, Edit, Write, Glob, Grep, Agent
---

# implement-pr

Implement an approved ticket plan. Reads `.claude/plans/<ticket-id>.md`, implements the changes, validates locally, opens the PR, then (optionally) starts an event-driven monitor and reacts to review comments and CI failures as they arrive.

Part of the **PR suite**. Works best after `/plan-pr <ticket-id>`; uses `review-pr` and `monitor-pr` if they're installed, and degrades gracefully if they aren't.

**Usage:**
```
/implement-pr PROJ-123
```

**Credentials required:**
- **GitHub** — uses the `gh` CLI (must be authenticated).
- **Issue tracker** — only needed if `review-pr --local` is installed (it fetches the ticket to check coverage).

---

## Step 1 — Load the plan

Extract the ticket ID from `$ARGUMENTS`.

Read `.claude/plans/<ticket-id>.md`. If it does not exist, either run `/plan-pr <ticket-id>` first (if installed), or ask the user for the intended changes before continuing.

From the plan, extract:
- The branch name (`feat/<ticket-id-lowercase>-<short-slug>`).
- The list of files to change.
- The scenario-by-scenario approach.

---

## Step 2 — Create the branch

Prefer a dedicated worktree so the user's main working directory is left untouched and the monitoring loop stays stable:

```bash
git fetch origin
git worktree add .git-worktrees/<ticket-id-slug> -b <branch-name> origin/main
```

If the branch already exists (e.g. resuming after interruption):
```bash
git worktree add .git-worktrees/<ticket-id-slug> <branch-name>
```

All subsequent commands (`git add`, `commit`, `push`, dependency installs, etc.) must run inside the worktree path. Never run git commands for this branch from the main worktree.

After creating the worktree, run any project-specific setup the repo needs in a fresh checkout — for example:

```bash
cd .git-worktrees/<ticket-id-slug>

# Restore anything worktree creation may have disturbed (e.g. git hooks, LFS files):
#   git checkout -- <path> 2>/dev/null || true

# Dependencies are not shared between worktrees — install for any workspace the
# change touches, e.g.:
#   [ -f package.json ] && npm install
#   [ -f pyproject.toml ] && poetry install
```

> If the repo is a monorepo with locally-linked workspace packages, restore those links after install (they often don't survive a fresh worktree). Keep this setup block in sync with how your repo is normally bootstrapped.

If worktrees aren't appropriate for your repo, fall back to a plain branch: `git checkout -b <branch-name> origin/main` — but expect the monitor loop in Step 6 to disrupt your working directory.

---

## Step 3 — Implement the changes

**Dependency-only PRs** (the entire diff is lock-file / manifest version bumps, no logic changes): skip the `review-pr --local` invocations below — a coverage review produces no meaningful signal on a dependency-only diff. Note "dependency-only PR — local review skipped" in any relevant commit or comment.

Work through the plan scenario by scenario. For each file to change:

1. Read the current file contents before editing.
2. Make only the changes described in the plan — do not refactor or improve unrelated code.
3. Follow existing code conventions (import style, type hints, naming, etc.).
4. After all changes, run the project's test suite if available, and fix any failures before proceeding.

Commit changes in logical chunks as you go:
```bash
git add <specific-files>
git commit -m "<type>(<scope>): <description> [<TICKET-ID>]"
```

> Use whatever commit-message convention and co-author trailer your environment normally applies.

---

## Step 4 — Local review loop

**If the `review-pr` skill is installed**, run it in `--local` mode as a sub-agent, passing the ticket ID:

> Invoke the review-pr skill with arguments: `--local <ticket-id>`
> Return the full review output.

**If `review-pr` is not installed**, do the same check inline: diff the branch against `origin/main`, re-read the ticket, and map each scenario to the diff yourself.

Read the review output. Check for:
- Any ❌ rows (missing scenarios) — these must be fixed.
- Any ⚠️ rows (partial coverage) — evaluate whether they are addressable in code.

**⚠️ rows fall into two categories:**
- **Addressable** — the scenario can be fully implemented in this PR (e.g. missing logic, incomplete handling). Fix these.
- **Intentionally partial** — the scenario is handled outside this diff by design (a follow-up PR, a config/prompt change in an external system, etc.). These are acceptable and should not block the loop.

**If the review is clean** (no ❌, and all ⚠️ rows are intentionally partial): proceed to Step 5.

**If there are addressable gaps:**
1. Address each ❌ and each addressable ⚠️ — implement the missing coverage.
2. Commit the fixes.
3. Re-run the local review (repeat this loop until clean).

Do not create the PR while any ❌ rows remain or any ⚠️ rows are addressable in code.

---

## Step 5 — Create the PR

Merge latest main before pushing:
```bash
git fetch origin && git merge origin/main
```
If there are merge conflicts, resolve them, then `git add` the resolved files and `git commit` before continuing.

After merging, re-run the local review (Step 4) until clean to confirm the merge didn't break scenario coverage.

Push the branch:
```bash
git push -u origin <branch-name>
```

If the repo has a PR template, follow it:
```bash
cat .github/PULL_REQUEST_TEMPLATE.md 2>/dev/null || true
```

Create the PR:
```bash
gh pr create \
  --title "<type>(<scope>): <description> [<TICKET-ID>]" \
  --body "$(cat <<'EOF'
<PR body following the repo's PR template if present>
EOF
)"
```

The PR body should include:
- The ticket reference (linkable).
- A scenario coverage table (same format as the review output).
- Any known limitations.

Output the PR URL to the user.

---

## Step 6 — Monitor for review comments (optional)

This step requires the `monitor-pr` skill. **If it isn't installed**, skip to Step 7 and tell the user to watch the PR manually (or re-run `/review-pr <pr-number> --watch` later).

After the PR is created, start an event-driven monitor and react to events as they arrive. The model is only invoked when an event actually fires (new comment, CI fail, branch behind main, PR state flip, HEAD SHA change) — far cheaper than fixed-interval polling.

### 6a — Start the monitor

> Invoke the `monitor-pr` skill with arguments: `<PR_NUMBER>`

Capture the returned task ID. The monitor emits one notification per real state change. See the `monitor-pr` skill for the event format and the full list of event types.

After invocation, control returns here. **Do not enter a polling loop.** Stay idle. Each subsequent notification routes to the handler below, keyed on `EVENT <type>`. The `<owner>/<repo>` in the commands below is the PR's repo (the monitor defaults to the current repo).

### 6b — Event handlers

Branch on the event type from each notification.

#### `inline` / `review` / `issue` — new reviewer comment

These three event types are reviewer comments from different endpoints. The reaction is the same; only the **reply mechanism** differs (see step 7 below).

For each new comment:

1. Read the body from the event line (fetch the full body via `gh api repos/<owner>/<repo>/pulls/$PR_NUMBER/{comments,reviews}/<id>` or `gh api repos/<owner>/<repo>/issues/comments/<id>` if the truncated preview is insufficient).
2. Understand the reviewer's concern. For `inline` events, the `path=` / `line=` fields locate the code. For `review` and `issue` events there is no file/line context.
3. Implement the fix: read the relevant file(s), make the targeted change, then stage and commit:
   ```bash
   git add <specific-files-changed>
   git commit -m "fix: address review comment — <short description> [<TICKET-ID>]"
   ```
4. Re-run the local review (Step 4) to validate the fix. If any ❌ rows or addressable ⚠️ rows remain, address them and re-commit before continuing. Do not push or reply until the local review is clean.
5. Merge latest main before pushing:
   ```bash
   git fetch origin && git merge origin/main
   ```
   Resolve any conflicts, then `git add` and `git commit` before continuing.
6. Push: `git push`
7. Reply to the comment. The reply mechanism depends on the event type:
   - **`inline`** — reply in-thread on the inline-comments endpoint. Use `in_reply_to=` from the event line if non-null, else the comment's own id:
     ```bash
     gh api "repos/<owner>/<repo>/pulls/$PR_NUMBER/comments" --input - <<'EOF'
     { "body": "Fixed — <one sentence on what was done and where>.", "in_reply_to": <id> }
     EOF
     ```
     (Passing the body via `--input -` as JSON avoids shells eating backticks in `-f body=...`. POSTing to `/comments` with `in_reply_to` works for all sources, including bots whose `/replies` endpoint may 404.)
   - **`review`** — top-level review submission. Reply as a PR issue comment; the inline `/comments` API rejects review ids:
     ```bash
     gh pr comment $PR_NUMBER --body "Addressed review from @<reviewer-login> — <one sentence on what was done and where>."
     ```
   - **`issue`** — PR-level comment from a human. Reply with another PR issue comment:
     ```bash
     gh pr comment $PR_NUMBER --body "@<reviewer-login> — <reply>."
     ```

After pushing fixes, update the PR title/description if scope has meaningfully changed (see 6c). The monitor dedupes by id automatically; the event won't fire again for the same comment.

#### `ci_fail` — CI check transitioned to fail

1. Fetch the failure log. Use the `link=` URL from the event line:
   ```bash
   gh run view <run-id> --log-failed 2>&1 | head -100
   # or, for a specific job:
   gh api "repos/<owner>/<repo>/actions/jobs/<job-id>/logs" 2>&1 | grep -iE "FAIL|Error|panic|cannot" | head -30
   ```
2. Diagnose the root cause from the log output.
3. Implement the fix and commit:
   ```bash
   git add <specific-files-changed>
   git commit -m "fix: address CI failure — <short description> [<TICKET-ID>]"
   ```
4. Re-run the local review (Step 4); fix any ❌ or addressable ⚠️ rows before pushing.
5. Merge latest main and push:
   ```bash
   git fetch origin && git merge origin/main && git push
   ```
6. Post a PR comment describing the fix:
   ```bash
   gh pr comment $PR_NUMBER --body "Fixed CI failure in <job-name> — <one sentence on root cause and fix>."
   ```

If the failure is not fixable in code (flaky test, infra issue), surface it to the user instead of looping. The same check name won't re-fire unless it briefly leaves and re-enters the fail bucket, so an unfixable failure won't keep waking you.

#### `sha` — HEAD SHA changed (external push or own push)

The monitor emits this on every SHA change, including your own pushes after fixes. Decide whether the push warrants a re-review by walking the first-parent chain to distinguish automated branch-update / auto-merge commits from developer pushes:

An automerge / update-branch commit is a **merge commit (2+ parents) committed by a bot rather than a person**. Detect the bot generically — don't hardcode a vendor list — so the skill works whatever merge tooling (if any) a repo uses:

```bash
OLD=<old SHA from event>
NEW=<new SHA from event>

# Optional override: only needed if your repo's merge tooling commits under a
# plain user login (not a `[bot]` account). Leave empty otherwise. Examples of
# tools whose commits are already caught automatically by the `[bot]` / web-flow
# checks below: kodiakhq[bot], mergify[bot], github-merge-queue[bot],
# dependabot[bot], and GitHub's web-UI merge account (web-flow).
AUTOMERGE_BOTS="${AUTOMERGE_BOTS:-}"   # e.g. 'ci-merger|release-bot'

# A committer is an automerge bot if: it's GitHub's web-UI merge account,
# its login is a GitHub App (ends in `[bot]`), or it matches the optional
# override list above.
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

The `[bot]` suffix check catches any GitHub App merge bot without configuration; the `AUTOMERGE_BOTS` override is only for the rarer case of a bot that commits under a plain user login.

Always sync the local worktree (restore any files an install step marked dirty before pulling):
```bash
git pull
git fetch origin
```

If `IS_AUTO_MERGE=1`, no further action needed. If `IS_AUTO_MERGE=0` (developer push): re-run the local review (Step 4), then loop — fix any ❌ or addressable ⚠️ rows the new push introduces, commit, push, re-review. Stop when clean.

Skip the SHA event entirely if it corresponds to a push you just made in another handler (track the SHA you just pushed in the conversation; the monitor will emit it, but you can no-op).

#### `behind` — `mergeStateStatus` flipped to BEHIND

Merge main into the branch and push:
```bash
git fetch origin && git merge origin/main --no-edit && git push
```
If there are conflicts, resolve and commit before pushing. After pushing, expect a `sha` event for the merge commit — handle it as your own push (auto-merge).

#### `state` — PR closed or merged

If `to=MERGED` or `to=CLOSED`, the monitor's job is done:
```bash
# TaskStop <task-id from 6a>
```
Then proceed to Step 7.

#### `armed` — first-run confirmation

No action — the monitor logs this once to confirm it has started.

### 6c — Update PR title and description

After any handler pushes fixes, check whether the PR title and description still accurately reflect the changes. If the scope has meaningfully changed (new scenarios addressed, files added/removed, approach changed), update them:

```bash
gh pr edit $PR_NUMBER --title "<updated title>" --body "$(cat <<'EOF'
<updated PR body>
EOF
)"
```

Only update if the changes are substantive — minor review-comment fixes that don't alter scope don't need a description update.

### 6d — Exit conditions

The model is invoked only when an event fires; otherwise idle. Stop the monitor (`TaskStop`) when any of:
- A `state` event arrives with `to=MERGED` or `to=CLOSED`.
- The user sends a message (interrupt).

---

## Step 7 — Clean up worktree

If you created a worktree in Step 2, remove it:

```bash
cd <original-working-directory>
git worktree remove .git-worktrees/<ticket-id-slug>
```

If the worktree has uncommitted changes (e.g. after an interruption), force removal:
```bash
git worktree remove --force .git-worktrees/<ticket-id-slug>
```

---

## Step 8 — Self-update from learnings

After the PR is merged, closed, or interrupted, reflect on the session:

1. **Identify learnings** — things that would have made implementation smoother:
   - A pattern in review comments that signals a gap in the plan format.
   - A local-review failure that recurred — suggests a gap in what the review checks.
   - A file or test that always needs updating when this type of change is made.
   - A commit convention or PR template section that was consistently missing.

2. **Update this skill file** if a learning is general enough to apply to future implementations:
   - Add it to the **## Learnings** section below.
   - Only add it if it would change the implementation or monitoring approach for a future ticket.

3. Do **not** record ticket-specific implementation details. Keep learnings free of any private or commercial specifics.

---

## Notes

- Don't skip the local review loop — don't create the PR until it passes clean.
- Address review comments one at a time, not in a single bulk commit, so each reply is precise.
- Never force-push — always create new commits for review fixes.
- If a review comment is ambiguous or would require a significant design change, surface it to the user rather than guessing.
- The plan file (`.claude/plans/<ticket-id>.md`) is read-only input — this skill does not modify it.

---

## Learnings

*Populated automatically after each session. Do not edit manually. Keep entries generic — no private or commercial specifics.*
