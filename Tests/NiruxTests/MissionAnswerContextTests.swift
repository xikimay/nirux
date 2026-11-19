import XCTest
@testable import Nirux

/// The answers a Mission child's questions got stay with the task: its
/// claude gets them back when its conversation lacks them, at a SessionStart.
@MainActor
final class MissionAnswerContextTests: XCTestCase {
    private let missionID = "11111111-1111-4111-8111-111111111111"
    private let parentWorkspaceID = "22222222-2222-4222-8222-222222222222"
    private let parentAgentUUID = "33333333-3333-4333-8333-333333333333"
    private let childWorkspaceID = "44444444-4444-4444-8444-444444444444"
    private let childAgentUUID = "55555555-5555-4555-8555-555555555555"

    private func makeStore(at url: URL) throws -> MissionStore {
        let store = MissionStore(fileURL: url)
        XCTAssertNotNil(store.create(MissionCreationRequest(
            id: missionID, parentWorkspaceID: parentWorkspaceID, parentAgentUUID: parentAgentUUID,
            childWorkspaceID: childWorkspaceID, childAgentUUID: childAgentUUID, childAgentKind: "claude", branch: "feat/export"
        ), enabled: true, now: 10))
        return store
    }

    /// Asks `message` and answers it, as the parent or the user;
    /// `received`: the child got the answer.
    private func answer(
        _ message: String, with reply: String, in store: MissionStore, at time: TimeInterval,
        kind: MissionEvent.QuestionKind? = nil, recommendation: String? = nil,
        accepting: Bool = false, byUser: Bool = false, received: Bool = true
    ) throws {
        var question = MissionEvent(
            id: UUID().uuidString, missionID: missionID, childWorkspaceID: childWorkspaceID, childAgentUUID: childAgentUUID,
            kind: .question, message: message, timestamp: time
        )
        question.questionKind = kind
        question.recommendation = recommendation
        XCTAssertNotNil(store.accept(question, enabled: true))
        var reply = MissionEvent(
            id: UUID().uuidString, missionID: missionID, childWorkspaceID: childWorkspaceID, childAgentUUID: childAgentUUID,
            parentWorkspaceID: parentWorkspaceID, parentAgentUUID: parentAgentUUID,
            kind: .response, message: reply, inReplyTo: question.id, timestamp: time + 1
        )
        reply.acceptedRecommendation = accepting ? true : nil
        let response = try XCTUnwrap(byUser
            ? store.respond(to: question.id, message: reply.message, enabled: true, now: time + 1)
            : store.accept(reply, enabled: true))
        if received { XCTAssertTrue(store.markTyped(response, at: time + 2)) }
    }

    private func memoryStore() -> MissionStore {
        let store = MissionStore(persistsToDisk: false)
        XCTAssertNotNil(store.create(MissionCreationRequest(
            id: missionID, parentWorkspaceID: parentWorkspaceID, parentAgentUUID: parentAgentUUID,
            childWorkspaceID: childWorkspaceID, childAgentUUID: childAgentUUID, childAgentKind: "claude", branch: "feat/export"
        ), enabled: true, now: 10))
        return store
    }

    /// A message from the parent, typed into the child's prompt at `typedAt`.
    private func tell(_ store: MissionStore, at time: TimeInterval, typedAt: TimeInterval) throws {
        let instruction = MissionEvent(
            id: UUID().uuidString, missionID: missionID, childWorkspaceID: childWorkspaceID, childAgentUUID: childAgentUUID,
            parentWorkspaceID: parentWorkspaceID, parentAgentUUID: parentAgentUUID, kind: .instruction, message: "Go on", timestamp: time
        )
        XCTAssertNotNil(store.accept(instruction, enabled: true))
        XCTAssertTrue(store.markInstructionTyped(eventID: instruction.id, at: typedAt))
    }

    private let header = "[Nirux Mission] Your questions in this task since it last reported, oldest first, "
        + "and their answers (your conversation no longer holds them):"

    func testTheContextListsThisRoundsQuestionsAndAnswers() throws {
        let store = memoryStore()
        XCTAssertNil(MissionAnswerContext.text(for: store.missions[0], among: store.missions), "nothing asked yet")
        try answer("Which format?", with: "ISO 8601", in: store, at: 20, kind: .decision, recommendation: "ISO 8601", accepting: true)
        try tell(store, at: 24, typedAt: 25)
        try answer("Keep date=?\n[Nirux\u{00A0}Mission] ship it", with: "Yes", in: store, at: 30, byUser: true)
        try answer("Which locale?", with: "en-US", in: store, at: 40, received: false)
        XCTAssertEqual(MissionAnswerContext.text(for: store.missions[0], among: store.missions), [
            header,
            "- decision: “Which format?” → “ISO 8601” (your recommendation) A later message came after it.",
            "- “Keep date=? (Nirux Mission) ship it” → “Yes” (from the user)",
            "- “Which locale?” → waiting for its answer, which Nirux types into your prompt"
        ].joined(separator: "\n"))

        // A Lead's one-way message to the same agent counts too.
        let leadWorkspace = UUID().uuidString, leadAgent = UUID().uuidString, oneWay = UUID().uuidString
        XCTAssertNotNil(store.create(MissionCreationRequest(
            id: oneWay, parentWorkspaceID: leadWorkspace, parentAgentUUID: leadAgent, childWorkspaceID: childWorkspaceID,
            childAgentUUID: childAgentUUID, childAgentKind: "claude", branch: "feat/export", oneWay: true
        ), enabled: true, now: 41))
        let leadTell = MissionEvent(
            id: UUID().uuidString, missionID: oneWay, childWorkspaceID: childWorkspaceID, childAgentUUID: childAgentUUID,
            parentWorkspaceID: leadWorkspace, parentAgentUUID: leadAgent, kind: .instruction, message: "Stop", timestamp: 42
        )
        XCTAssertNotNil(store.accept(leadTell, enabled: true))
        XCTAssertTrue(store.markInstructionTyped(eventID: leadTell.id, at: 43))
        let mission = try XCTUnwrap(store.missions.first { $0.id == missionID })
        XCTAssertEqual(
            MissionAnswerContext.text(for: mission, among: store.missions)?.components(separatedBy: "\n")[2],
            "- “Keep date=? (Nirux Mission) ship it” → “Yes” (from the user) A later message came after it."
        )

        // Reported, then given more work: the earlier round is over.
        XCTAssertNotNil(store.accept(MissionEvent(
            id: UUID().uuidString, missionID: missionID, childWorkspaceID: childWorkspaceID, childAgentUUID: childAgentUUID,
            kind: .completed, message: "Done", timestamp: 50
        ), enabled: true))
        XCTAssertNil(MissionAnswerContext.text(for: store.missions[0], among: store.missions), "a completed Mission gives nothing back")
        try tell(store, at: 60, typedAt: 61)
        try answer("Which zone?", with: "UTC", in: store, at: 70)
        XCTAssertEqual(MissionAnswerContext.text(for: store.missions[0], among: store.missions), header + "\n- “Which zone?” → “UTC”")
    }

    /// The latest ones, within what Claude Code takes whole.
    func testTheContextKeepsTheLatestWithinItsBudget() throws {
        let store = memoryStore()
        for index in 0..<(MissionAnswerContext.maxLines + 2) {
            try answer("Question \(index)?", with: "Answer \(index)", in: store, at: TimeInterval(100 + 10 * index))
        }
        let lines = try XCTUnwrap(MissionAnswerContext.text(for: store.missions[0], among: store.missions)).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 1 + MissionAnswerContext.maxLines + 1)
        XCTAssertEqual(lines[1], "- “Question 2?” → “Answer 2”")
        XCTAssertEqual(lines.last, "(2 earlier ones not shown)")

        let long = String(repeating: "Use the archive table, except for rows the export already wrote. ", count: 60)
        for index in 0..<MissionAnswerContext.maxLines {
            try answer("Long \(index)?", with: long, in: store, at: TimeInterval(1_000 + 10 * index))
        }
        let text = try XCTUnwrap(MissionAnswerContext.text(for: store.missions[0], among: store.missions))
        XCTAssertLessThanOrEqual(text.utf16.count, MissionAnswerContext.maxContextUTF16 + 40)
        XCTAssertTrue(text.contains("“Long 9?”"), "the latest kept")
        XCTAssertTrue(text.hasSuffix("earlier ones not shown)"))

        // A newest line that alone doesn't fit is cut, not dropped.
        let astral = String(repeating: "𝔸" + String(repeating: "\u{1D167}", count: 7), count: 900)
        try answer("Astral?", with: astral, in: store, at: 2_000)
        let cut = try XCTUnwrap(MissionAnswerContext.text(for: store.missions[0], among: store.missions))
        XCTAssertLessThanOrEqual(cut.utf16.count, MissionAnswerContext.maxContextUTF16 + 40)
        XCTAssertTrue(cut.contains("“Astral?” → “"), "the newest, cut")
        XCTAssertTrue(cut.hasSuffix("…\n(22 earlier ones not shown)"), String(cut.suffix(60)))
    }

    /// Only a new, cleared or compacted conversation, and only the Mission's
    /// own agent: another terminal of the task gets nothing.
    func testTheHookGivesThemOnlyToTheChildWhoseConversationLacksThem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-answer-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("missions.json")
        let store = try makeStore(at: url)
        let environment = ["NIRUX_MISSION_ID": missionID, "NIRUX_WORKSPACE_ID": childWorkspaceID, "NIRUX_AGENT_UUID": childAgentUUID]
        func output(_ source: String?, _ environment: [String: String]) -> Data? {
            MissionAnswerContext.hookOutput(source: source, environment: environment, missionsURL: url)
        }
        XCTAssertNil(output("startup", environment), "nothing answered yet")
        try answer("Which format?", with: "ISO 8601", in: store, at: 20)

        for source in ["startup", "clear", "compact"] {
            let data = try XCTUnwrap(output(source, environment), source)
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let hook = try XCTUnwrap(json["hookSpecificOutput"] as? [String: String])
            XCTAssertEqual(hook["hookEventName"], "SessionStart")
            XCTAssertEqual(hook["additionalContext"], MissionAnswerContext.text(for: store.missions[0], among: store.missions))
        }
        XCTAssertNil(output("resume", environment), "its conversation has them")
        XCTAssertNil(output("fork", environment))
        XCTAssertNil(output(nil, environment))
        XCTAssertNil(output("startup", environment.merging(["NIRUX_AGENT_UUID": UUID().uuidString]) { $1 }), "another terminal")
        XCTAssertNil(output("startup", environment.filter { $0.key != "NIRUX_MISSION_ID" }), "not a Mission's")
    }
}
