#!/usr/bin/python3 -I
"""gh in a canary copy (GitHub.CLI.candidates): answers what Nirux asks from the run's world,
<run>/github/world.json, changes it for a merge or a retarget, and refuses the rest. No network,
no login. The explorer's github tool (explorer_mcp.py) changes the same world mid-run."""

import json
from pathlib import Path
import sys
import time

WORLD = Path(__file__).resolve().parent.parent / "github" / "world.json"
CHECK_STATES = {"success": ("COMPLETED", "SUCCESS", "CLEAN"), "failure": ("COMPLETED", "FAILURE", "UNSTABLE"),
                "pending": ("IN_PROGRESS", "", "BLOCKED")}


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def option(args, name):
    for index, argument in enumerate(args):
        if argument == name and index + 1 < len(args):
            return args[index + 1]
        if argument.startswith(name + "="):
            return argument.split("=", 1)[1]
    return None


def fields(world, pull):
    owner, name = world["repository"].split("/")
    url = f"https://github.com/{world['repository']}/pull/{pull['number']}"
    status, conclusion, merge_state = CHECK_STATES[pull.get("checks", "success")]
    check = {"__typename": "CheckRun", "name": "test", "context": "test", "workflowName": "Tests", "status": status,
             "state": conclusion or "PENDING", "conclusion": conclusion, "detailsUrl": url + "/checks",
             "startedAt": pull["createdAt"], "completedAt": pull["createdAt"] if conclusion else None}
    return {
        "number": pull["number"], "title": pull.get("title", ""), "body": pull.get("body", ""), "state": pull["state"], "url": url,
        "headRefName": pull["headRefName"], "headRefOid": pull["headRefOid"], "baseRefName": pull.get("baseRefName", "main"),
        "baseRefOid": world.get("mainTip", ""), "headRepositoryOwner": {"login": owner}, "headRepository": {"name": name},
        "isDraft": pull.get("isDraft", False), "mergeable": "MERGEABLE", "mergeStateStatus": merge_state, "reviewDecision": "",
        "autoMergeRequest": None, "statusCheckRollup": [check], "additions": 1, "deletions": 0, "changedFiles": 1,
        "createdAt": pull["createdAt"], "mergedAt": pull.get("mergedAt"), "closedAt": pull.get("closedAt"), "mergeCommit": None,
        "commits": [], "reviews": [],
    }


def shown(world, pull, json_fields):
    everything = fields(world, pull)
    return {key: everything.get(key) for key in json_fields.split(",")} if json_fields else everything


def find(world, reference):
    number = int(str(reference).rstrip("/").rsplit("/", 1)[-1])
    return next(pull for pull in world["pullRequests"] if pull["number"] == number)


def answer(world, args):
    """(stdout, exit status, whether the world changed) for one gh command line."""
    command = args[:2]
    if args[:1] == ["auth"]:
        return "github.com\n  ✓ Logged in to github.com account canary (keyring)\n", 0, False
    if command == ["pr", "list"]:
        head, state = option(args, "--head"), (option(args, "--state") or "open").upper()
        pulls = [p for p in world["pullRequests"] if (head is None or p["headRefName"] == head) and state in ("ALL", p["state"])]
        limit = min(int(option(args, "--limit") or 30), 1000)
        return json.dumps([shown(world, p, option(args, "--json")) for p in pulls[:limit]]), 0, False
    if command == ["pr", "view"]:
        return json.dumps(shown(world, find(world, args[2]), option(args, "--json"))), 0, False
    if command == ["pr", "merge"]:
        pull = find(world, args[2])
        pull.update(state="MERGED", mergedAt=now())
        return f"✓ Merged pull request #{pull['number']}\n", 0, True
    if command == ["run", "list"]:
        return "[]", 0, False
    if command == ["run", "rerun"]:
        return "", 0, False
    if args[:1] == ["api"] and option(args, "--method") == "PATCH" and "/pulls/" in " ".join(args):
        pull = find(world, next(a for a in args if "/pulls/" in a))
        pull["baseRefName"] = option(args, "-f").split("=", 1)[1]
        return pull["baseRefName"] + "\n", 0, True
    return "", 1, False


def main(args=None):
    args = sys.argv[1:] if args is None else args
    world = json.loads(WORLD.read_text())
    out, status, changed = answer(world, args)
    with WORLD.with_name("calls.jsonl").open("a", encoding="utf-8") as calls:
        calls.write(json.dumps({"args": args, "status": status, "at": now()}) + "\n")
    if changed:
        WORLD.with_suffix(".tmp").write_text(json.dumps(world, indent=1))
        WORLD.with_suffix(".tmp").replace(WORLD)
    if status:
        sys.stderr.write(f"fake gh: {' '.join(args[:3])} isn't faked in a canary run\n")
    sys.stdout.write(out)
    return status


if __name__ == "__main__":
    sys.exit(main())
