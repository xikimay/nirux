import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


class FakeGhTests(unittest.TestCase):
    """fake_gh.py as the copy runs it: <run>/agents/gh, its world in <run>/github/world.json."""

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        run = Path(self.folder.name)
        (run / "agents").mkdir()
        (run / "github").mkdir()
        self.gh = run / "agents/gh"
        shutil.copyfile(HERE / "fake_gh.py", self.gh)
        self.gh.chmod(0o755)
        self.world = run / "github/world.json"
        self.world.write_text(json.dumps({"repository": "acme/widgets", "mainTip": "m", "pullRequests": [
            {"number": 1, "title": "Alpha", "headRefName": "canary-alpha", "headRefOid": "a", "state": "OPEN", "checks": "success",
             "createdAt": "2026-01-01T00:00:00Z"},
            {"number": 2, "title": "Beta", "headRefName": "canary-beta", "headRefOid": "b", "state": "OPEN", "checks": "pending",
             "createdAt": "2026-01-01T00:00:00Z"}]}))

    def tearDown(self):
        self.folder.cleanup()

    def gh_json(self, *args):
        result = subprocess.run([str(self.gh), *args], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_pull_requests_as_the_sidebar_and_the_board_ask_for_them(self):
        self.assertEqual(self.gh_json("pr", "list", "--head", "canary-alpha", "--state", "open", "--json", "number,state,headRefOid"),
                         [{"number": 1, "state": "OPEN", "headRefOid": "a"}])
        self.assertEqual(self.gh_json("pr", "list", "--head=canary-beta", "--state", "all", "--json", "number")[0]["number"], 2)
        board = self.gh_json("pr", "list", "--repo", "github.com/acme/widgets", "--state", "open", "--json",
                             "number,url,mergeStateStatus,statusCheckRollup,headRepository,headRepositoryOwner")
        self.assertEqual([(p["number"], p["mergeStateStatus"], p["statusCheckRollup"][0]["status"]) for p in board],
                         [(1, "CLEAN", "COMPLETED"), (2, "BLOCKED", "IN_PROGRESS")])
        self.assertEqual(board[0]["url"], "https://github.com/acme/widgets/pull/1")
        self.assertEqual((board[0]["headRepositoryOwner"], board[0]["headRepository"]), ({"login": "acme"}, {"name": "widgets"}))
        self.assertEqual(self.gh_json("pr", "view", "https://github.com/acme/widgets/pull/2", "--json", "title")["title"], "Beta")
        self.assertEqual(self.gh_json("run", "list", "--json", "databaseId"), [])
        calls = [json.loads(line) for line in self.world.with_name("calls.jsonl").read_text().splitlines()]
        self.assertEqual([(c["args"][:2], c["status"]) for c in calls][:2], [(["pr", "list"], 0), (["pr", "list"], 0)])

    def test_a_merge_and_a_retarget_change_the_world_and_the_rest_is_refused(self):
        merged = subprocess.run([str(self.gh), "pr", "merge", "2", "--squash", "--match-head-commit", "b"], capture_output=True, text=True)
        self.assertEqual(merged.returncode, 0)
        self.assertEqual(self.gh_json("pr", "list", "--state", "merged", "--json", "number"), [{"number": 2}])
        retarget = subprocess.run([str(self.gh), "api", "--hostname", "github.com", "--method", "PATCH",
                                   "repos/acme/widgets/pulls/1", "-f", "base=release", "--jq", ".base.ref"], capture_output=True, text=True)
        self.assertEqual(retarget.stdout.strip(), "release")
        self.assertEqual(json.loads(self.world.read_text())["pullRequests"][0]["baseRefName"], "release")
        self.assertEqual(subprocess.run([str(self.gh), "auth", "status", "--hostname", "github.com"], capture_output=True).returncode, 0)
        for refused in (["api", "graphql", "-f", "query=x"], ["repo", "clone", "acme/widgets"]):
            result = subprocess.run([str(self.gh), *refused], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, refused)
            self.assertIn("isn't faked", result.stderr)


if __name__ == "__main__":
    unittest.main()
