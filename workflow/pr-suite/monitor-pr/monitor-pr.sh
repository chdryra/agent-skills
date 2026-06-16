#!/usr/bin/env bash
# monitor-pr.sh — emit one stdout line per state change on a GitHub PR.
#
# Designed for use under the Monitor tool: each stdout line becomes a
# notification, and the script holds dedup state on disk so the model is
# only invoked on real events.
#
# Env vars:
#   PR              — PR number (required)
#   REPO            — owner/name (default: the current repo via `gh repo view`)
#   STATE_DIR       — where to keep seen-id + last-state files
#                     (default: $PWD/.context/monitor-pr/$PR)
#   POLL_SECS       — poll interval (default: 60)
#   HEARTBEAT_EVERY — emit a heartbeat event every N polls (default: 30,
#                     so ~30 min at the default poll interval). Lets the
#                     caller detect a silently-dead monitor: if heartbeats
#                     stop arriving, the script crashed and was not
#                     respawned by the inner supervisor loop.
#
# Event format (one per stdout line):
#   [HH:MM:SS] EVENT <type> <k=v>... [:: <body>]
# Types: inline, review, issue, ci_fail, behind, state, sha
#
# State on disk:
#   $STATE_DIR/seen_comments.txt   newline-delimited comment/review ids
#   $STATE_DIR/last_failures.txt   newline-delimited failing-check names (last poll)
#   $STATE_DIR/last_merge_state    most recent mergeStateStatus
#   $STATE_DIR/last_pr_state       most recent PR state (OPEN / CLOSED / MERGED)
#   $STATE_DIR/last_sha            most recent HEAD SHA
#
# Dedup is by seen-id only — do NOT filter by author. The authenticated user's
# login can coincide with a bot login, so an author filter would drop real
# human comments.

set -uo pipefail

: "${PR:?PR env var required}"
REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)}"
: "${REPO:?REPO env var required (could not auto-detect current repo)}"
STATE_DIR="${STATE_DIR:-$PWD/.context/monitor-pr/$PR}"
POLL_SECS="${POLL_SECS:-60}"
HEARTBEAT_EVERY="${HEARTBEAT_EVERY:-30}"

mkdir -p "$STATE_DIR"
SEEN="$STATE_DIR/seen_comments.txt"
LAST_FAILS="$STATE_DIR/last_failures.txt"
LAST_MERGE="$STATE_DIR/last_merge_state"
LAST_PR_STATE="$STATE_DIR/last_pr_state"
LAST_SHA_FILE="$STATE_DIR/last_sha"
touch "$SEEN" "$LAST_FAILS" "$LAST_MERGE" "$LAST_PR_STATE" "$LAST_SHA_FILE"

ts() { date '+%H:%M:%S'; }

# Seed seen-ids on first run so we don't flood with historical comments.
# IDs are stored as "<label>:<id>" because GitHub IDs are only unique within
# an endpoint — an inline-comment id can collide with a review id or an
# issue-comment id. Namespacing prevents one endpoint's seed from silently
# suppressing a real event from another.

# Format-migration guard: if the state file exists but uses an older un-namespaced
# format (no ":" in lines), discard it so the next block re-seeds with the current
# format. Without this, an upgrade would either re-flood every historical comment
# as "new" (lines fail to match namespaced grep) or silently miss legitimate new
# events (depending on which side of the format mismatch the grep falls on).
if [ -s "$SEEN" ] && ! head -1 "$SEEN" | grep -q ':'; then
  : > "$SEEN"
fi

if [ ! -s "$SEEN" ]; then
  {
    gh api "repos/$REPO/pulls/$PR/comments" --paginate -q '.[].id' 2>/dev/null | sed 's/^/inline:/'
    gh api "repos/$REPO/pulls/$PR/reviews"  --paginate -q '.[].id' 2>/dev/null | sed 's/^/review:/'
    gh api "repos/$REPO/issues/$PR/comments" --paginate -q '.[].id' 2>/dev/null | sed 's/^/issue:/'
  } > "$SEEN"
  echo "[$(ts)] EVENT armed pr=$PR repo=$REPO seeded_ids=$(wc -l < "$SEEN" | tr -d ' ')"
fi

# Seed last_sha so we only emit on actual changes after the first poll
if [ ! -s "$LAST_SHA_FILE" ]; then
  gh pr view "$PR" --repo "$REPO" --json headRefOid -q '.headRefOid' > "$LAST_SHA_FILE" 2>/dev/null
fi
# Same for last PR state
if [ ! -s "$LAST_PR_STATE" ]; then
  gh pr view "$PR" --repo "$REPO" --json state -q '.state' > "$LAST_PR_STATE" 2>/dev/null
fi

emit_new_comments() {
  local endpoint=$1 label=$2
  gh api "repos/$REPO/$endpoint" --paginate -q '.[] | @json' 2>/dev/null | while IFS= read -r line; do
    id=$(jq -r '.id' <<<"$line")
    [ -z "$id" ] || [ "$id" = "null" ] && continue
    # Namespace by label — GitHub IDs are only unique within an endpoint.
    seen_key="${label}:${id}"
    if ! grep -qx "$seen_key" "$SEEN"; then
      # Record the id even when we end up filtering the event out below,
      # so we don't re-evaluate it on every subsequent poll.
      echo "$seen_key" >> "$SEEN"

      author=$(jq -r '.user.login' <<<"$line")
      body_raw=$(jq -r '.body // ""' <<<"$line")
      body=$(jq -r '(.body // "") | gsub("[\\n\\r]+"; " ") | .[0:240]' <<<"$line")
      review_state=$(jq -r '(.state // "null")' <<<"$line")

      # Drop empty-body review wrappers. POSTing an inline reply to
      # /pulls/N/comments auto-creates a parent review with
      # state=COMMENTED and empty body — pure noise that fires one per
      # inline reply. During a reply burst (e.g. answering many bot
      # comments back-to-back) the volume is enough for the Monitor
      # runtime to auto-kill the task. Real reviewer submissions always
      # carry a body and survive this filter.
      if [ "$label" = "review" ] && [ -z "$body_raw" ] && [ "$review_state" = "COMMENTED" ]; then
        continue
      fi

      extra=""
      case "$label" in
        inline) extra=" path=$(jq -r '.path' <<<"$line") line=$(jq -r '(.line // "null")' <<<"$line") in_reply_to=$(jq -r '(.in_reply_to_id // "null")' <<<"$line")";;
        review) extra=" state=$review_state";;
      esac
      echo "[$(ts)] EVENT $label by=$author id=$id$extra :: $body"
    fi
  done
}

# Inner poll loop, run under the supervisor below. Returns (non-zero) if the
# loop body crashes for any reason; the supervisor will respawn it.
#
# All EVENT lines produced within a single poll cycle are accumulated into
# $buf and flushed via one printf at the end. The Monitor tool's stdout
# batching window then groups them into a single notification — without this,
# a burst (e.g. 7 inline replies posted at human-typing speed, all picked up
# in the same poll) emits N stdout lines spread over multiple seconds of jq
# subprocess work, each becoming a separate event. That volume can trip the
# Monitor runtime's anti-flood guard and silently kill the task.
poll_loop() {
  local poll_count=0
  while true; do
    poll_count=$((poll_count + 1))
    local buf=""

    # Comments — 3 endpoints. emit_new_comments echoes one line per new
    # event; capture into the buffer (and preserve the trailing newline only
    # when the function actually produced output).
    out=$(emit_new_comments "pulls/$PR/comments"  inline); [ -n "$out" ] && buf+="$out"$'\n'
    out=$(emit_new_comments "pulls/$PR/reviews"   review); [ -n "$out" ] && buf+="$out"$'\n'
    out=$(emit_new_comments "issues/$PR/comments" issue);  [ -n "$out" ] && buf+="$out"$'\n'

    # CI failures — emit on newly-failed check names (transitions into fail bucket).
    # gh pr checks --json supports: name, bucket, link, state.
    fails_now=$(gh pr checks "$PR" --repo "$REPO" --json name,bucket,link \
      -q '.[] | select(.bucket == "fail") | "\(.name)\t\(.link)"' 2>/dev/null | sort -u)
    fails_prev=$(cat "$LAST_FAILS")
    # Compare names only (col 1) for transition detection
    new_fails=$(comm -23 \
      <(printf '%s\n' "$fails_now"  | awk -F '\t' '{print $1}' | sort -u) \
      <(printf '%s\n' "$fails_prev" | awk -F '\t' '{print $1}' | sort -u))
    if [ -n "$new_fails" ]; then
      while IFS= read -r name; do
        [ -z "$name" ] && continue
        link=$(printf '%s\n' "$fails_now" | awk -F '\t' -v n="$name" '$1==n {print $2; exit}')
        buf+="[$(ts)] EVENT ci_fail check=$name link=$link"$'\n'
      done <<<"$new_fails"
    fi
    printf '%s\n' "$fails_now" > "$LAST_FAILS"

    # mergeStateStatus — emit when transitioning into BEHIND. Skip UNKNOWN
    # to avoid emitting a spurious duplicate `behind` event on the next poll
    # after a transient API failure (UNKNOWN would persist to disk, and on
    # recovery `merge_prev != BEHIND` would be true even if the PR was
    # already BEHIND).
    # Values: CLEAN, DIRTY, BEHIND, BLOCKED, HAS_HOOKS, UNKNOWN, UNSTABLE
    merge_now=$(gh pr view "$PR" --repo "$REPO" --json mergeStateStatus -q '.mergeStateStatus' 2>/dev/null || echo UNKNOWN)
    merge_prev=$(cat "$LAST_MERGE")
    if [ "$merge_now" = "BEHIND" ] && [ "$merge_prev" != "BEHIND" ]; then
      buf+="[$(ts)] EVENT behind merge_state=$merge_now"$'\n'
    fi
    if [ "$merge_now" != "UNKNOWN" ]; then
      printf '%s' "$merge_now" > "$LAST_MERGE"
    fi

    # PR state flips (OPEN → MERGED / CLOSED). Skip UNKNOWN to avoid spurious
    # events on transient API failures (and avoid persisting UNKNOWN, which would
    # emit a follow-up event when the API recovers).
    state_now=$(gh pr view "$PR" --repo "$REPO" --json state -q '.state' 2>/dev/null || echo UNKNOWN)
    state_prev=$(cat "$LAST_PR_STATE")
    if [ "$state_now" != "UNKNOWN" ] && [ "$state_now" != "$state_prev" ] && [ -n "$state_prev" ]; then
      buf+="[$(ts)] EVENT state from=$state_prev to=$state_now"$'\n'
    fi
    if [ "$state_now" != "UNKNOWN" ]; then
      printf '%s' "$state_now" > "$LAST_PR_STATE"
    fi

    # HEAD SHA changes — emit on new pushes (external pushes, automerge commits, our
    # own pushes). The caller is responsible for distinguishing automated bot merges
    # from human pushes by inspecting the commit chain — see implement-pr's `sha`
    # event handler. Full 40-char SHAs are emitted (not truncated) so the caller's
    # parent-walk loop can compare directly against the full SHAs returned by the
    # `gh api .../commits/<sha>` endpoint.
    sha_now=$(gh pr view "$PR" --repo "$REPO" --json headRefOid -q '.headRefOid' 2>/dev/null || echo UNKNOWN)
    sha_prev=$(cat "$LAST_SHA_FILE")
    if [ -n "$sha_now" ] && [ "$sha_now" != "UNKNOWN" ] && [ "$sha_now" != "$sha_prev" ] && [ -n "$sha_prev" ]; then
      buf+="[$(ts)] EVENT sha old=$sha_prev new=$sha_now"$'\n'
    fi
    if [ "$sha_now" != "UNKNOWN" ]; then
      printf '%s' "$sha_now" > "$LAST_SHA_FILE"
    fi

    # Heartbeat — periodic "still alive" event so the caller can detect a
    # silently-dead monitor. If heartbeats stop arriving at their expected
    # cadence, the script is gone.
    if [ $((poll_count % HEARTBEAT_EVERY)) -eq 0 ]; then
      buf+="[$(ts)] EVENT heartbeat polls=$poll_count merge=$merge_now state=$state_now"$'\n'
    fi

    # Single flush per poll cycle so the Monitor's batching window groups
    # every event from this poll into one notification.
    [ -n "$buf" ] && printf '%s' "$buf"

    sleep "$POLL_SECS"
  done
}

# Supervisor: respawn the inner poll loop if it ever exits. Defense in depth
# against bash crashes / unhandled errors. Note: this can't recover from the
# Monitor runtime itself killing the bash process — for that, the heartbeat
# event is the only signal.
while true; do
  poll_loop
  rc=$?
  echo "[$(ts)] EVENT restarted reason=poll_loop_exited code=$rc"
  sleep 5
done
