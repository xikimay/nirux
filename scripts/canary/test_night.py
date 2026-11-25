import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

import night

HERE = Path(__file__).resolve().parent
AC = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t100%; charged; 0:00 remaining present: true\n"
BATTERY = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t80%; discharging\n"


def ioreg(seconds):
    return f'    | |   "HIDIdleTime" = {int(seconds * 1e9)}\n'


def signed_app(folder, build):
    """An ad-hoc signed Nirux.app whose CFBundleVersion is `build`."""
    app = folder / "Nirux.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    shutil.copy("/usr/bin/true", app / "Contents/MacOS/Nirux")
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(
        {"CFBundleExecutable": "Nirux", "CFBundleIdentifier": "com.example.night-fixture", "CFBundleVersion": str(build)}))
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
    return app


def released(app):
    """A download that gets `app` zipped, as the nightly release ships it."""
    return lambda url, target: subprocess.run(["/usr/bin/ditto", "-c", "-k", "--keepParent", str(app), str(target)], check=True)


def unreachable(url, target):
    night.tool("download failed", ["/bin/sh", "-c", "echo 'curl: (6) Could not resolve host: github.com' >&2; exit 6"], 5)


def gone(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    return False


class NightTests(unittest.TestCase):
    def test_it_starts_only_on_ac_with_this_users_session_idle_for_30_minutes(self):
        self.assertTrue(night.on_ac_power(AC))
        self.assertFalse(night.on_ac_power(BATTERY))
        self.assertAlmostEqual(night.idle_seconds(ioreg(1834.5)), 1834.5, places=3)
        self.assertEqual(night.why_not(BATTERY, ioreg(3600), "me\n", "me"), "on battery")
        self.assertEqual(night.why_not(AC, ioreg(3600), "root\n", "me"), "the session in front is root's")
        self.assertEqual(night.why_not(AC, ioreg(600), "me\n", "me"), "idle for 10 min only")
        self.assertIsNone(night.why_not(AC, ioreg(1801), "me\n", "me"))

    def test_a_probe_that_hangs_reads_as_someone_there(self):
        with mock.patch.object(night.subprocess, "run", side_effect=subprocess.TimeoutExpired("ioreg", 10)):
            self.assertEqual(night.probe(["/usr/sbin/ioreg"]), "")
            self.assertEqual(night.current_idle(), 0.0)

    def test_a_stop_ends_the_whole_tree_through_explores_handler(self):
        # explore.py's way: a child in its own session (the hidden copy, claude -p), ended on SIGTERM.
        script = ("import sys, subprocess; sys.path.insert(0, sys.argv[1]); import explore; explore.stop_on_sigterm(); "
                  "child = subprocess.Popen(['/bin/sleep', '60'], start_new_session=True); print(child.pid, flush=True); "
                  "explore.wait_or_end(child, 60)")
        with tempfile.TemporaryFile("w+") as out:
            idles = iter([3600] * 20 + [5])

            def idle():
                out.seek(0)
                return next(idles) if out.read().strip() else 3600
            status, stopped = night.watched([sys.executable, "-B", "-c", script, str(HERE)], idle=idle,
                                            sleep=lambda _: time.sleep(0.05), stdout=out)
            out.seek(0)
            child = int(out.read().split()[0])
        self.assertTrue(stopped)
        deadline = time.monotonic() + 5
        while not gone(child) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(gone(child), "the child in its own session outlived the stop")
        self.assertEqual(night.watched(["/usr/bin/true"], idle=lambda: 3600, sleep=lambda _: time.sleep(0.05)), (0, False))

    def test_install_copies_the_runner_and_replaces_a_loaded_agent_uninstall_removes_both(self):
        with tempfile.TemporaryDirectory() as folder:
            root, calls = Path(folder), []
            run = lambda command, **kwargs: calls.append((command[1], kwargs.get("check")))
            plist, support = root / "LaunchAgents/agent.plist", root / "Support"
            for app in (Path("/tmp/Nirux.app"), night.app_argument("latest")):
                text = night.install(app, 4, plist=plist, support=support, run=run, which=lambda _: "/opt/tools/bin/claude")
            agent = plistlib.loads(plist.read_bytes())
            self.assertEqual(calls, [("bootout", False), ("bootstrap", True)] * 2)
            self.assertEqual(agent["ProgramArguments"][2:], [str(support / "runner/night.py"), "run", "--app", "latest"])
            self.assertEqual(agent["EnvironmentVariables"], {"PATH": "/opt/tools/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                                                             "NIRUX_CANARY_HISTORY_DIR": str(night.default_history_dir())})
            self.assertEqual((agent["StartCalendarInterval"], agent["RunAtLoad"]), ({"Hour": 4, "Minute": 0}, False))
            self.assertTrue((support / "runner/explore.py").exists() and (support / "runner/traces").is_dir())
            self.assertFalse(list((support / "runner").glob("test_*")))
            self.assertIn("sudo pmset repeat wakeorpoweron MTWRFSU 03:55:00", text)
            self.assertEqual(night.uninstall(plist=plist, support=support, run=run), "night run off")
            self.assertFalse(plist.exists() or support.exists())
        with self.assertRaises(SystemExit):
            night.install(Path("/tmp/Nirux.app"), 4, plist=plist, support=support, run=run, which=lambda _: None)

    def test_a_run_on_battery_or_beside_another_starts_nothing(self):
        probes = iter([BATTERY, ioreg(3600), "me\n"])
        watch = mock.Mock()
        with tempfile.TemporaryDirectory() as folder:
            history = Path(folder)
            self.assertEqual(night.run(mock.Mock(app=Path("/tmp/Nirux.app")), history=history, probe=lambda _: next(probes),
                                       watch=watch, user=lambda: "me"), 0)
            (history / "night").mkdir(exist_ok=True)
            with open(history / "night/run.lock", "a") as held:
                night.fcntl.flock(held, night.fcntl.LOCK_EX)
                night.run(mock.Mock(app=Path("/tmp/Nirux.app")), history=history, probe=lambda _: AC, watch=watch, user=lambda: "me")
        watch.assert_not_called()

    def test_latest_takes_a_newer_nightly_whose_signature_verifies_else_the_last_good_copy(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            kept, older, newer = (signed_app(root / str(build), build) for build in (202611250300, 202611240300, 202611260300))
            tampered = signed_app(root / "tampered", 202611270300)
            (tampered / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Nirux", "CFBundleVersion": "202611280300"}))
            junk = lambda url, target: target.write_text("<html>rate limited</html>")
            nightly, good = root / "nightly", root / "nightly/Nirux.app"
            got = lambda download: night.newest_nightly(nightly, download)

            self.assertEqual(got(unreachable),
                             (None, "none, nothing ran (newest nightly: download failed: curl: (6) Could not resolve host: github.com)"))
            self.assertEqual(got(released(kept)), (good, "nightly build 202611250300"))
            self.assertEqual(got(released(older)),
                             (good, "last good build 202611250300 (newest nightly: build 202611240300 is older than the last good one)"))
            self.assertEqual(got(unreachable)[1],
                             "last good build 202611250300 (newest nightly: download failed: curl: (6) Could not resolve host: github.com)")
            self.assertRegex(got(junk)[1], r"^last good build 202611250300 \(newest nightly: doesn't unpack: .+\)$")
            self.assertRegex(got(released(tampered))[1], r"^last good build 202611250300 \(newest nightly: signature doesn't verify: .+\)$")
            self.assertEqual(night.build_number(good), 202611250300)
            self.assertEqual(got(released(kept)), (good, "nightly build 202611250300"), "the same build again is no older")
            self.assertEqual(got(released(newer)), (good, "nightly build 202611260300"))
            self.assertEqual(night.build_number(good), 202611260300)
            self.assertEqual(sorted(path.name for path in nightly.iterdir()), ["Nirux.app"], "each download's leftovers go")

    def test_a_latest_run_tests_the_copy_it_got_and_none_when_there_is_none(self):
        answers = {"pmset": AC, "ioreg": ioreg(3600), "stat": "me\n"}
        probe = lambda command: answers[Path(command[0]).name]
        with tempfile.TemporaryDirectory() as folder:
            history = Path(folder)
            for app, about in ((Path("/kept/Nirux.app"), "last good build 202611250300 (newest nightly: download failed: x)"),
                               (None, "none, nothing ran (newest nightly: download failed: x)")):
                watch = mock.Mock(return_value=(0, False))
                night.run(mock.Mock(app="latest"), history=history, probe=probe, watch=watch, user=lambda: "me",
                          nightly=lambda: (app, about))
                digest = next((history / "night").glob("*/digest.md")).read_text()
                self.assertIn(f"- App: {about}\n", digest)
                if app:
                    self.assertTrue(watch.call_args_list and all(call.args[0][3] == str(app) for call in watch.call_args_list))
                else:
                    watch.assert_not_called()
                    self.assertNotIn("- Step", digest)

    def test_the_digest_tells_each_steps_end_and_the_replay_each_incident_allows(self):
        with tempfile.TemporaryDirectory() as folder:
            history = Path(folder)
            explored, scenario = history / "explore-7", history / "triage-3"
            explored.mkdir()
            (explored / "trace.jsonl").write_text("{}\n")
            (scenario / "run-001").mkdir(parents=True)
            (scenario / "run-001/manifest.json").write_text("{}")
            events = [
                {"type": "incident", "scenario": "explore", "classification": "intermittent", "timestamp": "2026-11-24T01:00:00Z",
                 "components": {"rule": "app-alive", "detail": "a-stale-incident"}, "investigationDir": "/tmp/stale"},
                {"type": "incident", "scenario": "explore", "classification": "intermittent", "timestamp": "2026-11-25T03:10:00Z",
                 "components": {"rule": "amber-has-reason", "detail": "1 waiting, no reason"}, "investigationDir": str(explored)},
                {"type": "incident", "scenario": "multi-agent-routing", "classification": "regression", "timestamp": "2026-11-25T03:12:00Z",
                 "components": {"rule": "pty-isolation"}, "investigationDir": str(scenario)},
                {"type": "pass", "scenario": "explore", "timestamp": "2026-11-25T03:20:00Z"},
            ]
            (history / "events.jsonl").write_text("".join(json.dumps(e) + "\n" for e in events))
            text = night.digest(history, "2026-11-25T00:00:00Z", [{"name": "explore", "exit": 2, "stopped": False},
                                                                  {"name": "trace a", "exit": 9, "stopped": False},
                                                                  {"name": "trace b", "exit": None, "stopped": True}])
        self.assertIn("- Step explore: infra unavailable", text)
        self.assertIn("- Step trace a: failed (exit 9)", text)
        self.assertIn("- Step trace b: stopped: someone was back", text)
        self.assertIn("2 incident(s), 1 clean run(s)", text)
        self.assertIn(f"Replay: scripts/canary.sh {explored}/Nirux.app.zip --explore --replay-trace {explored}/trace.jsonl", text)
        self.assertIn(f"Replay: scripts/canary.sh --replay {scenario}/run-001", text)
        self.assertNotIn("a-stale-incident", text)
        self.assertRegex(night.utc_now_iso(), r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$", "the stamp compares with the ledger's")


if __name__ == "__main__":
    unittest.main()
