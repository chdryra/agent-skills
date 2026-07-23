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

Read `.claude/plans/<ticket-id>.md`. If it does not exist:
1. Check the conversation for a clear description of what needs to be implemented. If the intent is obvious from context, derive a slug and proceed — synthesise the plan structure (title, scenarios, files) from what has been discussed.
2. If the conversation does not supply enough to write at least one concrete scenario, suggest running `/plan-pr <slug>` first (if installed), or ask the user for the intended changes before continuing.

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
> Return ONLY the review block (coverage table, gaps, verdict) — no narration.

**Token discipline for this loop:**
- The first pass is a full review. `review-pr --local` writes `.context/pr-suite/<ticket-id>/last-review.md` (previous table + reviewed SHA), so every later pass in this loop is automatically a **delta review** — only the diff since the last reviewed SHA is re-assessed, unchanged rows carry forward. It also caches the fetched ticket at `.context/pr-suite/<ticket-id>/ticket.md`, so the tracker is hit once, not once per pass.
- Run intermediate loop passes on a smaller model (`model: sonnet` on the Agent call) — mapping a small delta to scenarios doesn't need the top model. The final pre-PR gate (Step 5) runs `--full` on the session model.
- Cap the loop at 3 iterations. If gaps remain after that, present them to the user instead of continuing to burn passes.

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

After merging, run the final pre-PR gate — one full review on the session model:

> Invoke the review-pr skill with arguments: `--local <ticket-id> --full`

If it surfaces gaps, fix them via the Step 4 (delta) loop and re-run the gate. This single `--full` pass replaces the old "re-run until clean" full reviews.

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
  --title "<type>(<scope>): <description> [<TICKET-ID-or-slug>]" \
  --body "$(cat <<'EOF'
<PR body following the repo's PR template if present>
EOF
)"
```

The PR body should include:
- The ticket reference (linkable) if one exists, or the slug if not.
- A `<!-- goals -->` block containing the scenarios from the plan, so that `review-pr` can use them when run from a different environment without access to the local plan file. Format it as:
  ```
  <!-- goals
  ### Goals
  <paste the ### Scenarios section from the plan verbatim>
  -->
  ```
- A scenario coverage table (same format as the review output).
- Any known limitations.

Output the PR URL to the user.

---

## Step 6 — Monitor for review comments (optional)

This step requires the `monitor-pr` skill. **If it isn't installed**, skip to Step 7 and tell the user to watch the PR manually (or re-run `/review-pr <pr-number> --watch` later).

After the PR is created, monitoring is event-driven — the model is only invoked when something real happens (new comment, CI fail, branch behind main, PR state flip, SHA change).

### 6a — Write the handoff state file

Write `.context/pr-suite/<ticket-id>/state.md` containing: PR number, repo (`owner/repo`), branch name, worktree path, ticket ID, plan file path, and `last_pushed_sha: <current HEAD SHA>`. Event handling reads this file instead of conversation history — it survives compaction and lets sub-agents work without the full context.

### 6b — Start the monitor

> Invoke the `monitor-pr` skill with arguments: `<PR_NUMBER>`

Capture the returned task ID. The monitor emits one notification per real state change (see `monitor-pr` for the event format and types). After invocation, **do not enter a polling loop** — stay idle; each notification routes to the dispatch below.

### 6c — Event dispatch

By this point the conversation is large, and notifications usually arrive more than 5 minutes apart — so every inline handling turn re-reads the whole conversation with a cold prompt cache, once per tool call. Handle events in a sub-agent instead, keeping the main-loop turn to a single Agent call plus a one-line relay:

- **`state`** with `to=MERGED` / `to=CLOSED`: handle inline — stop the monitor (`TaskStop <task-id>`), then proceed to Step 7.
- **`armed` / `heartbeat`**: no action.
- **Everything else** (`inline`, `review`, `issue`, `ci_fail`, `sha`, `behind`, `restarted`): spawn ONE general-purpose sub-agent per notification, passing every event line it contains (the monitor batches events per poll — give the agent the whole batch):

  > Read `<skill-dir>/handlers.md` (the directory this SKILL.md lives in) and `.context/pr-suite/<ticket-id>/state.md`. Handle these events: `<event lines>`. Work in the worktree recorded in state.md. Update `last_pushed_sha` in state.md after any push. If an event needs a user decision (ambiguous comment, unfixable CI failure), don't guess — say so. Return a 1-3 sentence summary of what you did.

  Relay the sub-agent's summary to the user in one short line. Do not read files or run git commands in the main loop for these events — the handler file and state file give the sub-agent everything it needs.

### 6d — Exit conditions

Stop the monitor (`TaskStop`) when any of:
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

## Step 8 — Journal the outcome (optional)

If a journal skill is installed (e.g. a repo or global `/journal` skill), invoke it after the PR merges so the day's log records what the ticket delivered **as a whole** — what a user or the system can now do that it couldn't before — not just "addressed comments and merged PR #NN". Merge time is when this record is most easily lost: a session that only handles review comments and merges has little implementation context, so pull the substance from the ticket and PR if the work happened in earlier sessions.

Skip this step if no journal skill is installed or the PR was closed without merging.

---

## Step 9 — Self-update from learnings

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
- Commit review-comment fixes per comment (so each reply is precise), but batch the validation: one review pass, one merge, one push per notification batch — not per comment.
- Never force-push — always create new commits for review fixes.
- If a review comment is ambiguous or would require a significant design change, surface it to the user rather than guessing.
- The plan file (`.claude/plans/<ticket-id>.md`) is read-only input — this skill does not modify it.

---

## Learnings

*Populated automatically after each session. Do not edit manually. Keep entries generic — no private or commercial specifics. Cap this section at ~12 entries of 1-2 lines each; when adding, merge or drop older entries rather than growing the list.*
