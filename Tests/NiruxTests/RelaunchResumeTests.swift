import XCTest
@testable import Nirux

/// Which restored agents a relaunch starts on its own (`RelaunchResume`).
final class RelaunchResumeTests: XCTestCase {
    /// The Lead, an agent last seen working, one a Mission message waits
    /// for (the child for a `tell` or an answer, the parent for a question
    /// or a result); not an idle or waiting one with nothing for it.
    func testTheLeadWorkAndMessagesResume() {
        let mission = Mission(
            id: "m", parentWorkspaceID: "pw", parentAgentUUID: "lead", childWorkspaceID: "cw", childAgentUUID: "task",
            childAgentKind: "claude", branch: "feat/task", status: .active, createdAt: 0, updatedAt: 0, events: []
        )
        func pending(_ kind: MissionEvent.Kind, child: String = "task") -> MissionStore.AcceptedEvent {
            MissionStore.AcceptedEvent(mission: mission, event: MissionEvent(
                id: UUID().uuidString, missionID: "m", childWorkspaceID: "cw", childAgentUUID: child, kind: kind, message: "x", timestamp: 1
            ))
        }
        XCTAssertEqual(RelaunchResume.waitingAgents([pending(.instruction)]), ["task"])
        XCTAssertEqual(RelaunchResume.waitingAgents([pending(.response, child: "other")]), ["other"])
        XCTAssertEqual(RelaunchResume.waitingAgents([pending(.question), pending(.completed)]), ["lead"])

        func resumes(_ status: PersistedAgentStatus?, agent: String = "idle", lead: Bool = false, waiting: Set<String> = []) -> Bool {
            RelaunchResume.resumes(.init(agentUUID: agent, lastStatus: status, isLead: lead), messageWaitsFor: waiting)
        }
        XCTAssertTrue(resumes(.idle, lead: true))
        XCTAssertTrue(resumes(.working))
        XCTAssertTrue(resumes(.idle, waiting: ["idle"]))
        XCTAssertFalse(resumes(.idle))
        XCTAssertFalse(resumes(.needsAttention))
        XCTAssertFalse(resumes(nil, waiting: ["other"]))
        XCTAssertFalse(resumes(.needsAttention, waiting: ["idle"]), "waiting on the user, a message for it waits too")

        // Told to go on: only one last seen mid-turn.
        XCTAssertTrue(RelaunchResume.continues(.init(agentUUID: "a", lastStatus: .working, isLead: true)))
        XCTAssertFalse(RelaunchResume.continues(.init(agentUUID: "a", lastStatus: .idle, isLead: true)))
        XCTAssertFalse(RelaunchResume.continues(.init(agentUUID: "a", lastStatus: .needsAttention, isLead: false)))
    }
}
