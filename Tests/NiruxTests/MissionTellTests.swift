import XCTest
@testable import Nirux

/// `--mission tell`: the parent's message for a child, queued in the ledger
/// until Nirux types it into the child's free prompt.
@MainActor
final class MissionTellTests: XCTestCase {
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

    private func makeFixture(childAgentKind: String = "claude") throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-mission-tell-tests-\(UUID().uuidString)", isDirectory: true)
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
            childAgentKind: childAgentKind,
            branch: "feat/mission"
        ), enabled: true, now: 10))
        let center = MissionEventCenter(store: store, eventsURL: eventsURL, isEnabled: { true })
        return Fixture(missionsURL: missionsURL, eventsURL: eventsURL, store: store, center: center)
    }

    private func parentEnvironment(agentUUID: String? = nil) -> [String: String] {
        [
            "NIRUX_MISSION_HANDOFFS": "1",
            "NIRUX_WORKSPACE_ID": parentWorkspaceID,
            "NIRUX_AGENT_UUID": agentUUID ?? parentAgentUUID
        ]
    }

    private func tell(
        _ message: String,
        branch: String = "feat/mission",
        in fixture: Fixture,
        at time: TimeInterval = 20,
        agentUUID: String? = nil
    ) -> Int32 {
        MissionEventCLI.tell(
            arguments: ["--branch", branch, "--message", message, "--timeout", "0"],
            environment: parentEnvironment(agentUUID: agentUUID),
            now: { time },
            eventsURL: fixture.eventsURL,
            missionsURL: fixture.missionsURL,
            pollInterval: 0.01
        )
    }

    private func queuedEvents(in fixture: Fixture) throws -> [MissionEvent] {
        guard FileManager.default.fileExists(atPath: fixture.eventsURL.path) else { return [] }
        return try Data(contentsOf: fixture.eventsURL).split(separator: 0x0A).map {
            try JSONDecoder().decode(MissionEvent.self, from: Data($0))
        }
    }

    private func instructions(in fixture: Fixture) -> [MissionEvent] {
        fixture.store.missions[0].events.filter { $0.kind == .instruction }
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

    // MARK: - CLI

    func testTellQueuesAnInstructionUntilNiruxTypesIt() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(tell(" /code-review ", in: fixture), 3, "not typed yet")
        let queued = try XCTUnwrap(try queuedEvents(in: fixture).first)
        XCTAssertEqual(queued.kind, .instruction)
        XCTAssertEqual(queued.message, "/code-review")
        XCTAssertEqual(queued.parentWorkspaceID, parentWorkspaceID)
        XCTAssertEqual(queued.parentAgentUUID, parentAgentUUID)
        XCTAssertEqual(queued.childAgentUUID, childAgentUUID)

        fixture.center.drain()
        XCTAssertEqual(fixture.store.pendingInstructions(now: 30).map(\.event.id), [queued.id])

        XCTAssertTrue(fixture.store.markInstructionTyped(eventID: queued.id, at: 30))
        XCTAssertTrue(fixture.store.pendingInstructions(now: 30).isEmpty)
        XCTAssertEqual(instructions(in: fixture).first?.childConsumedAt, 30)
    }

    func testRetriedTellResumesTheSameInstruction() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(tell("/code-review", in: fixture), 3)
        fixture.center.drain()
        XCTAssertEqual(tell("/code-review", in: fixture), 3, "a rerun keeps waiting")
        XCTAssertTrue(try queuedEvents(in: fixture).isEmpty, "and queues nothing")

        let typed = try XCTUnwrap(instructions(in: fixture).first)
        XCTAssertTrue(fixture.store.markInstructionTyped(eventID: typed.id, at: 30))
        let replayAt = 30 + MissionEventCLI.answerReplayWindow - 1
        XCTAssertEqual(tell("/code-review", in: fixture, at: replayAt), 0, "a rerun right after it was typed")
        XCTAssertTrue(try queuedEvents(in: fixture).isEmpty)

        XCTAssertEqual(tell("/code-review", in: fixture, at: replayAt + 2), 3, "later, the same text is sent again")
        fixture.center.drain()
        XCTAssertEqual(instructions(in: fixture).count, 2)
    }

    func testRetryBeforeTheDrainQueuesTheSameInstruction() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(tell("/code-review", in: fixture), 3)
        XCTAssertEqual(tell("/code-review", in: fixture), 3, "rerun before Nirux drained the queue")
        let queued = try queuedEvents(in: fixture)
        XCTAssertEqual(queued.count, 2)
        XCTAssertEqual(Set(queued.map(\.id)).count, 1, "both attempts carry the same ID")
        fixture.center.drain()
        XCTAssertEqual(instructions(in: fixture).count, 1)
    }

    func testAnInstructionNotTypedWithinItsLifetimeIsDropped() throws {
        let fixture = try makeFixture()
        let lifetime = MissionEventCLI.instructionLifetime
        XCTAssertEqual(tell("/code-review", in: fixture, at: 20), 3)
        fixture.center.drain()
        XCTAssertEqual(fixture.store.pendingInstructions(now: 20 + lifetime - 1).count, 1)
        XCTAssertTrue(fixture.store.pendingInstructions(now: 20 + lifetime).isEmpty, "never typed now")

        XCTAssertEqual(tell("/code-review", in: fixture, at: 20 + lifetime), 3)
        fixture.center.drain()
        XCTAssertEqual(instructions(in: fixture).count, 2, "a rerun after that sends it anew")
        XCTAssertEqual(fixture.store.pendingInstructions(now: 20 + lifetime).count, 1)
    }

    func testTellReturnsOnceNiruxTypedIt() async throws {
        let fixture = try makeFixture()
        let environment = parentEnvironment()
        let eventsURL = fixture.eventsURL
        let missionsURL = fixture.missionsURL
        let waiting = Task.detached {
            MissionEventCLI.tell(
                arguments: ["--branch", "feat/mission", "--message", "/premortem", "--timeout", "10"],
                environment: environment,
                eventsURL: eventsURL,
                missionsURL: missionsURL,
                pollInterval: 0.01
            )
        }

        let deadline = Date().addingTimeInterval(5)
        while fixture.store.pendingInstructions().isEmpty, Date() < deadline {
            fixture.center.drain()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pending = try XCTUnwrap(fixture.store.pendingInstructions().first)
        XCTAssertTrue(fixture.store.markInstructionTyped(eventID: pending.event.id))

        let status = await waiting.value
        XCTAssertEqual(status, 0)
    }

    func testTellStopsForAnotherParentBranchOrAgent() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(tell("/code-review", branch: "feat/other", in: fixture), 4)
        XCTAssertEqual(tell("/code-review", in: fixture, agentUUID: otherAgentUUID), 4)
        XCTAssertTrue(try queuedEvents(in: fixture).isEmpty)

        let codex = try makeFixture(childAgentKind: "codex")
        XCTAssertEqual(tell("/code-review", in: codex), 4, "Nirux can't prove a Codex prompt is free")
        XCTAssertTrue(try queuedEvents(in: codex).isEmpty)

        for arguments in [["--branch", "feat/mission"], ["--message", "Hi"],
                          ["--branch", "feat/mission", "--message", String(repeating: "x", count: 501)]] {
            XCTAssertEqual(MissionEventCLI.tell(
                arguments: arguments,
                environment: parentEnvironment(),
                eventsURL: fixture.eventsURL,
                missionsURL: fixture.missionsURL
            ), 2, "\(arguments)")
        }
        XCTAssertEqual(MissionEventCLI.main(["tell", "--message", "Hi"], handoffsEnabled: { false }), 4)
    }

    // MARK: - Ledger

    func testTypingATellReopensACompletedMission() throws {
        let fixture = try makeFixture()
        complete(fixture)
        XCTAssertEqual(tell("/premortem", in: fixture), 3, "a follow-up after completion")
        fixture.center.drain()
        XCTAssertEqual(fixture.store.missions[0].status, .completed, "until the child gets it")

        let pending = try XCTUnwrap(fixture.store.pendingInstructions(now: 30).first)
        XCTAssertTrue(fixture.store.markInstructionTyped(eventID: pending.event.id, at: 30))
        XCTAssertEqual(fixture.store.missions[0].status, .active)
        XCTAssertEqual(MissionEventCLI.ask(
            arguments: ["--message", "Which API?", "--timeout", "0"],
            environment: [
                "NIRUX_MISSION_HANDOFFS": "1",
                "NIRUX_MISSION_ID": missionID,
                "NIRUX_WORKSPACE_ID": childWorkspaceID,
                "NIRUX_AGENT_UUID": childAgentUUID
            ],
            eventsURL: fixture.eventsURL,
            missionsURL: fixture.missionsURL,
            pollInterval: 0.01
        ), 3, "the child can ask again")
    }

    func testOnlyEventsWithTheRecordedParentIdentityAreTold() throws {
        let fixture = try makeFixture()
        func instruction(parentAgentUUID: String?) -> MissionEvent {
            MissionEvent(
                id: UUID().uuidString,
                missionID: missionID,
                childWorkspaceID: childWorkspaceID,
                childAgentUUID: childAgentUUID,
                parentWorkspaceID: parentAgentUUID == nil ? nil : parentWorkspaceID,
                parentAgentUUID: parentAgentUUID,
                kind: .instruction,
                message: "/code-review",
                timestamp: 20
            )
        }
        guard case .rejected = fixture.store.process(instruction(parentAgentUUID: nil), enabled: true) else {
            return XCTFail("the child cannot tell itself")
        }
        guard case .rejected = fixture.store.process(instruction(parentAgentUUID: otherAgentUUID), enabled: true)
        else { return XCTFail("another terminal cannot tell the child") }
        XCTAssertNotNil(fixture.store.accept(instruction(parentAgentUUID: parentAgentUUID), enabled: true))
        XCTAssertEqual(fixture.store.pendingInstructions(now: 30).count, 1)
    }

    // MARK: - Free prompt

    private let t0: TimeInterval = 1_000
    private let claudeProcess = ProcessInstance(pid: 4242, startedAt: 900)

    private func hook(_ name: AgentHookEvent.Name, at offset: TimeInterval, tool: String? = nil, key: String? = nil,
                      source: String? = nil) -> AgentHookEvent {
        AgentHookEvent(
            kind: .claude, name: name, sessionID: "lead", detail: tool, source: source, toolName: tool, toolKey: key,
            timestamp: t0 + offset
        )
    }

    private func claude(_ instance: ProcessInstance? = nil, arguments: [String] = ["claude"]) -> ForegroundProcess {
        ForegroundProcess(instance: instance ?? claudeProcess, name: "claude", arguments: arguments)
    }

    /// Whether a `tell` sent at `t0 + 100` may be typed now.
    private func isFree(_ machine: AgentStatusMachine, foreground: ForegroundProcess? = nil) -> Bool {
        machine.isPromptFree(foreground: foreground ?? claude(), runningSince: t0 + 100)
    }

    /// A Claude session that took its first prompt and finished the turn.
    private func idleMachine() -> AgentStatusMachine {
        var machine = AgentStatusMachine()
        _ = machine.tick(fgName: "claude", isUserFocused: false, now: Date(timeIntervalSince1970: t0))
        _ = machine.apply(hook(.sessionStart, at: 0), isUserFocused: false)
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 0.5)) // the prompt itself
        _ = machine.apply(hook(.userPromptSubmit, at: 1), isUserFocused: false)
        _ = machine.apply(hook(.stop, at: 5), isUserFocused: false)
        return machine
    }

    func testPromptIsFreeOnlyAtTheIdlePromptOfTheClaudeThatWasTold() {
        var machine = idleMachine()
        XCTAssertTrue(isFree(machine))
        XCTAssertFalse(machine.isPromptFree(foreground: nil, runningSince: t0 + 100))
        XCTAssertFalse(isFree(machine, foreground: ForegroundProcess(instance: claudeProcess, name: "zsh", arguments: [])))
        XCTAssertFalse(isFree(machine, foreground: claude(arguments: ["claude", "-p"])), "headless")
        XCTAssertFalse(isFree(machine, foreground: claude(ProcessInstance(pid: 7, startedAt: t0 + 6))),
                       "a claude that took no prompt since it started")
        XCTAssertFalse(machine.isPromptFree(foreground: claude(), runningSince: claudeProcess.startedAt - 1),
                       "a claude started after the tell, such as one restored after a relaunch")

        _ = machine.apply(hook(.userPromptSubmit, at: 6), isUserFocused: false)
        XCTAssertFalse(isFree(machine), "working")
        _ = machine.apply(hook(.permissionRequest, at: 7, tool: "Bash", key: "k"), isUserFocused: false)
        XCTAssertFalse(isFree(machine), "a dialog is open")
        _ = machine.apply(hook(.stop, at: 9), isUserFocused: false)
        XCTAssertTrue(isFree(machine))
    }

    func testPromptIsNotFreeOverADraftOrTextNotSubmittedYet() {
        var machine = idleMachine()
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 7))
        XCTAssertFalse(isFree(machine), "the user's draft, or a tell not yet submitted")
        _ = machine.apply(hook(.userPromptSubmit, at: 8), isUserFocused: false)
        _ = machine.apply(hook(.stop, at: 9), isUserFocused: false)
        XCTAssertTrue(isFree(machine))
    }

    /// `/clear` fires SessionStart, not UserPromptSubmit: the text went in.
    func testClearEmptiesThePrompt() {
        var machine = idleMachine()
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 7)) // "/clear" typed by a tell
        _ = machine.apply(hook(.sessionStart, at: 8, source: "clear"), isUserFocused: false)
        XCTAssertTrue(isFree(machine))
    }

    /// Claude Code shows some dialogs (trust, MCP servers) before any hook
    /// that would list them: a session that took no prompt yet is not free.
    func testASessionThatTookNoPromptIsNotFree() {
        var machine = AgentStatusMachine()
        _ = machine.tick(fgName: "claude", isUserFocused: false, now: Date(timeIntervalSince1970: t0))
        XCTAssertFalse(isFree(machine), "no hook yet")
        _ = machine.apply(hook(.sessionStart, at: 0), isUserFocused: false)
        XCTAssertFalse(isFree(machine), "SessionStart alone")
    }
}
