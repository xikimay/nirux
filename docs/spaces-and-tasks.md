# Spaces and tasks

A space holds the work of one product or client. A task is a workspace Nirux made for one piece of work, usually in a git worktree of its own.

## Spaces

**Space › New Space…** gives a space a name, a color and the repositories or folders its work lives in, one of them the default. A repository belongs to one space: its worktrees open there whatever space is on screen.

The space picker at the top of the sidebar lists every space with its task count, amber while an agent there waits for you. `Alt+Cmd+1…9` go to the first nine spaces, `Alt+Cmd+Left` and `Alt+Cmd+Right` to the previous and next.

**General** is the space every install starts with. It has no repository, comes first in every list and can't be deleted. A deleted space's workspaces move there.

### Space Settings

One window, one tab per topic:

| Tab | What it sets |
| --- | --- |
| General | name, color, repositories and folders, the default one, each repository's setup script |
| Defaults | the agent new tasks preselect, the Claude and Codex modes, environment variables for new shells |
| Lead | the space's [Lead](#the-lead) |
| Brief | rules given to every agent the space starts |
| Memory | what agents know about the repository ([Space memory](#space-memory)) |
| Board | the Board's repository, base branch and checks |
| Templates | the task templates of the `Cmd+N` sheet |

A launch uses a choice made for it first, then the space's defaults, then Settings.

Environment values are literal (`$PATH` isn't expanded), names starting with `NIRUX_` are reserved, and the values are kept in the space's `defaults.json`, readable only by you.

A repository's setup script runs with `/bin/sh -e`, without input, once in each new worktree Nirux makes for you, before the agent starts. Keep it idempotent. If it fails, Nirux notifies you and the agent still starts.

Deleting a space deletes its defaults and setup scripts. Its brief stays.

## Starting a task

`Cmd+N` opens **New in \<space\>**. It is also `New…` in the command palette and the Workspaces menu, and the sidebar's `+`.

Describe the task, then pick the repository (shown when the space has two or more), the agent and a template. The first line of the description names the workspace and suggests the branch: `fix/…` when the template is about a bug or the description starts with a word such as "Fix", "Bug" or "Crash", `feat/…` otherwise. **Edit** changes it. Return starts, `Shift+Return` adds a line, `Cmd+Return` starts from anywhere in the sheet.

**Start** then:

1. Fetches the branch the task starts from: the space's base branch on `origin` (Board settings), else origin's default branch, else its `main` or `master`. The fetch takes at most 10 seconds and never asks for credentials. If it fails, the sheet says why, and a second **Start** uses the branch as last fetched.
2. Creates a worktree next to the repository's main checkout, on a new branch without an upstream. The folder is named `<main folder>.<branch>`, with `/` replaced by `-`.
3. Writes the handover (`.claude-handover.md` or `.codex-handover.md`) with your description and the template's text, and keeps both names out of git through `.git/info/exclude`.
4. Opens a workspace named after the task and launches the agent, told to read the handover.

A branch that already exists, locally or on a remote, is refused, and the sheet stays open with the error. **Close** hides the sheet while a long checkout runs: the workspace opens when it is ready, and the sheet comes back if it fails.

With the description empty, **Start** opens a plain workspace instead: a shell in the repository's main checkout, or in your home folder when the space has no repository.

**Existing Branch…** lists the repository's worktrees, then its local branches and origin's that have none. Picking one creates its worktree and opens a shell there.

### Tasks without a repository

Research, writing or a one-off script need no repository: pick **No Repository**, the last item of the repository menu. Tasks in General, and in a space without a repository, always start this way.

Nirux then makes a new folder named after the task in `~/Nirux Tasks` (Settings › General picks another place) and starts the agent in it: no git, no branch, no pull request. A name already taken gets ` 2`, ` 3` and so on. Nirux never deletes these folders.

Claude Code and Codex ask whether to trust each new folder; the row reads `Needs you · Trust this folder?` until you answer in its terminal. Trusting `~/Nirux Tasks` once in Claude Code covers every folder in it.

### Templates

A template is text added to the handover. Each space has its own, edited in Space Settings › Templates and kept in `<state dir>/projects/<space id>/task-templates.md`, one `## Name` section per template. A new space offers three: Bugfix, Feature (full review cycle) and Investigation (no code).

## Cleaning up merged worktrees

When a task's pull request is merged, its row reads `Merged · Clean up`. The click removes the worktree folder and its local branch, then closes the workspaces open in it. The same action is **Clean Up Worktree…** in a workspace's `⋯` menu.

**Clean Up Merged Worktrees…** in the command palette does it in bulk. It lists every worktree a workspace is open in, plus the other worktrees of the same repositories, checks them all and cleans up the ones you leave checked, one at a time. A worktree whose pull request isn't merged reads `Not merged yet` in grey; real blockers read in orange.

Nothing is merged, pushed or fetched, and the remote branch is never touched. A worktree is cleaned up only when all of this holds, checked with `gh` and git:

- GitHub reports its branch's pull request as merged. The pull request's state counts, not git ancestry, so squash merges qualify.
- The branch tip is the merged pull request's head or an ancestor of it: no local commit is left out.
- Nothing is uncommitted or untracked, apart from the handover files and `.claude/settings.local.json`.
- No other worktree lives inside it, and it isn't locked.
- No editor tab holds unsaved changes to a file in it, and no agent of another workspace runs from inside it.

The refusal names the files that block.

Ignored files would be deleted with the folder, so Nirux moves them to the Trash first, in one "\<folder\> leftovers" folder per worktree. Build output such as `.build/`, `node_modules/` or `DerivedData/` is deleted instead. The confirmation lists all of it, and any agent session that closing the workspaces ends. Return cancels.

Right before deleting, Nirux reads the worktree again, and anything new stops the cleanup. It then runs `git worktree remove` without `--force`, and deletes the branch with `git branch -d` (`-D` after a squash merge). If git refuses, the cleanup stops, shows git's output and puts the leftovers back.

## Space memory

**Space Memory…** (command palette, or Space Settings › Memory) lists what agents know about the workspace's repository, whichever file holds it:

- the space brief's rules, always applied;
- the repository's `CLAUDE.md` and `AGENTS.md`, read-only here;
- Claude Code's auto-memory, shared by every worktree of the repository and read when relevant.

You can search the list, filter it by scope and follow `[[links]]`. Return opens an item's file at its line. A switch moves an item between **Always** and **When relevant**. Items can be added, edited and deleted; a deleted memory goes to the Trash.

## The Lead

A space can have a Lead: a Claude Code session, pinned at the top of the sidebar, that starts tasks for you and follows them. Turn it on with **Start a Lead** in New Space…, or in Space Settings › Lead. `Ctrl+Cmd+L` goes to it, or starts it when the space has none. General never has one.

The Lead can start tasks, send them messages, answer their questions or hand one to you, propose a merge queue, and note each task's next step and blocker. It cannot merge, remove a worktree or a branch, or reach another space. The design record [Spaces, anchors and the Lead](design/spaces.md#the-lead) has the full rules.
