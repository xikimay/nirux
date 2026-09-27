import XCTest
@testable import Nirux

final class WorkspaceClosePolicyTests: XCTestCase {
    private typealias LiveAgent = WorkspaceClosePolicy.LiveAgent

    private func agent(_ name: String = "claude", _ status: AgentStatus? = .idle) -> LiveAgent {
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
        XCTAssertNil(WorkspaceClosePolicy.columnConfirmation(for: nil))
    }

    func testColumnWithLiveAgentRequiresConfirmationInEveryStatus() {
        XCTAssertEqual(
            WorkspaceClosePolicy.columnConfirmation(for: agent("claude", .idle)),
            ["Claude is idle — closing the column ends its session."]
        )
        XCTAssertEqual(
            WorkspaceClosePolicy.columnConfirmation(for: agent("codex", .working)),
            ["Codex is working — closing the column ends its session."]
        )
        XCTAssertEqual(
            WorkspaceClosePolicy.columnConfirmation(for: agent("claude", .needsAttention)),
            ["Claude is waiting for you — closing the column ends its session."]
        )
        XCTAssertEqual(
            WorkspaceClosePolicy.columnConfirmation(for: agent("codex", nil)),
            ["Codex is running — closing the column ends its session."]
        )
    }

    func testDisplayNameFallsBackToProcessName() {
        XCTAssertEqual(agent("claude").displayName, "Claude")
        XCTAssertEqual(agent("codex").displayName, "Codex")
        XCTAssertEqual(agent("aider").displayName, "aider")
    }

    // MARK: - Status trust

    func testIdleIsOnlyTrustedWhenClaudeHooksDriveIt() {
        // Hook-driven Claude: idle means its turn ended.
        XCTAssertEqual(LiveAgent(processName: "claude", machineStatus: .idle, hookKind: "claude").status, .idle)
        // Output fallback: idle until the first keystroke, even while an
        // agent launched with a handover prompt works — don't claim idle.
        XCTAssertNil(LiveAgent(processName: "claude", machineStatus: .idle, hookKind: nil).status)
        XCTAssertNil(LiveAgent(processName: "codex", machineStatus: .idle, hookKind: "codex").status)
        // Busy states are kept — overstating activity only adds caution.
        XCTAssertEqual(LiveAgent(processName: "codex", machineStatus: .working, hookKind: nil).status, .working)
        XCTAssertEqual(
            LiveAgent(processName: "claude", machineStatus: .needsAttention, hookKind: "claude").status,
            .needsAttention
        )
    }

    // MARK: - Workspaces with a close in flight

    @MainActor
    private func makeStore(_ ids: [String]) -> WorkspaceStore {
        let store = WorkspaceStore()
        for id in ids {
            store.appendWorkspace(WorkspaceState(id: id, title: id, cwd: "/tmp/\(id)"), activate: false)
        }
        return store
    }

    @MainActor
    func testClosingWorkspacesDoNotCountAsRemaining() {
        // Regression: closeWorkspace keeps the workspace in the store for its
        // 0.35 s exit animation, so a quick second ⌘W saw two workspaces and
        // closed the last one too.
        let store = makeStore(["a", "b"])
        XCTAssertEqual(store.remainingWorkspaceCount, 2)
        store.workspaces[0].isClosing = true
        XCTAssertEqual(store.remainingWorkspaceCount, 1)
        XCTAssertFalse(WorkspaceClosePolicy.canClose(totalWorkspaceCount: store.remainingWorkspaceCount))
    }

    @MainActor
    func testFallbackSelectionSkipsClosingWorkspaces() {
        let store = makeStore(["a", "b", "c"])
        store.workspaces[0].isClosing = true
        // Closing "b": the previous neighbour "a" is on its way out too.
        XCTAssertEqual(store.fallbackIndexAfterClosingWorkspace(at: 1), 2)
        store.workspaces[2].isClosing = true
        XCTAssertNil(store.fallbackIndexAfterClosingWorkspace(at: 1))
    }
}
