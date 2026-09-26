import XCTest
@testable import Nirux

final class WorkspaceClosePolicyTests: XCTestCase {
    private typealias LiveAgent = WorkspaceClosePolicy.LiveAgent

    private func agent(_ name: String = "claude", _ status: AgentStatus = .idle) -> LiveAgent {
        LiveAgent(processName: name, status: status)
    }

    private func context(
        workspaces: Int = 2,
        columns: Int = 1,
        agents: [LiveAgent] = [],
        worktree: Bool = false
    ) -> WorkspaceClosePolicy.Context {
        WorkspaceClosePolicy.Context(
            totalWorkspaceCount: workspaces,
            columnCount: columns,
            liveAgents: agents,
            isWorktreeBacked: worktree
        )
    }

    private func details(_ decision: WorkspaceClosePolicy.Decision) -> [String]? {
        guard case .confirm(let details) = decision else { return nil }
        return details
    }

    // MARK: - Workspace

    func testLastWorkspaceIsBlockedEvenWithLiveAgents() {
        XCTAssertEqual(WorkspaceClosePolicy.decision(for: context(workspaces: 1)), .blocked)
        XCTAssertEqual(
            WorkspaceClosePolicy.decision(for: context(workspaces: 1, columns: 3, agents: [agent("claude", .working)])),
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

    func testIdleAgentRequiresConfirmation() {
        // Regression: the sidebar used to close a workspace whose agent sat
        // idle at its prompt without asking — ⌘W on the last column now
        // goes through the same policy, so this is the ⌘W guard too.
        let lines = details(WorkspaceClosePolicy.decision(for: context(agents: [agent("claude", .idle)])))
        XCTAssertEqual(lines, ["Claude is idle — closing the workspace ends its session."])
    }

    func testAgentStatusIsNamedInTheDetail() {
        let working = details(WorkspaceClosePolicy.decision(for: context(agents: [agent("codex", .working)])))
        XCTAssertEqual(working, ["Codex is working — closing the workspace ends its session."])
        let waiting = details(WorkspaceClosePolicy.decision(for: context(agents: [agent("claude", .needsAttention)])))
        XCTAssertEqual(waiting, ["Claude is waiting for you — closing the workspace ends its session."])
    }

    func testSeveralAgentsAreListedTogether() {
        let lines = details(WorkspaceClosePolicy.decision(for: context(
            columns: 2,
            agents: [agent("claude", .working), agent("codex", .idle)]
        )))
        XCTAssertEqual(lines, [
            "2 agents are running (Claude working, Codex idle) — closing the workspace ends their sessions.",
            "All 2 columns will be closed."
        ])
    }

    func testMultiColumnRequiresConfirmation() {
        let lines = details(WorkspaceClosePolicy.decision(for: context(columns: 3)))
        XCTAssertEqual(lines, ["All 3 columns will be closed."])
    }

    func testWorktreeNoteAppendedOnlyWhenConfirming() {
        let lines = details(WorkspaceClosePolicy.decision(
            for: context(columns: 2, agents: [agent()], worktree: true)
        ))
        XCTAssertEqual(lines?.count, 3)
        XCTAssertEqual(lines?.last, "The git worktree stays on disk.")
    }

    // MARK: - Column

    func testColumnWithoutAgentClosesWithoutConfirmation() {
        XCTAssertEqual(WorkspaceClosePolicy.columnDecision(agent: nil), .close)
    }

    func testColumnWithLiveAgentRequiresConfirmationInEveryStatus() {
        XCTAssertEqual(
            details(WorkspaceClosePolicy.columnDecision(agent: agent("claude", .idle))),
            ["Claude is idle — closing the column ends its session."]
        )
        XCTAssertEqual(
            details(WorkspaceClosePolicy.columnDecision(agent: agent("codex", .working))),
            ["Codex is working — closing the column ends its session."]
        )
        XCTAssertEqual(
            details(WorkspaceClosePolicy.columnDecision(agent: agent("claude", .needsAttention))),
            ["Claude is waiting for you — closing the column ends its session."]
        )
    }

    func testDisplayNameFallsBackToProcessName() {
        XCTAssertEqual(agent("claude").displayName, "Claude")
        XCTAssertEqual(agent("codex").displayName, "Codex")
        XCTAssertEqual(agent("aider").displayName, "aider")
    }
}
