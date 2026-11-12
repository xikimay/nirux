# Agent status

Nirux shows what each agent is doing, tells you when one needs you, and brings agents back after a restart.

## Supported agents

| Agent | Started by Nirux | Status |
| --- | --- | --- |
| Claude Code | yes (`Cmd+N`, `Open Claude Code`) | exact, from hooks |
| Codex | yes (`Cmd+N`, `Open Codex`) | the end of a turn is exact; "working" is estimated from terminal output |
| Gemini CLI, OpenCode | no, start them in a terminal | estimated from terminal output |

Settings › Agents sets the permission and sandbox mode Claude Code and Codex start with.

## Status hooks

Claude Code can run a command when a turn (one prompt and the work that follows) starts, stops or asks for permission, and Codex when a turn completes. Nirux adds itself as one such command. At every launch, the installed app writes to two files:

- `~/.claude/settings.json` gains `hooks` entries that run `Nirux --hook claude` on session start, prompt submit, tool use, permission request, notification, subagent stop, stop and session end. Your own hooks are kept.
- `~/.codex/config.toml` gains a `notify` entry that runs `Nirux --hook codex` when a turn completes. If you already have a `notify`, Nirux leaves the file alone.

Both files are global, so every Claude Code and Codex session on the Mac runs these entries. Each entry first tests `NIRUX_AGENT_UUID`, a variable only Nirux terminals set, and does nothing anywhere else. Symlinked config files are updated in place and the link is kept.

A Claude Code session started before the hooks were installed gets estimated status until it restarts.

To keep Nirux from writing the hooks, launch it with `NIRUX_SKIP_HOOK_INSTALL=1` in its environment. To remove them, quit Nirux, then delete the hook entries that contain `--hook claude` from the first file and the `notify` line that contains `--hook codex` from the second. A launch without that variable adds them back.

## What you see

Each agent's column carries a light at its edge:

- green and breathing while the agent is working;
- amber and pulsing while it is waiting for you;
- red when it stopped on an error;
- one sweep when Claude Code or Codex reports the end of its turn.

When an agent that is waiting or stopped on an error is out of view (a column scrolled away, another workspace), the window's edge on that side lights up and a small label names the agent for a few seconds. Click the label to go there.

With **Settings › General › Animate the interface** off, or macOS's Reduce motion on, the same colors show without moving.

While Nirux is in the background, it also sends a macOS notification (a click focuses the right workspace and column) and shows on its Dock icon how many workspaces need attention.

## Agents that wait or stop

`Cmd+J` goes through all of these, longest wait first.

- **A question at the end of a turn.** When a Claude Code turn ends on a question, its row stays amber and shows the question whole, under the choices the message lists right next to it, with **Reply…**, and **Yes** and **No** when either answers it. Clicking the row or reading the question in its column takes nothing away: it stays until you answer (on the row, in the notification or in the terminal) or the agent moves on. **Dismiss**, on the row and as **Dismiss Question** in its menu, takes it off the row without answering.
- **A long wait.** A Claude Code permission or question left open longer than **Settings › Agents › Flag a dialog waiting after** (10 minutes by default) keeps its row amber and notifies once. On the row of the workspace on screen, `waiting 2h05m` shows next to its column.
- **An API error.** After a Claude Code turn that ended on an API error, the row reads `Stopped on an API error`. For transient errors (overloaded, server error) a **Resume** button types `continue`, only on your click and once Claude Code is back at an empty prompt. Nirux learns of these errors only when it can read the version of every `claude` a Nirux terminal could run, and each is 2.1.78 or later.
- **An exit mid-turn.** A `claude` that died during a turn gets an overlay that resumes its conversation in the same permission mode.

## After a restart

Nirux saves each agent column's session: the launch mode and the Claude Code session ID or Codex thread ID. After a restart, each column resumes its own conversation by that ID (`claude --resume <id>`, `codex resume <id>`) in the folder it ran in. A Claude Code session that was never prompted restarts fresh. When the ID is missing or ambiguous, the agent's own resume picker opens.

Agents resume on demand, so that moving through workspaces doesn't start them all. A restored column reads `Not resumed yet — click or focus to resume`, with the session's title and its last status, and its row reads `Paused · Resume`. The agent starts once the column has stayed a moment in the workspace on screen, or when you click **Resume**. `Resume All Agents` (command palette, Agent menu) starts every one left. To start them all at launch instead, choose **All at once** for **Settings › General › Resume agents on launch**.

Plain terminals start as usual.

## Keep the Mac awake

While an agent is working or a merge queue is running, Nirux prevents idle sleep and shows a cup in the title bar. Hover the cup for what keeps the Mac awake.

- An agent that is waiting for you doesn't count, nor does one that has printed nothing and sent no hook event for 10 minutes.
- Nirux lets the Mac sleep again a minute after the last agent stops, and at once when you turn the setting off or quit.
- Only idle sleep is prevented. The display still turns off on its schedule, and closing a MacBook's lid still puts it to sleep, except in clamshell mode.

The setting is **Settings › General › Keep Mac awake while agents work or a merge queue runs**, on by default. `pmset -g assertions | grep Nirux` shows whether Nirux is holding the Mac awake.

## Claude Code context usage

The title bar of a column running Claude Code shows how full the session's context window is, as `ctx 62%`, orange from 80%. Hover it for the exact count, the model and the session's token totals. There is no cost estimate.

- Nirux reads the session's transcript without changing it, and keeps token counts and the model ID, never message content.
- Claude Code uses a 200k or a 1M window, and the transcript doesn't say which. Until a response passes 200k tokens, the label shows the count instead (`ctx 124k`). It always shows the count for `claude-sonnet-4-6` and for model IDs that don't start with `claude-`.
- Right after a compaction it shows `ctx —` until the next response.
- Subagents are not included. Codex columns show nothing.

## Claude plan usage limits

This indicator is off by default. With **Settings › Agents › Claude Code › Show plan usage limits in the title bar** on, the window's title bar shows how much of a Pro or Max plan's 5-hour window and weekly limit is used, as `5h 42% · 7d 18%`, orange from 80% of either. Hover it for the reset times.

Claude Code gives these numbers to one place only, the command set as its status line (Claude Code 2.1.80 or later). Turning the option on therefore makes Nirux that command: `~/.claude/settings.json` gains a `statusLine` entry that runs `Nirux --hook claude --statusline`, guarded like the hooks. With the option on:

- The status line stays blank, but Claude Code hides its `? for shortcuts` hint whenever a status line is set, in every session.
- A status line of your own is left as it is, and the limits don't show. Settings says so.
- The numbers are those the latest response of a Claude Code session in Nirux saw. Usage elsewhere shows up with the next response here.
- Nirux calls no claude.ai endpoint.

Turning the option off removes the entry and forgets the numbers. Turn it off before removing Nirux, or delete the `statusLine` entry afterwards.
