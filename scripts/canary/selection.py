"""Diff-targeted canary scenario selection: coverage index first, explicit path table fallback."""
import argparse
from fnmatch import fnmatch
import json
from pathlib import Path
import re
import sys

CORE_SCENARIO = "ghostty-monaco-restore"

# Ordered list of all known scenario IDs so output ordering is deterministic.
DEFAULT_SCENARIO_ORDER = (
    "ghostty-monaco-restore",
    "multi-agent-routing",
    "sidebar-breakpoints",
)

# Documentation and non-runtime files that never require a canary run on their own.
IGNORED_PATTERNS = (
    "docs/*",
    "README.md",
    "LICENSE",
    "*.md",
)

# Paths under scripts/canary/ README are docs, not runtime changes.
IGNORED_EXACT = {
    "scripts/canary/README.md",
}

# Changes here affect every scenario's bundle, runner, or persistence contract.
FULL_SUITE_PATTERNS = (
    "Package.swift",
    "Package.resolved",
    "NiruxCore/Package.swift",
    "NiruxCore/Package.resolved",
    "Resources/Info.plist",
    "scripts/bundle.sh",
    "scripts/canary.sh",
    "scripts/select-canary-scenarios.sh",
    "scripts/canary/*",
    ".github/workflows/canary.yml",
    "Sources/Nirux/Model/Persistence*.swift",
    "Sources/Nirux/Util/RealStateGuard.swift",
    "Sources/Nirux/Util/StateFolderLock.swift",
)

# Explicit fallback table: path glob patterns -> scenario IDs.
# Used when no coverage index is present or a changed file is not yet indexed (e.g. new files).
PATH_TO_SCENARIOS = (
    ("ghostty-monaco-restore", (
        "Sources/Nirux/NiruxApp.swift",
        "Sources/Nirux/NiruxApp+MenuActions.swift",
        "Sources/Nirux/NiruxApp+KeyHandling.swift",
        "Sources/Nirux/EditorAssets/*",
        "Sources/Nirux/Views/Editor*",
        "Sources/Nirux/Views/NiruxShellView+Persistence.swift",
        "Sources/Nirux/Views/NiruxShellView+LazyRestore.swift",
        "Sources/Nirux/Content/PtySession.swift",
        "Sources/Nirux/Content/Terminal*",
        "Sources/Nirux/Util/Terminal*",
        "Sources/Nirux/Model/ColumnState*.swift",
        "Sources/Nirux/Model/WorkspaceState*.swift",
    )),
    ("multi-agent-routing", (
        "Sources/Nirux/Content/PtySession.swift",
        "Sources/Nirux/Input/*",
        "Sources/Nirux/Model/Mission*.swift",
        "Sources/Nirux/Model/AgentHook*.swift",
        "Sources/Nirux/Model/AgentStatus*.swift",
        "Sources/Nirux/Model/AgentAttention.swift",
        "Sources/Nirux/Model/PermissionApproval*.swift",
        "Sources/Nirux/Model/ProjectStore.swift",
        "Sources/Nirux/Model/WorkspaceStore.swift",
        "Sources/Nirux/NiruxApp+SpaceAgentMenus.swift",
        "Sources/Nirux/Views/NiruxShellView+Mission*.swift",
        "Sources/Nirux/Views/NiruxShellView+Request*.swift",
        "Sources/Nirux/Views/NiruxShellView+Workspaces.swift",
        "Sources/Nirux/Views/Request*.swift",
        "Sources/Nirux/Views/SidebarApproval*.swift",
        "Sources/Nirux/Views/SidebarMission*.swift",
        "NiruxCore/Sources/NiruxCore/TaskThread*.swift",
    )),
    ("sidebar-breakpoints", (
        "Sources/Nirux/Views/NiruxShellView+SidebarFold.swift",
        "Sources/Nirux/Views/NiruxShellView+Appearance.swift",
        "Sources/Nirux/Views/NiruxShellView+UnderGlass.swift",
        "Sources/Nirux/Views/NiruxShellView+Workspaces.swift",
        "Sources/Nirux/Views/Sidebar*.swift",
        "Sources/Nirux/Views/IconRail.swift",
        "Sources/Nirux/Views/CommandBarView.swift",
        "Sources/Nirux/Views/StateIcon*.swift",
        "NiruxCore/Sources/NiruxCore/InterfaceTransparency.swift",
    )),
)

_SOURCE_ROOT_RE = re.compile(r"(?:^|/)(NiruxCore/Sources/.*|Sources/.*)$")


def normalize_repo_path(path):
    """Normalize a repository-relative path (forward slashes, no leading './')."""
    value = str(path).strip().replace("\\", "/")
    while value.startswith("./"):
        value = value[2:]
    return value


def is_ignored_path(path):
    """Return True for pure documentation or non-runtime files."""
    norm = normalize_repo_path(path)
    if not norm:
        return True
    if norm in IGNORED_EXACT:
        return True
    if norm.startswith("scripts/canary/") and not norm.endswith(".md"):
        return False
    return any(fnmatch(norm, pat) for pat in IGNORED_PATTERNS)


def is_runtime_source(path):
    norm = normalize_repo_path(path)
    return (
        (norm.startswith("Sources/") or norm.startswith("NiruxCore/Sources/"))
        and norm.endswith((".swift", ".js", ".html", ".css"))
    )


def parse_coverage_index(index_path):
    """Parse '<source_path> <scenario_id>' lines into {source_path: set(scenario_ids)}."""
    mapping = {}
    if not index_path:
        return mapping
    path = Path(index_path)
    if not path.is_file():
        return mapping
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        src = normalize_repo_path(parts[0])
        scenario_id = parts[1].strip()
        if src and scenario_id:
            mapping.setdefault(src, set()).add(scenario_id)
    return mapping


def extract_lcov_mappings(lcov_text, scenario_id):
    """Extract sorted '<source_path> <scenario_id>' lines from llvm-cov LCOV export."""
    current = None
    hit_files = set()
    for line in lcov_text.splitlines():
        if line.startswith("SF:"):
            raw = line[3:].strip()
            match = _SOURCE_ROOT_RE.search(raw)
            current = match.group(1) if match else None
        elif line.startswith("DA:") and current:
            parts = line[3:].split(",")
            if len(parts) >= 2:
                try:
                    if int(parts[1]) > 0:
                        hit_files.add(current)
                except ValueError:
                    pass
        elif line == "end_of_record":
            current = None
    return [f"{src} {scenario_id}" for src in sorted(hit_files)]


def _match_table(path, allowed_scenarios):
    matched = []
    for scenario_id, patterns in PATH_TO_SCENARIOS:
        if scenario_id not in allowed_scenarios:
            continue
        if any(fnmatch(path, pat) for pat in patterns):
            matched.append(scenario_id)
    return matched


def select_scenarios(
    changed_paths,
    *,
    available_scenarios=DEFAULT_SCENARIO_ORDER,
    coverage_index=None,
    core_scenario=CORE_SCENARIO,
):
    """Select canary scenarios for a set of changed paths.

    Priority per path:
    1. Pure docs/non-runtime files are ignored.
    2. Global bundle/runner/persistence paths select all available scenarios.
    3. Coverage index (if provided and contains the path) maps source -> scenarios.
    4. Explicit path->scenarios table acts as fallback for unindexed paths (e.g. new files)
       or when no coverage index is available.
    5. Unmapped runtime source files fall back to the core smoke scenario.
    """
    ordered = tuple(available_scenarios)
    allowed = set(ordered)
    cov_map = (
        parse_coverage_index(coverage_index)
        if isinstance(coverage_index, (str, Path))
        else (coverage_index or {})
    )

    selected = set()
    reasons = {}
    ignored = []
    unmapped_sources = []
    used_coverage = False
    used_table = False
    triggered_all = False

    def add(scenario_id, reason):
        if scenario_id not in allowed:
            return
        selected.add(scenario_id)
        reasons.setdefault(scenario_id, [])
        if reason not in reasons[scenario_id]:
            reasons[scenario_id].append(reason)

    for raw in changed_paths:
        path = normalize_repo_path(raw)
        if not path:
            continue
        if is_ignored_path(path):
            ignored.append(path)
            continue
        if any(fnmatch(path, pat) for pat in FULL_SUITE_PATTERNS):
            triggered_all = True
            for scenario_id in ordered:
                add(scenario_id, f"{path} (global)")
            continue

        cov_hits = sorted(s for s in cov_map.get(path, ()) if s in allowed)
        if cov_hits:
            used_coverage = True
            for scenario_id in cov_hits:
                add(scenario_id, f"{path} (coverage)")
            continue

        table_hits = _match_table(path, allowed)
        if table_hits:
            used_table = True
            for scenario_id in table_hits:
                add(scenario_id, f"{path} (table)")
            continue

        if is_runtime_source(path):
            unmapped_sources.append(path)
            if core_scenario in allowed:
                used_table = True
                add(core_scenario, f"{path} (core-fallback)")

    ordered_selected = [s for s in ordered if s in selected]
    if triggered_all:
        mode = "all"
    elif not ordered_selected:
        mode = "none"
    elif used_coverage and used_table:
        mode = "hybrid"
    elif used_coverage:
        mode = "coverage"
    else:
        mode = "table"

    return {
        "version": 1,
        "mode": mode,
        "scenarios": ordered_selected,
        "reasons": {s: reasons[s] for s in ordered_selected},
        "ignoredPaths": sorted(set(ignored)),
        "unmappedSources": sorted(set(unmapped_sources)),
    }


def read_paths_from_stream(stream, nul_delimited=False):
    raw = stream.read()
    if nul_delimited:
        return [item for item in raw.split("\0") if item]
    return [line.strip() for line in raw.splitlines() if line.strip()]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", help="changed repository paths (reads stdin when omitted)")
    parser.add_argument("--coverage-index", type=Path, default=None, help="optional '<source> <scenario>' coverage index")
    parser.add_argument("-z", "--nul", action="store_true", help="read NUL-delimited paths from stdin (git diff -z)")
    parser.add_argument("--json", action="store_true", help="emit structured JSON selection report")
    args = parser.parse_args(argv)

    paths = list(args.paths) if args.paths else read_paths_from_stream(sys.stdin, nul_delimited=args.nul)
    result = select_scenarios(paths, coverage_index=args.coverage_index)
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        for scenario_id in result["scenarios"]:
            print(scenario_id)
    return 0


if __name__ == "__main__":
    sys.exit(main())
