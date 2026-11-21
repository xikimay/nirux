"""Require an assertion failure in the designated XCTest for each isolated change."""
from pathlib import Path
import re
import subprocess

model = Path("Sources/Nirux/Model")
view = Path("Sources/Nirux/Views")
waiting = model / "BoardStages+Waiting.swift"
line = "BoardStagesLineTests/testWaitingStartNamesTheMergeAndHasNoWorktreeActionsOrStation"
units = "BoardStagesUnitsTests/testWaitingChainsStayWithTheirTaskAndKeepStackNumbersInBothOrders"
render = "BoardStagesViewTests/testWaitingLinesRenderInOrderAndFailuresAreAmber"
flow = "BoardStagesContentFlowTests/testWaitingWorkspaceFollowsItsDependencyAcrossSectionsUntilRelease"
mutations = [
    ("name the recorded PR", waiting, 'phrase = "Starts after ', 'phrase = "Wait for ', line),
    ("amber failed start", waiting, "state = .needsYou", "state = .waiting", line),
    ("no cleanup action", waiting, 'pullRequest: "", since: nil)', 'pullRequest: "", since: nil, menu: [.cleanUp(path: "/unused", blocked: nil)])', line),
    ("keep dependent beside its task across repositories", waiting, "var assigned = locations", "var assigned = [String: String]()", units),
    ("include the next wait in a chain", waiting, "appendChildren(of: child.id, to: &following)", "// dropped", units),
    ("hold a just-merged dependency in the list", model / "BoardStages+Units.swift", "lines[index].following.isEmpty && ", "", units),
    ("draw the waiting line", view / "BoardStagesView.swift", "for waiting in line.following { add(waiting, link: .none) }", "", render),
    ("exclude the placeholder from worktree rows", view / "ProjectBoardController+Stages.swift", "inputs.workspaces.filter { !waitingIDs.contains($0.id) }", "inputs.workspaces", flow),
    ("keep a failed wait visible before git reads", view / "ProjectBoardController+Stages.swift", "content.message?.showsWaitingTasks = true", "content.message?.showsWaitingTasks = false", flow),
]
for label, source, old, new, test in mutations:
    original = source.read_text()
    assert original.count(old) == 1, (label, original.count(old))
    print(f"::group::Revert {label}", flush=True)
    try:
        source.write_text(original.replace(old, new))
        result = subprocess.run(["swift", "test", "--filter", test], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        errors = [row for row in result.stdout.splitlines() if ": error:" in row and test.split("/")[1] in row]
        if result.returncode == 0 or not errors or not re.search(r"Executed 1 test, with [1-9]", result.stdout):
            print(result.stdout, flush=True)
            raise SystemExit(f"Missing XCTest failure for {label}")
        print(errors[0], flush=True)
    finally:
        source.write_text(original)
    print("::endgroup::", flush=True)
print(f"XCTest caught all {len(mutations)} single reverts")
