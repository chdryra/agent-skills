---
name: review-plan
description: Review an implementation plan against a ticket. Fetches the ticket from your issue tracker, maps each requirement/scenario to the plan, identifies gaps or risks, and returns a structured assessment with a sign-off decision. Used as a sub-agent by plan-pr, but can be run standalone.
argument-hint: <ticket-id> <plan-file> [ticket-cache-file]
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

`$ARGUMENTS` is: `<ticket-id> <plan-file> [ticket-cache-file]`

- Extract the ticket ID (e.g. `PROJ-123`).
- Extract the plan file path (e.g. `.claude/plans/PROJ-123.md`).
- Extract the optional ticket cache file path (e.g. `.context/pr-suite/PROJ-123/ticket.md`).
- Read the plan file contents. If the plan file does not exist, output: `ERROR: Plan file not found at <path>`.

---

## Step 2 — Establish the requirements to review against

### Ticket cache — check first

If a ticket cache file was passed as the third argument, or `.context/pr-suite/<ticket-id>/ticket.md` exists, read it and use it as the requirements — skip tracker detection and the fetch entirely. This is the normal path when invoked from `plan-pr`, which caches the ticket on its first fetch.

### Ticket path (when the ID matches a known tracker format)

If there is no cache and `<ticket-id>` looks like a real tracker ID (e.g. `PROJ-123`, `ENG-123`, `#123`), fetch it from the detected tracker. Read any token programmatically and **never echo it**:

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

Output **only** the assessment block below — no preamble, no narration of what was read, no restating the plan. When run as a sub-agent, this block is the entire return value. Use this exact format so `plan-pr` can parse it:

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
   - Keep the section compact: at most ~30 entries of 1-3 lines each. Before adding, look for an entry the new one overlaps and merge into it; drop the least useful entry rather than growing the list. Every entry is read on every run, so length costs each future review.

3. Do **not** record ticket-specific plan details. Keep learnings free of any private or commercial specifics.

---

## Notes

- Be specific about *where* in the plan a gap exists — quote the plan section if helpful.
- Do not penalise partial (⚠️) items if the ticket itself defers them to a follow-up or an out-of-diff mechanism.
- Focus on correctness and completeness, not style.

---

## Learnings

*Populated automatically after each use. Do not edit manually. Keep entries generic — no private or commercial specifics.*

- Verify every checkable absence claim yourself — "no test asserts this", "the artefact is not checked in", "this helper has no callers", "the builder has no such function". Each takes seconds to grep, plans get them wrong, and instructions written around a false absence land nowhere, silently.
- Re-run the plan's call-site counts with `grep -c`, one helper at a time, across every package including test packages. Plans under-count badly and directionally: the helper a plan calls "unchanged" often owns most of the sites, so its "mechanical churn" commit is where the risk lives.
- Do not accept a plan's names for the tests it says will break — grep for the old value or assertion. Plans name a plausible test that has no such assertion while missing the real one, often a count assertion that breaks silently. A plan naming zero breaking tests is itself the signal to go looking.
- On a second pass, check the *scope* of each fix, not just its presence: read the paths it claims to cover and look for sibling paths the revision did not extend to. On a rework against a rewritten ticket, check the AC mapping names each superseded criterion and says why, not silently renumbering around it.
- For every test a plan proposes, ask whether it would fail if the change were absent. A permissive-default fixture, a viewer subscribed to nothing, tied rows that land inside one page — each makes the assertion pass with or without the guard under test.
- When a plan says an existing test "must be flipped" to the opposite status, read its fixture, not its name: if it builds the permissive default the new gate never fires, and the right change is a new test with the restrictive fixture. When flipping deny→allow, check what coverage that assertion was the only source of.
- Read a plan's end-to-end test as a linear script, re-evaluating each step against the state the previous one leaves. Fixes to one step routinely invalidate a later assertion — a teardown that a newly created dependent now blocks, or a now-succeeding delete that cascades away the row a later step reads back.
- When a plan adds the first audit/log row to a function that wrote none, grep for a test asserting that absence, and for exact row-count assertions in every suite sharing a helper on that path. Both contradict the plan directly and are routinely missing from its change list.
- Never accept an instruction to delete a line range from a test file. Print the file's test-function lines with numbers and check the range's endpoints land on function boundaries — ranges routinely orphan a header and swallow cases the plan's own prose says survive. Ask for deletions named by function.
- When an acceptance criterion demands a failure/rollback test, make the plan name the injection point rather than deferring to "whatever pattern the file already uses". The usual mechanism — killing the connection pool — fails before the write under test, and then leaves nothing able to read the table back.
- When a plan satisfies "adding a new enum value must fail a test", trace what happens to an unclassified value: a switch with no default falls through to a named branch, and a table-driven walk still needs a failing default in the per-value fixture builder. Asserting the case lists union to the canonical list fails closed.
- When a permission bypass is conditioned on "the caller holds no role row at all", enumerate every value that column can hold. Neutral states such as `pending`, and active-but-unprivileged roles, end up worse off than a total stranger; the condition wanted is almost always "the caller is not in a denial state".
- When a plan adds a not-found-on-unknown-id check to a write endpoint that its sibling lacks, weigh it against the codebase's hidden-content rule: a hidden id succeeding while an unregistered one 404s makes the endpoint a sharper existence oracle than any read path. Recommend the same visibility guard the reads use.
- When a plan filters or guards one reference column of a shared event/audit table, check the sibling column too — the same entity turns up in the other slot under different event types, so a one-column filter leaves a partial leak.
- When a plan adds a visibility filter to data that is also counted, check the aggregate readers that JOIN the table, not just those that SELECT from it, and put the filter in the JOIN's ON clause: in WHERE it degenerates a LEFT JOIN into an inner one and drops the zero-count rows.
- When a plan widens a single-key aggregate into a batched `IN (...)`, check that every de-duplication key inside it — `DISTINCT ON`, `GROUP BY`, window `PARTITION BY` — gains the batching column, or rows collapse across the batched entities and undercount.
- When a plan reuses an existing SQL predicate helper, check the new call site's outer query does not select from a table the helper references unaliased: the inner name shadows the outer one and the correlation degenerates into an always-true test. Check the helper's parameter types too, not just its name.
- When a plan bounds a window with `COALESCE(manualCutoff, automaticCutoff)`, check the first argument can never fall later than the second. COALESCE takes the first non-null, not the earliest, so a late manual value widens the window back out and can flip a derived status; `LEAST`, or two AND'd bounds, is the usual intent.
- When a plan spells out a JOIN's ON clause, check every table it names is in scope at that point. Fluent query builders chain left-associatively, so a condition referencing a table joined later is a forward reference that fails at runtime; a nested join or an EXISTS subquery is the fix.
- For an AC phrased as "the query plan shows an index scan on X", enumerate the table's existing indexes first: ones already covering the predicate often make a different plan the optimiser's correct choice, so the criterion can be unsatisfiable as written.
- When a plan adds a shared pinning lock to a transaction that later takes an exclusive lock on any of the same rows, flag the share-to-exclusive upgrade deadlock: both transactions take the locks in the same order, so a "lock ordering is consistent" proof misses it. Narrow the pinning select to rows never re-locked exclusively.
- Do not accept a no-deadlock proof drawn only over the functions the plan touches. Enumerate every transaction reaching the same rows in the other order, including implicitly — inserting a row with a foreign key takes a shared lock on the parent, and audit-log inserts naming the actor are the usual hidden second lock.
- When a plan closes a check-then-write race on an endpoint with two authorization branches — privileged action and self-service — check the self-service branch too; its own gate is routinely left outside the transaction.
- When a race is called harmless because the final row state is deterministic, check what the losing request already returned and wrote: a committed 2xx, or a permanent public audit row for a state that no longer exists, is a real defect the "final state" framing hides.
- Before accepting "add a new migration" — or an in-place edit of the original — check the file's history for how the repo made the same change before, and say which way it leans rather than deciding. A new migration splits one source of truth in two; an in-place edit leaves long-lived dev databases silently stale, so the PR description must carry a one-time recreate.
- When a plan adds a value to a language-level enum, check whether that enum is mirrored in a seeded reference table with a foreign key: the new value then needs a data migration or every write using it fails at runtime. Take seed ids from the migration file, never the enum's length — removed values leave gaps.
- When a plan returns an existing domain struct from a new query, check which fields sibling read paths fill by post-query enrichment. A path that skips it returns nulls where every other endpoint returns data — and enrichment helpers are often unfiltered by viewer, so reusing one blindly can leak restricted names.
- When a plan changes the expression an `UPDATE ... SET` writes into a timestamp/audit column, grep the migrations for a before-update trigger on that table first: a shared trigger overwrites whatever the statement supplied, so the bug may not exist and the plan's rationale is false.
- When a plan makes previously-legal state illegal, grep the tests for fixtures that create it — suites rely on it casually as setup noise and break far from the feature. Check whether the shared setup helper swallows errors too, since the refusal then surfaces as a panic pages away from its cause.
- For a plan whose central security property depends on a setting outside the repository — an identity-provider toggle, a cloud IAM policy, a database privilege — require a blocking, recorded step, and say plainly in the review that no test or CI job can verify it.
