import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import uuid

from crash_correlator import (
    correlate_crash_reports,
    extract_normalized_frames,
    normalize_symbol,
    parse_ips_file,
    parse_ips_timestamp,
)
from history import default_history_dir, IncidentLedger
from qualify import compute_timing_stats, evaluate_qualification, qualification_exit_code
from run import (
    App,
    INFRA,
    iteration,
    manifest,
    Report,
    run_qualification,
    run_triage,
    SCENARIO,
)
from triage import (
    attempt_has_crash,
    classify_attempts,
    compute_fingerprint,
    INTERMITTENT,
    normalize_error_text,
    PASS,
    REGRESSION,
    triage_exit_code,
)


def make_ips_text(
    *,
    process_name="Nirux",
    bundle_id="com.xikimay.nirux",
    bug_type="309",
    incident_id=None,
    pid=42424,
    header_ts="2026-11-22 10:00:05.00 +0000",
    capture_time="2026-11-22 10:00:04.2500 +0000",
    proc_launch="2026-11-22 10:00:00.0000 +0000",
    exception_type="EXC_BREAKPOINT",
    signal_name="SIGTRAP",
    app_symbol="closure #1 in NiruxShellView.inspectForPanel(_:panel:queue:)",
    app_symbol_loc=256,
    app_image_offset=1349304,
    include_body=True,
    last_exception_frames=None,
):
    header = {
        "app_name": process_name,
        "name": process_name,
        "bundleID": bundle_id,
        "bug_type": bug_type,
        "incident_id": incident_id or str(uuid.uuid4()),
        "timestamp": header_ts,
    }
    first_line = json.dumps(header, sort_keys=True)
    if not include_body:
        return first_line + "\n"

    frames = [
        {"imageIndex": 1, "symbol": "_dispatch_assert_queue_fail", "symbolLocation": 120, "imageOffset": 226556},
        {"imageIndex": 1, "symbol": "dispatch_assert_queue$V2.cold.1", "symbolLocation": 116, "imageOffset": 229224},
        {"imageIndex": 1, "symbol": "dispatch_assert_queue", "symbolLocation": 108, "imageOffset": 20756},
        {"imageIndex": 2, "symbol": "_swift_task_checkIsolatedSwift", "symbolLocation": 48, "imageOffset": 349564},
        {"imageIndex": 2, "symbol": "swift_task_isCurrentExecutorWithFlagsImpl(swift::SerialExecutorRef)", "symbolLocation": 356, "imageOffset": 20764},
        {"imageIndex": 0, "symbol": app_symbol, "symbolLocation": app_symbol_loc, "imageOffset": app_image_offset},
        {"imageIndex": 3, "imageOffset": 99999},
    ]
    body = {
        "version": 2,
        "procName": process_name,
        "procRole": "Foreground",
        "parentProc": "sandbox-exec",
        "procPath": f"/private/tmp/nirux-canary-abc/{process_name}.app/Contents/MacOS/{process_name}",
        "bundleInfo": {"CFBundleIdentifier": bundle_id},
        "captureTime": capture_time,
        "procLaunch": proc_launch,
        "exception": {
            "type": exception_type,
            "signal": signal_name,
            "codes": "0x0000000000000001, 0x0000000180bac4fc",
        },
        "termination": {
            "namespace": "SIGNAL",
            "code": 5,
            "indicator": "Trace/BPT trap: 5",
        },
        "faultingThread": 1,
        "threads": [
            {"id": 1, "frames": [{"imageIndex": 3, "symbol": "mach_msg2_trap", "imageOffset": 8}]},
            {"id": 2, "triggered": True, "frames": frames},
        ],
        "usedImages": [
            {"name": process_name, "path": f"/private/tmp/nirux-canary-abc/{process_name}.app/Contents/MacOS/{process_name}"},
            {"name": "libdispatch.dylib", "path": "/usr/lib/system/libdispatch.dylib"},
            {"name": "libswift_Concurrency.dylib", "path": "/usr/lib/swift/libswift_Concurrency.dylib"},
            {"name": "libsystem_pthread.dylib", "path": "/usr/lib/system/libsystem_pthread.dylib"},
        ],
    }
    if pid is not None:
        body["pid"] = pid
    if last_exception_frames is not None:
        body["lastExceptionBacktrace"] = last_exception_frames
    return first_line + "\n" + json.dumps(body, indent=2) + "\n"


def fake_report(
    verdict="pass",
    *,
    failed_step=None,
    reason=None,
    scenario=SCENARIO,
    duration_ms=1000,
    processes=None,
    crashes=None,
    crashed=False,
    bundle_sha="abc123",
    steps=None,
):
    if steps is None:
        steps = [{"id": "preflight", "verdict": "pass", "durationMs": 50}]
        if verdict != "pass" and failed_step:
            steps.append({
                "id": failed_step,
                "verdict": verdict,
                "reason": reason or "failure",
                "durationMs": 200,
            })
        else:
            steps.append({"id": "final-quit", "verdict": "pass", "durationMs": 120})
    return {
        "version": 1,
        "scenario": scenario,
        "seed": str(uuid.uuid4()),
        "bundleSHA256": bundle_sha,
        "verdict": verdict,
        "failedStep": failed_step,
        "steps": steps,
        "preflight": {"keyWindow": verdict != INFRA},
        "processes": list(processes or []),
        "crashes": list(crashes or []),
        "crashed": crashed or bool(crashes),
        "durationMs": duration_ms,
        "replay": ["scripts/canary.sh", "--replay", "/tmp/example"],
    }


class ClassificationTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.history_dir = self.root / "history"
        self.ledger = IncidentLedger(self.history_dir)

    def test_pass_classification_skips_replays_and_updates_last_green(self):
        calls = []

        def execute(label, evidence_dir, archive_override):
            calls.append(label)
            rep = fake_report("pass", bundle_sha="sha-green-1")
            (evidence_dir / "report.json").write_text(json.dumps(rep))
            return rep

        summary = run_triage(
            execute,
            self.root / "triage-pass",
            repro_runs=2,
            ledger=self.ledger,
            commit="commit-green-1",
        )
        self.assertEqual(calls, ["initial"])
        self.assertEqual(summary["classification"], PASS)
        self.assertIsNone(summary["fingerprint"])
        self.assertFalse(summary["investigationRequired"])
        self.assertIsNone(summary["investigation"])
        self.assertEqual(summary["lastGreen"]["commit"], "commit-green-1")
        self.assertEqual(triage_exit_code(summary["classification"], summary["hasCrash"]), 0)

    def test_infra_unavailable_never_misclassified_and_skips_replays(self):
        calls = []

        def execute(label, evidence_dir, archive_override):
            calls.append(label)
            rep = fake_report(
                INFRA,
                failed_step="preflight",
                reason="requires accessibility, postEvents",
            )
            (evidence_dir / "report.json").write_text(json.dumps(rep))
            return rep

        summary = run_triage(
            execute,
            self.root / "triage-infra",
            repro_runs=2,
            ledger=self.ledger,
            commit="commit-infra",
        )
        self.assertEqual(calls, ["initial"])
        self.assertEqual(summary["classification"], INFRA)
        self.assertFalse(summary["investigationRequired"])
        self.assertIsNone(summary["investigation"])
        self.assertEqual(triage_exit_code(summary["classification"], summary["hasCrash"]), 2)
        state = self.ledger.load()
        entry = state["incidents"][summary["fingerprint"]]
        self.assertEqual(entry["status"], "infra")
        self.assertEqual(entry["counts"]["infra_unavailable"], 1)
        self.assertEqual(entry["counts"]["regression"], 0)

    def test_regression_reproduces_across_fresh_replays_and_opens_investigation(self):
        seen_dirs = []
        seen_archives = []

        def execute(label, evidence_dir, archive_override):
            seen_dirs.append(evidence_dir)
            seen_archives.append(archive_override)
            if label == "initial":
                (evidence_dir / "Nirux.app.zip").write_bytes(b"zip-bytes")
            rep = fake_report(
                "fail",
                failed_step="monaco",
                reason="Monaco save did not reach README.md",
            )
            (evidence_dir / "report.json").write_text(json.dumps(rep))
            return rep

        summary = run_triage(
            execute,
            self.root / "triage-reg",
            repro_runs=2,
            ledger=self.ledger,
            commit="commit-reg",
        )
        self.assertEqual(len(seen_dirs), 3)
        self.assertEqual(len(set(seen_dirs)), 3)
        self.assertIsNone(seen_archives[0])
        self.assertEqual(seen_archives[1], seen_dirs[0] / "Nirux.app.zip")
        self.assertEqual(seen_archives[2], seen_dirs[0] / "Nirux.app.zip")

        self.assertEqual(summary["classification"], REGRESSION)
        self.assertEqual(summary["replayCounts"], {
            "total": 2, "matched": 2, "passed": 0, "failed": 2, "infraUnavailable": 0,
        })
        self.assertTrue(summary["investigationRequired"])
        self.assertEqual(summary["investigationReason"], "regression")
        self.assertTrue(Path(summary["investigation"]).is_file())
        self.assertEqual(triage_exit_code(summary["classification"], summary["hasCrash"]), 1)

    def test_intermittent_non_crash_flake_passes_on_fresh_replay(self):
        outcomes = [
            fake_report("fail", failed_step="monaco", reason="Monaco text area did not take focus"),
            fake_report("pass"),
            fake_report("pass"),
        ]

        def execute(label, evidence_dir, archive_override):
            rep = outcomes.pop(0)
            (evidence_dir / "report.json").write_text(json.dumps(rep))
            return rep

        summary = run_triage(
            execute,
            self.root / "triage-flake",
            repro_runs=2,
            ledger=self.ledger,
            commit="commit-flake",
        )
        self.assertEqual(summary["classification"], INTERMITTENT)
        self.assertFalse(summary["hasCrash"])
        self.assertFalse(summary["investigationRequired"])
        self.assertIsNone(summary["investigation"])
        self.assertEqual(triage_exit_code(summary["classification"], summary["hasCrash"]), 3)

    def test_mismatched_replay_failure_surface_is_intermittent(self):
        initial = fake_report("fail", failed_step="monaco", reason="Monaco save did not reach README.md")
        replays = [
            fake_report("fail", failed_step="ghostty", reason="missing terminal effect first"),
            fake_report("fail", failed_step="restore", reason="missing terminal effect restored"),
        ]
        result = classify_attempts(initial, replays)
        self.assertEqual(result["classification"], INTERMITTENT)
        self.assertEqual(result["replayCounts"]["matched"], 0)
        self.assertEqual(result["replayCounts"]["failed"], 2)

    def test_single_occurrence_crash_1_of_3_always_opens_investigation(self):
        ips_src = self.root / "Nirux-2026-11-22-100005.ips"
        ips_src.write_text(make_ips_text(pid=5555, exception_type="EXC_BAD_ACCESS", signal_name="SIGSEGV"))

        crash_info = {
            "incidentId": "INC-CRASH-1",
            "fileName": ips_src.name,
            "copiedPath": str(ips_src),
            "pid": 5555,
            "matchedProcessPid": 5555,
            "matchedExitCode": -11,
            "exceptionType": "EXC_BAD_ACCESS",
            "signal": "SIGSEGV",
            "termination": "Segmentation fault: 11",
            "normalizedFrames": [
                "Nirux:NiruxShellView.inspectForPanel",
                "libdispatch.dylib:_dispatch_assert_queue_fail",
            ],
        }
        outcomes = [
            fake_report(
                "fail",
                failed_step="ghostty",
                reason="Nirux exited with status -11",
                processes=[{"pid": 5555, "exitCode": -11, "killedByCleanup": False}],
                crashes=[crash_info],
                crashed=True,
            ),
            fake_report("pass"),
            fake_report("pass"),
        ]

        def execute(label, evidence_dir, archive_override):
            rep = outcomes.pop(0)
            (evidence_dir / "report.json").write_text(json.dumps(rep))
            return rep

        summary = run_triage(
            execute,
            self.root / "triage-1of3-crash",
            repro_runs=2,
            ledger=self.ledger,
            commit="commit-crash",
        )
        self.assertEqual(summary["classification"], INTERMITTENT)
        self.assertTrue(summary["hasCrash"])
        self.assertEqual(summary["crashCount"], 1)
        self.assertTrue(summary["investigationRequired"])
        self.assertEqual(summary["investigationReason"], "single_crash_observed")
        # Never silently drop a 1-of-3 crash: exit code must be 1 and investigation bundle must exist
        self.assertEqual(triage_exit_code(summary["classification"], summary["hasCrash"]), 1)

        inv_path = Path(summary["investigation"])
        self.assertTrue(inv_path.is_file())
        inv_data = json.loads(inv_path.read_text())
        self.assertTrue(inv_data["opened"])
        self.assertEqual(inv_data["crashCount"], 1)
        self.assertEqual(inv_data["totalAttempts"], 3)
        self.assertEqual(len(inv_data["crashes"]), 1)
        copied_ips = inv_path.parent / inv_data["crashes"][0]["investigationPath"]
        self.assertTrue(copied_ips.is_file())

    def test_crash_only_on_replay_still_opens_investigation_and_records_crash_fingerprint(self):
        outcomes = [
            fake_report("fail", failed_step="monaco", reason="Monaco save did not reach README.md"),
            fake_report(
                "fail",
                failed_step="launch",
                reason="Nirux exited with status -6",
                processes=[{"pid": 7777, "exitCode": -6, "killedByCleanup": False}],
                crashed=True,
            ),
            fake_report("pass"),
        ]

        def execute(label, evidence_dir, archive_override):
            rep = outcomes.pop(0)
            (evidence_dir / "report.json").write_text(json.dumps(rep))
            return rep

        summary = run_triage(
            execute,
            self.root / "triage-replay-crash",
            repro_runs=2,
            ledger=self.ledger,
            commit="commit-replay-crash",
        )
        self.assertEqual(summary["classification"], INTERMITTENT)
        self.assertTrue(summary["hasCrash"])
        self.assertEqual(summary["crashCount"], 1)
        self.assertTrue(summary["investigationRequired"])
        self.assertEqual(triage_exit_code(summary["classification"], summary["hasCrash"]), 1)
        state = self.ledger.load()
        self.assertIn(summary["fingerprint"], state["incidents"])
        for crash_fp in summary["crashFingerprints"]:
            self.assertIn(crash_fp, state["incidents"])

    def test_cleanup_kill_is_not_misclassified_as_crash(self):
        report = Report(manifest(str(uuid.uuid4()), None))
        app = App(self.root, self.root, report, lambda: None)
        app.process = subprocess.Popen(["/bin/sleep", "30"], start_new_session=True)
        report.data["processes"].append({
            "pid": app.process.pid,
            "startedAt": time.time(),
            "endedAt": None,
            "exitCode": None,
            "killedByCleanup": False,
        })
        app.cleanup()
        self.assertTrue(report.data["processes"][-1]["killedByCleanup"])
        self.assertFalse(attempt_has_crash(report.data))

    def test_missing_bundle_prerequisite_classifies_as_infra_unavailable(self):
        work = self.root / "work-missing"
        evidence = self.root / "ev-missing"
        work.mkdir()
        evidence.mkdir()
        verdict = iteration(
            work,
            evidence,
            self.root / "DoesNotExist.app",
            False,
            manifest(str(uuid.uuid4()), None),
            lambda: None,
            crash_wait_seconds=0.0,
        )
        self.assertEqual(verdict, INFRA)
        report_data = json.loads((evidence / "report.json").read_text())
        self.assertEqual(report_data["verdict"], INFRA)
        self.assertEqual(report_data["failedStep"], "bundle")


class FingerprintTests(unittest.TestCase):
    def test_error_normalization_strips_pids_temp_paths_timestamps_uuids_and_addresses(self):
        err_a = (
            "Command '['/private/tmp/nirux-canary-a1b2c3/driver', 'open-editor', '12345']' "
            "failed at 2026-11-22 10:15:01.123 +0100 pid=12345 addr 0x0000000180bac4fc "
            "seed 11111111-2222-3333-4444-555555555555 in /var/folders/ab/cd1234/T/work-9"
        )
        err_b = (
            "Command '['/private/tmp/nirux-canary-z9y8x7/driver', 'open-editor', '98765']' "
            "failed at 2026-11-23T22:59:59Z pid=98765 addr 0x00000001deadbeef "
            "seed aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee in /private/var/folders/xy/zz9999/T/work-1"
        )
        norm_a = normalize_error_text(err_a)
        norm_b = normalize_error_text(err_b)
        self.assertEqual(norm_a, norm_b)
        self.assertNotIn("12345", norm_a)
        self.assertNotIn("98765", norm_a)
        self.assertNotIn("0x0000000180bac4fc", norm_a)
        self.assertNotIn("nirux-canary-a1b2c3", norm_a)
        self.assertNotIn("2026-11-22", norm_a)

    def test_fingerprint_stable_across_varying_pids_paths_and_timestamps(self):
        rep_a = fake_report(
            "fail",
            failed_step="monaco",
            reason="Command '['/private/tmp/nirux-canary-111/driver', 'open-editor', '1001']' returned 1 at 2026-11-22T10:00:00Z",
        )
        rep_b = fake_report(
            "fail",
            failed_step="monaco",
            reason="Command '['/private/tmp/nirux-canary-222/driver', 'open-editor', '9999']' returned 1 at 2026-11-25T23:45:12Z",
        )
        fp_a = compute_fingerprint(rep_a)
        fp_b = compute_fingerprint(rep_b)
        self.assertEqual(fp_a["fingerprint"], fp_b["fingerprint"])
        self.assertEqual(fp_a["components"], fp_b["components"])

    def test_fingerprint_distinguishes_different_surfaces_and_errors(self):
        fp_monaco = compute_fingerprint(
            fake_report("fail", failed_step="monaco", reason="Monaco save did not reach README.md")
        )
        fp_ghostty = compute_fingerprint(
            fake_report("fail", failed_step="ghostty", reason="missing terminal effect first")
        )
        fp_monaco_focus = compute_fingerprint(
            fake_report("fail", failed_step="monaco", reason="Monaco text area did not take focus")
        )
        self.assertNotEqual(fp_monaco["fingerprint"], fp_ghostty["fingerprint"])
        self.assertNotEqual(fp_monaco["fingerprint"], fp_monaco_focus["fingerprint"])

    def test_crash_fingerprint_stable_across_offsets_pids_and_addresses(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ips1 = root / "Nirux-2026-11-22-100001.ips"
            ips2 = root / "Nirux-2026-11-23-183045.ips"
            ips1.write_text(make_ips_text(
                pid=1111,
                header_ts="2026-11-22 10:00:01.00 +0000",
                capture_time="2026-11-22 10:00:01.1000 +0000",
                app_symbol_loc=128,
                app_image_offset=1000000,
            ))
            ips2.write_text(make_ips_text(
                pid=8888,
                header_ts="2026-11-23 18:30:45.00 +0000",
                capture_time="2026-11-23 18:30:45.5000 +0000",
                app_symbol_loc=512,
                app_image_offset=9999999,
            ))
            frames1 = extract_normalized_frames(parse_ips_file(ips1))
            frames2 = extract_normalized_frames(parse_ips_file(ips2))
            self.assertEqual(frames1, frames2)
            # App frame below runtime trap frames must be retained in normalized frames
            self.assertIn("Nirux:NiruxShellView.inspectForPanel", frames1)

            rep1 = fake_report(
                "fail",
                failed_step="ghostty",
                crashes=[{"exceptionType": "EXC_BREAKPOINT", "signal": "SIGTRAP", "normalizedFrames": frames1}],
                crashed=True,
            )
            rep2 = fake_report(
                "fail",
                failed_step="ghostty",
                crashes=[{"exceptionType": "EXC_BREAKPOINT", "signal": "SIGTRAP", "normalizedFrames": frames2}],
                crashed=True,
            )
            self.assertEqual(
                compute_fingerprint(rep1)["fingerprint"],
                compute_fingerprint(rep2)["fingerprint"],
            )

            # Different app frame yields a distinct fingerprint
            ips3 = root / "Nirux-2026-11-23-190000.ips"
            ips3.write_text(make_ips_text(
                pid=9999,
                app_symbol="EditorColumn.saveDocument(_:)",
            ))
            frames3 = extract_normalized_frames(parse_ips_file(ips3))
            rep3 = fake_report(
                "fail",
                failed_step="ghostty",
                crashes=[{"exceptionType": "EXC_BREAKPOINT", "signal": "SIGTRAP", "normalizedFrames": frames3}],
                crashed=True,
            )
            self.assertNotEqual(
                compute_fingerprint(rep1)["fingerprint"],
                compute_fingerprint(rep3)["fingerprint"],
            )


class IncidentHistoryTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.ledger = IncidentLedger(self.root / "history")

    def test_default_history_dir_is_outside_repo_checkout(self):
        repo_root = Path(__file__).resolve().parents[2]
        hist_dir = default_history_dir()
        self.assertNotIn(repo_root, hist_dir.parents)
        self.assertNotEqual(repo_root, hist_dir)

    def test_deduplication_counts_and_last_green_comparison(self):
        self.ledger.record_pass(
            SCENARIO,
            run_id="run-green-1",
            commit="sha-green-001",
            bundle_sha256="bundle-green",
            timestamp="2026-11-22T09:00:00Z",
        )
        components = {
            "scenario": SCENARIO,
            "surface": "monaco",
            "errorKind": "Monaco save did not reach README.md",
            "frames": [],
        }
        r1 = self.ledger.record_incident(
            "fp-deadbeef12345678",
            components,
            INTERMITTENT,
            run_id="run-fail-1",
            commit="sha-bad-002",
            timestamp="2026-11-22T10:00:00Z",
        )
        r2 = self.ledger.record_incident(
            "fp-deadbeef12345678",
            components,
            REGRESSION,
            run_id="run-fail-2",
            commit="sha-bad-003",
            crashed=True,
            timestamp="2026-11-22T11:00:00Z",
        )
        self.assertFalse(r1["reopened"])
        self.assertFalse(r2["reopened"])
        entry = r2["incident"]
        self.assertEqual(entry["firstSeen"], "2026-11-22T10:00:00Z")
        self.assertEqual(entry["lastSeen"], "2026-11-22T11:00:00Z")
        self.assertEqual(entry["occurrences"], 2)
        self.assertEqual(entry["counts"], {
            "regression": 1,
            "intermittent": 1,
            "infra_unavailable": 0,
        })
        self.assertEqual(entry["crashCount"], 1)
        self.assertEqual(entry["lastKnownGreen"]["commit"], "sha-green-001")
        self.assertEqual(entry["lastKnownGreen"]["runId"], "run-green-1")

    def test_reopen_after_confirmed_green_run(self):
        components = {
            "scenario": SCENARIO,
            "surface": "ghostty",
            "errorKind": "missing terminal effect first",
            "frames": [],
        }
        # 1. Incident opens
        first = self.ledger.record_incident(
            "fp-0011223344556677",
            components,
            REGRESSION,
            run_id="run-1",
            commit="sha-1",
            timestamp="2026-11-22T10:00:00Z",
        )
        self.assertEqual(first["incident"]["status"], "open")
        self.assertFalse(first["reopened"])

        # 2. Confirmed green run resolves it and updates lastGreen
        green = self.ledger.record_pass(
            SCENARIO,
            run_id="run-2-green",
            commit="sha-2-green",
            timestamp="2026-11-22T11:00:00Z",
        )
        self.assertEqual(green["resolvedFingerprints"], ["fp-0011223344556677"])
        resolved_entry = self.ledger.load()["incidents"]["fp-0011223344556677"]
        self.assertEqual(resolved_entry["status"], "resolved")
        self.assertEqual(resolved_entry["resolvedByRunId"], "run-2-green")

        # 3. Infra unavailability must NOT reopen a resolved incident
        self.ledger.record_incident(
            "fp-0011223344556677",
            components,
            INFRA,
            run_id="run-3-infra",
            commit="sha-3",
            timestamp="2026-11-22T11:30:00Z",
        )
        still_resolved = self.ledger.load()["incidents"]["fp-0011223344556677"]
        self.assertEqual(still_resolved["status"], "resolved")
        self.assertEqual(still_resolved["counts"]["infra_unavailable"], 1)

        # 4. Same fingerprint reappearing after green reopens the incident
        reopened = self.ledger.record_incident(
            "fp-0011223344556677",
            components,
            REGRESSION,
            run_id="run-4-reappear",
            commit="sha-4-bad",
            timestamp="2026-11-22T12:00:00Z",
        )
        self.assertTrue(reopened["reopened"])
        self.assertEqual(reopened["incident"]["status"], "reopened")
        self.assertEqual(reopened["incident"]["reopenCount"], 1)
        self.assertEqual(reopened["incident"]["reopenedAt"], "2026-11-22T12:00:00Z")
        self.assertEqual(reopened["incident"]["lastKnownGreen"]["commit"], "sha-2-green")

    def test_append_safe_events_log_rebuilds_materialized_ledger(self):
        components = {"scenario": SCENARIO, "surface": "restore", "errorKind": "timeout", "frames": []}
        self.ledger.record_incident("fp-rebuild12345678", components, REGRESSION, run_id="r1", commit="c1")
        self.ledger.record_pass(SCENARIO, run_id="r2", commit="c2")
        self.ledger.record_incident("fp-rebuild12345678", components, INTERMITTENT, run_id="r3", commit="c3")

        expected = self.ledger.load()
        self.ledger.ledger_path.unlink()
        rebuilt = self.ledger.load()
        self.assertEqual(rebuilt, expected)


class CrashCorrelationTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.diag_dir = self.root / "DiagnosticReports"
        self.diag_dir.mkdir()
        self.evidence_dir = self.root / "evidence"
        self.evidence_dir.mkdir()

    def test_correlates_matching_ips_and_ignores_unrelated_process_pid_and_window(self):
        start_epoch = parse_ips_timestamp("2026-11-22 10:00:00.00 +0000")
        end_epoch = parse_ips_timestamp("2026-11-22 10:00:04.00 +0000")

        # 1. Exact matching crash report
        matching = self.diag_dir / "Nirux-2026-11-22-100005.ips"
        matching.write_text(make_ips_text(
            process_name="Nirux",
            bundle_id="com.xikimay.nirux",
            incident_id="INC-MATCH",
            pid=42424,
            header_ts="2026-11-22 10:00:05.00 +0000",
            capture_time="2026-11-22 10:00:04.1000 +0000",
            proc_launch="2026-11-22 10:00:00.0000 +0000",
        ))
        # 2. Unrelated process
        (self.diag_dir / "Safari-2026-11-22-100005.ips").write_text(make_ips_text(
            process_name="Safari",
            bundle_id="com.apple.Safari",
            incident_id="INC-SAFARI",
            pid=42424,
        ))
        # 3. Wrong bundle ID
        (self.diag_dir / "Nirux-2026-11-22-100005.001.ips").write_text(make_ips_text(
            process_name="Nirux",
            bundle_id="com.example.other",
            incident_id="INC-OTHER-BUNDLE",
            pid=42424,
        ))
        # 4. Different PID (concurrent unrelated Nirux instance)
        (self.diag_dir / "Nirux-2026-11-22-100005.002.ips").write_text(make_ips_text(
            process_name="Nirux",
            bundle_id="com.xikimay.nirux",
            incident_id="INC-WRONG-PID",
            pid=99999,
        ))
        # 5. Outside time window (stale crash from 1 hour earlier)
        (self.diag_dir / "Nirux-2026-11-22-090000.ips").write_text(make_ips_text(
            process_name="Nirux",
            bundle_id="com.xikimay.nirux",
            incident_id="INC-STALE",
            pid=42424,
            header_ts="2026-11-22 09:00:01.00 +0000",
            capture_time="2026-11-22 09:00:00.5000 +0000",
            proc_launch="2026-11-22 08:59:50.0000 +0000",
        ))
        # 6. Non-crash bug_type (hang/resource report)
        (self.diag_dir / "Nirux-2026-11-22-100005.003.ips").write_text(make_ips_text(
            process_name="Nirux",
            bundle_id="com.xikimay.nirux",
            bug_type="202",
            incident_id="INC-HANG",
            pid=42424,
        ))

        processes = [{
            "pid": 42424,
            "startedAt": start_epoch,
            "endedAt": end_epoch,
            "exitCode": -5,
            "killedByCleanup": False,
        }]
        matched = correlate_crash_reports(processes, self.diag_dir, self.evidence_dir)
        self.assertEqual(len(matched), 1)
        crash = matched[0]
        self.assertEqual(crash["incidentId"], "INC-MATCH")
        self.assertEqual(crash["pid"], 42424)
        self.assertEqual(crash["exceptionType"], "EXC_BREAKPOINT")
        self.assertEqual(crash["signal"], "SIGTRAP")
        self.assertTrue(Path(crash["copiedPath"]).is_file())
        self.assertEqual(crash["relativePath"], "crashes/Nirux-2026-11-22-100005.ips")
        self.assertIn("Nirux:NiruxShellView.inspectForPanel", crash["normalizedFrames"])

    def test_deduplicates_duplicate_incident_and_prefers_full_body(self):
        start_epoch = parse_ips_timestamp("2026-11-22 10:00:00.00 +0000")
        end_epoch = parse_ips_timestamp("2026-11-22 10:00:04.00 +0000")

        # Truncated header-only copy + full-body copy for the same incident_id
        (self.diag_dir / "Nirux-2026-11-22-100005.ips").write_text(
            make_ips_text(incident_id="INC-DUP", pid=None, include_body=False)
        )
        (self.diag_dir / "Nirux-2026-11-22-100005.000.ips").write_text(
            make_ips_text(incident_id="INC-DUP", pid=31337, include_body=True)
        )
        matched = correlate_crash_reports(
            [{"pid": 31337, "startedAt": start_epoch, "endedAt": end_epoch, "exitCode": -6, "killedByCleanup": False}],
            self.diag_dir,
            self.evidence_dir,
        )
        self.assertEqual(len(matched), 1)
        self.assertTrue(matched[0]["hasBody"])
        self.assertEqual(matched[0]["fileName"], "Nirux-2026-11-22-100005.000.ips")

    def test_normalize_symbol_and_unsymbolicated_frames(self):
        self.assertEqual(
            normalize_symbol("partial apply for closure #1 in NiruxShellView.inspectForPanel(_:panel:)"),
            "NiruxShellView.inspectForPanel",
        )
        self.assertEqual(
            normalize_symbol("-[NSApplication reportException:]"),
            "-[NSApplication reportException:]",
        )
        ips = self.diag_dir / "Nirux-2026-11-22-100005.ips"
        ips.write_text(make_ips_text(
            last_exception_frames=[
                {"imageIndex": 0, "symbol": "-[NiruxController crashNow:]", "imageOffset": 4096},
                {"imageIndex": 3, "imageOffset": 123456},
            ]
        ))
        frames = extract_normalized_frames(parse_ips_file(ips))
        self.assertEqual(frames[0], "Nirux:-[NiruxController crashNow:]")
        self.assertEqual(frames[1], "libsystem_pthread.dylib:<unsym>")

    def test_iteration_correlates_delayed_ips_for_crashing_process(self):
        work = self.root / "work-crash"
        evidence = self.root / "ev-crash"
        work.mkdir()
        evidence.mkdir()
        seed = str(uuid.uuid4())
        now_str = time.strftime("%Y-%m-%d %H:%M:%S.00 +0000", time.gmtime())

        def fake_package(w, ev, src, rep, meta):
            meta["bundleSHA256"] = "fake-sha"

        def fake_launch(app_self):
            proc = subprocess.Popen(["/bin/sh", "-c", "exit 139"], start_new_session=True)
            proc.wait(timeout=5)
            started = time.time() - 1.0
            ended = time.time()
            app_self.process = proc
            app_self.report.data["processes"].append({
                "pid": proc.pid,
                "startedAt": started,
                "endedAt": ended,
                "exitCode": -11,
                "killedByCleanup": False,
            })

            def write_delayed_ips():
                time.sleep(0.05)
                ips_path = self.diag_dir / f"Nirux-2026-11-22-delayed-{proc.pid}.ips"
                ips_path.write_text(make_ips_text(
                    incident_id="INC-LIVE-CRASH",
                    pid=proc.pid,
                    header_ts=now_str,
                    capture_time=now_str,
                    proc_launch=now_str,
                    exception_type="EXC_BAD_ACCESS",
                    signal_name="SIGSEGV",
                    app_symbol="GhosttyTerminalView.renderFrame(_:)",
                ))

            threading.Thread(target=write_delayed_ips, daemon=True).start()
            raise RuntimeError("Nirux exited with status -11")

        preflight_out = json.dumps({
            "display": True, "onConsole": True, "unlocked": True,
            "accessibility": True, "postEvents": True,
        }).encode("utf-8")

        with patch("run.package", side_effect=fake_package), \
             patch("run.fixture"), \
             patch("run.subprocess.run"), \
             patch("run.subprocess.check_output", return_value=preflight_out), \
             patch.object(App, "launch", fake_launch), \
             patch.object(App, "holders", return_value=[]):
            verdict = iteration(
                work,
                evidence,
                self.root / "Nirux.app",
                False,
                manifest(seed, None),
                lambda: None,
                crash_reports_dir=self.diag_dir,
                crash_wait_seconds=1.5,
            )

        self.assertEqual(verdict, "fail")
        report_data = json.loads((evidence / "report.json").read_text())
        self.assertTrue(report_data["crashed"])
        self.assertEqual(report_data["failedStep"], "launch")
        self.assertEqual(len(report_data["crashes"]), 1)
        crash = report_data["crashes"][0]
        self.assertEqual(crash["incidentId"], "INC-LIVE-CRASH")
        self.assertTrue((evidence / crash["relativePath"]).is_file())
        self.assertIn("Nirux:GhosttyTerminalView.renderFrame", crash["normalizedFrames"])
        self.assertEqual(
            report_data["fingerprintComponents"]["errorKind"],
            "crash:EXC_BAD_ACCESS:SIGSEGV",
        )
        self.assertIn(
            "Nirux:GhosttyTerminalView.renderFrame",
            report_data["fingerprintComponents"]["frames"],
        )


class QualificationTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()

    def test_qualification_passes_all_consecutive_runs_and_reports_timing_variance(self):
        durations = [1000, 1200, 1100, 1300, 1400]

        def execute_run(index, run_dir):
            d = durations[index - 1]
            rep = fake_report(
                "pass",
                duration_ms=d,
                steps=[
                    {"id": "launch", "verdict": "pass", "durationMs": d // 2},
                    {"id": "monaco", "verdict": "pass", "durationMs": d // 4},
                ],
            )
            (run_dir / "report.json").write_text(json.dumps(rep))
            return rep

        summary = run_qualification(execute_run, self.root / "qual-pass", qualify_runs=5)
        self.assertTrue(summary["qualified"])
        self.assertEqual(summary["verdict"], "qualified")
        self.assertEqual(summary["passRate"], 1.0)
        self.assertEqual(summary["consecutiveCleanPasses"], 5)
        self.assertEqual(summary["timing"]["meanMs"], 1200.0)
        self.assertEqual(summary["timing"]["minMs"], 1000.0)
        self.assertEqual(summary["timing"]["maxMs"], 1400.0)
        self.assertEqual(summary["timing"]["varianceMs"], 20000.0)
        self.assertGreater(summary["timing"]["stddevMs"], 0.0)
        self.assertIn("launch", summary["stepTiming"])
        self.assertIn("monaco", summary["stepTiming"])
        self.assertTrue((self.root / "qual-pass/qualification.json").is_file())
        self.assertEqual(qualification_exit_code(summary), 0)

    def test_qualification_fails_on_single_flake(self):
        verdicts = ["pass", "pass", "fail", "pass"]

        def execute_run(index, run_dir):
            v = verdicts[index - 1]
            rep = fake_report(v, failed_step="monaco" if v == "fail" else None, duration_ms=500 + index * 10)
            (run_dir / "report.json").write_text(json.dumps(rep))
            return rep

        summary = run_qualification(execute_run, self.root / "qual-fail", qualify_runs=4)
        self.assertFalse(summary["qualified"])
        self.assertEqual(summary["verdict"], "unqualified")
        self.assertEqual(summary["passRate"], 0.75)
        self.assertEqual(summary["consecutiveCleanPasses"], 2)
        self.assertEqual(summary["failedRuns"], 1)
        self.assertEqual(qualification_exit_code(summary), 1)

    def test_qualification_infra_verdict_returns_exit_2(self):
        summary = evaluate_qualification(
            [{"index": 1, "verdict": INFRA, "durationMs": 120, "stepDurationsMs": {"preflight": 100}}],
            requested_runs=3,
            scenario=SCENARIO,
        )
        self.assertFalse(summary["qualified"])
        self.assertEqual(summary["verdict"], INFRA)
        self.assertEqual(qualification_exit_code(summary), 2)

    def test_timing_stats_handles_empty_and_single_value(self):
        self.assertEqual(compute_timing_stats([])["count"], 0)
        one = compute_timing_stats([250])
        self.assertEqual(one["meanMs"], 250.0)
        self.assertEqual(one["varianceMs"], 0.0)
        self.assertEqual(one["stddevMs"], 0.0)


class CLIValidationTests(unittest.TestCase):
    def test_mutually_exclusive_and_invalid_flags(self):
        script = Path(__file__).resolve().parent / "run.py"
        with tempfile.TemporaryDirectory() as tmp:
            fake_app = Path(tmp) / "Nirux.app"
            fake_app.mkdir()
            for bad_args in (
                [str(fake_app), "--triage", "--qualify", "3"],
                [str(fake_app), "--repro-runs", "0"],
                [str(fake_app), "--qualify", "0"],
                [str(fake_app), "--triage", "--runs", "2"],
            ):
                proc = subprocess.run(
                    [sys.executable, "-B", str(script), *bad_args],
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(proc.returncode, 64, msg=f"expected usage error for {bad_args}: {proc.stderr}")


if __name__ == "__main__":
    unittest.main()
