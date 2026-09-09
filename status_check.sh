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
    --base)    export SPANWEAVE_BASE="$2"; shift 2 ;;
    --branch)  export SPANWEAVE_BRANCH="$2"; shift 2 ;;
    --pids)    export SPANWEAVE_PIDS="$2"; shift 2 ;;
    --repo)    export SPANWEAVE_REPO="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "usage: $(basename "$0") --run N --batches \"A5 A6 ...\" [--base SHA] [--branch NAME] [--pids \"P P P\"] [--repo DIR]" >&2; exit 2 ;;
  esac
done

python3 - <<'PY'
import os, sys, time

sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import (age, claude_processes, config, derive_transcript,
                       entry_line, git_in, is_stopped, live_pids, mtime,
                       newest_under, pending_agents, resume_note_tail, stamp,
                       subagents_dir, tail_entries, workplan_statuses)

CFG     = config()
REPO    = CFG["repo"]
TDIR    = CFG["tdir"]
PINNED  = CFG["pinned"]
BASE    = CFG["base"]
BRANCH  = CFG["branch"]
RUN     = CFG["run"]
PIDSET  = CFG["pids"]
BATCHES = CFG["batches"]

now = time.time()
git = git_in(REPO)


def head(title):
    print()
    print("== %s " % title + "=" * max(0, 68 - len(title)))


# ------------------------------------------------------------------- repo ---
head("repo")
fetch_rc, _, fetch_err = git("fetch", "--quiet", "origin", BRANCH)
idx_m = mtime(os.path.join(REPO, ".git", "index"))
_, headsha, _     = git("rev-parse", "HEAD")
_, headshort, _   = git("rev-parse", "--short", "HEAD")
_, origin, _      = git("rev-parse", "origin/%s" % BRANCH)
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
print("branch          : %s (expected %s)" % (curbranch, BRANCH))
print("HEAD            : %s (%s)" % (headsha, headshort))
print("origin/%-8s: %s%s" % (BRANCH, origin,
                             "" if origin != basefull else "  == base, not pushed"))
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
statuses, _raw = workplan_statuses(REPO)
if statuses is None:
    print("WATCHER ERROR: WORKPLAN.md unreadable at %s" % REPO)
    sys.exit(2)
active = [b for b in BATCHES if not is_stopped(statuses.get(b))]
for b in BATCHES:
    print("  %-3s %s" % (b, statuses.get(b, "<row missing>")))
notes = [b for b in BATCHES
         if (statuses.get(b, "").strip().lower().startswith("awaiting")
             and not statuses.get(b, "").strip().lower().startswith("awaiting decision"))]
if notes:
    print("  note: stopped by a dependency marker, not a decision: %s"
          % ", ".join("%s (%s)" % (b, statuses[b]) for b in notes))
missing_rows = [b for b in BATCHES if b not in statuses]
if missing_rows:
    print("  note: no section-1 row yet for: %s" % ", ".join(missing_rows))
print()
print("  %d listed | %d stopped | %d active: %s"
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
print("PID set at arming: %s" % " ".join(str(p) for p in PIDSET))
print("present now      : %s" % (" ".join(str(p) for p in PIDSET if p in running) or "(none)"))
print("missing now      : %s" % (" ".join(str(p) for p in missing_pids) or "(none)"))
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
    sys.exit(2)
tpath = os.path.join(TDIR, tname)
sub   = subagents_dir(TDIR, tname)
t_m   = mtime(tpath)
s_m   = newest_under(sub) if os.path.isdir(sub) else None
live  = max([x for x in (t_m, s_m) if x is not None], default=None)
entries = tail_entries(tpath, 60)
pending = pending_agents(entries)

print("chosen     : %s  [%s]" % (tname, how))
print("pin        : %s%s" % (PINNED, "" if tname == PINNED else "   <-- FOLLOWED off the pin"))
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
quiet_min = (now - live) / 60.0 if live else None
if missing_pids:
    state = "BUILDER GONE (%d of %d arming PIDs missing)" % (len(missing_pids), len(PIDSET))
elif quiet_min is None:
    state = "UNKNOWN (no liveness signal)"
elif quiet_min >= 40:
    state = "QUIET %.1f min (>= stall threshold)" % quiet_min
elif quiet_min >= 10:
    state = "QUIET %.1f min (>= waiting threshold)" % quiet_min
else:
    state = "ALIVE (liveness %.1f min ago)" % quiet_min
pushed = "pushed" if origin and origin == headsha else "NOT pushed (origin %s)" % (origin[:7] if origin else "?")
print()
print("VERDICT: %s | run %d: %d/%d batches stopped, active: %s | HEAD %s %s | branch %s"
      % (state, RUN, len(BATCHES) - len(active), len(BATCHES),
         ", ".join(active) if active else "(none)", headshort, pushed, curbranch))
print()
print("TRANSCRIPT_DIR=%s" % TDIR)
print("TRANSCRIPT_FILE=%s" % tpath)
PY
