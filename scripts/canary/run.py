"""Run the packaged Ghostty/Monaco roundtrip. Python 3.9+, macOS."""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import pwd
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from crash_correlator import (  # noqa: E402
    correlate_crash_reports,
    DEFAULT_BUNDLE_ID,
    DEFAULT_PROCESS_NAME,
    is_unexpected_process_exit,
)
from history import default_history_dir, IncidentLedger  # noqa: E402
from qualify import evaluate_qualification, qualification_exit_code  # noqa: E402
from triage import (  # noqa: E402
    attempt_has_crash,
    classify_attempts,
    compute_fingerprint,
    open_investigation,
    PASS,
    triage_exit_code,
)

SCENARIO = "ghostty-monaco-restore"
STEPS = ("bundle", "fixture", "preflight", "launch", "ghostty", "monaco",
         "focus-back", "quit", "restore", "final-quit")
EFFECT_STEPS = {"ghostty", "monaco", "focus-back", "restore"}
INFRA = "infra_unavailable"
DEFAULT_CRASH_WAIT_SECONDS = 2.0


class InfrastructureError(RuntimeError):
    pass


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def environment(work):
    home = str(work / "home")
    return {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
        "HOME": home, "CFFIXED_USER_HOME": home, "ZDOTDIR": home, "SHELL": "/bin/zsh",
        "TMPDIR": str(work / "tmp"), "XDG_CONFIG_HOME": home + "/.config",
        "CLAUDE_CONFIG_DIR": home + "/.claude", "CODEX_HOME": home + "/.codex",
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0", "NIRUX_STATE_DIR": str(work / "state"),
        "NIRUX_SKIP_HOOK_INSTALL": "1", "NIRUX_MERGE_QUEUE_LIVE": "",
    }


def fixture(work, env, seed):
    tree = work / "worktree"
    repo = work / "repo"
    repo.mkdir()

    commit_date = "2000-01-01T00:00:00Z"
    git_env = dict(env, GIT_AUTHOR_DATE=commit_date, GIT_COMMITTER_DATE=commit_date)

    def git(*args):
        subprocess.run(["/usr/bin/git", "-c", "user.name=Nirux Canary",
                        "-c", "user.email=canary@localhost", *args], env=git_env, cwd=repo,
                       stdout=subprocess.DEVNULL, check=True, timeout=30)

    git("init", "-q", "-b", "main")
    (repo / "README.md").write_text("canary " + seed + "\n")
    git("add", "README.md")
    git("commit", "-qm", "Synthetic canary fixture")
    git("worktree", "add", "-qb", "canary", str(tree))
    workspace = {"id": seed, "title": "Canary", "cwd": str(tree), "focusedColumnIndex": 0,
                 "columns": [{"cwd": str(tree), "columnType": "terminal", "widthPreset": 0.5}]}
    write_json(work / "state/state.json", {
        "workspaces": [workspace], "activeWorkspaceIndex": 0, "activeWorkspaceID": seed,
        "settings": {"animatesInterface": False, "keepMacAwakeWhileAgentsWork": False},
    })
    (work / "home/.zshenv").write_text('exec 9<"$NIRUX_STATE_DIR/../children"\n')
    (work / "home/.zshrc").write_text('precmd() { print -r -- $$ > "$NIRUX_STATE_DIR/prompt"; }\n')


def manifest(seed, injection):
    return {"version": 1, "scenario": SCENARIO, "seed": seed, "injectFailure": injection,
            "fixture": {"branch": "canary", "file": "README.md"}}


def read_replay(directory):
    data = json.loads((directory / "manifest.json").read_text())
    if data["version"] != 1 or data["scenario"] != SCENARIO:
        raise ValueError("unsupported canary manifest")
    seed = str(uuid.UUID(data["seed"]))
    injection = data["injectFailure"]
    if injection is not None and injection not in STEPS:
        raise ValueError("unknown injection in manifest")
    archive = directory / "Nirux.app.zip"
    if checksum(archive) != data["bundleSHA256"]:
        raise ValueError("bundle checksum differs from the recorded run")
    return seed, injection, archive


def checksum(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


class Report:
    def __init__(self, metadata):
        self.data = dict(metadata, verdict="pass", failedStep=None, steps=[],
                         preflight={"keyWindow": None}, processes=[], crashes=[],
                         crashed=False)

    @contextlib.contextmanager
    def step(self, name):
        start = time.monotonic()
        row = {"id": name, "verdict": "pass"}
        try:
            if name == self.data["injectFailure"] and name not in EFFECT_STEPS:
                raise RuntimeError("injected failure")
            yield
        except Exception as error:
            verdict = INFRA if isinstance(error, InfrastructureError) else "fail"
            row.update(verdict=verdict, reason=str(error))
            self.data.update(verdict=verdict, failedStep=name)
            raise
        finally:
            row["durationMs"] = round((time.monotonic() - start) * 1000)
            self.data["steps"].append(row)


def wait_for(description, condition, alive=lambda: None, timeout=20):
    end = time.monotonic() + timeout
    while True:
        alive()
        if condition():
            return
        if time.monotonic() >= end:
            raise TimeoutError(description)
        time.sleep(0.1)


class App:
    def __init__(self, work, evidence, report, check_interrupt):
        self.check_interrupt = check_interrupt
        self.work = work
        self.tree = work / "worktree"
        self.env = environment(work)
        self.evidence = evidence
        self.report = report
        self.driver = work / "driver"
        self.process = None
        self.lease = work / "children"
        self.lease.touch()

    def launch(self):
        real_home = Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
        protected = {"CHECKOUT": HERE.parents[1], "STATE": real_home / "Library/Application Support/nirux",
                     "CLAUDE": real_home / ".claude", "CODEX": real_home / ".codex"}
        args = ["/usr/bin/sandbox-exec", "-f", str(HERE / "isolate.sb")]
        for name, path in protected.items():
            args += ["-D", f"{name}={path.resolve()}"]
        args += [str(self.work / "Nirux.app/Contents/MacOS/Nirux"), "-IgnoreGhosttyConfig", "YES",
                 "-SUEnableAutomaticChecks", "NO", "-SUAutomaticallyUpdate", "NO"]
        (self.work / "state/prompt").unlink(missing_ok=True)
        with self.lease.open("rb") as lease, (self.evidence / "stdout.log").open("ab") as out, \
                (self.evidence / "stderr.log").open("ab") as err:
            self.process = subprocess.Popen(args, cwd=self.tree, env=self.env, stdin=subprocess.DEVNULL,
                                            stdout=out, stderr=err, start_new_session=True,
                                            pass_fds=(lease.fileno(),))
        self.report.data["processes"].append({
            "pid": self.process.pid,
            "startedAt": time.time(),
            "endedAt": None,
            "exitCode": None,
            "killedByCleanup": False,
        })
        try:
            wait_for("no focused window", lambda: self.drive("window", probe=True), self.alive)
        except TimeoutError as error:
            self.report.data["preflight"]["keyWindow"] = False
            raise InfrastructureError(str(error)) from error
        self.report.data["preflight"]["keyWindow"] = True
        wait_for("zsh did not reach a prompt", (self.work / "state/prompt").is_file, self.check_window)

    def alive(self):
        self.check_interrupt()
        code = self.process.poll()
        if code is not None:
            proc_entry = self.report.data["processes"][-1]
            proc_entry["exitCode"] = code
            if proc_entry.get("endedAt") is None:
                proc_entry["endedAt"] = time.time()
            raise RuntimeError(f"Nirux exited with status {code}")

    def drive(self, action, *args, probe=False):
        self.alive()
        result = subprocess.run([self.driver, action, str(self.process.pid), *args],
                                cwd=self.work, env=self.env, timeout=6)
        if action != "quit" or result.returncode != 0:
            self.alive()
        if result.returncode == 3 and action != "window":
            self.report.data["preflight"]["keyWindow"] = False
            raise InfrastructureError("the canary lost its key window")
        if not probe or result.returncode not in (0, 1, 3):
            result.check_returncode()
        return result.returncode == 0

    def check_window(self):
        if not self.drive("window", probe=True):
            self.report.data["preflight"]["keyWindow"] = False
            raise InfrastructureError("the canary lost its key window")

    def shell_marker(self, name, seed, inject=False):
        marker = self.tree / name
        sent = "injected" if inject else seed
        self.drive("command", f'[[ . -ef "$NIRUX_STATE_DIR/../worktree" ]] && echo {sent} > {name}')
        wait_for(f"missing terminal effect {name}", lambda: marker.is_file()
                 and marker.read_text() == seed + "\n", self.check_window)

    def edit(self, token, inject=False):
        wait_for("Monaco text area did not take focus", lambda: self.drive("editor-focus", probe=True))
        file = self.tree / "README.md"
        original = file.read_text()
        self.drive("text", "injected" if inject else token)
        self.drive("save")

        def saved():
            value = file.read_text()
            return token in value and value.replace(token, "", 1) == original

        wait_for("Monaco save did not reach README.md", saved, self.check_window)

    def holders(self):
        result = subprocess.run(["/usr/sbin/lsof", "-nP", "-t", "--", self.lease],
                                capture_output=True, text=True, timeout=10)
        if result.returncode not in (0, 1) or result.stderr.strip():
            raise RuntimeError("cannot inspect canary children: " + result.stderr)
        return [int(pid) for pid in result.stdout.split()]

    def quit(self):
        self.drive("quit")
        self.process.wait(timeout=20)
        code = self.process.returncode
        proc_entry = self.report.data["processes"][-1]
        proc_entry["exitCode"] = code
        proc_entry["endedAt"] = time.time()
        if code:
            raise RuntimeError(f"AppKit quit exited with status {code}")
        wait_for("a child survived AppKit quit", lambda: not self.holders(), timeout=5)
        self.process = None

    def cleanup(self):
        if self.process is None:
            return
        was_running = self.process.poll() is None
        if was_running:
            self.process.kill()
        proc_entry = self.report.data["processes"][-1]
        proc_entry["exitCode"] = self.process.wait(timeout=5)
        if proc_entry.get("endedAt") is None:
            proc_entry["endedAt"] = time.time()
        if was_running:
            proc_entry["killedByCleanup"] = True
        for pid in self.holders():
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        wait_for("could not reap canary children", lambda: not self.holders(), timeout=5)


def verify_layout(work, seed):
    state = json.loads((work / "state/state.json").read_text())
    tree = work / "worktree"
    file = tree / "README.md"

    def matches(path, expected):
        return bool(path) and Path(path).resolve() == expected

    ws = next((ws for ws in state["workspaces"] if ws.get("id") == seed), {})
    columns = ws.get("columns", [])
    if (state.get("activeWorkspaceID") != seed or not matches(ws.get("cwd"), tree)
            or len(columns) != 2 or columns[0].get("columnType") != "terminal"
            or not matches(columns[0].get("cwd"), tree) or columns[1].get("columnType") != "editor"
            or not matches(columns[1].get("editorActiveFile"), file)
            or not any(matches(path, file) for path in columns[1].get("editorOpenFiles", []))):
        raise RuntimeError("quit did not persist the active fixture workspace, terminal and editor tab")


def package(work, evidence, source, replay, metadata):
    source_path = Path(source)
    if not source_path.exists():
        raise InfrastructureError(f"missing bundle prerequisite: {source_path}")
    archive = evidence / "Nirux.app.zip"
    if replay:
        shutil.copyfile(source_path, archive)
    else:
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--keepParent", source_path, archive],
                       check=True, timeout=120)
    metadata["bundleSHA256"] = checksum(archive)
    write_json(evidence / "manifest.json", metadata)
    subprocess.run(["/usr/bin/ditto", "-x", "-k", archive, work], check=True, timeout=120)
    app = work / "Nirux.app"
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app], check=True, timeout=60)
    for resource in ("Contents/MacOS/Nirux", "Contents/Resources/EditorAssets/index.html",
                     "Contents/Resources/GhosttyKit_GhosttyTerminal.bundle"):
        if not (app / resource).exists() or app not in (app / resource).resolve().parents:
            raise ValueError(f"missing packaged resource {resource}")


def snapshot(work, evidence):
    # Live state can contain sockets and lock files. Only archive regular files.
    for path in (work / "state").rglob("*"):
        if path.is_file() and not path.is_symlink():
            target = evidence / path.relative_to(work)
            target.parent.mkdir(exist_ok=True, parents=True)
            shutil.copyfile(path, target)
    file = work / "worktree/README.md"
    if file.is_file():
        shutil.copyfile(file, evidence / "README.observed.md")


def iteration(
    work,
    evidence,
    source,
    replay,
    metadata,
    check_interrupt,
    *,
    crash_reports_dir=None,
    crash_wait_seconds=DEFAULT_CRASH_WAIT_SECONDS,
    process_name=DEFAULT_PROCESS_NAME,
    bundle_id=DEFAULT_BUNDLE_ID,
):
    started = time.monotonic()
    report = Report(metadata)
    app = App(work, evidence, report, check_interrupt)
    seed = metadata["seed"]
    injection = metadata["injectFailure"]
    for name in ("state", "tmp", "home"):
        (work / name).mkdir(mode=0o700)
    for name in ("stdout.log", "stderr.log"):
        (evidence / name).touch()
    write_json(evidence / "manifest.json", metadata)
    report.data["replay"] = ["scripts/canary.sh", "--replay", str(evidence)]

    @contextlib.contextmanager
    def step(name):
        with report.step(name):
            check_interrupt()
            yield

    try:
        with step("bundle"):
            package(work, evidence, source, replay, metadata)
            report.data["bundleSHA256"] = metadata["bundleSHA256"]
        with step("fixture"):
            fixture(work, app.env, seed)
        with step("preflight"):
            try:
                subprocess.run(["/usr/bin/swiftc", HERE / "Driver.swift", "-o", app.driver],
                               check=True, timeout=90)
            except FileNotFoundError as error:
                raise InfrastructureError("Command Line Tools (swiftc) unavailable") from error
            probes = json.loads(subprocess.check_output([app.driver, "preflight"], env=app.env, timeout=10))
            report.data["preflight"].update(probes)
            missing = [key for key, available in probes.items() if not available]
            if missing:
                raise InfrastructureError("requires " + ", ".join(missing))
        with step("launch"):
            app.launch()
        with step("ghostty"):
            app.shell_marker("first", seed, injection == "ghostty")
        with step("monaco"):
            app.drive("open-editor")
            app.edit("edit" + seed.replace("-", ""), injection == "monaco")
        with step("focus-back"):
            app.drive("terminal")
            app.shell_marker("second", seed, injection == "focus-back")
        with step("quit"):
            app.quit()
            verify_layout(work, seed)
        with step("restore"):
            app.launch()
            app.shell_marker("restored", seed, injection == "restore")
            app.drive("editor")
            app.edit("restored" + seed.replace("-", ""))
        with step("final-quit"):
            app.quit()
    except Exception:
        if report.data["failedStep"] is None:
            raise
    finally:
        try:
            app.cleanup()
        except Exception as error:
            report.data.update(verdict="fail", cleanupError=str(error))
            if not report.data["failedStep"]:
                report.data["failedStep"] = "cleanup"
        if any(is_unexpected_process_exit(proc) for proc in report.data["processes"]):
            try:
                report.data["crashes"] = correlate_crash_reports(
                    report.data["processes"],
                    crash_reports_dir,
                    evidence,
                    process_name=process_name,
                    bundle_id=bundle_id,
                    wait_seconds=crash_wait_seconds,
                )
            except OSError as error:
                report.data["crashCorrelationError"] = str(error)
        report.data["crashed"] = attempt_has_crash(report.data)
        if report.data["verdict"] != PASS:
            fp = compute_fingerprint(report.data)
            report.data["fingerprint"] = fp["fingerprint"]
            report.data["fingerprintComponents"] = fp["components"]
        else:
            report.data["fingerprint"] = None
            report.data["fingerprintComponents"] = None
        report.data["durationMs"] = round((time.monotonic() - started) * 1000)
        if report.data["verdict"] != PASS:
            try:
                snapshot(work, evidence)
            except OSError as error:
                report.data["snapshotError"] = str(error)
        write_json(evidence / "report.json", report.data)
    return report.data["verdict"]


def detect_commit(explicit_commit=None):
    if explicit_commit:
        return explicit_commit
    env_sha = os.environ.get("GITHUB_SHA", "").strip()
    if env_sha:
        return env_sha
    try:
        result = subprocess.run(
            ["/usr/bin/git", "rev-parse", "HEAD"],
            cwd=HERE.parents[1],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def run_triage(
    execute_attempt,
    triage_dir,
    *,
    repro_runs=2,
    ledger=None,
    commit=None,
    scenario=SCENARIO,
    is_interrupted=lambda: False,
):
    """Run initial attempt plus fresh-state replays on non-infra failure, classify, and update history."""
    triage_path = Path(triage_dir).resolve()
    triage_path.mkdir(parents=True, exist_ok=True)
    if ledger is None:
        ledger = IncidentLedger(default_history_dir())

    initial_dir = triage_path / "initial"
    initial_dir.mkdir(parents=True, exist_ok=True)
    initial_report = execute_attempt("initial", initial_dir, None)
    attempt_records = [{
        "label": "initial",
        "evidenceDir": str(initial_dir),
        "report": initial_report,
    }]

    if initial_report.get("verdict") == "fail" and not is_interrupted():
        archive_candidate = initial_dir / "Nirux.app.zip"
        archive_override = archive_candidate if archive_candidate.is_file() else None
        for idx in range(1, repro_runs + 1):
            label = f"repro-{idx:02d}"
            replay_dir = triage_path / label
            replay_dir.mkdir(parents=True, exist_ok=True)
            replay_report = execute_attempt(label, replay_dir, archive_override)
            attempt_records.append({
                "label": label,
                "evidenceDir": str(replay_dir),
                "report": replay_report,
            })
            if is_interrupted():
                break

    triage_result = classify_attempts(
        initial_report,
        [rec["report"] for rec in attempt_records[1:]],
    )
    run_id = triage_path.name
    resolved_scenario = initial_report.get("scenario") or scenario
    bundle_sha256 = initial_report.get("bundleSHA256")
    classification = triage_result["classification"]
    inv_dir = (triage_path / "investigation") if triage_result["investigationRequired"] else None

    if classification == PASS:
        ledger_update = ledger.record_pass(
            resolved_scenario,
            run_id=run_id,
            commit=commit,
            bundle_sha256=bundle_sha256,
        )
        incident_info = None
        last_green = ledger_update["lastGreen"]
        reopened = False
    else:
        ledger_update = ledger.record_incident(
            triage_result["fingerprint"],
            triage_result["fingerprintComponents"],
            classification,
            run_id=run_id,
            commit=commit,
            bundle_sha256=bundle_sha256,
            crashed=triage_result["hasCrash"],
            investigation_dir=str(inv_dir) if inv_dir else None,
        )
        # Never drop a crash on a replay that had a different fingerprint than the initial failure.
        for rec in attempt_records:
            rep = rec["report"]
            if attempt_has_crash(rep):
                crash_fp = compute_fingerprint(rep)
                if crash_fp["fingerprint"] != triage_result["fingerprint"]:
                    ledger.record_incident(
                        crash_fp["fingerprint"],
                        crash_fp["components"],
                        "intermittent",
                        run_id=run_id,
                        commit=commit,
                        bundle_sha256=bundle_sha256,
                        crashed=True,
                        investigation_dir=str(inv_dir) if inv_dir else None,
                    )
        incident_info = ledger_update
        last_green = ledger_update.get("lastKnownGreen")
        reopened = bool(ledger_update.get("reopened", False))

    inv_path = None
    if triage_result["investigationRequired"]:
        inv_path = open_investigation(
            triage_path,
            triage_result,
            attempt_records,
            incident_update=incident_info,
        )

    attempt_summaries = []
    for rec in attempt_records:
        rep = rec["report"]
        fp = None if rep.get("verdict") == PASS else compute_fingerprint(rep)
        attempt_summaries.append({
            "label": rec["label"],
            "verdict": rep.get("verdict"),
            "failedStep": rep.get("failedStep"),
            "durationMs": rep.get("durationMs"),
            "crashed": attempt_has_crash(rep),
            "fingerprint": fp["fingerprint"] if fp else None,
            "report": str(Path(rec["evidenceDir"]) / "report.json"),
        })

    payload = {
        "version": 1,
        "runId": run_id,
        "scenario": resolved_scenario,
        "commit": commit,
        "bundleSHA256": bundle_sha256,
        **triage_result,
        "reopened": reopened,
        "lastGreen": last_green,
        "investigation": str(inv_path) if inv_path else None,
        "ledger": str(ledger.ledger_path),
        "incident": incident_info,
        "attempts": attempt_summaries,
    }
    write_json(triage_path / "triage.json", payload)
    return payload


def run_qualification(
    execute_run,
    evidence_root,
    *,
    qualify_runs,
    scenario=SCENARIO,
    is_interrupted=lambda: False,
):
    """Run N consecutive isolated canary runs and emit qualification pass rate and timing variance."""
    root = Path(evidence_root).resolve()
    root.mkdir(parents=True, exist_ok=True)
    run_records = []
    for index in range(1, qualify_runs + 1):
        run_dir = Path(tempfile.mkdtemp(dir=root, prefix=f"qualify-{index:03d}-"))
        report = execute_run(index, run_dir)
        fp = None if report.get("verdict") == PASS else compute_fingerprint(report)
        run_records.append({
            "index": index,
            "verdict": report.get("verdict"),
            "failedStep": report.get("failedStep"),
            "durationMs": report.get("durationMs"),
            "stepDurationsMs": {
                step["id"]: step.get("durationMs")
                for step in (report.get("steps") or [])
                if "id" in step
            },
            "crashed": attempt_has_crash(report),
            "fingerprint": fp["fingerprint"] if fp else None,
            "report": str(run_dir / "report.json"),
        })
        if is_interrupted():
            break

    summary = evaluate_qualification(run_records, qualify_runs, scenario)
    write_json(root / "qualification.json", summary)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("app", type=Path, nargs="?")
    inputs.add_argument("--replay", type=Path, help="a run directory containing manifest.json and Nirux.app.zip")
    parser.add_argument("--evidence-dir", type=Path, help="parent directory for new run directories")
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--inject-failure", choices=STEPS[1:])
    parser.add_argument(
        "--triage",
        action="store_true",
        help="enable multi-run reproduction, deterministic classification, fingerprinting, and incident history",
    )
    parser.add_argument(
        "--repro-runs",
        type=int,
        default=None,
        help="number of fresh-state replays on initial non-infra failure (implies --triage; default 2)",
    )
    parser.add_argument(
        "--history-dir",
        type=Path,
        default=None,
        help="directory for the append-safe incident history ledger (default outside repo checkout)",
    )
    parser.add_argument(
        "--crash-reports-dir",
        type=Path,
        default=None,
        help="directory to scan for .ips crash reports (default ~/Library/Logs/DiagnosticReports)",
    )
    parser.add_argument(
        "--commit",
        type=str,
        default=None,
        help="commit SHA to record in the incident history ledger",
    )
    parser.add_argument(
        "--qualify",
        type=int,
        default=None,
        metavar="N",
        help="run N consecutive clean passes and report pass rate and timing variance as JSON",
    )
    args = parser.parse_args()

    triage_mode = args.triage or (args.repro_runs is not None)
    repro_runs = 2 if args.repro_runs is None else args.repro_runs

    if args.runs < 1:
        parser.error("--runs must be positive")
    if args.repro_runs is not None and args.repro_runs < 1:
        parser.error("--repro-runs must be positive")
    if args.qualify is not None and args.qualify < 1:
        parser.error("--qualify must be positive")
    if triage_mode and args.qualify is not None:
        parser.error("--triage/--repro-runs and --qualify are mutually exclusive")
    if (triage_mode or args.qualify is not None) and args.runs != 1:
        parser.error("--runs cannot be combined with --triage or --qualify")

    if args.replay:
        try:
            seed, injection, source = read_replay(args.replay.resolve())
        except (OSError, KeyError, TypeError, ValueError) as error:
            parser.error(str(error))
        if args.inject_failure is not None:
            parser.error("replay uses the injection recorded in the manifest")
    else:
        seed, injection, source = None, args.inject_failure, args.app.resolve()
        if source.name != "Nirux.app" or not source.is_dir():
            parser.error("provide a packaged Nirux.app directory")

    interrupted = []

    def check_interrupt():
        if interrupted:
            raise InterruptedError(f"received {signal.Signals(interrupted[0]).name}")

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda number, frame: interrupted.append(number))
    evidence_root = args.evidence_dir or Path(tempfile.mkdtemp(prefix="nirux-evidence-"))
    evidence_root.mkdir(parents=True, exist_ok=True)
    crash_dir = args.crash_reports_dir.resolve() if args.crash_reports_dir else None

    def execute_single(evidence_dir, run_source, is_archive_replay):
        with tempfile.TemporaryDirectory(dir="/private/tmp", prefix="nirux-canary-") as folder:
            iteration(
                Path(folder),
                evidence_dir,
                run_source,
                is_archive_replay,
                manifest(seed or str(uuid.uuid4()), injection),
                check_interrupt,
                crash_reports_dir=crash_dir,
            )
        return json.loads((evidence_dir / "report.json").read_text(encoding="utf-8"))

    if triage_mode:
        triage_dir = Path(tempfile.mkdtemp(dir=evidence_root.resolve(), prefix="triage-"))
        history_dir = args.history_dir.resolve() if args.history_dir else default_history_dir()
        ledger = IncidentLedger(history_dir)
        commit = detect_commit(args.commit)

        def execute_attempt(label, attempt_dir, archive_override):
            use_source = archive_override if archive_override is not None else source
            is_archive = bool(args.replay) or (archive_override is not None)
            return execute_single(attempt_dir, use_source, is_archive)

        summary = run_triage(
            execute_attempt,
            triage_dir,
            repro_runs=repro_runs,
            ledger=ledger,
            commit=commit,
            scenario=SCENARIO,
            is_interrupted=lambda: bool(interrupted),
        )
        print(json.dumps({
            "classification": summary["classification"],
            "fingerprint": summary["fingerprint"],
            "hasCrash": summary["hasCrash"],
            "reopened": summary["reopened"],
            "investigation": summary["investigation"],
            "triage": str(triage_dir / "triage.json"),
        }), flush=True)
        if interrupted:
            return 128 + interrupted[0]
        return triage_exit_code(summary["classification"], has_crash=summary["hasCrash"])

    if args.qualify is not None:
        summary = run_qualification(
            lambda index, run_dir: execute_single(run_dir, source, bool(args.replay)),
            evidence_root,
            qualify_runs=args.qualify,
            scenario=SCENARIO,
            is_interrupted=lambda: bool(interrupted),
        )
        print(json.dumps({
            "verdict": summary["verdict"],
            "qualified": summary["qualified"],
            "passRate": summary["passRate"],
            "passedRuns": summary["passedRuns"],
            "requestedRuns": summary["requestedRuns"],
            "timing": summary["timing"],
            "qualification": str(evidence_root.resolve() / "qualification.json"),
        }), flush=True)
        if interrupted:
            return 128 + interrupted[0]
        return qualification_exit_code(summary)

    verdicts = []
    for index in range(args.runs):
        evidence = Path(tempfile.mkdtemp(dir=evidence_root.resolve(), prefix=f"run-{index + 1:03d}-"))
        report_data = execute_single(evidence, source, bool(args.replay))
        verdict = report_data["verdict"]
        print(json.dumps({"verdict": verdict, "report": str(evidence / "report.json")}), flush=True)
        verdicts.append(verdict)
        if interrupted:
            return 128 + interrupted[0]
    return 1 if "fail" in verdicts else 2 if INFRA in verdicts else 0


if __name__ == "__main__":
    sys.exit(main())
