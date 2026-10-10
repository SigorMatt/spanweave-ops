#!/usr/bin/env bash
# watch_monitor.sh - event-stream front end for watch_run.sh, for the Monitor tool.
#
# stdout is the event stream and is kept deliberately quiet: per-poll banners go
# to state/poll.log only - written there by watch_run.sh, which is the log's one
# writer, so this script never appends to it.  A line reaches stdout in exactly
# these cases:
#
#   the body of a `>>> EVENT <kind>` ... `<<< END EVENT` block, or a
#   `>>> LINE <text>` one-liner, emitted by watch_run.sh - that is every
#   trigger, terminal or not, and every RESUMED line
#   WATCHER   - watch_run.sh exited 2 (its own error)
#   TERMINAL  - watch_run.sh exited on `finished` (10, including the
#               `(series closed)` and `(CI unverified)` forms),
#               `finished: CI red on the tip` (15) or `builder gone` (13); the
#               evidence block has already streamed above it, then exit
#   HEARTBEAT - one line roughly hourly, so a silent death is distinguishable
#               from a quiet builder
#
# Non-terminal triggers (tripwire 14, waiting on user 11, stall 12) stream their
# evidence and the loop keeps going; watch_run.sh deduplicates them.  See WATCH.md.
#
# usage: watch_monitor.sh [--run N] [--batches "A5 A6 ..."] [--base SHA]
#                         [--branch NAME] [--pids "P P P"] [--repo DIR]
#
# --repo is the watched repo (default ~/git/spanweave); --branch defaults to
# its checkout, --pids to the `claude --dangerous...` processes whose working
# directory is inside it, and the transcript directory to Claude Code's project
# directory for that path.  The first two are resolved ONCE here, before the
# loop, and exported to every `watch_run.sh` invocation: this script re-invokes
# the watcher every few minutes, and re-deriving either per invocation would
# quietly disarm the branch tripwire and `builder gone`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SPANWEAVE_OPS_DIR="$HERE"
STATE="${SPANWEAVE_STATE_DIR:-$HERE/state}"
mkdir -p "$STATE"

. "$HERE/arming.sh"
# The repo out of argv, because arming reads the branch and the PID set FROM
# the watched repo, and the base out of argv, so arming's liveness note is
# about the base this watch is actually armed on: arming runs before
# `watch_run.sh` ever sees these flags.
spanweave_export_repo "$@"
spanweave_export_base "$@"
spanweave_arm
HEARTBEAT_EVERY="${HEARTBEAT_EVERY:-6}"    # invocations (~9 min each) between heartbeats

n=0
while :; do
  # Only event blocks are echoed to this script's stdout.  poll.log is not
  # written here: watch_run.sh already appends every banner and every event to
  # it, and teeing its output in as well put each banner in the log twice.  The
  # invocation's full output - stderr included, which watch_run.sh never logs -
  # is kept in last_invocation.txt, overwritten each time, for the error tails.
  : > "$STATE/last_invocation.txt"
  "$HERE/watch_run.sh" "$@" 2>&1 | awk -v outf="$STATE/last_invocation.txt" '
    { print >> outf; fflush(outf) }
    /^>>> EVENT /  { inblk = 1; print substr($0, 11) ":"; fflush(); next }
    /^<<< END EVENT$/ { inblk = 0; print ""; fflush(); next }
    /^>>> LINE /   { print substr($0, 10); fflush(); next }
    inblk          { print; fflush() }
  '
  rc="${PIPESTATUS[0]}"
  case "$rc" in
    0)  ;;
    2)  echo "WATCHER exit=2; last lines of its output:"
        tail -20 "$STATE/last_invocation.txt"; exit 2 ;;
    # Which `finished` it was - plain, series closed, CI unverified - is on
    # the event line that has already streamed above this one, so this says
    # the code and does not re-guess the kind.
    10) echo "TERMINAL exit=10 (a finished form - see the event above)"; exit 10 ;;
    15) echo "TERMINAL exit=15 (finished: CI red on the pushed tip)"; exit 15 ;;
    13) echo "TERMINAL exit=13 (builder gone)"; exit 13 ;;
    *)  echo "WATCHER unexpected exit=$rc; last lines of its output:"
        tail -20 "$STATE/last_invocation.txt"; exit "$rc" ;;
  esac
  n=$(( n + 1 ))
  if [ $(( n % HEARTBEAT_EVERY )) -eq 0 ]; then
    echo "HEARTBEAT $(tail -1 "$STATE/poll.log")"
  fi
done
