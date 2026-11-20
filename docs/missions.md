# Mission handoffs

When an agent starts a task for another agent in a new worktree, Nirux links the two with a Mission: the agent that started the task is the parent, the new agent the child. The child can ask its parent a question and report its result, and the parent can send it more work.

**Settings › Agents › Mission handoffs** turns Missions on or off for new terminals (on for a new install). A space's [Lead](spaces-and-tasks.md#the-lead) and the tasks it starts always have them, and so do the [sub-tasks](spaces-and-tasks.md#sub-tasks) a task's agent starts with its `start_task` tool.

## What you see

While a child is waiting for its parent's answer, its row reads `Asking <parent>` in grey. You don't have to do anything: Nirux types the question into the parent's prompt, and the answer into the child's.

The question comes to you instead when:

- the parent's workspace was closed;
- the parent's terminal doesn't run Claude Code;
- the parent's Claude Code hasn't taken a prompt since it started, as after Nirux relaunches and resumes it, and doesn't say it sits at its prompt (see below): until then it may show a startup or resume screen that Nirux can't see, so Nirux doesn't type into it. If you don't answer, Nirux types the question into it once it says so, or after its next turn, within an hour of the question;
- the parent's Claude Code restarted after it got the question;
- the parent read the question and ended its turn without answering;
- nobody answered within the time set by **Settings › Agents › Flag a dialog waiting after** (10 minutes by default; an hour when it is set to Never).

The row then turns amber and reads `Needs you ·` followed by the question, on up to four lines. The Dock icon counts it, and a notification goes out while Nirux is in the background. The question stays with you until someone answers it or Nirux types it into the parent's prompt.

Click the line, grey or amber, to read the whole question and answer it in a popover (`Cmd+Return` sends). Your answer reaches the child the way the parent's would.

A question can tell its parent what blocks the child, and what it recommends:

- **decision**: a choice the task leaves open. The child recommends the answer it would pick.
- **access**: something only a person can give, such as a login, a secret or a permission. The child says exactly what it needs and where.
- **spec-mismatch**: the task contradicts the code or itself. The child recommends a way out.

The parent reads both under the question and can send the recommendation as its answer in one step. An access question has none to accept: the parent hands it to you, unless it can say what to do instead.

## When Nirux types into a prompt

Nirux types a message only when the agent's `claude` is in front, its turn is over, no dialog is open and nothing has been typed at the prompt. The keys a dialog takes don't count: a question dialog's until it sends its answers, Esc or Ctrl-C; a permission or plan dialog's until Enter, a number, Esc or Ctrl-C answers it. Known limits: a number typed in an option's text after Tab (an amendment) reads as its answer, and so does an Esc that only leaves that text: what follows counts until the next prompt. Nor do the keys that only move the view or the cursor: Page Up and Down, Ctrl+Home and Ctrl+End, Home, and Left with a modifier (Left alone opens Claude Code's agents view from an empty prompt, so it still counts). Nor does Enter while a turn runs, when an empty prompt queues nothing; at an idle prompt it counts, since it may run text Nirux never saw. Otherwise the message waits for the end of that agent's next turn.

A `claude` that hasn't taken a prompt since it started, as after Nirux relaunches and resumes it, may show screens no hook reports: an offer to resume from a summary, a quota warning, a newer model. Nirux types into it only once Claude Code's own session record (`sessions/<pid>.json` in `~/.claude`, or in `CLAUDE_CONFIG_DIR`) has said for 3 seconds that it sits idle at its prompt with nothing waiting, its hooks report, and no key reached its terminal since the terminal started: a Claude Code you start by hand, or one you answered a screen of, waits for its first prompt, or for Type it now on its row (below). Without that record (another Claude Code version), the message waits for its first prompt too, and the system log says the record is missing. Before Enter after a long message, Nirux reads the record again, and leaves the message in the prompt if it still shows a screen of its own two seconds later.

Nirux types nothing into Codex. A message for a Codex child goes into Codex's own queue (`codex queue`, Codex 0.167 or later), and Codex starts it as a prompt of that conversation, as text: a slash command doesn't run there. Codex leaves a draft in its prompt as it is. Nirux hands the message over once that `codex` says its turn is over, and only to the conversation that `codex` started with the prompt Nirux launched it with, or resumed. After an Esc, Codex itself starts it only once another turn has ended. A `tell` to a `codex` you started without a prompt is refused, and one you moved to another conversation with `/new` keeps getting messages on the first. If Codex hasn't started the message 20 seconds later, the sender hears so, and you do too.

Nirux types a message into an Antigravity child's prompt once that `agy` says its turn is done, and no key has reached its terminal since that turn began: a key typed while it works stays in its prompt. Its dialogs (a command to approve, a question, its folder's trust) hold the message. An `agy` that hasn't ended a turn since it started, as after Nirux relaunches and resumes it, waits for its first one.

When a message has waited three minutes for an agent that isn't working, the agent's row says so and why, a Lead's too: `2 messages waiting since 22:21 · held by a draft until its next prompt`. Its tooltip says more, and a click shows the agent's column. Sending the agent a prompt usually lets them in. When a Claude Code that hasn't taken a prompt since it started holds them, and would take one on your word, a **Type it now** button shows under the line. Click the line to see its terminal; once it shows its prompt, empty, the button types one of them, and the rest follow that turn. From another workspace, the first click shows that terminal. There is no button while Claude Code's session record says a screen of its own is up, after keys that may have left text in its prompt (an Enter after them may only have taken a completion), or once Nirux typed into it before its first prompt. Nirux writes the reason to the system log, with what it read it from: within half a minute for keys at the prompt or a prompt that looks free, after three minutes for anything else (for a turn at work, only once no hook came for three minutes):

```
log show --predicate 'subsystem == "com.xikimay.nirux" AND category == "missions"'
```

## Limits

- A Mission ends only when the child reports that it is done, not when its turn stops.
- More work sent by the parent waits for the child's next free prompt, a day at most, and reaches the `claude` that was running when it was sent, or one that resumed that conversation since (after Nirux relaunches, say) once it took a prompt or says it sits at its prompt. If it isn't typed within an hour, the parent hears what holds it; if Nirux gives it up (a day passed, the task closed, or its `claude` restarted on another conversation), the parent hears that too. An answer has no limit and is typed whenever the child's prompt is free.
- The parent can send more work after the child reported its result, which makes the Mission active again.
- A Codex or Antigravity child waits for each answer in its terminal, and a Codex or Antigravity parent polls for its child's messages: Nirux types questions and results only into Claude Code.
- A worktree opened without a Mission keeps the plain handover file. The child reads it and works alone.
- A sub-task an agent starts with the `nirux-worktree` skill gets a Mission only while Mission handoffs is on, even under a Lead's task. Otherwise it works alone. One started with `start_task` always has one.

## Commands

Agents run these, not you. The bundled `nirux-worktree` skill teaches them. A space's Lead, and a task's agent for the sub-tasks it started with `start_task`, answer with their `reply` tool instead.

| Who | Command | Effect |
| --- | --- | --- |
| Child | `"$NIRUX_CLI_PATH" --mission ask --kind "<kind>" --message "..." --recommend "..."` | Asks the parent. Nirux types the question into the parent's prompt as a `[Nirux Mission]` message, with a line for its kind and recommendation. Both are optional |
| Parent | `--mission reply` (the question names the full command) | Answers the child; `--accept` in place of `--message` sends its recommendation |
| Child | `"$NIRUX_CLI_PATH" --mission completed --message "..."` | Reports the result. The parent gets a one-line notice, followed by the child's questions that never reached its prompt, if any |
| Parent | `"$NIRUX_CLI_PATH" --mission tell --branch <child-branch> --message "..."` | Sends the child more work. Nirux types the message and Enter into its prompt, so a slash command such as `/code-review` runs. A Codex child gets it through its own queue |
| Codex parent | `"$NIRUX_CLI_PATH" --mission receive` | Waits for the child's messages |
