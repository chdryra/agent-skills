---
name: review-pr
description: Review a PR against the ticket it references. Fetches the PR diff, extracts the ticket ID, fetches the ticket requirements from your issue tracker, maps scenarios to implementation, and posts a structured review comment on the PR. With --watch, starts an event-driven monitor (via monitor-pr) and re-reviews on new commits. Pass --local to review the current branch diff without posting (used by implement-pr before a PR exists).
argument-hint: <pr-number-or-url> [--watch] | --local <ticket-id>
allowed-tools: Bash, Read, Edit, Glob, Grep, Write
---

# review-pr

Review a PR against the ticket it references. Fetches the PR diff and description, extracts the ticket, compares requirements to implementation scenario-by-scenario, and posts a structured review comment directly on the PR.

Part of the **PR suite**. Runs standalone; uses `monitor-pr` for `--watch` mode if installed.

- `--watch` — after the initial review, start an event-driven monitor (via `monitor-pr`) that re-reviews on new commits and reacts to replies, CI failures, and merge-state changes.
- `--local <ticket-id>` — review the current branch diff locally without posting to GitHub. Used by `implement-pr` before a PR exists.

**Usage:**
```
/review-pr <pr-number-or-url>              # one-shot review, posts to GitHub
/review-pr <pr-number-or-url> --watch      # review + monitor for replies/changes
/review-pr --local <ticket-id>            # local review, no GitHub post
```

**Credentials required:**
- **Issue tracker** — Linear / Jira / GitHub Issues (detected; see below).
- **GitHub** — uses the `gh` CLI (must be authenticated).

---

## Detecting the issue tracker

Detect it in this order:

1. Linear MCP tools available (`mcp__linear__*`)? → Linear.
2. A `JIRA_URL` / `JIRA_PROJECT` env var, or a `.jira` / `jira.config.json` file? → Jira.
3. No external tracker, IDs look like `#123`? → GitHub Issues via `gh`.
4. Check memory for a previously noted tracker preference.
5. Ask the user.

---

## Step 1 — Parse the argument

`$ARGUMENTS` may be either:
- A PR number (e.g. `123`).
- A GitHub PR URL (e.g. `https://github.com/<owner>/<repo>/pull/123`).
- Either followed by `--watch` to enable monitoring mode.
- `--local <ticket-id>` to review the current branch without a PR.

Extract the repo and PR number. Default repo is the current repo (`gh repo view --json nameWithOwner -q .nameWithOwner`) if only a number is given.

**If `--local` is set:** skip Steps 2 and 6. Use the ticket ID provided (do not try to extract it from a PR). Get the diff via:
```bash
git fetch origin
git diff origin/main...HEAD
```
Using `origin/main` (the remote-tracking ref) avoids `git fetch origin main:main`, which fails when `main` is checked out in another worktree (the default under `implement-pr`'s worktree approach). After producing the review (Step 5), output it directly to the conversation — do not post to GitHub.

---

## Step 2 — Fetch the PR

```bash
gh pr view <number> --repo <owner/repo>
gh pr diff <number> --repo <owner/repo>
```

From the PR description, extract the ticket ID. Look for:
- A bare reference like `PROJ-123`, `ENG-123`, or `#123` in the title or body.
- A `[PROJ-123]` style reference.
- A tracker URL (e.g. `atlassian.net/browse/PROJ-123`, `linear.app/.../issue/ENG-123`).

If no ticket is found, post a review comment noting this and stop.

---

## Step 3 — Fetch the ticket

Fetch the ticket from the detected tracker. Read any token programmatically and **never echo it**:

- **Linear:** `mcp__linear__get_issue` with the issue id.
- **Jira:** prefer Jira MCP tools; otherwise REST API v3 `GET <JIRA_URL>/rest/api/3/issue/<KEY>`, run entirely in-process so the token stays out of terminal scrollback. Read the auth token from a `JIRA_API_TOKEN` env var; or — *Claude Code only* — `~/.claude.json`.
- **GitHub Issues:** `gh issue view <number> --json title,body,labels,comments`.

Extract:
- **Scenarios / decision logic** — numbered or bulleted cases the ticket defines.
- **Acceptance criteria** — any explicit requirements.
- **Summary table** if present.

(Jira descriptions use Atlassian Document Format — parse the ADF JSON to plain text.)

---

## Step 4 — Map requirements to implementation

For each scenario or requirement in the ticket:

1. Identify which files/functions in the diff address it.
2. Assess whether it is:
   - **Fully implemented** — code clearly handles this case.
   - **Partially implemented** — code addresses it but relies on model inference, an out-of-diff config/prompt change, or a follow-up PR.
   - **Not implemented** — no evidence in the diff.
   - **Not applicable** — handled by a different system (e.g. frontend-only).

Note any gaps, edge cases, or risks (e.g. model-dependent behaviour, missing tests, fallback paths).

---

## Step 5 — Compose the review

```
## Ticket coverage review: <TICKET-ID>

### Scenario coverage

| Scenario | Requirement | Status | Where handled |
|---|---|---|---|
| **1** — <name> | <ticket requirement> | ✅ / ⚠️ / ❌ / ➖ | <file or "out of diff"> |
...

### Gaps and observations

- <gap 1>
- <gap 2>

### Verdict

<one-sentence overall assessment>

---
*Posted by the `review-pr` skill*
```

Status symbols:
- ✅ Fully implemented in this PR.
- ⚠️ Partial — relies on model inference, an out-of-diff config/prompt change, or a follow-up.
- ❌ Not implemented.
- ➖ Not applicable — handled by a different system (e.g. frontend-only, out of scope).

---

## Step 6 — Post the review to GitHub

Post as a PR review comment (not an inline comment):
```bash
gh pr review <number> --repo <owner/repo> --comment --body "$(cat <<'EOF'
<review markdown>
EOF
)"
```

After posting, output the PR URL so the user can navigate to it.

If `--watch` was **not** passed, stop here.

---

## Step 7 — Monitor mode (`--watch` only)

Requires the `monitor-pr` skill. **If it isn't installed**, tell the user `--watch` is unavailable and stop after Step 6.

After posting the initial review, start an event-driven monitor and react to events as they arrive — the model is only invoked when an event fires.

### 7a — Start the monitor

> Invoke the `monitor-pr` skill with arguments: `<PR_NUMBER>`

Capture the returned task ID. See the `monitor-pr` skill for the event format. After invocation, stay idle — do not enter a polling loop.

### 7b — Event handlers

#### `sha` — new commits on the PR branch

1. Fetch the new diff: `gh pr diff <number> --repo <owner/repo>`.
2. Re-run Steps 4–6 (re-review against the same ticket).
3. In the new comment, note which scenarios changed status vs. the previous review.

#### `behind` — main is ahead of the PR branch

Update the branch via the GitHub API (equivalent to "Update branch" in the UI — no local checkout needed):
```bash
gh api -X PUT "repos/<owner>/<repo>/pulls/<number>/update-branch"
```
This returns 202 Accepted (async). The monitor will emit a follow-up `sha` event once the merge commit lands — check whether it's purely the auto-merge of main (a single bot commit) before re-reviewing. If it is, skip the re-review; otherwise treat it as a regular `sha` event.

#### `inline` / `review` / `issue` — new reviewer comment

1. Read the comment body from the event line (fetch the full body via `gh api` if the preview is insufficient).
2. If the reviewer is replying to a gap or observation from your review:
   - They confirm the gap is real → note it.
   - They explain why it's not a gap → this is a learning (Step 8).
   - They request a follow-up review → schedule a re-review on the next `sha` event.
3. If you post an acknowledgement, the monitor will see your own reply as a new event on the next poll — that's expected and silently deduped by id.

#### `ci_fail`

In `--watch` mode, `review-pr` doesn't fix CI failures — that's `implement-pr`'s job. Note the failure in conversation but take no action.

#### `state` — PR closed or merged

```bash
# TaskStop <task-id from 7a>
```
Then proceed to Step 8.

### 7c — Exit conditions

Exit (`TaskStop`) when any of:
- A `state` event arrives with `to=MERGED` or `to=CLOSED`.
- The user sends a message (interrupt).
- 30 minutes elapse with no activity (wall-clock check at the start of each handler).

---

## Step 8 — Self-update from learnings (`--watch` only)

After the loop exits, reflect on the review cycle:

1. **Identify learnings** — things that differed from what the skill expected:
   - A gap the skill flagged that turned out not to be a gap (reviewer explained why).
   - A scenario type not previously encountered (e.g. "ticket had no scenario table, only AC").
   - A false positive (marked ❌ but actually implemented elsewhere).

2. **Update this skill file** if a learning is general enough to apply to future reviews:
   - Add it to the **## Learnings** section below.
   - Only add it if it would change the review output for a future PR.

3. Do **not** record PR-specific details. Keep learnings free of any private or commercial specifics.

---

## Notes

- If the ticket has no structured scenario list, use the acceptance criteria or summary as the comparison basis.
- If a scenario is handled entirely outside the diff (e.g. a config or prompt change in an external system), mark it ⚠️ and note that it can't be verified from the diff alone.
- Do not request changes or approve — only post comment reviews.
- Keep the review concise: one row per scenario, gaps as bullet points.
- **Dependency-only PRs** (lock-file / manifest bumps, no logic changes): skip scenario-coverage review. Instead verify: (1) the lock resolves to the target version; (2) no packages present before are now missing (silent transitive-dep drops). Grep lock files for the target version and diff the resolved package list against main.

---

## Learnings

*Populated automatically during `--watch` cycles. Do not edit manually. Keep entries generic — no private or commercial specifics.*
