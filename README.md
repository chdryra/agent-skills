# agent-skills

Pick-and-mix Claude skills for product dev. Each is self-contained — copy the ones you want.

Two formats live here:

- **Flat commands** — single `.md` files (audits, analysis, session, the simpler workflow skills). Install to `~/.claude/commands/`.
- **`SKILL.md` directories** — a folder containing `SKILL.md` plus any bundled scripts (the PR suite, `release-digest`, `investigate-logs`). Install to `~/.claude/skills/`.

## Install

```bash
# Flat commands — copy individually
cp session/handoff.md ~/.claude/commands/
cp analysis/explain-codebase.md ~/.claude/commands/

# Audit skills — each is self-contained; copy any subset
cp audits/*.md ~/.claude/commands/

# SKILL.md directories — copy the whole folder (keeps bundled scripts alongside)
cp -r bug-fixing/investigate-logs ~/.claude/skills/
cp -r workflow/release-digest    ~/.claude/skills/

# The PR suite is a package of five skills; install all or just one
cp -r workflow/pr-suite/*        ~/.claude/skills/   # whole suite
cp -r workflow/pr-suite/review-pr ~/.claude/skills/  # or just one
```

---

## Skills

### Audits

Each audit skill is self-contained — install any subset you want.

| File | Command | What it does |
|---|---|---|
| `audits/security-audit.md` | `/security-audit` | Injection, auth bypass, weak crypto, CORS |
| `audits/performance-audit.md` | `/performance-audit` | N+1 queries, missing indexes, unbounded results |
| `audits/reliability-audit.md` | `/reliability-audit` | Unhandled errors, timeouts, race conditions |
| `audits/tooling-audit.md` | `/tooling-audit` | CI/CD, test coverage, type safety, linting |

### Analysis

| File | Command | What it does |
|---|---|---|
| `analysis/explain-codebase.md` | `/explain-codebase` | Purpose, stack, structure, data flow, key files — optionally writes to Notion or Confluence |

### Session

| File | Command | What it does |
|---|---|---|
| `session/handoff.md` | `/handoff` | Write or read a session handoff file — preserves context across agent restarts |

### Workflow

| File | Command | What it does |
|---|---|---|
| `workflow/journal.md` | `/journal` | Work journal with dated entries — supports Notion, Confluence, or any wiki |
| `workflow/ticket.md` | `/ticket` | Create tickets in Linear or Jira |
| `workflow/release-digest/` | `/release-digest` | Turn a range of git commits into readable release notes — HTML, Markdown, or Notion. Git history only |

#### PR suite (`workflow/pr-suite/`)

A package of five `SKILL.md` skills that take a ticket from plan → implementation → review → merge. Each is independently installable; cross-references between them are soft (optional). Works with GitHub PRs and an auto-detected issue tracker (Linear / Jira / GitHub Issues). See `workflow/pr-suite/README.md`.

| Skill | Command | What it does |
|---|---|---|
| `pr-suite/plan-pr` | `/plan-pr` | Fetch a ticket, explore the code, and write an implementation plan |
| `pr-suite/review-plan` | `/review-plan` | Critique a plan against its ticket and sign off |
| `pr-suite/implement-pr` | `/implement-pr` | Implement an approved plan, open the PR, autofix review/CI feedback |
| `pr-suite/review-pr` | `/review-pr` | Review a PR against its ticket; `--watch` re-reviews on new commits |
| `pr-suite/monitor-pr` | `/monitor-pr` | Event-driven PR monitor (comments, CI, merge state, SHA) |

### Bug fixing

| File | Command | What it does |
|---|---|---|
| `bug-fixing/investigate-logs/` | `/investigate-logs` | Investigate a production error from a GCP Cloud Logging URL — traces across services to root cause and writes up findings to a wiki |
