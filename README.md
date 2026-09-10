# spanweave-ops

Read-only operator tooling for the **spanweave audit series** — the run-by-run
execution of `WORKPLAN.md` on branch `audit-fixes` in `~/git/spanweave`.

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
| `watch_lib.py` | Shared read-only helpers — the transcript-derivation rule, the tripwire's batch-declaration rule, `WORKPLAN.md` parsing, transcript tails. Both entry points import it, so each rule has one implementation. |
| `selftest.sh` | 50 cases over throwaway fixtures. Proves both rules and every dedup path. Touches neither the real repo nor the real transcript directory. |

## Invocations

Status, right now:

```bash
~/spanweave-ops/status_check.sh --run 2 --batches "A5 A6 A7 A8 B3 A9 C3 D2 H2 G5 E2 E3 E4 F1 F2 G4"
```

Arm — **Monitor path** (the one in use; survives the host's low-memory guard
better than a tracked background task, because the Monitor holds it for the
session):

```bash
~/spanweave-ops/watch_monitor.sh --run 2 \
  --batches "A5 A6 A7 A8 B3 A9 C3 D2 H2 G5 E2 E3 E4 F1 F2 G4" \
  --base c79cbc5 --pids "820503 820602 820711 820816"
```

Arm — **plain-loop path** (a terminal you will watch yourself):

```bash
~/spanweave-ops/watch_loop.sh --run 2 \
  --batches "A5 A6 A7 A8 B3 A9 C3 D2 H2 G5 E2 E3 E4 F1 F2 G4" \
  --base c79cbc5 --pids "820503 820602 820711 820816"
```

Re-arm **after a usage-limit reset**. The builder is usually `/clear`ed and
resumed, which forks a new transcript file, and its PIDs usually change. Take a
fresh PID set and re-arm; leave `state/` alone so the tripwire does not
re-report commits it already reported:

```bash
pgrep -af claude                                   # note the new PID set
~/spanweave-ops/status_check.sh --run 2 --batches "…"   # confirm the derived transcript
~/spanweave-ops/watch_monitor.sh --run 2 --batches "…" --base c79cbc5 \
  --pids "<the new set>"
```

The derivation follows the resumed session on its own as long as its first
prompt says `Resume WORKPLAN.md` or `WORKPLAN.md run 2`; if it does not, pass
`SPANWEAVE_PINNED=<uuid>.jsonl`. To start the tripwire from scratch instead,
`rm state/watch_state.json` first.

Self-test:

```bash
~/spanweave-ops/selftest.sh          # exit 0 = all cases pass
```

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
plan as **closed** — no rows, nothing active, `finished` reachable. A missing
plan is never a watcher error; a present-but-unreadable one still is, after two
retries.

## Exit codes

| code | meaning |
|---|---|
| `0` | invocation ran its budget out; non-terminal events may have been reported |
| `10` | **finished** — origin moved past base, HEAD matches it, no batch still active |
| `13` | **builder gone** — a PID from the arming set disappeared while the run is incomplete |
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
