# Shared audit protocol

This file is referenced by the individual audit skills (`security-audit`, `performance-audit`, `reliability-audit`, `tooling-audit`). It is not a standalone command — install it alongside the individual files.

---

## Phase 0 — Scope (before reconnaissance)

An audit asked an open question ("what could be better?") always finds something, and refills the backlog whether or not the code improved. This phase makes the question closed.

1. **Read the project rulebook if the repo has one.** A rulebook is a file of the project's standing rules, each with a stable id: look for a file named `review-rules.md` under `docs/` or `*/docs/design/` (`git ls-files | grep -i review-rules.md`), or a path CLAUDE.md names for it. If there is none, skip the rest of this phase and run Phases 1–4 as written.
2. **Read its parked list and proposals list.** Anything on either is settled: do not report it again, in any wording.
3. **Scope to what changed.** The rulebook's last-audit table records the commit this audit type last ran against. Audit only files in `git diff <that commit>..HEAD --name-only` (plus anything they call into that you must read to judge them). If the table has no commit for this audit type, audit everything once and record the commit afterwards.
4. **Every finding cites a rule id**, from the rulebook, the project's CLAUDE.md or a design document. A finding that cites none is a *proposal*, reported in its own section of Phase 4, never fixed in this run and never turned into a ticket; the human decides whether it becomes a rule.
5. **Prefer the rulebook's own checks.** Where the rulebook carries a per-stack list of audit checks (each naming the test or CI step that already guards it), use those in Phase 2 in place of the generic checklist for anything they cover; do not re-report what a listed guard already enforces.

In Phase 3, every fix also adds the tripwire that stops the same finding being made twice (a test, a lint rule, a CI check) and a row for it in the rulebook's enforced-rules table. In Phase 4, end the report with one line, `Blockers: N` (findings that stop the project's named finish-line events), then record this audit's commit, date and blocker count in the rulebook's last-audit table.

---

## Phase 2.5 — Confirm with user

Before fixing anything, present all findings to the user as a list. For each finding include: severity, location (file:line), a one-line description of the issue, and a proposed commit summary in the form `fix(<type>): <what the issue was and what the fix is>`. Then ask two questions:

1. "Which of these would you like me to fix?"
2. "Should I commit each fix as I go, or leave changes unstaged for you to review first?"

Wait for their response before proceeding. Default to leaving changes unstaged if they don't address the commit question.

---

## Phase 3 — Fix

Fix only the issues the user approved, one at a time. For every fix:

1. **Understand before changing.** Re-read the relevant code and confirm your root-cause analysis before touching anything.
2. **Make the minimal change.** Fix only the specific issue. Do not refactor, rename, or improve adjacent code.
3. **Run tests after every change.** The fix must not alter behaviour beyond the issue being addressed. A fix that breaks existing tests is not acceptable.
4. **Commit only if the user said yes in Phase 2.5.** If committing, one commit per issue:
   ```
   fix(<type>): <issue> in <file/function>

   Root cause: <one sentence on the precise cause>
   Impact: <what this caused or allowed>
   Fix: <what was changed and why this is correct>
   ```
   Replace `<type>` with: `security`, `perf`, `reliability`, or `tooling`. If not committing, leave changes unstaged and summarise what was changed at the end.

The individual audit file may add one or two type-specific fix rules (e.g. considering migration paths for security, or failing fast at startup for reliability). Apply those in addition to the above.

---

## Phase 4 — Report

After all fixes are applied, produce a brief findings report:

```
## [Audit Type] Audit Findings

### Fixed
- [SEVERITY] <issue> (<file:line>) — <what was done>

### Identified but not fixed
- [SEVERITY] <issue> — <reason not fixed>

### Not found
- No issues found in: <categories>
```

Do not pad the report. Every finding must include a location and a concrete description.
