#!/usr/bin/env bash
# watch_run.sh - read-only watcher for a spanweave WORKPLAN.md builder session.
#
# Polls every POLL_SECONDS (default 300), runs at most BUDGET_SECONDS (default
# 540) per invocation.  Triggers are report-and-continue except the two
# terminal ones: `finished` and `builder gone` stop the watch and set the exit
# code; `tripwire`, `waiting on user` and `stall` print an evidence block,
# deduplicate themselves against state/watch_state.json, and keep polling.
# See WATCH.md for the per-trigger policy.
#
# Events are printed between the markers `>>> EVENT <kind>` and
# `<<< END EVENT`, or as a single `>>> LINE <text>`, so a front end can
# forward them without forwarding per-poll banners.
#
# Reads only: git log/status/stash list/fetch/diff --stat/show --stat/rev-parse,
# file mtimes, pgrep, transcript tails.  Never writes to the repo.  Never runs
# make, uv, or pytest.  Its only writes are under state/.
#
# usage: watch_run.sh [--once] [--run N] [--batches "A5 A6 ..."] [--memo "F1"]
#                     [--base SHA] [--branch NAME] [--pids "P P P"]
#
# Exit codes: 0 nothing terminal (non-terminal events may have been printed)
#             10 finished | 13 builder gone | 2 watcher error
# 11 waiting on user, 12 stall and 14 tripwire are printed events, not exits.

set -uo pipefail

OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SPANWEAVE_OPS_DIR="$OPS_DIR"
export SPANWEAVE_STATE_DIR="${SPANWEAVE_STATE_DIR:-$OPS_DIR/state}"
mkdir -p "$SPANWEAVE_STATE_DIR"

POLL_SECONDS="${POLL_SECONDS:-300}"
BUDGET_SECONDS="${BUDGET_SECONDS:-540}"

ONCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --once)    ONCE=1; shift ;;
    --run)     export SPANWEAVE_RUN="$2"; shift 2 ;;
    --batches) export SPANWEAVE_BATCHES="$2"; shift 2 ;;
    --memo)    export SPANWEAVE_MEMO="$2"; shift 2 ;;
    --base)    export SPANWEAVE_BASE="$2"; shift 2 ;;
    --branch)  export SPANWEAVE_BRANCH="$2"; shift 2 ;;
    --pids)    export SPANWEAVE_PIDS="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "usage: $(basename "$0") [--once] [--run N] [--batches \"A5 A6 ...\"] [--memo \"F1\"] [--base SHA] [--branch NAME] [--pids \"P P P\"]" >&2; exit 2 ;;
  esac
done

start=$(date +%s)

while :; do
  python3 - <<'PY'
import json, os, re, sys, time

sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import (WAIT_QUIET_S, age, asks_question, claude_processes,
                       config, declared_batches, derive_transcript, entry_line,
                       git_in, is_stopped, limit_notice, live_pids, mtime,
                       newest_under, pending_agents, render, resume_note_tail,
                       stamp, subagents_dir, substantive, tail_entries,
                       workplan_statuses)

CFG    = config()
REPO   = CFG["repo"]
TDIR   = CFG["tdir"]
PINNED = CFG["pinned"]
BASE   = CFG["base"]
BRANCH = CFG["branch"]
RUN    = CFG["run"]
PIDSET = CFG["pids"]
BATCHES = CFG["batches"]
MEMO   = set(CFG["memo"])          # memo-only batches for this run

STATE_DIR = os.environ["SPANWEAVE_STATE_DIR"]
STATE     = os.path.join(STATE_DIR, "watch_state.json")
EVIDENCE  = os.path.join(STATE_DIR, "last_evidence.txt")
LOG       = os.path.join(STATE_DIR, "poll.log")

STALL_QUIET_S = 40 * 60     # liveness must be still this long for "stall"
                            # (WAIT_QUIET_S, the 10 min for "waiting on user",
                            #  is shared with status_check.sh via watch_lib)

NONE, FINISHED, WAITING, STALL, GONE, TRIPWIRE, ERROR = 0, 10, 11, 12, 13, 14, 2
TERMINAL = {FINISHED, GONE, ERROR}

git = git_in(REPO)


def load_state():
    try:
        with open(STATE) as fh:
            return json.load(fh)
    except Exception:                             # noqa: BLE001
        return {}


def save_state(st):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(st, fh, indent=2, sort_keys=True)
    os.replace(tmp, STATE)


def movement(before, after):
    """Which of the four watched signals moved between two observations.
    Returns a list of human-readable phrases, empty if nothing moved."""
    moved = []
    if before.get("live") is not None and after.get("live") is not None \
            and after["live"] > before["live"] + 0.5:
        moved.append("liveness %s -> %s" % (stamp(before["live"]), stamp(after["live"])))
    if before.get("head") != after.get("head"):
        moved.append("HEAD %s -> %s" % ((before.get("head") or "?")[:7],
                                        (after.get("head") or "?")[:7]))
    if before.get("idx") is not None and after.get("idx") is not None \
            and after["idx"] > before["idx"] + 0.5:
        moved.append(".git/index touched %s" % stamp(after["idx"]))
    if before.get("commit") != after.get("commit") and after.get("commit"):
        moved.append("new commit at %s" % stamp(after["commit"]))
    return moved


# ------------------------------------------------------------------- the poll
def main():
    now = time.time()
    st = load_state()
    events = []           # (kind, code, text) - printed in order, none terminal
    code = NONE

    def event(kind, text):
        events.append((kind, text))

    # -- transcript ----------------------------------------------------------
    tname, tprompt, cands, how, _rejected = derive_transcript(CFG)
    if tname is None:
        event("watcher error",
              "WATCHER ERROR: no builder transcript found for run %d in %s" % (RUN, TDIR))
        return ERROR, events, st
    tpath = os.path.join(TDIR, tname)
    sub   = subagents_dir(TDIR, tname)
    t_m   = mtime(tpath)
    s_m   = newest_under(sub) if os.path.isdir(sub) else None
    live  = max([x for x in (t_m, s_m) if x is not None], default=None)
    entries = tail_entries(tpath, 60)
    pending = pending_agents(entries)
    followed = (tname != PINNED)

    # -- repo ----------------------------------------------------------------
    # Stat the index BEFORE running any git command: a plain `git status` can
    # rewrite .git/index while refreshing stat info, which would make the
    # watcher's own read look like builder activity.  (`--no-optional-locks`
    # below is the second half of that guard.)
    idx_m = mtime(os.path.join(REPO, ".git", "index"))
    fetch_rc, _, fetch_err = git("fetch", "--quiet", "origin", BRANCH)
    _, head, _        = git("rev-parse", "HEAD")
    _, headshort, _   = git("rev-parse", "--short", "HEAD")
    _, origin, _      = git("rev-parse", "origin/%s" % BRANCH)
    _, basefull, _    = git("rev-parse", BASE)
    _, curbranch, _   = git("branch", "--show-current")
    _, statusshort, _ = git("--no-optional-locks", "status", "--short")
    _, stashlist, _   = git("stash", "list")
    _, mainsha, _     = git("rev-parse", "refs/heads/main")
    _, lastcommit_ct, _ = git("log", "-1", "--format=%ct")
    try:
        last_commit_epoch = int(lastcommit_ct.strip())
    except Exception:                             # noqa: BLE001
        last_commit_epoch = None
    stash_count = len([x for x in stashlist.splitlines() if x.strip()])

    statuses, _rawrows, plan_src = workplan_statuses(REPO)
    if statuses is None:
        event("watcher error",
              "WATCHER ERROR: WORKPLAN.md is present but unreadable at %s" % REPO)
        return ERROR, events, st
    if plan_src == "absent":
        # G4's row is "Series close: ... remove WORKPLAN.md". A closed plan has
        # no rows, so nothing is active - that is the end state, not an error.
        active = []
    else:
        active = [b for b in BATCHES if not is_stopped(statuses.get(b))]

    # -- processes -----------------------------------------------------------
    pgrep_out = claude_processes()
    running = live_pids(pgrep_out)
    missing_pids = [p for p in PIDSET if p not in running]

    obs = {"live": live, "head": head, "idx": idx_m, "commit": last_commit_epoch}

    # -- per-poll banner -----------------------------------------------------
    suppressed = [k for k in ("waiting", "stall") if st.get(k)]
    banner = ("poll %s | run %d | watching %s%s | HEAD %s | origin %s | liveness %s (%s ago)"
              " | pendingBackgroundAgentCount=%s | active: %s%s"
              % (stamp(now), RUN, tname,
                 "  <-- FOLLOWED (pin was %s)" % PINNED if followed else "",
                 headshort, origin[:7] if origin else "?", stamp(live), age(live, now),
                 pending, ",".join(active) if active else "(none)",
                 ("%s%s" % (" | plan from %s" % plan_src if plan_src != "worktree" else "",
                            " | suppressed: %s" % ",".join(suppressed) if suppressed else ""))))
    print(banner, flush=True)
    try:
        with open(LOG, "a") as fh:
            fh.write(banner + "\n")
    except OSError:
        pass

    def status_block():
        if plan_src == "absent":
            return ("  WORKPLAN.md has been removed - the series is closed, so no\n"
                    "  batch row remains and nothing counts as active.")
        rows = ["  %-3s %s" % (b, statuses.get(b, "<row missing>")) for b in BATCHES]
        if plan_src != "worktree":
            rows.insert(0, "  (rows read from %s: the working-tree file is gone)" % plan_src)
        notes = [b for b in BATCHES
                 if (statuses.get(b, "").strip().lower().startswith("awaiting")
                     and not statuses.get(b, "").strip().lower().startswith("awaiting decision"))]
        if notes:
            rows.append("  note: stopped by a dependency marker, not a decision: %s"
                        % ", ".join("%s (%s)" % (b, statuses[b]) for b in notes))
        return "\n".join(rows)

    def transcript_block(n):
        return "\n".join(entry_line(e) for e in entries[-n:])

    def liveness_block():
        return ("  transcript mtime      : %s (%s ago)\n"
                "  subagents newest mtime: %s (%s ago)\n"
                "  liveness (newer of)   : %s (%s ago)\n"
                "  .git/index mtime      : %s (%s ago)\n"
                "  last local commit     : %s (%s ago)"
                % (stamp(t_m), age(t_m, now), stamp(s_m), age(s_m, now),
                   stamp(live), age(live, now), stamp(idx_m), age(idx_m, now),
                   stamp(last_commit_epoch), age(last_commit_epoch, now)))

    header = ("watching : %s (%s)\nlastPrompt: %s\nrepo     : %s (branch %s)\n"
              "HEAD     : %s\norigin/%s: %s\nbase     : %s (%s)"
              % (tpath, how, (tprompt or "")[:200], REPO, curbranch,
                 head, BRANCH, origin, BASE, basefull))

    def lines_to_text(lines):
        return "\n".join(lines)

    # -------------------------------------------------------------- RESUMED ---
    # A suppressed `waiting on user` or `stall` is lifted the moment any watched
    # signal moves again, and the lift is itself reported - one line, so the
    # human sees the pause end without re-reading an evidence block.
    for key in ("waiting", "stall"):
        rec = st.get(key)
        if not rec:
            continue
        moved = movement(rec, obs)
        if moved:
            event("resumed",
                  "RESUMED after %s (quiet %s): %s"
                  % (key if key != "waiting" else "waiting on user",
                     age(rec.get("live"), now), "; ".join(moved)))
            st.pop(key, None)

    # ------------------------------------------------------------- TRIPWIRE ---
    # Non-terminal.  Each commit is reported at most once, by sha; the
    # non-commit conditions are edge-triggered against the previous poll's
    # state, and the level-triggered one (wrong branch) is keyed too.
    reported = set(st.get("reported_commits") or [])
    conditions = dict(st.get("reported_conditions") or {})

    last_seen = st.get("last_seen_head") or basefull or BASE
    rc_range, newshas, _ = git("log", "--format=%H", "%s..HEAD" % last_seen)
    new_commits = [s for s in newshas.splitlines() if s.strip()] if rc_range == 0 else []
    new_commits.reverse()
    fresh = [s for s in new_commits if s not in reported]

    hits = []
    for sha in fresh:
        _, subj, _ = git("log", "-1", "--format=%s", sha)
        _, body, _ = git("log", "-1", "--format=%b", sha)
        _, files, _ = git("show", "--name-only", "--format=", sha)
        fl = [f for f in files.splitlines() if f.strip()]
        # Rule (a): only a declaration counts, never a prose citation.  Every
        # batch-id test below is built on it - including the memo rule, which
        # used to scan the whole subject+body for `\bF1\b`.  That was the same
        # mistake as the pre-477fe9b tripwire one paragraph later: a batch
        # commit that *cites* the memo ("F1 decided the envelope question")
        # while legitimately touching spanweave/ tripped it, and the memo rule
        # guards a halt point, so its false positives are the expensive kind.
        declared = declared_batches(subj, body)
        if any(f == "WORKPLAN.md" for f in fl) and not subj.startswith("plan:"):
            hits.append((sha, "touches WORKPLAN.md but subject does not start with 'plan:'"))
        memo_declared = [b for b in declared if b in MEMO]
        if any(f.startswith("spanweave/") for f in fl) and memo_declared:
            hits.append((sha, "touches spanweave/ while declaring memo-only batch(es) %s"
                              % ", ".join(memo_declared)))
        if any(f == "tests/serialized_shape.json" for f in fl) \
                and "serialized_shape" not in body:
            hits.append((sha, "touches tests/serialized_shape.json without mentioning "
                              "serialized_shape in the body"))
        outside = [b for b in declared if b not in BATCHES]
        if outside:
            hits.append((sha, "declares batch(es) outside the run-%d list: %s"
                              % (RUN, ", ".join(outside))))

    if curbranch and curbranch != BRANCH:
        ckey = "branch:%s" % curbranch
        if ckey not in conditions:
            hits.append(("-", "checked-out branch is %r, not %r" % (curbranch, BRANCH)))
            conditions[ckey] = True
    else:
        conditions = {k: v for k, v in conditions.items() if not k.startswith("branch:")}
    prev_main = st.get("main_sha")
    if mainsha and prev_main and mainsha != prev_main:
        hits.append(("-", "local main moved: %s -> %s" % (prev_main[:7], mainsha[:7])))
    prev_stash = st.get("stash_count")
    if prev_stash is not None and stash_count > prev_stash:
        hits.append(("-", "git stash list grew: %d -> %d" % (prev_stash, stash_count)))

    # Every commit examined this poll is now reported-or-cleared, either way it
    # must never be examined again.
    reported.update(fresh)
    st["reported_commits"] = sorted(reported)[-500:]
    st["reported_conditions"] = conditions
    st["last_seen_head"] = head or last_seen
    st["main_sha"] = mainsha
    st["stash_count"] = stash_count
    st["last_poll"] = now
    st["transcript"] = tname
    st["run"] = RUN

    if hits:
        L = []
        L.append("TRIGGER: tripwire  (reported, watch continues)")
        L.append(header)
        L.append("")
        L.append("Tripwire hits:")
        for sha, why in hits:
            L.append("  %s  %s" % (sha[:7] if sha != "-" else "-", why))
        L.append("")
        L.append("Commits reported for the first time this poll (%s..HEAD):" % last_seen[:7])
        for sha in fresh:
            _, shown, _ = git("show", "--stat", "--format=commit %H%nsubject: %s%nbody:%n%b", sha)
            L.append(shown)
            L.append("")
        L.append("git status --short:")
        L.append(statusshort or "  (clean)")
        L.append("git stash list:")
        L.append(stashlist or "  (empty)")
        L.append("current branch: %s | local main: %s" % (curbranch, mainsha))
        event("tripwire", lines_to_text(L))

    # ------------------------------------------------------------- FINISHED ---
    # Terminal.
    origin_moved = bool(origin) and bool(basefull) and origin != basefull
    if origin_moved and head == origin and not active:
        L = []
        L.append("TRIGGER: finished  (terminal, watch stops)")
        L.append(header)
        L.append("")
        L.append("git log --oneline %s..HEAD:" % BASE)
        _, log, _ = git("log", "--oneline", "%s..HEAD" % BASE)
        L.append(log or "  (empty)")
        L.append("")
        L.append("Run-%d batch statuses (WORKPLAN.md section 1):" % RUN)
        L.append(status_block())
        L.append("")
        L.append("Resume-note tail:")
        for line in resume_note_tail(REPO):
            L.append("  " + line)
        L.append("")
        L.append("git status --short:")
        L.append(statusshort or "  (clean)")
        event("finished", lines_to_text(L))
        return FINISHED, events, st

    # ------------------------------------------------------- WAITING ON USER ---
    # Non-terminal, reported once until liveness moves again.
    subs = substantive(entries)
    q, why = (asks_question(subs[-1]) if subs else (False, ""))
    limit_hit = limit_notice(entries)
    quiet = (now - live) if live else 0
    if (q or limit_hit) and quiet >= WAIT_QUIET_S and not st.get("waiting"):
        L = []
        L.append("TRIGGER: waiting on user  (reported once, watch continues)")
        L.append(header)
        L.append("")
        L.append("reason: %s" % ("assistant asks a question (%s)" % why if q
                                 else "usage/rate-limit notice in the last 30 entries: %r at %s"
                                      % (limit_hit[1], limit_hit[0])))
        if q and limit_hit:
            L.append("also: usage/rate-limit notice %r at %s" % (limit_hit[1], limit_hit[0]))
        L.append("liveness quiet for %s (threshold 10.0 min)" % age(live, now))
        L.append("")
        L.append(liveness_block())
        L.append("")
        L.append("Last 20 transcript entries:")
        L.append(transcript_block(20))
        L.append("")
        L.append("Batch statuses:")
        L.append(status_block())
        L.append("")
        L.append("Suppressed until liveness moves; a RESUMED line will say what moved.")
        event("waiting on user", lines_to_text(L))
        st["waiting"] = dict(obs, fired_at=now)

    # ---------------------------------------------------------- BUILDER GONE ---
    # Terminal.
    if missing_pids and active:
        L = []
        L.append("TRIGGER: builder gone  (terminal, watch stops)")
        L.append(header)
        L.append("")
        L.append("PID set from the status check: %s" % " ".join(str(p) for p in PIDSET))
        L.append("missing now                 : %s" % " ".join(str(p) for p in missing_pids))
        L.append("run %d incomplete, still active: %s" % (RUN, ", ".join(active)))
        L.append("")
        L.append("pgrep -af claude:")
        L.append(pgrep_out or "  (no matches)")
        L.append("")
        L.append("Last 10 transcript entries:")
        L.append(transcript_block(10))
        L.append("")
        L.append(liveness_block())
        event("builder gone", lines_to_text(L))
        return GONE, events, st

    # ----------------------------------------------------------------- STALL ---
    # Non-terminal.  Reported once; re-reported only after a further 40 minutes
    # in which nothing moved at all.
    batch_running = bool(active) or bool(pending)
    commit_quiet = (last_commit_epoch is None) or (now - last_commit_epoch >= STALL_QUIET_S)
    index_quiet  = (idx_m is None) or (now - idx_m >= STALL_QUIET_S)
    if batch_running and commit_quiet and index_quiet and quiet >= STALL_QUIET_S:
        prev = st.get("stall")
        repeat = bool(prev)
        due = (not prev) or (now - (prev.get("fired_at") or 0) >= STALL_QUIET_S)
        if due:
            L = []
            L.append("TRIGGER: stall%s  (reported, watch continues)"
                     % (" (still, %s since the last report)"
                        % age(prev.get("fired_at"), now) if repeat else ""))
            L.append(header)
            L.append("")
            L.append("No new commit, no .git/index change, no liveness movement for >= 40 min")
            L.append("while a batch is in progress.")
            L.append("")
            L.append(liveness_block())
            L.append("")
            L.append("pendingBackgroundAgentCount: %s" % pending)
            L.append("batches still active       : %s" % (", ".join(active) if active else "(none)"))
            L.append("")
            L.append("git status --short:")
            L.append(statusshort or "  (clean)")
            L.append("")
            L.append("Last 10 transcript entries:")
            L.append(transcript_block(10))
            L.append("")
            L.append("Suppressed for a further 40 min, or until liveness moves.")
            event("stall", lines_to_text(L))
            st["stall"] = dict(obs, fired_at=now)

    # -------------------------------------------------------------- no trigger --
    if fetch_rc != 0:
        print("  note: git fetch failed (%s) - 'finished' cannot fire this poll"
              % (fetch_err or fetch_rc), flush=True)
    return code, events, st


def emit(kind, text):
    """Print an event so a front end can forward it verbatim."""
    if "\n" in text:
        print(">>> EVENT %s" % kind, flush=True)
        print(text, flush=True)
        print("<<< END EVENT", flush=True)
    else:
        print(">>> LINE %s" % text, flush=True)


try:
    code, events, state = main()
except Exception as exc:                          # noqa: BLE001
    import traceback
    tb = traceback.format_exc()
    emit("watcher error", "WATCHER ERROR: %s\n%s" % (exc, tb))
    sys.exit(ERROR)

save_state(state)
for kind, text in events:
    emit(kind, text)
    if "\n" in text:
        try:
            with open(EVIDENCE, "w") as fh:
                fh.write(text + "\n")
        except OSError:
            pass
sys.exit(code)
PY
  rc=$?
  if [ "$rc" -ne 0 ]; then
    exit "$rc"
  fi
  if [ "$ONCE" -eq 1 ]; then
    exit 0
  fi
  now=$(date +%s)
  elapsed=$(( now - start ))
  if [ $(( elapsed + POLL_SECONDS )) -gt "$BUDGET_SECONDS" ]; then
    exit 0
  fi
  sleep "$POLL_SECONDS"
done
