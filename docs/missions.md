# Mission handoffs

When an agent hands a task to another agent in a new worktree, a Mission links the two: the child can ask its parent a question and report its result, and the parent can send more work.

**Settings › Agents › Mission handoffs** turns them on or off for new terminals (on for a new install). A space's [Lead](spaces-and-tasks.md#the-lead) and the tasks it starts always have them.

## How the agents talk

Nirux carries the messages by typing them into the agents' prompts.

| Who | Command | What happens |
| --- | --- | --- |
| Child | `"$NIRUX_CLI_PATH" --mission ask --message "..."` | Nirux types the question into the parent's prompt as a `[Nirux Mission]` message. The child ends its turn; the answer is typed into its prompt. |
| Parent | `--mission reply` (the question names the exact command) | Nirux types the answer into the child's prompt. |
| Child | `"$NIRUX_CLI_PATH" --mission completed --message "..."` | The parent gets a one-line notice. |
| Parent | `"$NIRUX_CLI_PATH" --mission tell --branch <child-branch> --message "..."` | Nirux types the message and Enter into the child's prompt, so a slash command such as `/code-review` runs. |

The bundled `nirux-worktree` skill teaches agents these commands; you don't type them.

Nirux types into a prompt only when it is safe: the agent's `claude` is in front, its turn is over, no dialog is open and nothing was typed at the prompt since its last one went in. Otherwise the message waits for that agent's next turn end.

A Mission ends only when the child reports `completed`. Nirux never infers it from a stopped turn. After that, `ask` and `completed` exit with status 4 so the child stops retrying.

## When the question comes to you

While the child waits, its row reads `Asking <parent>` in grey. The question comes to you instead when:

- the parent's workspace was closed;
- the parent's terminal doesn't run Claude Code;
- the parent read the question and ended its turn without answering;
- nobody answered within the stuck-agent threshold (Settings, 10 minutes by default).

The row then turns amber (`Needs you · a question`), the Dock badge counts it, and a notification goes out while Nirux is in the background.

Click the line, grey or amber, to read the whole question and answer it in a popover (`Cmd+Return` sends). Nirux types your answer into the child's prompt.

## Limits

- `tell` reaches only the `claude` that was running when the parent sent it, and only within an hour. A `claude` restarted since never gets it.
- `tell` works after the child completed, and makes the Mission active again.
- Codex children can `ask` and report `completed`, but can't be told: Codex reports no dialogs, so Nirux can't know its prompt is free. A Codex child's `ask` waits for the answer, at most 90 seconds at a time, then exits with status 3 and resumes the same question when run again.
- A Codex parent, which Nirux can't type into, waits for its child's events with `--mission receive`.
- A worktree opened without a Mission keeps the plain handover: the child reads the file and works alone.
