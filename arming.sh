# arming.sh - resolve, once, the two facts that must be fixed when a watch is
# ARMED rather than re-read on every poll.  Sourced by all four entry points;
# it is not executable on its own.  Requires SPANWEAVE_OPS_DIR.
#
# Both were hard-coded constants until 2026-09-30, and a constant about a
# *session* is stale by the next run:
#
#   branch  `audit-fixes`, for a repo that had moved to `live-graphs`.  Every
#           `origin/...` comparison named a ref that does not exist, so `git
#           fetch` failed, `origin` read empty, and `pushed` - and with it the
#           `finished` trigger - was structurally unreachable while the report
#           still printed a confident "NOT pushed".
#   pids    four PIDs whose processes had all exited, so `builder gone` was
#           armed to fire on the first poll of any watch that used the default.
#
# Why once, and not per poll:
#
#   branch  the tripwire's "checked-out branch is not the one we are watching"
#           condition is only a guard if the expected branch is a fact from
#           arming time.  Re-derived each poll it would follow the builder onto
#           any branch and call it normal.
#   pids    `builder gone` fires when the set SHRINKS.  A set re-derived each
#           poll can never shrink.
#
# So `watch_monitor.sh` and `watch_loop.sh` - which re-invoke `watch_run.sh`
# every few minutes - arm at their own start and export, and `watch_run.sh`
# only arms when it was started directly.  `status_check.sh` is one-shot, so
# for it "once" and "now" are the same thing.
#
# Unset and empty are different for the PID set: unset means arming has not
# happened, empty means it happened and found nothing (or a caller disarmed
# the trigger on purpose).  An empty branch is treated as not-given, because
# there is no branch by that name.

spanweave_arm() {
  local need_branch=0 need_pids=0 out
  [ -z "${SPANWEAVE_BRANCH:-}" ] && need_branch=1
  [ -z "${SPANWEAVE_PIDS+x}" ]   && need_pids=1
  [ "$need_branch" -eq 0 ] && [ "$need_pids" -eq 0 ] && return 0

  out="$(python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
import watch_lib

print(watch_lib.default_branch(watch_lib.repo_dir()))
print(" ".join(str(p) for p in watch_lib.arming_pids()))
PY
)" || out=""

  if [ "$need_branch" -eq 1 ]; then
    SPANWEAVE_BRANCH="$(printf '%s\n' "$out" | sed -n 1p)"
    export SPANWEAVE_BRANCH
    # Say who resolved it.  Arming exports the branch, so without this marker
    # every downstream `config()` sees a branch in the environment and reports
    # it as `given` - i.e. as though the operator had named it - which is the
    # one thing a report about a derived default must not get wrong.
    if [ -n "$SPANWEAVE_BRANCH" ]; then
      export SPANWEAVE_BRANCH_SRC=derived
    else
      export SPANWEAVE_BRANCH_SRC=undetermined
    fi
  fi
  if [ "$need_pids" -eq 1 ]; then
    SPANWEAVE_PIDS="$(printf '%s\n' "$out" | sed -n 2p)"
    export SPANWEAVE_PIDS
  fi
}
