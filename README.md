# Nirux

Nirux is a native macOS workspace for supervising terminal-based coding agents. It keeps agent terminals, a browser, source files, diffs, Git status, and workspace context in one persistent AppKit window so long-running Claude Code or Codex sessions stay visible and resumable.

Nirux is alpha software.

## Highlights

- Persistent workspaces: name each new task as you create it, stack workspaces vertically, and archive inactive ones in a collapsible sidebar section that does not poll GitHub.
- Horizontal columns: mix Ghostty-backed terminals, WKWebView browser columns, and Monaco editor columns in the same workspace.
- Agent launchers: start Claude Code or Codex from the command palette with configurable permission and sandbox presets.
- Attention and Activity: per-column agent status (working / needs attention, with elapsed time) driven by real Claude Code hooks and Codex turn notifications — not output guessing — plus a persistent sidebar feed, edge glows for off-screen attention, native macOS notifications that focus the right workspace and column on click, and a Dock badge counting waiting workspaces.
- Opt-in Telegram Remote Access: pair one private Telegram user to list live agent sessions, inspect status and recent output, receive completion/attention alerts, and continue a selected session without exposing a webhook or general-purpose shell.
- Worktree flow: create or open Git worktrees as new workspaces, optionally handing context from the current agent session into the new workspace.
- Built-in editor: open files, keep tabs, search the workspace, browse the file tree with Finder icons, view Git changes, and toggle file diffs. Find/replace, word wrap, font zoom, per-tab scroll restore, and disk-conflict protection included.
- Browser context: open URLs in app, keep URL history, import cookies from Chrome, Brave, Arc, or Edge into the shared WebKit data store, download files to ~/Downloads, and inspect pages with the Web Inspector.
- Pilot mode: switch to a compact overview of active workspaces with branch, column, diff, PR, CI, and review state where available.
- Session restore: workspace layout, editor tabs, browser URLs, sidebar state, detected Claude/Codex launch modes, and verified Codex thread IDs are saved under Application Support, with rotating backups for corruption recovery. Known Codex threads resume by exact ID; legacy, missing, empty, or duplicate IDs open Codex's interactive resume picker instead of guessing the last session.

## Requirements

- macOS 14 or newer.
- Swift 6 toolchain for local builds.
- `claude` and/or `codex` on `PATH` if you want Nirux to launch those agents.

## Install A Build

Download `Nirux.app.zip` from the nightly release:

```text
https://github.com/xikimay/nirux/releases/tag/nightly
```

Unzip it and move `Nirux.app` to `/Applications`.

Current public builds should be signed and notarized. If you are opening an older pre-notarized build and macOS Gatekeeper says Apple cannot verify it, open it once with:

1. Control-click or right-click `Nirux.app`.
2. Choose `Open`.
3. Confirm `Open` in the macOS dialog.

If macOS still blocks that older build, remove its quarantine attribute:

```bash
xattr -dr com.apple.quarantine /Applications/Nirux.app
```

## How To Use Nirux

Nirux is organized around workspaces.

A workspace is a persistent task context: it has a current directory, a title, a Git branch, and a horizontal strip of columns. Columns can be terminals, browser tabs, or editor views. Workspaces are stacked vertically, so you can keep several tasks alive without mixing their terminals, files, and browser context.

The intended setup is:

1. Open Nirux and use the first workspace as your main repo workspace.
2. In that workspace, `cd` into the main checkout of the repo.
3. Open the command palette with `Cmd+P`.
4. Run `Install Agent Skills` before starting agent work. You only need to do this once.
5. Launch Claude Code or Codex from the palette.
6. Ask the agent to start a feature, bugfix, or investigation in a separate workspace.

After the skill is installed, supported agents know how to hand work back to Nirux. When you ask for a separate task, the agent writes a short handover file and opens `nirux://new-worktree`. Nirux creates the Git worktree, moves the handover into it, opens a new workspace pointed at that worktree, and launches the same agent there.

That leaves your main workspace on the original checkout while each isolated branch gets its own Nirux workspace.

### Mission handoffs (experimental)

Mission handoffs add an explicit, durable mailbox between the agent that delegates a worktree task and the agent launched in that worktree. The feature is disabled by default. Enable `Settings` → `Experimental` → `Mission handoffs`; the setting applies to new terminals. After updating Nirux, run `Install Agent Skills` again so the installed `nirux-worktree` skill has the matching mailbox instructions.

With Mission handoffs enabled, worktrees opened by the installed skill can send correlated questions and wait for answers, while the parent agent can receive and reply from its terminal. Questions and explicit completion results also appear in the Activity section of the expanded sidebar and in native notifications while Nirux is in the background. Click a question in Activity to reply or open its child workspace.

Mission completion is always reported explicitly by the child agent. Nirux does not infer completion from a stopped turn and does not inject replies into a terminal. Worktrees opened without Mission metadata keep the existing handover behavior.

Typical command palette actions:

- Install Agent Skills
- Open Claude Code
- Open Codex
- New Worktree
- Open Worktree
- New Terminal
- Open Editor
- Search Workspace
- Open Browser
- Import Browser Cookies
- New Workspace
- Pilot Mode
- Rename Workspace

Useful shortcuts:

| Shortcut | Action |
| --- | --- |
| `Cmd+P` | Command palette (fuzzy matching) |
| `Cmd+T` | New terminal column |
| `Cmd+B` | Open browser URL flow |
| `Cmd+W` | Close editor tab, column, or workspace depending on context |
| `Cmd+1…9` | Focus column N |
| `Cmd+Left` / `Cmd+Right` | Focus previous or next column |
| `Shift+Cmd+Left` / `Shift+Cmd+Right` | Move the focused column |
| `Cmd+E` | Cycle focused column width through presets |
| `Cmd+N` | New workspace |
| `Cmd+Up` / `Cmd+Down` | Switch workspace |
| `Cmd+O` | Toggle Pilot Mode |
| `Cmd+S` | Toggle sidebar |
| `Shift+Cmd+F` | Search workspace |
| `Cmd+F` | Find in editor |
| `Shift+Cmd+D` | Toggle editor diff |
| `Alt+Cmd+Z` | Toggle word wrap in editor |
| `Cmd+=` / `Cmd+-` / `Cmd+0` | Editor font zoom in / out / reset |
| `Cmd+L` | Focus browser address bar |
| `Cmd+[` / `Cmd+]` | Browser back / forward |
| `Alt+Cmd+I` | Open Web Inspector on the focused browser column |

When a shell exits, its terminal shows a restart overlay — press `Enter` to respawn it (scrollback is preserved).

Column widths are freeform: drag the divider between columns to resize (double-click resets to half), or use `Cmd+E` to snap through presets. `Cmd+click` a web URL in a terminal to open it as a browser column in the same workspace; file links open in the editor, while other supported schemes use their macOS handler.

Creating a workspace with `Cmd+N` asks for its task name. Double-click a workspace card in the sidebar, or use `Rename Workspace`, to change that name later.

### Agent status hooks

Nirux installs lightweight lifecycle hooks so agent status is exact instead of guessed from terminal output:

- `~/.claude/settings.json` gains `hooks` entries invoking `Nirux --hook claude` on session start, prompt submit, tool use, notification, stop, and session end. Existing hooks are preserved; the entries refresh themselves on every launch.
- `~/.codex/config.toml` gains a `notify` entry invoking `Nirux --hook codex` on completed turns (left untouched if you already have your own `notify`).

Each event carries the column's stable `NIRUX_AGENT_UUID`, so status and attention signals are attributed to the exact column that emitted them — across restarts. Agents launched outside Nirux (or before the hooks were installed) fall back to simple output-activity detection. To remove the hooks, delete the marked entries from those two files.

### Telegram Remote Access

Telegram Remote Access is disabled by default. It uses outbound Bot API `getUpdates` long polling, so Nirux does not open a listening port and you do not need a public webhook. Nirux and the Mac must remain running and online for the bot to respond.

Set it up with a dedicated bot:

1. Create a bot with Telegram's `@BotFather` and copy its token.
2. Open **Nirux → Settings**, enable **Telegram Remote Access**, paste the token, choose the notification preferences, and click **Generate Pairing Code**.
3. Open a private chat with that bot and send `/pair CODE` using the one-time code shown in Settings. Codes expire after 10 minutes.
4. Send `/sessions`, choose a live agent, then send ordinary text as a prompt. You can also reply directly to a completion or attention notification.

Supported commands:

- `/sessions` — list and select recognized live agent sessions.
- `/status` — show the selected session's workspace, column, state, and directory.
- `/tail` — show a bounded plain-text tail of recent terminal output.
- `/help` — show the command summary.

The bot token is stored as a generic password in macOS Keychain, never in `state.json`. Nirux persists only non-secret preferences, the paired Telegram user/chat IDs, and the last consumed update ID. Messages from every other user or chat are ignored. There is deliberately no `/exec`: prompts are routed by stable column UUID and injected only after Nirux re-verifies that a recognized agent process—not an idle shell—is currently live in that column. Clearing the token disables Remote Access and removes the pairing.

## Worktrees And URL Scheme

Nirux registers the `nirux://` URL scheme in bundled builds.

Open a new workspace:

```text
nirux://new-workspace?cwd=/path/to/project&title=my-task&agent=claude
```

Create a Git worktree and open it as a workspace:

```text
nirux://new-worktree?branch=feat/example&repo=/path/to/repo&agent=codex&handover=/tmp/context.md&profile=default
```

Supported agents are `claude` and `codex`. The optional `profile` query parameter targets the Nirux session/space that should receive the new workspace; Nirux terminals expose it as `NIRUX_PROFILE_ID` for the worktree skill. When a handover file is provided, Nirux moves it into the new worktree as `.claude-handover.md` or `.codex-handover.md`, then launches the selected agent with a prompt to read it.

When Mission handoffs are enabled, the optional `parentWorkspace` and `parentAgent` query parameters identify the delegating Nirux workspace and terminal by UUID. Supplying both creates the parent/child Mission record; the bundled `nirux-worktree` skill adds them automatically. See [Mission handoffs](#mission-handoffs-experimental) for the user workflow.

Open a file in the editor column at a line range (used by agents to show code instead of pasting it into the terminal):

```text
nirux://open-editor?file=/path/to/file.swift&line=42&endLine=57&workspace=<NIRUX_WORKSPACE_ID>
```

`file` must be an absolute, URL-encoded path to an existing regular text file of at most 5 MB (binaries are refused; symlinks are resolved). `line` and `endLine` are optional 1-based line numbers; when both are present the editor highlights the whole range. `workspace` is optional — when it matches a workspace ID (Nirux terminals expose it as `NIRUX_WORKSPACE_ID`), Nirux switches to that workspace first. The open never pops dialogs; Nirux comes to the front, but keyboard focus stays in the column the user was working in — it never lands in the editor buffer.

The command palette action `Install Agent Skills` writes the bundled skills to:

```text
~/.agents/skills/nirux-worktree/SKILL.md
~/.agents/skills/nirux-show-code/SKILL.md
~/.claude/skills/nirux-worktree/SKILL.md
~/.claude/skills/nirux-show-code/SKILL.md
```

`nirux-worktree` lets supported agents open isolated Nirux workspaces when the user asks to start work on a feature, bug, or separate branch. `nirux-show-code` teaches agents to open code in the editor column via `nirux://open-editor` when the user asks to see code.

## Local Development

Build the Swift package:

```bash
swift build
```

Run tests:

```bash
swift test
```

Run from SwiftPM:

```bash
swift run Nirux
```

Create a local app bundle:

```bash
swift build -c release
./scripts/bundle.sh "dev" "1"
```

By default `bundle.sh` uses ad-hoc signing. To create a Developer ID-signed bundle locally:

```bash
NIRUX_CODESIGN_IDENTITY="Developer ID Application: Example Name (ABCDE12345)" \
  ./scripts/bundle.sh "dev" "1"
```

## Architecture

Nirux is a Swift Package with an AppKit executable target:

- `Sources/Nirux/NiruxApp.swift`: app delegate, menus, URL scheme, Sparkle setup.
- `Sources/Nirux/Views/NiruxShellView.swift`: workspace and column layout.
- `Sources/Nirux/Model`: persisted workspace, column, and settings state.
- `Sources/Nirux/Content`: PTY session handling and browser cookie import.
- `Sources/Nirux/EditorAssets`: Monaco editor assets copied into release bundles.
- `Resources/Info.plist`: bundle metadata, Sparkle feed, public key, and URL scheme.

Primary dependencies:

- `GhosttyTerminal` via `libghostty-spm` for terminal rendering.
- `Sparkle` for automatic updates.
- Monaco editor assets embedded as package resources.

## State And Local Files

Nirux writes user state under:

```text
~/Library/Application Support/nirux/
```

That directory contains workspace state, Activity and Mission history, URL history, generated helper scripts, and optional tool installs. Local agent state, generated build output, release archives, and signing assets are intentionally ignored by git. Keep `.desloppify/`, `.claude/`, `.build/`, `.env*`, certificates, provisioning profiles, and app archives out of commits.

## Release Pipeline

The nightly GitHub Actions workflow runs on pushes to `main` and on manual dispatch. It:

1. Runs the test suite.
2. Builds the release binary.
3. Bundles `Nirux.app`.
4. Signs with the Developer ID Application identity.
5. Submits to Apple notarization and staples the result.
6. Re-zips the app.
7. Signs the update archive for Sparkle.
8. Publishes `Nirux.app.zip` and `appcast.xml` to the `nightly` release, with a changelog generated from the commits since the previous nightly.

Sparkle reads updates from:

```text
https://github.com/xikimay/nirux/releases/download/nightly/appcast.xml
```

Signing and notarization setup is documented in [docs/release-signing.md](docs/release-signing.md).

## License

Nirux is available under the MIT License.
