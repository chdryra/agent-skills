---
name: plan-pr
description: Plan the implementation of a ticket. Fetches the ticket from your issue tracker, explores the codebase, produces a structured implementation plan, optionally has it critiqued by the review-plan skill, and loops with you until you're satisfied. Writes the approved plan to .claude/plans/<ticket-id>.md for use by implement-pr.
argument-hint: <ticket-id>
allowed-tools: Bash, Read, Edit, Write, Glob, Grep, Agent
---

# plan-pr

Plan the implementation of a ticket. Produces a structured implementation plan, has it reviewed, and iterates with you until both you and the review agree. Writes the approved plan to `.claude/plans/<ticket-id>.md`.

Part of the **PR suite** (`plan-pr` → `implement-pr` → `review-pr` → `monitor-pr`, with `review-plan` as a reviewer). Each skill works on its own; install the others to get the full pipeline.

**Usage:**
```
/plan-pr PROJ-123
```

---

## Detecting the issue tracker

This skill works with whatever tracker your project uses. Detect it in this order:

1. Linear MCP tools available (`mcp__linear__*`)? → Linear.
2. A `JIRA_URL` / `JIRA_PROJECT` env var, or a `.jira` / `jira.config.json` file? → Jira.
3. No external tracker, IDs look like `#123`? → GitHub Issues via `gh`.
4. Check memory for a previously noted tracker preference.
5. Ask the user.

---

## Step 1 — Fetch the ticket and ask clarifying questions

Extract the ticket ID from `$ARGUMENTS` (e.g. `PROJ-123`, `ENG-123`, `#123`).

Fetch the ticket from the detected tracker. Read any token programmatically and **never echo it**:

- **Linear:** `mcp__linear__get_issue` with the issue id.
- **Jira:** prefer Jira MCP tools; otherwise REST API v3 `GET <JIRA_URL>/rest/api/3/issue/<KEY>`. Read the auth token from a `JIRA_API_TOKEN` env var; or — *Claude Code only* — `~/.claude.json`.
- **GitHub Issues:** `gh issue view <number> --json title,body,labels,comments`.

Parse out:
- Summary / title
- Description (scenarios, acceptance criteria, decision tables)
- Any linked tickets or dependencies
- Labels / components (to identify which part of the codebase is affected)

Review the ticket for anything ambiguous, underspecified, or likely to affect implementation approach — e.g. unclear acceptance criteria, missing edge cases, conflicting requirements, or decisions that belong to the human rather than the agent.

If there are any such questions, **ask them now** before exploring the codebase. Present them as a numbered list and wait for answers before continuing to Step 2.

If the ticket is unambiguous and self-contained, say so briefly and proceed directly to Step 2.

---

## Step 2 — Explore the codebase

Based on the ticket's affected area, explore the relevant parts of the codebase:

1. Identify the module(s) / service(s) / package(s) involved.
2. Read key files relevant to the ticket's scope.
3. Understand existing patterns — how similar features are implemented, what conventions are used.
4. Identify all files that will need to change and why.

Do not skim — read the actual file contents of anything the implementation will touch.

---

## Step 3 — Produce the implementation plan

Write a structured plan covering:

```
## Implementation plan: <TICKET-ID> — <ticket title>

### Summary

<2-3 sentence overview of what needs to be done and why>

### Scenarios

For each scenario defined in the ticket:

#### Scenario N — <name>
- **Ticket requirement:** <what the ticket says>
- **Approach:** <how the plan addresses it>
- **Files to change:** <list of files>
- **Key details:** <any edge cases, gotchas, or decisions>

### Files changed

| File | Change type | Reason |
|---|---|---|
| `path/to/file` | modify / create / delete | <reason> |

### Branch name

`feat/<ticket-id-lowercase>-<short-slug>`

### Out of scope

<Anything the ticket explicitly defers or marks out of scope for this PR>

### Open questions

<Any ambiguities that need resolving before or during implementation>
```

---

## Step 4 — Review the plan

Write the draft plan to `.claude/plans/<ticket-id>.md` (creating `.claude/plans/` if needed).

**If the `review-plan` skill is installed**, spawn it as a sub-agent for an independent critique:

> Invoke the review-plan skill with arguments: `<ticket-id> .claude/plans/<ticket-id>.md`
> Return the full assessment output.

**If `review-plan` is not installed**, perform the review inline: re-read the ticket and the plan, and for each ticket scenario/acceptance criterion check coverage (covered / partial / missing) and note any risks. Produce the same sign-off (**APPROVED** / **CHANGES NEEDED**) yourself.

**IMPORTANT: do not end your response after the review.** Continue immediately to Step 5 in the same response turn — the review output appears inline and must be followed by the Step 5 presentation and question before handing control back to the user.

---

## Step 5 — Present to human for approval

Immediately after Step 4 (in the same response turn), show the user:
1. The current plan (paste the full contents of `.claude/plans/<ticket-id>.md`).
2. The review's sign-off decision (**APPROVED** or **CHANGES NEEDED**) and any ❌ missing scenarios or blocking risks.
3. Any open questions from the plan's "Open questions" section — these must be presented and resolved even if the review returned **APPROVED**.

Ask the user explicitly:
> "The review has [approved / flagged N issues]. [List any open questions.] Are you happy to proceed, or would you like changes?"

**Do not proceed to implementation until all three conditions are met:**
- Review returns **APPROVED**.
- All open questions from the plan are answered or explicitly deferred by the human.
- Human explicitly confirms (e.g. "yes", "looks good", "proceed").

---

## Step 6 — Iterate on feedback

If the review returned **CHANGES NEEDED**, the human requests changes, or any open questions remain unresolved:

1. Update the plan based on the feedback or answers to open questions.
2. Overwrite `.claude/plans/<ticket-id>.md` with the revised plan.
3. Re-run the review (Step 4).
4. Re-present to the human (Step 5).

Repeat until all three conditions in Step 5 are met.

---

## Step 7 — Finalise the plan

Once all three conditions in Step 5 are met (review APPROVED, open questions resolved, human confirms):

1. Ensure `.claude/plans/<ticket-id>.md` contains the final agreed plan.
2. Tell the user:
   > "Plan approved and saved to `.claude/plans/<ticket-id>.md`. Run `/implement-pr <ticket-id>` to start implementation." (if `implement-pr` is installed)

---

## Step 8 — Self-update from learnings

After the session ends (plan approved, or user abandons), reflect on how the planning session went:

1. **Identify learnings** — things that would have made the plan better or faster:
   - A file or module that turned out to be critical but wasn't obvious from the ticket.
   - A codebase pattern discovered during exploration that is likely to recur.
   - A ticket format or label that reliably signals which area is affected.
   - A type of open question that should always be raised for this kind of ticket.

2. **Update this skill file** if a learning is general enough to apply to future sessions:
   - Add it to the **## Learnings** section below.
   - Only add it if it would change the plan output or exploration approach for a future ticket.

3. Do **not** record ticket-specific implementation details — only methodology improvements. Keep learnings free of any private or commercial specifics.

---

## Notes

- The plan file is the contract between planning and implementation — be precise about file paths and approaches.
- If the ticket has no scenario list, derive scenarios from the acceptance criteria.
- Do not begin any implementation work in this skill — planning only.
- Open questions should be resolved with the human during the iteration loop, not deferred to implementation.

---

## Learnings

*Populated automatically after each session. Do not edit manually. Keep entries generic — no private or commercial specifics.*
