# Mission Tell

Status: design validated on 2026-10-03, implemented.

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
  several. Same 500-character limit as the other commands.
- **Delivery is guarded typing, not a hook.** Nirux types the text and Enter
  into the child's prompt, like the Resume button and Telegram, only when
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
- **An hour at most.** A message not typed within an hour is dropped: nobody
  may want it any more. A `claude` started after the message (restarted, or
  restored after Nirux relaunched) never gets it.
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
  write the queue can forge one. It shows in Activity as `told: ...`, read,
  like a reply.
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
