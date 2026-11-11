# Getting started

Install Nirux first: see the [README](../README.md#install).

## Workspaces, columns and spaces

- A **workspace** holds one piece of work: a folder, a title and a row of columns. Workspaces are listed in the sidebar.
- A **column** is a terminal, a browser page or an editor. Columns sit side by side.
- A **space** groups the workspaces of one product or client and knows which repositories its work lives in. The sidebar shows one space at a time. Every install starts with one space, **General**, which has no repository.

## First launch

Nirux opens with a **Getting Started** list in the sidebar, below the workspaces. You can ignore it and use the app. It shows:

- whether `claude` or `codex` is installed, with install commands to copy if neither is;
- whether the [agent skills](agent-skills.md) are installed, with an **Install** button. They are instructions for Claude Code and Codex that let an agent open a Nirux workspace or show you a file in the editor;
- whether the [status hooks](agent-status.md#status-hooks) are in place;
- the main shortcuts.

Nirux looks for the two CLIs in the common install locations without running your shell's startup files. If `claude` or `codex` runs fine in a Nirux terminal, ignore the **Install Claude Code or Codex** step.

Close the list with `×`, or with **Done** once every step is done. `Show Getting Started` in the command palette (`Cmd+P`) brings it back.

## Your first task

1. Choose **Space › New Space…**. Give the space a name and a color, and add your repository with **Add Repository…**.
2. Press `Cmd+N`, describe what you want done, pick Claude Code or Codex, and press Return.
3. Nirux fetches the base branch and creates a git worktree, a second checkout of the repository in its own folder next to yours, on a new branch. It starts the agent there with your description, and the new workspace appears in the sidebar.

Your own checkout stays as it was, so several tasks can run at once without touching each other's files. [Spaces and tasks](spaces-and-tasks.md) describes the `Cmd+N` sheet in full.

To open a plain shell instead, press `Cmd+N` and then Return with nothing typed. `Open Claude Code` and `Open Codex` in the command palette then start an agent in a new terminal column of that workspace.

## When an agent needs you

A row whose agent is waiting for you turns amber and reads `Needs you · …`. `Cmd+J` goes to the agent that has waited longest, then to the next one at each press.

While Nirux is in the background, it also sends a macOS notification and shows on its Dock icon how many workspaces need attention. [Agent status](agent-status.md) describes every state.

## Let an agent start the next task

With the agent skills installed, an agent can open a workspace by itself. Ask it to start a feature or a fix in a separate workspace. It writes a handover file, a short note for the next agent, and Nirux creates the worktree, opens a workspace on it and launches the same kind of agent there with that note.

With [Mission handoffs](missions.md) on, the two agents can then exchange questions and results.

## Next

- [Workspaces and columns](workspaces-and-columns.md) covers the sidebar, the editor, the browser and search.
- [Keyboard shortcuts](keyboard-shortcuts.md) lists every shortcut.
