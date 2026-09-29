#!/usr/bin/env bash
# watch_loop.sh - plain-terminal arming path: re-invoke watch_run.sh until a
# TERMINAL trigger fires, then stop.  Everything watch_run.sh prints - per-poll
# banners, non-terminal evidence blocks, RESUMED lines - goes straight to the
# terminal.  Exits with watch_run.sh's exit code.  See WATCH.md.
#
# usage: watch_loop.sh [--run N] [--batches "A5 A6 ..."] [--base SHA]
#                      [--branch NAME] [--pids "P P P"]
#
# --branch defaults to the repo's own checkout and --pids to the
# `claude --dangerous...` processes alive now, both resolved ONCE before the
# loop and exported - see arming.sh, and watch_monitor.sh for the same note.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SPANWEAVE_OPS_DIR="$HERE"

. "$HERE/arming.sh"
spanweave_arm

while :; do
  "$HERE/watch_run.sh" "$@"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "watch_loop: watch_run.sh exited $rc - stopping."
    exit "$rc"
  fi
done
