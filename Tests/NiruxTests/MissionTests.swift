import XCTest
@testable import Nirux

@MainActor
final class MissionTests: XCTestCase {
    private let missionID = "11111111-1111-4111-8111-111111111111"
    private let parentWorkspaceID = "22222222-2222-4222-8222-222222222222"
    private let parentAgentUUID = "33333333-3333-4333-8333-333333333333"
    private let childWorkspaceID = "44444444-4444-4444-8444-444444444444"
    private let childAgentUUID = "55555555-5555-4555-8555-555555555555"

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-mission-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func request(id: String? = nil, parentWorkspaceID: String? = nil) -> MissionCreationRequest {
        MissionCreationRequest(
            id: id ?? missionID,
            parentWorkspaceID: parentWorkspaceID ?? self.parentWorkspaceID,
            parentAgentUUID: parentAgentUUID,
            childWorkspaceID: childWorkspaceID,
            childAgentUUID: childAgentUUID,
            childAgentKind: "codex",
            branch: "feat/mission"
        )
    }

    private func event(
        id: String = "66666666-6666-4666-8666-666666666666",
        missionID: String? = nil,
        childWorkspaceID: String? = nil,
        childAgentUUID: String? = nil,
        kind: MissionEvent.Kind = .question,
        message: String = "Which API should I use?",
        timestamp: TimeInterval = 20
    ) -> MissionEvent {
        MissionEvent(
            id: id,
            missionID: missionID ?? self.missionID,
            childWorkspaceID: childWorkspaceID ?? self.childWorkspaceID,
            childAgentUUID: childAgentUUID ?? self.childAgentUUID,
            kind: kind,
            message: message,
            timestamp: timestamp,
            deliveredAt: nil
        )
    }

    func testMissionCreationIsDisabledByDefaultAndRejectsMalformedIdentifiers() throws {
        let fileURL = try makeDirectory().appendingPathComponent("missions.json")
        let store = MissionStore(fileURL: fileURL)

        XCTAssertNil(store.create(request(), enabled: false, now: 10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNil(store.create(request(parentWorkspaceID: "not-a-uuid"), enabled: true, now: 10))
        XCTAssertTrue(store.missions.isEmpty)
    }

    func testTerminalEnvironmentOnlyExposesMissionMetadataWhenEnabled() {
        let disabled = WorkspaceState.makeTerminalEnvironment(
            profileID: "profile",
            workspaceID: childWorkspaceID,
            agentUUID: childAgentUUID,
            missionID: missionID,
            missionHandoffsEnabled: false,
            executablePath: "/Applications/Nirux.app/Contents/MacOS/Nirux"
        )
        XCTAssertEqual(disabled["NIRUX_WORKSPACE_ID"], childWorkspaceID)
        XCTAssertNil(disabled["NIRUX_MISSION_HANDOFFS"])
        XCTAssertNil(disabled["NIRUX_MISSION_ID"])
        XCTAssertNil(disabled["NIRUX_CLI_PATH"])

        let enabled = WorkspaceState.makeTerminalEnvironment(
            profileID: "profile",
            workspaceID: childWorkspaceID,
            agentUUID: childAgentUUID,
            missionID: missionID,
            missionHandoffsEnabled: true,
            executablePath: "/Applications/Nirux.app/Contents/MacOS/Nirux"
        )
        XCTAssertEqual(enabled["NIRUX_MISSION_HANDOFFS"], "1")
        XCTAssertEqual(enabled["NIRUX_MISSION_ID"], missionID)
        XCTAssertEqual(enabled["NIRUX_CLI_PATH"], "/Applications/Nirux.app/Contents/MacOS/Nirux")
    }

    func testMissionPersistenceAndCompletionStatusRoundTrip() throws {
        let fileURL = try makeDirectory().appendingPathComponent("missions.json")
        let store = MissionStore(fileURL: fileURL)
        XCTAssertNotNil(store.create(request(), enabled: true, now: 10))

        let completion = event(kind: .completed, message: "Implemented and tested.")
        XCTAssertNotNil(store.accept(completion, enabled: true))
        store.markDelivered(eventID: completion.id, at: 30)

        let restored = MissionStore(fileURL: fileURL)
        restored.load()
        XCTAssertEqual(restored.missions.count, 1)
        XCTAssertEqual(restored.missions[0].status, .completed)
        XCTAssertEqual(restored.missions[0].events, [
            MissionEvent(
                id: completion.id,
                missionID: missionID,
                childWorkspaceID: childWorkspaceID,
                childAgentUUID: childAgentUUID,
                kind: .completed,
                message: "Implemented and tested.",
                timestamp: 20,
                deliveredAt: 30
            )
        ])
    }

    func testRoutingRejectsUnknownMismatchedAndStaleMissionEvents() throws {
        let fileURL = try makeDirectory().appendingPathComponent("missions.json")
        let store = MissionStore(fileURL: fileURL)
        XCTAssertNotNil(store.create(request(), enabled: true, now: 10))

        XCTAssertNil(store.accept(
            event(missionID: "77777777-7777-4777-8777-777777777777"), enabled: true
        ))
        XCTAssertNil(store.accept(
            event(childAgentUUID: "88888888-8888-4888-8888-888888888888"), enabled: true
        ))
        XCTAssertNil(store.accept(event(message: "   "), enabled: true))

        let completion = event(kind: .completed, message: "Done")
        XCTAssertNotNil(store.accept(completion, enabled: true))
        XCTAssertNil(store.accept(
            event(
                id: "99999999-9999-4999-8999-999999999999",
                message: "A late question",
                timestamp: 21
            ),
            enabled: true
        ))
    }

    func testCompletionRetiresPendingQuestionsBeforeParentReceive() throws {
        let directory = try makeDirectory()
        let missionsURL = directory.appendingPathComponent("missions.json")
        let eventsURL = directory.appendingPathComponent("mission-events.jsonl")
        let store = MissionStore(fileURL: missionsURL)
        XCTAssertNotNil(store.create(request(), enabled: true, now: 10))
        let question = event(timestamp: 20)
        let completion = event(
            id: "77777777-7777-4777-8777-777777777777",
            kind: .completed,
            message: "Done",
            timestamp: 30
        )

        XCTAssertNotNil(store.accept(question, enabled: true))
        XCTAssertNotNil(store.accept(completion, enabled: true))
        XCTAssertEqual(store.missions[0].events[0].parentConsumedAt, 30)

        XCTAssertEqual(MissionEventCLI.receive(
            arguments: ["--timeout", "0"],
            environment: parentEnvironment,
            now: { 40 },
            eventsURL: eventsURL,
            missionsURL: missionsURL,
            pollInterval: 0.01
        ), 0)
        let acknowledgement = try decodeSingleEvent(from: eventsURL)
        XCTAssertEqual(acknowledgement.kind, .acknowledged)
        XCTAssertEqual(acknowledgement.inReplyTo, completion.id)
    }

    func testResponseRequiresRecordedParentAndCorrelatesToQuestion() throws {
        let fileURL = try makeDirectory().appendingPathComponent("missions.json")
        let store = MissionStore(fileURL: fileURL)
        XCTAssertNotNil(store.create(request(), enabled: true, now: 10))
        let question = event()
        XCTAssertNotNil(store.accept(question, enabled: true))
        store.markDelivered(eventID: question.id, at: 25)
        XCTAssertNil(
            store.missions[0].events[0].parentConsumedAt,
            "showing Activity must not consume the parent agent inbox"
        )

        let forged = MissionEvent(
            id: "77777777-7777-4777-8777-777777777777",
            missionID: missionID,
            childWorkspaceID: childWorkspaceID,
            childAgentUUID: childAgentUUID,
            parentWorkspaceID: "88888888-8888-4888-8888-888888888888",
            parentAgentUUID: parentAgentUUID,
            kind: .response,
            message: "Use the forged answer",
            inReplyTo: question.id,
            timestamp: 30
        )
        XCTAssertNil(store.accept(forged, enabled: true))

        let accepted = try XCTUnwrap(store.respond(
            to: question.id,
            message: " Use AuthService. ",
            enabled: true,
            now: 31
        ))
        XCTAssertEqual(accepted.event.kind, .response)
        XCTAssertEqual(accepted.event.inReplyTo, question.id)
        XCTAssertEqual(accepted.event.message, "Use AuthService.")
        XCTAssertEqual(store.response(to: question.id)?.id, accepted.event.id)
        XCTAssertEqual(store.missions[0].events[0].parentConsumedAt, 31)
        XCTAssertNil(store.respond(to: question.id, message: "Duplicate", enabled: true, now: 32))
    }

    func testCompletionAcknowledgementUsesParentIdentity() throws {
        let fileURL = try makeDirectory().appendingPathComponent("missions.json")
        let store = MissionStore(fileURL: fileURL)
        XCTAssertNotNil(store.create(request(), enabled: true, now: 10))
        let completion = event(kind: .completed, message: "Done")
        XCTAssertNotNil(store.accept(completion, enabled: true))

        let forgedAck = MissionEvent(
            id: "77777777-7777-4777-8777-777777777777",
            missionID: missionID,
            childWorkspaceID: childWorkspaceID,
            childAgentUUID: childAgentUUID,
            parentWorkspaceID: parentWorkspaceID,
            parentAgentUUID: "88888888-8888-4888-8888-888888888888",
            kind: .acknowledged,
            message: "acknowledged",
            inReplyTo: completion.id,
            timestamp: 30
        )
        XCTAssertNil(store.accept(forgedAck, enabled: true))
        XCTAssertNil(store.missions[0].events[0].parentConsumedAt)

        let validAck = MissionEvent(
            id: "99999999-9999-4999-8999-999999999999",
            missionID: missionID,
            childWorkspaceID: childWorkspaceID,
            childAgentUUID: childAgentUUID,
            parentWorkspaceID: parentWorkspaceID,
            parentAgentUUID: parentAgentUUID,
            kind: .acknowledged,
            message: "acknowledged",
            inReplyTo: completion.id,
            timestamp: 31
        )
        XCTAssertNil(store.accept(validAck, enabled: true), "acks mutate the target, not the event list")
        XCTAssertEqual(store.missions[0].events[0].parentConsumedAt, 31)
        XCTAssertEqual(store.missions[0].events.count, 1)
    }

    func testCLIRequiresMissionEnvironmentAndWritesOneJSONLine() throws {
        let eventsURL = try makeDirectory().appendingPathComponent("mission-events.jsonl")
        let environment = [
            "NIRUX_MISSION_HANDOFFS": "1",
            "NIRUX_MISSION_ID": missionID,
            "NIRUX_WORKSPACE_ID": childWorkspaceID,
            "NIRUX_AGENT_UUID": childAgentUUID
        ]

        XCTAssertEqual(MissionEventCLI.run(
            kind: .question,
            arguments: ["--message", " Need an answer "],
            environment: environment,
            now: 42,
            eventsURL: eventsURL
        ), 0)

        let lines = try Data(contentsOf: eventsURL).split(separator: 0x0A)
        XCTAssertEqual(lines.count, 1)
        let decoded = try JSONDecoder().decode(MissionEvent.self, from: Data(lines[0]))
        XCTAssertEqual(decoded.missionID, missionID)
        XCTAssertEqual(decoded.childWorkspaceID, childWorkspaceID)
        XCTAssertEqual(decoded.childAgentUUID, childAgentUUID)
        XCTAssertEqual(decoded.kind, .question)
        XCTAssertEqual(decoded.message, "Need an answer")
        XCTAssertEqual(decoded.timestamp, 42)

        XCTAssertEqual(MissionEventCLI.run(
            kind: .completed,
            arguments: ["--message", "Done"],
            environment: [:],
            eventsURL: eventsURL
        ), 2)
        XCTAssertEqual(try Data(contentsOf: eventsURL).split(separator: 0x0A).count, 1)
    }

    func testAskWaitReturnsPersistedCorrelatedResponse() throws {
        let directory = try makeDirectory()
        let missionsURL = directory.appendingPathComponent("missions.json")
        let eventsURL = directory.appendingPathComponent("mission-events.jsonl")
        let store = MissionStore(fileURL: missionsURL)
        XCTAssertNotNil(store.create(request(), enabled: true, now: 10))
        let question = event()
        XCTAssertNotNil(store.accept(question, enabled: true))
        XCTAssertNotNil(store.respond(
            to: question.id,
            message: "Use AuthService.",
            enabled: true,
            now: 30
        ))

        let result = MissionEventCLI.ask(
            arguments: ["--message", "Which API?", "--timeout", "0"],
            environment: childEnvironment,
            now: 20,
            eventID: question.id,
            eventsURL: eventsURL,
            missionsURL: missionsURL,
            pollInterval: 0.01
        )
        XCTAssertEqual(result, 0)
        let queued = try decodeSingleEvent(from: eventsURL)
        XCTAssertEqual(queued.id, question.id)
        XCTAssertEqual(queued.kind, .question)
    }

    func testParentReceiveAndReplyRoundTripThroughQueue() throws {
        let directory = try makeDirectory()
        let missionsURL = directory.appendingPathComponent("missions.json")
        let eventsURL = directory.appendingPathComponent("mission-events.jsonl")
        let store = MissionStore(fileURL: missionsURL)
        XCTAssertNotNil(store.create(request(), enabled: true, now: 10))
        let question = event()
        XCTAssertNotNil(store.accept(question, enabled: true))

        XCTAssertEqual(MissionEventCLI.receive(
            arguments: ["--timeout", "0"],
            environment: parentEnvironment,
            eventsURL: eventsURL,
            missionsURL: missionsURL,
            pollInterval: 0.01
        ), 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: eventsURL.path),
            "a question stays pending until the parent actually replies"
        )

        XCTAssertEqual(MissionEventCLI.reply(
            arguments: ["--event", question.id, "--message", "Use AuthService."],
            environment: parentEnvironment,
            now: 30,
            eventsURL: eventsURL,
            missionsURL: missionsURL,
            confirmationTimeout: 0
        ), 0)
        let center = MissionEventCenter(store: store, eventsURL: eventsURL, isEnabled: { true })
        center.drain()

        XCTAssertEqual(store.response(to: question.id)?.message, "Use AuthService.")
        XCTAssertEqual(store.missions[0].events[0].parentConsumedAt, 30)
    }

    func testParentReceiveAcknowledgesCompletion() throws {
        let directory = try makeDirectory()
        let missionsURL = directory.appendingPathComponent("missions.json")
        let eventsURL = directory.appendingPathComponent("mission-events.jsonl")
        let store = MissionStore(fileURL: missionsURL)
        XCTAssertNotNil(store.create(request(), enabled: true, now: 10))
        let completion = event(kind: .completed, message: "Done")
        XCTAssertNotNil(store.accept(completion, enabled: true))

        XCTAssertEqual(MissionEventCLI.receive(
            arguments: ["--timeout", "0"],
            environment: parentEnvironment,
            now: { 40 },
            eventsURL: eventsURL,
            missionsURL: missionsURL,
            pollInterval: 0.01
        ), 0)
        let center = MissionEventCenter(store: store, eventsURL: eventsURL, isEnabled: { true })
        center.drain()

        XCTAssertEqual(store.missions[0].events[0].parentConsumedAt, 40)
    }

    func testLegacyMissionEventDecodesWithoutBidirectionalFields() throws {
        let json = Data("""
        {
          "id": "66666666-6666-4666-8666-666666666666",
          "missionID": "11111111-1111-4111-8111-111111111111",
          "childWorkspaceID": "44444444-4444-4444-8444-444444444444",
          "childAgentUUID": "55555555-5555-4555-8555-555555555555",
          "kind": "question",
          "message": "Which API?",
          "timestamp": 20
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(MissionEvent.self, from: json)
        XCTAssertNil(decoded.parentWorkspaceID)
        XCTAssertNil(decoded.parentAgentUUID)
        XCTAssertNil(decoded.inReplyTo)
        XCTAssertNil(decoded.parentConsumedAt)
    }

    func testDisabledCenterDropsQueuedEventsWithoutMutatingMission() throws {
        let directory = try makeDirectory()
        let missionsURL = directory.appendingPathComponent("missions.json")
        let eventsURL = directory.appendingPathComponent("mission-events.jsonl")
        let store = MissionStore(fileURL: missionsURL)
        XCTAssertNotNil(store.create(request(), enabled: true, now: 10))
        try write(event(), to: eventsURL)

        let center = MissionEventCenter(store: store, eventsURL: eventsURL, isEnabled: { false })
        center.drain()

        XCTAssertTrue(store.missions[0].events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: eventsURL.path))
    }

    func testCenterRecoversProcessingFileAfterRestart() throws {
        let directory = try makeDirectory()
        let missionsURL = directory.appendingPathComponent("missions.json")
        let eventsURL = directory.appendingPathComponent("mission-events.jsonl")
        let processingURL = eventsURL.deletingPathExtension().appendingPathExtension("processing")
        let initialStore = MissionStore(fileURL: missionsURL)
        XCTAssertNotNil(initialStore.create(request(), enabled: true, now: 10))
        let pending = event()
        try write(pending, to: processingURL)

        let restoredStore = MissionStore(fileURL: missionsURL)
        restoredStore.load()
        let center = MissionEventCenter(
            store: restoredStore, eventsURL: eventsURL, isEnabled: { true }
        )
        center.drain()

        XCTAssertEqual(restoredStore.missions[0].events.map(\.id), [pending.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: processingURL.path))
    }

    func testCenterRetainsProcessingFileUntilMissionSaveSucceeds() throws {
        let directory = try makeDirectory()
        let missionsURL = directory.appendingPathComponent("missions.json")
        let eventsURL = directory.appendingPathComponent("mission-events.jsonl")
        let processingURL = eventsURL.deletingPathExtension().appendingPathExtension("processing")
        let store = MissionStore(fileURL: missionsURL)
        XCTAssertNotNil(store.create(request(), enabled: true, now: 10))
        try FileManager.default.removeItem(at: missionsURL)
        try FileManager.default.createDirectory(at: missionsURL, withIntermediateDirectories: false)
        let pending = event()
        try write(pending, to: processingURL)
        let center = MissionEventCenter(store: store, eventsURL: eventsURL, isEnabled: { true })

        center.drain()

        XCTAssertTrue(store.missions[0].events.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: processingURL.path))

        try FileManager.default.removeItem(at: missionsURL)
        center.drain()

        XCTAssertEqual(store.missions[0].events.map(\.id), [pending.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: processingURL.path))
        let restoredStore = MissionStore(fileURL: missionsURL)
        restoredStore.load()
        XCTAssertEqual(restoredStore.missions[0].events.map(\.id), [pending.id])
    }

    func testPendingEventSurvivesRestartAndDeliversOnce() throws {
        let directory = try makeDirectory()
        let missionsURL = directory.appendingPathComponent("missions.json")
        let eventsURL = directory.appendingPathComponent("mission-events.jsonl")
        let firstStore = MissionStore(fileURL: missionsURL)
        XCTAssertNotNil(firstStore.create(request(), enabled: true, now: 10))
        let pending = event()
        try write(pending, to: eventsURL)

        // First process accepts and persists the event, then exits before a
        // UI delivery callback is available.
        let firstCenter = MissionEventCenter(
            store: firstStore, eventsURL: eventsURL, isEnabled: { true }
        )
        firstCenter.drain()
        XCTAssertEqual(firstStore.pendingEvents().map(\.event.id), [pending.id])

        // A fresh process reloads the ledger and mirrors the pending event.
        let restoredStore = MissionStore(fileURL: missionsURL)
        restoredStore.load()
        let restoredCenter = MissionEventCenter(
            store: restoredStore, eventsURL: eventsURL, isEnabled: { true }
        )
        var deliveredIDs: [String] = []
        restoredCenter.onEvent = { _, event in
            deliveredIDs.append(event.id)
            return true
        }
        restoredCenter.deliverPendingEvents()
        restoredCenter.deliverPendingEvents()

        XCTAssertEqual(deliveredIDs, [pending.id])
        XCTAssertTrue(restoredStore.pendingEvents().isEmpty)
        XCTAssertNotNil(restoredStore.missions[0].events[0].deliveredAt)
    }

    private func write(_ event: MissionEvent, to url: URL) throws {
        var data = try JSONEncoder().encode(event)
        data.append(0x0A)
        try data.write(to: url)
    }

    private var childEnvironment: [String: String] {
        [
            "NIRUX_MISSION_HANDOFFS": "1",
            "NIRUX_MISSION_ID": missionID,
            "NIRUX_WORKSPACE_ID": childWorkspaceID,
            "NIRUX_AGENT_UUID": childAgentUUID
        ]
    }

    private var parentEnvironment: [String: String] {
        [
            "NIRUX_MISSION_HANDOFFS": "1",
            "NIRUX_WORKSPACE_ID": parentWorkspaceID,
            "NIRUX_AGENT_UUID": parentAgentUUID
        ]
    }

    private func decodeSingleEvent(from url: URL) throws -> MissionEvent {
        let lines = try Data(contentsOf: url).split(separator: 0x0A)
        XCTAssertEqual(lines.count, 1)
        return try JSONDecoder().decode(MissionEvent.self, from: Data(lines[0]))
    }
}
