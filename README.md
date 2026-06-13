# agent-skills

Claude Code custom commands for product dev. Pick the ones you want and copy them to `~/.claude/commands/`.

## Install

```bash
# Standalone skills — copy individually
cp session/handoff.md ~/.claude/commands/
cp analysis/explain-codebase.md ~/.claude/commands/

# Audit skills — each is self-contained; copy any subset
cp audits/*.md ~/.claude/commands/
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
