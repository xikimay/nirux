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
            XCTAssertEqual(row?.handOff, .handedOver(why: why))
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

            let started = try call(LeadTools.startTask, ["description": "Write the API docs"], from: task, agentUUID: agent, in: harness)
            XCTAssertFalse(started.isError, started.text)
            XCTAssertTrue(started.text.contains("feat/write-the-api-docs"), started.text)
            XCTAssertTrue(started.text.contains("It reports to you"), started.text)
            let subtask = try XCTUnwrap(shell.workspaces.first { $0.title == "Write the API docs" })
            XCTAssertEqual(subtask.parentWorkspaceID, task.id)
            XCTAssertEqual(subtask.profileID, lead.space)
            XCTAssertTrue(subtask.startedByAgent)
            XCTAssertTrue(shell.activeWorkspace === lead.workspace, "it opens behind what the user is doing")
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
            XCTAssertEqual(
                MissionPromptText.text(for: accepted, childTitle: subtask.title, parentTitle: task.title),
                "[Nirux Mission] Question from \"Write the API docs\" (branch feat/write-the-api-docs):\nDocument the old date= parameter?\n"
                    + "Answer with the reply tool, question \(question.id); if neither the code nor the user's words settle it, "
                    + "don't guess: hand it to the user with ask_user."
            )
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
            harness.waitUntil("the sub-task's branch") { subtask.gitBranch == "feat/write-the-api-docs" }
            let handed = try ask("Keep the v1 examples?", from: mission)
            let why = "Only the user knows who reads them."
            XCTAssertFalse(try call(LeadTools.askUser, ["task": "feat/write-the-api-docs", "why": why], from: task, agentUUID: agent,
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
            let busy = try XCTUnwrap(shell.showNewPanel(spaceID: lead.space))
            let proposed = try call(LeadTools.startTask, ["description": "Write the API docs"], from: task, agentUUID: agent, in: harness)
            XCTAssertFalse(proposed.isError, proposed.text)
            XCTAssertTrue(proposed.text.hasPrefix("Queued for the user: the New Sub-task sheet shows it once the sheet open now closes."),
                          proposed.text)
            busy.cancelButton.performClick(nil)
            harness.waitUntil("the proposal") { shell.newTaskPanel?.subtaskParentID == task.id }
            let sheet = try XCTUnwrap(shell.newTaskPanel)
            XCTAssertEqual(sheet.headingLabel.stringValue, "Proposed by “Add a date filter” · Tools")
            XCTAssertEqual(sheet.descriptionView.string, "Write the API docs")
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
}
