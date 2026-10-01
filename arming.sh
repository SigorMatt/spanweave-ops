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

# Every flag is passed through to `watch_run.sh` untouched, with one exception:
# the two looping front ends pull `--base` out of their own argv and export it
# before they arm.  Arming's liveness note is about a base, and arming happens
# before `watch_run.sh` parses anything, so without this the note would be
# computed against DEF_BASE - a previous run's start.  `watch_run.sh` and
# `status_check.sh` parse `--base` themselves and do not need it.
spanweave_export_base() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) [ -n "${2:-}" ] && export SPANWEAVE_BASE="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
}

spanweave_arm() {
  local need_branch=0 need_pids=0 out
  [ -z "${SPANWEAVE_BRANCH:-}" ] && need_branch=1
  [ -z "${SPANWEAVE_PIDS+x}" ]   && need_pids=1
  if [ "$need_branch" -eq 0 ] && [ "$need_pids" -eq 0 ]; then
    # Nothing left to derive, but the base-time note below is about the base,
    # not about arming's two values, so it is still worth saying.
    spanweave_liveness_note
    return 0
  fi

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
  spanweave_liveness_note
}

# One line, printed only in the degraded state: no transcript in the directory
# was written at or after the base commit's author time, so there is no liveness
# to observe for this base and the stall rule runs on the commit and index times
# alone.  Said at arming because it is a fact about the base the watch was armed
# on, and because a reader who sees `liveness: unknown` in every banner deserves
# to have been told once why, up front.
#
# It asks the derivation the same question the polls ask (see
# `liveness_unknown_for_base`), so the note can never disagree with the banners
# that follow it.  It says nothing when a pin was given - a pin is an operator
# override and is not floor-tested - and nothing when the base cannot be
# resolved, because then there is no floor to report.
spanweave_liveness_note() {
  python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
import watch_lib

cfg = watch_lib.config()
# Only against a base an operator actually named.  `watch_monitor.sh` and
# `watch_loop.sh` arm before anything parses their flags, so without this the
# note would be computed against DEF_BASE - a previous run's start - and a note
# about the wrong base is worse than none.  They export SPANWEAVE_BASE from
# their own argv for exactly this reason; `watch_run.sh` and `status_check.sh`
# parse `--base` before they arm, so they always have it.
unknown, base_at, _rejected = (watch_lib.liveness_unknown_for_base(cfg)
                               if cfg["base_explicit"] else (False, None, []))
if unknown:
    print("arming: liveness is unknown for base %s (authored %s): every candidate"
          " transcript in %s was last written before it, so the stall rule runs on"
          " the commit and .git/index times alone. Pass SPANWEAVE_PINNED=<uuid>.jsonl"
          " to override."
          % (cfg["base"], watch_lib.stamp(base_at), cfg["tdir"]))
PY
}
