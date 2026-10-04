---
name: create-batch
description: Pick the next batch of tickets to work on and save it under a name. Reads the tracker's backlog, drops anything parked or blocked by unmerged work, orders the rest by priority, how much each unblocks, and age, fills the requested number of slots while avoiding tickets that clash, shows you the pick with a reason per ticket, and on your confirmation saves the batch (and labels the tickets) so plan-batch and finish-batch can run on the name alone. Use before plan-batch when you want the model to propose the batch rather than typing ticket ids.
argument-hint: [<batch-name>] [--size <n>] [--from <label|project|cycle>] [--include <ids>] [--exclude <ids>] [--min-priority urgent|high|medium|low]
allowed-tools: Bash, Read, Edit, Write, Glob, Grep
---

# create-batch

Choose the next few tickets and give the batch a name. Everything downstream (`plan-batch <name>`, `finish-batch <name>`) then works from that name.

Part of the **PR suite**. Needs an issue tracker; writes the state file that `plan-batch` and `finish-batch` read.

**Usage:**
```
/create-batch                       # name generated, default size
/create-batch batch-e --size 5
/create-batch hardening --size 4 --from "audit-2026-10" --exclude PROJ-43
```

- `<batch-name>` — optional. If missing, generate one: the next letter after the last batch found in `.context/pr-suite/batch-*/` or the tracker's batch labels (`batch-a`, `batch-b`, …), or `batch-<YYYY-MM-DD>` if there are none.
- `--size <n>` — how many tickets. Default 5; refuse more than 6 unless the human insists (a bigger batch costs more to plan, implement and review than one person can comfortably follow).
- `--from` — restrict the pool to a tracker label, project or cycle.
- `--include` / `--exclude` — force tickets in or out before the rule runs.
- `--min-priority` — ignore tickets below this priority.

---

## Why the model does not simply "pick good tickets"

Left to taste, a model picks whatever looks interesting or whatever it read most recently. Choosing tickets is a judgment the human owns. So this skill applies **one fixed, explainable rule**, shows its working, and lets the human swap tickets in and out before anything is saved. The rule is deliberately boring; the human's confirmation is the steering.

---

## Step 0 — Detect the tracker and the conventions

1. Detect the issue tracker the way `plan-pr` does (Linear MCP tools → Jira config → GitHub Issues → memory → ask).
2. Look for an existing batch convention: state files under `.context/pr-suite/batch-*/`, tracker labels shaped like `batch-*`, and any note in memory or the repo's agent instructions about a planned next batch or a parked list. A recorded "next batch" plan takes precedence over the rule below; say so when you use it.

---

## Step 1 — Build the pool

Fetch the team's tickets that are in a backlog or to-do state (not in progress, not in review, not done, not cancelled). Then remove:

- tickets marked parked, deferred or "wait for X" in their text, labels or a remembered parked list;
- tickets **blocked by** anything that is not done. Planning a blocked ticket is fine; implementing it is not, and a batch is for implementing;
- anything in `--exclude`; anything below `--min-priority`; anything outside `--from`.

Always keep `--include` tickets, even if the filters would drop them, and say why they would have been dropped.

For every remaining ticket record: priority, created date, how many other open tickets it blocks (its "unblock count"), its suggested implement/review models if the ticket states them, and any files or areas its text names.

---

## Step 2 — Order and fill

Order the pool by:

1. priority, highest first;
2. unblock count, highest first (landing an enabler early frees the next batch);
3. created date, oldest first.

Fill the slots from the top. Skip a ticket (and come back to it only if slots remain) when:

- it blocks, or is blocked by, a ticket already picked. Two dependent tickets in one batch means one of them waits for the other's merge, which wastes a workspace;
- it names the same files or area as a ticket already picked and neither says which lands first;
- it is a multi-PR or very large ticket and the batch already has one of those.

Write down the reason for every skip.

---

## Step 3 — Show the pick and ask once

One message:

| Slot | Ticket | Priority | Why this one | Implement / review |
|---|---|---|---|---|
| 1 | PROJ-12 | High | oldest high; independent | sonnet / opus |

Then the top three or four tickets **left out**, each with its one-line reason (blocked by PROJ-9; same files as PROJ-12; parked). Then one question: "Go with this batch, or swap anything?"

If the human swaps, re-check the clash rules for the new set and show the table again, briefly. Remember any preference the human states ("always put the CI tickets last", "never mix docs tickets into a fix batch") in memory, so the next run applies it without being told.

---

## Step 4 — Save the batch

On confirmation:

1. Write `.context/pr-suite/<batch-name>/state.md`: the batch name, the date, the ticket list in slot order, per-ticket implement and review models (from the tickets' own "Suggested model" lines, else: cheaper model when the ticket is fully specified at file level, stronger model otherwise), dependency and shared-file notes from Step 2, and `status: created`. Where plans are copied for the implementation workspaces is `plan-batch`'s concern, not this skill's. Every later skill reads this file.
2. If the tracker supports labels, add a `<batch-name>` label to each ticket (create it if needed). This makes the batch visible outside the chat and lets `plan-batch`/`finish-batch` rebuild the state file from the tracker if `.context/` is lost. Do not change ticket states; `plan-pr` moves tickets to in-progress when planning starts.
3. Reply with one line: "Batch `<name>` saved with N tickets. Run `/plan-batch <name>` to plan it."

---

## Step 5 — Self-update from learnings

After the batch is saved, reflect: a filter that should have applied; a clash the rule missed; a preference the human stated. Add a one-line entry to the Learnings section below. Keep it generic (no private or commercial specifics) and compact: at most ~12 entries, merging or dropping older ones.

---

## Notes

- The rule is intentionally simple. If the human wants something the rule cannot express, they say so at Step 3 and the preference is remembered; the rule does not grow a dozen flags.
- A ticket's own text is the only source for "touches the same files". If tickets do not name files, the clash check is weaker; say so rather than guessing.
- Never include a ticket whose blocker is open, even if the blocker is in the same batch, unless the human asks. Stacking a branch on an unmerged sibling is how merges go wrong.
- Keep batches small. Five is comfortable; six is the ceiling without an explicit override.

---

## Learnings

*Populated automatically during runs. Do not edit manually. Keep entries generic — no private or commercial specifics.*
