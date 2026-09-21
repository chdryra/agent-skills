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
- **A task notification with `status: killed`** (not an EVENT line — the runtime killed the monitor task itself): re-invoke `monitor-pr <pr-number>` immediately and silently, and record the new task id. Do not reply "no response requested" and do not wait to be asked — a dead monitor is indistinguishable from a quiet PR, so the loop is silently over until someone notices. Skip only if the PR has already merged or closed.
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

## Step 9 — Sync the docs (optional)

If a docs-sync skill is installed — a repo or global skill whose description says it brings a documentation set back in line with the code after PRs merge (e.g. a repo's `/docs-sync`) — invoke it once the PR has merged. It is the cheapest moment to do it: the change is fresh, and a doc set that is checked after every merge never drifts far enough to need a rewrite.

Run it from the original working directory, not the ticket's worktree. If the skill tracks its own sync range (for example, the last commit it synced to), let it work that out rather than passing the PR's commits in.

Skip this step, silently, if no such skill is installed or the PR was closed without merging. Never treat a failed or skipped docs sync as a failure of the ticket — report it and move on.

---

## Step 10 — Self-update from learnings

After the PR is merged, closed, or interrupted, reflect on the session:

1. **Identify learnings** — things that would have made implementation smoother:
   - A pattern in review comments that signals a gap in the plan format.
   - A local-review failure that recurred — suggests a gap in what the review checks.
   - A file or test that always needs updating when this type of change is made.
   - A commit convention or PR template section that was consistently missing.

2. **Update this skill file** if a learning is general enough to apply to future implementations:
   - Add it to the **## Learnings** section below.
   - Only add it if it would change the implementation or monitoring approach for a future ticket.
   - If the learning only applies to changes touching a database, queries, concurrency or access control, add it to `learnings-data-layer.md` in this skill's directory instead, under the same size rule.

3. Do **not** record ticket-specific implementation details. Keep learnings free of any private or commercial specifics.

---

## Notes

- Don't skip the local review loop — don't create the PR until it passes clean.
- Pushing the branch and opening the PR are part of this skill — once the gate is clean, do both without pausing to ask the user.
- Commit review-comment fixes per comment (so each reply is precise), but batch the validation: one review pass, one merge, one push per notification batch — not per comment.
- Never force-push — always create new commits for review fixes.
- If a review comment is ambiguous or would require a significant design change, surface it to the user rather than guessing.
- The plan file (`.claude/plans/<ticket-id>.md`) is read-only input — this skill does not modify it.

---

## Learnings

*Populated automatically after each session. Do not edit manually. Keep entries generic — no private or commercial specifics. Cap this section at ~30 entries of 1-3 lines each — every entry is read on every run; when adding, merge or drop older entries rather than growing the list.*

If the change touches a database, queries, concurrency or access control, also read `learnings-data-layer.md` in this skill's directory (skip silently if it isn't installed).

- When the working directory is already an isolated per-branch workspace (a container, or a worktree someone else made), treat it as the worktree: skip Step 2's `git worktree add` and skip Step 7's removal. Only ever remove a path this skill created — removing a pre-existing workspace destroys the user's work.
- Never invoke the test or lint command from memory — read the repo's own test target first. Repos often gate test-only files behind a build tag or marker, and an ad-hoc run without it fails as a cascade of undefined-symbol errors in files the branch never touched, which reads as broken code rather than a wrong invocation.
- Compare against `origin/main`, never local `main`: in a long-lived workspace local `main` can be hundreds of commits stale, so `main..HEAD` counts quietly lie, and `git checkout main` fails outright when main is checked out in a sibling worktree. Cut follow-up branches from `origin/main` too.
- Start any compound shell command with an explicit `cd <absolute path>`, since cwd drifts between calls; and when a subprocess must see variables from an env file with no `export` lines, wrap the source in `set -a` / `set +a`, or it silently falls back to defaults.
- A failure in territory the branch never touched is usually stale state, not a bug. Merge `origin/main` and re-run, check whether the job already fails on main, diff your env file against the README and CI config, and, if the repo edits migrations in place, recreate any persistent local database whose already-applied migration was edited.
- After every merge from main, run the type-check and the full suite, and check for numbered collisions git cannot flag — two migrations claiming one version, or two branches appending reference rows with the same id. A sibling's behavioural change lands in files that auto-merge cleanly.
- When several workspaces share one database or service, a schema failure can be drift left by a sibling branch, and a connection-exhaustion error naming different tests each run is contention. Queue behind any in-flight sibling run, and look for a leaked test process still holding connections.
- When a sibling ticket touched the same files, expect semantic duplication rather than textual conflict — both sides may have built the same guard. Read every merged function end to end, since changes on different return paths conflict in neither git nor CI, and settle disagreements from the domain model.
- Re-read the plan's stated assumptions against `origin/main` after each merge, not just its file list. A sibling can falsify "nothing in the codebase does X" without touching a file you touched; where the resulting gap is a product judgement, put it to the user rather than extending the policy yourself.
- Adding a value to a role/status enum — or a new kind to any shared registry of types — means auditing every switch and read-time filter that enumerates the old set. Watch for `default`/`else` arms that fail open by hiding the new value instead of refusing, and add a test that walks the whole enum.
- Pair every test of a filter that hides things with a control asserting what must still be visible — the near-miss case, and the owner who is exempt. Neutering the predicate only proves it hides enough, never that it hides only what it should, and over-hiding is the failure no falsification run catches.
- When falsifying, replace the clause under test with a tautology rather than deleting it, so a build error can't masquerade as coverage; confirm the run reached the tests; put the fixture one step from the boundary so a single leaked row flips the answer; and restore the file immediately.
- A test against a guard that runs ahead of the code it protects (a rate limit, an auth or size check) passes even when every request was malformed and would have been refused anyway — assert the success response before the expected rejection. Floor any counting test against an independent number.
- A pagination test that only asserts page one comes back full proves the filter moved into the query, not that the offset counts visible rows. Assert page two resumes exactly where page one stopped, and build the fixture by varying the listing's own sort key.
- When the fix sits behind a wrapper every test replaces with a double, the suite is green whether the production line works or not. Falsify the production code, not the double; if the suite stays green either way, say so in the PR body and raise the missing seam as a follow-up.
- Don't let Step 5's `--full` gate become a formality — delta reviews grade only what the plan's scenarios named, so repo-wide invariants the plan never mentioned go unchecked. Run it properly even when every delta pass was clean.
- Brief the final gate and every event-handling sub-agent on the change's settled deferrals and its security invariants up front, or they re-raise closed decisions as blocking findings and a handler "fixes" a trade-off the user deliberately made.
- The PR body is a promise, not a snapshot. Re-read it whenever a later commit fixes something it calls "deferred", and mark any scenario the user reversed mid-implementation as a deliberate departure — left stale, the next reviewer grades the diff against a spec nobody is following.
- Record a deferral in three places: a tracked ticket, the PR bullet naming it, and the state file event handlers read. Kept only in the PR body or the conversation, it gets "fixed" inside the current PR the moment a reviewer raises it — applying the very approach that was deliberately rejected.
- When implementation proves an acceptance criterion describes behaviour that does not and should not exist, amend it in the tracker with a dated note saying why, and fix the matching test-plan line. A PR-body caveat alone leaves the next reader grading a merged change against a spec it never met.
- When a change makes an external service's configuration load-bearing, no test in the repo can prove it. List those checks in the PR body as an unchecked checklist, say merge is blocked until they are run, record the same blocker in the state file, and put the standing requirement in the setup docs.
- Dispatch one event handler at a time, and read the whole batch before dispatching: two handlers push to the same branch and rewrite the same state file, and a clean review often arrives in the same batch as the merge that followed it, which needs no handler at all.
- Never take a handler's summary as proof — check `git log @{u}..HEAD` comes back empty (agents commit and then don't push) and re-run the affected tests uncached. Never write a SHA into the state file that you have not just read from `git rev-parse HEAD`.
- Sub-agents get no completion notification for background commands, so tell handlers to run validation synchronously and never wait on the parent's monitor. "I'll wait for the notification" is the tell that one stopped early — resume that same agent rather than spawning a second, which would race on its files.
- Confirm PR state before acting on any event: a "behind" or SHA line can arrive after the merge already happened, or name a commit caught mid-push. A monitor also baselines the PR when it starts, so anything that landed before it is never reported — read the PR yourself before starting one.
- Not every event on your PR is yours — reviews and pushes arrive from watchers outside the session, including an "update branch" merge onto your own branch. Make `git fetch` and a look at the remote head a handler's first and last act, reconcile by merging, and never force-push.
- A handler's fixes can be stranded when the PR merges mid-fix. Before treating a merge as closing the ticket, check that every commit a handler reported pushing is an ancestor of `origin/main`; if one is stranded, put it on a fresh branch cut from the updated main and open a follow-up PR.
- A CI failure from a registry or network blip is diagnosable without touching the diff — sibling jobs passed and main is green — so wait for the run to finish and re-run the failed jobs rather than escalating. For a flaky failure the pattern is the diagnosis: same function, different subtests each run.
- Treat a reviewer's claims as hypotheses, not decisions. Re-verify at their own layer before re-asserting, surface a suggested deferral to the user rather than accepting it silently, and settle a negative claim ("this guard is untested") by stripping the guard and running the suite.
- Before treating something as unsettled scope, or filing the follow-up ticket a plan asks for, check the plan's own Open Questions section and search the tracker — the point may already be resolved there, or ticketed during sign-off in different words.
