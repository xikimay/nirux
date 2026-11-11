# Agents

How Nirux knows what each agent is doing, how it tells you, and what it does after a restart.

## Supported agents

| Agent | Launched by Nirux | Status |
| --- | --- | --- |
| Claude Code | yes (`Cmd+N`, `Open Claude Code`) | exact, from hooks |
| Codex | yes (`Cmd+N`, `Open Codex`) | exact, from turn notifications |
| Gemini CLI, OpenCode | no, start them in a terminal | estimated from terminal output |

Settings › Agents sets the permission and sandbox mode Claude Code and Codex start with.

## Status hooks

Nirux installs hooks so that status comes from the agent, not from guessing at its output. At every launch, the installed app writes to two files:

- `~/.claude/settings.json` gains `hooks` entries that run `Nirux --hook claude` on session start, prompt submit, tool use, permission request, notification, stop and session end. Your own hooks are kept.
- `~/.codex/config.toml` gains a `notify` entry that runs `Nirux --hook codex` when a turn completes. If you already have a `notify`, Nirux leaves the file alone.

Both files are global, so every Claude Code and Codex session on the Mac runs these entries. They are guarded on `NIRUX_AGENT_UUID`, a variable only Nirux terminals set: anywhere else the command stops at a shell test and never launches Nirux. Symlinked config files are updated in place and the link is kept.

An agent started outside Nirux, or before the hooks were installed, falls back to output-activity detection.

To keep Nirux from writing the hooks, launch it with `NIRUX_SKIP_HOOK_INSTALL=1` in its environment. To remove them, quit Nirux and delete the entries that run `Nirux --hook` from the two files; a launch without that variable adds them back.

One event, `StopFailure` (a turn that ended on an API error), is added only when every `claude` a Nirux terminal could run is version 2.1.78 or later, because older versions of Claude Code ignore the whole settings file over an event name they don't know.

## What you see

On the column, light at its edge:

- green and breathing while the agent works;
- amber and pulsing while it waits for you;
- red when it broke;
- one sweep when Claude Code or Codex reports the end of its turn.

When an agent that waits or broke is out of view (a column scrolled away, another workspace), the window's edge on that side lights up and a pill names the agent for a few seconds. Click the pill to go there.

With **Settings › General › Animate the interface** off, or macOS's Reduce motion on, the same colors show without moving.

Outside the window, Nirux sends a macOS notification (a click focuses the right workspace and column) and shows the number of waiting workspaces on its Dock icon.

## Agents that wait or break

- **A long wait.** A permission or a question left open past a threshold (Settings, 10 minutes by default) keeps its row amber, shows `waiting 2h05m` on its column and notifies once.
- **An API error.** A Claude turn that ended on an API error shows `API error`. For transient errors (overloaded, server error) a **Resume** button types `continue`, only on your click and once Claude is back at an empty prompt.
- **An exit mid-turn.** A `claude` that died during a turn gets an overlay that resumes its conversation in the same permission mode.

`Cmd+J` walks through all of these, longest wait first.

## After a restart

Nirux saves each agent column's session: the launch mode and the verified Claude session or Codex thread ID. After a restart, each column resumes its own conversation by exact ID (`claude --resume <id>`, `codex resume <id>`) in the folder it ran in. A Claude session that was never prompted restarts fresh. When the ID is missing or ambiguous, the agent's own resume picker opens instead of a guess.

Agents resume on demand. A restored column reads `Not resumed yet`, with the session's title and its last status, and its row reads `Paused · Resume`. The agent starts once the column has stayed a moment in the workspace on screen, or when you click **Resume**. `Resume All Agents` (command palette, Agent menu) starts every one left. **Settings › General › Resume agents on launch › All at once** starts them all at launch instead.

Plain terminals start as usual.

## Keep the Mac awake

While at least one agent works, Nirux holds a macOS power assertion, `Nirux: agents working`, that prevents idle sleep, and shows a cup in the title bar. Hover the cup for the number of working agents.

- An agent that waits for you doesn't count, nor does one that has printed nothing and sent no hook event for 10 minutes.
- Nirux lets go a minute after the last agent stops, and at once when you turn the setting off or quit.
- Only idle sleep is prevented. The display still turns off on its schedule, and closing a MacBook's lid still puts it to sleep, except in clamshell mode.

The setting is **Settings › General › Keep Mac awake while agents work**, on by default. `pmset -g assertions | grep Nirux` shows whether the assertion is held.

## Claude context usage

The title bar of a column running Claude Code shows how full the session's context window is: `ctx 62%`, orange from 80%. Hover it for the exact count, the model and the session's token totals. There is no cost estimate.

- Nirux reads the session's transcript, read-only, and keeps token counts and the model ID, never message content.
- Claude Code uses a 200k or a 1M window, and the transcript doesn't say which. Until a response passes 200k tokens, the label shows the count instead (`ctx 124k`).
- Right after a compaction it shows `ctx —` until the next response.
- Subagents are not included. Codex columns show nothing.

## Claude plan usage limits

Off by default. With **Settings › Agents › Claude Code › Show plan usage limits in the title bar** on, the window's title bar shows how much of a Pro or Max plan's 5-hour window and weekly limit is used, as `5h 42% · 7d 18%`, orange from 80% of either. Hover it for the reset times.

Claude Code gives these numbers to one place only: the JSON its status line command receives (Claude Code 2.1.80 or later). So turning the option on makes Nirux Claude Code's status line: `~/.claude/settings.json` gains a `statusLine` that runs `Nirux --hook claude --statusline`, guarded like the hooks. What follows from that:

- The status line stays blank, but Claude Code hides its `? for shortcuts` hint whenever a status line is set, in every session.
- A status line of your own is left as it is, and the limits don't show. Settings says so.
- The numbers are those the latest response of a Claude session in Nirux saw. Usage elsewhere shows up with the next response here.
- Nirux calls no claude.ai endpoint.

Turning the option off removes the entry and forgets the numbers. Turn it off before removing Nirux, or delete the `statusLine` entry afterwards.
