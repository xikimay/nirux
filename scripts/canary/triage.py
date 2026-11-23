"""Multi-run reproduction, deterministic classification, fingerprinting, and crash investigation."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import signal

from crash_correlator import is_unexpected_process_exit

PASS = "pass"
REGRESSION = "regression"
INTERMITTENT = "intermittent"
INFRA = "infra_unavailable"
CLASSIFICATIONS = (PASS, REGRESSION, INTERMITTENT, INFRA)

FINGERPRINT_VERSION = 1

_HEX_ADDR_RE = re.compile(r"0x[0-9a-fA-F]+")
_UUID_RE = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)
_SEED_TOKEN_RE = re.compile(r"\b(edit|restored)[0-9a-fA-F]{32}\b|\b(ALPHA|BETA)-[0-9a-fA-F]{8,32}\b")
_TIMESTAMP_RE = re.compile(
    r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|\s*[+-]\d{2}:?\d{2})?"
)
_CANARY_TMP_ROOT_RE = re.compile(r"(?:/private)?/tmp/nirux-[a-z0-9]+-[A-Za-z0-9._-]+")
_VAR_TMP_RE = re.compile(r"(?:/private)?/var/folders/[^/\s'\",\]\)]+/[^/\s'\",\]\)]+/T/[^\s'\",\]\)]+")
_GENERIC_TMP_RE = re.compile(r"(?:/private)?/tmp/[^\s'\",\]\)]+")
_PID_LABELED_RE = re.compile(r"(?i)\b(pid|byPid)\s*[:= ]\s*\d+\b")
_PROCESS_NUM_RE = re.compile(r"(?i)\bprocess\s+\d+\b")
_DRIVER_PID_ARG_RE = re.compile(
    r"(['\"](?:window|open-editor|editor-focus|terminal|editor|save|quit|text|command|"
    r"menu|window-frame|resize-window|ax-controls|press-control|shortcut)['\"],\s*['\"])\d+(['\"])"
)
_WHITESPACE_RE = re.compile(r"\s+")


def signal_name(exit_code):
    if exit_code is None:
        return "UNKNOWN"
    if exit_code < 0:
        sig_num = -exit_code
        try:
            return signal.Signals(sig_num).name
        except ValueError:
            return f"SIG{sig_num}"
    return f"exit-{exit_code}"


def normalize_error_text(text):
    """Strip variable PIDs, temp paths, timestamps, UUIDs, and memory addresses from error text."""
    if not text:
        return "unknown"
    value = str(text)
    value = _TIMESTAMP_RE.sub("<timestamp>", value)
    value = _UUID_RE.sub("<uuid>", value)
    value = _SEED_TOKEN_RE.sub(lambda m: (m.group(1) or m.group(2) + "-") + "<seed>", value)
    value = _HEX_ADDR_RE.sub("<addr>", value)
    value = _CANARY_TMP_ROOT_RE.sub("<tmp>", value)
    value = _VAR_TMP_RE.sub("<tmp_path>", value)
    value = _GENERIC_TMP_RE.sub("<tmp_path>", value)
    value = _DRIVER_PID_ARG_RE.sub(r"\1<pid>\2", value)
    value = _PID_LABELED_RE.sub(r"\1=<pid>", value)
    value = _PROCESS_NUM_RE.sub("process <pid>", value)
    value = _WHITESPACE_RE.sub(" ", value).strip()
    return value or "unknown"


def attempt_has_crash(report):
    """Return True if an attempt experienced a crash or unexpected non-zero/signal termination."""
    if not isinstance(report, dict):
        return False
    if report.get("crashed"):
        return True
    if report.get("crashes"):
        return True
    return any(is_unexpected_process_exit(proc) for proc in report.get("processes") or [])


def _failed_step_reason(report):
    failed_step = report.get("failedStep")
    if failed_step == "cleanup" and report.get("cleanupError"):
        return report["cleanupError"]
    for step in reversed(report.get("steps") or []):
        if step.get("id") == failed_step and step.get("reason"):
            return step["reason"]
    for step in reversed(report.get("steps") or []):
        if step.get("verdict") != PASS and step.get("reason"):
            return step["reason"]
    return report.get("cleanupError") or ""


def _crash_error_kind(report):
    crashes = report.get("crashes") or []
    for crash in crashes:
        exc = crash.get("exceptionType")
        sig = crash.get("signal")
        term = crash.get("termination")
        if exc and sig:
            return f"crash:{exc}:{sig}"
        if exc:
            return f"crash:{exc}"
        if sig:
            return f"crash:{sig}"
        if term:
            return f"crash:{normalize_error_text(term)}"

    for proc in report.get("processes") or []:
        if is_unexpected_process_exit(proc):
            return f"crash:{signal_name(proc.get('exitCode'))}"
    return "crash:unknown"


def compute_fingerprint(report):
    """Compute a deterministic fingerprint from (scenario, surface, errorKind, normalized_frames)."""
    scenario = report.get("scenario") or "unknown"
    surface = report.get("failedStep") or "unknown"
    crashes = report.get("crashes") or []

    frames = []
    for crash in crashes:
        candidate_frames = crash.get("normalizedFrames") or []
        if candidate_frames:
            frames = list(candidate_frames)
            break

    if attempt_has_crash(report):
        error_kind = _crash_error_kind(report)
    else:
        error_kind = normalize_error_text(_failed_step_reason(report))

    components = {
        "scenario": scenario,
        "surface": surface,
        "errorKind": error_kind,
        "frames": frames,
    }
    canonical = json.dumps(
        {"version": FINGERPRINT_VERSION, **components},
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    fp_id = "fp-" + hashlib.sha256(canonical).hexdigest()[:16]
    return {"fingerprint": fp_id, "components": components}


def _failures_match(initial_fp, replay_fp):
    c1 = initial_fp["components"]
    c2 = replay_fp["components"]
    if c1["scenario"] != c2["scenario"]:
        return False
    if c1["surface"] != c2["surface"]:
        return False
    if c1["errorKind"] != c2["errorKind"]:
        return False
    if c1["frames"] and c2["frames"]:
        return c1["frames"] == c2["frames"]
    return True


def classify_attempts(initial, replays):
    """Deterministically classify an initial attempt and its fresh-state replays."""
    replays = list(replays or [])
    all_attempts = [initial, *replays]
    initial_verdict = initial.get("verdict")

    initial_fp = None if initial_verdict == PASS else compute_fingerprint(initial)
    attempt_fps = []
    for attempt in all_attempts:
        fp = None if attempt.get("verdict") == PASS else compute_fingerprint(attempt)
        attempt_fps.append(fp)

    crash_attempts = [a for a in all_attempts if attempt_has_crash(a)]
    has_crash = len(crash_attempts) > 0
    matching_replays = 0
    passed_replays = 0
    failed_replays = 0
    infra_replays = 0

    if initial_verdict == PASS:
        classification = PASS
    elif initial_verdict == INFRA:
        classification = INFRA
    else:
        for replay, replay_fp in zip(replays, attempt_fps[1:]):
            r_verdict = replay.get("verdict")
            if r_verdict == PASS:
                passed_replays += 1
            elif r_verdict == INFRA:
                infra_replays += 1
            else:
                failed_replays += 1
                if replay_fp is not None and _failures_match(initial_fp, replay_fp):
                    matching_replays += 1

        if replays and matching_replays == len(replays):
            classification = REGRESSION
        else:
            classification = INTERMITTENT

    investigation_required = (classification == REGRESSION) or has_crash
    if classification == REGRESSION and has_crash:
        investigation_reason = "regression_with_crash"
    elif classification == REGRESSION:
        investigation_reason = "regression"
    elif has_crash:
        investigation_reason = (
            "single_crash_observed" if len(crash_attempts) == 1 else "multiple_crashes_observed"
        )
    else:
        investigation_reason = None

    crash_fingerprints = []
    for attempt, fp in zip(all_attempts, attempt_fps):
        if attempt_has_crash(attempt) and fp is not None:
            if fp["fingerprint"] not in crash_fingerprints:
                crash_fingerprints.append(fp["fingerprint"])

    return {
        "classification": classification,
        "fingerprint": initial_fp["fingerprint"] if initial_fp else None,
        "fingerprintComponents": initial_fp["components"] if initial_fp else None,
        "hasCrash": has_crash,
        "crashCount": len(crash_attempts),
        "crashFingerprints": crash_fingerprints,
        "totalAttempts": len(all_attempts),
        "replayCounts": {
            "total": len(replays),
            "matched": matching_replays,
            "passed": passed_replays,
            "failed": failed_replays,
            "infraUnavailable": infra_replays,
        },
        "investigationRequired": investigation_required,
        "investigationReason": investigation_reason,
    }


def triage_exit_code(classification, has_crash=False):
    if classification == PASS:
        return 0
    if classification == INFRA:
        return 2
    if classification == REGRESSION:
        return 1
    if classification == INTERMITTENT:
        return 1 if has_crash else 3
    return 1


def open_investigation(triage_dir, triage_result, attempt_records, incident_update=None):
    """Create a self-contained investigation bundle directory for regressions and any observed crash."""
    inv_dir = Path(triage_dir) / "investigation"
    inv_dir.mkdir(parents=True, exist_ok=True)
    crashes_dir = inv_dir / "crashes"

    copied_crashes = []
    attempt_summaries = []
    for record in attempt_records:
        label = record["label"]
        report = record["report"]
        evidence_dir = Path(record["evidenceDir"])
        crashed = attempt_has_crash(report)
        fp = None if report.get("verdict") == PASS else compute_fingerprint(report)

        for crash in report.get("crashes") or []:
            src = Path(crash["copiedPath"]) if crash.get("copiedPath") else None
            inv_rel = None
            if src and src.is_file():
                crashes_dir.mkdir(parents=True, exist_ok=True)
                dest = crashes_dir / f"{label}-{src.name}"
                shutil.copyfile(src, dest)
                inv_rel = str(dest.relative_to(inv_dir))
            copied_crashes.append({
                "attempt": label,
                "incidentId": crash.get("incidentId"),
                "fileName": crash.get("fileName"),
                "investigationPath": inv_rel,
                "pid": crash.get("pid"),
                "matchedProcessPid": crash.get("matchedProcessPid"),
                "matchedExitCode": crash.get("matchedExitCode"),
                "exceptionType": crash.get("exceptionType"),
                "signal": crash.get("signal"),
                "termination": crash.get("termination"),
                "normalizedFrames": crash.get("normalizedFrames", []),
            })

        attempt_summaries.append({
            "label": label,
            "verdict": report.get("verdict"),
            "failedStep": report.get("failedStep"),
            "crashed": crashed,
            "fingerprint": fp["fingerprint"] if fp else None,
            "reportPath": str(evidence_dir / "report.json"),
            "replay": report.get("replay"),
        })

    payload = {
        "version": 1,
        "opened": True,
        "reason": triage_result["investigationReason"],
        "classification": triage_result["classification"],
        "fingerprint": triage_result["fingerprint"],
        "fingerprintComponents": triage_result["fingerprintComponents"],
        "crashCount": triage_result["crashCount"],
        "totalAttempts": triage_result["totalAttempts"],
        "crashFingerprints": triage_result["crashFingerprints"],
        "crashes": copied_crashes,
        "attempts": attempt_summaries,
        "incident": incident_update,
    }
    inv_path = inv_dir / "investigation.json"
    inv_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return inv_path
