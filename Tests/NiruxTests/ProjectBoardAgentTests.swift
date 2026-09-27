import XCTest
@testable import Nirux

/// What the board's Agent column says (docs/project-board.md, section 2),
/// from a status machine fed with hook events on an injected clock.
final class ProjectBoardAgentTests: XCTestCase {
    private var machine = AgentStatusMachine()
    private let t0: TimeInterval = 1_000

    private func apply(_ name: AgentHookEvent.Name, at offset: TimeInterval, focused: Bool, tool: String? = nil) {
        _ = machine.apply(AgentHookEvent(
            kind: .claude, name: name, sessionID: "lead", detail: tool, toolName: tool, toolKey: tool.map { "\($0)-1" },
            timestamp: t0 + offset
        ), isUserFocused: focused)
    }

    private func date(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: t0 + offset) }

    /// The board's reading of the column, with `claude` in front.
    private func boardState(agentInFront: Bool = true, hasAgent: Bool = true) -> ProjectBoard.AgentState {
        ProjectBoard.agentState(
            stuck: nil, hasAgent: hasAgent, agentInFront: agentInFront,
            status: machine.state, openDialog: machine.openDialogs.first?.reason
        )
    }

    private func askPermission(focused: Bool) {
        _ = machine.tick(fgName: "claude", isUserFocused: focused, now: date(0))
        apply(.sessionStart, at: 0, focused: focused)
        apply(.userPromptSubmit, at: 1, focused: focused)
        apply(.preToolUse, at: 2, focused: focused, tool: "Bash")
        apply(.permissionRequest, at: 2, focused: focused, tool: "Bash")
    }

    func testAnOpenDialogInTheFocusedColumnReadsAsWaiting() {
        askPermission(focused: true)
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: true, now: date(3)), .idle,
                       "the status alone reads idle while the user looks at the dialog")
        XCTAssertEqual(boardState(), .waiting(.permission(tool: "Bash", summary: nil)))
        XCTAssertEqual(boardState().label, "waiting (permission · Bash)")
    }

    func testADialogApprovedWhileItsToolRunsReadsAsWorking() {
        askPermission(focused: false)
        machine.noteKeystroke(now: date(3))
        machine.noteRead(now: date(5))
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: true, now: date(5.5)), .working)
        XCTAssertEqual(machine.openDialogs.count, 1, "it stays pending until the tool ends")
        XCTAssertEqual(boardState(), .working(duration: nil))

        apply(.postToolUse, at: 20, focused: true, tool: "Bash")
        XCTAssertTrue(machine.openDialogs.isEmpty)
        XCTAssertEqual(boardState(), .working(duration: nil))
    }

    func testAFinishedTurnOutOfFocusReadsAsIdle() {
        _ = machine.tick(fgName: "claude", isUserFocused: false, now: date(0))
        apply(.sessionStart, at: 0, focused: false)
        apply(.userPromptSubmit, at: 1, focused: false)
        apply(.stop, at: 9, focused: false)
        XCTAssertEqual(machine.state, .needsAttention)
        XCTAssertEqual(boardState(), .idle)
        XCTAssertEqual(boardState().label, "idle", "not “done”: that is a merged or closed pull request")
    }

    func testDialogsLeftByAnAgentNoLongerInFrontDontReadAsWaiting() {
        askPermission(focused: false)
        XCTAssertEqual(boardState(agentInFront: false, hasAgent: true), .idle, "suspended behind a shell")
        XCTAssertEqual(boardState(agentInFront: false, hasAgent: false), .none, "gone")
    }

    func testStuckStatesWinAsTheSidebarShowsThem() {
        let permission = AgentAttentionReason.permission(tool: "Bash", summary: "git push")
        let state = { (stuck: SidebarStuckState) in
            ProjectBoard.agentState(stuck: stuck, hasAgent: true, agentInFront: true, status: .working, openDialog: nil)
        }
        XCTAssertEqual(state(.waiting(permission, duration: "12m")), .waitingLong(permission, duration: "12m"))
        XCTAssertEqual(state(.waiting(permission, duration: "12m")).label, "waiting 12m (permission · Bash)")
        let failed = state(.stoppedOnError(kind: "overloaded", detail: "529", failedAt: 5, resume: .offered))
        XCTAssertEqual(failed, .stoppedOnError(kind: "overloaded", resume: .offered))
        XCTAssertEqual(failed.label, "stopped on error (overloaded)")
        XCTAssertEqual(
            ProjectBoard.agentState(
                stuck: .exitedMidTurn(processName: "claude"), hasAgent: false, agentInFront: false,
                status: .idle, openDialog: nil
            ),
            .exitedMidTurn(processName: "claude")
        )
    }

    func testARowShowsItsMostUrgentColumn() {
        let columns: [ProjectBoard.AgentState] = [
            .idle, .working(duration: "2m"), .waiting(.question(nil)), .none,
            .stoppedOnError(kind: nil, resume: .unavailable), .exitedMidTurn(processName: "claude")
        ]
        let agents = columns.enumerated().map { ProjectBoard.Agent(state: $1, workspaceID: "ws\($0)") }
        XCTAssertEqual(ProjectBoard.Agent.mostUrgent(agents).workspaceID, "ws4", "failures first")
        XCTAssertEqual(ProjectBoard.Agent.mostUrgent(Array(agents.prefix(4))).workspaceID, "ws2", "then dialogs")
        XCTAssertEqual(ProjectBoard.Agent.mostUrgent(Array(agents.prefix(2))).workspaceID, "ws1", "then work")
        XCTAssertEqual(ProjectBoard.Agent.mostUrgent([]).state, .none)
    }

    // MARK: - Buttons

    private func row(agent: ProjectBoard.Agent, workspaces: [String] = ["ws"], path: String? = "/p/w.fix") -> ProjectBoard.Row {
        ProjectBoard.Row(
            group: .active, worktreePath: path, branch: "fix", detachedHead: nil,
            workspaces: workspaces.map { ProjectBoard.WorkspaceRef(id: $0, title: $0, isInactive: false) },
            pullRequest: nil, agent: agent, folder: nil
        )
    }

    func testResumeIsOfferedOnlyWhenSidebarWouldOfferIt() {
        let column = UUID()
        let offered = ProjectBoardView.actions(for: row(agent: ProjectBoard.Agent(
            state: .stoppedOnError(kind: "overloaded", resume: .offered), workspaceID: "ws", columnID: column, failedAt: 42
        )))
        XCTAssertEqual(offered.map { $0.title }, ["Resume", "Focus", "Clean Up…"], "the most urgent first")
        XCTAssertEqual(offered[1].action, .focus(workspaceID: "ws", columnID: column))
        XCTAssertEqual(offered[0].action, .resumeFailed(workspaceID: "ws", columnID: column, failedAt: 42))
        XCTAssertEqual(offered[2].action, .cleanUp(path: "/p/w.fix"))

        let typed = ProjectBoardView.actions(for: row(agent: ProjectBoard.Agent(
            state: .stoppedOnError(kind: "overloaded", resume: .userTyped), workspaceID: "ws", columnID: column, failedAt: 42
        )))
        XCTAssertNil(typed[0].action, "shown disabled")
        XCTAssertEqual(typed[0].tooltip, SidebarStuckState.Resume.userTyped.status)

        let exited = ProjectBoardView.actions(for: row(agent: ProjectBoard.Agent(
            state: .exitedMidTurn(processName: "claude"), workspaceID: "ws", columnID: column
        )))
        XCTAssertEqual(exited[0].action, .resumeExited(workspaceID: "ws", columnID: column))

        let unopened = ProjectBoardView.actions(for: row(agent: ProjectBoard.Agent(), workspaces: []))
        XCTAssertEqual(unopened.map { $0.action }, [.open(path: "/p/w.fix", title: "fix"), .cleanUp(path: "/p/w.fix")])
        XCTAssertEqual(ProjectBoardView.actions(for: row(agent: ProjectBoard.Agent(), workspaces: [], path: nil)).count, 0)
    }
}
