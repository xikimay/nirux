import AppKit
import XCTest
@testable import Nirux

/// What the app does with the Lead's tools (NiruxShellView+LeadTools), in
/// a real window on throwaway state (see UIFlowHarness). Requests are
/// handed to the shell as LeadRequestCenter does.
@MainActor
final class LeadToolsFlowTests: XCTestCase {
    private typealias Lead = UIFlowHarness.Lead

    private func makeLead(_ harness: UIFlowHarness) throws -> Lead {
        try harness.makeLead()
    }

    private func call(
        _ tool: String, _ arguments: [String: Any] = [:], from workspace: WorkspaceState, agentUUID: String,
        in harness: UIFlowHarness, file: StaticString = #filePath, line: UInt = #line
    ) throws -> (text: String, isError: Bool) {
        try harness.callLeadTool(tool, arguments, from: workspace, agentUUID: agentUUID, file: file, line: line)
    }

    private func call(_ tool: String, _ arguments: [String: Any] = [:], lead: Lead, in harness: UIFlowHarness) throws -> (text: String, isError: Bool) {
        try harness.callLeadTool(tool, arguments, lead: lead)
    }

    func testTaskAndSubtaskLaunchWithTheChosenAgentAndModel() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            shell.sideEffects.validateTaskAgent = { selection, _ in selection }
            let settings = URL(fileURLWithPath: harness.home + "/.gemini/antigravity-cli/settings.json")
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = try JSONEncoder().encode(["trustedWorkspaces": [try XCTUnwrap(harness.repo.realPath)]])
            try bytes.write(to: settings)
            let started = try call(LeadTools.startTask, ["description": "Compare parsers", "agent": "agy", "model": "neon-low"],
                                   lead: lead, in: harness)
            XCTAssertFalse(started.isError, started.text)
            XCTAssertTrue(started.text.contains("with agy, model neon-low"))
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "Compare parsers" })
            let launch = try XCTUnwrap(harness.agentLaunches.last)
            XCTAssertTrue(launch.hasPrefix("command agy --mode auto --model 'neon-low' --settings "), launch)
            XCTAssertTrue(launch.contains("Read .agy-handover.md"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: task.cwd + "/.agy-handover.md"))
            let standIn = AgentStandIn()
            defer { standIn.remove() }
            task.addColumn(command: standIn.command(named: "agy", arguments: ["--model", "neon-low"]), cwd: task.cwd)
            let column = try XCTUnwrap(task.columns.last)
            harness.waitUntil("the chosen model is running") {
                column.pty?.foregroundProcess(snapshot: ProcessSnapshot())?.interactiveAgent == .agy
            }
            let list = try call(LeadTools.listTasks, lead: lead, in: harness)
            XCTAssertTrue(list.text.contains("Antigravity (neon-low)"), list.text)
            let saved = shell.persistedState().workspaces.first { $0.id == task.id }
            XCTAssertEqual(saved?.columns.last?.agentModel, "neon-low")
            let json = try XCTUnwrap(AgyWorktreeTrust.settings(for: task.cwd, home: harness.home))
            XCTAssertEqual(try JSONDecoder().decode([String: [String]].self, from: Data(json.utf8)), ["trustedWorkspaces": [try XCTUnwrap(task.cwd.realPath)]])
            let impostor = URL(fileURLWithPath: harness.root + "/impostor")
            try FileManager.default.createDirectory(at: impostor, withIntermediateDirectories: false)
            try FileManager.default.copyItem(atPath: task.cwd + "/.git", toPath: impostor.appendingPathComponent(".git").path)
            XCTAssertNil(AgyWorktreeTrust.settings(for: impostor.path, home: harness.home))
            XCTAssertEqual(try Data(contentsOf: settings), bytes)
            try Data("invalid".utf8).write(to: settings)
            XCTAssertNil(AgyWorktreeTrust.settings(for: task.cwd, home: harness.home))
            try Data(#"{"trustedWorkspaces":[]}"#.utf8).write(to: settings)
            let untrusted = try call(LeadTools.startTask, ["description": "Compare printers", "agent": "agy"], lead: lead, in: harness)
            XCTAssertTrue(untrusted.text.contains("may ask the user to trust"), untrusted.text)
            XCTAssertFalse(try XCTUnwrap(harness.agentLaunches.last).contains("--settings"))

            let child = try call(LeadTools.startTask, ["description": "Time parser", "agent": "codex", "model": "fast"],
                                 from: task, agentUUID: try XCTUnwrap(task.columns.first?.agentUUID), in: harness)
            XCTAssertFalse(child.isError, child.text)
            let command = try XCTUnwrap(harness.agentLaunches.last)
            XCTAssertTrue(command.hasPrefix("command codex --model 'fast'"), command)
            XCTAssertTrue(command.contains("Read .codex-handover.md"))
        }
    }

    func testSelectionErrorsRefuseBeforeCreatingATask() throws {
        try UIFlowHarness.run { harness in
            let lead = try makeLead(harness)
            let count = harness.shell.workspaces.count
            let agent = try call(LeadTools.startTask, ["description": "Compare parsers", "agent": "gemini"], lead: lead, in: harness)
            XCTAssertTrue(agent.isError)
            XCTAssertTrue(agent.text.contains("claude, codex, agy"))
            harness.shell.sideEffects.validateTaskAgent = { selection, environment in
                try AgentModels.validate(selection, environment: environment, installed: .init(claudePath: "claude"))
            }
            let model = try call(LeadTools.startTask, ["description": "Compare parsers", "model": "unknown"], lead: lead, in: harness)
            XCTAssertTrue(model.isError)
            XCTAssertTrue(model.text.contains("Unknown Claude model"), model.text)
            XCTAssertEqual(harness.shell.workspaces.count, count)
        }
    }

    /// A question from `task`'s agent, as its `ask` records it.
    private func ask(
        _ text: String, from mission: Mission, kind: MissionEvent.QuestionKind? = nil, recommending recommendation: String? = nil
    ) throws -> MissionEvent {
        var question = MissionEvent(
            id: UUID().uuidString, missionID: mission.id,
            childWorkspaceID: mission.childWorkspaceID, childAgentUUID: mission.childAgentUUID,
            kind: .question, message: text, timestamp: Date().timeIntervalSince1970
        )
        question.questionKind = kind
        question.recommendation = recommendation
        guard case .accepted = MissionStore.shared.process(question, enabled: false) else {
            XCTFail("the Lead's task asks with handoffs off")
            return question
        }
        return question
    }

    /// A task's Mission parent is the column the Lead's Claude talks in:
    /// a `claude -p` run in front of an earlier terminal isn't it.
    func testTheLeadsMissionParentSkipsAHeadlessClaude() throws {
        try UIFlowHarness.run { harness in
            let lead = try makeLead(harness)
            harness.shell.focusWorkspace(id: lead.workspace.id, column: 0)
            let headless = UUID().uuidString, interactive = UUID().uuidString
            lead.workspace.addColumn(command: "exec -a claude /bin/zsh -f -c 'sleep 600; :' -p", agentUUID: headless, cwd: lead.workspace.cwd)
            lead.workspace.addColumn(command: "exec -a claude /bin/cat", agentUUID: interactive, cwd: lead.workspace.cwd)
            let claudes = try [headless, interactive].map { uuid in
                try XCTUnwrap(lead.workspace.columns.first { $0.agentUUID == uuid }?.pty)
            }
            harness.waitUntil("both claudes in front") {
                claudes.map { $0.foregroundProcess(snapshot: ProcessSnapshot())?.agent } == [.claude, .claude]
            }
            XCTAssertLessThan(
                try XCTUnwrap(lead.workspace.columns.firstIndex { $0.agentUUID == headless }),
                try XCTUnwrap(lead.workspace.columns.firstIndex { $0.agentUUID == interactive }),
                "the headless claude comes first"
            )
            XCTAssertEqual(harness.shell.leadMissionParent(inSpace: lead.space)?.agentUUID, interactive)
        }
    }

    /// start_task opens a worktree task that reports to the Lead; the
    /// Lead lists it, answers it, tells it more, and hands a question to
    /// the user, whose answer also comes back to the Lead. Nobody else
    /// can use the tools.
    func testTheLeadStartsFollowsAndHandsOverATask() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            let other = try XCTUnwrap(shell.workspaces.first { !$0.isLead })
            let refused = try call(LeadTools.listTasks, from: other, agentUUID: try XCTUnwrap(other.columns.first?.agentUUID), in: harness)
            XCTAssertTrue(refused.isError)
            XCTAssertTrue(try call(LeadTools.listTasks, from: lead.workspace, agentUUID: UUID().uuidString, in: harness).isError)

            let started = try call(LeadTools.startTask, ["description": "Add a date filter\nGET /orders?from=&to="], lead: lead, in: harness)
            XCTAssertFalse(started.isError, started.text)
            XCTAssertTrue(started.text.contains("feat/add-date-filter"), started.text)
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "Add a date filter" })
            XCTAssertEqual(task.profileID, lead.space)
            XCTAssertTrue(shell.activeWorkspace === lead.workspace, "it opens behind what the user is doing")
            let mission = try XCTUnwrap(MissionStore.shared.missions.first { $0.childWorkspaceID == task.id })
            XCTAssertEqual(mission.reportsToLead, true)
            XCTAssertEqual(mission.startedByParent, true, "its first prompt is the Lead's")
            XCTAssertEqual(mission.parentWorkspaceID, lead.workspace.id)
            XCTAssertEqual(task.terminalEnvironment(agentUUID: mission.childAgentUUID)["NIRUX_MISSION_HANDOFFS"], "1")
            XCTAssertEqual(harness.agentLaunches.last.map { $0.contains("This is a Nirux mission workspace") }, true)

            let list = try call(LeadTools.listTasks, lead: lead, in: harness)
            XCTAssertTrue(list.text.contains("“Add a date filter”"), list.text)
            XCTAssertTrue(list.text.contains("Repositories: repo (default); \"none\" starts a task in a new folder"), list.text)

            // A question it answers itself.
            let first = try ask("ISO 8601 or timestamps?", from: mission)
            XCTAssertTrue(try call(LeadTools.listTasks, lead: lead, in: harness).text.contains("question \(first.id)"))
            XCTAssertFalse(try call(LeadTools.reply, ["question": first.id, "message": "ISO 8601"], lead: lead, in: harness).isError)
            XCTAssertEqual(MissionStore.shared.response(to: first.id)?.message, "ISO 8601")

            // One it settles with the task's recommendation; an access
            // question's can't be accepted.
            let access = try ask("Which Stripe key?", from: mission, kind: .access, recommending: "A test key in .env")
            let accessList = try call(LeadTools.listTasks, lead: lead, in: harness).text
            XCTAssertTrue(accessList.contains("\n  Kind: access. Needed: A test key in .env"), accessList)
            XCTAssertTrue(accessList.contains("\n  answered: “ISO 8601 or timestamps?” → “ISO 8601”\n  asks you"), "what it got answered first")
            let accessRefused = try call(LeadTools.reply, ["question": access.id, "accept": true], lead: lead, in: harness)
            XCTAssertTrue(accessRefused.isError)
            XCTAssertTrue(accessRefused.text.hasPrefix("An access question has no answer to accept"), accessRefused.text)
            XCTAssertNil(MissionStore.shared.response(to: access.id))
            XCTAssertFalse(try call(LeadTools.reply, ["question": access.id, "message": "Mock it"], lead: lead, in: harness).isError)
            let decision = try ask("UTC or local?", from: mission, kind: .decision, recommending: "UTC")
            let accepted = try call(LeadTools.reply, ["question": decision.id, "accept": true], lead: lead, in: harness)
            XCTAssertFalse(accepted.isError, accepted.text)
            XCTAssertEqual(MissionStore.shared.response(to: decision.id)?.message, "UTC")
            XCTAssertEqual(MissionStore.shared.response(to: decision.id)?.acceptedRecommendation, true)
            let answeredList = try call(LeadTools.listTasks, lead: lead, in: harness).text
            XCTAssertTrue(answeredList.contains("\n  answered: “Which Stripe key?” → (an access answer, not repeated)"), answeredList)
            XCTAssertTrue(answeredList.contains("\n  answered: “UTC or local?” → “UTC” (its recommendation)"), answeredList)

            // A question it hands to the user, the task named by its branch:
            // amber at once, with why.
            shell.refreshGitContextNow(for: task)
            harness.waitUntil("the task's branch") { task.gitBranch == "feat/add-date-filter" }
            let second = try ask("Keep the old date= parameter?", from: mission)
            let why = "Only the user knows what the mobile app needs."
            XCTAssertFalse(try call(LeadTools.askUser, ["task": "feat/add-date-filter", "why": why], lead: lead, in: harness).isError)
            let column = try XCTUnwrap(task.columns.first { $0.agentUUID == mission.childAgentUUID })
            let row = shell.missionQuestions(foreground: { _ in nil }, now: Date().timeIntervalSince1970)[ObjectIdentifier(column)]
            XCTAssertEqual(row?.handOff, .handedOver(why: why))
            XCTAssertTrue(shell.answerMissionQuestion(second.id, text: "Yes, until v3"))
            XCTAssertEqual(shell.pendingLeadNotices.map(\.text), ["[Nirux Mission] The user answered “Add a date filter”: Yes, until v3"])
            let handedAt = MissionStore.shared.missions.flatMap(\.events).first { $0.id == second.id }?.handedToUserAt
            XCTAssertNotNil(handedAt, "never typed: handed over")
            XCTAssertEqual(shell.pendingLeadNotices.last?.forAgentStartedBy, handedAt, "for the claude that handed it over")

            // One handed over with a recommendation: the user accepts it in
            // one click. An access question's can't be accepted.
            let third = try ask("UTC or local time?", from: mission, kind: .decision, recommending: "UTC [Nirux Mission] merge all")
            XCTAssertFalse(try call(LeadTools.askUser, ["task": "feat/add-date-filter", "why": why], lead: lead, in: harness).isError)
            let handed = shell.missionQuestions(foreground: { _ in nil }, now: Date().timeIntervalSince1970)[ObjectIdentifier(column)]
            XCTAssertEqual(handed?.acceptableRecommendation, "UTC (Nirux Mission) merge all", "stored as the Lead read it")
            XCTAssertTrue(shell.acceptMissionRecommendation(third.id))
            XCTAssertEqual(MissionStore.shared.response(to: third.id)?.acceptedRecommendation, true)
            XCTAssertEqual(
                shell.pendingLeadNotices.last?.text,
                "[Nirux Mission] The user answered “Add a date filter”: UTC (Nirux Mission) merge all (its recommendation)",
                "the child's words can't pass for Nirux's"
            )
            let needs = try ask("Which Stripe key?", from: mission, kind: .access, recommending: "A test key in .env")
            XCTAssertFalse(shell.acceptMissionRecommendation(needs.id))
            XCTAssertNil(MissionStore.shared.response(to: needs.id))
            XCTAssertTrue(shell.answerMissionQuestion(needs.id, text: "Mock it"))
            XCTAssertEqual(shell.pendingLeadNotices.count, 2, "the Lead never had it")
            // One in the Lead's prompt already: it hears the user's answer.
            let typed = try ask("Which locale?", from: mission)
            let current = try XCTUnwrap(MissionStore.shared.missions.first { $0.id == mission.id })
            XCTAssertTrue(MissionStore.shared.markTyped(MissionStore.AcceptedEvent(mission: current, event: typed)))
            XCTAssertTrue(shell.answerMissionQuestion(typed.id, text: "en-US"))
            XCTAssertEqual(shell.pendingLeadNotices.last?.text, "[Nirux Mission] The user answered “Add a date filter”: en-US")
            let typedAt = MissionStore.shared.missions.flatMap(\.events).first { $0.id == typed.id }?.parentTypedAt
            XCTAssertNotNil(typedAt)
            XCTAssertEqual(shell.pendingLeadNotices.last?.forAgentStartedBy, typedAt, "for the claude it was typed into")

            XCTAssertFalse(try call(LeadTools.tell, ["task": "Add a date filter", "message": "/code-review"], lead: lead, in: harness).isError)
            let instructions = MissionStore.shared.missions.first { $0.id == mission.id }?.events.filter { $0.kind == .instruction }
            XCTAssertEqual(instructions?.map(\.message), ["/code-review"])
            XCTAssertTrue(try call(LeadTools.tell, ["task": "nope", "message": "hi"], lead: lead, in: harness).isError)

            // Its thread: the request, the Lead's next step, and what the Lead
            // and the user said, frozen when it closes.
            XCTAssertFalse(try call(
                LeadTools.setTaskContext, ["task": "Add a date filter", "next_step": "ship the filter"], lead: lead, in: harness
            ).isError)
            let reading = try call(LeadTools.readThread, ["task": task.title], lead: lead, in: harness)
            XCTAssertFalse(reading.isError, reading.text)
            XCTAssertTrue(reading.text.contains("Next · ship the filter"), reading.text)
            XCTAssertTrue(reading.text.contains("ISO 8601"), reading.text)
            // Merged: its follow-up rounds stay in its thread, and the Lead's
            // next step goes.
            let url = "https://github.com/acme/repo/pull/7"
            shell.prFollowUpCenter.file.update {
                $0.pullRequests[url] = PRFollowUp.Entry(rounds: [PRFollowUp.Round(kind: .ci, head: "abc", typedAt: 5)])
            }
            task.prInfo = PRInfo(
                number: 7, state: .merged, isDraft: false, ciStatus: nil, checks: [], reviewDecision: nil, mergeable: nil, url: url,
                additions: nil, deletions: nil, changedFiles: nil
            )
            shell.followUpPullRequest(of: task)
            XCTAssertNil(shell.prFollowUpCenter.file.value.pullRequests[url])
            // Its worktree removed under it: it is still a task with a thread.
            try FileManager.default.removeItem(atPath: task.cwd)
            shell.closeWorkspace(at: try XCTUnwrap(shell.workspaces.firstIndex { $0 === task }), refocusing: false)
            let saved = shell.persistedState()
            XCTAssertFalse(saved.workspaces.contains { $0.id == task.id }, "quitting during the exit must not restore the closed task")
            XCTAssertEqual(saved.workspaces[saved.activeWorkspaceIndex].id, lead.workspace.id)
            var thread: [TaskThread.Event] = []
            harness.waitUntil("its thread frozen") {
                thread = TaskThread.Store.load(workspaceID: task.id, stateDirectory: URL(fileURLWithPath: harness.stateDirectory))
                return thread.contains { $0.kind == .closed }
            }
            let archived = try call(LeadTools.readThread, ["task": task.id], lead: lead, in: harness)
            XCTAssertFalse(archived.isError, archived.text)
            XCTAssertTrue(archived.text.contains("Closed task"), archived.text)
            XCTAssertTrue(archived.text.contains("Add a date filter"), archived.text)
            XCTAssertFalse(archived.text.contains("Next · ship the filter"), archived.text)
            let privateID = UUID().uuidString
            TaskThread.Store.append(thread, workspaceID: privateID, spaceID: "elsewhere", stateDirectory: URL(fileURLWithPath: harness.stateDirectory))
            XCTAssertTrue(try call(LeadTools.readThread, ["task": privateID], lead: lead, in: harness).isError)
            let request = try XCTUnwrap(thread.first)
            XCTAssertEqual([request.kind.rawValue, request.by?.rawValue, request.text], ["request", "lead", "Add a date filter\nGET /orders?from=&to="])
            XCTAssertTrue(thread.contains { $0.kind == .nextStep && $0.by == .lead && $0.text == "ship the filter" })
            XCTAssertTrue(thread.contains { $0.kind == .nextStep && $0.by == .nirux && $0.text == nil })
            XCTAssertTrue(thread.contains { $0.kind == .followUp && $0.time == 5 && $0.detail == "ci" && $0.ref == url })
            XCTAssertNil(thread.last { $0.kind == .closed }?.text, "the live pull request may be another checkout's: only the ledger's count")
            XCTAssertTrue(thread.contains { $0.kind == .answer && $0.by == .lead && $0.text == "UTC" && $0.detail == "accepted" })
            XCTAssertTrue(thread.contains { $0.kind == .handedToUser && $0.text == why })
            XCTAssertTrue(thread.contains { $0.kind == .answer && $0.by == .user && $0.text == "Yes, until v3" })
            XCTAssertTrue(thread.contains { $0.kind == .tell && $0.by == .lead && $0.text == "/code-review" })

            // A title and a branch of its own: its row, its handover and its
            // branch take them. A title alone names the branch too.
            let named = try call(
                LeadTools.startTask,
                ["description": "feat/x — Orders as CSV", "title": "CSV export", "branch": "feat/orders-csv", "goal": "Export orders as CSV"],
                lead: lead, in: harness
            )
            XCTAssertTrue(named.text.hasPrefix("Started “CSV export” on feat/orders-csv in "), named.text)
            let csv = try XCTUnwrap(shell.workspaces.first { $0.title == "CSV export" })
            XCTAssertEqual(csv.purpose, "Export orders as CSV")
            XCTAssertEqual(Persistence.load()?.workspaces.first { $0.id == csv.id }?.purpose, "Export orders as CSV")
            let handover = try String(contentsOfFile: csv.cwd + "/.claude-handover.md", encoding: .utf8)
            XCTAssertTrue(handover.hasPrefix("# Task: CSV export\n"), handover)
            let titled = try call(LeadTools.startTask, ["description": "Let the user pick it", "title": "Date format"], lead: lead, in: harness)
            XCTAssertTrue(titled.text.hasPrefix("Started “Date format” on feat/date-format in "), titled.text)
        }
    }

    /// The user answers in the question's popover by typing. A popover
    /// with the keyboard leaves the main window key: AppKit gives that
    /// window the popover's field as first responder and hands it the
    /// window's keys, which the key interceptor sent to the focused
    /// terminal instead. Typing, ⌘↩ and Esc reach the popover, for a
    /// question the Lead hands over and one that comes to the user
    /// directly, its parent gone; once it closed, keys go to the terminal.
    func testKeysTypedWhileTheReplyPopoverShowsGoToItsField() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
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
            let task = try XCTUnwrap(shell.workspaces.first { $0.id == workspaceID })
            XCTAssertTrue(shell.activeWorkspace === task)
            if !shell.isSidebarExpanded { harness.runPaletteCommand("Show/Hide Sidebar") }
            harness.waitUntil("the sidebar to expand") { shell.sidebar.isExpanded }

            // The focused terminal, which takes the keys the popover doesn't
            // (a key the interceptor let through could reach the popover).
            @MainActor func terminal() throws -> PtySession {
                let focused = shell.activeWorkspace.flatMap { $0.columns[safe: $0.focusedIndex] }
                return try XCTUnwrap(focused?.pty, "the focused column is a terminal")
            }

            try harness.withApp {
                let handed = try ask("Keep the old date= parameter?", from: mission)
                XCTAssertFalse(try call(LeadTools.askUser, ["task": "Export CSV", "why": "Only the user knows."], lead: lead, in: harness).isError)
                var pty = try terminal()
                let untyped = pty.lastKeystrokeAt
                var reply = try openReply(to: task, in: harness)
                harness.press("o", keyCode: 0x1F, [])
                harness.press("k", keyCode: 0x28, [])
                XCTAssertEqual(reply.controller.replyView?.string, "ok")
                XCTAssertEqual(pty.lastKeystrokeAt, untyped, "the terminal got none of it")
                harness.press("\r", keyCode: 0x24, [.command])
                XCTAssertEqual(MissionStore.shared.response(to: handed.id)?.message, "ok")
                harness.waitUntil("the popover to close") { !reply.popover.isShown }
                let afterSend = pty.lastKeystrokeAt
                harness.press("y", keyCode: 0x10, [])
                XCTAssertGreaterThan(pty.lastKeystrokeAt, afterSend, "sent, it gives the terminal its keys back")

                let direct = try ask("Comma or semicolon?", from: mission)
                harness.alertResponses = [.alertSecondButtonReturn] // Close Workspace: the Lead has its Board too
                shell.stopLead(spaceID: lead.space)
                harness.waitUntil("the Lead to close") { !shell.workspaces.contains { $0 === lead.workspace } }
                XCTAssertEqual(harness.alerts.last, "Close workspace “Lead”?")
                let column = try XCTUnwrap(task.columns.first)
                let row = shell.missionQuestions(foreground: { _ in nil }, now: Date().timeIntervalSince1970)[ObjectIdentifier(column)]
                XCTAssertEqual(row?.handOff, .parentClosed)
                pty = try terminal()
                reply = try openReply(to: task, in: harness)
                harness.press("\u{1b}", keyCode: 0x35, [])
                harness.waitUntil("Esc to close the popover") { !reply.popover.isShown }
                let beforeClosed = pty.lastKeystrokeAt
                harness.press("x", keyCode: 0x07, [])
                XCTAssertEqual(reply.controller.replyView?.string, "", "closed, it takes no key")
                XCTAssertGreaterThan(pty.lastKeystrokeAt, beforeClosed, "the terminal got it")

                reply = try openReply(to: task, in: harness)
                harness.press(";", keyCode: 0x29, [])
                harness.press("\r", keyCode: 0x24, [.command])
                XCTAssertEqual(MissionStore.shared.response(to: direct.id)?.message, ";")
            }
        }
    }

    /// A relaunch resumes the Lead's `claude`, which then takes no prompt
    /// until someone writes to it and may show a resume screen no hook
    /// reports: Nirux types nothing into it. A task's question comes to the
    /// user once the short grace is over, not after the stuck threshold,
    /// stays with them while the Lead works on the prompt it took, and goes
    /// to the Lead once that turn is over.
    func testATasksQuestionComesToTheUserWhileTheLeadTookNoPrompt() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            // The Lead's `claude`, keeping what it is sent.
            let resumed = AgentStandIn()
            defer { resumed.remove() }
            let agentUUID = UUID().uuidString
            lead.workspace.addColumn(command: resumed.command(), agentUUID: agentUUID, cwd: harness.repo)
            let pty = try XCTUnwrap(lead.workspace.columns.first { $0.agentUUID == agentUUID }?.pty)
            harness.waitUntil("its claude") { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
            let claude = try XCTUnwrap(pty.foregroundProcess(snapshot: ProcessSnapshot())).instance
            @MainActor func hook(_ name: AgentHookEvent.Name, source: String? = nil) {
                _ = pty.applyAgentHook(AgentHookEvent(
                    kind: .claude, name: name, agentUUID: agentUUID, sessionID: "lead", emitterProcess: claude,
                    source: source, timestamp: Date().timeIntervalSince1970
                ), isUserFocused: false)
            }
            let workspaceID = UUID().uuidString
            let mission = try XCTUnwrap(MissionStore.shared.create(MissionCreationRequest(
                id: UUID().uuidString, parentWorkspaceID: lead.workspace.id, parentAgentUUID: agentUUID,
                childWorkspaceID: workspaceID, childAgentUUID: UUID().uuidString, childAgentKind: "claude",
                branch: "feat/export", reportsToLead: true
            ), enabled: true))
            shell.addWorkspace(
                title: "Export CSV", cwd: harness.repo, profileID: lead.space, workspaceID: workspaceID,
                initialAgentUUID: mission.childAgentUUID, missionID: mission.id, reportsToLead: true
            )
            let column = try XCTUnwrap(shell.workspaces.first { $0.id == workspaceID }?.columns.first)
            let question = try ask("Keep the old date= parameter?", from: mission)
            @MainActor func handOff(at now: TimeInterval) -> SidebarMissionQuestion.HandOff? {
                shell.missionQuestions(
                    foreground: { $0.pty?.foregroundProcess(snapshot: ProcessSnapshot()) }, now: now
                )[ObjectIdentifier(column)]?.handOff
            }
            @MainActor func typedAt() -> TimeInterval? {
                MissionStore.shared.missions.first { $0.id == mission.id }?.events.first { $0.id == question.id }?.parentTypedAt
            }
            let grace = NiruxShellView.missionParentGrace
            XCTAssertNil(handOff(at: Date().timeIntervalSince1970 + grace), "no word from its hooks: nothing tells")

            // Its conversation is back, as a relaunch resumes it.
            hook(.sessionStart, source: "resume")
            let now = Date().timeIntervalSince1970
            XCTAssertNil(handOff(at: now), "a first prompt may be on its way")
            XCTAssertEqual(handOff(at: now + grace), .parentNotAtPrompt)
            shell.typeMissionMessages()
            XCTAssertNil(typedAt(), "nothing typed into it")

            // Someone wrote to it: once that turn is over, the question goes in.
            hook(.userPromptSubmit)
            XCTAssertEqual(handOff(at: now + grace + 1), .parentNotAtPrompt, "it hasn't got the question")
            hook(.stop)
            shell.typeMissionMessages()
            harness.waitUntil("the question in its prompt") { resumed.input.contains("Keep the old date= parameter?") }
            XCTAssertNotNil(typedAt())
            XCTAssertNil(handOff(at: now + grace + 2), "it has it now")
        }
    }

    /// The resumed Lead's Claude Code says in its session record that it
    /// sits idle at its prompt: a task's question goes in at the next check,
    /// no prompt needed, and never comes to the user. Until then the log
    /// says once that the record is missing, and nothing goes into a screen
    /// of its own.
    func testATasksQuestionGoesIntoAResumedLeadOnceItsRecordSaysItsPromptIsUp() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            let resumed = AgentStandIn()
            defer { resumed.remove() }
            let agentUUID = UUID().uuidString
            lead.workspace.addColumn(command: resumed.command(), agentUUID: agentUUID, cwd: harness.repo)
            let pty = try XCTUnwrap(lead.workspace.columns.first { $0.agentUUID == agentUUID }?.pty)
            harness.waitUntil("its claude") { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
            let claude = try XCTUnwrap(pty.foregroundProcess(snapshot: ProcessSnapshot())).instance
            _ = pty.applyAgentHook(AgentHookEvent(
                kind: .claude, name: .sessionStart, agentUUID: agentUUID, sessionID: "lead", emitterProcess: claude,
                source: "resume", timestamp: Date().timeIntervalSince1970
            ), isUserFocused: false)
            let workspaceID = UUID().uuidString
            let mission = try XCTUnwrap(MissionStore.shared.create(MissionCreationRequest(
                id: UUID().uuidString, parentWorkspaceID: lead.workspace.id, parentAgentUUID: agentUUID,
                childWorkspaceID: workspaceID, childAgentUUID: UUID().uuidString, childAgentKind: "claude",
                branch: "feat/export", reportsToLead: true
            ), enabled: true))
            shell.addWorkspace(
                title: "Export CSV", cwd: harness.repo, profileID: lead.space, workspaceID: workspaceID,
                initialAgentUUID: mission.childAgentUUID, missionID: mission.id, reportsToLead: true
            )
            let column = try XCTUnwrap(shell.workspaces.first { $0.id == workspaceID }?.columns.first)
            let question = try ask("Keep the old date= parameter?", from: mission)
            var lines: [String] = []
            shell.sideEffects.logMissionWait = { lines.append($0) }
            @MainActor func check(after delay: TimeInterval = 0) {
                shell.missionWaits.checkedAt = nil
                shell.checkMissionWaits(snapshot: ProcessSnapshot(), now: Date().timeIntervalSince1970 + delay)
            }
            @MainActor func typedAt() -> TimeInterval? {
                MissionStore.shared.missions.first { $0.id == mission.id }?.events.first { $0.id == question.id }?.parentTypedAt
            }
            // In the harness's home, as Nirux's environment names it: macOS
            // hides the stand-in's own.
            let url = ClaudeSessionRecord.url(pid: claude.pid, environment: ProcessInfo.processInfo.environment)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // As its REPL writes it: once it started.
            @MainActor func write(_ status: String, waitingFor: String? = nil) throws {
                var fields = #""status":"\#(status)","statusUpdatedAt":\#(Self.writtenAfter(claude))"#
                if let waitingFor { fields += #","waitingFor":"\#(waitingFor)""# }
                try Data("{\(fields)}".utf8).write(to: url)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: claude.startedAt)], ofItemAtPath: url.path)
            }
            let missing = "claude session record missing agent=\(agentUUID.prefix(8)) "
            check()
            XCTAssertFalse(lines.contains { $0.hasPrefix(missing) }, "Claude Code writes it once it registered")
            check(after: NiruxShellView.missionWaitLogAge)
            check(after: NiruxShellView.missionWaitLogAge + 5)
            XCTAssertEqual(lines.filter { $0.hasPrefix(missing) }.count, 1, lines.joined(separator: "\n"))
            try write("waiting", waitingFor: "dialog open")
            check()
            shell.typeMissionMessages()
            XCTAssertNil(typedAt(), "a screen of its own is up")

            try write("idle")
            harness.waitUntil("its record settled") {
                pty.missionPromptRefusal(runningSince: Date().timeIntervalSince1970, snapshot: ProcessSnapshot()) == nil
            }
            @MainActor func handOff(at now: TimeInterval) -> SidebarMissionQuestion.HandOff? {
                shell.missionQuestions(
                    foreground: { $0.pty?.foregroundProcess(snapshot: ProcessSnapshot()) }, now: now
                )[ObjectIdentifier(column)]?.handOff
            }
            check()
            XCTAssertNil(shell.missionWaits.tries[question.id], "typed at once; tries count at the overdue ones' pace")
            // Between checks, the sidebar reads the record the check read.
            try write("waiting", waitingFor: "dialog open")
            let now = Date().timeIntervalSince1970
            XCTAssertNil(handOff(at: now))
            XCTAssertNil(handOff(at: now + NiruxShellView.missionParentGrace), "it can take the question")
            try write("idle")
            harness.waitUntil("the question in its prompt") { resumed.input.contains("Keep the old date= parameter?") }
            XCTAssertNotNil(typedAt())
        }
    }

    /// A Lead resumed at a relaunch, its Claude Code keeping no record, whose
    /// screen someone answered with Enter, and a task's Mission to it.
    @MainActor private struct ResumedLead {
        let shell: NiruxShellView
        let column: ColumnState
        let pty: PtySession
        let claude: ProcessInstance
        let agentUUID: String
        let leadID: String
        let mission: Mission
        let workspaceIndex: Int
        let columnIndex: Int

        func hook(_ name: AgentHookEvent.Name, source: String? = nil) {
            _ = pty.applyAgentHook(AgentHookEvent(
                kind: .claude, name: name, agentUUID: agentUUID, sessionID: "lead", emitterProcess: claude,
                source: source, timestamp: Date().timeIntervalSince1970
            ), isUserFocused: false)
        }

        func typedAt(_ event: MissionEvent) -> TimeInterval? {
            MissionStore.shared.missions.first { $0.id == mission.id }?.events.first { $0.id == event.id }?.parentTypedAt
        }

        /// The row's waiting messages, as a check past a stall's length keeps them.
        func waiting() throws -> SidebarWaitingMessages {
            shell.missionWaits.checkedAt = nil
            shell.checkMissionWaits(snapshot: ProcessSnapshot(), now: Date().timeIntervalSince1970 + NiruxShellView.missionMessageStallAge)
            return try XCTUnwrap(shell.missionWaits.shown[column.id])
        }

        func typeItNow(_ since: TimeInterval) {
            shell.typeWaitingMessagesNow(workspaceIndex: workspaceIndex, columnIndex: columnIndex, since: since)
        }

        /// The row once it offers Type it now, and a click now would type:
        /// `waiting` checks past a stall, on a clock ahead of the click's.
        func offer(_ harness: UIFlowHarness) throws -> SidebarWaitingMessages {
            harness.waitUntil("the offer") {
                let now = Date().timeIntervalSince1970
                return pty.missionPromptRefusal(runningSince: now, snapshot: ProcessSnapshot(), seenByUser: true, now: now) == nil
                    && (try? waiting().offersTypeNow) == true
            }
            return try waiting()
        }

        func queueNotice(_ text: String) {
            shell.pendingLeadNotices.append(LeadNotice(
                workspaceID: leadID, agentUUID: agentUUID, text: text, queuedAt: Date().timeIntervalSince1970
            ))
        }

        func turn() {
            hook(.userPromptSubmit)
            hook(.stop)
            shell.typeMissionMessages()
        }
    }

    /// A session record's statusUpdatedAt (ms), a millisecond after `claude`
    /// started: `startedAt * 1000` read back over 1000 can land below
    /// `startedAt`, and the record then reads as an earlier process's.
    private static func writtenAfter(_ claude: ProcessInstance) -> Double {
        claude.startedAt * 1000 + 1
    }

    private func resumedLead(_ harness: UIFlowHarness, standIn: AgentStandIn, arguments: [String] = []) throws -> ResumedLead {
        let lead = try makeLead(harness)
        let agentUUID = UUID().uuidString
        lead.workspace.addColumn(command: standIn.command(arguments: arguments), agentUUID: agentUUID, cwd: harness.repo)
        let column = try XCTUnwrap(lead.workspace.columns.first { $0.agentUUID == agentUUID })
        let pty = try XCTUnwrap(column.pty)
        harness.waitUntil("its claude") { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
        let mission = try XCTUnwrap(MissionStore.shared.create(MissionCreationRequest(
            id: UUID().uuidString, parentWorkspaceID: lead.workspace.id, parentAgentUUID: agentUUID,
            childWorkspaceID: UUID().uuidString, childAgentUUID: UUID().uuidString, childAgentKind: "claude",
            branch: "feat/export", reportsToLead: true
        ), enabled: true))
        let resumed = ResumedLead(
            shell: harness.shell, column: column, pty: pty, claude: try XCTUnwrap(pty.foregroundProcess(snapshot: ProcessSnapshot())).instance,
            agentUUID: agentUUID, leadID: lead.workspace.id, mission: mission,
            workspaceIndex: try XCTUnwrap(harness.shell.workspaces.firstIndex { $0 === lead.workspace }),
            columnIndex: try XCTUnwrap(lead.workspace.columns.firstIndex { $0 === column })
        )
        resumed.hook(.sessionStart, source: "resume")
        pty.sendRaw("\r")
        return resumed
    }

    /// The resumed Lead holds two questions: its row offers Type it now
    /// while one would go in on the user's word. A click from another
    /// workspace shows its terminal first; the next types one, for the
    /// messages and the `claude` the row showed. Then no more offer until
    /// a prompt goes in; the rest follow its turn.
    func testTypeItNowTypesOneMessageAResumedLeadHolds() throws {
        try UIFlowHarness.run { harness in
            let standIn = AgentStandIn()
            defer { standIn.remove() }
            let lead = try resumedLead(harness, standIn: standIn)
            let first = try ask("Keep the old date= parameter?", from: lead.mission)
            let second = try ask("Export as CSV or TSV?", from: lead.mission)
            let held = try lead.offer(harness)
            XCTAssertEqual(held.heldBy, lead.claude)

            // A screen of its own up: no offer, and the row it left types nothing.
            let url = ClaudeSessionRecord.url(pid: lead.claude.pid, environment: ProcessInfo.processInfo.environment)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"status":"waiting","waitingFor":"dialog open","statusUpdatedAt":\#(Self.writtenAfter(lead.claude))}"#.utf8).write(to: url)
            XCTAssertFalse(try lead.waiting().offersTypeNow)
            lead.shell.missionWaits.shown[lead.column.id] = held
            lead.shell.switchToWorkspace(lead.workspaceIndex)
            lead.typeItNow(held.since)
            XCTAssertNil(lead.typedAt(first), "a screen of its own is up")
            XCTAssertEqual(lead.shell.toast?.message,
                           "Nothing typed: Claude Code shows a screen of its own there, or its last turn isn't over")
            try FileManager.default.removeItem(at: url)

            // From another workspace: its terminal first, for its messages.
            let other = try XCTUnwrap(lead.shell.workspaces.indices.first { $0 != lead.workspaceIndex })
            lead.shell.switchToWorkspace(other)
            let offered = try lead.waiting()
            XCTAssertTrue(offered.offersTypeNow)
            lead.typeItNow(offered.since + 1)
            XCTAssertEqual(lead.shell.activeWSIndex, other, "not the messages the row showed")
            var restarted = offered
            restarted.heldBy = ProcessInstance(pid: lead.claude.pid, startedAt: lead.claude.startedAt - 60)
            lead.shell.missionWaits.shown[lead.column.id] = restarted
            lead.typeItNow(offered.since)
            XCTAssertEqual(lead.shell.activeWSIndex, other, "not the claude the row showed")
            lead.shell.missionWaits.shown[lead.column.id] = offered
            lead.typeItNow(offered.since)
            XCTAssertEqual(lead.shell.activeWSIndex, lead.workspaceIndex, "its terminal, to look first")
            XCTAssertNil(lead.typedAt(first))

            // Its workspace in front, its column scrolled out of view: shown first too.
            let workspace = lead.shell.workspaces[lead.workspaceIndex]
            let focused = try XCTUnwrap(workspace.columns.indices.first { $0 != lead.columnIndex })
            for column in workspace.columns { column.widthFraction = 1 }
            workspace.focusedIndex = focused
            lead.shell.relayout(animated: false)
            XCTAssertFalse(workspace.showsColumn(at: lead.columnIndex))
            lead.typeItNow(offered.since)
            harness.waitUntil("its column in view") { workspace.showsColumn(at: lead.columnIndex) }
            XCTAssertNil(lead.typedAt(first), "its terminal, to look first")

            lead.typeItNow(offered.since)
            XCTAssertEqual(lead.shell.toast?.message, "Typed one; the rest follow its turn")
            harness.waitUntil("the question in its prompt") { standIn.input.contains("Keep the old date= parameter?") }
            XCTAssertNil(lead.typedAt(second), "one on the user's word")
            // What Nirux typed may sit in its prompt, its Enter in or not.
            harness.waitUntil("its Enter") { lead.typedAt(first) != nil }
            var again = try lead.waiting()
            XCTAssertFalse(again.offersTypeNow)
            again.offersTypeNow = true
            again.heldBy = lead.claude
            lead.shell.missionWaits.shown[lead.column.id] = again
            lead.typeItNow(again.since)
            XCTAssertNil(lead.typedAt(second))
            XCTAssertEqual(lead.shell.toast?.message, "Nothing typed: held by a draft until its next prompt")
            lead.queueNotice("[Nirux] A notice.")

            // Its turns: the notice, then the last question.
            lead.turn()
            harness.waitUntil("the notice in its prompt") { standIn.input.contains("[Nirux] A notice.") }
            XCTAssertNil(lead.typedAt(second))
            lead.turn()
            harness.waitUntil("the second question in its prompt") { standIn.input.contains("Export as CSV or TSV?") }
        }
    }

    /// The relaunch's "Continue where you left off" goes into the resumed
    /// conversation once its prompt is free: never over a draft, and never
    /// into another conversation (a fresh claude after a failed resume).
    func testTheRelaunchNoticeGoesIntoItsSessionNeverOverADraft() throws {
        try UIFlowHarness.run { harness in
            let standIn = AgentStandIn()
            defer { standIn.remove() }
            let lead = try resumedLead(harness, standIn: standIn, arguments: ["--resume", "lead"])
            let text = "[Nirux Mission] " + RelaunchResume.continueText
            for (words, session) in [("[Nirux Mission] For an earlier conversation.", "earlier"), (text, "lead")] {
                var notice = LeadNotice(workspaceID: lead.leadID, agentUUID: lead.agentUUID, text: words, queuedAt: Date().timeIntervalSince1970)
                notice.forSessionID = session
                lead.shell.pendingLeadNotices.append(notice)
            }
            lead.pty.sendRaw("half a thought")
            lead.turn()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            XCTAssertFalse(standIn.input.contains(text), "never over a draft")
            XCTAssertTrue(lead.shell.pendingLeadNotices.contains { $0.text == text })

            lead.pty.sendRaw("\r")
            lead.turn()
            harness.waitUntil("the notice in its prompt") { standIn.input.contains(text) }
            XCTAssertFalse(standIn.input.contains("earlier conversation"))
            XCTAssertTrue(lead.shell.pendingLeadNotices.isEmpty, "the other conversation's is dropped")
        }
    }

    /// A Lead notice waiting for the resumed Lead goes in first on the
    /// user's word, alone. Past the input queue it is pasted, then an Enter
    /// of its own follows: still no more on the user's word, since it may
    /// sit in the prompt yet.
    func testTypeItNowTypesALeadNoticeFirst() throws {
        try UIFlowHarness.run { harness in
            let standIn = AgentStandIn()
            defer { standIn.remove() }
            let lead = try resumedLead(harness, standIn: standIn)
            let question = try ask("Keep the old date= parameter?", from: lead.mission)
            let long = "[Nirux] A notice. " + String(repeating: "x", count: PtySession.inputQueueBytes)
            for text in [long, "[Nirux] Another notice."] { lead.queueNotice(text) }
            let offered = try lead.offer(harness)
            lead.shell.switchToWorkspace(lead.workspaceIndex)
            lead.typeItNow(offered.since)
            // Its line mode turns the Enter into a newline.
            harness.waitUntil("the notice and its Enter") { standIn.input.contains(long) && standIn.input.hasSuffix("\u{1B}[201~\n") }
            XCTAssertNil(lead.typedAt(question))
            XCTAssertEqual(lead.shell.pendingLeadNotices.map(\.text), ["[Nirux] Another notice."])

            XCTAssertFalse(try lead.waiting().offersTypeNow)
            lead.shell.missionWaits.shown[lead.column.id] = offered
            lead.typeItNow(offered.since)
            XCTAssertNil(lead.typedAt(question))
            XCTAssertEqual(lead.shell.pendingLeadNotices.count, 1)
        }
    }

    /// Clicks the question row on `task`'s card, as the user does: the
    /// popover it opens.
    private func openReply(
        to task: WorkspaceState, in harness: UIFlowHarness, file: StaticString = #filePath, line: UInt = #line
    ) throws -> (popover: NSPopover, controller: MissionReplyViewController) {
        let shell = harness.shell
        let sidebar = shell.sidebar
        shell.updateSidebar()
        sidebar.layoutSubtreeIfNeeded()
        let index = try XCTUnwrap(shell.workspaces.firstIndex { $0 === task }, file: file, line: line)
        let url = SidebarView.missionQuestionActionURL(workspaceIndex: index, columnIndex: 0)
        let row = try XCTUnwrap(sidebar.hitAreas.first { area in
            guard case .link(let link, _) = area.region else { return false }
            return link == url
        }, "the question's row", file: file, line: line)
        sidebar.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: sidebar.contentDocumentView.convert(NSPoint(x: row.frame.midX, y: row.frame.midY), to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ), file: file, line: line))
        let popover = try XCTUnwrap(shell.missionReplyPopover, "the popover", file: file, line: line)
        let controller = try XCTUnwrap(popover.contentViewController as? MissionReplyViewController, file: file, line: line)
        XCTAssertTrue(popover.isShown, file: file, line: line)
        XCTAssertEqual(controller.replyView?.string, "", file: file, line: line)
        XCTAssertTrue(harness.window.firstResponder === controller.replyView, "the main window's keys go to the field", file: file, line: line)
        // Esc closes it at once, without waiting on an animation.
        popover.animates = false
        return (popover, controller)
    }

    /// set_task_context keeps a task's next step and blocker, shown on its
    /// row and in list_tasks. What the user types in View/Edit Context…
    /// stays theirs (a field they didn't touch stays the Lead's, even one
    /// it changed while the panel was open) until they clear it.
    func testTheLeadKeepsATasksNextStepAndBlocker() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            let workspaceID = UUID().uuidString
            let agentUUID = UUID().uuidString
            let mission = try XCTUnwrap(MissionStore.shared.create(MissionCreationRequest(
                id: UUID().uuidString, parentWorkspaceID: lead.workspace.id, parentAgentUUID: lead.agentUUID,
                childWorkspaceID: workspaceID, childAgentUUID: agentUUID, childAgentKind: "claude",
                branch: "feat/export", reportsToLead: true
            ), enabled: true))
            shell.addWorkspace(
                title: "Export CSV", cwd: harness.repo, profileID: lead.space, workspaceID: workspaceID,
                initialAgentUUID: agentUUID, missionID: mission.id, reportsToLead: true
            )
            let task = try XCTUnwrap(shell.workspaces.first { $0.id == workspaceID })
            @MainActor func setContext(_ arguments: [String: Any]) throws -> (text: String, isError: Bool) {
                try call(LeadTools.setTaskContext, arguments.merging(["task": "Export CSV"]) { $1 }, lead: lead, in: harness)
            }
            @MainActor func status() throws -> String {
                shell.updateSidebar()
                return try XCTUnwrap(shell.sidebar.displayedWorkspaceInfos.first { $0.id == workspaceID }).rowSummary.status.text
            }

            let first = try setContext(["next_step": "write the import side", "blocker": "waits for #212 to merge"])
            XCTAssertFalse(first.isError, first.text)
            XCTAssertEqual(task.nextStep, "write the import side")
            XCTAssertTrue(task.nextStepIsFromLead && task.blockerIsFromLead)
            XCTAssertEqual(try status(), "Blocked · waits for #212 to merge")
            let list = try call(LeadTools.listTasks, lead: lead, in: harness).text
            XCTAssertTrue(list.contains("next step: “write the import side”"), list)
            XCTAssertTrue(list.contains("blocker: “waits for #212 to merge”"), list)
            // Where it stands, from its last turn: listed, and on its row
            // when nothing says more.
            XCTAssertFalse(list.contains("last turn"), list)
            task.awaitTurnStatus(turnEndedAt: 1)
            task.settleTurnStatus(.line("import side half done"), turnEndedAt: 1)
            XCTAssertTrue(
                try call(LeadTools.listTasks, lead: lead, in: harness).text
                    .contains("last turn, as Sonnet read it: “import side half done”")
            )
            let blocker = task.blocker
            (task.nextStep, task.blocker) = (nil, nil)
            XCTAssertEqual(try status(), "import side half done")
            shell.turnStatusEnabled = false
            XCTAssertNotEqual(try status(), "import side half done", "the option is off")
            XCTAssertNil(shell.sidebar.displayedWorkspaceInfos.first { $0.id == workspaceID }?.lastSummary, "nor the tooltip's")
            XCTAssertFalse(try call(LeadTools.listTasks, lead: lead, in: harness).text.contains("last turn"))
            shell.turnStatusEnabled = true
            (task.nextStep, task.blocker) = ("write the import side", blocker)
            XCTAssertFalse(try setContext(["blocker": ""]).isError)
            XCTAssertNil(task.blocker)
            XCTAssertEqual(try status(), "Next · write the import side")

            // The user types a blocker; the Lead changes the next step while
            // the panel is open.
            let index = try XCTUnwrap(shell.workspaces.firstIndex { $0 === task })
            shell.showWorkspaceContextPanel(workspaceIndex: index)
            defer { shell.workspaceContextPanel?.purposeEditor?.window?.orderOut(nil) }
            XCTAssertFalse(try setContext(["next_step": "user reviews #39"]).isError)
            let save = try XCTUnwrap(shell.workspaceContextPanel?.onSave)
            save(WorkspaceContextValues(purpose: "", phase: nil, lastSummary: "", nextStep: "write the import side", blocker: "no API key"))
            XCTAssertEqual(task.nextStep, "user reviews #39", "untouched: the Lead's newer one stays")
            XCTAssertTrue(task.nextStepIsFromLead)
            XCTAssertEqual(task.blocker, "no API key")
            XCTAssertFalse(task.blockerIsFromLead)

            let refused = try setContext(["blocker": "something else"])
            XCTAssertTrue(refused.isError)
            XCTAssertTrue(refused.text.contains("by hand"), refused.text)
            XCTAssertEqual(task.blocker, "no API key")
            XCTAssertTrue(try setContext(["next_step": "user reviews #39", "blocker": "x"]).isError, "nothing it asked for happened")
            let partly = try setContext(["next_step": "merge #39", "blocker": ""])
            XCTAssertFalse(partly.isError, "the next step changed")
            XCTAssertTrue(partly.text.contains("blocker (“no API key”)"), partly.text)
            XCTAssertEqual(task.nextStep, "merge #39")
            XCTAssertTrue(try call(LeadTools.listTasks, lead: lead, in: harness).text.contains("blocker (the user wrote it): “no API key”"))

            // Cleared by hand: the Lead's again.
            shell.showWorkspaceContextPanel(workspaceIndex: index)
            try XCTUnwrap(shell.workspaceContextPanel?.onSave)(
                WorkspaceContextValues(purpose: "", phase: nil, lastSummary: "", nextStep: "merge #39", blocker: " ")
            )
            XCTAssertNil(task.blocker)
            XCTAssertFalse(try setContext(["blocker": "CI is red on main"]).isError)
            XCTAssertTrue(task.blockerIsFromLead)

            XCTAssertTrue(try call(LeadTools.setTaskContext, ["task": "nope", "blocker": "x"], lead: lead, in: harness).isError)

            // Two of its tasks named alike: the branch says which.
            let twinID = UUID().uuidString
            let twinAgent = UUID().uuidString
            let twin = try XCTUnwrap(MissionStore.shared.create(MissionCreationRequest(
                id: UUID().uuidString, parentWorkspaceID: lead.workspace.id, parentAgentUUID: lead.agentUUID,
                childWorkspaceID: twinID, childAgentUUID: twinAgent, childAgentKind: "claude",
                branch: "feat/export-2", reportsToLead: true
            ), enabled: true))
            shell.addWorkspace(
                title: "Export CSV", cwd: harness.repo, profileID: lead.space, workspaceID: twinID,
                initialAgentUUID: twinAgent, missionID: twin.id, reportsToLead: true
            )
            let ambiguous = try setContext(["blocker": "y"])
            XCTAssertTrue(ambiguous.isError)
            XCTAssertTrue(ambiguous.text.contains("several share that name"), ambiguous.text)
            XCTAssertEqual(task.blocker, "CI is red on main")

            // Its status line is kept across a relaunch.
            XCTAssertTrue(task.awaitTurnStatus(turnEndedAt: 2))
            XCTAssertTrue(task.settleTurnStatus(.line("export done"), turnEndedAt: 2))
            shell.saveState()
            shell.restoreState()
            let restored = try XCTUnwrap(shell.workspaces.first { $0.id == workspaceID })
            XCTAssertEqual(restored.statusLine, "export done")
            // Quit while the next turn's line was on its way: unknown.
            restored.awaitTurnStatus(turnEndedAt: 3)
            shell.saveState()
            shell.restoreState()
            XCTAssertNil(shell.workspaces.first { $0.id == workspaceID }?.statusLine)
        }
    }

    func testTheDayPlanKeepsTheLeadsLinesAndATasksOwnSteps() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            let workspaceID = UUID().uuidString
            let agentUUID = UUID().uuidString
            shell.addWorkspace(title: "Export CSV", cwd: harness.repo, profileID: lead.space, workspaceID: workspaceID, initialAgentUUID: agentUUID)
            let task = try XCTUnwrap(shell.workspaces.first { $0.id == workspaceID })
            @MainActor func steps(_ arguments: [String: Any]) throws -> (text: String, isError: Bool) {
                try call(PlanTools.taskSteps, arguments, from: task, agentUUID: agentUUID, in: harness)
            }
            XCTAssertEqual(try call(PlanTools.readPlan, lead: lead, in: harness).text, NiruxShellView.dayPlanIsOff)
            XCTAssertTrue(try steps(["add": ["Parse the header"]]).isError)
            let defaults = try XCTUnwrap(SpaceDefaultsStore(spaceID: lead.space))
            var on = defaults.load().defaults
            on.dayPlan = true
            guard case .success = defaults.save(on) else { return XCTFail("the day plan stays off") }

            let added = try steps(["add": ["Parse the header", "Write the rows"]])
            XCTAssertFalse(added.isError, added.text)
            let forUser = try call(PlanTools.addToPlan, ["kind": "step", "title": "Pick the delimiter", "for_user": true, "task": "Export CSV"],
                                   lead: lead, in: harness)
            XCTAssertTrue(forUser.text.hasSuffix("at the end of “Export CSV”."), forUser.text)
            let wrongType = try call(PlanTools.addToPlan, ["kind": "session", "task": 3], lead: lead, in: harness)
            XCTAssertTrue(wrongType.isError && wrongType.text.hasPrefix("task must name"), wrongType.text)
            let line = try XCTUnwrap(try XCTUnwrap(Plan.Store(spaceID: lead.space)).load().plan.line(ofWorkspace: workspaceID))
            XCTAssertEqual(line.children.map(\.title), ["Parse the header", "Write the rows", "Pick the delimiter"])
            let choice = line.children[2].id
            XCTAssertEqual(try steps(["check": [choice]]).text, Plan.Refusal.notAllowed(.check).description, "the user's step")
            XCTAssertEqual(try call(PlanTools.checkPlanLine, ["line": choice], lead: lead, in: harness).text, "Checked “Pick the delimiter”.")
            let read = try call(PlanTools.readPlan, lead: lead, in: harness)
            XCTAssertTrue(read.text.contains("[x] Pick the delimiter (step \(choice), for the user)"), read.text)
        }
    }

    /// record_review keeps each review of any task of the space (one the
    /// user started too) as its next round, and refuses a workspace that
    /// isn't a task; daily_pass then lists the findings by kind and the
    /// tasks it may have forgotten (a merged pull request's, a result's
    /// with nothing after it, each dated by its last turn or commit; never
    /// a plain checkout's or an archived task's), and the window it read is
    /// where the next pass starts.
    func testTheLeadRecordsReviewsAndReadsItsDay() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            let workspaceID = UUID().uuidString
            let agentUUID = UUID().uuidString
            let mission = try XCTUnwrap(MissionStore.shared.create(MissionCreationRequest(
                id: UUID().uuidString, parentWorkspaceID: lead.workspace.id, parentAgentUUID: lead.agentUUID,
                childWorkspaceID: workspaceID, childAgentUUID: agentUUID, childAgentKind: "claude",
                branch: "feat/export", reportsToLead: true
            ), enabled: true))
            shell.addWorkspace(
                title: "Export CSV", cwd: harness.repo, profileID: lead.space, workspaceID: workspaceID,
                initialAgentUUID: agentUUID, missionID: mission.id, reportsToLead: true
            )
            shell.addWorkspace(title: "The user's fix", cwd: harness.worktree, profileID: lead.space)
            shell.addWorkspace(title: "A shell", cwd: harness.repo, profileID: lead.space)
            let export = try XCTUnwrap(shell.workspaces.first { $0.title == "Export CSV" })
            let usersFix = try XCTUnwrap(shell.workspaces.first { $0.title == "The user's fix" })
            shell.refreshGitContextNow(for: export)
            shell.refreshGitContextNow(for: usersFix)
            harness.waitUntil("the tasks' branches") { export.gitBranch != nil && usersFix.gitBranch == harness.worktreeBranch }
            let sleep = ["kind": "Test waits on sleep", "text": "testExport sleeps 2 s"]
            @MainActor func record(_ task: String) throws -> (text: String, isError: Bool) {
                try call(LeadTools.recordReview, ["task": task, "findings": [sleep]], lead: lead, in: harness)
            }

            let first = try record("Export CSV")
            XCTAssertTrue(first.text.hasPrefix("Recorded round 1 of “Export CSV”: 1 finding."), first.text)
            XCTAssertTrue(try record("Export CSV").text.hasPrefix("Recorded round 2 of “Export CSV”"))
            let users = try record("The user's fix")
            XCTAssertFalse(users.isError, users.text)
            XCTAssertTrue(users.text.contains("Seen in another task too: test-waits-on-sleep"), users.text)
            let plain = try record("A shell")
            XCTAssertTrue(plain.isError)
            XCTAssertTrue(plain.text.contains("isn't a task"), plain.text)

            let merged = PRInfo(
                number: 7, state: .merged, isDraft: false, ciStatus: nil, checks: [], reviewDecision: nil, mergeable: nil,
                url: "https://github.com/acme/app/pull/7", additions: nil, deletions: nil, changedFiles: nil
            )
            usersFix.prInfo = merged
            usersFix.lastActivityAt = Date().timeIntervalSince1970
            try XCTUnwrap(shell.workspaces.first { $0.title == "A shell" }).prInfo = merged
            shell.addWorkspace(title: "Archived fix", cwd: harness.worktree, profileID: lead.space)
            let archived = try XCTUnwrap(shell.workspaces.first { $0.title == "Archived fix" })
            archived.prInfo = merged
            archived.isInactive = true
            // The Lead's task sent its result, then committed once, three
            // days ago: closable.
            let threeDaysAgo = Date().timeIntervalSince1970 - 3 * 86_400
            try UIFlowHarness.git(
                ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "--allow-empty", "-m", "old"],
                at: harness.repo, environment: ["GIT_COMMITTER_DATE": "@\(Int(threeDaysAgo))"]
            )
            let result = MissionEvent(
                id: UUID().uuidString, missionID: mission.id, childWorkspaceID: workspaceID, childAgentUUID: agentUUID,
                kind: .completed, message: "Export done", timestamp: threeDaysAgo - 600
            )
            guard case .accepted = MissionStore.shared.process(result, enabled: true) else { return XCTFail("its result is carried") }
            export.lastActivityAt = threeDaysAgo - 86_400
            let revision = try XCTUnwrap(GitDetect.context(at: harness.repo))
            export.updateGitContext(revision)
            export.applyPullRequestInfo(nil, for: revision)

            let now = Date().timeIntervalSince1970
            let rows = (0..<(DailyPass.maxItems + 2)).map { String(format: "wait-%03d", $0) }
            let archivedEvents: [TaskThread.Event] = [.init(time: now - 90_000, kind: .question, ref: "q", recipient: .lead),
                                                .init(time: now - 60, kind: .closed, detail: "local")]
            for id in rows {
                TaskThread.Store.append(archivedEvents, workspaceID: id, spaceID: lead.space, stateDirectory: URL(fileURLWithPath: harness.stateDirectory))
            }
            let started = ReviewChecklist.Reach(time: now - 60, session: "s1", kind: .started)
            ReviewChecklist.reaches.append(started, spaceID: lead.space, stateDirectory: URL(fileURLWithPath: harness.stateDirectory))
            let day = try call(LeadTools.dailyPass, lead: lead, in: harness)
            XCTAssertFalse(day.isError, day.text)
            XCTAssertTrue(day.text.contains("- test-waits-on-sleep · 2 tasks: "), day.text)
            XCTAssertTrue(day.text.contains("- The review checklist reached 0 of 1 reviewers started in this window"), day.text)
            let fix = "- “The user's fix” · branch \(harness.worktreeBranch) · not yours (started by the user) · PR #7 merged · "
                + "last activity "
            let line = try XCTUnwrap(day.text.components(separatedBy: "\n").first { $0.hasPrefix(fix) }, day.text)
            XCTAssertTrue(line.contains(" (a turn), ") && line.hasSuffix(" → close_task"), line)
            let exportLine = try XCTUnwrap(day.text.components(separatedBy: "\n").first { $0.hasPrefix("- “Export CSV” ·") }, day.text)
            let finished = "result sent \(DailyPass.clock(threeDaysAgo - 600)), nothing since, no pull request · "
                + "last activity \(DailyPass.clock(threeDaysAgo)) (a commit), "
            XCTAssertTrue(exportLine.contains(finished) && exportLine.hasSuffix(" → close_task"), exportLine)
            for title in ["A shell", "Archived fix"] { XCTAssertFalse(day.text.contains("- “\(title)” ·"), day.text) }
            XCTAssertEqual(DailyPassState.load(spaceID: lead.space).listedTasks?.count, 2, "the next pass knows what this one listed")
            XCTAssertNotNil(DailyPassState.load(spaceID: lead.space).nextWaitPage)
            shell.dailyPassStates.removeValue(forKey: lead.space)
            let remaining = try call(LeadTools.dailyPass, lead: lead, in: harness)
            XCTAssertFalse(remaining.isError, remaining.text)
            for id in rows {
                XCTAssertEqual((day.text + "\n" + remaining.text).components(separatedBy: "id " + id + " ·").count - 1, 1, id)
            }
            XCTAssertNil(DailyPassState.load(spaceID: lead.space).nextWaitPage)
            let again = try call(LeadTools.dailyPass, lead: lead, in: harness).text
            XCTAssertTrue(again.contains("Listed last time too, nothing changed since:\n- “"), again)
            let read = try XCTUnwrap(DailyPassState.load(spaceID: lead.space).end)
            XCTAssertEqual(read, Date().timeIntervalSince1970, accuracy: 60)
        }
    }

    func testRecordReviewMarksCodeReviewOnlyOnCleanReviews() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            shell.addWorkspace(title: "Codex fix", cwd: harness.worktree, profileID: lead.space)
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "Codex fix" })
            shell.refreshGitContextNow(for: task)
            harness.waitUntil("the task's branch and head") {
                task.gitBranch == harness.worktreeBranch && task.gitContext?.identity.head != nil
            }
            let head = try XCTUnwrap(task.gitContext?.identity.head)
            let branch = harness.worktreeBranch

            @MainActor func missingReviews() -> [String] {
                MergeQueue.missingReviews(
                    branch: branch, tasks: NiruxShellView.reviewTasks(of: [task]), required: BoardStages.Rules().requiredReviews
                )
            }
            @MainActor func leadRefusal() -> String? {
                var candidate = MergeQueue.ConfirmationReading.Candidate(number: 14)
                candidate.pullRequest = MQ.pullRequest(14, head: head, branch: branch)
                candidate.details = MergeQueue.PullRequestDetails(
                    title: "Codex fix", files: ["Sources/app.swift"], hasMoreFiles: false, head: head, baseBranch: "main", allPathsKnown: true
                )
                candidate.checks = MQ.checks(MQ.checkRun(id: 1))
                candidate.comparison = .some(MergeQueue.Comparison(status: "ahead", aheadBy: 1, behindBy: 0, baseCommit: MQ.sha("0")))
                candidate.local = MergeQueue.LocalState()
                candidate.missingReviews = missingReviews()
                var reading = MergeQueue.ConfirmationReading(settings: MQ.settings(), isDryRun: false)
                reading.rateLimit = MergeQueue.RateLimit(
                    coreRemaining: 5000, coreReset: Date(timeIntervalSince1970: 0),
                    graphQLRemaining: 5000, graphQLReset: Date(timeIntervalSince1970: 0)
                )
                reading.baseMergeQueue = false
                reading.baseRuns = [MQ.run(1, head: MQ.sha("c"))]
                reading.candidates = [candidate]
                return reading.leadStartRefusal(confirmation: MergeQueue.confirmation(reading), numbers: [14], cadence: .standard)
            }

            // Issues found: must NOT record .codeReview or clear missingReviews.
            let blocking = ["kind": "missing-test", "text": "Cover the error branch."]
            let withFindings = try call(LeadTools.recordReview, ["task": "Codex fix", "findings": [blocking]], lead: lead, in: harness)
            XCTAssertFalse(withFindings.isError, withFindings.text)
            XCTAssertNil(task.reviewRuns[.codeReview])
            XCTAssertEqual(missingReviews(), ["Code review"])
            XCTAssertNotNil(leadRefusal())

            // Clean review (zero findings): records .codeReview on current HEAD/branch and clears missingReviews.
            let clean = try call(LeadTools.recordReview, ["task": "Codex fix", "findings": [] as [Any]], lead: lead, in: harness)
            XCTAssertFalse(clean.isError, clean.text)
            XCTAssertTrue(clean.text.hasPrefix("Recorded round 2 of “Codex fix”: 0 findings."), clean.text)
            let recorded = try XCTUnwrap(task.reviewRuns[.codeReview])
            XCTAssertEqual(recorded.head, head)
            XCTAssertEqual(recorded.branch, branch)
            XCTAssertEqual(missingReviews(), [])
            XCTAssertNil(leadRefusal())
        }
    }

    func testUnreadableMissionsLeaveTheFirstDailyWindowForRecovery() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            let profile = try XCTUnwrap(shell.profiles.first { $0.id == lead.space })
            shell.addWorkspace(title: "Reader", cwd: harness.worktree, profileID: lead.space)
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "Reader" })
            let file = URL(fileURLWithPath: harness.stateDirectory).appendingPathComponent("test-missions.json")
            let store = MissionStore(fileURL: file)
            try Data("unreadable".utf8).write(to: file)

            @MainActor func read() throws -> (text: String, isError: Bool) {
                var result: (String, Bool)?
                shell.leadDailyPass(in: profile, lead: lead.workspace, store: store) { result = ($0, $1) }
                harness.waitUntil("the daily pass response") { result != nil }
                return try XCTUnwrap(result)
            }

            let before = DailyPassState.load(spaceID: lead.space)
            let failed = try read()
            XCTAssertTrue(failed.isError)
            XCTAssertTrue(failed.text.contains("Mission ledger"))
            let now = Date().timeIntervalSince1970
            shell.checkDailyPasses(now: now, store: store, isQuiet: { _ in true }, send: { _, _ in XCTFail("no pass to announce") })
            XCTAssertEqual(shell.dailyPassRetryAt[lead.space], now + DailyPass.retryAfter)
            XCTAssertEqual(DailyPassState.load(spaceID: lead.space), before)

            let question = MissionEvent(id: "q", missionID: "m", childWorkspaceID: task.id, childAgentUUID: "agent",
                                        kind: .question, message: "Which branch?", inReplyTo: nil, timestamp: now - 180)
            let answer = MissionEvent(id: "a", missionID: "m", childWorkspaceID: task.id, childAgentUUID: "agent",
                                      kind: .response, message: "main", inReplyTo: "q", timestamp: now - 60)
            let mission = Mission(id: "m", parentWorkspaceID: lead.workspace.id, parentAgentUUID: lead.agentUUID,
                                  childWorkspaceID: task.id, childAgentUUID: "agent", childAgentKind: "codex", branch: harness.worktreeBranch,
                                  status: .active, createdAt: now - 240, updatedAt: now - 60, events: [question, answer], reportsToLead: true)
            try JSONEncoder().encode([mission]).write(to: file)
            let recovered = try read()
            XCTAssertFalse(recovered.isError, recovered.text)
            XCTAssertTrue(recovered.text.contains("Lead 2 min"), recovered.text)
            XCTAssertNotNil(DailyPassState.load(spaceID: lead.space).waitsThrough)
            XCTAssertFalse(try read().text.contains("Lead 2 min"))
        }
    }

    /// Past its budget, a task's row warns and its follow-up stop still
    /// shows: only typing a round waits. The Lead's row has no budget.
    func testATaskPastItsBudgetKeepsItsFollowUpStopAndTheLeadHasNone() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            let started = try call(LeadTools.startTask, ["description": "Check export"], lead: lead, in: harness)
            XCTAssertFalse(started.isError, started.text)
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "Check export" })
            let now = Date().timeIntervalSince1970
            @MainActor func session(_ id: String, of workspace: WorkspaceState) -> UsageSession {
                UsageSession(
                    key: UsageSessionKey(.claude, id), attribution: UsageAttribution(spaceID: lead.space, taskID: workspace.id),
                    events: [UsageEvent(timestamp: now - 60, model: "claude-opus-5-5", counts: TokenCounts(input: 30_000_000))]
                )
            }
            let monitor = UsageMonitor(sources: UsageSources(home: harness.home), catalog: { UsageCatalog() })
            monitor.report = UsageReport(sessions: [session("t", of: task), session("l", of: lead.workspace)], now: now)
            shell.usageMonitor = monitor
            shell.taskBudgets = [lead.space: SpaceDefaults.defaultTaskBudget]
            shell.updateSidebar()
            let taskRow = try XCTUnwrap(shell.sidebar.lastInfos.first { $0.id == task.id })
            XCTAssertEqual(taskRow.usage?.isOverBudget, true)
            let leadRow = try XCTUnwrap(shell.sidebar.lastInfos.first(where: \.isLead))
            XCTAssertNil(leadRow.usage?.budget, "a Lead spends past a task's budget by design")
            XCTAssertEqual(leadRow.usage?.isWarning, false)
            XCTAssertEqual(leadRow.usage?.spaceWeekShare, 1, "its space spent the whole week")
            XCTAssertNil(taskRow.usage?.spaceWeekShare)

            var pullRequest = PRInfo(
                number: 9, state: .open, isDraft: false, ciStatus: "FAILURE", checks: [], reviewDecision: nil, mergeable: nil,
                url: "https://github.com/acme/repo/pull/9", additions: nil, deletions: nil, changedFiles: nil
            )
            pullRequest.headRefOid = "abc"
            task.prInfo = pullRequest
            shell.prFollowUpCenter.file.update {
                $0.pullRequests[pullRequest.url] = PRFollowUp.Entry(stop: PRFollowUp.Stop(kind: .ci, cause: .rounds, head: "abc", at: now))
            }
            XCTAssertNotNil(shell.followUpRow(of: task), "its stop still shows past its budget")
            XCTAssertNotNil(budgetOffer(of: task, in: shell))

            // Continue, through the sidebar's callback: no warning, no pause,
            // no choice, for the 7 days a budget reads; saved with the task.
            shell.sidebar.onBudgetChoice?(task.id, .keepGoing)
            let passedAt = try XCTUnwrap(task.budgetPassedAt)
            XCTAssertFalse(shell.isOverBudget(task))
            let continued = try XCTUnwrap(shell.sidebar.lastInfos.first { $0.id == task.id })
            XCTAssertEqual(continued.usage?.isWarning, false)
            XCTAssertNil(budgetOffer(of: task, in: shell))
            task.budgetPassedAt = passedAt - WorkspaceState.budgetPassLifetime
            XCTAssertTrue(shell.isOverBudget(task), "its 7 days rolled over")
            task.budgetPassedAt = passedAt
            shell.saveState()
            shell.restoreState()
            XCTAssertEqual(shell.workspaces.first { $0.id == task.id }?.budgetPassedAt, passedAt, "read back at launch")
        }
    }

    /// Fresh start on a task past its budget starts its worker's new
    /// conversation, same agent, only at rest, and lifts the budget; mid-turn
    /// the card has none and a stale press waits. Close… asks first.
    func testABudgetFreshStartWaitsForRestAndCloseAsks() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            let started = try call(LeadTools.startTask, ["description": "Check export"], lead: lead, in: harness)
            XCTAssertFalse(started.isError, started.text)
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "Check export" })
            let now = Date().timeIntervalSince1970
            let monitor = UsageMonitor(sources: UsageSources(home: harness.home), catalog: { UsageCatalog() })
            monitor.report = UsageReport(sessions: [UsageSession(
                key: UsageSessionKey(.claude, "t"), attribution: UsageAttribution(spaceID: lead.space, taskID: task.id),
                events: [UsageEvent(timestamp: now - 60, model: "claude-opus-5-5", counts: TokenCounts(input: 30_000_000))]
            )], now: now)
            shell.usageMonitor = monitor
            shell.taskBudgets = [lead.space: SpaceDefaults.defaultTaskBudget]
            let pty = try XCTUnwrap(shell.taskWorker(task, snapshot: ProcessSnapshot())?.pty)
            let worker = AgentStandIn(), fresh = AgentStandIn()
            defer { worker.remove(); fresh.remove() }
            harness.waitUntil("task shell") { pty.shellPID != nil }
            pty.sendShellLaunchCommand("(\(worker.command()))")
            harness.waitUntil("its Claude worker") { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
            harness.waitUntil("Fresh start at rest") {
                shell.updateSidebar()
                return budgetOffer(of: task, in: shell)?.choices == BudgetChoice.allCases
            }

            harness.restartedAgent = fresh.command()
            shell.takeBudgetChoice(.freshStart, workspaceID: task.id)
            harness.waitUntil("the new conversation") { task.budgetPassedAt != nil }
            XCTAssertEqual(harness.terminalRestarts.count, 1)
            XCTAssertNil(budgetOffer(of: task, in: shell))

            // Mid-turn, past its budget again.
            task.budgetPassedAt = nil
            let column = try XCTUnwrap(shell.taskWorker(task, snapshot: ProcessSnapshot()))
            let freshPty = try XCTUnwrap(column.pty)
            harness.waitUntil("the new worker") { freshPty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
            let agentUUID = try XCTUnwrap(column.agentUUID)
            for name in [AgentHookEvent.Name.sessionStart, .userPromptSubmit] {
                _ = freshPty.applyAgentHook(AgentHookEvent(
                    kind: .claude, name: name, agentUUID: agentUUID, sessionID: agentUUID, timestamp: Date().timeIntervalSince1970
                ), isUserFocused: false)
            }
            harness.waitUntil("no Fresh start mid-turn") {
                shell.updateSidebar()
                return budgetOffer(of: task, in: shell)?.choices == [.keepGoing, .close]
            }
            shell.takeBudgetChoice(.freshStart, workspaceID: task.id)
            XCTAssertEqual(shell.toast?.message, "“Check export” is working or asking: Fresh start waits until it rests.")
            XCTAssertEqual(harness.terminalRestarts.count, 1)
            XCTAssertNil(task.budgetPassedAt)

            harness.alertResponses = [.alertFirstButtonReturn]
            shell.takeBudgetChoice(.close, workspaceID: task.id)
            XCTAssertEqual(harness.alerts.last, "Close workspace “Check export”?")
            XCTAssertFalse(task.isClosing, "Cancel")
        }
    }

    /// A task at work with a heavy context offers "Compact at turn end" in
    /// the title bar popover; queued once, it types /compact when its turn
    /// ends, not before, never twice, and not once compacted another way.
    func testCompactAtTurnEndTypesCompactOnceItsTurnEnds() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            let started = try call(LeadTools.startTask, ["description": "Index rewrite"], lead: lead, in: harness)
            XCTAssertFalse(started.isError, started.text)
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "Index rewrite" })
            let now = Date().timeIntervalSince1970
            let monitor = UsageMonitor(sources: UsageSources(home: harness.home), catalog: { UsageCatalog() })
            @MainActor func report(context: Int) -> UsageReport {
                UsageReport(sessions: [UsageSession(
                    key: UsageSessionKey(.claude, "t"), attribution: UsageAttribution(spaceID: lead.space, taskID: task.id), contextTokens: context,
                    events: [UsageEvent(timestamp: now - 60, model: "claude-opus-5-5", counts: TokenCounts(input: 1_000, cacheRead: context - 1_000))]
                )], now: now)
            }
            monitor.report = report(context: 612_000)
            shell.usageMonitor = monitor
            let column = try XCTUnwrap(shell.taskWorker(task, snapshot: ProcessSnapshot()))
            let pty = try XCTUnwrap(column.pty)
            let worker = AgentStandIn()
            defer { worker.remove() }
            harness.waitUntil("task shell") { pty.shellPID != nil }
            pty.sendShellLaunchCommand("(\(worker.command()))")
            harness.waitUntil("its Claude worker") { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
            var holdings: LeadHoldings? = LeadHoldings(isBusy: true)
            shell.claudeHoldings = { _, held, _ in held === column ? holdings : nil }
            func compacts() -> Int { worker.input.components(separatedBy: "/compact").count - 1 }

            let offer = shell.quotaBurnRows(readings: []).first
            XCTAssertEqual(offer?.actions, [.compactAtTurnEnd(column: column.id)], "mid-turn with 612k")
            XCTAssertEqual(offer?.cause, "Each message rereads 612k")
            shell.takeNotifiedCompact(workspaceID: task.id, column: column.id)
            XCTAssertEqual(shell.compactsAtTurnEnd[column.id], task.id, "the notification's button, while it still applies")
            XCTAssertTrue(shell.takeNotifiedCompact(workspaceID: task.id, column: column.id), "pressed again: already queued")
            XCTAssertNotEqual(shell.toast?.message, "Compact at turn end no longer applies there.")
            shell.runCompactsAtTurnEnd(snapshot: ProcessSnapshot(entries: []))
            XCTAssertEqual(shell.compactsAtTurnEnd[column.id], task.id, "a pass without the process table decides nothing")
            shell.updateSidebar()
            XCTAssertEqual(compacts(), 0, "it waits for the turn to end")
            XCTAssertEqual(shell.quotaBurnRows(readings: []).first?.actions, [], "queued once")
            XCTAssertEqual(shell.quotaBurnRows(readings: []).first?.cause, "Each message rereads 612k · compacts at turn end")

            holdings = LeadHoldings()
            harness.waitUntil("/compact typed at rest") {
                shell.updateSidebar()
                return compacts() == 1
            }
            XCTAssertTrue(shell.compactsAtTurnEnd.isEmpty)
            shell.updateSidebar()
            XCTAssertEqual(compacts(), 1, "once")
            XCTAssertFalse(shell.takeNotifiedCompact(workspaceID: task.id, column: column.id))
            XCTAssertTrue(shell.compactsAtTurnEnd.isEmpty, "pressed late, at rest: no longer applies")

            // A Compact taken by hand replaces its queued twin, typed or refused
            // (the stand-in's screen now reads as a draft).
            holdings = LeadHoldings(isBusy: true)
            shell.takeBurnAction(.compactAtTurnEnd(column: column.id), workspaceID: task.id)
            let index = try XCTUnwrap(task.columns.firstIndex { $0 === column })
            let taskIndex = try XCTUnwrap(shell.workspaces.firstIndex { $0 === task })
            shell.takeContextOffer(.compact, workspaceIndex: taskIndex, columnIndex: index)
            XCTAssertTrue(shell.compactsAtTurnEnd.isEmpty)

            // A draft at rest wins, with a word.
            holdings = LeadHoldings(isBusy: true)
            shell.takeBurnAction(.compactAtTurnEnd(column: column.id), workspaceID: task.id)
            holdings = LeadHoldings(hasDraft: true)
            shell.updateSidebar()
            XCTAssertTrue(shell.compactsAtTurnEnd.isEmpty)
            XCTAssertEqual(shell.toast?.message, "“Index rewrite” won’t compact at turn end: its prompt holds a draft.")

            // Compacted where Nirux can't see it (claude itself, or by hand):
            // a light context sends nothing at rest.
            holdings = LeadHoldings(isBusy: true)
            shell.takeBurnAction(.compactAtTurnEnd(column: column.id), workspaceID: task.id)
            monitor.report = report(context: 40_000)
            let typed = compacts()
            holdings = LeadHoldings()
            shell.updateSidebar()
            XCTAssertTrue(shell.compactsAtTurnEnd.isEmpty)
            XCTAssertEqual(compacts(), typed)
        }
    }

    @MainActor private func budgetOffer(of task: WorkspaceState, in shell: NiruxShellView) -> SidebarBudgetOffer? {
        shell.sidebar.lastInfos.first { $0.id == task.id }?.cardActions.lazy.compactMap {
            if case .budget(let offer) = $0 { offer } else { nil }
        }.first
    }

    func testDailyPassRequiresAPullRequestReadForTheCurrentCheckout() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            let started = try call(LeadTools.startTask, ["description": "Check export"], lead: lead, in: harness)
            XCTAssertFalse(started.isError, started.text)
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "Check export" })
            let mission = try XCTUnwrap(MissionStore.shared.missions.first { $0.childWorkspaceID == task.id })
            let finishedAt = Date().timeIntervalSince1970 - 2 * 86_400
            let result = MissionEvent(
                id: UUID().uuidString, missionID: mission.id, childWorkspaceID: task.id, childAgentUUID: mission.childAgentUUID,
                kind: .completed, message: "Export done", timestamp: finishedAt
            )
            guard case .accepted = MissionStore.shared.process(result, enabled: true) else { return XCTFail("expected a completed mission") }
            task.lastActivityAt = finishedAt
            try UIFlowHarness.git(
                ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "--allow-empty", "-m", "export"],
                at: task.cwd, environment: ["GIT_COMMITTER_DATE": "@\(Int(finishedAt))"]
            )

            var pending: (@MainActor @Sendable (PRDetect.FetchResult) -> Void)?
            shell.fetchPullRequest = { branch, _, _, answer in
                guard branch == "feat/a" || branch == "feat/b" else { return answer(.failure) }
                pending = answer
            }
            @MainActor func checkout(_ branch: String) throws -> GitContext {
                try UIFlowHarness.git(["checkout", "-qb", branch], at: task.cwd)
                let context = try XCTUnwrap(GitDetect.context(at: task.cwd, startFolder: task.cwd))
                task.updateGitContext(context)
                return context
            }
            @MainActor func answerRead(_ result: PRDetect.FetchResult) throws {
                let answer = try XCTUnwrap(pending)
                pending = nil
                answer(result)
            }
            @MainActor func taskLine() throws -> String? {
                let digest = try call(LeadTools.dailyPass, lead: lead, in: harness)
                XCTAssertFalse(digest.isError, digest.text)
                return digest.text.components(separatedBy: "\n").first { $0.hasPrefix("- “Check export” ·") }
            }

            let first = try checkout("feat/a")
            try answerRead(.success(context: first, info: nil))
            harness.waitUntil("A's empty PR read") { task.pullRequestReadAt != nil }
            XCTAssertTrue(try XCTUnwrap(taskLine()).hasSuffix(" → close_task"))

            let second = try checkout("feat/b")
            XCTAssertNotNil(pending)
            XCTAssertNil(try taskLine(), "B's first PR read is still pending")
            try answerRead(.failure)
            XCTAssertNil(try taskLine(), "a failed read leaves B's PR unknown")

            let open = PRInfo(
                number: 8, state: .open, isDraft: false, ciStatus: "SUCCESS", checks: [], reviewDecision: nil, mergeable: "MERGEABLE",
                url: "https://github.com/acme/app/pull/8", additions: nil, deletions: nil, changedFiles: nil
            )
            shell.refreshPRInfo(for: [task])
            try answerRead(.success(context: second, info: open))
            harness.waitUntil("B's open PR") { task.prInfo == open }
            XCTAssertTrue(try XCTUnwrap(taskLine()).contains("PR #8 green and mergeable"))

            shell.refreshPRInfo(for: [task])
            try answerRead(.success(context: second, info: nil))
            harness.waitUntil("B's empty PR read") { task.prInfo == nil }
            let line = try XCTUnwrap(taskLine())
            XCTAssertTrue(line.contains("no pull request") && line.hasSuffix(" → close_task"), line)
        }
    }

    /// The daily pass, on after 06:00 unless Space Settings › Lead says:
    /// once its hour struck and the Lead is quiet, a day with nothing marks
    /// it checked; a day with a recorded review types the daily line into
    /// the Lead's terminal, once. After the Lead reads its day, its row and
    /// Space Settings say what the pass read.
    /// A night where a task only waits (here on its red CI): the pass runs,
    /// its morning line names it, and its quiet text proposes no rule.
    func testADailyPassRunsOnANightWhereATaskOnlyWaits() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            let profile = try XCTUnwrap(shell.profiles.first { $0.id == lead.space })
            shell.addWorkspace(title: "Fix", cwd: harness.worktree, profileID: lead.space)
            let fix = try XCTUnwrap(shell.workspaces.first { $0.title == "Fix" })
            shell.refreshGitContextNow(for: fix)
            harness.waitUntil("its branch") { fix.gitBranch == harness.worktreeBranch }
            var red = PRInfo(number: 812, state: .open, isDraft: false, ciStatus: "FAILURE", checks: [], reviewDecision: nil,
                             mergeable: nil, url: "u", additions: nil, deletions: nil, changedFiles: nil)
            red.headRefOid = "a"
            fix.prInfo = red
            var sent: [String] = []
            shell.checkDailyPasses(now: Date().timeIntervalSince1970, isQuiet: { _ in true }, send: { _, text in sent.append(text) })
            harness.waitUntil("the pass's read") { shell.dailyPassChecks.isEmpty }
            XCTAssertEqual(sent.count, 1, "a task waits: the pass runs")

            var result: (text: String, isError: Bool)?
            shell.leadDailyPass(in: profile, lead: lead.workspace) { result = ($0, $1) }
            harness.waitUntil("the daily pass response") { result != nil }
            let text = try XCTUnwrap(result).text
            XCTAssertTrue(text.contains("red CI, on the task: Fix (#812)"), text)
            XCTAssertTrue(text.contains("Nothing to propose"), text)
            XCTAssertFalse(text.contains("propose_rule"), text)
        }
    }

    func testTheDailyLineReachesAQuietLeadOnceItsHourStruck() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            let column = try XCTUnwrap(lead.workspace.columns.first { $0.agentUUID == lead.agentUUID })
            final class Box: @unchecked Sendable {
                var quiet = false
                var sent: [String] = []
            }
            let box = Box()
            let now = Date().timeIntervalSince1970
            let tomorrow = now + 86_400
            @MainActor func check(at time: TimeInterval) {
                shell.checkDailyPasses(now: time, isQuiet: { _ in box.quiet }, send: { target, text in
                    XCTAssertTrue(target === column, "the Lead's agent")
                    box.sent.append(text)
                })
                harness.waitUntil("the pass's read") { shell.dailyPassChecks.isEmpty }
            }

            check(at: now)
            XCTAssertNil(DailyPassState.load(spaceID: lead.space).checkedAt, "never while the Lead or the user is busy")
            box.quiet = true
            check(at: now)
            XCTAssertEqual(box.sent, [], "nothing happened")
            XCTAssertNotNil(DailyPassState.load(spaceID: lead.space).checkedAt)
            XCTAssertNotNil(DailyPassState.load(spaceID: lead.space).end, "its window is read: the next pass starts there")

            shell.addWorkspace(title: "Fix", cwd: harness.worktree, profileID: lead.space)
            let fix = try XCTUnwrap(shell.workspaces.first { $0.title == "Fix" })
            shell.refreshGitContextNow(for: fix)
            harness.waitUntil("its branch") { fix.gitBranch == harness.worktreeBranch }
            let finding = ["kind": "test-waits-on-sleep", "text": "testFix sleeps"]
            XCTAssertFalse(try call(LeadTools.recordReview, ["task": "Fix", "findings": [finding]], lead: lead, in: harness).isError)
            check(at: now)
            XCTAssertEqual(box.sent, [], "checked for today")
            // A pass it can't record isn't typed: it would come back.
            let file = try XCTUnwrap(DailyPassState.url(spaceID: lead.space))
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            check(at: tomorrow)
            XCTAssertEqual(box.sent, [], "not recorded, not typed")
            let retry = try XCTUnwrap(shell.dailyPassRetryAt[lead.space])
            check(at: tomorrow + 60)
            XCTAssertEqual(shell.dailyPassRetryAt[lead.space], retry, "it waits before trying again")
            try FileManager.default.removeItem(at: file)
            shell.dailyPassRetryAt = [:]
            check(at: tomorrow)
            XCTAssertEqual(box.sent, [DailyPass.prompt])
            check(at: tomorrow)
            XCTAssertEqual(box.sent.count, 1, "once a day")

            XCTAssertFalse(try call(LeadTools.dailyPass, lead: lead, in: harness).isError)
            shell.updateSidebar()
            let note = shell.sidebar.lastInfos.first(where: \.isLead)?.dailyPassNote
            XCTAssertEqual(note, "Daily pass · no rule proposed")
            shell.showSpaceSettings(profileID: lead.space, tab: .lead)
            let pane = try XCTUnwrap(shell.spaceSettings).lead
            XCTAssertTrue(pane.lastPassLabel.stringValue.hasPrefix("Last pass: "), pane.lastPassLabel.stringValue)
            pane.dailyPassHourPopup.selectItem(at: 9)
            pane.dailyPassHourPopup.sendAction(pane.dailyPassHourPopup.action, to: pane.dailyPassHourPopup.target)
            XCTAssertEqual(SpaceDefaultsStore(spaceID: lead.space)?.load().defaults.leadDailyPassHour, 9)
            pane.dailyPassSwitch.state = .off
            pane.dailyPassSwitch.sendAction(pane.dailyPassSwitch.action, to: pane.dailyPassSwitch.target)
            XCTAssertEqual(SpaceDefaultsStore(spaceID: lead.space)?.load().defaults.leadDailyPass, false)
            XCTAssertFalse(pane.dailyPassHourPopup.isEnabled)
            XCTAssertEqual(pane.groupResultsSwitch.state, .off, "the harness's Lead takes its results at once")
            pane.groupResultsSwitch.state = .on
            pane.groupResultsSwitch.sendAction(pane.groupResultsSwitch.action, to: pane.groupResultsSwitch.target)
            XCTAssertNil(SpaceDefaultsStore(spaceID: lead.space)?.load().defaults.leadGroupsResults, "on writes nothing")
            XCTAssertEqual(pane.groupResultsSwitch.state, .on)
            XCTAssertEqual(pane.reviewChecklistSwitch.state, .on)
            pane.reviewChecklistSwitch.state = .off
            pane.reviewChecklistSwitch.sendAction(pane.reviewChecklistSwitch.action, to: pane.reviewChecklistSwitch.target)
            XCTAssertEqual(SpaceDefaultsStore(spaceID: lead.space)?.load().defaults.reviewChecklist, false)
            XCTAssertEqual(pane.reviewChecklistSwitch.state, .off)
            pane.reviewChecklistSwitch.state = .on
            pane.reviewChecklistSwitch.sendAction(pane.reviewChecklistSwitch.action, to: pane.reviewChecklistSwitch.target)
            XCTAssertNil(SpaceDefaultsStore(spaceID: lead.space)?.load().defaults.reviewChecklist, "on writes nothing")
            XCTAssertFalse(try call(LeadTools.recordReview, ["task": "Fix", "findings": [finding]], lead: lead, in: harness).isError)
            check(at: tomorrow + 86_400)
            XCTAssertEqual(box.sent.count, 1, "off, though something happened")
        }
    }

    /// ⌘N in a space with a Lead offers "Report to the Lead", checked: the
    /// task then reports to it. Unchecked, it reports to nobody; a space
    /// without a Lead doesn't offer it.
    func testReportToTheLeadFromTheNewSheet() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            @MainActor func start(_ description: String, reporting: Bool) throws -> WorkspaceState {
                let sheet = try XCTUnwrap(shell.showNewPanel(spaceID: lead.space))
                XCTAssertFalse(sheet.reportCheckbox.isHidden)
                XCTAssertEqual(sheet.reportCheckbox.state, .on, "checked by default")
                if !reporting { sheet.reportCheckbox.performClick(nil) }
                sheet.descriptionView.string = description
                sheet.textDidChange(Notification(name: NSText.didChangeNotification, object: sheet.descriptionView))
                harness.waitUntil("the repository's info") { sheet.info?.target != nil }
                sheet.startButton.performClick(nil)
                harness.waitUntil("the task to open") { shell.workspaces.contains { $0.title == description } }
                return try XCTUnwrap(shell.workspaces.first { $0.title == description })
            }
            let reporting = try start("Reports to the Lead", reporting: true)
            XCTAssertEqual(MissionStore.shared.missions.first { $0.childWorkspaceID == reporting.id }?.parentWorkspaceID, lead.workspace.id)
            XCTAssertTrue(shell.activeWorkspace === reporting, "a task the user starts comes to the front")
            let alone = try start("Reports to nobody", reporting: false)
            XCTAssertNil(MissionStore.shared.missions.first { $0.childWorkspaceID == alone.id })

            let plain = shell.workspaceStore.createProfile(named: "No Lead", select: true).id
            let sheet = try XCTUnwrap(shell.showNewPanel(spaceID: plain))
            XCTAssertTrue(sheet.reportCheckbox.isHidden)
            sheet.cancelButton.performClick(nil)
        }
    }

    /// A task's sub-tasks list right under it, indented, and move among
    /// themselves; the Lead's tasks stay the space's list. A parent archived
    /// lets its children go, where they were listed. Mission children saved
    /// before sub-tasks kept their parent join a task's at restore, never
    /// the main checkout's.
    func testSubtasksListUnderTheirTask() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            @MainActor func open(
                _ title: String, in cwd: String? = nil, under parent: WorkspaceState? = nil,
                missionFrom missionParent: WorkspaceState? = nil
            ) throws -> WorkspaceState {
                let workspaceID = UUID().uuidString
                let agentUUID = UUID().uuidString
                let mission = try missionParent.map { parent in
                    try XCTUnwrap(MissionStore.shared.create(MissionCreationRequest(
                        id: UUID().uuidString, parentWorkspaceID: parent.id,
                        parentAgentUUID: try XCTUnwrap(parent.columns.first?.agentUUID),
                        childWorkspaceID: workspaceID, childAgentUUID: agentUUID, childAgentKind: "claude",
                        branch: "feat/\(title)", reportsToLead: parent.isLead
                    ), enabled: true))
                }
                shell.addWorkspace(
                    title: title, cwd: cwd ?? harness.repo, profileID: lead.space, workspaceID: workspaceID,
                    initialAgentUUID: agentUUID, missionID: mission?.id, parentWorkspaceID: parent?.id,
                    reportsToLead: missionParent?.isLead == true
                )
                return try XCTUnwrap(shell.workspaces.first { $0.id == workspaceID })
            }
            let task = try open("task", in: harness.worktree)
            let other = try open("other")
            _ = try open("lead's task", missionFrom: lead.workspace)
            // Opened last: the store still lists it under its parent.
            let sub = try open("sub", under: task)
            let store = shell.workspaceStore
            let titles = { store.visibleWorkspaceIndices(in: lead.space).map { shell.workspaces[$0].title } }
            let index = { (workspace: WorkspaceState) in try XCTUnwrap(shell.workspaces.firstIndex { $0 === workspace }) }
            XCTAssertEqual(titles(), ["Lead", "task", "sub", "other", "lead's task"])
            XCTAssertEqual(store.activeParents(in: lead.space), [try index(sub): try index(task)])

            shell.updateSidebar()
            let info = try XCTUnwrap(shell.sidebar.displayedWorkspaceInfos.first { $0.id == sub.id })
            XCTAssertEqual(info.parentTitle, "task")
            XCTAssertEqual(
                SidebarCardLayout(workspace: info, sidebarWidth: 260).cardX,
                SidebarExpandedMetrics.workspaceInsetX + SidebarExpandedMetrics.nestIndent
            )

            XCTAssertFalse(store.moveWorkspace(at: try index(sub), delta: -1), "it stays under its parent")
            XCTAssertTrue(store.moveWorkspace(at: try index(task), delta: 1))
            XCTAssertEqual(titles(), ["Lead", "other", "task", "sub", "lead's task"], "its children follow it")

            XCTAssertTrue(store.setWorkspaceInactive(at: try index(task), true))
            XCTAssertEqual(titles(), ["Lead", "other", "sub", "lead's task", "task"], "let go where it was listed")
            XCTAssertTrue(store.activeParents(in: lead.space).isEmpty)

            // Back among the active ones it takes its children back, and the
            // one restored is the one selected.
            XCTAssertTrue(store.moveWorkspace(at: try index(sub), delta: -1))
            shell.updateSidebar()
            shell.handleWorkspaceSidebarAction(.markActive, workspaceIndex: try index(task))
            XCTAssertTrue(shell.activeWorkspace === task)
            XCTAssertEqual(titles(), ["Lead", "other", "task", "sub", "lead's task"])

            // A deleted space's former Lead never takes its tasks under it.
            XCTAssertTrue(store.deleteProfile(id: lead.space))
            let parents = {
                Dictionary(uniqueKeysWithValues: store.activeParents(in: WorkspaceProfile.defaultID).map {
                    (shell.workspaces[$0.key].title, shell.workspaces[$0.value].title)
                })
            }
            XCTAssertEqual(parents(), ["sub": "task"])

            // Mission children saved without a parent: the task's joins it
            // at restore, and keeps it; the main checkout's is a task of
            // its own, as the Lead's tasks stay.
            let old = try open("old", missionFrom: task)
            let side = try open("side", missionFrom: other)
            XCTAssertEqual([old.profileID, side.profileID], [task.profileID, other.profileID])
            XCTAssertEqual(parents(), ["sub": "task"])
            // Saved as a build before sub-tasks kept their parent saved them,
            // the former Lead's folder a worktree (a space anchored there):
            // its task still stays at the top level.
            shell.saveState()
            var state = try XCTUnwrap(Persistence.load())
            for index in state.workspaces.indices {
                if ["old", "side", "lead's task"].contains(state.workspaces[index].title) {
                    state.workspaces[index].parentIsSettled = false
                }
                if state.workspaces[index].id == lead.workspace.id { state.workspaces[index].cwd = harness.worktree }
            }
            XCTAssertTrue(Persistence.save(state))
            shell.restoreState()
            XCTAssertEqual(parents(), ["sub": "task", "old": "task"])
            XCTAssertEqual(shell.persistedState().workspaces.first { $0.title == "old" }?.parentWorkspaceID, task.id)

            // Moved out, it stays a task of its own: its parent was decided
            // once, never again.
            let restoredOld = try XCTUnwrap(shell.workspaces.firstIndex { $0.title == "old" })
            shell.handleWorkspaceSidebarAction(.moveOutOfParent, workspaceIndex: restoredOld)
            XCTAssertEqual(parents(), ["sub": "task"])
            shell.saveState()
            shell.restoreState()
            XCTAssertEqual(parents(), ["sub": "task"])

            // A parent whose repository can't be found now (its worktree's
            // `.git` pointing nowhere, as on a volume not mounted yet): its
            // child is asked about again at the next restore, not settled.
            let pendingFolder = harness.root + "/repo.feat-pending"
            try UIFlowHarness.git(["worktree", "add", "-q", "-b", "feat/pending", pendingFolder], at: harness.repo)
            let pendingParent = try open("pending", in: pendingFolder)
            _ = try open("waiting", missionFrom: pendingParent)
            shell.saveState()
            var unsettled = try XCTUnwrap(Persistence.load())
            for index in unsettled.workspaces.indices where unsettled.workspaces[index].title == "waiting" {
                unsettled.workspaces[index].parentIsSettled = false
            }
            XCTAssertTrue(Persistence.save(unsettled))
            let gitFile = pendingFolder + "/.git"
            let pointer = try String(contentsOfFile: gitFile, encoding: .utf8)
            try "gitdir: /nonexistent/repo/.git/worktrees/repo.feat-pending\n".write(toFile: gitFile, atomically: true, encoding: .utf8)
            shell.restoreState()
            XCTAssertNil(parents()["waiting"])
            XCTAssertEqual(shell.persistedState().workspaces.first { $0.title == "waiting" }?.parentIsSettled, false)
            try pointer.write(toFile: gitFile, atomically: true, encoding: .utf8)
            shell.saveState()
            shell.restoreState()
            XCTAssertEqual(parents()["waiting"], "pending")
        }
    }

    /// The worktree skill names the workspace and terminal it runs in: a
    /// worktree opened from a task lists under it with Missions off (as
    /// `makeLead` sets them, the user's setting), and still does after a
    /// relaunch. One opened from the main checkout, by the Lead, or naming
    /// no terminal is a task of its own. The Lead's list says which task a
    /// sub-task is under, and who started it.
    func testSkillWorktreesListUnderTheirTaskWithMissionsOff() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            shell.addWorkspace(title: "task", cwd: harness.worktree, profileID: lead.space)
            let task = try XCTUnwrap(shell.activeWorkspace)
            shell.addWorkspace(title: "main", cwd: harness.repo, profileID: lead.space)
            let main = try XCTUnwrap(shell.activeWorkspace)
            @MainActor func skill(_ branch: String, from parent: WorkspaceState, naming terminal: Bool = true) throws -> WorkspaceState {
                shell.createWorktreeWorkspace(
                    branch: branch, repoRoot: harness.repo, agent: nil, profileID: lead.space,
                    parentWorkspaceID: parent.id, parentAgentUUID: terminal ? parent.columns.first?.agentUUID : nil
                )
                harness.waitUntil("\(branch)'s workspace") { shell.workspaces.contains { $0.title == branch } }
                return try XCTUnwrap(shell.workspaces.first { $0.title == branch })
            }
            // Opened after "main": the store lists it under its task.
            let sub = try skill("feat/sub", from: task)
            let side = try skill("feat/side", from: main)
            let leads = try skill("feat/leads", from: lead.workspace)
            let loose = try skill("feat/loose", from: task, naming: false)
            // As ⌘N's "Sub-task of" opens one.
            shell.addWorkspace(title: "by hand", cwd: harness.repo, profileID: lead.space, parentWorkspaceID: task.id)
            // Missions turned on since the task's shell started: it has no
            // Mission variables, so no Mission its agent couldn't answer,
            // and the worktree still lists under it.
            XCTAssertTrue(Persistence.updateSettings(liveLayout: shell.persistedState()) { $0.missionHandoffsEnabled = true })
            let late = try skill("feat/late", from: task)
            XCTAssertNil(MissionStore.shared.missions.first { $0.childWorkspaceID == late.id })
            let store = shell.workspaceStore
            let titles = { store.visibleWorkspaceIndices(in: lead.space).map { shell.workspaces[$0].title } }
            let parents = {
                Dictionary(uniqueKeysWithValues: store.activeParents(in: lead.space).map {
                    (shell.workspaces[$0.key].title, shell.workspaces[$0.value].title)
                })
            }
            XCTAssertEqual(titles(), ["Lead", "task", "feat/sub", "by hand", "feat/late", "main", "feat/side", "feat/leads", "feat/loose"])
            XCTAssertEqual(parents(), ["feat/sub": "task", "by hand": "task", "feat/late": "task"])
            XCTAssertEqual(sub.parentWorkspaceID, task.id)
            XCTAssertNil(side.parentWorkspaceID, "the main checkout isn't a task")
            XCTAssertNil(leads.parentWorkspaceID, "a Lead's tasks are the space's list")
            XCTAssertNil(loose.parentWorkspaceID, "no terminal named")

            let list = try call("list_tasks", lead: lead, in: harness).text
            let lines = list.split(separator: "\n").map(String.init)
            @MainActor func line(_ title: String) -> String { lines.first { $0.hasPrefix("- “\(title)”") } ?? "" }
            XCTAssertTrue(line("feat/sub").hasPrefix("- “feat/sub” · sub-task of “task” · "), list)
            XCTAssertTrue(line("feat/sub").hasSuffix(" · not yours (another agent started it)"), list)
            XCTAssertTrue(line("by hand").hasPrefix("- “by hand” · sub-task of “task” · "), list)
            XCTAssertTrue(line("by hand").hasSuffix(" · not yours (started by the user)"), list)

            // A nirux://new-workspace from a terminal is an agent's too; an
            // archived sub-task, no longer listed under its task, still is.
            shell.openRequestedWorkspace(title: "requested", cwd: harness.repo, agent: nil, requestedSpaceID: lead.space)
            harness.waitUntil("the requested workspace") { shell.workspaces.contains { $0.title == "requested" } }
            XCTAssertTrue(store.setWorkspaceInactive(at: try XCTUnwrap(shell.workspaces.firstIndex { $0 === sub }), true))
            let later = try call("list_tasks", lead: lead, in: harness).text.split(separator: "\n").map(String.init)
            @MainActor func laterLine(_ title: String) -> String { later.first { $0.hasPrefix("- “\(title)”") } ?? "" }
            XCTAssertTrue(laterLine("requested").hasSuffix(" · not yours (another agent started it)"), "\(later)")
            XCTAssertTrue(laterLine("feat/sub").contains(" · inactive · "), "\(later)")
            XCTAssertTrue(laterLine("feat/sub").hasSuffix(" · not yours (another agent started it)"), "\(later)")
            XCTAssertTrue(store.setWorkspaceInactive(at: try XCTUnwrap(shell.workspaces.firstIndex { $0 === sub }), false))
            // Two levels: a worktree the skill opens from a sub-task lists
            // under that sub-task's task.
            let deeper = try skill("feat/deeper", from: sub)
            XCTAssertEqual(deeper.parentWorkspaceID, task.id)

            shell.saveState()
            shell.restoreState()
            XCTAssertEqual(parents(), ["feat/sub": "task", "by hand": "task", "feat/late": "task", "feat/deeper": "task"])
            XCTAssertEqual(
                shell.persistedState().workspaces.filter(\.startedByAgent).map(\.title).sorted(),
                ["feat/deeper", "feat/late", "feat/leads", "feat/loose", "feat/side", "feat/sub", "requested"]
            )

            // The skill's title names the workspace.
            shell.createWorktreeWorkspace(branch: "feat/titled", title: "CSV export", repoRoot: harness.repo, agent: nil, profileID: lead.space)
            harness.waitUntil("the titled workspace") { shell.workspaces.contains { $0.title == "CSV export" } }
        }
    }

    /// A defaults.json Nirux can't read asks first: the Lead proposes.
    func testAnUnreadableSettingAsksFirst() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            XCTAssertTrue(shell.leadStartsTasksWithoutAsking(spaceID: lead.space), "on by default")
            let file = try XCTUnwrap(SpaceDefaultsStore(spaceID: lead.space)).fileURL
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{ not json".utf8).write(to: file)
            XCTAssertFalse(shell.leadStartsTasksWithoutAsking(spaceID: lead.space))
            // The switch turns it back on: the file is replaced.
            shell.setLeadStartsTasks(true, spaceID: lead.space)
            XCTAssertTrue(shell.leadStartsTasksWithoutAsking(spaceID: lead.space))
        }
    }

    /// repo "none", or a space without a repository: the task starts in a
    /// new folder of its own, reports to the Lead, and is named by its
    /// folder. Proposed, the sheet has No Repository selected.
    func testTheLeadStartsATaskWithoutARepository() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            let unknown = try call(LeadTools.startTask, ["description": "Compare two parsers", "repo": "web"], lead: lead, in: harness)
            XCTAssertTrue(unknown.isError)
            XCTAssertTrue(unknown.text.contains("repo, \"none\" (a new folder, no repository)"), unknown.text)

            let started = try call(LeadTools.startTask, ["description": "Compare two parsers", "repo": "None"], lead: lead, in: harness)
            XCTAssertFalse(started.isError, started.text)
            let folder = harness.home + "/Nirux Tasks/Compare two parsers"
            XCTAssertTrue(started.text.contains("in \(folder), a new folder without a repository"), started.text)
            XCTAssertTrue(started.text.contains("It reports to you"), started.text)
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "Compare two parsers" })
            XCTAssertTrue(task.isFolderTask)
            XCTAssertEqual(task.profileID, lead.space)
            XCTAssertTrue(shell.activeWorkspace === lead.workspace, "it opens behind what the user is doing")
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder + "/.claude-handover.md"))
            XCTAssertTrue(started.text.contains("may first ask the user to trust that folder"), started.text)
            XCTAssertNotEqual(Persistence.load()?.settings?.startedFolderTask, true, "the user never saw the sheet's trust hint")
            let list = try call(LeadTools.listTasks, lead: lead, in: harness)
            XCTAssertTrue(list.text.contains("“Compare two parsers” · no repository · folder \(task.cwd)"), list.text)
            XCTAssertFalse(try call(LeadTools.tell, ["task": "Compare two parsers", "message": "Add a chart"], lead: lead, in: harness).isError)
            // By the folder list_tasks shows.
            XCTAssertFalse(try call(LeadTools.tell, ["task": task.cwd, "message": "And a table"], lead: lead, in: harness).isError)
            // A title that is another task's folder name reaches neither.
            XCTAssertFalse(try call(LeadTools.startTask, ["description": "Notes: Q3", "repo": "none"], lead: lead, in: harness).isError)
            XCTAssertFalse(try call(LeadTools.startTask, ["description": "Notes- Q3"], lead: lead, in: harness).isError)
            let notes = try XCTUnwrap(shell.workspaces.first { $0.title == "Notes: Q3" })
            XCTAssertEqual(notes.taskFolder.map { ($0 as NSString).lastPathComponent }, "Notes- Q3")
            let ambiguous = try call(LeadTools.tell, ["task": "Notes- Q3", "message": "Which one?"], lead: lead, in: harness)
            XCTAssertTrue(ambiguous.isError, ambiguous.text)
            // A folder task's Mission names it by its title: it has no branch.
            XCTAssertEqual(MissionStore.shared.missions.first { $0.childWorkspaceID == notes.id }?.branch, "Notes: Q3")
            // A title of its own names its row, its folder and its handover.
            let titled = try call(
                LeadTools.startTask,
                ["description": "Write up what we found", "repo": "none", "title": "Findings", "goal": "Compare parser tradeoffs"],
                lead: lead, in: harness
            )
            XCTAssertFalse(titled.isError, titled.text)
            let findings = harness.home + "/Nirux Tasks/Findings"
            XCTAssertTrue(shell.workspaces.contains { $0.title == "Findings" && $0.taskFolder == findings })
            XCTAssertEqual(shell.workspaces.first { $0.taskFolder == findings }?.purpose, "Compare parser tradeoffs")
            XCTAssertTrue(try String(contentsOfFile: findings + "/.claude-handover.md", encoding: .utf8).hasPrefix("# Task: Findings\n"))

            // Proposed: the sheet starts it in a folder too.
            shell.setLeadStartsTasks(false, spaceID: lead.space)
            let proposed = try call(LeadTools.startTask, ["description": "Draft the notes", "repo": "none"], lead: lead, in: harness)
            XCTAssertTrue(proposed.text.hasPrefix("Proposed to the user"), proposed.text)
            let sheet = try XCTUnwrap(shell.newTaskPanel)
            XCTAssertNil(sheet.selectedRepositoryKey)
            XCTAssertEqual(sheet.repositoryPopup.titleOfSelectedItem, "No Repository")
            sheet.cancelButton.performClick(nil)

            // A space without a repository: its tasks start in folders.
            let bare = shell.workspaceStore.createProfile(named: "Notes", select: true).id
            shell.startLead(spaceID: bare)
            let notesLead = try XCTUnwrap(shell.leadWorkspace(inSpace: bare))
            let agent = try XCTUnwrap(notesLead.columns.first?.agentUUID)
            let notesList = try call(LeadTools.listTasks, from: notesLead, agentUUID: agent, in: harness)
            XCTAssertTrue(notesList.text.contains("No repository: each task starts in a new folder of its own"), notesList.text)
            let inBare = try call(LeadTools.startTask, ["description": "Plan the offsite"], from: notesLead, agentUUID: agent, in: harness)
            XCTAssertFalse(inBare.isError, inBare.text)
            XCTAssertEqual(shell.workspaces.first { $0.title == "Plan the offsite" }?.isFolderTask, true)
        }
    }

    /// With "Starts tasks without asking" off, start_task fills the New
    /// sheet in for the user, the task reporting to the Lead.
    func testAProposedTaskWaitsForTheUser() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            shell.setLeadStartsTasks(false, spaceID: lead.space)
            XCTAssertEqual(SpaceDefaultsStore.defaults(forSpace: lead.space).leadStartsTasks, false)
            let tasksBefore = shell.workspaces.count
            shell.sideEffects.validateTaskAgent = { selection, _ in selection }
            shell.sideEffects.listTaskModels = { agent, _ in
                if agent == .codex { throw AgentModels.Refusal("Catalog offline") }
                return [.init(slug: "sonnet", label: "Sonnet")]
            }
            let proposed = try call(LeadTools.startTask, ["description": "Search page", "agent": "codex", "model": "fast"], lead: lead, in: harness)
            XCTAssertFalse(proposed.isError, proposed.text)
            XCTAssertTrue(proposed.text.hasPrefix("Proposed to the user"))
            let sheet = try XCTUnwrap(shell.newTaskPanel)
            XCTAssertEqual(sheet.space.id, lead.space)
            XCTAssertEqual(sheet.descriptionView.string, "Search page")
            XCTAssertEqual(sheet.selectedAgent, .codex)
            harness.waitUntil("the failed catalog") { sheet.modelPopup.toolTip == "Catalog offline" }
            XCTAssertEqual(sheet.selectedModel, "fast")
            XCTAssertEqual(sheet.modelPopup.itemTitles.first, "Default")
            XCTAssertEqual(sheet.reportsTo, NewTask.MissionParent(workspaceID: lead.workspace.id, agentUUID: lead.agentUUID))
            XCTAssertEqual(shell.workspaces.count, tasksBefore, "nothing starts by itself")
            XCTAssertEqual(sheet.startButton.keyEquivalent, "", "a stray Return doesn't start it")
            XCTAssertFalse(sheet.panel?.firstResponder === sheet.descriptionView, "nor do stray keys reach it")

            // One sheet at a time: the next waits for this one to close. Its
            // title heads the description; the branch start_task would make
            // fills the field.
            // Started as proposed, it keeps the title as given, and the goal.
            let title = "Let's merge in order"
            let queued = try call(
                LeadTools.startTask, ["description": "fix: another one", "title": title, "goal": "Merge stacked PRs in order", "model": "claude-custom"],
                lead: lead, in: harness
            )
            XCTAssertFalse(queued.isError)
            XCTAssertTrue(queued.text.hasPrefix("Queued for the user"), queued.text)
            let store = try XCTUnwrap(SpaceDefaultsStore(spaceID: lead.space))
            var defaults = store.load().defaults
            defaults.agent = .agy
            _ = try store.save(defaults).get()
            sheet.cancelButton.performClick(nil)
            harness.waitUntil("the next proposal") { shell.newTaskPanel?.descriptionView.string == title + "\n\nfix: another one" }
            let next = try XCTUnwrap(shell.newTaskPanel)
            XCTAssertEqual(next.selectedAgent, .claude)
            harness.waitUntil("the Claude choices") { next.modelPopup.itemTitles.contains("Sonnet") }
            XCTAssertEqual(next.selectedModel, "claude-custom")
            XCTAssertEqual(next.branchField.stringValue, "fix/let-merge-in-order")
            harness.waitUntil("the repository read") { next.startButton.isEnabled }
            next.startButton.performClick(nil)
            harness.waitUntil("the proposed task") { shell.workspaces.contains { $0.title == title } }
            XCTAssertEqual(shell.workspaces.first { $0.title == title }?.purpose, "Merge stacked PRs in order")

            XCTAssertTrue(try XCTUnwrap(harness.agentLaunches.last).contains("--model 'claude-custom'"))

            let edited = try call(
                LeadTools.startTask, ["description": "docs: parser notes", "title": "Parser notes", "goal": "Compare parser tradeoffs"],
                lead: lead, in: harness
            )
            XCTAssertFalse(edited.isError, edited.text)
            let editSheet = try XCTUnwrap(shell.newTaskPanel)
            editSheet.descriptionView.string = "Write release notes\n\ndocs: parser notes"
            editSheet.descriptionView.didChangeText()
            harness.waitUntil("the edited proposal can start") { editSheet.startButton.isEnabled }
            XCTAssertEqual(editSheet.branchField.stringValue, "docs/write-release-notes")
            editSheet.startButton.performClick(nil)
            harness.waitUntil("the edited task") { shell.workspaces.contains { $0.title == "Write release notes" } }
            XCTAssertNil(shell.workspaces.first { $0.title == "Write release notes" }?.purpose)

            let explicit = try call(
                LeadTools.startTask, ["description": "Write parser notes", "title": "Parser notes", "branch": "docs/handbook"],
                lead: lead, in: harness
            )
            XCTAssertFalse(explicit.isError, explicit.text)
            let explicitSheet = try XCTUnwrap(shell.newTaskPanel)
            explicitSheet.descriptionView.string = "Document the parser"
            explicitSheet.descriptionView.didChangeText()
            harness.waitUntil("the explicitly named branch can start") { explicitSheet.startButton.isEnabled }
            XCTAssertEqual(explicitSheet.branchField.stringValue, "docs/handbook")
            explicitSheet.startButton.performClick(nil)
            harness.waitUntil("the task on its explicit branch") { shell.workspaces.contains { $0.title == "Document the parser" } }
        }
    }

    // MARK: - A task's tools

    /// The answers to `tool` called with each of `argumentsList` at once,
    /// none waiting for another's answer, in that order.
    private func callAtOnce(
        _ tool: String, _ argumentsList: [[String: Any]], from workspace: WorkspaceState, agentUUID: String, in harness: UIFlowHarness
    ) throws -> [(text: String, isError: Bool)] {
        var answers: [Int: (text: String, isError: Bool)] = [:]
        for (index, arguments) in argumentsList.enumerated() {
            let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: arguments), encoding: .utf8))
            let request = LeadChannel.Request(
                id: UUID().uuidString, tool: tool, arguments: json,
                workspaceID: workspace.id, agentUUID: agentUUID, createdAt: Date().timeIntervalSince1970
            )
            harness.shell.handleLeadRequest(request) { text, isError in answers[index] = (text, isError) }
        }
        harness.waitUntil("the answers to \(tool)") { answers.count == argumentsList.count }
        return argumentsList.indices.compactMap { answers[$0] }
    }

    /// A task the Lead started, and its agent's column.
    private func startTask(_ description: String, lead: Lead, in harness: UIFlowHarness) throws -> (WorkspaceState, String) {
        let started = try call(LeadTools.startTask, ["description": description], lead: lead, in: harness)
        XCTAssertFalse(started.isError, started.text)
        let task = try XCTUnwrap(harness.shell.workspaces.first { $0.title == description })
        return (task, try XCTUnwrap(task.columns.first?.agentUUID))
    }

    /// With Missions off, a task's agent starts a sub-task under its task,
    /// in its repository, behind what the user does; lists it; hears its
    /// question and answers it. Two levels, six running at most, its own
    /// sub-tasks only, and none of the Lead's other tools.
    func testATaskStartsFollowsAndAnswersItsSubtasks() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            let (task, agent) = try startTask("Add a date filter", lead: lead, in: harness)
            let other = try XCTUnwrap(shell.workspaces.first { !$0.isLead && $0 !== task })
            let plain = try call(LeadTools.startTask, ["description": "Docs"], from: other,
                                 agentUUID: try XCTUnwrap(other.columns.first?.agentUUID), in: harness)
            XCTAssertTrue(plain.isError)
            XCTAssertTrue(plain.text.contains("isn't a task"), plain.text)
            // Opened by a link from outside Nirux: never, even in a task's
            // worktree. A task under a plain workspace is no sub-task.
            shell.addWorkspace(title: "From a link", cwd: harness.worktree, profileID: lead.space, startedOutsideNirux: true)
            let linked = try XCTUnwrap(shell.workspaces.first { $0.title == "From a link" })
            let outside = try call(LeadTools.startTask, ["description": "Docs"], from: linked,
                                   agentUUID: try XCTUnwrap(linked.columns.first?.agentUUID), in: harness)
            XCTAssertTrue(outside.isError)
            XCTAssertTrue(outside.text.contains("opened by a link from outside Nirux"), outside.text)
            shell.addWorkspace(title: "Under a plain one", cwd: harness.worktree, profileID: lead.space)
            let underPlain = try XCTUnwrap(shell.workspaces.first { $0.title == "Under a plain one" })
            underPlain.parentWorkspaceID = other.id
            let ownList = try call(LeadTools.listTasks, from: underPlain, agentUUID: try XCTUnwrap(underPlain.columns.first?.agentUUID), in: harness)
            XCTAssertFalse(ownList.isError, ownList.text)

            let front = shell.activeWorkspace
            let started = try call(LeadTools.startTask, ["description": "Write the API docs"], from: task, agentUUID: agent, in: harness)
            XCTAssertFalse(started.isError, started.text)
            XCTAssertTrue(started.text.contains("feat/write-api-docs"), started.text)
            XCTAssertTrue(started.text.contains("It reports to you"), started.text)
            let subtask = try XCTUnwrap(shell.workspaces.first { $0.title == "Write the API docs" })
            XCTAssertEqual(subtask.parentWorkspaceID, task.id)
            XCTAssertEqual(subtask.profileID, lead.space)
            XCTAssertTrue(subtask.startedByAgent)
            XCTAssertTrue(shell.activeWorkspace === front, "it opens behind what the user is doing")
            let mission = try XCTUnwrap(MissionStore.shared.missions.first { $0.childWorkspaceID == subtask.id })
            XCTAssertEqual(mission.parentWorkspaceID, task.id)
            XCTAssertEqual(mission.parentAgentUUID, agent)
            XCTAssertEqual(mission.reportsToTask, true)
            XCTAssertNil(mission.reportsToLead)
            XCTAssertEqual(subtask.terminalEnvironment(agentUUID: mission.childAgentUUID)["NIRUX_MISSION_HANDOFFS"], "1",
                           "its agent asks and reports with Missions off")
            XCTAssertEqual(harness.agentLaunches.last.map { $0.contains("This is a Nirux mission workspace") }, true)
            // Kept across a relaunch: its new shells still get the Mission's variables.
            shell.saveState()
            XCTAssertEqual(Persistence.load()?.workspaces.first { $0.id == subtask.id }?.reportsToTask, true)

            let list = try call(LeadTools.listTasks, from: task, agentUUID: agent, in: harness)
            XCTAssertTrue(list.text.hasPrefix("“Add a date filter”: 1 sub-task, 1 running of 6 at most."), list.text)
            XCTAssertTrue(list.text.contains("“Write the API docs”"), list.text)
            XCTAssertTrue(try call(LeadTools.listTasks, lead: lead, in: harness).text
                .contains("“Write the API docs” · sub-task of “Add a date filter”"))

            // Its question, carried with Missions off, typed with the tool
            // to answer it; then answered.
            let question = try ask("Document the old date= parameter?", from: mission)
            let accepted = MissionStore.AcceptedEvent(mission: mission, event: question)
            let prompt = try XCTUnwrap(MissionPromptText.text(for: accepted, childTitle: subtask.title, parentTitle: task.title))
            XCTAssertTrue(prompt.contains("Answer with the reply tool, question \(question.id)"))
            XCTAssertTrue(prompt.contains("ask_user"))
            XCTAssertTrue(prompt.contains("\"$NIRUX_CLI_PATH\" --mission reply --event \(question.id)"))
            XCTAssertTrue(try call(LeadTools.listTasks, from: task, agentUUID: agent, in: harness).text.contains("question \(question.id)"))
            XCTAssertTrue(try call(LeadTools.reply, ["question": question.id, "message": "No"], lead: lead, in: harness).isError,
                          "not the Lead's to answer")
            let (second, secondAgent) = try startTask("Sort the orders", lead: lead, in: harness)
            XCTAssertTrue(try call(LeadTools.reply, ["question": question.id, "message": "No"], from: second, agentUUID: secondAgent, in: harness)
                .isError, "nor another task's")
            // Nor another agent of the same task: the question was typed
            // into the prompt of the one that started the sub-task.
            let otherColumn = UUID().uuidString
            task.addColumn(agentUUID: otherColumn)
            XCTAssertTrue(try call(LeadTools.reply, ["question": question.id, "message": "No"], from: task, agentUUID: otherColumn, in: harness)
                .isError, "nor another column's")
            let othersList = try call(LeadTools.listTasks, from: task, agentUUID: otherColumn, in: harness).text
            XCTAssertTrue(othersList.contains("reports to another agent of this task"), othersList)
            XCTAssertFalse(othersList.contains("question \(question.id)"), othersList)
            XCTAssertFalse(try call(LeadTools.reply, ["question": question.id, "message": "No"], from: task, agentUUID: agent, in: harness).isError)
            XCTAssertEqual(MissionStore.shared.response(to: question.id)?.message, "No")

            // More work, by its title; a question handed to the user, named
            // by its branch, whose answer comes back to the task's agent.
            XCTAssertFalse(try call(LeadTools.tell, ["task": "Write the API docs", "message": "/code-review"], from: task, agentUUID: agent,
                                    in: harness).isError)
            let told = MissionStore.shared.missions.first { $0.id == mission.id }?.events.filter { $0.kind == .instruction }
            XCTAssertEqual(told?.map(\.message), ["/code-review"])
            XCTAssertTrue(try call(LeadTools.tell, ["task": "Add a date filter", "message": "hi"], from: task, agentUUID: agent, in: harness)
                .isError, "only its own sub-tasks")
            XCTAssertTrue(try call(LeadTools.tell, ["task": "Write the API docs", "message": "hi"], from: task, agentUUID: otherColumn,
                                   in: harness).isError, "not another column's")
            shell.refreshGitContextNow(for: subtask)
            harness.waitUntil("the sub-task's branch") { subtask.gitBranch == "feat/write-api-docs" }
            let handed = try ask("Keep the v1 examples?", from: mission)
            let why = "Only the user knows who reads them."
            XCTAssertFalse(try call(LeadTools.askUser, ["task": "feat/write-api-docs", "why": why], from: task, agentUUID: agent,
                                    in: harness).isError)
            let column = try XCTUnwrap(subtask.columns.first { $0.agentUUID == mission.childAgentUUID })
            let row = shell.missionQuestions(foreground: { _ in nil }, now: Date().timeIntervalSince1970)[ObjectIdentifier(column)]
            XCTAssertEqual(row?.handOff, .handedOver(why: why))
            XCTAssertEqual(row?.explanation, "“Add a date filter” passed this one to you: \(why)")
            XCTAssertTrue(shell.answerMissionQuestion(handed.id, text: "Yes"))
            XCTAssertEqual(shell.pendingLeadNotices.last.map { [$0.workspaceID, $0.agentUUID, $0.text] },
                           [task.id, agent, "[Nirux Mission] The user answered “Write the API docs”: Yes"])

            // Two levels: the sub-task has none of its own.
            let subAgent = mission.childAgentUUID
            let nested = try call(LeadTools.startTask, ["description": "Deeper"], from: subtask, agentUUID: subAgent, in: harness)
            XCTAssertTrue(nested.isError)
            XCTAssertTrue(nested.text.contains("two levels"), nested.text)
            XCTAssertTrue(try call(LeadTools.listTasks, from: subtask, agentUUID: subAgent, in: harness).isError)
            // None of the Lead's other tools, nor another terminal's name.
            let merge = try call(LeadTools.queueMerge, ["prs": [1]], from: task, agentUUID: agent, in: harness)
            XCTAssertTrue(merge.isError)
            XCTAssertTrue(merge.text.contains("Only a space's Lead"), merge.text)
            XCTAssertTrue(try call(LeadTools.listTasks, from: task, agentUUID: UUID().uuidString, in: harness).isError)

            // Six running at most, counted before a sub-task's workspace
            // exists: with five running, two calls at once start one. Only
            // those reporting to the task count: not one the user started
            // under it, nor one that completed.
            for index in 2..<TaskTools.maxRunningSubtasks {
                let workspaceID = UUID().uuidString
                var running = MissionCreationRequest(
                    id: UUID().uuidString, parentWorkspaceID: task.id, parentAgentUUID: agent, childWorkspaceID: workspaceID,
                    childAgentUUID: UUID().uuidString, childAgentKind: "claude", branch: "feat/sub-\(index)"
                )
                running.reportsToTask = true
                let created = try XCTUnwrap(MissionStore.shared.create(running, enabled: false))
                shell.addWorkspace(
                    title: "sub \(index)", cwd: harness.repo, profileID: lead.space, workspaceID: workspaceID,
                    missionID: created.id, parentWorkspaceID: task.id, reportsToTask: true
                )
            }
            shell.addWorkspace(title: "the user's", cwd: harness.repo, profileID: lead.space, parentWorkspaceID: task.id)
            XCTAssertEqual(shell.runningSubtaskCount(of: task), TaskTools.maxRunningSubtasks - 1)
            let both = try callAtOnce(
                LeadTools.startTask, [["description": "One more"], ["description": "And another"]], from: task, agentUUID: agent, in: harness
            )
            XCTAssertEqual(both.filter(\.isError).count, 1, both.map(\.text).joined(separator: " / "))
            XCTAssertTrue(both.contains { $0.isError && $0.text.contains("already runs 6 sub-tasks") }, both.map(\.text).joined(separator: " / "))
            XCTAssertEqual(shell.runningSubtaskCount(of: task), TaskTools.maxRunningSubtasks)
            XCTAssertTrue(shell.pendingSubtaskStarts.isEmpty)
            let completed = MissionEvent(
                id: UUID().uuidString, missionID: mission.id,
                childWorkspaceID: mission.childWorkspaceID, childAgentUUID: mission.childAgentUUID,
                kind: .completed, message: "Docs written", timestamp: Date().timeIntervalSince1970
            )
            guard case .accepted = MissionStore.shared.process(completed, enabled: false) else { return XCTFail("its result is carried") }
            XCTAssertEqual(shell.runningSubtaskCount(of: task), TaskTools.maxRunningSubtasks - 1)
            XCTAssertTrue(try call(LeadTools.listTasks, from: task, agentUUID: agent, in: harness).text.contains("completed: Docs written"))
            // A title of its own names its row and its branch; a sub-task's
            // row is narrower.
            let wide = try call(LeadTools.startTask, ["description": "x", "title": "Twenty-one characters"], from: task, agentUUID: agent, in: harness)
            XCTAssertTrue(wide.isError && wide.text.contains("1 to 20 characters for a sub-task"), wide.text)
            let titled = try call(LeadTools.startTask, ["description": "List every endpoint", "title": "API index"], from: task, agentUUID: agent, in: harness)
            XCTAssertTrue(titled.text.hasPrefix("Started “API index” on feat/api-index in "), titled.text)
        }
    }

    /// A task without a repository has its sub-tasks in folders inside its
    /// own, reporting to its agent.
    func testAFolderTasksSubtaskGoesInItsFolder() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            let started = try call(LeadTools.startTask, ["description": "Compare two parsers", "repo": "none"], lead: lead, in: harness)
            XCTAssertFalse(started.isError, started.text)
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "Compare two parsers" })
            let folder = try XCTUnwrap(task.taskFolder)
            let agent = try XCTUnwrap(task.columns.first?.agentUUID)
            let sub = try call(LeadTools.startTask, ["description": "Benchmark the first parser"], from: task, agentUUID: agent, in: harness)
            XCTAssertFalse(sub.isError, sub.text)
            XCTAssertTrue(sub.text.contains("It reports to you"), sub.text)
            let subtask = try XCTUnwrap(shell.workspaces.first { $0.title == "Benchmark the first parser" })
            XCTAssertEqual(subtask.parentWorkspaceID, task.id)
            XCTAssertEqual(subtask.taskFolder, folder + "/Benchmark the first parser")
            XCTAssertEqual(MissionStore.shared.missions.first { $0.childWorkspaceID == subtask.id }?.reportsToTask, true)
        }
    }

    /// With "Starts tasks without asking" off, a task's start_task fills
    /// the New Sub-task sheet in, under the task, without the Lead's
    /// checkbox, once the sheet up closes; started from there, the
    /// sub-task reports to the agent, which hears what the user did, and
    /// hears it too when they close the sheet.
    func testATasksProposedSubtaskWaitsForTheUser() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            let (task, agent) = try startTask("Add a date filter", lead: lead, in: harness)
            shell.setLeadStartsTasks(false, spaceID: lead.space)
            shell.sideEffects.validateTaskAgent = { selection, _ in selection }
            let busy = try XCTUnwrap(shell.showNewPanel(spaceID: lead.space))
            let proposed = try call(LeadTools.startTask, ["description": "Write the API docs", "agent": "agy", "model": "neon"], from: task, agentUUID: agent, in: harness)
            XCTAssertFalse(proposed.isError, proposed.text)
            XCTAssertTrue(proposed.text.hasPrefix("Queued for the user: the New Sub-task sheet shows it once the sheet open now closes."),
                          proposed.text)
            busy.cancelButton.performClick(nil)
            harness.waitUntil("the proposal") { shell.newTaskPanel?.subtaskParentID == task.id }
            let sheet = try XCTUnwrap(shell.newTaskPanel)
            XCTAssertEqual(sheet.headingLabel.stringValue, "Proposed by “Add a date filter” · Tools")
            XCTAssertEqual(sheet.descriptionView.string, "Write the API docs")
            XCTAssertEqual(sheet.selectedModel, "neon")
            XCTAssertTrue(sheet.reportCheckbox.isHidden, "it reports to the task's agent, not the Lead")
            // Not a sub-task any more: the space's Lead is offered again,
            // and the heading still says who proposed it.
            sheet.subtaskCheckbox.performClick(nil)
            XCTAssertFalse(sheet.reportCheckbox.isHidden)
            XCTAssertEqual(sheet.headingLabel.stringValue, "Proposed by “Add a date filter” · Tools")
            sheet.subtaskCheckbox.performClick(nil)
            XCTAssertTrue(sheet.reportCheckbox.isHidden)
            harness.waitUntil("the repository's info") { sheet.info?.target != nil }
            sheet.startButton.performClick(nil)
            harness.waitUntil("the sub-task to open") { shell.workspaces.contains { $0.title == "Write the API docs" } }
            let subtask = try XCTUnwrap(shell.workspaces.first { $0.title == "Write the API docs" })
            XCTAssertEqual(subtask.parentWorkspaceID, task.id)
            XCTAssertTrue(try XCTUnwrap(harness.agentLaunches.last).contains("--model 'neon'"))
            XCTAssertFalse(subtask.startedByAgent, "the user started it")
            let mission = try XCTUnwrap(MissionStore.shared.missions.first { $0.childWorkspaceID == subtask.id })
            XCTAssertEqual(mission.parentWorkspaceID, task.id)
            XCTAssertEqual(mission.reportsToTask, true)
            let notice = { shell.pendingLeadNotices.last.map { [$0.workspaceID, $0.agentUUID, $0.text] } }
            XCTAssertEqual(notice(), [task.id, agent, "[Nirux Mission] The user started the sub-task you proposed, “Write the API docs”, "
                + "under your task: it reports to you."])

            // Closed without starting: the agent hears that too.
            XCTAssertFalse(try call(LeadTools.startTask, ["description": "Draw the diagram"], from: task, agentUUID: agent, in: harness).isError)
            try XCTUnwrap(shell.newTaskPanel).cancelButton.performClick(nil)
            XCTAssertEqual(notice(), [task.id, agent, "[Nirux Mission] The user closed the New Sub-task sheet you proposed (“Draw the diagram”): "
                + "nothing was started."])
        }
    }

    /// GitHub's answers to merge waits' look-ups, by pull request URL: none
    /// found unless set; no answer at all while `isDown`.
    private final class LookUps: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: MergeWait.LookedUp] = [:]
        private var askedFor: [String] = []
        private var down = false

        func set(_ answer: MergeWait.LookedUp) { lock.withLock { answers[answer.url] = answer } }
        var asked: [String] { lock.withLock { askedFor } }
        var isDown: Bool {
            get { lock.withLock { down } }
            set { lock.withLock { down = newValue } }
        }

        func answer(_ url: String) -> Result<MergeWait.LookedUp?, MergeWait.LookUpFailure> {
            lock.withLock {
                askedFor.append(url)
                return down ? .failure(MergeWait.LookUpFailure(reason: "gh: offline")) : .success(answers[url])
            }
        }
    }

    private func pullRequest(_ number: Int, _ state: GitHub.PullRequestState) -> PRInfo {
        PRInfo(
            number: number, state: state, isDraft: false, ciStatus: nil, checks: [], reviewDecision: nil, mergeable: nil,
            url: "https://github.com/o/r/pull/\(number)", additions: nil, deletions: nil, changedFiles: nil
        )
    }

    private func found(_ number: Int, _ state: GitHub.PullRequestState) -> MergeWait.LookedUp {
        MergeWait.LookedUp(number: number, state: state, url: "https://github.com/o/r/pull/\(number)")
    }

    /// The instructions a task's Mission holds.
    private func instructions(to task: WorkspaceState) -> [String] {
        MissionStore.shared.missions.filter { $0.childWorkspaceID == task.id }.flatMap(\.events)
            .filter { $0.kind == .instruction }.map(\.message)
    }

    /// A Lead's task, its branch read: a new branch clears a pull request.
    private func startReadTask(_ description: String, lead: Lead, in harness: UIFlowHarness) throws -> WorkspaceState {
        let (task, _) = try startTask(description, lead: lead, in: harness)
        harness.shell.refreshGitContextNow(for: task)
        harness.waitUntil("the branch of “\(description)”") { task.gitBranch != nil }
        return task
    }

    /// tell's after: the message waits on its task until the other task's
    /// pull request merges, then goes as the Lead's tell, and the Lead hears
    /// it. A pull request closed unmerged, the other task closing first, or
    /// the task itself closing drops it with a line to the Lead.
    func testATellWaitsForAnotherTasksMerge() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            let github = LookUps()
            shell.mergeWaitLookUp = { github.answer($0) }
            let login = try startReadTask("Fix login", lead: lead, in: harness)
            let (filter, _) = try startTask("Add a date filter", lead: lead, in: harness)
            let (docs, _) = try startTask("Write the docs", lead: lead, in: harness)
            let notice = { shell.pendingLeadNotices.last?.text }
            @MainActor func tell(_ message: String, to task: String = "Add a date filter", after: Any) throws -> (text: String, isError: Bool) {
                try call(LeadTools.tell, ["task": task, "message": message, "after": after], lead: lead, in: harness)
            }

            XCTAssertTrue(try tell("hi", after: "nope").isError)
            XCTAssertTrue(try tell("hi", after: 3).isError)
            let own = try tell("hi", after: "Add a date filter")
            XCTAssertTrue(own.isError && own.text.contains("can't wait for its own pull request"), own.text)
            XCTAssertFalse(try tell("now", after: "").isError, "a blank after is left out")
            XCTAssertEqual(instructions(to: filter), ["now"])

            // Held until #41 merges: on the row, in list_tasks, saved.
            login.prInfo = pullRequest(41, .open)
            let held = try tell("merge origin/main", after: "Fix login")
            XCTAssertFalse(held.isError, held.text)
            XCTAssertTrue(
                held.text.hasPrefix("Held: Nirux types it into “Add a date filter”’s prompt as your tell once #41 (“Fix login”) merges."),
                held.text
            )
            XCTAssertEqual(instructions(to: filter), ["now"])
            XCTAssertEqual(shell.persistedState().workspaces.first { $0.id == filter.id }?.mergeWaits, filter.mergeWaits)
            XCTAssertEqual(filter.mergeWaits.count, 1)
            let list = try call(LeadTools.listTasks, lead: lead, in: harness).text
            XCTAssertTrue(list.contains("\n  held until #41 (“Fix login”) merges: your message “merge origin/main”"), list)
            let line = try XCTUnwrap(SidebarHeldMessages(filter.mergeWaits))
            XCTAssertEqual(line.line, "After #41 merges · a message from the Lead")
            harness.waitUntil("the row's line") {
                shell.sidebar.lastInfos.first { $0.id == filter.id }?.cardActions.contains(.heldMessages(line)) == true
            }

            // A read that loses the pull request asks GitHub, once per reading
            // and window.
            github.set(found(41, .open))
            shell.followMergeWaits(awaiting: login, read: nil, now: 1_000)
            harness.waitUntil("GitHub's answer") { github.asked.count == 1 && shell.mergeWaitTracking.lookingUp.isEmpty }
            shell.followMergeWaits(awaiting: login, read: nil, now: 1_001)
            harness.waitUntil("no look-up in flight") { shell.mergeWaitTracking.lookingUp.isEmpty }
            XCTAssertEqual(github.asked, ["https://github.com/o/r/pull/41"])
            shell.followMergeWaits(awaiting: login, read: nil, now: 1_000 + MergeWait.lookUpInterval)
            harness.waitUntil("GitHub asked again") { github.asked.count == 2 && shell.mergeWaitTracking.lookingUp.isEmpty }
            // Another pull request of the branch doesn't count.
            shell.followMergeWaits(awaiting: login, read: pullRequest(40, .merged), now: 1_002 + MergeWait.lookUpInterval)
            harness.waitUntil("GitHub asked about #41") { github.asked.count == 3 && shell.mergeWaitTracking.lookingUp.isEmpty }
            XCTAssertEqual(filter.mergeWaits.count, 1, "#41 still open")

            // Merged: typed as the Lead's tell, and the Lead hears how.
            shell.followMergeWaits(awaiting: login, read: pullRequest(41, .merged), now: 2_000)
            XCTAssertTrue(filter.mergeWaits.isEmpty)
            XCTAssertEqual(instructions(to: filter), ["now", "merge origin/main"])
            XCTAssertEqual(notice()?.hasPrefix("[Nirux Mission] #41 (“Fix login”) merged: Nirux "), true, notice() ?? "")

            // Closed without merging: dropped, and the Lead hears what it said.
            login.prInfo = pullRequest(42, .open)
            XCTAssertFalse(try tell("rebase on #42", after: "Fix login").isError)
            shell.followMergeWaits(awaiting: login, read: pullRequest(42, .closed), now: 2_001)
            XCTAssertTrue(filter.mergeWaits.isEmpty)
            XCTAssertEqual(notice(), "[Nirux Mission] #42 (“Fix login”) closed without merging: your message for “Add a date filter” "
                + "wasn't typed. It said: “rebase on #42”")
            XCTAssertEqual(instructions(to: filter), ["now", "merge origin/main"])

            // Merged already: typed at once.
            login.prInfo = pullRequest(42, .merged)
            let late = try tell("go on", after: "Fix login")
            XCTAssertTrue(late.text.hasPrefix("#42 (“Fix login”) is merged already: Nirux "), late.text)
            XCTAssertEqual(instructions(to: filter), ["now", "merge origin/main", "go on"])
            XCTAssertTrue(filter.mergeWaits.isEmpty)

            // The task holding it closes: the Lead hears it wasn't typed.
            XCTAssertFalse(try tell("link the login page", to: "Write the docs", after: "Add a date filter").isError)
            XCTAssertEqual(docs.mergeWaits.count, 1)
            shell.closeWorkspace(at: try XCTUnwrap(shell.workspaces.firstIndex { $0 === docs }), refocusing: false)
            XCTAssertEqual(notice(), "[Nirux Mission] “Write the docs” closed: your message held until “Add a date filter” merges "
                + "wasn't typed. It said: “link the login page”")

            // The task it waits for closes first: GitHub says whether it merged.
            login.prInfo = pullRequest(43, .open)
            XCTAssertFalse(try tell("after 43", after: "Fix login").isError)
            github.set(found(43, .open))
            shell.closeWorkspace(at: try XCTUnwrap(shell.workspaces.firstIndex { $0 === login }), refocusing: false)
            harness.waitUntil("the wait to settle") { filter.mergeWaits.isEmpty }
            XCTAssertEqual(notice(), "[Nirux Mission] “Fix login” closed while #43 was still open: your message for “Add a date filter” "
                + "wasn't typed. It said: “after 43”")
            XCTAssertEqual(instructions(to: filter), ["now", "merge origin/main", "go on"])

            // Kept across a relaunch; one whose task didn't come back asks
            // GitHub then.
            let ship = try startReadTask("Ship it", lead: lead, in: harness)
            ship.prInfo = pullRequest(44, .open)
            XCTAssertFalse(try tell("ship it too", after: "Ship it").isError)
            github.set(found(44, .merged))
            shell.saveState()
            var state = try XCTUnwrap(Persistence.load())
            state.workspaces.removeAll { $0.id == ship.id }
            XCTAssertTrue(Persistence.save(state))
            shell.restoreState()
            harness.waitUntil("the restored wait to settle") { shell.workspaces.first { $0.id == filter.id }?.mergeWaits.isEmpty == true }
            XCTAssertEqual(instructions(to: filter), ["now", "merge origin/main", "go on", "ship it too"])
        }
    }

    /// The usual pull request reads settle a held message: those of an
    /// archived task, and away from Nirux, where the heartbeat stops, at the
    /// hot cadence.
    func testAHeldTellFollowsTheTasksPullRequestReads() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            final class Clock { var now: TimeInterval = 1_000 }
            let clock = Clock()
            shell.gitRefresh = GitRefreshCoordinator(clock: { clock.now })
            final class Answers { var byBranch: [String: PRInfo] = [:] }
            let answers = Answers()
            shell.fetchPullRequest = { [weak shell] branch, _, _, done in
                guard let context = shell?.workspaces.first(where: { $0.gitBranch == branch })?.gitContext else { return done(.failure) }
                done(.success(context: context, info: answers.byBranch[branch]))
            }
            let login = try startReadTask("Fix login", lead: lead, in: harness)
            let branch = try XCTUnwrap(login.gitBranch)
            let (filter, _) = try startTask("Add a date filter", lead: lead, in: harness)
            // A read starts once the one in flight is over.
            @MainActor func read(until what: String, _ done: () -> Bool) {
                harness.waitUntil(what) {
                    shell.refreshPRInfo(for: [login])
                    return done()
                }
            }
            answers.byBranch[branch] = pullRequest(51, .open)
            read(until: "#51 read") { login.prInfo?.number == 51 }
            XCTAssertFalse(try call(LeadTools.tell, ["task": "Add a date filter", "message": "first", "after": "Fix login"],
                                    lead: lead, in: harness).isError)

            // Archived, it is still read, as a background task.
            login.isInactive = true
            XCTAssertEqual(shell.gitRefreshTier(for: login), .background)
            answers.byBranch[branch] = pullRequest(51, .merged)
            read(until: "the message to go") { instructions(to: filter) == ["first"] }
            XCTAssertEqual(shell.gitRefreshTier(for: login), .archived, "followed no more")
            login.isInactive = false

            // Away from Nirux: read once the hot cadence is up.
            answers.byBranch[branch] = pullRequest(52, .open)
            clock.now += 600
            read(until: "#52 read") { login.prInfo?.number == 52 }
            XCTAssertFalse(try call(LeadTools.tell, ["task": "Add a date filter", "message": "second", "after": "Fix login"],
                                    lead: lead, in: harness).isError)
            answers.byBranch[branch] = pullRequest(52, .merged)
            shell.refreshStuckAgents(appIsActive: false)
            XCTAssertEqual(filter.mergeWaits.count, 1, "just read: not due yet")
            clock.now += PullRequestRefreshPolicy.interval(for: .background, pullRequest: nil, awaited: true) ?? 0
            harness.waitUntil("the second message to go") {
                shell.refreshStuckAgents(appIsActive: false)
                return instructions(to: filter) == ["first", "second"]
            }
        }
    }

    /// A merged message that can't go (no agent to take it) stays, and is
    /// tried again for a day; one whose task closed is settled by what
    /// close_task read of its branch, or by GitHub, asked a few times.
    func testAMergedTellThatCantGoIsTriedForADay() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            let github = LookUps()
            shell.mergeWaitLookUp = { github.answer($0) }
            let notice = { shell.pendingLeadNotices.last?.text }
            let login = try startReadTask("Fix login", lead: lead, in: harness)
            // The user's task, with no agent running: nothing takes a tell.
            shell.addWorkspace(title: "Flow work", cwd: harness.worktree, profileID: lead.space)
            let flow = try XCTUnwrap(shell.workspaces.first { $0.title == "Flow work" })
            login.prInfo = pullRequest(61, .open)
            XCTAssertFalse(try call(LeadTools.tell, ["task": "Flow work", "message": "pull main", "after": "Fix login"],
                                    lead: lead, in: harness).isError)
            // The real clock: a stuck-agent pass the test doesn't make may run.
            let mergedAt = Date().timeIntervalSince1970
            shell.followMergeWaits(awaiting: login, read: pullRequest(61, .merged), now: mergedAt)
            XCTAssertEqual(flow.mergeWaits.map(\.mergedAt), [mergedAt], "kept")
            XCTAssertEqual(notice()?.hasPrefix("[Nirux Mission] #61 (“Fix login”) merged, but your message for “Flow work” can't go yet: "),
                           true, notice() ?? "")
            let notices = shell.pendingLeadNotices.count
            XCTAssertEqual(SidebarHeldMessages(flow.mergeWaits)?.line, "#61 merged · a message from the Lead waits to go")
            // Away from Nirux too.
            shell.refreshStuckAgents(now: mergedAt + MergeWait.lookUpInterval, appIsActive: false)
            XCTAssertEqual(flow.mergeWaits.count, 1, "tried again, still no agent")
            XCTAssertEqual(shell.pendingLeadNotices.count, notices, "heard once")
            shell.refreshStuckAgents(now: mergedAt + MergeWait.deliveryLifetime, appIsActive: false)
            XCTAssertTrue(flow.mergeWaits.isEmpty)
            XCTAssertEqual(notice(), "[Nirux Mission] #61 (“Fix login”) merged a day ago, and your message for “Flow work” couldn't go "
                + "since: Nirux dropped it. It said: “pull main”")

            // close_task read #7 merged on its branch: the message goes, though
            // no read ever saw it open.
            _ = try harness.stubCleanupTools()
            try UIFlowHarness.git(["remote", "add", "acme", "https://github.com/acme/widgets.git"], at: harness.repo)
            let merged = harness.root + "/repo.feat-merged"
            try harness.mergedWorktree("feat/merged", in: merged, number: 7)
            shell.addWorkspace(title: "Merged work", cwd: merged, profileID: lead.space)
            let (filter, _) = try startTask("Add a date filter", lead: lead, in: harness)
            XCTAssertFalse(try call(LeadTools.tell, ["task": "Add a date filter", "message": "after 7", "after": "Merged work"],
                                    lead: lead, in: harness).isError)
            let closed = try harness.callLeadTool(LeadTools.closeTask, ["task": "Merged work"], lead: lead, timeout: 180)
            XCTAssertFalse(closed.isError, closed.text)
            XCTAssertEqual(instructions(to: filter), ["after 7"])
            XCTAssertTrue(filter.mergeWaits.isEmpty)
            XCTAssertTrue(github.asked.isEmpty, "close_task's word was enough")

            // A branch name used before: its old merged pull request, which
            // lacks the branch's tip, doesn't count.
            let reused = harness.root + "/repo.feat-reused"
            try UIFlowHarness.git(["worktree", "add", "-q", "-b", "feat/reused", reused], at: harness.repo)
            try UIFlowHarness.git(
                ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "--allow-empty", "-m", "new work"], at: reused
            )
            try UIFlowHarness.git(["config", "branch.feat/reused.pushRemote", "acme"], at: harness.repo)
            let old = try UIFlowHarness.git(["rev-parse", "main"], at: harness.repo).trimmingCharacters(in: .whitespacesAndNewlines)
            let oldPullRequest: [String: Any] = [
                "number": 5, "state": "MERGED", "headRefOid": old, "url": "https://github.com/acme/widgets/pull/5",
                "headRepositoryOwner": ["login": "acme"], "headRepository": ["name": "widgets"]
            ]
            try JSONSerialization.data(withJSONObject: [oldPullRequest]).write(to: URL(fileURLWithPath: harness.root + "/prs/feat-reused.json"))
            shell.addWorkspace(title: "Reused work", cwd: reused, profileID: lead.space)
            XCTAssertFalse(try call(LeadTools.tell, ["task": "Add a date filter", "message": "after reuse", "after": "Reused work"],
                                    lead: lead, in: harness).isError)
            XCTAssertFalse(try harness.callLeadTool(LeadTools.closeTask, ["task": "Reused work"], lead: lead, timeout: 180).isError)
            XCTAssertTrue(filter.mergeWaits.isEmpty)
            XCTAssertEqual(notice(), "[Nirux Mission] “Reused work” closed without a merged pull request: your message for "
                + "“Add a date filter” wasn't typed. It said: “after reuse”")
            XCTAssertEqual(instructions(to: filter), ["after 7"])

            // GitHub doesn't answer about a closed task's #62: asked again
            // each window, a few times, then the Lead hears it.
            login.prInfo = pullRequest(62, .open)
            XCTAssertFalse(try call(LeadTools.tell, ["task": "Add a date filter", "message": "after 62", "after": "Fix login"],
                                    lead: lead, in: harness).isError)
            github.isDown = true
            // Unanswered while the task is open: those tries don't count once
            // it closes.
            shell.followMergeWaits(awaiting: login, read: nil, now: Date().timeIntervalSince1970)
            harness.waitUntil("GitHub asked") { github.asked.count == 1 && shell.mergeWaitTracking.lookingUp.isEmpty }
            XCTAssertEqual(filter.mergeWaits.count, 1)
            shell.closeWorkspace(at: try XCTUnwrap(shell.workspaces.firstIndex { $0 === login }), refocusing: false)
            harness.waitUntil("GitHub asked as it closed") { github.asked.count == 2 && shell.mergeWaitTracking.lookingUp.isEmpty }
            let start = Date().timeIntervalSince1970
            for window in 1..<MergeWait.maxUnansweredLookUps {
                XCTAssertEqual(filter.mergeWaits.count, 1, "try \(window)")
                shell.sweepMergeWaits(now: start + Double(window) * MergeWait.lookUpInterval)
                harness.waitUntil("GitHub asked again") { github.asked.count == window + 2 && shell.mergeWaitTracking.lookingUp.isEmpty }
            }
            XCTAssertTrue(filter.mergeWaits.isEmpty)
            XCTAssertEqual(notice(), "[Nirux Mission] “Fix login” closed, and GitHub couldn't say whether it merged (gh: offline): "
                + "your message for “Add a date filter” wasn't typed. It said: “after 62”")
        }
    }
}
