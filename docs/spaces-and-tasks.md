# Spaces and tasks

A space holds the work of one product or client. A task is a workspace that Nirux creates from your description, usually in a git worktree of its own: a second checkout of the repository, in its own folder.

## Spaces

**Space › New Space…** gives a space a name, a color and the repositories or folders its work lives in, one of them the default. A repository belongs to one space, and its worktrees open there whatever space is on screen.

The space picker at the top of the sidebar lists every space with its task count, amber while an agent there is waiting for you. `Option+Cmd+1…9` go to the first nine spaces, `Option+Cmd+Left` and `Option+Cmd+Right` to the previous and next.

**General** is the space every install starts with. It has no repository, comes first in every list and can't be deleted. A deleted space's workspaces move there.

### Space Settings

Space Settings is one window with a tab per topic:

| Tab | What it sets |
| --- | --- |
| General | name, color, repositories and folders, the default one, each repository's setup script |
| Defaults | the agent new tasks preselect, the Claude Code and Codex modes, environment variables for new shells |
| Lead | the space's [Lead](#the-lead) |
| Brief | rules given to every agent the space starts |
| Memory | what agents know about the repository ([Space memory](#space-memory)) |
| Board | per repository, the base branch and the checks the [Board](pull-requests.md#the-board) uses |
| Templates | the task templates of the New sheet |

The agent picked in the New sheet overrides the space's default agent. The space's Claude Code and Codex modes override those of Settings, unless they are left on Same as Settings.

Environment values are literal (`$PATH` isn't expanded) and names starting with `NIRUX_` are reserved. They are kept in a file only you can read.

A repository's setup script runs once in each new worktree made for a task, before the agent starts, with `/bin/sh -e` and no input. A worktree made by **Existing Branch…** runs none. If the script fails, Nirux notifies you and the agent still starts.

Deleting a space deletes its defaults and setup scripts but keeps its brief.

## Starting a task

`Cmd+N` opens the New sheet, titled **New in \<space\>**. The same sheet opens from `New…` in the command palette and the Workspaces menu, and from the sidebar's `+`.

Describe the task, then pick the repository (in every space but General), the agent and a template. The first line of the description names the workspace and suggests the branch: `fix/…` when the template is about a bug or the description starts with a word such as "Fix", "Bug" or "Crash", `feat/…` otherwise. **Edit** changes the branch name. Return starts, `Shift+Return` adds a line, and `Cmd+Return` starts from anywhere in the sheet.

**Start** then does four things:

1. It fetches the branch the task starts from: the base branch set for that repository in Space Settings › Board, else origin's default branch, else its `main` or `master`. When `origin` has none of these, the task starts from the main checkout's HEAD, and the sheet says so.
2. It creates a worktree next to the repository's main checkout, on a new branch. The folder is named `<main folder>.<branch>`, with `/` replaced by `-`.
3. It writes a handover file in the worktree (`.claude-handover.md` or `.codex-handover.md`) with your description and the template's text, and keeps that file out of git.
4. It opens a workspace named after the task and launches the agent, told to read the handover file.

If the fetch fails, the sheet says why, and a second **Start** uses the branch as last fetched. A branch name that already exists, locally or on a remote, is refused, and the sheet stays open with the error.

**Close** hides the sheet while a long checkout runs. The workspace opens when it is ready, and the sheet comes back if the checkout fails.

With the description empty, **Start** opens a plain workspace instead: a shell in the repository's main checkout, or in your home folder when **No Repository** is selected.

**Existing Branch…** lists the repository's worktrees, then its local branches and origin's that have none. Picking a worktree opens it. Picking a branch creates its worktree and opens a shell there.

### Sub-tasks

**New Sub-task…**, in a task's `⋯` menu and the Workspaces menu, opens the sheet under that task. The sub-task starts in the task's repository, from the same base branch as any task, or in a folder inside the task's own folder for a task without a repository. It lists right under its task in the sidebar.

A task's Claude Code agent can start sub-tasks itself, with the `start_task` tool Nirux gives it, when you ask it to split the work. A sub-task it starts opens behind what you are doing. It reports to that agent even with Mission handoffs off: its questions and its result are typed into the agent's prompt (see [Missions](missions.md)). With its tools, the agent lists its sub-tasks, gives one more work, answers their questions, or hands a question it can't settle to you: the sub-task's row then turns amber with its reason.

- There are two levels at most: `start_task` refuses to start a sub-task from a sub-task.
- A task runs at most six sub-tasks at once. Only those that report to it count: not archived ones, not those that reported their result, and not those you started under it yourself.
- When **Starts tasks without asking** is off in Space Settings › Lead, the agent's sub-task opens in the sheet, filled in, for you to start, once any sheet already open closes. The agent hears what you did.
- Each sub-task reports to the agent that started it: another agent of the same task doesn't see its questions.
- A workspace opened by a link from outside Nirux gets no such tools.

### Tasks without a repository

Research, writing or a one-off script need no repository. Pick **No Repository**, the last item of the repository menu. Tasks in General, and in a space without a repository, always start this way.

Nirux then makes a new folder named after the task in `~/Nirux Tasks` (Settings › General picks another place) and starts the agent in it, with no git, no branch and no pull request. A name already taken gets ` 2`, ` 3` and so on. Nirux never deletes these folders.

Claude Code and Codex ask whether to trust each new folder, and the row reads `Needs you · Trust this folder?` until you answer in its terminal. Trusting `~/Nirux Tasks` once in Claude Code covers every folder in it.

### Templates

A template is text added to the handover file. Each space has its own templates, edited in Space Settings › Templates. A new space offers three: Bugfix, Feature (full review cycle) and Investigation (no code).

## Cleaning up merged worktrees

When a task's pull request is merged, its row reads `Merged · Clean up`. The click removes the worktree folder and its local branch, then closes the workspaces open in it. The same action is **Clean Up Worktree…** in a workspace's `⋯` menu.

**Clean Up Merged Worktrees…** in the command palette does it in bulk. It lists every worktree a workspace is open in, plus the other worktrees of the same repositories, and inspects them all. Worktrees that are ready, open in a workspace, with idle agents and in the folder made for their branch come selected, and the selected ones are cleaned up one at a time. A worktree whose pull request isn't merged reads `Not merged yet` in grey, and a real blocker reads in orange.

### What Nirux checks first

Nothing is merged, pushed or fetched, and the remote branch is never touched. A worktree is cleaned up only when all of this holds:

- GitHub reports its branch's pull request as merged. The pull request's state counts, not git ancestry, so squash merges qualify.
- The branch has no local commit that the merged pull request lacks.
- Nothing is uncommitted or untracked, apart from the handover files and `.claude/settings.local.json`.
- No other worktree lives inside it, and it isn't locked.
- No editor tab holds unsaved changes to a file in it, and no agent of another workspace runs from inside it.

When a check fails, the refusal names the files that block.

### What happens to ignored files

Git would delete ignored files with the folder, so Nirux moves them to the Trash first, in one "\<folder\> leftovers" folder per worktree. Build output such as `.build/`, `node_modules/` or `DerivedData/` is deleted instead. The confirmation lists these files and the agent sessions that closing the workspaces would end. Return cancels it.

Nirux never forces the worktree's removal. If git refuses, the cleanup stops, shows git's message and puts the leftovers back. If only the branch deletion fails, the folder is gone, the branch is kept and the leftovers stay in the Trash.

## Space memory

**Space Memory…** (command palette, or Space Settings › Memory) lists what agents know about the workspace's repository, whichever file holds it:

- the space brief's rules, always applied;
- the repository's `CLAUDE.md` and `AGENTS.md`, read-only here;
- Claude Code's auto-memory, shared by every worktree of the repository and read when relevant.

You can search the list, filter it by scope and follow `[[links]]`. Return opens an item's file at its line. A switch moves an item between **Always** and **When relevant**. Items can be added, edited and deleted, and a deleted memory goes to the Trash.

## The Lead

A space can have a Lead: a Claude Code session, pinned at the top of the sidebar, that starts tasks for you and follows them. Turn it on with **Start a Lead**, in New Space… or the Space menu, or with the **Lead workspace** switch in Space Settings › Lead. `Ctrl+Cmd+L` goes to the Lead, or starts one when the space has none. General can't have a Lead.

The Lead can start tasks, send them messages, answer their questions or hand one to you, propose a merge queue, and note each task's next step and blocker. It cannot merge, remove a worktree or a branch, or reach another space. Its rules are written down in the design record [Spaces, anchors and the Lead](design/spaces.md#the-lead).
