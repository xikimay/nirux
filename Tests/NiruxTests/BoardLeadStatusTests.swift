import XCTest
@testable import Nirux

@MainActor
final class BoardLeadStatusTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let shell: NiruxShellView
        let lead: WorkspaceState
        let store = MissionStore(persistsToDisk: false)
        let claude: ColumnState
        let codex: ColumnState
        let worker: WorkspaceState
        var claudeProcess = ForegroundProcess(instance: .init(pid: 1001, startedAt: 10), name: "claude", arguments: ["claude"])
        var codexProcess = ForegroundProcess(instance: .init(pid: 1002, startedAt: 20), name: "codex", arguments: ["codex"])

        init(_ harness: UIFlowHarness) throws {
            shell = harness.shell
            worker = try XCTUnwrap(shell.activeWorkspace)
            shell.addWorkspace(title: "Lead", cwd: harness.repo, profileID: worker.profileID, isLead: true)
            lead = try XCTUnwrap(shell.activeWorkspace)
            claude = try XCTUnwrap(lead.columns.first)
            lead.addColumn()
            codex = try XCTUnwrap(lead.columns.last)
            _ = claude.pty?.applyAgentHook(.init(
                kind: .claude, name: .stopFailure, emitterProcess: claudeProcess.instance, detail: "429", errorKind: "rate_limit", timestamp: 30
            ), isUserFocused: false)
            report(.working)
        }

        func report(_ state: AgentProgramStatus.State, message: String? = nil) {
            codex.pty?.noteCodexStatus(.init(state: state, kind: nil, message: message, process: "codex"), from: codexProcess.instance)
        }

        func route(
            to column: ColumnState?, child: String? = nil, parent: String? = nil, oneWay: Bool = false
        ) throws -> Mission {
            try XCTUnwrap(store.create(.init(
                id: UUID().uuidString, parentWorkspaceID: parent ?? lead.id, parentAgentUUID: column?.agentUUID ?? UUID().uuidString,
                childWorkspaceID: child ?? worker.id, childAgentUUID: UUID().uuidString, childAgentKind: "claude", branch: "fixture task",
                reportsToLead: !oneWay, oneWay: oneWay
            ), enabled: true, now: 100))
        }

        func event(_ kind: MissionEvent.Kind, for mission: Mission, at time: TimeInterval) throws -> MissionStore.AcceptedEvent {
            try XCTUnwrap(store.accept(.init(
                id: UUID().uuidString, missionID: mission.id, childWorkspaceID: mission.childWorkspaceID,
                childAgentUUID: mission.childAgentUUID, kind: kind, message: "fixture", timestamp: time
            ), enabled: true))
        }

        func header(at time: TimeInterval = 200, showsCodex: Bool = true) -> BoardStagesView.Lead {
            var front = [ObjectIdentifier(claude): claudeProcess]
            if showsCodex { front[ObjectIdentifier(codex)] = codexProcess }
            let columns = lead.columns.enumerated().map { index, column in
                shell.sidebarColumnInfo(
                    column, at: index, isUserFocused: false, agentStatus: column.pty?.cachedAgentState ?? .idle,
                    foregroundProcess: front[ObjectIdentifier(column)], approvalHold: nil, missionQuestion: nil,
                    showsDialog: false, snapshot: ProcessSnapshot(entries: []), now: time
                )
            }
            return shell.boardLeadStatus(of: lead, columns: columns, foreground: front, now: time, store: store)
        }
    }

    func testHandoffShowsTheRoutedTerminalAndKeepsFailuresAttributed() throws {
        try UIFlowHarness.run { harness in
            var fixture = try Fixture(harness)
            let single = fixture.header(showsCodex: false)
            XCTAssertEqual(single.text, "Lead · Claude Code · Stopped on an API error")
            XCTAssertEqual(single.state, .failed)
            XCTAssertTrue(single.tooltip.contains("Needs a fix in the terminal"))
            XCTAssertEqual(fixture.header().text, "Lead · Active session unclear")

            let old = try fixture.route(to: fixture.claude)
            let report = try fixture.event(.completed, for: old, at: 150)
            XCTAssertTrue(fixture.store.markTyped(report, at: 151))
            _ = try fixture.route(to: fixture.codex)
            _ = try fixture.route(to: fixture.claude, oneWay: true)
            _ = try fixture.route(to: fixture.claude, parent: UUID().uuidString)
            let working = fixture.header()
            XCTAssertEqual(working.text, "Lead · Codex · Working")
            XCTAssertEqual(working.state, .working)
            XCTAssertEqual(working.columnID, fixture.codex.id)
            XCTAssertTrue(working.tooltip.contains("Claude Code (terminal 1) · Stopped on an API error (no reporting Missions)"))

            fixture.report(.error, message: "Service unavailable")
            XCTAssertEqual(fixture.header().state, .failed)
            XCTAssertTrue(fixture.header().tooltip.contains("Service unavailable"))
            fixture.codexProcess = .init(instance: .init(pid: 1002, startedAt: 190), name: "codex", arguments: ["codex"])
            XCTAssertEqual(fixture.header().text, "Lead · Codex · Status unknown", "the old process's error cannot follow a reused PID")
            fixture.report(.idle)
            XCTAssertEqual(fixture.header().text, "Lead · Codex · Idle")
        }
    }

    func testSplitAndMissingDestinationsShowWhichTasksAreAffected() throws {
        try UIFlowHarness.run { harness in
            let fixture = try Fixture(harness)
            _ = try fixture.route(to: fixture.codex)
            fixture.shell.addWorkspace(title: "Review notes", cwd: harness.repo, profileID: fixture.lead.profileID)
            let notes = try XCTUnwrap(fixture.shell.activeWorkspace)
            _ = try fixture.route(to: fixture.claude, child: notes.id)
            let split = fixture.header()
            XCTAssertEqual(split.text, "Lead · Missions report to multiple sessions (Claude Code, Codex)")
            XCTAssertEqual(split.state, .idle)
            XCTAssertNil(split.columnID)
            XCTAssertTrue(split.tooltip.contains("Claude Code (terminal 1) · Stopped on an API error — Review notes"))
            XCTAssertTrue(split.tooltip.contains("Codex (terminal 2) · Working — " + fixture.worker.title))

            fixture.report(.error)
            XCTAssertEqual(fixture.header().state, .failed, "every known destination stopped")
            fixture.report(.working)
            _ = try fixture.route(to: nil)
            let unknown = fixture.header()
            XCTAssertEqual(unknown.text, "Lead · Missions report to multiple sessions (Claude Code, Codex, unknown destination)")
            XCTAssertTrue(unknown.tooltip.contains("Unidentified terminal — " + fixture.worker.title))
            XCTAssertNil(unknown.columnID)
        }
    }

    func testUnknownRouteAndClosedChildQuestionDoNotElectTheHealthyTerminal() throws {
        try UIFlowHarness.run { harness in
            let fixture = try Fixture(harness)
            _ = try fixture.route(to: fixture.codex)
            let closedChild = UUID().uuidString
            let other = try fixture.route(to: nil, child: closedChild)
            let question = try fixture.event(.question, for: other, at: 105)
            XCTAssertEqual(fixture.header().text, "Lead · Mission destination unknown")
            XCTAssertNotNil(fixture.store.handToUser(questionID: question.event.id, because: "User decides", now: 110))
            XCTAssertEqual(fixture.header().text, "Lead · Codex · Working")
        }
    }

    func testAReplacedClaudeDoesNotInheritThePreviousProcessFailure() throws {
        try UIFlowHarness.run { harness in
            var fixture = try Fixture(harness)
            _ = try fixture.route(to: fixture.claude)
            fixture.claudeProcess = .init(instance: .init(pid: 1001, startedAt: 60), name: "claude", arguments: ["claude"])
            XCTAssertEqual(fixture.header().text, "Lead · Claude Code · Idle")
        }
    }

    func testClosedChildReportExpiresForClaudeAndWaitsForCodexReceipt() throws {
        try UIFlowHarness.run { harness in
            let fixture = try Fixture(harness)
            let closedChild = UUID().uuidString
            let deadline = 150 + MissionEventCLI.parentMessageLifetime
            let claude = try fixture.route(to: fixture.claude, child: closedChild)
            _ = try fixture.event(.completed, for: claude, at: 150)
            XCTAssertEqual(fixture.header(at: deadline - 1).columnID, fixture.claude.id)
            XCTAssertEqual(fixture.header(at: deadline).text, "Lead · Active session unclear")

            let codex = try fixture.route(to: fixture.codex, child: closedChild)
            let report = try fixture.event(.completed, for: codex, at: 150)
            let before = fixture.store.missions
            XCTAssertEqual(fixture.header(at: deadline + 100).columnID, fixture.codex.id)
            XCTAssertEqual(fixture.store.missions, before, "rendering leaves the unread report in the parent's inbox")
            let receipt = MissionEvent(
                id: UUID().uuidString, missionID: codex.id, childWorkspaceID: closedChild, childAgentUUID: codex.childAgentUUID,
                parentWorkspaceID: fixture.lead.id, parentAgentUUID: fixture.codex.agentUUID, kind: .acknowledged,
                message: "acknowledged", inReplyTo: report.event.id, timestamp: deadline + 101
            )
            guard case .accepted = fixture.store.process(receipt, enabled: true) else { return XCTFail("receipt rejected") }
            XCTAssertEqual(fixture.header(at: deadline + 102).text, "Lead · Active session unclear")
        }
    }
}
