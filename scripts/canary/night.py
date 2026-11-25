"""The canary's night run, off until a person installs it. A LaunchAgent starts it at --hour; it
explores the hidden copy and replays the kept traces only on AC power, with this user's session
in front and idle for 30 minutes, and stops the moment the keyboard or mouse is touched. The
morning digest lists what the ledger got since the last one, each incident with its replay command,
and how each step ended.

  night.py install --app PATH [--hour 3]   copies the runner, writes and loads the LaunchAgent
  night.py uninstall                       unloads and removes both
  night.py run --app PATH                  what the LaunchAgent starts
  night.py digest                          prints the digest of what came since the last one

A sleeping Mac skips the night: launchd runs the job at wake, the check then sees the user back
and does nothing. Running at the hour needs a wake schedule, system-wide (sudo pmset repeat
wakeorpoweron ...): install prints the command for the user, never runs it. While a run lasts,
caffeinate keeps the Mac from sleeping.
"""

import argparse
import datetime
import fcntl
import getpass
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from history import default_history_dir, utc_now_iso  # noqa: E402

LABEL = "com.xikimay.nirux.canary-night"
IDLE_TO_START = 30 * 60
# Idle for less than this while running: someone is back.
TOUCHED = 60
PLIST = Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"
# A copy of the runner where no task worktree goes away under it.
SUPPORT = Path.home() / "Library/Application Support/Nirux Canary"
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


def on_ac_power(pmset):
    """From pmset -g batt: "Now drawing from 'AC Power'"."""
    return "'AC Power'" in (pmset.splitlines() or [""])[0]


def idle_seconds(ioreg):
    """From ioreg -c IOHIDSystem: the time since the last keyboard or mouse event; 0 when unknown."""
    match = re.search(r'"HIDIdleTime" = (\d+)', ioreg)
    return int(match.group(1)) / 1e9 if match else 0.0


def why_not(pmset, ioreg, console, user):
    """Why the night run may not start now, or None."""
    if not on_ac_power(pmset):
        return "on battery"
    if console.strip() != user:
        return f"the session in front is {console.strip() or 'nobody'}'s"
    idle = idle_seconds(ioreg)
    if idle < IDLE_TO_START:
        return f"idle for {int(idle // 60)} min only"
    return None


def probe(command):
    """A system tool's answer; "" when it fails or hangs, which reads as someone being there."""
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=10).stdout
    except (subprocess.TimeoutExpired, OSError):
        return ""


def current_idle():
    return idle_seconds(probe(["/usr/sbin/ioreg", "-c", "IOHIDSystem", "-d", "4"]))


def watched(command, idle=current_idle, sleep=time.sleep, interval=5, **popen):
    """Runs \`command\` (explore.py); once someone touches the keyboard or mouse, or the watch itself
    fails, sends it SIGTERM, which ends its copy and claude (explore.stop_on_sigterm), then kills
    what is left. (exit status, whether it was stopped)."""
    process = subprocess.Popen(command, start_new_session=True, **popen)
    stopped = False
    try:
        while process.poll() is None:
            if idle() < TOUCHED:
                stopped = True
                break
            sleep(interval)
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=60)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
    return process.returncode, stopped


def launch_agent(app, hour, runner, claude, python=sys.executable):
    """Started at \`hour\` every night, never at load; claude's folder on its PATH; its output in the history."""
    logs = default_history_dir() / "night"
    return {
        "Label": LABEL,
        "ProgramArguments": [python, "-B", str(runner / "night.py"), "run", "--app", str(app)],
        "EnvironmentVariables": {"PATH": f"{Path(claude).parent}:{SYSTEM_PATH}"},
        "StartCalendarInterval": {"Hour": hour, "Minute": 0},
        "RunAtLoad": False,
        "ProcessType": "Background",
        "LowPriorityIO": True,
        "StandardOutPath": str(logs / "night.log"),
        "StandardErrorPath": str(logs / "night.log"),
    }


def install(app, hour, *, plist=PLIST, support=SUPPORT, run=subprocess.run, which=shutil.which):
    claude = which("claude")
    if not claude:
        raise SystemExit("night.py: claude isn't on PATH")
    runner = support / "runner"
    shutil.rmtree(runner, ignore_errors=True)
    shutil.copytree(HERE, runner, ignore=shutil.ignore_patterns("__pycache__", "test_*"))
    (default_history_dir() / "night").mkdir(parents=True, exist_ok=True)
    plist.parent.mkdir(parents=True, exist_ok=True)
    plist.write_bytes(plistlib.dumps(launch_agent(app, hour, runner, claude)))
    domain = f"gui/{os.getuid()}"
    # A label already loaded keeps its old schedule unless it is unloaded first.
    run(["/bin/launchctl", "bootout", f"{domain}/{LABEL}"], check=False, capture_output=True)
    run(["/bin/launchctl", "bootstrap", domain, str(plist)], check=True)
    wake = (datetime.datetime(2000, 1, 1, hour) - datetime.timedelta(minutes=5)).strftime("%H:%M:00")
    return (f"night run on at {hour:02d}:00: {plist}\n"
            f"A sleeping Mac skips it. To wake it (system-wide, your call): sudo pmset repeat wakeorpoweron MTWRFSU {wake}")


def uninstall(*, plist=PLIST, support=SUPPORT, run=subprocess.run):
    run(["/bin/launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"], check=False, capture_output=True)
    plist.unlink(missing_ok=True)
    shutil.rmtree(support / "runner", ignore_errors=True)
    return "night run off"


def replay_command(folder):
    """How to replay an incident's evidence: an explore run's trace, a scenario run's manifest."""
    folder = Path(folder)
    if (folder / "trace.jsonl").exists():
        return f"scripts/canary.sh {folder}/Nirux.app.zip --explore --replay-trace {folder}/trace.jsonl"
    manifest = next(iter(sorted(folder.glob("manifest.json")) + sorted(folder.glob("*/manifest.json"))), None)
    if manifest:
        return f"scripts/canary.sh --replay {manifest.parent}"
    return f"evidence gone or not replayable: {folder}"


STEP_ENDS = {0: "clean", 1: "findings", 2: "infra unavailable"}


def digest(history, since, steps=()):
    """The ledger's events after \`since\`, as markdown: how each step ended, the incidents with their
    replay commands, the clean runs."""
    events_path = history / "events.jsonl"
    events = [json.loads(line) for line in events_path.read_text().splitlines()] if events_path.exists() else []
    recent = [event for event in events if event.get("timestamp", "") > since]
    incidents = [event for event in recent if event["type"] == "incident"]
    passes = [event for event in recent if event["type"] == "pass"]
    lines = [f"# Canary night digest, {datetime.date.today().isoformat()}", ""]
    for step in steps:
        end = "stopped: someone was back" if step["stopped"] else STEP_ENDS.get(step["exit"], f"failed (exit {step['exit']})")
        lines.append(f"- Step {step['name']}: {end}")
    lines += ["" if steps else None, f"{len(incidents)} incident(s), {len(passes)} clean run(s) since {since or 'the start'}.", ""]
    for event in incidents:
        components, folder = event.get("components") or {}, event.get("investigationDir")
        lines.append(f"- **{event['scenario']}** · {components.get('rule', '?')} ({event['classification']}): "
                     f"{components.get('detail', '')}")
        if folder:
            lines.append(f"  Replay: {replay_command(folder)}")
    return "\n".join(line for line in lines if line is not None) + "\n"


def run(args, history=None, probe=probe, watch=watched, user=getpass.getuser):
    history = history or default_history_dir()
    (history / "night").mkdir(parents=True, exist_ok=True)
    with open(history / "night" / "run.lock", "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("night run skipped: another one runs")
            return 0
        reason = why_not(probe(["/usr/bin/pmset", "-g", "batt"]), probe(["/usr/sbin/ioreg", "-c", "IOHIDSystem", "-d", "4"]),
                         probe(["/usr/bin/stat", "-f", "%Su", "/dev/console"]), user())
        if reason:
            print(f"night run skipped: {reason}")
            return 0
        # No idle sleep while this run lasts (an assertion of this process, nothing system-wide).
        awake = subprocess.Popen(["/usr/bin/caffeinate", "-i", "-w", str(os.getpid())])
        night = history / "night" / datetime.date.today().isoformat()
        night.mkdir(parents=True, exist_ok=True)
        stamp = history / "night" / "last-digest"
        since = stamp.read_text().strip() if stamp.exists() else ""
        explore = [sys.executable, "-B", str(HERE / "explore.py"), str(args.app), "--evidence-dir", str(night),
                   "--history-dir", str(history)]
        steps = [("explore", explore)] + [(f"trace {trace.stem}", explore + ["--replay-trace", str(trace)])
                                          for trace in sorted((HERE / "traces").glob("*.jsonl"))]
        ended = []
        for name, command in steps:
            status, stopped = watch(command)
            ended.append({"name": name, "exit": status, "stopped": stopped})
            if stopped:
                break
        (night / "digest.md").write_text(digest(history, since, ended))
        stamp.write_text(utc_now_iso())
        awake.terminate()
        print(f"digest: {night / 'digest.md'}")
        return 0


def main(argv=None):
    root = argparse.ArgumentParser(prog="night.py")
    commands = root.add_subparsers(dest="command", required=True)
    installing = commands.add_parser("install")
    installing.add_argument("--app", type=Path, required=True)
    installing.add_argument("--hour", type=int, default=3, choices=range(24), metavar="0-23")
    commands.add_parser("uninstall")
    commands.add_parser("run").add_argument("--app", type=Path, required=True)
    commands.add_parser("digest")
    args = root.parse_args(argv)
    if args.command == "install":
        print(install(args.app.resolve(), args.hour))
    elif args.command == "uninstall":
        print(uninstall())
    elif args.command == "run":
        return run(args)
    else:
        stamp = default_history_dir() / "night" / "last-digest"
        print(digest(default_history_dir(), stamp.read_text().strip() if stamp.exists() else ""), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
