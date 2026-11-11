# Nirux

Nirux is a macOS app that runs several terminal coding agents side by side, each task in its own workspace and git worktree.

It runs [Claude Code](https://github.com/anthropics/claude-code) and [Codex](https://github.com/openai/codex) in real terminals and shows which one needs you. Nirux is alpha software: it changes often and updates itself from nightly builds.

## What you can do

- Keep each task in its own workspace: terminal, browser and editor columns side by side.
- See which agents are working, which wait for you and which stopped on an error.
- Start a task with `Cmd+N`: Nirux creates the worktree and launches the agent in it.
- Follow each pull request from the sidebar: checks, failures that look flaky, merges.
- Read a whole branch on one page before you review it.
- Quit and come back: layouts, tabs and each agent's conversation are restored.

## Install

Nirux needs macOS 14 or later.

1. Download `Nirux.app.zip` from the [nightly release](https://github.com/xikimay/nirux/releases/tag/nightly).
2. Unzip it and move `Nirux.app` to `/Applications`.

Builds are signed and notarized, and they install their own updates (**Nirux › Install Updates Automatically** turns that off). Nirux opens your workspaces only from `/Applications`, or from `~/Applications` when `/Applications` holds no Nirux: a copy started anywhere else says why and quits.

To launch agents, Nirux needs `claude` or `codex` installed. Pull request and CI status need the GitHub CLI, `gh`, installed with Homebrew and signed in.

## Quick start

1. Open Nirux. **Getting Started**, in the sidebar, checks that an agent is installed and offers to install the agent skills.
2. Choose **Space › New Space…**, name the space and add your repository.
3. Press `Cmd+N`, describe a task and press Return. Nirux fetches the base branch, creates a worktree on a new branch and starts the agent there with your description.

A row turns amber when its agent needs you; `Cmd+J` goes to the one that has waited longest. `Cmd+P` opens the command palette, which also switches workspaces.

## Agent status hooks

Nirux reads each agent's status from the agent itself, not from its output. At every launch it adds hooks to `~/.claude/settings.json` and a `notify` command to `~/.codex/config.toml`. Both files are global, but the entries do nothing outside a Nirux terminal. Your own hooks are kept, and a `notify` you already set is left alone. [Agents](docs/agents.md#status-hooks) lists what is written and how to remove it.

## Documentation

The [documentation index](docs/README.md) lists every page. The guides most people need:

- [Getting started](docs/getting-started.md): workspaces, columns, spaces and the first launch
- [Spaces and tasks](docs/spaces-and-tasks.md): repositories, `Cmd+N`, worktrees and their cleanup
- [Agents](docs/agents.md): status, notifications, resuming, usage indicators
- [Pull requests](docs/pull-requests.md): checks, CI failures, review badges, Branch Review
- [Keyboard shortcuts](docs/keyboard-shortcuts.md)

Design records, the decisions behind each feature, are listed [in the same index](docs/README.md#design-records).

## Build from source

With Swift 6.2 or later:

```bash
swift build
NIRUX_STATE_DIR=/tmp/nirux-dev swift run Nirux
```

A build that isn't the installed app refuses to open your real workspaces: `NIRUX_STATE_DIR` gives it a state of its own. [Development](docs/development.md) covers tests, app bundles and releases.

## License

[MIT](LICENSE)
