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
git -C "$R" add -A && git -C "$R" commit -qm "base"
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
printf '%s\n' "$out" | grep -q "plan from absent" \
  && ok "the banner reports the plan as absent" \
  || bad "the banner does not report the plan as absent"
printf '%s\n' "$out" | grep -q "active: (none)" \
  && ok "a closed plan leaves no batch active" \
  || bad "a closed plan still shows an active batch"

# (3) with the plan closed and the branch pushed, `finished` is reachable.
git -C "$R2" push -q origin audit-fixes
out="$(SPANWEAVE_STATE_DIR="$ST2" SPANWEAVE_REPO="$R2" SPANWEAVE_TDIR="$TD2" \
       SPANWEAVE_PINNED="11111111.jsonl" SPANWEAVE_SELF="none.jsonl" \
       SPANWEAVE_BASE="$BASE2" SPANWEAVE_BRANCH=audit-fixes \
       SPANWEAVE_PIDS="" SPANWEAVE_BATCHES="A5 B3" \
       "$OPS_DIR/watch_run.sh" --once --run 2 2>&1)"
check "a closed, pushed plan still reaches finished" "$?" "10"
printf '%s\n' "$out" | grep -q "the series is closed" \
  && ok "the finished block says the series is closed" \
  || bad "the finished block does not say the series is closed"

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
      pushed=False, asks=False, limit_hit=False, declared=()):
    return verdict(statuses, source, batches, how, quiet_s, pushed,
                   asks, limit_hit, list(declared))[0]

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
    ("plan removed and pushed -> finished",
     V(statuses={}, source="absent", pushed=True), "finished"),
    ("plan removed but unpushed -> unclear",
     V(statuses={}, source="absent", pushed=False), "unclear"),
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
    ok_v = got in VOCAB or got.startswith("underway: batch ")
    if got == want and ok_v: print("  PASS  %s" % name)
    else:
        print("  FAIL  %s\n        got %r want %r%s"
              % (name, got, want, "" if ok_v else "  (outside the vocabulary!)"))
        bad = 1
sys.exit(bad)
PY
[ $? -eq 0 ] || fail=1

echo
if [ "$fail" -eq 0 ]; then echo "selftest: all cases pass"; else echo "selftest: FAILURES above"; fi
exit "$fail"
