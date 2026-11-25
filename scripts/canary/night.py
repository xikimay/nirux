"""The canary's night run, off until a person installs it. A LaunchAgent starts it at --hour; it
explores the hidden copy and replays the kept traces only on AC power, with this user's session
in front and idle for 30 minutes, and stops the moment the keyboard or mouse is touched. The
morning digest lists what the ledger got since the last one, with each incident's replay command.

  night.py install --app PATH [--hour 3]   writes and loads ~/Library/LaunchAgents/<LABEL>.plist
  night.py uninstall                       unloads and removes it
  night.py run --app PATH                  what the LaunchAgent starts
  night.py digest                          prints the digest of what came since the last one
"""

import argparse
import datetime
import getpass
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from history import default_history_dir  # noqa: E402

LABEL = "com.xikimay.nirux.canary-night"
IDLE_TO_START = 30 * 60
# Idle for less than this while running: someone is back.
TOUCHED = 60
PLIST = Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"


def on_ac_power(pmset):
    """From pmset -g batt: "Now drawing from 'AC Power'"."""
    return "'AC Power'" in (pmset.splitlines() or [""])[0]


def idle_seconds(ioreg):
    """From ioreg -c IOHIDSystem: the time since the last keyboard or mouse event."""
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
    return subprocess.run(command, capture_output=True, text=True, timeout=10).stdout


def current_idle():
    return idle_seconds(probe(["/usr/sbin/ioreg", "-c", "IOHIDSystem", "-d", "4"]))


def watched(command, idle=current_idle, sleep=time.sleep, interval=5, **popen):
    """Runs \`command\`; stops its process group once someone touches the keyboard or mouse.
    (exit status, whether it was stopped)."""
    process = subprocess.Popen(command, start_new_session=True, **popen)
    while process.poll() is None:
        if idle() < TOUCHED:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            return process.returncode, True
        sleep(interval)
    return process.returncode, False


def launch_agent(app, hour, python=sys.executable):
    """The LaunchAgent: started at \`hour\` every night, never at load, its output in the history."""
    logs = default_history_dir() / "night"
    return {
        "Label": LABEL,
        "ProgramArguments": [python, "-B", str(HERE / "night.py"), "run", "--app", str(app)],
        "StartCalendarInterval": {"Hour": hour, "Minute": 0},
        "RunAtLoad": False,
        "ProcessType": "Background",
        "LowPriorityIO": True,
        "StandardOutPath": str(logs / "night.log"),
        "StandardErrorPath": str(logs / "night.log"),
    }


def digest(history, since):
    """The ledger's events after \`since\` (ISO), as markdown: incidents first, with their replay commands."""
    events_path = history / "events.jsonl"
    events = [json.loads(line) for line in events_path.read_text().splitlines()] if events_path.exists() else []
    recent = [event for event in events if event.get("timestamp", "") > since]
    incidents = [event for event in recent if event["type"] == "incident"]
    passes = [event for event in recent if event["type"] == "pass"]
    lines = [f"# Canary night digest, {datetime.date.today().isoformat()}", "",
             f"{len(incidents)} incident(s), {len(passes)} clean run(s) since {since or 'the start'}.", ""]
    for event in incidents:
        components, folder = event.get("components") or {}, event.get("investigationDir")
        lines.append(f"- **{event['scenario']}** · {components.get('rule', '?')} ({event['classification']}): "
                     f"{components.get('detail', '')}")
        if folder:
            lines.append(f"  Replay: scripts/canary.sh {folder}/Nirux.app.zip --explore --replay-trace {folder}/trace.jsonl")
    return "\n".join(lines) + "\n"


def run(args, history=None):
    history = history or default_history_dir()
    reason = why_not(probe(["/usr/bin/pmset", "-g", "batt"]), probe(["/usr/sbin/ioreg", "-c", "IOHIDSystem", "-d", "4"]),
                     probe(["/usr/bin/stat", "-f", "%Su", "/dev/console"]), getpass.getuser())
    if reason:
        print(f"night run skipped: {reason}")
        return 0
    night = history / "night" / datetime.date.today().isoformat()
    night.mkdir(parents=True, exist_ok=True)
    stamp = history / "night" / "last-digest"
    since = stamp.read_text().strip() if stamp.exists() else ""
    explore = [sys.executable, "-B", str(HERE / "explore.py"), str(args.app), "--evidence-dir", str(night), "--history-dir", str(history)]
    steps = [explore] + [explore + ["--replay-trace", str(trace)] for trace in sorted((HERE / "traces").glob("*.jsonl"))]
    for step in steps:
        _, stopped = watched(step)
        if stopped:
            print("night run stopped: someone is back")
            break
    (night / "digest.md").write_text(digest(history, since))
    stamp.write_text(datetime.datetime.now(datetime.timezone.utc).isoformat())
    print(f"digest: {night / 'digest.md'}")
    return 0


def main(argv=None):
    root = argparse.ArgumentParser(prog="night.py")
    commands = root.add_subparsers(dest="command", required=True)
    install = commands.add_parser("install")
    install.add_argument("--app", type=Path, required=True)
    install.add_argument("--hour", type=int, default=3)
    commands.add_parser("uninstall")
    commands.add_parser("run").add_argument("--app", type=Path, required=True)
    commands.add_parser("digest")
    args = root.parse_args(argv)
    domain = f"gui/{os.getuid()}"
    if args.command == "install":
        (default_history_dir() / "night").mkdir(parents=True, exist_ok=True)
        PLIST.parent.mkdir(parents=True, exist_ok=True)
        PLIST.write_bytes(plistlib.dumps(launch_agent(args.app.resolve(), args.hour)))
        subprocess.run(["/bin/launchctl", "bootstrap", domain, str(PLIST)], check=True)
        print(f"night run on: {PLIST}")
    elif args.command == "uninstall":
        subprocess.run(["/bin/launchctl", "bootout", f"{domain}/{LABEL}"], check=False)
        PLIST.unlink(missing_ok=True)
        print("night run off")
    elif args.command == "run":
        return run(args)
    else:
        stamp = default_history_dir() / "night" / "last-digest"
        print(digest(default_history_dir(), stamp.read_text().strip() if stamp.exists() else ""), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
