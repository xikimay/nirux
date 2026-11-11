# Board Stages

> **Design record:** in progress. The model of a line is in the app; nothing draws it yet.\
> **Differs today:** the Board is still the table of [Project Board](project-board.md), one per project.\
> **User guide:** [Pull requests](../pull-requests.md#the-board).

Status: design validated by the user on 2026-11-11 (study D). The line's
model is implemented (`BoardStages`); the view and the per-space Board follow.

The Board was a table built for the merge queue: one row per branch, with
Agent, PR, Checks and Queue columns. It didn't say where a task stands, nor
what comes next. It becomes the overview of a space:

- **One Board per space**: a section per repository, then the tasks without one.
- **One line per task**: its state and title, a rail of four stations, one
  phrase, its pull request, a time.
- **Linked tasks stay together**: a sub-task under its task, a stack of pull
  requests on a numbered rail in merge order.
- **It shows, it doesn't ask**: no card to answer an agent from. A click on a
  line opens the task. The merge queue keeps its list, its sheet and its rules.

## Decided

- **Four stations, the same for every task**: Code, Reviews, Checks, Merge.
  The current one is the first not done.
- **A commit doesn't send a line back.** Reviews is done once a code review
  ran in the task, on any commit, and its turn is over: fixes always follow a
  review. The station then shows that the review is older than HEAD.
- **Which reviews count, and whether they must be on HEAD, are two constants**
  (`BoardStages.Rules`), built to become space settings.
- **Amber means an agent waits for the user**, and nothing else. It is never
  hidden, even once the pull request merged.
- **The queue's list stays the user's.** The number on the Merge station is a
  pull request's place in that list.
- **One reading per line**: its state, its phrase and its clock come from one
  ladder, so they can't disagree.

## 1. Stations

| Station | Done when | Read from |
| --- | --- | --- |
| Code | A review pass that counts ran in the task (on any commit), or its pull request is open and not a draft | Review badges ([review-badges.md](review-badges.md)); the Board's open pull requests |
| Reviews | Each pass that counts ran, and its turn is over | Review badges; the turn that started the pass |
| Checks | The pull request is open, every required check is green and none is red; with no required check, none still runs | The pull request's check rollup; `requiredChecks` of board.json |
| Merge | The pull request is merged, and the queue is through with it | The Board's merged pull requests; the merge queue |

- Only a pass that counts ends Code: a prompt that merely names an adversarial
  review records one.
- A review pass is recorded when it starts. Until its turn is over, Reviews is
  the current station, whatever the agent does meanwhile (a permission to
  allow, say). A pass started again is waited for again.
- A pull request the running queue works on is where the queue has it: Checks
  while it updates the branch or waits for checks, Merge while it merges and
  until the post-merge run ends, though GitHub says merged within a minute:
  its number stays on the Merge station meanwhile. A post-merge failure keeps
  it at Merge, in red; a stop from before its merge says nothing once it
  merged. The user confirmed its head at Start, whatever its reviews.
- **No Reviews station**, drawn as a gap, where no review is waited for or
  none was seen: a pull request with no workspace here, one the queue took or
  that merged before a review that counts ever ran, rules that ask for none.
  The rail never claims a review that didn't run.
- A task without a repository has no rail.

## 2. States

The line's dot and its current station take the state's colour. The first that
holds, in the sidebar row's order:

| State | Colour | When |
| --- | --- | --- |
| Needs you | amber | An agent waits for the user: a permission, a question, a plan |
| Failed | red | An agent stopped on an error or exited mid-turn |
| Working | green | An agent works |
| Waiting | grey | The running queue works on its pull request |
| Failed | red | Its open pull request conflicts with its base, or has a red check; else the last queue stopped on it. What is wrong now comes before what stopped a queue |
| Waiting | grey | Its agent asked the agent that started it |
| Blocked | dim | A blocker is set |
| Merged | purple | Its pull request merged |
| Idle | grey | Its base is a merged pull request's branch: the user retargets it |
| Waiting | grey | At Checks: checks run, or a required one hasn't reported. At Merge: the pull request before it in its stack hasn't merged |
| Idle | grey | At Merge and held: a draft, another base than the queue's, changes requested, a review required, review comments to answer |
| Ready | light | At Merge, and nothing holds it |
| Idle | grey | Nothing above |

A red check or a conflict shows at any station: the phrase says which.

## 3. Phrase, pull request, clock

The phrase is the state's own line of the ladder:

- "Needs you · a question"; the agent's failure; "Working";
- the queue's step ("Updating branch", "Waiting for nightly");
- "Conflicts with main"; "Checks failed: test", or "Checks failed · likely
  flaky" when the [triage](ci-failure-triage.md) said so; "Queue stopped:
  changed";
- "Asking Lead"; "Blocked · …";
- "Merged", "Merged · Clean up", "Merged · cleaning up…";
- "Base #52 merged · Retarget to main" ([stacked pull requests](pr-stacks.md));
- at Checks, "Checks running", or "No test run yet" while a required check
  hasn't reported, each followed by "lands after #52" in a stack;
- at Merge, "Lands after #52", "Draft", "Targets release", "Changes
  requested", else "Ready". "Ready" and "Draft" add what the pull request
  passed, and only that: "Ready · reviews done, checks green";
- at rest, "Next · …" (the user's next step, else the Lead's), else where the
  task stood when its last turn ended, else what the station needs: "No code
  review yet", "No pull request yet".

"Clean up" and "Retarget to main" are links: the one click that moves the line
on. While an agent works the line says "Working", not the last turn's line,
which is about the turn before.

The pull request cell reads "#52", "#53 · 2/3" in a straight stack, "#53 · on
#52" in a fork, "no PR yet".

The clock counts from the turn's start while an agent works, from the checks'
while the line waits for them, else from the last activity (as for a turn
whose start isn't known). A line that is
ready, blocked, merged or in the queue's hands has none.

## Known limits

- **Reviews Nirux can't see.** Codex has no prompt hook, and a `claude -p`
  review run from a shell doesn't count ([review-badges.md](review-badges.md)):
  such a task stays at Reviews, "No code review yet".
- **Review badges are kept per workspace**, each pass's latest run only. A
  workspace that moves on to another branch keeps the reviews of the first;
  closing the workspace that ran the review loses it; and a second run of a
  pass puts the line back at Reviews until its turn ends.
- **A review that died** (its turn stopped on an error) still counts once a
  later turn ends: nothing records that a review finished.
- **Checks and reviews are about two commits**: the rollup is of the pull
  request's head on GitHub, the badges of the local HEAD.
- **A queue's stop stays** on its pull request until the next Start, until
  the pull request's head moves, or until it merges (unless the stop is the
  post-merge run's failure).
