import XCTest
@testable import Nirux

final class WorkspaceClosePolicyTests: XCTestCase {
    private func context(
        workspaces: Int = 2,
        columns: Int = 1,
        busy: Bool = false,
        worktree: Bool = false
    ) -> WorkspaceClosePolicy.Context {
        WorkspaceClosePolicy.Context(
            totalWorkspaceCount: workspaces,
            columnCount: columns,
            hasBusyAgent: busy,
            isWorktreeBacked: worktree
        )
    }

    func testLastWorkspaceIsBlockedEvenWhenBusy() {
        XCTAssertEqual(WorkspaceClosePolicy.decision(for: context(workspaces: 1)), .blocked)
        XCTAssertEqual(
            WorkspaceClosePolicy.decision(for: context(workspaces: 1, columns: 3, busy: true)),
            .blocked
        )
        XCTAssertFalse(WorkspaceClosePolicy.canClose(totalWorkspaceCount: 1))
        XCTAssertTrue(WorkspaceClosePolicy.canClose(totalWorkspaceCount: 2))
    }

    func testPlainSingleColumnWorkspaceClosesWithoutConfirmation() {
        XCTAssertEqual(WorkspaceClosePolicy.decision(for: context()), .close)
        // Worktree-backed alone is no reason for ceremony — nothing is lost.
        XCTAssertEqual(WorkspaceClosePolicy.decision(for: context(worktree: true)), .close)
    }

    func testBusyAgentRequiresConfirmation() {
        guard case .confirm(let details) = WorkspaceClosePolicy.decision(for: context(busy: true)) else {
            return XCTFail("expected .confirm")
        }
        XCTAssertTrue(details.contains { $0.contains("agent is still running") })
        XCTAssertFalse(details.contains { $0.contains("worktree") })
    }

    func testMultiColumnRequiresConfirmation() {
        guard case .confirm(let details) = WorkspaceClosePolicy.decision(for: context(columns: 3)) else {
            return XCTFail("expected .confirm")
        }
        XCTAssertTrue(details.contains { $0.contains("All 3 columns") })
    }

    func testWorktreeNoteAppendedOnlyWhenConfirming() {
        guard case .confirm(let details) = WorkspaceClosePolicy.decision(
            for: context(columns: 2, busy: true, worktree: true)
        ) else {
            return XCTFail("expected .confirm")
        }
        XCTAssertEqual(details.count, 3)
        XCTAssertEqual(details.last, "The git worktree stays on disk.")
    }
}
