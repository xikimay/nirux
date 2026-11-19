# Mission Tell

> **Design record:** shipped. `--mission tell` is in the app.\
> **Differs today:** the same guarded typing now carries questions and answers too, and a Claude Code child's `ask` returns at once. A Codex child gets tells through Codex's own queue (2026-11-19, below).\
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
  user. A Lead's tell to a task that doesn't report to it has a header line
  (spaces.md, "The Lead").
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
  child held when Nirux recorded it (`MissionEvent.childSessionID`, read
  from the agent the status refresh last saw in front): a restart resuming
  it, as Nirux's relaunch does, still gets it, once that `claude` took a
  prompt (a resumed one may show a dialog its hooks don't tell) or its
  session record says it sits idle at its prompt (`ClaudeSessionRecord`,
  2026-11-19); one that
  hasn't said yet which it holds keeps it waiting. One recorded with no
  conversation (an older build's, or before any was confirmed) counts as
  for the same. Until
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
  that branch from this terminal, a child that runs neither Claude Code nor
  Codex, or handoffs off; 2 usage; 1 state.
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
- **Codex children** (until 2026-11-19, see below). Codex reported no
  dialogs, so Nirux couldn't prove its prompt was free.
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
  background subagent at work doesn't stop it (the main prompt is free), and
  a wheel scroll's arrows aren't passed on meanwhile (inside the paste they
  would be its text).
  - It counts as typed only once its Enter went in: until then `tell`
    answers that Nirux is typing it, and the CLI keeps waiting.
  - None of it reached the terminal (its agent left first): it waits for the
    next free prompt, under the same rules.
  - Some of it did: never typed again, a copy would follow the fragment. A
    tell is given up (`expiredAt`), an answer or a question counts as typed.
    All of it in the prompt, unsent (someone typed, a dialog opened): the
    user gets a toast to press Enter there, and a task's sender a
    `[Nirux Mission]` line. Only its start (the agent stopped reading, or
    left): a toast to clear it, and the sender may send it again.
- Limits count characters, and scalars too: what Nirux types stops at
  `TypedPromptSanitizer.maxCharacters` scalars.
- A file the message points to was rejected: one in the task's worktree shows
  in git status and can get committed; one in Nirux's state folder sits
  outside the task's project, so Claude asks the user before reading it.

## Codex children (2026-11-19)

The user asked that any task's agent hear from its parent and the Lead.
Codex 0.167 has its own way in: `codex queue --thread <id> --message <text>`
stores the message with the thread, and Codex starts it as a prompt only
once that conversation is idle, not after an Esc. Probed live, nothing
reaches the terminal: an idle Codex started it at once, a draft stayed in its
composer untouched, a busy one finished its turn first. So Nirux types
nothing into Codex (`CodexQueue`, `queueForCodex`).

- **Which thread.** Codex's notify also reports threads it runs out of
  sight: one titles each new conversation, seen right after the first turn.
  `CodexSessionTracker` counts a thread as the column's once its first
  message is the prompt that `codex` was launched with (the notify carries a
  digest, never the text), or once `codex resume <id>` named it; no other
  thread replaces it then, which also keeps a relaunch from resuming the
  title's thread. The first proof stands: a fork (/side) begins with the
  same message. A `codex` launched without a prompt proves none, so a tell
  to it is refused. One that started another conversation with /new keeps
  getting messages on the first, and a relaunch resumes the first: the
  title's thread, which came up after every first turn, made following the
  last thread worse.
- **When.** Codex sends OSC 7501 like agy (`app=codex`): Nirux hands a message
  over only while the `codex` it was sent to (or one resuming its thread)
  last said `done` or `idle` (`codexQueueRefusal`). After an Esc Codex says
  `idle` too, and its queue starts nothing until another turn ends: the
  message waits there, and the notice below says so. Nirux doesn't hold it
  itself, since a resume replays turns as `working` then `idle` without an
  Esc. Codex would wait for an idle thread anyway; waiting here keeps the
  day's lifetime, the held notice and the give-up as they are for Claude
  Code. One message per Codex is handed at a time, so its queue
  keeps their order. Codex's status on its row still comes from its notify
  and its output.
- **Typed** once `codex queue` exits 0, run with what runs that `codex`
  (its binary, or npm's `node …/bin/codex`), so the same build takes it.
  The message goes as `--message=<text>`: one starting with "-" stays a
  value. If Codex then reports nothing for 20 s, the sender and the user
  hear that it hasn't started it, and not to send it again. A refusal (an
  older Codex, a thread it doesn't know) leaves it waiting; after three
  tries its row says Codex didn't take it. No answer within 30 s gives it up
  untold to Codex again, its sender told: Codex may hold it.
- It goes as text: a slash command doesn't run in Codex.
- A Codex child's `ask` still waits for its answer.
