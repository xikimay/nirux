# Packaged app canary

Exercises the release `Nirux.app` bundle on macOS in strict isolation against synthetic git worktrees and disposable state. Run from an unlocked graphical login with Command Line Tools installed and Accessibility permission for the launching terminal.

```sh
swift build -c release
scripts/bundle.sh 0.0.0 0

# List registered scenarios and their invariants
scripts/canary.sh --list-scenarios

# Run a specific scenario, all scenarios, or diff-targeted scenarios
scripts/canary.sh Nirux.app --scenario ghostty-monaco-restore --evidence-dir /tmp/nirux-evidence
scripts/canary.sh Nirux.app --scenario multi-agent-routing --evidence-dir /tmp/nirux-multi
scripts/canary.sh Nirux.app --scenario sidebar-breakpoints --evidence-dir /tmp/nirux-sidebar
scripts/canary.sh Nirux.app --scenario all --triage --evidence-dir /tmp/nirux-suite
scripts/canary.sh Nirux.app --diff-base origin/main --triage --evidence-dir /tmp/nirux-diff

# Inspect diff-targeted selection standalone (coverage index + explicit table fallback)
git diff --no-renames --name-only -z origin/main HEAD | scripts/select-canary-scenarios.sh -z --json

# Failure injection & deterministic replay
scripts/canary.sh Nirux.app --inject-failure monaco --evidence-dir /tmp/nirux-injection
scripts/canary.sh --replay /tmp/nirux-evidence/run-001-XXXXXXXX

# Triage mode: initial run + 2 fresh-state replays on non-infra failure, fingerprinting,
# external .ips crash correlation, investigation bundle, and incident history ledger
scripts/canary.sh Nirux.app --triage --repro-runs 2 \
  --evidence-dir /tmp/nirux-triage \
  --history-dir /tmp/nirux-canary-history

# Runner qualification / soak check (N consecutive clean passes + timing variance)
scripts/canary.sh Nirux.app --qualify 5 --evidence-dir /tmp/nirux-qualify

# Runner unit tests (stdlib Python only, no Xcode required)
/usr/bin/python3 -B -m unittest discover -s scripts/canary -v
```

The runner prints a JSON summary line to stdout with the report/triage/qualification/suite path. Use an individual run directory for `--replay`, including after downloading a workflow artifact. Each iteration owns a fresh state folder (`NIRUX_STATE_DIR`), home, git repo, linked worktree(s), and isolated bundle copy. Replay checks the archived app's SHA-256 and uses its original scenario, fixture seed, and injection in a new directory (supports both v1 and v2 manifests). Use evidence from a trusted build since replay executes its binary.

## Scenarios & step invariants

Scenarios are declared in `scripts/canary/scenarios.py` with explicit step lists, effect steps, and per-step invariants recorded into `report.json` (`steps[].invariants` and `invariantsSummary`).

### 1. `ghostty-monaco-restore` (tier: `core`)

1. The signed, copied bundle launches a real zsh in the synthetic worktree. A PID-targeted keyboard event types a command and the runner verifies its relative file write.
2. Accessibility presses **Columns → Open Editor**. The worktree's `README.md` is the app's standard starter file. The driver waits for the focused Monaco text area, types a marker and sends ⌘S. The file must acquire precisely that marker and retain its original text.
3. ⌘1 returns focus to Ghostty. A second shell command must create a different file in the same worktree.
4. ⌘Q must exit with status zero and release all child processes (the quit step waits for zero children) and leave a valid state (`state-json-valid`). The saved active workspace must contain its original terminal and its new editor tab. Relaunch uses the same state without reseeding it. A third shell command and a second edit/save through the restored column prove both are usable.

### 2. `multi-agent-routing` (tier: `targeted`)

Exercises two Spaces (`Canary Alpha`, `Canary Beta`), two linked git worktrees, two workspaces with stable `agentUUID`s, and an active Mission between them:

1. Runs a fake `claude` (`FakeAgent.swift`, built on first use and linked under the agent's name, since Nirux knows agents by their kernel process name) in each workspace. It logs every byte it reads, and plays one turn per line through Claude Code's hooks, sent from inside its own terminal.
2. Types a seeded token into Beta and verifies byte-for-byte arrival in Beta's PTY with zero leakage into Alpha's PTY (`pty-isolation`).
3. Exercises the packaged binary's own `--mission ask` and `--mission reply --accept` against the isolated `NIRUX_STATE_DIR` (`mission-no-double-delivery`). Then Beta's fake agent asks for a permission: the amber badge must appear, and a whole-word reason must be rendered in the AX tree (`amber-has-reason`).
4. Switches back to Alpha via **Space → Previous Space**, types Alpha's token, and verifies byte-for-byte arrival in Alpha with zero cross-PTY leak to Beta.
5. Quits cleanly and checks `state-json-valid`, `mission-no-double-delivery`, and `pty-isolation`.

### 3. `sidebar-breakpoints` (tier: `targeted`)

Metamorphic UI checks across the exact `SidebarFold` breakpoints (`NiruxShellView+SidebarFold.swift`) without brittle pixel golden images:

1. Resizes the canary window via AX across the narrowing sweep `940 → 900 → 899 pt` and verifies stabilization to `expanded`, `expanded`, `folded` (icon rail).
2. Resizes across the widening hysteresis sweep `899 → 900 → 939 → 940 pt` and verifies the sidebar stays `folded` at `900` and `939` before unfolding at `940`.
3. Checks `ax-controls-reachable` at every breakpoint: named controls (`Search, Command P`, `Space: ...`, `History` when expanded, `New task` + `Board` when folded) stay enabled, non-empty, and inside the window bounds.
4. Quits cleanly (verifying auto-fold never overwrote the user's persisted `sidebarExpanded: true`), toggles Reduce Motion (`animatesInterface: false` → `true`), relaunches, repeats the sweep, and asserts metamorphic equivalence of fold states and reachable named controls.

## Diff-targeted selection

`scripts/canary/selection.py` and `scripts/select-canary-scenarios.sh` map changed repository paths to scenarios:

1. **Coverage index first** (`--coverage-index <path>`): reads `<source_path> <scenario_id>` lines (same format as `.build/coverage-index.txt` from `coverage-map.yml`, with `extract_lcov_mappings` for `llvm-cov` LCOV output).
2. **Explicit path table fallback**: maps sidebar/rail, Mission/hooks/PTY/input, and editor/terminal/persistence globs when no coverage index is present or a changed file is newly added.
3. **Global triggers & core fallback**: changes to the runner (`scripts/canary/*` but its README, `canary.yml`), the bundle (`Package.swift`, `NiruxCore/Package.swift`, `Resources/Info.plist`, `scripts/bundle.sh`) or `Persistence*.swift` select all scenarios; unmapped runtime sources fall back to `ghostty-monaco-restore`. Pure documentation diffs select zero scenarios and exit `4` (`nothing_selected`), never `pass`.

## Isolation and evidence

The runner unpacks a copy under `/private/tmp` and launches its executable with the worktree as cwd. The app and fixture git commands start with an explicit environment allowlist. `NIRUX_STATE_DIR` is canonical and private. The temporary home and zsh startup directory, skipped hook installation, empty live-merge override and repo without remotes keep agent and git activity local. Sparkle automatic checks and downloads are disabled for each launch. A macOS sandbox denies outbound IP connections, access to the checkout and SwiftPM build directories, and access to the account's real Nirux state, Claude and Codex directories. This also covers SwiftPM resource accessors that try an absolute build path.

All input goes to the spawned PID (`Driver.swift` guards every command on the canary app owning the focused key window). Never captures the global screen or posts synthetic events while another app is focused.

Each run folder contains the exact signed app in `Nirux.app.zip`, a versioned `manifest.json` (v1 or v2), `stdout.log`, `stderr.log` and `report.json`. Failures also retain regular files from synthetic state, the observed README when available, and any correlated `.ips` crash reports under `crashes/`. Multi-scenario invocations also write `<evidence-dir>/suite.json`.

### Standard mode (`--runs N`) exit codes

| Verdict | Exit | Meaning |
| --- | --- | --- |
| `pass` | 0 | Every iteration completed cleanly. |
| `fail` | 1 | A bundle, scenario, invariant or cleanup check failed. |
| `infra_unavailable` | 2 | A display, unlocked console, event permission, focused window, CLT or bundle prerequisite was unavailable. |
| `nothing_selected` | 4 | The diff selected no scenario: nothing ran. |
| usage error | 64 | Bad arguments or an unreadable `--diff-base`: nothing ran. |

## Triage mode: reproduction, classification & crash investigation

Pass `--triage` (or `--repro-runs N`, default `2`) to run deterministic triage:

1. Runs an `initial` attempt in `<evidence-dir>/triage-XXXXXXXX/initial`.
2. If the initial attempt returns `pass` or `infra_unavailable`, no replays are run.
3. If the initial attempt returns `fail` (non-infra), the supervisor runs `N` fresh-state replays (`repro-01`, `repro-02`, ...), each with its own disposable `NIRUX_STATE_DIR`, home, fixture repo/worktree, and isolated unpacked bundle copy from `initial/Nirux.app.zip`.
4. Classifies deterministically:

| Classification | Exit | Condition | Investigation bundle |
| --- | --- | --- | --- |
| `pass` | 0 | Initial run passed. | No |
| `infra_unavailable` | 2 | Graphical, focus, display, AX, CLT, or bundle prerequisite missing (never misclassified as a product bug). | No |
| `regression` | 1 | Initial failure + every fresh-state replay failed with matching failure surface and error/assertion (and matching crash frames when present). | Yes (`regression` / `regression_with_crash`) |
| `intermittent` (with crash) | 1 | Failed initially or partially with at least one observed crash (e.g. a 1-of-3 crash). | **Always Yes** (`single_crash_observed` / `multiple_crashes_observed`) |
| `intermittent` (no crash) | 3 | Failed initially, passed on at least one fresh replay (or failed on a different surface/assertion) with no crash observed. | No |

## Fingerprints, incident history, `.ips` correlation & qualification

- Deterministic fingerprint (`fp-<16-hex>`) over `(scenario, surface, errorKind, normalized_frames)`, stripping variable PIDs, temp paths, timestamps, UUIDs, seed tokens, and hex addresses.
- Append-safe incident ledger outside the checkout (`ledger.lock`, `events.jsonl`, atomic `incidents.json`), tracking per-scenario `lastGreen`, deduplicated incidents, resolution on confirmed pass, and reopening on reappearance.
- External `.ips` crash correlation from `--crash-reports-dir` (default `~/Library/Logs/DiagnosticReports`), independent of in-app `CrashReportScanner`.
- `--qualify N` runs `N` consecutive isolated iterations and writes `qualification.json` with pass rate and per-step timing statistics.

## Explorer: Claude drives a hidden copy

```sh
scripts/canary.sh Nirux.app --explore [--goal TEXT]... [--episodes 4] [--calls 50] [--episode-calls 12] \
  [--renders 6] [--minutes 20] [--model opus] --evidence-dir /tmp/nirux-explore
scripts/canary.sh Nirux.app --explore --replay-trace /tmp/nirux-explore/explore-XXXXXXXX/trace.jsonl
```

The copy runs hidden through the canary channel (no focus taken, nothing in front, no Accessibility permission) in the two-space world of `multi-agent-routing`. Every terminal runs a fake claude, never a shell, and the copy and all its children run under `explore.sb`: file reads and writes denied but for macOS's own folders and the run's throwaway folder, no network but localhost (`test_explore_sandbox.py`). The MCP server refuses what opens a terminal (⌘T, Columns › New Terminal), a malformed call, and anything past the run's budget. Each episode is a fresh `claude -p` toward one goal, with the explorer's MCP server (`explorer_mcp.py`) as its only tools: `--strict-mcp-config`, `--tools ""`, hooks off, the runner's environment without API keys. The tools act as a person does (`look`, `press`, `menu`, `key`, `type`, `terminal`, `render`, `note`).

The copy's GitHub is `fake_gh.py`: in a canary run only, Nirux runs it as gh (`GitHub.CLI.candidates`), never the user's. It answers pull requests, checks and sign-in from `<run>/github/world.json` (a pull request per fixture branch, each with an upstream on `acme/widgets`), records every call in `calls.jsonl`, and refuses GraphQL and the rest. The explorer's `github` tool changes that world as someone outside Nirux would: merge, close, reopen, checks passing, failing or running.

After each action the server runs the oracles and says what failed: the app exited, didn't answer, an amber badge without a rendered reason (or the Space button's "waits for you in"), `state.json` unreadable, a fatal line in the app's stderr, typed text that showed in a terminal other than the focused one. The runner adds a quit nobody asked for, children that outlive the quit, and `.ips` crash reports. `budget.json` caps the run's calls and renders; the runner stops the last episode at the deadline.

The run folder keeps `report.json` (episodes, tokens, cost, findings), `trace.jsonl` (every call, with its answer and failed checks), `findings.jsonl`, and `digest.md` (the agent's notes: to verify by a person, never in the ledger). Each distinct finding goes to the incident ledger as `intermittent`; `--replay-trace` runs a trace again without a model, and a finding it brings back is a `regression`.

```sh
# Shrink a run's trace to the calls that bring its finding back (ddmin, one fresh copy per replay)
scripts/canary.sh /tmp/nirux-explore/explore-XXXXXXXX/Nirux.app.zip --explore \
  --reduce /tmp/nirux-explore/explore-XXXXXXXX/trace.jsonl [--rule app-alive] --evidence-dir /tmp/nirux-reduce
# A kept trace is a regression check that needs no model
scripts/canary.sh Nirux.app --explore --replay-trace scripts/canary/traces/hidden-copy-quits-when-a-popover-closes.jsonl
```

`--replay-traces DIR` replays every kept trace of a folder, each in a fresh copy; a trace that finds its bug again is a `regression`, one that doesn't is a pass under `trace:<name>`. `.github/workflows/canary-traces.yml` runs `scripts/canary/traces` this way every night at 03:00 UTC on main (and on demand, or on a pull request that changes the traces or the workflow), without a model.

`--diff-base REF` puts first the goals that the files changed since REF touch. `traces/` keeps reduced traces: `hidden-copy-quits-when-a-popover-closes` (4 of the first run's 21 calls, 178 replays) quit the hidden copy before it stopped counting a closing popover as its last window.

## Night run (off until installed)

```sh
/usr/bin/python3 scripts/canary/night.py install --app latest [--hour 3]   # turns it on, testing the newest nightly
/usr/bin/python3 scripts/canary/night.py uninstall                         # turns it off
/usr/bin/python3 scripts/canary/night.py digest                            # what came since the last digest
```

`--app` takes `latest` or a path to a Nirux.app. With `latest`, each run first downloads the `nightly` release's `Nirux.app.zip` (what Sparkle installs, built on every push to main; the night's only network use, outside the sandboxed run) and tests it once `codesign --verify --deep --strict` passes and its build is no older than the last good copy's, kept in `~/Library/Application Support/Nirux Canary/nightly`, which it then replaces. When the download or a check fails, it tests the last good copy, and the digest says why.

Install copies the runner to `~/Library/Application Support/Nirux Canary/runner` (a task worktree goes away), resolves `claude` and puts its folder on the agent's PATH, pins the history folder, and replaces an agent already loaded. Uninstall removes the agent and `~/Library/Application Support/Nirux Canary` (the runner and the nightly copy); the history stays. The LaunchAgent (`com.xikimay.nirux.canary-night`, never at load) starts `night.py run` at the hour. It goes on only on AC power, with this user's session in front and the keyboard and mouse idle for 30 minutes, one run at a time; it runs one explore run (50 calls, `--max-usd`) then replays each kept trace. When someone touches the keyboard or mouse, or the idle check fails, it sends SIGTERM to `explore.py`, which ends its hidden copy and `claude -p`. Each night's runs and `digest.md` (the app tested, how each step ended, new incidents with the replay their evidence allows, clean runs) go to the history folder's `night/<date>/`. `caffeinate` keeps the Mac awake while a run lasts; a Mac asleep at the hour skips the night (launchd runs the job at wake, the check sees the user back), unless the user adds a wake schedule (`sudo pmset repeat wakeorpoweron …`, system-wide: install prints it, never runs it). Nothing installs it but a person.

## Workflow

**Packaged app canary** (`.github/workflows/canary.yml`) is a manual Actions workflow supporting `triage` and `qualify` modes and single-scenario, `all`, or diff-targeted `selected` execution. It stays outside PR triggers to respect the 5-job macOS CI concurrency cap. The runner unit tests run on every PR in `.github/workflows/tests.yml` (job `core`).
