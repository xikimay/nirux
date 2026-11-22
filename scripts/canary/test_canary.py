import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import uuid

from run import (App, environment, fixture, InfrastructureError, manifest, read_replay,
                 Report, checksum, verify_layout, wait_for, write_json)


class CanaryTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.work = Path(tmp.name).resolve()
        self.seed = str(uuid.uuid4())

    def test_environment_is_an_allowlist(self):
        with patch.dict(os.environ, {"GH_TOKEN": "personal", "SSH_AUTH_SOCK": "personal",
                                     "FUTURE_TOKEN": "personal", "NIRUX_ALLOW_REAL_STATE": "1",
                                     "NIRUX_MERGE_QUEUE_LIVE": "1", "NIRUX_STATE_DIR": "/real"}):
            env = environment(self.work)
        self.assertEqual(set(env), {
            "PATH", "LANG", "HOME", "CFFIXED_USER_HOME", "ZDOTDIR", "SHELL", "TMPDIR",
            "XDG_CONFIG_HOME", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "GIT_CONFIG_NOSYSTEM",
            "GIT_CONFIG_GLOBAL", "GIT_TERMINAL_PROMPT", "NIRUX_STATE_DIR",
            "NIRUX_SKIP_HOOK_INSTALL", "NIRUX_MERGE_QUEUE_LIVE",
        })
        self.assertEqual(env["NIRUX_STATE_DIR"], str(self.work / "state"))
        self.assertEqual(env["HOME"], str(self.work / "home"))
        self.assertEqual(env["NIRUX_SKIP_HOOK_INSTALL"], "1")
        self.assertEqual(env["SHELL"], "/bin/zsh")
        self.assertEqual(env["NIRUX_MERGE_QUEUE_LIVE"], "")

    def test_replay_recovers_inputs_and_checks_the_archive(self):
        data = manifest(self.seed, "monaco")
        archive = self.work / "Nirux.app.zip"
        archive.write_bytes(b"recorded bytes")
        write_json(self.work / "manifest.json", dict(data, bundleSHA256=checksum(archive)))
        self.assertEqual(read_replay(self.work), (self.seed, "monaco", archive))
        archive.write_bytes(b"changed bytes")
        with self.assertRaisesRegex(ValueError, "checksum"):
            read_replay(self.work)

    def test_report_keeps_completed_steps_and_attributes_failure(self):
        report = Report(manifest(self.seed, "quit"))
        with report.step("ghostty"):
            pass
        with self.assertRaisesRegex(RuntimeError, "injected"), report.step("quit"):
            self.fail("injection should precede the action")
        self.assertEqual(report.data["failedStep"], "quit")
        self.assertEqual([s["verdict"] for s in report.data["steps"]], ["pass", "fail"])
        self.assertTrue(all(s["durationMs"] >= 0 for s in report.data["steps"]))

    def test_missing_ax_is_infrastructure(self):
        report = Report(manifest(self.seed, None))
        with self.assertRaises(InfrastructureError), report.step("preflight"):
            raise InfrastructureError("accessibility unavailable")
        self.assertEqual(report.data["verdict"], "infra_unavailable")
        self.assertEqual(report.data["failedStep"], "preflight")

    def test_restore_requires_an_editor_created_after_launch(self):
        for name in ("state", "home"):
            (self.work / name).mkdir()
        fixture(self.work, environment(self.work), self.seed)
        path = self.work / "state/state.json"
        state = json.loads(path.read_text())
        self.assertTrue((self.work / "worktree/.git").is_file())
        with self.assertRaises(RuntimeError):
            verify_layout(self.work, self.seed)
        state["workspaces"][0]["columns"].append({
            "columnType": "editor", "editorActiveFile": str(self.work / "worktree/README.md"),
        })
        write_json(path, state)
        verify_layout(self.work, self.seed)

    def test_cleanup_finds_a_shell_that_outlived_its_parent(self):
        report = Report(manifest(self.seed, None))
        app = App(self.work, self.work, report, lambda: None)
        with app.lease.open("rb") as lease:
            app.process = subprocess.Popen(["/bin/zsh", "-fc", "/bin/zsh -fc 'sleep 30; exit' &"],
                                           pass_fds=(lease.fileno(),), start_new_session=True)
        report.data["processes"].append({"pid": app.process.pid})
        try:
            app.process.wait(timeout=5)
            wait_for("shell disappeared early", app.holders, timeout=3)
        finally:
            app.cleanup()
        self.assertEqual(app.holders(), [])


if __name__ == "__main__":
    unittest.main()
