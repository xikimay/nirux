import AppKit
import XCTest
@testable import Nirux

@MainActor
final class CodexTaskFlowTests: XCTestCase {
    private func setMode(_ mode: CodexLaunchMode, in space: String) throws {
        _ = try XCTUnwrap(SpaceDefaultsStore(spaceID: space)).save(SpaceDefaults(agent: .codex, codexLaunchMode: mode)).get()
    }

    /// Run the launch through a shell so a flag embedded in the prompt cannot satisfy an argv assertion.
    private func arguments(_ command: String?, in harness: UIFlowHarness) throws -> [String] {
        let executable = URL(fileURLWithPath: harness.root + "/codex")
        try "#!/bin/sh\nfor arg do printf '%s\\0' \"$arg\"; done\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", try XCTUnwrap(command)]
        process.environment = ["PATH": harness.root + ":/usr/bin:/bin", "HOME": harness.home]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    func testNativeLeadAndChildLaunchWithTheirSpaceMode() throws {
        try UIFlowHarness.run { harness in
            let lead = try harness.makeLead()
            try setMode(.bypass, in: lead.space)
            let started = try harness.callLeadTool(LeadTools.startTask, ["description": "Review fixture"], lead: lead)
            XCTAssertFalse(started.isError, started.text)
            XCTAssertEqual(try arguments(harness.agentLaunches.last, in: harness).first, CodexLaunchMode.bypass.cliArgs.first)

            let task = try XCTUnwrap(harness.shell.workspaces.first { $0.title == "Review fixture" })
            let child = try harness.callLeadTool(LeadTools.startTask, ["description": "Check fixture"], from: task,
                                                 agentUUID: try XCTUnwrap(task.columns.first?.agentUUID))
            XCTAssertFalse(child.isError, child.text)
            XCTAssertEqual(try arguments(harness.agentLaunches.last, in: harness).first, CodexLaunchMode.bypass.cliArgs.first)
        }
    }

    func testExternalWorktreeUsesTheModeShownOnTheSheet() throws {
        try UIFlowHarness.run { harness in
            let space = try NewTaskFlowTests.anchoredSpace(harness)
            try setMode(.bypass, in: space.id)
            let app = NiruxApp()
            app.shell = harness.shell
            app.mainWindow = harness.window
            var link = URLComponents()
            link.scheme = "nirux"
            link.host = "new-worktree"
            link.queryItems = ["repo": harness.repo, "branch": harness.worktreeBranch, "agent": "codex", "title": "Check release notes",
                               "profile": "untrusted", "mode": "readOnly", "parentWorkspace": "untrusted"].map(URLQueryItem.init)
            app.application(NSApp, open: [try XCTUnwrap(link.url)])
            harness.waitUntil("the external worktree confirmation") { harness.window.attachedSheet != nil }
            let sheet = try XCTUnwrap(harness.window.attachedSheet)
            let content = try XCTUnwrap(sheet.contentView)
            XCTAssertNotNil(UIFlowHarness.descendant(of: content, as: NSTextField.self) {
                $0.stringValue.contains("Space: " + space.name) && $0.stringValue.contains(CodexLaunchMode.bypass.displayName)
            })
            try setMode(.readOnly, in: space.id)
            harness.window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            harness.waitUntil("Codex launches in the approved worktree") { harness.agentLaunches.last?.hasPrefix("command codex") == true }
            let opened = try XCTUnwrap(harness.shell.activeWorkspace)
            XCTAssertEqual(opened.title, "Check release notes")
            XCTAssertEqual(opened.profileID, space.id)
            XCTAssertTrue(opened.startedOutsideNirux)
            XCTAssertNil(opened.missionID)
            XCTAssertEqual(try arguments(harness.agentLaunches.last, in: harness), CodexLaunchMode.bypass.cliArgs)
        }
    }

    func testOpeningCodexAndResumingFromHistoryInAnExternalWorkspaceUseTheCurrentSpaceMode() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let space = try NewTaskFlowTests.anchoredSpace(harness)
            XCTAssertNil(Persistence.load()?.settings?.codexLaunchMode)
            try setMode(.readOnly, in: space.id)
            let confirmed = shell.codexLaunchForConfirmation(in: space.id)
            try setMode(.bypass, in: space.id)
            shell.openRequestedWorkspace(title: "External", cwd: harness.worktree, agent: .codex, requestedSpaceID: nil,
                                         startedOutsideNirux: true, confirmedCodexLaunch: confirmed)
            harness.waitUntil("the confirmed external launch") { harness.agentLaunches.count == 1 }
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertTrue(workspace.startedOutsideNirux)
            XCTAssertEqual(try arguments(harness.agentLaunches.last, in: harness), CodexLaunchMode.readOnly.cliArgs)

            harness.runPaletteCommand("Open Codex")
            XCTAssertIdentical(shell.activeWorkspace, workspace)
            XCTAssertEqual(try arguments(harness.agentLaunches.last, in: harness), CodexLaunchMode.bypass.cliArgs)

            let record = SessionHistoryFlowTests.session(UUID().uuidString.lowercased(), title: "Resume this conversation",
                                                         folder: harness.worktree, agent: .codex, workspaceID: workspace.id)
            try SessionHistoryFlowTests.seed([record], in: harness)
            harness.runPaletteCommand("Resume this conversation")
            harness.waitUntil("Session History opens the third Codex column") { harness.agentLaunches.count == 3 }
            XCTAssertIdentical(shell.activeWorkspace, workspace)
            XCTAssertEqual(try arguments(harness.agentLaunches.last, in: harness),
                           ["resume", record.sessionID, "-C", harness.worktree] + CodexLaunchMode.bypass.cliArgs)
        }
    }

    func testResumeWithCodexInAnExternalClaudeTaskUsesTheDestinationSpaceMode() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let space = try NewTaskFlowTests.anchoredSpace(harness)
            XCTAssertNil(Persistence.load()?.settings?.codexLaunchMode)
            try setMode(.bypass, in: space.id)
            shell.openRequestedWorkspace(title: "External task", cwd: harness.worktree, agent: .claude,
                                         requestedSpaceID: nil, startedOutsideNirux: true)
            harness.waitUntil("the external task opens") { shell.activeWorkspace?.title == "External task" }
            let task = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertEqual(task.profileID, space.id)
            XCTAssertTrue(task.startedOutsideNirux)
            let pty = try XCTUnwrap(task.columns.first?.pty)
            let claude = AgentStandIn(), codex = AgentStandIn()
            defer {
                claude.remove()
                codex.remove()
            }
            harness.waitUntil("the task shell starts") { pty.shellPID != nil }
            pty.sendShellLaunchCommand("(\(claude.command()))")
            harness.waitUntil("Claude owns the task terminal") { pty.foregroundProcess(snapshot: ProcessSnapshot())?.interactiveAgent == .claude }
            harness.restartedAgent = codex.command(named: "codex")
            harness.alertResponses = [.alertSecondButtonReturn]
            shell.showResumeTask(task)
            harness.waitUntil("Codex resumes the same task") {
                !shell.resumingTasks.contains(task.id) && pty.foregroundProcess(snapshot: ProcessSnapshot())?.interactiveAgent == .codex
            }
            XCTAssertEqual(harness.terminalRestarts.count, 1)
            XCTAssertEqual(try arguments(harness.terminalRestarts.first, in: harness).first, "--dangerously-bypass-approvals-and-sandbox")
        }
    }

    func testExternalWorkspaceConfirmsAChangedDestinationBeforeStarting() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let space = try NewTaskFlowTests.anchoredSpace(harness)
            try setMode(.bypass, in: space.id)
            let confirmed = shell.codexLaunchForConfirmation(in: space.id)
            XCTAssertTrue(shell.workspaceStore.setAnchors([], forProfile: space.id))
            try setMode(.readOnly, in: WorkspaceProfile.defaultID)
            @MainActor func open() {
                shell.openRequestedWorkspace(title: "Moved", cwd: harness.worktree, agent: .codex, requestedSpaceID: nil,
                                             startedOutsideNirux: true, confirmedCodexLaunch: confirmed)
            }
            open()
            harness.waitUntil("the new destination's confirmation") { !harness.alerts.isEmpty }
            XCTAssertNil(shell.workspaces.first { $0.title == "Moved" })
            XCTAssertTrue(harness.alertDetails.last?.contains(CodexLaunchMode.readOnly.displayName) == true)
            harness.alertResponses = [.alertSecondButtonReturn]
            open()
            harness.waitUntil("the confirmed destination opens") { shell.workspaces.contains { $0.title == "Moved" } }
            XCTAssertEqual(shell.activeWorkspace?.profileID, WorkspaceProfile.defaultID)
            XCTAssertEqual(try arguments(harness.agentLaunches.last, in: harness), CodexLaunchMode.readOnly.cliArgs)
        }
    }

    func testExternalCodexRequestWithoutAConfirmedModeWaitsForConsent() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let space = try NewTaskFlowTests.anchoredSpace(harness)
            try setMode(.bypass, in: space.id)
            shell.openRequestedWorkspace(title: "External", cwd: harness.worktree, agent: .codex, requestedSpaceID: nil,
                                         startedOutsideNirux: true)
            harness.waitUntil("the destination mode confirmation") { !harness.alerts.isEmpty }
            XCTAssertTrue(harness.alertDetails.last?.contains(CodexLaunchMode.bypass.displayName) == true)
            XCTAssertTrue(harness.agentLaunches.isEmpty)
            XCTAssertFalse(shell.workspaces.contains { $0.title == "External" })
        }
    }

    func testDecliningCodexInAReroutedWorktreeKeepsTheWorktreeWithoutStartingAnAgent() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let space = try NewTaskFlowTests.anchoredSpace(harness)
            try setMode(.bypass, in: space.id)
            let confirmed = shell.codexLaunchForConfirmation(in: space.id)
            XCTAssertTrue(shell.workspaceStore.setAnchors([], forProfile: space.id))
            shell.createWorktreeWorkspace(branch: harness.worktreeBranch, repoRoot: harness.repo, agent: .codex,
                                          startedOutsideNirux: true, confirmedCodexLaunch: confirmed)
            harness.waitUntil("the worktree opens after declining the new destination") {
                shell.activeWorkspace?.title == harness.worktreeBranch
            }
            XCTAssertEqual(shell.activeWorkspace?.profileID, WorkspaceProfile.defaultID)
            XCTAssertTrue(harness.alertDetails.last?.contains(CodexLaunchMode.default.displayName) == true)
            XCTAssertTrue(harness.agentLaunches.isEmpty)
        }
    }

    func testLazyRestoreResolvesMissingModesAtLaunchAndKeepsRecordedChoices() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let space = try NewTaskFlowTests.anchoredSpace(harness)
            try setMode(.readOnly, in: space.id)
            var state = shell.persistedState()
            let cases: [(String, Bool, CodexLaunchMode?)] = [
                ("native", false, nil), ("explicit", false, .default), ("outside", true, nil), ("recorded", true, .readOnly)
            ]
            for (title, outside, mode) in cases {
                let column = PersistedColumn(widthPreset: 1, cwd: harness.repo, columnType: .codex, webViewURL: nil,
                                             claudeLaunchMode: nil, codexLaunchMode: mode, codexSessionID: UUID().uuidString)
                state.workspaces.append(PersistedWorkspace(id: title, title: title, cwd: harness.repo, columns: [column],
                                                          focusedColumnIndex: 0, profileID: space.id, startedOutsideNirux: outside))
            }
            XCTAssertTrue(Persistence.save(state))
            shell.restoreState()
            try setMode(.bypass, in: space.id)
            XCTAssertTrue(shell.resumeAllDeferredAgents())
            XCTAssertEqual(harness.restoredAgentLaunches.count, 3)
            let launches = try harness.restoredAgentLaunches.map { try arguments($0, in: harness) }
            for (title, _, mode) in cases where title != "outside" {
                let id = try XCTUnwrap(state.workspaces.first { $0.title == title }?.columns.first?.codexSessionID)
                XCTAssertTrue(launches.contains(["resume", id] + (mode ?? .bypass).cliArgs), title)
            }
            let legacy = try XCTUnwrap(shell.workspaces.first { $0.id == "outside" })
            let column = try XCTUnwrap(legacy.columns.first)
            XCTAssertTrue(column.isAwaitingResume)
            XCTAssertTrue(harness.alerts.isEmpty)
            XCTAssertFalse(shell.resumeDeferredAgent(column, in: legacy), "Cancel keeps the column paused")
            harness.alertResponses = [.alertSecondButtonReturn]
            XCTAssertTrue(shell.resumeDeferredAgent(column, in: legacy))
            XCTAssertEqual(try arguments(harness.restoredAgentLaunches.last, in: harness).last, CodexLaunchMode.bypass.cliArgs.first)
            XCTAssertEqual(column.restoredColumn?.codexLaunchMode, .bypass)
        }
    }
}

extension CodexTaskFlowTests {
    func testOnlyTheCodexWithABlockingChoiceNeedsTheUser() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let space = try NewTaskFlowTests.anchoredSpace(harness)
            let first = try XCTUnwrap(shell.activeWorkspace)
            shell.addWorkspace(title: "Second", cwd: harness.repo, profileID: space.id)
            let second = try XCTUnwrap(shell.activeWorkspace)
            let standIn = AgentStandIn()
            defer { standIn.remove() }
            first.addColumn(command: standIn.command(named: "codex", arguments: CodexLaunchMode.bypass.cliArgs),
                            agentUUID: UUID().uuidString, cwd: harness.repo)
            second.addColumn(command: standIn.command(named: "codex"), agentUUID: UUID().uuidString, cwd: harness.repo)
            let a = try XCTUnwrap(first.columns.last)
            let b = try XCTUnwrap(second.columns.last)
            harness.waitUntil("both Codex processes") {
                let snapshot = ProcessSnapshot()
                return [a, b].allSatisfy { $0.pty?.foregroundProcess(snapshot: snapshot)?.name == "codex" }
            }
            let saved = shell.persistedState()
            XCTAssertEqual(saved.workspaces.first { $0.id == first.id }?.columns.last?.codexLaunchMode, .bypass)
            XCTAssertEqual(saved.workspaces.first { $0.id == second.id }?.columns.last?.codexLaunchMode, .default)
            @MainActor func report(_ payload: String, to column: ColumnState) throws {
                var scanner = AgentProgramStatus.Scanner()
                let event = try XCTUnwrap(scanner.statuses(in: AgentProgramStatus.prefix + payload + "\u{1b}\\").first)
                column.pty?.onProgramStatus?(event)
            }
            @MainActor func row(_ task: WorkspaceState) throws -> WorkspaceInfo {
                shell.updateSidebar()
                return try XCTUnwrap(shell.sidebar.displayedWorkspaceInfos.first { $0.id == task.id })
            }
            try report("state=working:app=codex", to: a)
            try report("state=working:app=codex", to: b)
            try report("state=blocked:app=codex:kind=permission", to: a)
            XCTAssertEqual(try row(first).rowSummary.status.text, "Needs you · approval in Codex")
            XCTAssertEqual(try row(second).rowSummary.mark, .working)
            try report("state=blocked:app=codex:kind=question", to: b)
            let question = try row(second)
            XCTAssertEqual(question.rowSummary.status.text, "Needs you · choose an option in Codex")
            XCTAssertEqual(BoardStages.TaskReading(question, summary: nil, gitRoot: nil).activity, .needsYou("choose an option in Codex"))
            XCTAssertTrue(shell.taskListHead(second, in: space, parentTitle: nil, snapshot: ProcessSnapshot())
                .contains("Needs you · choose an option in Codex"))
            guard case .blockedByDialog = shell.sendTypedPrompt(agentUUID: try XCTUnwrap(b.agentUUID), prompt: "Check the fixture")
            else { return XCTFail("A prompt could answer the choice") }
            try report("state=working:app=codex", to: a)
            XCTAssertEqual(try row(first).rowSummary.mark, .working)
            XCTAssertEqual(try row(second).rowSummary.mark, .needsYou)
            try report("state=idle:app=codex", to: b)
            XCTAssertNotEqual(try row(second).rowSummary.mark, .needsYou)
            XCTAssertFalse(shell.taskListHead(second, in: space, parentTitle: nil, snapshot: ProcessSnapshot()).contains("Needs you"))
            XCTAssertTrue(standIn.input.isEmpty)
        }
    }
}
