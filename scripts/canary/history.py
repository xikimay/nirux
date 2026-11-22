"""Append-safe JSON incident history ledger for canary triage runs."""
import contextlib
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import tempfile

LEDGER_VERSION = 1
MAX_INLINE_HISTORY = 50
VALID_INCIDENT_CLASSES = ("regression", "intermittent", "infra_unavailable")


def utc_now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def default_history_dir():
    """Return a history directory outside the mutable repository checkout."""
    override = os.environ.get("NIRUX_CANARY_HISTORY_DIR")
    if override:
        return Path(override).expanduser().resolve()
    return Path(tempfile.gettempdir()).resolve() / "nirux-canary-history"


def _empty_state():
    return {
        "version": LEDGER_VERSION,
        "scenarios": {},
        "incidents": {},
    }


def _atomic_write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(data, indent=2, sort_keys=True) + "\n"
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp")
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_path, path)
    except Exception:
        tmp_path.unlink(missing_ok=True)
        raise


def _append_jsonl(path, event):
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n"
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as handle:
        handle.write(line)
        handle.flush()
        os.fsync(handle.fileno())


def _apply_pass_event(state, event):
    scenario = event["scenario"]
    timestamp = event["timestamp"]
    run_id = event["runId"]
    green_record = {
        "runId": run_id,
        "timestamp": timestamp,
        "commit": event.get("commit"),
        "bundleSHA256": event.get("bundleSHA256"),
    }
    state.setdefault("scenarios", {}).setdefault(scenario, {})["lastGreen"] = green_record

    resolved = []
    for fp, entry in state.setdefault("incidents", {}).items():
        if entry.get("scenario") != scenario:
            continue
        if entry.get("status") in ("open", "reopened"):
            entry["status"] = "resolved"
            entry["resolvedAt"] = timestamp
            entry["resolvedByRunId"] = run_id
            entry["lastKnownGreen"] = dict(green_record)
            resolved.append(fp)

    return {"lastGreen": dict(green_record), "resolvedFingerprints": sorted(resolved)}


def _apply_incident_event(state, event):
    fp = event["fingerprint"]
    components = event.get("components") or {}
    scenario = components.get("scenario") or event.get("scenario") or "unknown"
    classification = event["classification"]
    timestamp = event["timestamp"]
    run_id = event["runId"]
    crashed = bool(event.get("crashed", False))

    last_green = state.setdefault("scenarios", {}).get(scenario, {}).get("lastGreen")
    incidents = state.setdefault("incidents", {})
    entry = incidents.get(fp)
    reopened = False

    if entry is None:
        entry = {
            "fingerprint": fp,
            "scenario": scenario,
            "components": dict(components),
            "status": "infra" if classification == "infra_unavailable" else "open",
            "firstSeen": timestamp,
            "lastSeen": timestamp,
            "occurrences": 0,
            "reopenCount": 0,
            "reopenedAt": None,
            "resolvedAt": None,
            "resolvedByRunId": None,
            "counts": {
                "regression": 0,
                "intermittent": 0,
                "infra_unavailable": 0,
            },
            "crashCount": 0,
            "lastClassification": classification,
            "lastRunId": run_id,
            "lastCommit": event.get("commit"),
            "lastKnownGreen": dict(last_green) if last_green else None,
            "history": [],
        }
        incidents[fp] = entry
    else:
        entry["lastSeen"] = timestamp
        if components:
            entry["components"] = dict(components)
        if classification != "infra_unavailable":
            if entry.get("status") == "resolved":
                entry["status"] = "reopened"
                entry["reopenCount"] = int(entry.get("reopenCount", 0)) + 1
                entry["reopenedAt"] = timestamp
                reopened = True
            elif entry.get("status") == "infra":
                entry["status"] = "open"

    entry["occurrences"] = int(entry.get("occurrences", 0)) + 1
    counts = entry.setdefault(
        "counts",
        {"regression": 0, "intermittent": 0, "infra_unavailable": 0},
    )
    counts[classification] = int(counts.get(classification, 0)) + 1
    if crashed:
        entry["crashCount"] = int(entry.get("crashCount", 0)) + 1

    entry["lastClassification"] = classification
    entry["lastRunId"] = run_id
    entry["lastCommit"] = event.get("commit")
    if last_green is not None:
        entry["lastKnownGreen"] = dict(last_green)

    history = entry.setdefault("history", [])
    history.append({
        "runId": run_id,
        "timestamp": timestamp,
        "classification": classification,
        "commit": event.get("commit"),
        "bundleSHA256": event.get("bundleSHA256"),
        "crashed": crashed,
        "reopened": reopened,
        "investigationDir": event.get("investigationDir"),
    })
    if len(history) > MAX_INLINE_HISTORY:
        del history[:-MAX_INLINE_HISTORY]

    return {
        "incident": json.loads(json.dumps(entry)),
        "reopened": reopened,
        "lastKnownGreen": dict(last_green) if last_green else None,
    }


class IncidentLedger:
    """File-locked, append-safe incident history ledger (events.jsonl + atomic incidents.json)."""

    def __init__(self, history_dir):
        self.history_dir = Path(history_dir).resolve()
        self.events_path = self.history_dir / "events.jsonl"
        self.ledger_path = self.history_dir / "incidents.json"
        self.lock_path = self.history_dir / "ledger.lock"

    @contextlib.contextmanager
    def _locked(self):
        self.history_dir.mkdir(parents=True, exist_ok=True)
        with self.lock_path.open("a+", encoding="utf-8") as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)

    def _rebuild_from_events(self):
        state = _empty_state()
        if not self.events_path.is_file():
            return state
        for raw_line in self.events_path.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue
            event_type = event.get("type")
            if event_type == "pass":
                _apply_pass_event(state, event)
            elif event_type == "incident":
                _apply_incident_event(state, event)
        return state

    def _load_unlocked(self):
        if self.ledger_path.is_file():
            try:
                data = json.loads(self.ledger_path.read_text(encoding="utf-8"))
                if isinstance(data, dict) and data.get("version") == LEDGER_VERSION:
                    return data
            except (OSError, ValueError):
                pass
        return self._rebuild_from_events()

    def load(self):
        with self._locked():
            return self._load_unlocked()

    def record_pass(
        self,
        scenario,
        *,
        run_id,
        commit=None,
        bundle_sha256=None,
        timestamp=None,
    ):
        event = {
            "type": "pass",
            "scenario": scenario,
            "runId": run_id,
            "timestamp": timestamp or utc_now_iso(),
            "commit": commit,
            "bundleSHA256": bundle_sha256,
        }
        with self._locked():
            state = self._load_unlocked()
            result = _apply_pass_event(state, event)
            _append_jsonl(self.events_path, event)
            _atomic_write_json(self.ledger_path, state)
        return result

    def record_incident(
        self,
        fingerprint,
        components,
        classification,
        *,
        run_id,
        commit=None,
        bundle_sha256=None,
        crashed=False,
        investigation_dir=None,
        timestamp=None,
    ):
        if classification not in VALID_INCIDENT_CLASSES:
            raise ValueError(f"unsupported incident classification: {classification}")
        scenario = (components or {}).get("scenario") or "unknown"
        event = {
            "type": "incident",
            "scenario": scenario,
            "fingerprint": fingerprint,
            "components": dict(components or {}),
            "classification": classification,
            "runId": run_id,
            "timestamp": timestamp or utc_now_iso(),
            "commit": commit,
            "bundleSHA256": bundle_sha256,
            "crashed": bool(crashed),
            "investigationDir": str(investigation_dir) if investigation_dir else None,
        }
        with self._locked():
            state = self._load_unlocked()
            result = _apply_incident_event(state, event)
            _append_jsonl(self.events_path, event)
            _atomic_write_json(self.ledger_path, state)
        return result
