import AppKit
import XCTest
@testable import Nirux

/// A space's Lead in the harness, and its tools called as LeadRequestCenter
/// hands them to the shell.
extension UIFlowHarness {
    struct Lead {
        let space: String
        let workspace: WorkspaceState
        let agentUUID: String
    }

    /// A space anchored to the harness's repository, with its Lead, and
    /// Mission handoffs off: the Lead's tasks must work all the same. Its
    /// tasks' results reach it at once: a flow can't wait out the group's
    /// window (`MissionResultBatch`).
    func makeLead(environment: [SpaceDefaults.EnvironmentVariable] = []) throws -> Lead {
        shell.projectBoardClient = ProjectBoardFlowTests.FakeGitHub(openPullRequests: "[]", runs: "[]")
        XCTAssertTrue(Persistence.updateSettings(liveLayout: shell.persistedState()) { $0.missionHandoffsEnabled = false })
        let repository = SpaceAnchor(kind: .gitRepository(commonDir: repo + "/.git"), name: "repo", isDefault: true)
        let space = shell.workspaceStore.createProfile(named: "Tools", anchors: [repository], select: true).id
        shell.changeSpaceDefaults(spaceID: space) {
            $0.environment = environment
            $0.leadGroupsResults = false
        }
        shell.startLead(spaceID: space)
        let workspace = try XCTUnwrap(shell.leadWorkspace(inSpace: space))
        return Lead(space: space, workspace: workspace, agentUUID: try XCTUnwrap(workspace.columns.first?.agentUUID))
    }

    /// The answer to a request from `workspace`'s column, once it comes,
    /// within `timeout` seconds.
    func callLeadTool(
        _ tool: String, _ arguments: [String: Any] = [:], from workspace: WorkspaceState, agentUUID: String,
        timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line
    ) throws -> (text: String, isError: Bool) {
        let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: arguments), encoding: .utf8))
        let request = LeadChannel.Request(
            id: UUID().uuidString, tool: tool, arguments: json,
            workspaceID: workspace.id, agentUUID: agentUUID, createdAt: Date().timeIntervalSince1970
        )
        final class Answer: @unchecked Sendable {
            var value: (text: String, isError: Bool)?
        }
        let answer = Answer()
        let shell = self.shell
        // From the run loop, as LeadRequestCenter hands requests over.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                shell.handleLeadRequest(request) { text, isError in answer.value = (text, isError) }
            }
        }
        waitUntil("the answer to \(tool)", timeout: timeout, file: file, line: line) { answer.value != nil }
        return try XCTUnwrap(answer.value, file: file, line: line)
    }

    func callLeadTool(
        _ tool: String, _ arguments: [String: Any] = [:], lead: Lead, timeout: TimeInterval = 30,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> (text: String, isError: Bool) {
        try callLeadTool(tool, arguments, from: lead.workspace, agentUUID: lead.agentUUID, timeout: timeout, file: file, line: line)
    }
}
