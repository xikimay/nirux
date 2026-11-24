import AppKit
import NiruxCore
import XCTest
@testable import Nirux

/// Mission messages a waiter hook takes in place of typing
/// (NiruxShellView+MissionHooks, docs/design/mission-delivery.md): a task's
/// question for its Lead, whose `claude` is a stand-in, in a real window on
/// throwaway state (see UIFlowHarness). Hook events go through the real drain.
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
        let transcript: URL

        var mailbox: MissionMailbox { MissionWaitHook.mailbox }

        /// When Nirux recorded the question as in the Lead's hands.
        var deliveredAt: TimeInterval? {
            MissionStore.shared.missions.first { $0.id == mission.id }?.events.first { $0.id == question.id }?.parentTypedAt
        }

        var typed: Bool { standIn.input.contains("Keep the old date= parameter?") }

        var claude: ForegroundProcess? { column.pty?.foregroundProcess(snapshot: ProcessSnapshot()) }

        /// A hook of the Lead's `claude`, through the app's drain.
        func hook(_ name: AgentHookEvent.Name) throws {
            let claude = try XCTUnwrap(claude)
            let event = AgentHookEvent(
                kind: .claude, name: name, agentUUID: column.agentUUID, sessionID: session, emitterProcess: claude.instance,
                source: name == .sessionStart ? "startup" : nil, timestamp: Date().timeIntervalSince1970
            )
            shell.applyAgentHookEvents([try XCTUnwrap(AgentHookCenter.shared.dispatch(event))])
        }

        /// The Lead's waiter claims what waits, as its claude runs the session.
        func claim() throws -> MissionMailbox.Letter {
            try mailbox.noteRunning(session, in: try XCTUnwrap(claude).instance.pid)
            try mailbox.noteTranscript(transcript.path, of: session)
            return try XCTUnwrap(mailbox.claim(session, at: Date().timeIntervalSince1970).first)
        }

        /// The model reads `letter`: its turn's line in the transcript.
        func read(_ letter: MissionMailbox.Letter) throws {
            let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .gmt, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
            let line: [String: Any] = ["type": "user", "timestamp": stamp, "content": MissionWaitHook.preamble + " " + letter.text]
            try (String(decoding: try JSONSerialization.data(withJSONObject: line, options: [.withoutEscapingSlashes]), as: UTF8.self) + "\n")
                .write(to: transcript, atomically: true, encoding: .utf8)
        }
    }

    /// A Lead whose `claude` sits at a free prompt, on a confirmed
    /// conversation, and a question from one of its tasks.
    private func makeParent(_ harness: UIFlowHarness, standIn: AgentStandIn) throws -> Parent {
        let shell = harness.shell
        AgentHookCenter.shared.resolver = { [weak shell] in shell?.resolveAgentColumn(uuid: $0) }
        addTeardownBlock { @MainActor in AgentHookCenter.shared.resolver = nil }
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
        guard case .accepted = MissionStore.shared.process(question, enabled: false) else { throw XCTSkip("the question wasn't recorded") }
        let parent = Parent(
            shell: shell, column: column, standIn: standIn, session: UUID().uuidString, mission: mission, question: question,
            transcript: URL(fileURLWithPath: harness.root + "/transcript-\(UUID().uuidString).jsonl")
        )
        try parent.hook(.sessionStart)
        try parent.hook(.userPromptSubmit)
        try parent.hook(.stop)
        XCTAssertEqual(shell.conversation(of: column, foreground: parent.claude), parent.session)
        return parent
    }

    /// Posted while a waiter waits on the Lead's conversation, never typed;
    /// in its hands once a turn's end finds it read in the transcript.
    func testAQuestionTheWaiterTookCountsOnceTheModelReadIt() throws {
        try UIFlowHarness.run { harness in
            let standIn = AgentStandIn()
            defer { standIn.remove() }
            let parent = try makeParent(harness, standIn: standIn)
            var waiter = try parent.mailbox.arm(parent.session)
            parent.shell.typeMissionMessages()
            XCTAssertEqual(parent.mailbox.places()[parent.question.id], .waiting(conversation: parent.session))
            XCTAssertFalse(parent.typed, "nothing typed into a free prompt")

            let letter = try parent.claim()
            XCTAssertTrue(letter.text.hasPrefix("[Nirux Mission] Question from"), letter.text)
            waiter = nil
            parent.shell.typeMissionMessages()
            try parent.hook(.stop)
            XCTAssertFalse(parent.typed, "the hook has it")
            XCTAssertNil(parent.deliveredAt, "a turn that didn't read it proves nothing")

            try parent.read(letter)
            try parent.hook(.stop)
            XCTAssertNotNil(parent.deliveredAt)
            XCTAssertTrue(parent.mailbox.claims().isEmpty)
            parent.shell.typeMissionMessages()
            XCTAssertFalse(parent.typed, "delivered once")
            XCTAssertNil(waiter)
        }
    }

    /// Esc ends the turn that read it with no Stop: the session's end
    /// records it rather than sending it again.
    func testASessionEndRecordsAClaimTheModelReadAndFreesOneItDidnt() throws {
        try UIFlowHarness.run { harness in
            let standIn = AgentStandIn()
            defer { standIn.remove() }
            let parent = try makeParent(harness, standIn: standIn)
            let waiter = try parent.mailbox.arm(parent.session)
            parent.shell.typeMissionMessages()
            let letter = try parent.claim()
            try parent.read(letter)
            try parent.hook(.sessionEnd)
            XCTAssertNotNil(parent.deliveredAt)
            XCTAssertTrue(parent.mailbox.claims().isEmpty)
            withExtendedLifetime(waiter) {}
        }
    }

    /// Ctrl-Z: the task's claude whose waiter took a tell is stopped, the
    /// shell in front; the tell isn't typed too once it is back.
    func testAStoppedClaudeKeepsTheTellItsWaiterTook() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            AgentHookCenter.shared.resolver = { [weak shell] in shell?.resolveAgentColumn(uuid: $0) }
            defer { AgentHookCenter.shared.resolver = nil }
            let lead = try harness.makeLead()
            let mission = try XCTUnwrap(MissionStore.shared.create(MissionCreationRequest(
                id: UUID().uuidString, parentWorkspaceID: lead.workspace.id, parentAgentUUID: UUID().uuidString,
                childWorkspaceID: UUID().uuidString, childAgentUUID: UUID().uuidString, childAgentKind: "claude",
                branch: "feat/export", reportsToLead: true
            ), enabled: true))
            shell.addWorkspace(
                title: "Export CSV", cwd: harness.repo, profileID: lead.space, workspaceID: mission.childWorkspaceID,
                missionID: mission.id, reportsToLead: true
            )
            let task = try XCTUnwrap(shell.workspaces.first { $0.id == mission.childWorkspaceID })
            let standIn = AgentStandIn()
            defer { standIn.remove() }
            task.addColumn(command: standIn.command(), agentUUID: mission.childAgentUUID, cwd: harness.repo)
            let column = try XCTUnwrap(task.columns.first { $0.agentUUID == mission.childAgentUUID })
            harness.waitUntil("its claude") { column.pty?.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
            let session = UUID().uuidString
            for name in [AgentHookEvent.Name.sessionStart, .userPromptSubmit, .stop] {
                let claude = try XCTUnwrap(column.pty?.foregroundProcess(snapshot: ProcessSnapshot()))
                shell.applyAgentHookEvents([try XCTUnwrap(AgentHookCenter.shared.dispatch(AgentHookEvent(
                    kind: .claude, name: name, agentUUID: mission.childAgentUUID, sessionID: session, emitterProcess: claude.instance,
                    source: name == .sessionStart ? "startup" : nil, timestamp: Date().timeIntervalSince1970
                )))])
            }
            let tell = MissionEvent(
                id: UUID().uuidString, missionID: mission.id, childWorkspaceID: mission.childWorkspaceID, childAgentUUID: mission.childAgentUUID,
                parentWorkspaceID: mission.parentWorkspaceID, parentAgentUUID: mission.parentAgentUUID,
                kind: .instruction, message: "Now the docs.", timestamp: Date().timeIntervalSince1970
            )
            guard case .accepted = MissionStore.shared.process(tell, enabled: true) else { return XCTFail("the tell wasn't recorded") }
            let mailbox = MissionWaitHook.mailbox
            let waiter = try mailbox.arm(session)
            shell.typeMissionMessages()
            XCTAssertEqual(mailbox.places()[tell.id], .waiting(conversation: session))
            // Stands for that claude: a process started before the claim, then stopped.
            let suspended = Process()
            suspended.executableURL = URL(fileURLWithPath: "/bin/sleep")
            suspended.arguments = ["60"]
            try suspended.run()
            defer {
                kill(suspended.processIdentifier, SIGCONT)
                suspended.terminate()
            }
            try mailbox.noteRunning(session, in: suspended.processIdentifier)
            XCTAssertEqual(mailbox.claim(session, at: Date().timeIntervalSince1970).count, 1)
            kill(suspended.processIdentifier, SIGSTOP)
            kill(try XCTUnwrap(column.pty?.foregroundProcess(snapshot: ProcessSnapshot())).instance.pid, SIGTERM)
            harness.waitUntil("the shell in front") { column.pty?.foregroundProcess(snapshot: ProcessSnapshot())?.agent != .claude }
            shell.typeMissionMessages()
            guard case .claimed? = mailbox.places()[tell.id] else {
                return XCTFail("the claim went: \(String(describing: mailbox.places()[tell.id]))")
            }
            withExtendedLifetime(waiter) {}
        }
    }

    /// A waiter that leaves before it claims hands the question back to
    /// typing, and the letter Nirux took back goes once typed.
    func testWhatNoWaiterTookIsTypedAndLeavesNothingOwed() throws {
        try UIFlowHarness.run { harness in
            let standIn = AgentStandIn()
            defer { standIn.remove() }
            let parent = try makeParent(harness, standIn: standIn)
            var waiter = try parent.mailbox.arm(parent.session)
            parent.shell.typeMissionMessages()
            XCTAssertEqual(parent.mailbox.places()[parent.question.id], .waiting(conversation: parent.session))
            waiter = nil
            XCTAssertNil(waiter)
            parent.shell.typeMissionMessages()
            harness.waitUntil("the question typed into its prompt") { parent.typed }
            XCTAssertNotNil(parent.deliveredAt)
            XCTAssertNil(parent.mailbox.places()[parent.question.id])
        }
    }

    /// At launch, a claim whose claude went with the last run, unread, goes
    /// again; the Lead's resumed waiter or typing carries it.
    func testAtLaunchAClaimNoModelReadGoesAgain() throws {
        try UIFlowHarness.run { harness in
            let standIn = AgentStandIn()
            defer { standIn.remove() }
            let parent = try makeParent(harness, standIn: standIn)
            let waiter = try parent.mailbox.arm(parent.session)
            parent.shell.typeMissionMessages()
            try parent.mailbox.noteTranscript(parent.transcript.path, of: parent.session)
            XCTAssertEqual(parent.mailbox.claim(parent.session, at: Date().timeIntervalSince1970).count, 1, "no claude noted: it's gone")
            parent.shell.restoreState()
            XCTAssertTrue(parent.mailbox.claims().isEmpty)
            XCTAssertNil(parent.deliveredAt)
            withExtendedLifetime(waiter) {}
        }
    }
}
