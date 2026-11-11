# Workspaces and columns

What the window holds and how to move around it. Shortcuts are listed in [Keyboard shortcuts](keyboard-shortcuts.md).

## The sidebar

Each workspace is a row of two lines: its title and time, then one status line. The status line says the most pressing thing about the task:

| Status line | When |
| --- | --- |
| `Needs you · npm run migrate` (amber) | an agent waits for you: a permission, a question |
| `Asking the Lead` | the agent waits for another agent's answer ([Missions](missions.md)) |
| `Working` | an agent is working |
| `Blocked · waits for #212` | the blocker noted in the task's context |
| `#39 · checks passed`, `#39 · checks failed`, `Ready to merge` | the state of its [pull request](pull-requests.md) |
| `Next · …` | the next step noted in the task's context |
| the branch or folder | nothing else to say |

The row of the workspace on screen also lists its columns, its changes and its pull request's links.

- **Rename:** double-click a row, or `Rename Workspace` in its `⋯` menu.
- **Context:** `View/Edit Context…` in the `⋯` menu keeps a longer purpose apart from the title, a phase, and the latest summary, next step and blocker. They are saved with the workspace.
- **Archive:** the `⋯` menu archives a finished workspace. Archived workspaces wait behind the **Archived** row at the bottom of the sidebar and don't poll GitHub.

Collapsed (`Ctrl+Cmd+S`), the sidebar is a rail: the space on top, then one tile per workspace with its initials and its state in a corner, amber only when an agent waits for you. Hover a tile for what it is doing. Click, drag and right-click work as on the rows.

## Columns

A workspace's columns sit side by side. `Cmd+T` adds a terminal, `Cmd+B` a browser, and `Open Editor` in the command palette an editor. Drag the divider between two columns to resize them (a double-click resets it to half), or press `Cmd+E` to step through preset widths.

### Terminals

Terminals are drawn by Ghostty's engine and follow the appearance settings of your [Ghostty configuration](terminal-appearance.md).

- `Cmd+F` searches the scrollback and highlights every match.
- `Cmd+click` on a web URL opens it as a browser column in the same workspace. File links open in the editor; other schemes go to their macOS handler.
- When a shell exits, the terminal offers to restart it: press Enter. The scrollback is kept.

### Editor

The editor opens files in tabs, with a file tree, a search across the workspace, the list of git changes and a diff view for each file (`Shift+Cmd+D`). It has find and replace, word wrap, font zoom, and it warns before overwriting a file that changed on disk. `Alt+Cmd+Return` sends the selection to the agent's terminal.

### Browser

A browser column keeps its URL history, downloads files to `~/Downloads`, and opens the Web Inspector with `Alt+Cmd+I`. `Import Browser Cookies` in the command palette copies the cookies of a Chrome, Brave, Arc or Edge profile, so pages open signed in. `Cmd+F` finds text in the page and counts the matches.

## Finding your way

- **`Cmd+P`** lists the current space's workspaces and its five most recent sessions, then the actions. Type a workspace's name, branch, space or folder and press Return to go to it, in any space, archived ones included. Each row shows its agents' state.
- **`Cmd+J`** goes to the agent that has waited for you longest.
- **Session History…** (command palette, Space menu) lists every past Claude and Codex session of the space, cleaned-up worktrees included. Return resumes one, in its workspace or in a new one, bringing its worktree back when it was cleaned up.
- **`Alt+Cmd+F`**, Search Everywhere, finds text in the scrollback of every terminal, in every workspace and space, then in the transcripts of your Claude sessions. Picking a terminal match opens that terminal's find bar on it; picking a transcript match resumes the session or goes to its column.
- **`Shift+Cmd+F`** searches the files of the current workspace.

At the right end of the title bar, three buttons open the New sheet (`Cmd+N`), the Board (`Ctrl+Cmd+B`) and the search (`Cmd+P`).

## After a restart

Nirux saves the layout of every workspace, its editor tabs, its browser URLs and the sidebar's state, and restores them at launch. Agents come back too: see [After a restart](agents.md#after-a-restart).
