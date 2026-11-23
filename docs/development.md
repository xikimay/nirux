# Development

The root Swift package builds the AppKit executable and links the local NiruxCore library. It runs on macOS 14 or later. Building needs Swift 6.2 or later; CI uses Xcode 26.3 on macOS 15.

## Build, test, run

```bash
swift build
swift test
scripts/test-core.sh
NIRUX_STATE_DIR=/tmp/nirux-dev swift run Nirux
```

CI runs the app’s XCTest suite one process per test class, several at a time.

```bash
swift build --build-tests && scripts/run-tests.sh
```

An agent waiting on the PR’s Tests workflow can run `scripts/watch-ci-failure.sh <run-id>` from the checkout. It prints the first source-located Swift build error or XCTest assertion as JSON, including the tested checkout, PR head, run and attempt. Match the PR head to the revision you’re working on. The command exits 0 on a successful run with no diagnostic, 1 on a diagnostic or a failed run, 2 when the watcher itself fails (GitHub API errors after retries, or still no verdict after an hour, `NIRUX_CI_WATCH_TIMEOUT` seconds), and 3 when the run was cancelled or replaced by a new attempt. The suite continues and the final checks remain on the PR. Use `gh run list --workflow tests.yml --branch <branch>` to find the run. Other failures still appear in the normal job logs.

Draft pull requests run `test (selected)`. The daily Coverage map workflow records which XCTest classes executed each Swift source file on main. The selector examines all changes since the indexed commit, including changes that landed on main after the map was recorded. It also includes classes declared by changed test files. Shared test helpers, removed test files, uncovered sources, build inputs, and missing or empty selections trigger the full suite. Marking the PR ready and each subsequent push run the full suite under the separate `test` check.

The longest classes start first, in the order `scripts/test-class-times.txt` gives. When classes have grown or new long ones came in, `scripts/test-class-times.sh` rewrites it from main's last green nightly runs.

A new or reworked UI test class passes a flake gate before its pull request is ready. On a pushed branch:

```bash
gh workflow run flake-gate.yml --ref <branch> -f classes="NiruxTests.FooTests" -f runs=10
```

One job builds the branch and runs each class 10 times, each run in its own process, beside the six heaviest classes. It ends with a line like `NiruxTests.FooTests: 10 of 10 runs passed`. After a local build, `scripts/run-tests.sh --repeat 10 NiruxTests.FooTests` does the same.

## NiruxCore

Put policy that only needs core types in `NiruxCore/Sources/NiruxCore` and its Swift Testing cases in `NiruxCore/Tests/NiruxCoreTests`. AppKit and Ghostty adapters stay in the app. Policies that still depend on app models can live in `Sources/Nirux/Model` and use the core API through the app’s re-export.

Run `scripts/test-core.sh` from the root or `../scripts/test-core.sh` inside `NiruxCore`. The script builds the independent package and locates the active toolchain’s Swift Testing macros, including with the macOS Command Line Tools. With Xcode, `swift test` inside the package runs the same suite. From the root, `swift test` runs the app tests, which require Xcode.

Run `scripts/check-core-boundary.sh` to check for UI imports in NiruxCore and typecheck Model, Util and GitHub against the core module. The remaining app exceptions are listed in `scripts/core-boundary-exceptions.txt`.

## Development builds and your real workspaces

Only the installed app opens your workspaces: `/Applications/Nirux.app`, or `~/Applications/Nirux.app` when `/Applications` has none. Any other copy (`swift run`, `.build/debug/Nirux`, a `bundle.sh` bundle, a download run from elsewhere) quits unless `NIRUX_STATE_DIR` is set. It says why on stderr, and in an alert when Finder, the Dock, `open` or a `nirux://` link started it.

Any copy, the installed app included, opens with no argument, or with `-Key value` defaults only (such as `-IgnoreGhosttyConfig YES`). Any other argument that none of its command-line modes (`--hook`, `--mission`, the release checks) takes prints the usage and exits with status 2: on stderr, or in an alert when Finder, the Dock or `open` started it. `--help` prints the usage. An agent guessing a command can't start a second Nirux this way.

One Nirux runs per state folder. A second one started on the same folder (the binary run from a terminal, `open -n`, `open` on the binary) brings the first to the front and quits before reading anything. If the first can't be brought forward, it says so, in an alert when Finder or the Dock started it. When the first is quitting, the second waits up to five seconds for it. The lock is `app.lock` in the state folder, and it goes with the process, a crash included. A copy on `NIRUX_STATE_DIR` has its own folder, so it runs beside the installed app. A `nirux://` link given to such a second launch (`open -n -a Nirux nirux://…`) is dropped: without `-n`, macOS hands links to the Nirux already running.

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
