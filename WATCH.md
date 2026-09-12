# WATCH.md — read-only watch on a spanweave WORKPLAN.md builder run

`watch_run.sh` observes the builder Claude Code session executing a run of
`WORKPLAN.md` on branch `audit-fixes` in `~/git/spanweave`. It reports; it never
intervenes. `status_check.sh` is the same knowledge as a one-shot report.
`README.md` has the invocations; this file is the behaviour.

## What it is allowed to do

Reads only:

- `git fetch --quiet origin audit-fixes`, `git log`, `git rev-parse`,
  `git --no-optional-locks status --short`, `git stash list`, `git show --stat`
- file mtimes (`WORKPLAN.md`, `.git/index`, transcripts, sub-agent transcripts)
- `pgrep -af claude`
- tails of the builder's transcript JSONL

It **never** writes to the repo, never commits, never checks out, never runs
`make`, `uv`, or `pytest`. Its only writes are under `state/`;
`status_check.sh` writes nothing at all.

`git fetch` and `--no-optional-locks` are deliberate: fetch updates only the
remote-tracking ref, and `--no-optional-locks` stops `git status` from
rewriting `.git/index` — which would otherwise make the watcher's own read look
like builder activity and permanently suppress the `stall` trigger. For the same
reason `.git/index` is stat'd *before* any git command runs in a poll.

## Running it

```bash
./watch_run.sh --run 2 --batches "A5 A6 ..."          # poll every 5 min, at most 9 min, then exit
./watch_run.sh --once --run 2 --batches "A5 A6 ..."   # a single poll
./watch_monitor.sh --run 2 --batches "A5 A6 ..."      # arming path under the Monitor tool
./watch_loop.sh --run 2 --batches "A5 A6 ..."         # arming path in a plain terminal
```

Flags on all four: `--run N`, `--batches "<list>"`, `--base SHA`,
`--branch NAME`, `--pids "P P P"`; `watch_run.sh` also takes `--once`.
Environment overrides (all optional, flags set the same variables):
`SPANWEAVE_REPO`, `SPANWEAVE_TDIR`, `SPANWEAVE_PINNED`, `SPANWEAVE_SELF`,
`SPANWEAVE_BASE`, `SPANWEAVE_BRANCH`, `SPANWEAVE_RUN`, `SPANWEAVE_BATCHES`,
`SPANWEAVE_PIDS`, `SPANWEAVE_STATE_DIR`, `POLL_SECONDS`, `BUDGET_SECONDS`.

Each poll prints a one-line banner naming the transcript it is watching, HEAD,
`origin/audit-fixes`, the liveness timestamp and its age, the last observed
`pendingBackgroundAgentCount`, the batches still active, and any currently
suppressed trigger. Banners are appended to `state/poll.log`.

## Per-trigger policy

Two triggers are **terminal** — they stop the watch and set the exit code.
The other three are **report-and-continue**: they print their evidence block
and the loop goes on polling, so a single tripwire hit or a pause for a
question no longer costs the watch.

| trigger | terminal? | repeat policy |
|---|---|---|
| **finished** | yes, exit `10` | — |
| **builder gone** | yes, exit `13` | — |
| **tripwire** | no | per commit sha, once ever; `state/watch_state.json` keeps `reported_commits` |
| **waiting on user** | no | once, then suppressed until liveness moves |
| **stall** | no | once, then suppressed for a further 40 min without movement |
| watcher error | yes, exit `2` | — |

A suppressed `waiting on user` or `stall` is lifted the moment any watched
signal moves, and the lift is itself reported as one line:

```
RESUMED after waiting on user (quiet 23.4 min): liveness 02:10:04 -> 02:31:12
```

"What moved" is drawn from the four signals the watch tracks: liveness (the
newer of the builder transcript and its `subagents/`), `HEAD`, `.git/index`,
and the last commit's date. After a `RESUMED` the trigger may fire again.

`stall` re-reports only when a further 40 minutes pass with **nothing** moving;
the repeat block says `TRIGGER: stall (still, N min since the last report)`.

### Event markers

So a front end can forward triggers without forwarding banners, `watch_run.sh`
brackets every event:

```
>>> EVENT tripwire
…evidence block…
<<< END EVENT
>>> LINE RESUMED after stall (quiet 51.0 min): HEAD a9f6fd9 -> 7f68aca
```

`watch_monitor.sh` streams exactly those to stdout and everything else to
`state/poll.log`. `watch_loop.sh` prints everything to the terminal.

## Exit codes

| code | meaning |
|---|---|
| `0` | the invocation ran out its budget; non-terminal events may have been printed |
| `10` | **finished** (terminal) |
| `13` | **builder gone** (terminal) |
| `2` | watcher error (no builder transcript found, `WORKPLAN.md` unreadable, unhandled exception) or bad usage |

`11` (waiting on user), `12` (stall) and `14` (tripwire) name the triggers in
prose and in `state/`; they are **not** exit codes any more, because those
three no longer end an invocation.

## Which transcript is the builder's

Not "the newest file in the directory" —
`/home/msi/.claude/projects/-home-msi-git-spanweave/` also holds aux-session
transcripts, including the watching session's own, and builder transcripts from
*earlier runs*.

The derivation takes the run number. A candidate is a top-level `*.jsonl` in
that directory whose most recent `"lastPrompt"`:

1. does not open by announcing itself as a reviewer or a watcher, **and**
2. says `Resume WORKPLAN.md`, or mentions `WORKPLAN.md` *and* names run `N`
   in an operative form — `run N`, `runN`, `run #N` — anywhere in the prompt,
   **and**
3. does not name a different run *without* also naming `N`, **and**
4. is neither this session's own transcript (`CLAUDE_CODE_SESSION_ID`) nor a
   known past watcher/aux one (`SPANWEAVE_SELF`).

**Why 1 exists.** Aux sessions talk about the plan and name the run too, so
once rule 2 stopped demanding the literal phrase they became candidates: a
run-2 check derived onto `Cold review of run 2 of the spanweave audit series`,
an aux reviewer, in preference to the builder. What separates them is position,
not vocabulary — an aux prompt says what it is in its opening words, while run
3's *builder* prompt contains "review" 150 characters in — so only the first 80
characters are tested.

**Why 2 is not the literal phrase.** Run 3's builder was started with `Apply
~/Downloads/run3-2026-09-11.md with one plan-only sub-agent (recreate
WORKPLAN.md from git show c79cbc5:WORKPLAN.md …)`. That is unmistakably a run-3
builder and it matched neither `WORKPLAN.md run 3` nor `Resume WORKPLAN.md`, so
the watch fell back to the pin — the *run-2* transcript — and reported a
finished session's liveness as though run 3 were alive. Being about the plan
and being about run `N` are two conditions, and nothing requires them to be
adjacent.

**Why 3 is not "names no other run".** The same run-3 prompt ends `single
commit plan: reopen for run 3 -- run-2 review findings`. It names run 3 and
*cites* run 2, and the old absolute test threw it out for the citation — the
same citation-versus-declaration mistake rule (a) exists to correct. A prompt
that names `N` is about `N`, whatever else it refers to. The hyphenated
`run-2` is treated as citation-only for rule 2 as well: in this corpus that
form is always adjectival (`run-2 review findings`, `run-1 concerns`), whereas
an operative reference is spaced or bare, including the `run3-…` of a handover
filename where the digit attaches to the word.

**Why 4 is not just a list.** `SPANWEAVE_SELF` is written before the session
that uses it exists, so it can never contain the running watcher — and rule 2's
loosening makes self-derivation *more* likely, not less, because a watcher is
told about `WORKPLAN.md` and about the run number too. The live session is
excluded by `CLAUDE_CODE_SESSION_ID` instead; the static list now covers only
watcher and aux sessions from earlier. `selftest.sh` asserts both halves,
including that without the session id the watcher does derive onto itself.

Among candidates: the newest **`<stem>/subagents/` directory mtime** wins, then
the transcript's own mtime, then the name. (That is the *derivation* tiebreak;
*liveness* separately uses the newest mtime of any file anywhere under
`subagents/`, which is the finer signal.) With no candidate the configured pin
is used — an operator override, so it is not re-tested against the run number.
With no candidate and no pin the script exits `2`.

So a builder that is `/clear`ed and resumed after a usage-limit reset — which
forks a brand-new transcript file — is followed instead of the old one being
declared dead. When the chosen file differs from the pin, the banner says
`<-- FOLLOWED (pin was …)`.

**Why rule 2 exists.** On 2026-09-10 02:10 the watch derived onto
`95360def-…jsonl`, whose `lastPrompt` is `Execute WORKPLAN.md run 1` — the
*previous* run's builder. The old rule was "newest matching transcript", and
`WORKPLAN\.md run` matched run 1 as happily as run 2, so the watch reported on a
finished session while run 2 ran elsewhere. Rule 2 makes that impossible: run 1
is excluded from a run-2 watch by name, whatever its mtime. `selftest.sh`
asserts the exact case, from both directions and under either pin.

`status_check.sh` prints the candidate list, the rejected files with the reason
each was rejected, and whether the choice was `derived` or `pin (no candidate)`.

## Where the batch rows come from

The last batch of the series, **G4**, is *"Series close: … remove
`WORKPLAN.md` and its README row"*. The file the watch reads is deleted on
purpose at the end. So "no `WORKPLAN.md`" is a planned end state, not a
failure, and the rows are looked for in three places in order:

| source | when | effect |
|---|---|---|
| `worktree` | normal | rows as written |
| `HEAD` | the deletion is staged but not yet committed | rows from the committed copy; the banner says `plan from HEAD` |
| `absent` | gone from the worktree *and* from `HEAD` | no rows remain, so **nothing counts as active** and `finished` becomes reachable; the banner says `plan from absent` |

A file that *is* there and cannot be read is retried twice (the builder
rewrites it in place between batches) and only then is a watcher error.

On 2026-09-10 04:25 the watch died `exit 2` in the second row of that table:
G4 had staged the deletion, the working-tree file was gone, and the watcher
treated a missing file as unreadable. Four `selftest.sh` cases now cover the
staged deletion, the committed deletion, `finished` reached with the plan
closed, and the still-an-error case.

## Liveness

The builder's own transcript is silent for minutes at a time while a batch
sub-agent runs; the file that moves is the sub-agent's. Liveness is therefore the
**newer of**:

- the builder transcript's mtime, and
- the newest mtime anywhere under `<transcript-stem>/subagents/`.

The last `pendingBackgroundAgentCount` seen in a `system` entry in the last 60
lines is read as a secondary signal (`1` means a batch sub-agent is outstanding).

## Triggers

Evaluated in this order. The non-terminal ones do not stop the poll; a poll can
therefore report a tripwire *and* a stall.

**tripwire** — checked against every local commit not yet reported, minus
`reported_commits`. The range starts at the `--base` sha whenever one is given:
an operator-given base is a statement about where *this* run starts and
outranks the `last_seen_head` a previous run persisted, so re-basing a run no
longer needs the state file deleted. With no `--base`, the range is
`last_seen_head..HEAD` as before:

- subject does not start with `plan:` but the commit touches `WORKPLAN.md`
- touches `spanweave/` while the body names batch **F1** (F1 is memo-only; it
  halts as `awaiting decision` if its design needs a model change)
- touches `tests/serialized_shape.json` and the body does not mention
  `serialized_shape`
- the commit **declares** a batch outside the run list
- the checked-out branch is not `audit-fixes`, or local `main` moved
- `git stash list` grew

Evidence: `git show --stat` plus subject and body for each newly reported
commit, `git status --short`, `git stash list`, current branch, `main` sha.

**What "declares a batch" means.** Only two forms count:

- a body line `Batch <ID> of WORKPLAN.md …`
- a subject `plan: <ID> …`

A batch id anywhere else in the prose is a *citation*, not a declaration, and is
ignored. The old rule scanned the whole subject+body for `\b[A-H]\d\b`, and on
2026-09-10 02:10 it fired on `477fe9b` — a legitimate A6 commit whose body opens
`Batch A6 of WORKPLAN.md.` and then explains what A1 had left undone. "A1" was
read as a second declaration. Batch commits in this series routinely cite
earlier batches (`A3's rule`, `C1's sentence is fixed by C3`), so the old rule
was a false positive generator, not a tripwire. `selftest.sh` runs the real
`477fe9b` message through it.

*The memo rule uses the same test.* It used to scan the whole body for
`\bF1\b`, on the reasoning that a false positive is cheap. It is not: a batch
commit that legitimately touches `spanweave/` while *citing* the memo ("R3 is
the memo that will decide stated units; this commit does not pre-empt it")
tripped it, which is the pre-`477fe9b` mistake exactly. It now fires only when
a commit **declares** a memo batch. The memo set is per-run and passed with
`--memo` (run 2: `F1`; run 3: `R3`); it defaults to `F1`.

*Batch ids are prefix-agnostic.* `BATCH_ID` was `[A-H]\d+`, which covered run
2's ids and none of run 3's `R1`–`R7`. Every run-3 row read as `<row missing>`,
every run-3 declaration was invisible to the tripwire, and the status report's
`0/7 batches stopped, active: <all seven>` was a default rather than an
observation. It is now `[A-Z]\d+`: which letter a plan uses is the plan's
business.

*Row statuses are prefix-matched.* `is_stopped` tested `done` and `dropped` by
equality while `awaiting` and `blocked` were prefix-matched. The plan does not
write a bare `done` — it writes ``done (`0e4262e`)`` — so once run 3's rows
became visible at all, every completed batch still read as active. All four are
prefix-matched now.

**finished** *(terminal)* — `origin/audit-fixes` moved past the base, **and**
local HEAD equals it, **and** no listed batch is `todo` or `in progress`.
`done`, `dropped`, `awaiting …`, `blocked …` all count as stopped. Evidence:
`git log --oneline <base>..HEAD`, the status line for each listed batch, the
resume-note tail, `git status --short`.

*Caveat:* a row stopped by a *dependency* marker (`E3 awaiting E2`) counts as
stopped, so if the builder finishes the `todo` batches without ever flipping
such a row, `finished` fires with work left undone. The evidence block prints a
`note:` line listing exactly which rows are in that state, so the condition is
visible rather than silent. (For run 2 the maintainer resolved all six of those
markers to `todo` on 2026-09-10, so the caveat is currently inert.)

**waiting on user** — the last substantive transcript entry is an assistant
message that asks a question (trailing `?`, or an `AskUserQuestion` /
`ExitPlanMode` tool use), **or** any of the last 30 entries contains a
usage/rate-limit notice — and liveness has not moved for 10 minutes.
Metadata records (`attachment`, `queue-operation`, `file-history-snapshot`,
`cost-state`, `last-prompt`, `custom-title`, `agent-name`, `mode`,
`permission-mode`, `atis-latch`, `bridge-session`, `summary`) are skipped when
finding the last substantive entry. Evidence: the reason, the liveness block, the
last 20 entries with type/role and 200-character previews, batch statuses.

**builder gone** *(terminal)* — any PID from the set observed at arming time is
no longer present while the run is incomplete. Which of the four `claude`
processes is the builder is not knowable from outside, so the set shrinking is
the signal. Evidence: `pgrep -af claude`, the missing PIDs, the still-active
batches, the last 10 transcript entries, the liveness block.
*Note:* if the human restarts sessions for an unrelated reason this fires on a
stale PID set — re-arm with `--pids "…"`.

**stall** — no new local commit, no `.git/index` mtime change, and no
liveness movement for 40 minutes while a batch is in progress ("in progress" =
some listed batch is `todo`/`in progress`, or `pendingBackgroundAgentCount > 0`;
the builder marks a row `done` only *after* the batch lands, so a running batch
shows as `todo`). Evidence: the three timestamps, `git status --short`,
`pendingBackgroundAgentCount`.

## State

`state/` (gitignored):

- `watch_state.json` — `last_seen_head`, `main_sha`, `stash_count`,
  `last_poll`, `transcript`, `run`, `reported_commits` (the tripwire's
  once-ever list, capped at 500), `reported_conditions` (level-triggered
  tripwire conditions, currently only "wrong branch"), and `waiting` / `stall`
  suppression records (each holds the four signal values at fire time plus
  `fired_at`). `last_seen_head` is only consulted when no `--base` is given;
  pass `--base` to re-baseline, or delete the file to clear the dedup lists
  too.
- `poll.log` — one banner line per poll, plus the full text of every event.
- `last_evidence.txt` — the most recent evidence block.

## Verified

`./selftest.sh` — 115 cases, fixtures only, `~/git/spanweave` and the real
transcript directory never touched. It covers: the rule-(a) shapes including
the real `477fe9b` message and the `R`-prefixed and two-digit ids; the rule-(b)
derivation from both run directions, both tiebreaks, the pin fallback, the aux
and watcher prompts that must not be builders, and self-exclusion — including
the case that *without* `CLAUDE_CODE_SESSION_ID` the watcher derives onto
itself; the `95360def` drift from both pins; the run-3 row shapes, with an
escaped pipe in the row and a sha on the status; the memo rule firing on a
declaration and not on a citation; all six verdict values, including that
`waiting on user` outranks an in-progress row but not a finished, pushed run;
and every dedup path — tripwire once-per-sha, waiting
once-then-`RESUMED`-then-again, stall once-then-40-min-then-again, and both
terminal exits; and the series-close cases, where `WORKPLAN.md` is deleted
staged, then committed, then reached `finished` with the plan closed.

The dedup fixtures pin their timestamps once rather than recomputing
`touch -d '-20 min'` per call. Recomputing made the fixture lift its own
suppression before the poll meant to observe it — `movement()` reads liveness
advancing by >0.5 s as a resume — which failed roughly half of runs on this
tree and on the tree before these fixes.

Earlier, 2026-09-10, against a throwaway fixture repo: exit `0` on a quiet poll
and each trigger's evidence block rendering correctly.

## Operational notes

- The transcript tail is read by seeking the last 2 MB from the end of the file,
  so a transcript that grows to tens of MB never enters memory whole. Candidate
  transcripts are scanned line-by-line for `lastPrompt`, never slurped.
- 2026-09-10 01:55: the first armed `watch_loop.sh` run was killed by the host's
  low-memory guard while sleeping between polls — not by a trigger. A kill leaves
  `state/poll.log` ending in an ordinary banner and no new event; that is how to
  tell a kill from a trigger. State in `watch_state.json` survives, so re-running
  resumes where it left off rather than re-reporting old commits.
- 2026-09-10 02:00: killed a second time the same way. `watch_loop.sh` was
  replaced as the arming path by `watch_monitor.sh`, run under the Monitor tool
  with `persistent: true` (a session-length watch rather than a tracked
  background bash task). `watch_loop.sh` still works for a plain terminal.
- 2026-09-10 02:10: the two rules above were both wrong at once — the tripwire
  fired on `477fe9b` (a prose citation) while watching `95360def` (run 1's
  builder). Both are fixed here and both are self-tested.
- 2026-09-10 02:45: triggers became report-and-continue except `finished` and
  `builder gone`, so a false positive costs a paragraph rather than the watch.
- 2026-09-10 04:37: the tripwire fired on `ff05b2d` — F2's implementation
  commit, whose body cites F1 three times to say F1 did *not* halt. The F1 rule
  is the one left prose-matched on purpose; the hit was a false positive and,
  under the new policy, cost one paragraph. F1's own commit `c943543` is
  docs-only, so the thing the rule guards against did not happen.
- 2026-09-10 04:25: the watch died `exit 2` when G4 staged the deletion of
  `WORKPLAN.md`. Fixed above — the plan now has three sources and an absent
  plan is a closed series, not an error.
