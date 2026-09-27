# Nirux

Nirux is a native macOS workspace for supervising terminal-based coding agents. It keeps agent terminals, a browser, source files, diffs, Git status, and workspace context in one persistent AppKit window so long-running Claude Code or Codex sessions stay visible and resumable.

Nirux is alpha software.

## Highlights

- Persistent workspaces: keep each task's name and context visible, stack workspaces vertically, and archive inactive ones in a collapsible sidebar section that does not poll GitHub.
- Horizontal columns: mix Ghostty-backed terminals, WKWebView browser columns, and Monaco editor columns in the same workspace. `Cmd+F` in a terminal searches its scrollback with Ghostty's native search, highlighting every match.
- Agent launchers: start Claude Code or Codex from the command palette with configurable permission and sandbox presets.
- Attention and Activity: per-column agent status (working / needs attention, with elapsed time) driven by real Claude Code hooks and Codex turn notifications — not output guessing — plus a persistent sidebar feed, edge glows for off-screen attention, native macOS notifications that focus the right workspace and column on click, and a Dock badge counting waiting workspaces.
- Claude context usage: a Claude column's title bar shows how full its session's context window is (`ctx 62%`, or `ctx 124k` while the window size is unknown), with the session's token totals in a tooltip — read from the session transcript, see [Claude context usage](#claude-context-usage).
- Opt-in Telegram Remote Access: pair one private Telegram user to list live agent sessions, inspect status and recent output, receive completion/attention alerts, and continue a selected session without exposing a webhook or general-purpose shell.
- Worktree flow: create or open Git worktrees as new workspaces, optionally handing context from the current agent session into the new workspace.
- Built-in editor: open files, keep tabs, search the workspace, browse the file tree with Finder icons, view Git changes, and toggle file diffs. Find/replace, word wrap, font zoom, per-tab scroll restore, and disk-conflict protection included.
- Browser context: open URLs in app, keep URL history, import cookies from Chrome, Brave, Arc, or Edge into the shared WebKit data store, download files to ~/Downloads, and inspect pages with the Web Inspector.
- Pilot mode: switch to a compact overview of active workspaces with branch, column, diff, PR, CI, and review state where available.
- Session restore: workspace layout, editor tabs, browser URLs, sidebar state, detected Claude/Codex launch modes, and verified Claude session / Codex thread IDs are saved under Application Support, with rotating backups for corruption recovery. Each agent column resumes its own conversation by exact ID (`claude --resume <id>`, `codex resume <id>`) in the directory it ran in; a Claude session that was never prompted restarts fresh, and legacy, missing, malformed, or duplicate IDs open the agent's interactive resume picker instead of guessing the last session. A `claude -p` launched by a column's agent, or a `codex exec` launched by a Claude column, keeps its own session and doesn't drive that column's status, notifications, or restore.

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

A workspace is a persistent task context: it has a current directory, a short title, optional task notes, and a horizontal strip of columns. Columns can be terminals, browser tabs, or editor views. Workspaces are stacked vertically, so you can keep several tasks alive without mixing their terminals, files, and browser context.

On first launch, Nirux opens the sidebar on a **Getting Started** checklist, shown below the workspaces. It never blocks the app, and it covers:

- whether `claude` or `codex` is installed where a Nirux terminal finds it, with copyable install commands (Claude Code's native installer, Homebrew for Codex) and a **Check again** link otherwise. Nirux reads the terminal `PATH` and the usual per-user install locations (`~/.local/bin`, the npm prefix from `~/.npmrc`, nvm, fnm, Volta, asdf, mise, Nix profiles) without running your shell's startup files, so a CLI installed elsewhere shows as missing: close the card if you already have one;
- whether the bundled Agent Skills are installed and match this version, with an **Install**/**Update** button;
- whether the [agent status hooks](#agent-status-hooks) are present in `~/.claude/settings.json` and `~/.codex/config.toml`;
- the main shortcuts: `Cmd+P` palette, `Cmd+T` column, `Cmd+N` workspace, `Cmd+O` Pilot Mode.

Close it with `×` (or **Done** once every step is done); the choice is saved with your settings. Reopen it anytime with `Show Getting Started` from the command palette. Installs that already had workspaces before the checklist existed don't show it on their own.

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

With Mission handoffs enabled, worktrees opened by the installed skill can send correlated questions and wait for answers, while the parent agent can receive and reply from its terminal. Each wait lasts at most 90 seconds, under the default 2-minute limit of Claude Code's shell tool, then exits with status 3; running the identical `ask` again resumes the same question instead of sending a duplicate. Once a Mission has ended, `ask` and `completed` exit with status 4 so the child stops retrying. Questions and explicit completion results also appear in the Activity section of the expanded sidebar and in native notifications while Nirux is in the background. Click a question in Activity to reply or open its child workspace.

Mission completion is always reported explicitly by the child agent. Nirux does not infer completion from a stopped turn and does not inject replies into a terminal. Worktrees opened without Mission metadata keep the existing handover behavior.

Typical command palette actions:

- Install Agent Skills
- Show Getting Started
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
- Show/Hide Sidebar
- Rename Workspace
- Resize Column (Cycle Width)
- Toggle Web Inspector
- Open Settings

Useful shortcuts:

| Shortcut | Action |
| --- | --- |
| `Cmd+P` | Command palette (fuzzy matching); in the editor, the workspace file picker |
| `Shift+Cmd+P` | Command palette, including from the editor |
| `Cmd+T` | New terminal column |
| `Cmd+B` | Open browser URL flow |
| `Cmd+W` | Close editor tab, column, or workspace depending on context — asks first when a Claude or Codex session is running (Return cancels, ⌘D closes); with Settings or a detached Web Inspector in front, closes that window instead |
| `Cmd+1…9` | Focus column N |
| `Cmd+Left` / `Cmd+Right` | Focus previous or next column |
| `Shift+Cmd+Left` / `Shift+Cmd+Right` | Move the focused column |
| `Cmd+E` | Cycle focused column width through presets |
| `Cmd+N` | New workspace |
| `Cmd+Up` / `Cmd+Down` | Switch workspace |
| `Alt+Cmd+Left` / `Alt+Cmd+Right` | Switch to the previous or next space (the workspace group named in the sidebar header) |
| `Cmd+O` | Toggle Pilot Mode |
| `Ctrl+Cmd+S` | Toggle sidebar |
| `Ctrl+Cmd+F` | Enter or exit full screen |
| `Cmd+M` | Minimize the window |
| `Cmd+,` | Settings |
| `Cmd+Z` / `Shift+Cmd+Z` | Undo / redo in the editor and in panel text fields (palette, rename, settings) |
| `Shift+Cmd+F` | Search workspace |
| `Cmd+F` | Find in the focused editor or terminal; a terminal's find bar closes with `Esc` |
| `Cmd+G` / `Shift+Cmd+G` | Next / previous terminal match (`Return` / `Shift+Return` in the find bar); next moves up to older output, as in Ghostty |
| `Cmd+S` / `Alt+Cmd+S` | Save the active editor file / save all |
| `Shift+Cmd+D` | Toggle editor diff |
| `Alt+Cmd+Z` | Toggle word wrap in editor |
| `Shift+Cmd+M` | Toggle minimap in editor |
| `Alt+Cmd+Return` | Send the editor selection to the agent terminal |
| `Cmd+=` / `Cmd+-` / `Cmd+0` | Editor font zoom in / out / reset |
| `Cmd+L` | Focus browser address bar |
| `Cmd+[` / `Cmd+]` | Browser back / forward |
| `Alt+Cmd+I` | Open Web Inspector on the focused browser column |

When a shell exits, its terminal shows a restart overlay — press `Enter` to respawn it (scrollback is preserved).

Column widths are freeform: drag the divider between columns to resize (double-click resets to half), or use `Cmd+E` to snap through presets. `Cmd+click` a web URL in a terminal to open it as a browser column in the same workspace; file links open in the editor, while other supported schemes use their macOS handler.

Creating a workspace with `Cmd+N` asks for its task name. Double-click a workspace card in the sidebar, or use `Rename Workspace`, to change that name later.

Use the `⋯` menu on a workspace card and choose `View/Edit Context…` to keep the longer purpose separate from its short title, choose an automatic or manual phase, and record the latest meaningful summary, next step, or blocker. The compact card always shows the effective phase and agent-activity recency, then adds the optional context rows you have populated. Automatic phase follows blocker, agent, archive, and pull-request state. Codex turn completions can update the summary until you edit it; clearing a manual summary resumes automatic updates. The same panel shows the focused path plus Git, diff, pull-request, and agent state as read-only live context. Context fields persist with the workspace across relaunches.

### Agent status hooks

Nirux installs lightweight lifecycle hooks so agent status is exact instead of guessed from terminal output:

- `~/.claude/settings.json` gains `hooks` entries invoking `Nirux --hook claude` on session start, prompt submit, tool use, notification, stop, and session end. Existing hooks are preserved; the entries refresh themselves on every launch.
- `~/.codex/config.toml` gains a `notify` entry invoking `Nirux --hook codex` on completed turns (left untouched if you already have your own `notify`).

Each event carries the column's stable `NIRUX_AGENT_UUID`, so status and attention signals are attributed to the exact column that emitted them — across restarts. Agents launched outside Nirux (or before the hooks were installed) fall back to simple output-activity detection. To remove the hooks, delete the marked entries from those two files.

Both files are global, so every Claude Code and Codex session on the Mac runs these hooks. They are guarded on `NIRUX_AGENT_UUID`, which Nirux terminals set and processes started from them inherit: a session without it stops at a shell test and never launches Nirux, and Nirux ignores any event that arrives without it. Symlinked config files (dotfiles) are updated in place; the link is kept.

### Claude context usage

The title bar of a column running Claude Code shows the context of its session's latest response — input, cache-write and cache-read tokens, as Claude Code counts it — as `ctx 62%` of the context window, turning orange from 80%. Hover it for the exact count, the model, and the session's token totals (output, input, cache read, cache write). There is no cost estimate.

Nirux learns the session's transcript from the `transcript_path` of the [agent status hooks](#agent-status-hooks) (session start, prompt submit, stop) and follows it read-only: only what was appended since the last read, off the main thread, about once a second for columns on screen, keeping token counts and the model ID but never message content. The label shows only while that session's own `claude` is the column's foreground process; subagents, nested `claude -p` runs and other sessions are ignored.

Claude Code picks a 200k or 1M window depending on the model variant, the account and the provider, and the transcript doesn't record which. Until a response goes past 200k tokens, which proves the 1M window, the label shows the token count instead (`ctx 124k`). Right after a compaction it shows `ctx —` until the next response. Codex columns show nothing.

### Telegram Remote Access

Telegram Remote Access is disabled by default. It uses outbound Bot API `getUpdates` long polling, so Nirux does not open a listening port and you do not need a public webhook. Nirux and the Mac must remain running and online for the bot to respond.

Set it up with a dedicated bot:

1. Create a bot with Telegram's `@BotFather` and copy its token.
2. Open **Nirux → Settings**, enable **Telegram Remote Access**, paste the token, choose the notification preferences, and click **Generate Pairing Code**.
3. Open a private chat with that bot and send `/pair CODE` using the one-time code shown in Settings. Codes expire after 10 minutes.
4. Send `/sessions`, choose a live agent, then send ordinary text as a prompt. You can also reply directly to a recent completion or attention notification; if its route has expired, use `/sessions` to select the agent again.

Supported commands:

- `/sessions` — list and select recognized live agent sessions.
- `/status` — show the selected session's workspace, column, state, and directory.
- `/tail` — show a bounded plain-text tail of recent terminal output.
- `/help` — show the command summary.

The bot token is stored as a generic password in macOS Keychain, never in `state.json`. Nirux persists only non-secret preferences, the paired Telegram user/chat IDs, and the last consumed update ID. Once pairing is complete, messages from every other user or chat are ignored. There is deliberately no `/exec`: prompts are routed by stable column UUID and injected only after Nirux re-verifies that a recognized agent process—not an idle shell—is currently live in that column. Clearing the token disables Remote Access and removes the pairing.

### Terminal appearance (Ghostty config)

Terminals follow the appearance settings of your Ghostty configuration. Nirux reads the same files as Ghostty, in the same order: `$XDG_CONFIG_HOME/ghostty/config` and `config.ghostty` (`~/.config` when `XDG_CONFIG_HOME` is unset), then `config` and `config.ghostty` in `~/Library/Application Support/com.mitchellh.ghostty/`, then any `config-file` includes.

Only appearance keys are honored:

- fonts: `font-family*`, `font-style*`, `font-feature`, `font-variation*`, `font-codepoint-map`, `font-synthetic-style`, `font-size`, `font-thicken*`, `font-shaping-break`, and the `adjust-*` cell metrics;
- colors: `theme`, `background`, `foreground`, `palette`, `palette-generate`, `palette-harmonious`, `bold-color`, `minimum-contrast`, `faint-opacity`, `alpha-blending`, `window-colorspace`, `selection-*` and `search-*` colors, and the deprecated `bold-is-bright`, `cursor-invert-fg-bg`, and `selection-invert-fg-bg`;
- cursor: `cursor-color`, `cursor-text`, `cursor-opacity`, `cursor-style`, `cursor-style-blink`.

Everything else, including keybinds, window and macOS options, padding, opacity, and shell or command settings, is ignored: Nirux handles input, layout, and shells itself. Settings you don't set keep Nirux's defaults: 14pt, a blinking block cursor, and the Afterglow palette. If you set your own `background` or `foreground`, Afterglow's cursor and selection colors are dropped too, so they stay visible against your colors.

`theme` accepts a theme name, an absolute path, or a `light:…,dark:…` pair. Nirux always uses the dark variant, because its window is always dark. Names are looked up in `$XDG_CONFIG_HOME/ghostty/themes` (`~/.config/ghostty/themes` by default), then in the themes bundled with Ghostty.app when it is installed. A theme that can't be found is ignored. Only the theme's appearance settings are used. As in Ghostty, a theme overrides the defaults, and your explicit settings override the theme. Nirux's default colors are left out as soon as the theme contributes any setting.

Invalid lines, in your config or in its theme, are skipped individually instead of invalidating the whole config; look for `[GhosttyConfig]` messages in Console.app.

The configuration is read each time a terminal opens, so a change applies to terminals you open afterwards. Terminals that are already open keep their settings.

To make Nirux ignore your Ghostty configuration, run `defaults write com.xikimay.nirux IgnoreGhosttyConfig -bool true` (`defaults delete com.xikimay.nirux IgnoreGhosttyConfig` undoes it).

## Worktrees And URL Scheme

Nirux registers the `nirux://` URL scheme in bundled builds.

Open a new workspace:

```text
nirux://new-workspace?cwd=/path/to/project&title=my-task&agent=claude&launch=<NIRUX_LAUNCH_ID>
```

Create a Git worktree and open it as a workspace:

```text
nirux://new-worktree?branch=feat/example&repo=/path/to/repo&agent=codex&handover=/tmp/nirux-handover-codex-Ab12Cd&profile=default&launch=<NIRUX_LAUNCH_ID>
```

`repo` is the top level of any checkout of the repository: the main one or a linked worktree. The new worktree goes next to the main checkout and is named after its folder, as `<main folder>.<branch>` with `/` in the branch replaced by `-`: from `repo.feat-a`, `feat/b` becomes `repo.feat-b`, not `repo.feat-a.feat-b`. When git can't tell where the main checkout is (a bare repository, a separate git dir, a submodule), the worktree goes next to `repo` instead. A branch that doesn't exist yet starts from the HEAD of `repo`; one that only exists on the remote tracks `origin/<branch>`. If the branch is already checked out in another linked worktree, Nirux opens that worktree wherever it is, after checking the folder is still that worktree; a branch checked out in the main checkout or in `repo` itself is refused.

Supported agents are `claude` and `codex`. The optional `profile` query parameter targets the Nirux session/space that should receive the new workspace; Nirux terminals expose it as `NIRUX_PROFILE_ID` for the worktree skill. When a handover file is provided, Nirux moves it into the new worktree as `.claude-handover.md` or `.codex-handover.md`, then launches the selected agent with a prompt to read it. The handover must be the user's own regular file directly in `/tmp` with a name starting with `nirux-handover-` (the skill creates it with `mktemp /tmp/nirux-handover-<agent>-XXXXXX`); any other path is ignored and the worktree opens without it. An agent is only told to read a handover that this request delivered, never one that already exists in the folder.

Any app or web page can open a `nirux://` URL, so every action runs without asking only when it carries `launch=` with the current value of `NIRUX_LAUNCH_ID`. Nirux generates that value at each launch and exports it to its terminals; the bundled skills pass it automatically. Without it, or with a value from before Nirux last restarted (for example from inside tmux), Nirux shows a confirmation that spells out the folder or file, branch, agent, and permission mode before doing anything; a confirmed request opens in the space you are looking at and can't link to a Mission. After updating Nirux, run `Install Agent Skills` again so installed skills pass the launch ID.

When Mission handoffs are enabled, the optional `parentWorkspace` and `parentAgent` query parameters identify the delegating Nirux workspace and terminal by UUID. Supplying both creates the parent/child Mission record; the bundled `nirux-worktree` skill adds them automatically. See [Mission handoffs](#mission-handoffs-experimental) for the user workflow.

Open a file in the editor column at a line range (used by agents to show code instead of pasting it into the terminal):

```text
nirux://open-editor?file=/path/to/file.swift&line=42&endLine=57&workspace=<NIRUX_WORKSPACE_ID>&launch=<NIRUX_LAUNCH_ID>
```

`file` must be an absolute, URL-encoded path to an existing regular text file of at most 5 MB (binaries are refused; symlinks are resolved). `line` and `endLine` are optional 1-based line numbers; when both are present the editor highlights the whole range. `workspace` is optional — when it matches a workspace ID (Nirux terminals expose it as `NIRUX_WORKSPACE_ID`), Nirux switches to that workspace first. With a valid `launch=<NIRUX_LAUNCH_ID>` the file opens and Nirux comes to the front without a dialog; without it, Nirux first asks for confirmation (like the other actions), so a web page can't put an arbitrary file on screen. Keyboard focus stays in the column the user was working in — it never lands in the editor buffer.

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

A development build otherwise restores and saves the installed app's workspaces. Isolate smoke runs:

```bash
NIRUX_STATE_DIR=/tmp/nirux-dev swift run Nirux
```

`NIRUX_STATE_DIR` moves workspaces, settings, Activity and Mission history, and agent hook events out of `~/Library/Application Support/nirux/` (`HOME` is ignored). URL history, the Keychain (Telegram token), and the `nirux://` scheme stay shared with the installed app.

Only a Nirux running from an `.app` bundle installs the agent hooks, so `swift run` leaves `~/.claude/settings.json` and `~/.codex/config.toml` alone. The hooks the installed app wrote keep working, and agents in the dev build's terminals report into its state directory. To test installer changes, set `NIRUX_FORCE_HOOK_INSTALL=1`; this points the global hooks at the dev binary until the installed app is relaunched. `NIRUX_SKIP_HOOK_INSTALL=1` disables the install for any build; set it when launching a local `bundle.sh` bundle for a smoke test, which would otherwise point the hooks at that bundle.

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

### Fingerprint mismatch for libghostty-spm

If SwiftPM fails with `Revision be4e5b6… for libghostty-spm … version 1.3.1 does not match previously recorded value b093032…`, your machine recorded the `1.3.1` tag before upstream re-tagged it onto an identical source tree. Clear the stale fingerprint once:

```bash
rm ~/Library/org.swift.swiftpm/security/fingerprints/libghostty-spm-*.json
```

## Architecture

Nirux is a Swift Package with an AppKit executable target:

- `Sources/Nirux/NiruxApp.swift`: app delegate, menus, Sparkle setup; `NiruxApp+URLScheme.swift` routes `nirux://` URLs.
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
8. Publishes `Nirux.app.zip` and `appcast.xml` to an immutable `nightly-YYYY.MM.DD-HHMM-<sha>` release (the 20 most recent are kept) and to the rolling `nightly` release, with a changelog generated from the commits since the previous nightly.

Sparkle reads updates from:

```text
https://github.com/xikimay/nirux/releases/download/nightly/appcast.xml
```

Signing and notarization setup, and how to roll back a broken nightly, are documented in [docs/release-signing.md](docs/release-signing.md).

## License

Nirux is available under the MIT License.
