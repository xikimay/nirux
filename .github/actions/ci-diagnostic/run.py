"""Hand off the log at the first error and return the original command's exit code."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

COMMANDS = {"build": ["swift", "build", "--build-tests"], "suite": ["scripts/run-tests.sh"]}
SOURCE_ERROR = re.compile(r"^(.+?):(\d+)(?::\d+)?: error: (.+)")


def execute(state, phase):
    command = COMMANDS[phase]
    selected = os.environ.get("NIRUX_TESTS_ONLY")
    if phase == "suite" and selected:
        command = [*command, "--only", selected]
    with (state / "log").open("wb") as log:
        try:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                    env={**os.environ, "NIRUX_STREAM_TEST_ERRORS": "1",
                                         "GITHUB_STEP_SUMMARY": str(state / "summary")})
            code = result.returncode
        except OSError as error:
            log.write(f"{error}\n".encode())
            code = 1
    (state / "exit.tmp").write_text(str(code if code >= 0 else 128 - code))
    (state / "exit.tmp").replace(state / "exit")


def publish(state, phase, match, offset):
    path, number, message = match.groups()
    diagnostic = state / "diagnostic.json"
    diagnostic.write_text(json.dumps({
        "run": os.environ["GITHUB_RUN_ID"], "attempt": os.environ["GITHUB_RUN_ATTEMPT"],
        "checkout": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
        "pr_head": os.environ.get("PR_HEAD") or None, "phase": phase,
        "file": os.path.relpath(path) if os.path.isabs(path) else path,
        "line": int(number), "message": message,
    }) + "\n")
    (state / "offset").write_text(str(offset))
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        print(f"diagnostic={diagnostic}", file=output)


def follow(state, phase, offset, pid, worker=None):
    with (state / "log").open("rb") as log:
        log.seek(offset)
        while True:
            finished = (state / "exit").exists()
            line = log.readline()
            if line and (finished or line.endswith(b"\n")):
                sys.stdout.buffer.write(line)
                sys.stdout.buffer.flush()
                if phase:
                    match = SOURCE_ERROR.match(line.decode(errors="replace").rstrip())
                    if match:
                        try:
                            publish(state, phase, match, log.tell())
                            return 0
                        except Exception as error:
                            print(f"::warning::No early diagnostic: {error}", flush=True)
                            phase = None
                continue
            if finished:
                code = int((state / "exit").read_text())
                summary = state / "summary"
                if summary.exists():
                    with open(os.environ["GITHUB_STEP_SUMMARY"], "ab") as out:
                        out.write(summary.read_bytes())
                shutil.rmtree(state)
                return code
            if line:
                log.seek(-len(line), os.SEEK_CUR)
            try:
                if worker is not None and worker.poll() is not None:
                    raise ProcessLookupError
                os.kill(pid, 0)
            except ProcessLookupError:
                if not (state / "exit").exists():
                    raise SystemExit("CI command stopped without an exit code")
            time.sleep(0.2)


if __name__ == "__main__":
    mode, argument = sys.argv[1:3]
    if mode == "execute":
        execute(Path(argument), sys.argv[3])
    elif mode == "start":
        if argument not in COMMANDS:
            raise SystemExit(f"Unknown phase {argument}")
        state = Path(tempfile.mkdtemp(dir=os.environ["RUNNER_TEMP"]))
        (state / "log").touch()
        worker = subprocess.Popen([sys.executable, __file__, "execute", str(state), argument],
                                  stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, start_new_session=True)
        (state / "pid").write_text(str(worker.pid))
        sys.exit(follow(state, argument, 0, worker.pid, worker))
    elif mode == "finish":
        state = Path(argument).parent
        sys.exit(follow(state, None, int((state / "offset").read_text()), int((state / "pid").read_text())))
