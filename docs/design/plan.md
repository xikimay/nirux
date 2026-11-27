# Day plan

> **Design record:** in progress. The model, the store, the agents' tools, the sidebar's feature folders, calm
> rows and planned sessions are built, behind Space Settings › Lead › "Day plan (preview)", off by default.

Status: study approved by the user on 2026-11-27 ("on va tester puis si chiant
on avisera plus tard"): directions 1 (calm rows) and 3 (the Lead island), with
the morning triage in the island. Study page (French):
https://claude.ai/artifact/6XK8A4Gx6SxV4rTD3WD9gP

The user plans the day with the Lead each morning, before any task exists;
then steps turn up inside the first big task, and the plan gets lost. Nirux kept
one "Next" line per task, which the Lead rewrote 634 times on 86 tasks in two
weeks. The plan keeps the whole day instead, as one tree per space, in the
sidebar that exists today.

## Decided

- **One plan per space**, kept by Nirux and read back by a restarted Lead.
- **Features**: labels that group lines; no worktree, no agent. Folded, a
  feature is one line with a small progress ring.
- **Four kinds of lines in a feature**, or outside any: a to-do for the user, a
  line of the Lead's own work, a planned session (its pale "Planned · Start"
  row lights up in place when it starts), a running session.
- **Steps** under a line, for its agent or for the user. A step for the user
  stops the agent: the row turns amber. A step that grows becomes a sub-task,
  in its place.
- **Nothing moves by itself.** An addition goes at the end of its place, so
  never above a session's current step. Only the user reorders.
- **Nothing is deleted by itself.** A checked line stays until the next
  morning, then shows under "Done Yesterday".
- **Each line says where it comes from**: who added it and when, and for the
  Lead's lines the source it read (GitHub, Linear, Slack, Mail, Figma) with a
  link. A line someone else added keeps a blue dot until the user looks at it.
- **A planned session can wait**: for the user's go, a merge (the existing
  `MergeWait`), or a checked line.
- **Morning triage in the island**: the Lead reads the sources with its own
  connectors and proposes lines, grouped by feature, each with its source and
  why. The user adds, starts or drops each in one click, or tells the Lead.
  Nirux adds no integration.
- **Rules for the Lead go in its tools' descriptions**: its instructions sit at
  2,030 of 2,048 characters.

## The model

`Plan` (NiruxCore, `Plan.swift`, `Plan+Changes.swift`) is a tree of
`Plan.Line`: `feature`, `todo`, `lead`, `session`, `step`. A feature sits
at the top; to-dos, Lead lines and sessions at the top or in a feature; steps
and sessions under a to-do, a Lead line or a session. A session line without a
workspace is planned; `link` turns a to-do, a Lead line, a step or a planned
session into a task's line, in its place, with its steps. Each workspace has
at most one line.

Who may change what (`TaskThread.Author`):

| | Add | Check | Start (`link`) | Move, remove | Propose | Take, drop |
| --- | --- | --- | --- | --- | --- | --- |
| User | anything | anything | yes | yes | | yes |
| Lead, Nirux | anything, at the end | anything | yes | | Lead | Lead |
| A task's agent | steps under a session | its agent's steps | | | | |

An agent's tool reaches its own session's line only. A refused change throws a
`Plan.Refusal` whose text the tools can pass on, and leaves the plan as it
was. `released` lists the planned sessions whose awaited line is checked;
removing that line hands them back to the user's go.

## Store and tools

`Plan.Store` keeps a space's plan in `plan.json` beside its brief, written by
the app only, 0600 and atomically. A file it can't take as a plan (not one it
decodes, a newer `schemaVersion`, too large, unreadable just now) is never
replaced: changes are refused with the reason, reads still answer. A change
that would make the file larger than a load reads (1 MB) is refused too ("the
plan is full"), so the file on disk is always one Nirux reads back.

The tools are listed only where the space's day plan is on
(`SpaceDefaults.dayPlan`, off by default, no switch shown until the sidebar
shows the plan); the app refuses them elsewhere. Their rules live in their
descriptions.

- The Lead: `read_plan` (every line with its id, then its proposals),
  `add_to_plan` (a to-do, a Lead line, a session, planned or a task's, or a
  step; into a feature by name, under a line, or for a task; with `propose`,
  into the triage, with source, link and why), `check_plan_line`.
- A task's agent: `task_steps`, its own steps only: add at the end, check
  its own, read them back. Its first step makes its task's line at the end
  of the plan.

## In the sidebar

While the space's day plan is on, Tasks lists each feature first, in the
plan's order: a fold row with its done lines over all of them and a small
ring, then its tasks' rows (nested, as sub-tasks are), its to-dos ("you"), its
Lead lines ("Lead") and its planned sessions. Then come the tasks in
no feature, as before, then the loose to-dos and planned sessions. Sessions
under a to-do, a Lead line or a session list with their feature. The Lead's
lines outside any feature sit under its row, or end Tasks while the space has
no Lead. A task in a feature leaves its own place, and doesn't drag. A folded
feature keeps the tasks asking the user or on screen, with their sub-tasks,
and says how many of its lines wait for the user: its to-dos, its tasks and
sub-tasks asking, an agent stopped at the user's step (amber while one of
those is an agent). Folds last until the app quits; nothing is edited from the
sidebar yet. The switch's tools reach an agent at its next start.

A task with steps keeps its row calm. Unselected, its line is its current
step (its first open step) behind a bar of one segment per step (done in
violet, the current one green while the agent works, amber when it is the
user's): "Next" becomes the first open step, "Working" the step worked on, and
a step for the user turns the row amber ("Needs you") until its pull request
merges or closes. Selected, the row lists its steps under its line: "✓ N
done", then each open one, the current one marked; the Lead's next step gives
way to them. Where no bar shows (the command bar, the catch-up card, the hover
preview) a step worked on says "Working · …". A row stopped at the user's step
asks the user as a question does for the sidebar (a fold, the rail, the
archived list keep it); ⌘J and the waiting count stay with agents' questions
and approvals, which they answer in place. The Board doesn't read the steps
yet.

A planned session is a pale row with a dashed ring: "Planned · Start", or
"After “…” · Start" while the line it waits for is unchecked. Start opens the
New sheet with its title and detail; the task started there takes the line's
place, so the row lights up where it was. The Lead does the same with
`start_task`'s `plan_line`; with `after`, the waiting task's row ("Waits for
#418 to merge") takes the place at once. Checking the line a planned session
waits for starts it as `start_task` would, for the space's Lead: at once
while the space starts tasks without asking, else in the New sheet. Without a
Lead it waits for Start.

## Pull requests

1. The model (lane 1).
2. The per-space store; Lead tools to write and propose lines, with source
   and link; a session tool to add and check its steps (lane 2).
3. Feature folders in the sidebar. 4. Calm rows with steps. 5. Planned
   sessions. 6. The Lead island. 7. Triage in the island. (Lane 3: the user
   sees renders before they land.)
8. Editing: +, Return, Tab, drag, check, Make It a Task (lane 2).
9. Done Yesterday and the daily pass (lane 2).

UI that isn't usable yet stays behind one setting, off by default.
