#!/usr/bin/env bash
# watch_loop.sh - plain-terminal arming path: re-invoke watch_run.sh until a
# TERMINAL trigger fires, then stop.  Everything watch_run.sh prints - per-poll
# banners, non-terminal evidence blocks, RESUMED lines - goes straight to the
# terminal.  Exits with watch_run.sh's exit code.  See WATCH.md.
#
# usage: watch_loop.sh [--run N] [--batches "A5 A6 ..."] [--base SHA]
#                      [--branch NAME] [--pids "P P P"]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while :; do
  "$HERE/watch_run.sh" "$@"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "watch_loop: watch_run.sh exited $rc - stopping."
    exit "$rc"
  fi
done
