# Getting started

From a fresh install to a first task. To install Nirux, see the [README](../README.md#install).

## Three words

- A **workspace** is one task: a folder, a title and a row of columns. Workspaces are listed in the sidebar.
- A **column** is a terminal, a browser page or an editor. Columns sit side by side.
- A **space** groups the workspaces of one product or client and knows which repositories its work lives in. The sidebar shows one space at a time. Every install starts with one space, **General**, which has no repository.

## First launch

Nirux opens with a **Getting Started** list in the sidebar, below the workspaces. It never blocks the app. It shows:

- whether `claude` or `codex` is installed where a Nirux terminal finds it, with install commands to copy if not;
- whether the [agent skills](url-scheme.md#agent-skills) are installed and match this version, with an **Install** or **Update** button;
- whether the [status hooks](agents.md#status-hooks) are in place;
- the main shortcuts.

Nirux looks for the two CLIs on the terminal `PATH` and in the usual per-user install places (`~/.local/bin`, the npm prefix from `~/.npmrc`, nvm, fnm, Volta, asdf, mise, Nix profiles), without running your shell's startup files. A CLI installed somewhere else shows as missing: close the list if you already have one.

Close the list with `×`, or with **Done** once every step is done. `Show Getting Started` in the command palette (`Cmd+P`) brings it back.

## Your first task

1. Choose **Space › New Space…**. Give the space a name and a color, and add your repository with **Add Repository…**.
2. Press `Cmd+N`, describe what you want done, pick Claude Code or Codex, and press Return.
3. Nirux fetches the base branch, creates a git worktree on a new branch next to your checkout, and starts the agent there with your description. The new workspace appears in the sidebar.

Your main checkout stays as it was: each task works in its own worktree. [Spaces and tasks](spaces-and-tasks.md) covers the sheet, the branch names and what happens when something fails.

To open a plain shell instead, press `Cmd+N` and then Return with nothing typed. From a shell, `Open Claude Code` and `Open Codex` in the command palette start an agent.

## When an agent needs you

A row whose agent waits for you turns amber and reads `Needs you · …`. `Cmd+J` goes to the agent that has waited longest, then to the next one at each press. Nirux also sends a macOS notification and counts the waiting workspaces on its Dock icon. [Agents](agents.md) describes every state.

## Let an agent start the next task

With the agent skills installed, an agent can open a workspace by itself. Ask it to start a feature or a fix in a separate workspace: it writes a short handover, and Nirux creates the worktree, opens a workspace on it and launches the same agent there. With [Mission handoffs](missions.md) on, the two agents can then exchange questions and results.

## Next

- [Workspaces and columns](workspaces-and-columns.md): the sidebar, the editor, the browser, search
- [Keyboard shortcuts](keyboard-shortcuts.md)
