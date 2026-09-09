#!/usr/bin/env bash
# watch_monitor.sh - event-stream front end for watch_run.sh, for the Monitor tool.
#
# stdout is the event stream and is kept deliberately quiet: per-poll banners go
# to state/poll.log only.  A line reaches stdout in exactly these cases:
#
#   the body of a `>>> EVENT <kind>` ... `<<< END EVENT` block, or a
#   `>>> LINE <text>` one-liner, emitted by watch_run.sh - that is every
#   trigger, terminal or not, and every RESUMED line
#   WATCHER   - watch_run.sh exited 2 (its own error)
#   TERMINAL  - watch_run.sh exited on `finished` (10) or `builder gone` (13);
#               the evidence block has already streamed above it, then exit
#   HEARTBEAT - one line roughly hourly, so a silent death is distinguishable
#               from a quiet builder
#
# Non-terminal triggers (tripwire 14, waiting on user 11, stall 12) stream their
# evidence and the loop keeps going; watch_run.sh deduplicates them.  See WATCH.md.
#
# usage: watch_monitor.sh [--run N] [--batches "A5 A6 ..."] [--base SHA]
#                         [--branch NAME] [--pids "P P P"]

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${SPANWEAVE_STATE_DIR:-$HERE/state}"
mkdir -p "$STATE"
HEARTBEAT_EVERY="${HEARTBEAT_EVERY:-6}"    # invocations (~9 min each) between heartbeats

n=0
while :; do
  # Everything watch_run.sh prints is appended to poll.log; only event blocks
  # are echoed to this script's stdout.
  "$HERE/watch_run.sh" "$@" 2>&1 | awk -v logf="$STATE/poll.log" '
    { print >> logf; fflush(logf) }
    /^>>> EVENT /  { inblk = 1; print substr($0, 11) ":"; fflush(); next }
    /^<<< END EVENT$/ { inblk = 0; print ""; fflush(); next }
    /^>>> LINE /   { print substr($0, 10); fflush(); next }
    inblk          { print; fflush() }
  '
  rc="${PIPESTATUS[0]}"
  case "$rc" in
    0)  ;;
    2)  echo "WATCHER exit=2; last poll.log lines:"; tail -20 "$STATE/poll.log"; exit 2 ;;
    10) echo "TERMINAL exit=10 (finished)"; exit 10 ;;
    13) echo "TERMINAL exit=13 (builder gone)"; exit 13 ;;
    *)  echo "WATCHER unexpected exit=$rc; last poll.log lines:"
        tail -20 "$STATE/poll.log"; exit "$rc" ;;
  esac
  n=$(( n + 1 ))
  if [ $(( n % HEARTBEAT_EVERY )) -eq 0 ]; then
    echo "HEARTBEAT $(tail -1 "$STATE/poll.log")"
  fi
done
