# Task Thread

> **Design record:** PR 1 of the socle is built: what Nirux records and the thread frozen at close. Next: `read_thread` and the daily pass's waits (PR 2), then the panel opened from the task's row (two PRs).

Status: study approved by the user on 2026-11-21, direction B (the panel from
the row). Study page: https://claude.ai/artifact/R4mJgibGcXiPzqsFjRA1e8

A task's story from its request to its merge. Nirux kept most of it already,
in nine places that don't talk to each other, and lost the rest: the request
(the handover file goes with Clean Up), every status line, next step and
blocker but the last, every turn end, and the follow-up rounds and triaged
failures their files drop at a merge or a passing rerun. The thread records
what was lost, joins the rest at read, and copies it once, when the task
closes.

## 1. What Nirux records

One event per change, with its time and who made it (`TaskThread.Author`:
the user, the Lead, the parent task, the task's agent, Nirux itself).

- **request**: at birth (`openTaskWorkspace`: ⌘N, the Lead's or a task's
  `start_task`), the description as given and the template's name.
- **goal**: each change of `purpose` (View/Edit Context…, and the goal the
  task rows study writes at birth, through `setPurpose`).
- **status**: each new status line, at its turn's end (Sonnet's), or the
  user's own summary. Claude's last message and Codex's report are never
  recorded: they are the conversation, not a line about it.
- **nextStep**, **blocker**: each change, by the Lead (`set_task_context`),
  the user (View/Edit Context…), or Nirux (a merge clears the Lead's).
- **turnEnd**: each Stop or turn-complete event of the task's agents, from
  the hook case that also dates the task's last activity
  (`recordAgentHookActivity`), which the forgotten-tasks digest reads.
  A turn end replayed after a relaunch counts once.
- **followUp**: a pull request's follow-up rounds, when its entry goes at
  its merge or close (`pr-follow-up.json` keeps no merged pull request).
- **ciFailure**: a triaged failure, when its verdict is given (a rerun that
  passes takes it out of `ci-triage.json`).
- **closed**: the close (§3); it names the task's pull requests.

Only tasks keep a thread (`NiruxShellView.isTask`), and a workspace whose
thread exists already (a worktree removed under its task): never the Lead,
nor a workspace in the main checkout.

## 2. What is joined at read

`TaskThread.swift` compiles with Foundation alone; the app-specific joins
live in `TaskThread+Sources.swift`. The store requires an explicit state
directory URL. `TaskThread.events(from:)` is pure (no AppKit); `Sources.load` reads the
files by the task's workspace id, then by its pull requests' URLs, from
`sessions.jsonl` in every space (the live pull request follows the focused
column, which may be another checkout). Nothing is copied.

- by workspace id: its Missions (a question with its kind and
  recommendation, an answer and who gave it, a tell, a result, a question
  handed to the user), its review runs, the Lead's findings in every space;
- by pull request: its follow-up rounds and triaged failures while their
  files still have them, and the rules added to the brief whose evidence
  cites it: by URL, or by number alone in a space of one repository.

The same event read twice (a hook replayed, a round both recorded and
joined, a task closed twice) counts once, and so does a status line that
repeats the one before.

## 3. The freeze

Every close goes through `closeWorkspace(at:)` (⌘W, `close_task`, Clean
Up): what the files say of the task is appended, then `closed`. Then one
`gh pr view <url> --json …` per pull request adds its history: its
opening, its newest 100 commits, its reviews, the last run of each check,
its merge or close. A closed thread reads its file alone (its reader passes
no sources): the files it was joined from drop the task in time.

- Not while `missions.json` can't be read: the thread then has no close and
  is joined at each read.
- A history `gh` couldn't give (offline, signed out, a quit right after the
  close) is missing; the close names the pull requests, so a later read can
  ask again.

## 4. Storage

- `<state dir>/projects/<space id>/threads/<workspace id>.jsonl`, 0600,
  only appended to; it moves with its task into another space.
- A request keeps 65,536 characters, any other text 8,000 characters; a file takes no
  more past 2 MB, but its close.
- A line a crash cut is skipped, and the next one starts on its own line.
- At launch and after each close, in every space's folder (a deleted
  space's too): a thread no open task owns goes six months after it was last
  written, and the oldest of them go first while they hold more than 20 MB.
  An open task's thread stays, under its own 2 MB.
- What is queued is written before Nirux quits. Closing workspaces are
  omitted from saved state, even while their exit animation runs.
- The thread never reads transcripts.

## 5. Not yet

- `read_thread` for the Lead and the daily pass's waits (PR 2).
- The panel from the task's row, where the user answers (two PRs).
- The Thread button in the browser column (after the panel).
- Removing completed Missions older than 30 days from `missions.json`: approved
  only after their text is frozen, in a separate PR; open Missions stay.
- A task's wait for another's merge (`MergeWait`), once task dependencies
  land.
- A task handed over by a `nirux://` link records no request: it has no
  New Task request.
