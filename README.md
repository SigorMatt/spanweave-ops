# spanweave-ops

Read-only operator tooling for a **spanweave `WORKPLAN.md` series** — the
run-by-run execution of a plan in a repo you name with `--repo` (default
`~/git/spanweave`). It was written for the audit-fixes series and is not tied
to it, nor to one repository: the branch it watches, the builder processes it
watches for and the transcript directory it reads are all **derived from the
repo at arming time**, never named in a constant.

Nothing here writes to that repo. Nothing here runs `make`, `uv`, or `pytest`.
The only writes are under `state/`, which is gitignored. `WATCH.md` is the
behaviour contract; this file is how to run it.

## The scripts

| file | what it does |
|---|---|
| `watch_run.sh` | One watch invocation: polls every 5 min for at most 9 min, evaluates the five triggers, prints events. The whole policy lives here. |
| `watch_monitor.sh` | Arming path under the **Monitor** tool. Re-invokes `watch_run.sh` forever; forwards only event blocks to stdout, plus an hourly `HEARTBEAT`; it never writes `state/poll.log`, which `watch_run.sh` alone appends to, once per banner and once per event. Stops on a terminal trigger. |
| `watch_loop.sh` | Arming path in a **plain terminal**. Re-invokes `watch_run.sh` forever, everything to the terminal. Stops on a terminal trigger. |
| `status_check.sh` | One-shot status report. Writes nothing anywhere. |
| `arming.sh` | Sourced by all four. Resolves, **once**, the two facts that must be fixed when a watch is armed rather than re-read per poll: the branch and the builder PID set — both read from the watched repo, which is why it also pulls `--repo` out of argv for the two looping front ends. |
| `watch_lib.py` | Shared read-only helpers — the transcript-derivation rule, the tripwire's batch-declaration rule, `WORKPLAN.md` parsing, transcript tails. Both entry points import it, so each rule has one implementation. |
| `selftest.sh` | 400 cases over throwaway fixtures. Proves both rules, the floor read backwards and forwards, the derived branch, PID and transcript-directory defaults, `--repo` reaching arming on every entry point, the batch-id pattern over an `R`-prefixed plan, the verdict vocabulary — including both underway branches and both finished qualifiers — all four CI answers behind `finished`, the series close and the absence that is not one, every dedup path, and one banner being one `poll.log` line. Touches neither the real repo nor the real transcript directory, and never runs the real `gh` or the real `pgrep`. |

## What you have to pass, and what you do not

Four things are **derived**, so the only flags a normal invocation needs are
`--run`, `--batches` and `--base` — plus `--repo` when the series is not in
`~/git/spanweave`:

| | derived from | pass it only when |
|---|---|---|
| the branch | `git symbolic-ref --short HEAD` in the watched repo, read **once at arming** | you want to watch a branch the repo is not on — which is also what arms the wrong-branch tripwire |
| the builder PID set | the `claude --dangerous…` processes alive **at arming** whose working directory is inside the watched repo, via `pgrep` | you know which processes are the builder's and the derived set is wrong |
| the transcript directory | Claude Code's project directory for the watched repo — its absolute path with every non-alphanumeric character replaced by `-` | Claude Code's encoding changes, or the sessions are under another path; then `SPANWEAVE_TDIR=<dir>` |
| the builder transcript | the derivation rule in `WATCH.md` — prompt, run number, not-an-aux-session, **and last written no earlier than the base commit**; failing the run number, the one post-base non-aux transcript about the plan, if there is exactly one | the derivation cannot see your session, or two post-base sessions could be it; then `SPANWEAVE_PINNED=<uuid>.jsonl` |

None of the four is a constant any more, and that is the point: three of them
named a *session* and one named a *repository*, so each was stale by the run —
or the project — after the one it was written for. See the note at the end of
this file.

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
is enough — **and** the transcript was last written no earlier than the base
commit. If it does not, pass `SPANWEAVE_PINNED=<uuid>.jsonl`; a pin is an
operator override and is tested against neither the run number nor the base. To
start the tripwire from scratch instead, `rm state/watch_state.json` first.

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

### Why the base commit is a floor on the transcript

**A run number is per-series; a date is about this run.** On 2026-10-01 a run-3
watch of the `live-graphs` series derived onto `351ac45a-…jsonl`, whose own mtime
was 2026-09-11 00:37 and whose `subagents/` was 2026-09-10 17:09 — twenty days
before the base (`ce9ff17`, authored 2026-10-01 00:23:40) it was armed on. It
reported that finished session's liveness and then `finished`. Its prompt (`Apply
~/Downloads/run3-2026-09-11.md … single commit plan: reopen for run 3 -- run-2
review…`) is a *correct* run-3 builder prompt — for the **September audit
series'** run 3. No prompt rule can tell the two apart, because `run 3` is all
either of them says.

It won with no contest because the real builder was not a candidate at all. A
stored `lastPrompt` is cut at about 200 characters, and `1d41a6d1-…jsonl` stored
`… one plan-only sub-agent, one commit plan: run-2 rev…` — the only run number
inside the cut is **2**. The phrase naming run 3 was never written down.

So candidacy now has a floor: a transcript whose **last write** — the newer of
its own mtime and its `subagents/` directory mtime — predates the base commit's
**author** time cannot be the builder's, whatever its prompt says, and is
reported as a near miss with both timestamps rather than quietly dropped. If the
floor leaves nothing and no pin was given, the watch does not error: liveness is
**unknown**, every banner says so, and `WATCH.md` has what that does to the stall
rule.

**And the same floor, read forwards.** On 2026-10-02 run 5 had landed L23,
pushed it, and was mid-L24 with a sub-agent live — and *no* transcript named
run 5: the builder was the session told to apply the **run-4** review
decisions, which made the base commit itself and rolled straight into run 5
without a new prompt, its `lastPrompt` naming run 4 inside the 200-character
cut. Both entry points said "no builder transcript found for run 5" and exited
`2`, about a live builder that was the only session written since the base.

So when no prompt names run `N`, the floor is asked the other question. Among
the transcripts that are about `WORKPLAN.md`, are not aux prompts, are not this
session's own, and were written **since** the base commit, **exactly one is an
answer**: it is derived, and every banner and the report say
`derived by floor, not by run number` rather than letting it pass for a
prompt-derived choice. **Two or more is not an answer** — the floor cannot pick
between two sessions that both started after the base, so that stays a watcher
error, exit `2`, with both files named so you can pin one. A base the repo
cannot resolve gives no floor at all, so the fallback is simply unavailable:
"clears the floor" must not degrade into "exists". The fallback drops the run
number and *only* the run number — the aux test, the self test and the floor
all still stand.

Self-test:

```bash
~/spanweave-ops/selftest.sh          # exit 0 = all cases pass
```

## What `status_check.sh` says

The last line of the report is a **verdict**, drawn from a closed vocabulary
of six values — two of which, `underway` and `finished`, take a qualifier
saying which evidence carried it. Nothing else appears on that line, so a
caller can match it exactly; the evidence it was derived from is printed
underneath it.

| verdict | means | derived from |
|---|---|---|
| `not started` | the run has not begun | no builder transcript derived for this run, **and** no commit since base declares one of its batches |
| `applying plan` | the run's plan commit is still being made | a derived transcript with liveness under 10 min, **and** the plan commit is absent or not pushed. That is *all* it means now |
| `underway: batch <ID>` | a batch is being worked, and something has landed | a row says something other than `todo`/stopped, else the first still-open row once a commit since base has **declared** one of the run's batches |
| `underway: batch <ID> (in flight, uncommitted)` | a batch is being worked and nothing has landed yet | the plan commit is pushed, **and** a builder sub-agent is live (`pendingBackgroundAgentCount ≥ 1`, or a `subagents/` file touched within the 40-min stall window), **and** the tree has uncommitted changes. `<ID>` is the first `todo` batch in the run's section-2 execution order |
| `waiting on user` | blocked on a human | the last assistant entry asks a question, or a usage/rate-limit notice appears, **and** liveness has been still ≥ 10 min |
| `finished` | the run is done | every batch stopped **and** HEAD is pushed |
| `finished (series closed)` | the run is done, and it was the one that closed the series | `WORKPLAN.md` was **present at `--base`** and is **absent at HEAD** — this run deleted it — **and** HEAD is pushed **and** CI on the pushed tip is green |
| `finished (series closed, CI unverified)` | the same end state, with the CI half unread | all of the above except that `gh` could not be read, so nothing has verified green |
| `unclear` | the evidence does not settle it | an unreadable plan; a plan with no row for any batch of this run while some are committed; every batch stopped but HEAD unpushed with nothing live; a quiet derived builder that has declared nothing; a live one with the plan pushed, no row moved and nothing in flight; **a deleted plan whose tip is unpushed, or whose CI is pending or red** |

The qualified forms are still `underway` and `finished`, not new words — each
begins with the word a caller matches on. `underway`'s parenthetical is there
because it is a **weaker** claim than the unqualified one: no commit has
declared the batch, so the evidence is activity, not a result. `finished`'s
says why there are no batch rows printed underneath it — the last batch deleted
them — so an empty status block is not read as the parser losing the rows
again.

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

Only the finished trigger and `builder gone` end the watch. The rest report
and keep polling, so a false positive costs a paragraph rather than the whole
watch.

`finished` asks one more question than "is it pushed?": what CI concluded on
the pushed tip. `WORKPLAN.md` 0.1 step 8 ends a run at *pushed **and** green*,
and says a local `make check` is not a substitute. So the answer has four
shapes, not two — and the three that end the watch say which one they are:

| CI on the tip | what the watch does |
|---|---|
| success | fires `finished` — or `finished (series closed)`, where this run deleted the plan — exit `10` |
| queued / running / no run for the sha yet | does not fire; one note, and the poll loop goes on |
| any other conclusion | fires `finished: CI red on <sha>`, exit `15` |
| `gh` could not tell us anything | fires `finished (CI unverified)`, exit `10` |

The last row is the one worth reading twice. A missing, unauthenticated,
rate-limited or timed-out `gh` is not evidence that CI is red, and it is not
evidence that CI is green either. The watch stops — the run *is* pushed and
every batch has stopped — but it says the CI half is unchecked rather than
printing a `finished` that quietly means "we did not look".

| trigger | stops the watch? | repeats? |
|---|---|---|
| **finished** | yes (exit `10`) | — |
| **finished (series closed)** | yes (exit `10`) | — |
| **finished (CI unverified)** | yes (exit `10`) | — |
| **finished (series closed, CI unverified)** | yes (exit `10`) | — |
| **finished: CI red on `<sha>`** | yes (exit `15`) | — |
| **builder gone** | yes (exit `13`) | — |
| **tripwire** | no | each commit sha once, ever |
| **waiting on user** | no | once, then suppressed until liveness moves |
| **stall** | no | once, then only after a further 40 min with nothing moving |

When liveness is **unknown** — no transcript in the directory was written after
the base commit, and no pin was given — the stall keeps that schedule exactly and
runs on the commit and `.git/index` times alone. Liveness neither arms it nor
holds it off, and nothing moving in the transcript directory can emit a
`RESUMED`, because the watch is not watching a transcript.

When a suppressed `waiting on user` or `stall` lifts, one line says so and says
what moved:

```
RESUMED after stall (quiet 51.0 min): liveness 02:10:04 -> 03:01:12; HEAD a9f6fd9 -> 7f68aca
```

`WATCH.md` has the full definition of each trigger and its evidence block.

## The series ends by deleting the plan

G4, the last batch, removes `WORKPLAN.md`. The watch reads the rows from the
working tree, else from `HEAD` while the deletion is staged, else there are no
rows at all. A missing plan is never a watcher error; a present-but-unreadable
one still is, after two retries.

**No rows is not by itself a closed series.** Two states look identical to a
reader of the worktree:

| at `--base` | at HEAD | what it is |
|---|---|---|
| present | absent | the **close** — this run deleted the plan |
| absent | absent | a plan **not written yet** — nothing was deleted |

The second is run 3's shape: its builder was started with *"recreate
`WORKPLAN.md` from `git show c79cbc5:WORKPLAN.md`"*, so it had no plan at base
and none at HEAD either until its plan commit landed. The old rule — "gone and
pushed is finished" — called that a finished run. So the absence is read
against git's answer for the base commit, and that answer has three values:
present (the close), absent (not a close — every batch stays open and
`finished` is unreachable from the absence), and **could not be read**, which
is not treated as either.

A close is `finished` on exactly the same terms as a run with rows: **pushed
and green.** A closed plan has no rows left to carry `WORKPLAN.md` 0.1 step
8's second half, so the only evidence for green is CI on the pushed tip —
absent with the tip unpushed, or with CI pending or red, is **not** finished.
`status_check.sh` asks `gh` for exactly this case and no other, and prints the
answer it used on a `ci :` line.

## Exit codes

| code | meaning |
|---|---|
| `0` | invocation ran its budget out; non-terminal events may have been reported |
| `10` | **finished** — origin moved past base, HEAD matches it, no batch still open, and CI on the tip concluded success. Also the code for **finished (series closed)**, which is that end state reached by *deleting* the plan, and for the **(CI unverified)** form of either, where all of it holds but `gh` could not be read |
| `15` | **finished: CI red on `<sha>`** — the push landed and every batch stopped, but CI on the pushed tip concluded something other than success |
| `13` | **builder gone** — a PID from the arming set disappeared while the run is incomplete. An **empty** arming set cannot shrink, so the trigger has no signal; every poll banner says `no PID set: 'builder gone' disarmed` rather than looking quiet |
| `2` | watcher error (no transcript in the directory was ever a candidate for this run, **two or more cleared the base-time floor so none could be derived** — both are named — `WORKPLAN.md` unreadable, unhandled exception) or bad usage. A directory whose candidates were all refused by the **base-time floor** is *not* this: the watch keeps polling with liveness unknown |

`status_check.sh` exits `0` when it printed a report, `2` on the same watcher
errors — and a one-shot report has nothing to poll, so it exits `2` where the
watch degrades to unknown liveness, after saying which of the two it is and
listing every transcript it refused and why.

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

The same mistake had one more home, in `state/`. The tripwire's `local main
moved` compared against the `main_sha` in `watch_state.json` — which persists
across series, so on the first poll of a new series it was whatever `main` was
during the *previous* one. `main` had legitimately moved since (the last
series' PR merged), so the watch opened by reporting a merge that happened
before it was armed. A new series now **seeds** that value instead of
comparing it, and says so in one line; within a series the tripwire is
unchanged. "New series" is read from the arming identity — run, branch, base —
persisted alongside it.

All three are derived now, and `selftest.sh` holds each one in place: the
branch from the checkout and from a detached HEAD, the PID set from a synthetic
`pgrep` (including that the `pgrep` wrapper never enrols itself in the set it
is about to watch), and the fact that an empty set and an unset one are
different answers.

**And a constant that names a repository is a lie in the next project.** On
2026-10-04 a second series opened — `spanweave-live`, with its own branch, its
own plan and its own builder — and `DEF_TDIR` named
`~/.claude/projects/-home-msi-git-spanweave`. A check pointed at the new repo
with `SPANWEAVE_REPO` read that repo's branch and that repo's commits while the
transcript, the liveness timestamp and the sub-agent activity all came from the
*other* project's sessions, and the PID set was armed on whichever builder
happened to be running anywhere on the machine — so `builder gone` would have
fired when a stranger finished and stayed silent when the watched builder died.
The repo is a parameter now, and the branch, the PID set and the transcript
directory are read from it.
