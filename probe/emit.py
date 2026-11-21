import datetime, json, os, pathlib, re, subprocess
env = os.environ
root = pathlib.Path(env["RUNNER_TEMP"])
tested = subprocess.run(
    ["swift", "test", "--package-path", str(root / "known-red"), "--skip-build", "--filter", "FuzzyMatchTests"],
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
)
assertion = next((line for line in tested.stdout.splitlines() if ": error:" in line and "testEmptyQueryMatchesEverything" in line), None)
if tested.returncode == 0 or not assertion or not re.search(r"Executed 5 tests?, with 1 failure", tested.stdout):
    raise SystemExit(tested.stdout)
payload = dict(run=env["GITHUB_RUN_ID"], attempt=env["GITHUB_RUN_ATTEMPT"], sha=env["FIXTURE_SHA"],
               candidate=env["TARGET"], source="isolated-known-red", assertion=assertion,
               detected=datetime.datetime.now(datetime.timezone.utc).isoformat())
(root / "diagnostic.json").write_text(json.dumps(payload))
print(assertion)
