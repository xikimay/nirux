# Mission Tell

> **Design record:** shipped. `--mission tell` is in the app.\
> **Differs today:** the same guarded typing now carries questions and answers too, and a Claude Code child's `ask` returns at once.\
> **User guide:** [Mission handoffs](../missions.md).

Status: design validated on 2026-10-03, implemented. Since 2026-11-08 the
same guarded typing also carries a child's questions and completion to the
parent and the answers back to a Claude Code child, and the Activity feed is
gone (see "Missions without waiting" in [spaces.md](spaces.md)).

Missions only went child → parent (`ask`, `completed`). When the parent agent
had something for a child (a follow-up, review output, "run /code-review then
/premortem"), the user copy-pasted it into the child's terminal by hand. On
2026-10-02 this showed up as "dans la session de la PR 6, run: /code-review
/premortem ...", "quel output de la review que je t'avais donné pour PR 2", and
"est-ce qu'on a run /code-review dans sa session ?".

`--mission tell` lets the parent agent send a message that Nirux types into the
child's prompt.

## Decided

- **One new command, parent side:**
  `"$NIRUX_CLI_PATH" --mission tell --branch <child-branch> --message "<text>"`.
  The branch names the child among this parent's Missions (the parent knows
  branches, not Mission IDs); the newest Mission wins when a branch had
  several. Same 500-character limit as the other commands (4,000 since
  2026-11-17, see below).
- **Delivery is guarded typing, not a hook.** Nirux types the text and Enter
  into the child's prompt, like the Resume button, only when
  `AgentStatusMachine.isPromptFree` holds: the column's interactive `claude`
  is in front, it was already running when the parent sent the message, it
  took a prompt since it started (Claude Code shows some dialogs before any
  hook could list them), its turn is over, no dialog is listed, and nothing
  was typed since its last prompt went in. Otherwise the message waits in the
  ledger, and Nirux tries again when a turn ends (Stop or StopFailure). Nirux
  records the message as typed before typing it, so a failed save never types
  it twice. Typing, unlike a Stop hook's `block` reason, also works for slash
  commands and for a child that is already idle (a Stop hook never fires
  again on an idle session).
- **Raw text.** No prefix, so `/code-review` stays a slash command. The child
  can't tell the parent from the user, which is fine: the parent acts for the
  user.
- **Typing reopens a completed Mission.** Most follow-ups come after
  `completed`, so once the message is typed the Mission is `active` again and
  the child can `ask` and `completed` again. A message still waiting doesn't
  reopen anything.
- **A day at most, its sender told.** A message waits for the child's next
  free prompt, however long its turn runs, up to a day
  (`MissionEvent.typableUntil`). An hour after it was sent, still untyped, its
  sender gets one `[Nirux Mission]` line saying what holds it
  (`heldNoticeAt`). Nirux gives it up, telling the sender (`expiredAt`), once
  its day ran out, its task closed, or a `claude` started after the message
  confirmed another conversation. The message is for the conversation its
  child held when Nirux recorded it (`MissionEvent.childSessionID`): a
  restart resuming it, as Nirux's relaunch does, still gets it, once that
  `claude` took a prompt (a resumed one may show a dialog its hooks don't
  tell); one that hasn't said yet which it holds keeps it waiting. Until
  2026-11-17 an untyped message was dropped silently after an hour: a review
  the Lead sent at the start of a task's 75-minute turn was lost that way.
  The missions log now records a turn at work holding a message too, once per
  message, after `missionMessageStallAge`.
- **`/clear` counts as a prompt.** It fires SessionStart (`source: clear`),
  not UserPromptSubmit; without this, a `tell` of `/clear` would block every
  later one. Other built-in commands (`/model`) fire neither: the next `tell`
  then waits for a prompt from someone else.
- **`tell` waits like `ask`:** up to 90 s for Nirux to type the message. 0
  typed; 3 not typed yet, and the same command again resumes the wait instead
  of queuing the text twice (like `ask`, its ID is derived from the text; a
  message typed less than 60 s ago counts as that same one); 4 no Mission on
  that branch from this terminal, a Codex child, or handoffs off; 2 usage; 1
  state.
- **Ledger:** a new event kind `instruction` (parent → child), with
  `childConsumedAt` set once typed. Nirux routes only events that carry the
  recorded parent identity; as for `reply`, any process of the user that can
  write the queue can forge one.
- **Docs:** the README and the `nirux-worktree` skill describe `tell`.

## Not in this version

- **`--mission status`.** Live agent state lives in the app's memory, not in
  the ledger, so the CLI would need a new state file. A `tell` that ends with
  "then report with `completed`" answers "did it run /code-review?" through the
  existing inbox.
- **Codex children.** Codex reports no dialogs, so Nirux can't prove its
  prompt is free.
- **Messages over 500 characters.** Long review output goes in a file; the
  `tell` gives its path.

## Longer messages (2026-11-17)

The Lead hit the limit daily and wrote scratchpad files for it. Why 500: the
CLI's `--message` limit, shared by every command. The real constraint was
the typing: one `write` on the main thread, while the terminal's input queue
holds about a kilobyte and empties only as the agent reads (see Branch
Review's send).

- `tell` and `reply` (the Lead's and a task's tools, the CLI, the user's
  answer popover) hold 4,000 characters; questions and results stay at 500
  (folded onto one line, repeated by `list_tasks`).
- A message past `PtySession.inputQueueBytes` with its Enter is typed with
  `pasteInBackground` (off the main thread, as the agent reads it, 30 s at
  most), Enter once it is all in, still all the prompt holds: no key since,
  no dialog keys would answer, the same agent in front, its task open. A
  background subagent at work doesn't stop it (the main prompt is free).
  - Its agent left, or its task closed, before it was all in: it is marked
    untyped again and waits for the next free prompt, under the same rules.
  - All of it in the prompt, unsent (someone typed, a dialog opened): the
    user gets a toast to press Enter there, and a task's sender a
    `[Nirux Mission]` line; sending it again would only add a copy after
    the draft.
  - Cut off (the agent stopped reading for 30 s): only its start is in the
    prompt; the user gets a toast to clear it, and a task's sender a line to
    send it again.
  - A message whose typing had reopened a completed Mission completes it
    again when it is marked untyped.
- Limits count characters, and scalars too: what Nirux types stops at
  `TypedPromptSanitizer.maxCharacters` scalars.
- A file the message points to was rejected: one in the task's worktree shows
  in git status and can get committed; one in Nirux's state folder sits
  outside the task's project, so Claude asks the user before reading it.
