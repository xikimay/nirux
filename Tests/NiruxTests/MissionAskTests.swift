import XCTest
@testable import Nirux

/// Agent-facing Mission commands: bounded waits, idempotent `ask` retries,
/// the child's receipt, and the exit statuses the instructions promise.
@MainActor
final class MissionAskTests: XCTestCase {
    private let missionID = "11111111-1111-4111-8111-111111111111"
    private let parentWorkspaceID = "22222222-2222-4222-8222-222222222222"
    private let parentAgentUUID = "33333333-3333-4333-8333-333333333333"
    private let childWorkspaceID = "44444444-4444-4444-8444-444444444444"
    private let childAgentUUID = "55555555-5555-4555-8555-555555555555"
    private let otherAgentUUID = "88888888-8888-4888-8888-888888888888"

    private struct Fixture {
        let missionsURL: URL
        let eventsURL: URL
        let store: MissionStore
        let center: MissionEventCenter
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-mission-ask-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let missionsURL = directory.appendingPathComponent("missions.json")
        let eventsURL = directory.appendingPathComponent("mission-events.jsonl")
        let store = MissionStore(fileURL: missionsURL)
        XCTAssertNotNil(store.create(MissionCreationRequest(
            id: missionID,
            parentWorkspaceID: parentWorkspaceID,
            parentAgentUUID: parentAgentUUID,
            childWorkspaceID: childWorkspaceID,
            childAgentUUID: childAgentUUID,
            childAgentKind: "claude",
            branch: "feat/mission"
        ), enabled: true, now: 10))
        let center = MissionEventCenter(store: store, eventsURL: eventsURL, isEnabled: { true })
        return Fixture(missionsURL: missionsURL, eventsURL: eventsURL, store: store, center: center)
    }

    private func childEnvironment(agentUUID: String? = nil) -> [String: String] {
        [
            "NIRUX_MISSION_HANDOFFS": "1",
            "NIRUX_MISSION_ID": missionID,
            "NIRUX_WORKSPACE_ID": childWorkspaceID,
            "NIRUX_AGENT_UUID": agentUUID ?? childAgentUUID
        ]
    }

    private var parentEnvironment: [String: String] {
        [
            "NIRUX_MISSION_HANDOFFS": "1",
            "NIRUX_WORKSPACE_ID": parentWorkspaceID,
            "NIRUX_AGENT_UUID": parentAgentUUID
        ]
    }

    private func ask(
        _ message: String,
        in fixture: Fixture,
        at time: TimeInterval = 20,
        agentUUID: String? = nil,
        output: (String) -> Void = { _ in }
    ) -> Int32 {
        MissionEventCLI.ask(
            arguments: ["--message", message, "--timeout", "0"],
            environment: childEnvironment(agentUUID: agentUUID),
            now: { time },
            eventsURL: fixture.eventsURL,
            missionsURL: fixture.missionsURL,
            pollInterval: 0.01,
            output: output
        )
    }

    private func queuedEvents(in fixture: Fixture) throws -> [MissionEvent] {
        guard FileManager.default.fileExists(atPath: fixture.eventsURL.path) else { return [] }
        return try Data(contentsOf: fixture.eventsURL).split(separator: 0x0A).map {
            try JSONDecoder().decode(MissionEvent.self, from: Data($0))
        }
    }

    private func questions(in fixture: Fixture) -> [MissionEvent] {
        fixture.store.missions[0].events.filter { $0.kind == .question }
    }

    private func complete(_ fixture: Fixture) {
        XCTAssertNotNil(fixture.store.accept(MissionEvent(
            id: "66666666-6666-4666-8666-666666666666",
            missionID: missionID,
            childWorkspaceID: childWorkspaceID,
            childAgentUUID: childAgentUUID,
            kind: .completed,
            message: "Done",
            timestamp: 15
        ), enabled: true))
    }

    func testRetriedAskResumesTheSameQuestion() throws {
        let fixture = try makeFixture()

        XCTAssertEqual(ask("Which API?", in: fixture), 3, "nothing answered yet")
        XCTAssertEqual(ask(" Which API? ", in: fixture), 3, "retry before Nirux drained the queue")
        let queued = try queuedEvents(in: fixture)
        XCTAssertEqual(queued.count, 2)
        XCTAssertEqual(Set(queued.map(\.id)).count, 1, "both attempts carry the same question ID")
        XCTAssertNotNil(UUID(uuidString: queued[0].id))

        fixture.center.drain()
        XCTAssertEqual(questions(in: fixture).map(\.id), [queued[0].id])

        XCTAssertEqual(ask("Which API?", in: fixture), 3, "retry after the question was recorded")
        XCTAssertTrue(try queuedEvents(in: fixture).isEmpty, "a recorded question is not queued again")

        XCTAssertEqual(ask("Which schema?", in: fixture), 3)
        fixture.center.drain()
        XCTAssertEqual(questions(in: fixture).count, 2, "a different question gets its own ID")
    }

    func testRetryPrintsTheAnswerAndOnlyLaterStartsANewQuestion() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(ask("Which API?", in: fixture), 3)
        fixture.center.drain()
        let question = try XCTUnwrap(questions(in: fixture).first)
        let response = try XCTUnwrap(fixture.store.respond(
            to: question.id, message: "Use AuthService.", enabled: true, now: 30
        ))

        var printed: [String] = []
        XCTAssertEqual(ask("Which API?", in: fixture, at: 40) { printed.append($0) }, 0)
        XCTAssertEqual(printed, ["Use AuthService."])
        let queued = try queuedEvents(in: fixture)
        XCTAssertEqual(queued.count, 1, "no duplicate question")
        XCTAssertEqual(queued.first?.kind, .acknowledged)
        XCTAssertEqual(queued.first?.inReplyTo, response.event.id)
        XCTAssertNil(queued.first?.parentWorkspaceID)

        fixture.center.drain()
        XCTAssertEqual(fixture.store.response(to: question.id)?.childConsumedAt, 40)
        XCTAssertEqual(fixture.store.missions[0].events.count, 2, "receipts are not retained")

        // A rerun right after the answer (its output was lost to a shell-tool
        // timeout, say) prints the same answer again.
        let replayAt = 40 + MissionEventCLI.answerReplayWindow - 1
        XCTAssertEqual(ask("Which API?", in: fixture, at: replayAt) { printed.append($0) }, 0)
        XCTAssertEqual(printed, ["Use AuthService.", "Use AuthService."])
        fixture.center.drain()
        XCTAssertEqual(questions(in: fixture).count, 1)
        XCTAssertEqual(fixture.store.response(to: question.id)?.childConsumedAt, 40)

        // Later, the same text is a new question.
        XCTAssertEqual(ask("Which API?", in: fixture, at: replayAt + 2), 3)
        let next = try XCTUnwrap(try queuedEvents(in: fixture).first)
        XCTAssertEqual(next.kind, .question)
        XCTAssertNotEqual(next.id, question.id)
        fixture.center.drain()
        XCTAssertEqual(questions(in: fixture).count, 2)
        XCTAssertEqual(ask("Which API?", in: fixture, at: replayAt + 3), 3, "and its retries resume it")
        XCTAssertEqual(try queuedEvents(in: fixture).count, 0)
    }

    func testAskWaitsForAnAnswerSavedWhileItPolls() async throws {
        let fixture = try makeFixture()
        let environment = childEnvironment()
        let eventsURL = fixture.eventsURL
        let missionsURL = fixture.missionsURL
        let waiting = Task.detached { () -> (Int32, [String]) in
            var printed: [String] = []
            let status = MissionEventCLI.ask(
                arguments: ["--message", "Which API?", "--timeout", "10"],
                environment: environment,
                eventsURL: eventsURL,
                missionsURL: missionsURL,
                pollInterval: 0.01,
                output: { printed.append($0) }
            )
            return (status, printed)
        }

        let question = try await drainUntilQuestionIsRecorded(fixture)
        XCTAssertNotNil(fixture.store.respond(
            to: question.id, message: "Use AuthService.", enabled: true, now: 30
        ))

        let (status, printed) = await waiting.value
        XCTAssertEqual(status, 0)
        XCTAssertEqual(printed, ["Use AuthService."])
    }

    func testAskStopsWhenTheMissionCompletesWhileItWaits() async throws {
        let fixture = try makeFixture()
        let environment = childEnvironment()
        let eventsURL = fixture.eventsURL
        let missionsURL = fixture.missionsURL
        let waiting = Task.detached {
            MissionEventCLI.ask(
                arguments: ["--message", "Which API?", "--timeout", "10"],
                environment: environment,
                eventsURL: eventsURL,
                missionsURL: missionsURL,
                pollInterval: 0.01
            )
        }

        _ = try await drainUntilQuestionIsRecorded(fixture)
        complete(fixture)

        let status = await waiting.value
        XCTAssertEqual(status, 4)
    }

    /// The CLI creates the queue file before writing its line, so drain
    /// until the question is in the ledger rather than when the file exists.
    private func drainUntilQuestionIsRecorded(_ fixture: Fixture) async throws -> MissionEvent {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            fixture.center.drain()
            if let question = questions(in: fixture).first { return question }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try XCTUnwrap(questions(in: fixture).first)
    }

    func testChildCommandsStopForAFinishedMissionOrAnotherColumn() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(ask("Which API?", in: fixture, agentUUID: otherAgentUUID), 4)
        XCTAssertEqual(MissionEventCLI.run(
            kind: .completed,
            arguments: ["--message", "Done"],
            environment: childEnvironment(agentUUID: otherAgentUUID),
            eventsURL: fixture.eventsURL,
            missionsURL: fixture.missionsURL
        ), 4)
        XCTAssertTrue(try queuedEvents(in: fixture).isEmpty, "Nirux would drop these events")

        complete(fixture)
        XCTAssertEqual(ask("Still there?", in: fixture), 4)
        XCTAssertEqual(MissionEventCLI.run(
            kind: .completed,
            arguments: ["--message", "Done again"],
            environment: childEnvironment(),
            eventsURL: fixture.eventsURL,
            missionsURL: fixture.missionsURL
        ), 4)
        XCTAssertTrue(try queuedEvents(in: fixture).isEmpty)
    }

    func testAskReportsAnUnreadableLedgerAsRetryable() throws {
        let fixture = try makeFixture()
        try Data("not json".utf8).write(to: fixture.missionsURL)
        XCTAssertEqual(ask("Which API?", in: fixture), 1)
        XCTAssertTrue(try queuedEvents(in: fixture).isEmpty)
    }

    func testReceiveStopsOnlyWhenNoMissionIsActive() throws {
        let fixture = try makeFixture()
        func receive() -> Int32 {
            MissionEventCLI.receive(
                arguments: ["--timeout", "0"],
                environment: parentEnvironment,
                eventsURL: fixture.eventsURL,
                missionsURL: fixture.missionsURL,
                pollInterval: 0.01
            )
        }
        XCTAssertEqual(receive(), 3, "the child is still working")
        complete(fixture)
        XCTAssertEqual(receive(), 0, "prints the completion")
        fixture.center.drain()
        XCTAssertEqual(receive(), 4, "nothing left to wait for")
    }

    func testReplyStopsWhenTheQuestionWasAlreadyAnswered() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(ask("Which API?", in: fixture), 3)
        fixture.center.drain()
        let question = try XCTUnwrap(questions(in: fixture).first)
        XCTAssertNotNil(fixture.store.respond(
            to: question.id, message: "Answered from Activity.", enabled: true, now: 30
        ))
        XCTAssertEqual(MissionEventCLI.reply(
            arguments: ["--event", question.id, "--message", "Use AuthService."],
            environment: parentEnvironment,
            eventsURL: fixture.eventsURL,
            missionsURL: fixture.missionsURL,
            confirmationTimeout: 0
        ), 4)
        XCTAssertTrue(try queuedEvents(in: fixture).isEmpty)
    }

    func testDisabledSettingAndBadCommandsNeverTouchTheMailbox() {
        XCTAssertEqual(MissionEventCLI.main(["ask", "--message", "Hi"], handoffsEnabled: { false }), 4)
        XCTAssertEqual(MissionEventCLI.main([], handoffsEnabled: { true }), 2)
        XCTAssertEqual(MissionEventCLI.main(["response"], handoffsEnabled: { true }), 2)
        XCTAssertEqual(MissionEventCLI.main(["ask", "--message"], handoffsEnabled: { nil }), 2)
    }

    func testTimeoutCanShortenButNeverExtendTheWait() {
        XCTAssertEqual(MissionEventCLI.validTimeout(nil), MissionEventCLI.defaultWaitTimeout)
        XCTAssertEqual(MissionEventCLI.validTimeout("900"), MissionEventCLI.defaultWaitTimeout)
        XCTAssertEqual(MissionEventCLI.validTimeout("5"), 5)
        XCTAssertEqual(MissionEventCLI.validTimeout("0"), 0)
        XCTAssertNil(MissionEventCLI.validTimeout("-1"))
        XCTAssertNil(MissionEventCLI.validTimeout("soon"))
    }

    func testOnlyTheChildMarksAResponseReceived() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(ask("Which API?", in: fixture), 3)
        fixture.center.drain()
        let question = try XCTUnwrap(questions(in: fixture).first)
        let response = try XCTUnwrap(fixture.store.respond(
            to: question.id, message: "Use AuthService.", enabled: true, now: 30
        )).event

        func receipt(for target: String, parent: Bool) -> MissionEvent {
            MissionEvent(
                id: UUID().uuidString,
                missionID: missionID,
                childWorkspaceID: childWorkspaceID,
                childAgentUUID: childAgentUUID,
                parentWorkspaceID: parent ? parentWorkspaceID : nil,
                parentAgentUUID: parent ? parentAgentUUID : nil,
                kind: .acknowledged,
                message: "acknowledged",
                inReplyTo: target,
                timestamp: 40
            )
        }
        guard case .rejected = fixture.store.process(receipt(for: response.id, parent: true), enabled: true) else {
            return XCTFail("the parent cannot mark its own response received")
        }
        guard case .rejected = fixture.store.process(receipt(for: question.id, parent: false), enabled: true) else {
            return XCTFail("the child cannot consume its own question")
        }
        var forged = response
        forged.childConsumedAt = 1
        guard case .rejected = fixture.store.process(forged, enabled: true) else {
            return XCTFail("incoming events never carry a receipt")
        }
        XCTAssertNil(fixture.store.response(to: question.id)?.childConsumedAt)

        guard case .accepted(nil) = fixture.store.process(receipt(for: response.id, parent: false), enabled: true) else {
            return XCTFail("the child receipt is accepted")
        }
        XCTAssertEqual(fixture.store.response(to: question.id)?.childConsumedAt, 40)
        XCTAssertNil(fixture.store.missions[0].events[0].childConsumedAt)
    }

    func testLedgerReaderDecodesOnlyAfterTheFileChanges() throws {
        let fixture = try makeFixture()
        var reader = MissionLedgerReader(url: fixture.missionsURL)
        XCTAssertTrue(reader.refresh())
        XCTAssertEqual(reader.missions.map(\.id), [missionID])
        XCTAssertFalse(reader.refresh(), "unchanged file is not decoded again")

        XCTAssertEqual(ask("Which API?", in: fixture), 3)
        fixture.center.drain()
        XCTAssertTrue(reader.refresh(), "an atomic save is a change")
        XCTAssertEqual(reader.missions[0].events.count, 1)

        try Data("not json".utf8).write(to: fixture.missionsURL)
        XCTAssertFalse(reader.refresh())
        XCTAssertEqual(reader.missions[0].events.count, 1, "an unreadable ledger keeps the last good one")
    }

    func testWaitInstructionsMatchTheCommands() throws {
        XCTAssertLessThan(MissionEventCLI.defaultWaitTimeout, 120, "Claude Code stops foreground commands at 2 minutes")
        let skill = NiruxShellView.worktreeSkillContent
        let prompt = try XCTUnwrap(
            NiruxShellView.agentStartupPrompt(agent: .claude, deliveredHandover: false, isMission: true)
        )
        for text in [skill, prompt] {
            XCTAssertFalse(text.contains("--timeout"), "the default wait already fits the shell tool")
            XCTAssertTrue(text.contains("\(Int(MissionEventCLI.defaultWaitTimeout)) seconds"))
            XCTAssertTrue(text.contains("\(MissionEventCLI.maxMessageLength) characters"))
            XCTAssertTrue(text.contains("exact same command again"))
            XCTAssertTrue(text.contains("status 3") || text.contains("- 3:"))
            XCTAssertTrue(text.contains("Status 4") || text.contains("- 4:"))
        }
    }
}
