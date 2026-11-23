import json
import os
import pty
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


@unittest.skipUnless(shutil.which("xcrun"), "needs the Swift compiler")
class FakeAgentTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.bin = Path(cls.tmp.name) / "bin"
        cls.bin.mkdir()
        binary = cls.bin / "fake-agent"
        subprocess.run(["xcrun", "swiftc", str(HERE / "FakeAgent.swift"), "-o", str(binary)], check=True)
        for name in ("claude", "codex", "agy"):
            os.link(binary, cls.bin / name)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        self.work = Path(tempfile.mkdtemp(dir=self.tmp.name))
        self.stub_log = self.work / "hooks.log"
        stub = self.work / "Nirux"
        # What the real hook receiver gets: its arguments, and stdin unless Codex passes JSON as an argument.
        stub.write_text('#!/bin/sh\n{ printf "ARGS %s\\n" "$*"; [ "$2" = codex ] || { printf "STDIN "; cat; printf "\\n"; }; } >> "$STUB_LOG"\n')
        stub.chmod(0o755)
        self.env = {"PATH": "/usr/bin:/bin", "NIRUX_CLI_PATH": str(stub), "STUB_LOG": str(self.stub_log),
                    "NIRUX_CANARY_AGENT_LOG": str(self.work / "agents.jsonl"), "NIRUX_AGENT_UUID": "U-1"}

    def run_agent(self, name, args, lines):
        """Runs the agent in a pty, types each line once it shows its banner, and returns its output and kernel name."""
        master, slave = pty.openpty()
        process = subprocess.Popen([str(self.bin / name), *args], stdin=slave, stdout=slave, stderr=slave,
                                   cwd=self.work, env=self.env)
        os.close(slave)
        output = bytearray()
        reader = threading.Thread(target=self._read, args=(master, output), daemon=True)
        reader.start()
        self._wait(lambda: b"session" in output, "banner")
        comm = subprocess.run(["ps", "-o", "ucomm=", "-p", str(process.pid)], capture_output=True, text=True).stdout.strip()
        for line in lines:
            os.write(master, line.encode() + b"\r")
        self.assertEqual(process.wait(timeout=20), 0)
        reader.join(5)
        os.close(master)
        return bytes(output).decode(errors="replace"), comm

    @staticmethod
    def _read(master, output):
        while True:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                return
            if not chunk:
                return
            output.extend(chunk)

    @staticmethod
    def _wait(condition, what, timeout=10):
        end = time.monotonic() + timeout
        while not condition():
            if time.monotonic() > end:
                raise TimeoutError(what)
            time.sleep(0.02)

    def hooks(self):
        lines = self.stub_log.read_text().splitlines() if self.stub_log.exists() else []
        return [json.loads(line[6:]) for line in lines if line.startswith("STDIN ")], [line[5:] for line in lines if line.startswith("ARGS ")]

    def log(self):
        return [json.loads(line) for line in (self.work / "agents.jsonl").read_text().splitlines()]

    def test_claude_plays_turns_through_its_hooks_under_its_own_name(self):
        _, comm = self.run_agent("claude", ["--resume", "abc"], ["hello", "ask:which", "A", "exit"])
        self.assertEqual(comm, "claude")  # what Nirux's process table reads
        payloads, args = self.hooks()
        self.assertEqual(set(args), {"--hook claude"})
        self.assertEqual([p["hook_event_name"] for p in payloads],
                         ["SessionStart", "UserPromptSubmit", "Stop", "UserPromptSubmit", "Stop", "Stop", "SessionEnd"])
        self.assertEqual({p["session_id"] for p in payloads}, {"abc"})
        self.assertEqual(payloads[0]["source"], "resume")
        self.assertEqual(payloads[4]["last_assistant_message"], "Which one do you want: A or B?")
        log = self.log()
        self.assertEqual(log[0]["argv"], ["--resume", "abc"])
        self.assertEqual(log[0]["agentUUID"], "U-1")
        self.assertIn("hello\r", "".join(e["text"] for e in log if e["event"] == "input"))

    def test_agy_reports_its_state_and_stops_mid_work(self):
        output, comm = self.run_agent("agy", [], ["background:build", "go", "exit"])
        self.assertEqual(comm, "agy")
        payloads, args = self.hooks()
        self.assertEqual(set(args), {"--hook claude --agy"})
        self.assertEqual([p["hookEventName"] for p in payloads], ["SessionStart", "Stop", "Stop"])
        states = [part.split(":")[0] for part in output.split("\x1b]7501;")[1:]]
        self.assertEqual(states, ["state=idle", "state=working", "state=done", "state=working", "state=working", "state=done"])
        self.assertIn("app=antigravity", output)

    def test_codex_notifies_turn_ends_with_json_arguments(self):
        output, comm = self.run_agent("codex", ["resume", "t1"], ["hi", "exit"])
        self.assertEqual(comm, "codex")
        _, args = self.hooks()
        self.assertEqual(len(args), 1)
        self.assertTrue(args[0].startswith("--hook codex "))
        notify = json.loads(args[0][len("--hook codex "):])
        self.assertEqual((notify["type"], notify["thread-id"], notify["input-messages"]), ("agent-turn-complete", "t1", ["hi"]))
        self.assertIn("app=codex", output)


if __name__ == "__main__":
    unittest.main()
