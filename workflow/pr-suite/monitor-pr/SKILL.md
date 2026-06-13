---
name: monitor-pr
description: Start an event-driven monitor on a GitHub PR. Uses the Monitor tool plus a bundled polling script that holds dedup state on disk and emits one stdout line per real state change. Cheaper than fixed-interval polling — the model is only invoked when an event actually fires. Emits events for new comments (inline / review / issue endpoints), CI failures, mergeStateStatus=BEHIND, PR state flips (merged/closed), and HEAD SHA changes. Use from other skills that need to react to PR events; the caller owns the reaction logic.
argument-hint: <pr-number> [owner/repo]
allowed-tools: Bash, Read
---

# monitor-pr

Start a persistent event-driven monitor on a GitHub PR. The bundled script polls every 60s and emits one stdout line per state change. Each line becomes a notification via the Monitor tool, so the model is only invoked when something real happens — not on every tick.

This skill is **setup only**: it starts the monitor and returns. The reaction logic for each event lives in the calling skill.

Part of the **PR suite** — used by `implement-pr` (Step 6) and `review-pr --watch`, but usable from any skill or on its own.

## When to use this

When a calling skill needs to watch a PR after creation for reviewer comments, CI failures, or mergeability changes. Replaces fixed-interval polling loops.

Do **not** use it for one-shot waits (e.g. "wait until this Actions run completes") — use `gh run watch <run-id>` or a backgrounded `Bash` call for those.

## Invocation

```
/monitor-pr <pr-number>
/monitor-pr <pr-number> <owner/repo>     # if not the current repo
```

When invoked from another skill, the calling skill should say:

> Invoke the `monitor-pr` skill with arguments: `<pr-number>`

After invocation, control returns to the calling skill, which then reacts to events as they arrive.

## What the skill does

1. Parse the PR number (and optional `owner/repo`) from `$ARGUMENTS`. Default repo is the current repo (`gh repo view --json nameWithOwner -q .nameWithOwner`).
2. Call the **Monitor tool** with:
   - `persistent: true`
   - `command:` `PR=<pr-number> REPO=<owner/repo> bash <skill-dir>/monitor-pr.sh` — where `<skill-dir>` is the directory this `SKILL.md` lives in (e.g. `.claude/skills/monitor-pr/` or wherever you installed it).
   - `description:` `PR #<pr-number> events (comments, CI, merge state, SHA)`
   - `timeout_ms: 3600000` (1h ceiling; `persistent=true` ignores it but the field is required).
3. Capture the returned task ID and report it briefly to the user, e.g. `Monitor armed: task <id>, PR #<n>`.
4. **If the first event line shows `seeded_ids > 0` and this is a manual user invocation (not a programmatic call from another skill)**, fetch and summarise the existing comments in the same turn. The script seeds historical ids to avoid flooding the event stream, but the side-effect is that you start blind to the PR's existing review state. Pull the three endpoints and report a one-line summary per comment:

   ```bash
   gh api "repos/$REPO/pulls/$PR/comments"  --paginate -q '.[] | "INLINE id=\(.id) by=\(.user.login) path=\(.path):\(.line // "?") :: \((.body // "") | gsub("[\\n\\r]+"; " ") | .[0:300])"'
   gh api "repos/$REPO/pulls/$PR/reviews"   --paginate -q '.[] | "REVIEW id=\(.id) by=\(.user.login) state=\(.state) :: \((.body // "") | gsub("[\\n\\r]+"; " ") | .[0:300])"'
   gh api "repos/$REPO/issues/$PR/comments" --paginate -q '.[] | "ISSUE id=\(.id) by=\(.user.login) :: \((.body // "") | gsub("[\\n\\r]+"; " ") | .[0:300])"'
   ```

   For programmatic callers, skip this step — they just created the PR or posted the initial review, so there's nothing pre-existing to surface.

That's it. The Monitor task runs in the background until session end or `TaskStop`.

## Event format

Each event arrives as one notification, formatted:

```
[HH:MM:SS] EVENT <type> <k=v>... [:: <body>]
```

| Type      | Fields                                                       | Meaning                                                                 |
|-----------|--------------------------------------------------------------|-------------------------------------------------------------------------|
| `armed`   | `pr=N repo=… seeded_ids=N`                                   | First-run confirmation. Existing comment ids seeded; not a real event.  |
| `inline`  | `by=<login> id=N path=… line=… in_reply_to=…`                | New inline review comment (`/pulls/N/comments` endpoint).               |
| `review`  | `by=<login> id=N state=<APPROVED\|COMMENTED\|…>`             | New top-level review (`/pulls/N/reviews`). Many review bots land here.   |
| `issue`   | `by=<login> id=N`                                            | New PR-level comment (`/issues/N/comments`). Human PR-level comments land here. |
| `ci_fail` | `check=<name> link=<url>`                                    | A CI check transitioned into the `fail` bucket. Fires once per check name. |
| `behind`  | `merge_state=BEHIND`                                         | PR `mergeStateStatus` transitioned to `BEHIND` — main has moved.        |
| `state`   | `from=<OPEN\|…> to=<MERGED\|CLOSED\|OPEN>`                   | PR state flipped. Exit signal for most callers.                         |
| `sha`     | `old=<full-40-char> new=<full-40-char>`                      | HEAD SHA changed (external push, automerge, or own push). Full SHAs (not truncated) so a caller's parent-walk can compare directly against `gh api .../commits/<sha>` results. |
| `heartbeat` | `polls=N merge=… state=…`                                  | Periodic "still alive" signal — every `HEARTBEAT_EVERY` polls (default 30, ≈ 30 min). If heartbeats stop arriving at their expected cadence, the monitor died and needs relaunching. No action required when one arrives. |
| `restarted` | `reason=poll_loop_exited code=N`                           | The inner poll loop exited unexpectedly and the script's supervisor respawned it. Investigate if recurring — usually a transient failure (API rate-limit, jq error). |

All event lines end with the comment body when applicable (truncated to 240 chars, newlines collapsed).

**Important: there is no author filter.** The authenticated user's GitHub login can coincide with a bot login, so filtering by author would silently drop real human comments. Dedup is by seen comment id only.

**One content-based filter exists:** `review` events with `state=COMMENTED` and an empty body are dropped, because POSTing an inline reply via `/pulls/N/comments` auto-creates a parent review of that exact shape. Without the filter, a burst of inline replies (e.g. answering many bot comments back-to-back) doubles the event volume — enough for the Monitor runtime to auto-kill the task. Real review submissions always carry a body and survive the filter.

### Monitor runtime kills the task on event flood

The Monitor tool stops a monitor that produces too many events in a short window. To stay under that limit, the poll loop accumulates every EVENT line from a single poll cycle into a buffer and flushes it with one `printf` at the end. The Monitor's stdout batching window then groups the whole poll into a single notification, regardless of how many comments / state changes happened — so a burst of 10+ inline replies picked up in the same poll arrives as one event, not ten. Combined with the empty-body-review filter, this makes flood-kill a non-issue for normal reply waves.

If the runtime still kills the task (very large bursts, multi-poll storms, or runtime changes), heartbeats stop and the only signal is "no events for >30 min when you'd expect activity." Re-invoke `monitor-pr <pr-number>` to resume — the on-disk state means you won't re-flood; only events posted while the monitor was dead come through, as one batch.

### Auto-rearm on kill

When you receive a task notification with `status: killed` for a monitor-pr task, **re-arm immediately without waiting for the user to ask**. Use the same PR number and repo. Don't send any text to the user — just re-invoke the Monitor tool silently. The on-disk state ensures no re-flooding. Only skip re-arming if the PR has already merged or closed (check `last_pr_state` on disk or the most recent `state` event).

## State on disk

`.context/monitor-pr/<pr-number>/` (override with `STATE_DIR`):
- `seen_comments.txt` — newline-delimited ids across all 3 comment endpoints.
- `last_failures.txt` — failing check names from the last poll.
- `last_merge_state` — last `mergeStateStatus`.
- `last_pr_state` — last PR state (`OPEN` / `MERGED` / `CLOSED`).
- `last_sha` — last HEAD SHA.

Add `.context/` to `.gitignore`. This state persists across branch switches and sessions, so re-invoking `monitor-pr` on the same PR resumes rather than re-flooding. To force a re-flood (e.g. after a fresh checkout), delete the state dir before invoking.

## Stopping the monitor

- The user can interrupt at any time.
- `TaskStop <task-id>` cancels cleanly.
- A `state` event with `to=MERGED` or `to=CLOSED` usually means the caller should exit its own loop and stop the monitor.

## Limitations

The event set is fixed: comments × 3 endpoints, CI failures, BEHIND, PR state flip, SHA change. To watch anything else (specific merge-queue state, branch-protection changes, reaction additions), extend `monitor-pr.sh`. For the standard PR-watching loop (`implement-pr` / `review-pr --watch`), the fixed set is sufficient.
