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
            XCTAssertTrue(list.text.contains("Repositories: repo (default)."), list.text)

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

    /// A task's own Mission children list right under it, indented, and
    /// move among themselves; the Lead's tasks stay the space's list. A
    /// parent archived lets its children go, where they were listed.
    func testMissionChildrenListUnderTheirParent() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try makeLead(harness)
            @MainActor func open(_ title: String, reportingTo parent: WorkspaceState? = nil) throws -> WorkspaceState {
                let workspaceID = UUID().uuidString
                let agentUUID = UUID().uuidString
                let mission = try parent.map { parent in
                    try XCTUnwrap(MissionStore.shared.create(MissionCreationRequest(
                        id: UUID().uuidString, parentWorkspaceID: parent.id,
                        parentAgentUUID: try XCTUnwrap(parent.columns.first?.agentUUID),
                        childWorkspaceID: workspaceID, childAgentUUID: agentUUID, childAgentKind: "claude",
                        branch: "feat/\(title)", reportsToLead: parent.isLead
                    ), enabled: true))
                }
                shell.addWorkspace(
                    title: title, cwd: harness.repo, profileID: lead.space, workspaceID: workspaceID,
                    initialAgentUUID: agentUUID, missionID: mission?.id, reportsToLead: parent?.isLead == true
                )
                return try XCTUnwrap(shell.activeWorkspace)
            }
            let task = try open("task")
            let other = try open("other")
            _ = try open("lead's task", reportingTo: lead.workspace)
            // Opened last: the store still lists it under its parent.
            let sub = try open("sub", reportingTo: task)
            let store = shell.workspaceStore
            let titles = { store.visibleWorkspaceIndices(in: lead.space).map { shell.workspaces[$0].title } }
            let index = { (workspace: WorkspaceState) in try XCTUnwrap(shell.workspaces.firstIndex { $0 === workspace }) }
            XCTAssertEqual(titles(), ["Lead", "task", "sub", "other", "lead's task"])
            XCTAssertEqual(store.nestedWorkspaceIndices(in: lead.space), [try index(sub)])

            shell.updateSidebar()
            let info = try XCTUnwrap(shell.sidebar.displayedWorkspaceInfos.first { $0.id == sub.id })
            XCTAssertTrue(info.isNested)
            XCTAssertEqual(
                SidebarCardLayout(workspace: info, sidebarWidth: 260).cardX,
                SidebarExpandedMetrics.workspaceInsetX + SidebarExpandedMetrics.nestIndent
            )

            XCTAssertFalse(store.moveWorkspace(at: try index(sub), delta: -1), "it stays under its parent")
            XCTAssertTrue(store.moveWorkspace(at: try index(task), delta: 1))
            XCTAssertEqual(titles(), ["Lead", "other", "task", "sub", "lead's task"], "its children follow it")

            XCTAssertTrue(store.setWorkspaceInactive(at: try index(task), true))
            XCTAssertEqual(titles(), ["Lead", "other", "sub", "lead's task", "task"], "let go where it was listed")
            XCTAssertTrue(store.nestedWorkspaceIndices(in: lead.space).isEmpty)

            // Back among the active ones it takes its children back, and the
            // one restored is the one selected.
            XCTAssertTrue(store.moveWorkspace(at: try index(sub), delta: -1))
            shell.updateSidebar()
            shell.handleWorkspaceSidebarAction(.markActive, workspaceIndex: try index(task))
            XCTAssertTrue(shell.activeWorkspace === task)
            XCTAssertEqual(titles(), ["Lead", "other", "task", "sub", "lead's task"])

            // A deleted space's former Lead never takes its tasks under it.
            XCTAssertTrue(store.deleteProfile(id: lead.space))
            XCTAssertEqual(
                store.nestedWorkspaceIndices(in: WorkspaceProfile.defaultID).map { shell.workspaces[$0].title }, ["sub"]
            )
            _ = other
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
