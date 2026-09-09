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
# Every watcher/aux session that has ever run this tooling from inside the same
# project directory.  A watcher must never derive onto itself.
DEF_SELF   = ("c2a395dd-9fdb-4c60-8878-b3c4e7a5a48d.jsonl "
              "05be40ff-b82d-4a92-bc3c-df42832b095c.jsonl")
DEF_BASE   = "c79cbc5"
DEF_BRANCH = "audit-fixes"
DEF_RUN    = "2"
DEF_PIDS   = "820503 820602 820711 820816"
DEF_BATCHES = "A5 A6 A7 A8 B3 A9 C3 D2 H2 G5 E2 E3 E4 F1 F2 G4"


def config():
    """Resolve configuration from the environment.  Callers set these; the
    shell front ends turn their flags into these variables."""
    return {
        "repo":    os.environ.get("SPANWEAVE_REPO", DEF_REPO),
        "tdir":    os.environ.get("SPANWEAVE_TDIR", DEF_TDIR),
        "pinned":  os.environ.get("SPANWEAVE_PINNED", DEF_PINNED),
        "self":    [n for n in os.environ.get("SPANWEAVE_SELF", DEF_SELF)
                    .replace(",", " ").split() if n],
        "base":    os.environ.get("SPANWEAVE_BASE", DEF_BASE),
        "branch":  os.environ.get("SPANWEAVE_BRANCH", DEF_BRANCH),
        "run":     int(os.environ.get("SPANWEAVE_RUN", DEF_RUN)),
        "pids":    [int(x) for x in os.environ.get("SPANWEAVE_PIDS", DEF_PIDS)
                    .replace(",", " ").split()],
        "batches": os.environ.get("SPANWEAVE_BATCHES", DEF_BATCHES)
                   .replace(",", " ").split(),
    }


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

BATCH_ID = r"[A-H]\d+"
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
#   * mentions "WORKPLAN.md run N" or "Resume WORKPLAN.md", and
#   * names no run number other than N, and
#   * is not one of this tooling's own session files.
#
# Among candidates: newest `<stem>/subagents/` directory mtime wins, then the
# transcript's own mtime.  With no candidate the configured pin is used - an
# operator override, so it is not re-tested against the run number.
#
# Under this rule the 95360def drift cannot recur: its lastPrompt is
# "Execute WORKPLAN.md run 1", which fails the run-N match *and* names run 1.

LP_RE = re.compile(r'"lastPrompt"\s*:\s*"((?:[^"\\]|\\.)*)"')
RUNNUM_RE = re.compile(r"\brun\s*#?\s*(\d+)\b", re.I)


def want_re(run):
    return re.compile(r"WORKPLAN\.md\s+run\s+0*%d\b|Resume\s+WORKPLAN\.md" % int(run),
                      re.I)


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
    want = want_re(run)
    cands, rejected = [], []
    for path in sorted(glob.glob(os.path.join(cfg["tdir"], "*.jsonl"))):
        name = os.path.basename(path)
        if name in cfg["self"]:
            rejected.append((name, "own session file"))
            continue
        lp = last_prompt(path)
        if not lp:
            continue
        if not want.search(lp):
            continue
        named = set(int(x) for x in RUNNUM_RE.findall(lp))
        other = sorted(named - {run})
        if other:
            rejected.append((name, "lastPrompt names run %s, not run %d"
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


def workplan_statuses(repo):
    path = os.path.join(repo, "WORKPLAN.md")
    try:
        with open(path, errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return None, None
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
    return out, raw


def is_stopped(status):
    s = (status or "").strip().lower()
    return (s in ("done", "dropped")
            or s.startswith("awaiting")
            or s.startswith("blocked"))


def resume_note_tail(repo, n=12):
    path = os.path.join(repo, "WORKPLAN.md")
    try:
        with open(path, errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return ["<WORKPLAN.md unreadable>"]
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
