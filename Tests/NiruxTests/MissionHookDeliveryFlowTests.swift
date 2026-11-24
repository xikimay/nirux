import AppKit
import NiruxCore
import XCTest
@testable import Nirux

/// Mission messages a waiter hook takes in place of typing
/// (NiruxShellView+MissionHooks, docs/design/mission-delivery.md): a task's
/// question for its Lead, whose `claude` is a stand-in, in a real window on
/// throwaway state (see UIFlowHarness).
@MainActor
final class MissionHookDeliveryFlowTests: XCTestCase {
    @MainActor
    private struct Parent {
        let shell: NiruxShellView
        let column: ColumnState
        let standIn: AgentStandIn
        let session: String
        let mission: Mission
        let question: MissionEvent

        /// When Nirux recorded the question as in the Lead's hands.
        var deliveredAt: TimeInterval? {
            MissionStore.shared.missions.first { $0.id == mission.id }?.events.first { $0.id == question.id }?.parentTypedAt
        }

        var typed: Bool { standIn.input.contains("Keep the old date= parameter?") }

        /// A hook of the Lead's `claude`, as the column takes it in.
        @discardableResult
        func hook(_ name: AgentHookEvent.Name, at time: TimeInterval = Date().timeIntervalSince1970) throws -> AgentHookEvent {
            let pty = try XCTUnwrap(column.pty)
            let snapshot = ProcessSnapshot()
            let claude = try XCTUnwrap(pty.foregroundProcess(snapshot: snapshot))
            let event = AgentHookEvent(
                kind: .claude, name: name, agentUUID: column.agentUUID, sessionID: session, emitterProcess: claude.instance,
                source: name == .sessionStart ? "startup" : nil, timestamp: time
            )
            _ = column.admitClaudeHook(event, foregroundProcess: claude, snapshot: snapshot)
            _ = pty.applyAgentHook(event, isUserFocused: false)
            return event
        }
    }

    /// A Lead whose `claude` sits at a free prompt, on a confirmed
    /// conversation, and a question from one of its tasks.
    private func makeParent(_ harness: UIFlowHarness, standIn: AgentStandIn) throws -> Parent {
        let shell = harness.shell
        let lead = try harness.makeLead()
        let agentUUID = UUID().uuidString
        lead.workspace.addColumn(command: standIn.command(), agentUUID: agentUUID, cwd: harness.repo)
        let column = try XCTUnwrap(lead.workspace.columns.first { $0.agentUUID == agentUUID })
        harness.waitUntil("its claude") { column.pty?.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
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
        let question = MissionEvent(
            id: UUID().uuidString, missionID: mission.id,
            childWorkspaceID: mission.childWorkspaceID, childAgentUUID: mission.childAgentUUID,
            kind: .question, message: "Keep the old date= parameter?", timestamp: Date().timeIntervalSince1970
        )
        guard case .accepted = MissionStore.shared.process(question, enabled: false) else {
            throw XCTSkip("the question wasn't recorded")
        }
        let parent = Parent(
            shell: shell, column: column, standIn: standIn, session: UUID().uuidString, mission: mission, question: question
        )
        try parent.hook(.sessionStart)
        try parent.hook(.userPromptSubmit)
        try parent.hook(.stop)
        XCTAssertEqual(shell.conversation(of: column, foreground: column.pty?.foregroundProcess(snapshot: ProcessSnapshot())), parent.session)
        return parent
    }

    /// Posted while a waiter waits on the Lead's conversation, never typed;
    /// in its hands once a turn of that conversation ends after the claim.
    func testAQuestionGoesToTheWaiterAndCountsOnceTheTurnThatTookItEnds() throws {
        try UIFlowHarness.run { harness in
            let standIn = AgentStandIn()
            defer { standIn.remove() }
            let parent = try makeParent(harness, standIn: standIn)
            let mailbox = MissionWaitHook.mailbox
            var waiter = try mailbox.arm(parent.session)
            parent.shell.typeMissionMessages()
            XCTAssertEqual(mailbox.places()[parent.question.id], .waiting(conversation: parent.session))
            XCTAssertFalse(parent.typed, "nothing typed into a free prompt")
            XCTAssertNil(parent.deliveredAt)

            let taken = mailbox.claim(parent.session, at: Date().timeIntervalSince1970)
            XCTAssertTrue(taken.first?.text.hasPrefix("[Nirux Mission] Question from") == true, taken.first?.text ?? "nothing")
            waiter = nil
            parent.shell.typeMissionMessages()
            XCTAssertFalse(parent.typed, "the hook has it")
            XCTAssertNil(parent.deliveredAt, "not before its turn ends")

            // A claude started since then never got it: its turn proves nothing.
            let resumed = ProcessInstance(pid: 1, startedAt: Date().timeIntervalSince1970 + 60)
            parent.shell.settleHookClaims(after: [AgentHookEvent(
                kind: .claude, name: .stop, agentUUID: parent.column.agentUUID, sessionID: parent.session, emitterProcess: resumed,
                timestamp: Date().timeIntervalSince1970 + 61
            )])
            XCTAssertNil(parent.deliveredAt)

            parent.shell.settleHookClaims(after: [try parent.hook(.stop)])
            XCTAssertNil(parent.deliveredAt, "that Stop ends the turn that was finishing as the waiter took it")

            parent.shell.settleHookClaims(after: [try parent.hook(.stop, at: Date().timeIntervalSince1970 + MissionWaitHook.turnAfterClaim + 1)])
            XCTAssertNotNil(parent.deliveredAt)
            XCTAssertTrue(mailbox.claims().isEmpty)
            parent.shell.typeMissionMessages()
            XCTAssertFalse(parent.typed, "delivered once")
            XCTAssertNil(waiter)
        }
    }

    /// A waiter that leaves before it claims hands the question back to
    /// typing; a claim whose session ends before a turn does goes again.
    func testWhatNoWaiterTookGoesBackToTyping() throws {
        try UIFlowHarness.run { harness in
            let standIn = AgentStandIn()
            defer { standIn.remove() }
            let parent = try makeParent(harness, standIn: standIn)
            let mailbox = MissionWaitHook.mailbox
            var waiter = try mailbox.arm(parent.session)
            parent.shell.typeMissionMessages()
            XCTAssertEqual(mailbox.places()[parent.question.id], .waiting(conversation: parent.session))
            _ = mailbox.claim(parent.session, at: Date().timeIntervalSince1970)
            parent.shell.settleHookClaims(after: [try parent.hook(.sessionEnd)])
            XCTAssertNil(mailbox.places()[parent.question.id], "its session ended first: it goes again")
            XCTAssertNil(parent.deliveredAt)

            // Resumed, and back at its prompt.
            try parent.hook(.sessionStart)
            try parent.hook(.userPromptSubmit)
            try parent.hook(.stop)
            parent.shell.typeMissionMessages()
            XCTAssertEqual(mailbox.places()[parent.question.id], .waiting(conversation: parent.session))
            waiter = nil
            XCTAssertNil(waiter)
            parent.shell.typeMissionMessages()
            XCTAssertNil(mailbox.places()[parent.question.id], "taken back from a conversation no waiter waits on")
            harness.waitUntil("the question typed into its prompt") { parent.typed }
            XCTAssertNotNil(parent.deliveredAt)
        }
    }
}
