import XCTest
@testable import Nirux

/// Promote to Lead's rules: only a Claude conversation at rest moves, and
/// the Missions it carried as a task end without typing anything more.
@MainActor
final class LeadPromotionTests: XCTestCase {
    private let parentWorkspaceID = "22222222-2222-4222-8222-222222222222"
    private let parentAgentUUID = "33333333-3333-4333-8333-333333333333"
    private let childWorkspaceID = "44444444-4444-4444-8444-444444444444"
    private let childAgentUUID = "55555555-5555-4555-8555-555555555555"

    private let atRest = LeadPromotion.Worker(agent: .claude, sessionID: "s", isAtRest: true)

    func testOnlyAClaudeConversationAtRestMoves() {
        XCTAssertNil(LeadPromotion.refusal(atRest))
        var cases: [(LeadPromotion.Worker?, String)] = [(nil, "agent terminal")]
        XCTAssertTrue(LeadPromotion.refusal(atRest, isSubtask: true)?.contains("Promote its task") == true)
        func with(_ change: (inout LeadPromotion.Worker) -> Void) -> LeadPromotion.Worker {
            var worker = atRest
            change(&worker)
            return worker
        }
        cases += [
            (with { $0.isStarting = true }, "starting"),
            (with { $0.otherProgram = "vim" }, "vim runs"),
            (with { $0.agent = nil }, "No agent"),
            (with { $0.agent = .codex }, "Only a Claude task"),
            (with { $0.agent = .agy }, "Only a Claude task"),
            (with { $0.sessionID = nil }, "first turn"),
            (with { $0.isAtRest = false }, "working"),
            (with { $0.hasDialog = true }, "dialog"),
            (with { $0.hasDraft = true }, "draft")
        ]
        for (worker, expected) in cases {
            let refusal = LeadPromotion.refusal(worker)
            XCTAssertTrue(refusal?.contains(expected) == true, "\(String(describing: worker)): \(String(describing: refusal))")
        }
    }

    /// Its question, its result (which ended its Mission) and the Lead's
    /// tell, all still waiting:
    /// none is typed any more, and another task's Mission is left alone.
    func testEndingAWorkersMissionsTypesNothingMore() throws {
        let store = MissionStore(fileURL: URL(fileURLWithPath: "/dev/null"), persistsToDisk: false)
        func mission(child: String) throws -> Mission {
            try XCTUnwrap(store.create(MissionCreationRequest(
                id: UUID().uuidString, parentWorkspaceID: parentWorkspaceID, parentAgentUUID: parentAgentUUID,
                childWorkspaceID: child, childAgentUUID: childAgentUUID, childAgentKind: "claude",
                branch: "feat/coordinator", reportsToLead: true
            ), enabled: false, now: 10))
        }
        let own = try mission(child: childWorkspaceID)
        let reported = try mission(child: childWorkspaceID)
        let other = try mission(child: "66666666-6666-4666-8666-666666666666")
        let now = Date().timeIntervalSince1970
        for (target, kind) in [(own, MissionEvent.Kind.question), (reported, .completed), (other, .question)] {
            guard case .accepted = store.process(MissionEvent(
                id: UUID().uuidString, missionID: target.id, childWorkspaceID: target.childWorkspaceID,
                childAgentUUID: childAgentUUID, kind: kind, message: "From the task", timestamp: now - 2
            ), enabled: false) else { return XCTFail("the task's \(kind) was refused") }
        }
        guard case .accepted = store.process(MissionEvent(
            id: UUID().uuidString, missionID: own.id, childWorkspaceID: childWorkspaceID, childAgentUUID: childAgentUUID,
            parentWorkspaceID: parentWorkspaceID, parentAgentUUID: parentAgentUUID, kind: .instruction,
            message: "From the Lead", timestamp: now - 1
        ), enabled: false) else { return XCTFail("the Lead's tell was refused") }
        XCTAssertEqual(store.pendingPromptDeliveries(now: now).count, 4)

        XCTAssertTrue(store.endChildMissions(workspaceID: childWorkspaceID, agentUUID: childAgentUUID, at: now))
        XCTAssertEqual(store.missions.first { $0.id == own.id }?.status, .completed)
        XCTAssertEqual(store.pendingPromptDeliveries(now: now).map(\.mission.id), [other.id])
        XCTAssertEqual(store.missions.first { $0.id == other.id }?.status, .active)
    }

    /// The Missions a promoted task parented report to the Lead now, as
    /// its own tasks; another parent's are left alone.
    func testItsMissionsAsAParentMoveToTheLead() throws {
        let store = MissionStore(fileURL: URL(fileURLWithPath: "/dev/null"), persistsToDisk: false)
        let leadID = "77777777-7777-4777-8777-777777777777", leadAgent = "88888888-8888-4888-8888-888888888888"
        func mission(parent: String) throws -> Mission {
            try XCTUnwrap(store.create(MissionCreationRequest(
                id: UUID().uuidString, parentWorkspaceID: parent, parentAgentUUID: parentAgentUUID,
                childWorkspaceID: UUID().uuidString, childAgentUUID: UUID().uuidString, childAgentKind: "claude",
                branch: "feat/part", reportsToTask: true
            ), enabled: false, now: 10))
        }
        let own = try mission(parent: parentWorkspaceID)
        let other = try mission(parent: childWorkspaceID)
        XCTAssertTrue(store.reparentMissions(
            fromWorkspace: parentWorkspaceID, agentUUID: parentAgentUUID, toLead: leadID, leadAgentUUID: leadAgent, at: 20
        ))
        let moved = try XCTUnwrap(store.missions.first { $0.id == own.id })
        XCTAssertEqual([moved.parentWorkspaceID, moved.parentAgentUUID], [leadID, leadAgent])
        XCTAssertEqual(moved.reportsToLead, true)
        XCTAssertNil(moved.reportsToTask)
        XCTAssertEqual(store.missions.first { $0.id == other.id }?.parentWorkspaceID, childWorkspaceID)
    }
}
