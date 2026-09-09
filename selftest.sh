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

# -- tripwire: reported, watch continues, each commit reported once ----------
transcript "Working on B3 now."
touch "$BUILDER"
GIT_COMMITTER_DATE="$(date -d '-85 min' -R)" GIT_AUTHOR_DATE="$(date -d '-85 min' -R)" \
git -C "$R2" commit -q --allow-empty -F - <<'MSG'
reader: unrelated

Batch B1 of WORKPLAN.md. Not in the run list.
MSG
age_index "$(date -d '-90 min' '+%Y-%m-%d %H:%M:%S')"
check "tripwire is non-terminal: it reports and exits 0" "$(run2)" "0|tripwire"
grep -q "watch continues" "$TMP/last_run.txt" && ok "the block says the watch continues" \
  || bad "the block does not say the watch continues"
age_index "$(date -d '-90 min' '+%Y-%m-%d %H:%M:%S')"
check "the same commit is not reported a second time" "$(run2)" "0|"
GIT_COMMITTER_DATE="$(date -d '-80 min' -R)" GIT_AUTHOR_DATE="$(date -d '-80 min' -R)" \
git -C "$R2" commit -q --allow-empty -F - <<'MSG'
reader: another

Batch G1 of WORKPLAN.md. Also not in the run list.
MSG
age_index "$(date -d '-90 min' '+%Y-%m-%d %H:%M:%S')"
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
touch -d '-20 min' "$BUILDER"
age_index "$(date -d '-90 min' '+%Y-%m-%d %H:%M:%S')"
check "waiting on user is non-terminal and reports once" "$(run2)" "0|waiting on user"
touch -d '-20 min' "$BUILDER"; age_index "$(date -d '-90 min' '+%Y-%m-%d %H:%M:%S')"
check "a repeat waiting-on-user poll is suppressed" "$(run2)" "0|"
touch "$BUILDER"; age_index "$(date -d '-90 min' '+%Y-%m-%d %H:%M:%S')"
check "liveness returning emits one RESUMED line" "$(run2)" "0|RESUMED"
grep -q '^>>> LINE RESUMED after waiting on user' "$TMP/last_run.txt" \
  && ok "the RESUMED line names what it resumed from" \
  || bad "the RESUMED line does not name what it resumed from"
grep -q 'liveness .* -> ' "$TMP/last_run.txt" && ok "the RESUMED line names what moved" \
  || bad "the RESUMED line does not name what moved"
touch -d '-20 min' "$BUILDER"; age_index "$(date -d '-90 min' '+%Y-%m-%d %H:%M:%S')"
check "after a resume, waiting on user can fire again" "$(run2)" "0|waiting on user"

# -- stall: once, then only after a further 40 minutes -----------------------
python3 - "$ST2/watch_state.json" <<'PY'
import json, sys
st = json.load(open(sys.argv[1])); st.pop("waiting", None); st.pop("stall", None)
json.dump(st, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
transcript "Running the batch."
touch -d '-60 min' "$BUILDER"
age_index "$(date -d '-90 min' '+%Y-%m-%d %H:%M:%S')"
check "stall is non-terminal and reports once" "$(run2)" "0|stall"
touch -d '-60 min' "$BUILDER"; age_index "$(date -d '-90 min' '+%Y-%m-%d %H:%M:%S')"
check "a repeat stall poll inside 40 min is suppressed" "$(run2)" "0|"
python3 - "$ST2/watch_state.json" <<'PY'
import json, sys, time
st = json.load(open(sys.argv[1]))
if "stall" not in st:
    print("  FAIL  no stall record in watch_state.json to age"); sys.exit(1)
st["stall"]["fired_at"] = time.time() - 41 * 60      # pretend 41 min have passed
json.dump(st, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
touch -d '-60 min' "$BUILDER"; age_index "$(date -d '-90 min' '+%Y-%m-%d %H:%M:%S')"
check "stall fires a second time after a further 40 min" "$(run2)" "0|stall"
grep -q "TRIGGER: stall (still," "$TMP/last_run.txt" && ok "the repeat says it is a repeat" \
  || bad "the repeat does not say it is a repeat"
touch "$BUILDER"; age_index "$(date -d '-90 min' '+%Y-%m-%d %H:%M:%S')"
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

echo
if [ "$fail" -eq 0 ]; then echo "selftest: all cases pass"; else echo "selftest: FAILURES above"; fi
exit "$fail"
