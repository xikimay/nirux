import json
import stat
import tempfile
import threading
import unittest
import uuid
from pathlib import Path

import canaryctl
import channel


class FakeClock:
    """Time that moves only when the client sleeps."""

    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class ChannelTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = Path(self.tmp.name)
        self.token = channel.new_token()

    def tearDown(self):
        self.tmp.cleanup()

    def answer_next(self, text="ok", is_error=False):
        """A stand-in for the app: answers the first request it finds."""
        seen = []

        def run():
            requests = self.state / "canary/requests"
            while not seen:
                for path in requests.glob("*.json") if requests.exists() else []:
                    request = json.loads(path.read_text())
                    path.unlink()
                    seen.append((request, stat.S_IMODE(requests.stat().st_mode)))
                    channel.write_whole(self.state / "canary/responses", path.name,
                                        {"id": request["id"], "text": text, "isError": is_error})

        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        return seen, thread

    def test_a_call_carries_the_token_in_the_apps_request_shape(self):
        seen, thread = self.answer_next("done")
        result = channel.Channel(self.state, self.token).menu("Space", "Previous Space")
        thread.join(5)
        self.assertEqual(result, "done")
        request, mode = seen[0]
        # LeadChannel.Request decodes exactly these keys; arguments is a JSON string.
        self.assertEqual(set(request), {"v", "id", "tool", "arguments", "workspaceID", "agentUUID", "createdAt"})
        self.assertEqual(request["v"], 1)
        self.assertEqual(str(uuid.UUID(request["id"])).upper(), request["id"])
        self.assertEqual(json.loads(request["arguments"]), {"path": ["Space", "Previous Space"], "token": self.token})
        self.assertEqual(mode, 0o700)
        self.assertEqual(list((self.state / "canary/responses").iterdir()), [])

    def test_a_refusal_raises(self):
        _, thread = self.answer_next("This request doesn't carry the run's canary token.", is_error=True)
        with self.assertRaisesRegex(channel.ChannelError, "canary token"):
            channel.Channel(self.state, self.token).text("echo hi")
        thread.join(5)

    def test_an_untaken_request_is_taken_back(self):
        clock = FakeClock()
        client = channel.Channel(self.state, self.token, take_timeout=2, clock=clock, sleep=clock.sleep)
        with self.assertRaises(channel.NotTaken):
            client.key("1", key_code=18, modifiers=["command"])
        self.assertEqual(list((self.state / "canary/requests").iterdir()), [])
        self.assertGreaterEqual(clock.now, 2)

    def test_canaryctl_sends_each_action_with_its_arguments(self):
        environ = {"NIRUX_STATE_DIR": str(self.state), "NIRUX_CANARY_TOKEN": self.token}
        cases = [
            (["menu", "Space", "Next Space"], "menu", {"path": ["Space", "Next Space"]}),
            (["key", "1", "--code", "18", "--mod", "command"], "key", {"characters": "1", "keyCode": 18, "modifiers": ["command"]}),
            (["press", "Board"], "press", {"label": "Board"}),
            (["snapshot"], "snapshot", {}),
        ]
        for argv, tool, arguments in cases:
            seen, thread = self.answer_next()
            self.assertEqual(canaryctl.main(argv, environ), 0, argv)
            thread.join(5)
            request = seen[0][0]
            self.assertEqual(request["tool"], tool)
            self.assertEqual(json.loads(request["arguments"]), dict(arguments, token=self.token))

    def test_canaryctl_needs_the_runs_environment(self):
        self.assertEqual(canaryctl.main(["snapshot"], {}), 2)

    def test_files_are_private_and_whole(self):
        channel.write_whole(self.state / "canary/requests", "x.json", {"a": 1})
        path = self.state / "canary/requests/x.json"
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual([p.name for p in path.parent.iterdir()], ["x.json"])


if __name__ == "__main__":
    unittest.main()
