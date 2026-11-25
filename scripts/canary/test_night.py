import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest import mock

import night

AC = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t100%; charged; 0:00 remaining present: true\n"
BATTERY = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t80%; discharging\n"


def ioreg(seconds):
    return f'    | |   "HIDIdleTime" = {int(seconds * 1e9)}\n'


class NightTests(unittest.TestCase):
    def test_it_starts_only_on_ac_with_this_users_session_idle_for_30_minutes(self):
        self.assertTrue(night.on_ac_power(AC))
        self.assertFalse(night.on_ac_power(BATTERY))
        self.assertAlmostEqual(night.idle_seconds(ioreg(1834.5)), 1834.5, places=3)
        self.assertEqual(night.why_not(BATTERY, ioreg(3600), "me\n", "me"), "on battery")
        self.assertEqual(night.why_not(AC, ioreg(3600), "root\n", "me"), "the session in front is root's")
        self.assertEqual(night.why_not(AC, ioreg(600), "me\n", "me"), "idle for 10 min only")
        self.assertIsNone(night.why_not(AC, ioreg(1801), "me\n", "me"))

    def test_a_run_stops_the_moment_someone_is_back(self):
        idles = iter([3600, 3600, 5])
        started = time.monotonic()
        status, stopped = night.watched(["/bin/sleep", "30"], idle=lambda: next(idles), sleep=lambda _: None, interval=0)
        self.assertTrue(stopped)
        self.assertLess(time.monotonic() - started, 10)
        self.assertEqual(night.watched(["/usr/bin/true"], idle=lambda: 3600, sleep=lambda _: time.sleep(0.05)), (0, False))

    def test_the_launch_agent_starts_at_its_hour_never_at_load(self):
        agent = night.launch_agent(Path("/tmp/Nirux.app"), 4, python="/usr/bin/python3")
        self.assertEqual(agent["Label"], night.LABEL)
        self.assertEqual(agent["StartCalendarInterval"], {"Hour": 4, "Minute": 0})
        self.assertFalse(agent["RunAtLoad"])
        self.assertEqual(agent["ProgramArguments"][-3:], ["run", "--app", "/tmp/Nirux.app"])

    def test_a_run_on_battery_starts_nothing(self):
        with mock.patch.object(night, "probe", side_effect=[BATTERY, ioreg(3600), "me\n"]), \
                mock.patch.object(night, "watched") as watched, mock.patch.object(night.getpass, "getuser", return_value="me"), \
                tempfile.TemporaryDirectory() as folder:
            self.assertEqual(night.run(mock.Mock(app=Path("/tmp/Nirux.app")), history=Path(folder)), 0)
        watched.assert_not_called()

    def test_the_digest_lists_what_came_since_the_last_one_with_replay_commands(self):
        with tempfile.TemporaryDirectory() as folder:
            history = Path(folder)
            events = [
                {"type": "incident", "scenario": "explore", "classification": "intermittent", "timestamp": "2026-11-24T01:00:00Z",
                 "components": {"rule": "app-alive", "detail": "old"}, "investigationDir": "/tmp/old"},
                {"type": "incident", "scenario": "explore", "classification": "intermittent", "timestamp": "2026-11-25T03:10:00Z",
                 "components": {"rule": "amber-has-reason", "detail": "1 waiting, no reason"}, "investigationDir": "/tmp/run-7"},
                {"type": "pass", "scenario": "explore", "timestamp": "2026-11-25T03:20:00Z"},
            ]
            (history / "events.jsonl").write_text("".join(json.dumps(e) + "\n" for e in events))
            text = night.digest(history, "2026-11-25T00:00:00")
        self.assertIn("1 incident(s), 1 clean run(s)", text)
        self.assertIn("**explore** · amber-has-reason (intermittent): 1 waiting, no reason", text)
        self.assertIn("Replay: scripts/canary.sh /tmp/run-7/Nirux.app.zip --explore --replay-trace /tmp/run-7/trace.jsonl", text)
        self.assertNotIn("old", text)


if __name__ == "__main__":
    unittest.main()
