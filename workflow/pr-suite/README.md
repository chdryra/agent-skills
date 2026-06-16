# PR suite

A set of skills that take a ticket from plan → implementation → review → merge, reacting to PR events along the way.

```
plan-pr  ──▶  implement-pr  ──▶  (PR opened)  ──▶  monitor-pr  ──▶  review-pr
   │                                                                   ▲
   └─ review-plan (critiques the plan)         review-pr --local ──────┘
                                               (used by implement-pr before the PR exists)
```

| Skill | Command | What it does |
|---|---|---|
| `plan-pr` | `/plan-pr <ticket-id>` | Fetch the ticket, explore the codebase, write a structured implementation plan to `.claude/plans/<ticket-id>.md`, and iterate with you until approved. |
| `review-plan` | `/review-plan <ticket-id> <plan-file>` | Critique a plan against its ticket scenario-by-scenario; returns a sign-off. Usually a sub-agent of `plan-pr`. |
| `implement-pr` | `/implement-pr <ticket-id>` | Implement an approved plan on a branch, validate locally, open the PR, then monitor and autofix review comments + CI failures. |
| `review-pr` | `/review-pr <pr#> [--watch]` / `--local <ticket-id>` | Review a PR against its ticket and post a structured coverage review; `--watch` re-reviews on new commits; `--local` reviews the branch diff without posting. |
| `monitor-pr` | `/monitor-pr <pr#>` | Start an event-driven monitor on a PR (comments, CI, merge state, SHA). Setup only — the caller owns the reaction logic. |

## Pick-and-mix vs. the full package

These skills cross-reference each other, but each is **independently installable** — every cross-reference is a soft, optional enhancement:

- `plan-pr` spawns `review-plan` if it's installed; otherwise it reviews the plan inline.
- `implement-pr` uses `review-pr --local` if it's installed; otherwise it checks coverage inline. It starts `monitor-pr` if installed; otherwise it tells you to watch the PR manually.
- `review-pr --watch` needs `monitor-pr`; without it, the one-shot review still works.

So you can:
- **Install the whole folder** for the full pipeline, or
- **Copy one `SKILL.md`** (e.g. just `review-pr`) and it will still work on its own.

## Install

Skills are `SKILL.md` directories. Copy whichever you want into your skills directory:

```bash
# Whole suite
cp -r pr-suite/* ~/.claude/skills/

# Or one skill
cp -r pr-suite/review-pr ~/.claude/skills/
```

`monitor-pr` bundles `monitor-pr.sh` — keep it alongside its `SKILL.md`.

## Assumptions

- **GitHub** for PRs (via the `gh` CLI, authenticated).
- **An issue tracker** — Linear, Jira, or GitHub Issues — auto-detected (MCP tools → env vars/config → ask). Tokens are read programmatically and never echoed.
- **Trunk-based**: branches cut from and merged to `origin/main`.

Adjust the branch convention, commit-message format, and worktree setup in `implement-pr` to match your repo.
