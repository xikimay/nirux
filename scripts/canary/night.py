"""The canary's night, on GitHub Actions (.github/workflows/canary-night.yml). Claude explores the
newest nightly build, the one Sparkle installs, in a hidden copy (50 calls, $3), then the kept traces
replay in fresh copies. The job summary says which app was tested, how each step ended, and each
incident with the replay its evidence allows; the night's incidents go to one open issue labelled canary.

  night.py run ROOT     downloads and checks the nightly, explores it, replays the traces, digests
  night.py issue BODY   comments on the open issue labelled canary, or opens it

Without the CLAUDE_CODE_OAUTH_TOKEN secret the exploration is skipped and the traces still replay.
The token goes to the exploration's claude alone: never to the copy, the traces or the job's log.
"""

import argparse
import datetime
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
NIGHTLY_ZIP = "https://github.com/xikimay/nirux/releases/download/nightly/Nirux.app.zip"
TOKEN = "CLAUDE_CODE_OAUTH_TOKEN"
NO_TOKEN = (f"skipped: no {TOKEN} secret (`claude setup-token`, then `gh secret set {TOKEN}`); "
            "the kept traces still replay")
STEP_ENDS = {0: "clean", 1: "findings", 2: "infra unavailable"}


class Unusable(Exception):
    """Why the nightly can't be tested."""


def tool(why, command, timeout):
    """Runs a system tool; when it fails, raises Unusable("why: its last line")."""
    try:
        subprocess.run(command, check=True, capture_output=True, text=True, timeout=timeout)
    except subprocess.CalledProcessError as error:
        said = (error.stderr or error.stdout or "").strip().splitlines()
        raise Unusable(f"{why}: {said[-1] if said else f'exit {error.returncode}'}") from None
    except (subprocess.TimeoutExpired, OSError) as error:
        raise Unusable(f"{why}: {error}") from None


def curl(url, target):
    tool("download failed", ["/usr/bin/curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https",
                             "--proto-redir", "=https", "--max-time", "600", "--output", str(target), url], 660)


def build_number(app):
    """CFBundleVersion: a nightly's yyyymmddHHMM."""
    try:
        with open(app / "Contents/Info.plist", "rb") as info:
            return int(plistlib.load(info)["CFBundleVersion"])
    except (OSError, KeyError, TypeError, ValueError):
        raise Unusable("no build number") from None


def fetch_nightly(folder, download=curl):
    """The nightly release's zip, downloaded into `folder`, once its app unpacks, its signature
    verifies and it has a build number. (zip or None, the digest's line)."""
    archive, unpacked = folder / "Nirux.app.zip", folder / "unpacked"
    folder.mkdir(parents=True, exist_ok=True)
    try:
        download(NIGHTLY_ZIP, archive)
        tool("doesn't unpack", ["/usr/bin/ditto", "-x", "-k", str(archive), str(unpacked)], 300)
        app = unpacked / "Nirux.app"
        tool("signature doesn't verify", ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], 120)
        return archive, f"nightly build {build_number(app)}"
    except Unusable as refused:
        return None, f"none, nothing ran (nightly: {refused})"
    finally:
        shutil.rmtree(unpacked, ignore_errors=True)


def run_step(command, env, log):
    """Its exit status. Its output goes to `log`, not to the job's log, where a line the copy wrote
    could read as a workflow command."""
    with open(log, "wb") as out:
        return subprocess.run(command, env=env, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT).returncode


def drop_files_holding(folder, secret):
    """Deletes the files under `folder` that hold `secret`, before they are uploaded; how many."""
    needle = secret.encode()
    held = [path for path in folder.rglob("*") if path.is_file() and not path.is_symlink() and needle in path.read_bytes()]
    for path in held:
        path.unlink()
    return len(held)


def this_job(environ):
    run, repo = environ.get("GITHUB_RUN_ID", "local"), environ.get("GITHUB_REPOSITORY", "xikimay/nirux")
    return {"id": run, "repo": repo, "artifact": f"canary-night-{run}",
            "url": f"{environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{repo}/actions/runs/{run}"}


def replay_command(folder, root, job):
    """How to replay an incident's evidence from the run's artifact."""
    shown = Path("canary-night") / Path(folder).resolve().relative_to(root.resolve())
    if not (Path(folder) / "trace.jsonl").exists():
        return f"not replayable: {shown} has no trace"
    return (f"gh run download {job['id']} --repo {job['repo']} -n {job['artifact']} -D canary-night && "
            f"scripts/canary.sh {shown}/Nirux.app.zip --explore --replay-trace {shown}/trace.jsonl")


def ledger(history):
    path = history / "events.jsonl"
    events = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    return ([event for event in events if event["type"] == "incident"],
            [event for event in events if event["type"] == "pass"])


def digest(history, root, job, app, steps):
    """The job summary: the app tested, how each step ended, each incident with its replay."""
    incidents, passes = ledger(history)
    lines = [f"# Canary night, {datetime.date.today().isoformat()}", "", f"- App: {app}"]
    lines += [f"- Step {name}: {end}" for name, end in steps]
    lines += ["", f"{len(incidents)} incident(s), {len(passes)} clean run(s). Evidence: artifact `{job['artifact']}`.", ""]
    for event in incidents:
        components = event.get("components") or {}
        lines.append(f"- **{event['scenario']}** · {components.get('rule', '?')} ({event['classification']}): "
                     f"{' '.join(str(components.get('detail', '')).split())}")
        if event.get("investigationDir"):
            lines.append(f"  Replay: `{replay_command(event['investigationDir'], root, job)}`")
    return "\n".join(lines) + "\n"


def issue_text(history, root, job, app):
    """The night's incidents for the canary issue: each rule, classification, fingerprint and replay,
    never a finding's detail or a note, which can hold text the explorer read or typed."""
    incidents, _ = ledger(history)
    lines = [f"Canary night {datetime.date.today().isoformat()} on {app}: {len(incidents)} incident(s). "
             f"[Run and summary]({job['url']}).", ""]
    for event in incidents:
        lines.append(f"- **{event['scenario']}** · {(event.get('components') or {}).get('rule', '?')} "
                     f"({event['classification']}), fingerprint `{event['fingerprint'][:12]}`")
        if event.get("investigationDir"):
            lines.append(f"  Replay: `{replay_command(event['investigationDir'], root, job)}`")
    return "\n".join(lines) + "\n"


def publish(environ, summary, outputs):
    """To the job's summary and outputs, or stdout outside Actions."""
    if "GITHUB_STEP_SUMMARY" not in environ:
        print(summary, end="")
        return
    with open(environ["GITHUB_STEP_SUMMARY"], "a") as file:
        file.write(summary)
    with open(environ["GITHUB_OUTPUT"], "a") as file:
        file.writelines(f"{key}={value}\n" for key, value in outputs.items())


def run(root, environ=os.environ, fetch=fetch_nightly, step=run_step):
    """The night. 0 when every step that ran was clean, 1 with incidents, 2 when something couldn't run."""
    evidence, history, job = root / "evidence", root / "history", this_job(environ)
    evidence.mkdir(parents=True, exist_ok=True)
    app, about = fetch(root / "nightly")
    token = environ.get(TOKEN, "")
    steps, statuses = [], []

    def explore(name, arguments, env):
        command = [sys.executable, "-B", str(HERE / "explore.py"), str(app), "--evidence-dir", str(evidence),
                   "--history-dir", str(history), *arguments]
        statuses.append(step(command, env, evidence / f"{name.replace(' ', '-')}.log"))
        steps.append((name, STEP_ENDS.get(statuses[-1], f"failed (exit {statuses[-1]})")))

    if app and token:
        explore("explore", ["--calls", "50", "--max-usd", "3"], dict(environ))
    elif app:
        print(f"::notice title=Canary night::Exploration {NO_TOKEN}")
        steps.append(("explore", NO_TOKEN))
    if app:
        explore("kept traces", ["--replay-traces", str(HERE / "traces")],
                {key: value for key, value in environ.items() if key != TOKEN})
    if token and drop_files_holding(root, token):
        steps.append(("upload", "files holding the Claude token removed from the evidence"))
    incidents, _ = ledger(history)
    if incidents:
        (root / "issue.md").write_text(issue_text(history, root, job, about))
    publish(environ, digest(history, root, job, about, steps), {"incidents": len(incidents)})
    if incidents:
        return 1
    return 0 if app and not any(statuses) else 2


def gh(*arguments):
    return subprocess.run(["gh", *arguments], check=True, capture_output=True, text=True, timeout=60).stdout.strip()


def file_issue(body, gh=gh):
    """Comments on the open issue labelled canary, or opens one."""
    number = gh("issue", "list", "--label", "canary", "--state", "open", "--limit", "1", "--json", "number", "--jq", ".[].number")
    if number:
        gh("issue", "comment", number, "--body-file", str(body))
        return f"commented on #{number}"
    gh("label", "create", "canary", "--color", "D93F0B", "--description", "Found by the canary's night run", "--force")
    return "opened " + gh("issue", "create", "--title", "Canary night: incidents", "--label", "canary", "--body-file", str(body))


def main(argv=None):
    root = argparse.ArgumentParser(prog="night.py")
    commands = root.add_subparsers(dest="command", required=True)
    commands.add_parser("run").add_argument("root", type=Path)
    commands.add_parser("issue").add_argument("body", type=Path)
    args = root.parse_args(argv)
    if args.command == "run":
        return run(args.root.resolve())
    print(file_issue(args.body))
    return 0


if __name__ == "__main__":
    sys.exit(main())
