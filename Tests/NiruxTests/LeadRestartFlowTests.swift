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
        // The login shell can still be in canonical mode when the full launch arguments exceed MAX_CANON.
        let script = URL(fileURLWithPath: harness.root).appendingPathComponent("lead-worker-\(UUID().uuidString).sh")
        try command.write(to: script, atomically: true, encoding: .utf8)
        harness.waitUntil("its shell") { pty.shellPID != nil }
        pty.sendRaw("(. \(NiruxShellView.shellQuotedArgument(script.path)))\n")
        harness.waitUntil("its \(name)") { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == name }
        return try XCTUnwrap(pty.foregroundProcess(snapshot: ProcessSnapshot())).instance
    }

    private func reportFirstTurnEnded(in pty: PtySession, agentUUID: String, sessionID: String = "fresh") throws {
        let process = try XCTUnwrap(pty.foregroundProcess(snapshot: ProcessSnapshot())).instance
        for event in [AgentHookEvent.Name.userPromptSubmit, .stop] {
            _ = pty.applyAgentHook(AgentHookEvent(
                kind: .claude, name: event, agentUUID: agentUUID, sessionID: sessionID, emitterProcess: process,
                timestamp: Date().timeIntervalSince1970
            ), isUserFocused: false)
        }
    }

    private func askLead(_ lead: UIFlowHarness.Lead) throws -> MissionEvent {
        let mission = try XCTUnwrap(MissionStore.shared.create(MissionCreationRequest(
            id: UUID().uuidString, parentWorkspaceID: lead.workspace.id, parentAgentUUID: lead.agentUUID,
            childWorkspaceID: UUID().uuidString, childAgentUUID: UUID().uuidString, childAgentKind: "claude",
            branch: "feat/export", reportsToLead: true
        ), enabled: true))
        let question = MissionEvent(
            id: UUID().uuidString, missionID: mission.id, childWorkspaceID: mission.childWorkspaceID,
            childAgentUUID: mission.childAgentUUID, kind: .question, message: "Which date format?",
            timestamp: Date().timeIntervalSince1970
        )
        guard case .accepted = MissionStore.shared.process(question, enabled: false) else {
            XCTFail("the Lead’s task could not ask its question")
            return question
        }
        return question
    }

    private func clickLeadLine(_ text: String, in harness: UIFlowHarness) throws {
        let sidebar = harness.shell.sidebar
        let area = try XCTUnwrap(sidebar.hitAreas.first {
            if case .link(_, let label) = $0.region { return label.stringValue == text }
            return false
        })
        let location = sidebar.contentDocumentView.convert(NSPoint(x: area.frame.midX, y: area.frame.midY), to: nil)
        let hit = try XCTUnwrap(harness.window.contentView?.superview?.hitTest(location))
        hit.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        )))
    }

    func testRelaunchFromTheLeadRowResumesItsConversation() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.isSidebarExpanded = true
            shell.sidebar.isExpanded = true
            shell.relayout(animated: false)
            let lead = try harness.makeLead()
            let column = try XCTUnwrap(lead.workspace.leadTerminal)
            let pty = try XCTUnwrap(column.pty)
            let old = AgentStandIn(), resumed = AgentStandIn()
            defer { old.remove(); resumed.remove() }
            let settings = try XCTUnwrap(ClaudeSpaceSettings.fileURL(spaceID: lead.space))
            let flags = NiruxMCPServer.claudeArguments(executable: "/test/Nirux") + ["--settings=" + settings.path]
            let original = try run(old.command(arguments: flags), in: column, harness: harness)
            shell.updateSidebar()
            let index = try XCTUnwrap(shell.workspaces.firstIndex { $0 === lead.workspace })
            @MainActor func menu() -> NSMenu { shell.sidebar.workspaceActionMenu(workspaceIndex: index, columnIndex: nil) }
            XCTAssertNil(shell.sidebar.lastInfos.first(where: \.isLead)?.leadLaunchIssue)
            XCTAssertNil(menu().item(withTitle: "Relaunch with New Options…"))
            shell.setClaudeSafety(.sandbox, on: true, spaceID: lead.space)
            shell.updateSidebar()
            XCTAssertEqual(shell.sidebar.lastInfos.first(where: \.isLead)?.leadLaunchIssue, .olderOptions)
            let sessionID = UUID().uuidString
            try clickLeadLine("Launched with older options · Relaunch", in: harness)
            XCTAssertTrue(harness.terminalRestarts.isEmpty)
            XCTAssertEqual(shell.toast?.message, "Claude hasn’t recorded a conversation to resume yet.")
            let snapshot = ProcessSnapshot()
            let process = try XCTUnwrap(pty.foregroundProcess(snapshot: snapshot))
            let event = AgentHookEvent(kind: .claude, name: .userPromptSubmit, agentUUID: lead.agentUUID,
                                       sessionID: sessionID, emitterProcess: original, timestamp: Date().timeIntervalSince1970)
            _ = column.admitClaudeHook(event, foregroundProcess: process, snapshot: snapshot)
            _ = pty.applyAgentHook(event, isUserFocused: false)
            harness.perform(["Relaunch with New Options…"], in: menu())
            XCTAssertEqual(harness.alerts.last, "Relaunch the Lead of “Tools”?")
            XCTAssertTrue(harness.alertDetails.last?.contains("its turn stops") == true)
            XCTAssertTrue(harness.terminalRestarts.isEmpty)
            XCTAssertEqual(ProcessInstance.running(pid: original.pid), original)
            shell.setClaudeSafety(.sandbox, on: false, spaceID: lead.space)
            shell.updateSidebar()
            XCTAssertNil(shell.sidebar.lastInfos.first(where: \.isLead)?.leadLaunchIssue)
            shell.setClaudeSafety(.sandbox, on: true, spaceID: lead.space)
            shell.changeSpaceDefaults(spaceID: lead.space) { $0.claudeLaunchMode = .manual }
            shell.updateSidebar()
            let question = try askLead(lead)
            harness.restartedAgent = resumed.command(arguments: flags + ["--resume", sessionID, "--permission-mode", "default"],
                                                     launchPrompt: NiruxShellView.leadRelaunchPrompt)
            harness.alertResponses = [.alertSecondButtonReturn]
            try clickLeadLine("Launched with older options · Relaunch", in: harness)
            let command = try XCTUnwrap(harness.terminalRestarts.last)
            for part in ["--resume " + NiruxShellView.shellQuotedArgument(sessionID), "--permission-mode default",
                         "--settings=", NiruxShellView.shellQuotedArgument(NiruxShellView.leadRelaunchPrompt)] {
                XCTAssertTrue(command.contains(part), command)
            }
            harness.waitUntil("the resumed Lead") {
                pty.foregroundProcess(snapshot: ProcessSnapshot())?.arguments.last == NiruxShellView.leadRelaunchPrompt
            }
            XCTAssertNotEqual(ProcessInstance.running(pid: original.pid), original)
            XCTAssertIdentical(column, lead.workspace.leadTerminal)
            XCTAssertEqual(column.agentUUID, lead.agentUUID)
            let relaunched = try XCTUnwrap(pty.foregroundProcess(snapshot: ProcessSnapshot()))
            XCTAssertTrue(lead.workspace.runsRestartedLead(relaunched))
            shell.typeMissionMessages()
            XCTAssertTrue(MissionStore.shared.pendingPromptDeliveries().contains { $0.event.id == question.id })
            XCTAssertFalse(resumed.input.contains(question.message))
            try reportFirstTurnEnded(in: pty, agentUUID: lead.agentUUID, sessionID: sessionID)
            shell.typeMissionMessages()
            harness.waitUntil("the Mission question in the resumed conversation") { resumed.input.contains(question.message) }
            XCTAssertEqual(column.persistedClaudeRestore(foregroundProcess: relaunched), .resume(sessionID))
            shell.updateSidebar()
            XCTAssertNil(shell.sidebar.lastInfos.first(where: \.isLead)?.leadLaunchIssue)
        }
    }

    func testRelaunchProtectsTheTranscriptAndReservesItAcrossTheHangup() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            let column = try XCTUnwrap(lead.workspace.leadTerminal)
            let pty = try XCTUnwrap(column.pty)
            let old = AgentStandIn(), resumed = AgentStandIn()
            defer { old.remove(); resumed.remove() }
            let flags = NiruxMCPServer.claudeArguments(executable: "/test/Nirux")
            let original = try run(old.command(arguments: flags), in: column, harness: harness)
            let sessionID = UUID().uuidString
            let transcript = URL(fileURLWithPath: harness.root).appendingPathComponent(sessionID + ".jsonl")
            try Data().write(to: transcript)
            let snapshot = ProcessSnapshot()
            let event = AgentHookEvent(kind: .claude, name: .userPromptSubmit, agentUUID: lead.agentUUID,
                                       sessionID: sessionID, emitterProcess: original, timestamp: Date().timeIntervalSince1970)
            _ = column.admitClaudeHook(event, foregroundProcess: pty.foregroundProcess(snapshot: snapshot), snapshot: snapshot)
            @MainActor func record(_ event: AgentHookEvent.Name) {
                shell.sessionLedger.record(AgentSessionObservation(
                    agent: .claude, sessionID: sessionID, event: event, source: nil, timestamp: Date().timeIntervalSince1970,
                    agentProcess: original, name: nil, cwd: harness.repo, transcriptPath: transcript.path, checkout: nil,
                    pullRequest: nil, workspaceID: lead.workspace.id, workspaceTitle: "Lead", agentUUID: lead.agentUUID, columnIndex: 0
                ), spaceID: lead.space)
            }
            record(.userPromptSubmit)
            record(.stop)
            let knownPath = try XCTUnwrap(shell.sessionLedger.session(agent: .claude, sessionID: sessionID)?.transcriptPath)
            XCTAssertEqual(knownPath, transcript.path)
            @MainActor func relaunch() {
                harness.alertResponses = [.alertSecondButtonReturn]
                shell.requestLeadRecovery(.olderOptions, in: lead.workspace)
            }
            try FileManager.default.removeItem(at: transcript)
            relaunch()
            XCTAssertEqual(shell.toast?.message, SessionHistory.message(.transcriptGone, agent: .claude))
            XCTAssertTrue(harness.terminalRestarts.isEmpty)
            XCTAssertEqual(ProcessInstance.running(pid: original.pid), original)
            try Data().write(to: transcript)

            let key = AgentSessionRecord.key(agent: "claude", sessionID: sessionID)
            shell.sessionResume.inFlight.insert(key)
            relaunch()
            XCTAssertTrue(harness.terminalRestarts.isEmpty)
            XCTAssertEqual(ProcessInstance.running(pid: original.pid), original)
            shell.sessionResume.inFlight.remove(key)
            lead.workspace.addColumn(cwd: harness.repo)
            let other = try XCTUnwrap(lead.workspace.columns.last)
            @MainActor func holdInOtherColumn(_ id: String) {
                shell.sessionResume.noteLaunch(of: id, in: other, now: ProcessInfo.processInfo.systemUptime)
            }
            holdInOtherColumn(sessionID)
            relaunch()
            XCTAssertTrue(harness.terminalRestarts.isEmpty)
            XCTAssertEqual(ProcessInstance.running(pid: original.pid), original)
            holdInOtherColumn(UUID().uuidString)
            let restartTerminal = shell.sideEffects.restartTerminal
            defer { shell.sideEffects.restartTerminal = restartTerminal }
            shell.sideEffects.restartTerminal = { _, _, starts in
                XCTAssertEqual(column.relaunchingLeadSessionID, sessionID)
                XCTAssertFalse(starts(["claude"]))
            }
            relaunch()
            XCTAssertNil(column.relaunchingLeadSessionID, "timeout releases the reservation")
            shell.sideEffects.restartTerminal = { _, _, starts in
                holdInOtherColumn(sessionID)
                XCTAssertFalse(starts([]), "another holder appeared during the wait")
            }
            relaunch()
            XCTAssertNil(column.relaunchingLeadSessionID)
            holdInOtherColumn(UUID().uuidString)

            let history = try XCTUnwrap(shell.sessionLedger.session(agent: .claude, sessionID: sessionID))
            let columnCount = lead.workspace.columns.count
            shell.sideEffects.restartTerminal = { target, _, starts in
                target.restartTerminal(running: resumed.command(arguments: flags + ["--resume", sessionID])) { survivors in
                    record(.sessionEnd)
                    XCTAssertNotEqual(ProcessInstance.running(pid: original.pid), original)
                    let holders = shell.agentSessionHolders(snapshot: ProcessSnapshot())
                    XCTAssertEqual(HeldAgentSession.find(sessionID, in: holders)?.columnID, column.id)
                    shell.resumeSession(history, spaceID: lead.space)
                    XCTAssertFalse(shell.sessionResume.inFlight.contains(history.key))
                    return starts(survivors)
                }
            }
            relaunch()
            harness.waitUntil("one resumed Claude in the Lead") {
                pty.foregroundProcess(snapshot: ProcessSnapshot())?.arguments.last == sessionID
            }
            XCTAssertEqual(lead.workspace.columns.count, columnCount)
            XCTAssertNil(column.relaunchingLeadSessionID)
            let holders = shell.agentSessionHolders(snapshot: ProcessSnapshot()).filter { HeldAgentSession.find(sessionID, in: [$0]) != nil }
            XCTAssertEqual(holders.map(\.columnID), [column.id])
        }
    }

    func testStoppedAndUnmanagedLeadRowsStartFresh() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.isSidebarExpanded = true
            shell.sidebar.isExpanded = true
            shell.relayout(animated: false)
            let lead = try harness.makeLead()
            let column = try XCTUnwrap(lead.workspace.leadTerminal)
            let pty = try XCTUnwrap(column.pty)
            harness.waitUntil("the bare shell") { pty.foregroundProcess(snapshot: ProcessSnapshot()) != nil }
            let manual = AgentStandIn(), fresh = AgentStandIn()
            defer { manual.remove(); fresh.remove() }
            harness.restartedAgent = manual.command(arguments: ["--mcp-config={}", "--permission-mode", "plan"])
            shell.updateSidebar()
            harness.alertResponses = [.alertSecondButtonReturn]
            try clickLeadLine("Claude isn’t running · Restart Lead", in: harness)
            harness.waitUntil("the unmanaged Claude") { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
            shell.updateSidebar()
            XCTAssertEqual(shell.sidebar.lastInfos.first(where: \.isLead)?.leadLaunchIssue, .missingTools)
            harness.restartedAgent = fresh.command(launchPrompt: NiruxShellView.leadRestartPrompt)
            harness.alertResponses = [.alertSecondButtonReturn]
            try clickLeadLine("Started without Nirux’s tools · Restart Lead", in: harness)
            harness.waitUntil("the fresh conversation") {
                pty.foregroundProcess(snapshot: ProcessSnapshot())?.arguments.last == NiruxShellView.leadRestartPrompt
            }
            XCTAssertEqual(harness.terminalRestarts.count, 2)
            for command in harness.terminalRestarts {
                XCTAssertFalse(command.contains("--resume"))
                XCTAssertTrue(command.contains(NiruxShellView.shellQuotedArgument(NiruxShellView.leadRestartPrompt)))
            }
        }
    }

    func testRestartLeadStartsAFreshClaudeInItsColumn() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let target = "RESTART_FLOW_TARGET"
            let removed = "RESTART_FLOW_OBSOLETE"
            let lead = try harness.makeLead(environment: [.init(name: target, value: "old"), .init(name: removed, value: "old")])
            let column = try XCTUnwrap(lead.workspace.leadTerminal)
            let pty = try XCTUnwrap(column.pty)
            let old = AgentStandIn()
            defer { old.remove() }
            let variables = harness.root + "/launch-environment"
            let record = #"/bin/sh -c 'printf "%s\n" "$RESTART_FLOW_TARGET" "${RESTART_FLOW_OBSOLETE-unset}" "$NIRUX_LEAD" "$NIRUX_AGENT_UUID"'"#
                + " > " + NiruxShellView.shellQuotedArgument(variables) + "; "
            let oldClaude = try run(record + old.command(), in: column, harness: harness)
            XCTAssertEqual(try String(contentsOfFile: variables, encoding: .utf8), "old\nold\n1\n\(lead.agentUUID)\n")
            shell.changeSpaceDefaults(spaceID: lead.space) {
                $0.environment = [.init(name: target, value: "new")]
                $0.claudeLaunchMode = .manual
            }
            let shellBefore = pty.shellPID

            shell.requestRestartLead(spaceID: lead.space)
            XCTAssertEqual(harness.alerts.last, "Restart the Lead of “Tools”?")
            XCTAssertTrue(harness.alertDetails.last?.contains("launch mode (Manual)") == true, harness.alertDetails.last ?? "")
            XCTAssertEqual(harness.terminalRestarts, [], "cancelled")

            let question = try askLead(lead)
            let fresh = AgentStandIn()
            defer { fresh.remove() }
            harness.restartedAgent = record + fresh.command(launchPrompt: NiruxShellView.leadRestartPrompt)
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
            XCTAssertEqual(try String(contentsOfFile: variables, encoding: .utf8), "new\nunset\n1\n\(lead.agentUUID)\n")
            shell.typeMissionMessages()
            XCTAssertTrue(MissionStore.shared.pendingPromptDeliveries().contains { $0.event.id == question.id })
            XCTAssertFalse(fresh.input.contains(question.message))
            try reportFirstTurnEnded(in: pty, agentUUID: lead.agentUUID)
            shell.typeMissionMessages()
            harness.waitUntil("the waiting question in the fresh Lead's prompt") { fresh.input.contains(question.message) }
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
                mode: .auto, agent: status.map { WorkspaceClosePolicy.LiveAgent(agent: .claude, status: $0) }
            )
        }
        XCTAssertTrue(details(nil)[0].contains("launch mode (Auto)"), details(nil)[0])
        XCTAssertEqual(details(nil).count, 2)
        XCTAssertEqual(details(.idle).count, 2)
        XCTAssertEqual(details(.working).last, "Claude is working: its turn stops.")
        XCTAssertEqual(details(.needsAttention).last, "Claude is waiting for you: that goes unanswered.")
        XCTAssertEqual(
            NiruxShellView.leadRestartDetails(mode: .auto, agent: nil, otherProgram: "vim").last, "vim runs in its terminal: it ends too."
        )
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
            harness.restartedAgent = fresh.command(launchPrompt: NiruxShellView.leadRestartPrompt)
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
            let manual = ForegroundProcess(
                instance: try XCTUnwrap(foreground(column)).instance, name: "claude", arguments: ["claude"]
            )
            _ = shell.missionQuestions(foreground: { _ in manual }, now: now)
            let handStarted = shell.missionQuestions(foreground: { _ in manual }, now: now + NiruxShellView.missionParentGrace + 5)
            XCTAssertEqual(handStarted[ObjectIdentifier(task)]?.handOff, .parentRestarted)
            // The user answers it: the restarted Lead hears it.
            XCTAssertTrue(shell.answerMissionQuestion(question.id, text: "Keep it"))
            let notice = try XCTUnwrap(shell.pendingLeadNotices.last)
            XCTAssertTrue(notice.text.hasSuffix(": Keep it"), notice.text)
            try reportFirstTurnEnded(in: pty, agentUUID: lead.agentUUID)
            shell.typeLeadNotices()
            harness.waitUntil("the answer in the fresh Lead's prompt") { fresh.input.contains(notice.text) }
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
            let folder = harness.root + "/worktree"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
            state.workspaces[saved].columns[claudeColumn].cwd = folder
            XCTAssertTrue(Persistence.save(state))
            shell.restoreState()
            let restored = try XCTUnwrap(shell.leadWorkspace(inSpace: lead.space))
            let column = try XCTUnwrap(restored.leadTerminal)
            XCTAssertTrue(column.isAwaitingResume)
            XCTAssertNotNil(column.restoredColumn)
            XCTAssertEqual(column.launchDirectory, folder)
            try FileManager.default.removeItem(atPath: folder)

            let fresh = AgentStandIn()
            defer { fresh.remove() }
            harness.restartedAgent = fresh.command()
            harness.alertResponses = [.alertSecondButtonReturn]
            shell.requestRestartLead(spaceID: lead.space)
            XCTAssertFalse(column.isAwaitingResume)
            XCTAssertEqual(harness.terminalRestarts.count, 1)
            XCTAssertEqual(harness.restoredAgentLaunches, [], "not the conversation before")
            XCTAssertNil(column.restoredColumn, "a save keeps the fresh conversation")
            XCTAssertEqual(column.launchDirectory, restored.cwd)
            let pty = try XCTUnwrap(column.pty)
            harness.waitUntil("the fresh claude") { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
            // Its terminal ends: Restart Shell starts a plain shell.
            let claude = try XCTUnwrap(pty.foregroundProcess(snapshot: ProcessSnapshot()))
            kill(claude.instance.pid, SIGKILL)
            harness.waitUntil("its terminal to end") { pty.hasExited }
            column.restartShell()
            harness.waitUntil("a shell") { pty.foregroundProcess(snapshot: ProcessSnapshot()) != nil }
            XCTAssertNotEqual(pty.foregroundProcess(snapshot: ProcessSnapshot())?.name, "claude")
        }
    }

    /// A Lead whose Claude column closed before a Lead kept it gets a new
    /// one, with the agent UUID its tasks report to.
    func testALeadWithoutItsClaudeColumnGetsOne() throws {
        try UIFlowHarness.run { harness in
            let lead = try harness.makeLead()
            lead.workspace.closeColumn(at: try XCTUnwrap(lead.workspace.columns.firstIndex { $0 === lead.workspace.leadTerminal }))
            XCTAssertNil(lead.workspace.leadTerminal)
            let launches = harness.agentLaunches.count
            harness.alertResponses = [.alertSecondButtonReturn]
            harness.shell.requestRestartLead(spaceID: lead.space)
            let column = try XCTUnwrap(lead.workspace.leadTerminal)
            XCTAssertEqual(column.agentUUID, lead.agentUUID)
            XCTAssertEqual(lead.workspace.columns.count, 2)
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
            let stuck = try run("exec nohup /bin/sleep 600 > /dev/null 2>&1", named: "sleep", in: column, harness: harness)
            defer { if ProcessInstance.running(pid: stuck.pid) == stuck { kill(stuck.pid, SIGKILL) } }
            let fresh = AgentStandIn()
            defer { fresh.remove() }
            harness.restartedAgent = fresh.command()
            harness.alertResponses = [.alertSecondButtonReturn]
            harness.shell.requestRestartLead(spaceID: lead.space)
            let pty = try XCTUnwrap(column.pty)
            harness.waitUntil("its shell to end") { pty.hasExited }
            XCTAssertFalse(column.isShowingShellExit, "no Restart Shell while Nirux restarts it")
            column.restartShell()
            XCTAssertTrue(pty.hasExited, "nor does Enter start one")
            harness.shell.requestRestartLead(spaceID: lead.space)
            XCTAssertEqual(harness.shell.toast?.message, "The Lead is restarting.")
            XCTAssertEqual(harness.alerts.count, 1, "nothing to confirm twice")
            harness.waitUntil("the toast", timeout: NiruxShellView.exitTimeout + 20) {
                harness.shell.toast?.message.hasPrefix("The Lead’s Claude didn’t stop") == true
            }
            XCTAssertTrue(harness.shell.toast?.message.contains("(sleep)") == true, harness.shell.toast?.message ?? "")
            XCTAssertTrue(harness.shell.toast?.message.hasSuffix("Once it stops, choose Restart Lead again.") == true)
            XCTAssertEqual(column.pty?.hasExited, true, "its terminal stays ended")
            XCTAssertTrue(column.isShowingShellExit)
            XCTAssertEqual(harness.terminalRestarts.count, 1)
            XCTAssertEqual(fresh.input, "", "no Claude started")

            harness.alertResponses = [.alertSecondButtonReturn]
            harness.shell.requestRestartLead(spaceID: lead.space)
            harness.waitUntil("the retry to finish", timeout: NiruxShellView.exitTimeout + 20) { !column.isRestartingShell }
            XCTAssertTrue(pty.hasExited, "the shell is gone but its original job still runs")
            if ProcessInstance.running(pid: stuck.pid) == stuck { kill(stuck.pid, SIGKILL) }
            harness.alertResponses = [.alertSecondButtonReturn]
            harness.shell.requestRestartLead(spaceID: lead.space)
            harness.waitUntil("the new Lead after the job exits") { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
        }
    }

    /// Saved with neither its Claude column nor its agent UUID: the new
    /// column takes the one its tasks report to.
    func testALeadSavedWithoutItsClaudeColumnTakesItsTasksParent() throws {
        try UIFlowHarness.run { harness in
            let lead = try harness.makeLead()
            let parent = UUID().uuidString
            _ = try XCTUnwrap(MissionStore.shared.create(MissionCreationRequest(
                id: UUID().uuidString, parentWorkspaceID: lead.workspace.id, parentAgentUUID: parent,
                childWorkspaceID: UUID().uuidString, childAgentUUID: UUID().uuidString, childAgentKind: "claude",
                branch: "feat/export", reportsToLead: true
            ), enabled: true))
            lead.workspace.closeColumn(at: try XCTUnwrap(lead.workspace.columns.firstIndex { $0 === lead.workspace.leadTerminal }))
            lead.workspace.leadAgentUUID = nil
            harness.alertResponses = [.alertSecondButtonReturn]
            harness.shell.requestRestartLead(spaceID: lead.space)
            XCTAssertEqual(lead.workspace.leadTerminal?.agentUUID, parent)
        }
    }

    /// Its shell not started yet (a Lead just turned on): nothing to end.
    func testALeadStillStartingIsNotRestarted() throws {
        try UIFlowHarness.run { harness in
            let lead = try harness.makeLead()
            XCTAssertNil(lead.workspace.leadTerminal?.pty?.shellPID)
            harness.alertResponses = [.alertSecondButtonReturn]
            harness.shell.requestRestartLead(spaceID: lead.space)
            XCTAssertEqual(harness.shell.toast?.message, "The Lead is starting: restart it in a moment.")
            XCTAssertEqual(harness.terminalRestarts, [])
        }
    }

    /// A shell that ignores the hang-up keeps its terminal, with no "Session
    /// ended" over it.
    func testAShellThatIgnoresTheHangUpKeepsItsTerminal() throws {
        try UIFlowHarness.run { harness in
            let lead = try harness.makeLead()
            let column = try XCTUnwrap(lead.workspace.leadTerminal)
            let pty = try XCTUnwrap(column.pty)
            harness.waitUntil("its shell") { pty.shellPID != nil }
            let marker = harness.root + "/trapped"
            pty.sendRaw("trap '' HUP; touch '\(marker)'\n")
            harness.waitUntil("the trap") { FileManager.default.fileExists(atPath: marker) }
            harness.alertResponses = [.alertSecondButtonReturn]
            harness.shell.requestRestartLead(spaceID: lead.space)
            harness.waitUntil("the toast", timeout: NiruxShellView.exitTimeout + 20) {
                harness.shell.toast?.message.hasPrefix("The Lead’s Claude didn’t stop") == true
            }
            let shellName = (PtySession.defaultShell as NSString).lastPathComponent
            XCTAssertTrue(harness.shell.toast?.message.contains("(\(shellName))") == true, harness.shell.toast?.message ?? "")
            XCTAssertFalse(pty.hasExited)
            XCTAssertFalse(column.isShowingShellExit)
        }
    }

    /// Turned off while its restart waits for its programs: nothing starts.
    func testTurningTheLeadOffDuringARestartStartsNothing() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            let column = try XCTUnwrap(lead.workspace.leadTerminal)
            let stuck = try run("exec nohup /bin/sleep 600 > /dev/null 2>&1", named: "sleep", in: column, harness: harness)
            defer { if ProcessInstance.running(pid: stuck.pid) == stuck { kill(stuck.pid, SIGKILL) } }
            harness.alertResponses = [.alertSecondButtonReturn]
            shell.requestRestartLead(spaceID: lead.space)
            let pty = try XCTUnwrap(column.pty)
            harness.waitUntil("its shell to end") { pty.hasExited }
            harness.alertResponses = [.alertSecondButtonReturn]
            shell.stopLead(spaceID: lead.space)
            harness.waitUntil("the Lead to close") { !shell.workspaces.contains { $0 === lead.workspace } }
            kill(stuck.pid, SIGKILL)
            harness.waitUntil("the restart's wait to end") { !column.isRestartingShell }
            XCTAssertTrue(pty.hasExited, "no Claude started in a closed column")
        }
    }

    /// Its tasks report to its Claude column when another column runs Claude too.
    func testItsTasksReportToItsClaudeColumnFirst() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            let other = AgentStandIn()
            defer { other.remove() }
            let otherUUID = UUID().uuidString
            lead.workspace.addColumn(command: other.command(), agentUUID: otherUUID, cwd: harness.repo)
            while lead.workspace.focusedIndex > 0 { lead.workspace.moveColumn(.left) }
            let otherPty = try XCTUnwrap(lead.workspace.columns.first { $0.agentUUID == otherUUID }?.pty)
            harness.waitUntil("the other claude") { otherPty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
            XCTAssertEqual(shell.leadMissionParent(inSpace: lead.space)?.agentUUID, otherUUID, "its own runs no Claude")
            let own = AgentStandIn()
            defer { own.remove() }
            _ = try run(own.command(), in: try XCTUnwrap(lead.workspace.leadTerminal), harness: harness)
            XCTAssertEqual(shell.leadMissionParent(inSpace: lead.space)?.agentUUID, lead.agentUUID)
            harness.alertResponses = [.alertSecondButtonReturn]
            shell.requestRestartLead(spaceID: lead.space)
            XCTAssertTrue(lead.workspace.leadTerminal?.isRestartingShell == true)
            XCTAssertEqual(shell.leadMissionParent(inSpace: lead.space)?.agentUUID, lead.agentUUID)
            harness.waitUntil("the restart to finish") { lead.workspace.leadTerminal?.isRestartingShell == false }
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
