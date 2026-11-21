import AppKit
import XCTest
@testable import Nirux

/// Restart Lead (NiruxShellView+Lead): once confirmed, the Lead's Claude
/// ends and a fresh conversation starts in the same column, launched as a
/// new Lead's is, its tasks still reporting to it.
@MainActor
final class LeadRestartFlowTests: XCTestCase {
    /// The Lead's shell running `command` as a child, `name`d: that process.
    private func run(_ command: String, named name: String = "claude", in column: ColumnState, harness: UIFlowHarness) throws -> ProcessInstance {
        let pty = try XCTUnwrap(column.pty)
        harness.waitUntil("its shell") { pty.shellPID != nil }
        pty.sendRaw("(\(command))\n")
        harness.waitUntil("its \(name)") { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == name }
        return try XCTUnwrap(pty.foregroundProcess(snapshot: ProcessSnapshot())).instance
    }

    func testRestartLeadStartsAFreshClaudeInItsColumn() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            shell.changeSpaceDefaults(spaceID: lead.space) { $0.claudeLaunchMode = .manual }
            let column = try XCTUnwrap(lead.workspace.leadTerminal)
            let pty = try XCTUnwrap(column.pty)
            let old = AgentStandIn()
            defer { old.remove() }
            let oldClaude = try run(old.command(), in: column, harness: harness)
            let shellBefore = pty.shellPID

            shell.requestRestartLead(spaceID: lead.space)
            XCTAssertEqual(harness.alerts.last, "Restart the Lead of “Tools”?")
            XCTAssertTrue(harness.alertDetails.last?.contains("launch mode (Manual)") == true, harness.alertDetails.last ?? "")
            XCTAssertEqual(harness.terminalRestarts, [], "cancelled")

            let fresh = AgentStandIn()
            defer { fresh.remove() }
            harness.restartedAgent = fresh.command()
            harness.alertResponses = [.alertSecondButtonReturn]
            shell.requestRestartLead(spaceID: lead.space)
            let command = try XCTUnwrap(harness.terminalRestarts.last)
            for part in ["--permission-mode default", NiruxShellView.shellQuotedArgument("--name=Lead · Tools"),
                         NiruxShellView.shellQuotedArgument(NiruxShellView.leadRestartPrompt), "--settings="] {
                XCTAssertTrue(command.contains(part), "\(part) in \(command)")
            }
            XCTAssertFalse(command.contains("--resume"), "a fresh conversation")
            harness.waitUntil("a fresh claude in its column") {
                pty.foregroundProcess(snapshot: ProcessSnapshot()).map { $0.name == "claude" && $0.instance != oldClaude } == true
            }
            XCTAssertNotEqual(ProcessInstance.running(pid: oldClaude.pid), oldClaude, "the one before ended")
            XCTAssertNotEqual(pty.shellPID, shellBefore)
            XCTAssertIdentical(lead.workspace.leadTerminal, column)
            XCTAssertEqual(column.agentUUID, lead.agentUUID, "its tasks' Mission parent")
        }
    }

    /// The confirmation names the mode it starts with, and what stops.
    func testTheConfirmationSaysWhatStops() {
        func details(_ status: AgentStatus?) -> [String] {
            NiruxShellView.leadRestartDetails(
                mode: .auto, agent: status.map { WorkspaceClosePolicy.LiveAgent(processName: "claude", status: $0) }
            )
        }
        XCTAssertTrue(details(nil)[0].contains("launch mode (Auto)"), details(nil)[0])
        XCTAssertEqual(details(nil).count, 2)
        XCTAssertEqual(details(.idle).count, 2)
        XCTAssertEqual(details(.working).last, "Claude is working: its turn stops.")
        XCTAssertEqual(details(.needsAttention).last, "Claude is waiting for you: that goes unanswered.")
    }

    /// A question typed into the Lead before it restarted stays with it (the
    /// new one reads it in list_tasks) instead of coming to the user.
    func testAQuestionTypedIntoTheLeadStaysWithTheRestartedOne() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            let column = try XCTUnwrap(lead.workspace.leadTerminal)
            let old = AgentStandIn()
            defer { old.remove() }
            _ = try run(old.command(), in: column, harness: harness)
            let workspaceID = UUID().uuidString
            let mission = try XCTUnwrap(MissionStore.shared.create(MissionCreationRequest(
                id: UUID().uuidString, parentWorkspaceID: lead.workspace.id, parentAgentUUID: lead.agentUUID,
                childWorkspaceID: workspaceID, childAgentUUID: UUID().uuidString, childAgentKind: "claude",
                branch: "feat/export", reportsToLead: true
            ), enabled: true))
            shell.addWorkspace(
                title: "Export CSV", cwd: harness.repo, profileID: lead.space, workspaceID: workspaceID,
                initialAgentUUID: mission.childAgentUUID, missionID: mission.id, reportsToLead: true
            )
            let task = try XCTUnwrap(shell.workspaces.first { $0.id == workspaceID }?.columns.first)
            let question = MissionEvent(
                id: UUID().uuidString, missionID: mission.id, childWorkspaceID: workspaceID, childAgentUUID: mission.childAgentUUID,
                kind: .question, message: "Keep the old date= parameter?", timestamp: Date().timeIntervalSince1970
            )
            guard case .accepted = MissionStore.shared.process(question, enabled: false) else { return XCTFail("not asked") }
            let current = try XCTUnwrap(MissionStore.shared.missions.first { $0.id == mission.id })
            XCTAssertTrue(MissionStore.shared.markTyped(MissionStore.AcceptedEvent(mission: current, event: question)))

            let fresh = AgentStandIn()
            defer { fresh.remove() }
            harness.restartedAgent = fresh.command()
            harness.alertResponses = [.alertSecondButtonReturn]
            shell.requestRestartLead(spaceID: lead.space)
            let pty = try XCTUnwrap(column.pty)
            harness.waitUntil("the fresh claude") {
                pty.foregroundProcess(snapshot: ProcessSnapshot()).map { $0.name == "claude" && $0.instance.startedAt > question.timestamp } == true
            }
            let now = Date().timeIntervalSince1970
            let foreground = { (column: ColumnState) in column.pty?.foregroundProcess(snapshot: ProcessSnapshot()) }
            _ = shell.missionQuestions(foreground: foreground, now: now)
            let later = shell.missionQuestions(foreground: foreground, now: now + NiruxShellView.missionParentGrace + 5)
            XCTAssertNotNil(later[ObjectIdentifier(task)], "it still waits")
            XCTAssertNil(later[ObjectIdentifier(task)]?.handOff, "with the Lead, not the user")
        }
    }

    /// A restored Lead whose Claude hasn't resumed starts the fresh one, not
    /// the conversation it would have resumed.
    func testARestoredLeadNotResumedYetStartsFresh() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            // Off screen, so that it doesn't resume once restored.
            shell.selectProfile(WorkspaceProfile.defaultID)
            shell.saveState()
            var state = try XCTUnwrap(Persistence.load())
            let saved = try XCTUnwrap(state.workspaces.firstIndex { $0.id == lead.workspace.id })
            let claudeColumn = try XCTUnwrap(state.workspaces[saved].columns.firstIndex { $0.agentUUID == lead.agentUUID })
            state.workspaces[saved].columns[claudeColumn].columnType = .claudeCode
            state.workspaces[saved].columns[claudeColumn].claudeSessionID = UUID().uuidString
            XCTAssertTrue(Persistence.save(state))
            shell.restoreState()
            let restored = try XCTUnwrap(shell.leadWorkspace(inSpace: lead.space))
            let column = try XCTUnwrap(restored.leadTerminal)
            XCTAssertTrue(column.isAwaitingResume)

            let fresh = AgentStandIn()
            defer { fresh.remove() }
            harness.restartedAgent = fresh.command()
            harness.alertResponses = [.alertSecondButtonReturn]
            shell.requestRestartLead(spaceID: lead.space)
            XCTAssertFalse(column.isAwaitingResume)
            XCTAssertEqual(harness.terminalRestarts.count, 1)
            XCTAssertEqual(harness.restoredAgentLaunches, [], "not the conversation before")
            let pty = try XCTUnwrap(column.pty)
            harness.waitUntil("the fresh claude") { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
        }
    }

    /// A Lead whose Claude column closed before a Lead kept it gets a new one.
    func testALeadWithoutItsClaudeColumnGetsOne() throws {
        try UIFlowHarness.run { harness in
            let lead = try harness.makeLead()
            lead.workspace.leadAgentUUID = nil
            let launches = harness.agentLaunches.count
            harness.alertResponses = [.alertSecondButtonReturn]
            harness.shell.requestRestartLead(spaceID: lead.space)
            let column = try XCTUnwrap(lead.workspace.leadTerminal)
            XCTAssertNotEqual(column.agentUUID, lead.agentUUID)
            XCTAssertEqual(lead.workspace.columns.count, 3)
            XCTAssertEqual(harness.agentLaunches.count, launches + 1)
            XCTAssertTrue(harness.agentLaunches.last?.contains(NiruxShellView.shellQuotedArgument(NiruxShellView.leadRestartPrompt)) == true)
            XCTAssertEqual(harness.terminalRestarts, [])
        }
    }

    /// A program in its terminal that outlives the hang-up: nothing starts,
    /// and a toast says so.
    func testNothingStartsWhileTheLeadsProgramsRun() throws {
        try UIFlowHarness.run { harness in
            let lead = try harness.makeLead()
            let column = try XCTUnwrap(lead.workspace.leadTerminal)
            // nohup: the shell ends on the hang-up, the program it runs doesn't.
            let stuck = try run("nohup /bin/sleep 600 > /dev/null 2>&1", named: "sleep", in: column, harness: harness)
            defer { kill(stuck.pid, SIGKILL) }
            let fresh = AgentStandIn()
            defer { fresh.remove() }
            harness.restartedAgent = fresh.command()
            harness.alertResponses = [.alertSecondButtonReturn]
            harness.shell.requestRestartLead(spaceID: lead.space)
            let pty = try XCTUnwrap(column.pty)
            harness.waitUntil("its shell to end") { pty.hasExited }
            XCTAssertFalse(column.isShowingShellExit, "no Restart Shell while Nirux restarts it")
            harness.waitUntil("the toast", timeout: NiruxShellView.exitTimeout + 20) {
                harness.shell.toast?.message.hasPrefix("The Lead’s Claude didn’t stop") == true
            }
            XCTAssertTrue(harness.shell.toast?.message.contains("(sleep)") == true, harness.shell.toast?.message ?? "")
            XCTAssertEqual(column.pty?.hasExited, true, "its terminal stays ended")
            XCTAssertTrue(column.isShowingShellExit)
            XCTAssertEqual(fresh.input, "", "no Claude started")
        }
    }

    /// The Space menu offers it while its space has a Lead, as Space
    /// Settings › Lead does.
    func testRestartLeadFromTheSpaceMenuAndSpaceSettings() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let bar = MenuBar(shell: shell)
            XCTAssertFalse(bar.isEnabled(["Space", NiruxShellView.restartLeadTitle]), "General has no Lead")
            let lead = try harness.makeLead()
            XCTAssertTrue(bar.isEnabled(["Space", NiruxShellView.restartLeadTitle]))
            bar.run(["Space", NiruxShellView.restartLeadTitle])
            XCTAssertEqual(harness.alerts.last, "Restart the Lead of “Tools”?")

            shell.showSpaceSettings(profileID: lead.space, tab: .lead)
            let pane = try XCTUnwrap(shell.spaceSettings?.lead)
            XCTAssertFalse(pane.restartButton.isHidden)
            pane.restartButton.performClick(nil)
            XCTAssertEqual(harness.alerts.count, 2)
            harness.alertResponses = [.alertSecondButtonReturn]
            shell.stopLead(spaceID: lead.space)
            harness.waitUntil("the Lead to close") { shell.leadWorkspace(inSpace: lead.space) == nil }
            harness.waitUntil("the pane to say so") { pane.restartButton.isHidden }
        }
    }
}
