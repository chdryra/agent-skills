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
| `review-plan` | `/review-plan <ticket-id> <plan-file> [ticket-cache]` | Critique a plan against its ticket scenario-by-scenario; returns a sign-off. Usually a sub-agent of `plan-pr`. |
| `implement-pr` | `/implement-pr <ticket-id>` | Implement an approved plan on a branch, validate locally, open the PR, then monitor and autofix review comments + CI failures. |
| `review-pr` | `/review-pr <pr#> [--watch]` / `--local <ticket-id> [--full]` | Review a PR against its ticket and post a structured coverage review; `--watch` re-reviews on new commits; `--local` reviews the branch diff without posting (delta by default, `--full` for the whole diff). |
| `monitor-pr` | `/monitor-pr <pr#>` | Start an event-driven monitor on a PR (comments, CI, merge state, SHA). Setup only — the caller owns the reaction logic. |

## Pick-and-mix vs. the full package

These skills cross-reference each other, but each is **independently installable** — every cross-reference is a soft, optional enhancement:

- `plan-pr` spawns `review-plan` if it's installed; otherwise it reviews the plan inline.
- `implement-pr` uses `review-pr --local` if it's installed; otherwise it checks coverage inline. It starts `monitor-pr` if installed; otherwise it tells you to watch the PR manually.
- `review-pr --watch` needs `monitor-pr`; without it, the one-shot review still works.
- `implement-pr` logs the merged ticket via a `/journal`-style skill if one is installed; otherwise it skips that step.

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

`monitor-pr` bundles `monitor-pr.sh`, and `implement-pr` bundles `handlers.md` (event-handler reference, loaded only when a PR event fires) — keep each alongside its `SKILL.md`.

## Token efficiency

The suite is built to avoid re-paying for work it has already done. Shared state lives in `.context/pr-suite/<ticket-id>/` (gitignore `.context/`):

- `ticket.md` — the ticket is fetched from the tracker **once** (by whichever skill runs first) and reused by every later pass.
- `last-review.md` — the previous coverage table + reviewed SHA. Repeat `review-pr --local` passes are **delta reviews**: only the diff since the last pass is re-assessed, unchanged rows carry forward. One `--full` pass on the strongest model gates PR creation; intermediate loop passes can run on a smaller model.
- `state.md` — implement-pr's monitoring handoff (PR number, worktree, last pushed SHA). PR events are handled by a fresh sub-agent reading this file plus `handlers.md`, so the large implementation conversation isn't replayed (uncached) on every event.

Review-comment fixes are batched per monitor notification — one review pass, one merge, one push — with individual replies per comment.

## Assumptions

- **GitHub** for PRs (via the `gh` CLI, authenticated).
- **An issue tracker** — Linear, Jira, or GitHub Issues — auto-detected (MCP tools → env vars/config → ask). Tokens are read programmatically and never echoed.
- **Trunk-based**: branches cut from and merged to `origin/main`.

Adjust the branch convention, commit-message format, and worktree setup in `implement-pr` to match your repo.
