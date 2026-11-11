# URL scheme

The installed app registers the `nirux://` URL scheme. The [agent skills](agent-skills.md) use it to open workspaces and files from inside an agent session, and your own scripts can use it too.

## When a link asks for confirmation

Any app or web page can open a `nirux://` URL. A link therefore runs without asking only when it carries `launch=` with the current value of `NIRUX_LAUNCH_ID`. Nirux generates that value at each launch and sets it in its terminals, except in a workspace that a confirmed link opened. The skills pass it automatically.

Without it, or with a value from before Nirux last restarted, Nirux shows a confirmation that spells out the folder or file, the branch, the agent and the permission mode. A request confirmed this way ignores `profile`, `parentWorkspace`, `parentAgent` and `workspace`. Its workspace opens in the space that has its repository or folder, else in General.

## `nirux://new-workspace`

```text
nirux://new-workspace?cwd=/path/to/project&title=my-task&agent=claude&launch=<NIRUX_LAUNCH_ID>
```

Opens a workspace in `cwd`. `agent` is `claude` or `codex`.

## `nirux://new-worktree`

```text
nirux://new-worktree?branch=feat/example&repo=/path/to/repo&agent=codex&handover=/tmp/nirux-handover-codex-Ab12Cd&profile=default&launch=<NIRUX_LAUNCH_ID>
```

Creates a git worktree and opens it as a workspace.

| Parameter | Meaning |
| --- | --- |
| `repo` | The top level of any checkout of the repository: the main one or a linked worktree |
| `branch` | The branch to check out. See below for where it starts |
| `agent` | `claude` or `codex` |
| `handover` | Optional. A file Nirux moves into the worktree as `.claude-handover.md` or `.codex-handover.md`, then tells the agent to read. It must be your own regular file directly in `/tmp`, named `nirux-handover-…`, not empty and at most 1 MB. Anything else is ignored |
| `from=head` | Optional. Start a new branch from the HEAD of `repo` instead of the base branch |
| `profile` | Optional. A space ID, as Nirux terminals have it in `NIRUX_PROFILE_ID` |
| `parentWorkspace`, `parentAgent` | Optional. The requesting workspace and terminal, by UUID. When the parent is a task, the new workspace lists under it as a sub-task. With [Mission handoffs](missions.md) on, or when the parent is a Lead, they also link the two agents |

The workspace goes to the space that has its repository or folder. Without one, it goes to the parent workspace's space, then to `profile`, then to General.

The worktree is created next to the main checkout and named `<main folder>.<branch>`, with `/` replaced by `-`. From `repo.feat-a`, the branch `feat/b` gives `repo.feat-b`. When git can't tell where the main checkout is (a bare repository, a separate git dir, a submodule), the worktree goes next to `repo`.

Where the branch starts depends on whether it exists:

- A new branch starts from the base branch the space's Board sets for that repository, else origin's default branch, else its `main` or `master`. That branch is fetched first. If the fetch fails, the new branch starts from the base as last fetched, and Nirux says so. Without an `origin`, or when the base was never fetched, it starts from the HEAD of `repo`.
- A branch that exists locally opens as it is. One that exists only on the remote tracks `origin/<branch>`.
- A branch already checked out in another linked worktree opens that worktree. A branch checked out in the main checkout, or in `repo` itself, is refused.

## `nirux://open-editor`

```text
nirux://open-editor?file=/path/to/file.swift&line=42&endLine=57&workspace=<NIRUX_WORKSPACE_ID>&launch=<NIRUX_LAUNCH_ID>
```

Opens a file in an editor column.

- `file` is an absolute, URL-encoded path to an existing regular text file of at most 5 MB. Binaries are refused, and symlinks are resolved.
- `line` and `endLine` are optional line numbers, starting at 1. With both, the editor highlights the range.
- `workspace` is optional. When it matches a workspace ID (`NIRUX_WORKSPACE_ID` in Nirux terminals), Nirux switches to that workspace first.

The editor becomes the focused column, so `Cmd+W` then closes the file's tab, but typing still goes where it went before.
