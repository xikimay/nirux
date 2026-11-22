# Packaged app canary

`ghostty-monaco-restore` exercises the release bundle on macOS. Run it from an unlocked graphical login with Command Line Tools installed and Accessibility permission for the launching terminal. It takes keyboard focus during the scenario.

```sh
swift build -c release
scripts/bundle.sh 0.0.0 0
scripts/canary.sh Nirux.app --runs 3 --evidence-dir /tmp/nirux-evidence
scripts/canary.sh Nirux.app --inject-failure monaco --evidence-dir /tmp/nirux-injection
scripts/canary.sh --replay /tmp/nirux-evidence/run-001-XXXXXXXX
/usr/bin/python3 -B -m unittest discover -s scripts/canary -v
```

The runner prints each report path as JSON. Use its containing directory for replay, including after downloading a workflow artifact. Each iteration owns a fresh state folder, home, git repo and linked worktree. Replay checks the archived app’s SHA-256 and uses its original fixture seed and injection in a new directory. Use evidence from a trusted build since replay executes its binary.

## What a pass proves

1. The signed, copied bundle launches a real zsh in the synthetic worktree. A PID-targeted keyboard event types a command and the runner verifies its relative file write.
2. Accessibility presses **Columns → Open Editor**. The worktree’s `README.md` is the app’s standard starter file. The driver waits for the focused Monaco text area, types a marker and sends ⌘S. The file must acquire precisely that marker and retain its original text.
3. ⌘1 returns focus to Ghostty. A second shell command must create a different file in the same worktree.
4. ⌘Q must exit with status zero and release the child processes. The saved active workspace must contain its original terminal and its new editor tab. Relaunch uses the same state without reseeding it. A third shell command and a second edit/save through the restored column prove both are usable. The second launch also quits through AppKit.

All input goes to the spawned PID. The driver uses AX to observe the key window and focused editor, and CGEvents for typing and shortcuts. Synchronization waits for the shell prompt, AX state, file contents and process exit. The app runs its normal event loop and persistence path.

## Isolation and evidence

The runner unpacks a copy under `/private/tmp` and launches its executable with the worktree as cwd. The app and fixture git commands start with an explicit environment allowlist. `NIRUX_STATE_DIR` is canonical and private. The temporary home and zsh startup directory, skipped hook installation, empty live-merge override and repo without remotes keep agent and git activity local. Sparkle automatic checks and downloads are disabled for each launch. A macOS sandbox denies outbound IP connections, access to the checkout and SwiftPM build directories, and access to the account’s real Nirux state, Claude and Codex directories. This also covers SwiftPM resource accessors that try an absolute build path.

Each run folder contains the exact signed app in `Nirux.app.zip`, a versioned `manifest.json`, `stdout.log`, `stderr.log` and `report.json`. Failures also retain regular files from synthetic state and the observed README when available. The report records step IDs, elapsed milliseconds, the failed step, preflight observations and an exit code for each app process launched. A negative exit code identifies a signal. A null key-window observation means preflight stopped before launch.

| Verdict | Exit | Meaning |
| --- | --- | --- |
| `pass` | 0 | Every iteration completed the roundtrip. |
| `fail` | 1 | A bundle, scenario or cleanup check failed. |
| `infra_unavailable` | 2 | A display, unlocked console, event permission or focused window was unavailable. |

In a multi-run invocation a failure takes precedence over an infrastructure verdict. The runner traps interrupt, hangup and termination, cleans up, and exits with 128 plus the signal number. The app and its shells hold a run-specific file descriptor, so cleanup can identify a reparented shell without matching a process name. Temporary app copies and fixtures are removed after evidence collection.

Use `--inject-failure preflight` to check failure attribution and replay on a locked machine. For terminal and editor steps, injection sends a wrong marker through the UI and lets the ordinary disk assertion catch it. Other injectable IDs appear in `--help`. An earlier missing prerequisite takes precedence over a later injection.

## Workflow and follow-up work

**Packaged app canary** is a manual Actions workflow. It builds ad hoc, runs the canary and uploads evidence even on failure. A hosted runner without an interactive desktop records an inconclusive result in the job summary. The nightly release workflow runs independently.

The versioned manifest and step IDs provide extension points for follow-up PRs. PR 2 can add scenarios using the same fixture and driver. PR 3 can index reports across runs. PR 4 can schedule the suite on an AX-enabled Mac. PR 5 can introduce a release gate once repeated runs establish reliability.
