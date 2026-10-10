# arming.sh - resolve, once, the two facts that must be fixed when a watch is
# ARMED rather than re-read on every poll.  Sourced by all four entry points;
# it is not executable on its own.  Requires SPANWEAVE_OPS_DIR.
#
# Both facts are read FROM THE WATCHED REPO, so `--repo` has to be in hand
# before arming runs - see `spanweave_export_repo`.
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
      # `shift 2` past the end fails and shifts nothing, which spins this
      # loop forever, so a flag given without a value is shifted one at a time.
      --base) [ -n "${2:-}" ] && export SPANWEAVE_BASE="$2"
              shift; [ $# -gt 0 ] && shift ;;
      *) shift ;;
    esac
  done
}

# `--repo` is pulled out of argv for the same reason, and more urgently: both
# of arming's values are read from the watched repo, and the transcript
# directory is derived from it too.  A `--repo` seen only later by
# `watch_run.sh` would leave a watch armed on the DEFAULT repo's branch and the
# default repo's builder processes while every poll reported on the given one -
# a report that is wrong in exactly the way this file exists to prevent.
# `watch_run.sh` and `status_check.sh` parse `--repo` themselves before arming.
spanweave_export_repo() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) [ -n "${2:-}" ] && export SPANWEAVE_REPO="$2"
              shift; [ $# -gt 0 ] && shift ;;
      *) shift ;;
    esac
  done
}

spanweave_arm() {
  local need_branch=0 need_pids=0 out scope_note
  [ -z "${SPANWEAVE_BRANCH:-}" ] && need_branch=1
  [ -z "${SPANWEAVE_PIDS+x}" ]   && need_pids=1
  if [ "$need_branch" -eq 0 ] && [ "$need_pids" -eq 0 ]; then
    # Nothing left to derive, but the base-time note below is about the base,
    # not about arming's two values, so it is still worth saying.
    spanweave_liveness_note
    return 0
  fi

  # `$$` is the shell running this file - the front end, or the shell that
  # sourced it - not the `$(...)` subshell below, so the tree is the watcher's.
  out="$(SPANWEAVE_ARM_SHELL="$$" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
import watch_lib

repo = watch_lib.repo_dir()
# The dispatching-builder case: when the repo's own cwd is nobody's project
# directory, the transcript is derived from another project's and the builder
# driving this run has its cwd THERE, not in the repo.  Arming is the only
# place the PID set is fixed, so it is the only place that can accept it - a
# set scoped to the repo alone would be empty here, and `builder gone` would be
# disarmed against a builder that is alive and orchestrating.  Asked of the
# derivation rather than guessed: `project_cwd` reads the directory out of the
# chosen transcript's own entries.
also = []
try:
    cfg = watch_lib.config()
    tdir_used, tname = watch_lib.derive_transcript_in(cfg)[:2]
    if tname and os.path.abspath(tdir_used) != os.path.abspath(cfg["tdir"]):
        cwd = watch_lib.project_cwd(tdir_used, tname)
        if cwd:
            also.append(cwd)
except Exception:                              # noqa: BLE001 - arming must not die
    also = []
# The watcher's own session is never a builder.  Armed from a Claude Code
# session (the Monitor path), the shell running this file descends from that
# session's `claude` process, which is builder-shaped whenever the session was
# started with --dangerously-skip-permissions - and in scope whenever its cwd is
# the repo.  Excluded before scoping, and counted, so the note can say so.
pg = watch_lib.claude_processes()
try:
    shell = int(os.environ.get("SPANWEAVE_ARM_SHELL") or 0)
except ValueError:
    shell = 0
tree = watch_lib.session_tree(shell)
own = sorted(p for p in watch_lib.builder_pids(pg) if p in tree)
armed, outside = watch_lib.pids_in_repo(pg, repo=repo, also=also, exclude=tree)
print(watch_lib.default_branch(repo))
print(" ".join(str(p) for p in armed))
# Line 3: how many arming excluded as the watcher's own session - said even
# when it is 0 whenever anything builder-shaped was seen, so a reader can tell
# "none of these was the watcher" from an arming that never looked.  With
# nothing builder-shaped running at all there is nothing to report, and arming
# stays silent as it always has.
if own or armed or outside:
    print("arming: excluded %d builder-shaped claude process(es) as this watcher's"
          " own session (the process tree of shell %d)%s."
            % (len(own), shell, (": " + " ".join(str(p) for p in own)) if own else ""))
# Line 4: the scope's rejections, so an empty armed set is never confused with
# "no builder is running".  Said once, at arming, because that is when the set
# is fixed - and because the usual cause is a second series under way in
# another repo, which an operator who sees the PIDs can recognise at a glance.
if outside:
    # The scope is named in full, because with `also` it is no longer just the
    # repo and a note that said "outside <repo>" would be false about what was
    # armed on.
    scope = repo + "".join(" or %s" % a for a in also)
    print("arming: %d builder-shaped claude process(es) are running outside %s"
          " and are not armed on (%s); 'builder gone' watches only the %d"
          " inside it."
          % (len(outside), scope, " ".join(str(p) for p in outside), len(armed)))
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
    # Only when this arming actually derived the set: a note about PIDs we did
    # not arm on makes no sense beside an operator's own `--pids`.
    scope_note="$(printf '%s\n' "$out" | sed -n '3,$p')"
    [ -n "$scope_note" ] && printf '%s\n' "$scope_note"
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
