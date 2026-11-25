"""Explore a canary copy of Nirux with Claude, whose only tools are the
explorer's MCP server (explorer_mcp.py): no shell, no file tool, no other
MCP server.

  scripts/canary.sh Nirux.app --explore [--goal TEXT]... [--episodes 4]
      [--calls 50] [--episode-calls 12] [--renders 6] [--minutes 20]
      [--model opus] [--evidence-dir DIR] [--history-dir DIR]

The copy runs hidden (no focus taken, nothing in front) in the two-space
world of multi-agent-routing, a fake claude in each task's terminal. Each
episode is a fresh `claude -p` toward one goal; the server refuses past the
run's budget, and the runner stops the last episode at the deadline. The run
folder keeps the report, the trace, the findings and the agent's notes
(digest.md, to verify). Each distinct finding goes to the incident ledger as
intermittent: one exploration hasn't reproduced it yet.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
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

from channel import Channel, ChannelError, new_token  # noqa: E402
from crash_correlator import correlate_crash_reports, is_unexpected_process_exit  # noqa: E402
from explorer_mcp import ACTIONS, Explorer  # noqa: E402
from history import IncidentLedger, default_history_dir  # noqa: E402
from run import (  # noqa: E402
    App, InfrastructureError, Report, detect_changed_files_from_git, detect_commit, package, wait_for, write_json,
)
from scenarios import fixture_multi_agent  # noqa: E402
from triage import normalize_error_text  # noqa: E402

SCENARIO = "explore"
EXIT_FINDINGS = 1
# After a replay's last call, what it set off has this long to happen.
SETTLE_SECONDS = 3
EXIT_INFRA = 2

# Each goal with the paths whose change puts it first (pick_goals).
GOALS = (
    ("keys", r"KeyHandling|/Input/|KeyMapper|Canary|Terminal",
     "Move between the two spaces and their tasks with keyboard shortcuts and the menus while the agents work. "
     "Type into each agent and check that what you type always reaches the terminal that has the keyboard."),
    ("waiting", r"Agent|Mission|Hook|Permission|TurnEnd|Attention",
     "Make one agent ask a question (type 'ask: Shall I merge?' then Return) and the other ask a permission "
     "('permission: Bash'). Answer them from the sidebar and from the terminal; the amber state must come and go "
     "with a visible reason."),
    ("columns", r"Editor|WebView|Column|Monaco|BranchReview",
     "Open an editor column and a browser column beside an agent, move between columns, close and reopen them, "
     "and check that the keyboard follows the focus."),
    ("tasks", r"Palette|Workspace|Space|Sidebar|Menu",
     "Use the command palette (shift-command-P), the Space and Workspace menus: open, rename, close and reopen "
     "tasks, and check that the sidebar stays consistent."),
)


def pick_goals(changed, count):
    """The goals the changed paths touch first, then the others, in order."""
    touched = [goal for goal in GOALS if any(re.search(goal[1], path) for path in changed)]
    return [text for _, _, text in touched + [goal for goal in GOALS if goal not in touched]][:count]


def ddmin(items, reproduces):
    """A 1-minimal subsequence of `items` for which `reproduces` holds (Zeller's ddmin)."""
    granularity = 2
    while len(items) >= 2:
        size = -(-len(items) // granularity)
        chunks = [items[start:start + size] for start in range(0, len(items), size)]
        smaller = next((chunk for chunk in chunks if reproduces(chunk)), None)
        if smaller is not None:
            items, granularity = smaller, 2
            continue
        complements = ([item for other, chunk in enumerate(chunks) if other != index for item in chunk]
                       for index in range(len(chunks)))
        smaller = next((complement for complement in complements if reproduces(complement)), None)
        if smaller is not None:
            items, granularity = smaller, max(granularity - 1, 2)
        elif granularity >= len(items):
            break
        else:
            granularity = min(len(items), granularity * 2)
    return items


SYSTEM_PROMPT = """You test Nirux, a macOS app where coding agents run in terminal columns, grouped in tasks \
(workspaces) and spaces, with a sidebar of tasks and a command bar. You reach a copy of it only through the canary \
tools, as a person would: menus, labelled controls, keys, typed text.

The copy runs on synthetic data: two spaces (Canary Alpha, Canary Beta), one task in each (Alpha Parent, \
Beta Child, a Mission of Alpha Parent), each with a fake agent named claude in its terminal. A fake agent reads \
lines: "ask: <anything>" ends its turn on its one question, "Which one do you want: A or B?"; \
"permission: <tool>" asks for a permission to use that tool; "exit" quits; anything else is a prompt it answers \
with one turn. Their texts are synthetic: judge what Nirux shows of them, not their wording.

Work toward the goal you are given, and take unexpected but legitimate paths a hurried person might: fast \
switches, closing and reopening, typing while something opens, shortcuts. After each action the canary runs its \
checks: a "CHECK FAILED" line is a bug. Then try once to reach the same state again, and go on. Call note() \
for anything that looks wrong although no check failed (a wrong label, a lost focus, a stale count).

Your tool calls are counted. When a tool says the budget is spent, stop. End with a short report: what you did, \
which checks failed and how, what you noted."""

# The explorer's world: every terminal runs a fake claude, never a shell
# the agent could type commands into (explore.sb confines it besides).
AUTOSTART = """
[[ -o interactive ]] && NIRUX_CANARY_AGENT_LOG="$NIRUX_STATE_DIR/agent-$NIRUX_AGENT_UUID.jsonl" exec claude
"""

# What claude keeps of the runner's environment: its login, never an API key.
CLAUDE_ENVIRONMENT = ("HOME", "USER", "LOGNAME", "PATH", "SHELL", "LANG", "TERM", "TMPDIR", "CLAUDE_CONFIG_DIR")


def claude_environment(environ):
    return {key: environ[key] for key in CLAUDE_ENVIRONMENT if key in environ}


def claude_command(claude, *, model, goal, server_environment, max_turns, max_usd):
    config = {"mcpServers": {"canary": {
        "command": sys.executable, "args": ["-B", str(HERE / "explorer_mcp.py")], "env": server_environment,
    }}}
    return [
        claude, "-p", "Goal: " + goal, "--model", model,
        "--mcp-config=" + json.dumps(config), "--strict-mcp-config",
        "--tools", "", "--allowedTools=mcp__canary",
        "--disable-slash-commands", "--no-session-persistence", "--setting-sources", "",
        "--max-budget-usd", f"{max_usd:.2f}",
        "--settings", json.dumps({"disableAllHooks": True}),
        "--system-prompt", SYSTEM_PROMPT,
        "--output-format", "stream-json", "--verbose", "--max-turns", str(max_turns),
    ]


def last_result(log):
    """The stream's `result` event: turns, usage, cost and the final report."""
    result = {}
    if log.exists():
        for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("type") == "result":
                result = event
    return result


def read_jsonl(path):
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def distinct_findings(findings):
    """One per rule and normalized detail, with its fingerprint."""
    seen = {}
    for finding in findings:
        detail = normalize_error_text(finding["detail"])
        fingerprint = hashlib.sha256(f"{SCENARIO}|{finding['rule']}|{detail}".encode()).hexdigest()
        seen.setdefault(fingerprint, {"fingerprint": fingerprint, "rule": finding["rule"], "detail": detail,
                                      "firstCall": finding.get("call"), "episode": finding.get("episode")})
    return list(seen.values())


def digest(notes):
    lines = ["# To verify", "", "What the explorer noted although no check failed.", ""]
    lines += [f"- Episode {note['episode']}, call {note['call']}: {note['text']}" for note in notes]
    return "\n".join(lines) + "\n"


def build_world(app, work, seed):
    for name in ("state", "tmp", "home"):
        (work / name).mkdir(mode=0o700)
    world = fixture_multi_agent(work, app.env, seed)
    app.tree = world["treeAlpha"]
    agents = [app.fake_agent(name) for name in ("claude", "codex", "agy")]
    app.env["PATH"] = f"{agents[0].parent}:{app.env['PATH']}"
    with (work / "home/.zshrc").open("a", encoding="utf-8") as rc:
        rc.write(AUTOSTART)
    return world


def run_episode(index, goal, *, claude, args, evidence, server_environment, deadline, max_usd):
    folder = evidence / f"episode-{index}"
    folder.mkdir()
    log = folder / "claude.jsonl"
    command = claude_command(claude, model=args.model, goal=goal, server_environment=dict(
        server_environment, CANARY_EPISODE=str(index), CANARY_EPISODE_ACTIONS=str(args.episode_calls),
    ), max_turns=args.episode_calls + 2, max_usd=max_usd)
    timed_out = False
    with log.open("wb") as out:
        process = subprocess.Popen(command, cwd=folder, env=claude_environment(os.environ), stdin=subprocess.DEVNULL,
                                   stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            process.wait(timeout=max(1.0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
    result = last_result(log)
    return {"episode": index, "goal": goal, "exitCode": process.returncode, "timedOut": timed_out,
            "subtype": result.get("subtype"), "turns": result.get("num_turns"), "usage": result.get("usage"),
            "costUSD": result.get("total_cost_usd"), "report": result.get("result")}


def replay(trace, explorer, sleep=time.sleep):
    """The trace's calls again, at their pace (3 s at most between two), without a model."""
    last = trace[0]["at"] if trace else 0
    for record in trace:
        sleep(min(3.0, max(0.0, record["at"] - last)))
        last = record["at"]
        if record["tool"] != "note":
            explorer.call(record["tool"], record["arguments"])


def quit_hidden(app, channel):
    """⌘Q, as a person quits; True once the app exited."""
    try:
        channel.key("q", key_code=12, modifiers=["command"])
        app.process.wait(timeout=20)
    except (ChannelError, subprocess.TimeoutExpired):
        return False
    app.report.data["processes"][-1].update(exitCode=app.process.returncode, endedAt=time.time())
    return True


def finish(report, evidence, findings, episodes):
    """The run's report: the server's findings and the runner's, the notes as a digest."""
    findings = read_jsonl(evidence / "findings.jsonl") + findings
    notes = read_jsonl(evidence / "notes.jsonl")
    (evidence / "digest.md").write_text(digest(notes), encoding="utf-8")
    report.data.update(
        verdict="fail" if findings else "pass", episodes=episodes, findings=distinct_findings(findings),
        notes=len(notes), budget=json.loads((evidence / "budget.json").read_text()),
    )
    return report.data


def explore(args, evidence, work, trace=None):
    """One run: Claude's episodes, or `trace` replayed without a model."""
    claude = shutil.which("claude")
    if not claude:
        raise InfrastructureError("claude is not on PATH")
    seed = str(uuid.uuid4())
    metadata = {"version": 2, "scenario": SCENARIO, "seed": seed, "injectFailure": None,
                "goals": args.goal or pick_goals(changed_paths(args), args.episodes), "model": args.model,
                "budget": {"calls": args.calls, "episodeCalls": args.episode_calls, "renders": args.renders,
                           "minutes": args.minutes}}
    report = Report(metadata)
    app = App(work, evidence, report, lambda: None)
    for name in ("stdout.log", "stderr.log"):
        (evidence / name).touch()
    package(work, evidence, args.app, args.app.suffix == ".zip", metadata)
    report.data["bundleSHA256"] = metadata["bundleSHA256"]
    build_world(app, work, seed)
    token = new_token()
    app.env["NIRUX_CANARY_TOKEN"] = token
    channel = Channel(work / "state", token)
    calls, renders = (len(trace), len(trace)) if trace is not None else (args.calls, args.renders)
    write_json(evidence / "budget.json", {"calls": 0, "callLimit": calls, "renders": 0, "renderLimit": renders})
    deadline = time.monotonic() + args.minutes * 60
    episodes, findings = [], []
    try:
        try:
            app.launch(channel=channel, profile=HERE / "explore.sb")
        except RuntimeError as error:
            # Nirux exited before its channel answered: a crash at launch.
            findings.append({"rule": "app-alive", "detail": f"Nirux exited at launch: {error}", "episode": None,
                             "call": None})
            return finish(report, evidence, findings, [])
        server_environment = {
            "NIRUX_STATE_DIR": str(work / "state"), "NIRUX_CANARY_TOKEN": token,
            "CANARY_EXPLORER_RUN": str(evidence), "CANARY_APP_PID": str(app.process.pid),
            "CANARY_APP_STDERR": str(evidence / "stderr.log"),
        }
        goals = metadata["goals"]
        if trace is not None:
            replay(trace, Explorer(dict(server_environment, CANARY_EPISODE_ACTIONS=str(len(trace))), channel=channel))
            time.sleep(SETTLE_SECONDS)
        for index in range(1, 0 if trace is not None else args.episodes + 1):
            budget = json.loads((evidence / "budget.json").read_text())
            if budget["calls"] >= budget["callLimit"] or time.monotonic() >= deadline or app.process.poll() is not None:
                break
            spent = sum(episode.get("costUSD") or 0 for episode in episodes)
            if spent >= args.max_usd:
                break
            episodes.append(run_episode(index, goals[(index - 1) % len(goals)], claude=claude, args=args,
                                        evidence=evidence, server_environment=server_environment, deadline=deadline,
                                        max_usd=args.max_usd - spent))
        if app.process.poll() is not None:
            # Between two actions, so no check saw it; a status 0 is a quit nobody asked for.
            findings.append({"rule": "app-alive", "detail": f"Nirux quit by itself (status {app.process.returncode})",
                             "episode": len(episodes), "call": None})
        elif quit_hidden(app, channel):
            try:
                wait_for("children outlived the app", lambda: not app.holders(), timeout=5)
            except TimeoutError:
                findings.append({"rule": "no-orphan-process", "detail": f"{len(app.holders())} children outlived Nirux",
                                 "episode": None, "call": None})
    finally:
        app.cleanup()
        processes = report.data["processes"]
        if any(is_unexpected_process_exit(process) for process in processes):
            report.data["crashes"] = correlate_crash_reports(processes, None, evidence, wait_seconds=2.0)
            findings.append({"rule": "app-alive", "detail": "Nirux exited unexpectedly", "episode": None, "call": None})
    return finish(report, evidence, findings, episodes)


def changed_paths(args):
    return detect_changed_files_from_git(args.diff_base) if args.diff_base else []


def reduce(args, root):
    """The trace's fewest calls that still bring back its finding (by rule), as reduced.jsonl."""
    trace = [record for record in read_jsonl(args.reduce) if record["tool"] != "note" and not record.get("refused")]
    findings = json.loads((args.reduce.parent / "report.json").read_text()).get("findings") or [{}]
    rule = args.rule or findings[0].get("rule")
    attempts = []

    def reproduces(calls):
        evidence = Path(tempfile.mkdtemp(dir=root, prefix="reduce-"))
        with tempfile.TemporaryDirectory(dir="/private/tmp", prefix="nirux-canary-") as folder:
            data = explore(args, evidence, Path(folder), trace=calls)
        write_json(evidence / "report.json", data)
        attempts.append({"calls": [call["call"] for call in calls], "reproduced": any(
            finding["rule"] == rule for finding in data["findings"])})
        return attempts[-1]["reproduced"]

    if not reproduces(trace):
        reduced = None
    else:
        # Looks change nothing as a rule: one replay may drop them all.
        actions = [record for record in trace if record["tool"] in ACTIONS]
        reduced = ddmin(actions if len(actions) < len(trace) and reproduces(actions) else trace, reproduces)
    result = {"rule": rule, "from": len(trace), "reduced": [r["call"] for r in reduced] if reduced else None,
              "replays": len(attempts), "attempts": attempts}
    write_json(root / "reduction.json", result)
    if reduced:
        (root / "reduced.jsonl").write_text("".join(json.dumps(r, sort_keys=True) + "\n" for r in reduced))
    return result


def record(ledger, data, evidence, commit, reproduced=()):
    """A finding a replay brought back is a regression; one exploration's, intermittent."""
    run_id = evidence.name
    if not data["findings"]:
        ledger.record_pass(SCENARIO, run_id=run_id, commit=commit, bundle_sha256=data.get("bundleSHA256"))
    for finding in data["findings"]:
        ledger.record_incident(
            finding["fingerprint"], {"scenario": SCENARIO, "rule": finding["rule"], "detail": finding["detail"]},
            "regression" if finding["fingerprint"] in reproduced else "intermittent",
            run_id=run_id, commit=commit, bundle_sha256=data.get("bundleSHA256"),
            crashed=finding["rule"] == "app-alive", investigation_dir=evidence,
        )


def parser():
    root = argparse.ArgumentParser(prog="canary.sh --explore")
    root.add_argument("app", type=Path)
    root.add_argument("--explore", action="store_true", help=argparse.SUPPRESS)
    root.add_argument("--goal", action="append", help="a goal for the episodes, in turn (default: the built-in four)")
    root.add_argument("--episodes", type=int, default=4)
    root.add_argument("--calls", type=int, default=50, help="tool calls for the whole run")
    root.add_argument("--episode-calls", type=int, default=12)
    root.add_argument("--renders", type=int, default=6)
    root.add_argument("--minutes", type=float, default=20)
    root.add_argument("--model", default="opus")
    root.add_argument("--max-usd", type=float, default=3.0, help="dollars for the whole run (claude --max-budget-usd)")
    root.add_argument("--evidence-dir", type=Path)
    root.add_argument("--history-dir", type=Path)
    root.add_argument("--replay-trace", type=Path, help="replay a run's trace.jsonl without a model")
    root.add_argument("--reduce", type=Path, help="shrink a run's trace.jsonl to the calls that bring back its finding")
    root.add_argument("--rule", help="with --reduce: the finding's rule (default: the run's first finding)")
    root.add_argument("--diff-base", help="put first the goals that the files changed since this ref touch")
    return root


def main(argv=None):
    args = parser().parse_args(argv)
    root = args.evidence_dir or Path(tempfile.mkdtemp(prefix="nirux-evidence-"))
    root.mkdir(parents=True, exist_ok=True)
    if args.reduce:
        result = reduce(args, root.resolve())
        print(json.dumps({key: result[key] for key in ("rule", "from", "reduced", "replays")}))
        return 0 if result["reduced"] else EXIT_FINDINGS
    evidence = Path(tempfile.mkdtemp(dir=root.resolve(), prefix="explore-"))
    trace = read_jsonl(args.replay_trace) if args.replay_trace else None
    with tempfile.TemporaryDirectory(dir="/private/tmp", prefix="nirux-canary-") as folder:
        try:
            data = explore(args, evidence, Path(folder), trace=trace)
        except InfrastructureError as error:
            write_json(evidence / "report.json", {"scenario": SCENARIO, "verdict": "infra_unavailable", "error": str(error)})
            print(json.dumps({"report": str(evidence / "report.json"), "verdict": "infra_unavailable", "error": str(error)}))
            return EXIT_INFRA
    write_json(evidence / "report.json", data)
    original = args.replay_trace.parent / "report.json" if args.replay_trace else None
    reproduced = {f["fingerprint"] for f in data["findings"]} & (
        {f["fingerprint"] for f in json.loads(original.read_text())["findings"]} if original and original.exists() else set())
    record(IncidentLedger(args.history_dir or default_history_dir()), data, evidence, detect_commit(), reproduced)
    print(json.dumps({"report": str(evidence / "report.json"), "verdict": data["verdict"],
                      "findings": len(data["findings"]), "notes": data["notes"], "calls": data["budget"]["calls"]}))
    return EXIT_FINDINGS if data["findings"] else 0


if __name__ == "__main__":
    sys.exit(main())
