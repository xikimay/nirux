# Board Stages

Status: design validated by the user on 2026-11-11 (study D). The line's
model is implemented (`BoardStages`); the view and the per-space Board follow.
Until they ship, the Board is the table of [Project Board](project-board.md).

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
- **A line only moves forward on reviews.** Reviews is done once a code review
  ran in the task, on any commit, and its turn is over. A commit after the
  review doesn't send the line back: fixes always follow a review. The station
  then shows that the review is older than HEAD.
- **Which reviews count, and whether they must be on HEAD, are two constants**
  (`BoardStages.Rules`), built to become space settings.
- **Amber means an agent waits for the user**, and nothing else.
- **The queue's list stays the user's.** The number on the Merge station is a
  pull request's place in that list.

## 1. Stations

| Station | Done when | Read from |
| --- | --- | --- |
| Code | A review pass ran in the task (any pass, any commit), or its pull request is open and not a draft | Review badges ([review-badges.md](review-badges.md)); the Board's open pull requests |
| Reviews | Each required pass ran, and the turn it started in is over | Review badges; the working turn's start |
| Checks | The pull request is open, every required check is green and none is red | The pull request's check rollup; `requiredChecks` of board.json |
| Merge | The pull request is merged | The Board's merged pull requests |

- A review pass is recorded when it starts. While the turn that started it
  still runs, Reviews stays the current station.
- A pull request the running queue works on is where the queue has it: Checks
  while it updates the branch or waits for checks, Merge while it merges or
  waits for the post-merge run. The user confirmed its head at Start, whatever
  its reviews.
- A pull request with no worktree here has no Reviews station: nothing here
  could have seen a review.
- A task without a repository has no rail: "no pull request".

## 2. States

The line's dot and its current station take the state's colour. The first that
holds, in the sidebar row's order:

| State | Colour | When |
| --- | --- | --- |
| Needs you | amber | An agent waits for the user: a permission, a question, a plan. Never hidden, even once merged |
| Merged | purple | Its pull request merged |
| Failed | red | An agent stopped on an error or exited mid-turn |
| Working | green | An agent works |
| Waiting | grey | The running queue works on it |
| Failed | red | With no agent working: the last queue stopped on it, it conflicts with its base, a check is red |
| Blocked | dim | A blocker is set |
| Waiting | grey | At Checks: checks run. At Merge: the pull request before it in its stack hasn't merged |
| Ready | light | At Merge, and nothing holds it: not a draft, on the base branch, no merged base |
| Idle | grey | Nothing above |

## 3. Phrase, pull request, time

The phrase follows the state's order: "Needs you · a question", the agent's
failure, the task's status line while it works, the queue's step, "Queue
stopped: changed", "Conflicts with main", "Checks failed: test" (or "Checks
failed · likely flaky" when the [triage](ci-failure-triage.md) said so), what
an idle agent waits for ("Asking Lead"), "Blocked · …". Then:

- "Base #52 merged · Retarget to main", at any station: its last words are a
  link ([stacked pull requests](pr-stacks.md));
- at Checks, "Checks running", followed by "lands after #52" in a stack;
- at Merge, "Lands after #52", "Draft · checks green", "Targets release", else
  "Ready · reviews done, checks green";
- at rest, "Next · …" (the user's next step, else the Lead's), else the status
  line, else what the station waits for: "No code review yet", "No pull
  request yet".

The pull request cell reads "#52", "#53 · 2/3" in a straight stack, "#53 · on
#52" in a fork, "no PR yet".

The time counts the turn while an agent works, the checks while the line waits
for them, else the time since the last activity. A line that is ready, blocked,
merged or in the queue's hands shows none.

## Known limits

- **Reviews Nirux can't see.** Codex has no prompt hook, and a `claude -p`
  review run from a shell doesn't count ([review-badges.md](review-badges.md)):
  such a task stays at Reviews, "No code review yet".
- **Review badges are kept per workspace**, not per branch: a workspace that
  moves on to another branch keeps the reviews of the first.
- **Checks and reviews are about two commits**: the rollup is of the pull
  request's head on GitHub, the badges of the local HEAD.
