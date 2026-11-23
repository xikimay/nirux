"""Client of the app's canary channel (Sources/Nirux/Model/CanaryChannel.swift).

A run launches Nirux with NIRUX_STATE_DIR and NIRUX_CANARY_TOKEN. Each call
writes one request into <state>/canary/requests/ and waits for the app's
answer in <state>/canary/responses/, over the same files as LeadChannel.
The app acts inside its own event dispatch, so it never needs the focus.
"""

import json
import os
import secrets
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path

TOKEN_KEY = "NIRUX_CANARY_TOKEN"
PROTOCOL_VERSION = 1


class ChannelError(RuntimeError):
    """The app refused or failed the action."""


class NotTaken(ChannelError):
    """No Nirux took the request: it was taken back, nothing happened."""


class StillWorking(ChannelError):
    """Nirux took the request but didn't answer in time: it may still act."""


def new_token():
    return secrets.token_hex(32)


def write_whole(directory, name, payload):
    """payload as JSON in directory/name, 0600 in a 0700 folder, whole or not at all."""
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    staging = directory / f".{name}.{uuid.uuid4()}.tmp"
    descriptor = os.open(staging, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        json.dump(payload, handle)
    os.rename(staging, directory / name)


def take(path):
    """The JSON object in path, removed once read; None while it isn't there."""
    try:
        data = path.read_bytes()
    except FileNotFoundError:
        return None
    path.unlink(missing_ok=True)
    return json.loads(data)


@dataclass(frozen=True)
class Channel:
    state_dir: Path
    token: str
    take_timeout: float = 5.0
    work_timeout: float = 10.0
    clock: callable = field(default=time.monotonic, repr=False)
    sleep: callable = field(default=time.sleep, repr=False)

    def folder(self, name):
        return Path(self.state_dir) / "canary" / name

    def call(self, tool, **arguments):
        """The app's answer to one action; raises ChannelError when it refuses."""
        request_id = str(uuid.uuid4()).upper()
        request = {
            "v": PROTOCOL_VERSION,
            "id": request_id,
            "tool": tool,
            "arguments": json.dumps(dict(arguments, token=self.token)),
            "workspaceID": "",
            "agentUUID": "",
            "createdAt": time.time(),
        }
        request_file = self.folder("requests") / f"{request_id}.json"
        response_file = self.folder("responses") / f"{request_id}.json"
        write_whole(request_file.parent, request_file.name, request)
        start = self.clock()
        interval = 0.01
        while True:
            response = take(response_file)
            if response is not None:
                if response["isError"]:
                    raise ChannelError(f"{tool}: {response['text']}")
                return response["text"]
            elapsed = self.clock() - start
            if request_file.exists():
                if elapsed >= self.take_timeout:
                    try:
                        request_file.unlink()
                    except FileNotFoundError:
                        continue  # claimed meanwhile
                    raise NotTaken(tool)
            elif elapsed >= self.take_timeout + self.work_timeout:
                raise StillWorking(tool)
            self.sleep(interval)
            interval = min(0.5, interval * 1.5)

    def menu(self, *path):
        return self.call("menu", path=list(path))

    def key(self, characters, key_code=0, modifiers=()):
        return self.call("key", characters=characters, keyCode=key_code, modifiers=list(modifiers))

    def text(self, text):
        return self.call("text", text=text)

    def render(self):
        """A PNG of the main window as the app draws it."""
        return Path(self.call("render"))
