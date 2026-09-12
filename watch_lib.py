"""watch_lib.py - shared read-only helpers for the spanweave watch tooling.

Imported by watch_run.sh's poll and by status_check.sh.  Both entry points get
their builder-transcript derivation and their WORKPLAN parsing from here, so
the two rules documented in WATCH.md have exactly one implementation.

Nothing in this module writes to the watched repo, opens a socket, or executes
trace/transcript content.
"""

import glob
import json
import os
import re
import subprocess
import time

# --------------------------------------------------------------------- config

DEF_REPO   = os.path.expanduser("~/git/spanweave")
DEF_TDIR   = os.path.expanduser("~/.claude/projects/-home-msi-git-spanweave")
DEF_PINNED = "28018437-a07a-443c-b854-7c4589983fc7.jsonl"
# Watcher/aux sessions that ran this tooling from inside the same project
# directory in the *past*.  A watcher must never derive onto itself, and a
# static list cannot know about the session it is running in, so this list is
# only the historical part of the answer - `self_names()` adds the live one.
DEF_SELF   = ("c2a395dd-9fdb-4c60-8878-b3c4e7a5a48d.jsonl "
              "05be40ff-b82d-4a92-bc3c-df42832b095c.jsonl")
DEF_BASE   = "c79cbc5"
DEF_BRANCH = "audit-fixes"
DEF_RUN    = "2"
DEF_PIDS   = "820503 820602 820711 820816"
DEF_BATCHES = "A5 A6 A7 A8 B3 A9 C3 D2 H2 G5 E2 E3 E4 F1 F2 G4"
# Memo-only batches: they end `awaiting decision` and must never touch
# spanweave/.  Per-run, so it is configurable (run 2: F1; run 3: R3).
DEF_MEMO   = "F1"

# Liveness must be still this long before a question or a limit notice is read
# as "waiting on user" rather than as a session mid-thought.  Shared with
# watch_run.sh so the watch and the one-shot report agree.
WAIT_QUIET_S = 10 * 60


def config():
    """Resolve configuration from the environment.  Callers set these; the
    shell front ends turn their flags into these variables."""
    return {
        "repo":    os.environ.get("SPANWEAVE_REPO", DEF_REPO),
        "tdir":    os.environ.get("SPANWEAVE_TDIR", DEF_TDIR),
        "pinned":  os.environ.get("SPANWEAVE_PINNED", DEF_PINNED),
        "self":    [n for n in os.environ.get("SPANWEAVE_SELF", DEF_SELF)
                    .replace(",", " ").split() if n],
        "base":    (os.environ.get("SPANWEAVE_BASE") or "").strip() or DEF_BASE,
        # Whether the operator actually named a base, as opposed to inheriting
        # `DEF_BASE` - which is a *previous* run's start and is wrong for every
        # run after it.  The tripwire needs the distinction: an operator-given
        # base outranks the baseline a previous run persisted, a defaulted one
        # must not (see `watch_run.sh`, TRIPWIRE).
        "base_explicit": bool((os.environ.get("SPANWEAVE_BASE") or "").strip()),
        "branch":  os.environ.get("SPANWEAVE_BRANCH", DEF_BRANCH),
        "run":     int(os.environ.get("SPANWEAVE_RUN", DEF_RUN)),
        "pids":    [int(x) for x in os.environ.get("SPANWEAVE_PIDS", DEF_PIDS)
                    .replace(",", " ").split()],
        "batches": os.environ.get("SPANWEAVE_BATCHES", DEF_BATCHES)
                   .replace(",", " ").split(),
        "memo":    os.environ.get("SPANWEAVE_MEMO", DEF_MEMO)
                   .replace(",", " ").split(),
    }


def self_names(cfg):
    """Transcript filenames this watcher must never derive onto.

    Two sources, because neither alone is right:

      * `SPANWEAVE_SELF` / `DEF_SELF` - watcher and aux sessions from earlier,
        which a live check cannot see because they are no longer running;
      * `CLAUDE_CODE_SESSION_ID` - *this* session, which no static list can
        contain, because the list is written before the session exists.

    The second is the one that matters in practice: a stale static list let a
    watcher derive onto its own transcript, and loosening the prompt rule (see
    `is_builder_prompt`) makes that more likely, not less - a watcher session
    is told about `WORKPLAN.md` and about the run number too.
    """
    names = set(cfg.get("self") or [])
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "").strip()
    if sid:
        names.add(sid + ".jsonl")
    return names


# -------------------------------------------------------------- tiny helpers

def mtime(path):
    try:
        return os.stat(path).st_mtime
    except OSError:
        return None


def newest_under(path):
    """Newest mtime of any file anywhere under `path` (liveness signal)."""
    best = None
    for root, _dirs, files in os.walk(path):
        for name in files:
            m = mtime(os.path.join(root, name))
            if m is not None and (best is None or m > best):
                best = m
    return best


def stamp(epoch):
    if epoch is None:
        return "n/a"
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(epoch))


def age(epoch, now):
    """Age in minutes, clamped at 0: a file can be written while the report is
    being produced, and a negative age reads as a bug rather than as freshness."""
    if epoch is None:
        return "n/a"
    return "%.1f min" % (max(0.0, now - epoch) / 60.0)


def git_in(repo):
    def git(*args, timeout=90):
        try:
            p = subprocess.run(["git", "-C", repo, *args],
                               capture_output=True, text=True, timeout=timeout)
            return p.returncode, p.stdout.rstrip("\n"), p.stderr.strip()
        except Exception as exc:              # noqa: BLE001 - a watcher must not die
            return 124, "", "%s: %s" % (type(exc).__name__, exc)
    return git


# ------------------------------------------------- rule (a): declared batches
#
# A commit "names a batch" only where the convention says a batch is declared:
#
#   * a body line of the form   Batch <ID> of WORKPLAN.md
#   * a subject of the form     plan: <ID> ...
#
# A batch id anywhere else in the prose is a citation, not a declaration.  The
# 477fe9b false positive was exactly that: batch A6's body opened with
# "Batch A6 of WORKPLAN.md." and then explained what A1 had left undone, and
# the old whole-blob `\b([A-H]\d)\b` scan read "A1" as a second declaration.

# Prefix-agnostic on purpose.  Run 2's batches were A-H; run 3's are R1-R7, and
# `[A-H]\d+` made every run-3 row, and every run-3 declaration, invisible to the
# whole watcher - rows read as "<row missing>", so "0/7 stopped, active: all
# seven" was a default, not an observation.  A batch id is a capital letter and
# digits; which letter is the plan's business, not the watcher's.
BATCH_ID = r"[A-Z]\d+"
DECL_BODY_RE = re.compile(r"^\s*Batch\s+(%s)\s+of\s+WORKPLAN\.md\b" % BATCH_ID,
                          re.I | re.M)
DECL_SUBJ_RE = re.compile(r"^\s*plan:\s*(%s)\b" % BATCH_ID, re.I)


def declared_batches(subject, body):
    """The batch ids a commit *declares*, in the two forms above.  Returns a
    sorted list; prose mentions are deliberately not included."""
    found = set(m.group(1).upper() for m in DECL_BODY_RE.finditer(body or ""))
    m = DECL_SUBJ_RE.match(subject or "")
    if m:
        found.add(m.group(1).upper())
    return sorted(found)


# ------------------------------------ rule (b): builder-transcript derivation
#
# Candidates are top-level *.jsonl in TDIR whose most recent "lastPrompt":
#
#   * is a builder prompt for run N (see `is_builder_prompt`), and
#   * names no run number other than N, and
#   * is not this session's transcript, nor a known past watcher/aux one.
#
# Among candidates: newest `<stem>/subagents/` directory mtime wins, then the
# transcript's own mtime.  With no candidate the configured pin is used - an
# operator override, so it is not re-tested against the run number.
#
# Under this rule the 95360def drift cannot recur: its lastPrompt names run 1,
# so it is excluded from a run-2 watch by rule 2 whatever its mtime.

LP_RE = re.compile(r'"lastPrompt"\s*:\s*"((?:[^"\\]|\\.)*)"')
# Two regexes, because naming a run and *being about* a run are different
# questions.
#
# RUNNUM_RE is the broad one: every way a run number can appear, including the
# hyphenated `run-2`.  It answers "which runs does this prompt mention at all",
# which is what rule 2 needs.
#
# RUN_TOKEN is the narrow one, and deliberately excludes `run-N`.  In this
# corpus the hyphenated form is always adjectival - a *citation* of an earlier
# run modifying a noun ("run-2 review findings", "run-1 concerns") - while the
# operative form is spaced or bare: "run 3", "run #3", and the `run3-...` of a
# handover filename, where the digit is attached to the word and the hyphen
# comes after it.  Without this split, "reopen for run 3 -- run-2 review
# findings" reads as a run-2 builder prompt as readily as a run-3 one, and a
# run-2 watch would follow run 3's builder.
RUNNUM_RE  = re.compile(r"\brun\s*[#_-]?\s*(\d+)", re.I)
RUN_TOKEN  = r"\brun\s*[#_]?\s*0*%d\b"
PLAN_RE    = re.compile(r"WORKPLAN\.md", re.I)
RESUME_RE  = re.compile(r"Resume\s+WORKPLAN\.md", re.I)

# The aux sessions - reviewers and watchers - talk about the plan and name the
# run, so once the prompt rule stopped demanding the literal `WORKPLAN.md run
# N` they became candidates too: a run-2 check derived onto "Cold review of run
# 2 of the spanweave audit series", an aux reviewer, over the builder.
#
# What separates them is not vocabulary but *position*.  An aux prompt says
# what it is in its opening words; a builder prompt says "Execute" or "Apply"
# and only later mentions, say, "run-2 review findings" - run 3's builder
# prompt contains the word "review", 150 characters in.  So this is matched
# against the head of the prompt only.
AUX_HEAD   = 80
AUX_RE     = re.compile(
    r"\breview(ing|ed|er|s)?\b|\bwatch(ing)?\b|\bre-?arm\b|\baudit\b|"
    r"\breport\s+only\b|\bchange\s+nothing\b|\bone-off\s+helper\b", re.I)


def is_aux_prompt(lp):
    """Does this prompt open by announcing itself as a reviewer or a watcher?"""
    return bool(AUX_RE.search((lp or "")[:AUX_HEAD]))


def run_token_re(run):
    return re.compile(RUN_TOKEN % int(run), re.I)


def is_builder_prompt(lp, run):
    """Is this lastPrompt a builder being told to work run N?

    The old rule demanded the literal phrase `WORKPLAN.md run N` (or
    `Resume WORKPLAN.md`).  Run 3's builder was started with

        Apply ~/Downloads/run3-2026-09-11.md with one plan-only sub-agent
        (recreate WORKPLAN.md from git show c79cbc5:...)

    which is unambiguously a run-3 builder and matched neither form, so the
    watch fell back to the pin - the *run-2* transcript - and read a finished
    session's liveness as though run 3 were alive.

    The rule is therefore split into its two real parts: the prompt must be
    about the plan, and it must name the run.  Either the two are adjacent
    (`WORKPLAN.md run 3`) or they are not (`run3-....md` ... `WORKPLAN.md`);
    the watcher has no business caring which.  `Resume WORKPLAN.md` still
    stands alone, because a resumed session need not restate the run.

    "Names the run" here means the operative form only - see RUN_TOKEN: a
    prompt that merely *cites* `run-2` while directing run 3 is a run-3 builder
    prompt and not a run-2 one.
    """
    if not lp:
        return False
    if is_aux_prompt(lp):
        return False
    if RESUME_RE.search(lp):
        return True
    return bool(PLAN_RE.search(lp)) and bool(run_token_re(run).search(lp))


def last_prompt(path):
    """The last "lastPrompt" value in a transcript.  Scanned line by line: a
    transcript can be tens of MB and is never slurped."""
    found = None
    try:
        with open(path, errors="replace") as fh:
            for line in fh:
                if '"lastPrompt"' in line:
                    m = LP_RE.search(line)
                    if m:
                        try:
                            found = json.loads('"%s"' % m.group(1))
                        except Exception:      # noqa: BLE001
                            found = m.group(1)
    except OSError:
        return None
    return found


def subagents_dir(tdir, name):
    return os.path.join(tdir, name[:-6], "subagents")


def derive_transcript(cfg):
    """-> (name, lastPrompt, candidates, how)

    candidates is a list of (sub_mtime, own_mtime, name, lastPrompt), best
    first.  `how` is "derived", "pin (no candidate)" or "none"."""
    run = cfg["run"]
    mine = self_names(cfg)
    cands, rejected = [], []
    for path in sorted(glob.glob(os.path.join(cfg["tdir"], "*.jsonl"))):
        name = os.path.basename(path)
        lp = last_prompt(path)
        if name in mine:
            # Only worth reporting when it would otherwise have been a
            # candidate; the directory holds dozens of unrelated sessions and
            # listing them all as "rejected" buries the ones that matter.
            if is_builder_prompt(lp, run):
                rejected.append((name, "this watcher's own session file"))
            continue
        if not lp:
            continue
        if not is_builder_prompt(lp, run):
            continue
        # Rule 2, and the same citation/declaration distinction as rule (a):
        # a run number the prompt *also* mentions is only disqualifying when
        # the prompt never names run N itself.  Run 3's builder was started
        # with "...single commit plan: reopen for run 3 -- run-2 review
        # findings", which names run 3 and cites run 2; the old "names no run
        # other than N" test threw it out for the citation.  A prompt that
        # names N is about N, whatever else it refers to.
        named = set(int(x) for x in RUNNUM_RE.findall(lp))
        other = sorted(named - {run})
        if other and run not in named:
            rejected.append((name, "lastPrompt names run %s, never run %d"
                             % (", ".join(str(x) for x in other), run)))
            continue
        cands.append((mtime(subagents_dir(cfg["tdir"], name)) or 0.0,
                      mtime(path) or 0.0, name, lp))
    cands.sort(key=lambda c: (c[0], c[1], c[2]), reverse=True)
    if cands:
        return cands[0][2], cands[0][3], cands, "derived", rejected
    pin = os.path.join(cfg["tdir"], cfg["pinned"])
    if os.path.exists(pin):
        return cfg["pinned"], last_prompt(pin), cands, "pin (no candidate)", rejected
    return None, None, cands, "none", rejected


# ------------------------------------------------------------ transcript tails

SKIP_TYPES = {"attachment", "queue-operation", "file-history-snapshot", "cost-state",
              "last-prompt", "custom-title", "agent-name", "mode", "permission-mode",
              "atis-latch", "bridge-session", "summary"}


def tail_entries(path, n=60, window=2_000_000):
    """Last n JSONL entries, read by seeking from the end so a large transcript
    is never pulled into memory whole."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            start = max(0, size - window)
            fh.seek(start)
            chunk = fh.read()
        if start > 0:                          # drop the partial first line
            nl = chunk.find(b"\n")
            chunk = chunk[nl + 1:] if nl >= 0 else b""
        lines = chunk.decode("utf-8", "replace").splitlines()
    except OSError:
        return []
    out = []
    for line in lines[-n:]:
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except Exception:                      # noqa: BLE001
            out.append({"type": "unparseable", "raw": line[:200]})
    return out


def render(entry, width=200):
    msg = entry.get("message") or {}
    content = msg.get("content")
    if isinstance(content, list):
        parts = []
        for b in content:
            t = b.get("type")
            if t == "text":
                parts.append(b.get("text", ""))
            elif t == "thinking":
                parts.append("[thinking] " + b.get("thinking", ""))
            elif t == "tool_use":
                parts.append("[tool_use %s] %s" % (b.get("name", ""),
                                                   json.dumps(b.get("input"))))
            elif t == "tool_result":
                c = b.get("content")
                parts.append("[tool_result] " +
                             (c if isinstance(c, str) else json.dumps(c)))
            else:
                parts.append("[%s]" % t)
        s = " | ".join(parts)
    elif isinstance(content, str):
        s = content
    else:
        s = json.dumps(entry)
    return s[:width].replace("\n", " ")


def entry_line(e):
    return "[%s] type=%s role=%s: %s" % (
        e.get("timestamp"), e.get("type"),
        (e.get("message") or {}).get("role"), render(e))


def substantive(entries):
    return [e for e in entries if e.get("type") not in SKIP_TYPES]


QUESTION_TOOLS = {"AskUserQuestion", "ExitPlanMode"}
LIMIT_RE = re.compile(
    r"usage limit|rate.?limit|quota exceeded|resets? at \d|"
    r"upgrade to increase|limit will reset", re.I)


def asks_question(entry):
    """-> (bool, why).  The last substantive assistant entry is a question if
    it used a question tool or its final line ends in a question mark."""
    if entry.get("type") != "assistant":
        return False, ""
    content = (entry.get("message") or {}).get("content")
    if not isinstance(content, list):
        return False, ""
    texts = []
    for b in content:
        if b.get("type") == "tool_use" and b.get("name") in QUESTION_TOOLS:
            return True, "tool_use %s" % b.get("name")
        if b.get("type") == "text":
            texts.append(b.get("text", ""))
    body = "\n".join(texts).strip()
    if not body:
        return False, ""
    tail = body[-400:]
    if "?" in tail.split("\n")[-1] or tail.rstrip().endswith("?"):
        return True, "trailing question mark"
    return False, ""


def limit_notice(entries, n=30):
    """-> (timestamp, matched text) for the most recent usage/rate-limit notice
    in the last n entries, else None."""
    hit = None
    for e in entries[-n:]:
        m = LIMIT_RE.search(json.dumps(e))
        if m:
            hit = (e.get("timestamp"), m.group(0))
    return hit


def pending_agents(entries):
    val = None
    for e in entries:
        if e.get("type") == "system":
            m = re.search(r'"pendingBackgroundAgentCount":\s*(\d+)', json.dumps(e))
            if m:
                val = int(m.group(1))
    return val


# ------------------------------------------------------------ WORKPLAN parsing

ROW_RE = re.compile(r"^\|\s*(%s)\s*\|" % BATCH_ID)


def _workplan_lines(repo):
    """The plan's lines and where they came from.

    G4 - the series-close batch - *removes* WORKPLAN.md, so "the file is not
    there" is a planned end state, not a failure.  Three sources, in order:

      "worktree"  the file on disk
      "HEAD"      the committed copy, while the deletion is staged but not
                  yet committed (the window this watcher died in)
      "absent"    gone from both: the plan is closed, so there are no rows
                  and nothing is active

    A present-but-unreadable file is retried twice before it counts as an
    error, because the builder rewrites it in place between batches.
    """
    path = os.path.join(repo, "WORKPLAN.md")
    for attempt in range(3):
        if not os.path.exists(path):
            break
        try:
            with open(path, errors="replace") as fh:
                return fh.read().splitlines(), "worktree"
        except OSError:
            if attempt == 2:
                return None, "unreadable"
            time.sleep(0.2)
    rc, out, _ = git_in(repo)("show", "HEAD:WORKPLAN.md")
    if rc == 0 and out.strip():
        return out.splitlines(), "HEAD"
    return [], "absent"


def workplan_statuses(repo):
    """-> (statuses, raw_rows, source).  `statuses` is None only when the file
    is there and cannot be read; an absent plan gives {} with source
    "absent"."""
    lines, source = _workplan_lines(repo)
    if lines is None:
        return None, None, source
    if source == "absent":
        return {}, {}, source
    start = None
    for i, line in enumerate(lines):
        if line.startswith("## 1."):
            start = i
            break
    if start is None:
        start = 0
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if lines[i].startswith("## ") and not lines[i].startswith("## 1."):
            end = i
            break
    out, raw = {}, {}
    for line in lines[start:end]:
        m = ROW_RE.match(line)
        if not m:
            continue
        fields = line.replace("\\|", "\x00").split("|")
        if len(fields) < 5:
            continue
        out[m.group(1)] = fields[-3].strip().replace("\x00", "|")
        raw[m.group(1)] = line
    return out, raw, source


def is_stopped(status):
    """Prefix-matched, all four words.  The plan does not write a bare `done`:
    it writes ``done (`0e4262e`)``, and the exact-match test on "done" and
    "dropped" read every completed run-3 batch as still active.  `awaiting` and
    `blocked` were already prefix-matched for exactly this reason - the three
    forms just never met a `done` with a sha on it until the rows became
    visible at all."""
    s = (status or "").strip().lower()
    return s.startswith(("done", "dropped", "awaiting", "blocked"))


def is_running(status):
    """A row that says work is happening *now*.  `todo` is not running, and a
    stopped status is not running; anything else the plan writes in that
    column - `in progress`, `running`, `dispatched` - is."""
    s = (status or "").strip().lower()
    if not s or s in ("todo", "-", "not started") or is_stopped(s):
        return False
    return True


# ------------------------------------------------------------------ verdict
#
# One line, one of exactly six values.  The point of a closed vocabulary is
# that the reader never has to interpret: `status_check.sh` used to print
# `ALIVE (liveness 5.7 min ago) | run 3: 0/7 batches stopped, active: <all
# seven>`, every word of which was true and which together said the opposite
# of the truth - the liveness was a `/clear` in a *finished* run-2 session, and
# the seven "active" batches were seven rows the parser could not see.

V_NOT_STARTED = "not started"
V_APPLYING    = "applying plan"
V_UNDERWAY    = "underway: batch %s"
V_WAITING     = "waiting on user"
V_FINISHED    = "finished"
V_UNCLEAR     = "unclear"


def verdict(statuses, source, batches, how, quiet_s, pushed,
            asks, limit_hit, declared_since_base):
    """-> (verdict line, one-line reason).

    Pure: every argument is evidence already gathered by the caller, so the
    rule is testable without a repo, a transcript or a clock.

      statuses            {batch id: status} from WORKPLAN.md section 1
      source              "worktree" | "HEAD" | "absent" | "unreadable"
      batches             the run's batch list, in order
      how                 "derived" | "pin (no candidate)" | "none"
      quiet_s             seconds since the newest liveness signal, or None
      pushed              HEAD == origin/<branch>
      asks / limit_hit    the two "waiting on user" signals
      declared_since_base batch ids of this run declared by a commit since base
    """
    if statuses is None or source == "unreadable":
        return V_UNCLEAR, "WORKPLAN.md is present but cannot be read"

    live = quiet_s is not None and quiet_s < WAIT_QUIET_S
    quiet = quiet_s is not None and quiet_s >= WAIT_QUIET_S

    # Blocked on a human outranks whatever the plan says: the run is not
    # advancing and no amount of batch bookkeeping changes that.
    if (asks or limit_hit) and quiet:
        return V_WAITING, ("the last assistant entry asks a question"
                           if asks else
                           "a usage/rate-limit notice is in the recent entries")

    if source == "absent":
        if pushed:
            return V_FINISHED, "WORKPLAN.md is gone and HEAD is pushed"
        return V_UNCLEAR, "WORKPLAN.md is gone but HEAD is not pushed"

    # A plan that is present but has no row for any batch of this run is not
    # describing this run.  Asking a run-2 question after run 3 recreated
    # WORKPLAN.md gave "0/16 stopped, active: <all sixteen>" - sixteen absent
    # rows defaulting to todo - and then "underway: batch A5" for a run that
    # finished a day earlier.  Absent rows are the absence of evidence.
    if not any(b in statuses for b in batches) and declared_since_base:
        return V_UNCLEAR, ("WORKPLAN.md has no row for any batch of this run, "
                           "yet %d of them are committed" % len(declared_since_base))

    active = [b for b in batches if not is_stopped(statuses.get(b, "todo"))]

    if not active:
        if pushed:
            return V_FINISHED, "every batch is stopped and HEAD is pushed"
        if live:
            return V_APPLYING, "every batch is stopped but HEAD is not pushed yet"
        return V_UNCLEAR, "every batch is stopped, HEAD is not pushed, nothing is live"

    running = [b for b in batches if is_running(statuses.get(b))]
    if running:
        return V_UNDERWAY % running[0], "its row says %r" % statuses[running[0]]
    if declared_since_base:
        return (V_UNDERWAY % active[0],
                "batch(es) %s already committed; %s is the first row still open"
                % (", ".join(declared_since_base), active[0]))

    # Nothing has moved on any batch.  The builder is either mid-setup or has
    # not been started at all, and the transcript is what tells them apart.
    if how == "derived" and live:
        return V_APPLYING, "a builder for this run is live, no batch declared yet"
    if how == "derived":
        return V_UNCLEAR, "a builder for this run exists but is quiet and has declared nothing"
    return V_NOT_STARTED, "no builder transcript for this run, and no batch declared"


def resume_note_tail(repo, n=12):
    lines, source = _workplan_lines(repo)
    if lines is None:
        return ["<WORKPLAN.md unreadable>"]
    if source == "absent":
        return ["<WORKPLAN.md removed - the series is closed>"]
    start = None
    for i, line in enumerate(lines):
        if line.startswith("## 4. Resume note"):
            start = i
            break
    if start is None:
        return ["<no resume note section>"]
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if lines[i].startswith("## ") or lines[i].strip() == "---":
            end = i
            break
    return lines[start:end][-n:]


def claude_processes():
    try:
        p = subprocess.run(["pgrep", "-af", "claude"], capture_output=True,
                           text=True, timeout=30)
        return p.stdout.rstrip("\n")
    except Exception as exc:                   # noqa: BLE001
        return "pgrep failed: %s" % exc


def live_pids(pgrep_out):
    out = set()
    for line in pgrep_out.splitlines():
        tok = line.split(None, 1)[0] if line.split() else ""
        if tok.isdigit():
            out.add(int(tok))
    return out
