"""Each single revert must build and produce a failure in the intended XCTest."""
import re
import subprocess
from pathlib import Path

suite = "WaitingTaskFlowTests"
merge = "testMergeStartsTheRestoredRowFromTheNewRemoteTipOnce"
recover = "testInterruptedStartAndMissingRepositoryStayActionableAfterRestore"
retry = "testFailedDependencyCanBeRepointedOrStartedManually"
views = Path("Sources/Nirux/Views")
mutations = [
    ("fresh base", "NiruxShellView+WaitingTasks.swift", "branch: branch), fetchesFirst: true", "branch: branch), fetchesFirst: false", merge),
    ("saved template", "NiruxShellView+WaitingTasks.swift", "start.description + note, template: start.template", "start.description + note, template: nil", merge),
    ("bulk cleanup", "NiruxShellView+WorktreeCleanup.swift", "&& !workspace.isWaitingTask && !covered", "&& !covered", merge),
    ("interrupted creation", "NiruxShellView+MergeWaits.swift", "if let branch = task.waitingStart?.startingBranch {", "if let branch = task.waitingStart?.startingBranch, branch.isEmpty {", recover),
    ("failed dependency", "NiruxShellView+MergeWaits.swift", "return failWaitingTask(holder, reason: wait.sentence(failure))", "return", retry),
    ("dependency cycle", "NiruxShellView+WaitingTasks.swift", 'return answer("That dependency would make tasks wait on each other.", true)', "break", retry),
    ("closed placeholder", "NiruxShellView+LeadTaskTools.swift", 'closeLeadTask(task)\n            return answer("Closed “\\(title)”.", false)', 'return answer("Closed “\\(title)”.", false)', retry),
]
for label, filename, old, new, method in mutations:
    print(f"::group::Revert {label}", flush=True)
    source = views / filename
    original = source.read_text()
    assert original.count(old) == 1, (label, original.count(old))
    try:
        source.write_text(original.replace(old, new))
        result = subprocess.run(["swift", "test", "--filter", f"{suite}/{method}"],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
        failures = [line for line in result.stdout.splitlines() if ": error:" in line and method in line]
        if result.returncode == 0 or not failures or not re.search(r"Executed 1 test, with [1-9]", result.stdout):
            print(result.stdout, flush=True)
            raise SystemExit(f"Missing XCTest failure for {label}")
        print("\n".join(failures), flush=True)
    finally:
        source.write_text(original)
    print("::endgroup::", flush=True)
print(f"XCTest caught all {len(mutations)} single reverts", flush=True)
