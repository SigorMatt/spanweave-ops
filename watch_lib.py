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
# The transcript directory is DERIVED from the watched repo - see
# `default_tdir`.  It was a constant naming spanweave's project directory, and
# a constant about one repo is wrong for every other: `--repo ~/git/spanweave-live`
# would have been watched for its branch and its commits while the transcript,
# the liveness timestamp and the sub-agent activity all came from a different
# project's sessions, and nothing in the banner would have said so.
DEF_PROJECTS = os.path.expanduser("~/.claude/projects")
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


def default_tdir(repo, projects=None):
    """Claude Code's transcript directory for sessions started in `repo`.

    Claude Code names a project directory after the absolute path of the
    directory the session was started in, with every character that is not a
    letter or a digit replaced by `-`; so `/home/msi/git/spanweave` becomes
    `-home-msi-git-spanweave`.  Derived rather than configured, so that naming
    the repo names the transcripts too: a watch pointed at one repo and reading
    another repo's sessions would report a stranger's liveness as the builder's.

    `SPANWEAVE_TDIR` still outranks this - the encoding is Claude Code's, not
    ours, and an operator who knows better must be able to say so."""
    enc = re.sub(r"[^A-Za-z0-9]", "-", os.path.abspath(os.path.expanduser(repo)))
    return os.path.join(projects or DEF_PROJECTS, enc)


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


def pid_cwd(pid):
    """The working directory of `pid`, or None if it cannot be read.

    None is "we could not look" - the process exited between the `pgrep` and
    this call, or it belongs to another user - and is deliberately not "" : the
    scope below refuses an unreadable cwd rather than assuming either answer."""
    try:
        return os.path.realpath(os.readlink("/proc/%d/cwd" % pid))
    except OSError:
        return None


def pids_in_repo(pgrep_out=None, repo=None, cwd_of=pid_cwd):
    """-> (armed, outside): the builder-shaped `claude` PIDs whose working
    directory is inside `repo`, and the builder-shaped ones that are not.

    The command shape alone is not enough once the repo is a parameter.  Two
    series can be under way on this machine at the same time - and on
    2026-10-04 two were, `~/git/spanweave` and `~/git/spanweave-live` - so a
    set armed on "every `claude --dangerous...` alive" would arm each watch on
    the other watch's builder: `builder gone` would then fire on a stranger
    finishing, and would stay silent when the builder this watch is about died
    while the stranger lived.  A builder's cwd is the directory its session was
    started in, which is the repo (or a path inside it).

    With no `repo` there is no scope to apply and every builder-shaped PID is
    armed on - that is the pre-repo behaviour, kept for a direct caller.  A PID
    whose cwd cannot be read is reported as outside, never armed on: "not known
    to be this repo's" is the honest reading, and the caller says so out loud
    rather than quietly arming a trigger on a process it could not identify."""
    out = claude_processes() if pgrep_out is None else pgrep_out
    root = os.path.realpath(os.path.abspath(os.path.expanduser(repo))) if repo else None
    armed, outside = [], []
    for line in out.splitlines():
        parts = line.split(None, 1)
        if len(parts) != 2 or not parts[0].isdigit() \
                or not parts[1].startswith(ARM_CMD_PREFIX):
            continue
        pid = int(parts[0])
        if root is None:
            armed.append(pid)
            continue
        cwd = cwd_of(pid)
        if cwd is not None and (cwd == root or cwd.startswith(root + os.sep)):
            armed.append(pid)
        else:
            outside.append(pid)
    return sorted(armed), sorted(outside)


def arming_pids(pgrep_out=None, repo=None, cwd_of=pid_cwd):
    """The builder-shaped `claude` PIDs of `repo` alive now, sorted.

    Resolved once when a watch is armed, never per poll: `builder gone` fires
    when this set *shrinks*, and a set re-derived each poll can never shrink.
    See `arming.sh`, which is the only thing that should call this."""
    return pids_in_repo(pgrep_out, repo, cwd_of)[0]


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
        # Derived from the repo unless an operator names it: see `default_tdir`.
        # An empty value is not a directory, so it counts as not given.
        "tdir":    (os.environ.get("SPANWEAVE_TDIR") or "").strip()
                   or default_tdir(repo),
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
#   * is not this session's transcript, nor a known past watcher/aux one,
#   * and whose LAST WRITE is not earlier than the base commit's author time
#     (the floor - see `derive_transcript`; run numbers are per-series, so a
#     prompt test alone cannot tell September's run 3 from October's).
#
# Among candidates: newest `<stem>/subagents/` directory mtime wins, then the
# transcript's own mtime.  With no candidate the configured pin is used - an
# operator override, so it is re-tested against neither the run number nor the
# floor.
#
# Under this rule the 95360def drift cannot recur: its lastPrompt names run 1,
# so it is excluded from a run-2 watch by rule 2 whatever its mtime.  Nor can
# the 351ac45a drift: it is a run-3 builder prompt, and the floor refuses it
# anyway because it was last written twenty days before the base commit.

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


# The stored `lastPrompt` is capped at about 200 characters, with a trailing
# "…" where it was cut.  That cap is half of why the 2026-10-01 drift below
# happened, so a prompt that is *about* the plan but names no operative run N
# while sitting at the cap is reported as a near miss rather than dropped in
# silence: the phrase that names the run may lie beyond the cut, and it did.
TRUNC_LEN = 200


def truncated_prompt(lp):
    """Is this stored lastPrompt cut off at the cap?"""
    lp = lp or ""
    return lp.rstrip().endswith("…") or len(lp) >= TRUNC_LEN


def base_author_time(repo, base):
    """The base commit's AUTHOR time as an epoch, or None if it cannot be read.

    Author time, not committer time: a rebase, an amend or a cherry-pick
    rewrites the committer time to *now*, which would drag the floor forward
    over work the run already contains and disqualify the live builder.  The
    author time is when the base was written, which is the thing the floor is
    actually asking about.

    None when the base is empty, unresolvable, or the path is not a repo - and
    then there is no floor at all.  A watch cannot invent a bound it could not
    read.
    """
    if not base:
        return None
    rc, out, _ = git_in(repo)("log", "-1", "--format=%at", base)
    if rc != 0:
        return None
    try:
        return int(out.strip().splitlines()[0])
    except Exception:                          # noqa: BLE001
        return None


def last_write(tdir, name):
    """-> (last_write, own_mtime, subagents_dir_mtime) for one transcript.

    "Last write" is the **newer of** the transcript's own mtime and its
    `<stem>/subagents/` directory mtime.  Of the readings available this is the
    conservative one - the one least likely to exclude a *live* builder: a
    builder's own file can sit unflushed for minutes while a batch sub-agent
    runs, and the directory mtime moves when that sub-agent's file is created.
    Taking the own mtime alone would refuse a working builder; taking the newer
    of the two cannot.

    The directory's own mtime is used, not the recursive `newest_under` that
    *liveness* uses, so this matches the derivation tiebreak exactly - the same
    two numbers that order the candidates are the two that bound them.
    """
    own = mtime(os.path.join(tdir, name))
    sub = mtime(subagents_dir(tdir, name))
    return max(own or 0.0, sub or 0.0), own, sub


# `how` values `derive_transcript` returns.  HOW_FLOOR is not an error: it says
# every transcript this run could have derived onto was last written before the
# base commit, so the builder's session is not visible from here *yet*.  The
# callers degrade to "liveness unknown" on it rather than exiting.
HOW_DERIVED = "derived"
HOW_PIN     = "pin (no candidate)"
HOW_NONE    = "none"
HOW_FLOOR   = "none (older than base)"
# The floor read forwards instead of backwards.  A run number is a fact about
# *some* run; a date is a fact about *this* one (see the 2026-10-01 note in
# `derive_transcript`).  So where no prompt names run N - because the stored
# `lastPrompt` is capped at ~200 characters and the run number lay beyond the
# cut, or because the builder rolled from the previous run's last prompt
# straight into this one - but exactly one transcript is about `WORKPLAN.md`,
# is not an aux prompt, and was written *since the base commit*, that one is
# the builder's, and it says on every banner which evidence carried it.  It
# begins with `derived`, because that is what it is, and a caller matching the
# derivations matches on that word.
HOW_FLOOR_DERIVED = "derived by floor, not by run number"
# ... and two of them is not an answer.  The floor can say "since this run
# started"; it cannot pick between two sessions that both were.  Guessing here
# is the 2026-10-01 drift with a new cause, so this is the watcher error it
# looks like, with both files named so the operator can pin one.
HOW_AMBIGUOUS = "none (two or more clear the floor)"


def liveness_unknown_for_base(cfg):
    """-> (unknown, base_at, rejected) - what `arming.sh` says once, up front.

    `unknown` is True exactly when the derivation ends in HOW_FLOOR: candidates
    existed for this run and the floor refused every one of them, and no pin
    overrode it.  It asks the derivation rather than approximating it with a
    cheaper stat sweep, because a note that disagreed with the banners it
    precedes would be worse than no note: "newest transcript in the directory"
    is not the same question as "newest *candidate* for this run", and the
    directory is full of aux sessions that are newer than any base.  One extra
    derivation per *arming* - not per poll - is what that costs.
    """
    _name, _lp, _cands, how, rejected = derive_transcript(cfg)
    return how == HOW_FLOOR, base_author_time(cfg["repo"], cfg["base"]), rejected


def derive_transcript(cfg):
    """-> (name, lastPrompt, candidates, how, rejected)

    candidates is a list of (sub_mtime, own_mtime, name, lastPrompt), best
    first.  `how` is one of HOW_DERIVED, HOW_PIN, HOW_FLOOR or HOW_NONE."""
    run = cfg["run"]
    mine = self_names(cfg)
    # The base-time floor.  A transcript whose last write predates the base
    # commit's author time cannot be the builder's for this run: the run had
    # not started when that session last wrote.  It is applied below to every
    # candidate, before any ordering, and whatever its lastPrompt says.
    #
    # Why it exists, 2026-10-01: a run-3 watch of the `live-graphs` series
    # derived onto `351ac45a-...jsonl`, own mtime 2026-09-11 00:37 and
    # `subagents/` 2026-09-10 17:09 - twenty days before the run it was
    # watching - and reported that dead session's liveness, then `finished`,
    # against a base (`ce9ff17`) authored 2026-10-01 00:23:40.  Two independent
    # causes met:
    #
    #   * RUN NUMBERS ARE PER-SERIES.  351ac45a is the *September audit
    #     series'* run 3 ("Apply ~/Downloads/run3-2026-09-11.md ... single
    #     commit plan: reopen for run 3 -- run-2 review findings"), so every
    #     prompt predicate says yes: not aux in its first 80 characters, names
    #     WORKPLAN.md, names run 3 operatively, spared by rule 2 because it
    #     names run 3 itself.  Nothing in the derivation knows about series or
    #     about recency, and a run number alone cannot tell two series apart.
    #   * THE STORED `lastPrompt` IS TRUNCATED at ~200 characters.  The real
    #     run-3 builder (`1d41a6d1-...jsonl`, own mtime 2026-10-01 15:49,
    #     `subagents/` 2026-10-01 01:20) stored "In ~/git/spanweave on
    #     live-graphs (tip 2cde61f), read WORKPLAN.md §0 in full. Apply
    #     patches/decisions-live-2026-09-30.md exactly as its header says: one
    #     plan-only sub-agent, one commit plan: run-2 rev…" - the only run
    #     number inside the cut is 2, so `run_token_re(3)` is False and it is
    #     not a candidate.  The phrase that named run 3 lay beyond the cut.
    #
    # So the wrong transcript was the *only* candidate and won outright; the
    # (subagents mtime, own mtime) ordering never got a chance to prefer the
    # newer session.  The floor is what the ordering could not do: a date is a
    # fact about this run, where a run number is only a fact about some run.
    base_at = base_author_time(cfg["repo"], cfg["base"])
    cands, rejected, floored = [], [], False
    # The fallback pool: every transcript that is about the plan, does not
    # announce itself as an aux session, and was last written since the base
    # commit - whatever run number it names or fails to name.  Collected on
    # this same pass, so the fallback costs no second sweep of the directory.
    floor_clear = []
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
        # Every candidate is plan-shaped - `is_builder_prompt` requires a
        # non-aux prompt that matches PLAN_RE on both its branches - so one
        # `last_write` here serves the candidate test, the floor and the pool.
        plan_shaped = (not is_aux_prompt(lp)) and bool(PLAN_RE.search(lp))
        lw = own_m = sub_m = None
        clears_floor = False
        if plan_shaped:
            lw, own_m, sub_m = last_write(cfg["tdir"], name)
            clears_floor = (base_at is None) or (lw >= base_at)
            # The pool needs the floor to have actually *said* something.  With
            # no readable base author time the floor refuses nothing, so
            # "clears the floor" would mean "exists" - no warrant at all, and
            # certainly not one to derive a session the run number disowns.
            # The fallback is then simply unavailable, which is the answer the
            # watcher gave before it existed.
            if clears_floor and base_at is not None:
                floor_clear.append((sub_m or 0.0, own_m or 0.0, name, lp))
        if not is_builder_prompt(lp, run):
            # One near miss is worth printing: a prompt about the plan, not an
            # aux one, naming no operative run N - and cut off at the stored
            # cap, so the run number may be in the part that was not kept.
            # That is exactly how the real run-3 builder was passed over on
            # 2026-10-01 (see the note above), and it is a different rejection
            # from the floor's, so the two are distinguishable in this list.
            # Prompts that are short enough to be whole are not listed: they
            # really do not name the run, and the directory holds dozens.
            if plan_shaped and truncated_prompt(lp):
                named = sorted(set(int(x) for x in RUNNUM_RE.findall(lp)))
                rejected.append(
                    (name, "lastPrompt is about WORKPLAN.md but names no operative "
                           "run %d (%s); it is %d chars, truncated at the stored cap, "
                           "so a later 'run %d' would not be stored"
                     % (run, "names run %s" % ", ".join(str(x) for x in named)
                        if named else "names no run at all", len(lp), run)))
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
        if not clears_floor:
            # The floor.  Reported, not dropped: this is the near miss, and a
            # reader has to be able to see which file nearly won and by how
            # many days it missed.
            floored = True
            rejected.append(
                (name, "last write %s (own %s, subagents/ %s) predates the base "
                       "commit's author time %s - the run had not started"
                 % (stamp(lw), stamp(own_m), stamp(sub_m), stamp(base_at))))
            continue
        cands.append((sub_m or 0.0, own_m or 0.0, name, lp))
    # The ordering is unchanged, and is the implementation of "among surviving
    # candidates, the newest write wins": `subagents/` mtime first, then the
    # transcript's own mtime, then the name.  A `subagents/` directory is only
    # written by a builder that is *orchestrating* - it is the stronger signal
    # of the two, so it is read first rather than averaged with the other.
    #
    # The two readings diverge in exactly one case: a candidate with a newer
    # own mtime and NO `subagents/` directory loses to one with a newer
    # `subagents/` directory and an older own mtime.  That outcome is the
    # preferred one - the orchestrating session is the builder, and its own file
    # goes quiet for minutes at a time precisely while its sub-agent works, so
    # "newest own mtime" would hand the watch to a session that typed one line.
    # `selftest.sh` pins it ("a newer transcript still loses to a newer
    # subagents/ dir").  Both candidates have already cleared the floor, so
    # neither can be a previous series' session.
    cands.sort(key=lambda c: (c[0], c[1], c[2]), reverse=True)
    if cands:
        return cands[0][2], cands[0][3], cands, HOW_DERIVED, rejected
    # There is no default pin any more, so this branch is reached only when an
    # operator passed one.  The pin is an operator override and is NOT re-tested
    # against the floor, exactly as it is already not re-tested against the run
    # number: an operator who names a file has said something the watcher's
    # evidence cannot outvote.
    if cfg["pinned"]:
        pin = os.path.join(cfg["tdir"], cfg["pinned"])
        if os.path.exists(pin):
            return cfg["pinned"], last_prompt(pin), cands, HOW_PIN, rejected
    # No prompt named run N.  Read the floor forwards: among the transcripts
    # that are about the plan, are not aux prompts and were written since the
    # base commit, exactly one is an answer and two are not.
    #
    # Why this is not the run-number rule giving up.  On 2026-10-02 run 5 of
    # the live-graphs series had landed L23, pushed it, and was mid-L24 with a
    # sub-agent live, and no transcript in the directory named run 5: the
    # builder was the session that had been told to apply the *run-4* review
    # decisions, had made the base commit itself, and rolled straight on into
    # run 5 without a new prompt.  Its stored `lastPrompt` names run 4 and is
    # cut at the 200-character cap, so no later "run 5" could be stored
    # either.  Both entry points answered "no builder transcript found for run
    # 5" and exited 2, about a run whose builder was alive, pinned by nothing,
    # and the only session in the directory written since the base.
    #
    # The floor is the evidence that makes that safe to act on.  A run number
    # is a fact about some run; "written since this run's base commit" is a
    # fact about this one, and it is the same fact the floor already trusts in
    # the other direction when it refuses a twenty-day-old candidate.
    floor_clear.sort(key=lambda c: (c[0], c[1], c[2]), reverse=True)
    if len(floor_clear) == 1:
        sub_m, own_m, name, lp = floor_clear[0]
        # It is chosen, so it must not also be listed as refused: it appears in
        # `rejected` from the near-miss branch above, which is now the wrong
        # thing to say about it.
        rejected = [r for r in rejected if r[0] != name]
        return name, lp, list(floor_clear), HOW_FLOOR_DERIVED, rejected
    if len(floor_clear) > 1:
        for _sm, _om, name, lp in floor_clear:
            rejected = [r for r in rejected if r[0] != name]
            rejected.append(
                (name, "names no operative run %d, but is about WORKPLAN.md, is "
                       "not an aux prompt and was written since the base - and so "
                       "are %d others, so the floor cannot pick between them: "
                       "name one with SPANWEAVE_PINNED=<uuid>.jsonl"
                 % (run, len(floor_clear) - 1)))
        return None, None, list(floor_clear), HOW_AMBIGUOUS, rejected
    # No candidate and no pin.  The two ways of getting here are different
    # answers and must not be reported as the same one: HOW_FLOOR means
    # candidates existed and the floor refused them all, so liveness is unknown
    # for this base and the watch degrades honestly; HOW_NONE means nothing in
    # the directory was ever a candidate, which is the watcher error it always
    # was.
    return None, None, cands, (HOW_FLOOR if floored else HOW_NONE), rejected


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
    """The last `pendingBackgroundAgentCount` in a `system` entry of `entries`.

    ONE transcript's entries, always: both callers pass `tail_entries` of the
    transcript the derivation (or the pin) chose, and nothing here or in them
    unions counts across transcripts.  It has to stay that way.  The count is
    read as evidence that *this* builder has a batch sub-agent outstanding, and
    it feeds `stall` (via `batch_running`) and the `underway (in flight)`
    verdict; a count borrowed from some other session in the directory would
    report another run's sub-agent as this run's activity, and would suppress a
    stall on evidence about a session the watch is not watching.  The 2026-10-01
    drift was one derivation away from doing exactly that.  `selftest.sh` keeps
    a decoy transcript with a count of 7 in the fixture directory and pins that
    the watch reports the chosen transcript's 0.
    """
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


def plan_at_rev(repo, rev):
    """Was WORKPLAN.md in the tree at `rev`?  -> True | False | None.

    `None` is "could not be read" - a rev that does not resolve, or a git that
    failed - and is deliberately not False: "the plan was never there" and "we
    could not look" are different claims, and only the first of them says
    anything about whether a series closed.

    This is what makes an absent plan legible.  The series ends by *deleting*
    WORKPLAN.md (G4), so "no plan at HEAD" is the end state of a closed series
    - but only if there was a plan at the base commit to delete.  A run that
    *begins* by recreating the plan (run 3's builder was started with `recreate
    WORKPLAN.md from git show c79cbc5:WORKPLAN.md`) has no plan at base and,
    until its plan commit lands, none at HEAD either.  Those two states look
    identical to a reader of the worktree, and the old rule - "gone and pushed
    is finished" - called the second one a finished run.
    """
    git = git_in(repo)
    rc, _, _ = git("cat-file", "-e", "%s:WORKPLAN.md" % rev)
    if rc == 0:
        return True
    # `cat-file -e` fails the same way for "no such path in that tree" and for
    # "no such tree", so ask whether the rev resolves at all before reading the
    # failure as an absence.
    rc2, _, _ = git("rev-parse", "--verify", "%s^{commit}" % rev)
    if rc2 != 0:
        return None
    return False


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
# Two more qualified `finished`es, on the same terms as the qualified
# `underway` above: both begin with `finished`, which is what a caller matches
# on, and the parenthetical says what is different about this one.  Here it is
# the *reason there are no rows to read* - the last batch deleted the plan - so
# a reader is not left wondering why a finished run reports no batch statuses.
V_FINISHED_CLOSED = "finished (series closed)"
# ... and the "we did not look" form, for the same reason the finished trigger
# has one: `gh` being unreadable is not evidence that CI passed.
V_FINISHED_CLOSED_UNVERIFIED = "finished (series closed, CI unverified)"
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
            head_past_base=True, pending=None, sub_quiet_s=None, dirty=False,
            base_had_plan=None, ci=None):
    """-> (verdict line, one-line reason).

    Pure: every argument is evidence already gathered by the caller, so the
    rule is testable without a repo, a transcript or a clock.

      statuses            {batch id: status} from WORKPLAN.md section 1
      source              "worktree" | "HEAD" | "absent" | "unreadable"
      batches             the run's batch list, in section 2's execution order
      how                 HOW_DERIVED | HOW_FLOOR_DERIVED | HOW_PIN |
                          HOW_FLOOR | HOW_NONE | HOW_AMBIGUOUS.  Only the two
                          that begin with `derived` mean "a session for this
                          run is visible"; the floor's and the ambiguity's
                          answers read as no transcript here, which is what
                          they are from the verdict's point of view
      quiet_s             seconds since the newest liveness signal, or None
      pushed              HEAD == origin/<branch>
      asks / limit_hit    the two "waiting on user" signals
      declared_since_base batch ids of this run declared by a commit since base
      head_past_base      HEAD has at least one commit since base - i.e. the
                          run's plan commit exists at all
      pending             last pendingBackgroundAgentCount seen, or None
      sub_quiet_s         seconds since the newest file under `subagents/`
      dirty               the working tree has uncommitted changes
      base_had_plan       WORKPLAN.md existed at the base commit: True | False
                          | None ("could not be read" - see `plan_at_rev`)
      ci                  what CI concluded on the pushed tip, as
                          `ci_conclusion` reports it: "success" | "pending" |
                          "failure" | "unavailable" | None (not asked, which
                          counts as unverified, never as green)

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

    # A closed series has no rows to read: G4's last act is to remove
    # WORKPLAN.md, so the run that finishes the series ends with the parser
    # looking at a file that is not there.  That absence is the end state - but
    # it is only *this* run's end state if there was a plan at base to delete,
    # and it is only *finished* on the same terms as every other finished run:
    # pushed AND green (WORKPLAN.md 0.1 step 8).  An absence that was already
    # there at base is not a close at all, and falls through to the ordinary
    # rules below with no rows - where `active` is the whole batch list, so
    # `finished` is unreachable.  That is the run-3 shape: a builder told to
    # recreate the plan has no WORKPLAN.md at base, and none at HEAD either
    # until its plan commit lands.
    if source == "absent" and base_had_plan:
        if not pushed:
            return V_UNCLEAR, ("WORKPLAN.md was removed since base - the series "
                               "close - but HEAD is not pushed")
        if ci == "success":
            return V_FINISHED_CLOSED, ("WORKPLAN.md was present at base and is gone "
                                       "at HEAD, HEAD is pushed and CI on it is green")
        if ci == "pending":
            return V_UNCLEAR, ("the series close is pushed but CI on the pushed tip "
                               "has not concluded")
        if ci == "failure":
            return V_UNCLEAR, ("the series close is pushed but CI on the pushed tip "
                               "did not pass, so 0.1 step 8 is not met")
        return V_FINISHED_CLOSED_UNVERIFIED, (
            "WORKPLAN.md was present at base and is gone at HEAD and HEAD is "
            "pushed, but CI on it was not read (%s)" % (ci or "not asked"))
    if source == "absent" and base_had_plan is None:
        return V_UNCLEAR, ("WORKPLAN.md is gone at HEAD, but whether it existed at "
                           "base could not be read, so this is not a close we can "
                           "claim")

    # A plan that is present but has no row for any batch of this run is not
    # describing this run.  Asking a run-2 question after run 3 recreated
    # WORKPLAN.md gave "0/16 stopped, active: <all sixteen>" - sixteen absent
    # rows defaulting to todo - and then "underway: batch A5" for a run that
    # finished a day earlier.  Absent rows are the absence of evidence.
    if not any(b in statuses for b in batches) and declared_since_base:
        return V_UNCLEAR, (
            ("WORKPLAN.md is absent at base and at HEAD, so there is no row for any "
             "batch of this run, yet %d of them are committed"
             if source == "absent" else
             "WORKPLAN.md has no row for any batch of this run, yet %d of them are "
             "committed") % len(declared_since_base))

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
    derived = (how or "").startswith("derived")
    if derived and live:
        if not head_past_base:
            return V_APPLYING, "a builder for this run is live and no plan commit exists yet"
        if not pushed:
            return V_APPLYING, "a builder for this run is live and the plan commit is not pushed yet"
        return (V_UNCLEAR,
                "the plan commit is pushed and a builder is live, but no batch is "
                "declared, no row has moved and nothing is in flight")
    if derived:
        return V_UNCLEAR, "a builder for this run exists but is quiet and has declared nothing"
    return V_NOT_STARTED, "no builder transcript for this run, and no batch declared"


def resume_note_tail(repo, n=12):
    lines, source = _workplan_lines(repo)
    if lines is None:
        return ["<WORKPLAN.md unreadable>"]
    if source == "absent":
        # Not "the series is closed": this function cannot see the base, and an
        # absent plan is a close only if there was one at base to delete.  The
        # verdict line says which; this just says there is nothing to read.
        return ["<WORKPLAN.md is absent - no rows and no resume note to read>"]
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
