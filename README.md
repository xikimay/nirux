# Nirux

Nirux is a native macOS workspace for supervising terminal-based coding agents. It keeps agent terminals, a browser, source files, diffs, Git status, and workspace context in one persistent AppKit window so long-running Claude Code or Codex sessions stay visible and resumable.

Nirux is alpha software.

## Highlights

- Persistent workspaces: stack independent workspaces vertically, each with its own current directory, title, Git branch, focused column, and restored layout.
- Horizontal columns: mix Ghostty-backed terminals, WKWebView browser columns, and Monaco editor columns in the same workspace.
- Agent launchers: start Claude Code or Codex from the command palette with configurable permission and sandbox presets.
- Worktree flow: create or open Git worktrees as new workspaces, optionally handing context from the current agent session into the new workspace.
- Built-in editor: open files, keep tabs, search the workspace, browse the file tree, view Git changes, and toggle file diffs.
- Browser context: open URLs in app, keep URL history, and import cookies from Chrome, Brave, Arc, or Edge into the shared WebKit data store.
- Pilot mode: switch to a compact overview of active workspaces with branch, column, diff, PR, CI, and review state where available.
- Session restore: workspace layout, editor tabs, browser URLs, and detected Claude/Codex launch modes are saved under Application Support.

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
4. Run `Install Worktree Skill` before starting agent work. You only need to do this once.
5. Launch Claude Code or Codex from the palette.
6. Ask the agent to start a feature, bugfix, or investigation in a separate workspace.

After the skill is installed, supported agents know how to hand work back to Nirux. When you ask for a separate task, the agent writes a short handover file and opens `nirux://new-worktree`. Nirux creates the Git worktree, moves the handover into it, opens a new workspace pointed at that worktree, and launches the same agent there.

That leaves your main workspace on the original checkout while each isolated branch gets its own Nirux workspace.

Typical command palette actions:

- Install Worktree Skill
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
| `Cmd+P` | Command palette |
| `Cmd+T` | New terminal column |
| `Cmd+B` | Open browser URL flow |
| `Cmd+W` | Close editor tab, column, or workspace depending on context |
| `Cmd+Left` / `Cmd+Right` | Focus previous or next column |
| `Shift+Cmd+Left` / `Shift+Cmd+Right` | Move the focused column |
| `Cmd+E` | Cycle focused column width |
| `Cmd+N` | New workspace |
| `Cmd+Up` / `Cmd+Down` | Switch workspace |
| `Cmd+O` | Toggle Pilot Mode |
| `Cmd+S` | Toggle sidebar |
| `Shift+Cmd+F` | Search workspace |

## Worktrees And URL Scheme

Nirux registers the `nirux://` URL scheme in bundled builds.

Open a new workspace:

```text
nirux://new-workspace?cwd=/path/to/project&title=my-task&agent=claude
```

Create a Git worktree and open it as a workspace:

```text
nirux://new-worktree?branch=feat/example&repo=/path/to/repo&agent=codex&handover=/tmp/context.md
```

Supported agents are `claude` and `codex`. When a handover file is provided, Nirux moves it into the new worktree as `.claude-handover.md` or `.codex-handover.md`, then launches the selected agent with a prompt to read it.

The command palette action `Install Worktree Skill` writes a local `nirux-worktree` skill to:

```text
~/.agents/skills/nirux-worktree/SKILL.md
~/.claude/skills/nirux-worktree/SKILL.md
```

That lets supported agents open isolated Nirux workspaces when the user asks to start work on a feature, bug, or separate branch.

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

That directory contains workspace state, URL history, generated helper scripts, and optional tool installs. Local agent state, generated build output, release archives, and signing assets are intentionally ignored by git. Keep `.desloppify/`, `.claude/`, `.build/`, `.env*`, certificates, provisioning profiles, and app archives out of commits.

## Release Pipeline

The nightly GitHub Actions workflow runs on pushes to `main` and on manual dispatch. It:

1. Builds the release binary.
2. Bundles `Nirux.app`.
3. Signs with the Developer ID Application identity.
4. Submits to Apple notarization and staples the result.
5. Re-zips the app.
6. Signs the update archive for Sparkle.
7. Publishes `Nirux.app.zip` and `appcast.xml` to the `nightly` release.

Sparkle reads updates from:

```text
https://github.com/xikimay/nirux/releases/download/nightly/appcast.xml
```

Signing and notarization setup is documented in [docs/release-signing.md](docs/release-signing.md).

## License

Nirux is available under the MIT License.
