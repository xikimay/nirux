"""Declarative canary scenario registry, step invariants, AgentStandIn multi-agent & sidebar breakpoint scenarios."""
from dataclasses import dataclass
import json
from pathlib import Path
import re
import subprocess
import time
import uuid

from selection import DEFAULT_SCENARIO_ORDER

DEFAULT_SCENARIO = "ghostty-monaco-restore"

SIDEBAR_NARROW_WIDTH = 900
SIDEBAR_HYSTERESIS = 40
SIDEBAR_REEXPAND_WIDTH = SIDEBAR_NARROW_WIDTH + SIDEBAR_HYSTERESIS
SIDEBAR_BREAKPOINTS = (940, 900, 899, 900, 939, 940)
SIDEBAR_WINDOW_HEIGHT = 720
SIDEBAR_EXPANDED_MIN_WIDTH = 150.0
SIDEBAR_RAIL_MAX_WIDTH = 56.0

_WAITING_BADGE_RE = re.compile(r"^(\d+)\s+agents?\s+waiting\s+for\s+you,\s+Command\s+J$")


@dataclass(frozen=True)
class ScenarioSpec:
    id: str
    title: str
    description: str
    tier: str  # "core" or "targeted"
    requires_focus: bool
    steps: tuple
    effect_steps: frozenset
    invariants: tuple

    @property
    def injectable_steps(self):
        return self.steps[1:]

    def to_dict(self):
        return {
            "id": self.id,
            "title": self.title,
            "description": self.description,
            "tier": self.tier,
            "requiresFocus": self.requires_focus,
            "steps": list(self.steps),
            "injectableSteps": list(self.injectable_steps),
            "invariants": list(self.invariants),
        }


SCENARIOS = {
    "ghostty-monaco-restore": ScenarioSpec(
        id="ghostty-monaco-restore",
        title="Ghostty / Monaco roundtrip & restore",
        description=(
            "Launches the signed bundle in a synthetic worktree, verifies Ghostty shell execution, "
            "opens Monaco editor, saves README.md, refocuses Ghostty, quits cleanly, relaunches on "
            "saved state, and verifies both columns remain usable."
        ),
        tier="core",
        requires_focus=True,
        steps=("bundle", "fixture", "preflight", "launch", "ghostty", "monaco",
               "focus-back", "quit", "restore", "final-quit"),
        effect_steps=frozenset({"ghostty", "monaco", "focus-back", "restore"}),
        invariants=("state-json-valid", "no-orphan-children"),
    ),
    "multi-agent-routing": ScenarioSpec(
        id="multi-agent-routing",
        title="Multi-agent AgentStandIn routing, permissions & Missions",
        description=(
            "Runs two Spaces, two linked git worktrees, and two AgentStandIn PTY stand-ins. "
            "Verifies byte-for-byte keystroke routing with zero cross-PTY leakage, Mission ask/reply "
            "delivery through the packaged CLI, Claude permission hook handling, amber reason invariants, "
            "and persistence across quit."
        ),
        tier="targeted",
        requires_focus=True,
        steps=("bundle", "fixture", "preflight", "launch", "standin-start",
               "routing-beta", "mission-and-permission", "switch-and-route-alpha", "quit-and-verify"),
        effect_steps=frozenset({"routing-beta", "mission-and-permission", "switch-and-route-alpha"}),
        invariants=(
            "state-json-valid",
            "pty-isolation",
            "amber-has-reason",
            "mission-no-double-delivery",
            "no-orphan-children",
        ),
    ),
    "sidebar-breakpoints": ScenarioSpec(
        id="sidebar-breakpoints",
        title="Sidebar fold breakpoints (899/900/939/940 pt) & Reduce Motion metamorphic checks",
        description=(
            "Resizes the canary window across the exact SidebarFold breakpoints (940->900->899->900->939->940 pt) "
            "and repeats with Reduce Motion (animatesInterface) toggled. Checks structural AX invariants and "
            "metamorphic equivalence of visible, reachable controls after settling—without golden images."
        ),
        tier="targeted",
        requires_focus=False,
        steps=("bundle", "fixture", "preflight", "launch", "narrow-sweep",
               "widen-hysteresis", "reduce-motion-metamorphic", "final-quit"),
        effect_steps=frozenset({"narrow-sweep", "widen-hysteresis", "reduce-motion-metamorphic"}),
        invariants=("state-json-valid", "ax-controls-reachable", "no-orphan-children"),
    ),
}


def list_scenarios():
    return [SCENARIOS[sid] for sid in DEFAULT_SCENARIO_ORDER if sid in SCENARIOS]


def get_scenario(scenario_id):
    if scenario_id not in SCENARIOS:
        known = ", ".join(sorted(SCENARIOS))
        raise ValueError(f"unknown canary scenario {scenario_id!r} (expected one of: {known})")
    return SCENARIOS[scenario_id]


def write_json(path, data):
    Path(path).write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# AgentStandIn oracle helpers
# ---------------------------------------------------------------------------

def agent_stand_in_command(output_path, name="claude"):
    """Shell command matching Tests/NiruxTests/AgentStandIn.swift (raw PTY byte capture)."""
    if "'" in str(output_path) or "'" in str(name):
        raise ValueError("AgentStandIn paths and names must not contain single quotes")
    return f"stty -icanon min 1 time 0; exec -a {name} /bin/cat > '{output_path}'"


def read_pty_capture(path):
    target = Path(path)
    if not target.is_file():
        return ""
    return target.read_bytes().decode("utf-8", errors="replace")


# ---------------------------------------------------------------------------
# Reusable step invariants
# ---------------------------------------------------------------------------

def check_state_json_valid(state_dir, *, expected_workspace_ids=None, expected_active_id=None):
    """Verify state.json parses cleanly and has consistent workspace identities."""
    path = Path(state_dir) / "state.json"
    if not path.is_file():
        return False, "state.json is missing"
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return False, f"state.json unreadable: {error}"
    workspaces = state.get("workspaces")
    if not isinstance(workspaces, list) or not workspaces:
        return False, "state.json has no workspaces"
    ids = [ws.get("id") for ws in workspaces]
    if any(not ws_id for ws_id in ids):
        return False, "state.json contains a workspace without an id"
    if len(ids) != len(set(ids)):
        return False, "state.json contains duplicate workspace ids"
    active_id = state.get("activeWorkspaceID")
    if active_id is not None and active_id not in ids:
        return False, f"activeWorkspaceID {active_id} is not in workspaces"
    if expected_workspace_ids:
        missing = [wid for wid in expected_workspace_ids if wid not in ids]
        if missing:
            return False, f"missing expected workspaces: {', '.join(missing)}"
    if expected_active_id is not None and active_id != expected_active_id:
        return False, f"expected activeWorkspaceID {expected_active_id}, got {active_id}"
    return True, f"{len(workspaces)} workspaces valid"


def check_pty_isolation(captures):
    """Verify byte-for-byte PTY isolation across AgentStandIn captures.

    captures: dict mapping agent_label -> {
        "path": Path,
        "required": [token, ...],
        "forbidden": [token, ...],
    }
    """
    for label, spec in sorted(captures.items()):
        text = read_pty_capture(spec["path"])
        for token in spec.get("required") or ():
            if token not in text:
                return False, f"agent {label} PTY missing expected token {token}"
        for token in spec.get("forbidden") or ():
            if token in text:
                return False, f"cross-PTY leak: agent {label} received forbidden token {token}"
    return True, f"isolated across {len(captures)} PTYs"


def check_mission_no_double_delivery(state_dir, mission_id=None):
    """Verify missions.json has no duplicate responses per question or duplicate instructions."""
    path = Path(state_dir) / "missions.json"
    if not path.is_file():
        return True, "missions.json not present"
    try:
        missions = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return False, f"missions.json unreadable: {error}"
    if not isinstance(missions, list):
        return False, "missions.json root is not a list"
    for mission in missions:
        if mission_id and mission.get("id") != mission_id:
            continue
        events = mission.get("events") or []
        event_ids = [ev.get("id") for ev in events if ev.get("id")]
        if len(event_ids) != len(set(event_ids)):
            return False, f"duplicate event id in mission {mission.get('id')}"
        replies_by_question = {}
        for ev in events:
            if ev.get("kind") == "response" and ev.get("inReplyTo"):
                qid = ev["inReplyTo"]
                replies_by_question[qid] = replies_by_question.get(qid, 0) + 1
                if replies_by_question[qid] > 1:
                    return False, f"double response delivery for question {qid}"
    return True, "no duplicate mission deliveries"


def check_amber_has_reason(ax_snapshot):
    """Invariant: amber waiting count > 0 must have a rendered reason in the AX tree."""
    controls = (ax_snapshot or {}).get("controls") or []
    waiting_count = 0
    for ctrl in controls:
        label = ctrl.get("label") or ""
        match = _WAITING_BADGE_RE.match(label)
        if match:
            waiting_count = int(match.group(1))
            break
    if waiting_count == 0:
        return True, "no amber waiting badge active"

    # A rendered reason appears as permission text/buttons, Mission question/reply,
    # waiting status on a task row/rail item, or "An agent waits for you in ...".
    reason_markers = (
        "Allow once ",
        "Deny ",
        "Reply to:",
        "Claude asks:",
        "An agent waits for you in ",
        "waiting",
        "Permission",
        "asks",
        "question",
    )
    for ctrl in controls:
        label = ctrl.get("label") or ""
        value = ctrl.get("value") or ""
        if _WAITING_BADGE_RE.match(label):
            continue
        combined = f"{label} {value}"
        if any(marker.lower() in combined.lower() for marker in reason_markers):
            return True, f"waiting={waiting_count} backed by AX reason {label!r}"
    return False, f"amber badge reports {waiting_count} waiting agent(s) with no rendered reason in AX tree"


def check_ax_controls_reachable(ax_snapshot, required_labels=(), required_prefixes=()):
    """Verify named AX controls are present, enabled, non-empty, and inside the window."""
    controls = (ax_snapshot or {}).get("controls") or []
    missing = []
    unreachable = []
    for label in required_labels:
        matches = [c for c in controls if c.get("label") == label]
        if not matches:
            missing.append(label)
        elif not any(c.get("enabled") and c.get("inWindow") for c in matches):
            unreachable.append(label)
    for prefix in required_prefixes:
        matches = [c for c in controls if (c.get("label") or "").startswith(prefix)]
        if not matches:
            missing.append(f"{prefix}*")
        elif not any(c.get("enabled") and c.get("inWindow") for c in matches):
            unreachable.append(f"{prefix}*")
    if missing:
        return False, "missing required AX controls: " + ", ".join(missing)
    if unreachable:
        return False, "unreachable or clipped AX controls: " + ", ".join(unreachable)
    return True, f"all {len(required_labels) + len(required_prefixes)} named controls reachable"


def record_step_invariants(report, step_id, checks):
    """Evaluate (invariant_id, passed, detail) tuples, attach to the active/last step, and raise on failure."""
    records = []
    failures = []
    for inv_id, passed, detail in checks:
        records.append({"id": inv_id, "passed": bool(passed), "detail": str(detail)})
        if not passed:
            failures.append(f"invariant:{inv_id}: {detail}")
    report.record_invariants(step_id, records)
    if failures:
        raise RuntimeError("; ".join(failures))


# ---------------------------------------------------------------------------
# Sidebar breakpoints & metamorphic AX evaluation
# ---------------------------------------------------------------------------

def expected_sidebar_folded_sequence(widths=SIDEBAR_BREAKPOINTS, chosen_expanded=True):
    """Pure mirror of SidebarFold.windowResized(to:) from NiruxShellView+SidebarFold.swift."""
    is_narrow = False
    auto_folded = False
    result = []
    for width in widths:
        narrow = width < (SIDEBAR_NARROW_WIDTH + (SIDEBAR_HYSTERESIS if is_narrow else 0))
        if narrow != is_narrow:
            is_narrow = narrow
            auto_folded = narrow
        expanded = chosen_expanded and not auto_folded
        result.append((width, not expanded))
    return result


def classify_sidebar_state(ax_snapshot):
    """Classify the canary window's sidebar as 'expanded', 'folded', or 'ambiguous' from AX controls."""
    controls = (ax_snapshot or {}).get("controls") or []
    window = (ax_snapshot or {}).get("window") or {}
    win_x = float(window.get("x", 0.0))

    expanded_history = [
        c for c in controls
        if c.get("label") == "History"
        and c.get("inWindow")
        and float((c.get("frame") or {}).get("width", 0.0)) >= SIDEBAR_EXPANDED_MIN_WIDTH
    ]
    rail_new_task = [
        c for c in controls
        if c.get("label") == "New task"
        and c.get("inWindow")
        and float((c.get("frame") or {}).get("width", 0.0)) <= SIDEBAR_RAIL_MAX_WIDTH
        and (float((c.get("frame") or {}).get("x", 0.0)) - win_x) <= SIDEBAR_RAIL_MAX_WIDTH
    ]
    rail_board = [
        c for c in controls
        if c.get("label") in ("Board", "Board, open")
        and c.get("inWindow")
        and float((c.get("frame") or {}).get("width", 0.0)) <= SIDEBAR_RAIL_MAX_WIDTH
        and (float((c.get("frame") or {}).get("x", 0.0)) - win_x) <= SIDEBAR_RAIL_MAX_WIDTH
    ]

    if expanded_history and not rail_new_task:
        return "expanded"
    if rail_new_task and rail_board and not expanded_history:
        return "folded"
    return "ambiguous"


def extract_metamorphic_signature(ax_snapshot):
    """Reduce an AX snapshot to stable semantic observables (no pixel golden images)."""
    controls = (ax_snapshot or {}).get("controls") or []
    window = (ax_snapshot or {}).get("window") or {}
    state = classify_sidebar_state(ax_snapshot)
    reachable_command_bar = sorted({
        c["label"] for c in controls
        if c.get("enabled") and c.get("inWindow") and (
            c.get("label") == "Search, Command P"
            or (c.get("label") or "").startswith("Space: ")
        )
    })
    sidebar_controls = sorted({
        c["label"] for c in controls
        if c.get("enabled") and c.get("inWindow") and c.get("label") in {
            "History", "New task", "New Task", "Board", "Board, open",
            "Archived tasks", "Archived, 1",
        }
    })
    return {
        "windowWidth": round(float(window.get("width", 0.0))),
        "sidebarState": state,
        "commandBarControls": reachable_command_bar,
        "sidebarControls": sidebar_controls,
    }


def assert_metamorphic_equivalence(pass_reduce_motion, pass_animated):
    """Assert identical fold/unfold transitions and reachable controls across Reduce Motion off/on."""
    if len(pass_reduce_motion) != len(pass_animated):
        raise RuntimeError(
            f"metamorphic sweep length mismatch: {len(pass_reduce_motion)} vs {len(pass_animated)}"
        )
    for idx, (sig_a, sig_b) in enumerate(zip(pass_reduce_motion, pass_animated)):
        if sig_a["windowWidth"] != sig_b["windowWidth"]:
            raise RuntimeError(
                f"metamorphic width drift at step {idx}: {sig_a['windowWidth']} vs {sig_b['windowWidth']}"
            )
        if sig_a["sidebarState"] != sig_b["sidebarState"]:
            raise RuntimeError(
                f"metamorphic sidebar state mismatch at {sig_a['windowWidth']}pt: "
                f"reduceMotion={sig_a['sidebarState']} vs animated={sig_b['sidebarState']}"
            )
        if sig_a["commandBarControls"] != sig_b["commandBarControls"]:
            raise RuntimeError(
                f"metamorphic command bar controls diverged at {sig_a['windowWidth']}pt: "
                f"{sig_a['commandBarControls']} vs {sig_b['commandBarControls']}"
            )
        if sig_a["sidebarControls"] != sig_b["sidebarControls"]:
            raise RuntimeError(
                f"metamorphic sidebar controls diverged at {sig_a['windowWidth']}pt: "
                f"{sig_a['sidebarControls']} vs {sig_b['sidebarControls']}"
            )


# ---------------------------------------------------------------------------
# Fixture builders for PR 3 scenarios
# ---------------------------------------------------------------------------

def _init_git_repo(repo, env, seed):
    repo.mkdir(parents=True, exist_ok=True)
    commit_date = "2000-01-01T00:00:00Z"
    git_env = dict(env, GIT_AUTHOR_DATE=commit_date, GIT_COMMITTER_DATE=commit_date)

    def git(*args):
        subprocess.run(
            ["/usr/bin/git", "-c", "user.name=Nirux Canary",
             "-c", "user.email=canary@localhost", *args],
            env=git_env, cwd=repo, stdout=subprocess.DEVNULL, check=True, timeout=30,
        )

    git("init", "-q", "-b", "main")
    (repo / "README.md").write_text("canary " + seed + "\n", encoding="utf-8")
    git("add", "README.md")
    git("commit", "-qm", "Synthetic canary fixture")
    return git


def _write_shell_rc(work):
    (work / "home/.zshenv").write_text('exec 9<"$NIRUX_STATE_DIR/../children"\n', encoding="utf-8")
    (work / "home/.zshrc").write_text(
        'precmd() { print -r -- "$$" > "$NIRUX_STATE_DIR/prompt-${NIRUX_WORKSPACE_ID:-default}"; '
        'print -r -- "$$" > "$NIRUX_STATE_DIR/prompt"; }\n',
        encoding="utf-8",
    )


def fixture_multi_agent(work, env, seed):
    """Create 2 Spaces, 2 linked worktrees, 2 workspaces with stable agent UUIDs, and an active Mission."""
    repo = work / "repo"
    tree_alpha = work / "worktree-alpha"
    tree_beta = work / "worktree-beta"
    git = _init_git_repo(repo, env, seed)
    git("worktree", "add", "-qb", "canary-alpha", str(tree_alpha))
    git("worktree", "add", "-qb", "canary-beta", str(tree_beta))

    base_ns = uuid.UUID(seed)
    space_alpha_id = str(uuid.uuid5(base_ns, "space-alpha"))
    space_beta_id = str(uuid.uuid5(base_ns, "space-beta"))
    ws_alpha_id = str(uuid.uuid5(base_ns, "ws-alpha"))
    ws_beta_id = str(uuid.uuid5(base_ns, "ws-beta"))
    agent_alpha_id = str(uuid.uuid5(base_ns, "agent-alpha"))
    agent_beta_id = str(uuid.uuid5(base_ns, "agent-beta"))
    mission_id = str(uuid.uuid5(base_ns, "mission-alpha-beta"))

    profiles = [
        {"id": space_alpha_id, "name": "Canary Alpha", "colorHex": "#7AA2F7"},
        {"id": space_beta_id, "name": "Canary Beta", "colorHex": "#9ECE6A"},
    ]
    write_json(work / "state/projects.json", {
        "schemaVersion": 2,
        "projects": profiles,
        "deletedIDs": [],
    })
    write_json(work / "state/state.json", {
        "projectsFileVersion": 2,
        "workspaceProfiles": profiles,
        "activeProfileID": space_alpha_id,
        "activeWorkspaceIndex": 0,
        "activeWorkspaceID": ws_alpha_id,
        "workspaces": [
            {
                "id": ws_alpha_id,
                "title": "Alpha Parent",
                "cwd": str(tree_alpha),
                "profileID": space_alpha_id,
                "focusedColumnIndex": 0,
                "isInactive": False,
                "columns": [{
                    "cwd": str(tree_alpha),
                    "columnType": "terminal",
                    "widthPreset": 0.5,
                    "agentUUID": agent_alpha_id,
                }],
            },
            {
                "id": ws_beta_id,
                "title": "Beta Child",
                "cwd": str(tree_beta),
                "profileID": space_beta_id,
                "missionID": mission_id,
                "parentWorkspaceID": ws_alpha_id,
                "focusedColumnIndex": 0,
                "isInactive": False,
                "columns": [{
                    "cwd": str(tree_beta),
                    "columnType": "terminal",
                    "widthPreset": 0.5,
                    "agentUUID": agent_beta_id,
                }],
            },
        ],
        "settings": {
            "animatesInterface": False,
            "keepMacAwakeWhileAgentsWork": False,
            "missionHandoffsEnabled": True,
            "sidebarApprovalsEnabled": True,
            "sidebarExpanded": True,
            "sidebarWidth": 260,
        },
    })
    now = time.time()
    write_json(work / "state/missions.json", [{
        "id": mission_id,
        "parentWorkspaceID": ws_alpha_id,
        "parentAgentUUID": agent_alpha_id,
        "childWorkspaceID": ws_beta_id,
        "childAgentUUID": agent_beta_id,
        "childAgentKind": "claude",
        "branch": "canary-beta",
        "status": "active",
        "createdAt": now,
        "updatedAt": now,
        "events": [],
        "startedByParent": True,
    }])
    _write_shell_rc(work)
    return {
        "spaceAlphaID": space_alpha_id,
        "spaceBetaID": space_beta_id,
        "wsAlphaID": ws_alpha_id,
        "wsBetaID": ws_beta_id,
        "agentAlphaID": agent_alpha_id,
        "agentBetaID": agent_beta_id,
        "missionID": mission_id,
        "treeAlpha": tree_alpha,
        "treeBeta": tree_beta,
        "ptyAlpha": work / "state/pty-alpha.txt",
        "ptyBeta": work / "state/pty-beta.txt",
    }


def fixture_sidebar_breakpoints(work, env, seed):
    """Create 1 Space with 1 active + 1 archived workspace and expanded sidebar (260 pt)."""
    repo = work / "repo"
    tree = work / "worktree"
    git = _init_git_repo(repo, env, seed)
    git("worktree", "add", "-qb", "canary-sidebar", str(tree))

    base_ns = uuid.UUID(seed)
    space_id = str(uuid.uuid5(base_ns, "space-sidebar"))
    ws_active_id = str(uuid.uuid5(base_ns, "ws-active"))
    ws_archived_id = str(uuid.uuid5(base_ns, "ws-archived"))
    profiles = [{"id": space_id, "name": "Sidebar Canary", "colorHex": "#7AA2F7"}]
    write_json(work / "state/projects.json", {
        "schemaVersion": 2,
        "projects": profiles,
        "deletedIDs": [],
    })
    write_json(work / "state/state.json", {
        "projectsFileVersion": 2,
        "workspaceProfiles": profiles,
        "activeProfileID": space_id,
        "activeWorkspaceIndex": 0,
        "activeWorkspaceID": ws_active_id,
        "workspaces": [
            {
                "id": ws_active_id,
                "title": "Sidebar Active",
                "cwd": str(tree),
                "profileID": space_id,
                "focusedColumnIndex": 0,
                "isInactive": False,
                "columns": [{"cwd": str(tree), "columnType": "terminal", "widthPreset": 0.5}],
            },
            {
                "id": ws_archived_id,
                "title": "Sidebar Archived",
                "cwd": str(tree),
                "profileID": space_id,
                "focusedColumnIndex": 0,
                "isInactive": True,
                "columns": [{"cwd": str(tree), "columnType": "terminal", "widthPreset": 0.5}],
            },
        ],
        "settings": {
            "animatesInterface": False,
            "keepMacAwakeWhileAgentsWork": False,
            "sidebarExpanded": True,
            "sidebarWidth": 260,
        },
    })
    _write_shell_rc(work)
    return {
        "spaceID": space_id,
        "wsActiveID": ws_active_id,
        "wsArchivedID": ws_archived_id,
        "tree": tree,
    }


# ---------------------------------------------------------------------------
# Scenario execution functions (invoked by run.py)
# ---------------------------------------------------------------------------

def run_multi_agent_routing(app, work, report, step, seed, injection, wait_for):
    """Execute the AgentStandIn multi-agent routing, permission & Mission scenario."""
    with step("fixture"):
        ctx = fixture_multi_agent(work, app.env, seed)
        app.tree = ctx["treeAlpha"]

    with step("preflight"):
        app.preflight()

    with step("launch"):
        app.launch()
        wait_for(
            "Alpha workspace prompt did not appear",
            (work / f"state/prompt-{ctx['wsAlphaID']}").is_file,
            app.check_window,
        )
        record_step_invariants(report, "launch", [
            ("state-json-valid", *check_state_json_valid(
                work / "state",
                expected_workspace_ids=[ctx["wsAlphaID"], ctx["wsBetaID"]],
            )),
        ])

    token_beta = f"BETA-{seed.replace('-', '')[:12]}"
    token_alpha = f"ALPHA-{seed.replace('-', '')[:12]}"
    pty_alpha = ctx["ptyAlpha"]
    pty_beta = ctx["ptyBeta"]

    with step("standin-start"):
        app.drive("command", agent_stand_in_command(pty_alpha, name="claude"))
        wait_for("Alpha AgentStandIn output file not created", pty_alpha.is_file, app.check_window)

        app.drive("menu", "Space", "Next Space")
        wait_for(
            "Beta workspace prompt did not appear after Space switch",
            (work / f"state/prompt-{ctx['wsBetaID']}").is_file,
            app.check_window,
        )
        app.drive("command", agent_stand_in_command(pty_beta, name="claude"))
        wait_for("Beta AgentStandIn output file not created", pty_beta.is_file, app.check_window)

    with step("routing-beta"):
        sent = "INJECTED-WRONG-BETA" if injection == "routing-beta" else token_beta
        app.drive("command", sent)
        wait_for(
            "Beta AgentStandIn did not receive expected keystrokes",
            lambda: token_beta in read_pty_capture(pty_beta),
            app.check_window,
        )
        record_step_invariants(report, "routing-beta", [
            ("pty-isolation", *check_pty_isolation({
                "alpha": {"path": pty_alpha, "required": [], "forbidden": [token_beta]},
                "beta": {"path": pty_beta, "required": [token_beta], "forbidden": []},
            })),
        ])

    with step("mission-and-permission"):
        nirux_bin = str(work / "Nirux.app/Contents/MacOS/Nirux")
        child_env = dict(
            app.env,
            NIRUX_MISSION_HANDOFFS="1",
            NIRUX_MISSION_ID=ctx["missionID"],
            NIRUX_WORKSPACE_ID=ctx["wsBetaID"],
            NIRUX_AGENT_UUID=ctx["agentBetaID"],
        )
        question_msg = f"Canary decision {seed[:8]}?"
        ask_cmd = [
            nirux_bin, "--mission", "ask",
            "--kind", "decision",
            "--message", question_msg,
            "--recommend", "Keep deterministic path",
            "--timeout", "5",
        ]
        if injection == "mission-and-permission":
            raise RuntimeError("injected mission-and-permission failure")
        ask_res = subprocess.run(ask_cmd, env=child_env, capture_output=True, text=True, timeout=15)
        if ask_res.returncode != 0:
            raise RuntimeError(f"packaged CLI --mission ask failed ({ask_res.returncode}): {ask_res.stderr.strip()}")

        def mission_has_question():
            missions = json.loads((work / "state/missions.json").read_text(encoding="utf-8"))
            for m in missions:
                if m.get("id") == ctx["missionID"]:
                    return any(e.get("kind") == "question" and e.get("message") == question_msg
                               for e in m.get("events") or [])
            return False

        wait_for("Mission question not persisted in missions.json", mission_has_question, app.check_window)

        # Feed a real Claude PermissionRequest hook event into the isolated queue for Alpha.
        hook_env = dict(
            app.env,
            NIRUX_WORKSPACE_ID=ctx["wsAlphaID"],
            NIRUX_AGENT_UUID=ctx["agentAlphaID"],
        )
        hook_payload = json.dumps({
            "hook_event_name": "Notification",
            "notification_type": "permission_prompt",
            "message": "Claude needs permission to run echo canary",
            "session_id": f"canary-sess-{seed[:8]}",
            "cwd": str(ctx["treeAlpha"]),
        })
        hook_res = subprocess.run(
            [nirux_bin, "--hook", "claude"],
            input=hook_payload, env=hook_env, capture_output=True, text=True, timeout=10,
        )
        if hook_res.returncode != 0:
            raise RuntimeError(f"packaged CLI --hook claude failed ({hook_res.returncode}): {hook_res.stderr.strip()}")

        # Parent replies via packaged CLI accepting the child's recommendation.
        missions = json.loads((work / "state/missions.json").read_text(encoding="utf-8"))
        q_event = next(
            e for m in missions if m.get("id") == ctx["missionID"]
            for e in (m.get("events") or [])
            if e.get("kind") == "question" and e.get("message") == question_msg
        )
        parent_env = dict(
            app.env,
            NIRUX_MISSION_HANDOFFS="1",
            NIRUX_WORKSPACE_ID=ctx["wsAlphaID"],
            NIRUX_AGENT_UUID=ctx["agentAlphaID"],
        )
        reply_res = subprocess.run(
            [nirux_bin, "--mission", "reply", "--event", q_event["id"], "--accept"],
            env=parent_env, capture_output=True, text=True, timeout=15,
        )
        if reply_res.returncode != 0:
            raise RuntimeError(f"packaged CLI --mission reply failed ({reply_res.returncode}): {reply_res.stderr.strip()}")

        def mission_has_response():
            latest = json.loads((work / "state/missions.json").read_text(encoding="utf-8"))
            for m in latest:
                if m.get("id") == ctx["missionID"]:
                    return any(
                        e.get("kind") == "response"
                        and e.get("inReplyTo") == q_event["id"]
                        and e.get("acceptedRecommendation") is True
                        for e in m.get("events") or []
                    )
            return False

        wait_for("Mission reply not persisted in missions.json", mission_has_response, app.check_window)
        ax_snap = app.ax_controls()
        record_step_invariants(report, "mission-and-permission", [
            ("amber-has-reason", *check_amber_has_reason(ax_snap)),
            ("mission-no-double-delivery", *check_mission_no_double_delivery(work / "state", ctx["missionID"])),
            ("pty-isolation", *check_pty_isolation({
                "alpha": {"path": pty_alpha, "required": [], "forbidden": [token_beta]},
                "beta": {"path": pty_beta, "required": [token_beta], "forbidden": []},
            })),
        ])

    with step("switch-and-route-alpha"):
        app.drive("menu", "Space", "Previous Space")
        wait_for(
            "Space Alpha not active in Command Bar after switch",
            lambda: any(
                c.get("label") == "Space: Canary Alpha"
                for c in (app.ax_controls().get("controls") or [])
            ),
            app.check_window,
        )
        sent = "INJECTED-WRONG-ALPHA" if injection == "switch-and-route-alpha" else token_alpha
        app.drive("command", sent)
        wait_for(
            "Alpha AgentStandIn did not receive expected keystrokes after switch back",
            lambda: token_alpha in read_pty_capture(pty_alpha),
            app.check_window,
        )
        record_step_invariants(report, "switch-and-route-alpha", [
            ("pty-isolation", *check_pty_isolation({
                "alpha": {"path": pty_alpha, "required": [token_alpha], "forbidden": [token_beta]},
                "beta": {"path": pty_beta, "required": [token_beta], "forbidden": [token_alpha]},
            })),
        ])

    with step("quit-and-verify"):
        app.quit()
        record_step_invariants(report, "quit-and-verify", [
            ("no-orphan-children", len(app.holders()) == 0, f"holders={app.holders()}"),
            ("state-json-valid", *check_state_json_valid(
                work / "state",
                expected_workspace_ids=[ctx["wsAlphaID"], ctx["wsBetaID"]],
            )),
            ("mission-no-double-delivery", *check_mission_no_double_delivery(work / "state", ctx["missionID"])),
            ("pty-isolation", *check_pty_isolation({
                "alpha": {"path": pty_alpha, "required": [token_alpha], "forbidden": [token_beta]},
                "beta": {"path": pty_beta, "required": [token_beta], "forbidden": [token_alpha]},
            })),
        ])


def _resize_and_assert_breakpoint(app, width, expected_folded, wait_for, inject=False):
    """Resize the canary window to `width` and wait for stabilized AX state."""
    expected_state = "folded" if expected_folded else "expanded"
    if inject:
        expected_state = "expanded" if expected_folded else "folded"
    app.resize_window(width, SIDEBAR_WINDOW_HEIGHT)

    observed = {}

    def settled():
        snap = app.ax_controls()
        actual_w = round(float((snap.get("window") or {}).get("width", 0.0)))
        if abs(actual_w - width) > 2:
            return False
        state = classify_sidebar_state(snap)
        if state != expected_state:
            return False
        observed["snap"] = snap
        return True

    wait_for(
        f"sidebar did not settle to {expected_state} at {width}pt",
        settled,
        app.check_window,
        timeout=10,
    )
    return observed["snap"]


def run_sidebar_breakpoints(app, work, report, step, seed, injection, wait_for):
    """Execute the 899/900/939/940 pt sidebar fold/hysteresis & Reduce Motion metamorphic scenario."""
    with step("fixture"):
        ctx = fixture_sidebar_breakpoints(work, app.env, seed)
        app.tree = ctx["tree"]

    with step("preflight"):
        app.preflight()

    with step("launch"):
        app.launch()
        record_step_invariants(report, "launch", [
            ("state-json-valid", *check_state_json_valid(
                work / "state",
                expected_workspace_ids=[ctx["wsActiveID"], ctx["wsArchivedID"]],
                expected_active_id=ctx["wsActiveID"],
            )),
        ])

    reduce_motion_sigs = []

    with step("narrow-sweep"):
        narrow_seq = expected_sidebar_folded_sequence((940, 900, 899), chosen_expanded=True)
        for idx, (width, should_fold) in enumerate(narrow_seq):
            snap = _resize_and_assert_breakpoint(
                app, width, should_fold, wait_for,
                inject=(injection == "narrow-sweep" and idx == len(narrow_seq) - 1),
            )
            reduce_motion_sigs.append(extract_metamorphic_signature(snap))
            required = ["Search, Command P", "New task", "Board"] if should_fold else ["Search, Command P", "History"]
            record_step_invariants(report, "narrow-sweep", [
                ("ax-controls-reachable", *check_ax_controls_reachable(
                    snap, required_labels=required, required_prefixes=("Space: ",),
                )),
            ])

    with step("widen-hysteresis"):
        # Start from the already-narrow 899pt state: 900 & 939 must stay folded; 940 unfolds.
        widen_seq = [(900, True), (939, True), (940, False)]
        for idx, (width, should_fold) in enumerate(widen_seq):
            snap = _resize_and_assert_breakpoint(
                app, width, should_fold, wait_for,
                inject=(injection == "widen-hysteresis" and idx == 1),
            )
            reduce_motion_sigs.append(extract_metamorphic_signature(snap))
            required = ["Search, Command P", "New task", "Board"] if should_fold else ["Search, Command P", "History"]
            record_step_invariants(report, "widen-hysteresis", [
                ("ax-controls-reachable", *check_ax_controls_reachable(
                    snap, required_labels=required, required_prefixes=("Space: ",),
                )),
            ])

    with step("reduce-motion-metamorphic"):
        app.quit()
        state_path = work / "state/state.json"
        saved = json.loads(state_path.read_text(encoding="utf-8"))
        if saved.get("settings", {}).get("sidebarExpanded") is not True:
            raise RuntimeError("auto-fold overwrote the user's persisted sidebarExpanded=true choice")
        saved.setdefault("settings", {})["animatesInterface"] = True
        write_json(state_path, saved)

        app.launch()
        animated_sigs = []
        full_seq = expected_sidebar_folded_sequence(SIDEBAR_BREAKPOINTS, chosen_expanded=True)
        for idx, (width, should_fold) in enumerate(full_seq):
            snap = _resize_and_assert_breakpoint(
                app, width, should_fold, wait_for,
                inject=(injection == "reduce-motion-metamorphic" and idx == len(full_seq) - 1),
            )
            animated_sigs.append(extract_metamorphic_signature(snap))
        assert_metamorphic_equivalence(reduce_motion_sigs, animated_sigs)
        report.data["metamorphic"] = {
            "reduceMotion": reduce_motion_sigs,
            "animated": animated_sigs,
        }
        record_step_invariants(report, "reduce-motion-metamorphic", [
            ("state-json-valid", *check_state_json_valid(
                work / "state",
                expected_workspace_ids=[ctx["wsActiveID"], ctx["wsArchivedID"]],
            )),
        ])

    with step("final-quit"):
        app.quit()
        record_step_invariants(report, "final-quit", [
            ("no-orphan-children", len(app.holders()) == 0, f"holders={app.holders()}"),
        ])
