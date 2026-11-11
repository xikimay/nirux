# Keyboard shortcuts

Standard macOS shortcuts (copy, paste, quit) work as usual and are not listed. Most command palette actions also have a menu bar item, so the Help menu's search finds them. A few titles differ slightly.

## Everywhere

| Shortcut | Action |
| --- | --- |
| `Cmd+P` | Command palette and workspace switcher. In the editor, the file picker |
| `Shift+Cmd+P` | Command palette, also from the editor |
| `Cmd+N` | New…: a task, or a shell when nothing is typed |
| `Cmd+J` | Next waiting agent: the one that has waited for you longest, then the next at each press |
| `Ctrl+Cmd+B` | Board of the current space |
| `Ctrl+Cmd+L` | The space's Lead |
| `Ctrl+Cmd+S` | Collapse or expand the sidebar |
| `Cmd+,` | Settings (General, Agents, Notifications). A change applies at once |
| `Ctrl+Cmd+F` | Enter or leave full screen |
| `Cmd+M` | Minimize the window |

## Workspaces and spaces

| Shortcut | Action |
| --- | --- |
| `Cmd+Up` / `Cmd+Down` | Previous or next workspace |
| `Ctrl+Cmd+Up` / `Ctrl+Cmd+Down` | Previous or next workspace, also while you type in a text field |
| `Option+Cmd+Left` / `Option+Cmd+Right` | Previous or next space |
| `Option+Cmd+1…9` | The space at that place in the space picker |

## Columns

| Shortcut | Action |
| --- | --- |
| `Cmd+T` | New terminal column |
| `Cmd+B` | New browser column |
| `Cmd+W` | Close the editor tab, the column or the workspace, depending on context. Asks first when an agent session is running (Return cancels, `Cmd+D` closes) |
| `Cmd+1…9` | Focus column N |
| `Cmd+Left` / `Cmd+Right` | Focus the previous or next column |
| `Ctrl+Cmd+Left` / `Ctrl+Cmd+Right` | Focus the previous or next column, also while you type in a text field |
| `Shift+Cmd+Left` / `Shift+Cmd+Right` | Move the focused column |
| `Cmd+E` | Step the focused column through preset widths |

While you type in a text field (the editor, a field of a web page, the address bar, a find field), the arrow shortcuts act on the text first:

- `Cmd+Left` and `Cmd+Right` go to the start or end of the line. In the editor, a press with the caret already there focuses the column beside.
- `Cmd+Up` and `Cmd+Down` go to the start or end of the document. In the editor, a press with the caret already on the first or last line switches workspace.
- `Shift+Cmd+Left` and `Shift+Cmd+Right` select to the start or end of the line. **Columns › Move Left** and **Move Right** still move the column.

The shortcuts that switch workspace or column don't repeat while the key is held.

## Search

| Shortcut | Action |
| --- | --- |
| `Cmd+F` | Find in the focused editor, terminal or browser page. `Esc` closes the find bar |
| `Cmd+G` / `Shift+Cmd+G` | Next or previous match. In a terminal, next moves up to older output, as in Ghostty |
| `Shift+Cmd+F` | Search the files of the workspace |
| `Option+Cmd+F` | Search Everywhere: every terminal's scrollback, then your Claude sessions' transcripts |

A full-screen program (vim, less) keeps no scrollback, so Search Everywhere searches only its screen.

## Editor

| Shortcut | Action |
| --- | --- |
| `Cmd+S` / `Option+Cmd+S` | Save the file / save all |
| `Shift+Cmd+D` | Show or hide the file's diff |
| `Option+Cmd+Z` | Word wrap |
| `Shift+Cmd+M` | Minimap |
| `Option+Cmd+Return` | Send the selection to the agent's terminal |
| `Cmd+=` / `Cmd+-` / `Cmd+0` | Font size: larger, smaller, reset |
| `Cmd+L` | Select the line |
| `Cmd+Z` / `Shift+Cmd+Z` | Undo / redo, also in panel text fields |

## Browser

| Shortcut | Action |
| --- | --- |
| `Cmd+L` | Focus the address bar |
| `Cmd+[` / `Cmd+]` | Back / forward |
| `Option+Cmd+I` | Web Inspector on the focused browser column |

## Command palette actions

Open the palette with `Cmd+P` and type a few letters of an action:

- **Agents:** Open Claude Code, Open Codex, Next Waiting Agent, Resume All Agents, Install Agent Skills
- **Tasks and workspaces:** New…, Open Worktree, Clean Up Merged Worktrees…, Rename Workspace, Session History…, Space Memory…
- **Columns:** New Terminal, Open Editor, Open Browser, Open Board, Review Branch, Resize Column (Cycle Width)
- **Search:** Search Workspace, Search Everywhere
- **Editor and browser:** Toggle Editor Diff, Toggle Web Inspector, Import Browser Cookies (listed when a Chrome, Brave, Arc or Edge profile is found)
- **Window:** Show/Hide Sidebar, Show/Hide Archived, Show Getting Started, Open Settings
