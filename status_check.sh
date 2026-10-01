#!/usr/bin/env bash
# status_check.sh - one-shot, read-only status of a spanweave WORKPLAN.md run.
#
# Prints the sections of the status query the watch series uses:
#   repo | plan statuses | resume-note tail | builder processes |
#   builder transcript | sub-agent activity | verdict | TRANSCRIPT_DIR/FILE
#
# usage: status_check.sh --run N --batches "A5 A6 ..." [--base SHA]
#                        [--branch NAME] [--pids "P P P"] [--repo DIR]
#
# --branch defaults to the repo's own checkout (`git symbolic-ref --short
# HEAD`) and --pids to the `claude --dangerous...` processes alive right now;
# neither is a constant any more.  See arming.sh.
#
# Reads only.  Writes nothing anywhere - not to the repo, not to state/.
# The one command that touches .git is `git fetch --quiet`, which updates the
# remote-tracking ref only; `git status` runs with --no-optional-locks so it
# cannot rewrite .git/index and fake builder activity for the watcher.
#
# Exit codes: 0 printed | 2 watcher error (no transcript, WORKPLAN unreadable,
#             unhandled exception) or bad usage.

set -uo pipefail

OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SPANWEAVE_OPS_DIR="$OPS_DIR"

while [ $# -gt 0 ]; do
  case "$1" in
    --run)     export SPANWEAVE_RUN="$2"; shift 2 ;;
    --batches) export SPANWEAVE_BATCHES="$2"; shift 2 ;;
    --memo)    export SPANWEAVE_MEMO="$2"; shift 2 ;;
    --base)    export SPANWEAVE_BASE="$2"; shift 2 ;;
    --branch)  export SPANWEAVE_BRANCH="$2"; shift 2 ;;
    --pids)    export SPANWEAVE_PIDS="$2"; shift 2 ;;
    --repo)    export SPANWEAVE_REPO="$2"; shift 2 ;;
    -h|--help) sed -n '2,21p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "usage: $(basename "$0") --run N --batches \"A5 A6 ...\" [--base SHA] [--branch NAME] [--pids \"P P P\"] [--repo DIR]" >&2; exit 2 ;;
  esac
done

# One-shot, so "armed once" and "armed now" are the same thing.
. "$OPS_DIR/arming.sh"
spanweave_arm

python3 - <<'PY'
import os, sys, time

sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import (ARM_CMD_PREFIX, HOW_FLOOR, age, asks_question, claude_processes,
                       config, declared_batches, derive_transcript, entry_line,
                       git_in, is_stopped, limit_notice, live_pids, mtime,
                       newest_under, pending_agents, resume_note_tail, stamp,
                       subagents_dir, substantive, tail_entries, verdict,
                       workplan_statuses)

CFG     = config()
REPO    = CFG["repo"]
TDIR    = CFG["tdir"]
PINNED  = CFG["pinned"]
BASE    = CFG["base"]
BRANCH  = CFG["branch"]
BRANCH_SRC = CFG["branch_src"]
RUN     = CFG["run"]
PIDSET  = CFG["pids"]
BATCHES = CFG["batches"]
MEMO    = CFG["memo"]

now = time.time()
git = git_in(REPO)


def head(title):
    print()
    print("== %s " % title + "=" * max(0, 68 - len(title)))


# ------------------------------------------------------------------- repo ---
head("repo")
# With no branch there is nothing to fetch and nothing to compare against;
# fetching "origin ''" would only produce a confusing failure note.
if BRANCH:
    fetch_rc, _, fetch_err = git("fetch", "--quiet", "origin", BRANCH)
else:
    fetch_rc, fetch_err = 0, ""
idx_m = mtime(os.path.join(REPO, ".git", "index"))
_, headsha, _     = git("rev-parse", "HEAD")
_, headshort, _   = git("rev-parse", "--short", "HEAD")
_, origin, _      = git("rev-parse", "origin/%s" % BRANCH) if BRANCH else (1, "", "")
_, basefull, _    = git("rev-parse", BASE)
_, curbranch, _   = git("branch", "--show-current")
_, statusshort, _ = git("--no-optional-locks", "status", "--short")
_, stashlist, _   = git("stash", "list")
_, mainsha, _     = git("rev-parse", "refs/heads/main")
_, lastct, _      = git("log", "-1", "--format=%ct")
try:
    last_commit_epoch = int(lastct.strip())
except Exception:                                   # noqa: BLE001
    last_commit_epoch = None

print("path            : %s" % REPO)
print("branch          : %s (watching %s, %s)"
      % (curbranch or "(detached)", BRANCH or "(none)", BRANCH_SRC))
print("HEAD            : %s (%s)" % (headsha, headshort))
if BRANCH:
    print("origin/%-8s: %s%s" % (BRANCH, origin,
                                 "" if origin != basefull else "  == base, not pushed"))
else:
    print("origin           : (no branch to compare against - the repo has a")
    print("                   detached HEAD and none was given with --branch)")
print("base            : %s (%s)" % (BASE, basefull))
print("local main      : %s" % mainsha)
print("last commit     : %s (%s ago)" % (stamp(last_commit_epoch),
                                         age(last_commit_epoch, now)))
print(".git/index mtime: %s (%s ago)" % (stamp(idx_m), age(idx_m, now)))
if fetch_rc != 0:
    print("note            : git fetch failed (%s); origin line may be stale"
          % (fetch_err or fetch_rc))
print()
print("git log --oneline %s..HEAD:" % BASE)
_, log, _ = git("log", "--oneline", "%s..HEAD" % BASE)
print(log or "  (empty)")
print()
print("git status --short:")
print(statusshort or "  (clean)")
print("git stash list:")
print(stashlist or "  (empty)")

# --------------------------------------------------------- plan statuses ---
head("plan statuses (WORKPLAN.md section 1, run %d)" % RUN)
statuses, _raw, plan_src = workplan_statuses(REPO)
if statuses is None:
    print("WATCHER ERROR: WORKPLAN.md is present but unreadable at %s" % REPO)
    sys.exit(2)
if plan_src == "absent":
    # G4 removes WORKPLAN.md on series close; a closed plan has no active batch.
    active = []
    print("  WORKPLAN.md has been removed - the series is closed, so no batch")
    print("  row remains and nothing counts as active.")
else:
    active = [b for b in BATCHES if not is_stopped(statuses.get(b))]
    if plan_src != "worktree":
        print("  (rows read from %s: the working-tree file is gone)" % plan_src)
    for b in BATCHES:
        print("  %-3s %s" % (b, statuses.get(b, "<row missing>")))
notes = [] if plan_src == "absent" else [b for b in BATCHES
         if (statuses.get(b, "").strip().lower().startswith("awaiting")
             and not statuses.get(b, "").strip().lower().startswith("awaiting decision"))]
if notes:
    print("  note: stopped by a dependency marker, not a decision: %s"
          % ", ".join("%s (%s)" % (b, statuses[b]) for b in notes))
missing_rows = [] if plan_src == "absent" else [b for b in BATCHES if b not in statuses]
if missing_rows:
    print("  note: no section-1 row yet for: %s" % ", ".join(missing_rows))
print()
print("  %d listed | %d stopped | %d open: %s"
      % (len(BATCHES), len(BATCHES) - len(active), len(active),
         ", ".join(active) if active else "(none)"))

# ------------------------------------------------------ resume-note tail ---
head("resume-note tail (WORKPLAN.md section 4)")
for line in resume_note_tail(REPO, 14):
    print("  " + line)

# ------------------------------------------------------ builder processes ---
head("builder processes")
pgrep_out = claude_processes()
running = live_pids(pgrep_out)
missing_pids = [p for p in PIDSET if p not in running]
print("PID set at arming: %s" % (" ".join(str(p) for p in PIDSET) or "(empty)"))
print("present now      : %s" % (" ".join(str(p) for p in PIDSET if p in running) or "(none)"))
print("missing now      : %s" % (" ".join(str(p) for p in missing_pids) or "(none)"))
if not PIDSET:
    print("note             : no builder-shaped process (%r) is running, so this"
          % ARM_CMD_PREFIX)
    print("                   set is empty and `builder gone` has no signal.")
print()
print("pgrep -af claude (claude processes only):")
shown = [l for l in pgrep_out.splitlines()
         if l.split(None, 1)[1:2] and l.split(None, 1)[1].startswith("claude")]
print("\n".join("  " + l for l in shown) or "  (no matches)")

# ------------------------------------------------------ builder transcript ---
head("builder transcript (derivation rule: run %d)" % RUN)
tname, tprompt, cands, how, rejected = derive_transcript(CFG)
if tname is None:
    print("WATCHER ERROR: no builder transcript found for run %d in %s" % (RUN, TDIR))
    if how == HOW_FLOOR:
        # Which of the two "no transcript" answers this is, said out loud: every
        # candidate was last written before the base commit, so liveness is
        # unknown for this base rather than merely unobserved.  `watch_run.sh`
        # degrades and keeps polling on this; a one-shot report has nothing to
        # poll, so it still exits 2 - but not without naming the reason.
        print("  Every candidate was refused by the base-time floor - no transcript")
        print("  in this directory was written after base %s. Liveness is unknown" % BASE)
        print("  for this base. Pass SPANWEAVE_PINNED=<uuid>.jsonl to override.")
        for name, why in rejected:
            print("  refused: %s  %s" % (name, why))
    sys.exit(2)
tpath = os.path.join(TDIR, tname)
sub   = subagents_dir(TDIR, tname)
t_m   = mtime(tpath)
s_m   = newest_under(sub) if os.path.isdir(sub) else None
live  = max([x for x in (t_m, s_m) if x is not None], default=None)
# The chosen transcript's tail, and only that one: `pendingBackgroundAgentCount`
# below is read from these entries, never from a union over the directory, so a
# count printed here is always this builder's.  See `pending_agents`.
entries = tail_entries(tpath, 60)
pending = pending_agents(entries)

print("chosen     : %s  [%s]" % (tname, how))
# Only an operator-given pin is worth a line.  There is no default pin: a
# constant naming one run's session made every later run report `<-- FOLLOWED
# off the pin`, which reads as drift when it is the derivation working.
if PINNED:
    print("pin        : %s%s"
          % (PINNED, "" if tname == PINNED else "   <-- FOLLOWED off the given pin"))
print("lastPrompt : %s" % (tprompt or "")[:200])
print("candidates : %d" % len(cands))
for sm, om, name, lp in cands:
    print("  %s  subagents/ %s  own %s  | %s"
          % (name, stamp(sm) if sm else "n/a", stamp(om), lp[:80]))
if rejected:
    print("rejected   :")
    for name, why in rejected:
        print("  %s  %s" % (name, why))
print()
print("  transcript mtime      : %s (%s ago)" % (stamp(t_m), age(t_m, now)))
print("  subagents newest mtime: %s (%s ago)" % (stamp(s_m), age(s_m, now)))
print("  liveness (newer of)   : %s (%s ago)" % (stamp(live), age(live, now)))
print("  pendingBackgroundAgentCount: %s" % pending)
print()
print("Last 10 transcript entries:")
for e in entries[-10:]:
    print("  " + entry_line(e))

# ------------------------------------------------------- sub-agent activity ---
head("sub-agent activity")
if not os.path.isdir(sub):
    print("  no subagents/ directory under %s" % os.path.join(TDIR, tname[:-6]))
else:
    files = []
    for root, _d, names in os.walk(sub):
        for n in names:
            p = os.path.join(root, n)
            files.append((mtime(p) or 0.0, os.path.relpath(p, sub)))
    files.sort(reverse=True)
    print("  %d file(s) under subagents/, newest first:" % len(files))
    for m, rel in files[:8]:
        print("    %s (%s ago)  %s" % (stamp(m), age(m, now), rel))
    if files:
        newest = os.path.join(sub, files[0][1])
        print()
        print("  last 6 entries of %s:" % files[0][1])
        for e in tail_entries(newest, 6):
            print("    " + entry_line(e))

# -------------------------------------------------------------- verdict ---
# One closed-vocabulary line, then the evidence it was derived from.  The
# vocabulary is documented in README.md; nothing else may appear on the
# VERDICT line, because a caller is meant to be able to match it exactly.
head("verdict")

# Which of this run's batches a commit since base actually declared.  This is
# what separates "not started" from "underway" when every row still says todo,
# and it uses rule (a), so a commit that merely *cites* a batch does not count.
_, shas, _ = git("log", "--format=%H", "%s..HEAD" % BASE)
declared_since_base = []
for sha in [x for x in shas.splitlines() if x.strip()]:
    _, dsubj, _ = git("log", "-1", "--format=%s", sha)
    _, dbody, _ = git("log", "-1", "--format=%b", sha)
    for b in declared_batches(dsubj, dbody):
        if b in BATCHES and b not in declared_since_base:
            declared_since_base.append(b)

subs = substantive(entries)
asks, asks_why = (asks_question(subs[-1]) if subs else (False, ""))
limit_hit = limit_notice(entries)
quiet_s = (now - live) if live else None
is_pushed = bool(origin) and origin == headsha
# The evidence for "a batch is in flight but nothing has landed": the run's
# plan commit exists, a sub-agent is working, and the tree is dirty.  Untracked
# paths count as uncommitted - a batch in progress routinely adds a new test
# file before it adds anything else.
head_past_base = bool([x for x in shas.splitlines() if x.strip()])
sub_quiet_s = (now - s_m) if s_m else None
dirty_paths = [x for x in statusshort.splitlines() if x.strip()]

v, why = verdict(statuses, plan_src, BATCHES, how, quiet_s, is_pushed,
                 asks, bool(limit_hit), declared_since_base,
                 head_past_base=head_past_base, pending=pending,
                 sub_quiet_s=sub_quiet_s, dirty=bool(dirty_paths))

if is_pushed:
    pushed_txt = "pushed"
elif origin:
    pushed_txt = "NOT pushed (origin %s)" % origin[:7]
else:
    # No remote-tracking ref read at all - an unknown push state, which is not
    # the same claim as "not pushed" and must not be printed as one.
    pushed_txt = "push state unknown (no origin/%s)" % (BRANCH or "<branch>")
print()
print("VERDICT: %s" % v)
print()
print("  why       : %s" % why)
print("  liveness  : %s (%s ago) | transcript %s [%s]"
      % (stamp(live), age(live, now), tname, how))
print("  batches   : run %d: %d/%d stopped, open: %s"
      % (RUN, len(BATCHES) - len(active), len(BATCHES),
         ", ".join(active) if active else "(none)"))
print("  declared  : %s" % (", ".join(declared_since_base) or "(none since %s)" % BASE))
print("  in flight : pendingBackgroundAgentCount=%s | subagents/ %s | tree %s"
      % (pending,
         ("%s ago" % age(s_m, now)) if s_m else "n/a",
         ("%d uncommitted path(s): %s" % (len(dirty_paths),
                                          " ".join(p.strip() for p in dirty_paths[:4])))
         if dirty_paths else "clean"))
print("  head      : %s %s | branch %s | plan rows from %s"
      % (headshort, pushed_txt, curbranch, plan_src))
if missing_pids:
    print("  processes : %d of %d arming PIDs missing: %s"
          % (len(missing_pids), len(PIDSET),
             " ".join(str(p) for p in missing_pids)))
if asks:
    print("  question  : %s" % asks_why)
if limit_hit:
    print("  limit     : %r at %s" % (limit_hit[1], limit_hit[0]))
print()
print("TRANSCRIPT_DIR=%s" % TDIR)
print("TRANSCRIPT_FILE=%s" % tpath)
PY
