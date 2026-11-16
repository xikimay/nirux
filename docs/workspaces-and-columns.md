# Workspaces and columns

Every shortcut mentioned here is also listed in [Keyboard shortcuts](keyboard-shortcuts.md).

## The sidebar

Each workspace is a row of two lines: its title and time, then one status line. Before the title, its state icon, the same one the folded rail, the command bar and the requests show: an amber disc while an agent waits for you (a command or a question), a red "!" for an error, a green ring while an agent works, a grey check once a turn has ended, a grey ring while its pull request's checks run (an arc that turns while the window is in sight, dashes with Reduce motion or on an archived task), a green ring with a check once they pass, a violet disc once merged, a struck grey ring for a blocker, a grey "?" while the agent asks the one that started it. The selected row lies on a pane of glass. At the foot of the sidebar, **Tasks · Board · History**: Tasks is the list above, Board opens the space's Board, History opens `Session History…`. The status line shows the first of these that applies:

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

`Ctrl+Cmd+S` folds the sidebar into a rail of icons: the space's Lead, then one state icon per task with the task's initials in its ring, ringed in amber only when an agent is waiting for you (the reason then takes the place of the initials, as an error's "!" does), and a working one breathes. Hover an icon for its name and what its row says. A click goes where a click on its row goes (a task whose agent waits for you opens on that agent), and a right-click opens the task's menu; drag and double-click to rename stay in the unfolded sidebar. Under the rail: the archived tasks (unfolds the sidebar with the Archived list open), a new task, and the Board. The sidebar also folds by itself when the window is narrower than 900 points, and unfolds again from 940 points if you had it unfolded.

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
- `Cmd+J` goes to the agent that has waited for you longest, those you have not seen yet first. With the sidebar folded, it opens the requests under the command bar instead: each with its answers (Allow, Yes, Reply…); press `Cmd+J` again to go to the one chosen (`↑` `↓` choose). A click on an amber icon of the rail shows its task's request beside it.
- `Session History…` (command palette, Space menu) lists every past Claude Code and Codex session of the space, including those whose worktree was cleaned up. Return resumes one, in its workspace or in a new one, and brings its worktree back if needed.
- `Option+Cmd+F`, Search Everywhere, finds text in the scrollback of every terminal, in every workspace and space, then in the transcripts of your Claude sessions. Picking a terminal match opens that terminal's find bar on it. Picking a transcript match resumes the session or goes to its column.
- `Shift+Cmd+F` searches the files of the current workspace.

The command bar sits at the top of the window, level with its buttons. It shows the space (click for the space menu), the task on screen and where it stands (click for the task's menu), the search (`Cmd+P`, which opens under the bar), and how many requests wait for you in every space (click or `Cmd+J`: the requests with the sidebar folded, the next agent with it unfolded). New is in the sidebar and `Cmd+N` (and a click on the task part when nothing is open), the [Board](pull-requests.md#the-board) is `Ctrl+Cmd+B`, in the Space menu and in the command palette.

## After a restart

Nirux saves the layout of every workspace, its editor tabs, its browser URLs and the sidebar's state, and restores them at launch. Agents come back too, as [Agent status](agent-status.md#after-a-restart) explains.
