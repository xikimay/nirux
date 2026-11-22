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
SCENARIO = "ghostty-monaco-restore"
STEPS = ("bundle", "fixture", "preflight", "launch", "ghostty", "monaco",
         "focus-back", "quit", "restore", "final-quit")
EFFECT_STEPS = {"ghostty", "monaco", "focus-back", "restore"}
INFRA = "infra_unavailable"


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
                         preflight={"keyWindow": None}, processes=[])

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
        self.report.data["processes"].append({"pid": self.process.pid, "exitCode": None})
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
        self.report.data["processes"][-1]["exitCode"] = code
        if code:
            raise RuntimeError(f"AppKit quit exited with status {code}")
        wait_for("a child survived AppKit quit", lambda: not self.holders(), timeout=5)
        self.process = None

    def cleanup(self):
        if self.process is None:
            return
        if self.process.poll() is None:
            self.process.kill()
        self.report.data["processes"][-1]["exitCode"] = self.process.wait(timeout=5)
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
    archive = evidence / "Nirux.app.zip"
    if replay:
        shutil.copyfile(source, archive)
    else:
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--keepParent", source, archive],
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


def iteration(work, evidence, source, replay, metadata, check_interrupt):
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
            subprocess.run(["/usr/bin/swiftc", HERE / "Driver.swift", "-o", app.driver],
                           check=True, timeout=90)
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
        if report.data["verdict"] != "pass":
            try:
                snapshot(work, evidence)
            except OSError as error:
                report.data["snapshotError"] = str(error)
        write_json(evidence / "report.json", report.data)
    return report.data["verdict"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("app", type=Path, nargs="?")
    inputs.add_argument("--replay", type=Path, help="a run directory containing manifest.json and Nirux.app.zip")
    parser.add_argument("--evidence-dir", type=Path, help="parent directory for new run directories")
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--inject-failure", choices=STEPS[1:])
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
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
    verdicts = []
    for index in range(args.runs):
        evidence = Path(tempfile.mkdtemp(dir=evidence_root.resolve(), prefix=f"run-{index + 1:03d}-"))
        with tempfile.TemporaryDirectory(dir="/private/tmp", prefix="nirux-canary-") as folder:
            verdict = iteration(Path(folder), evidence, source, bool(args.replay),
                                manifest(seed or str(uuid.uuid4()), injection), check_interrupt)
        print(json.dumps({"verdict": verdict, "report": str(evidence / "report.json")}), flush=True)
        verdicts.append(verdict)
        if interrupted:
            return 128 + interrupted[0]
    return 1 if "fail" in verdicts else 2 if INFRA in verdicts else 0


if __name__ == "__main__":
    sys.exit(main())
