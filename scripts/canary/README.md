# Packaged app canary

`ghostty-monaco-restore` exercises the release bundle on macOS. Run it from an unlocked graphical login with Command Line Tools installed and Accessibility permission for the launching terminal. It takes keyboard focus during the scenario.

```sh
swift build -c release
scripts/bundle.sh 0.0.0 0

# Single or multi-run smoke
scripts/canary.sh Nirux.app --runs 3 --evidence-dir /tmp/nirux-evidence
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

The runner prints a JSON summary line to stdout with the report/triage/qualification path. Use an individual run directory for `--replay`, including after downloading a workflow artifact. Each iteration owns a fresh state folder (`NIRUX_STATE_DIR`), home, git repo, linked worktree, and isolated bundle copy. Replay checks the archived app's SHA-256 and uses its original fixture seed and injection in a new directory. Use evidence from a trusted build since replay executes its binary.

## What a pass proves

1. The signed, copied bundle launches a real zsh in the synthetic worktree. A PID-targeted keyboard event types a command and the runner verifies its relative file write.
2. Accessibility presses **Columns → Open Editor**. The worktree's `README.md` is the app's standard starter file. The driver waits for the focused Monaco text area, types a marker and sends ⌘S. The file must acquire precisely that marker and retain its original text.
3. ⌘1 returns focus to Ghostty. A second shell command must create a different file in the same worktree.
4. ⌘Q must exit with status zero and release the child processes. The saved active workspace must contain its original terminal and its new editor tab. Relaunch uses the same state without reseeding it. A third shell command and a second edit/save through the restored column prove both are usable. The second launch also quits through AppKit.

All input goes to the spawned PID. The driver uses AX to observe the key window and focused editor, and CGEvents for typing and shortcuts. Synchronization waits for the shell prompt, AX state, file contents and process exit. The app runs its normal event loop and persistence path.

## Isolation and evidence

The runner unpacks a copy under `/private/tmp` and launches its executable with the worktree as cwd. The app and fixture git commands start with an explicit environment allowlist. `NIRUX_STATE_DIR` is canonical and private. The temporary home and zsh startup directory, skipped hook installation, empty live-merge override and repo without remotes keep agent and git activity local. Sparkle automatic checks and downloads are disabled for each launch. A macOS sandbox denies outbound IP connections, access to the checkout and SwiftPM build directories, and access to the account's real Nirux state, Claude and Codex directories. This also covers SwiftPM resource accessors that try an absolute build path.

Each run folder contains the exact signed app in `Nirux.app.zip`, a versioned `manifest.json`, `stdout.log`, `stderr.log` and `report.json`. Failures also retain regular files from synthetic state, the observed README when available, and any correlated `.ips` crash reports under `crashes/`. The report records step IDs, elapsed milliseconds, total `durationMs`, the failed step, preflight observations, process records (`pid`, `startedAt`, `endedAt`, `exitCode`, `killedByCleanup`), correlated `crashes`, `crashed` boolean, and failure `fingerprint` / `fingerprintComponents`. A negative exit code identifies a signal. A null key-window observation means preflight stopped before launch.

### Standard mode (`--runs N`) exit codes

| Verdict | Exit | Meaning |
| --- | --- | --- |
| `pass` | 0 | Every iteration completed the roundtrip. |
| `fail` | 1 | A bundle, scenario or cleanup check failed. |
| `infra_unavailable` | 2 | A display, unlocked console, event permission, focused window, CLT or bundle prerequisite was unavailable. |

In a multi-run invocation a failure takes precedence over an infrastructure verdict. The runner traps interrupt, hangup and termination, cleans up, and exits with 128 plus the signal number. The app and its shells hold a run-specific file descriptor, so cleanup can identify a reparented shell without matching a process name. Temporary app copies and fixtures are removed after evidence collection.

Use `--inject-failure preflight` to check failure attribution and replay on a locked machine. For terminal and editor steps, injection sends a wrong marker through the UI and lets the ordinary disk assertion catch it. Other injectable IDs appear in `--help`. An earlier missing prerequisite takes precedence over a later injection.

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

An observed crash is never silently dropped: even a 1-of-3 crash opens `<triage-dir>/investigation/investigation.json`, copies matched `.ips` files into `<triage-dir>/investigation/crashes/`, records the crash fingerprint in the incident ledger, and exits with code `1`.

## Fingerprints & append-safe incident history

Every non-passing run computes a deterministic fingerprint (`fp-<16-hex>`) from:

```json
{
  "version": 1,
  "scenario": "ghostty-monaco-restore",
  "surface": "<failedStep>",
  "errorKind": "<normalized assertion or crash:EXC:SIG>",
  "frames": ["<image>:<normalized_symbol>", "..."]
}
```

Normalization strips variable PIDs, temporary paths (`/private/tmp/nirux-*`, `/var/folders/.../T/...`), timestamps, UUIDs/seed tokens, and hex memory addresses (`0x...`), and drops raw symbol/image offsets from crash frames.

The supervisor persists an append-safe incident ledger outside the mutable repo checkout (configurable via `--history-dir` or `NIRUX_CANARY_HISTORY_DIR`; defaults to `<tmpdir>/nirux-canary-history`):

- `ledger.lock`: advisory `fcntl.flock` mutex preventing concurrent writers from corrupting state.
- `events.jsonl`: append-only NDJSON event log (`O_APPEND` + `fsync`).
- `incidents.json`: atomically replaced (`tempfile` + `fsync` + `os.replace`) materialized index (rebuildable from `events.jsonl`) tracking:
  - Per-scenario `lastGreen` (`runId`, `timestamp`, `commit`, `bundleSHA256`).
  - Per-fingerprint `firstSeen`, `lastSeen`, `occurrences`, `status` (`open`, `resolved`, `reopened`, `infra`), `counts` (`regression`, `intermittent`, `infra_unavailable`), `crashCount`, `lastKnownGreen`, `reopenCount`, and recent run `history`.
  - A confirmed `pass` for a scenario updates `lastGreen` and transitions open/reopened incidents for that scenario to `resolved`. If the same fingerprint reappears after a confirmed green run, its status transitions to `reopened` (`reopened: true`, `reopenCount += 1`). `infra_unavailable` events never resolve open product bugs or falsely reopen resolved bugs.

Pass `--commit <sha>` (or set `GITHUB_SHA`) to tag ledger entries; otherwise the runner attempts `git rev-parse HEAD`.

## External `.ips` crash report correlation

When any launched Nirux process exits unexpectedly (`exitCode != 0` and not `killedByCleanup`), the external Python supervisor scans `--crash-reports-dir` (defaulting to the real account's `~/Library/Logs/DiagnosticReports`, independent of in-app `CrashReportScanner`):

- Filters for crash `.ips` reports (`bug_type == "309"`), matching process name (`Nirux`) and bundle ID (`com.xikimay.nirux`).
- Correlates by PID (when present in the `.ips`) and launch/crash time window around the process's `startedAt`..`endedAt`.
- Deduplicates duplicate incident files (preferring complete-body reports), copies matched `.ips` files into `<evidence>/crashes/`, and extracts top normalized frames (prioritizing `lastExceptionBacktrace`, faulting thread top frames, and the earliest `Nirux` app frames below runtime traps) into `report.json` and the failure fingerprint.

## Qualification / soak check (`--qualify N`)

Inspired by `flake-gate.yml`, `--qualify N` runs `N` consecutive isolated canary iterations and writes `<evidence-dir>/qualification.json`:

- `qualified`: `true` iff all `N` consecutive runs passed cleanly (`passRate == 1.0`, exit `0`).
- `verdict`: `qualified` (exit `0`), `infra_unavailable` (exit `2` when no failures occurred and infra blocked runs), or `unqualified` (exit `1`).
- `passRate`, `passedRuns`, `failedRuns`, `infraRuns`, `consecutiveCleanPasses`, `longestCleanStreak`.
- `timing` and per-step `stepTiming`: `count`, `minMs`, `maxMs`, `meanMs`, `medianMs`, `varianceMs`, `stddevMs`, `p95Ms`, `cv`.

## Key JSON schemas

- `report.json` (per attempt): `version`, `scenario`, `seed`, `bundleSHA256`, `verdict`, `failedStep`, `durationMs`, `steps`, `preflight`, `processes`, `crashes`, `crashed`, `fingerprint`, `fingerprintComponents`, `replay`.
- `triage.json` (per `--triage` session): `version`, `runId`, `scenario`, `commit`, `bundleSHA256`, `classification`, `fingerprint`, `fingerprintComponents`, `hasCrash`, `crashCount`, `crashFingerprints`, `totalAttempts`, `replayCounts`, `investigationRequired`, `investigationReason`, `reopened`, `lastGreen`, `investigation`, `ledger`, `incident`, `attempts`.
- `investigation/investigation.json`: `version`, `opened`, `reason`, `classification`, `fingerprint`, `fingerprintComponents`, `crashCount`, `totalAttempts`, `crashFingerprints`, `crashes`, `attempts`, `incident`.
- `qualification.json`: `version`, `scenario`, `requestedRuns`, `completedRuns`, `passedRuns`, `failedRuns`, `infraRuns`, `consecutiveCleanPasses`, `longestCleanStreak`, `passRate`, `qualified`, `verdict`, `timing`, `stepTiming`, `runs`.

## Workflow

**Packaged app canary** (`.github/workflows/canary.yml`) is a manual Actions workflow supporting both `triage` (default) and `qualify` modes. It builds ad hoc, runs the canary runner unit tests, executes the canary, and uploads evidence and history artifacts even on failure. A hosted runner without an interactive desktop records an inconclusive `infra_unavailable` result in the job summary. The runner unit tests also run on every PR in `.github/workflows/tests.yml`.
