# Mission handoffs

When an agent starts a task for another agent in a new worktree, Nirux links the two with a Mission. The child agent can ask its parent a question and report its result, and the parent can send it more work.

**Settings › Agents › Mission handoffs** turns Missions on or off for new terminals (on for a new install). A space's [Lead](spaces-and-tasks.md#the-lead) and the tasks it starts always have them.

## What you see

While a child waits for its parent's answer, its row reads `Asking <parent>` in grey. You don't have to do anything: Nirux types the question into the parent's prompt, and the answer into the child's.

The question comes to you instead when:

- the parent's workspace was closed;
- the parent's terminal doesn't run Claude Code;
- the parent read the question and ended its turn without answering;
- nobody answered within the time set by **Settings › Agents › Flag a dialog waiting after** (10 minutes by default; an hour when it is set to Never).

The row then turns amber and reads `Needs you · a question`. The Dock icon counts it, and a notification goes out while Nirux is in the background.

Click the line, grey or amber, to read the whole question and answer it in a popover (`Cmd+Return` sends). Your answer reaches the child the way the parent's would.

## When Nirux types into a prompt

Nirux types a message only when the agent's `claude` is in front, its turn is over, no dialog is open and nothing has been typed at the prompt. Otherwise the message waits for the end of that agent's next turn.

A Mission ends only when the child reports that it is done. Nirux never infers that from a turn that stopped.

## Limits

- A message from the parent reaches only the `claude` that was running when it was sent, and only within an hour. A `claude` restarted since never gets it.
- The parent can send more work after the child reported its result, which makes the Mission active again.
- A Codex child can ask and report, but can't be sent work: Codex reports no dialogs, so Nirux can't know that its prompt is free. A Codex child waits for each answer in its terminal, and a Codex parent polls for its child's messages.
- A worktree opened without a Mission keeps the plain handover file. The child reads it and works alone.

## Commands

Agents run these, not you. The bundled `nirux-worktree` skill teaches them.

| Who | Command | Effect |
| --- | --- | --- |
| Child | `"$NIRUX_CLI_PATH" --mission ask --message "..."` | Asks the parent. Nirux types the question into the parent's prompt as a `[Nirux Mission]` message |
| Parent | `--mission reply` (the question names the full command) | Answers the child |
| Child | `"$NIRUX_CLI_PATH" --mission completed --message "..."` | Reports the result. The parent gets a one-line notice |
| Parent | `"$NIRUX_CLI_PATH" --mission tell --branch <child-branch> --message "..."` | Sends the child more work. Nirux types the message and Enter into its prompt, so a slash command such as `/code-review` runs |
| Codex parent | `"$NIRUX_CLI_PATH" --mission receive` | Waits for the child's messages |
