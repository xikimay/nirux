import contextlib
import io
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

import night

HERE = Path(__file__).resolve().parent
TOKEN = "sk-ant-oat01-canary-night-test"
BUILD = "nightly build 202611250300"


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


def actions(root):
    """What GitHub Actions gives a step."""
    (root / "summary.md").touch()
    (root / "output").touch()
    return {"PATH": "/usr/bin:/bin", "GITHUB_RUN_ID": "42", "GITHUB_REPOSITORY": "xikimay/nirux",
            "GITHUB_SERVER_URL": "https://github.com", "GITHUB_STEP_SUMMARY": str(root / "summary.md"),
            "GITHUB_OUTPUT": str(root / "output")}


def nightly(folder):
    return folder / "Nirux.app.zip", BUILD


class NightTests(unittest.TestCase):
    def test_the_nightly_is_tested_once_it_unpacks_and_its_signature_verifies(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            good = signed_app(root / "good", 202611250300)
            tampered = signed_app(root / "tampered", 202611260300)
            (tampered / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Nirux", "CFBundleVersion": "202611270300"}))
            unsigned = root / "unsigned/Nirux.app"
            shutil.copytree(good, unsigned)
            shutil.rmtree(unsigned / "Contents/_CodeSignature")
            junk = lambda url, target: target.write_text("<html>rate limited</html>")
            got = lambda download: night.fetch_nightly(root / "nightly", download)

            self.assertEqual(got(unreachable), (None, "none, nothing ran (nightly: download failed: curl: (6) Could not resolve host: github.com)"))
            self.assertRegex(got(junk)[1], r"^none, nothing ran \(nightly: doesn't unpack: .+\)$")
            for refused in (tampered, unsigned):
                self.assertRegex(got(released(refused))[1], r"^none, nothing ran \(nightly: signature doesn't verify: .+\)$")
            self.assertEqual(got(released(good)), (root / "nightly/Nirux.app.zip", "nightly build 202611250300"))
            self.assertEqual([path.name for path in (root / "nightly").iterdir()], ["Nirux.app.zip"])

    def test_without_the_token_the_exploration_is_skipped_and_the_traces_still_replay(self):
        with tempfile.TemporaryDirectory() as folder:
            root, steps = Path(folder), []
            environ = actions(root)
            with contextlib.redirect_stdout(io.StringIO()) as printed:
                status = night.run(root / "canary", environ, nightly, lambda command, env, log: steps.append(command) or 0)
            summary, output = (root / "summary.md").read_text(), (root / "output").read_text()
        self.assertEqual(status, 0)
        self.assertEqual([command[command.index("--history-dir") + 2:] for command in steps],
                         [["--replay-traces", str(HERE / "traces")]])
        skipped = ("- Step explore: skipped: no CLAUDE_CODE_OAUTH_TOKEN secret (`claude setup-token`, "
                   "then `gh secret set CLAUDE_CODE_OAUTH_TOKEN`); the kept traces still replay")
        self.assertIn(skipped, summary)
        self.assertIn("- Step kept traces: clean", summary)
        self.assertIn("::notice title=Canary night::Exploration skipped: no CLAUDE_CODE_OAUTH_TOKEN secret", printed.getvalue())
        self.assertEqual(output, "incidents=0\n")

    def test_the_token_reaches_the_exploration_alone_never_the_traces_the_log_or_the_upload(self):
        with tempfile.TemporaryDirectory() as folder:
            root, envs = Path(folder), {}
            environ = dict(actions(root), CLAUDE_CODE_OAUTH_TOKEN=TOKEN)

            def step(command, env, log):
                name = "traces" if "--replay-traces" in command else "explore"
                envs[name] = env
                (log.parent / f"{name}-leak.json").write_text(json.dumps({"env": env}))
                return 0
            with contextlib.redirect_stdout(io.StringIO()) as printed:
                status = night.run(root / "canary", environ, nightly, step)
            uploaded = [path.read_text() for path in (root / "canary").rglob("*") if path.is_file()]
            summary = (root / "summary.md").read_text()
            log = root / "step.log"
            self.assertEqual(night.run_step(["/bin/sh", "-c", "echo '::warning::from the copy'; exit 2"], {}, log), 2)
            self.assertEqual(log.read_text(), "::warning::from the copy\n")
        self.assertEqual(status, 0)
        self.assertEqual(envs["explore"][night.TOKEN], TOKEN)
        self.assertNotIn(night.TOKEN, envs["traces"])
        self.assertTrue(uploaded)
        self.assertFalse([text for text in uploaded + [summary, printed.getvalue()] if TOKEN in text])
        self.assertIn("- Step upload: files holding the Claude token removed from the evidence", summary)

    def test_the_issue_names_each_incident_with_its_replay_and_nothing_the_explorer_wrote(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            environ = dict(actions(root), CLAUDE_CODE_OAUTH_TOKEN=TOKEN)

            def step(command, env, log):
                if "--replay-traces" in command:
                    return 0
                evidence = log.parent / "explore-1"
                evidence.mkdir()
                (evidence / "trace.jsonl").write_text("{}\n")
                (evidence / "notes.jsonl").write_text(json.dumps({"note": "a note the explorer wrote"}) + "\n")
                history = Path(command[command.index("--history-dir") + 1])
                history.mkdir(parents=True)
                (history / "events.jsonl").write_text(json.dumps({
                    "type": "incident", "scenario": "explore", "fingerprint": "0123456789abcdef", "classification": "intermittent",
                    "components": {"rule": "pty-isolation", "detail": "typed 'echo hello' landed\nin Beta Child"},
                    "investigationDir": str(evidence)}) + "\n")
                return 1
            with contextlib.redirect_stdout(io.StringIO()):
                status = night.run(root / "canary", environ, nightly, step)
            issue, summary = (root / "canary/issue.md").read_text(), (root / "summary.md").read_text()
            output = (root / "output").read_text()
        replay = ("gh run download 42 --repo xikimay/nirux -n canary-night-42 -D canary-night && scripts/canary.sh "
                  "canary-night/evidence/explore-1/Nirux.app.zip --explore --replay-trace canary-night/evidence/explore-1/trace.jsonl")
        self.assertEqual(status, 1)
        self.assertEqual(output, "incidents=1\n")
        self.assertIn(f"on {BUILD}: 1 incident(s). [Run and summary](https://github.com/xikimay/nirux/actions/runs/42).", issue)
        self.assertIn("- **explore** · pty-isolation (intermittent), fingerprint `0123456789ab`", issue)
        self.assertIn(f"  Replay: `{replay}`", issue)
        for written in ("echo hello", "a note the explorer wrote", TOKEN):
            self.assertNotIn(written, issue)
        self.assertIn("pty-isolation (intermittent): typed 'echo hello' landed in Beta Child", summary)
        self.assertIn(f"  Replay: `{replay}`", summary)
        workflow = (HERE.parent.parent / ".github/workflows/canary-night.yml").read_text()
        self.assertIn("name: canary-night-${{ github.run_id }}", workflow, "the replay downloads the artifact by this name")

    def test_the_issue_goes_to_the_open_canary_issue_or_a_new_one(self):
        for listed, said in (("17", "commented on #17"), ("", "opened https://github.com/xikimay/nirux/issues/18")):
            calls = []

            def gh(*arguments):
                calls.append(arguments[:2])
                return {("issue", "list"): listed, ("issue", "create"): "https://github.com/xikimay/nirux/issues/18"}.get(arguments[:2], "")
            self.assertEqual(night.file_issue(Path("issue.md"), gh), said)
            self.assertEqual(calls, [("issue", "list"), ("issue", "comment")] if listed else
                             [("issue", "list"), ("label", "create"), ("issue", "create")])

    def test_a_missing_nightly_runs_nothing_and_says_why(self):
        with tempfile.TemporaryDirectory() as folder:
            root, steps = Path(folder), []
            environ = dict(actions(root), CLAUDE_CODE_OAUTH_TOKEN=TOKEN)
            status = night.run(root / "canary", environ, lambda folder: (None, "none, nothing ran (nightly: download failed: x)"),
                               lambda command, env, log: steps.append(command) or 0)
            summary = (root / "summary.md").read_text()
        self.assertEqual((status, steps), (2, []))
        self.assertIn("- App: none, nothing ran (nightly: download failed: x)", summary)


if __name__ == "__main__":
    unittest.main()
