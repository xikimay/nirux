# CI Failure Triage

Status: approved by the user on 2026-11-10 (one of the model features),
measured and built the same day.

A red pull request costs a look, and on the night of 2026-11-09 five of them
were flakes: tests that passed on a rerun, a dependency download that could
not connect. [CI Failure Actions](ci-failure-actions.md) already says when a
workspace's pull request turns red. The triage adds one thing: when the
failure looks flaky, Nirux says so, says why, and puts the rerun first.

## What shows

Only a likely flake says more than before:

- the row reads `#52 · checks failed · likely flaky`;
- the notification is titled "CI failed · likely flaky", with the reason on
  a line of its own, and its first button is **Rerun Failed CI Jobs…**;
- in the row's menu, the CI items start with the reason ("Likely flaky: …",
  its tooltip holds all of it), then **Rerun Failed CI Jobs…**, then **Ask
  Agent Why CI Failed**.

A failure Nirux reads as real, or can't read, shows exactly as it always
did. There is no "likely real": a red pull request is already taken as
real, and the words would be one more place to be wrong.

Nirux never reruns by itself. The rerun stays the user's, behind its
confirmation.

## How it decides

**Rules first.** When a pull request's checks are red and their run is
over, Nirux reads, with `gh`: the run's jobs and steps, the failed steps'
log of that attempt, the attempt before when this one is a rerun, and the
files the pull request changes. Each red job is judged on its own part of
the log, in this order:

1. A job that ran no step is **flaky** when GitHub says no runner took it,
   or the runner was lost (its check run's annotations). Any other reason
   (a `runs-on` or matrix GitHub couldn't evaluate, a job cancelled by
   hand) gives no verdict: the workflow is the pull request's too.
2. Compile errors are **real**; so is a crash (`Fatal error`) in a file the
   pull request changes.
3. No test failed and a dependency download did ("failed downloading …
   required by binary target"): **flaky**, unless the pull request changes
   `Package.swift` or `Package.resolved`, or the attempt before failed the
   same way.
4. A test fails that failed in the attempt before, in a job that attempt
   ran too: **real**. (A job GitHub carried over keeps its id: its failure
   is the same one, not a second.)
5. The pull request changes the file of a failing test: the one of its
   class's name, or the one a failure was reported in: **real**.
6. Every failing test is one Nirux saw fail and then pass on a rerun of the
   same commit: **flaky**.
7. Any other failing test is **open**.

A test XCTest reports failed counts even when none of its failure lines
could be read. Rules 3 and 6 never fire in a job whose log holds an error
no rule reads (SwiftPM's `error: …`, a workflow's `##[error]…`, a signal
with no test left unfinished), nor when the attempt before couldn't be
read: what they can't see may be real. A run is flaky only when each red
job is, and gets no verdict when one of them gets none; a pull request is
flaky only when each red run is. A red check that is not an Actions run of
the pull request's repository (a commit status, another repository) can't
be read, so the failure stays plain.

**Then a model, on what the rules leave open**: failing tests the pull
request doesn't edit. Claude Sonnet, through a headless `claude -p`, is
given the failing tests with their messages, their source, any crash line,
and the files the pull request changes with the function, property or type
each change sits in (read from the workspace's repository, at the run's
commit, in one `git cat-file --batch`). It answers one sentence, then a
last line holding FLAKY, REAL or UNSURE and nothing else; anything else is
no answer. The sentence is the reason shown. A failing test that isn't at
the pull request's commit came with the base branch (the run tests their
merge): no verdict, and nothing goes to the model.

**What Nirux learns.** It remembers each run it triaged, with its red checks
and the tests that failed. When each of those checks passes on a later
attempt of the same run (a rerun keeps the run, on the same commit), those
tests failed and then passed with no change: they go on the repository's
flaky list, which rule 6 reads. A check another run of the workflow took
over teaches nothing. A test leaves the list two months after its last such
failure.

## Measured

On every failed run of this repository still readable on 2026-11-10: 188
labelled runs, 168 real (mutation pull requests, compile errors, failures
fixed by the next push) and 20 flaky (passed on rerun, failed downloads,
jobs that never ran).

| | Says flaky | Real failures called flaky | Left open |
|---|---|---|---|
| Rules alone | 9 of the 20 flakes | 0 of 168 | 21 runs (11 flaky, 10 real) |
| Haiku on the open runs, one word | 0 of 11 | 0 of 10 | |
| Haiku, one sentence then the word | 6 or 7 of 11 | 0 or 1 of 10 | |
| Sonnet, one sentence then the word | 9 of 11 | 1 of 10 | |

After the reviews, the rules as built (per job, with the failure's own file
in rule 5) give, replayed on the same logs: 9 of the 20 flakes, still no
real failure called flaky, and 16 runs left open instead of 21 (five
failures of test classes declared in another file now read as real).

The one real failure called flaky is a timing test that failed on the pull
request that introduced the parallel test runner: a fair call either way.

Two more sets stress the model on what a wrong "flaky" would cost:

- 98 regressions that edit no test (each mutation replayed as a pull
  request holding only the mutant commit): Sonnet called none flaky (95
  real, 3 unsure), and neither did Haiku in three passes;
- 65 flakes replayed against other pull requests' changes: Sonnet found 59.

Asking for a sentence before the verdict is what makes a model commit: with
one word, Haiku answers "unsure" on almost every flake.

About one failed pull request run a day here on average, of which the rules
settle 9 in 10; on a busy day (24 failed runs on 2026-11-08) the model runs
a few times. 3 s at the median. That is why the stronger model is the one
used.

## Limits

- **XCTest and Swift builds only.** The rules were measured on those logs;
  another test framework's failures are not recognized, so its jobs get no
  verdict (and neither does a run that holds one). Each framework needs its
  own measurement.
- **A test's first flake** is unknown to rule 6; only the model can call it.
  A test on the flaky list stays there whatever made it fail next time.
- **A run read when it couldn't be** (`gh` signed out, the model resting,
  the agent not running yet) is read once more five minutes later, then
  kept as it is.
- **The reason is a model's sentence about a log**, which the pull
  request's own code writes. It is cleaned, bounded and only ever shown. A
  log made to say "flaky" could earn the word; nothing acts on it. Failing
  test names from one pull request's log can put tests on the repository's
  flaky list after a rerun passes.
- **One log line** is read by its first and last 8 KB and its first and
  last 8 test markers: a line of a megabyte costs what a short one does.

## What leaves the Mac

The rules send nothing anywhere: `gh` reads from GitHub, and the log stays
in memory. The model's run sends the failing tests' names, messages and
source, and the names of the changed files and declarations (60,000
characters at most), to the Claude account `claude` is logged in with. So,
as for the turn-end option:

- it runs on a Claude subscription only. An API key behind a run stops it
  before the model is called; extra usage rests every model run of Nirux
  until the plan's limit resets (an hour at least, a week at most), kept in
  the state directory across relaunches;
- it runs only for a repository one of whose Claude Code agents runs on
  that same account, in a column of the workspace and a folder of that
  repository. The hook receiver says so on each SessionStart,
  UserPromptSubmit and Stop (`AgentHookEvent.onNiruxAccount`), by the rule
  that decides whether a final message may be read: no account variable in
  the agent's environment (a cloud provider, a gateway, an API key or a
  token), the configuration folder of a running Nirux, no settings file
  that chooses another account. A workspace without such an agent (a
  shell, Codex, a `claude` on an API key or a cloud provider, one in
  another repository, one that hasn't said yet) gets the rules only;
- the run sees its input and nothing else: no tools, MCP servers, hooks,
  settings or instruction files. `git` reads only what the local repository
  has (`GIT_NO_LAZY_FETCH`).

## Setting

Settings › Notifications › "Say when a CI failure looks flaky", on by
default. Off, nothing more is read (a run being read is dropped before
anything goes to the model) and nothing says "likely flaky". Any failure
(`gh`, the log, the model, the account) means the pull request shows as it
always did.

## Decided

1. Rules first, then the model on open cases only (the Lead, 2026-11-10).
2. Sonnet, not Haiku: 9 of the 11 open flakes against 6 or 7, and at one
   run a week its price doesn't count.
3. Only "likely flaky" is shown; real and unsure stay "checks failed".
4. Never a rerun by Nirux itself.
5. The notification waits for the verdict up to 20 s, then goes out
   without it; the row gets the verdict when it comes. One waits at a time:
   a second failure meanwhile sends the first's as it is.
6. A pull request already red at launch is triaged too (silently, as
   before): its row says "likely flaky" when it is.

## Files

`CITriage` (rules), `CITriage+Log` (what a log says), `CITriage+Prompt`
(the model's input and answer), `CITriageStore` (`ci-triage.json` in the
state directory), `CITriageInvestigation` (`gh`, the local repository, the
model), `ClaudeOneShotRunner` (the `claude -p` runs it shares with the
turn-end classifier), `NiruxShellView+CITriage` (the flow, the held
notification, the account gate), `TurnEndText.agentOnNiruxAccount` and
`TurnEndMarker` (the receiver's side).
Tests: `CITriageTests`, `CITriageInvestigationTests`, `CITriageFlowTests`,
and the account rule in `TurnEndClassificationTests`.
