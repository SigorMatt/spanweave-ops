# WATCH.md — read-only watch on a spanweave WORKPLAN.md builder run

`watch_run.sh` observes the builder Claude Code session executing a run of
`WORKPLAN.md` in `~/git/spanweave`. It reports; it never intervenes. The branch
it watches is whichever one the repo is on when the watch is armed — not a
name written down here. `status_check.sh` is the same knowledge as a one-shot report.
`README.md` has the invocations; this file is the behaviour.

## What it is allowed to do

Reads only:

- `git symbolic-ref --short HEAD` (once, at arming, to learn the branch),
  `git fetch --quiet origin <branch>`, `git log`, `git rev-parse`,
  `git --no-optional-locks status --short`, `git stash list`, `git show --stat`
- file mtimes (`WORKPLAN.md`, `.git/index`, transcripts, sub-agent transcripts)
- `pgrep -af claude`
- tails of the builder's transcript JSONL
- one bounded, read-only `gh run list --branch <branch> --json
  headSha,status,conclusion` in the watched repo, asked only when everything
  else `finished` needs is already true

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
`SPANWEAVE_BRANCH_SRC` is set by `arming.sh`, not by hand: arming *exports*
the branch it derived, so without a marker every downstream `config()` would
see a branch in the environment and report it as `given`.

`--branch` and `--pids` are optional and normally omitted; see **Arming**
below. `SPANWEAVE_PINNED` is empty by default — there is no pinned transcript.

Each poll prints a one-line banner naming the transcript it is watching, HEAD,
`origin/<branch>`, the liveness timestamp and its age — or
`liveness: unknown (no transcript newer than base)` where there is no
transcript to read one from (see **Which transcript is the builder's**) — the last observed
`pendingBackgroundAgentCount`, the batches still open — the field is
`open:`, and `open: (none)` means every listed batch has stopped — any
currently suppressed trigger, and — if the arming PID set is empty — that `builder gone`
is disarmed. Banners are appended to `state/poll.log`.

## Arming

Two facts are resolved **once**, when a watch is armed, by `arming.sh`, and
then held fixed for the life of that watch. Both used to be constants in
`watch_lib.py`, and both were stale by the next run.

| | default | resolved by |
|---|---|---|
| branch | `git symbolic-ref --short HEAD` in the watched repo | `arming.sh` at start, exported |
| PID set | the `claude --dangerous…` processes alive now | `arming.sh` at start, exported |

`watch_monitor.sh` and `watch_loop.sh` re-invoke `watch_run.sh` every few
minutes, so **they** arm, at their own start, and export both down; a
`watch_run.sh` started directly arms for itself. Whoever arms first owns both
values for the whole watch.

Arming also says one line when **liveness is unknown for the base** it was armed
on (see **Which transcript is the builder's**). That is a fact about a base, and
the two looping front ends arm before anything parses their flags, so they pull
`--base` out of their own argv and export it first — otherwise the note would be
computed against a *previous* run's default base, and a note about the wrong base
is worse than no note. `watch_run.sh` and `status_check.sh` parse `--base`
themselves, so they always have it.

**Why once and not per poll.** Re-reading either would disarm a trigger rather
than keep it fresh:

- `builder gone` fires when the PID set **shrinks**. A set re-derived each poll
  can never shrink.
- the branch tripwire fires when the checkout is not the branch being watched.
  A branch re-derived each poll would follow the builder onto any branch it
  checked out and report nothing.

**Empty is not a constant.** An empty PID set (no `claude --dangerous…` process
is running, or `--pids ""` was passed) leaves `builder gone` with no signal;
every banner says so. A repo with a **detached HEAD** yields no branch: there
is no `origin/…` to compare against, `finished` becomes unreachable, and the
poll prints a note saying exactly that. Neither degrades into a guess.

The `pgrep` match is anchored to the start of the *command* (`claude
--dangerous`), not searched anywhere in the line, so the wrapper process that
runs the `pgrep` — whose own command line quotes the pattern — can never enrol
itself in the set it is about to watch for disappearance.

## Per-trigger policy

The finished trigger — in all three of its forms — and `builder gone` are
**terminal**: they stop the watch and set the exit code. The other three are
**report-and-continue**: they print their evidence block
and the loop goes on polling, so a single tripwire hit or a pause for a
question no longer costs the watch.

| trigger | terminal? | repeat policy |
|---|---|---|
| **finished** | yes, exit `10` | — |
| **finished (series closed)** | yes, exit `10` | — |
| **finished (CI unverified)** | yes, exit `10` | — |
| **finished (series closed, CI unverified)** | yes, exit `10` | — |
| **finished: CI red on `<sha>`** | yes, exit `15` | — |
| **builder gone** | yes, exit `13` | — |
| **tripwire** | no | per commit sha, once ever; `state/watch_state.json` keeps `reported_commits` |
| **waiting on user** | no | once, then suppressed until liveness moves |
| **stall** | no | once, then suppressed for a further 40 min without movement |
| watcher error | yes, exit `2` | — |

With **liveness unknown** — the base-time floor left no candidate transcript and
no pin — `stall` keeps this policy exactly, and runs on the commit and
`.git/index` times alone: liveness neither arms it nor holds it off. `waiting on
user` is unreachable in that state, because there is no transcript to read a
question or a limit notice out of.

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
| `10` | **finished** (terminal), and also **finished (series closed)** — the same end state reached with the plan deleted — and the two **(CI unverified)** forms of both, which are that end state with an unread CI |
| `15` | **finished: CI red on `<sha>`** (terminal) |
| `13` | **builder gone** (terminal) |
| `2` | watcher error (no transcript was ever a candidate, `WORKPLAN.md` unreadable, unhandled exception) or bad usage |

A transcript directory whose every candidate the **base-time floor** refused is
not exit `2`: the watch keeps polling with liveness unknown. Only "nothing in
there was ever a candidate for this run" is the error. `status_check.sh` has
nothing to poll, so it still exits `2` in both cases — but it says which of the
two it is, and lists what was refused and why.

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
   known past watcher/aux one (`SPANWEAVE_SELF`), **and**
5. whose **last write is not earlier than the base commit's author time** — the
   floor, below. This one is not about the prompt at all.

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

**Why 5 exists — run numbers are per-series.** On 2026-10-01 a run-3 watch of
the `live-graphs` series derived onto
`351ac45a-5ef8-4d8a-a988-c1f213eda35a.jsonl`, whose own mtime is 2026-09-11
00:37 and whose `subagents/` mtime is 2026-09-10 17:09 — twenty days before the
run it was watching, whose base (`ce9ff17`) was authored 2026-10-01 00:23:40. It
reported that finished session's liveness and then `finished`. Two independent
causes met, and rules 1–4 cannot catch either:

- **Run numbers are per-series.** `351ac45a`'s `lastPrompt` is `Apply
  ~/Downloads/run3-2026-09-11.md with one plan-only sub-agent (recreate
  WORKPLAN.md from git show c79cbc5:WORKPLAN.md, restore its README row, single
  commit plan: reopen for run 3 -- run-2 review…`. That is the *September audit
  series'* run 3, and every predicate says yes: not aux in its first 80
  characters, names `WORKPLAN.md`, names run 3 operatively, spared by rule 3
  because it names run 3 itself. Nothing in the derivation knows about series or
  about recency, and `run 3` alone cannot tell one series' third run from
  another's.
- **The stored `lastPrompt` is truncated at ~200 characters.** The real run-3
  builder, `1d41a6d1-cc2d-4535-a1a6-445dc3875bd9.jsonl` (own mtime 2026-10-01
  15:49, `subagents/` 2026-10-01 01:20), stored `In ~/git/spanweave on
  live-graphs (tip 2cde61f), read WORKPLAN.md §0 in full. Apply
  patches/decisions-live-2026-09-30.md exactly as its header says: one
  plan-only sub-agent, one commit plan: run-2 rev…` — the only run number
  inside the cut is **2**, so rule 2 fails on it and it is not a candidate. The
  phrase that named run 3 lay beyond the cut.

So the wrong transcript was the **only** candidate and won outright: the
ordering below never got a chance to prefer the newer session. A date is a fact
about *this* run where a run number is only a fact about *some* run, so the
floor is where that gap closes.

**What "last write" means, and why.** The **newer of** the transcript's own
mtime and its `<stem>/subagents/` directory mtime. Of the available readings
that is the conservative one — the one least likely to exclude a *live* builder:
a builder's own file sits unflushed for minutes while a batch sub-agent runs,
and the directory's mtime moves when that sub-agent's file is created, so "own
mtime alone" would refuse a working builder and the newer of the two cannot. It
is the directory's own mtime, not the recursive newest-file mtime *liveness*
uses, so the two numbers that bound a candidate are exactly the two that order
it. The floor is the base commit's **author** time, not its committer time: a
rebase, an amend or a cherry-pick rewrites the committer time to *now*, which
would drag the floor forward over work the run already contains. It is read with
`git log -1 --format=%at <base>` from the base the watch already resolved (a
given `--base` outranking the persisted baseline, `b308424`). A base the repo
cannot resolve yields **no floor**: a watch does not invent a bound it could not
read.

Among candidates: the newest **`<stem>/subagents/` directory mtime** wins, then
the transcript's own mtime, then the name. (That is the *derivation* tiebreak;
*liveness* separately uses the newest mtime of any file anywhere under
`subagents/`, which is the finer signal.)

**That ordering is the implementation of "the newest write wins."** A
`subagents/` directory is only written by a builder that is *orchestrating*, so
it is the stronger of the two signals and is read first rather than averaged
with the other. The two readings diverge in exactly one case: a candidate with a
newer **own** mtime and **no** `subagents/` directory loses to one with a newer
`subagents/` mtime and an older own mtime. The ordering's answer is the preferred
one — the orchestrating session is the builder, and its own file goes quiet
precisely *while* its sub-agent works, so "newest own mtime" would hand the watch
to a session that typed one line. `selftest.sh` pins it ("a newer transcript
still loses to a newer `subagents/` dir"). Both candidates have cleared the
floor by then, so neither can be a previous series' session.

With no candidate the configured pin is used — an operator override, so it is
re-tested against neither the run number **nor** the floor.

### The floor, read forwards

With no candidate and no pin, the floor is asked the *other* question. Not
"which of these is too old" but "which of these was written since this run
began" — and among the transcripts that

1. are about `WORKPLAN.md`, **and**
2. do not open by announcing themselves as a reviewer or a watcher, **and**
3. are not this session's own or a known past aux one, **and**
4. were last written **at or after** the base commit's author time,

**exactly one is an answer, and two are not.** The one is derived, and says so
on every banner and in the report: `derived by floor, not by run number`.

*Why.* On 2026-10-02 run 5 of the live-graphs series had landed L23, pushed it,
and was mid-L24 with a sub-agent live — and no transcript in the directory
named run 5. The builder was the session that had been told to apply the
**run-4** review decisions: it made the base commit itself and rolled straight
on into run 5 without a new prompt, so its stored `lastPrompt` names run 4 and
is cut at the 200-character cap, where no later "run 5" could be stored either.
Both entry points answered *"no builder transcript found for run 5"* and exited
`2`, about a run whose builder was alive, pinned by nothing, and the only
session in the directory written since the base.

A run number is a fact about *some* run; "written since this run's base commit"
is a fact about *this* one. That is the same reasoning the floor already uses to
refuse a twenty-day-old candidate, pointed the other way — so the fallback's
warrant is the floor itself, which is why it names the floor in its own `how`
and why `status_check.sh` prints the reason next to the file it chose.

What the fallback drops is rule 2 (the run number) and nothing else. The aux
test, the self test and the floor all still stand, and each is pinned by a
`selftest.sh` case: an aux prompt newer than the base is still refused, a
post-base transcript that never mentions the plan is not in the pool, and the
watcher's own session never is.

**Two is not an answer.** The floor can say "since this run started"; it cannot
pick between two sessions that both were, and the newest-of-two guess is the
2026-10-01 drift with a new cause. So two or more leaves the watcher error
exactly where it was — exit `2` in both entry points — with **both** files
named and `SPANWEAVE_PINNED=<uuid>.jsonl` offered, because an operator naming
one is evidence the watcher does not have.

**No readable base, no fallback.** A base the repo cannot resolve yields no
floor at all, so "clears the floor" would degrade to "exists" — no warrant
whatever. The fallback is then simply unavailable, and the answer is the one
the watcher gave before it existed.

A pin outranks all of this, as it already outranks the run number.

With no candidate, no pin and no floor derivation there are three different
answers, and they are not reported as one:

| | means | watch |
|---|---|---|
| nothing was ever a candidate | no session in the directory is working this run | watcher error, exit `2`, as before |
| the floor refused every candidate | the builder's session is not visible from here | **liveness unknown** — a degraded mode, not an error |
| two or more cleared the floor | more than one session could be the builder | watcher error, exit `2`, both named |

In the second state the banner prints `liveness: unknown (no transcript newer
than base)` in place of the timestamp and age, the evidence block names the
refused files and by how much each missed, and the watch goes on polling. It
never prints a borrowed age. Every rejection — floor or prompt — is listed with
its own reason, so the near miss is visible rather than hidden; the two
rejections above are distinguishable in that list, one by its timestamps and one
by its truncation.

**There is no default pin.** `SPANWEAVE_PINNED` is empty unless an operator
sets it. It used to name run 2's builder transcript, which meant every run
after run 2 reported `<-- FOLLOWED off the pin` while the derivation was in
fact working — a drift notice that fires when nothing has drifted, which
trains the reader to ignore it. The pin is now only what you pass when the
derivation cannot see your session, and the `FOLLOWED` line appears only
against a pin you gave.

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
each was rejected, and whether the choice was `derived`, `derived by floor, not
by run number` or `pin (no candidate)`. A file the floor *chose* is dropped
from the rejected list, because "refused for naming no run 5" is no longer a
true thing to say about the file on the line above it.

## Where the batch rows come from

The last batch of the series, **G4**, is *"Series close: … remove
`WORKPLAN.md` and its README row"*. The file the watch reads is deleted on
purpose at the end. So "no `WORKPLAN.md`" is a planned end state, not a
failure, and the rows are looked for in three places in order:

| source | when | effect |
|---|---|---|
| `worktree` | normal | rows as written |
| `HEAD` | the deletion is staged but not yet committed | rows from the committed copy; the banner says `plan from HEAD` |
| `absent` | gone from the worktree *and* from `HEAD` | no rows remain. Whether that is the **series close** depends on the base — see below; the banner says `plan absent (series closed)` or `plan absent, and absent too at base: not a close` |

A file that *is* there and cannot be read is retried twice (the builder
rewrites it in place between batches) and only then is a watcher error.

### An absent plan is only a close if there was one at base

Two states look identical to a reader of the worktree, and only one of them is
a finished series:

| at base | at HEAD | what it is |
|---|---|---|
| present | absent | the **series close** — this run deleted the plan |
| absent | absent | a plan **not written yet** — nothing was deleted |

The second is not hypothetical. Run 3's builder was started with *"recreate
`WORKPLAN.md` from `git show c79cbc5:WORKPLAN.md`"*: no plan at base, and none
at HEAD either until its plan commit landed. The old rule — "gone and pushed
is finished" — called that a finished run.

So the watch asks git whether `WORKPLAN.md` existed at `--base`
(`plan_at_rev`), and that answer has **three** values, because "the plan was
never there" and "we could not look" are different claims:

| `plan_at_rev` | effect |
|---|---|
| present at base | the absence is the close: nothing counts as open, and `finished (series closed)` is reachable once the tip is pushed **and** green |
| absent at base | **not** a close: there are no rows, so every listed batch stays open and `finished` is unreachable from the absence |
| could not be read (the rev does not resolve, or git failed) | not a close either — the watch says so rather than guessing |

`finished (series closed)` is a **qualified** `finished`, on the same terms as
`underway: batch <ID> (in flight, uncommitted)`: same exit code, same terminal
policy, and it still begins with `finished`, which is what a caller matches on.
The qualifier is there because a closed series has *no batch rows left* — it
says why the status block under it is empty, so an empty one is not read as the
parser losing the rows again.

And it is gated on CI exactly as any other `finished` is. A closed plan has no
rows left to carry §0.1 step 8's second half, so the only evidence for green is
what CI said about the pushed tip: **absent with the tip unpushed, or with CI
pending or red, is not finished.**

On 2026-09-10 04:25 the watch died `exit 2` in the second row of that table:
G4 had staged the deletion, the working-tree file was gone, and the watcher
treated a missing file as unreadable. Four `selftest.sh` cases now cover the
staged deletion, the committed deletion, `finished` reached with the plan
closed, and the still-an-error case — and a further section covers the close
end to end: all four CI answers on a closed, pushed tip, and an absence that
was already there at base, which is not a close in either the report or the
watch.

## Liveness

The builder's own transcript is silent for minutes at a time while a batch
sub-agent runs; the file that moves is the sub-agent's. Liveness is therefore the
**newer of**:

- the builder transcript's mtime, and
- the newest mtime anywhere under `<transcript-stem>/subagents/`.

With the floor leaving no candidate and no pin there is nothing to read either
mtime from, and liveness is **unknown**: the banner says
`liveness: unknown (no transcript newer than base)`, the evidence block prints
the base's author time, the `.git/index` mtime and the last commit — the
timestamps that *are* known — and no age is invented from an old file.

The last `pendingBackgroundAgentCount` seen in a `system` entry in the last 60
lines is read as a secondary signal (`1` means a batch sub-agent is outstanding).
It is read from the **chosen** transcript's tail and from nothing else — never
from a union over the directory. The count feeds `stall` (through "a batch is in
progress") and the `underway (in flight)` verdict, so a count borrowed from
another session would report another run's sub-agent as this run's activity and
suppress a stall on evidence about a session the watch is not watching. The
2026-10-01 drift was one derivation away from doing exactly that. The code was
already correct here; it now says so, and `selftest.sh` keeps a decoy transcript
claiming `7` in the fixture directory and pins that the watch reports the chosen
transcript's `0`.

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
  — **except the series close**, which *deletes* the plan (see below)
- touches `spanweave/` while the body names batch **F1** (F1 is memo-only; it
  halts as `awaiting decision` if its design needs a model change)
- touches `tests/serialized_shape.json` and the body does not mention
  `serialized_shape`
- the commit **declares** a batch outside the run list
- the checked-out branch is not the branch this watch was armed on, or local
  `main` moved **within this series** (see below)
- `git stash list` grew

Evidence: `git show --stat` plus subject and body for each newly reported
commit, `git status --short`, `git stash list`, current branch, `main` sha.

**The series close is exempt from the `plan:` subject rule.** The convention
behind that rule is that a commit touching `WORKPLAN.md` reports on a batch, so
its subject names one. The close batch is the one commit that cannot obey it:
it **deletes** the plan, and there is no row left to report on. Run 5's close
landed as `docs: the live-graphs series closes, and WORKPLAN.md goes with it`
and tripped a rule it was right to break.

So a commit that deletes `WORKPLAN.md` is read as the close — but only on two
facts, because a blanket exemption would mean any commit could drop the file
and walk past the rule by doing so:

- **the plan was present at the base commit**, so there was a series here to
  close. This is `plan_at_rev`'s distinction, the same one that keeps "a plan
  not yet written" from being read as a finished run: a rev that will not
  resolve answers `None`, and *we could not look* is not evidence that a
  series closed.
- **no close has been exempted in this series yet.** A series closes once. The
  exemption is spent on one sha, recorded in `watch_state.json` as
  `close_exempt`, and a *second* `WORKPLAN.md` delete in the same series trips
  normally. A new series clears it, exactly as it clears `main_sha`.

A granted exemption **prints** (`note: <sha> deletes WORKPLAN.md and the plan
was present at base …`), because a silent exemption is indistinguishable from
a tripwire that was never armed. Modifying the plan under a non-`plan:` subject
still trips: the exemption is about deleting, not about touching.

**`local main moved` is scoped to a series.** It catches the builder landing
work on `main` *while a watch is running*. But `watch_state.json` outlives a
series, and its `main_sha` is whatever `main` was during the **previous** one —
by the time the next series is armed, `main` has legitimately moved, because
the previous series' PR merged. Comparing against it made the first poll of
every new series report a merge that happened before the watch existed: a
value that was true in the run it was written in and a lie in the next one.

So the **first poll of a new series seeds `main_sha` instead of comparing it**,
and says so in one `note:` line naming both identities and both shas, so a
reader is never left guessing whether the tripwire is armed. From the second
poll of that series on, it compares exactly as it always did, and a genuine
mid-watch move of `main` still fires.

A **series** is identified by what arms it — the run number, the branch being
watched, and the base — persisted as `series` in `watch_state.json` and
compared on load. All three are facts about the arming, not guesses about the
repo, and any one of them differing means a new series. A first-ever poll, with
no state at all, seeds as it always did. The scope is `main_sha` only:
`reported_commits` is not touched by this.

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

**finished** *(terminal)* — `origin/<branch>` moved past the base, **and**
local HEAD equals it, **and** no listed batch is `todo` or `in progress`,
**and** CI concluded `success` on the pushed tip. `done`, `dropped`,
`awaiting …`, `blocked …` all count as stopped. When there are no rows at all
because this run **deleted** the plan, the same trigger fires as **finished
(series closed)** — see *An absent plan is only a close if there was one at
base*. Evidence: the CI answer and
where it came from, `git log --oneline <base>..HEAD`, the status line for each
listed batch, the resume-note tail, `git status --short`.

*Why CI is a conjunct.* `WORKPLAN.md` §0.1 step 8 ends a run at **pushed and
green**, and says in as many words that a local `make check` is not a
substitute for the checks that run on the pushed sha. The first three
conjuncts are the push half only, so a run whose CI went red on the tip it had
just pushed used to be reported, terminally, as finished.

The three git conditions decide **whether to ask**; CI decides **what the
answer is**, in four shapes:

| CI on the tip | trigger | exit |
|---|---|---|
| `success` | `finished`, or `finished (series closed)` where the run deleted the plan | `10` |
| queued, running, or no workflow run for the sha yet | *none* — one note, and the poll loop continues | — |
| any other conclusion (`failure`, `cancelled`, `timed_out`, …) | `finished: CI red on <sha>` | `15` |
| `gh` could not be read at all | `finished (CI unverified)`, or `finished (series closed, CI unverified)` | `10` |

*Pending is not news.* CI on a tip pushed seconds ago is queued by definition,
so the pending case prints one `note:` line in the same shape as the other
"`finished` cannot fire this poll" notes, and nothing else. No event, no
evidence block, no suppression record to keep.

*Unreadable is not red, and it is not green.* A `gh` that is missing from
`PATH`, unauthenticated, rate limited, timed out, or answering with something
that is not a list of runs has told the watch **nothing about the build**.
Reading that as failure would invent a red build; reading it as success would
be the silent overclaim this conjunct exists to remove. So the watch still
stops — the run is pushed and every batch has stopped, which is as much as it
can see — under a name that says the CI half is unchecked, and the evidence
block tells the reader to check it by hand.

*Bounded on purpose.* The `gh` call has a 25-second timeout and is made at
most once per poll, only once every other condition already holds. A `gh` that
hangs costs that poll its CI answer — reported as unverified — and never the
watch. "gh ran fine and lists no run for this sha yet" is a fact about CI
(nothing has been queued), so it is **pending**; only a failure to *read* an
answer is unavailable.

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
no longer present while the run is incomplete. Which of the `claude
--dangerous…` processes is the builder is not knowable from outside, so the set
shrinking is the signal. Evidence: `pgrep -af claude`, the missing PIDs, the
still-open batches, the last 10 transcript entries, the liveness block.
*Note:* if the human restarts sessions for an unrelated reason this fires on a
stale PID set — just re-arm, and arming takes a fresh set. An empty set
disarms the trigger; the banner says so every poll.

**stall** — no new local commit, no `.git/index` mtime change, and no
liveness movement for 40 minutes while a batch is in progress ("in progress" =
some listed batch is `todo`/`in progress`, or `pendingBackgroundAgentCount > 0`;
the builder marks a row `done` only *after* the batch lands, so a running batch
shows as `todo`). Evidence: the three timestamps, `git status --short`,
`pendingBackgroundAgentCount`.

*With liveness unknown, liveness is **excluded** from this rule* — not read as
quiet and not read as moving. The commit time and the `.git/index` mtime still
count and still arm the stall on their own; liveness neither arms it nor
suppresses it. Both halves matter: an ancient mtime read as "quiet" would arm a
stall off a dead session's timestamp, which is the 2026-10-01 drift in miniature,
and an mtime that never moves would hold the stall off forever. For the same
reason a transcript moving anywhere in the directory cannot emit a `RESUMED` in
that state — the watch is not watching one, so there is nothing for it to have
moved; a new commit or a touched `.git/index` still lifts a suppression, because
those were really observed. The stall's evidence block says which of the two
rules it fired under, and `arming.sh` says it once up front:

```
arming: liveness is unknown for base ce9ff17 (authored 2026-10-01 00:23:40): every
candidate transcript in … was last written before it, so the stall rule runs on the
commit and .git/index times alone. Pass SPANWEAVE_PINNED=<uuid>.jsonl to override.
```

## State

`state/` (gitignored):

- `watch_state.json` — `last_seen_head`, `main_sha`, `stash_count`,
  `last_poll`, `transcript`, `run`, `series` (the arming identity — run,
  branch, base — which is how a poll tells "this watch, later" from "a new
  watch reading what the last one left"; see the tripwire's `main_sha`
  seeding), `reported_commits` (the tripwire's
  once-ever list, capped at 500), `reported_conditions` (level-triggered
  tripwire conditions, currently only "wrong branch"), and `waiting` / `stall`
  suppression records (each holds the four signal values at fire time plus
  `fired_at`). `last_seen_head` is only consulted when no `--base` is given;
  pass `--base` to re-baseline, or delete the file to clear the dedup lists
  too.
- `poll.log` — one banner line per poll, plus the full text of every event.
- `last_evidence.txt` — the most recent evidence block.

## Verified

`./selftest.sh` — 290 cases, fixtures only, `~/git/spanweave` and the real
transcript directory never touched. It covers: the rule-(a) shapes including
the real `477fe9b` message and the `R`-prefixed and two-digit ids; the rule-(b)
derivation from both run directions, both tiebreaks, the pin fallback, the aux
and watcher prompts that must not be builders, and self-exclusion — including
the case that *without* `CLAUDE_CODE_SESSION_ID` the watcher derives onto
itself; the `95360def` drift from both pins; the run-3 row shapes, with an
escaped pipe in the row and a sha on the status; the memo rule firing on a
declaration and not on a citation; all six verdict values and both of
`finished`'s qualifiers, including that `waiting on user` outranks an
in-progress row but not a finished, pushed run;
and every dedup path — tripwire once-per-sha, waiting
once-then-`RESUMED`-then-again, stall once-then-40-min-then-again, and both
terminal exits; the series-close cases, where `WORKPLAN.md` is deleted staged,
then committed, then reached `finished (series closed)` with the plan closed —
pushed and green, and not on an unpushed tip, a pending CI or a red one, and
not at all where the plan was already absent at the base; and the two
derived defaults — the branch from the checkout, from an operator flag and from
a detached HEAD, a poll with no `--branch` against a repo that is *not* on
`audit-fixes` running clean while a given-but-wrong branch still trips the
wire, the PID set from a synthetic `pgrep` including that the wrapper never
matches itself, unset-versus-empty, and an empty set leaving `builder gone`
disarmed and saying so; and both branches of `underway` — a batch **declared**
by a commit since base, and a batch **in flight** (plan commit pushed, a live
sub-agent, a dirty tree) with each of those three conjuncts shown to be
load-bearing, the first `todo` batch named in the run's execution order rather
than the alphabet, and `applying plan` narrowed to the two plan-commit states;
and all four CI answers behind `finished` — success fires it, pending does not
and the watch goes on polling, a non-success conclusion fires `finished: CI
red on <sha>` with the sha in the event line, and every way of failing to read
an answer (non-zero exit, empty output, non-JSON, JSON that is not a list, a
`gh` that hangs past its timeout, and a `gh` that is not on `PATH` at all)
fires `finished (CI unverified)` rather than claiming green.

Every CI case answers through a **stub `gh`** placed first on `PATH` for the
whole script, which prints canned JSON and never opens a socket; its default
is the unavailable branch, so a case that forgets to say what CI said gets the
unverified answer rather than a call to the real `gh`.

It covers the floor read **forwards** — one post-base transcript derived with
its warrant named in the banner and the report, an aux one and a plan-silent
one and the watcher's own kept out of the pool, a pin and a run-naming prompt
both outranking it, two candidates left as exit `2` with both named, and an
unreadable base leaving the fallback unavailable rather than permissive. It
covers the **base-time floor** against the 2026-10-01 shapes: the September
run-3 prompt is shown to be a perfectly good run-3 builder prompt and the
transcript is still refused, with the rejection naming both timestamps; the same
transcript is **accepted** once the base's author time is moved behind it, so it
is the floor and not the prompt that refuses it; a candidate whose own mtime
predates the base but whose `subagents/` mtime does not is **kept**, and refused
once that mtime is old too; the real builder's truncated `lastPrompt` refuses it
for its own reason, with the floor satisfied, so the two rejections are
distinguishable in one list; and a pin is honoured without being floor-tested.
The degraded mode has its own fixture: a base 90 minutes old against a
transcript from 2026-09-11, where the banner says `liveness: unknown (no
transcript newer than base)` and no age at all, `arming.sh` says it once, the
stall fires on the commit and `.git/index` times alone and says that liveness is
excluded rather than quiet, a transcript moving elsewhere in the directory emits
no `RESUMED`, and the stall is suppressed and repeated on exactly the normal
schedule. One more fixture keeps `pendingBackgroundAgentCount` honest: a decoy
transcript claiming `7`, newer than the builder but never a candidate, while the
banner and the status report both read the chosen transcript's `0`.

It also covers the `main_sha` seeding: a stale `main_sha` from a previous
series is seeded rather than reported, a genuine mid-watch move still fires on
the next poll, a first-ever poll with no state behaves as it always did, and
each of the run, the branch and the base is shown to mean "new series" on its
own.

Because the branch is derived, an unset `SPANWEAVE_BRANCH` would make
`config()` shell out to the *real* repo. `selftest.sh` exports a fixture floor
for `SPANWEAVE_REPO` and `SPANWEAVE_BRANCH` at the top so the promise in its
header still holds; the branch cases unset them deliberately, against a fixture
repo of their own.

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
- 2026-10-01: a run-3 watch of the `live-graphs` series derived onto
  `351ac45a-…jsonl` — own mtime 2026-09-11 00:37, `subagents/` 2026-09-10 17:09,
  twenty days before the base `ce9ff17` it was armed on (authored 2026-10-01
  00:23:40) — and reported that finished session's liveness and then `finished`.
  Its `lastPrompt` (`Apply ~/Downloads/run3-2026-09-11.md … reopen for run 3 --
  run-2 review…`) is a correct run-3 builder prompt: it is the *September audit
  series'* run 3, and **run numbers are per-series**. The actual builder,
  `1d41a6d1-…jsonl`, was not even a candidate, because its stored `lastPrompt` is
  cut at ~200 characters (`… one commit plan: run-2 rev…`) and the only run
  number inside the cut is 2. One candidate, so it won with no contest. Fixed by
  the **base-time floor** above, and by reporting both near misses instead of
  one of them; `pendingBackgroundAgentCount` was audited at the same time and was
  already read from the chosen transcript alone.
- 2026-09-30: the three session-shaped constants were retired. A run-2 status
  check against the `live-graphs` series compared everything against
  `origin/audit-fixes`: `git fetch` failed with *couldn't find remote ref*,
  `origin` read as a stale sha from a branch nobody was on, and the report
  still printed `NOT pushed (origin b863767)` — machinery comparing against the
  wrong branch, stated as fact. The same check reported all four arming PIDs
  missing (they had exited weeks earlier, so a watch would have fired the
  terminal `builder gone` on its first poll) and `<-- FOLLOWED off the pin`
  while the derivation had in fact found the right transcript. Branch and PID
  set are now derived at arming (see **Arming**); the pin defaults to empty.
