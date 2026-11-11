# Development

Nirux is a Swift package with one AppKit executable target. Building needs macOS 14 or later and Swift 6.2 or later.

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

## A development build never opens your real workspaces

Only the installed app opens your workspaces: `/Applications/Nirux.app`, or `~/Applications/Nirux.app` when `/Applications` has none. Any other copy (`swift run`, `.build/debug/Nirux`, a `bundle.sh` bundle, a download run from elsewhere) quits unless `NIRUX_STATE_DIR` is set. It says why on stderr, and in an alert when Finder, the Dock, `open` or a `nirux://` link started it.

Copies built before this check existed aren't covered. Delete old `Nirux.app` bundles: macOS may still hand them `nirux://` links.

## Environment variables

| Variable | Effect |
| --- | --- |
| `NIRUX_STATE_DIR` | Moves workspaces, settings, Mission history, URL history and agent hook events out of `~/Library/Application Support/nirux/`. The `nirux://` scheme stays shared with the installed app |
| `NIRUX_ALLOW_REAL_STATE=1` | Lets another copy use the real state. It then restores and saves the installed app's workspaces and relaunches their agent sessions, even while the installed app runs |
| `NIRUX_SKIP_HOOK_INSTALL=1` | No build writes the agent hooks or rewrites the agent skills. Set it when launching a local bundle, which would otherwise point the global hooks at itself |
| `NIRUX_FORCE_HOOK_INSTALL=1` | Makes a development build install the hooks, to test the installer. The global hooks then point at the dev binary until the installed app is relaunched |

Only a Nirux running from an `.app` bundle installs the [agent hooks](agents.md#status-hooks), so `swift run` leaves `~/.claude/settings.json` and `~/.codex/config.toml` alone. The hooks the installed app wrote keep working, and agents in the dev build's terminals report into its own state directory.

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

`Sources/Nirux/EditorAssets/pierre-diff.bundle.js` draws the editor's diffs with [`@pierre/diffs`](https://www.npmjs.com/package/@pierre/diffs). It is built from `Web/pierre-diff` and committed, because CI doesn't build JavaScript. After changing the wrapper `pierre-diff-entry.js`, rebuild it with Node.js and npm:

```bash
Web/pierre-diff/build.sh
```

- To change a dependency's version, run `npm install --save-exact <package>@<version>` in `Web/pierre-diff` first: `build.sh` installs with `npm ci`, which refuses a `package.json` and a lock that disagree.
- `build.sh` records the SHA-256 of the sources and of the bundle in `Web/pierre-diff/SHA256SUMS`. `PierreDiffBundleTests` fails when they no longer match, so a pull request that only updates the lock fails until `build.sh` runs on its branch.
- `Web/pierre-diff/build.sh --check` rebuilds to a temporary file and says whether the committed bundle is what the sources build.

## Where things are

| Path | What |
| --- | --- |
| `Sources/Nirux/NiruxApp.swift` | App delegate and launch; the `NiruxApp+*.swift` files hold menus, settings, updates and the `nirux://` routing |
| `Sources/Nirux/Views/NiruxShellView.swift` | Workspace and column layout |
| `Sources/Nirux/Model` | Persisted workspace, column and settings state, and the features' logic |
| `Sources/Nirux/Content` | Terminal sessions (PTY) and browser cookie import |
| `Sources/Nirux/EditorAssets` | The Monaco editor, the Branch Review page and the diff bundle |
| `Web/pierre-diff` | Source and build script of the diff bundle |
| `Resources/Info.plist` | Bundle metadata, the Sparkle feed and key, the URL scheme |
| `docs/design` | [Design records](README.md#design-records): why each feature is the way it is |

Dependencies: [libghostty-spm](https://github.com/Lakr233/libghostty-spm) for terminal rendering, at the revision `Package.swift` pins, and [Sparkle](https://github.com/sparkle-project/Sparkle) for updates. Monaco is embedded as a package resource.

## State on disk

Nirux writes user state under `~/Library/Application Support/nirux/`: workspaces, settings, Mission history, URL history and generated helper scripts.

Keep `.claude/`, `.build/`, `.env*`, certificates, provisioning profiles and app archives out of commits; `.gitignore` already lists them.
