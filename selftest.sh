#!/usr/bin/env bash
# selftest.sh - proves the two rules WATCH.md documents, against fixtures only.
#
# Builds a throwaway repo and a throwaway transcript directory under a temp
# dir; ~/git/spanweave and the real transcript directory are never read or
# written.  Exit 0 = all cases pass.

set -uo pipefail
OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SPANWEAVE_OPS_DIR="$OPS_DIR"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/spanweave-selftest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# A floor, so the header's promise still holds.  `branch` is DERIVED from the
# watched repo's checkout now, so any `config()` call that left
# SPANWEAVE_BRANCH unset would shell out to the real ~/git/spanweave.  Every
# section that cares overrides both; the branch-default cases below unset them
# deliberately, against a fixture repo of their own.
export SPANWEAVE_REPO="$TMP/no-such-repo" SPANWEAVE_BRANCH="selftest-floor"

# The same kind of floor for `gh`, which `finished` now asks about the CI
# conclusion on the pushed tip.  The real `gh` is never run from this script:
# a stub is first on PATH for every case below, and it answers only from
# GH_STUB_*.  Its default is the "gh could not tell us anything" branch, so a
# case that forgets to say what CI said gets the unverified answer rather than
# a silent network call.
STUBBIN="$TMP/stubbin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
# selftest stub for gh - prints canned JSON, never opens a socket.
[ -n "${GH_STUB_SLEEP:-}" ] && sleep "$GH_STUB_SLEEP"
[ -n "${GH_STUB_OUT:-}" ] && printf '%s\n' "$GH_STUB_OUT"
[ -n "${GH_STUB_ERR:-}" ] && printf '%s\n' "$GH_STUB_ERR" >&2
exit "${GH_STUB_RC:-1}"
STUB
chmod +x "$STUBBIN/gh"
# The same kind of floor for `pgrep`, which arming shells out to for the PID
# set.  It answered from the real machine until 2026-10-04, which was harmless
# only while the PID set was unscoped: now that the set is scoped to the
# watched repo, arming prints a line naming the builder-shaped processes
# running OUTSIDE it - so a real `pgrep` put this machine's own sessions into
# the output a case was comparing, and `arming derives the branch` failed with
# three live PIDs in its captured stdout.  A fixture-only harness cannot read
# the machine at all.  Default: nothing is running, which is pgrep's exit 1.
cat > "$STUBBIN/pgrep" <<'STUB'
#!/usr/bin/env bash
# selftest stub for pgrep - answers only from PGREP_STUB_OUT.
[ -n "${PGREP_STUB_OUT:-}" ] || exit 1
printf '%s\n' "$PGREP_STUB_OUT"
STUB
chmod +x "$STUBBIN/pgrep"
export PATH="$STUBBIN:$PATH"
export GH_STUB_RC=1 GH_STUB_OUT="" GH_STUB_ERR="stub gh: no canned answer for this case"
export PGREP_STUB_OUT=""

gh_says() {   # gh_says <repo> <status> <conclusion-as-json> - about that repo's HEAD
  export GH_STUB_RC=0 GH_STUB_ERR=""
  export GH_STUB_OUT="[{\"headSha\":\"$(git -C "$1" rev-parse HEAD)\",\"status\":\"$2\",\"conclusion\":$3}]"
}
gh_unavailable() {  # the default: gh ran and told us nothing usable
  export GH_STUB_RC=1 GH_STUB_OUT="" GH_STUB_ERR="${1:-could not connect to api.github.com}"
}

fail=0
ok()   { printf '  PASS  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
check(){
  if [ "$2" = "$3" ]; then ok "$1"
  else printf '  FAIL  %s\n        got : %s\n        want: %s\n' "$1" "$2" "$3"; fail=1; fi
}

# ---------------------------------------------------------------------------
echo "rule (a) - a batch id counts only where a batch is declared"
# ---------------------------------------------------------------------------
python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import declared_batches

RUN2 = "A5 A6 A7 A8 B3 A9 C3 D2 H2 G5 E2 E3 E4 F1 F2 G4".split()
cases = [
    # (name, subject, body, expected declared, expected outside-run-2)
    ("477fe9b: declares A6, cites A1 in prose",
     "errors: deep nesting is contained on the CLI's paths and on the write side",
     "Batch A6 of WORKPLAN.md. Review blocker 2 plus the resume note's write-side\n"
     "finding, both under audit finding 3.\n\n"
     "A1 contained `RecursionError` where the reader and the adapters *parse*. It\n"
     "stopped there, in two directions:\n\n"
     "* A3's rule applied one level up. C1's sentence is fixed by C3, not here.\n",
     ["A6"], []),
    ("plan subject declares its batch",
     "plan: A6 done; dependency markers resolved to todo",
     "A6 (`477fe9b`) contained deep nesting. D2, E2, E3, E4, F1, F2 -> todo.\n",
     ["A6"], []),
    ("a real out-of-run declaration still trips",
     "reader: something",
     "Batch B1 of WORKPLAN.md. Annotation cost.\n", ["B1"], ["B1"]),
    ("a plan: subject naming an out-of-run batch trips",
     "plan: G1 done", "Roadmap gate defined.\n", ["G1"], ["G1"]),
    ("prose-only mention of an out-of-run batch does not trip",
     "docs: tidy", "Batch A7 of WORKPLAN.md. Supersedes what G1 and B2 said.\n",
     ["A7"], []),
    ("no declaration at all", "chore: whitespace", "Nothing to declare.\n", [], []),
    ("two declarations, both counted", "chore: two",
     "Batch A5 of WORKPLAN.md.\nBatch H9 of WORKPLAN.md.\n", ["A5", "H9"], ["H9"]),
    ("indented / lowercased declaration still counted", "chore: c",
     "  batch a5 of WORKPLAN.md and more\n", ["A5"], []),
    # BATCH_ID is prefix-agnostic: run 3's ids are R1-R7, and `[A-H]\d+` made
    # every one of them invisible - rows, declarations and all.
    ("an R-prefixed body declaration is seen", "read: something",
     "Batch R1 of WORKPLAN.md. Timestamps are finite and bounded.\n", ["R1"], ["R1"]),
    ("an R-prefixed plan: subject is seen", "plan: R4 done",
     "B3's sentence against B3's behaviour.\n", ["R4"], ["R4"]),
    ("a two-digit id past the old A-H range is seen", "plan: Z12 done",
     "Nothing.\n", ["Z12"], ["Z12"]),
    ("the run-3 reopen commit declares nothing", "plan: reopen for run 3 -- run-2 review findings",
     "So the execution-state file G4 deliberately deleted comes back, with a\n"
     "run-3 batch list:\n\n- R1 timestamps are finite and bounded, or missing;\n"
     "- R2 track the reviews under `reviews/`;\n", [], []),
]
bad = 0
for name, subj, body, want_decl, want_out in cases:
    got = declared_batches(subj, body)
    out = [b for b in got if b not in RUN2]
    if got == want_decl and out == want_out:
        print("  PASS  %s" % name)
    else:
        print("  FAIL  %s\n        declared %s want %s | outside %s want %s"
              % (name, got, want_decl, out, want_out))
        bad = 1
sys.exit(bad)
PY
[ $? -eq 0 ] || fail=1

# ---------------------------------------------------------------------------
echo
echo "rule (b) - builder-transcript derivation takes --run N"
# ---------------------------------------------------------------------------
TD="$TMP/tdir"; mkdir -p "$TD"
mk() {  # mk <uuid> <lastPrompt> ; creates <uuid>.jsonl
  printf '{"type":"last-prompt","lastPrompt":%s}\n' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$2")" > "$TD/$1.jsonl"
}
# The exact drift case: a run-1 builder, newest of all by mtime, with subagents.
mk 95360def "Execute WORKPLAN.md run 1"
mkdir -p "$TD/95360def/subagents"; : > "$TD/95360def/subagents/a.jsonl"
# A run-2 builder, older, whose subagents/ moved more recently.
mk 28018437 "Execute WORKPLAN.md run 2"
mkdir -p "$TD/28018437/subagents"; : > "$TD/28018437/subagents/a.jsonl"
# A resumed run-2 builder with no subagents yet.
mk aaaaaaaa "Resume WORKPLAN.md after the limit reset"
# The watcher's own session, which also names run 2.
mk c2a395dd "arm a read-only watch on WORKPLAN.md run 2"
# An aux reviewer: names run 2 but not in a form the rule accepts.
mk 29d210c7 "Review WORKPLAN.md commits since 02e9f6e"
# A run-3 session that says "Resume WORKPLAN.md" - excluded by run number.
mk bbbbbbbb "Resume WORKPLAN.md run 3"

touch -d '2026-09-10 01:00:00' "$TD/28018437.jsonl" "$TD/28018437/subagents/a.jsonl"
touch -d '2026-09-10 01:30:00' "$TD/28018437/subagents"
touch -d '2026-09-10 02:00:00' "$TD/95360def.jsonl" "$TD/95360def/subagents/a.jsonl" "$TD/95360def/subagents"
touch -d '2026-09-10 02:10:00' "$TD/aaaaaaaa.jsonl"
touch -d '2026-09-10 02:20:00' "$TD/c2a395dd.jsonl"
touch -d '2026-09-10 02:25:00' "$TD/29d210c7.jsonl"
touch -d '2026-09-10 02:30:00' "$TD/bbbbbbbb.jsonl"

derive() {  # derive <run> <pinned> -> "<name>|<how>|<candidate names>"
  SPANWEAVE_TDIR="${TD}" SPANWEAVE_RUN="$1" SPANWEAVE_PINNED="$2" \
  SPANWEAVE_SELF="c2a395dd.jsonl" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import config, derive_transcript
name, lp, cands, how, rej = derive_transcript(config())
print("%s|%s|%s" % (name, how, ",".join(c[2] for c in cands)))
PY
}

check "run 2 picks the run-2 builder, not the newer run-1 one" \
      "$(derive 2 28018437.jsonl)" \
      "28018437.jsonl|derived|28018437.jsonl,aaaaaaaa.jsonl"
# "Resume WORKPLAN.md" names no run number, so it is a candidate for any run -
# that is the point of the phrase: a resumed session need not restate the run.
check "run 1 picks the run-1 builder over the run-2 one" \
      "$(derive 1 28018437.jsonl)" \
      "95360def.jsonl|derived|95360def.jsonl,aaaaaaaa.jsonl"
check "a run the fixtures do not name keeps only the unnumbered resume" \
      "$(derive 9 28018437.jsonl)" \
      "aaaaaaaa.jsonl|derived|aaaaaaaa.jsonl"
mkdir -p "$TMP/empty" && : > "$TMP/empty/28018437.jsonl"
check "no candidate at all falls back to the pin" \
      "$(TD="$TMP/empty" derive 2 28018437.jsonl)" \
      "28018437.jsonl|pin (no candidate)|"

# The drift itself: 95360def must never be chosen for run 2, by any path.
for pin in 28018437.jsonl aaaaaaaa.jsonl; do
  got="$(derive 2 "$pin")"
  case "$got" in
    95360def*) bad "95360def chosen for run 2 with pin $pin" ;;
    *)         ok  "95360def not chosen for run 2 (pin $pin)" ;;
  esac
done

# Remove the run-2 candidates: even then, the run-1 transcript is not eligible.
rm -f "$TD/28018437.jsonl" "$TD/aaaaaaaa.jsonl"
check "with every run-2 candidate gone, run 1's transcript is still refused" \
      "$(derive 2 zzz.jsonl)" "None|none|"
mk 28018437 "Execute WORKPLAN.md run 2"; mk aaaaaaaa "Resume WORKPLAN.md after the limit reset"
touch -d '2026-09-10 01:00:00' "$TD/28018437.jsonl"; touch -d '2026-09-10 01:30:00' "$TD/28018437/subagents"
touch -d '2026-09-10 02:10:00' "$TD/aaaaaaaa.jsonl"

# Tie-break order: subagents/ mtime first, then the transcript's own mtime.
touch -d '2026-09-10 02:40:00' "$TD/aaaaaaaa.jsonl"
check "a newer transcript still loses to a newer subagents/ dir" \
      "$(derive 2 28018437.jsonl)" \
      "28018437.jsonl|derived|28018437.jsonl,aaaaaaaa.jsonl"
touch -d '2026-09-10 03:00:00' "$TD/28018437/subagents" "$TD/aaaaaaaa.jsonl"
mkdir -p "$TD/aaaaaaaa/subagents"; touch -d '2026-09-10 03:00:00' "$TD/aaaaaaaa/subagents"
check "equal subagents/ mtime falls through to the transcript's own mtime" \
      "$(derive 2 28018437.jsonl)" \
      "aaaaaaaa.jsonl|derived|aaaaaaaa.jsonl,28018437.jsonl"

got="$(SPANWEAVE_SELF="c2a395dd.jsonl,28018437.jsonl,aaaaaaaa.jsonl" \
       SPANWEAVE_TDIR="$TD" SPANWEAVE_RUN=2 SPANWEAVE_PINNED=zzz.jsonl python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import config, derive_transcript
name, lp, cands, how, rej = derive_transcript(config())
print("%s|%s" % (name, how))
PY
)"
check "a watcher never derives onto its own session file" "$got" "None|none"

# ---------------------------------------------------------------------------
echo
echo "end to end - watch_run.sh --once over a fixture repo"
# ---------------------------------------------------------------------------
R="$TMP/repo"; mkdir -p "$R"
git -C "$R" init -q -b audit-fixes
git -C "$R" config user.email t@example.invalid
git -C "$R" config user.name Selftest
cat > "$R/WORKPLAN.md" <<'MD'
## 1. Batches

| # | Batch | Status | Est. calls |
|---|---|---|---|
| A5 | thing | done | 20 |
| A6 | thing | done | 12 |
| B3 | thing | todo | 15 |

## 4. Resume note

- A6 done.

---
MD
git -C "$R" add -A
# The base is authored BEFORE the transcript fixtures above (2026-09-10), which
# were written when that was "now".  The base-time floor refuses any transcript
# last written before the base commit's author time, so a base authored today
# would push this section onto the pin and quietly stop it exercising the
# derivation at all.  Dating the base restores what the fixture always meant.
GIT_COMMITTER_DATE="2026-09-09 00:00:00 +0300" GIT_AUTHOR_DATE="2026-09-09 00:00:00 +0300" \
  git -C "$R" commit -qm "base"
BASE="$(git -C "$R" rev-parse HEAD)"
git -C "$R" remote add origin "$R/../remote.git"
git -C "$R" init -q --bare "$TMP/remote.git" 2>/dev/null || git init -q --bare "$TMP/remote.git"
git -C "$R" remote set-url origin "$TMP/remote.git"
git -C "$R" push -q origin audit-fixes

# The 477fe9b shape: declares A6, cites A1 in prose, touches a source path.
mkdir -p "$R/spanweave" && echo x > "$R/spanweave/errors.py"
git -C "$R" add -A
git -C "$R" commit -q -F - <<'MSG'
errors: deep nesting is contained on the CLI's paths and on the write side

Batch A6 of WORKPLAN.md. Review blocker 2 plus the resume note's write-side
finding, both under audit finding 3.

A1 contained `RecursionError` where the reader and the adapters *parse*.
A3's rule applied one level up. C1's sentence is fixed by C3, not here.
MSG

ST="$TMP/state"; mkdir -p "$ST"
export SPANWEAVE_STATE_DIR="$ST" SPANWEAVE_REPO="$R" SPANWEAVE_TDIR="$TD" \
       SPANWEAVE_PINNED="28018437.jsonl" SPANWEAVE_SELF="c2a395dd.jsonl" \
       SPANWEAVE_BASE="$BASE" SPANWEAVE_BRANCH=audit-fixes \
       SPANWEAVE_PIDS="" SPANWEAVE_BATCHES="A5 A6 B3"
"$OPS_DIR/watch_run.sh" --once --run 2 >"$TMP/out1.txt" 2>&1
check "a 477fe9b-shaped commit does not trip the tripwire" "$?" "0"

git -C "$R" commit -q --allow-empty -F - <<'MSG'
reader: unrelated

Batch B1 of WORKPLAN.md. Not in the run list.
MSG
"$OPS_DIR/watch_run.sh" --once --run 2 >"$TMP/out2.txt" 2>&1
check "a commit declaring an out-of-run batch does trip it, without stopping" \
      "$?|$(sed -n 's/^>>> EVENT \(.*\)$/\1/p' "$TMP/out2.txt" | paste -sd, -)" \
      "0|tripwire"
grep -q "declares batch(es) outside the run-2 list: B1" "$TMP/out2.txt" \
  && ok "the evidence block names B1" || bad "the evidence block does not name B1"

# ---------------------------------------------------------------------------
echo
echo "per-trigger policy - terminal vs report-and-continue, and the dedup paths"
# ---------------------------------------------------------------------------
R2="$TMP/repo2"; mkdir -p "$R2"
git -C "$R2" init -q -b audit-fixes
git -C "$R2" config user.email t@example.invalid
git -C "$R2" config user.name Selftest
cat > "$R2/WORKPLAN.md" <<'MD'
## 1. Batches

| # | Batch | Status | Est. calls |
|---|---|---|---|
| A5 | thing | done | 20 |
| B3 | thing | todo | 15 |

## 4. Resume note

- A5 done.

---
MD
git -C "$R2" add -A
GIT_COMMITTER_DATE="$(date -d '-90 min' -R)" GIT_AUTHOR_DATE="$(date -d '-90 min' -R)" \
  git -C "$R2" commit -qm "base"
BASE2="$(git -C "$R2" rev-parse HEAD)"
git init -q --bare "$TMP/remote2.git"
git -C "$R2" remote add origin "$TMP/remote2.git"
git -C "$R2" push -q origin audit-fixes

TD2="$TMP/tdir2"; mkdir -p "$TD2"
ST2="$TMP/state2"; mkdir -p "$ST2"
BUILDER="$TD2/11111111.jsonl"

transcript() {  # transcript <last assistant text>
  {
    printf '{"type":"last-prompt","lastPrompt":"Execute WORKPLAN.md run 2"}\n'
    printf '{"type":"assistant","timestamp":"2026-09-10T00:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":%s}]}}\n' \
      "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")"
  } > "$BUILDER"
}

run2() {  # run2 -> prints "<exit>|<event kinds, comma separated>"
  local out rc
  out="$(SPANWEAVE_STATE_DIR="$ST2" SPANWEAVE_REPO="$R2" SPANWEAVE_TDIR="$TD2" \
         SPANWEAVE_PINNED="11111111.jsonl" SPANWEAVE_SELF="none.jsonl" \
         SPANWEAVE_BASE="$BASE2" SPANWEAVE_BRANCH=audit-fixes \
         SPANWEAVE_PIDS="" SPANWEAVE_BATCHES="A5 B3" \
         "$OPS_DIR/watch_run.sh" --once --run 2 2>&1)"
  rc=$?
  printf '%s\n' "$out" > "$TMP/last_run.txt"
  printf '%s|%s' "$rc" \
    "$(printf '%s\n' "$out" | sed -n -e 's/^>>> EVENT \(.*\)$/\1/p' -e 's/^>>> LINE \(RESUMED\).*$/\1/p' | paste -sd, -)"
}

age_index() { touch -d "$1" "$R2/.git/index"; }

# Fixed points, captured once, NOT recomputed per touch.
#
# `movement()` lifts a suppressed waiting/stall the moment liveness moves
# forward by more than 0.5 s. `touch -d '-20 min'` is relative to *now*, so
# calling it again after a poll sets the transcript 20 min before a later now -
# i.e. later than the stored observation - and the fixture lifted its own
# suppression before the poll that was meant to find it suppressed. Whether it
# raced through depended on how long `git fetch` took: ~50% here, and it fails
# on the pre-existing tree too. An absolute stamp only ever gets older, which
# is what "quiet" is supposed to mean.
WAIT_AT="$(date -d '-20 min' '+%Y-%m-%d %H:%M:%S')"
STALL_AT="$(date -d '-60 min' '+%Y-%m-%d %H:%M:%S')"
INDEX_AT="$(date -d '-90 min' '+%Y-%m-%d %H:%M:%S')"

# -- tripwire: reported, watch continues, each commit reported once ----------
transcript "Working on B3 now."
touch "$BUILDER"
GIT_COMMITTER_DATE="$(date -d '-85 min' -R)" GIT_AUTHOR_DATE="$(date -d '-85 min' -R)" \
git -C "$R2" commit -q --allow-empty -F - <<'MSG'
reader: unrelated

Batch B1 of WORKPLAN.md. Not in the run list.
MSG
age_index "$INDEX_AT"
check "tripwire is non-terminal: it reports and exits 0" "$(run2)" "0|tripwire"
grep -q "watch continues" "$TMP/last_run.txt" && ok "the block says the watch continues" \
  || bad "the block does not say the watch continues"
age_index "$INDEX_AT"
check "the same commit is not reported a second time" "$(run2)" "0|"
GIT_COMMITTER_DATE="$(date -d '-80 min' -R)" GIT_AUTHOR_DATE="$(date -d '-80 min' -R)" \
git -C "$R2" commit -q --allow-empty -F - <<'MSG'
reader: another

Batch G1 of WORKPLAN.md. Also not in the run list.
MSG
age_index "$INDEX_AT"
check "a new offending commit is reported" "$(run2)" "0|tripwire"
grep -q "outside the run-2 list: G1" "$TMP/last_run.txt" && ok "the second block names G1" \
  || bad "the second block does not name G1"
grep -q "outside the run-2 list: B1" "$TMP/last_run.txt" && bad "the second block repeats B1" \
  || ok "the second block does not repeat B1"
python3 - "$ST2/watch_state.json" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
n = len(st.get("reported_commits") or [])
print("  PASS  watch_state.json records %d reported commit sha(s)" % n) if n >= 2 \
    else print("  FAIL  watch_state.json records %d reported commit shas, want >= 2" % n)
sys.exit(0 if n >= 2 else 1)
PY
[ $? -eq 0 ] || fail=1

# -- waiting on user: once, suppressed, RESUMED when liveness returns --------
transcript "Two options here. Shall I take the first?"
touch -d "$WAIT_AT" "$BUILDER"
age_index "$INDEX_AT"
check "waiting on user is non-terminal and reports once" "$(run2)" "0|waiting on user"
touch -d "$WAIT_AT" "$BUILDER"; age_index "$INDEX_AT"
check "a repeat waiting-on-user poll is suppressed" "$(run2)" "0|"
touch "$BUILDER"; age_index "$INDEX_AT"
check "liveness returning emits one RESUMED line" "$(run2)" "0|RESUMED"
grep -q '^>>> LINE RESUMED after waiting on user' "$TMP/last_run.txt" \
  && ok "the RESUMED line names what it resumed from" \
  || bad "the RESUMED line does not name what it resumed from"
grep -q 'liveness .* -> ' "$TMP/last_run.txt" && ok "the RESUMED line names what moved" \
  || bad "the RESUMED line does not name what moved"
touch -d "$WAIT_AT" "$BUILDER"; age_index "$INDEX_AT"
check "after a resume, waiting on user can fire again" "$(run2)" "0|waiting on user"

# -- stall: once, then only after a further 40 minutes -----------------------
python3 - "$ST2/watch_state.json" <<'PY'
import json, sys
st = json.load(open(sys.argv[1])); st.pop("waiting", None); st.pop("stall", None)
json.dump(st, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
transcript "Running the batch."
touch -d "$STALL_AT" "$BUILDER"
age_index "$INDEX_AT"
check "stall is non-terminal and reports once" "$(run2)" "0|stall"
touch -d "$STALL_AT" "$BUILDER"; age_index "$INDEX_AT"
check "a repeat stall poll inside 40 min is suppressed" "$(run2)" "0|"
python3 - "$ST2/watch_state.json" <<'PY'
import json, sys, time
st = json.load(open(sys.argv[1]))
if "stall" not in st:
    print("  FAIL  no stall record in watch_state.json to age"); sys.exit(1)
st["stall"]["fired_at"] = time.time() - 41 * 60      # pretend 41 min have passed
json.dump(st, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
touch -d "$STALL_AT" "$BUILDER"; age_index "$INDEX_AT"
check "stall fires a second time after a further 40 min" "$(run2)" "0|stall"
grep -q "TRIGGER: stall (still," "$TMP/last_run.txt" && ok "the repeat says it is a repeat" \
  || bad "the repeat does not say it is a repeat"
touch "$BUILDER"; age_index "$INDEX_AT"
check "liveness returning after a stall emits RESUMED" "$(run2)" "0|RESUMED"

# -- the two terminal triggers still exit ------------------------------------
python3 - "$ST2/watch_state.json" <<'PY'
import json, sys
st = json.load(open(sys.argv[1])); st.pop("waiting", None); st.pop("stall", None)
json.dump(st, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
transcript "Working."
touch "$BUILDER"
out="$(SPANWEAVE_STATE_DIR="$ST2" SPANWEAVE_REPO="$R2" SPANWEAVE_TDIR="$TD2" \
       SPANWEAVE_PINNED="11111111.jsonl" SPANWEAVE_SELF="none.jsonl" \
       SPANWEAVE_BASE="$BASE2" SPANWEAVE_BRANCH=audit-fixes \
       SPANWEAVE_PIDS="4000000001" SPANWEAVE_BATCHES="A5 B3" \
       "$OPS_DIR/watch_run.sh" --once --run 2 2>&1)"
check "builder gone is terminal (exit 13)" "$?" "13"
printf '%s\n' "$out" | grep -q "terminal, watch stops" \
  && ok "the builder-gone block says the watch stops" \
  || bad "the builder-gone block does not say the watch stops"

sed -i 's/^| B3 | thing | todo | 15 |$/| B3 | thing | done | 15 |/' "$R2/WORKPLAN.md"
git -C "$R2" commit -qam "plan: B3 done"
git -C "$R2" push -q origin audit-fixes
gh_says "$R2" completed '"success"'
out="$(SPANWEAVE_STATE_DIR="$ST2" SPANWEAVE_REPO="$R2" SPANWEAVE_TDIR="$TD2" \
       SPANWEAVE_PINNED="11111111.jsonl" SPANWEAVE_SELF="none.jsonl" \
       SPANWEAVE_BASE="$BASE2" SPANWEAVE_BRANCH=audit-fixes \
       SPANWEAVE_PIDS="" SPANWEAVE_BATCHES="A5 B3" \
       "$OPS_DIR/watch_run.sh" --once --run 2 2>&1)"
check "finished is terminal (exit 10)" "$?" "10"
printf '%s\n' "$out" | grep -q "terminal, watch stops" \
  && ok "the finished block says the watch stops" \
  || bad "the finished block does not say the watch stops"

# ---------------------------------------------------------------------------
echo
echo "series close - G4 removes WORKPLAN.md, and the watch must survive it"
# ---------------------------------------------------------------------------
python3 - "$ST2/watch_state.json" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
for k in ("waiting", "stall"): st.pop(k, None)
json.dump(st, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
transcript "Closing the series."
touch "$BUILDER"

# Keep HEAD ahead of origin so `finished` cannot fire and mask these cases.
git -C "$R2" commit -q --allow-empty -m "chore: hold HEAD ahead of origin"

# (1) staged deletion: gone from the worktree, still committed at HEAD.
git -C "$R2" rm -q --cached WORKPLAN.md && rm -f "$R2/WORKPLAN.md"
check "a staged WORKPLAN.md deletion does not kill the watch" "$(run2)" "0|"
grep -q "plan from HEAD" "$TMP/last_run.txt" \
  && ok "the banner says the rows came from HEAD" \
  || bad "the banner does not say where the rows came from"

# (2) committed deletion: gone from the worktree and from HEAD.
git -C "$R2" commit -q -m "plan: series closed, WORKPLAN.md removed"
out="$(SPANWEAVE_STATE_DIR="$ST2" SPANWEAVE_REPO="$R2" SPANWEAVE_TDIR="$TD2" \
       SPANWEAVE_PINNED="11111111.jsonl" SPANWEAVE_SELF="none.jsonl" \
       SPANWEAVE_BASE="$BASE2" SPANWEAVE_BRANCH=audit-fixes \
       SPANWEAVE_PIDS="" SPANWEAVE_BATCHES="A5 B3" \
       "$OPS_DIR/watch_run.sh" --once --run 2 2>&1)"
rc=$?
check "a committed WORKPLAN.md deletion does not raise a watcher error" \
      "$(printf '%s' "$rc" | sed 's/^2$/WATCHER ERROR/')" "0"
printf '%s\n' "$out" | grep -q "plan absent (series closed)" \
  && ok "the banner reports the plan as absent, and as a close" \
  || bad "the banner does not report the plan as absent and closed"
printf '%s\n' "$out" | grep -q "open: (none)" \
  && ok "a closed plan leaves no batch open" \
  || bad "a closed plan still shows an open batch"

# (3) with the plan closed and the branch pushed, `finished` is reachable -
# and it is the qualified form, because the reason there are no rows under it
# is that the last batch deleted them.
git -C "$R2" push -q origin audit-fixes
gh_says "$R2" completed '"success"'
out="$(SPANWEAVE_STATE_DIR="$ST2" SPANWEAVE_REPO="$R2" SPANWEAVE_TDIR="$TD2" \
       SPANWEAVE_PINNED="11111111.jsonl" SPANWEAVE_SELF="none.jsonl" \
       SPANWEAVE_BASE="$BASE2" SPANWEAVE_BRANCH=audit-fixes \
       SPANWEAVE_PIDS="" SPANWEAVE_BATCHES="A5 B3" \
       "$OPS_DIR/watch_run.sh" --once --run 2 2>&1)"
check "a closed, pushed, green plan still reaches finished (exit 10)" "$?" "10"
printf '%s\n' "$out" | grep -q "^>>> EVENT finished (series closed)\$" \
  && ok "the trigger is 'finished (series closed)'" \
  || bad "the trigger does not read 'finished (series closed)'"
printf '%s\n' "$out" | grep -q "the series is closed" \
  && ok "the finished block says the series is closed" \
  || bad "the finished block does not say the series is closed"
printf '%s\n' "$out" | grep -q "present at base $BASE2" \
  && ok "the finished block names the base the plan was present at" \
  || bad "the finished block does not say the plan was present at base"

# (3b) ... and it is still gated on CI, exactly as a plan with rows is: a
# closed series has no rows left to carry 0.1 step 8's second half, so the
# only evidence for it is what CI said about the tip.
gh_says "$R2" in_progress 'null'
out="$(SPANWEAVE_STATE_DIR="$ST2" SPANWEAVE_REPO="$R2" SPANWEAVE_TDIR="$TD2" \
       SPANWEAVE_PINNED="11111111.jsonl" SPANWEAVE_SELF="none.jsonl" \
       SPANWEAVE_BASE="$BASE2" SPANWEAVE_BRANCH=audit-fixes \
       SPANWEAVE_PIDS="" SPANWEAVE_BATCHES="A5 B3" \
       "$OPS_DIR/watch_run.sh" --once --run 2 2>&1)"
check "a closed, pushed series with CI pending is not finished" "$?" "0"
printf '%s\n' "$out" | grep -q "'finished (series closed)' cannot fire this poll" \
  && ok "the pending poll says the closed-series trigger could not fire" \
  || bad "the pending poll does not name the trigger it withheld"
printf '%s\n' "$out" | grep -q "the series close landed" \
  && ok "the pending note says what landed, not 'every batch stopped'" \
  || bad "the pending note still claims every batch stopped"

# (3c) `gh` unreadable: the run is closed and pushed, so the watch stops, but
# it says the CI half is unchecked rather than printing a bare close.
gh_unavailable
out="$(SPANWEAVE_STATE_DIR="$ST2" SPANWEAVE_REPO="$R2" SPANWEAVE_TDIR="$TD2" \
       SPANWEAVE_PINNED="11111111.jsonl" SPANWEAVE_SELF="none.jsonl" \
       SPANWEAVE_BASE="$BASE2" SPANWEAVE_BRANCH=audit-fixes \
       SPANWEAVE_PIDS="" SPANWEAVE_BATCHES="A5 B3" \
       "$OPS_DIR/watch_run.sh" --once --run 2 2>&1)"
check "a closed series with gh unreadable is terminal (exit 10)" "$?" "10"
printf '%s\n' "$out" | grep -q "^>>> EVENT finished (series closed, CI unverified)\$" \
  && ok "the unverified close says so in the trigger line" \
  || bad "the unverified close does not name itself"

# (3d) CI red on the closed tip keeps its own name and its own exit code: the
# push landed, and the run did not end green.
gh_says "$R2" completed '"failure"'
out="$(SPANWEAVE_STATE_DIR="$ST2" SPANWEAVE_REPO="$R2" SPANWEAVE_TDIR="$TD2" \
       SPANWEAVE_PINNED="11111111.jsonl" SPANWEAVE_SELF="none.jsonl" \
       SPANWEAVE_BASE="$BASE2" SPANWEAVE_BRANCH=audit-fixes \
       SPANWEAVE_PIDS="" SPANWEAVE_BATCHES="A5 B3" \
       "$OPS_DIR/watch_run.sh" --once --run 2 2>&1)"
check "a closed series whose CI is red is 'CI red', not a close (exit 15)" "$?" "15"
printf '%s\n' "$out" | grep -q "^>>> EVENT finished: CI red on " \
  && ok "the closed-series CI-red trigger keeps the CI-red name" \
  || bad "the closed-series CI-red trigger lost its name"
gh_says "$R2" completed '"success"'

# (4) a present-but-unreadable plan is still a watcher error.
git -C "$R2" revert --no-edit HEAD >/dev/null 2>&1
chmod 000 "$R2/WORKPLAN.md"
if [ -r "$R2/WORKPLAN.md" ]; then
  ok "skipped: this filesystem/user can read a 000 file"
else
  SPANWEAVE_STATE_DIR="$ST2" SPANWEAVE_REPO="$R2" SPANWEAVE_TDIR="$TD2" \
  SPANWEAVE_PINNED="11111111.jsonl" SPANWEAVE_SELF="none.jsonl" \
  SPANWEAVE_BASE="$BASE2" SPANWEAVE_BRANCH=audit-fixes \
  SPANWEAVE_PIDS="" SPANWEAVE_BATCHES="A5 B3" \
  "$OPS_DIR/watch_run.sh" --once --run 2 >/dev/null 2>&1
  check "a present-but-unreadable plan is still a watcher error" "$?" "2"
fi
chmod 644 "$R2/WORKPLAN.md"

# ---------------------------------------------------------------------------
echo
echo "the batches-not-yet-stopped field is called 'open:', not 'active:'"
# ---------------------------------------------------------------------------
# `active` claimed something the watcher cannot see - that work is happening on
# a batch. All the field knows is that the row has not stopped yet. The old
# name is pinned as *absent* from live output so a revert fails here, and the
# historical lines quoted in README.md, WATCH.md, watch_lib.py and the comment
# further down this file are deliberately left saying `active:`, because they
# are records of output that really was printed.
sed -i 's/^| B3 | thing | done | 15 |$/| B3 | thing | todo | 15 |/' "$R2/WORKPLAN.md"
transcript "Working on B3."
touch "$BUILDER"
out="$(SPANWEAVE_STATE_DIR="$ST2" SPANWEAVE_REPO="$R2" SPANWEAVE_TDIR="$TD2" \
       SPANWEAVE_PINNED="11111111.jsonl" SPANWEAVE_SELF="none.jsonl" \
       SPANWEAVE_BASE="$BASE2" SPANWEAVE_BRANCH=audit-fixes \
       SPANWEAVE_PIDS="" SPANWEAVE_BATCHES="A5 B3" \
       "$OPS_DIR/watch_run.sh" --once --run 2 2>&1)"
bannerline="$(printf '%s\n' "$out" | grep -m1 '^poll ')"
printf '%s\n' "$bannerline" | grep -q '| open: B3' \
  && ok "the poll banner names the open batches in an 'open:' field" \
  || bad "the poll banner has no 'open:' field: $bannerline"
printf '%s\n' "$bannerline" | grep -q 'active:' \
  && bad "the poll banner still prints the old 'active:' field" \
  || ok "the poll banner no longer prints 'active:'"

sout="$(SPANWEAVE_REPO="$R2" SPANWEAVE_TDIR="$TD2" \
        SPANWEAVE_PINNED="11111111.jsonl" SPANWEAVE_SELF="none.jsonl" \
        SPANWEAVE_BASE="$BASE2" SPANWEAVE_BRANCH=audit-fixes \
        SPANWEAVE_PIDS="" \
        "$OPS_DIR/status_check.sh" --run 2 --batches "A5 B3" 2>&1)"
printf '%s\n' "$sout" | grep -q '2 listed | 1 stopped | 1 open: B3' \
  && ok "the status report's plan section counts open batches" \
  || bad "the status report's plan section has no 'open:' field"
printf '%s\n' "$sout" | grep -q 'batches   : run 2: 1/2 stopped, open: B3' \
  && ok "the status report's verdict evidence says 'open:'" \
  || bad "the status report's verdict evidence has no 'open:' field"
printf '%s\n' "$sout" | grep -q 'active:' \
  && bad "the status report still prints the old 'active:' field" \
  || ok "the status report no longer prints 'active:'"
sed -i 's/^| B3 | thing | todo | 15 |$/| B3 | thing | done | 15 |/' "$R2/WORKPLAN.md"

# ---------------------------------------------------------------------------
echo
echo "finished gates on CI on the pushed tip, in four answers"
# ---------------------------------------------------------------------------
# WORKPLAN.md 0.1 step 8: a run is done when the push lands AND CI on the
# pushed tip is green. `finished` used to fire on the push alone. Every case
# here answers through the stub gh installed at the top of this file - the
# real one is never run.
transcript "Pushed the last batch."
touch "$BUILDER"
git -C "$R2" push -q -f origin audit-fixes      # head == origin, every batch stopped
TIP7="$(git -C "$R2" rev-parse --short HEAD)"

gh_says "$R2" completed '"success"'
check "CI success on the tip fires finished (exit 10)" "$(run2)" "10|finished"
grep -q "CI on the pushed tip" "$TMP/last_run.txt" \
  && ok "the finished block shows the CI evidence it fired on" \
  || bad "the finished block does not show any CI evidence"

gh_says "$R2" in_progress 'null'
check "CI still running does not fire, and the watch keeps polling" "$(run2)" "0|"
grep -q "'finished' cannot fire this poll" "$TMP/last_run.txt" \
  && ok "the pending poll says why finished did not fire" \
  || bad "the pending poll is silent about why finished did not fire"

# gh answered and simply has no run for this sha yet. That is a fact about CI
# (nothing queued) - pending - not a failure to read one.
export GH_STUB_RC=0 GH_STUB_ERR=""
export GH_STUB_OUT='[{"headSha":"0000000000000000000000000000000000000000","status":"completed","conclusion":"success"}]'
check "no workflow run for the tip yet reads as pending, not unavailable" "$(run2)" "0|"
grep -q "no workflow run for $TIP7 yet" "$TMP/last_run.txt" \
  && ok "the pending poll says gh has no run for the tip yet" \
  || bad "the pending poll does not distinguish 'no run yet' from an unreadable answer"

gh_says "$R2" completed '"failure"'
out="$(run2)"
check "CI red on the tip is terminal with its own exit code (15)" "${out%%|*}" "15"
grep -q "^>>> EVENT finished: CI red on $TIP7\$" "$TMP/last_run.txt" \
  && ok "the CI-red event line names the sha it is red on" \
  || bad "the CI-red event line does not read 'finished: CI red on <sha>'"
grep -q "not a substitute" "$TMP/last_run.txt" \
  && ok "the CI-red block says a local make check is not a substitute" \
  || bad "the CI-red block does not say why the push is not enough"

# The arming front end has to know the new code too, or a red CI reads as
# "unexpected exit" - a stop, but one that says the watcher broke.
mout="$(SPANWEAVE_STATE_DIR="$ST2" SPANWEAVE_REPO="$R2" SPANWEAVE_TDIR="$TD2" \
        SPANWEAVE_PINNED="11111111.jsonl" SPANWEAVE_SELF="none.jsonl" \
        SPANWEAVE_BASE="$BASE2" SPANWEAVE_BRANCH=audit-fixes \
        SPANWEAVE_PIDS="" SPANWEAVE_BATCHES="A5 B3" \
        "$OPS_DIR/watch_monitor.sh" --run 2 2>&1)"
check "watch_monitor.sh stops on CI red with its own exit code" "$?" "15"
printf '%s\n' "$mout" | grep -q "TERMINAL exit=15" \
  && ok "watch_monitor.sh names CI red as terminal, not unexpected" \
  || bad "watch_monitor.sh reports CI red as an unexpected exit"

gh_unavailable "could not connect to api.github.com"
out="$(run2)"
check "an unreadable gh still fires terminally (exit 10)" "${out%%|*}" "10"
grep -q "^>>> EVENT finished (CI unverified)\$" "$TMP/last_run.txt" \
  && ok "an unreadable gh says the CI claim is unverified" \
  || bad "an unreadable gh claims CI is green"
grep -q "nothing here has verified CI" "$TMP/last_run.txt" \
  && ok "the unverified block tells the reader to check CI by hand" \
  || bad "the unverified block does not say the claim is unchecked"

# Every way of failing to READ an answer, at the function, including the one
# an end-to-end case cannot stage: gh not on PATH at all.
python3 - "$R2" "$STUBBIN" "$TMP" <<'PY'
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import ci_conclusion

repo, ghbin, tmp = sys.argv[1], sys.argv[2], sys.argv[3]
sha = "0123456789abcdef0123456789abcdef01234567"
empty = os.path.join(tmp, "nobin"); os.makedirs(empty, exist_ok=True)
bad = 0


def c(name, got, want):
    global bad
    if got == want:
        print("  PASS  %s" % name)
    else:
        print("  FAIL  %s\n        got : %r\n        want: %r" % (name, got, want)); bad = 1


def ask(timeout=25, **env):
    for k, v in env.items():
        os.environ[k] = v
    return ci_conclusion(repo, "audit-fixes", sha, timeout=timeout)[0]


os.environ["PATH"] = ghbin + os.pathsep + os.environ["PATH"]
c("gh exiting non-zero is unavailable", ask(GH_STUB_RC="1", GH_STUB_OUT=""), "unavailable")
c("gh exiting 0 with no output is unavailable",
  ask(GH_STUB_RC="0", GH_STUB_OUT=""), "unavailable")
c("gh printing something that is not JSON is unavailable",
  ask(GH_STUB_RC="0", GH_STUB_OUT="gh: rate limit exceeded"), "unavailable")
c("gh printing JSON that is not a list of runs is unavailable",
  ask(GH_STUB_RC="0", GH_STUB_OUT='{"message":"Bad credentials"}'), "unavailable")
c("a conclusion that is not success is failure, whatever the word",
  ask(GH_STUB_RC="0",
      GH_STUB_OUT='[{"headSha":"%s","status":"completed","conclusion":"cancelled"}]' % sha),
  "failure")
c("one green and one red run on the tip is failure",
  ask(GH_STUB_RC="0",
      GH_STUB_OUT='[{"headSha":"%s","status":"completed","conclusion":"success"},'
                  '{"headSha":"%s","status":"completed","conclusion":"failure"}]' % (sha, sha)),
  "failure")
c("one green and one unconcluded run on the tip is pending",
  ask(GH_STUB_RC="0",
      GH_STUB_OUT='[{"headSha":"%s","status":"completed","conclusion":"success"},'
                  '{"headSha":"%s","status":"queued","conclusion":null}]' % (sha, sha)),
  "pending")
# Bounded: a gh that never answers costs one poll, not the watch.
c("a gh that hangs past the timeout is unavailable, not a wedged poll",
  ask(timeout=1, GH_STUB_RC="0", GH_STUB_SLEEP="5",
      GH_STUB_OUT='[{"headSha":"%s","status":"completed","conclusion":"success"}]' % sha),
  "unavailable")
os.environ.pop("GH_STUB_SLEEP", None)
# gh missing from PATH entirely - the one case a stub cannot be.
os.environ["PATH"] = empty
c("gh not on PATH at all is unavailable", ci_conclusion(repo, "audit-fixes", sha)[0],
  "unavailable")
sys.exit(bad)
PY
[ $? -eq 0 ] || fail=1
gh_unavailable

# ---------------------------------------------------------------------------
echo
echo "the 'local main moved' tripwire seeds on a new series instead of lying"
# ---------------------------------------------------------------------------
# watch_state.json outlives a series. Its main_sha is whatever `main` was
# during the PREVIOUS one, and `main` has legitimately moved since - the
# previous series' PR merged. Comparing against it made the first poll of a new
# series report a merge that happened before the watch was armed.
R4="$TMP/repo4"; mkdir -p "$R4"
git -C "$R4" init -q -b main
git -C "$R4" config user.email t@example.invalid
git -C "$R4" config user.name Selftest
cat > "$R4/WORKPLAN.md" <<'MD'
## 1. Batches

| # | Batch | Status | Est. calls |
|---|---|---|---|
| L3 | thing | todo | 20 |

## 4. Resume note

- nothing yet.

---
MD
git -C "$R4" add -A
git -C "$R4" commit -qm "base"
BASE4="$(git -C "$R4" rev-parse HEAD)"
git -C "$R4" checkout -q -b live-graphs
git -C "$R4" commit -q --allow-empty -m "chore: somewhere else to start from"
BASE4B="$(git -C "$R4" rev-parse HEAD)"
TD4="$TMP/tdir4"; mkdir -p "$TD4"
# "Resume WORKPLAN.md" is a builder prompt for any run, so the run number can
# be varied below without the derivation losing the transcript.
printf '{"type":"last-prompt","lastPrompt":"Resume WORKPLAN.md after the limit reset"}\n' \
  > "$TD4/44444444.jsonl"
ST4="$TMP/state4"; mkdir -p "$ST4"

run4() {  # run4 <run> <branch> <base> -> "<exit>|<event kinds>"
  local out rc
  out="$(SPANWEAVE_STATE_DIR="$ST4" SPANWEAVE_REPO="$R4" SPANWEAVE_TDIR="$TD4" \
         SPANWEAVE_PINNED="" SPANWEAVE_SELF="none.jsonl" \
         SPANWEAVE_BASE="$3" SPANWEAVE_BRANCH="$2" \
         SPANWEAVE_PIDS="" SPANWEAVE_BATCHES="L3" \
         "$OPS_DIR/watch_run.sh" --once --run "$1" 2>&1)"
  rc=$?
  printf '%s\n' "$out" > "$TMP/last_run4.txt"
  printf '%s|%s' "$rc" \
    "$(printf '%s\n' "$out" | sed -n -e 's/^>>> EVENT \(.*\)$/\1/p' | paste -sd, -)"
}
move_main() {  # a commit lands on local main, as a merged PR does
  git -C "$R4" checkout -q main
  git -C "$R4" commit -q --allow-empty -m "$1"
  git -C "$R4" checkout -q live-graphs
}
state4() {  # state4 <key>
  python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "")' \
    "$ST4/watch_state.json" "$1"
}
seeded_not_reported() {  # seeded_not_reported <case name> <expected main sha>
  grep -q "local main moved: " "$TMP/last_run4.txt" \
    && bad "$1: reported 'local main moved' on the first poll of a new series" \
    || ok "$1: no 'local main moved' on the first poll of a new series"
  grep -q "note: new watch series" "$TMP/last_run4.txt" \
    && ok "$1: the poll says it seeded main_sha and why" \
    || bad "$1: the seed is silent, so a reader cannot tell the tripwire is armed"
  check "$1: main_sha is seeded to the current value" "$(state4 main_sha)" "$2"
}

# (3) a first-ever poll, with no state at all, behaves as it always did.
run4 5 live-graphs "$BASE4" > /dev/null
grep -q "local main moved: " "$TMP/last_run4.txt" \
  && bad "a first-ever poll reported 'local main moved' against nothing" \
  || ok "a first-ever poll has nothing to compare and reports nothing"
check "a first-ever poll seeds main_sha" "$(state4 main_sha)" "$(git -C "$R4" rev-parse main)"
check "a first-ever poll records the series identity" "$(state4 series)" \
      "run=5 branch=live-graphs base=$BASE4"

# (1) a PR merges between series, then a new series is armed. The persisted
# main_sha is now a fact about the previous series only.
move_main "chore: the run-5 PR merged"
run4 6 live-graphs "$BASE4" > /dev/null
seeded_not_reported "a new run number" "$(git -C "$R4" rev-parse main)"

# (2) within that series, a genuine mid-watch move of main still fires.
move_main "reader: the builder landed this on main mid-watch"
check "a mid-watch move of main still fires the tripwire" \
      "$(run4 6 live-graphs "$BASE4")" "0|tripwire"
grep -q "local main moved: " "$TMP/last_run4.txt" \
  && ok "the mid-watch hit is the 'local main moved' one" \
  || bad "the mid-watch tripwire fired on something other than main moving"

# (4) each of the three arming facts is enough on its own to mean "new series".
move_main "chore: another PR merged between series"
run4 7 live-graphs "$BASE4" > /dev/null
seeded_not_reported "the run number alone" "$(git -C "$R4" rev-parse main)"
move_main "chore: and another"
run4 7 some-other-branch "$BASE4" > /dev/null
seeded_not_reported "the watched branch alone" "$(git -C "$R4" rev-parse main)"
move_main "chore: and one more"
run4 7 some-other-branch "$BASE4B" > /dev/null
seeded_not_reported "the base alone" "$(git -C "$R4" rev-parse main)"
# ...and having seeded, the same series compares again on the very next poll.
move_main "reader: landed on main inside the re-based series"
check "the re-based series arms from its second poll" \
      "$(run4 7 some-other-branch "$BASE4B")" "0|tripwire"
grep -q "local main moved: " "$TMP/last_run4.txt" \
  && ok "the second poll of a seeded series compares again" \
  || bad "the second poll of a seeded series is still seeding"

# ---------------------------------------------------------------------------
echo
echo "run-3 shapes - prefix-agnostic ids, and the rows the old regex could not see"
# ---------------------------------------------------------------------------
R3D="$TMP/repo3"; mkdir -p "$R3D"
cat > "$R3D/WORKPLAN.md" <<'MD'
## 1. Batch list

| # | Batch | Status | Est. calls |
|---|---|---|---|
| R1 | **Timestamps are finite and bounded.** Rule: a \| pipe \| in prose. | done (`0e4262e`) | 20 |
| R2 | Track the reviews. | done (`0284ec3`) | 8 |
| R3 | Stated timestamp units (HALT memo). | awaiting decision (`5697313`) | 6 |
| R7 | Series close, again. | awaiting R3 | 6 |

## 2. Execution order
MD
python3 - "$R3D" <<'PY'
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import is_running, is_stopped, workplan_statuses

st, raw, src = workplan_statuses(sys.argv[1])
bad = 0
def c(name, got, want):
    global bad
    if got == want: print("  PASS  %s" % name)
    else:
        print("  FAIL  %s\n        got : %r\n        want: %r" % (name, got, want)); bad = 1

c("R-prefixed rows are parsed at all", sorted(st), ["R1", "R2", "R3", "R7"])
c("an escaped pipe inside the row does not shift the status column",
  st["R1"], "done (`0e4262e`)")
c("`done (`sha`)` counts as stopped", is_stopped(st["R1"]), True)
c("`awaiting decision (`sha`)` counts as stopped", is_stopped(st["R3"]), True)
c("a dependency marker counts as stopped", is_stopped(st["R7"]), True)
c("`todo` is neither stopped nor running",
  (is_stopped("todo"), is_running("todo")), (False, False))
c("`in progress` is running", is_running("in progress"), True)
c("a stopped row is never also running", is_running(st["R1"]), False)
sys.exit(bad)
PY
[ $? -eq 0 ] || fail=1

# ---------------------------------------------------------------------------
echo
echo "rule (b) - a builder prompt need not use the literal phrase"
# ---------------------------------------------------------------------------
python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import is_builder_prompt

# The real run-3 arming prompt, which the old literal-phrase rule missed.
RUN3 = ("Apply ~/Downloads/run3-2026-09-11.md with one plan-only sub-agent "
        "(recreate WORKPLAN.md from git show c79cbc5:WORKPLAN.md, restore its "
        "README row, single commit plan: reopen for run 3 -- run-2 review findings)")
cases = [
    ("the literal phrase still matches", "Execute WORKPLAN.md run 2", 2, True),
    ("... and does not match another run", "Execute WORKPLAN.md run 2", 1, False),
    ("Resume matches any run", "Resume WORKPLAN.md after the limit reset", 9, True),
    ("a run3-dated file plus a WORKPLAN.md mention matches run 3", RUN3, 3, True),
    ("the same prompt is not a run-2 builder", RUN3, 2, False),
    ("run3 with no plan mention is not a builder prompt",
     "Apply ~/Downloads/run3-2026-09-11.md", 3, False),
    ("a plan mention with no run is not a builder prompt",
     "Review WORKPLAN.md commits since 02e9f6e", 3, False),
    ("run#3 and run 03 are operative forms",
     "WORKPLAN.md: see run#3 and run 03", 3, True),
    ("the hyphenated form alone is a citation, not a directive",
     "WORKPLAN.md: carry over the run-3 findings", 3, False),
    ("an empty prompt is not a builder prompt", "", 3, False),
    # Aux sessions name the plan and the run too. Once the literal-phrase rule
    # went, they became candidates: a run-2 check derived onto the cold
    # reviewer, over the builder. They are refused on their opening words.
    ("the cold reviewer is not a builder",
     "Cold review of run 2 of the spanweave audit series: commits c79cbc5..fcc842d "
     "on audit-fixes. The review protocol is \u00a70.2 of WORKPLAN.md", 2, False),
    ("the aux reviewer form is not a builder",
     "Review WORKPLAN.md commits since 02e9f6e", 2, False),
    ("a watcher arming itself is not a builder",
     "Set up and arm a read-only watch on the builder session running WORKPLAN.md run 2",
     2, False),
    ("a watcher re-arming itself is not a builder",
     "Consolidate the watch tooling in ~/spanweave-ops/ and re-arm. WORKPLAN.md run 2",
     2, False),
    ("the audit-reproduction form is not a builder",
     "Reproduce WORKPLAN.md audit for run 2", 2, False),
    # ... and the word that makes them aux appears in a real builder prompt too,
    # 150 characters in, which is why only the head of the prompt is matched.
    ("'review' late in a builder prompt does not make it aux", RUN3, 3, True),
]
bad = 0
for name, lp, run, want in cases:
    got = is_builder_prompt(lp, run)
    if got == want: print("  PASS  %s" % name)
    else: print("  FAIL  %s\n        got %r want %r" % (name, got, want)); bad = 1
sys.exit(bad)
PY
[ $? -eq 0 ] || fail=1

TD3="$TMP/tdir3"; mkdir -p "$TD3"
mk3() { printf '{"type":"last-prompt","lastPrompt":%s}\n' \
        "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$2")" > "$TD3/$1.jsonl"; }
mk3 351ac45a "Apply ~/Downloads/run3-2026-09-11.md with one plan-only sub-agent (recreate WORKPLAN.md from git show c79cbc5:WORKPLAN.md, single commit plan: reopen for run 3 -- run-2 review findings)"
mk3 bbbbbbbb "Resume WORKPLAN.md run 4"
mk3 ace03d5e "Yes: make all three watcher fixes. Batch <ID> of WORKPLAN.md. run 3 has already finished."

derive3() {  # derive3 <run> [session-id] -> "<name>|<how>|<rejected reasons>"
  SPANWEAVE_TDIR="$TD3" SPANWEAVE_RUN="$1" SPANWEAVE_PINNED="zzz.jsonl" \
  SPANWEAVE_SELF="" CLAUDE_CODE_SESSION_ID="${2:-}" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import config, derive_transcript
name, lp, cands, how, rej = derive_transcript(config())
print("%s|%s|%s" % (name, how, ";".join("%s:%s" % (n, w) for n, w in rej)))
PY
}

check "a prompt that names only another run is still rejected" \
      "$(derive3 4)" "bbbbbbbb.jsonl|derived|"
# With no live session id, the watcher's own transcript IS a candidate - its
# prompt names WORKPLAN.md and run 3 - and it is newer, so it wins. That is
# the self-derivation hazard the loosened rule creates, shown rather than
# asserted away.
check "without a session id the watcher does derive onto itself" \
      "$(derive3 3)" \
      "ace03d5e.jsonl|derived|bbbbbbbb.jsonl:lastPrompt names run 4, never run 3"
# CLAUDE_CODE_SESSION_ID is what closes it, and no static list could have -
# the list is written before the session exists.
check "the live session is excluded by CLAUDE_CODE_SESSION_ID, not by a static list" \
      "$(derive3 3 ace03d5e)" \
      "351ac45a.jsonl|derived|ace03d5e.jsonl:this watcher's own session file;bbbbbbbb.jsonl:lastPrompt names run 4, never run 3"
# The run-3 builder cites "run-2 review findings"; the old rule threw it out
# for the citation, which is how the watch ended up on the pin.
grep -q . /dev/null
check "a run cited in prose does not disqualify the builder that names its own run" \
      "$(derive3 3 ace03d5e | cut -d'|' -f1)" "351ac45a.jsonl"
got="$(derive3 3 351ac45a)"
case "$got" in
  351ac45a*) bad "the watcher derived onto its own session file" ;;
  *)         ok  "with the builder id as the live session, it is not chosen" ;;
esac

# ---------------------------------------------------------------------------
echo
echo "the base-time floor - a transcript older than the base is not the builder's"
# ---------------------------------------------------------------------------
# 2026-10-01: a run-3 watch of the `live-graphs` series derived onto
# 351ac45a-...jsonl - the SEPTEMBER audit series' run 3 - and reported that dead
# session's liveness, then `finished`. Run numbers are PER-SERIES, so every
# prompt predicate said yes; the file's own mtime was 2026-09-11 00:37 and its
# subagents/ 2026-09-10 17:09, twenty days before the base commit (ce9ff17,
# authored 2026-10-01 00:23:40) the watch was armed on. The real builder
# (1d41a6d1-...jsonl) was not a candidate at all: its stored lastPrompt is cut
# at ~200 characters and the only run number inside the cut is 2, so the phrase
# that named run 3 was never stored. One candidate, so it won outright - the
# (subagents, own) ordering never got a chance to prefer the newer session.
LP351='Apply ~/Downloads/run3-2026-09-11.md with one plan-only sub-agent (recreate WORKPLAN.md from git show c79cbc5:WORKPLAN.md, restore its README row, single commit plan: reopen for run 3 -- run-2 review…'
LP1D4='In ~/git/spanweave on live-graphs (tip 2cde61f), read WORKPLAN.md §0 in full. Apply patches/decisions-live-2026-09-30.md exactly as its header says: one plan-only sub-agent, one commit plan: run-2 rev…'

R7="$TMP/repo7"; mkdir -p "$R7"
git -C "$R7" init -q -b live-graphs
git -C "$R7" config user.email t@example.invalid
git -C "$R7" config user.name Selftest
# The real base's author time, to the second.
GIT_COMMITTER_DATE="2026-10-01 00:23:40 +0300" GIT_AUTHOR_DATE="2026-10-01 00:23:40 +0300" \
  git -C "$R7" commit -q --allow-empty -m "plan: reopen for run 3"
BASE7="$(git -C "$R7" rev-parse HEAD)"
# The same history with an earlier base, so the counter-check can move the floor
# instead of the prompt: author time is what the floor reads, and git is happy
# for a later commit to carry an earlier author date.
GIT_COMMITTER_DATE="2026-10-01 00:30:00 +0300" GIT_AUTHOR_DATE="2026-09-01 00:00:00 +0300" \
  git -C "$R7" commit -q --allow-empty -m "chore: authored in September"
BASE7EARLY="$(git -C "$R7" rev-parse HEAD)"

mkT() {  # mkT <dir> <uuid> <lastPrompt>
  mkdir -p "$1"
  printf '{"type":"last-prompt","lastPrompt":%s}\n' \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$3")" > "$1/$2.jsonl"
}
deriveF() {  # deriveF <tdir> <base> <run> [pin] -> "<name>|<how>"; rejected rows to $TMP/derF.txt
  SPANWEAVE_REPO="$R7" SPANWEAVE_TDIR="$1" SPANWEAVE_BASE="$2" SPANWEAVE_RUN="$3" \
  SPANWEAVE_PINNED="${4:-}" SPANWEAVE_SELF="" CLAUDE_CODE_SESSION_ID="" python3 - <<'PY' > "$TMP/derF.txt"
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import config, derive_transcript
name, lp, cands, how, rej = derive_transcript(config())
print("%s|%s" % (name, how))
for n, w in rej:
    print("rejected %s  %s" % (n, w))
PY
  head -1 "$TMP/derF.txt"
}

# (1) the prompt is a perfectly good run-3 builder prompt. That is the point:
#     the floor is not a second opinion about the prompt.
check "the September run-3 prompt is still a builder prompt for run 3" \
      "$(SPANWEAVE_RUN=3 python3 -c '
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import is_builder_prompt
print(is_builder_prompt(sys.argv[1], 3))' "$LP351")" "True"

TD7="$TMP/tdir7"; mkT "$TD7" 351ac45a "$LP351"
mkdir -p "$TD7/351ac45a/subagents"; : > "$TD7/351ac45a/subagents/a.jsonl"
touch -d '2026-09-10 17:09:59' "$TD7/351ac45a/subagents/a.jsonl" "$TD7/351ac45a/subagents"
touch -d '2026-09-11 00:37:31' "$TD7/351ac45a.jsonl"
check "a transcript last written before the base is refused, prompt and all" \
      "$(deriveF "$TD7" "$BASE7" 3)" "None|none (older than base)"
grep -q 'rejected 351ac45a.jsonl .*2026-09-11 00:37:31.*predates the base' "$TMP/derF.txt" \
  && ok "the rejection names the transcript's last write" \
  || bad "the rejection does not name the transcript's last write"
grep -q "predates the base commit's author time 2026-10-01 00:23:40" "$TMP/derF.txt" \
  && ok "the rejection names the base commit's author time too" \
  || bad "the rejection does not name the base commit's author time"

# (2) the counter-check: move the floor, not the prompt, and the same file wins.
check "the same transcript is accepted against a base authored before it" \
      "$(deriveF "$TD7" "$BASE7EARLY" 3)" "351ac45a.jsonl|derived"

# (3) a pin is an operator override and is not floor-tested, exactly as it is
#     not re-tested against the run number.
check "a pin is honoured without being floor-tested" \
      "$(deriveF "$TD7" "$BASE7" 3 351ac45a.jsonl)" "351ac45a.jsonl|pin (no candidate)"

# (4) both mtimes are consulted. "Last write" is the NEWER of the transcript's
#     own mtime and its subagents/ dir mtime, which is the reading least likely
#     to exclude a live builder whose own file has not flushed yet.
TD7B="$TMP/tdir7b"; mkT "$TD7B" dddddddd "Resume WORKPLAN.md run 3"
mkdir -p "$TD7B/dddddddd/subagents"; : > "$TD7B/dddddddd/subagents/a.jsonl"
touch -d '2026-09-20 00:00:00' "$TD7B/dddddddd.jsonl"
touch -d '2026-10-01 10:00:00' "$TD7B/dddddddd/subagents/a.jsonl" "$TD7B/dddddddd/subagents"
check "an old own mtime with a subagents/ dir newer than base is kept" \
      "$(deriveF "$TD7B" "$BASE7" 3)" "dddddddd.jsonl|derived"
touch -d '2026-09-20 00:00:00' "$TD7B/dddddddd/subagents/a.jsonl" "$TD7B/dddddddd/subagents"
check "with the subagents/ dir old too, the same transcript is refused" \
      "$(deriveF "$TD7B" "$BASE7" 3)" "None|none (older than base)"

# (5) the real builder's prompt does not name run 3 - the run number lay beyond
#     the 200-char cap - but its last write is newer than the base, and it is
#     the only such transcript here. The floor, read forwards, derives it.
TD7C="$TMP/tdir7c"; mkT "$TD7C" 1d41a6d1 "$LP1D4"
touch -d '2026-10-01 15:49:31' "$TD7C/1d41a6d1.jsonl"
check "the real builder, named by no prompt, is derived by the floor instead" \
      "$(deriveF "$TD7C" "$BASE7" 3)" "1d41a6d1.jsonl|derived by floor, not by run number"
grep -q 'rejected 1d41a6d1.jsonl' "$TMP/derF.txt" \
  && bad "the chosen transcript is also listed as refused" \
  || ok "the chosen transcript is no longer listed as refused"

# (6) both present: the September session is refused by the floor and the real
#     builder is derived by it. That is the whole 2026-10-01 drift in one list,
#     ending in the right file rather than in exit 2.
TD7D="$TMP/tdir7d"; mkT "$TD7D" 351ac45a "$LP351"; mkT "$TD7D" 1d41a6d1 "$LP1D4"
touch -d '2026-09-11 00:37:31' "$TD7D/351ac45a.jsonl"
touch -d '2026-10-01 15:49:31' "$TD7D/1d41a6d1.jsonl"
check "the September session loses to the real builder, by date not by prompt" \
      "$(deriveF "$TD7D" "$BASE7" 3)" "1d41a6d1.jsonl|derived by floor, not by run number"
grep -q 'rejected 351ac45a.jsonl .*predates the base' "$TMP/derF.txt" \
  && ok "the September session is still refused, and still says why" \
  || bad "the September session's floor rejection is gone from the list"

# ---------------------------------------------------------------------------
echo
echo "the floor read forwards - exactly one post-base transcript is an answer"
# ---------------------------------------------------------------------------
# 2026-10-02, run 5 of the live-graphs series: L23 landed and was pushed, L24
# was in flight with a sub-agent live, and no transcript in the directory named
# run 5. The builder was the session told to apply the *run-4* review
# decisions - it made the base commit itself and rolled straight on into run 5
# without a new prompt - so its stored lastPrompt names run 4, cut at the
# 200-char cap. Both entry points said "no builder transcript found for run 5"
# and exited 2, about a run whose builder was alive and was the only session in
# the directory written since the base.
#
# So the floor is read forwards as well as backwards: a run number is a fact
# about *some* run, while "written since this run's base commit" is a fact
# about this one. Exactly one such transcript is an answer; two are not.
R9="$TMP/repo9"; mkdir -p "$R9"
git -C "$R9" init -q -b live-graphs
git -C "$R9" config user.email t@example.invalid
git -C "$R9" config user.name Selftest
cat > "$R9/WORKPLAN.md" <<'MD'
## 1. Batches

| # | Batch | Status | Est. calls |
|---|---|---|---|
| L23 | thing | done (`aaaaaaa`) | 20 |
| L24 | thing | todo | 15 |

## 4. Resume note

- L23 done.

---
MD
git -C "$R9" add -A
GIT_COMMITTER_DATE='2026-10-02 12:30:20' GIT_AUTHOR_DATE='2026-10-02 12:30:20' \
  git -C "$R9" commit -qm "plan: run-4 review decided, run 5 closes the series"
BASE9="$(git -C "$R9" rev-parse HEAD)"
git init -q --bare "$TMP/remote9.git"
git -C "$R9" remote add origin "$TMP/remote9.git"
git -C "$R9" push -q origin live-graphs

# The real shape: a prompt that is about the plan, is not an aux prompt, names
# run 4 operatively and is cut at the cap, so no later "run 5" was stored.
LPRUN4='In ~/git/spanweave on live-graphs (tip e2df391), read WORKPLAN.md §0 in full. Apply patches/decisions-live-2026-10-02.md exactly as its header says: one plan-only sub-agent, one commit plan: run-4 rev…'

der9() {  # der9 <tdir> <run> [pin] -> "<name>|<how>"; rejected rows to $TMP/der9.txt
  SPANWEAVE_REPO="$R9" SPANWEAVE_TDIR="$1" SPANWEAVE_BASE="$BASE9" SPANWEAVE_RUN="$2" \
  SPANWEAVE_PINNED="${3:-}" SPANWEAVE_SELF="" CLAUDE_CODE_SESSION_ID="" python3 - <<'PY' > "$TMP/der9.txt"
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import config, derive_transcript
name, lp, cands, how, rej = derive_transcript(config())
print("%s|%s" % (name, how))
for n, w in rej:
    print("rejected %s  %s" % (n, w))
PY
  head -1 "$TMP/der9.txt"
}

# (1) exactly one post-base, plan-shaped, non-aux transcript: derive it, and
#     say which rule chose it.
TD9="$TMP/tdir9"; mkT "$TD9" 7c13afaf "$LPRUN4"
touch -d '2026-10-02 12:44:04' "$TD9/7c13afaf.jsonl"
check "no prompt names run 5, so the only post-base transcript is derived" \
      "$(der9 "$TD9" 5)" "7c13afaf.jsonl|derived by floor, not by run number"
printf '%s\n' "$(der9 "$TD9" 5)" | grep -q '^7c13afaf.jsonl|derived' \
  && ok "the how it reports still begins with 'derived'" \
  || bad "the how it reports does not begin with 'derived'"

# (2) a session that predates the base is not in the pool at all: the floor
#     still refuses it backwards, which is what makes one answer *one*.
mkT "$TD9" 351ac45a "$LP351"
touch -d '2026-09-11 00:37:31' "$TD9/351ac45a.jsonl"
check "a pre-base session does not join the pool and does not make it ambiguous" \
      "$(der9 "$TD9" 5)" "7c13afaf.jsonl|derived by floor, not by run number"

# (3) an aux prompt is never in the pool, however recent. This is the guard
#     that keeps a reviewer or a watcher out: the pool drops the run-number
#     test, so the aux test is the only thing left standing between the
#     derivation and a session that was told to *report* on the run.
mkT "$TD9" 29d210c7 "Review WORKPLAN.md run 5 commits since the base, report only"
touch -d '2026-10-02 12:45:00' "$TD9/29d210c7.jsonl"
check "an aux prompt newer than the base is still not in the pool" \
      "$(der9 "$TD9" 5)" "7c13afaf.jsonl|derived by floor, not by run number"

# (4) a transcript that says nothing about the plan is not in the pool either.
mkT "$TD9" eeeeeeee "Fix the flaky test in tests/test_ids.py and push"
touch -d '2026-10-02 12:46:00' "$TD9/eeeeeeee.jsonl"
check "a post-base transcript that is not about the plan is not in the pool" \
      "$(der9 "$TD9" 5)" "7c13afaf.jsonl|derived by floor, not by run number"

# (5) the watcher's own session is excluded from the pool as it is from the
#     candidates - it is about the plan, it is newer than the base, and it is
#     not the builder.
TD9S="$TMP/tdir9s"; mkT "$TD9S" 7c13afaf "$LPRUN4"
mkT "$TD9S" a5a21da0 "First, in ~/spanweave-ops at its tip, one commit with selftests, push: a run whose last batch deletes WORKPLAN.md ends with no rows to read — when WORKPLAN.md was present at --base…"
touch -d '2026-10-02 12:44:04' "$TD9S/7c13afaf.jsonl"
touch -d '2026-10-02 12:47:00' "$TD9S/a5a21da0.jsonl"
check "this watcher's own post-base session is not in the pool" \
      "$(SPANWEAVE_REPO="$R9" SPANWEAVE_TDIR="$TD9S" SPANWEAVE_BASE="$BASE9" \
         SPANWEAVE_RUN=5 SPANWEAVE_PINNED="" SPANWEAVE_SELF="" \
         CLAUDE_CODE_SESSION_ID="a5a21da0" python3 -c '
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import config, derive_transcript
name, lp, cands, how, rej = derive_transcript(config())
print("%s|%s" % (name, how))')" \
      "7c13afaf.jsonl|derived by floor, not by run number"

# (6) two of them is not an answer. Both are named, because the fix is for the
#     operator to pin one - and guessing the newest would be the 2026-10-01
#     drift with a new cause.
TD9B="$TMP/tdir9b"; mkT "$TD9B" 7c13afaf "$LPRUN4"
mkT "$TD9B" fdd33f45 'In ~/git/spanweave on live-graphs (tip 3ab6638), read WORKPLAN.md §0 in full. Apply patches/decisions-live-2026-10-03.md exactly as its header says: one plan-only sub-agent, one commit plan: run-6 rev…'
touch -d '2026-10-02 12:44:04' "$TD9B/7c13afaf.jsonl"
touch -d '2026-10-02 12:45:04' "$TD9B/fdd33f45.jsonl"
check "two post-base candidates are not an answer: nothing is derived" \
      "$(der9 "$TD9B" 5)" "None|none (two or more clear the floor)"
check "both are listed, by name" \
      "$(grep -c -e 'rejected 7c13afaf.jsonl .*floor cannot pick between them' \
                 -e 'rejected fdd33f45.jsonl .*floor cannot pick between them' "$TMP/der9.txt")" \
      "2"
grep -q 'SPANWEAVE_PINNED=<uuid>.jsonl' "$TMP/der9.txt" \
  && ok "the ambiguity says how to resolve it" \
  || bad "the ambiguity does not say how to resolve it"

# (7) an operator pin still outranks the floor - it outranks the run number
#     already, and an operator who names a file has said something the
#     watcher's evidence cannot outvote.
check "a pin outranks the ambiguity" \
      "$(der9 "$TD9B" 5 fdd33f45.jsonl)" "fdd33f45.jsonl|pin (no candidate)"
check "a pin outranks a floor derivation too" \
      "$(der9 "$TD9" 5 351ac45a.jsonl)" "351ac45a.jsonl|pin (no candidate)"

# (8) a prompt that DOES name the run still wins, and the near-miss keeps its
#     own rejection: the fallback is a fallback, not a replacement.
TD9C="$TMP/tdir9c"; mkT "$TD9C" 7c13afaf "$LPRUN4"
mkT "$TD9C" cccccccc "Resume WORKPLAN.md run 5"
touch -d '2026-10-02 12:44:04' "$TD9C/7c13afaf.jsonl"
touch -d '2026-10-02 12:40:00' "$TD9C/cccccccc.jsonl"
check "a prompt that names the run beats the newer post-base one" \
      "$(der9 "$TD9C" 5)" "cccccccc.jsonl|derived"
grep -q 'rejected 7c13afaf.jsonl .*names no operative run 5 (names run 4).*truncated at the stored cap' \
     "$TMP/der9.txt" \
  && ok "the near miss still names the truncation and the run it does name" \
  || bad "the near miss lost its truncation rejection"

# (9) with no readable base author time the floor has said nothing, so the
#     fallback is unavailable: "clears the floor" would mean "exists".
check "an unreadable base leaves the fallback unavailable, not permissive" \
      "$(SPANWEAVE_REPO="$R9" SPANWEAVE_TDIR="$TD9" SPANWEAVE_BASE="deadbeef" \
         SPANWEAVE_RUN=5 SPANWEAVE_PINNED="" SPANWEAVE_SELF="" \
         CLAUDE_CODE_SESSION_ID="" python3 -c '
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import config, derive_transcript
name, lp, cands, how, rej = derive_transcript(config())
print("%s|%s" % (name, how))')" \
      "None|none"

# (10) the verdict reads a floor derivation as a visible builder. It is a
#      weaker warrant for *which file*, not weaker evidence that a session is
#      there - and reading it as "no transcript" would report a live builder
#      mid-batch as `not started`.
python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import HOW_FLOOR_DERIVED, verdict
B = ["L23", "L24"]
bad = 0
cases = [
    ("a live floor-derived builder with no plan commit is applying plan",
     verdict({b: "todo" for b in B}, "worktree", B, HOW_FLOOR_DERIVED, 60, False,
             False, False, [], head_past_base=False)[0], "applying plan"),
    ("a quiet floor-derived builder that declared nothing is unclear, not 'not started'",
     verdict({b: "todo" for b in B}, "worktree", B, HOW_FLOOR_DERIVED, 3600, True,
             False, False, [])[0], "unclear"),
]
for name, got, want in cases:
    if got == want: print("  PASS  %s" % name)
    else: print("  FAIL  %s\n        got %r want %r" % (name, got, want)); bad = 1
sys.exit(bad)
PY
[ $? -eq 0 ] || fail=1

# (11) end to end in both entry points: the banner says which rule chose the
#      file, the report says it in the transcript section, and the ambiguity is
#      a watcher error in both - with both files named.
TD9="$TD9" ; ST9="$TMP/state9"; mkdir -p "$ST9"
out="$(SPANWEAVE_STATE_DIR="$ST9" SPANWEAVE_REPO="$R9" SPANWEAVE_TDIR="$TD9" \
       SPANWEAVE_BASE="$BASE9" SPANWEAVE_BRANCH=live-graphs \
       SPANWEAVE_SELF="" CLAUDE_CODE_SESSION_ID="" \
       SPANWEAVE_PIDS="" SPANWEAVE_BATCHES="L23 L24" \
       "$OPS_DIR/watch_run.sh" --once --run 5 2>&1)"
printf '%s\n' "$out" | grep -q "^poll .*<-- derived by floor, not by run number" \
  && ok "the poll banner says it was derived by floor, not by run number" \
  || bad "the poll banner does not say how the transcript was derived"

sout="$(SPANWEAVE_REPO="$R9" SPANWEAVE_TDIR="$TD9" SPANWEAVE_BASE="$BASE9" \
        SPANWEAVE_BRANCH=live-graphs SPANWEAVE_SELF="" CLAUDE_CODE_SESSION_ID="" \
        SPANWEAVE_PIDS="" \
        "$OPS_DIR/status_check.sh" --run 5 --batches "L23 L24" 2>&1)"
printf '%s\n' "$sout" | grep -q "chosen     : 7c13afaf.jsonl  \[derived by floor, not by run number\]" \
  && ok "the report names the rule that chose the transcript" \
  || bad "the report does not name the rule that chose the transcript"
printf '%s\n' "$sout" | grep -q "no prompt named run 5" \
  && ok "the report says why the floor had to choose" \
  || bad "the report does not say why the floor had to choose"

rm -rf "$ST9"; mkdir -p "$ST9"
out="$(SPANWEAVE_STATE_DIR="$ST9" SPANWEAVE_REPO="$R9" SPANWEAVE_TDIR="$TD9B" \
       SPANWEAVE_BASE="$BASE9" SPANWEAVE_BRANCH=live-graphs \
       SPANWEAVE_SELF="" CLAUDE_CODE_SESSION_ID="" \
       SPANWEAVE_PIDS="" SPANWEAVE_BATCHES="L23 L24" \
       "$OPS_DIR/watch_run.sh" --once --run 5 2>&1)"
check "two post-base candidates are a watcher error in the watch (exit 2)" "$?" "2"
printf '%s\n' "$out" | grep -q "7c13afaf.jsonl" && printf '%s\n' "$out" | grep -q "fdd33f45.jsonl" \
  && ok "the watcher error names both transcripts" \
  || bad "the watcher error does not name both transcripts"

SPANWEAVE_REPO="$R9" SPANWEAVE_TDIR="$TD9B" SPANWEAVE_BASE="$BASE9" \
SPANWEAVE_BRANCH=live-graphs SPANWEAVE_SELF="" CLAUDE_CODE_SESSION_ID="" \
SPANWEAVE_PIDS="" "$OPS_DIR/status_check.sh" --run 5 --batches "L23 L24" \
  > "$TMP/sc9b.txt" 2>&1
check "two post-base candidates are a watcher error in the report (exit 2)" "$?" "2"
grep -c -e '7c13afaf.jsonl' -e 'fdd33f45.jsonl' "$TMP/sc9b.txt" >/dev/null \
  && grep -q 'floor cannot pick between them' "$TMP/sc9b.txt" \
  && ok "the report names both and says how to resolve it" \
  || bad "the report does not name both candidates"

# ---------------------------------------------------------------------------
echo
echo "no transcript newer than base - liveness is unknown, and the stall says so"
# ---------------------------------------------------------------------------
R8="$TMP/repo8"; mkdir -p "$R8"
git -C "$R8" init -q -b live-graphs
git -C "$R8" config user.email t@example.invalid
git -C "$R8" config user.name Selftest
cat > "$R8/WORKPLAN.md" <<'MD'
## 1. Batches

| # | Batch | Status | Est. calls |
|---|---|---|---|
| L9 | thing | todo | 20 |

## 4. Resume note

- nothing yet.

---
MD
git -C "$R8" add -A
GIT_COMMITTER_DATE="$(date -d '-90 min' -R)" GIT_AUTHOR_DATE="$(date -d '-90 min' -R)" \
  git -C "$R8" commit -qm "base"
BASE8="$(git -C "$R8" rev-parse HEAD)"
git init -q --bare "$TMP/remote8.git"
git -C "$R8" remote add origin "$TMP/remote8.git"
git -C "$R8" push -q origin live-graphs
# Nothing has landed for 85 minutes. With liveness unknown, THIS and the index
# mtime are the whole stall rule.
GIT_COMMITTER_DATE="$(date -d '-85 min' -R)" GIT_AUTHOR_DATE="$(date -d '-85 min' -R)" \
  git -C "$R8" commit -q --allow-empty -m "chore: nothing since"

TD8="$TMP/tdir8"
# A September builder, exactly the 351ac45a shape, weeks older than the base.
mkT "$TD8" 351ac45a "$LP351"
touch -d '2026-09-11 00:37:31' "$TD8/351ac45a.jsonl"
# An aux session that is NOT a candidate at any date - the decoy whose mtime
# moves below, to prove a transcript the watch is not watching cannot resume it.
mkT "$TD8" 29d210c7 "Review WORKPLAN.md run 3 commits since the base"
ST8="$TMP/state8"; mkdir -p "$ST8"
INDEX_AT8="$(date -d '-90 min' '+%Y-%m-%d %H:%M:%S')"

run8() {  # run8 [pin] [state-dir] -> "<exit>|<event kinds>"
  local out rc
  touch -d "$INDEX_AT8" "$R8/.git/index"
  out="$(SPANWEAVE_STATE_DIR="${2:-$ST8}" SPANWEAVE_REPO="$R8" SPANWEAVE_TDIR="$TD8" \
         SPANWEAVE_PINNED="${1:-}" SPANWEAVE_SELF="" CLAUDE_CODE_SESSION_ID="" \
         SPANWEAVE_BASE="$BASE8" SPANWEAVE_BRANCH=live-graphs \
         SPANWEAVE_PIDS="" SPANWEAVE_BATCHES="L9" \
         "$OPS_DIR/watch_run.sh" --once --run 3 2>&1)"
  rc=$?
  printf '%s\n' "$out" > "$TMP/last_run8.txt"
  printf '%s|%s' "$rc" \
    "$(printf '%s\n' "$out" | sed -n -e 's/^>>> EVENT \(.*\)$/\1/p' \
                                    -e 's/^>>> LINE \(RESUMED\).*$/\1/p' | paste -sd, -)"
}

check "no candidate newer than base is not a watcher error: the stall fires" \
      "$(run8)" "0|stall"
grep -q '^poll .*| liveness: unknown (no transcript newer than base) |' "$TMP/last_run8.txt" \
  && ok "the banner says liveness is unknown instead of printing an age" \
  || bad "the banner does not say liveness is unknown"
grep -qE '^poll .*liveness (2026|[0-9]{4}-)' "$TMP/last_run8.txt" \
  && bad "the banner still prints a liveness timestamp" \
  || ok "the banner prints no borrowed liveness timestamp"
grep -q '(0.0 min ago)' "$TMP/last_run8.txt" \
  && bad "the output invents a 0.0 min age" || ok "the output invents no age"
grep -q 'arming: liveness is unknown for base' "$TMP/last_run8.txt" \
  && ok "arming says liveness is unknown for this base" \
  || bad "arming does not say liveness is unknown"
grep -q 'the stall rule runs on the commit and .git/index times alone' "$TMP/last_run8.txt" \
  && ok "arming says what the stall rule runs on instead" \
  || bad "arming does not say what the stall rule runs on"
grep -q 'it is excluded from the rule - it neither armed' "$TMP/last_run8.txt" \
  && ok "the stall block says liveness is excluded, not quiet" \
  || bad "the stall block does not say liveness is excluded"
grep -q 'refused: 351ac45a.jsonl .*predates the base' "$TMP/last_run8.txt" \
  && ok "the evidence block shows the near miss rather than hiding it" \
  || bad "the evidence block hides the refused transcript"

check "the stall is suppressed on the same schedule as a normal one" \
      "$(run8)" "0|"
# A transcript moving on disk while liveness is unknown is not a resume: the
# watch is not watching one, so there is nothing for it to have moved.
touch "$TD8/29d210c7.jsonl"
check "a liveness-only movement emits no RESUMED while liveness is unknown" \
      "$(run8)" "0|"
python3 - "$ST8/watch_state.json" <<'PY'
import json, sys, time
st = json.load(open(sys.argv[1]))
if "stall" not in st:
    print("  FAIL  no stall record to age in the unknown-liveness state"); sys.exit(1)
st["stall"]["fired_at"] = time.time() - 41 * 60
json.dump(st, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
[ $? -eq 0 ] || fail=1
check "and it repeats after a further 40 min, like a normal stall" \
      "$(run8)" "0|stall"
grep -q 'TRIGGER: stall (still,' "$TMP/last_run8.txt" \
  && ok "the repeat says it is a repeat" || bad "the repeat does not say so"

# A pin overrides the floor, so liveness becomes observable again - the ancient
# timestamp is printed as what it is, not hidden and not called unknown.
ST8B="$TMP/state8b"; mkdir -p "$ST8B"
check "a pin is still honoured, and liveness stops being unknown" \
      "$(run8 351ac45a.jsonl "$ST8B")" "0|stall"
grep -q 'liveness 2026-09-11 00:37:31' "$TMP/last_run8.txt" \
  && ok "the pinned watch prints the pinned transcript's real liveness" \
  || bad "the pinned watch does not print the pinned transcript's liveness"
grep -q 'liveness: unknown' "$TMP/last_run8.txt" \
  && bad "the pinned watch still calls liveness unknown" \
  || ok "the pinned watch does not call liveness unknown"

# ---------------------------------------------------------------------------
echo
echo "pendingBackgroundAgentCount comes from the chosen transcript and no other"
# ---------------------------------------------------------------------------
# It feeds `batch_running` in the stall rule and the in-flight verdict, so a
# count read from a second transcript would report another session's sub-agent
# as this run's activity - and would suppress a stall on evidence about a
# session the watch is not watching.
TD9="$TMP/tdir9"; mkdir -p "$TD9"
mkT9() {  # mkT9 <uuid> <lastPrompt> <pendingBackgroundAgentCount>
  { printf '{"type":"last-prompt","lastPrompt":%s}\n' \
      "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$2")"
    printf '{"type":"system","timestamp":"2026-10-01T12:00:00.000Z","content":"ok","pendingBackgroundAgentCount":%s}\n' "$3"
  } > "$TD9/$1.jsonl"
}
mkT9 11111111 "Resume WORKPLAN.md run 3" 0
# Newer, and loudly claiming an outstanding sub-agent - but an aux prompt, so
# never a candidate. If a count ever leaked across transcripts, it would be 7.
mkT9 29d210c7 "Review WORKPLAN.md run 3 commits since the base" 7
ST9="$TMP/state9"; mkdir -p "$ST9"
out9="$(SPANWEAVE_STATE_DIR="$ST9" SPANWEAVE_REPO="$R8" SPANWEAVE_TDIR="$TD9" \
        SPANWEAVE_PINNED="" SPANWEAVE_SELF="" CLAUDE_CODE_SESSION_ID="" \
        SPANWEAVE_BASE="$BASE8" SPANWEAVE_BRANCH=live-graphs \
        SPANWEAVE_PIDS="" SPANWEAVE_BATCHES="L9" \
        "$OPS_DIR/watch_run.sh" --once --run 3 2>&1)"
check "the watch derives onto the builder, not the newer aux session" \
      "$(printf '%s\n' "$out9" | sed -n 's/^poll .*watching \([^ |]*\).*/\1/p')" \
      "11111111.jsonl"
check "the banner reports the chosen transcript's count, not the decoy's" \
      "$(printf '%s\n' "$out9" | sed -n 's/^poll .*pendingBackgroundAgentCount=\([^ |]*\).*/\1/p')" \
      "0"
sout9="$(SPANWEAVE_REPO="$R8" SPANWEAVE_TDIR="$TD9" \
         SPANWEAVE_PINNED="" SPANWEAVE_SELF="" CLAUDE_CODE_SESSION_ID="" \
         SPANWEAVE_BASE="$BASE8" SPANWEAVE_BRANCH=live-graphs SPANWEAVE_PIDS="" \
         "$OPS_DIR/status_check.sh" --run 3 --batches "L9" 2>&1)"
check "the status report reads it from the chosen transcript too" \
      "$(printf '%s\n' "$sout9" | sed -n 's/^ *pendingBackgroundAgentCount: //p')" "0"

# ---------------------------------------------------------------------------
echo
echo "the memo tripwire counts declarations, not citations"
# ---------------------------------------------------------------------------
R4D="$TMP/repo4"; mkdir -p "$R4D"
git -C "$R4D" init -q -b audit-fixes
git -C "$R4D" config user.email t@example.invalid
git -C "$R4D" config user.name Selftest
cat > "$R4D/WORKPLAN.md" <<'MD'
## 1. Batch list

| # | Batch | Status | Est. calls |
|---|---|---|---|
| R1 | thing | todo | 20 |
| R3 | memo | todo | 6 |

## 4. Resume note

- nothing yet.

---
MD
git -C "$R4D" add -A && git -C "$R4D" commit -qm "base"
BASE4="$(git -C "$R4D" rev-parse HEAD)"
git init -q --bare "$TMP/remote4.git"
git -C "$R4D" remote add origin "$TMP/remote4.git"
git -C "$R4D" push -q origin audit-fixes

TD4="$TMP/tdir4"; mkdir -p "$TD4"; ST4="$TMP/state4"; mkdir -p "$ST4"
printf '{"type":"last-prompt","lastPrompt":"Execute WORKPLAN.md run 3"}\n' > "$TD4/44444444.jsonl"

run4() {
  local out rc
  out="$(SPANWEAVE_STATE_DIR="$ST4" SPANWEAVE_REPO="$R4D" SPANWEAVE_TDIR="$TD4" \
         SPANWEAVE_PINNED="44444444.jsonl" SPANWEAVE_SELF="" CLAUDE_CODE_SESSION_ID="" \
         SPANWEAVE_BASE="$BASE4" SPANWEAVE_BRANCH=audit-fixes \
         SPANWEAVE_PIDS="" SPANWEAVE_BATCHES="R1 R3" SPANWEAVE_MEMO="R3" \
         "$OPS_DIR/watch_run.sh" --once --run 3 2>&1)"
  rc=$?
  printf '%s\n' "$out" > "$TMP/last_run4.txt"
  printf '%s|%s' "$rc" \
    "$(printf '%s\n' "$out" | sed -n 's/^>>> EVENT \(.*\)$/\1/p' | paste -sd, -)"
}

mkdir -p "$R4D/spanweave" && echo x > "$R4D/spanweave/model.py"
git -C "$R4D" add -A
git -C "$R4D" commit -q -F - <<'MSG'
model: a timestamp keeps the digits the record wrote

Batch R1 of WORKPLAN.md. R3 is the memo that will decide stated units; this
commit does not pre-empt it, and F1 already settled the envelope question.
MSG
check "citing the memo batch while touching spanweave/ does not trip" "$(run4)" "0|"

echo y > "$R4D/spanweave/model.py"
git -C "$R4D" add -A
git -C "$R4D" commit -q -F - <<'MSG'
model: implement the memo

Batch R3 of WORKPLAN.md. This one really does touch the core.
MSG
check "declaring the memo batch while touching spanweave/ does trip" "$(run4)" "0|tripwire"
grep -q "declaring memo-only batch(es) R3" "$TMP/last_run4.txt" \
  && ok "the block names the declared memo batch" \
  || bad "the block does not name the declared memo batch"

# ---------------------------------------------------------------------------
echo
echo "an operator-given --base outranks the baseline a previous run persisted"
# ---------------------------------------------------------------------------
# Run 5's first poll scanned `fcc842d..HEAD` instead of the `b091904..HEAD` it
# was given: `last_seen_head` from run 4 was consulted first, so every commit
# between the two was never examined.  The fixture reproduces exactly that
# shape - an offending commit sitting between the given base and the stale
# persisted head - and pins both halves of the rule.
R5D="$TMP/repo5"; mkdir -p "$R5D"
git -C "$R5D" init -q -b audit-fixes
git -C "$R5D" config user.email t@example.invalid
git -C "$R5D" config user.name Selftest
cat > "$R5D/WORKPLAN.md" <<'MD'
## 1. Batch list

| # | Batch | Status | Est. calls |
|---|---|---|---|
| S1 | thing | todo | 20 |
| S2 | thing | todo | 15 |

## 4. Resume note

- nothing yet.

---
MD
git -C "$R5D" add -A && git -C "$R5D" commit -qm "base"
BASE5="$(git -C "$R5D" rev-parse HEAD)"
git init -q --bare "$TMP/remote5.git"
git -C "$R5D" remote add origin "$TMP/remote5.git"
git -C "$R5D" push -q origin audit-fixes

# The commit the stale baseline hides: offending, and between base and stale.
git -C "$R5D" commit -q --allow-empty -F - <<'MSG'
reader: something before the stale baseline

Batch Z9 of WORKPLAN.md. Not in the run-5 list.
MSG
STALE5="$(git -C "$R5D" rev-parse HEAD)"      # the run-4-tail analogue
git -C "$R5D" commit -q --allow-empty -m "chore: after the stale baseline"

TD5="$TMP/tdir5"; mkdir -p "$TD5"; ST5="$TMP/state5"; mkdir -p "$ST5"
printf '{"type":"last-prompt","lastPrompt":"Execute WORKPLAN.md run 5"}\n' > "$TD5/55555555.jsonl"

seed5() {  # persist a baseline that is AHEAD of the base the operator gives
  python3 - "$ST5/watch_state.json" "$STALE5" <<'PYSEED'
import json, sys
json.dump({"last_seen_head": sys.argv[2], "reported_commits": [],
           "reported_conditions": {}, "run": 5},
          open(sys.argv[1], "w"), indent=2, sort_keys=True)
PYSEED
}

run5() {  # run5 [anything] -> "<exit>|<event kinds>"; with no argument, no --base
  local out rc
  out="$(SPANWEAVE_STATE_DIR="$ST5" SPANWEAVE_REPO="$R5D" SPANWEAVE_TDIR="$TD5" \
         SPANWEAVE_PINNED="55555555.jsonl" SPANWEAVE_SELF="" CLAUDE_CODE_SESSION_ID="" \
         SPANWEAVE_BRANCH=audit-fixes SPANWEAVE_PIDS="" SPANWEAVE_BATCHES="S1 S2" \
         SPANWEAVE_MEMO="" \
         "$OPS_DIR/watch_run.sh" --once --run 5 ${1:+--base "$BASE5"} 2>&1)"
  rc=$?
  printf '%s\n' "$out" > "$TMP/last_run5.txt"
  printf '%s|%s' "$rc" \
    "$(printf '%s\n' "$out" | sed -n 's/^>>> EVENT \(.*\)$/\1/p' | paste -sd, -)"
}

# (a) The control: no --base, so the persisted baseline is all there is, and
#     the commit behind it stays unexamined.  This is the bug, held in place so
#     the next case is known to be testing the fix and not the fixture.
seed5
check "with no --base, a stale persisted baseline hides the commit behind it" \
  "$(run5)" "0|"

# (b) The rule: the same stale baseline, the same commit, one --base flag.
seed5
check "an explicit --base re-scans from the base and finds it" "$(run5 base)" "0|tripwire"
grep -q "outside the run-5 list: Z9" "$TMP/last_run5.txt" \
  && ok "the block names the batch the stale baseline hid" \
  || bad "the block does not name the batch the stale baseline hid"
grep -q "first time this poll (${BASE5:0:7}\.\.HEAD)" "$TMP/last_run5.txt" \
  && ok "the evidence header names the given base, not the persisted head" \
  || bad "the evidence header does not name the given base"

# (c) Re-scanning from the base every poll must not re-report: the widened
#     range is deduped by `reported_commits`, exactly as the narrow one was.
check "a second --base poll re-scans the same range and reports nothing twice" \
  "$(run5 base)" "0|"

# (d) An empty SPANWEAVE_BASE is not an operator statement; it must fall back
#     to the persisted baseline rather than to `DEF_BASE`, which belongs to a
#     run that ended long ago.
seed5
out5="$(SPANWEAVE_STATE_DIR="$ST5" SPANWEAVE_REPO="$R5D" SPANWEAVE_TDIR="$TD5" \
        SPANWEAVE_PINNED="55555555.jsonl" SPANWEAVE_SELF="" CLAUDE_CODE_SESSION_ID="" \
        SPANWEAVE_BASE="" SPANWEAVE_BRANCH=audit-fixes SPANWEAVE_PIDS="" \
        SPANWEAVE_BATCHES="S1 S2" SPANWEAVE_MEMO="" \
        "$OPS_DIR/watch_run.sh" --once --run 5 2>&1)"
check "an empty SPANWEAVE_BASE does not count as an operator-given base" \
  "$(printf '%s\n' "$out5" | sed -n 's/^>>> EVENT \(.*\)$/\1/p' | paste -sd, -)" ""

python3 - <<'PYCFG'
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import config, DEF_BASE

cases = [
    ("a given base is explicit",      {"SPANWEAVE_BASE": "b091904"},   "b091904", True),
    ("a padded base is stripped",     {"SPANWEAVE_BASE": "  b091904 "},"b091904", True),
    ("an empty base is not explicit", {"SPANWEAVE_BASE": ""},          DEF_BASE,  False),
    ("an absent base is not explicit", {},                             DEF_BASE,  False),
]
bad = 0
for name, env, want_base, want_expl in cases:
    os.environ.pop("SPANWEAVE_BASE", None)
    os.environ.update(env)
    cfg = config()
    got, want = (cfg["base"], cfg["base_explicit"]), (want_base, want_expl)
    if got == want:
        print("  PASS  %s" % name)
    else:
        print("  FAIL  %s\n        got %r want %r" % (name, got, want)); bad = 1
os.environ.pop("SPANWEAVE_BASE", None)
sys.exit(bad)
PYCFG
[ $? -eq 0 ] || fail=1

# ---------------------------------------------------------------------------
echo
echo "the branch is derived from the checkout, not assumed"
# ---------------------------------------------------------------------------
# `DEF_BRANCH` was the constant `audit-fixes`.  On 2026-09-30 a run-2 status
# check ran against a repo that had moved to `live-graphs`: `git fetch origin
# audit-fixes` failed with "couldn't find remote ref", `origin` read as the
# stale sha of a branch nobody was on, and the report still printed a confident
# `NOT pushed (origin b863767)`.  Every clause was produced by machinery
# comparing against the wrong branch.
R6D="$TMP/repo6"; mkdir -p "$R6D"
git -C "$R6D" init -q -b live-graphs
git -C "$R6D" config user.email t@example.invalid
git -C "$R6D" config user.name Selftest
cat > "$R6D/WORKPLAN.md" <<'MD'
## 1. Batch list

| # | Batch | Status | Est. calls |
|---|---|---|---|
| L3 | thing | todo | 20 |

## 4. Resume note

- nothing yet.

---
MD
git -C "$R6D" add -A && git -C "$R6D" commit -qm "base"
BASE6="$(git -C "$R6D" rev-parse HEAD)"
git init -q --bare "$TMP/remote6.git"
git -C "$R6D" remote add origin "$TMP/remote6.git"
git -C "$R6D" push -q origin live-graphs

branchcfg() {  # branchcfg <repo> [SPANWEAVE_BRANCH] -> "<branch>|<src>"
  env -u SPANWEAVE_BRANCH SPANWEAVE_REPO="$1" ${2:+SPANWEAVE_BRANCH="$2"} python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import config
cfg = config()
print("%s|%s" % (cfg["branch"], cfg["branch_src"]))
PY
}

check "with nothing given, the branch is the repo's own checkout" \
      "$(branchcfg "$R6D")" "live-graphs|derived"
check "an operator-given branch outranks the checkout" \
      "$(branchcfg "$R6D" audit-fixes)" "audit-fixes|given"
git -C "$R6D" checkout -q --detach HEAD
check "a detached HEAD yields no branch, and says so rather than guessing" \
      "$(branchcfg "$R6D")" "|undetermined"
git -C "$R6D" checkout -q live-graphs

TD6="$TMP/tdir6"; mkdir -p "$TD6"; ST6="$TMP/state6"; mkdir -p "$ST6"
printf '{"type":"last-prompt","lastPrompt":"Execute WORKPLAN.md run 2"}\n' > "$TD6/66666666.jsonl"

run6() {  # run6 [branch] -> "<exit>|<event kinds>"; with no argument, no --branch
  local out rc
  out="$(env -u SPANWEAVE_BRANCH \
         SPANWEAVE_STATE_DIR="$ST6" SPANWEAVE_REPO="$R6D" SPANWEAVE_TDIR="$TD6" \
         SPANWEAVE_PINNED="" SPANWEAVE_SELF="" CLAUDE_CODE_SESSION_ID="" \
         SPANWEAVE_BASE="$BASE6" SPANWEAVE_PIDS="" SPANWEAVE_BATCHES="L3" \
         SPANWEAVE_MEMO="" \
         "$OPS_DIR/watch_run.sh" --once --run 2 ${1:+--branch "$1"} 2>&1)"
  rc=$?
  printf '%s\n' "$out" > "$TMP/last_run6.txt"
  printf '%s|%s' "$rc" \
    "$(printf '%s\n' "$out" | sed -n 's/^>>> EVENT \(.*\)$/\1/p' | paste -sd, -)"
}

# End to end: no --branch, on a repo that is not on `audit-fixes`.  Under the
# constant this poll fetched a ref that does not exist AND tripped the
# wrong-branch condition on the repo's own checkout.
check "no --branch on a non-audit-fixes repo polls clean" "$(run6)" "0|"
grep -q "git fetch failed" "$TMP/last_run6.txt" \
  && bad "the fetch still names a branch the remote does not have" \
  || ok "the fetch names the branch the repo is actually on"
grep -q "origin $(git -C "$R6D" rev-parse --short origin/live-graphs)" "$TMP/last_run6.txt" \
  && ok "the banner compares against origin/live-graphs" \
  || bad "the banner does not compare against origin/live-graphs"

# The guard the derived default must not cost: an operator who names a branch
# still gets told when the builder is somewhere else.  This is also why the
# branch is resolved once at arming and not re-read per poll - re-derived, it
# would follow the checkout and this could never fire.
check "a given branch the repo is not on still trips the wire" \
      "$(run6 audit-fixes)" "0|tripwire"
grep -q "checked-out branch is 'live-graphs', not 'audit-fixes'" "$TMP/last_run6.txt" \
  && ok "the block names both branches" || bad "the block does not name both branches"

# ---------------------------------------------------------------------------
echo
echo "the arming PID set is derived, not assumed"
# ---------------------------------------------------------------------------
# `DEF_PIDS` was four PIDs from one session on 2026-09-10.  All four had exited
# by 2026-09-30, so any watch that took the default was armed to fire `builder
# gone` - a terminal trigger - on its first poll, on evidence about processes
# that had been dead for weeks.
python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import arming_pids, config

# A synthetic `pgrep -af claude`, so the case is about the rule and not about
# whatever happens to be running on this machine.
PGREP = "\n".join([
    "1351527 claude --dangerously-skip-permissions",
    "1550331 claude",                      # not a builder: no --dangerously
    "1558407 claude --dangerously-skip-permissions --resume abc",
    "999 /usr/bin/claude-helper --dangerously-skip-permissions",   # wrong command
    # The wrapper that runs the pgrep. Its command line QUOTES the pattern, so
    # a substring match would enrol the watcher's own shell in the set it is
    # about to watch for disappearance.
    "424242 bash -c pgrep -af claude | grep 'claude --dangerous'",
    "nonsense line with no pid",
])
cases = [
    ("only --dangerously sessions are armed on",
     arming_pids(PGREP), [1351527, 1558407]),
    ("the pgrep wrapper never matches itself",
     [p for p in arming_pids(PGREP) if p == 424242], []),
    ("no claude process at all is an empty set, not a default",
     arming_pids("nothing here"), []),
]
bad = 0
for name, got, want in cases:
    if got == want:
        print("  PASS  %s" % name)
    else:
        print("  FAIL  %s\n        got %r want %r" % (name, got, want)); bad = 1

# Unset and empty are different: unset means arming has not run, empty means it
# ran and found nothing.  Neither may fall back to a constant.
for name, env, want in [
    ("an unset PID set is empty and flagged unarmed", None, ("unarmed", [])),
    ("an explicitly empty PID set stays empty",       "",   ("armed",   [])),
    ("a given PID set is taken verbatim",         "7 9 8",  ("armed", [7, 8, 9])),
]:
    os.environ.pop("SPANWEAVE_PIDS", None)
    if env is not None:
        os.environ["SPANWEAVE_PIDS"] = env
    cfg = config()
    got = (cfg["pids_src"], sorted(cfg["pids"]))
    if got == want:
        print("  PASS  %s" % name)
    else:
        print("  FAIL  %s\n        got %r want %r" % (name, got, want)); bad = 1
os.environ.pop("SPANWEAVE_PIDS", None)
sys.exit(bad)
PY
[ $? -eq 0 ] || fail=1

# arming.sh resolves both once, and never overwrites what it was given.
armed() {  # armed -> "<branch>|<src>|<pids resolved?>"
  env -u SPANWEAVE_BRANCH -u SPANWEAVE_BRANCH_SRC -u SPANWEAVE_PIDS \
      SPANWEAVE_REPO="$R6D" bash -c '
    . "$SPANWEAVE_OPS_DIR/arming.sh"; spanweave_arm
    printf "%s|%s|%s" "$SPANWEAVE_BRANCH" \
           "$(python3 -c "import os,sys;sys.path.insert(0,os.environ[\"SPANWEAVE_OPS_DIR\"]);
from watch_lib import config;print(config()[\"branch_src\"])")" \
           "${SPANWEAVE_PIDS+set}"'
}
# Arming EXPORTS the branch it derived, so without a marker every downstream
# config() would see a branch in the environment and call it `given` - the one
# thing a report about a derived default must not get wrong.
check "arming derives the branch and says it derived it" \
      "$(armed)" "live-graphs|derived|set"
check "arming leaves an operator's own values alone" \
      "$(SPANWEAVE_REPO="$R6D" SPANWEAVE_BRANCH=given SPANWEAVE_PIDS="" bash -c '
          . "$SPANWEAVE_OPS_DIR/arming.sh"; spanweave_arm
          printf "%s|%s" "$SPANWEAVE_BRANCH" "[$SPANWEAVE_PIDS]"')" \
      "given|[]"

# The consequence at the trigger: an empty set cannot shrink, so `builder gone`
# has no signal - which the poll must say out loud rather than look quiet.
check "an empty PID set does not fire builder gone" "$(run6)" "0|"
grep -q "no PID set: 'builder gone' disarmed" "$TMP/last_run6.txt" \
  && ok "the banner says the trigger is disarmed" \
  || bad "the banner does not say the trigger is disarmed"

# ---------------------------------------------------------------------------
echo
echo "the watched repo is a parameter, and three defaults derive from it"
# ---------------------------------------------------------------------------
# `--repo` existed on `status_check.sh` only, and the transcript directory was
# the constant `~/.claude/projects/-home-msi-git-spanweave`.  So a check
# pointed at a second repo - and on 2026-10-04 there was one, `spanweave-live`
# - read that repo's branch and that repo's commits while the transcript, the
# liveness timestamp and the sub-agent activity all came from the OTHER
# project's sessions, and the PID set was armed on whichever builder happened
# to be running anywhere on the machine.  Three facts now derive from the repo
# the operator named: the branch, the PID set and the transcript directory.
python3 - <<'PY'
import os, re, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import DEF_PROJECTS, config, default_tdir, pids_in_repo

# The floor this script set at the top, to be put back after the cases below
# move SPANWEAVE_REPO around: no later case may be left pointing anywhere real.
FLOOR = os.environ.get("SPANWEAVE_REPO")
bad = 0


def c(name, got, want):
    global bad
    if got == want:
        print("  PASS  %s" % name)
    else:
        print("  FAIL  %s\n        got %r\n        want %r" % (name, got, want))
        bad = 1


# -- the transcript directory ------------------------------------------------
# Claude Code names a project directory after the absolute path of the
# directory the session started in, with every non-alphanumeric character
# replaced by `-`.  The encoding is Claude Code's; these cases pin our reading
# of it against the real names on this machine.
c("the project directory is the repo path with every non-alnum as '-'",
  default_tdir("/home/msi/git/spanweave", "/P"), "/P/-home-msi-git-spanweave")
c("a second repo gets a second directory, which is the whole point",
  default_tdir("/home/msi/git/spanweave-live", "/P"),
  "/P/-home-msi-git-spanweave-live")
c("dots and underscores are not alphanumeric either",
  default_tdir("/home/msi/git/my_repo.v2", "/P"), "/P/-home-msi-git-my-repo-v2")
c("a relative path is resolved before it is encoded",
  default_tdir("."),
  os.path.join(DEF_PROJECTS, re.sub(r"[^A-Za-z0-9]", "-", os.getcwd())))

# -- and through config(), where the entry points read it --------------------
for name, env, want in [
    ("with no SPANWEAVE_TDIR the directory derives from the repo",
     {"SPANWEAVE_REPO": "/tmp/r1"}, default_tdir("/tmp/r1")),
    ("naming the repo names the transcripts too",
     {"SPANWEAVE_REPO": "/tmp/r2"}, default_tdir("/tmp/r2")),
    ("an operator's own SPANWEAVE_TDIR still outranks the derivation",
     {"SPANWEAVE_REPO": "/tmp/r1", "SPANWEAVE_TDIR": "/tmp/elsewhere"},
     "/tmp/elsewhere"),
    # The encoding belongs to Claude Code, not to us, so an empty value must
    # not be mistaken for "the operator chose the empty directory".
    ("an empty SPANWEAVE_TDIR is not a directory, so it does not count as given",
     {"SPANWEAVE_REPO": "/tmp/r1", "SPANWEAVE_TDIR": ""}, default_tdir("/tmp/r1")),
]:
    for k in ("SPANWEAVE_REPO", "SPANWEAVE_TDIR"):
        os.environ.pop(k, None)
    os.environ.update(env)
    c(name, config()["tdir"], want)
for k in ("SPANWEAVE_REPO", "SPANWEAVE_TDIR"):
    os.environ.pop(k, None)
if FLOOR is not None:
    os.environ["SPANWEAVE_REPO"] = FLOOR

# -- the PID set, now scoped to the repo -------------------------------------
# Command shape alone stopped being enough the moment two series could be
# under way at once: an unscoped set arms each watch on the other watch's
# builder, so `builder gone` fires on a stranger finishing and stays silent
# when the builder this watch is about dies.
PGREP = "\n".join([
    "101 claude --dangerously-skip-permissions",          # in the repo
    "102 claude --dangerously-skip-permissions --resume x",  # in a subdirectory
    "103 claude --dangerously-skip-permissions",          # the OTHER repo
    "104 claude --dangerously-skip-permissions",          # cwd unreadable
    "105 claude",                                         # not a builder at all
])
CWD = {101: "/w/spanweave", 102: "/w/spanweave/tests",
       103: "/w/spanweave-live", 104: None, 105: "/w/spanweave"}
c("a builder whose cwd is the repo, or inside it, is armed on",
  pids_in_repo(PGREP, repo="/w/spanweave", cwd_of=CWD.get)[0], [101, 102])
c("a builder in another repo is reported outside, never armed on",
  103 in pids_in_repo(PGREP, repo="/w/spanweave", cwd_of=CWD.get)[1], True)
# A sibling that merely shares the prefix is a different repo.  Without the
# separator test `/w/spanweave-live` reads as "inside /w/spanweave" and the
# scope lets through exactly the process it exists to exclude.
c("a sibling repo sharing the path prefix is not inside it",
  pids_in_repo(PGREP, repo="/w/spanweave", cwd_of=CWD.get),
  ([101, 102], [103, 104]))
# "We could not look" is not "it is ours".  Arming a terminal trigger on a
# process we failed to identify is the guess this tooling does not make.
c("a builder whose cwd cannot be read is outside, not armed on",
  pids_in_repo(PGREP, repo="/w/spanweave", cwd_of=lambda p: None),
  ([], [101, 102, 103, 104]))
c("a non-builder process is neither armed on nor reported outside",
  [p for grp in pids_in_repo(PGREP, repo="/w/spanweave", cwd_of=CWD.get)
   for p in grp if p == 105], [])
c("with no repo there is no scope, and every builder-shaped PID is armed on",
  pids_in_repo(PGREP, cwd_of=CWD.get), ([101, 102, 103, 104], []))
sys.exit(bad)
PY
[ $? -eq 0 ] || fail=1

# A second fixture repo, on its own branch, with an R-prefixed batch list: the
# `--repo` cases below name it while SPANWEAVE_REPO in the environment still
# points at the first one, so every case is about the flag reaching arming -
# and none of them can fall back to the real ~/git/spanweave.
RA="$TMP/repoA"; mkdir -p "$RA"
git -C "$RA" init -q -b other-series
git -C "$RA" config user.email t@example.invalid
git -C "$RA" config user.name Selftest
cat > "$RA/WORKPLAN.md" <<'MD'
## 1. Batch list

| ID | Batch | Status | Calls |
|---|---|---|---|
| R0 | skeleton | done (`696702f`) | 10 |
| R1 | framing | done (`a4fec60`) | 10 |
| R2 | routing | todo | 15 |

## 4. Resume note

- nothing yet.

---
MD
git -C "$RA" add -A && git -C "$RA" commit -qm "plan: open the series"
BASEA="$(git -C "$RA" rev-parse HEAD)"
git init -q --bare "$TMP/remoteA.git"
git -C "$RA" remote add origin "$TMP/remoteA.git"
git -C "$RA" push -q origin other-series
TDA="$TMP/tdirA"; mkdir -p "$TDA"; STA="$TMP/stateA"; mkdir -p "$STA"
printf '{"type":"last-prompt","lastPrompt":"Execute WORKPLAN.md run 2"}\n' > "$TDA/aaaaaaaa.jsonl"

# `arming.sh` reads BOTH of its values from the watched repo, so `--repo` has
# to reach it - and the two looping front ends arm before `watch_run.sh` ever
# parses a flag.  Without `spanweave_export_repo` a `--repo` watch is armed on
# the DEFAULT repo's branch and the default repo's processes while every poll
# reports on the given one.
armedrepo() {  # armedrepo <argv...> -> "<repo>|<branch>"
  env -u SPANWEAVE_BRANCH -u SPANWEAVE_BRANCH_SRC -u SPANWEAVE_PIDS \
      SPANWEAVE_REPO="$R6D" bash -c '
    . "$SPANWEAVE_OPS_DIR/arming.sh"
    spanweave_export_repo "$@"
    spanweave_arm >/dev/null
    printf "%s|%s" "$SPANWEAVE_REPO" "$SPANWEAVE_BRANCH"' bash "$@"
}
check "arming takes --repo out of argv and derives that repo's branch" \
      "$(armedrepo --run 2 --repo "$RA" --batches "R2")" "$RA|other-series"
check "no --repo in argv leaves the environment's repo alone" \
      "$(armedrepo --run 2 --batches "R2")" "$R6D|live-graphs"
check "an empty --repo is not a path, so it is not taken" \
      "$(armedrepo --run 2 --repo "" )" "$R6D|live-graphs"

# The scope's rejections are an EVENT, said once at arming: an armed set that
# is empty because the builders are all in another repo must never read as
# "no builder is running".
scopenote() {  # scopenote <PGREP_STUB_OUT> -> arming's stdout
  env -u SPANWEAVE_BRANCH -u SPANWEAVE_BRANCH_SRC -u SPANWEAVE_PIDS \
      SPANWEAVE_REPO="$RA" PGREP_STUB_OUT="$1" bash -c '
    . "$SPANWEAVE_OPS_DIR/arming.sh"; spanweave_arm'
}
printf '%s\n' "$(scopenote "777001 claude --dangerously-skip-permissions")" \
  > "$TMP/scopenote.txt"
grep -q "are running outside $RA" "$TMP/scopenote.txt" \
  && ok "arming says which builder-shaped processes the scope refused" \
  || bad "arming is silent about a builder-shaped process outside the repo"
grep -q "777001" "$TMP/scopenote.txt" \
  && ok "the note names the PIDs, so an operator can recognise the other series" \
  || bad "the note does not name the refused PIDs"
check "nothing builder-shaped is running: no note, nothing to report" \
      "$(scopenote "")" ""

# End to end, on each entry point that takes the flag.
sa_out="$(env -u SPANWEAVE_BRANCH -u SPANWEAVE_PIDS \
          SPANWEAVE_REPO="$R6D" SPANWEAVE_TDIR="$TDA" SPANWEAVE_PINNED="" \
          SPANWEAVE_SELF="" CLAUDE_CODE_SESSION_ID="" \
          "$OPS_DIR/status_check.sh" --run 2 --batches "R2" --base "$BASEA" \
          --repo "$RA" 2>&1)"
check "status_check.sh --repo reports that repo's path" \
      "$(printf '%s\n' "$sa_out" | sed -n 's/^path  *: //p')" "$RA"
check "... and that repo's branch, derived" \
      "$(printf '%s\n' "$sa_out" | sed -n 's/^branch  *: //p')" \
      "other-series (watching other-series, derived)"

wr_out="$(env -u SPANWEAVE_BRANCH \
          SPANWEAVE_STATE_DIR="$STA" SPANWEAVE_REPO="$R6D" \
          SPANWEAVE_TDIR="$TDA" SPANWEAVE_PINNED="" SPANWEAVE_SELF="" \
          CLAUDE_CODE_SESSION_ID="" SPANWEAVE_BASE="$BASEA" SPANWEAVE_PIDS="" \
          SPANWEAVE_BATCHES="R2" SPANWEAVE_MEMO="" \
          "$OPS_DIR/watch_run.sh" --once --run 2 --repo "$RA" 2>&1)"
check "watch_run.sh --repo polls that repo clean" \
      "$(printf '%s\n' "$wr_out" | sed -n 's/^>>> EVENT \(.*\)$/\1/p' | paste -sd, -)" ""
printf '%s\n' "$wr_out" | grep -q "origin $(git -C "$RA" rev-parse --short origin/other-series)" \
  && ok "its banner compares against the given repo's origin/other-series" \
  || bad "its banner does not compare against the given repo's origin"

# The two looping front ends arm and then re-invoke, so the flag has to survive
# both.  One poll is enough: a dead PID in the set with a batch still open is
# `builder gone`, which is terminal, so the loop exits instead of running on.
mon_out="$(env -u SPANWEAVE_BRANCH \
           SPANWEAVE_STATE_DIR="$STA" SPANWEAVE_REPO="$R6D" \
           SPANWEAVE_TDIR="$TDA" SPANWEAVE_PINNED="" SPANWEAVE_SELF="" \
           CLAUDE_CODE_SESSION_ID="" SPANWEAVE_BATCHES="R2" SPANWEAVE_MEMO="" \
           "$OPS_DIR/watch_monitor.sh" --run 2 --base "$BASEA" --repo "$RA" \
           --pids 4000001 2>&1)"
mon_rc=$?
check "watch_monitor.sh --repo arms on the given repo and reaches its terminal trigger" \
      "$mon_rc" "13"
# The discriminating assertion, not merely "13": `builder gone` fires off the
# PID set alone and would fire however the branch was armed.  What only a
# `--repo` that reached ARMING can produce is an armed branch read from the
# given repo - `origin/other-series` in the evidence, and no wrong-branch
# tripwire ahead of it.  Dropping `spanweave_export_repo` from this script
# arms on the environment's repo instead, and the block says `origin/live-graphs`
# with a tripwire above it.
printf '%s\n' "$mon_out" | grep -q "^origin/other-series:" \
  && ok "the monitor armed the branch on the repo the flag named" \
  || bad "the monitor's evidence names a branch from some other repo"
printf '%s\n' "$mon_out" | grep -q "tripwire" \
  && bad "the monitor tripped the wrong-branch wire, so arming missed --repo" \
  || ok "no wrong-branch tripwire: the armed branch and the checkout agree"

loop_out="$(env -u SPANWEAVE_BRANCH \
            SPANWEAVE_STATE_DIR="$STA" SPANWEAVE_REPO="$R6D" \
            SPANWEAVE_TDIR="$TDA" SPANWEAVE_PINNED="" SPANWEAVE_SELF="" \
            CLAUDE_CODE_SESSION_ID="" SPANWEAVE_BATCHES="R2" SPANWEAVE_MEMO="" \
            "$OPS_DIR/watch_loop.sh" --run 2 --base "$BASEA" --repo "$RA" \
            --pids 4000002 2>&1)"
loop_rc=$?
check "watch_loop.sh --repo does the same in a plain terminal" "$loop_rc" "13"
printf '%s\n' "$loop_out" | grep -q "^origin/other-series:" \
  && ok "the loop armed the branch on the repo the flag named" \
  || bad "the loop's evidence names a branch from some other repo"

# ---------------------------------------------------------------------------
echo
echo "a batch id is a capital letter and digits, whichever letter the plan uses"
# ---------------------------------------------------------------------------
# `[A-H]\d+` made every run-3 row and every run-3 declaration invisible: rows
# read as "<row missing>", so "0/7 stopped, active: all seven" was a default
# rather than an observation.  The pattern is `[A-Z]\d+` now; the receiver
# series uses R0-R9, including a batch whose digit is ZERO, so these cases pin
# that the generalisation actually covers the plan in use today.
python3 - "$RA" <<'PY'
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import BATCH_ID, declared_batches, workplan_statuses

bad = 0


def c(name, got, want):
    global bad
    if got == want:
        print("  PASS  %s" % name)
    else:
        print("  FAIL  %s\n        got %r\n        want %r" % (name, got, want))
        bad = 1


c("the pattern itself admits R and a digit", BATCH_ID, r"[A-Z]\d+")
# The receiver series' own plan commits, verbatim.
c("a plan: subject declares an R batch",
  declared_batches("plan: R0 done, and the pins are HTTPS so CI can check out"
                   " the submodule", ""), ["R0"])
c("a zero is a digit: R0 is a batch id, not a near-miss",
  declared_batches("plan: R0 done", ""), ["R0"])
c("a body line declares an R batch",
  declared_batches("routing: one spanweave.Builder per trace",
                   "Batch R2 of WORKPLAN.md.  SPEC sections 4.1-4.7."), ["R2"])
c("a second clause after the batch id does not hide it",
  declared_batches("plan: R2 done, and its mutation criterion was wrong"
                   " - the row is corrected", ""), ["R2"])
# Still only where a batch is DECLARED: the R2 row cites R3 in prose, and a
# citation is not a declaration whatever the prefix.
c("an R batch cited in prose is still not a declaration",
  declared_batches("plan: R2 done", "R3 does not depend on either thread."),
  ["R2"])
# And the rows: a table the watcher cannot read is reported as every batch
# open, which is a default dressed as an observation.
statuses, raw, source = workplan_statuses(sys.argv[1])
c("an R-prefixed batch list is read, not reported missing",
  (source, statuses),
  ("worktree", {"R0": "done (`696702f`)", "R1": "done (`a4fec60`)",
                "R2": "todo"}))
sys.exit(bad)
PY
[ $? -eq 0 ] || fail=1

# ---------------------------------------------------------------------------
echo
echo "a run whose last batch deletes the plan ends with no rows to read"
# ---------------------------------------------------------------------------
# G4's last act is `remove WORKPLAN.md`, so the run that closes the series ends
# with the parser looking at a file that is not there.  Two different states
# look exactly like that to a reader of the worktree:
#
#   the close          - a plan was there at base, and this run deleted it
#   a plan not yet written - run 3's builder was started with "recreate
#                        WORKPLAN.md from git show c79cbc5:WORKPLAN.md", so it
#                        had no plan at base and none at HEAD until its plan
#                        commit landed
#
# The old rule - "gone and pushed is finished" - called the second one a
# finished run.  `plan_at_rev` is what separates them, and the close is
# finished on the same terms as any other run: pushed AND green.
RC="$TMP/repoC"; mkdir -p "$RC"
git -C "$RC" init -q -b live-graphs
git -C "$RC" config user.email t@example.invalid
git -C "$RC" config user.name Selftest
cat > "$RC/WORKPLAN.md" <<'MD'
## 1. Batches

| # | Batch | Status | Est. calls |
|---|---|---|---|
| L23 | thing | done (`aaaaaaa`) | 20 |
| L24 | thing | done (`bbbbbbb`) | 15 |

## 4. Resume note

- L24 done.

---
MD
echo x > "$RC/keep.txt"
git -C "$RC" add -A
GIT_COMMITTER_DATE="$(date -d '-90 min' -R)" GIT_AUTHOR_DATE="$(date -d '-90 min' -R)" \
  git -C "$RC" commit -qm "base"
BASEC="$(git -C "$RC" rev-parse HEAD)"
git init -q --bare "$TMP/remoteC.git"
git -C "$RC" remote add origin "$TMP/remoteC.git"
git -C "$RC" push -q origin live-graphs

TDC="$TMP/tdirC"; mkdir -p "$TDC"
STC="$TMP/stateC"; mkdir -p "$STC"
{
  printf '{"type":"last-prompt","lastPrompt":"Execute WORKPLAN.md run 5"}\n'
  printf '{"type":"assistant","timestamp":"2026-10-02T00:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Closing the series."}]}}\n'
} > "$TDC/cccccccc.jsonl"

scC() {  # scC -> the status report for run 5 over this fixture
  SPANWEAVE_REPO="$RC" SPANWEAVE_TDIR="$TDC" \
  SPANWEAVE_PINNED="cccccccc.jsonl" SPANWEAVE_SELF="none.jsonl" \
  SPANWEAVE_BASE="$BASEC" SPANWEAVE_BRANCH=live-graphs SPANWEAVE_PIDS="" \
  "$OPS_DIR/status_check.sh" --run 5 --batches "L23 L24" 2>&1
}
vC() { printf '%s\n' "$1" | grep -m1 '^VERDICT: ' | sed 's/^VERDICT: //'; }

RC="$RC" BASEC="$BASEC" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import plan_at_rev
RC = os.environ["RC"]
base = os.environ["BASEC"]
bad = 0
for name, got, want in [
    ("plan_at_rev sees the plan at base", plan_at_rev(RC, base), True),
    ("plan_at_rev reads a rev that does not resolve as unreadable, not absent",
     plan_at_rev(RC, "0000000000000000000000000000000000000000"), None),
    ("plan_at_rev on a repo that is not one is unreadable too",
     plan_at_rev(os.path.join(RC, "no-such-dir"), "HEAD"), None),
]:
    if got is want: print("  PASS  %s" % name)
    else: print("  FAIL  %s\n        got %r want %r" % (name, got, want)); bad = 1
sys.exit(bad)
PY
[ $? -eq 0 ] || fail=1

# The close itself: delete the plan, commit, push, CI green.
git -C "$RC" rm -q WORKPLAN.md
git -C "$RC" commit -qm "plan: series closed, WORKPLAN.md removed"

# (1) deleted and committed but NOT pushed - not finished.
gh_says "$RC" completed '"success"'
out="$(scC)"
check "deleted at HEAD but unpushed is not finished" "$(vC "$out")" "unclear"
printf '%s\n' "$out" | grep -q "plan file : absent at HEAD | present at base" \
  && ok "the report says the plan was present at base and is absent at HEAD" \
  || bad "the report does not say where the plan was and was not"

# (2) pushed, and CI on the tip is green - the close is finished.
git -C "$RC" push -q origin live-graphs
out="$(scC)"
check "present at base, absent at HEAD, pushed and green -> finished (series closed)" \
      "$(vC "$out")" "finished (series closed)"
printf '%s\n' "$out" | grep -q "the series is closed" \
  && ok "the plan section says the series is closed" \
  || bad "the plan section does not say the series is closed"
printf '%s\n' "$out" | grep -q "^  ci        : success: " \
  && ok "the report prints the CI answer the verdict used" \
  || bad "the report does not print the CI answer"

# (3) CI pending on the pushed tip - not finished, and the reason says so.
gh_says "$RC" in_progress 'null'
out="$(scC)"
check "pushed with CI pending is not finished" "$(vC "$out")" "unclear"
printf '%s\n' "$out" | grep -q "CI on the pushed tip has not concluded" \
  && ok "the why line names CI as what is missing" \
  || bad "the why line does not name CI"

# (4) gh unreadable - terminal, but it says the CI half is unchecked.
gh_unavailable
check "pushed with gh unreadable says CI is unverified" \
      "$(vC "$(scC)")" "finished (series closed, CI unverified)"

# (5) CI red - not finished.
gh_says "$RC" completed '"failure"'
check "pushed with CI red is not finished" "$(vC "$(scC)")" "unclear"

# (6) a plan absent at base too is not a close.  Re-base the same report on the
# closing commit: at THAT base there is no WORKPLAN.md either, so the absence
# says nothing about this run - and with both batches' rows gone, every batch
# is open, which is what keeps `finished` out of reach.
gh_says "$RC" completed '"success"'
out="$(SPANWEAVE_REPO="$RC" SPANWEAVE_TDIR="$TDC" \
       SPANWEAVE_PINNED="cccccccc.jsonl" SPANWEAVE_SELF="none.jsonl" \
       SPANWEAVE_BASE="$(git -C "$RC" rev-parse HEAD)" \
       SPANWEAVE_BRANCH=live-graphs SPANWEAVE_PIDS="" \
       "$OPS_DIR/status_check.sh" --run 5 --batches "L23 L24" 2>&1)"
printf '%s\n' "$(vC "$out")" | grep -qx "finished (series closed)" \
  && bad "an absence that was already there at base is read as a series close" \
  || ok "an absence that was already there at base is not a series close"
printf '%s\n' "$out" | grep -q "this is not a" \
  && ok "the plan section says why the absence is not a close" \
  || bad "the plan section does not say why the absence is not a close"
printf '%s\n' "$out" | grep -q "2 listed | 0 stopped | 2 open: L23, L24" \
  && ok "with no rows and no close, every batch stays open" \
  || bad "a non-close absence still leaves batches stopped"

# (7) the watch agrees with the report: the same shape is terminal there, with
# the same name, and the non-close absence does not fire at all.
gh_says "$RC" completed '"success"'
out="$(SPANWEAVE_STATE_DIR="$STC" SPANWEAVE_REPO="$RC" SPANWEAVE_TDIR="$TDC" \
       SPANWEAVE_PINNED="cccccccc.jsonl" SPANWEAVE_SELF="none.jsonl" \
       SPANWEAVE_BASE="$BASEC" SPANWEAVE_BRANCH=live-graphs \
       SPANWEAVE_PIDS="" SPANWEAVE_BATCHES="L23 L24" \
       "$OPS_DIR/watch_run.sh" --once --run 5 2>&1)"
check "the watch fires the close as terminal (exit 10)" "$?" "10"
printf '%s\n' "$out" | grep -q "^>>> EVENT finished (series closed)\$" \
  && ok "the watch's trigger name matches the report's verdict" \
  || bad "the watch's trigger name does not match the report's verdict"

rm -rf "$STC"; mkdir -p "$STC"
out="$(SPANWEAVE_STATE_DIR="$STC" SPANWEAVE_REPO="$RC" SPANWEAVE_TDIR="$TDC" \
       SPANWEAVE_PINNED="cccccccc.jsonl" SPANWEAVE_SELF="none.jsonl" \
       SPANWEAVE_BASE="$(git -C "$RC" rev-parse HEAD)" \
       SPANWEAVE_BRANCH=live-graphs \
       SPANWEAVE_PIDS="" SPANWEAVE_BATCHES="L23 L24" \
       "$OPS_DIR/watch_run.sh" --once --run 5 2>&1)"
check "a non-close absence is not terminal in the watch either" "$?" "0"
printf '%s\n' "$out" | grep -q "not a close" \
  && ok "the poll banner says the absence is not a close" \
  || bad "the poll banner does not say the absence is not a close"

# ---------------------------------------------------------------------------
echo
echo "the series close is the one WORKPLAN.md commit that cannot say 'plan:'"
# ---------------------------------------------------------------------------
# The convention is that a commit touching WORKPLAN.md reports on a batch, so
# its subject starts `plan:`, and the tripwire says so.  The close batch is the
# single commit that cannot obey it: it *deletes* the plan, and there is no row
# left to report on.  Run 5's close landed as `docs: the live-graphs series
# closes, and WORKPLAN.md goes with it` and tripped a rule it was right to
# break.
#
# The exemption is deliberately narrow, and the cases below pin both halves.  A
# delete is read as a close only when the plan was present at the BASE commit -
# so there was a series here to close - and only ONCE per series, because a
# series closes once.  Without the second half the rule is a blanket hole: any
# commit could drop the file and walk past it by doing so.
RXD="$TMP/repoX"; mkdir -p "$RXD"
git -C "$RXD" init -q -b live-graphs
git -C "$RXD" config user.email t@example.invalid
git -C "$RXD" config user.name Selftest
cat > "$RXD/WORKPLAN.md" <<'MD'
## 1. Batch list

| # | Batch | Status | Est. calls |
|---|---|---|---|
| L23 | thing | todo | 20 |
| L24 | thing | todo | 15 |

## 4. Resume note

- nothing yet.

---
MD
git -C "$RXD" add -A && git -C "$RXD" commit -qm "base"
BASEX="$(git -C "$RXD" rev-parse HEAD)"
git init -q --bare "$TMP/remoteX.git"
git -C "$RXD" remote add origin "$TMP/remoteX.git"
git -C "$RXD" push -q origin live-graphs

TDX="$TMP/tdirX"; mkdir -p "$TDX"; STX="$TMP/stateX"; mkdir -p "$STX"
# `Resume WORKPLAN.md` is a builder prompt for ANY run (RESUME_RE), which is
# what lets the last case below poll a second series without the fixture's
# transcript suddenly naming the wrong run.
printf '{"type":"last-prompt","lastPrompt":"Resume WORKPLAN.md"}\n' > "$TDX/78787878.jsonl"

runx() {  # runx [run] -> "<exit>|<event kinds>"; default run 5
  local out rc
  out="$(SPANWEAVE_STATE_DIR="$STX" SPANWEAVE_REPO="$RXD" SPANWEAVE_TDIR="$TDX" \
         SPANWEAVE_PINNED="78787878.jsonl" SPANWEAVE_SELF="" CLAUDE_CODE_SESSION_ID="" \
         SPANWEAVE_BASE="$BASEX" SPANWEAVE_BRANCH=live-graphs SPANWEAVE_PIDS="" \
         SPANWEAVE_BATCHES="L23 L24" SPANWEAVE_MEMO="" \
         "$OPS_DIR/watch_run.sh" --once --run "${1:-5}" 2>&1)"
  rc=$?
  printf '%s\n' "$out" > "$TMP/last_runX.txt"
  printf '%s|%s' "$rc" \
    "$(printf '%s\n' "$out" | sed -n 's/^>>> EVENT \(.*\)$/\1/p' | paste -sd, -)"
}

# (a) The rule itself, unchanged: a commit that MODIFIES the plan under a
#     non-`plan:` subject still trips.  The exemption is about deleting, and a
#     fixture that could not tell the two apart would prove nothing below.
printf '\n- touched.\n' >> "$RXD/WORKPLAN.md"
git -C "$RXD" add -A
git -C "$RXD" commit -qm "docs: tidy the plan's wording"
check "modifying WORKPLAN.md under a non-'plan:' subject still trips" \
      "$(runx)" "0|tripwire"
grep -q "subject does not start with 'plan:'" "$TMP/last_runX.txt" \
  && ok "the block names the 'plan:' subject rule" \
  || bad "the block does not name the 'plan:' subject rule"

# (b) The control in the other direction: a real `plan:` commit never tripped
#     and still does not.
printf '\n- L23 done.\n' >> "$RXD/WORKPLAN.md"
git -C "$RXD" add -A
git -C "$RXD" commit -qm "plan: L23 done"
check "a 'plan:' commit touching WORKPLAN.md does not trip" "$(runx)" "0|"

# (c) The close: deletes the plan, subject says `docs:`, plan was at base.
git -C "$RXD" rm -q WORKPLAN.md
git -C "$RXD" commit -qm "docs: the live-graphs series closes, and WORKPLAN.md goes with it"
CLOSEX="$(git -C "$RXD" rev-parse HEAD)"
check "the close deletes the plan under a 'docs:' subject and does not trip" \
      "$(runx)" "0|"
grep -q "read as the series close" "$TMP/last_runX.txt" \
  && ok "the exemption prints, so a reader can tell it was granted" \
  || bad "the exemption is silent, so a reader cannot tell it was granted"
grep -q "${CLOSEX:0:7}" "$TMP/last_runX.txt" \
  && ok "the note names the exempted commit" \
  || bad "the note does not name the exempted commit"
python3 - "$STX/watch_state.json" "$CLOSEX" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
got = st.get("close_exempt")
if got == sys.argv[2]:
    print("  PASS  watch_state.json records which commit the exemption was spent on")
else:
    print("  FAIL  watch_state.json close_exempt is %r, want %r" % (got, sys.argv[2]))
    sys.exit(1)
PY
[ $? -eq 0 ] || fail=1

# (d) Once per series.  Recreating the plan under a `plan:` subject is fine;
#     deleting it a SECOND time is not a close, and the exemption is spent.
cat > "$RXD/WORKPLAN.md" <<'MD'
## 1. Batch list

| # | Batch | Status | Est. calls |
|---|---|---|---|
| L23 | thing | done (`aaaaaaa`) | 20 |
MD
git -C "$RXD" add -A && git -C "$RXD" commit -qm "plan: reopen for one more batch"
git -C "$RXD" rm -q WORKPLAN.md
git -C "$RXD" commit -qm "chore: drop the plan again"
check "a second WORKPLAN.md delete in the same series does trip" \
      "$(runx)" "0|tripwire"
grep -q "subject does not start with 'plan:'" "$TMP/last_runX.txt" \
  && ok "the second delete is reported under the 'plan:' subject rule" \
  || bad "the second delete is not reported under the 'plan:' subject rule"

# (e) A new series clears it, like `main_sha`.  The series identity is the run,
#     the branch and the base, so polling run 6 is a new series - and its own
#     close is exempt again rather than inheriting run 5's spent exemption.
cat > "$RXD/WORKPLAN.md" <<'MD'
## 1. Batch list

| # | Batch | Status | Est. calls |
|---|---|---|---|
| L23 | thing | todo | 20 |
MD
git -C "$RXD" add -A && git -C "$RXD" commit -qm "plan: open the next series"
git -C "$RXD" rm -q WORKPLAN.md
git -C "$RXD" commit -qm "docs: the next series closes too"
check "a new series gets its own exemption, not the last one's leftovers" \
      "$(runx 6)" "0|"
grep -q "read as the series close" "$TMP/last_runX.txt" \
  && ok "the new series' close is exempt" \
  || bad "the new series' close is not exempt"

# (f) The other half of the narrowing: no plan at the base commit means there
#     was no series here to close, so a delete is just a delete.  This is the
#     `plan_at_rev` distinction that already keeps "a plan not yet written"
#     from being read as a finished run - the exemption leans on the same fact.
RYD="$TMP/repoY"; mkdir -p "$RYD"
git -C "$RYD" init -q -b live-graphs
git -C "$RYD" config user.email t@example.invalid
git -C "$RYD" config user.name Selftest
echo seed > "$RYD/README.md"
git -C "$RYD" add -A && git -C "$RYD" commit -qm "base without a plan"
BASEY="$(git -C "$RYD" rev-parse HEAD)"
git init -q --bare "$TMP/remoteY.git"
git -C "$RYD" remote add origin "$TMP/remoteY.git"
git -C "$RYD" push -q origin live-graphs
printf 'x\n' > "$RYD/WORKPLAN.md"
git -C "$RYD" add -A && git -C "$RYD" commit -qm "plan: recreate the plan"
git -C "$RYD" rm -q WORKPLAN.md
git -C "$RYD" commit -qm "docs: and the series closes"
TDY="$TMP/tdirY"; mkdir -p "$TDY"; STY="$TMP/stateY"; mkdir -p "$STY"
printf '{"type":"last-prompt","lastPrompt":"Resume WORKPLAN.md"}\n' > "$TDY/79797979.jsonl"
outy="$(SPANWEAVE_STATE_DIR="$STY" SPANWEAVE_REPO="$RYD" SPANWEAVE_TDIR="$TDY" \
        SPANWEAVE_PINNED="79797979.jsonl" SPANWEAVE_SELF="" CLAUDE_CODE_SESSION_ID="" \
        SPANWEAVE_BASE="$BASEY" SPANWEAVE_BRANCH=live-graphs SPANWEAVE_PIDS="" \
        SPANWEAVE_BATCHES="L23 L24" SPANWEAVE_MEMO="" \
        "$OPS_DIR/watch_run.sh" --once --run 5 2>&1)"
rcy=$?
printf '%s\n' "$outy" > "$TMP/last_runY.txt"
check "with no plan at base, a delete is not a close and does trip" \
      "$rcy|$(printf '%s\n' "$outy" | sed -n 's/^>>> EVENT \(.*\)$/\1/p' | paste -sd, -)" \
      "0|tripwire"
grep -q "read as the series close" "$TMP/last_runY.txt" \
  && bad "the exemption was granted with no plan at base" \
  || ok "the exemption is withheld with no plan at base"

echo
echo "verdict - one of exactly six values, from evidence alone"
# ---------------------------------------------------------------------------
python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import verdict

B = ["R1", "R2", "R3"]
TODO = {b: "todo" for b in B}
DONE = {b: "done (`abc1234`)" for b in B}

def V(statuses=TODO, source="worktree", batches=B, how="none", quiet_s=60,
      pushed=False, asks=False, limit_hit=False, declared=(),
      base_had_plan=None, ci=None):
    return verdict(statuses, source, batches, how, quiet_s, pushed,
                   asks, limit_hit, list(declared),
                   base_had_plan=base_had_plan, ci=ci)[0]

cases = [
    # The exact state of run 3 when this session first checked it: rows all
    # todo, plan reopened, no builder transcript derived, liveness a `/clear`
    # in the finished run-2 session.  The old line said "ALIVE ... active: all
    # seven", which read as work in progress.
    ("no builder transcript and nothing declared -> not started",
     V(how="pin (no candidate)", quiet_s=340), "not started"),
    ("a live builder that has declared nothing -> applying plan",
     V(how="derived", quiet_s=60), "applying plan"),
    ("a quiet builder that has declared nothing is not 'not started'",
     V(how="derived", quiet_s=3600), "unclear"),
    ("a row that says in progress -> underway, naming it",
     V(statuses={"R1": "done (`a`)", "R2": "in progress", "R3": "todo"},
       how="derived"), "underway: batch R2"),
    ("a declared batch with every row still todo -> underway, naming the first open",
     V(how="derived", declared=["R1"]), "underway: batch R1"),
    ("all stopped and pushed -> finished",
     V(statuses=DONE, pushed=True, how="derived"), "finished"),
    ("all stopped but unpushed, builder live -> applying plan",
     V(statuses=DONE, pushed=False, how="derived", quiet_s=60), "applying plan"),
    ("all stopped, unpushed, nothing live -> unclear",
     V(statuses=DONE, pushed=False, how="derived", quiet_s=3600), "unclear"),
    # The series close: G4's last act removes WORKPLAN.md, so the run that
    # ends the series ends with no rows to read.  It is finished on the same
    # terms as any other run - pushed AND green - and the absence counts as a
    # close only if there was a plan at base to delete.
    ("plan present at base, removed at HEAD, pushed and green -> finished (series closed)",
     V(statuses={}, source="absent", pushed=True, base_had_plan=True, ci="success"),
     "finished (series closed)"),
    ("... unpushed is not finished",
     V(statuses={}, source="absent", pushed=False, base_had_plan=True, ci="success"),
     "unclear"),
    ("... pushed with CI pending is not finished",
     V(statuses={}, source="absent", pushed=True, base_had_plan=True, ci="pending"),
     "unclear"),
    ("... pushed with CI red is not finished",
     V(statuses={}, source="absent", pushed=True, base_had_plan=True, ci="failure"),
     "unclear"),
    ("... pushed with gh unreadable says the CI half is unchecked",
     V(statuses={}, source="absent", pushed=True, base_had_plan=True, ci="unavailable"),
     "finished (series closed, CI unverified)"),
    ("... and a caller that never asked CI gets the same unverified answer",
     V(statuses={}, source="absent", pushed=True, base_had_plan=True),
     "finished (series closed, CI unverified)"),
    # A plan that was absent at base was never there to delete.  This is run
    # 3's shape - a builder told to recreate WORKPLAN.md - and the old rule
    # ("gone and pushed is finished") called it a finished run.
    ("a plan absent at base and at HEAD is not a close: it falls through to the rows",
     V(statuses={}, source="absent", pushed=True, base_had_plan=False,
       ci="success", how="derived", quiet_s=60), "unclear"),
    # Not `underway` either: with no rows at all and batches committed, the
    # no-row rule speaks first, and it is right to - a run whose batches are
    # landing against a plan nobody can read is exactly what `unclear` is for.
    # What matters is that it is not `finished`.
    ("... and with a batch declared it is still not finished",
     V(statuses={}, source="absent", pushed=True, base_had_plan=False,
       ci="success", how="derived", declared=["R1"]), "unclear"),
    ("... and unreadable at base is not a close either",
     V(statuses={}, source="absent", pushed=True, base_had_plan=None, ci="success"),
     "unclear"),
    ("an unreadable plan -> unclear",
     V(statuses=None, source="unreadable"), "unclear"),
    # Asking about a finished run after the plan was recreated for the next one.
    ("a present plan with no row for any of this run's batches -> unclear",
     V(statuses={"X1": "todo"}, how="pin (no candidate)", declared=["R1", "R2"]),
     "unclear"),
    ("... but before anything is declared, that is still just not started",
     V(statuses={"X1": "todo"}, how="pin (no candidate)"), "not started"),
    ("a question plus 10 min of quiet -> waiting on user",
     V(how="derived", asks=True, quiet_s=700), "waiting on user"),
    ("a limit notice plus quiet -> waiting on user",
     V(how="derived", limit_hit=True, quiet_s=700), "waiting on user"),
    ("a question with the session still live is not waiting yet",
     V(how="derived", asks=True, quiet_s=60), "applying plan"),
    ("waiting on user outranks an in-progress row",
     V(statuses={"R1": "in progress", "R2": "todo", "R3": "todo"},
       how="derived", asks=True, quiet_s=700), "waiting on user"),
    ("... but not a finished, pushed run",
     V(statuses=DONE, pushed=True, how="derived", asks=True, quiet_s=700),
     "waiting on user"),
]
VOCAB = {"not started", "applying plan", "waiting on user", "finished", "unclear"}
bad = 0
for name, got, want in cases:
    # `underway: batch ...` and `finished (...)` are qualified members of the
    # vocabulary, not new words: each begins with the word a caller matches on.
    ok_v = (got in VOCAB or got.startswith("underway: batch ")
            or got.startswith("finished ("))
    if got == want and ok_v: print("  PASS  %s" % name)
    else:
        print("  FAIL  %s\n        got %r want %r%s"
              % (name, got, want, "" if ok_v else "  (outside the vocabulary!)"))
        bad = 1
sys.exit(bad)
PY
[ $? -eq 0 ] || fail=1

# ---------------------------------------------------------------------------
echo
echo "underway - a batch that has landed (a), and one still in flight (b)"
# ---------------------------------------------------------------------------
# On 2026-09-30 a run-2 check said `applying plan` while batch L3's sub-agent
# was three edits into `spanweave/ids.py`.  Every clause was true - plan commit
# pushed, nothing declared, L3's row still `todo` - and the line as a whole
# said the run had not got going.  The builder marks a row `done` only AFTER
# the batch lands, so between the first dispatch and the first commit the rows
# and the log are both silent; the only evidence is a live sub-agent and a
# dirty tree.  That window is underway, not applying plan.
python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SPANWEAVE_OPS_DIR"])
from watch_lib import STALL_QUIET_S, first_todo, verdict

# The real run-2 shape: L4 and L5 are stopped by dependency markers, so the
# run's order matters - the answer is L3, and L6 is the next one after it.
B = ["L3", "L4", "L5", "L6"]
ROWS = {"L3": "todo", "L4": "awaiting L3", "L5": "awaiting L4", "L6": "todo"}

def V(**kw):
    a = dict(statuses=ROWS, source="worktree", batches=B, how="derived",
             quiet_s=60, pushed=True, asks=False, limit_hit=False,
             declared_since_base=[], head_past_base=True, pending=None,
             sub_quiet_s=None, dirty=False)
    a.update(kw)
    return verdict(a["statuses"], a["source"], a["batches"], a["how"],
                   a["quiet_s"], a["pushed"], a["asks"], a["limit_hit"],
                   a["declared_since_base"], head_past_base=a["head_past_base"],
                   pending=a["pending"], sub_quiet_s=a["sub_quiet_s"],
                   dirty=a["dirty"])[0]

INFLIGHT = "underway: batch L3 (in flight, uncommitted)"
cases = [
    # -- (a) a commit since base declared a batch of this run ----------------
    ("(a) a declared batch is underway even with every row still todo",
     V(declared_since_base=["L3"]), "underway: batch L3"),
    ("(a) holds without any sub-agent or dirty tree",
     V(declared_since_base=["L3"], pending=0, sub_quiet_s=None, dirty=False),
     "underway: batch L3"),
    ("(a) names the first row still open, not the one declared",
     V(statuses=dict(ROWS, L3="done (`abc1234`)"), declared_since_base=["L3"]),
     "underway: batch L6"),

    # -- (b) pushed plan + live sub-agent + dirty tree -----------------------
    ("(b) the exact 2026-09-30 state is underway, not applying plan",
     V(pending=1, dirty=True), INFLIGHT),
    ("(b) a subagents/ file inside the stall window carries it without pending",
     V(pending=0, sub_quiet_s=5 * 60, dirty=True), INFLIGHT),
    ("(b) pending alone carries it with no subagents/ mtime at all",
     V(pending=2, sub_quiet_s=None, dirty=True), INFLIGHT),
    ("(b) names the first TODO batch in the run's order, skipping the blocked",
     V(statuses=dict(ROWS, L3="done (`abc1234`)"), pending=1, dirty=True),
     "underway: batch L6 (in flight, uncommitted)"),

    # -- each conjunct of (b) is load-bearing --------------------------------
    ("a clean tree is not a batch in flight",
     V(pending=1, dirty=False), "unclear"),
    ("a dirty tree with no sub-agent is not a batch in flight",
     V(pending=0, sub_quiet_s=None, dirty=True), "unclear"),
    ("a sub-agent quiet past the stall window is not in flight",
     V(pending=0, sub_quiet_s=STALL_QUIET_S + 60, dirty=True), "unclear"),
    ("an unpushed plan commit is applying plan, and outranks in-flight",
     V(pushed=False, pending=1, dirty=True), "applying plan"),
    ("no plan commit at all is applying plan, however busy the tree",
     V(head_past_base=False, pending=1, dirty=True), "applying plan"),

    # -- `applying plan` is now ONLY the two plan-commit states --------------
    ("a live builder with the plan pushed and nothing moving is not 'applying plan'",
     V(pending=0, dirty=False), "unclear"),
    ("a live builder with the plan unpushed is applying plan",
     V(pushed=False), "applying plan"),
    ("a live builder with no plan commit yet is applying plan",
     V(head_past_base=False), "applying plan"),

    # -- the rules that already outranked underway still do ------------------
    ("a row that says in progress still wins over in-flight",
     V(statuses=dict(ROWS, L3="in progress"), pending=1, dirty=True),
     "underway: batch L3"),
    ("waiting on user still outranks a batch in flight",
     V(pending=1, dirty=True, asks=True, quiet_s=700), "waiting on user"),
    ("a finished, pushed run is not in flight whatever the tree looks like",
     V(statuses={b: "done (`abc1234`)" for b in B}, pending=1, dirty=True),
     "finished"),
]
bad = 0
for name, got, want in cases:
    # The qualified form is still `underway`, not a seventh word: a caller
    # matching the vocabulary must not have to learn a new prefix.
    ok_v = (got in {"not started", "applying plan", "waiting on user",
                    "finished", "unclear"}
            or got.startswith("underway: batch "))
    if got == want and ok_v:
        print("  PASS  %s" % name)
    else:
        print("  FAIL  %s\n        got %r want %r%s"
              % (name, got, want, "" if ok_v else "  (outside the vocabulary!)"))
        bad = 1

for name, got, want in [
    ("first_todo takes the run's order, not the alphabet",
     first_todo({"L3": "done (`a`)", "L4": "todo", "L6": "todo"}, ["L6", "L3", "L4"]), "L6"),
    ("first_todo skips a row that is already running",
     first_todo({"L3": "in progress", "L6": "todo"}, ["L3", "L6"]), "L6"),
    ("first_todo skips a dependency marker",
     first_todo({"L3": "done (`a`)", "L4": "awaiting L3", "L6": "todo"},
                ["L3", "L4", "L6"]), "L6"),
    ("first_todo has no answer when every row is stopped",
     first_todo({"L3": "done (`a`)"}, ["L3"]), None),
]:
    if got == want:
        print("  PASS  %s" % name)
    else:
        print("  FAIL  %s\n        got %r want %r" % (name, got, want)); bad = 1
sys.exit(bad)
PY
[ $? -eq 0 ] || fail=1

echo
if [ "$fail" -eq 0 ]; then echo "selftest: all cases pass"; else echo "selftest: FAILURES above"; fi
exit "$fail"
