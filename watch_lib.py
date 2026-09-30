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
# No pin.  `DEF_PINNED` used to name run 2's builder transcript, and a constant
# that names one session is a lie in every run after it: on 2026-09-30 a run-2
# check reported `<-- FOLLOWED off the pin` while the derivation had already
# found the right file on its own, which reads as drift rather than as the rule
# working.  The derivation (rule (b)) is the rule; a pin is now only what an
# operator passes when the derivation cannot see their session.
DEF_PINNED = ""
# Watcher/aux sessions that ran this tooling from inside the same project
# directory in the *past*.  A watcher must never derive onto itself, and a
# static list cannot know about the session it is running in, so this list is
# only the historical part of the answer - `self_names()` adds the live one.
DEF_SELF   = ("c2a395dd-9fdb-4c60-8878-b3c4e7a5a48d.jsonl "
              "05be40ff-b82d-4a92-bc3c-df42832b095c.jsonl")
DEF_BASE   = "c79cbc5"
# Branch and PID set are DERIVED, never assumed - see `default_branch` and
# `arming_pids`.  Both were constants until 2026-09-30 and both were stale by
# then: `audit-fixes` for a repo that had moved to `live-graphs`, so every
# `origin/...` comparison and the `git fetch` named a ref that no longer
# existed, and four PIDs whose processes had all exited, so `builder gone` was
# armed to fire on the first poll of any watch that used the default.
DEF_BRANCH = ""
DEF_RUN    = "2"
DEF_PIDS   = ""
DEF_BATCHES = "A5 A6 A7 A8 B3 A9 C3 D2 H2 G5 E2 E3 E4 F1 F2 G4"
# Memo-only batches: they end `awaiting decision` and must never touch
# spanweave/.  Per-run, so it is configurable (run 2: F1; run 3: R3).
DEF_MEMO   = "F1"

# Liveness must be still this long before a question or a limit notice is read
# as "waiting on user" rather than as a session mid-thought.  Shared with
# watch_run.sh so the watch and the one-shot report agree.
WAIT_QUIET_S = 10 * 60

# The stall window: nothing moving for this long, while a batch is in progress,
# is a stall.  It lives here rather than in watch_run.sh because the verdict
# rule uses it too - "a sub-agent file touched within the stall window" is what
# makes a batch *in flight* rather than merely started - and the two must not
# be allowed to drift apart.
STALL_QUIET_S = 40 * 60


def repo_dir():
    """The watched repo, resolved without the rest of the configuration.

    Separate from `config()` because the two derived defaults below need the
    repo path *before* a configuration exists - and `config()` derives the
    branch, so asking it for the repo in order to derive the branch would be
    circular."""
    return os.environ.get("SPANWEAVE_REPO", DEF_REPO)


def default_branch(repo):
    """The branch `repo` has checked out right now, or "" if it has none.

    This is a default, resolved at *arming* time by `arming.sh` and then held
    fixed for the life of the watch - not a per-poll reading.  The distinction
    is the whole point: the tripwire's "checked-out branch is not the one we
    are watching" condition is only a guard if the expected branch is a fact
    from arming time.  A branch re-read every poll would follow the builder
    onto any branch it checked out and report nothing.

    "" is returned for a detached HEAD or a path that is not a repo.  There is
    no honest fallback name - falling back to a constant is exactly the bug
    this replaces - so callers report the gap instead of papering over it."""
    rc, out, _ = git_in(repo)("symbolic-ref", "--short", "HEAD")
    return out.strip() if rc == 0 else ""


# A builder session is started with `--dangerously-skip-permissions`; the
# watcher and other aux sessions are not.  Matched as a prefix of the *command*
# rather than anywhere in the line, so the `pgrep` wrapper - a bash or python3
# process whose own command line quotes this pattern - can never match itself.
ARM_CMD_PREFIX = "claude --dangerous"


def arming_pids(pgrep_out=None):
    """The builder-shaped `claude` PIDs alive now, sorted.

    Resolved once when a watch is armed, never per poll: `builder gone` fires
    when this set *shrinks*, and a set re-derived each poll can never shrink.
    See `arming.sh`, which is the only thing that should call this."""
    out = claude_processes() if pgrep_out is None else pgrep_out
    pids = []
    for line in out.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[0].isdigit() \
                and parts[1].startswith(ARM_CMD_PREFIX):
            pids.append(int(parts[0]))
    return sorted(pids)


def config():
    """Resolve configuration from the environment.  Callers set these; the
    shell front ends turn their flags into these variables."""
    repo = repo_dir()
    # An operator-given branch outranks the checkout, and an empty value is
    # not a branch name, so it counts as "not given".  With nothing given the
    # branch is derived here too - so a direct `watch_lib` caller is not left
    # with a wrong constant - but the front ends resolve it once at arming and
    # export it, which is what keeps it fixed across polls.
    branch_env = (os.environ.get("SPANWEAVE_BRANCH") or "").strip()
    branch = branch_env or default_branch(repo)
    branch_src = (os.environ.get("SPANWEAVE_BRANCH_SRC") or "").strip()
    if branch_src not in ("given", "derived", "undetermined"):
        branch_src = ("given" if branch_env
                      else "derived" if branch else "undetermined")
    # Unset and empty differ for the PID set: unset means `arming.sh` has not
    # run yet, empty means it ran and there was nothing to arm on (or a caller
    # deliberately disarmed the trigger).  Only the front ends derive.
    pids_env = os.environ.get("SPANWEAVE_PIDS")
    return {
        "repo":    repo,
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
        "branch":  branch,
        # "given" | "derived" | "undetermined" - so a report can say where the
        # branch it compares against came from, and say so loudly when the
        # checkout has no branch at all and every `origin/...` answer is empty.
        # `arming.sh` states it, because it exports the branch it derived and
        # the environment alone cannot then tell the two apart.
        "branch_src": branch_src,
        "run":     int(os.environ.get("SPANWEAVE_RUN", DEF_RUN)),
        "pids":    [int(x) for x in (pids_env if pids_env is not None else DEF_PIDS)
                    .replace(",", " ").split()],
        "pids_src": "unarmed" if pids_env is None else "armed",
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
    # There is no default pin any more, so this branch is reached only when an
    # operator passed one.  With neither a candidate nor a pin the answer is
    # "no builder transcript for this run", which the callers report as a
    # watcher error rather than guessing at a file.
    if cfg["pinned"]:
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
# A qualified `underway`, not a seventh word: it still starts with `underway:
# batch `, which is what a caller matches on.  The parenthetical says which
# evidence carried it, because "in flight, uncommitted" is a weaker claim than
# a commit that declared the batch - nothing has landed yet.
V_UNDERWAY_INFLIGHT = "underway: batch %s (in flight, uncommitted)"
V_WAITING     = "waiting on user"
V_FINISHED    = "finished"
V_UNCLEAR     = "unclear"


def first_todo(statuses, batches):
    """The first batch in the run's own order that is neither stopped nor
    already running - i.e. the one a builder would pick up next.

    `batches` is the order the operator passed, which is WORKPLAN.md section
    2's *execution* order, not section 1's listing order; run 3's was
    `R1 R2 R4 R6 R5 R3 R7`.  So "first" here means first to be worked, which is
    the only sense in which naming one batch out of several is useful."""
    for b in batches:
        if not is_stopped(statuses.get(b, "todo")) and not is_running(statuses.get(b)):
            return b
    return None


def verdict(statuses, source, batches, how, quiet_s, pushed,
            asks, limit_hit, declared_since_base,
            head_past_base=True, pending=None, sub_quiet_s=None, dirty=False):
    """-> (verdict line, one-line reason).

    Pure: every argument is evidence already gathered by the caller, so the
    rule is testable without a repo, a transcript or a clock.

      statuses            {batch id: status} from WORKPLAN.md section 1
      source              "worktree" | "HEAD" | "absent" | "unreadable"
      batches             the run's batch list, in section 2's execution order
      how                 "derived" | "pin (no candidate)" | "none"
      quiet_s             seconds since the newest liveness signal, or None
      pushed              HEAD == origin/<branch>
      asks / limit_hit    the two "waiting on user" signals
      declared_since_base batch ids of this run declared by a commit since base
      head_past_base      HEAD has at least one commit since base - i.e. the
                          run's plan commit exists at all
      pending             last pendingBackgroundAgentCount seen, or None
      sub_quiet_s         seconds since the newest file under `subagents/`
      dirty               the working tree has uncommitted changes

    **Why the last four exist.** On 2026-09-30 a run-2 check reported `applying
    plan` while batch L3's sub-agent was three edits into `spanweave/ids.py`.
    Every clause was true - the plan commit was pushed, no commit had declared
    L3, its row still said `todo` - and the line as a whole said the run had
    not got going.  It had.  The builder marks a row `done` only *after* the
    batch lands, so between a run's first dispatch and its first commit there
    is a window in which the rows and the log are both silent and the only
    evidence is a live sub-agent and a dirty tree.  That window is `underway`,
    not `applying plan`; `applying plan` now means only what its name says -
    the run's plan commit is still being written or has not been pushed."""
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

    # (a) A commit since base declared one of this run's batches.  The strongest
    # evidence there is: something has landed.
    if declared_since_base:
        return (V_UNDERWAY % active[0],
                "batch(es) %s already committed; %s is the first row still open"
                % (", ".join(declared_since_base), active[0]))

    # (b) Nothing has landed and no row has moved, but the run's plan commit is
    # pushed and a builder sub-agent is working in a dirty tree.  That is a
    # batch in flight: the first one in the run's execution order, because the
    # builder works them in that order and nothing else is open.
    #
    # All three conjuncts are load-bearing, and each rules out a state that
    # would otherwise be misread:
    #   pushed      - an unpushed plan commit means the plan is still being
    #                 applied, which is `applying plan` and outranks this;
    #   sub_live    - a dirty tree on its own is any stray edit, or an
    #                 untracked scratch directory nobody has cleaned up;
    #   dirty       - a live sub-agent on its own may be a plan-only or
    #                 read-only helper that will never touch the tree.
    sub_live = (pending is not None and pending >= 1) or \
               (sub_quiet_s is not None and sub_quiet_s < STALL_QUIET_S)
    if pushed and head_past_base and sub_live and dirty:
        nxt = first_todo(statuses, batches) or active[0]
        return (V_UNDERWAY_INFLIGHT % nxt,
                "the plan commit is pushed and a builder sub-agent is live (%s) "
                "in a dirty tree; %s is the first todo batch in the run's order, "
                "and nothing has been committed for it yet"
                % ("pendingBackgroundAgentCount=%s" % pending
                   if pending is not None and pending >= 1
                   else "subagents/ touched %.0f min ago" % ((sub_quiet_s or 0) / 60.0),
                   nxt))

    # Nothing has moved on any batch and nothing is in flight.  `applying plan`
    # is now only what its name says - the run's plan commit is absent or not
    # pushed - and the transcript is what separates that from not started.
    if how == "derived" and live:
        if not head_past_base:
            return V_APPLYING, "a builder for this run is live and no plan commit exists yet"
        if not pushed:
            return V_APPLYING, "a builder for this run is live and the plan commit is not pushed yet"
        return (V_UNCLEAR,
                "the plan commit is pushed and a builder is live, but no batch is "
                "declared, no row has moved and nothing is in flight")
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


# -------------------------------------------------------------- CI on the tip
#
# WORKPLAN.md section 0.1 step 8 ends a run at "pushed AND CI green on the
# pushed tip", and says in as many words that a local `make check` is not a
# substitute.  `finished` used to fire on "origin moved, HEAD matches it, no
# batch open", which is the *push* half of that sentence only - so a run whose
# CI went red on the tip it had just pushed was reported as finished.
#
# Four answers, not two.  "gh could not tell us anything" must never be read as
# "CI is red", and it must never be read as "CI is green" either: both of those
# are claims about the build, and the only honest thing to say is that the
# claim is unverified.  And "gh answered, and has no run for this sha yet" is
# NOT that case - a workflow that has not been queued yet is pending, which is
# a fact about CI, so it is reported as pending and the watch keeps polling.
CI_TIMEOUT_S = 25
# Statuses that mean the run exists but has not concluded.  `gh` reports
# `queued`, `in_progress`, `waiting`, `requested` and `pending` here.
CI_OPEN_STATUS = {"queued", "in_progress", "waiting", "requested", "pending"}


def ci_conclusion(repo, branch, sha, timeout=CI_TIMEOUT_S):
    """What CI says about `sha`, as ("success"|"pending"|"failure"|"unavailable",
    why).  Read-only: one bounded `gh run list`, with a timeout, so a hanging
    or unauthenticated `gh` costs one poll rather than wedging the watch.  Any
    failure to *read* an answer is "unavailable", never "failure"."""
    if not sha:
        return "unavailable", "no tip sha to ask about"
    if not branch:
        return "unavailable", "no branch to ask about"
    cmd = ["gh", "run", "list", "--branch", branch, "--limit", "40",
           "--json", "headSha,status,conclusion"]
    try:
        p = subprocess.run(cmd, cwd=repo, capture_output=True, text=True,
                           timeout=timeout)
    except FileNotFoundError:
        return "unavailable", "gh is not on PATH"
    except subprocess.TimeoutExpired:
        return "unavailable", "gh did not answer within %ds" % timeout
    except Exception as exc:                   # noqa: BLE001 - never die here
        return "unavailable", "gh could not be run: %s: %s" % (type(exc).__name__, exc)
    if p.returncode != 0:
        first = (p.stderr or "").strip().splitlines()
        return "unavailable", ("gh exited %d: %s"
                               % (p.returncode, first[0][:160] if first else "(no stderr)"))
    raw = (p.stdout or "").strip()
    if not raw:
        return "unavailable", "gh exited 0 but printed nothing"
    try:
        runs = json.loads(raw)
    except Exception:                          # noqa: BLE001
        return "unavailable", "gh printed something that is not JSON"
    if not isinstance(runs, list):
        return "unavailable", "gh printed JSON that is not a list of runs"
    mine = [r for r in runs if isinstance(r, dict) and r.get("headSha") == sha]
    if not mine:
        return "pending", ("gh lists no workflow run for %s yet (%d run(s) on %s)"
                           % (sha[:7], len(runs), branch))
    unfinished = [r for r in mine
                  if not (r.get("conclusion") or "").strip()
                  or (r.get("status") or "").strip().lower() in CI_OPEN_STATUS]
    if unfinished:
        return "pending", ("%d of %d run(s) on %s have not concluded"
                           % (len(unfinished), len(mine), sha[:7]))
    concs = [(r.get("conclusion") or "").strip().lower() for r in mine]
    notgreen = sorted({c for c in concs if c != "success"})
    if notgreen:
        return "failure", ("%d run(s) on %s concluded %s"
                           % (len([c for c in concs if c != "success"]),
                              sha[:7], ", ".join(notgreen)))
    return "success", "%d run(s) on %s concluded success" % (len(concs), sha[:7])
