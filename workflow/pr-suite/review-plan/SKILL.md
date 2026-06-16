---
name: review-plan
description: Review an implementation plan against a ticket. Fetches the ticket from your issue tracker, maps each requirement/scenario to the plan, identifies gaps or risks, and returns a structured assessment with a sign-off decision. Used as a sub-agent by plan-pr, but can be run standalone.
argument-hint: <ticket-id> <plan-file>
allowed-tools: Bash, Read, Edit, Write, Glob, Grep
---

# review-plan

Review an implementation plan against a ticket. Fetches the ticket requirements, maps them to the plan scenario-by-scenario, identifies gaps or risks, and returns a structured sign-off.

Part of the **PR suite**. Usually invoked as a sub-agent by `plan-pr`, but runs standalone too.

**Usage:**
```
/review-plan PROJ-123 .claude/plans/PROJ-123.md
```

---

## Detecting the issue tracker

Detect it in this order:

1. Linear MCP tools available (`mcp__linear__*`)? → Linear.
2. A `JIRA_URL` / `JIRA_PROJECT` env var, or a `.jira` / `jira.config.json` file? → Jira.
3. No external tracker, IDs look like `#123`? → GitHub Issues via `gh`.
4. Check memory for a previously noted tracker preference.
5. Ask the user.

---

## Step 1 — Parse arguments

`$ARGUMENTS` is: `<ticket-id> <plan-file>`

- Extract the ticket ID (e.g. `PROJ-123`).
- Extract the plan file path (e.g. `.claude/plans/PROJ-123.md`).
- Read the plan file contents. If the plan file does not exist, output: `ERROR: Plan file not found at <path>`.

---

## Step 2 — Establish the requirements to review against

### Ticket path (when the ID matches a known tracker format)

If `<ticket-id>` looks like a real tracker ID (e.g. `PROJ-123`, `ENG-123`, `#123`), fetch it from the detected tracker. Read any token programmatically and **never echo it**:

- **Linear:** `mcp__linear__get_issue` with the issue id.
- **Jira:** prefer Jira MCP tools; otherwise REST API v3 `GET <JIRA_URL>/rest/api/3/issue/<KEY>`. Read the auth token from a `JIRA_API_TOKEN` env var; or — *Claude Code only* — `~/.claude.json`.
- **GitHub Issues:** `gh issue view <number> --json title,body,labels,comments`.

Extract from the response:
- **Scenarios / decision logic** — numbered or bulleted cases the ticket defines.
- **Acceptance criteria** — any explicit requirements.
- **Summary table** if present.
- **Out of scope** items (so the plan isn't penalised for not covering them).

### Conversation path (when no tracker ticket exists)

If `<ticket-id>` is a slug (not a tracker ID), or if the tracker fetch fails, use the plan file itself as the source of requirements:

1. Read the `### Scenarios` section of the plan file — these are the requirements the plan committed to covering.
2. Read the `### Summary` section for overall intent.
3. Do not ask the user for requirements — use what is in the plan.

---

## Step 3 — Map ticket requirements to the plan

For each scenario or acceptance criterion in the ticket:

1. Find the corresponding section of the plan that addresses it.
2. Assess coverage:
   - **Covered** — plan clearly addresses this case with a concrete approach.
   - **Partial** — plan mentions it but is vague, relies on model-only behaviour, or defers it.
   - **Missing** — no mention in the plan.
   - **Out of scope** — ticket itself marks it as out of scope or for a follow-up PR.
3. Note any risks in the plan's approach — e.g. edge cases not handled, wrong file targeted, approach that will break existing behaviour.

---

## Step 4 — Produce the assessment

Output the assessment in this exact format so `plan-pr` can parse it:

```
## Plan review: <TICKET-ID>

### Scenario coverage

| Scenario | Requirement | Coverage | Notes |
|---|---|---|---|
| **1** — <name> | <ticket requirement> | ✅ / ⚠️ / ❌ / ➖ | <notes> |
...

### Risks and concerns

- <risk 1>
- <risk 2>

### Sign-off

**APPROVED** / **CHANGES NEEDED**

<One sentence rationale. If CHANGES NEEDED, list the blocking issues concisely.>
```

Coverage symbols:
- ✅ Covered — plan has a clear, concrete approach.
- ⚠️ Partial — vague, model-dependent, or deferred.
- ❌ Missing — not addressed in plan.
- ➖ Out of scope.

**Sign-off rules:**
- **APPROVED** only if there are no ❌ rows and no blocking risks.
- **CHANGES NEEDED** if any ❌ rows exist, or if a risk would cause incorrect or broken behaviour.

---

## Step 5 — Self-update from learnings

After each use, reflect on the review:

1. **Identify learnings** — things that would improve future reviews:
   - A gap flagged as ❌ that turned out to be intentionally deferred (false alarm).
   - A risk raised that was not actually a risk given how this codebase works.
   - A ticket format where the scenario extraction approach needed to change.
   - A type of plan section that reliably signals a missing scenario.

2. **Update this skill file** if a learning generalises beyond this ticket:
   - Add it to the **## Learnings** section below.
   - Only add it if it would change how a future plan is reviewed.

3. Do **not** record ticket-specific plan details. Keep learnings free of any private or commercial specifics.

---

## Notes

- Be specific about *where* in the plan a gap exists — quote the plan section if helpful.
- Do not penalise partial (⚠️) items if the ticket itself defers them to a follow-up or an out-of-diff mechanism.
- Focus on correctness and completeness, not style.

---

## Learnings

*Populated automatically after each use. Do not edit manually. Keep entries generic — no private or commercial specifics.*
