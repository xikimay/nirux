# Spaces, anchors and the Lead

> **Design record:** shipped. Every plan step, S1 to S13, is in the app, with tasks without a repository and learned rules.\
> **Differs today:** the status line below lists fewer steps than have shipped, and some passages describe the earlier behaviour in the present tense.\
> **User guide:** [Spaces and tasks](../spaces-and-tasks.md).

Status: design validated by the user on 2026-11-08. Shipped: anchors and
routing (S4), one ⌘N (S7), Space Settings and per-space defaults (S8), the
empty space view (S9), the Lead's workspace and settings (S11a), a board per
repository (S12), the Lead's task context (S13), tasks without a repository.
Where this document and [projects.md](projects.md) differ
(management UI, routing, defaults), this one wins.

Creating spaces and workspaces was messy because a space didn't know where its
code lives. Five ways to create a workspace each guessed a different starting
point:

| Entry | Starts from today |
| --- | --- |
| New Workspace (⌘N) | `~`, named "ws N", no agent |
| New Project | the active workspace's folder, not remembered |
| New Task… | `origin/<base>` after a fetch, the repository guessed from open workspaces (fails in an empty space) |
| New Worktree | the focused terminal's `HEAD` (fails after a `cd` elsewhere) |
| `nirux-worktree` skill | the agent's checkout `HEAD`, no fetch |

This document gives a space its repositories (anchors), replaces the five
entries with one, makes parent/child messages reliable, adds a Lead agent per
space, and strips the interface down to what is used.

## Decided

- **A space is a free group** with zero, one or several anchors (a git
  repository or a folder), one of them the default.
- **A repository belongs to one space.** Its worktrees open there.
- **The UI says "Space" again**, not "Project". Code, persisted keys
  (`profileID`), `NIRUX_PROFILE_ID` and the `profile=` parameter keep their
  names.
- **General** is the default space (id `default`, today named "main"): first in
  the picker, never deleted, no anchors. It takes what arrives from outside
  and matches no anchor.
- **One door: ⌘N.** It replaces New Workspace, New Task… and New Worktree, and
  always starts from `origin/<base>`, fetched. The skill and the Lead go through
  the same path.
- **One Lead per space**, optional, seeing only its space. It starts tasks
  without asking (a switch turns that into "propose, you click").
- **"Report to the Lead"** in ⌘N, checked by default when the space has a Lead.
- **Always the user:** merging, removing a worktree or branch, and permissions
  the Lead can't judge.
- **Isolation by place and by view.** Each task has its own worktree and
  branch; a space shows only itself. No sandbox (out of scope).
- **The sidebar Activity section goes.** Cards, native notifications, the Dock
  badge and ⌘J cover it.
- **Missions are rebuilt before the Lead**, in their own PR: messages are typed
  into prompts both ways.
- **Clean, minimal interface, the Apple way**, with only what is used. Dark
  only stays.
- **One task, at most one repository.** A feature across two repositories is
  two tasks the Lead links. Work that needs no repository gets a folder of its
  own (see "Tasks without a repository").
- **One merge queue per repository.**

## Spaces and anchors

```swift
struct SpaceAnchor: Codable, Equatable {
    enum Kind { case gitRepository(commonDir: String), folder(path: String), unknown(raw: Data) }
    var kind: Kind
    var name: String        // the main checkout's folder name, or the folder's
    var isDefault: Bool
}
```

- Stored on the space in `projects.json` (schema version 2). Decoding stays
  lenient and keeps unknown kinds; a build that finds a newer schema reads the
  file and never writes it (existing rule). Version 2 is written only once a
  space has an anchor, so an older nightly keeps writing the file until then.
  `state.json`'s mirror carries the anchors too; an older build's mirror has
  none, and the file's are kept.
- **Identity** of a repository is
  `git rev-parse --path-format=absolute --git-common-dir`, symlinks resolved:
  the same for the main checkout and every linked worktree. Run it off the
  main thread with a limit of about 300 ms. Folder anchors compare whole path
  components (`/a/web` doesn't match `/a/web2`).
- **One space per anchor.** Adding a repository anchored elsewhere offers to
  move it.
- **Adding an anchor** offers to move that repository's workspaces into the
  space; the ones in General are preselected. A workspace counts when its
  folder, or its focused terminal's, now routes to the space.
- **A space with anchors** opens a plain new workspace in its default anchor's
  main checkout, never in `~`. When that folder is gone, the first of its other
  anchors' folders still there; a bare repository has no main checkout to find
  without git: `~` then.
- **Never the home folder** (or a folder holding it) as a folder anchor: every
  folder under it would join the space.
- **Read-only:** while `projects.json` can't be written (a newer Nirux saved
  it, or it is unreadable), anchors don't change, as spaces can't be deleted:
  only that file keeps them.
- **New Space…** (shipped) suggests the focused terminal's repository, already
  in the list and naming the space, unless another space has it. "Add
  Repository…" in Space Settings › General anchors the repository holding
  the folder picked (or the folder, when it is in none and the user agrees).
  General also lists the repositories and folders, adds one ("Add
  Folder…" anchors a folder even inside a repository), makes one the
  default, and removes one.

## Routing

Decided once, before the workspace is created, so the first agent starts in the
right space with the right env:

1. **Anchor match.** The most specific anchor wins (a folder anchor inside a
   repository beats the repository).
2. **Parent.** A worktree or Mission child joins its parent's current space.
3. **Started by the user from a space** (⌘N, the sidebar's "+", the space menu,
   Open Worktree): that space.
4. **Anything else** (a `nirux://` request from outside, a confirmed request
   without a launch ID): **General**, with a notification offering "Move to…"
   and "Anchor to a Space…". It is a banner at the bottom of the window (a
   native notification never shows: the request brings Nirux to the front),
   for 12 s or until a click elsewhere.

A request from a Nirux terminal names its shell's space (`profile=`), which
counts as rule 3. Routing runs git only once a space has an anchor, and waits
for it at most 300 ms (3 s after a worktree was made off the main thread, for a
`nirux://new-worktree` or a ⌘N task); past that it routes as if the folder were
in no repository.

After that the assignment is sticky: only the user moves a workspace.

## One door: ⌘N

A sheet titled "New in <space>":

- A large description field. Return with text starts a task; Return with an
  empty field opens a plain workspace (a shell in the default anchor's main
  checkout, or `~` without anchors).
- **Repository** popup, shown outside General, the default preselected: the
  space's repositories and folders, then "No Repository" (a task in a folder
  of its own). **Agent** (the space's default) and **Template** popups.
- The suggested branch on one line, editable, "from origin/main"; without a
  repository, the folder's name, editable, "new folder in ~/Nirux Tasks, no
  repository".
- **Report to the Lead** checkbox, shown when the space has a Lead, checked by
  default: the task's Mission reports to the Lead's Claude (shipped with
  S11c). A Lead's proposal comes with it checked.
- **Sub-task of “<task>”** checkbox, shown when the sheet comes from a task's
  "New Sub-task…" (its card menu, or Workspaces in the menu bar), checked: the
  heading reads "New Sub-task in <space>", and the task it starts lists under
  that task, in its repository (the Repository popup hides; checked again, the
  sheet goes back to it). A sub-task is new work with a description: Existing
  Branch… hides, and Start waits for text instead of opening a shell.
  Unchecked, it is a task of its own. Offered for an active task: a workspace
  in a git worktree, in a space that has its repository (so not in General),
  or a task without a repository, whose sub-tasks get their folders in its
  own while it is there.
- **Existing Branch…** opens an existing worktree (today's Open Worktree), or
  a branch without one: its worktree is made, with a shell (shipped with S7).
- Names come from the description's first line, else the branch, else the
  folder. Never "ws N".
- The skill and the Lead start from `origin/<base>` too. The skill may ask for
  the current `HEAD` explicitly when the user wants a stacked branch
  (`from=head`); a branch that exists opens as it is.
- **A space without a repository**: the Repository popup shows "No
  Repository", where tasks start in folders of their own, and offers the
  focused terminal's repository and "Add Repository…". General never has a
  repository: its tasks start in folders, with no popup.

## Tasks without a repository

Research, writing, a document, a question, a one-off script: work that needs
an agent but no git (the user, 2026-11-11: "sometimes you just don't have a
repo").

- **A new folder per task**, named after it (the description's first line, at
  most 50 characters; "/" and ":" become "-", no leading "."), "name 2",
  "name 3"… when taken: never a folder already there. It goes in the tasks
  folder, `~/Nirux Tasks` unless Settings › General picks another (never one
  in a git repository); in the space's folder when that folder is selected
  and surely outside git (no `.git` in it or above); or in the folder of the
  task it is a sub-task of. Only `~/Nirux Tasks` is made when missing: any
  other folder gone stops the task with an error. The handover goes there,
  and the agent starts there. The workspace keeps that folder
  (`taskFolder`), wherever its terminals go.
- **Like any task** in the sidebar: its row, status, Missions, Report to the
  Lead, sub-tasks, the turn status line and the catch-up card. With no branch
  or pull request, those lines stay empty; the row shows its folder.
- **Its space** is the one it was started from (the Lead's, the parent
  task's), never one that anchors a folder above it.
- **Nothing to clean up:** Clean Up Worktree… isn't offered, Clean Up Merged
  Worktrees… skips it, even with its folder gone, and closing or archiving it
  never deletes the folder. The user deletes it in Finder.
- **The trust question.** Claude Code and Codex ask whether to trust each new
  folder, before any hook runs. Nirux reads it on the screen of these tasks'
  agents, from their launch until a hook or a key reaches them (at most 5
  minutes), and the row reads "Needs you · Trust this folder?" (the Dock
  badge, ⌘J and the Lead's `list_tasks` count it too). Nirux never writes
  Claude Code's settings: trusting `~/Nirux Tasks` once in Claude Code covers
  every folder in it, which the ⌘N sheet says until the user starts a Claude
  Code task there (or picks another tasks folder).

## Missions without waiting

Today a child's `ask` blocks for up to 90 s and must be re-run until answered;
the parent only sees a question if it runs `--mission receive` itself; the user
answers through an `NSAlert` with a one-line field. Questions get lost and the
reply UI is unreadable.

New flow, built on the guarded typing `tell` already uses
(`AgentStatusMachine.isPromptFree`, retried at each turn end):

- **Ask.** A Claude child's `ask` records the question and returns at once,
  telling the agent to end its turn: the answer will be typed into its prompt.
  The child shows "Asking <parent>" in neutral grey (amber stays for the user).
- **Deliver.** Nirux types the question into the parent's prompt when it is
  free, with one line naming the child and how to reply.
- **Reply.** The parent's `--mission reply` is typed into the child's prompt the
  same way. `completed` is typed into the parent's prompt as a one-line notice.
- **Fallback to the user.** When the parent is gone, is not Claude, or hasn't
  taken the question within the stuck-agent threshold, the child turns amber
  ("Needs you · " and the question). A popover shows the whole question with a
  multi-line reply field (⌘↩ sends). It replaces the `NSAlert`.
- **Codex children** keep today's blocking `ask` (Codex reports no dialogs, so
  Nirux can't tell its prompt is free). Since 2026-11-19 a tell reaches them
  through Codex's own queue ([mission-tell.md](mission-tell.md)).
- `receive` keeps working for old skills but leaves the skill text.
- The Activity section, its store and its reply alert go. Native
  notifications, the Dock badge and ⌘J stay.

## The Lead

- **Opt-in per space:** "Start a Lead" in New Space… (off unless switched on)
  and Space Settings › Lead. A workspace pinned at the top of the sidebar, in
  the default anchor's main checkout, with Claude and the Board column (unless
  another workspace of the space shows the Board). One per space, never in
  General; it can't be moved, dragged, parked or sent to another space.
  ⌃⌘L (Space › Lead) focuses it, or starts it when the space has none: ⌘0
  stays the editor's font-size reset. Turning it off, or closing its
  workspace, closes it (asking first while Claude runs); the tasks it started
  then ask the user, as for any parent gone, and a new Lead doesn't take them
  over. Deleting its space makes it a plain workspace in General (its running
  shells keep `NIRUX_LEAD=1` until they restart).
- **Its role** reaches its Claude through the Nirux MCP server's instructions:
  its shells carry `NIRUX_LEAD=1` (blank in every other shell). It starts
  tasks only with its tools, reads `list_tasks` before starting one, and
  ends its turn after starting or telling tasks: Nirux types their messages
  into its prompt only while it is idle.
  Its folder is fixed when it starts: Space Settings › Lead says when it is
  none of the space's repositories any more, and turning it off and on moves
  it.
- **Tools** (Nirux MCP server, given to the Lead's Claude only), limited to its
  space and its anchors (shipped with S11b):
  - `start_task(description, repo?, template?)`: the ⌘N path (origin's base
    fetched, else as last fetched; the space's agent; a branch from the
    description's first line, `-2`… when it exists), reporting to the Lead as
    a Mission, in the Lead's space. `repo: "none"`, or any task in a space
    without a repository, starts in a folder of its own (see "Tasks without a
    repository"). It opens behind what the user is doing:
    no focus or space change. With "Starts tasks without asking" off (Space
    Settings › Lead, on by default; an unreadable defaults.json counts as
    off), it opens the New sheet filled in, titled "Proposed by the Lead",
    without taking the keyboard or Return; the task reports to the Lead if
    the user starts it. One sheet at a time: later proposals wait their turn.
  - `list_tasks()`: the space's tasks (title, branch, agent state, pull request
    and checks, the question waiting or the result) and repositories.
  - `tell(task, message)`, `reply(question, message | accept)`: Missions, 4,000
    characters at most (see mission-tell.md, "Longer messages"); `accept` sends
    the question's recommendation (docs/missions.md). A task is named
    by its branch, else its folder, else its title or folder's name (a
    workspace's branch is its focused terminal's, which another may share).
    Every Lead tool reads a
    name the same way (`spaceTask`): the first rank any task of the space
    answers decides; within it, the Lead's own task when only one of them
    answers, else the only task that does; several, and the tool refuses.
    `reply` reaches only the tasks the Lead started that are still in its
    space; a question typed into the Lead names it. `tell` reaches any task
    of the space but the Lead, sub-tasks and the user's tasks included: the
    Lead reviews and merges their pull requests, and a review relayed
    through a parent waits on that parent's turn. A task that reports to
    another agent, through a Mission still live (carried, its agent's
    column and its parent's terminal open), gets it as an instruction on
    that Mission sent by the Lead (`MissionEvent.leadSender`): typed as its
    parent's tell would be, it cancels a result still on its way to the
    parent and reopens the Mission; its held, given-up and unsent lines go to
    the Lead. Refused when it would reopen a finished sub-task whose task
    already runs its six, and when that agent isn't Claude Code. Any other
    task (one the user started, or whose Mission's agent or parent is gone)
    gets it through a one-way Mission (`Mission.oneWay`, one per Lead
    terminal and task agent, made at the first tell) to a Claude Code in
    front in one of its columns (not `claude -p`) or waiting to resume
    there. Both are typed under "[Nirux Mission] From the space's Lead
    (one-way: your questions and result still go to whoever started this
    task):", so a slash command doesn't run. A workspace that isn't a task
    (`isTask`), or that a link from outside Nirux opened, is refused. The
    answer says who gets the task's questions and result: the terminal its
    own Mission reports to while open, else the user. A one-way Mission never
    takes a question or a result (`MissionStore.process` refuses them), and
    counts nowhere as the Lead's: `list_tasks` still says "not yours", and
    `reply`, `ask_user`, `interrupt_task`, the CLI's `receive` and `tell`
    and the sidebar's question rows leave it out.
  - `ask_user(task, why)`: hands the question the task waits on to the user
    (amber row at once, the popover saying why). The answer is typed into the
    task, and a line into the Lead ("[Nirux Mission] The user answered …").
    The question is the task's own: the Lead asks its own in its conversation.
  - `queue_merge(prs, repo?)`: opens one repository's merge queue confirmation
    sheet with those pull requests, in that order (one queue per repository),
    once Board Settings allow it; only open pull requests, and never over a
    list the user is preparing. It never starts a queue.
  - `set_task_context(task, next_step?, blocker?)` (shipped with S13): a task's
    next step and blocker (View/Edit Context…), one line each, at most 200
    characters; an empty string clears one. Its role says when: after a
    task's question is answered, when it completes, when it notices a
    blocker. A field the user changed stays theirs (the tool says so) until
    they clear it; one they didn't touch stays the Lead's, even one it
    changed while the panel was open. A pull request seen merged clears what
    the Lead wrote (nothing tells it). Any task of the space, refused as
    `tell` refuses a workspace that isn't a task or that a link opened.
    `list_tasks` shows both for every task, and who wrote them.
  - `propose_rule(rule, evidence)`: a rule for the space brief, once the Lead
    sends tasks the same kind of finding a second time (see "Learned rules"
    below). Nothing reaches the brief without the user.
  - `close_task(task)`: closes any task of the space, the user's too, as
    Close Workspace does. When its pull request is merged, Clean Up
    Worktree…'s checks run and, all passed, its worktree and local branch go
    too (the call stands in for the alert's click); a task without a
    repository has its folder moved to the Trash (for this tool only: Close
    and Archive keep it). Otherwise they stay and the answer says why: not
    merged, uncommitted changes, another workspace open in it, or a reused
    base folder. After a branch switch, the exact worktree path for the
    starting branch recorded in this workspace’s Mission also qualifies.
    The merged PR and the local branch removed are the current branch’s. The task closes and
    its shells hang up first; git runs, or the folder goes to the Trash,
    once all their processes ended (10 s at most, else the folder stays and
    the answer names them). A folder task's folder holding a git repository
    with uncommitted changes or commits no remote has stays; the answer
    names where the Trash took the rest, which Put Back restores. Refused
    while the user has it on screen (Nirux active), and while its agent's own
    state holds something (`AgentStatusMachine.hold`, under a launcher too):
    a turn, a dialog, a question it ended on, any attention but a finished
    turn, a draft typed and not sent, a turn end still being read; also a
    question handed over, an agent paused since a relaunch last seen working
    or waiting, or one that can't be told idle (no hooks); while a program
    is in front of one of its terminals; with unsaved editor changes; for a sub-task whose
    parent's agent waits for it, a task with sub-tasks open, and a workspace
    that isn't a task (a main checkout). Closing the selected task selects
    the next without giving its terminal the keyboard. A folder task's
    folder stays when another workspace or task works in it, and is moved
    once its terminals are gone.
  - `move_task(task, position)`: moves a task among its siblings (the
    space's tasks, a task's sub-tasks, or the archived ones), 1 for the top,
    as dragging its row does: its sub-tasks follow, and the Lead stays first.
  - `rename_task(task, title)`: as Rename…, one line of 80 characters at
    most (a longer one is refused, not cut); agents' titles no longer replace
    it.
  - `set_task_parent(task, parent?)`: lists a task under another of the
    space, or at the top level without `parent`, within the sub-task rules
    (the parent a task, two levels, six sub-tasks, those on their way
    included). Archived sub-tasks count for nothing; an archived task stays
    put. Who it reports to doesn't change.
  - `interrupt_task(task)`: Esc into the turn of one of the Lead's tasks, in
    the column its Mission names (as `tell`), without closing anything.
    Claude Code gives the prompt box back a prompt it hasn't begun answering
    and the prompts queued meanwhile, and fires no Stop: so only once the
    main thread's turn called a tool and nothing was typed since its prompt,
    with no dialog waiting for a key, not while the user has the task on
    screen, and one Esc per turn (a second opens the rewind). The turn is
    over once its transcript shows "[Request interrupted by user" stamped
    after the Esc (watched 30 s; the Lead hears within 4), unless a newer
    prompt went in; the messages waiting for it go in then. The Esc counts
    as no draft, and the next `tell` goes in at once.
  - `read_task(task)`: the last message of the task's newest Claude Code
    conversation (the session history keeps its transcript, across
    relaunches), up to 6,000 characters, its start and end past that. Never
    an answer to an earlier prompt: a newest prompt without text since says
    so, with the prompt's first line and whether a turn runs; an end filled
    with tool output says so. The conversation before a `/clear` is read
    only while the newer holds nothing, labelled earlier. Lines that look
    like a secret are withheld.
  - `record_review(task, findings)` and `daily_pass()`: what the Lead's
    reviews found, by kind, and what happened in the space since its last
    daily pass, for its rules (see daily-pass.md).
- **The channel:** each call is a file in `<state dir>/lead/requests/`
  (LeadChannel), answered in `lead/responses/`. The Nirux that has the
  calling workspace claims it (a rename: another Nirux on the same state
  leaves it), checks the column belongs to its space's Lead, and acts. A call
  nobody claims within 15 s is taken back: nothing happens. A claimed one the
  app hasn't finished within its wait may still happen, and the Lead is told
  not to call again. Calls are answered off the server's read loop.
- **No tool merges or reaches another space.** Only `close_task` removes a
  worktree and a branch, once Clean Up Worktree…'s checks pass.
- **Sub-tasks under their task** (shipped with S11c for Mission children): a
  workspace keeps the task it is a sub-task of (`parentWorkspaceID`, saved
  with it) when it opens from ⌘N's "Sub-task of", or from the worktree skill
  run in that task, Missions on or off (the skill names its workspace and
  terminal: `parentWorkspace` and `parentAgent`). Only a task has sub-tasks: a
  workspace in a git worktree, not the main checkout (a worktree an agent
  opens from there is a task of its own) nor the Lead; whether it is one is
  read from its worktree's `.git` file when a menu opens or a workspace does,
  never on a sidebar refresh. Mission children saved before that get their
  Mission's parent at restore when it is a task (never a Lead's), decided once
  per workspace (`parentIsSettled`); a restore that can't tell yet (the
  Mission ledger unreadable, the parent's folder or repository not found, as
  on a volume not mounted yet) asks again the next time. Sub-tasks list right
  after their task, indented, in the sidebar, the rail and ⌘↑/↓ alike; they
  move among themselves and follow their parent when it moves, never dragged.
  Organize › Move Out of “<task>” lists one next to its task, after its other
  sub-tasks: under the task that one is listed under, else as a task of its
  own, for good. The row's title tooltip and VoiceOver say "Sub-task of
  “<task>”". The Lead's tasks stay the space's list under the Lead row (a
  deleted space's former Lead too). Reporting and nesting are apart: a
  sub-task that reports to the Lead still lists under its task. The Lead's
  `list_tasks` names a task's parent and who started it (the user, or another
  agent: a `nirux://` request from a Nirux terminal). A parent closed,
  archived or in another space lets its children go to the top level, where
  they were listed: the store keeps the sidebar's order. A row asking the user
  isn't indented, so its request is never cut. No folding; a grandchild has a
  child's indent.
- **State lives in Nirux** (board, Missions), not in the Lead's conversation: a
  `/clear` or a restart loses nothing.
- **Learned rules** (LearnedRules, RuleProposalStore): a review fixes one
  run; a rule in the brief reaches every run after it. When the Lead sends
  tasks the same kind of finding a second time, its role says to propose a
  rule with `propose_rule`: one or two lines (300 characters at most) that
  would have prevented it, and where the defect showed up (`#395, #417`).
  No model call: the Lead, which reads every review, judges "same kind".
  - **Refused:** a rule the brief says already (same words in any case,
    spacing or final punctuation; the Lead is told since when, and to tell
    the task that missed it), one already waiting, one the user added or
    dismissed in the last 90 days (in the Lead's words or the user's, even
    taken out of the brief since), a fourth one waiting, a rule holding
    `<!--` or `-->`. Its answer asks the Lead to say it in one line of its
    reply, so the user hears it where they talk to it.
  - **Shown:** "Rule proposed · Review" (or "2 rules proposed") on the Lead's
    row, grey: nothing waits on it, so no amber, notification, sound or
    focus. Review opens a sheet with the oldest one: the rule and where it was
    learned, both editable; the brief's size before and after ("Brief: 1,240
    → 1,330 of 16,000 characters", "long" past half, red past it); Add to
    Brief, Dismiss, Later (Esc). It says sessions already running keep the
    brief they started with.
  - **The user's own:** "Add a Rule to the Brief…" in any row's menu opens the
    same sheet, where it was learned filled with the row's pull request or
    branch, with the same size line and limit; Add writes it at once.
  - **Stored:** proposals in
    `<state dir>/projects/<space id>/rule-proposals.json` (0600; a decided
    one kept 90 days, the newest 100 at most; deleted with the space; one that
    can't be read just now is left alone). An added rule goes at the end of
    the brief's `## Rules learned` section (a closing `##` or a comment on its
    line allowed; a setext heading ends it too), made at the
    brief's end when missing (from the template when there is no brief), as
    `- <rule> (learned 2026-11-11, #395, #417)`: agents read the date and the
    source too. The write inserts that line and nothing else: every byte of
    the brief stays, its line breaks included. It re-reads the brief right
    before replacing it and starts over when it changed (Project Memory's
    write, which keeps a UTF-8 byte order mark too), so the user's edits made
    meanwhile stay. On the text it writes over, it looks for the rule first:
    when the brief says it already, nothing is written, and the Lead hears
    that instead. A place sessions
    wouldn't get (a code block, a comment; an unclosed `<!--` hides
    nothing from them) is refused, and so is a brief past 16,000 characters
    or 64,000 bytes of what sessions get, a brief file past 1 MB (sessions
    don't read it), a proposals file Nirux can't write (the decision would
    be lost), or Space Settings › Brief with unsaved edits (its Save would
    drop the rule). Space Memory lists the rule as an
    Always item, to edit or move to memory.
  - **The Lead hears it:** once the user adds or dismisses its rule, or finds
    the brief says it already, a line is typed into the space's Lead's
    prompt when it is idle ("[Nirux Mission] The user added your rule to the
    space brief as: “…”. Only sessions started from now on read it: tell
    running tasks yourself if they need it."), one per free prompt, oldest
    first, to the terminal that proposed it, else the one the Lead's Claude
    runs in. The decision waits in the proposals file until it is told
    (`leadToldAt`): a relaunch, or a Lead busy for hours or started again,
    doesn't lose it. It is recorded before it is typed: one Nirux can't
    record (a newer Nirux's file) is never typed, rather than at every turn
    end. A space without a Lead keeps its decisions until one starts.
  - **Pruning:** Nirux never removes a rule. Each says when it was learned;
    Space Settings › Brief shows the brief's size beside its buttons; the
    user deletes a rule there or moves it to memory in Space Memory.
- Mission handoffs and sidebar permission answers leave Experimental for
  Settings › Agents › Missions (shipped with S11a), on for a new install. A
  state file keeps the value it holds: both were opt-in, and turning Missions
  on would link every worktree an agent opens to it. A Lead and the tasks it
  starts use Missions whatever the setting (`Mission.reportsToLead`, and the
  Mission variables in their shells).

## Interface

Mockups were validated in the design session. What changes:

- **Sidebar:** a space picker at the top (name, task count, amber when an agent
  waits; ⌥⌘1…⌥⌘9, since ⌘1…⌘9 focus columns), the Lead row, then each task's title and time,
  its goal when supplied, and a step chip beside its status. The chip follows
  the Board (Plan, Code, Review, Checks, Ready, Merged) and carries the PR
  number. A question, blocker or error can wrap to four lines. A
  working Claude that may be going in
  circles says so in the same grey, in place of "Working" ("Stuck? · 3
  timeouts", "Stuck? · swift build failed 5×"): 3 commands past their
  time limit close together, or 5 failures in a row of one command, counted
  from its hooks over the turn. A command that only waits (a `sleep`, a poll
  loop, `gh pr checks`) counts as neither, nor does an exit 1 that answers
  (grep found nothing, a test is false). It never alerts or interrupts the
  agent; Settings › Agents turns it off. A blocker says
  "Blocked · …" in grey after needs you, broken (failed checks too), asking,
  working and "Paused · Resume", before a finished turn and the pull request;
  the selected row prints its next step below its columns. INACTIVE becomes an
  "Archived" row at the bottom, unfolding its list above it. The bottom dot switcher and Activity go. This
  replaces the three-line cards of the October visual system.
  Hovering a task row or its folded-rail icon opens the same preview beside the sidebar, with the full title, optional goal, status and next action. The preview keeps keyboard focus in the workspace. Its button opens the task, or its thread when a thread presenter is connected.
- **Title bar:** three buttons: New, Board, Search. Since replaced by the
  glass interface's command bar (step 3.1, [glass-interface.md](glass-interface.md)).
- **Popovers, not alerts,** for anything the user must read and answer.
- **⌘P in sections:** this space, actions, other spaces. One "New…" entry.
- **Menu bar:** Space, Agent and Help menus, so every command has a menu item
  and its shortcut. ⌃⌘B opens the Board.
- **Card menu:** state actions first (Review Branch, failed CI, Clean Up once
  merged), then an Organize submenu, then Rename, the context and Close.
- **Space Settings:** one window with tabs (General, Defaults, Safety, Lead,
  Brief, Memory, Board, Templates) instead of five separate panels; since the glass
  interface's 4.1, the space's panes of the one Settings window
  (docs/design/glass-interface.md). Shipped without
  Lead (S11): toolbar tabs like Nirux Settings, each change applied at once
  except the Brief and Templates editors and the Board form, which have
  Save. (S10a reduced the space menu to Space Settings… and Delete Space….) A repository's setup
  script is edited in a sheet from General. A space's default agent only
  preselects the agent of its tasks; a plain workspace stays a shell.
- **An empty space** shows its name, Add Repository… until it has a
  repository or folder, Start a Lead (shipped with S11a), and New… (Return,
  ⌘N). General shows only New…. The view stays while workspaces
  elsewhere close or move, and comes back at launch. Closing a space's last
  workspace still selects another space's.
- **Nirux's own skills update themselves** on launch, unless the user edited
  them.

## Plan

Each PR is reviewable on its own and follows the usual cycle (adversarial
review, `/code-review`, premortem, confirmation review, CI green, release
build). PRs merge one at a time. S1 is mostly labels: it lands first and the
others rebase on it.

| # | PR | Depends on | Wave |
| --- | --- | --- | --- |
| S1 | "Space" labels; General (rename "main", first in the picker) | none | 1 |
| S2 | Missions without waiting; Activity removed; reply popover | none | 1 |
| S3 | Nirux's skills update themselves | none | 1 |
| S4 | Anchors, routing, New Space… sheet, General as catch-all | none (rebases on S1) | 1 |
| S5 | ⌘P in sections | S1 | 2 |
| S6 | Space, Agent and Help menus; shorter card menu | S1 | 2 |
| S7 | One ⌘N | S3, S4 | 3 |
| S8 | Space Settings and per-space defaults | S4 | 3 |
| S9 | Empty space view | S4 | 3 |
| S10 | Clean sidebar, space picker, title bar | S1, S2 | 4 |
| S11 | The Lead | S2, S4, S7, S8 | 5 |
| S12 | Board with several repositories | S4 | 5 |
| S13 | The Lead keeps each task's next step and blocker | S11 | 6 |

Notes per PR:

- **S1.** Every visible "Project" becomes "Space" (menus, palette, panels,
  board header, README). The default space is renamed "General" only while its
  name is still "main". General sorts first.
- **S2.** See "Missions without waiting". Update the `nirux-worktree` skill and
  the README. Keep Codex children working.
- **S3.** Rewrite an installed Nirux skill (`metadata.author: nirux`) when the
  bundled text changed and the installed copy is the one Nirux wrote (keep its
  hash). A copy the user edited stays, and Getting Started keeps offering the
  update.
- **S4.** Model, identity, routing and General as above; New Space… sheet
  (name, color, repositories, default); "Add Repository…" in the space menu;
  the skill always sends its parent workspace. Moved-repository detection is
  out of scope.
- **S5.** Sections and scope; typing still finds workspaces in every space.
- **S6.** Items open today's panels until S8 lands.
- **S7.** See "One door: ⌘N". The palette keeps a single "New…", and so
  does the menu bar's Workspaces menu.
- **S8.** Defaults follow projects.md section 5 (precedence, literal env,
  reserved `NIRUX_*`, `0600`, setup script typed before the agent, only for
  workspaces the user started). Shipped; the defaults live in the space's
  own `defaults.json`, not in projects.json (see projects.md section 5).
- **S9.** Shipped. "Start a Lead" came with S11a.
- **S10.** Three PRs: the picker and the Archived row, then the two-line
  rows, then the title bar (New, Board, Search; Search opens ⌘P). The
  keep-awake cup and the plan usage limits stay, left of the buttons.
  Mission children grouped under their parent wait for S11.
- **S11.** See "The Lead". Three PRs: S11a the Lead's workspace, the New
  Space switch, the Lead tab, ⌃⌘L, Missions and sidebar answers on by
  default; S11b its MCP tools; S11c the ⌘N checkbox and Mission children
  under their parent in the sidebar.
- **S12.** `board.json` gets one config per anchor; the current single
  repository becomes the matching anchor's. Shipped: see
  [project-board.md](project-board.md), sections 2.2 and 5.1.
- **S13.** An MCP tool sets a task's next step and blocker; manual editing
  stays. Shipped: see the Lead's tools and the Interface section.

## Out of scope

Sandboxing agents to their space, a Lead across spaces, a light theme, moved
repository detection, and tasks spanning two repositories.
