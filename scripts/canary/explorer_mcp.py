"""The canary explorer's MCP server: an agent's only way into the canary copy.

Each tool is one action through the app's channel (channel.py), as a person
would act. After each action the server runs the oracles (ORACLES) and tells
the agent what failed. The run folder (CANARY_EXPLORER_RUN) gets the trace
(trace.jsonl, replayable without a model), the findings (findings.jsonl) and
the agent's own remarks (notes.jsonl, to verify). budget.json, shared by the
run's episodes, caps the calls and the renders.

Environment: NIRUX_STATE_DIR, NIRUX_CANARY_TOKEN, CANARY_EXPLORER_RUN,
CANARY_APP_PID, CANARY_APP_STDERR, CANARY_EPISODE, CANARY_EPISODE_ACTIONS.
"""

import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

from channel import Channel, ChannelError, NotTaken, StillWorking
from scenarios import check_amber_has_reason, check_state_json_valid

PROTOCOL_VERSION = "2025-06-18"
ANSWER_LIMIT = 400
LOOK_LIMIT = 160
TERMINAL_LINES = 40
# The Space button's value when the waiting agent is in another space.
ELSEWHERE_RE = re.compile(r"\bwaits for you in\b")
# What only a broken app writes to its stderr.
FATAL_RE = re.compile(r"Fatal error|Assertion failed|Precondition failed|Thread \d+ Crashed|Unexpectedly found nil")

INSTRUCTIONS = (
    "The tools act on a copy of Nirux the way a person would: menus, labelled controls, keys, typed text. "
    "After each action the canary's checks run; a failed check is a bug to report. "
    "look() lists what is on screen (lines marked + are new since the last look)."
)

TOOLS = [
    {"name": "look", "description": "The windows' accessibility elements: role, label, value. New lines are marked +.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "press", "description": "Click the enabled element with this label or title.",
     "inputSchema": {"type": "object", "properties": {"label": {"type": "string"}}, "required": ["label"]}},
    {"name": "menu", "description": "Pick a menu item by its titles, e.g. [\"Space\", \"Next Space\"].",
     "inputSchema": {"type": "object", "properties": {"path": {"type": "array", "items": {"type": "string"}}},
                     "required": ["path"]}},
    {"name": "key", "description": "One key press routed as a typed key, e.g. characters \"p\" with [\"command\", \"shift\"]. "
                                   "keyCode is the macOS virtual key code (Return 36, Escape 53, arrows 123-126).",
     "inputSchema": {"type": "object", "properties": {
         "characters": {"type": "string"}, "keyCode": {"type": "integer"},
         "modifiers": {"type": "array", "items": {"enum": ["command", "control", "option", "shift"]}}},
         "required": ["characters"]}},
    {"name": "type", "description": "Type text, one key per character; \\n presses Return.",
     "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}},
    {"name": "terminal", "description": "The last lines of the active task's terminals; the one with the keyboard is marked.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "render", "description": "A picture of the main window. Scarce: use look() first.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "note", "description": "Something that looks wrong although no check failed: what you did and what you saw.",
     "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}},
]
ACTIONS = {"press", "menu", "key", "type"}
# What the agent isn't handed, whatever explore.sb and the copy already refuse: a terminal (every
# one runs a fake agent), a browser (pages are localhost only, CanaryChannel.pagePolicy), the
# user's clipboard (the copy reaches none).
REFUSALS = {
    "terminal": "The canary opens no terminal: every one runs a fake agent.",
    "browser": "The canary opens no browser unless the run allows local pages (CANARY_ALLOW_BROWSER).",
    "clipboard": "The canary leaves the clipboard alone: it is the user's.",
}
COMMAND_KEYS = {"t": "terminal", "b": "browser", "c": "clipboard", "v": "clipboard", "x": "clipboard"}
MENU_RES = (
    (re.compile(r"\bTerminal\b"), "terminal"),
    (re.compile(r"\bBrowser\b|Address Bar"), "browser"),
    (re.compile(r"^(Cut|Copy|Paste)\b"), "clipboard"),
)
TYPED_RES = ((re.compile(r"new terminal", re.I), "terminal"), (re.compile(r"(open|new) browser", re.I), "browser"))
SCHEMA_TYPES = {"string": str, "integer": int, "array": list}
BUTTON_ROLES = {"AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle"}


def invalid(name, arguments):
    """Why a call's arguments don't fit its tool's schema, or None."""
    schema = next((tool["inputSchema"] for tool in TOOLS if tool["name"] == name), None)
    if schema is None:
        return f"Unknown tool {name}."
    if not isinstance(arguments, dict):
        return "Arguments must be an object."
    for key in schema.get("required", []):
        if key not in arguments:
            return f"{key} is required."
    for key, value in arguments.items():
        spec = schema["properties"].get(key)
        expected = SCHEMA_TYPES.get((spec or {}).get("type"))
        if spec is None or (expected and (not isinstance(value, expected) or isinstance(value, bool))):
            return f"{key} must be {(spec or {}).get('type', 'absent')}."
        if expected is list and not all(isinstance(item, str) for item in value):
            return f"{key} must hold strings."
        allowed = (spec.get("items") or {}).get("enum")
        if expected is list and allowed and not set(value) <= set(allowed):
            return f"{key} must be among {', '.join(allowed)}."
    return None


def refused(name, arguments, allows_browser=False):
    """What the call would open that the agent isn't handed, or None."""
    if name == "key" and "command" in (arguments.get("modifiers") or []):
        kind = COMMAND_KEYS.get(arguments["characters"].lower())
    elif name == "menu":
        kind = next((kind for title in arguments["path"] for pattern, kind in MENU_RES if pattern.search(title)), None)
    elif name == "type":
        kind = next((kind for pattern, kind in TYPED_RES if pattern.search(arguments["text"])), None)
    else:
        kind = None
    return None if kind is None or (kind == "browser" and allows_browser) else kind


def elements(snapshot):
    """Every element of the snapshot's windows, as the amber check reads controls."""
    return [element for window in snapshot.get("windows", []) for element in window.get("elements", [])]


def check_amber(snapshot):
    """An amber badge comes with a reason on screen, or with where the agent waits."""
    ok, detail = check_amber_has_reason({"controls": elements(snapshot)})
    if not ok and any(ELSEWHERE_RE.search(str(element.get("value") or "")) for element in elements(snapshot)):
        return True, "the agent waits in another space, which the Space button says"
    return ok, detail


def look_lines(snapshot):
    lines = []
    for window in snapshot.get("windows", []):
        lines.append(f"window {window.get('title')!r} key={window.get('isKey')} firstResponder={window.get('firstResponder')}")
        for element in window.get("elements", []):
            text = element.get("label") or element.get("title") or ""
            value = element.get("value") or ""
            if not text and not value:
                continue
            state = " (disabled)" if element.get("role") in BUTTON_ROLES and not element.get("pressable") else ""
            lines.append(f"{element.get('role', '')} {text!r}" + (f" = {value[:80]!r}" if value else "") + state)
    return lines


def mark_new(lines, previous):
    seen = set(previous)
    return [("+ " if previous and line not in seen else "  ") + line for line in lines]


def gained(before, after, typed):
    """Terminals whose text holds `typed` more times after than before."""
    def counts(answer):
        return {(t["workspace"], t["column"]): t["text"].count(typed) for t in answer.get("terminals", [])}
    old = counts(before)
    return [place for place, count in counts(after).items() if count > old.get(place, 0)]


def check_keys(before, after, typed):
    """Typed text shows only in the terminal that had the keyboard."""
    focused = [(t["workspace"], t["column"]) for t in before.get("terminals", []) if t.get("focused")]
    elsewhere = [place for place in gained(before, after, typed) if place not in focused]
    if elsewhere:
        return False, f"{typed!r} reached {', '.join(f'{w} column {c}' for w, c in elsewhere)}, not the focused terminal"
    return True, "keys stayed in the focused terminal"


class Explorer:
    def __init__(self, environ, channel=None, clock=time.time):
        self.run = Path(environ["CANARY_EXPLORER_RUN"])
        self.state = Path(environ["NIRUX_STATE_DIR"])
        self.channel = channel or Channel(self.state, environ["NIRUX_CANARY_TOKEN"])
        self.pid = int(environ.get("CANARY_APP_PID") or 0)
        self.stderr = Path(environ["CANARY_APP_STDERR"]) if environ.get("CANARY_APP_STDERR") else None
        self.episode = int(environ.get("CANARY_EPISODE") or 1)
        self.episode_actions = int(environ.get("CANARY_EPISODE_ACTIONS") or 12)
        self.clock = clock
        self.allows_browser = environ.get("CANARY_ALLOW_BROWSER") == "1"
        self.calls = 0
        self.previous_look = []
        self.stderr_offset = self.stderr.stat().st_size if self.stderr and self.stderr.exists() else 0

    # Budget, shared by the run's episodes.

    def budget(self):
        return json.loads((self.run / "budget.json").read_text())

    def spend(self, field):
        budget = self.budget()
        budget[field] = budget.get(field, 0) + 1
        (self.run / "budget.json").write_text(json.dumps(budget))
        return budget

    def refusal(self, name):
        budget = self.budget()
        if budget["calls"] >= budget["callLimit"]:
            return "The run's budget is spent: stop and write your report."
        if self.calls >= self.episode_actions:
            return "This episode's calls are spent: stop and write your report."
        if name == "render" and budget.get("renders", 0) >= budget["renderLimit"]:
            return "No renders left: use look()."
        return None

    def append(self, name, record):
        with (self.run / name).open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(record, sort_keys=True) + "\n")

    # Oracles.

    def alive(self):
        """Running, not a zombie: the runner, not this server, reaps the app."""
        if not self.pid:
            return True
        state = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(self.pid)], capture_output=True, text=True)
        return state.returncode == 0 and not state.stdout.strip().startswith("Z")

    def new_stderr(self):
        if not self.stderr or not self.stderr.exists():
            return ""
        with self.stderr.open("rb") as stream:
            stream.seek(self.stderr_offset)
            text = stream.read().decode("utf-8", "replace")
            self.stderr_offset = stream.tell()
        return text

    def oracles(self):
        """(rule, ok, detail) for each check after an action."""
        if not self.alive():
            return [("app-alive", False, "Nirux exited")]
        results = []
        try:
            snapshot = json.loads(self.channel.call("snapshot"))
            results.append(("app-answers", True, "answered"))
            results.append(("amber-has-reason", *check_amber(snapshot)))
        except (NotTaken, StillWorking) as error:
            results.append(("app-answers", False, f"the app didn't answer: {error}"))
        results.append(("state-json-valid", *check_state_json_valid(self.state)))
        fatal = [line for line in self.new_stderr().splitlines() if FATAL_RE.search(line)]
        results.append(("no-fatal-log", not fatal, fatal[0][:300] if fatal else "no fatal line"))
        return results

    # Tools.

    def terminals(self):
        return json.loads(self.channel.call("terminal"))

    def act(self, name, arguments):
        if name == "press":
            return self.channel.call("press", label=arguments["label"])
        if name == "menu":
            return self.channel.menu(*arguments["path"])
        if name == "key":
            return self.channel.key(arguments["characters"], key_code=int(arguments.get("keyCode") or 0),
                                    modifiers=arguments.get("modifiers") or [])
        return self.channel.text(arguments["text"].replace("\n", "\r"))

    def action(self, name, arguments):
        lines = arguments.get("text", "").strip().splitlines() if name == "type" else []
        typed = lines[0].strip() if lines else ""
        before = self.terminals() if len(typed) >= 3 else None
        answer = self.act(name, arguments)
        checks = self.oracles()
        if before is not None and "terminal" in answer:
            after = {}
            deadline = self.clock() + 1.5
            while self.clock() < deadline:
                after = self.terminals()
                if gained(before, after, typed):
                    break
                time.sleep(0.2)
            checks.append(("keys-reach-focused-terminal", *check_keys(before, after, typed)))
        failed = [(rule, detail) for rule, ok, detail in checks if not ok]
        for rule, detail in failed:
            self.append("findings.jsonl", {"rule": rule, "detail": detail, "episode": self.episode,
                                           "call": self.budget()["calls"], "tool": name, "arguments": arguments})
        lines = [answer[:ANSWER_LIMIT]]
        lines += [f"CHECK FAILED {rule}: {detail}" for rule, detail in failed] or ["Checks passed."]
        return "\n".join(lines), [rule for rule, _ in failed]

    def call(self, name, arguments):
        """(content, isError) for one tool call."""
        refusal = invalid(name, arguments) or self.refusal(name)
        if not refusal and refused(name, arguments, self.allows_browser):
            refusal = REFUSALS[refused(name, arguments, self.allows_browser)]
        if refusal:
            return [{"type": "text", "text": refusal}], True
        budget = self.spend("calls")
        self.calls += 1
        failed = []
        try:
            if name in ACTIONS:
                text, failed = self.action(name, arguments)
                content = [{"type": "text", "text": text}]
            elif name == "look":
                lines = look_lines(json.loads(self.channel.call("snapshot")))
                marked = mark_new(lines, self.previous_look)[:LOOK_LIMIT]
                self.previous_look = lines
                content = [{"type": "text", "text": "\n".join(marked)}]
            elif name == "terminal":
                shown = [t for t in self.terminals()["terminals"] if t.get("active")]
                text = "\n\n".join(
                    f"{t['workspace']} column {t['column']}{' (keyboard)' if t['focused'] else ''}:\n"
                    + "\n".join(t["text"].rstrip().splitlines()[-TERMINAL_LINES:])
                    for t in shown)
                content = [{"type": "text", "text": text or "No terminal is open."}]
            elif name == "render":
                self.spend("renders")
                data = Path(self.channel.call("render")).read_bytes()
                content = [{"type": "image", "data": base64.b64encode(data).decode(), "mimeType": "image/png"}]
            elif name == "note":
                self.append("notes.jsonl", {"text": arguments["text"], "episode": self.episode, "call": budget["calls"]})
                content = [{"type": "text", "text": "Noted."}]
            else:
                return [{"type": "text", "text": f"Unknown tool {name}."}], True
        except (ChannelError, KeyError, ValueError) as error:
            content = [{"type": "text", "text": f"Refused: {error}"}]
            self.append("trace.jsonl", self.trace_record(budget, name, arguments, str(error), failed, refused=True))
            return content, True
        answer = content[0].get("text", "(image)")
        self.append("trace.jsonl", self.trace_record(budget, name, arguments, answer, failed))
        return content, False

    def trace_record(self, budget, name, arguments, answer, failed, refused=False):
        return {"call": budget["calls"], "episode": self.episode, "tool": name, "arguments": arguments,
                "answer": answer[:ANSWER_LIMIT], "failed": failed, "refused": refused, "at": self.clock()}


def handle(explorer, message):
    """The JSON-RPC answer to one message, or None for a notification."""
    method, ident = message.get("method"), message.get("id")
    if ident is None:
        return None
    if method == "initialize":
        version = (message.get("params") or {}).get("protocolVersion") or PROTOCOL_VERSION
        result = {"protocolVersion": version, "capabilities": {"tools": {}},
                  "serverInfo": {"name": "nirux-canary", "version": "1"}, "instructions": INSTRUCTIONS}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        params = message.get("params") or {}
        content, is_error = explorer.call(params.get("name"), params.get("arguments") or {})
        result = {"content": content, "isError": is_error}
    elif method == "ping":
        result = {}
    else:
        return {"jsonrpc": "2.0", "id": ident, "error": {"code": -32601, "message": f"no method {method}"}}
    return {"jsonrpc": "2.0", "id": ident, "result": result}


def main(stdin=sys.stdin, stdout=sys.stdout, environ=os.environ):
    explorer = Explorer(environ)
    for line in stdin:
        if not line.strip():
            continue
        try:
            message = json.loads(line)
            reply = handle(explorer, message)
        except Exception as error:  # One bad call never ends the episode's server.
            ident = message.get("id") if isinstance(locals().get("message"), dict) else None
            reply = {"jsonrpc": "2.0", "id": ident, "error": {"code": -32603, "message": f"{type(error).__name__}: {error}"}}
        if reply is not None:
            stdout.write(json.dumps(reply) + "\n")
            stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
