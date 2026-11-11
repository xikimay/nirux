# Workspaces and columns

Every shortcut mentioned here is also listed in [Keyboard shortcuts](keyboard-shortcuts.md).

## The sidebar

Each workspace is a row of two lines: its title and time, then one status line. The status line shows the first of these that applies:

| Status line | When |
| --- | --- |
| `Needs you · npm run migrate` (amber) | an agent is waiting for you, here for a permission |
| `#39 · checks failed` (red) | the checks of its [pull request](pull-requests.md) failed, and no agent is working |
| `Asking <parent>` | the agent is waiting for an answer from the agent that started it ([Mission handoffs](missions.md)) |
| `Working` | an agent is working |
| `Blocked · waits for #212` | the blocker noted in the workspace's context |
| `#39 · checks passed`, `Ready to merge` | the state of its pull request |
| `Next · …` | the next step noted in the workspace's context |
| the branch or folder | nothing else to say |

The row of the workspace on screen also lists its columns, its changes and its pull request's links.

In a row's `⋯` menu:

- `Rename Workspace` changes the title. A double-click on the row does too.
- `View/Edit Context…` holds notes on the work: purpose, phase, latest summary, next step, blocker. They are saved with the workspace.
- `Organize › Archive` puts a finished workspace away. Archived workspaces wait behind the **Archived** row at the bottom of the sidebar and don't poll GitHub.

`Ctrl+Cmd+S` collapses the sidebar to a rail: the space on top, then one tile per workspace with its initials and its state in a corner, amber only when an agent is waiting for you. Hover a tile for what it is doing. Click, drag and right-click work as on the rows.

## Columns

A workspace's columns sit side by side. `Cmd+T` adds a terminal, `Cmd+B` a browser, and `Open Editor` in the command palette an editor. Drag the divider between two columns to resize them (a double-click resets it to half), or press `Cmd+E` to step through preset widths.

### Terminals

Terminals are drawn by Ghostty's engine and follow the appearance settings of your [Ghostty configuration](terminal-appearance.md).

- `Cmd+F` searches the scrollback and highlights every match.
- `Cmd+click` on a web URL opens it as a browser column in the same workspace. File links open in the editor, and other schemes go to their macOS handler.
- When a shell exits, press Enter to restart it. The scrollback is kept.

### Editor

The editor opens files in tabs, with a file tree, a search across the workspace, the list of git changes and a diff view for each file (`Shift+Cmd+D`). It warns before overwriting a file that changed on disk. `Option+Cmd+Return` sends the selection to the agent's terminal.

### Browser

A browser column keeps its URL history, downloads files to `~/Downloads`, and opens the Web Inspector with `Option+Cmd+I`. `Cmd+F` finds text in the page and counts the matches.

`Import Browser Cookies` in the command palette copies the cookies of a Chrome, Brave, Arc or Edge profile, so that pages open signed in. The action is listed when one of these browsers is found.

## Finding your way

- `Cmd+P` opens the command palette (`Shift+Cmd+P` from the editor). It lists the current space's workspaces and its five most recent sessions, then the actions. Type a workspace's name, branch, space or folder and press Return to go to it, in any space, archived ones included. Each row shows its agents' state.
- `Cmd+J` goes to the agent that has waited for you longest.
- `Session History…` (command palette, Space menu) lists every past Claude Code and Codex session of the space, including those whose worktree was cleaned up. Return resumes one, in its workspace or in a new one, and brings its worktree back if needed.
- `Option+Cmd+F`, Search Everywhere, finds text in the scrollback of every terminal, in every workspace and space, then in the transcripts of your Claude sessions. Picking a terminal match opens that terminal's find bar on it. Picking a transcript match resumes the session or goes to its column.
- `Shift+Cmd+F` searches the files of the current workspace.

At the right end of the title bar, three buttons open the New sheet (`Cmd+N`), the [Board](pull-requests.md#the-board) (`Ctrl+Cmd+B`) and the command palette (`Cmd+P`).

## After a restart

Nirux saves the layout of every workspace, its editor tabs, its browser URLs and the sidebar's state, and restores them at launch. Agents come back too, as [Agent status](agent-status.md#after-a-restart) explains.
