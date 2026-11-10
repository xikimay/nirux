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
- the row's menu starts with the reason ("Likely flaky: …", its tooltip
  holds all of it), then **Rerun Failed CI Jobs…**, then **Ask Agent Why CI
  Failed**.

A failure Nirux reads as real, or can't read, shows exactly as it always
did. There is no "likely real": a red pull request is already taken as
real, and the words would be one more place to be wrong.

Nirux never reruns by itself. The rerun stays the user's, behind its
confirmation.

## How it decides

**Rules first.** When a pull request's checks are red and their run is
over, Nirux reads, with `gh`: the run's jobs and steps, the failed steps'
log, and the files the pull request changes. In this order:

1. Every failed job ended without a single step (no runner took it, the
   runner was lost): **flaky**. A run with no job at all is not: GitHub
   refused the workflow file.
2. The log holds compile errors: **real**.
3. No test failed and a dependency download did ("failed downloading … 
   required by binary target"): **flaky**.
4. A test fails that failed in an earlier attempt of the same run: **real**.
5. The pull request edits the file of a failing test: **real**.
6. Every failing test is one Nirux saw fail and then pass on a rerun of the
   same commit: **flaky**.
7. Any other failing test is **open**; a log with nothing recognized gets no
   verdict.

A pull request with several red runs is flaky only when each is; a red
check that is not an Actions run of the pull request's repository (a commit
status, another repository) can't be read, so the failure stays plain.

**Then a model, on what the rules leave open**: failing tests the pull
request doesn't edit. Claude Sonnet, through a headless `claude -p`, is
given the failing tests with their messages, their source, and the files
the pull request changes with the declarations edited in each (read from
the workspace's repository, at the run's commit). It answers one sentence,
then FLAKY, REAL or UNSURE. The sentence is the reason shown.

**What Nirux learns.** It remembers each run it triaged with the tests that
failed. When that run later passes (a rerun keeps the run, on the same
commit), those tests failed and then passed with no change: they go on the
repository's flaky list, which rule 6 reads. A test leaves the list two
months after its last such failure.

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

The one real failure called flaky is a timing test that failed on the pull
request that introduced the parallel test runner: a fair call either way.

Two more sets stress the model on what a wrong "flaky" would cost:

- 98 regressions that edit no test (each mutation replayed as a pull
  request holding only the mutant commit): Sonnet called none flaky (95
  real, 3 unsure), and neither did Haiku in three passes;
- 65 flakes replayed against other pull requests' changes: Sonnet found 59.

Asking for a sentence before the verdict is what makes a model commit: with
one word, Haiku answers "unsure" on almost every flake.

About one failed pull request run a day here, of which the rules settle 9
in 10: the model runs about once a week, 3 s at the median. That is why the
stronger model is the one used.

## Limits

- **XCTest and Swift builds only.** The rules were measured on those logs;
  another test framework's failures are not recognized, so its runs get a
  verdict from rules 1 and 3 only. Each framework needs its own
  measurement.
- **A test's first flake** is unknown to rule 6; only the model can call it.
- **The model is asked when the failure is first read.** A workspace whose
  agent wasn't running then (a pull request already red at launch, before
  its agent resumed) keeps the rules' answer.
- **The reason is a model's sentence about a log**, which the pull
  request's own code writes. It is cleaned, bounded and only ever shown. A
  log made to say "flaky" could earn the word; nothing acts on it.

## What leaves the Mac

The rules send nothing anywhere: `gh` reads from GitHub, and the log stays
in memory. The model's run sends the failing tests' names, messages and
source, and the names of the changed files and declarations, to the Claude
account `claude` is logged in with. So, as for the turn-end option:

- it runs on a Claude subscription only. An API key behind a run stops it
  before the model is called; extra usage rests every model run of Nirux
  for an hour;
- it runs only for a workspace whose Claude Code runs on that same account.
  The hook receiver says so on each SessionStart, UserPromptSubmit and Stop
  (`AgentHookEvent.onNiruxAccount`), by the rule that decides whether a
  final message may be read: no account variable in the agent's
  environment, the configuration folder of a running Nirux, no settings
  file that chooses another account. A workspace without such an agent (a
  shell, Codex, a `claude` on an API key or a cloud provider, one that
  hasn't said yet) gets the rules only;
- the run sees its input and nothing else: no tools, MCP servers, hooks,
  settings or instruction files.

## Setting

Settings › Notifications › "Say when a CI failure looks flaky", on by
default. Off, nothing is read and nothing says "likely flaky". Any failure
(`gh`, the log, the model, the account) means the pull request shows as it
always did.

## Decided

1. Rules first, then the model on open cases only (the Lead, 2026-11-10).
2. Sonnet, not Haiku: 9 of the 11 open flakes against 6 or 7, and at one
   run a week its price doesn't count.
3. Only "likely flaky" is shown; real and unsure stay "checks failed".
4. Never a rerun by Nirux itself.
5. The notification waits for the verdict up to 20 s, then goes out
   without it; the row gets the verdict when it comes.
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
