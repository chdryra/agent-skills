---
name: finish-batch
description: Review and merge a batch of PRs from the reviewing seat while separate implementation sessions do the coding. Finds the PR for each ticket, reviews it with review-pr at the agreed model, leaves gaps for the implementing session to fix, waits for green CI, merges in dependency order, brings the remaining branches up to date, verifies (rather than redoes) the implementing sessions' post-merge chores, and closes the batch out. Use after plan-batch, once the implementations have been launched.
argument-hint: <batch-name> | <ticket-id-or-pr#> ... [--review-model <model>] [--merge-method merge|squash|rebase]
allowed-tools: Bash, Read, Edit, Write, Glob, Grep, Agent, Skill
---

# finish-batch

Take a batch from "implementations launched" to "everything merged and closed out". Run the reviewing seat for a batch: one session that reviews, merges and keeps the branches in step, while each ticket is implemented elsewhere by `implement-pr`.

Part of the **PR suite**. Uses `review-pr` and `monitor-pr`; reads the state file `create-batch` and `plan-batch` leave behind. Works without them too: give it tickets or PR numbers.

**Usage:**
```
/finish-batch batch-e
/finish-batch PROJ-12 PROJ-13 PROJ-15 --review-model opus
/finish-batch 231 232 233 --merge-method squash
```

---

## Why a batch skill

The reviewing seat's job is simple and repetitive, and every lapse in it has the same shape: a PR merged before its blocker; a review posted by the same model that wrote the code; a branch left behind main until it conflicts; a monitor that expired quietly so a green PR sat unmerged for an hour; two sessions editing the same journal page at once. This skill is that checklist, kept in a state file that survives a context reset.

---

## Step 0 — Load or build the batch

1. If the argument is a batch name, read `.context/pr-suite/<batch-name>/state.md` (written by `create-batch`, extended by `plan-batch`): tickets, implement/review models, order and dependency notes. If the file is missing, rebuild the ticket list from the tracker label of that name.
2. Otherwise build the same state from the arguments: for each ticket id, find its PR with `gh pr list --repo <owner/repo> --search "<ticket-id> in:title,body" --state open`; for each PR number, read its title to find the ticket.
3. Fill in, per ticket: PR number (or `awaiting PR`), head branch, review model (from the plan's "Suggested model", the ticket, `--review-model`, or the session model), dependencies (tracker blocking links plus the plan's notes), status (`awaiting PR` / `under review` / `changes requested` / `green` / `merged` / `blocked`).
4. Detect the repo's merge convention (`--merge-method`, else look at recent merge commits: merge commits → `--merge`, squashed history → `--squash`).

Write it all to the state file. Every later step reads and updates this file, not the conversation.

---

## Step 1 — Watch for PRs and events

- For each PR that exists, start `monitor-pr` and capture the task id. For tickets still `awaiting PR`, check `gh pr list` when another event fires or roughly every twenty minutes; do not poll faster than that.
- Monitors and shell watchers expire (typically after 30 and 10 minutes). When one expires, **re-arm it**; a silent monitor is the most common way a green PR sits unmerged.
- Stay idle between events. Do not narrate waiting. When the human asks "where are we?", answer from the state file as a short table.

---

## Step 2 — Review each PR

When a PR opens or its head changes:

1. Check dependencies first. If the ticket is blocked by a sibling that is not merged, review it anyway if you like, but mark it `blocked` and do not merge until the sibling lands. Never suggest rebasing one unmerged branch onto another.
2. Run `review-pr <pr#>` in a sub-agent at the PR's review model. `review-pr` posts the coverage review on the PR itself; the sub-agent returns only the verdict and any gaps. Use a different model from the one that implemented the code where you can.
3. If the review found gaps: leave it. `implement-pr`'s own monitor reads the review comment and fixes it; when the head SHA changes, re-review (the `review-pr` delta mode means this is cheap). Mark `changes requested`.
4. If the review is clean: mark `under review → green` once CI passes. Never merge on a review alone.
5. If a PR has been open with no activity for a long time, or the ticket is multi-PR and the implementing session stopped after its first PR, tell the human which workspace needs a nudge. The reviewing seat does not push to another workspace's branch.

---

## Step 3 — Merge in order

When a PR is reviewed clean, CI is green and nothing it depends on is unmerged:

1. If GitHub reports the branch is behind the default branch, bring it up to date (`gh pr update-branch <pr#>` or the API). If that fails with a conflict, do **not** resolve it from the reviewing seat: tell the human which workspace owns the branch and what it conflicts with, mark `blocked`, and wait for the new SHA. Then re-review the delta.
2. Wait for CI on the updated head.
3. Merge: `gh pr merge <pr#> --repo <owner/repo> --<method>` with the detected method. Mark `merged` with the merge commit SHA.
4. Immediately bring every other open PR in the batch up to date with the default branch, so conflicts surface now and CI re-runs against the real main. Expect the occasional 422; handle it as in 1.
5. Note anything the PR description asks of the human after merge (a database to recreate, a setting to flip, a manual check) in the state file under `post-merge actions`.

The merge order is the dependency order, then "whatever is green first". Being last in the plan's suggested order is a tidiness preference, not a rule; if everything else is waiting on it, merge it.

---

## Step 4 — Verify the implementing sessions' chores, do not redo them

`implement-pr` journals the outcome and syncs docs itself, usually within minutes of the merge. Two sessions doing that at once corrupt the shared page or log. So after each merge:

1. Wait a few minutes (the next event is a good moment).
2. Check whether the journal entry and the docs-sync record now cover the PR. If they do, stop. If they do not after a reasonable wait, do the minimum yourself, with small, exact anchors, never a whole-page rewrite.
3. Never edit a shared page while an implementing session may be editing it. Re-read it immediately before any edit.

---

## Step 5 — Close the batch out

When every ticket is `merged` (or explicitly parked by the human):

1. Confirm each ticket's tracker state is done. Tracker automations sometimes move tickets the wrong way when PRs attach; fix any that are wrong.
2. Write one batch-level summary where the project keeps its durable record (the journal skill's current page if one is installed): what the batch delivered as a whole, the merge order and anything unusual, and the `post-merge actions` still owed by the human.
3. Update memory or the handoff note: batch complete, main at `<sha>`, what the next batch is.
4. Hand the human the list of post-merge actions in one place.
5. Stop all monitors.

---

## Step 6 — Self-update from learnings

After the batch closes, reflect: an event the monitor missed; a merge that should have waited; a check that would have caught a conflict earlier. Add a one-line entry to the Learnings section below. Keep it generic (no private or commercial specifics) and compact: at most ~12 entries, merging or dropping older ones.

---

## Notes

- **Never merge red, unreviewed, or ahead of a blocker.** Those are the three rules; everything else is bookkeeping.
- **Branches belong to their workspaces.** The reviewing seat updates branches through GitHub and merges; it does not resolve conflicts or push commits to a branch another session is working on, unless the human asks.
- **Re-arm expired monitors.** Treat a long silence as a question, not as good news.
- **The state file is the memory.** Everything the human might ask ("why isn't 223 merged?") must be answerable from it after a context reset.
- **Model choice:** the stronger review model for anything touching auth, permissions, transactions or privacy, regardless of who implemented it; the cheaper one is fine for docs, CI and renames.
- An `implement-pr` run ends after one PR. A ticket that needs several PRs needs a nudge from the human per PR; say so as soon as the first one merges.

---

## Learnings

*Populated automatically during runs. Do not edit manually. Keep entries generic — no private or commercial specifics.*
