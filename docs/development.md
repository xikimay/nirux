# Development

Nirux is a Swift package with one AppKit executable target. It runs on macOS 14 or later. Building needs Swift 6.2 or later; CI uses Xcode 26.3 on macOS 15.

## Build, test, run

```bash
swift build
swift test
NIRUX_STATE_DIR=/tmp/nirux-dev swift run Nirux
```

CI runs the tests one process per test class, several at a time:

```bash
swift build --build-tests && scripts/run-tests.sh
```

## Development builds and your real workspaces

Only the installed app opens your workspaces: `/Applications/Nirux.app`, or `~/Applications/Nirux.app` when `/Applications` has none. Any other copy (`swift run`, `.build/debug/Nirux`, a `bundle.sh` bundle, a download run from elsewhere) quits unless `NIRUX_STATE_DIR` is set. It says why on stderr, and in an alert when Finder, the Dock, `open` or a `nirux://` link started it.

Any copy, the installed app included, opens with no argument, or with `-Key value` defaults only (such as `-IgnoreGhosttyConfig YES`). Any other argument that none of its command-line modes (`--hook`, `--mission`, the release checks) takes prints the usage and exits with status 2: on stderr, or in an alert when Finder, the Dock or `open` started it. `--help` prints the usage. An agent guessing a command can't start a second Nirux this way.

One Nirux runs per state folder. A second one started on the same folder (the binary run from a terminal, `open -n`, `open` on the binary) waits a few seconds in case the first is quitting, then brings it to the front and quits before reading anything. The lock is `app.lock` in the state folder, and it goes with the process, a crash included. A copy on `NIRUX_STATE_DIR` has its own folder, so it runs beside the installed app.

Delete old `Nirux.app` bundles left in checkouts. macOS may still hand them `nirux://` links, and a bundle built before this check existed doesn't have it.

## Environment variables

| Variable | Effect |
| --- | --- |
| `NIRUX_STATE_DIR` | Moves workspaces, settings, Mission history, URL history and agent hook events out of `~/Library/Application Support/nirux/`. The `nirux://` scheme stays shared with the installed app |
| `NIRUX_ALLOW_REAL_STATE=1` | Lets another copy use the real state. It then restores and saves the installed app's workspaces and relaunches their agent sessions, even while the installed app runs |
| `NIRUX_SKIP_HOOK_INSTALL=1` | Stops any build from writing the status hooks and from updating the agent skills at launch. Set it when launching a local bundle, which would otherwise point the global hooks at itself |
| `NIRUX_FORCE_HOOK_INSTALL=1` | Makes a development build install the hooks, to test the installer. The global hooks then point at the dev binary until the installed app is relaunched |

Only a Nirux running from an `.app` bundle installs the [status hooks](agent-status.md#status-hooks), so `swift run` leaves `~/.claude/settings.json` and `~/.codex/config.toml` alone. The hooks the installed app wrote keep working, and agents in the dev build's terminals report into its own state directory.

## The sidebar's log

Rows of tasks that were gone have been seen to stay in the sidebar until a click or a pass over the list. To tell what was behind, the installed app writes one line to the system log when the pointer comes back to the sidebar after two seconds away (a move, a press, a scroll or a right-click, before it acts), and when Nirux comes to the front. The line holds counts, `0`/`1` flags and seconds the Mac was awake: no title, no path, no text.

```sh
log show --last 1h --predicate 'process == "Nirux" AND subsystem == "com.xikimay.nirux" AND category == "sidebar"'
```

| Fields | What they say |
| --- | --- |
| `store`, `held`, `same` | The tasks the store lists, those the sidebar holds, and whether they are the same, in the same order, each archived or not. `same=0`: the list was behind, and `drag`, `deferred`, `refresh` and `heartbeat` say what held it |
| `stray`, `nolayer`, `leftover`, `ghosts` | Layers that back no view, views whose layer isn't attached yet (AppKit attaches it at its next display pass), views a rebuild left behind, pictures of rows that left that may still show (their fold's animation is still on them, or they aren't transparent). Above 0: the rows were behind the list. A fold takes under half a second: `ghosts` with a `rebuild` older than that is a picture of a gone row still drawn |
| `wake`, `unlock`, `session`, `front`, `uncovered` | Seconds since the display woke, the screen was unlocked, the macOS session came back, Nirux came to the front (on a `front` line, the time before) and its window was uncovered (shown again after it was covered, minimized or on a display that slept); `-` for not since launch. With the rest in order, the screen was behind, or something the line doesn't count: these say after what |

## App bundle

```bash
swift build -c release
./scripts/bundle.sh "dev" "1"
```

`bundle.sh` signs ad hoc by default. For a Developer ID signature:

```bash
NIRUX_CODESIGN_IDENTITY="Developer ID Application: Example Name (ABCDE12345)" \
  ./scripts/bundle.sh "dev" "1"
```

[Release signing](release-signing.md) covers the nightly workflow, notarization and rollbacks.

## The diff bundle

`Sources/Nirux/EditorAssets/pierre-diff.bundle.js` draws the editor's diffs with [`@pierre/diffs`](https://www.npmjs.com/package/@pierre/diffs). It is built from `Web/pierre-diff` and committed, because CI doesn't build JavaScript. After changing the wrapper `pierre-diff-entry.js`, rebuild the bundle with Node.js and npm:

```bash
Web/pierre-diff/build.sh
```

- To change a dependency's version, run `npm install --save-exact <package>@<version>` in `Web/pierre-diff` first. `build.sh` installs with `npm ci`, which refuses a `package.json` and a lock that disagree.
- `build.sh` records the SHA-256 of the sources and of the bundle in `Web/pierre-diff/SHA256SUMS`. `PierreDiffBundleTests` fails when they no longer match, so a pull request that only updates the lock fails until `build.sh` runs on its branch.
- `Web/pierre-diff/build.sh --check` rebuilds to a temporary file and says whether the committed bundle is what the sources build.

## Where things are

| Path | What |
| --- | --- |
| `Sources/Nirux/NiruxApp.swift` | App delegate and launch. The `NiruxApp+*.swift` files hold menus, settings, updates and the `nirux://` routing |
| `Sources/Nirux/Views/NiruxShellView.swift` | Workspace and column layout |
| `Sources/Nirux/Model` | Persisted workspace, column and settings state, and the features' logic |
| `Sources/Nirux/Content` | Terminal sessions (PTY) and browser cookie import |
| `Sources/Nirux/EditorAssets` | The Monaco editor, the Branch Review page and the diff bundle |
| `Web/pierre-diff` | Source and build script of the diff bundle |
| `Resources/Info.plist` | Bundle metadata, the Sparkle feed and key, the URL scheme |
| `docs/design` | [Design records](README.md#design-records) of the features |

Dependencies: libghostty-spm for terminal rendering, for now from the fork and revision that `Package.swift` pins (upstream is [Lakr233/libghostty-spm](https://github.com/Lakr233/libghostty-spm)), and [Sparkle](https://github.com/sparkle-project/Sparkle) for updates. Monaco is embedded as a package resource.
