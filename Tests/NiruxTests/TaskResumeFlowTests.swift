import AppKit
import XCTest
@testable import Nirux

@MainActor
final class TaskResumeFlowTests: XCTestCase {
    func testModelChoiceAndCLIArguments() throws {
        func command(_ choice: TaskAgentChoice, prompt: String) throws -> String {
            switch choice.agent {
            case .claude: return NiruxShellView.claudeCommand(mode: .default, model: choice.model, handoverPrompt: prompt)
            case .codex: return NiruxShellView.codexCommand(mode: .default, model: choice.model, handoverPrompt: prompt)
            case .agy: return NiruxShellView.agyCommand(model: choice.model, handoverPrompt: prompt)
            default: throw XCTSkip("This CLI cannot launch a task")
            }
        }
        for agent in CodingAgent.launchable {
            let omitted = try TaskAgentChoice.parse(["agent": agent.rawValue]).get()
            let blank = try TaskAgentChoice.parse(["agent": agent.rawValue, "model": " "]).get()
            XCTAssertEqual(omitted, blank)
            XCTAssertFalse(try command(omitted, prompt: "continue").contains("--model"))
            let chosen = try TaskAgentChoice.parse(["agent": agent.rawValue, "model": "vendor/model's-v2"]).get()
            let args = try command(chosen, prompt: "continue")
            XCTAssertTrue(args.contains("--model " + NiruxShellView.shellQuotedArgument("vendor/model's-v2")))
            XCTAssertTrue(args.hasSuffix(agent == .agy ? "-i 'continue'" : "'continue'"))
        }
        for arguments: [String: Any] in [["agent": "unknown"], ["agent": "codex", "model": 7],
                                          ["agent": "agy", "model": "x\ny"], ["agent": "claude", "model": "--help"]] {
            XCTAssertThrowsError(try TaskAgentChoice.parse(arguments).get())
        }
    }

    func testAnInheritedBlockingQuestionReachesTheNewPrompt() throws {
        let store = MissionStore(persistsToDisk: false)
        let mission = try XCTUnwrap(store.create(MissionCreationRequest(
            id: UUID().uuidString, parentWorkspaceID: UUID().uuidString, parentAgentUUID: UUID().uuidString,
            childWorkspaceID: UUID().uuidString, childAgentUUID: UUID().uuidString, childAgentKind: "agy",
            branch: "feat/report", reportsToLead: true
        ), enabled: false))
        let question = MissionEvent(
            id: UUID().uuidString, missionID: mission.id, childWorkspaceID: mission.childWorkspaceID,
            childAgentUUID: mission.childAgentUUID, kind: .question, message: "Which date?", timestamp: 1
        )
        XCTAssertNotNil(store.accept(question, enabled: false))
        XCTAssertTrue(store.resumeWorker(workspaceID: mission.childWorkspaceID, agentUUID: mission.childAgentUUID,
                                         missionID: mission.id, as: .codex))
        let response = MissionEvent(
            id: UUID().uuidString, missionID: mission.id, childWorkspaceID: mission.childWorkspaceID,
            childAgentUUID: mission.childAgentUUID, parentWorkspaceID: mission.parentWorkspaceID,
            parentAgentUUID: mission.parentAgentUUID, kind: .response, message: "Friday", inReplyTo: question.id, timestamp: 2
        )
        XCTAssertNotNil(store.accept(response, enabled: false))
        let delivery = try XCTUnwrap(store.pendingAnswer(childWorkspaceID: mission.childWorkspaceID, childAgentUUID: mission.childAgentUUID))
        XCTAssertEqual(delivery.event.message, "Friday")
        XCTAssertEqual(NiruxShellView.recipientAgent(of: delivery), .codex)
    }

    private func startWorker(
        _ worker: AgentStandIn, named agent: String, harness: UIFlowHarness, lead: UIFlowHarness.Lead
    ) throws -> (WorkspaceState, PtySession, ProcessInstance) {
        let title = "Review invoices"
        let started = try harness.callLeadTool(
            LeadTools.startTask, ["description": title, "repo": LeadTools.noRepository], lead: lead
        )
        XCTAssertFalse(started.isError, started.text)
        let task = try XCTUnwrap(harness.shell.workspaces.first { $0.title == title })
        let pty = try XCTUnwrap(task.columns.first?.pty)
        harness.waitUntil("task shell") { pty.shellPID != nil }
        pty.sendShellLaunchCommand("(\(worker.command(named: agent)))")
        harness.waitUntil("original worker") { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == agent }
        let process = try XCTUnwrap(pty.foregroundProcess(snapshot: ProcessSnapshot())).instance
        return (task, pty, process)
    }

    func testLeadPreservesDraftTypedDuringHandoverAndRetriesAfterSubmission() throws {
        try UIFlowHarness.run { harness in
            let lead = try harness.makeLead()
            let old = AgentStandIn(), replacement = AgentStandIn()
            defer {
                old.remove()
                replacement.remove()
            }
            let (task, pty, process) = try startWorker(old, named: "claude", harness: harness, lead: lead)
            let sessionID = UUID().uuidString
            let workerID = try XCTUnwrap(task.columns.first?.agentUUID)
            harness.shell.sessionLedger.record(AgentSessionObservation(
                agent: .claude, sessionID: sessionID, event: .userPromptSubmit, source: nil, timestamp: Date().timeIntervalSince1970,
                agentProcess: process, name: nil, cwd: task.cwd, transcriptPath: nil, checkout: nil, pullRequest: nil,
                workspaceID: task.id, workspaceTitle: task.title, agentUUID: workerID, columnIndex: 0
            ), spaceID: lead.space)
            let arguments = ["task": task.title, "agent": "codex"]
            harness.restartedAgent = replacement.command(named: "codex")
            let request = LeadChannel.Request(
                id: UUID().uuidString, tool: LeadTools.resumeTask,
                arguments: String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self),
                workspaceID: lead.workspace.id, agentUUID: lead.agentUUID, createdAt: Date().timeIntervalSince1970
            )
            var refusal: String?
            harness.shell.handleLeadRequest(request) { message, failed in
                XCTAssertTrue(failed, message)
                refusal = message
            }
            XCTAssertNil(refusal)
            let draft = "Keep the original invoice dates."
            // Keep the main queue occupied until the bytes have reached the old PTY.
            let wrote = DispatchSemaphore(value: 0)
            let terminal = pty.terminalSession
            DispatchQueue.global().async {
                terminal.sendInput(Data(draft.utf8))
                wrote.signal()
            }
            XCTAssertEqual(wrote.wait(timeout: .now() + 5), .success)
            harness.waitUntil("draft reached the original worker and held the switch") { old.input == draft && refusal != nil }
            let existing = try harness.callLeadTool(LeadTools.resumeTask, arguments, lead: lead)
            XCTAssertTrue(existing.isError, existing.text)
            XCTAssertEqual(refusal, existing.text)
            XCTAssertTrue(existing.text.contains("unsent draft"), existing.text)
            XCTAssertTrue(existing.text.contains("retry"), existing.text)
            XCTAssertTrue(harness.terminalRestarts.isEmpty)
            XCTAssertEqual(pty.foregroundProcess(snapshot: ProcessSnapshot())?.instance, process)
            XCTAssertEqual(harness.shell.sessionLedger.session(agent: .claude, sessionID: sessionID)?.isActive, true)
            XCTAssertEqual(old.input, draft)

            pty.sendRaw("\r")
            for name in [AgentHookEvent.Name.userPromptSubmit, .stopFailure] {
                _ = pty.applyAgentHook(AgentHookEvent(
                    kind: .claude, name: name, agentUUID: workerID, sessionID: sessionID, emitterProcess: process,
                    errorKind: name == .stopFailure ? "rate_limit" : nil, timestamp: Date().timeIntervalSince1970
                ), isUserFocused: false)
            }
            XCTAssertEqual(pty.agentTurnFailure?.kind, "rate_limit")
            let resumed = try harness.callLeadTool(LeadTools.resumeTask, arguments, lead: lead)
            XCTAssertFalse(resumed.isError, resumed.text)
            XCTAssertEqual(harness.terminalRestarts.count, 1)
            XCTAssertEqual(harness.shell.sessionLedger.session(agent: .claude, sessionID: sessionID)?.isActive, false)
            XCTAssertEqual(pty.foregroundProcess(snapshot: ProcessSnapshot())?.name, "codex")
        }
    }

    func testCodexDraftDiscardOnlyAppliesToTheConfirmedDraft() throws {
        try UIFlowHarness.run { harness in
            let lead = try harness.makeLead()
            let old = AgentStandIn(), replacement = AgentStandIn()
            defer {
                old.remove()
                replacement.remove()
            }
            let (task, pty, process) = try startWorker(old, named: "codex", harness: harness, lead: lead)
            pty.sendRaw("Keep this")
            let refused = try harness.callLeadTool(LeadTools.resumeTask, ["task": task.title, "agent": "claude"], lead: lead)
            XCTAssertTrue(refused.isError, refused.text)
            XCTAssertTrue(refused.text.contains("draft"), refused.text)

            harness.alertResponses = [.alertSecondButtonReturn, .alertFirstButtonReturn]
            harness.shell.showResumeTask(task)
            XCTAssertEqual(harness.alerts.last, "Discard the draft in “\(task.title)”?")
            XCTAssertEqual(harness.alertDefaultButtons.last, "Cancel")
            XCTAssertTrue(harness.terminalRestarts.isEmpty)
            harness.alertResponses = [.alertSecondButtonReturn, .alertSecondButtonReturn]
            harness.shell.showResumeTask(task)
            pty.sendRaw(" amendment")
            harness.waitUntil("the edited draft held the switch") { !harness.shell.resumingTasks.contains(task.id) }
            XCTAssertEqual(pty.foregroundProcess(snapshot: ProcessSnapshot())?.instance, process)
            XCTAssertTrue(harness.terminalRestarts.isEmpty)
            harness.waitUntil("the draft reached the original Codex") { old.input == "Keep this amendment" }

            harness.restartedAgent = replacement.command()
            harness.alertResponses = [.alertSecondButtonReturn, .alertSecondButtonReturn]
            harness.shell.showResumeTask(task)
            harness.waitUntil("explicit discard switched CLI") {
                !harness.shell.resumingTasks.contains(task.id) && pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude"
            }
            XCTAssertEqual(harness.terminalRestarts.count, 1)
        }
    }

    func testFailedSwitchRetriesOnceAndReportsToOriginalLead() throws {
        let executable = try niruxExecutable()
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            let start = try harness.callLeadTool(LeadTools.startTask, ["description": "Check invoice dates"], lead: lead)
            XCTAssertFalse(start.isError, start.text)
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "Check invoice dates" })
            let store = MissionStore.shared
            let mission = try XCTUnwrap(store.missions.first { $0.childWorkspaceID == task.id })
            let column = try XCTUnwrap(task.columns.first { $0.agentUUID == mission.childAgentUUID })
            let pty = try XCTUnwrap(column.pty)
            let branch = try UIFlowHarness.git(["branch", "--show-current"], at: task.cwd)
            let dirty = URL(fileURLWithPath: task.cwd).appendingPathComponent("pending.txt")
            try Data("unfinished".utf8).write(to: dirty)
            task.nextStep = "Preserve the invoice format"
            let old = AgentStandIn()
            defer { old.remove() }
            harness.waitUntil("task shell") { pty.shellPID != nil }
            pty.sendShellLaunchCommand("(\(old.command()))")
            harness.waitUntil("old Claude worker") { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
            let original = try XCTUnwrap(pty.foregroundProcess(snapshot: ProcessSnapshot())).instance
            let pullRequest = try SidebarPanelFlowTests.redPullRequest()
            task.prInfo = pullRequest
            let previousID = UUID().uuidString
            shell.sessionLedger.record(AgentSessionObservation(
                agent: .claude, sessionID: previousID, event: .userPromptSubmit, source: nil,
                timestamp: Date().timeIntervalSince1970, agentProcess: original, name: nil, cwd: task.cwd,
                transcriptPath: nil, checkout: nil, pullRequest: nil, workspaceID: task.id,
                workspaceTitle: task.title, agentUUID: mission.childAgentUUID, columnIndex: 0
            ), spaceID: lead.space)
            let space = try XCTUnwrap(SpaceBrief.directory(spaceID: lead.space, stateDirectory: Persistence.stateDirectory))
            let threads = space.appendingPathComponent("threads")
            try FileManager.default.createDirectory(at: threads, withIntermediateDirectories: true)
            try Data(#"{"t":1,"kind":"request","text":"Retain the original timezone"}"#.utf8)
                .write(to: threads.appendingPathComponent("\(task.id).jsonl"))
            let choice = TaskAgentChoice(agent: .codex, model: "gpt-6.2-astra")
            let arguments = ["task": task.title, "agent": choice.agent.rawValue, "model": "gpt-6.2-astra"]
            harness.restartedAgent = "exit 19"
            var failure: String?
            shell.resumeTask(task, with: choice) { message, failed in
                XCTAssertTrue(failed)
                failure = message
            }
            var duplicate: String?
            shell.resumeTask(task, with: choice) { message, failed in
                XCTAssertTrue(failed)
                duplicate = message
            }
            XCTAssertEqual(duplicate, "This task is already switching CLI.")
            harness.waitUntil("the failed launch") { failure != nil }
            XCTAssertEqual(harness.terminalRestarts.count, 1)
            XCTAssertNotEqual(ProcessInstance.running(pid: original.pid), original)

            // xctest hosts the card. Its worker invokes the built Mission CLI, exactly as an installed CLI would.
            let state = store.fileURL.deletingLastPathComponent()
            let queue = MissionEventCenter(store: store, eventsURL: state.appendingPathComponent("mission-events.jsonl"))
            let received = URL(fileURLWithPath: harness.root).appendingPathComponent("reply")
            let cli = NiruxShellView.shellQuotedArgument(executable)
            let output = NiruxShellView.shellQuotedArgument(received.path)
            let worker = AgentStandIn()
            defer { worker.remove() }
            harness.restartedAgent = "export NIRUX_STATE_DIR=\(NiruxShellView.shellQuotedArgument(state.path)); "
                + "(\(cli) --mission ask --kind decision --message 'Which timezone?' --recommend UTC > \(output) && "
                + "\(cli) --mission completed --message 'Invoice verified') </dev/null & "
                + worker.command(named: "codex")
            let resumed = try harness.callLeadTool(LeadTools.resumeTask, arguments, lead: lead)
            XCTAssertFalse(resumed.isError, resumed.text)
            let command = try XCTUnwrap(harness.terminalRestarts.last)
            XCTAssertTrue(command.contains("command codex"))
            XCTAssertTrue(command.contains("--model 'gpt-6.2-astra'"))
            XCTAssertTrue(command.contains("Preserve the invoice format"))
            XCTAssertTrue(command.contains(NiruxShellView.waitingMission.replacingOccurrences(of: "'", with: "'\\''")))
            XCTAssertTrue(command.contains("Retain the original timezone"))
            XCTAssertTrue(command.contains(previousID))
            XCTAssertEqual(shell.sessionLedger.session(agent: .claude, sessionID: previousID)?.isActive, false)
            let repeated = try harness.callLeadTool(LeadTools.resumeTask, arguments, lead: lead)
            XCTAssertTrue(repeated.isError)
            XCTAssertTrue(repeated.text.contains("already runs codex"))
            XCTAssertEqual(harness.terminalRestarts.count, 2, "a successful activation cannot repeat")

            @MainActor func current() -> Mission? { store.missions.first { $0.id == mission.id } }
            harness.waitUntil("the replacement's question") {
                _ = queue.drain()
                return current()?.events.contains { $0.kind == .question } == true
            }
            let question = try XCTUnwrap(current()?.events.first { $0.kind == .question })
            let list = try harness.callLeadTool(LeadTools.listTasks, lead: lead)
            XCTAssertTrue(list.text.contains(question.id), list.text)
            let reply = try harness.callLeadTool(LeadTools.reply, ["question": question.id, "message": "Use UTC"], lead: lead)
            XCTAssertFalse(reply.isError, reply.text)
            harness.waitUntil("the replacement's completion on the same Mission") {
                _ = queue.drain()
                return current()?.status == .completed
            }
            XCTAssertEqual(try String(contentsOf: received, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "Use UTC")
            XCTAssertEqual(current()?.parentWorkspaceID, lead.workspace.id)
            XCTAssertEqual(current()?.childAgentUUID, column.agentUUID)
            XCTAssertEqual(current()?.childAgentKind, "codex")
            XCTAssertEqual(current()?.events.last?.message, "Invoice verified")
            XCTAssertTrue(try harness.callLeadTool(LeadTools.listTasks, lead: lead).text.contains("Invoice verified"))
            XCTAssertEqual(task.prInfo, pullRequest)
            XCTAssertIdentical(shell.workspaces.first { $0.id == mission.childWorkspaceID }, task)
            XCTAssertEqual(try UIFlowHarness.git(["branch", "--show-current"], at: task.cwd), branch)
            XCTAssertEqual(try Data(contentsOf: dirty), Data("unfinished".utf8))
        }
    }
}
