# spanweave-ops

Read-only operator tooling for a **spanweave `WORKPLAN.md` series** — the
run-by-run execution of a plan in `~/git/spanweave`. It was written for the
audit-fixes series and is not tied to it: the branch it watches and the builder
processes it watches for are **derived at arming time**, never named in a
constant.

Nothing here writes to that repo. Nothing here runs `make`, `uv`, or `pytest`.
The only writes are under `state/`, which is gitignored. `WATCH.md` is the
behaviour contract; this file is how to run it.

## The scripts

| file | what it does |
|---|---|
| `watch_run.sh` | One watch invocation: polls every 5 min for at most 9 min, evaluates the five triggers, prints events. The whole policy lives here. |
| `watch_monitor.sh` | Arming path under the **Monitor** tool. Re-invokes `watch_run.sh` forever; forwards only event blocks to stdout, banners to `state/poll.log`, plus an hourly `HEARTBEAT`. Stops on a terminal trigger. |
| `watch_loop.sh` | Arming path in a **plain terminal**. Re-invokes `watch_run.sh` forever, everything to the terminal. Stops on a terminal trigger. |
| `status_check.sh` | One-shot status report. Writes nothing anywhere. |
| `arming.sh` | Sourced by all four. Resolves, **once**, the two facts that must be fixed when a watch is armed rather than re-read per poll: the branch and the builder PID set. |
| `watch_lib.py` | Shared read-only helpers — the transcript-derivation rule, the tripwire's batch-declaration rule, `WORKPLAN.md` parsing, transcript tails. Both entry points import it, so each rule has one implementation. |
| `selftest.sh` | 160 cases over throwaway fixtures. Proves both rules, the derived branch and PID defaults, the verdict vocabulary — including both underway branches — and every dedup path. Touches neither the real repo nor the real transcript directory. |

## What you have to pass, and what you do not

Three things are **derived**, so the only flags a normal invocation needs are
`--run`, `--batches` and `--base`:

| | derived from | pass it only when |
|---|---|---|
| the branch | `git symbolic-ref --short HEAD` in `~/git/spanweave`, read **once at arming** | you want to watch a branch the repo is not on — which is also what arms the wrong-branch tripwire |
| the builder PID set | the `claude --dangerous…` processes alive **at arming**, via `pgrep` | you know which processes are the builder's and the derived set is wrong |
| the builder transcript | the derivation rule in `WATCH.md` — prompt, run number, not-an-aux-session | the derivation cannot see your session; then `SPANWEAVE_PINNED=<uuid>.jsonl` |

None of the three is a constant any more, and that is the point: each one named
a *session*, so each was stale by the run after the one it was written for. See
the note at the end of this file.

## Invocations

Status, right now:

```bash
~/spanweave-ops/status_check.sh --run 2 --batches "L3 L4 L5 L6" --base 27ec3db
```

Arm — **Monitor path** (the one in use; survives the host's low-memory guard
better than a tracked background task, because the Monitor holds it for the
session):

```bash
~/spanweave-ops/watch_monitor.sh --run 2 --batches "L3 L4 L5 L6" --base 27ec3db
```

Arm — **plain-loop path** (a terminal you will watch yourself):

```bash
~/spanweave-ops/watch_loop.sh --run 2 --batches "L3 L4 L5 L6" --base 27ec3db
```

Re-arm **after a usage-limit reset**. The builder is usually `/clear`ed and
resumed, which forks a new transcript file, and its PIDs change. Just re-arm —
the new PID set is picked up by the arming itself. Leave `state/` alone so the
tripwire does not re-report commits it already reported:

```bash
~/spanweave-ops/status_check.sh --run 2 --batches "…"   # confirm the derived transcript
~/spanweave-ops/watch_monitor.sh --run 2 --batches "…" --base <sha>
```

The transcript derivation follows the resumed session on its own as long as its
prompt says `Resume WORKPLAN.md`, or mentions `WORKPLAN.md` and names the run —
the run number need not be adjacent to the filename, so being pointed at a
handover file (`Apply ~/Downloads/run3-2026-09-11.md … recreate WORKPLAN.md …`)
is enough. If it does not, pass `SPANWEAVE_PINNED=<uuid>.jsonl`. To start the
tripwire from scratch instead, `rm state/watch_state.json` first.

**Why arming reads them once.** Both derived values are observations about the
*start* of a watch, and re-reading either per poll would disarm a trigger
rather than keep it fresh. `builder gone` fires when the PID set **shrinks**; a
set re-derived each poll can never shrink. The branch tripwire fires when the
checkout is not the branch being watched; a branch re-derived each poll would
follow the builder onto any branch and call it normal. So `watch_monitor.sh`
and `watch_loop.sh` — which re-invoke `watch_run.sh` every few minutes — arm
once at their own start and export both down.

Pass `--memo "R3"` to name the run's memo-only batches — the ones that must end
`awaiting decision` and never touch `spanweave/`. It defaults to run 2's `F1`.

Self-test:

```bash
~/spanweave-ops/selftest.sh          # exit 0 = all cases pass
```

## What `status_check.sh` says

The last line of the report is a **verdict**, drawn from a closed vocabulary
of six values — one of which, `underway`, takes a qualifier saying which
evidence carried it. Nothing else appears on that line, so a caller can match
it exactly; the evidence it was derived from is printed underneath it.

| verdict | means | derived from |
|---|---|---|
| `not started` | the run has not begun | no builder transcript derived for this run, **and** no commit since base declares one of its batches |
| `applying plan` | the run's plan commit is still being made | a derived transcript with liveness under 10 min, **and** the plan commit is absent or not pushed. That is *all* it means now |
| `underway: batch <ID>` | a batch is being worked, and something has landed | a row says something other than `todo`/stopped, else the first still-open row once a commit since base has **declared** one of the run's batches |
| `underway: batch <ID> (in flight, uncommitted)` | a batch is being worked and nothing has landed yet | the plan commit is pushed, **and** a builder sub-agent is live (`pendingBackgroundAgentCount ≥ 1`, or a `subagents/` file touched within the 40-min stall window), **and** the tree has uncommitted changes. `<ID>` is the first `todo` batch in the run's section-2 execution order |
| `waiting on user` | blocked on a human | the last assistant entry asks a question, or a usage/rate-limit notice appears, **and** liveness has been still ≥ 10 min |
| `finished` | the run is done | every batch stopped (or `WORKPLAN.md` gone) **and** HEAD is pushed |
| `unclear` | the evidence does not settle it | an unreadable plan; a plan with no row for any batch of this run while some are committed; every batch stopped but HEAD unpushed with nothing live; a quiet derived builder that has declared nothing; a live one with the plan pushed, no row moved and nothing in flight |

The qualified form is still `underway`, not a seventh word — it begins
`underway: batch `, which is what a caller matches on. The parenthetical is
there because it is a **weaker** claim than the unqualified one: no commit has
declared the batch, so the evidence is activity, not a result.

`waiting on user` outranks everything except a finished, pushed run: a session
blocked on a human is not advancing, whatever the rows say. A row that says
`in progress` outranks the in-flight reading, and so does a declared commit.

### Why in-flight is its own answer

On 2026-09-30 a run-2 check reported `applying plan` while batch L3's sub-agent
was three edits into `spanweave/ids.py`. Every clause was true — the plan
commit was pushed, no commit had declared L3, its row still said `todo` — and
the line as a whole said the run had not got going. It had.

The builder marks a row `done` only **after** a batch lands, so between a run's
first dispatch and its first commit the rows and the log are both silent. The
only evidence in that window is a live sub-agent and a dirty tree, and all
three conjuncts are load-bearing: an unpushed plan commit means the plan is
still being applied; a dirty tree alone is any stray edit or an untracked
scratch directory; a live sub-agent alone may be a plan-only helper that never
touches the tree.

**Why a closed vocabulary.** The old last line was free-form, and on 2026-09-10
it read `ALIVE (liveness 5.7 min ago) | run 3: 0/7 batches stopped, active: R1,
R2, R4, R6, R5, R3, R7`. Every clause was true and the line as a whole was
false: the liveness was a `/clear` typed into the *finished* run-2 session, and
the seven "active" batches were seven rows the parser could not see, because
batch ids were matched as `[A-H]\d+` and run 3's are `R1`–`R7`. A reader
skimming that line would have concluded run 3 was underway. It had not started.

## Per-trigger policy

Only two triggers end the watch. The rest report and keep polling, so a false
positive costs a paragraph rather than the whole watch.

| trigger | stops the watch? | repeats? |
|---|---|---|
| **finished** | yes (exit `10`) | — |
| **builder gone** | yes (exit `13`) | — |
| **tripwire** | no | each commit sha once, ever |
| **waiting on user** | no | once, then suppressed until liveness moves |
| **stall** | no | once, then only after a further 40 min with nothing moving |

When a suppressed `waiting on user` or `stall` lifts, one line says so and says
what moved:

```
RESUMED after stall (quiet 51.0 min): liveness 02:10:04 -> 03:01:12; HEAD a9f6fd9 -> 7f68aca
```

`WATCH.md` has the full definition of each trigger and its evidence block.

## The series ends by deleting the plan

G4, the last batch, removes `WORKPLAN.md`. The watch reads the rows from the
working tree, else from `HEAD` while the deletion is staged, else treats the
plan as **closed** — no rows, nothing open, `finished` reachable. A missing
plan is never a watcher error; a present-but-unreadable one still is, after two
retries.

## Exit codes

| code | meaning |
|---|---|
| `0` | invocation ran its budget out; non-terminal events may have been reported |
| `10` | **finished** — origin moved past base, HEAD matches it, no batch still open |
| `13` | **builder gone** — a PID from the arming set disappeared while the run is incomplete. An **empty** arming set cannot shrink, so the trigger has no signal; every poll banner says `no PID set: 'builder gone' disarmed` rather than looking quiet |
| `2` | watcher error (no builder transcript, `WORKPLAN.md` unreadable, unhandled exception) or bad usage |

`status_check.sh` exits `0` when it printed a report, `2` on the same watcher
errors.

## The memory-kill note

**A dead watch is not a finished watch.** Twice on 2026-09-10 the host's
low-memory guard killed an armed `watch_loop.sh` while it slept between polls.
A kill is silent: no event, no evidence block, no non-zero exit anyone sees.

How to tell a kill from a trigger:

- a **trigger** ends with an event block on stdout and, for a terminal one, exit
  `10`/`13`; `state/last_evidence.txt` is fresh
- a **kill** leaves `state/poll.log` ending in an ordinary `poll …` banner, with
  no event after it, and nothing new in `state/last_evidence.txt`

If the watch has simply gone quiet, check `tail -3 state/poll.log` against the
clock before believing the builder is idle. Re-arming after a kill is safe:
`watch_state.json` survives, so the tripwire resumes from where it left off
rather than re-reporting old commits.

The Monitor path (`watch_monitor.sh` under the Monitor tool with
`persistent: true`) is the arming path in use precisely because it is held for
the session rather than as a tracked background bash task.

## The stale-constant note

**A constant that names a session is a lie in the next run.** Three defaults
here were written down during the audit-fixes series and every one of them was
wrong by 2026-09-30, when the repo had moved to `live-graphs`:

- `DEF_BRANCH = "audit-fixes"` — `git fetch origin audit-fixes` failed with
  *couldn't find remote ref*, so `origin` read as a stale sha belonging to a
  branch nobody was on, and the report printed a confident
  `NOT pushed (origin b863767)` derived from it. `finished` was structurally
  unreachable for the whole watch.
- `DEF_PIDS` — four PIDs from 2026-09-10, all long exited, so a watch taking
  the default was armed to fire `builder gone` — a *terminal* trigger — on its
  first poll, on evidence about processes dead for weeks.
- `DEF_PINNED` — run 2's builder transcript, so every later run reported
  `<-- FOLLOWED off the pin` while the derivation was in fact working. A drift
  notice that fires when nothing has drifted trains the reader to ignore it.

All three are derived now, and `selftest.sh` holds each one in place: the
branch from the checkout and from a detached HEAD, the PID set from a synthetic
`pgrep` (including that the `pgrep` wrapper never enrols itself in the set it
is about to watch), and the fact that an empty set and an unset one are
different answers.
