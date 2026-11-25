import io
import json
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest import mock

import explore
import explorer_mcp
from channel import NotTaken
from history import IncidentLedger

BADGE = "1 agent waiting for you, Command J"


def snapshot(*labels):
    return json.dumps({"windows": [{"title": "Nirux", "isKey": False, "firstResponder": "TerminalView",
                                    "elements": [{"role": "AXButton", "label": label, "pressable": True} for label in labels]}]})


def terminals(alpha="", beta="", focused="Alpha"):
    return json.dumps({"terminals": [
        {"workspace": "Alpha", "column": 0, "active": True, "focused": focused == "Alpha", "text": alpha},
        {"workspace": "Beta", "column": 0, "active": False, "focused": focused == "Beta", "text": beta},
    ]})


class FakeChannel:
    """The app's channel as a script: each tool answers its queue in turn, then its last answer."""

    def __init__(self, **answers):
        self.answers = {tool: list(queue) for tool, queue in answers.items()}
        self.calls = []

    def call(self, tool, **arguments):
        self.calls.append((tool, arguments))
        queue = self.answers.get(tool) or ["ok"]
        answer = queue.pop(0) if len(queue) > 1 else queue[0]
        if isinstance(answer, Exception):
            raise answer
        return answer

    def menu(self, *path):
        return self.call("menu", path=list(path))

    def key(self, characters, key_code=0, modifiers=()):
        return self.call("key", characters=characters, keyCode=key_code, modifiers=list(modifiers))

    def text(self, text):
        return self.call("text", text=text)


class ExplorerTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name)
        (self.root / "state").mkdir()
        (self.root / "state/state.json").write_text(json.dumps({"workspaces": [{"id": "a"}], "activeWorkspaceID": "a"}))
        (self.root / "stderr.log").write_text("launched\n")
        self.budget(calls=50, renders=6)

    def tearDown(self):
        self.folder.cleanup()

    def budget(self, calls, renders):
        (self.root / "budget.json").write_text(json.dumps({"calls": 0, "callLimit": calls, "renders": 0, "renderLimit": renders}))

    def explorer(self, channel, episode_calls=12):
        return explorer_mcp.Explorer({
            "CANARY_EXPLORER_RUN": str(self.root), "NIRUX_STATE_DIR": str(self.root / "state"),
            "NIRUX_CANARY_TOKEN": "t", "CANARY_APP_STDERR": str(self.root / "stderr.log"),
            "CANARY_EPISODE": "2", "CANARY_EPISODE_ACTIONS": str(episode_calls),
        }, channel=channel)

    def lines(self, name):
        path = self.root / name
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_an_action_runs_the_checks_and_traces_itself(self):
        explorer = self.explorer(FakeChannel(snapshot=[snapshot("New Task")]))
        content, is_error = explorer.call("menu", {"path": ["Space", "Next Space"]})
        self.assertFalse(is_error)
        self.assertEqual(content[0]["text"], "ok\nChecks passed.")
        self.assertEqual(explorer.channel.calls[0], ("menu", {"path": ["Space", "Next Space"]}))
        trace = self.lines("trace.jsonl")
        self.assertEqual([(t["call"], t["episode"], t["tool"], t["failed"]) for t in trace], [(1, 2, "menu", [])])
        self.assertEqual(self.lines("findings.jsonl"), [])

    def test_amber_without_a_reason_is_a_finding(self):
        explorer = self.explorer(FakeChannel(snapshot=[snapshot(BADGE)]))
        content, _ = explorer.call("press", {"label": "Alpha Parent"})
        self.assertIn("CHECK FAILED amber-has-reason", content[0]["text"])
        self.assertEqual([(f["rule"], f["tool"], f["call"]) for f in self.lines("findings.jsonl")],
                         [("amber-has-reason", "press", 1)])
        with_reason = self.explorer(FakeChannel(snapshot=[snapshot(BADGE, "Allow Bash?")]))
        self.assertIn("Checks passed.", with_reason.call("press", {"label": "x"})[0][0]["text"])
        elsewhere = json.loads(snapshot(BADGE))
        elsewhere["windows"][0]["elements"].append(
            {"role": "AXMenuButton", "label": "Space", "value": "Canary Alpha. An agent waits for you in Canary Beta"})
        in_other_space = self.explorer(FakeChannel(snapshot=[json.dumps(elsewhere)]))
        self.assertIn("Checks passed.", in_other_space.call("press", {"label": "x"})[0][0]["text"])

    def test_a_silent_app_a_fatal_log_line_and_a_broken_state_are_findings(self):
        (self.root / "stderr.log").write_text("launched\nFatal error: Index out of range\n")
        (self.root / "state/state.json").write_text("{")
        explorer = self.explorer(FakeChannel(snapshot=[NotTaken("snapshot")]))
        explorer.stderr_offset = len("launched\n")
        text = explorer.call("key", {"characters": "k", "modifiers": ["command"]})[0][0]["text"]
        self.assertEqual(sorted(f["rule"] for f in self.lines("findings.jsonl")),
                         ["app-answers", "no-fatal-log", "state-json-valid"])
        self.assertIn("Fatal error: Index out of range", text)

    def test_typed_text_must_show_in_the_focused_terminal_only(self):
        typed = "hello agent"
        leak = FakeChannel(terminal=[terminals(), terminals(beta=typed)], text=["Sent, unconfirmed, to the terminal"],
                           snapshot=[snapshot("A")])
        text = self.explorer(leak).call("type", {"text": typed + "\n"})[0][0]["text"]
        self.assertIn("CHECK FAILED keys-reach-focused-terminal: 'hello agent' reached Beta column 0", text)
        self.assertEqual(leak.calls[1], ("text", {"text": typed + "\r"}))
        (self.root / "findings.jsonl").unlink()
        right = FakeChannel(terminal=[terminals(), terminals(alpha=typed)], text=["Sent, unconfirmed, to the terminal"],
                            snapshot=[snapshot("A")])
        self.assertIn("Checks passed.", self.explorer(right).call("type", {"text": typed})[0][0]["text"])
        self.assertFalse((self.root / "findings.jsonl").exists())

    def test_the_budget_is_the_runs_and_each_episode_has_its_share(self):
        self.budget(calls=2, renders=0)
        explorer = self.explorer(FakeChannel(snapshot=[snapshot("A")]))
        self.assertTrue(explorer.call("render", {})[1], "no renders left")
        explorer.call("look", {})
        explorer.call("look", {})
        content, is_error = explorer.call("look", {})
        self.assertTrue(is_error)
        self.assertIn("budget is spent", content[0]["text"])
        self.assertEqual(json.loads((self.root / "budget.json").read_text())["calls"], 2)
        self.budget(calls=50, renders=6)
        episode = self.explorer(FakeChannel(terminal=[terminals()]), episode_calls=1)
        self.assertFalse(episode.call("terminal", {})[1])
        self.assertIn("episode", episode.call("look", {})[0][0]["text"])

    def test_look_marks_what_is_new_and_terminal_shows_the_active_task(self):
        explorer = self.explorer(FakeChannel(snapshot=[snapshot("A"), snapshot("A", "B")],
                                             terminal=[terminals(alpha="$ ls\nREADME.md")]))
        self.assertIn("  AXButton 'A'", explorer.call("look", {})[0][0]["text"])
        self.assertIn("+ AXButton 'B'", explorer.call("look", {})[0][0]["text"])
        text = explorer.call("terminal", {})[0][0]["text"]
        self.assertEqual(text, "Alpha column 0 (keyboard):\n$ ls\nREADME.md")

    def test_a_malformed_call_is_refused_and_the_server_goes_on(self):
        explorer = self.explorer(FakeChannel(snapshot=[snapshot("A")]))
        for arguments, why in [({"text": 5}, "text must be string."), ({}, "text is required."),
                               ({"text": "x", "extra": 1}, "extra must be absent.")]:
            content, is_error = explorer.call("type", arguments)
            self.assertTrue(is_error)
            self.assertEqual(content[0]["text"], why)
        self.assertEqual(explorer.call("menu", {"path": ["Space", 3]})[0][0]["text"], "path must hold strings.")
        self.assertFalse(explorer.call("menu", {"path": ["Space", "Next Space"]})[1])
        self.assertEqual(explorer.channel.calls[0], ("menu", {"path": ["Space", "Next Space"]}))

    def test_nothing_that_opens_a_terminal_reaches_the_app(self):
        explorer = self.explorer(FakeChannel())
        for name, arguments, why in [
            ("key", {"characters": "t", "modifiers": ["command"]}, "opens no terminal"),
            ("key", {"characters": "T", "modifiers": ["command", "shift"]}, "opens no terminal"),
            ("key", {"characters": "t", "modifiers": ["command", "x"]}, "modifiers must be among command"),
            ("menu", {"path": ["Columns", "New Terminal"]}, "opens no terminal"),
            ("type", {"text": "New Terminal\n"}, "opens no terminal"),
            ("key", {"characters": "b", "modifiers": ["command"]}, "opens no browser"),
            ("menu", {"path": ["Columns", "Open Browser"]}, "opens no browser"),
            ("menu", {"path": ["Columns", "Focus Address Bar"]}, "opens no browser"),
            ("type", {"text": "open browser"}, "opens no browser"),
            ("key", {"characters": "v", "modifiers": ["command"]}, "clipboard"),
            ("key", {"characters": "c", "modifiers": ["command"]}, "clipboard"),
            ("menu", {"path": ["Edit", "Paste"]}, "clipboard"),
            ("menu", {"path": ["Edit", "Cut"]}, "clipboard"),
            ("press", {"label": "New Terminal"}, "opens no terminal"),
            ("press", {"label": "Open Browser"}, "opens no browser"),
        ]:
            content, is_error = explorer.call(name, arguments)
            self.assertTrue(is_error, arguments)
            self.assertIn(why, content[0]["text"], arguments)
        self.assertEqual(explorer.channel.calls, [])
        self.assertFalse(explorer_mcp.refused("menu", {"path": ["Columns", "Open Browser"]}, allows_browser=True))
        self.assertFalse(explorer_mcp.refused("key", {"characters": "p", "modifiers": ["command", "shift"]}))
        self.assertFalse(explorer_mcp.refused("press", {"label": "New…"}))

    def test_a_dead_app_reads_dead_although_nobody_reaped_it(self):
        child = subprocess.Popen(["/usr/bin/true"])
        explorer = explorer_mcp.Explorer({"CANARY_EXPLORER_RUN": str(self.root), "NIRUX_STATE_DIR": str(self.root),
                                          "NIRUX_CANARY_TOKEN": "t", "CANARY_APP_PID": str(child.pid)}, channel=FakeChannel())
        deadline = time.monotonic() + 5
        while explorer.alive() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(explorer.alive(), "a zombie is dead")
        child.wait()
        running = subprocess.Popen(["/bin/sleep", "5"])
        try:
            explorer.pid = running.pid
            self.assertTrue(explorer.alive())
        finally:
            running.kill()
            running.wait()

    def test_the_github_tool_changes_the_copys_github_as_from_outside(self):
        world = self.root / "github/world.json"
        world.parent.mkdir()
        world.write_text(json.dumps({"repository": "acme/widgets", "pullRequests": [
            {"number": 2, "headRefName": "canary-beta", "state": "OPEN", "checks": "pending"}]}))
        explorer = self.explorer(FakeChannel(snapshot=[snapshot("A")]))
        content, is_error = explorer.call("github", {"pull": 2, "event": "merge"})
        self.assertFalse(is_error)
        self.assertEqual(content[0]["text"], "Pull request #2: merge.\nChecks passed.")
        self.assertEqual(json.loads(world.read_text())["pullRequests"][0]["state"], "MERGED")
        explorer.call("github", {"pull": 2, "event": "checks-fail"})
        self.assertEqual(json.loads(world.read_text())["pullRequests"][0]["checks"], "failure")
        self.assertEqual(explorer.call("github", {"pull": 2, "event": "delete"})[0][0]["text"],
                         "event must be one of merge, close, reopen, checks-pass, checks-fail, checks-run.")
        self.assertIn("no pull request #9", explorer.call("github", {"pull": 9, "event": "merge"})[0][0]["text"])

    def test_notes_wait_for_a_person(self):
        self.explorer(FakeChannel()).call("note", {"text": "The badge says 2, one agent waits."})
        self.assertEqual([(n["text"], n["episode"]) for n in self.lines("notes.jsonl")],
                         [("The badge says 2, one agent waits.", 2)])

    def test_the_server_speaks_mcp_over_stdio(self):
        messages = [
            "not json",
            {"jsonrpc": "2.0", "id": 1, "method": "server/discover"},
            {"jsonrpc": "2.0", "id": 2, "method": "initialize", "params": {"protocolVersion": "2025-11-25"}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/list"},
        ]
        out = io.StringIO()
        explorer_mcp.main(io.StringIO("".join((m if isinstance(m, str) else json.dumps(m)) + "\n" for m in messages)), out, {
            "CANARY_EXPLORER_RUN": str(self.root), "NIRUX_STATE_DIR": str(self.root / "state"), "NIRUX_CANARY_TOKEN": "t",
        })
        replies = [json.loads(line) for line in out.getvalue().splitlines()]
        self.assertEqual([r["id"] for r in replies], [None, 1, 2, 3])
        self.assertEqual(replies[0]["error"]["code"], -32603, "a bad line answers an error and the server goes on")
        self.assertEqual(replies[1]["error"]["code"], -32601)
        self.assertEqual(replies[2]["result"]["protocolVersion"], "2025-11-25")
        self.assertEqual({t["name"] for t in replies[3]["result"]["tools"]},
                         {"look", "press", "menu", "key", "type", "terminal", "render", "github", "note"})


class RunnerTests(unittest.TestCase):
    def test_claude_gets_the_canary_server_and_nothing_else(self):
        command = explore.claude_command("/bin/claude", model="opus", goal="Switch spaces",
                                         server_environment={"NIRUX_CANARY_TOKEN": "t"}, max_turns=14, max_usd=2.5)
        self.assertEqual(command[:3], ["/bin/claude", "-p", "Goal: Switch spaces"])
        self.assertEqual(command[command.index("--tools") + 1], "")
        self.assertEqual(command[command.index("--setting-sources") + 1], "", "no user settings, plugins or mode")
        self.assertEqual(command[command.index("--max-budget-usd") + 1], "2.50")
        for flag in ("--strict-mcp-config", "--allowedTools=mcp__canary", "--no-session-persistence"):
            self.assertIn(flag, command)
        config = json.loads(next(a for a in command if a.startswith("--mcp-config="))[len("--mcp-config="):])
        self.assertEqual(list(config["mcpServers"]), ["canary"])
        self.assertTrue(config["mcpServers"]["canary"]["args"][-1].endswith("explorer_mcp.py"))
        self.assertEqual(json.loads(command[command.index("--settings") + 1]), {"disableAllHooks": True})
        environment = explore.claude_environment({"HOME": "/h", "PATH": "/bin", "ANTHROPIC_API_KEY": "k",
                                                  "CLAUDE_CODE_OAUTH_TOKEN": "o", "NIRUX_AGENT_UUID": "u", "NIRUX_CANARY_TOKEN": "t"})
        self.assertEqual(environment, {"HOME": "/h", "PATH": "/bin", "CLAUDE_CODE_OAUTH_TOKEN": "o"})

    def test_findings_go_to_the_ledger_once_each_and_a_clean_run_as_a_pass(self):
        findings = explore.distinct_findings([
            {"rule": "amber-has-reason", "detail": "2 waiting at 0x1234", "call": 3, "episode": 1},
            {"rule": "amber-has-reason", "detail": "2 waiting at 0x9999", "call": 9, "episode": 2},
            {"rule": "app-answers", "detail": "the app didn't answer", "call": 4, "episode": 1},
        ])
        self.assertEqual([(f["rule"], f["firstCall"]) for f in findings], [("amber-has-reason", 3), ("app-answers", 4)])
        with tempfile.TemporaryDirectory() as folder:
            ledger = IncidentLedger(Path(folder))
            explore.record(ledger, {"findings": findings, "bundleSHA256": "b"}, Path(folder) / "explore-1", "c")
            explore.record(ledger, {"findings": [], "bundleSHA256": "b"}, Path(folder) / "explore-2", "c")
            explore.record(ledger, {"findings": findings[:1], "bundleSHA256": "b"}, Path(folder) / "explore-3", "c",
                           reproduced={findings[0]["fingerprint"]})
            events = [json.loads(line) for line in (Path(folder) / "events.jsonl").read_text().splitlines()]
        self.assertEqual([(e["type"], e.get("classification")) for e in events],
                         [("incident", "intermittent"), ("incident", "intermittent"), ("pass", None),
                          ("incident", "regression")])
        self.assertEqual({e["scenario"] for e in events}, {"explore"})

    def test_a_trace_replays_its_calls_at_their_pace_without_its_notes(self):
        calls, pauses = [], []

        class Recorder:
            def call(self, name, arguments):
                calls.append((name, arguments))

        explore.replay([{"tool": "menu", "arguments": {"path": ["Space", "Next Space"]}, "at": 10.0},
                        {"tool": "note", "arguments": {"text": "odd"}, "at": 10.5},
                        {"tool": "press", "arguments": {"label": "New…"}, "at": 30.0}], Recorder(), sleep=pauses.append)
        self.assertEqual(calls, [("menu", {"path": ["Space", "Next Space"]}), ("press", {"label": "New…"})])
        self.assertEqual(pauses, [0.0, 0.5, 3.0])

    def test_ddmin_keeps_only_the_calls_the_failure_needs(self):
        tried = []

        def reproduces(calls):
            tried.append(calls)
            return {3, 7} <= set(calls)

        self.assertEqual(explore.ddmin(list(range(1, 13)), reproduces), [3, 7])
        self.assertLess(len(tried), 40)
        self.assertEqual(explore.ddmin([5], lambda calls: True), [5])

    def test_the_goals_the_diff_touches_come_first(self):
        texts = {name: text for name, _, text in explore.GOALS}
        picked = explore.pick_goals(["Sources/Nirux/Views/EditorColumn.swift", "README.md"], 2)
        self.assertEqual(picked, [texts["columns"], texts["keys"]])
        self.assertEqual(explore.pick_goals([], 4), [text for _, _, text in explore.GOALS])

    def test_a_crash_at_launch_is_a_finding_with_its_report(self):
        class CrashingApp:
            def __init__(self, work, evidence, report, check_interrupt):
                self.report, self.env, self.process = report, {"PATH": "/bin"}, None

            def launch(self, channel, profile):
                self.profile = profile
                raise RuntimeError("Nirux exited with status -11")

            def cleanup(self):
                pass

        with tempfile.TemporaryDirectory() as folder, \
                mock.patch.object(explore, "App", CrashingApp), mock.patch.object(explore, "build_world"), \
                mock.patch.object(explore, "package", lambda work, evidence, app, replay, metadata:
                                  metadata.update(bundleSHA256="b")), \
                mock.patch.object(explore.shutil, "which", return_value="/usr/local/bin/claude"):
            evidence = Path(folder)
            data = explore.explore(explore.parser().parse_args(["Nirux.app"]), evidence, evidence / "work")
            self.assertTrue((evidence / "digest.md").exists())
        self.assertEqual(data["verdict"], "fail")
        self.assertEqual([(f["rule"], f["detail"]) for f in data["findings"]],
                         [("app-alive", "Nirux exited at launch: Nirux exited with status -11")])
        self.assertEqual(data["episodes"], [])

    def test_kept_traces_replay_each_in_a_fresh_copy_and_a_failure_is_a_regression(self):
        with tempfile.TemporaryDirectory() as folder:
            root, traces = Path(folder), Path(folder) / "traces"
            traces.mkdir()
            for name in ("fixed-bug", "back-again"):
                (traces / f"{name}.jsonl").write_text(json.dumps({"tool": "menu", "arguments": {"path": ["Space"]}, "at": 1}) + "\n")
            replayed = []

            def run(trace, evidence):
                replayed.append((trace[0]["tool"], evidence.name.split("-")[1]))
                failed = "back-again" in evidence.name
                return {"verdict": "fail" if failed else "pass", "bundleSHA256": "b", "findings": [
                    {"fingerprint": "f", "rule": "app-alive", "detail": "Nirux quit by itself (status 0)"}] if failed else []}

            args = explore.parser().parse_args(["Nirux.app", "--replay-traces", str(traces)])
            code = explore.replay_kept(args, root, IncidentLedger(root / "history"), "c", run=run)
            events = [json.loads(line) for line in (root / "history/events.jsonl").read_text().splitlines()]
            summary = json.loads((root / "traces.json").read_text())
        self.assertEqual(code, explore.EXIT_FINDINGS)
        self.assertEqual(sorted(replayed), [("menu", "back"), ("menu", "fixed")])
        self.assertEqual(sorted((e["scenario"], e["type"], e.get("classification")) for e in events),
                         [("trace:back-again", "incident", "regression"), ("trace:fixed-bug", "pass", None)])
        self.assertEqual([(s["trace"], s["findings"]) for s in summary], [("back-again", 1), ("fixed-bug", 0)])

    def test_an_episode_reads_its_result_and_notes_make_the_digest(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / "claude.jsonl"
            log.write_text("\n".join([json.dumps({"type": "system", "subtype": "init"}), "not json",
                                      json.dumps({"type": "result", "num_turns": 7, "result": "Done."})]))
            self.assertEqual(explore.last_result(log)["num_turns"], 7)
        self.assertIn("- Episode 1, call 4: Stale count", explore.digest([{"episode": 1, "call": 4, "text": "Stale count"}]))
        self.assertIn("[[ -o interactive ]] && NIRUX_CANARY_AGENT_LOG=", explore.AUTOSTART)
        self.assertTrue(explore.AUTOSTART.strip().endswith("exec claude"), "every terminal runs the fake agent")


if __name__ == "__main__":
    unittest.main()
