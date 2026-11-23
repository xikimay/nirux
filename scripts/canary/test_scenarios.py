"""Unit tests for PR 3 canary scenarios, step invariants, AgentStandIn, sidebar breakpoints & diff selection."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from run import (  # noqa: E402
    checksum,
    combine_exit_codes,
    environment,
    manifest,
    read_replay,
    read_replay_manifest,
    Report,
    write_json,
)
from scenarios import (  # noqa: E402
    agent_stand_in_command,
    assert_metamorphic_equivalence,
    check_amber_has_reason,
    check_ax_controls_reachable,
    check_mission_no_double_delivery,
    check_pty_isolation,
    check_state_json_valid,
    classify_sidebar_state,
    expected_sidebar_folded_sequence,
    extract_metamorphic_signature,
    fixture_multi_agent,
    fixture_sidebar_breakpoints,
    get_scenario,
    list_scenarios,
    read_pty_capture,
    record_step_invariants,
    SCENARIOS,
    SIDEBAR_BREAKPOINTS,
)
from selection import (  # noqa: E402
    CORE_SCENARIO,
    extract_lcov_mappings,
    parse_coverage_index,
    select_scenarios,
)
from triage import compute_fingerprint, normalize_error_text  # noqa: E402


def _ax_snapshot(width, *, folded, waiting_count=0, extra_controls=None):
    controls = [
        {
            "role": "AXButton",
            "label": "Search, Command P",
            "title": "",
            "value": "",
            "enabled": True,
            "frame": {"x": 200.0, "y": 40.0, "width": 120.0, "height": 28.0},
            "inWindow": True,
        },
        {
            "role": "AXButton",
            "label": "Space: Sidebar Canary",
            "title": "",
            "value": "",
            "enabled": True,
            "frame": {"x": 80.0, "y": 40.0, "width": 110.0, "height": 28.0},
            "inWindow": True,
        },
        {
            "role": "AXButton",
            "label": f"{waiting_count} agent{'s' if waiting_count != 1 else ''} waiting for you, Command J",
            "title": "",
            "value": "",
            "enabled": True,
            "frame": {"x": 340.0, "y": 40.0, "width": 44.0, "height": 28.0},
            "inWindow": True,
        },
    ]
    if folded:
        controls.extend([
            {
                "role": "AXButton",
                "label": "New task",
                "title": "",
                "value": "",
                "enabled": True,
                "frame": {"x": 7.0, "y": 620.0, "width": 38.0, "height": 38.0},
                "inWindow": True,
            },
            {
                "role": "AXButton",
                "label": "Board",
                "title": "",
                "value": "",
                "enabled": True,
                "frame": {"x": 7.0, "y": 666.0, "width": 38.0, "height": 38.0},
                "inWindow": True,
            },
            {
                "role": "AXButton",
                "label": "Archived tasks",
                "title": "",
                "value": "",
                "enabled": True,
                "frame": {"x": 7.0, "y": 574.0, "width": 38.0, "height": 38.0},
                "inWindow": True,
            },
        ])
    else:
        controls.extend([
            {
                "role": "AXButton",
                "label": "History",
                "title": "",
                "value": "",
                "enabled": True,
                "frame": {"x": 12.0, "y": 670.0, "width": 236.0, "height": 28.0},
                "inWindow": True,
            },
            {
                "role": "AXButton",
                "label": "Archived, 1",
                "title": "",
                "value": "",
                "enabled": True,
                "frame": {"x": 12.0, "y": 636.0, "width": 236.0, "height": 28.0},
                "inWindow": True,
            },
            {
                "role": "AXButton",
                "label": "Board",
                "title": "",
                "value": "",
                "enabled": True,
                "frame": {"x": 12.0, "y": 90.0, "width": 236.0, "height": 28.0},
                "inWindow": True,
            },
        ])
    if extra_controls:
        controls.extend(extra_controls)
    return {
        "window": {"x": 0.0, "y": 0.0, "width": float(width), "height": 720.0},
        "controls": controls,
    }


class ScenarioRegistryTests(unittest.TestCase):
    def test_registry_has_well_formed_specs_and_manifests(self):
        specs = list_scenarios()
        self.assertEqual([s.id for s in specs], [
            "ghostty-monaco-restore",
            "multi-agent-routing",
            "sidebar-breakpoints",
        ])
        for spec in specs:
            self.assertEqual(get_scenario(spec.id), spec)
            self.assertEqual(spec.steps[0], "bundle")
            self.assertTrue(spec.invariants)
            self.assertTrue(spec.effect_steps.issubset(set(spec.steps)))
            as_dict = spec.to_dict()
            self.assertEqual(as_dict["id"], spec.id)

        with self.assertRaises(ValueError):
            get_scenario("nonexistent-scenario")

    def test_v1_and_v2_replay_manifests_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = root / "Nirux.app.zip"
            archive.write_bytes(b"zip-bytes")
            sha = checksum(archive)
            seed = str(uuid.uuid4())

            m1 = manifest(seed, "monaco", scenario="ghostty-monaco-restore")
            self.assertEqual(m1["version"], 1)
            write_json(root / "manifest.json", dict(m1, bundleSHA256=sha))
            self.assertEqual(read_replay(root), (seed, "monaco", archive))
            self.assertEqual(
                read_replay_manifest(root),
                ("ghostty-monaco-restore", seed, "monaco", archive),
            )

            m2 = manifest(seed, "routing-beta", scenario="multi-agent-routing")
            self.assertEqual(m2["version"], 2)
            self.assertIn("pty-isolation", m2["invariants"])
            write_json(root / "manifest.json", dict(m2, bundleSHA256=sha))
            self.assertEqual(
                read_replay_manifest(root),
                ("multi-agent-routing", seed, "routing-beta", archive),
            )


class MultiAgentAndInvariantTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.work = Path(tmp.name).resolve()
        for name in ("state", "tmp", "home"):
            (self.work / name).mkdir()
        self.seed = str(uuid.uuid4())

    def test_agent_stand_in_runs_the_fake_agent_and_reads_its_log(self):
        cmd = agent_stand_in_command("/tmp/agent-alpha.jsonl", "/tmp/agents/claude")
        self.assertEqual(cmd, "NIRUX_CANARY_AGENT_LOG='/tmp/agent-alpha.jsonl' exec '/tmp/agents/claude'")
        with self.assertRaises(ValueError):
            agent_stand_in_command("/tmp/bad'path.jsonl", "/tmp/agents/claude")
        log = self.work / "agent.jsonl"
        log.write_text("\n".join(json.dumps(e) for e in [
            {"event": "start", "argv": []}, {"event": "input", "text": "BETA-1"}, {"event": "hook", "hook": "Stop"},
            {"event": "input", "text": "\r"},
        ]) + "\n", encoding="utf-8")
        self.assertEqual(read_pty_capture(log), "BETA-1\r")

    def test_multi_agent_fixture_creates_two_spaces_worktrees_and_active_mission(self):
        ctx = fixture_multi_agent(self.work, environment(self.work), self.seed)
        self.assertTrue((ctx["treeAlpha"] / ".git").is_file())
        self.assertTrue((ctx["treeBeta"] / ".git").is_file())

        ok, detail = check_state_json_valid(
            self.work / "state",
            expected_workspace_ids=[ctx["wsAlphaID"], ctx["wsBetaID"]],
            expected_active_id=ctx["wsAlphaID"],
        )
        self.assertTrue(ok, detail)

        projects = json.loads((self.work / "state/projects.json").read_text())
        self.assertEqual(len(projects["projects"]), 2)
        self.assertEqual([p["name"] for p in projects["projects"]], ["Canary Alpha", "Canary Beta"])

        missions = json.loads((self.work / "state/missions.json").read_text())
        self.assertEqual(len(missions), 1)
        self.assertEqual(missions[0]["id"], ctx["missionID"])
        self.assertEqual(missions[0]["parentWorkspaceID"], ctx["wsAlphaID"])
        self.assertEqual(missions[0]["childWorkspaceID"], ctx["wsBetaID"])
        self.assertEqual(missions[0]["childAgentKind"], "claude")

        ok_m, detail_m = check_mission_no_double_delivery(self.work / "state", ctx["missionID"])
        self.assertTrue(ok_m, detail_m)

    def test_pty_isolation_invariant_detects_cross_pty_leak(self):
        pty_alpha = self.work / "state/pty-alpha.txt"
        pty_beta = self.work / "state/pty-beta.txt"
        pty_alpha.write_text(json.dumps({"event": "input", "text": "ALPHA-111\n"}) + "\n")
        pty_beta.write_text(json.dumps({"event": "input", "text": "BETA-222\n"}) + "\n")

        ok, _ = check_pty_isolation({
            "alpha": {"path": pty_alpha, "required": ["ALPHA-111"], "forbidden": ["BETA-222"]},
            "beta": {"path": pty_beta, "required": ["BETA-222"], "forbidden": ["ALPHA-111"]},
        })
        self.assertTrue(ok)

        # Simulate a focus/routing bug where ALPHA keystrokes leak into BETA's PTY.
        pty_beta.write_text(json.dumps({"event": "input", "text": "BETA-222\nALPHA-111\n"}) + "\n")
        ok_leak, detail = check_pty_isolation({
            "alpha": {"path": pty_alpha, "required": ["ALPHA-111"], "forbidden": ["BETA-222"]},
            "beta": {"path": pty_beta, "required": ["BETA-222"], "forbidden": ["ALPHA-111"]},
        })
        self.assertFalse(ok_leak)
        self.assertIn("cross-PTY leak", detail)

    def test_amber_has_reason_invariant_catches_unexplained_waiting_badge(self):
        # Zero waiting -> always passes.
        ok0, _ = check_amber_has_reason(_ax_snapshot(940, folded=False, waiting_count=0))
        self.assertTrue(ok0)

        # Waiting == 1 with NO rendered reason -> must FAIL.
        ok_missing, detail = check_amber_has_reason(_ax_snapshot(940, folded=False, waiting_count=1))
        self.assertFalse(ok_missing)
        self.assertIn("no rendered reason", detail)

        # Waiting == 1 WITH a rendered Allow button -> must PASS.
        ok_reason, _ = check_amber_has_reason(_ax_snapshot(
            940,
            folded=False,
            waiting_count=1,
            extra_controls=[{
                "role": "AXButton",
                "label": "Allow once echo canary-ok",
                "title": "Allow",
                "value": "",
                "enabled": True,
                "frame": {"x": 180.0, "y": 300.0, "width": 56.0, "height": 24.0},
                "inWindow": True,
            }],
        ))
        self.assertTrue(ok_reason)

    def test_mission_no_double_delivery_catches_duplicate_reply(self):
        missions_path = self.work / "state/missions.json"
        write_json(missions_path, [{
            "id": "m1",
            "events": [
                {"id": "q1", "kind": "question", "message": "Use v2?"},
                {"id": "r1", "kind": "response", "inReplyTo": "q1", "message": "Yes"},
                {"id": "r2", "kind": "response", "inReplyTo": "q1", "message": "Yes"},
            ],
        }])
        ok, detail = check_mission_no_double_delivery(self.work / "state", "m1")
        self.assertFalse(ok)
        self.assertIn("double response delivery", detail)

    def test_step_invariants_attach_to_report_and_fail_step(self):
        report = Report(manifest(self.seed, None, scenario="multi-agent-routing"))
        with self.assertRaisesRegex(RuntimeError, "invariant:pty-isolation"):
            with report.step("routing-beta"):
                record_step_invariants(report, "routing-beta", [
                    ("state-json-valid", True, "2 workspaces valid"),
                    ("pty-isolation", False, "cross-PTY leak: agent alpha received BETA-1234567890ab"),
                ])
        self.assertEqual(report.data["verdict"], "fail")
        self.assertEqual(report.data["failedStep"], "routing-beta")
        self.assertEqual(report.data["invariantsSummary"], {"checked": 2, "failed": 1})
        self.assertEqual(len(report.data["steps"][0]["invariants"]), 2)

        # Fingerprints must normalize ALPHA-/BETA- seed tokens across runs.
        fp1 = compute_fingerprint(report.data)["fingerprint"]
        report2 = Report(manifest(str(uuid.uuid4()), None, scenario="multi-agent-routing"))
        with self.assertRaises(RuntimeError):
            with report2.step("routing-beta"):
                record_step_invariants(report2, "routing-beta", [
                    ("pty-isolation", False, "cross-PTY leak: agent alpha received BETA-fedcba987654"),
                ])
        fp2 = compute_fingerprint(report2.data)["fingerprint"]
        self.assertEqual(fp1, fp2)
        self.assertIn("BETA-<seed>", normalize_error_text("received BETA-fedcba987654"))


class SidebarBreakpointsMetamorphicTests(unittest.TestCase):
    def test_exact_899_900_939_940_hysteresis_truth_table(self):
        seq = expected_sidebar_folded_sequence(SIDEBAR_BREAKPOINTS, chosen_expanded=True)
        self.assertEqual(seq, [
            (940, False),  # wide: expanded
            (900, False),  # 900 is NOT narrow: still expanded
            (899, True),   # crosses < 900: auto-folded
            (900, True),   # hysteresis: stays folded
            (939, True),   # hysteresis (939 < 940): stays folded
            (940, False),  # crosses >= 940: auto-unfolds
        ])
        folded_user = expected_sidebar_folded_sequence(SIDEBAR_BREAKPOINTS, chosen_expanded=False)
        self.assertTrue(all(is_folded for _, is_folded in folded_user))

    def test_ax_classification_and_metamorphic_equivalence(self):
        snaps_rm = [
            _ax_snapshot(w, folded=is_folded)
            for w, is_folded in expected_sidebar_folded_sequence(SIDEBAR_BREAKPOINTS)
        ]
        snaps_anim = [
            _ax_snapshot(w, folded=is_folded)
            for w, is_folded in expected_sidebar_folded_sequence(SIDEBAR_BREAKPOINTS)
        ]
        for (w, is_folded), snap in zip(expected_sidebar_folded_sequence(SIDEBAR_BREAKPOINTS), snaps_rm):
            self.assertEqual(classify_sidebar_state(snap), "folded" if is_folded else "expanded")
            ok, detail = check_ax_controls_reachable(
                snap,
                required_labels=("Search, Command P", "New task", "Board") if is_folded else ("Search, Command P", "History"),
                required_prefixes=("Space: ",),
            )
            self.assertTrue(ok, f"at {w}pt: {detail}")

        sigs_rm = [extract_metamorphic_signature(s) for s in snaps_rm]
        sigs_anim = [extract_metamorphic_signature(s) for s in snaps_anim]
        assert_metamorphic_equivalence(sigs_rm, sigs_anim)

        # Break Reduce Motion equivalence at 939pt (e.g. premature unfold when animated).
        broken = list(sigs_anim)
        broken[4] = dict(broken[4], sidebarState="expanded")
        with self.assertRaisesRegex(RuntimeError, "metamorphic sidebar state mismatch at 939pt"):
            assert_metamorphic_equivalence(sigs_rm, broken)

    def test_sidebar_fixture_writes_active_and_archived_workspaces(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            for name in ("state", "tmp", "home"):
                (work / name).mkdir()
            seed = str(uuid.uuid4())
            ctx = fixture_sidebar_breakpoints(work, environment(work), seed)
            ok, detail = check_state_json_valid(
                work / "state",
                expected_workspace_ids=[ctx["wsActiveID"], ctx["wsArchivedID"]],
                expected_active_id=ctx["wsActiveID"],
            )
            self.assertTrue(ok, detail)
            state = json.loads((work / "state/state.json").read_text())
            self.assertTrue(state["settings"]["sidebarExpanded"])
            self.assertFalse(state["settings"]["animatesInterface"])


class DiffTargetedSelectionTests(unittest.TestCase):
    def test_explicit_table_maps_surfaces_accurately(self):
        res_sidebar = select_scenarios(["Sources/Nirux/Views/NiruxShellView+SidebarFold.swift"])
        self.assertEqual(res_sidebar["scenarios"], ["sidebar-breakpoints"])
        self.assertEqual(res_sidebar["mode"], "table")

        res_mission = select_scenarios(["Sources/Nirux/Model/Mission.swift"])
        self.assertEqual(res_mission["scenarios"], ["multi-agent-routing"])

        res_editor = select_scenarios(["Sources/Nirux/EditorAssets/bridge.js"])
        self.assertEqual(res_editor["scenarios"], ["ghostty-monaco-restore"])

        res_shared = select_scenarios(["Sources/Nirux/Content/PtySession.swift"])
        self.assertEqual(res_shared["scenarios"], ["ghostty-monaco-restore", "multi-agent-routing"])

    def test_docs_only_selects_nothing_and_global_selects_all(self):
        docs = select_scenarios(["docs/design/spaces.md", "README.md", "scripts/canary/README.md"])
        self.assertEqual(docs["scenarios"], [])
        self.assertEqual(docs["mode"], "none")
        self.assertEqual(len(docs["ignoredPaths"]), 3)

        global_change = select_scenarios(["Sources/Nirux/Model/Persistence.swift"])
        self.assertEqual(global_change["mode"], "all")
        self.assertEqual(global_change["scenarios"], [
            "ghostty-monaco-restore",
            "multi-agent-routing",
            "sidebar-breakpoints",
        ])

    def test_coverage_index_takes_priority_with_hybrid_fallback_for_new_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            idx = Path(tmp) / "canary-coverage.txt"
            idx.write_text(
                "# scenario coverage map\n"
                "Sources/Nirux/Model/CustomPolicy.swift multi-agent-routing\n"
                "Sources/Nirux/Views/IconRail.swift sidebar-breakpoints\n",
                encoding="utf-8",
            )
            parsed = parse_coverage_index(idx)
            self.assertEqual(parsed["Sources/Nirux/Model/CustomPolicy.swift"], {"multi-agent-routing"})

            # Coverage-only hit:
            cov_only = select_scenarios(["Sources/Nirux/Model/CustomPolicy.swift"], coverage_index=idx)
            self.assertEqual(cov_only["mode"], "coverage")
            self.assertEqual(cov_only["scenarios"], ["multi-agent-routing"])

            # Hybrid: one indexed file + one brand-new unindexed Swift file -> coverage + core fallback!
            hybrid = select_scenarios(
                ["Sources/Nirux/Model/CustomPolicy.swift", "Sources/Nirux/Model/BrandNewFeature.swift"],
                coverage_index=idx,
            )
            self.assertEqual(hybrid["mode"], "hybrid")
            self.assertEqual(hybrid["scenarios"], [CORE_SCENARIO, "multi-agent-routing"])
            self.assertEqual(hybrid["unmappedSources"], ["Sources/Nirux/Model/BrandNewFeature.swift"])

    def test_lcov_extractor_produces_coverage_index_lines(self):
        sample_lcov = (
            "TN:\n"
            "SF:/Users/runner/work/nirux/Sources/Nirux/Views/NiruxShellView+SidebarFold.swift\n"
            "DA:10,0\n"
            "DA:43,5\n"
            "end_of_record\n"
            "SF:/Users/runner/work/nirux/Sources/Nirux/Model/Unused.swift\n"
            "DA:1,0\n"
            "end_of_record\n"
            "SF:/Users/runner/work/nirux/NiruxCore/Sources/NiruxCore/InterfaceTransparency.swift\n"
            "DA:12,3\n"
            "end_of_record\n"
        )
        lines = extract_lcov_mappings(sample_lcov, "sidebar-breakpoints")
        self.assertEqual(lines, [
            "NiruxCore/Sources/NiruxCore/InterfaceTransparency.swift sidebar-breakpoints",
            "Sources/Nirux/Views/NiruxShellView+SidebarFold.swift sidebar-breakpoints",
        ])

    def test_select_shell_wrapper_reads_nul_delimited_stdin(self):
        script = REPO_ROOT / "scripts/select-canary-scenarios.sh"
        res = subprocess.run(
            [str(script), "-z", "--json"],
            input="Sources/Nirux/Views/IconRail.swift\0Sources/Nirux/Model/Mission.swift\0",
            capture_output=True,
            text=True,
            check=True,
            timeout=10,
        )
        payload = json.loads(res.stdout)
        self.assertEqual(payload["scenarios"], ["multi-agent-routing", "sidebar-breakpoints"])

    def test_cli_list_scenarios_and_docs_only_changed_files(self):
        res = subprocess.run(
            [sys.executable, str(HERE / "run.py"), "--list-scenarios"],
            capture_output=True,
            text=True,
            check=True,
            timeout=10,
        )
        listed = json.loads(res.stdout)
        self.assertEqual([item["id"] for item in listed], list(SCENARIOS.keys()))

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake_app = root / "Nirux.app"
            fake_app.mkdir()
            changed = root / "changed.txt"
            changed.write_text("docs/README.md\n", encoding="utf-8")
            ev = root / "evidence"
            run_res = subprocess.run(
                [
                    sys.executable, str(HERE / "run.py"),
                    str(fake_app), "--changed-files", str(changed), "--evidence-dir", str(ev),
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
            self.assertEqual(run_res.returncode, 4)
            summary = json.loads(run_res.stdout.strip())
            self.assertEqual(summary["verdict"], "nothing_selected")
            self.assertEqual(summary["scenarios"], [])
            self.assertTrue((ev / "suite.json").is_file())

    def test_combine_exit_codes_prioritizes_failure_over_intermittent_over_infra(self):
        self.assertEqual(combine_exit_codes([]), 0)
        self.assertEqual(combine_exit_codes([0, 0]), 0)
        self.assertEqual(combine_exit_codes([0, 2]), 2)
        self.assertEqual(combine_exit_codes([2, 3]), 3)
        self.assertEqual(combine_exit_codes([0, 2, 3, 1]), 1)


class EndToEndScenarioFlowTests(unittest.TestCase):
    def test_sidebar_breakpoints_iteration_runs_all_steps_and_records_metamorphic_evidence(self):
        from run import App, iteration

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            work = root / "work"
            evidence = root / "evidence"
            work.mkdir()
            evidence.mkdir()
            seed = str(uuid.uuid4())
            state = {"width": 1200, "is_narrow": False}

            def fake_package(w, ev, src, replay, meta):
                meta["bundleSHA256"] = "a" * 64

            def fake_resize(app_self, width, height):
                state["width"] = width
                narrow = width < (900 + (40 if state["is_narrow"] else 0))
                if narrow != state["is_narrow"]:
                    state["is_narrow"] = narrow
                return {"x": 0.0, "y": 0.0, "width": float(width), "height": float(height)}

            def fake_ax(app_self):
                return _ax_snapshot(state["width"], folded=state["is_narrow"])

            def fake_launch(app_self):
                state["width"] = 1200
                state["is_narrow"] = False

            with patch("run.package", side_effect=fake_package), \
                    patch.object(App, "preflight", return_value=None), \
                    patch.object(App, "launch", autospec=True, side_effect=fake_launch), \
                    patch.object(App, "resize_window", autospec=True, side_effect=fake_resize), \
                    patch.object(App, "ax_controls", autospec=True, side_effect=fake_ax), \
                    patch.object(App, "check_window", return_value=None), \
                    patch.object(App, "quit", return_value=None), \
                    patch.object(App, "holders", return_value=[]):
                verdict = iteration(
                    work, evidence, root / "Nirux.app", False,
                    manifest(seed, None, scenario="sidebar-breakpoints"),
                    lambda: None,
                )
            self.assertEqual(verdict, "pass")
            report = json.loads((evidence / "report.json").read_text())
            self.assertEqual(report["scenario"], "sidebar-breakpoints")
            self.assertEqual([s["id"] for s in report["steps"]], list(SCENARIOS["sidebar-breakpoints"].steps))
            self.assertEqual(len(report["metamorphic"]["reduceMotion"]), 6)
            self.assertEqual(len(report["metamorphic"]["animated"]), 6)
            self.assertEqual(report["invariantsSummary"]["failed"], 0)
            self.assertGreater(report["invariantsSummary"]["checked"], 0)

    def test_multi_agent_routing_iteration_verifies_pty_isolation_and_missions(self):
        from run import App, iteration

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            work = root / "work"
            evidence = root / "evidence"
            work.mkdir()
            evidence.mkdir()
            seed = str(uuid.uuid4())
            active = {"space": "alpha", "pty_alpha": None, "pty_beta": None, "waiting": 0}

            def fake_package(w, ev, src, replay, meta):
                meta["bundleSHA256"] = "b" * 64

            def fake_launch(app_self):
                state = json.loads((work / "state/state.json").read_text())
                ws_alpha = state["workspaces"][0]["id"]
                (work / f"state/prompt-{ws_alpha}").write_text("123\n")
                (work / "state/prompt").write_text("123\n")

            def fake_drive(app_self, action, *args, probe=False):
                if action == "menu" and args == ("Space", "Next Space"):
                    active["space"] = "beta"
                    state = json.loads((work / "state/state.json").read_text())
                    ws_beta = state["workspaces"][1]["id"]
                    (work / f"state/prompt-{ws_beta}").write_text("124\n")
                    return True
                if action == "menu" and args == ("Space", "Previous Space"):
                    active["space"] = "alpha"
                    return True
                if action == "command":
                    cmd = args[0]
                    if "agent-alpha.jsonl" in cmd:
                        active["pty_alpha"] = work / "state/agent-alpha.jsonl"
                        active["pty_alpha"].write_text("")
                    elif "agent-beta.jsonl" in cmd:
                        active["pty_beta"] = work / "state/agent-beta.jsonl"
                        active["pty_beta"].write_text("")
                    else:
                        active["waiting"] = {"permission:canary": 1, "y": 0}.get(cmd, active["waiting"])
                        target = active["pty_beta"] if active["space"] == "beta" else active["pty_alpha"]
                        with target.open("a", encoding="utf-8") as stream:
                            stream.write(json.dumps({"event": "input", "text": cmd + "\r"}) + "\n")
                    return True
                return True

            def fake_ax(app_self):
                label = "Space: Canary Alpha" if active["space"] == "alpha" else "Space: Canary Beta"
                reason = {"role": "AXStaticText", "label": "Claude needs your permission to use Bash", "title": "",
                          "value": "", "enabled": True, "frame": {"x": 0, "y": 0, "width": 10, "height": 10}, "inWindow": True}
                snap = _ax_snapshot(1200, folded=False, waiting_count=active["waiting"],
                                    extra_controls=[reason] if active["waiting"] else None)
                snap["controls"][1]["label"] = label
                return snap

            real_run = subprocess.run

            def fake_subproc(cmd, *args, **kwargs):
                if isinstance(cmd, list) and len(cmd) >= 2 and cmd[1] == "--mission":
                    missions_path = work / "state/missions.json"
                    missions = json.loads(missions_path.read_text())
                    if cmd[2] == "ask":
                        msg = cmd[cmd.index("--message") + 1]
                        missions[0]["events"].append({
                            "id": "q-canary-1",
                            "kind": "question",
                            "message": msg,
                            "recommendation": "Keep deterministic path",
                        })
                        write_json(missions_path, missions)
                    elif cmd[2] == "reply":
                        qid = cmd[cmd.index("--event") + 1]
                        missions[0]["events"].append({
                            "id": "r-canary-1",
                            "kind": "response",
                            "inReplyTo": qid,
                            "acceptedRecommendation": True,
                            "message": "Keep deterministic path",
                        })
                        write_json(missions_path, missions)
                    return subprocess.CompletedProcess(cmd, 0, stdout="ok\n", stderr="")
                if isinstance(cmd, list) and len(cmd) >= 2 and cmd[1] == "--hook":
                    return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
                return real_run(cmd, *args, **kwargs)

            with patch("run.package", side_effect=fake_package), \
                    patch("scenarios.subprocess.run", side_effect=fake_subproc), \
                    patch.object(App, "preflight", return_value=None), \
                    patch.object(App, "fake_agent", return_value=Path("/tmp/agents/claude")), \
                    patch.object(App, "launch", autospec=True, side_effect=fake_launch), \
                    patch.object(App, "drive", autospec=True, side_effect=fake_drive), \
                    patch.object(App, "ax_controls", autospec=True, side_effect=fake_ax), \
                    patch.object(App, "check_window", return_value=None), \
                    patch.object(App, "quit", return_value=None), \
                    patch.object(App, "holders", return_value=[]):
                verdict = iteration(
                    work, evidence, root / "Nirux.app", False,
                    manifest(seed, None, scenario="multi-agent-routing"),
                    lambda: None,
                )
            self.assertEqual(verdict, "pass")
            report = json.loads((evidence / "report.json").read_text())
            self.assertEqual(report["scenario"], "multi-agent-routing")
            self.assertEqual([s["id"] for s in report["steps"]], list(SCENARIOS["multi-agent-routing"].steps))
            self.assertEqual(report["invariantsSummary"]["failed"], 0)
            self.assertGreaterEqual(report["invariantsSummary"]["checked"], 8)



class ReviewRoundOneTests(unittest.TestCase):
    """Each check fails on a bad state (Lead review of #777, round 1)."""

    def test_amber_needs_the_amber_and_a_whole_word_reason(self):
        archived = [{"role": "AXStaticText", "label": "Archived tasks", "title": "", "value": "", "enabled": True,
                     "frame": {"x": 0, "y": 0, "width": 10, "height": 10}, "inWindow": True}]
        ok, detail = check_amber_has_reason(_ax_snapshot(940, folded=False, waiting_count=1, extra_controls=archived))
        self.assertFalse(ok, detail)
        ok, detail = check_amber_has_reason(_ax_snapshot(940, folded=False, waiting_count=0), expect_waiting=True)
        self.assertFalse(ok)
        self.assertIn("no amber", detail)
        reason = [dict(archived[0], label="Claude needs your permission to use Bash")]
        self.assertTrue(check_amber_has_reason(_ax_snapshot(940, folded=False, waiting_count=1, extra_controls=reason),
                                               expect_waiting=True)[0])

    def test_a_truncated_snapshot_never_reads_as_reachable(self):
        snapshot = dict(_ax_snapshot(940, folded=False), truncated=True)
        ok, detail = check_ax_controls_reachable(snapshot, required_labels=["Search, Command P"])
        self.assertFalse(ok)
        self.assertIn("truncated", detail)

    def test_a_breakpoint_settled_in_the_wrong_state_fails(self):
        from scenarios import _resize_and_assert_breakpoint

        class FakeApp:
            def __init__(self, folded):
                self.folded = folded

            def resize_window(self, width, height):
                self.width = width

            def ax_controls(self):
                return _ax_snapshot(self.width, folded=self.folded)

            def check_window(self):
                pass

        def wait_for(description, condition, alive=None, timeout=10):
            for _ in range(10):
                if condition():
                    return
            raise TimeoutError(description)

        self.assertEqual(classify_sidebar_state(_resize_and_assert_breakpoint(FakeApp(True), 899, True, wait_for)), "folded")
        with self.assertRaisesRegex(RuntimeError, "settled expanded at 899pt, expected folded"):
            _resize_and_assert_breakpoint(FakeApp(False), 899, True, wait_for)

    def test_scenarios_driven_through_the_key_window_require_focus(self):
        from run import missing_prerequisites

        for spec in SCENARIOS.values():
            self.assertTrue(spec.requires_focus, spec.id)
        probes = {"accessibility": True, "unlocked": False, "postEvents": False}
        self.assertEqual(missing_prerequisites(probes, requires_focus=True), ["unlocked", "postEvents"])
        self.assertEqual(missing_prerequisites(probes, requires_focus=False), [])
        self.assertEqual(missing_prerequisites(dict(probes, accessibility=False), requires_focus=False), ["accessibility"])

    def test_runner_and_bundle_changes_select_every_scenario(self):
        everything = sorted(SCENARIOS)
        for path in ["scripts/canary/triage.py", "scripts/canary/qualify.py", "scripts/canary/history.py",
                     "scripts/canary/crash_correlator.py", "scripts/canary/selection.py", "scripts/canary/FakeAgent.swift",
                     ".github/workflows/canary.yml", "Resources/Info.plist", "NiruxCore/Package.swift"]:
            self.assertEqual(sorted(select_scenarios([path], available_scenarios=everything)["scenarios"]), everything, path)
        self.assertEqual(select_scenarios(["scripts/canary/README.md"], available_scenarios=everything)["scenarios"], [])

    def test_bad_arguments_exit_with_their_own_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake_app = Path(tmp) / "Nirux.app"
            fake_app.mkdir()
            res = subprocess.run([sys.executable, str(HERE / "run.py"), str(fake_app), "--diff-base", "no-such-ref"],
                                 capture_output=True, text=True, timeout=20)
            self.assertEqual(res.returncode, 64, res.stderr)
            res = subprocess.run([sys.executable, str(HERE / "run.py"), "--no-such-flag"], capture_output=True, text=True, timeout=20)
            self.assertEqual(res.returncode, 64, res.stderr)

    def test_only_an_infra_verdict_reads_as_inconclusive(self):
        from verdicts import any_infra

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.assertFalse(any_infra(root, "triage.json", "classification"), "no evidence at all")
            (root / "a").mkdir()
            (root / "b").mkdir()
            write_json(root / "a/triage.json", {"classification": "pass"})
            self.assertFalse(any_infra(root, "triage.json", "classification"))
            write_json(root / "b/triage.json", {"classification": "infra_unavailable"})
            self.assertTrue(any_infra(root, "triage.json", "classification"))


if __name__ == "__main__":
    unittest.main()
