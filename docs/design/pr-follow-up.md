# PR Auto Follow-up

> **Design record:** in progress. PR 1 (the decision, not wired) and PR 2 (the setting, the wiring, the row).\
> **Differs today:** nothing types yet: PR 2 wires it.\
> **User guide:** to come with PR 2.

Status: approved by the user on 2026-11-19, from the review of "A look inside
the factory" (a local daemon owns each pull request until it merges). Lane 2:
Nirux types into a terminal.

Once a task has pushed its pull request, three things can still keep it from
merging: new review feedback, failed checks, a conflict with the base. Nirux
already shows each one and waits for a click (Address, Ask Agent Why CI
Failed, "Conflicts with main"). The follow-up types the matching prompt itself
while the task's Claude sits idle, three rounds per pull request at most, then
hands the pull request to the user.

## Setting

Space Settings › Defaults, "Follow up on pull requests", per space, off by
default: it types into terminals and spends usage on its own.

## Which agent

Tasks only, never the main checkout or a Lead: the task's Claude in the pull
request's checkout, running with Nirux's hooks. Its prompt must take a Mission
message (`isPromptFree`: not working, no dialog, no draft, no failed turn, no
turn end being read, a prompt taken since it started), its turn must not have
ended on a question to the user, no Mission question or message of the task
waits, and its last turn ended 30 s ago or more.

## When a round goes

After each read of the pull request and each turn end of that agent:

- **Not at all** while a running merge queue holds the pull request (it reruns
  checks and stops on its own), or auto-merge is on (a round's commit would
  merge unseen).
- **The checkout first:** its HEAD is the pull request's head (no push in
  flight, nothing unpushed), and no tracked file changed, read just before
  typing. Untracked files don't count.
- **Kinds, in order.** A kind that must wait lets the next one go: a check that
  never ends must not hold feedback.
  1. **Conflict:** `mergeable` CONFLICTING (UNKNOWN never counts), with a plain
     base name and a remote of the checkout for the pull request's repository.
  2. **CI:** a red check of the pull request's own Actions runs that ended on
     FAILURE or TIMED_OUT (a cancelled job, or one that never started, isn't
     the branch's doing), once its runs are over, the triage has spoken, and
     the failure is 2 minutes old (the user's own Rerun or Why Failed goes
     first). A likely flake starts nothing: its rerun stays the user's. A
     failure the user's Why Failed took is theirs.
  3. **Feedback:** review threads, and what people (not bots) write besides an
     approval, posted since Nirux started following the pull request, never
     handed before, outdated threads left out, the newest 3 minutes old (bots
     post over a minute or two).

## Prompts

Each ends on "(Nirux follow-up, round n of 3.)".

- Conflict: "PR #N conflicts with `base`. Run `git fetch <remote> <base>`,
  merge `<remote>/<base>` into this branch, resolve the conflicts, run the
  checks, commit and push." Never a rebase: a pushed branch only moves
  fast-forward.
- CI: the `gh run view … --log-failed` commands of Why Failed, then "find why
  it failed, fix it, run the checks, commit and push. If this branch didn't
  cause it, say so and push nothing."
- Feedback: Address's `/receiving-code-review` prompt with the new items, then
  "Commit and push the fixes."

## Rounds and stops

- A round is recorded when decided, so that no other read types it again, and
  dropped if typing fails. Three per pull request, all kinds together.
- A round is judged once its turn ended (or 2 hours after it was typed: Esc
  sends no Stop), its agent rests, and reads came after it (of feedback too,
  for a feedback round). While GitHub computes `mergeable` or a run goes,
  nothing is judged.
- **Stops**, each a "Needs you" with its reason:
  - another round was due after three;
  - a round pushed nothing and its signal is still there (still conflicting,
    still a fixable failure, one of its items still listed);
  - 10 minutes after a round, the checkout still isn't at the pull request's
    head (commits not pushed, or a push from elsewhere not pulled).
- A stop holds until the pull request's head moves or what stopped it goes
  away; while that isn't known, it holds.
- `pr-follow-up.json` in the state directory (0600) keeps each pull request's
  rounds, handed feedback and stop, by URL: the count survives a relaunch and
  a workspace opened again. An entry goes once its pull request reads merged
  or closed, or after 30 days with no change unless it holds a stop. What
  another build wrote differently is dropped entry by entry, not the file.

## Wiring rules for PR 2

- End a round only on `finishedTurn(afterTypingAt:)` with no failed turn.
- Read the tracked changes (`GitDetect.hasTrackedChanges(at:)`) off the main
  thread just before typing; date `readAt` and `feedbackReadAt` from when
  each read started.
- A merge queue holds a pull request while any of its entries isn't done or
  stopped.
- At most one automatic round in flight across all tasks.
