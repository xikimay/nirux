import AppKit
import XCTest
@testable import Nirux

/// Restart Lead (NiruxShellView+Lead): once confirmed, the Lead's Claude
/// ends and a fresh conversation starts in the same column, launched as a
/// new Lead's is, its tasks still reporting to it.
@MainActor
final class LeadRestartFlowTests: XCTestCase {
    /// The Lead's shell running `command` as a child, `name`d: that process.
    /// `asLaunchLine`: sent as Nirux sends an agent's launch line, which
    /// is no draft.
    private func run(
        _ command: String, named name: String = "claude", in column: ColumnState, harness: UIFlowHarness, asLaunchLine: Bool = false
    ) throws -> ProcessInstance {
        let pty = try XCTUnwrap(column.pty)
        // The login shell can still be in canonical mode when the full launch arguments exceed MAX_CANON.
        let script = URL(fileURLWithPath: harness.root).appendingPathComponent("lead-worker-\(UUID().uuidString).sh")
        try command.write(to: script, atomically: true, encoding: .utf8)
        harness.waitUntil("its shell") { pty.shellPID != nil }
        let line = "(. \(NiruxShellView.shellQuotedArgument(script.path)))"
        if asLaunchLine { pty.sendShellLaunchCommand(line) } else { pty.sendRaw(line + "\n") }
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

    func testLeadPickerControlsStartAndRestartIndependentlyOfTaskAgent() throws {
        for agent in CodingAgent.launchable {
            try UIFlowHarness.run { harness in
                let shell = harness.shell
                shell.projectBoardClient = ProjectBoardFlowTests.FakeGitHub(openPullRequests: "[]", runs: "[]")
                let repo = SpaceAnchor(kind: .gitRepository(commonDir: harness.repo + "/.git"), name: "repo", isDefault: true)
                let space = shell.workspaceStore.createProfile(named: agent.name, anchors: [repo], select: true).id
                shell.changeSpaceDefaults(spaceID: space) { $0.agent = .agy }
                shell.showSpaceSettings(profileID: space, tab: .lead)
                let pane = try XCTUnwrap(shell.spaceSettings?.lead)
                XCTAssertEqual(pane.agentPopup.titleOfSelectedItem, CodingAgent.claude.productName)
                pane.agentPopup.selectItem(withTitle: agent.productName)
                pane.agentChanged(pane.agentPopup)
                XCTAssertEqual(SpaceDefaultsStore.defaults(forSpace: space).preferredLeadAgent, agent)
                shell.startLead(spaceID: space)
                let lead = try XCTUnwrap(shell.leadWorkspace(inSpace: space))
                let column = try XCTUnwrap(lead.leadTerminal)
                XCTAssertTrue(try XCTUnwrap(harness.agentLaunches.last).hasPrefix("command \(agent.rawValue)"))
                let next: CodingAgent = agent == .claude ? .agy : (agent == .agy ? .codex : .claude)
                pane.agentPopup.selectItem(withTitle: next.productName)
                pane.agentChanged(pane.agentPopup)
                harness.waitUntil("the Lead shell to start") { column.pty?.shellPID != nil }
                harness.alertResponses = [.alertSecondButtonReturn]
                shell.requestRestartLead(spaceID: space)
                harness.waitUntil("the selected agent to restart") {
                    harness.terminalRestarts.last?.hasPrefix("command \(next.rawValue)") == true && !column.isRestartingShell
                }
                XCTAssertTrue(try XCTUnwrap(harness.alertMenuTitles.last).contains { $0.hasPrefix(next.productName) })
                XCTAssertEqual(lead.leadAgentUUID, column.agentUUID)
                XCTAssertEqual(SpaceDefaultsStore.defaults(forSpace: space).taskAgent, .agy)
            }
        }
    }

    func testRestartDefaultsToTheLiveAgentAndHonorsAnExplicitSwitch() throws {
        for (index, agent) in CodingAgent.launchable.enumerated() {
            try UIFlowHarness.run { harness in
                let shell = harness.shell
                let lead = try harness.makeLead()
                shell.changeSpaceDefaults(spaceID: lead.space) { $0.agyLaunchMode = .plan }
                let column = try XCTUnwrap(lead.workspace.leadTerminal)
                let standIn = AgentStandIn()
                defer { standIn.remove() }
                let original = try run(standIn.command(named: agent.rawValue), named: agent.rawValue, in: column, harness: harness)
                let next = (index + 1) % CodingAgent.launchable.count
                let modal = shell.sideEffects.runModal
                shell.sideEffects.runModal = { alert in
                    let picker = alert.accessoryView as? NSPopUpButton
                    XCTAssertEqual(picker?.indexOfSelectedItem, index)
                    XCTAssertTrue(picker?.itemTitles.contains("Antigravity — Plan") == true)
                    return modal(alert)
                }
                harness.alertMenuChoices = [next, next]
                shell.requestRestartLead(spaceID: lead.space)
                XCTAssertTrue(harness.terminalRestarts.isEmpty)
                XCTAssertEqual(ProcessInstance.running(pid: original.pid), original)

                harness.alertResponses = [.alertSecondButtonReturn]
                shell.requestRestartLead(spaceID: lead.space)
                let selected = CodingAgent.launchable[next]
                let command = try XCTUnwrap(harness.terminalRestarts.last)
                XCTAssertTrue(command.hasPrefix("command \(selected.rawValue) "), command)
                if selected == .agy { XCTAssertTrue(command.contains("--mode plan"), command) }
                XCTAssertTrue(command.contains(NiruxShellView.shellQuotedArgument(NiruxShellView.leadRestartPrompt(for: selected))))
                XCTAssertEqual(SpaceDefaultsStore.defaults(forSpace: lead.space).preferredLeadAgent, .claude)
                harness.waitUntil("the switch to finish") { !column.isRestartingShell }
                XCTAssertEqual(column.agentUUID, lead.agentUUID)
            }
        }
    }

    func testAntigravityLeadPromptOffersMCPAndTheMissionFallback() {
        let prompt = NiruxShellView.agyLeadPrompt
        for tool in ["list_tasks", "start_task", "tell", "reply", "ask_user", "queue_merge", "merge_queue_status", "stop_merge_queue"] {
            XCTAssertTrue(prompt.contains(tool), tool)
        }
        XCTAssertTrue(prompt.contains(#"If the tools are unavailable, answer Mission questions with "$NIRUX_CLI_PATH" --mission reply"#))
        XCTAssertTrue(NiruxShellView.leadRestartPrompt(for: .agy).contains(prompt))
        XCTAssertTrue(NiruxShellView.leadRelaunchPrompt(for: .agy).contains(prompt))
    }

    func testManualCodexAndAntigravityLeadReceiveQuestionsResultsAndNotices() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            for agent in [CodingAgent.codex, .agy] {
                let lead = try harness.makeLead()
                let column = try XCTUnwrap(lead.workspace.leadTerminal)
                column.onAgentAttention = { _ in }
                let pty = try XCTUnwrap(column.pty)
                let standIn = AgentStandIn()
                defer { standIn.remove() }
                let first = "Check the space."
                let process = try run(standIn.command(named: agent.rawValue, launchPrompt: first), named: agent.rawValue,
                                      in: column, harness: harness)
                var queued: [CodexQueue.Request] = []
                shell.sideEffects.queueCodexMessage = { request, done in queued.append(request); done(.queued) }
                @MainActor func report(_ state: AgentProgramStatus.State) {
                    pty.onProgramStatus?(AgentProgramStatus(state: state, kind: nil, message: nil, agent: agent))
                }
                report(.working)
                let question = try askLead(lead)
                shell.addWorkspace(title: "Export", cwd: harness.worktree, profileID: lead.space,
                                   workspaceID: question.childWorkspaceID, initialAgentUUID: question.childAgentUUID,
                                   missionID: question.missionID, reportsToLead: true)
                let child = try XCTUnwrap(shell.workspaces.first { $0.id == question.childWorkspaceID }?.columns.first)
                let foreground = { (column: ColumnState) in column.pty?.foregroundProcess(snapshot: ProcessSnapshot()) }
                let front = try XCTUnwrap(foreground(column))
                let mission = try XCTUnwrap(MissionStore.shared.missions.first { $0.id == question.missionID })
                let delivery = MissionStore.AcceptedEvent(mission: mission, event: question)
                XCTAssertEqual(NiruxShellView.recipientAgent(of: delivery, foreground: front), agent)
                shell.typeMissionMessages()
                XCTAssertTrue(queued.isEmpty && standIn.input.isEmpty)
                let now = Date().timeIntervalSince1970
                @MainActor func handOff(_ at: TimeInterval) -> SidebarMissionQuestion.HandOff? {
                    shell.missionQuestions(foreground: foreground, now: at)[ObjectIdentifier(child)]?.handOff
                }
                XCTAssertNil(handOff(now))
                XCTAssertNil(handOff(now + NiruxShellView.missionParentGrace), "the parent is still working on its first prompt")
                if agent == .codex {
                    report(.done)
                    shell.typeMissionMessages()
                    XCTAssertTrue(queued.isEmpty, "the queue requires the exact thread")
                    _ = column.captureCodexSession(sessionID: "thread", soleInputDigest: CodexLaunch.promptDigest(first),
                                                   emitterProcess: process, snapshot: ProcessSnapshot())
                }
                report(.done)
                shell.typeMissionMessages()
                func received(_ text: String) -> Bool {
                    agent == .codex ? queued.contains { $0.thread == "thread" && $0.message.contains(text) } : standIn.input.contains(text)
                }
                harness.waitUntil("the Lead's question") { received(question.id) }
                XCTAssertNil(handOff(now))
                XCTAssertNil(handOff(now + NiruxShellView.missionParentGrace + 1), "idle before the question started")
                report(.working)
                report(.done)
                XCTAssertNil(handOff(now + 30))
                XCTAssertEqual(handOff(now + 30 + NiruxShellView.missionParentGrace), .parentDidNotAnswer)
                let result = MissionEvent(id: UUID().uuidString, missionID: mission.id, childWorkspaceID: mission.childWorkspaceID,
                                          childAgentUUID: mission.childAgentUUID, kind: .completed, message: "Export finished.",
                                          timestamp: Date().timeIntervalSince1970)
                XCTAssertNotNil(MissionStore.shared.accept(result, enabled: false))
                shell.typeMissionMessages()
                harness.waitUntil("the Lead's completion") { received("Export finished.") }
                report(.working)
                report(.done)
                shell.tellProposer(NewTask.MissionParent(workspaceID: lead.workspace.id, agentUUID: lead.agentUUID), "Notice for the Lead.")
                harness.waitUntil("the Lead's notice") { received("Notice for the Lead.") }
                if agent == .codex { XCTAssertEqual(standIn.input, "") }
            }
        }
    }

    /// "Group task results" on: a Lead's result waits for its group's
    /// window, with a pass due when it ends; a due group goes in one paste,
    /// and one past a paste's limit goes in pastes that fit, each result once.
    func testALeadsGroupedResultsGoTogetherInPastesThatFit() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            shell.setLeadGroupsResults(true, spaceID: lead.space)
            let column = try XCTUnwrap(lead.workspace.leadTerminal)
            column.onAgentAttention = { _ in }
            let pty = try XCTUnwrap(column.pty)
            let standIn = AgentStandIn()
            defer { standIn.remove() }
            _ = try run(standIn.command(named: "agy", launchPrompt: "Check the space."), named: "agy", in: column, harness: harness)
            @MainActor func report(_ state: AgentProgramStatus.State) {
                pty.onProgramStatus?(AgentProgramStatus(state: state, kind: nil, message: nil, agent: .agy))
            }
            report(.working)
            report(.done)
            @MainActor func result(_ message: String, at time: TimeInterval) throws {
                let mission = try XCTUnwrap(MissionStore.shared.create(MissionCreationRequest(
                    id: UUID().uuidString, parentWorkspaceID: lead.workspace.id, parentAgentUUID: lead.agentUUID,
                    childWorkspaceID: UUID().uuidString, childAgentUUID: UUID().uuidString, childAgentKind: "claude",
                    branch: "feat/x", reportsToLead: true
                ), enabled: true))
                XCTAssertNotNil(MissionStore.shared.accept(MissionEvent(
                    id: UUID().uuidString, missionID: mission.id, childWorkspaceID: mission.childWorkspaceID,
                    childAgentUUID: mission.childAgentUUID, kind: .completed, message: message, timestamp: time
                ), enabled: false))
            }
            // A redraw's Ctrl+L can reach the stand-in (its process is perl) in the middle of a paste.
            func input() -> String { standIn.input.replacingOccurrences(of: "\u{0C}", with: "") }
            func pastes() -> Int { input().components(separatedBy: "\u{1b}[200~").count - 1 }
            func count(_ text: String) -> Int { input().components(separatedBy: text).count - 1 }
            let now = Date().timeIntervalSince1970
            try result("Docs written.", at: now)
            shell.typeMissionMessages()
            XCTAssertNotNil(shell.missionWaits.resultReleaseAt, "a pass when its window ends")
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            XCTAssertEqual(pastes(), 0, "within its window")

            try result("Export finished.", at: now - MissionResultBatch.window - 1)
            shell.typeMissionMessages()
            harness.waitUntil("the Lead's results") { input().contains("Docs written.") }
            XCTAssertEqual(count("Export finished."), 1)
            XCTAssertEqual(pastes(), 1, "one paste, one wake")

            // 20 × 490 characters: past one paste's 8,000, whatever frames them.
            let parts = (1...20).map { String(format: "Part %02d ", $0) }
            for (index, part) in parts.enumerated() {
                try result(part + String(repeating: "x", count: 482), at: now - MissionResultBatch.window - 100 + TimeInterval(index))
            }
            report(.working)
            report(.done)
            shell.typeMissionMessages()
            harness.waitUntil("what fits") { pastes() == 2 }
            XCTAssertEqual(count(parts[0]), 1)
            XCTAssertEqual(count(parts[19]), 0, "past the paste's limit: the next pass")
            // An agent starts its turn after the paste's Enter: the rest is held till then.
            harness.waitUntil("its Enter") { shell.missionWaits.typing.isEmpty }
            report(.working)
            report(.done)
            shell.typeMissionMessages()
            @MainActor func state(_ part: String) -> String {
                let event = MissionStore.shared.missions.flatMap(\.events).first { $0.message.hasPrefix(part) }
                return "\(part)typed=\(event?.parentTypedAt != nil) typing=\(event.map { shell.missionWaits.typing.contains($0.id) } ?? false)"
            }
            harness.waitUntil("the rest", timeout: 20) { count(parts[19]) == 1 }
            XCTAssertEqual(pastes(), 3)
            XCTAssertEqual(
                parts.map(count), Array(repeating: 1, count: parts.count),
                "each result once; Ctrl+L seen: \(standIn.input.contains("\u{0C}")); pastes \(pastes()); "
                    + parts.filter { count($0) != 1 }.map(state).joined(separator: ", ") + "; tail: " + String(input().suffix(160)).debugDescription
            )
        }
    }

    func testCodexRecoveryChecksToolsAndResumesTheProvenThreadWithCurrentOptions() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            let column = try XCTUnwrap(lead.workspace.leadTerminal)
            let pty = try XCTUnwrap(column.pty)
            let old = AgentStandIn(), resumed = AgentStandIn()
            defer { old.remove(); resumed.remove() }
            let flags = NiruxMCPServer.codexArguments(executable: "/test/Nirux")
            let prompt = "Check the space."
            let original = try run(old.command(named: "codex", arguments: flags, launchPrompt: prompt),
                                   named: "codex", in: column, harness: harness)
            let snapshot = ProcessSnapshot()
            let process = try XCTUnwrap(pty.foregroundProcess(snapshot: snapshot))
            @MainActor func issue(_ arguments: [String]) -> LeadLaunchIssue? {
                let foreground = ForegroundProcess(instance: original, name: "codex", arguments: ["codex"] + arguments)
                return shell.leadLaunchIssue(in: lead.workspace, foreground: foreground, snapshot: snapshot)
            }
            XCTAssertEqual(issue([]), .missingTools)
            XCTAssertEqual(issue(["-c", "mcp_servers.other={}"]), .missingTools)
            XCTAssertNil(issue(flags))
            shell.changeSpaceDefaults(spaceID: lead.space) { $0.codexLaunchMode = .readOnly }
            XCTAssertEqual(issue(flags), .olderOptions)
            XCTAssertNil(issue(flags + CodexLaunchMode.readOnly.cliArgs))
            shell.requestLeadRecovery(.launchIssue(.olderOptions), in: lead.workspace)
            XCTAssertEqual(shell.toast?.message, "Codex hasn’t recorded a conversation to resume yet.")
            XCTAssertTrue(harness.terminalRestarts.isEmpty)

            let id = UUID().uuidString
            XCTAssertTrue(column.captureCodexSession(sessionID: id, soleInputDigest: CodexLaunch.promptDigest(prompt),
                                                     emitterProcess: original, snapshot: snapshot))
            XCTAssertEqual(column.leadSessionID(for: process), id)
            harness.restartedAgent = resumed.command(named: "codex", arguments: ["resume", id] + flags + CodexLaunchMode.readOnly.cliArgs,
                                                     launchPrompt: NiruxShellView.leadRelaunchPrompt)
            let key = AgentSessionRecord.key(agent: "codex", sessionID: id)
            shell.sessionResume.inFlight.insert(key)
            harness.alertResponses = [.alertSecondButtonReturn, .alertSecondButtonReturn]
            shell.requestLeadRecovery(.launchIssue(.olderOptions), in: lead.workspace)
            XCTAssertTrue(harness.terminalRestarts.isEmpty)
            shell.sessionResume.inFlight.remove(key)
            shell.requestLeadRecovery(.launchIssue(.olderOptions), in: lead.workspace)
            let command = try XCTUnwrap(harness.terminalRestarts.last)
            XCTAssertTrue(command.hasPrefix("command codex resume " + NiruxShellView.shellQuotedArgument(id)), command)
            XCTAssertTrue(command.contains("--sandbox read-only"), command)
            XCTAssertTrue(try XCTUnwrap(harness.alertDetails.last).contains("Codex will resume"))
            harness.waitUntil("the same Codex thread") {
                guard let process = pty.foregroundProcess(snapshot: ProcessSnapshot()) else { return false }
                return process.instance != original && column.leadSessionID(for: process) == id
            }
        }
    }

    func testAntigravityRelaunchKeepsTheConversationAndLeadColumn() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            let column = try XCTUnwrap(lead.workspace.leadTerminal)
            let pty = try XCTUnwrap(column.pty)
            let old = AgentStandIn(), resumed = AgentStandIn()
            defer { old.remove(); resumed.remove() }
            let original = try run(old.command(named: "agy"), named: "agy", in: column, harness: harness)
            let snapshot = ProcessSnapshot()
            let process = try XCTUnwrap(pty.foregroundProcess(snapshot: snapshot))
            let id = UUID().uuidString
            XCTAssertNil(column.leadSessionID(for: process))
            shell.updateSidebar()
            let index = try XCTUnwrap(shell.workspaces.firstIndex { $0 === lead.workspace })
            let menu = shell.sidebar.workspaceActionMenu(workspaceIndex: index, columnIndex: nil)
            let action = "Relaunch with Current Options…"
            XCTAssertNotNil(menu.item(withTitle: action))
            XCTAssertNil(shell.sidebar.lastInfos.first(where: \.isLead)?.leadLaunchIssue)
            harness.perform([action], in: menu)
            XCTAssertEqual(shell.toast?.message, "Antigravity hasn’t recorded a conversation to resume yet.")
            XCTAssertTrue(harness.terminalRestarts.isEmpty)
            XCTAssertTrue(column.captureAgySession(sessionID: id, emitterProcess: original, snapshot: snapshot))
            XCTAssertEqual(column.leadSessionID(for: process), id)
            let prompt = NiruxShellView.leadRelaunchPrompt(for: .agy)
            harness.restartedAgent = resumed.command(named: "agy", arguments: ["--conversation", id, "-i"], launchPrompt: prompt)
            harness.alertResponses = [.alertSecondButtonReturn]
            harness.perform([action], in: menu)
            XCTAssertTrue(try XCTUnwrap(harness.alertDetails.last).contains("Antigravity will resume"))
            let command = try XCTUnwrap(harness.terminalRestarts.last)
            XCTAssertTrue(command.hasPrefix("command agy --conversation " + NiruxShellView.shellQuotedArgument(id)), command)
            XCTAssertTrue(command.hasSuffix("-i " + NiruxShellView.shellQuotedArgument(prompt)), command)
            harness.waitUntil("the resumed Antigravity conversation") {
                guard let current = pty.foregroundProcess(snapshot: ProcessSnapshot()) else { return false }
                return current.instance != original && lead.workspace.runsRestartedLead(current) && column.leadSessionID(for: current) == id
            }
            XCTAssertEqual(lead.workspace.leadTerminal?.agentUUID, lead.agentUUID)
        }
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
                shell.requestLeadRecovery(.launchIssue(.olderOptions), in: lead.workspace)
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
            try clickLeadLine("Lead agent isn’t running · Restart Lead", in: harness)
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
            XCTAssertTrue(try XCTUnwrap(harness.alertMenuTitles.last).contains("Claude Code — Manual"))
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
                agent: status.map { WorkspaceClosePolicy.LiveAgent(agent: .claude, status: $0) }
            )
        }
        XCTAssertEqual(details(nil).count, 2)
        XCTAssertEqual(details(.idle).count, 2)
        XCTAssertEqual(details(.working).last, "Claude is working: its turn stops.")
        XCTAssertEqual(details(.needsAttention).last, "Claude is waiting for you: that goes unanswered.")
        XCTAssertEqual(
            NiruxShellView.leadRestartDetails(agent: nil, otherProgram: "vim").last, "vim runs in its terminal: it ends too."
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
            // After the user's Quit: the Lead waits for Resume.
            state.quitByUser = true
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
                harness.shell.toast?.message.hasPrefix("The Lead’s previous session didn’t stop") == true
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
                harness.shell.toast?.message.hasPrefix("The Lead’s previous session didn’t stop") == true
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

    func testItsTasksPreferItsDesignatedCodexOverAnotherClaudeColumn() throws {
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
            _ = try run(own.command(named: "codex"), named: "codex", in: try XCTUnwrap(lead.workspace.leadTerminal), harness: harness)
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

    // MARK: - Promote to Lead

    /// A task of `space` whose Claude stand-in proved `sessionID` with its
    /// hooks; its turn over unless `turnEnded` is false.
    private func makeTask(
        _ title: String, in space: String, sessionID: String, standIn: AgentStandIn, harness: UIFlowHarness,
        missionID: String? = nil, workspaceID: String = UUID().uuidString, agentUUID: String = UUID().uuidString,
        turnEnded: Bool = true
    ) throws -> (task: WorkspaceState, column: ColumnState, process: ProcessInstance) {
        let shell = harness.shell
        shell.addWorkspace(
            title: title, cwd: harness.worktree, profileID: space, workspaceID: workspaceID, initialAgentUUID: agentUUID,
            missionID: missionID, reportsToLead: missionID != nil
        )
        let task = try XCTUnwrap(shell.workspaces.first { $0.id == workspaceID })
        let column = try XCTUnwrap(task.columns.first)
        let process = try run(
            standIn.command(arguments: NiruxMCPServer.claudeArguments(executable: "/test/Nirux")), in: column, harness: harness, asLaunchLine: true
        )
        let pty = try XCTUnwrap(column.pty)
        let snapshot = ProcessSnapshot()
        let foreground = try XCTUnwrap(pty.foregroundProcess(snapshot: snapshot))
        for name in turnEnded ? [AgentHookEvent.Name.userPromptSubmit, .stop] : [.userPromptSubmit] {
            let event = AgentHookEvent(kind: .claude, name: name, agentUUID: agentUUID, sessionID: sessionID,
                                       emitterProcess: process, timestamp: Date().timeIntervalSince1970)
            _ = column.admitClaudeHook(event, foregroundProcess: foreground, snapshot: snapshot)
            _ = pty.applyAgentHook(event, isUserFocused: false)
        }
        return (task, column, process)
    }

    /// The task's Claude ends, then its conversation resumes in the Lead's
    /// column, in the space's checkout, with the Lead's agent UUID and
    /// environment: the Lead's tasks report to it, a relaunch resumes it
    /// there, and a compaction rebuilds its system prompt from this launch.
    /// The task keeps its worktree, branch and row; its own Mission ends
    /// without a word to the Lead.
    func testPromotingATaskResumesItsConversationInTheLeadsColumn() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            let leadColumn = try XCTUnwrap(lead.workspace.leadTerminal)
            let leadPty = try XCTUnwrap(leadColumn.pty)
            let oldLead = AgentStandIn(), worker = AgentStandIn(), promoted = AgentStandIn()
            defer { oldLead.remove(); worker.remove(); promoted.remove() }
            let flags = NiruxMCPServer.claudeArguments(executable: "/test/Nirux")
            let original = try run(oldLead.command(arguments: flags), in: leadColumn, harness: harness)
            let question = try askLead(lead)
            let (taskID, taskUUID) = (UUID().uuidString, UUID().uuidString)
            let own = try XCTUnwrap(MissionStore.shared.create(MissionCreationRequest(
                id: UUID().uuidString, parentWorkspaceID: lead.workspace.id, parentAgentUUID: lead.agentUUID,
                childWorkspaceID: taskID, childAgentUUID: taskUUID, childAgentKind: "claude",
                branch: "feat/coordinator", reportsToLead: true
            ), enabled: true))
            let ownQuestion = MissionEvent(
                id: UUID().uuidString, missionID: own.id, childWorkspaceID: taskID, childAgentUUID: taskUUID,
                kind: .question, message: "Shall I merge it?", timestamp: Date().timeIntervalSince1970
            )
            guard case .accepted = MissionStore.shared.process(ownQuestion, enabled: false) else {
                return XCTFail("the task could not ask the Lead")
            }
            let sessionID = UUID().uuidString
            let (task, column, process) = try makeTask(
                "Coordinator", in: lead.space, sessionID: sessionID, standIn: worker, harness: harness,
                missionID: own.id, workspaceID: taskID, agentUUID: taskUUID
            )
            let branch = GitWorktree.currentBranch(at: harness.worktree)
            XCTAssertNotNil(branch)
            // Resumed in the task a moment ago: its column held the session
            // for the launch's grace, which ends with its agent.
            shell.sessionResume.noteLaunch(of: sessionID, in: column, now: ProcessInfo.processInfo.systemUptime)
            let restartTask = shell.sideEffects.restartTaskTerminal
            let promotedCommand = promoted.command(arguments: flags + ["--resume", sessionID], launchPrompt: NiruxShellView.leadPromotionPrompt)
            shell.sideEffects.restartTaskTerminal = { [weak harness] target, command, canStop, starts in
                harness?.restartedAgent = ":"
                restartTask(target, command, canStop, starts)
                harness?.restartedAgent = promotedCommand
            }

            harness.alertResponses = [.alertSecondButtonReturn]
            let index = try XCTUnwrap(shell.workspaces.firstIndex { $0 === task })
            harness.perform([NiruxShellView.promoteToLeadTitle], in: shell.sidebar.workspaceActionMenu(workspaceIndex: index, columnIndex: nil))
            XCTAssertEqual(harness.alerts.last, "Make “Coordinator” the Lead of “Tools”?", shell.toast?.message ?? "")
            harness.waitUntil("the promoted conversation in the Lead's column") {
                leadPty.foregroundProcess(snapshot: ProcessSnapshot())?.arguments.contains(sessionID) == true
            }
            XCTAssertEqual(harness.terminalRestarts.count, 2, "\(harness.terminalRestarts)")
            XCTAssertTrue(harness.terminalRestarts.first?.contains(NiruxShellView.promotionNoticeLine) == true)
            let command = try XCTUnwrap(harness.terminalRestarts.last)
            for part in ["command claude --resume " + NiruxShellView.shellQuotedArgument(sessionID),
                         NiruxShellView.leadPromotionPrompt, lead.workspace.cwd, harness.worktree] {
                XCTAssertTrue(command.contains(part), part)
            }
            XCTAssertNotEqual(ProcessInstance.running(pid: original.pid), original)
            XCTAssertNotEqual(ProcessInstance.running(pid: process.pid), process)
            XCTAssertIdentical(leadColumn, lead.workspace.leadTerminal)
            XCTAssertEqual(leadColumn.agentUUID, lead.agentUUID)
            XCTAssertEqual(leadColumn.launchDirectory, lead.workspace.cwd)
            XCTAssertEqual(leadColumn.launchEnvironment?[LeadChannel.environmentKey], "1")

            XCTAssertTrue(shell.workspaces.contains { $0 === task })
            XCTAssertEqual(GitWorktree.currentBranch(at: harness.worktree), branch)
            XCTAssertEqual(task.lastSummary, NiruxShellView.promotionNoticeLine)
            harness.waitUntil("the task's plain shell") {
                guard let pty = column.pty, let shellPID = pty.shellPID else { return false }
                return pty.foregroundProcess(snapshot: ProcessSnapshot())?.instance.pid == shellPID
            }
            XCTAssertEqual(MissionStore.shared.missions.first { $0.id == own.id }?.status, .completed)
            XCTAssertFalse(MissionStore.shared.pendingPromptDeliveries().contains { $0.event.id == ownQuestion.id })

            let relaunched = try XCTUnwrap(leadPty.foregroundProcess(snapshot: ProcessSnapshot()))
            XCTAssertTrue(lead.workspace.runsRestartedLead(relaunched))
            try reportFirstTurnEnded(in: leadPty, agentUUID: lead.agentUUID, sessionID: sessionID)
            shell.typeMissionMessages()
            harness.waitUntil("the Lead's question in the promoted conversation") { promoted.input.contains(question.message) }
            XCTAssertFalse(promoted.input.contains(ownQuestion.message))
            XCTAssertEqual(leadColumn.persistedClaudeRestore(foregroundProcess: relaunched), .resume(sessionID))
        }
    }

    /// Its sub-tasks become the Lead's tasks: their Missions report to the
    /// Lead's agent, a question one asked reaches the promoted conversation,
    /// and they list among the Lead's tasks.
    func testItsSubtasksFollowItToTheLead() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            let leadPty = try XCTUnwrap(lead.workspace.leadTerminal?.pty)
            let worker = AgentStandIn(), promoted = AgentStandIn()
            defer { worker.remove(); promoted.remove() }
            let sessionID = UUID().uuidString
            let (task, column, _) = try makeTask("Coordinator", in: lead.space, sessionID: sessionID, standIn: worker, harness: harness)
            let workerUUID = try XCTUnwrap(column.agentUUID)
            let (subtaskID, subtaskUUID) = (UUID().uuidString, UUID().uuidString)
            let mission = try XCTUnwrap(MissionStore.shared.create(MissionCreationRequest(
                id: UUID().uuidString, parentWorkspaceID: task.id, parentAgentUUID: workerUUID,
                childWorkspaceID: subtaskID, childAgentUUID: subtaskUUID, childAgentKind: "claude",
                branch: "feat/its-part", reportsToTask: true
            ), enabled: true))
            shell.addWorkspace(
                title: "Its part", cwd: harness.worktree, profileID: lead.space, workspaceID: subtaskID,
                initialAgentUUID: subtaskUUID, missionID: mission.id, parentWorkspaceID: task.id, reportsToTask: true
            )
            let subtask = try XCTUnwrap(shell.workspaces.first { $0.id == subtaskID })
            XCTAssertEqual(subtask.parentWorkspaceID, task.id)
            let question = MissionEvent(
                id: UUID().uuidString, missionID: mission.id, childWorkspaceID: subtaskID, childAgentUUID: subtaskUUID,
                kind: .question, message: "Which endpoint?", timestamp: Date().timeIntervalSince1970
            )
            guard case .accepted = MissionStore.shared.process(question, enabled: false) else { return XCTFail("the sub-task could not ask") }
            let promotedCommand = promoted.command(
                arguments: NiruxMCPServer.claudeArguments(executable: "/test/Nirux") + ["--resume", sessionID],
                launchPrompt: NiruxShellView.leadPromotionPrompt
            )
            let restartTask = shell.sideEffects.restartTaskTerminal
            shell.sideEffects.restartTaskTerminal = { [weak harness] target, command, canStop, starts in
                harness?.restartedAgent = ":"
                restartTask(target, command, canStop, starts)
                harness?.restartedAgent = promotedCommand
            }
            harness.alertResponses = [.alertSecondButtonReturn]
            shell.requestLeadPromotion(of: task)
            harness.waitUntil("the promoted conversation in the Lead's column") {
                leadPty.foregroundProcess(snapshot: ProcessSnapshot())?.arguments.contains(sessionID) == true
            }
            XCTAssertNil(subtask.parentWorkspaceID)
            let moved = try XCTUnwrap(MissionStore.shared.missions.first { $0.id == mission.id })
            XCTAssertEqual(moved.parentWorkspaceID, lead.workspace.id)
            XCTAssertEqual(moved.parentAgentUUID, lead.agentUUID)
            XCTAssertEqual(moved.reportsToLead, true)
            XCTAssertNil(moved.reportsToTask)
            try reportFirstTurnEnded(in: leadPty, agentUUID: lead.agentUUID, sessionID: sessionID)
            shell.typeMissionMessages()
            harness.waitUntil("the sub-task's question in the promoted conversation") { promoted.input.contains(question.message) }
        }
    }

    /// Mid-turn, the task's conversation stays where it is: nothing asks,
    /// nothing stops. Neither the Lead, a task opened from outside Nirux nor
    /// a sub-task is promoted.
    func testATaskIsPromotedOnlyAtRest() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            let worker = AgentStandIn()
            defer { worker.remove() }
            let sessionID = UUID().uuidString
            let (task, column, process) = try makeTask(
                "Busy", in: lead.space, sessionID: sessionID, standIn: worker, harness: harness, turnEnded: false
            )
            // A silent stand-in reads idle after a while: its turn starts again now.
            _ = try XCTUnwrap(column.pty).applyAgentHook(AgentHookEvent(
                kind: .claude, name: .userPromptSubmit, agentUUID: try XCTUnwrap(column.agentUUID), sessionID: sessionID,
                emitterProcess: process, timestamp: Date().timeIntervalSince1970
            ), isUserFocused: false)
            XCTAssertEqual(column.liveAgent(snapshot: ProcessSnapshot())?.status, .working)
            XCTAssertTrue(shell.offersLeadPromotion(task))
            XCTAssertFalse(shell.offersLeadPromotion(lead.workspace))
            shell.requestLeadPromotion(of: task)
            XCTAssertEqual(shell.toast?.message, "The task’s agent is working. Promote it once its turn ends.")
            XCTAssertTrue(harness.alerts.isEmpty)
            XCTAssertTrue(harness.terminalRestarts.isEmpty)
            XCTAssertEqual(ProcessInstance.running(pid: process.pid), process)
            shell.addWorkspace(title: "From a link", cwd: harness.worktree, profileID: lead.space, startedOutsideNirux: true)
            XCTAssertFalse(shell.offersLeadPromotion(try XCTUnwrap(shell.activeWorkspace)), "opened from outside Nirux")
            shell.addWorkspace(title: "Its part", cwd: harness.worktree, profileID: lead.space, parentWorkspaceID: task.id)
            let subtask = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertEqual(subtask.parentWorkspaceID, task.id)
            shell.requestLeadPromotion(of: subtask)
            XCTAssertEqual(shell.toast?.message, "A sub-task can’t become the Lead: its task waits for it. Promote its task instead.")
        }
    }

    /// A space with no Lead gets one, in its checkout, holding the
    /// promoted conversation.
    func testPromotingATaskOfASpaceWithoutALeadStartsOne() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.projectBoardClient = ProjectBoardFlowTests.FakeGitHub(openPullRequests: "[]", runs: "[]")
            let repository = SpaceAnchor(kind: .gitRepository(commonDir: harness.repo + "/.git"), name: "repo", isDefault: true)
            let space = shell.workspaceStore.createProfile(named: "Solo", anchors: [repository], select: true).id
            let worker = AgentStandIn()
            defer { worker.remove() }
            let sessionID = UUID().uuidString
            let (task, _, process) = try makeTask("Grown", in: space, sessionID: sessionID, standIn: worker, harness: harness)
            harness.alertResponses = [.alertSecondButtonReturn]
            shell.requestLeadPromotion(of: task)
            XCTAssertEqual(harness.alerts.last, "Make “Grown” the Lead of “Solo”?", shell.toast?.message ?? "")
            harness.waitUntil("the new Lead's launch") { harness.agentLaunches.contains { $0.contains("--resume") } }
            let lead = try XCTUnwrap(shell.leadWorkspace(inSpace: space))
            let column = try XCTUnwrap(lead.leadTerminal)
            let command = try XCTUnwrap(harness.agentLaunches.last)
            XCTAssertTrue(command.hasPrefix("command claude --resume " + NiruxShellView.shellQuotedArgument(sessionID)), command)
            XCTAssertTrue(command.contains(NiruxShellView.leadPromotionPrompt), command)
            XCTAssertEqual(harness.agentLaunches.filter { $0.hasPrefix("command ") }.count, 1, "no fresh Lead launched beside it")
            XCTAssertEqual(column.launchDirectory, harness.repo)
            XCTAssertEqual(column.launchEnvironment?[LeadChannel.environmentKey], "1")
            XCTAssertNotEqual(ProcessInstance.running(pid: process.pid), process)
            XCTAssertTrue(shell.workspaces.contains { $0 === task })
        }
    }
}
