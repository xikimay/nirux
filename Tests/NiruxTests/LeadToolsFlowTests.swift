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
            XCTAssertTrue(try call(LeadTools.startTask, ["description": "Another one"], lead: lead, in: harness).isError, "one sheet at a time")
            sheet.cancelButton.performClick(nil)
        }
    }
}
