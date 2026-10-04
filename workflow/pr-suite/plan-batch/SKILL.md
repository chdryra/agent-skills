---
name: plan-batch
description: Plan a named batch of tickets at once. Reads the batch create-batch saved (or an explicit ticket list), runs plan-pr for every ticket in parallel (one sub-agent each, at the model recorded for it), waits for all of them, then walks you through the open questions one at a time, records each answer in the plan, signs the plans off, posts a sign-off note on each ticket, copies the plans wherever your implementation workspaces pick them up from, and ends with a table of /implement-pr commands and models. Use after create-batch, before a round of implementation.
argument-hint: <batch-name> [--no-review <ticket-id>,...] | <ticket-id>[:<model>] ... [--plans-dir <path>]
allowed-tools: Bash, Read, Edit, Write, Glob, Grep, Agent, Skill
---

# plan-batch

Plan several tickets in one sitting. Each ticket gets its own planning sub-agent running `plan-pr`; you only get involved once every plan is drafted, and then one question at a time.

Part of the **PR suite**. Needs `plan-pr`; uses `review-plan` if installed. Usually follows `create-batch`, which chose the tickets and saved the batch under a name; `merge-batch` takes over once the implementations are launched.

**Usage:**
```
/plan-batch batch-e                              # the normal form: a batch create-batch saved
/plan-batch batch-e --no-review PROJ-12,PROJ-13  # skip the plan critique for fully specified tickets
/plan-batch PROJ-12:sonnet PROJ-13:opus --plans-dir ~/Dev/myrepo/.claude/plans   # ad hoc, no create-batch
```

- `<batch-name>` — a batch saved by `create-batch` in `.context/pr-suite/<batch-name>/state.md` (or, if that is missing, a tracker label of the same name). The ticket list, per-ticket models and plans directory all come from there, so nothing else needs typing.
- `<ticket-id>:<model>` — the ad hoc form when there is no saved batch. The model is what the planning sub-agent runs on: the cheaper one when the ticket already spells out files, steps and acceptance criteria; the stronger one when design judgment is left. Default: the stronger model available to you. A slug is generated for the state file.
- `--no-review` — skip the `review-plan` critique for the named tickets (sensible when the ticket itself was already verified line by line and the plan is short).
- `--plans-dir` — where approved plans are copied for the implementation workspaces (see Step 5). Normally not needed: the path is taken from memory or the repo's agent instructions.

---

## Why a batch skill

Planning five tickets by hand means five `plan-pr` runs, each stopping to ask you things while the others are still working, and the same closing chores five times. The failure modes are always the same: the first question arrives before the other planners have finished and gets buried under progress notices; questions arrive in a block of fifteen; a plan is approved but never copied where the implementing workspace looks for it; the launch table has to be rebuilt from memory. This skill does the mechanical parts once and keeps the human parts in the order that works.

---

## Step 0 — Load the batch and check it

1. If the first argument is a batch name, read `.context/pr-suite/<batch-name>/state.md`; if it is missing, rebuild it from the tracker label of that name (ticket list only; models default as below). Take the ticket list, per-ticket planner models (use the recorded implement model as the planner model unless the state file names one) and the dependency notes from there. Otherwise collect the ticket ids and models from the arguments and generate a slug.
2. Detect the issue tracker the way `plan-pr` does (Linear MCP tools → Jira config → GitHub Issues → memory → ask).
3. For each ticket, fetch just enough to sanity-check: it exists, it is not already in review or done, and its blocking relations. Then warn about, but do not refuse:
   - a ticket blocked by something **outside** the batch that is not merged yet. Planning it is fine; implementing it is not until the blocker lands. Say so in the final table.
   - two tickets in the batch where one blocks the other. Plan both, and put the order in the final table.
   - two tickets that touch the same files (if the tickets say so). Put the order in the final table.
4. In the ad hoc form, choose a short batch slug (for example the date) for the state file.

Write or update `.context/pr-suite/<batch-name>/state.md` with the ticket list, models, flags and `status: planning`. Update it as you go; it is what survives a context reset.

---

## Step 1 — Launch the planners, all at once

Spawn one background sub-agent per ticket, all in a single step, each at its ticket's model. The prompt to each:

> Run the `plan-pr` skill for `<ticket-id>` **non-interactively**: do not ask the human anything. Write the plan to `.claude/plans/<ticket-id>.md` with an "Open questions" section. [If the ticket is not in the `--no-review` set:] Run the `review-plan` critique and loop until it returns APPROVED or you have done three rounds; record the final status. For every open question, give your own recommendation and the reason in one or two sentences. Do not move any ticket beyond its in-progress state, do not create branches, do not touch other tickets' plans. Report back: the plan path, the review status, the open questions with recommendations, and anything in the ticket you found to be wrong or already done.

`plan-pr` moves the ticket to its in-progress state itself; if the tracker has no such state, nothing to do.

Then **wait for all of them**. Do not poll. Do not start the sign-off for the first planner that finishes. Do not post "planner 3 is done" updates between questions later. If one planner fails or stalls, nudge it once with a message; if it still fails, plan that ticket inline yourself after the others have reported.

---

## Step 2 — One digest, then the first question

When every planner has reported, give the human **one** short message:

1. A table: ticket, review status, number of open questions, one-line headline of the approach.
2. Anything a planner found wrong with a ticket (already fixed, stale line numbers, a claim that did not hold).
3. Then the **first** open question only, in plain English, with the recommendation and a concrete example where it helps.

Nothing else. The human should be able to answer with one word.

---

## Step 3 — Sign-off, one question at a time

Work through the tickets in the order they were given, and through each ticket's open questions in order. For each:

1. Ask one question. Wait for the answer. Never bundle two, never list the remaining ones.
2. Record the answer in the plan file under a `## Decisions` section (the question, the answer, the date). Keep the plan's own text consistent with the decision; edit the relevant section rather than leaving a contradiction.
3. If the answer changes scope, approach or the file list, re-run `review-plan` for that ticket (via a sub-agent, same model as its planner) before moving on. A generalising answer ("do that everywhere") is a scope change: list what it now reaches, confirm, then re-review. A wording-level answer needs no re-review.
4. If an answer affects another ticket in the batch, say so in one sentence and record it in that ticket's plan too.
5. When the human asks "explain" or "explain more simply", explain with an example before re-asking; do not move on.

When a ticket has no open questions and its review is APPROVED, say so in one line and go straight to the next ticket's first question.

---

## Step 4 — Sign the plans off

Once every question is answered and every review is APPROVED:

1. Append to each plan: `Signed off <YYYY-MM-DD>` and the list of decisions.
2. Post one comment on each ticket in the tracker: "Plan approved and signed off on <date>: <one line per decision>." Decisions are easier to find on the ticket than in a chat log.
3. Make sure each ticket is in its in-progress state.

---

## Step 5 — Put the plans where the implementations will look

`implement-pr` reads `.claude/plans/<ticket-id>.md` from the working tree it runs in. If implementations run in separate worktrees or workspaces created fresh from the default branch, that file will not be there unless something copies it. In order of preference:

1. `--plans-dir <path>` if given: copy every signed-off plan there.
2. A plan-distribution path recorded in memory or in the repo's agent instructions (for example a note that a workspace tool copies `.claude/plans/*` from a root checkout into new workspaces). Use it.
3. Otherwise, ask once: "Where should the plans go so the implementation workspaces can find them?" and remember the answer.

Verify the copies exist before moving on.

---

## Step 6 — The launch table

End with one table the human can work from without reading anything else:

| Ticket | Command | Implement model | Review model | Order / notes |
|---|---|---|---|---|
| PROJ-12 | `/implement-pr PROJ-12` | sonnet | opus | independent |
| PROJ-13 | `/implement-pr PROJ-13` | sonnet | sonnet | after PROJ-12 lands (same files) |

- Implement and review models come from the tickets' own "Suggested model" lines if they have them, else from the planner's judgment. Anything touching auth, permissions, transactions or privacy gets the stronger review model regardless of who implements.
- "Order / notes" carries every dependency and shared-file warning from Step 0. Say plainly when a ticket must **wait for a merge** rather than be started now; stacking a ticket's branch on an unmerged sibling is not an option to offer.
- Close with one sentence: run each command in its own workspace or worktree, tell me when they are launched, and I will run `/merge-batch <batch-name>` to review and merge them.

Update the batch state file to `status: signed-off` with the table, so `merge-batch <batch-name>` can read it.

---

## Step 7 — Self-update from learnings

After the batch is signed off, reflect: a question that should always be raised for this kind of ticket; a check in Step 0 that would have caught something; a way the digest or the questions could have been shorter. Add a one-line entry to the Learnings section below. Keep it generic (no private or commercial specifics) and compact: at most ~12 entries, merging or dropping older ones.

---

## Notes

- The whole point of waiting for every planner is that the human's attention is the scarce resource, not the agents' time. One digest, then one question at a time.
- Planners run non-interactively so they can run in parallel. Everything that needs a human comes back as an open question with a recommendation; the human decides in Step 3.
- A planner that finds the ticket wrong (stale line numbers, a step already done, a claim that does not hold) must report it, not quietly fix the ticket. The human decides whether to amend the ticket.
- Keep the batch to a size the human can review in one sitting. Five or six tickets is comfortable; more than that, and the sign-off round and the implementation round both get expensive. Split and say what the following batch is.
- Models are per ticket on purpose: a fully specified ticket does not need the strongest planner, and token budgets are finite.

---

## Learnings

*Populated automatically during runs. Do not edit manually. Keep entries generic — no private or commercial specifics.*
