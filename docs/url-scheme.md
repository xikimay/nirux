# URL scheme and agent skills

The installed app registers the `nirux://` URL scheme. The bundled agent skills use it to open workspaces and files from inside an agent session; scripts can use it too.

## Agent skills

`Install Agent Skills` (command palette, Getting Started) writes four skills, each to `~/.claude/skills/<name>/SKILL.md` and `~/.agents/skills/<name>/SKILL.md`:

| Skill | What it lets an agent do |
| --- | --- |
| `nirux-worktree` | Open a separate Nirux workspace, in a new worktree, when you ask to start a feature, a fix or a parallel piece of work |
| `nirux-show-code` | Open code in the editor column when you ask to see it, instead of pasting it in the terminal |
| `nirux-draft` | Put text you will paste elsewhere (a Slack message, a PR description, a ticket, a SQL query) in an editor column, where `Cmd+A` `Cmd+C` copies it verbatim |
| `nirux-second-opinion` | When you ask Claude for a second opinion, send its answer to a read-only `codex exec` in the same folder and show Codex's reply |

Nirux keeps these copies current: at launch, the installed app rewrites each copy whose text a version of Nirux wrote. A copy you edited stays as you left it, and so does one reached through a symbolic link; Getting Started then offers **Update**, and `Install Agent Skills` replaces it. A skill you deleted from a folder is never added back.

## Trust: the launch ID

Any app or web page can open a `nirux://` URL. So an action runs without asking only when the URL carries `launch=` with the current value of `NIRUX_LAUNCH_ID`, which Nirux generates at each launch and exports to its terminals. The skills pass it automatically.

Without it, or with a value from before Nirux last restarted, Nirux shows a confirmation that spells out the folder or file, the branch, the agent and the permission mode before doing anything.

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
| `handover` | Optional. A file Nirux moves into the worktree as `.claude-handover.md` or `.codex-handover.md`, then tells the agent to read. It must be your own regular file directly in `/tmp`, named `nirux-handover-…`; any other path is ignored |
| `profile` | Optional. The space that receives the workspace. Nirux terminals expose theirs as `NIRUX_PROFILE_ID` |
| `from=head` | Optional. Start a new branch from the HEAD of `repo` (a stacked branch) |
| `parentWorkspace`, `parentAgent` | Optional. The requesting workspace and terminal, by UUID. The new workspace goes to that workspace's space and, when the parent is a task, lists under it as a sub-task. With [Mission handoffs](missions.md) on, they also link the two agents |

**Where the worktree goes.** Next to the main checkout, named `<main folder>.<branch>` with `/` replaced by `-`: from `repo.feat-a`, `feat/b` becomes `repo.feat-b`. When git can't tell where the main checkout is (a bare repository, a separate git dir, a submodule), it goes next to `repo`.

**Where the branch starts.**

- A branch that doesn't exist yet starts from origin's base branch: the space's board setting when the repository is the space's default one, else origin's default branch, else its `main` or `master`. It is fetched first and not tracked. If the fetch fails, the branch starts from the base as last fetched, and Nirux says so.
- A branch that exists locally opens as it is. One that exists only on the remote tracks `origin/<branch>`.
- A branch already checked out in another linked worktree opens that worktree. A branch checked out in the main checkout, or in `repo` itself, is refused.

## `nirux://open-editor`

```text
nirux://open-editor?file=/path/to/file.swift&line=42&endLine=57&workspace=<NIRUX_WORKSPACE_ID>&launch=<NIRUX_LAUNCH_ID>
```

Opens a file in an editor column.

- `file` is an absolute, URL-encoded path to an existing regular text file of at most 5 MB. Binaries are refused; symlinks are resolved.
- `line` and `endLine` are optional 1-based line numbers. With both, the editor highlights the range.
- `workspace` is optional. When it matches a workspace ID (`NIRUX_WORKSPACE_ID` in Nirux terminals), Nirux switches to that workspace first.

Keyboard focus stays in the column you were working in: it never lands in the editor.
