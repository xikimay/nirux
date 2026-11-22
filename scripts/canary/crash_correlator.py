"""External macOS .ips crash report parsing and correlation for the canary supervisor."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import time

CRASH_BUG_TYPE = "309"
DEFAULT_PROCESS_NAME = "Nirux"
DEFAULT_BUNDLE_ID = "com.xikimay.nirux"
MAX_FINGERPRINT_FRAMES = 6

_HEX_ADDR_RE = re.compile(r"0x[0-9a-fA-F]+")
_UUID_RE = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)
_TIMESTAMP_RE = re.compile(
    r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|\s*[+-]\d{2}:?\d{2})?"
)
_TMP_PATH_RE = re.compile(r"(?:/private)?/(?:tmp|var/folders)/[^\s'\",\]\)]+")
_PID_RE = re.compile(r"(?i)\bpid\s*[:= ]\s*\d+\b")

_SYMBOL_WRAPPERS = (
    "partial apply for ",
    "thunk for ",
    "specialized ",
    "merged ",
    "@objc ",
    "static ",
)
_SYMBOL_PREFIX_PATTERNS = (
    re.compile(r"^(?:implicit )?closure #\d+ (?:.*? )?in "),
    re.compile(r"^\(extension in [^)]*\):"),
)


def default_crash_reports_dir():
    real_home = Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
    return real_home / "Library/Logs/DiagnosticReports"


def _clean_str(value):
    if not isinstance(value, str):
        return None
    stripped = value.strip()
    return stripped or None


def _clean_int(value):
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value


def parse_ips_timestamp(text):
    """Parse macOS .ips timestamp ('YYYY-MM-DD HH:MM:SS.ff +ZZZZ' or ISO-8601) to UTC epoch."""
    text = _clean_str(text)
    if not text:
        return None

    # ISO-8601 form (e.g. 2026-09-27T11:14:48Z or 2026-09-27T11:14:48.123+02:00)
    if "T" in text:
        iso = text[:-1] + "+00:00" if text.endswith("Z") else text
        try:
            dt = datetime.fromisoformat(iso)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.timestamp()
        except ValueError:
            return None

    # Standard Apple .ips format: "2026-09-27 11:14:48.00 +0200" (arbitrary fractional digits)
    parts = text.split(" ")
    if len(parts) != 3:
        return None
    date_part, clock_part, tz_part = parts
    if "." in clock_part:
        seconds_part, frac_part = clock_part.split(".", 1)
        if not frac_part.isdigit():
            return None
        fraction = float("0." + frac_part)
    else:
        seconds_part = clock_part
        fraction = 0.0
    try:
        dt = datetime.strptime(f"{date_part} {seconds_part} {tz_part}", "%Y-%m-%d %H:%M:%S %z")
    except ValueError:
        return None
    return dt.timestamp() + fraction


def _parse_frames(raw_frames, images):
    frames = []
    if not isinstance(raw_frames, list):
        return frames
    for item in raw_frames:
        if not isinstance(item, dict):
            continue
        image_index = _clean_int(item.get("imageIndex"))
        image = None
        if image_index is not None and 0 <= image_index < len(images):
            image = images[image_index]
        frames.append({
            "image": image,
            "symbol": _clean_str(item.get("symbol")),
            "symbolOffset": _clean_int(item.get("symbolLocation")),
            "imageOffset": _clean_int(item.get("imageOffset")),
        })
    return frames


def _parse_asi(raw_asi):
    if not isinstance(raw_asi, dict):
        return []
    messages = []
    for key in sorted(raw_asi):
        val = raw_asi[key]
        if isinstance(val, list):
            for entry in val:
                cleaned = _clean_str(entry)
                if cleaned:
                    messages.append(cleaned)
        else:
            cleaned = _clean_str(val)
            if cleaned:
                messages.append(cleaned)
    return messages


def parse_ips_file(path):
    """Leniently parse a macOS .ips crash report file. Returns None if unreadable/non-JSON header."""
    path = Path(path)
    try:
        raw = path.read_bytes()
    except OSError:
        return None

    newline = raw.find(b"\n")
    first_line = raw if newline == -1 else raw[:newline]
    try:
        header = json.loads(first_line.decode("utf-8", errors="replace"))
    except (ValueError, TypeError):
        return None
    if not isinstance(header, dict):
        return None

    bug_type = _clean_str(header.get("bug_type"))
    header_ts = _clean_str(header.get("timestamp"))
    parsed = {
        "path": str(path),
        "fileName": path.name,
        "hasBody": False,
        "bugType": bug_type,
        "isCrash": bug_type is None or bug_type == CRASH_BUG_TYPE,
        "bundleId": _clean_str(header.get("bundleID")),
        "appName": _clean_str(header.get("app_name")) or _clean_str(header.get("name")),
        "processName": _clean_str(header.get("app_name")) or _clean_str(header.get("name")),
        "incidentId": _clean_str(header.get("incident_id")),
        "headerTimestamp": header_ts,
        "headerTimestampEpoch": parse_ips_timestamp(header_ts),
        "captureTime": None,
        "captureTimeEpoch": None,
        "procLaunch": None,
        "procLaunchEpoch": None,
        "pid": None,
        "procPath": None,
        "procRole": None,
        "parentProc": None,
        "exceptionType": None,
        "signal": None,
        "exceptionSubtype": None,
        "termination": None,
        "faultingThread": None,
        "frames": [],
        "exceptionBacktrace": [],
        "messages": [],
    }

    if newline == -1:
        return parsed
    body_bytes = raw[newline + 1:].strip()
    if not body_bytes:
        return parsed
    try:
        body = json.loads(body_bytes.decode("utf-8", errors="replace"))
    except (ValueError, TypeError):
        return parsed
    if not isinstance(body, dict):
        return parsed

    parsed["hasBody"] = True
    parsed["processName"] = _clean_str(body.get("procName")) or parsed["processName"]
    bundle_info = body.get("bundleInfo")
    if isinstance(bundle_info, dict) and not parsed["bundleId"]:
        parsed["bundleId"] = _clean_str(bundle_info.get("CFBundleIdentifier"))
    parsed["pid"] = _clean_int(body.get("pid"))
    parsed["procPath"] = _clean_str(body.get("procPath"))
    parsed["procRole"] = _clean_str(body.get("procRole"))
    parsed["parentProc"] = _clean_str(body.get("parentProc"))

    capture_time = _clean_str(body.get("captureTime"))
    parsed["captureTime"] = capture_time
    parsed["captureTimeEpoch"] = parse_ips_timestamp(capture_time)

    proc_launch = _clean_str(body.get("procLaunch"))
    parsed["procLaunch"] = proc_launch
    parsed["procLaunchEpoch"] = parse_ips_timestamp(proc_launch)

    exception = body.get("exception")
    if isinstance(exception, dict):
        parsed["exceptionType"] = _clean_str(exception.get("type"))
        parsed["signal"] = _clean_str(exception.get("signal"))
        parsed["exceptionSubtype"] = _clean_str(exception.get("subtype"))

    termination = body.get("termination")
    if isinstance(termination, dict):
        parsed["termination"] = _clean_str(termination.get("indicator"))

    raw_images = body.get("usedImages")
    images = []
    if isinstance(raw_images, list):
        for img in raw_images:
            images.append(_clean_str(img.get("name")) if isinstance(img, dict) else None)

    raw_threads = body.get("threads")
    threads = raw_threads if isinstance(raw_threads, list) else []
    declared = _clean_int(body.get("faultingThread"))
    faulting_index = None
    if declared is not None and 0 <= declared < len(threads):
        faulting_index = declared
    else:
        for idx, thread in enumerate(threads):
            if isinstance(thread, dict) and thread.get("triggered") is True:
                faulting_index = idx
                break
    parsed["faultingThread"] = faulting_index if faulting_index is not None else declared
    if faulting_index is not None and isinstance(threads[faulting_index], dict):
        parsed["frames"] = _parse_frames(threads[faulting_index].get("frames"), images)

    parsed["exceptionBacktrace"] = _parse_frames(body.get("lastExceptionBacktrace"), images)
    parsed["messages"] = _parse_asi(body.get("asi"))
    return parsed


def _argument_list_start(name):
    depth = 0
    previous = None
    for idx, ch in enumerate(name):
        if ch == "<":
            depth += 1
        elif ch == ">" and previous != "-":
            depth = max(0, depth - 1)
        elif ch == "(" and depth == 0:
            return idx
        previous = ch
    return len(name)


def normalize_symbol(symbol):
    """Normalize a crash stack symbol, stripping Swift wrappers, arg lists, addresses, and temp paths."""
    if not symbol:
        return "<unknown>"
    text = symbol.strip()
    text = _HEX_ADDR_RE.sub("<addr>", text)
    text = _UUID_RE.sub("<uuid>", text)
    text = _TIMESTAMP_RE.sub("<timestamp>", text)
    text = _TMP_PATH_RE.sub("<tmp>", text)
    text = _PID_RE.sub("pid=<pid>", text)

    if text.startswith("-[") or text.startswith("+["):
        return text

    name = text
    stripped = True
    while stripped:
        stripped = False
        for wrapper in _SYMBOL_WRAPPERS:
            if name.startswith(wrapper):
                name = name[len(wrapper):]
                stripped = True
        for pattern in _SYMBOL_PREFIX_PATTERNS:
            match = pattern.match(name)
            if match:
                name = name[match.end():]
                stripped = True

    cut = _argument_list_start(name)
    short = name[:cut].strip()
    return short or text


def format_normalized_frame(frame):
    image = frame.get("image") or "<unknown>"
    symbol = frame.get("symbol")
    if symbol:
        return f"{image}:{normalize_symbol(symbol)}"
    return f"{image}:<unsym>"


def extract_normalized_frames(parsed, process_name=DEFAULT_PROCESS_NAME, max_frames=MAX_FINGERPRINT_FRAMES):
    """Extract deterministic normalized crash frames, ensuring app binary frames are represented."""
    combined = list(parsed.get("exceptionBacktrace") or []) + list(parsed.get("frames") or [])
    if not combined:
        return []

    formatted = [format_normalized_frame(f) for f in combined]
    selected_indices = []
    seen_indices = set()

    def add_index(idx):
        if idx not in seen_indices and len(selected_indices) < max_frames:
            seen_indices.add(idx)
            selected_indices.append(idx)

    # First reserve top 3 faulting frames
    for idx in range(min(3, len(combined))):
        add_index(idx)

    # Ensure earliest frames in the app's own binary are included even below runtime traps
    app_added = 0
    for idx, frame in enumerate(combined):
        if frame.get("image") == process_name and frame.get("symbol"):
            add_index(idx)
            app_added += 1
            if app_added >= 3:
                break

    # Fill any remaining slots with subsequent frames in order
    for idx in range(len(combined)):
        if len(selected_indices) >= max_frames:
            break
        add_index(idx)

    selected_indices.sort()
    return [formatted[idx] for idx in selected_indices]


def is_unexpected_process_exit(proc):
    """Return True if a launched process terminated unexpectedly (crash / signal / non-zero exit)."""
    if not isinstance(proc, dict):
        return False
    if proc.get("killedByCleanup"):
        return False
    code = proc.get("exitCode")
    return code is not None and code != 0


def _report_event_epoch(parsed, path):
    if parsed.get("captureTimeEpoch") is not None:
        return parsed["captureTimeEpoch"]
    if parsed.get("headerTimestampEpoch") is not None:
        return parsed["headerTimestampEpoch"]
    try:
        return path.stat().st_mtime
    except OSError:
        return None


def _matches_process(parsed, path, proc, *, process_name, bundle_id, pre_window_seconds, post_window_seconds, now):
    if not parsed.get("isCrash", False):
        return None

    proc_name_in_ips = parsed.get("processName")
    if proc_name_in_ips != process_name:
        return None

    ips_bundle_id = parsed.get("bundleId")
    if bundle_id and ips_bundle_id and ips_bundle_id != bundle_id:
        return None

    expected_pid = _clean_int(proc.get("pid"))
    ips_pid = parsed.get("pid")
    if expected_pid is not None and ips_pid is not None and ips_pid != expected_pid:
        return None

    event_epoch = _report_event_epoch(parsed, path)
    started_at = proc.get("startedAt")
    ended_at = proc.get("endedAt")
    if event_epoch is not None:
        if started_at is not None and event_epoch < (started_at - pre_window_seconds):
            return None
        upper = (ended_at if ended_at is not None else now) + post_window_seconds
        if event_epoch > upper:
            return None

    # If the .ips records procLaunch, verify it aligns with the process start window
    proc_launch_epoch = parsed.get("procLaunchEpoch")
    if proc_launch_epoch is not None and started_at is not None:
        launch_lower = started_at - max(pre_window_seconds, 15.0)
        launch_upper = (ended_at if ended_at is not None else now) + 5.0
        if not (launch_lower <= proc_launch_epoch <= launch_upper):
            return None

    # Score match quality: exact PID match + body present + closeness to ended_at
    pid_exact = 1 if (expected_pid is not None and ips_pid == expected_pid) else 0
    has_body = 1 if parsed.get("hasBody") else 0
    ref_time = ended_at if ended_at is not None else (started_at if started_at is not None else now)
    delta = abs(event_epoch - ref_time) if event_epoch is not None else float("inf")
    return (pid_exact, has_body, -delta)


def _scan_once(crashed_procs, search_dir, *, process_name, bundle_id, pre_window_seconds, post_window_seconds):
    if not search_dir or not Path(search_dir).is_dir():
        return []
    now = time.time()
    best_by_incident = {}

    for entry in sorted(Path(search_dir).iterdir()):
        if entry.suffix != ".ips" or not entry.is_file() or entry.is_symlink():
            continue
        parsed = parse_ips_file(entry)
        if parsed is None:
            continue

        best_proc = None
        best_score = None
        for proc in crashed_procs:
            score = _matches_process(
                parsed,
                entry,
                proc,
                process_name=process_name,
                bundle_id=bundle_id,
                pre_window_seconds=pre_window_seconds,
                post_window_seconds=post_window_seconds,
                now=now,
            )
            if score is not None and (best_score is None or score > best_score):
                best_score = score
                best_proc = proc

        if best_proc is None:
            continue

        incident_key = parsed.get("incidentId") or entry.name
        existing = best_by_incident.get(incident_key)
        candidate = (best_score, entry, parsed, best_proc)
        if existing is None or candidate[0] > existing[0]:
            best_by_incident[incident_key] = candidate

    matches = sorted(best_by_incident.values(), key=lambda item: item[0], reverse=True)
    return matches


def _copy_ips(source_path, crashes_dir):
    crashes_dir.mkdir(parents=True, exist_ok=True)
    dest = crashes_dir / source_path.name
    if dest.exists():
        stem = source_path.stem
        suffix = source_path.suffix
        counter = 1
        while dest.exists():
            dest = crashes_dir / f"{stem}-{counter}{suffix}"
            counter += 1
    shutil.copyfile(source_path, dest)
    return dest


def correlate_crash_reports(
    processes,
    search_dir,
    evidence_dir,
    *,
    process_name=DEFAULT_PROCESS_NAME,
    bundle_id=DEFAULT_BUNDLE_ID,
    wait_seconds=0.0,
    poll_interval=0.25,
    pre_window_seconds=5.0,
    post_window_seconds=60.0,
):
    """Correlate .ips crash reports for unexpectedly terminated processes and copy them into evidence."""
    crashed_procs = [proc for proc in (processes or []) if is_unexpected_process_exit(proc)]
    if not crashed_procs:
        return []

    search_path = Path(search_dir) if search_dir is not None else default_crash_reports_dir()
    deadline = time.monotonic() + max(0.0, float(wait_seconds))
    matches = []

    while True:
        matches = _scan_once(
            crashed_procs,
            search_path,
            process_name=process_name,
            bundle_id=bundle_id,
            pre_window_seconds=pre_window_seconds,
            post_window_seconds=post_window_seconds,
        )
        matched_pids = {
            proc.get("pid")
            for _, _, parsed, proc in matches
            if parsed.get("hasBody")
        }
        expected_pids = {proc.get("pid") for proc in crashed_procs}
        if matches and expected_pids.issubset(matched_pids):
            break
        if time.monotonic() >= deadline:
            break
        time.sleep(min(poll_interval, max(0.01, deadline - time.monotonic())))

    evidence_path = Path(evidence_dir)
    crashes_dir = evidence_path / "crashes"
    results = []
    for _, source_path, parsed, proc in matches:
        copied = _copy_ips(source_path, crashes_dir)
        normalized_frames = extract_normalized_frames(parsed, process_name=process_name)
        results.append({
            "incidentId": parsed.get("incidentId"),
            "sourceFile": str(source_path),
            "fileName": source_path.name,
            "copiedPath": str(copied),
            "relativePath": str(copied.relative_to(evidence_path)),
            "pid": parsed.get("pid"),
            "matchedProcessPid": proc.get("pid"),
            "matchedExitCode": proc.get("exitCode"),
            "processName": parsed.get("processName"),
            "bundleId": parsed.get("bundleId"),
            "hasBody": parsed.get("hasBody"),
            "exceptionType": parsed.get("exceptionType"),
            "signal": parsed.get("signal"),
            "exceptionSubtype": parsed.get("exceptionSubtype"),
            "termination": parsed.get("termination"),
            "captureTime": parsed.get("captureTime") or parsed.get("headerTimestamp"),
            "normalizedFrames": normalized_frames,
            "messages": parsed.get("messages", [])[:3],
        })
    return results
