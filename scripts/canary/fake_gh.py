#!/usr/bin/python3 -I
"""gh in a canary copy (GitHub.CLI.candidates): answers what Nirux asks from the run's world,
<run>/github/world.json, changes it for a merge, a close or a retarget, and refuses the rest with
gh-like errors. No network, no login. The explorer's github tool (explorer_mcp.py) changes the same
world through update(), under the same lock."""

import fcntl
import json
import os
from pathlib import Path
import sys
import tempfile
import time

WORLD = Path(__file__).resolve().parent.parent / "github" / "world.json"
CHECK_STATES = {"success": ("COMPLETED", "SUCCESS", "CLEAN"), "failure": ("COMPLETED", "FAILURE", "UNSTABLE"),
                "pending": ("IN_PROGRESS", "", "BLOCKED")}


class Refusal(Exception):
    """gh's answer to a call it can't serve: its message, exit status 1."""


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def update(world_file, change):
    """change(world) under an exclusive lock, the world rewritten through a unique temp file when it
    says so: (result, changed). The lock spans the read, so two writers never lose a change."""
    with open(world_file.with_suffix(".lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        world = json.loads(world_file.read_text())
        result, changed = change(world)
        if changed:
            handle, temporary = tempfile.mkstemp(dir=world_file.parent, prefix=".world-", suffix=".tmp")
            with os.fdopen(handle, "w") as stream:
                json.dump(world, stream, indent=1)
            os.replace(temporary, world_file)
        return result, changed


def option(args, name):
    for index, argument in enumerate(args):
        if argument == name and index + 1 < len(args):
            return args[index + 1]
        if argument.startswith(name + "="):
            return argument.split("=", 1)[1]
    return None


def field_values(args):
    """The -f/--raw-field name=value pairs of an api call."""
    pairs = [args[i + 1] for i, a in enumerate(args[:-1]) if a in ("-f", "--raw-field", "-F", "--field")]
    return dict(pair.split("=", 1) for pair in pairs if "=" in pair)


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
    if reference is None:
        raise Refusal("argument required: a pull request number or URL")
    tail = str(reference).rstrip("/").rsplit("/", 1)[-1]
    pull = next((p for p in world["pullRequests"] if tail.isdigit() and p["number"] == int(tail)), None)
    if pull is None:
        raise Refusal(f"GraphQL: Could not resolve to a PullRequest with the number of {tail}. (repository.pullRequest)")
    return pull


def positional(args, index):
    """The word at `index`, as Nirux writes it (pr view <url>, pr merge <n>), unless it is an option."""
    return args[index] if len(args) > index and not args[index].startswith("-") else None


def answer(world, args):
    """(stdout, changed) for one gh command line; Refusal for what it doesn't serve."""
    command = args[:2]
    if args[:1] == ["auth"]:
        return "github.com\n  ✓ Logged in to github.com account canary (keyring)\n", False
    if command == ["pr", "list"]:
        head, state = option(args, "--head"), (option(args, "--state") or "open").upper()
        pulls = [p for p in world["pullRequests"] if (head is None or p["headRefName"] == head) and state in ("ALL", p["state"])]
        limit = min(int(option(args, "--limit") or 30), 1000)
        return json.dumps([shown(world, p, option(args, "--json")) for p in pulls[:limit]]), False
    if command == ["pr", "view"]:
        return json.dumps(shown(world, find(world, positional(args, 2)), option(args, "--json"))), False
    if command == ["pr", "merge"]:
        pull = find(world, positional(args, 2))
        if "--disable-auto" in args:
            return f"✓ Auto-merge disabled for pull request #{pull['number']}\n", False
        pull.update(state="MERGED", mergedAt=now())
        return f"✓ Merged pull request #{pull['number']}\n", True
    if command == ["run", "list"]:
        return "[]", False
    if command == ["run", "rerun"]:
        return "", False
    if args[:1] == ["api"] and option(args, "--method") == "PATCH":
        path = next((a for a in args[1:] if "/pulls/" in a), None)
        values = field_values(args)
        if path is None or not values:
            raise Refusal("fake gh: this PATCH isn't faked in a canary run")
        pull = find(world, path)
        if values.get("state") == "closed":
            pull.update(state="CLOSED", closedAt=now())
        if "base" in values:
            pull["baseRefName"] = values["base"]
        return (pull.get("baseRefName", "main") + "\n") if "base" in values else "", True
    raise Refusal(f"fake gh: {' '.join(args[:3])} isn't faked in a canary run")


def main(args=None, world_file=WORLD):
    args = sys.argv[1:] if args is None else args
    out, status, message = "", 0, ""
    try:
        out, _ = update(world_file, lambda world: answer(world, args))
    except Refusal as refusal:
        status, message = 1, str(refusal)
    except Exception as error:  # A bad world or a bug answers as gh would, never a traceback.
        status, message = 1, f"fake gh: {type(error).__name__}: {error}"
    finally:
        with world_file.with_name("calls.jsonl").open("a", encoding="utf-8") as calls:
            calls.write(json.dumps({"args": args, "status": status, "at": now()}) + "\n")
    if message:
        sys.stderr.write(message + "\n")
    sys.stdout.write(out)
    return status


if __name__ == "__main__":
    sys.exit(main())
