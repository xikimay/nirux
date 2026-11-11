import AppKit
import XCTest
@testable import Nirux

/// What the app does with the Lead's tools (NiruxShellView+LeadTools), in
/// a real window on throwaway state (see UIFlowHarness). Requests are
/// handed to the shell as LeadRequestCenter does.
@MainActor
final class LeadToolsFlowTests: XCTestCase {
    private struct Lead {
        let space: String
        let workspace: WorkspaceState
        let agentUUID: String
    }

    /// A space anchored to the harness's repository, with its Lead, and
    /// Mission handoffs off: the Lead's tasks must work all the same.
    private func makeLead(_ harness: UIFlowHarness) throws -> Lead {
        let shell = harness.shell
        shell.projectBoardClient = ProjectBoardFlowTests.FakeGitHub(openPullRequests: "[]", runs: "[]")
        XCTAssertTrue(Persistence.updateSettings(liveLayout: shell.persistedState()) { $0.missionHandoffsEnabled = false })
        let repository = SpaceAnchor(kind: .gitRepository(commonDir: harness.repo + "/.git"), name: "repo", isDefault: true)
        let space = shell.workspaceStore.createProfile(named: "Tools", anchors: [repository], select: true).id
        shell.startLead(spaceID: space)
        let workspace = try XCTUnwrap(shell.leadWorkspace(inSpace: space))
        return Lead(space: space, workspace: workspace, agentUUID: try XCTUnwrap(workspace.columns.first?.agentUUID))
    }

    /// The answer to a request from `workspace`'s column, once it comes.
    private func call(
        _ tool: String, _ arguments: [String: Any] = [:], from workspace: WorkspaceState, agentUUID: String,
        in harness: UIFlowHarness, file: StaticString = #filePath, line: UInt = #line
    ) throws -> (text: String, isError: Bool) {
        let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: arguments), encoding: .utf8))
        let request = LeadChannel.Request(
            id: UUID().uuidString, tool: tool, arguments: json,
            workspaceID: workspace.id, agentUUID: agentUUID, createdAt: Date().timeIntervalSince1970
        )
        var answer: (text: String, isError: Bool)?
        harness.shell.handleLeadRequest(request) { text, isError in answer = (text, isError) }
        harness.waitUntil("the answer to \(tool)", file: file, line: line) { answer != nil }
        return try XCTUnwrap(answer, file: file, line: line)
    }

    private func call(_ tool: String, _ arguments: [String: Any] = [:], lead: Lead, in harness: UIFlowHarness) throws -> (text: String, isError: Bool) {
        try call(tool, arguments, from: lead.workspace, agentUUID: lead.agentUUID, in: harness)
    }

    /// A question from `task`'s agent, as its `ask` records it.
    private func ask(_ text: String, from mission: Mission) throws -> MissionEvent {
        let question = MissionEvent(
            id: UUID().uuidString, missionID: mission.id,
            childWorkspaceID: mission.childWorkspaceID, childAgentUUID: mission.childAgentUUID,
            kind: .question, message: text, timestamp: Date().timeIntervalSince1970
        )
        guard case .accepted = MissionStore.shared.process(question, enabled: false) else {
            XCTFail("the Lead's task asks with handoffs off")
            return question
        }
        return question
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
            XCTAssertTrue(started.text.contains("feat/add-a-date-filter"), started.text)
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "Add a date filter" })
            XCTAssertEqual(task.profileID, lead.space)
            XCTAssertTrue(shell.activeWorkspace === lead.workspace, "it opens behind what the user is doing")
            let mission = try XCTUnwrap(MissionStore.shared.missions.first { $0.childWorkspaceID == task.id })
            XCTAssertEqual(mission.reportsToLead, true)
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

            // A question it hands to the user, the task named by its branch:
            // amber at once, with why.
            shell.refreshGitContextNow(for: task)
            harness.waitUntil("the task's branch") { task.gitBranch == "feat/add-a-date-filter" }
            let second = try ask("Keep the old date= parameter?", from: mission)
            let why = "Only the user knows what the mobile app needs."
            XCTAssertFalse(try call(LeadTools.askUser, ["task": "feat/add-a-date-filter", "why": why], lead: lead, in: harness).isError)
            let column = try XCTUnwrap(task.columns.first { $0.agentUUID == mission.childAgentUUID })
            let row = shell.missionQuestions(foreground: { _ in nil }, now: Date().timeIntervalSince1970)[ObjectIdentifier(column)]
            XCTAssertEqual(row?.handOff, .lead(why: why))
            XCTAssertTrue(shell.answerMissionQuestion(second.id, text: "Yes, until v3"))
            XCTAssertEqual(shell.pendingLeadNotices.map(\.text), ["[Nirux Mission] The user answered “Add a date filter”: Yes, until v3"])

            XCTAssertFalse(try call(LeadTools.tell, ["task": "Add a date filter", "message": "/code-review"], lead: lead, in: harness).isError)
            let instructions = MissionStore.shared.missions.first { $0.id == mission.id }?.events.filter { $0.kind == .instruction }
            XCTAssertEqual(instructions?.map(\.message), ["/code-review"])
            XCTAssertTrue(try call(LeadTools.tell, ["task": "nope", "message": "hi"], lead: lead, in: harness).isError)
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
                harness.waitUntil("the popover to close", timeout: 5) { !reply.popover.isShown }
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
                harness.waitUntil("Esc to close the popover", timeout: 5) { !reply.popover.isShown }
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
            XCTAssertTrue(ambiguous.text.contains("several share that title"), ambiguous.text)
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

            shell.saveState()
            shell.restoreState()
            XCTAssertEqual(parents(), ["feat/sub": "task", "by hand": "task", "feat/late": "task"])
            XCTAssertEqual(
                shell.persistedState().workspaces.filter(\.startedByAgent).map(\.title).sorted(),
                ["feat/late", "feat/leads", "feat/loose", "feat/side", "feat/sub", "requested"]
            )
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
            let list = try call(LeadTools.listTasks, lead: lead, in: harness)
            XCTAssertTrue(list.text.contains("“Compare two parsers” · no repository · folder \(task.cwd)"), list.text)
            XCTAssertFalse(try call(LeadTools.tell, ["task": "Compare two parsers", "message": "Add a chart"], lead: lead, in: harness).isError)

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
            let proposed = try call(LeadTools.startTask, ["description": "Search page"], lead: lead, in: harness)
            XCTAssertFalse(proposed.isError, proposed.text)
            XCTAssertTrue(proposed.text.hasPrefix("Proposed to the user"))
            let sheet = try XCTUnwrap(shell.newTaskPanel)
            XCTAssertEqual(sheet.space.id, lead.space)
            XCTAssertEqual(sheet.descriptionView.string, "Search page")
            XCTAssertEqual(sheet.reportsTo, NewTask.MissionParent(workspaceID: lead.workspace.id, agentUUID: lead.agentUUID))
            XCTAssertEqual(shell.workspaces.count, tasksBefore, "nothing starts by itself")
            XCTAssertEqual(sheet.startButton.keyEquivalent, "", "a stray Return doesn't start it")
            XCTAssertFalse(sheet.panel?.firstResponder === sheet.descriptionView, "nor do stray keys reach it")

            // One sheet at a time: the next waits for this one to close.
            let queued = try call(LeadTools.startTask, ["description": "Another one"], lead: lead, in: harness)
            XCTAssertFalse(queued.isError)
            XCTAssertTrue(queued.text.hasPrefix("Queued for the user"), queued.text)
            sheet.cancelButton.performClick(nil)
            harness.waitUntil("the next proposal") { shell.newTaskPanel?.descriptionView.string == "Another one" }
            shell.newTaskPanel?.cancelButton.performClick(nil)
        }
    }
}
