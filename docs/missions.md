# Mission handoffs

When an agent starts a task for another agent in a new worktree, Nirux links the two with a Mission: the agent that started the task is the parent, the new agent the child. The child can ask its parent a question and report its result, and the parent can send it more work.

**Settings › Agents › Mission handoffs** turns Missions on or off for new terminals (on for a new install). A space's [Lead](spaces-and-tasks.md#the-lead) and the tasks it starts always have them, and so do the [sub-tasks](spaces-and-tasks.md#sub-tasks) a task's agent starts with its `start_task` tool.

## What you see

While a child is waiting for its parent's answer, its row reads `Asking <parent>` in grey. You don't have to do anything: Nirux types the question into the parent's prompt, and the answer into the child's.

The question comes to you instead when:

- the parent's workspace was closed;
- the parent's terminal doesn't run Claude Code;
- the parent's Claude Code hasn't taken a prompt since it started, as after Nirux relaunches and resumes it: until then it may show a startup or resume screen that Nirux can't see, so Nirux doesn't type into it. If you don't answer, Nirux types the question into it after its next turn, within an hour of the question;
- the parent's Claude Code restarted after it got the question;
- the parent read the question and ended its turn without answering;
- nobody answered within the time set by **Settings › Agents › Flag a dialog waiting after** (10 minutes by default; an hour when it is set to Never).

The row then turns amber and reads `Needs you ·` followed by the question, on up to four lines. The Dock icon counts it, and a notification goes out while Nirux is in the background. The question stays with you until someone answers it or Nirux types it into the parent's prompt.

Click the line, grey or amber, to read the whole question and answer it in a popover (`Cmd+Return` sends). Your answer reaches the child the way the parent's would.

## When Nirux types into a prompt

Nirux types a message only when the agent's `claude` is in front, its turn is over, no dialog is open and nothing has been typed at the prompt. The keys a dialog takes don't count: a question dialog's until it sends its answers, Esc or Ctrl-C; a permission or plan dialog's until Enter, a number, Esc or Ctrl-C answers it. Known limits: a number typed in an option's text after Tab (an amendment) reads as its answer, and so does an Esc that only leaves that text: what follows counts until the next prompt. Nor do the keys that only move the view or the cursor: Page Up and Down, Ctrl+Home and Ctrl+End, Home, and Left with a modifier (Left alone opens Claude Code's agents view from an empty prompt, so it still counts). Nor does Enter while a turn runs, when an empty prompt queues nothing; at an idle prompt it counts, since it may run text Nirux never saw. Otherwise the message waits for the end of that agent's next turn.

When a message has waited three minutes for an agent that isn't working, the agent's row says so and why, a Lead's too: `2 messages waiting since 22:21 · held by a draft until its next prompt`. Its tooltip says more, and a click shows the agent's column. Sending the agent a prompt usually lets them in. Nirux writes the reason to the system log, with what it read it from: within half a minute for keys at the prompt or a prompt that looks free, after three minutes for anything else (for a turn at work, only once no hook came for three minutes):

```
log show --predicate 'subsystem == "com.xikimay.nirux" AND category == "missions"'
```

## Limits

- A Mission ends only when the child reports that it is done, not when its turn stops.
- More work sent by the parent reaches only the `claude` that was running when it was sent, and only within an hour. A `claude` restarted since never gets it. An answer has no such limit and is typed whenever the child's prompt is free.
- The parent can send more work after the child reported its result, which makes the Mission active again.
- A Codex child can ask and report, but can't be sent work: Codex reports no dialogs, so Nirux can't know that its prompt is free. A Codex child waits for each answer in its terminal, and a Codex parent polls for its child's messages.
- A worktree opened without a Mission keeps the plain handover file. The child reads it and works alone.
- A sub-task an agent starts with the `nirux-worktree` skill gets a Mission only while Mission handoffs is on, even under a Lead's task. Otherwise it works alone. One started with `start_task` always has one.

## Commands

Agents run these, not you. The bundled `nirux-worktree` skill teaches them. A space's Lead, and a task's agent for the sub-tasks it started with `start_task`, answer with their `reply` tool instead.

| Who | Command | Effect |
| --- | --- | --- |
| Child | `"$NIRUX_CLI_PATH" --mission ask --message "..."` | Asks the parent. Nirux types the question into the parent's prompt as a `[Nirux Mission]` message |
| Parent | `--mission reply` (the question names the full command) | Answers the child |
| Child | `"$NIRUX_CLI_PATH" --mission completed --message "..."` | Reports the result. The parent gets a one-line notice, followed by the child's questions that never reached its prompt, if any |
| Parent | `"$NIRUX_CLI_PATH" --mission tell --branch <child-branch> --message "..."` | Sends the child more work. Nirux types the message and Enter into its prompt, so a slash command such as `/code-review` runs |
| Codex parent | `"$NIRUX_CLI_PATH" --mission receive` | Waits for the child's messages |
