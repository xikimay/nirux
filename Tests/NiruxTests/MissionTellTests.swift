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

    /// The instructions Nirux would type now.
    private func pendingInstructions(
        _ fixture: Fixture, now: TimeInterval = Date().timeIntervalSince1970
    ) -> [MissionStore.AcceptedEvent] {
        fixture.store.pendingPromptDeliveries(now: now).filter { $0.event.kind == .instruction }
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
        XCTAssertEqual(pendingInstructions(fixture, now: 30).map(\.event.id), [queued.id])

        XCTAssertTrue(fixture.store.markInstructionTyped(eventID: queued.id, at: 30))
        XCTAssertTrue(pendingInstructions(fixture, now: 30).isEmpty)
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
        XCTAssertEqual(pendingInstructions(fixture, now: 20 + lifetime - 1).count, 1)
        XCTAssertTrue(pendingInstructions(fixture, now: 20 + lifetime).isEmpty, "never typed now")

        XCTAssertEqual(tell("/code-review", in: fixture, at: 20 + lifetime), 3)
        fixture.center.drain()
        XCTAssertEqual(instructions(in: fixture).count, 2, "a rerun after that sends it anew")
        XCTAssertEqual(pendingInstructions(fixture, now: 20 + lifetime).count, 1)
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
        while pendingInstructions(fixture).isEmpty, Date() < deadline {
            fixture.center.drain()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pending = try XCTUnwrap(pendingInstructions(fixture).first)
        XCTAssertTrue(fixture.store.markInstructionTyped(eventID: pending.event.id))

        let status = await waiting.value
        XCTAssertEqual(status, 0)
    }

    /// Past the scalars Nirux types whole, the message is refused, and the
    /// refusal says so.
    func testAMessageOfManyScalarsSaysWhy() {
        let family = String(repeating: "👨‍👩‍👧", count: 2_000)
        XCTAssertTrue(family.count <= MissionEventCLI.maxInstructionLength && family.unicodeScalars.count > MissionEventCLI.maxScalars)
        XCTAssertTrue(MissionEventCLI.problem(with: family, limit: MissionEventCLI.maxInstructionLength)?.contains("Unicode scalars") == true)
        XCTAssertEqual(MissionEventCLI.problem(with: "", limit: 10), "message must hold 1 to 10 characters.")
        XCTAssertNil(MissionEventCLI.problem(with: "Go.", limit: 10))
    }

    /// A tell Nirux gave up ends the wait: a rerun would send it again.
    func testTellStopsOnceNiruxGaveItUp() async throws {
        let fixture = try makeFixture()
        let environment = parentEnvironment()
        let eventsURL = fixture.eventsURL
        let missionsURL = fixture.missionsURL
        let waiting = Task.detached {
            MissionEventCLI.tell(
                arguments: ["--branch", "feat/mission", "--message", "/premortem", "--timeout", "10"],
                environment: environment, eventsURL: eventsURL, missionsURL: missionsURL, pollInterval: 0.01
            )
        }
        try await waitUntil("the tell recorded", timeout: 5) {
            fixture.center.drain()
            return !pendingInstructions(fixture).isEmpty
        }
        let pending = try XCTUnwrap(pendingInstructions(fixture).first)
        XCTAssertTrue(fixture.store.noteInstructions(heldNotice: [], expired: [pending.event.id], at: Date().timeIntervalSince1970))
        let status = await waiting.value
        XCTAssertEqual(status, 4)
    }

    func testTellStopsForAnotherParentBranchOrAgent() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(tell("/code-review", branch: "feat/other", in: fixture), 4)
        XCTAssertEqual(tell("/code-review", in: fixture, agentUUID: otherAgentUUID), 4)
        XCTAssertTrue(try queuedEvents(in: fixture).isEmpty)

        let other = try makeFixture(childAgentKind: "gemini")
        XCTAssertEqual(tell("/code-review", in: other), 4, "Nirux delivers nothing to an agent it doesn't know")
        XCTAssertTrue(try queuedEvents(in: other).isEmpty)
        let agy = try makeFixture(childAgentKind: "agy")
        XCTAssertEqual(tell("/code-review", in: agy), 2, "agy runs a slash command itself, with no turn to end")
        XCTAssertEqual(tell("Review the diff.", in: agy), 3, "typed into Antigravity's prompt")
        XCTAssertEqual(tell("/Users/me/review.md: apply it.", in: agy), 3, "a path is no slash command")
        XCTAssertEqual(try queuedEvents(in: agy).map(\.kind), [.instruction, .instruction])
        XCTAssertEqual(NiruxShellView.resumedConversation(ofAgy: ["agy", "--conversation", "c1"]), "c1")
        XCTAssertEqual(NiruxShellView.resumedConversation(ofAgy: ["agy", "--conversation=c2"]), "c2")
        XCTAssertNil(NiruxShellView.resumedConversation(ofAgy: ["agy", "-i", "Go"]))
        let codex = try makeFixture(childAgentKind: "codex")
        XCTAssertEqual(tell("/code-review", in: codex), 3, "Codex takes it through its own queue")
        XCTAssertEqual(try queuedEvents(in: codex).map(\.kind), [.instruction])

        for arguments in [["--branch", "feat/mission"], ["--message", "Hi"],
                          ["--branch", "feat/mission", "--message", String(repeating: "x", count: MissionEventCLI.maxInstructionLength + 1)]] {
            XCTAssertEqual(MissionEventCLI.tell(
                arguments: arguments,
                environment: parentEnvironment(),
                eventsURL: fixture.eventsURL,
                missionsURL: fixture.missionsURL
            ), 2, "\(arguments)")
        }
        XCTAssertEqual(MissionEventCLI.main(["tell", "--message", "Hi"], handoffsEnabled: { false }, environment: [:]), 4)
    }

    // MARK: - Ledger

    func testTypingATellReopensACompletedMission() throws {
        let fixture = try makeFixture()
        complete(fixture)
        XCTAssertEqual(tell("/premortem", in: fixture), 3, "a follow-up after completion")
        fixture.center.drain()
        XCTAssertEqual(fixture.store.missions[0].status, .completed, "until the child gets it")

        let pending = try XCTUnwrap(pendingInstructions(fixture, now: 30).first)
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
            pollInterval: 0.01,
            confirmationTimeout: 0
        ), 3, "the child can ask again")
    }

    func testReceiveKeepsWaitingWhileATellMayReopenTheMission() throws {
        let fixture = try makeFixture()
        func receive() -> Int32 {
            MissionEventCLI.receive(
                arguments: ["--timeout", "0"],
                environment: parentEnvironment(),
                eventsURL: fixture.eventsURL,
                missionsURL: fixture.missionsURL,
                pollInterval: 0.01
            )
        }
        complete(fixture)
        XCTAssertEqual(receive(), 0, "prints the completion")
        fixture.center.drain()
        XCTAssertEqual(receive(), 4, "nothing left to wait for")

        let now = Date().timeIntervalSince1970
        XCTAssertEqual(tell("/premortem", in: fixture, at: now), 3)
        fixture.center.drain()
        XCTAssertEqual(receive(), 3, "the child gets more work once the message is typed")
    }

    /// A Lead's one-way Mission to a task of its space isn't one of its own
    /// to the CLI: `tell` by branch doesn't find it, `receive` doesn't wait
    /// on it.
    func testALeadsOneWayMissionIsNotItsOwnToTheCLI() throws {
        let fixture = try makeFixture()
        XCTAssertNotNil(fixture.store.create(MissionCreationRequest(
            id: "99999999-9999-4999-8999-999999999999", parentWorkspaceID: parentWorkspaceID, parentAgentUUID: parentAgentUUID,
            childWorkspaceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", childAgentUUID: otherAgentUUID, childAgentKind: "claude",
            branch: "feat/by-hand", oneWay: true
        ), enabled: false, now: 11))
        XCTAssertEqual(tell("Review: guard the race.", branch: "feat/by-hand", in: fixture), 4)
        func receive() -> Int32 {
            MissionEventCLI.receive(
                arguments: ["--timeout", "0"],
                environment: parentEnvironment(),
                eventsURL: fixture.eventsURL,
                missionsURL: fixture.missionsURL,
                pollInterval: 0.01
            )
        }
        complete(fixture)
        XCTAssertEqual(receive(), 0, "prints the completion")
        fixture.center.drain()
        XCTAssertEqual(receive(), 4, "nothing left to wait for")
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
        XCTAssertEqual(pendingInstructions(fixture, now: 30).count, 1)
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

    private func refusal(_ machine: AgentStatusMachine) -> AgentPromptRefusal? {
        machine.promptRefusal(foreground: claude(), runningSince: t0 + 100)
    }

    private func press(_ keys: String, at offset: TimeInterval, into machine: inout AgentStatusMachine) {
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + offset), keys: Data(keys.utf8))
    }

    private func prompt(_ id: String, at offset: TimeInterval, transcript: String? = nil) -> AgentHookEvent {
        AgentHookEvent(kind: .claude, name: .userPromptSubmit, sessionID: "lead", promptID: id, transcriptPath: transcript, timestamp: t0 + offset)
    }

    private func subagentDialog(at offset: TimeInterval, agent: String = "sub") -> AgentHookEvent {
        AgentHookEvent(
            kind: .claude, name: .permissionRequest, sessionID: "lead", toolName: "Bash", toolKey: agent, agentID: agent,
            timestamp: t0 + offset
        )
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

    /// A Codex child's message goes into Codex's own queue once the `codex`
    /// it was sent to says its turn is over (OSC 7501), keys at its prompt
    /// or not: nothing is typed.
    func testCodexTakesAMessageOnceItSaysItsTurnIsOver() {
        let codex = ForegroundProcess(instance: claudeProcess, name: "codex", arguments: ["codex", "Go"])
        var machine = AgentStatusMachine()
        func refusal(_ foreground: ForegroundProcess? = codex, since: TimeInterval = t0 + 100) -> AgentPromptRefusal? {
            machine.codexQueueRefusal(foreground: foreground, runningSince: since)
        }
        func report(_ state: AgentProgramStatus.State, kind: String? = nil, from process: ProcessInstance? = nil) {
            let status = AgentProgramStatus(state: state, kind: kind, message: nil, agent: .codex)
            machine.noteCodexStatus(status, from: process ?? claudeProcess, now: t0 + 50)
        }
        XCTAssertEqual(refusal(nil), .noClaude)
        XCTAssertEqual(refusal(ForegroundProcess(instance: claudeProcess, name: "codex", arguments: ["codex", "exec", "Go"])), .noClaude,
                       "a run, not a conversation")
        XCTAssertEqual(refusal(), .noPromptYet, "no state reported yet")
        report(.working)
        XCTAssertEqual(refusal(), .working)
        report(.blocked, kind: "permission")
        XCTAssertEqual(refusal(), .dialog)
        report(.error)
        XCTAssertEqual(refusal(), .failedTurn)
        report(.done)
        XCTAssertNil(refusal())
        XCTAssertEqual(refusal(since: claudeProcess.startedAt - 1), .restarted, "a codex started after the tell")
        report(.idle)
        XCTAssertNil(refusal(), "a key after its turn's end: its queue takes the message all the same")
        // Codex says each state once: a Ctrl-G editor or a ^Z shell in front keeps it.
        let editor = ProcessInstance(pid: 11, startedAt: t0 + 60)
        _ = machine.tick(fgName: "vim", isUserFocused: false, now: Date(timeIntervalSince1970: t0 + 60))
        machine.keepProgramStatus(of: editor)
        _ = machine.tick(fgName: "codex", isUserFocused: false, now: Date(timeIntervalSince1970: t0 + 61))
        machine.keepProgramStatus(of: claudeProcess)
        XCTAssertNil(refusal(), "its idle stays")
        report(.done, from: ProcessInstance(pid: 9, startedAt: t0))
        XCTAssertEqual(refusal(), .noPromptYet, "another codex's word")
        // Read on an empty process table: the codex in front then's.
        machine.noteCodexStatus(AgentProgramStatus(state: .done, kind: nil, message: nil, agent: .codex), from: nil, now: t0 + 70)
        XCTAssertNil(refusal(), "one already running")
        XCTAssertEqual(refusal(ForegroundProcess(instance: ProcessInstance(pid: 12, startedAt: t0 + 80), name: "codex", arguments: ["codex"])),
                       .noPromptYet, "not one started since")
    }

    /// An Antigravity child's prompt is free once its `agy` said its turn is
    /// done (OSC 7501) and no key reached the terminal since that turn began:
    /// agy 1.5.12 says idle at a key after done, but keeps one typed while it
    /// worked in its box, and still says done.
    func testAntigravityPromptIsFreeOnceItsTurnIsDoneWithNoKeySince() {
        let agy = ForegroundProcess(instance: claudeProcess, name: "agy", arguments: ["agy", "-i", "Go"])
        var machine = AgentStatusMachine()
        _ = machine.tick(fgName: "agy", isUserFocused: true, now: Date(timeIntervalSince1970: t0))
        func refusal(_ foreground: ForegroundProcess? = agy, since: TimeInterval = t0 + 100) -> AgentPromptRefusal? {
            machine.promptRefusal(foreground: foreground, runningSince: since, agent: .agy)
        }
        func report(_ state: AgentProgramStatus.State, kind: String? = nil, at offset: TimeInterval, from process: ProcessInstance? = nil) {
            _ = machine.noteProgramStatus(
                AgentProgramStatus(state: state, kind: kind, message: nil, agent: .agy), from: process ?? claudeProcess,
                isUserFocused: true, now: Date(timeIntervalSince1970: t0 + offset)
            )
        }
        XCTAssertEqual(refusal(ForegroundProcess(instance: claudeProcess, name: "agy", arguments: ["agy", "-p", "Go"])), .noClaude,
                       "a one-shot run")
        report(.idle, at: 1)
        XCTAssertEqual(refusal(), .noPromptYet, "ready, but no turn ended since it started")
        report(.working, at: 2)
        XCTAssertEqual(refusal(), .working)
        report(.blocked, kind: "permission", at: 3)
        XCTAssertEqual(refusal(), .dialog)
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 3.5), keys: Data("1".utf8))
        report(.working, at: 4)
        report(.done, at: 5)
        XCTAssertNil(refusal(), "the key that answered its dialog is no draft")
        XCTAssertEqual(refusal(since: claudeProcess.startedAt - 1), .restarted)
        XCTAssertEqual(machine.promptRefusal(foreground: agy, runningSince: t0 + 100), .noClaude, "text for Claude Code never goes into agy")
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 5.5), keys: Data("\u{1B}[5~".utf8))
        report(.idle, at: 5.5)
        XCTAssertNil(refusal(), "a key after its turn that leaves no text (Page Up)")
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 6))
        report(.idle, at: 6)
        XCTAssertEqual(refusal(), .draft, "a key after its turn")
        report(.working, at: 7)
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 8))
        report(.done, at: 9)
        XCTAssertEqual(refusal(), .draft, "a key typed while it worked stays in its box")
        report(.working, at: 10)
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 10.5))
        report(.blocked, kind: "permission", at: 10.6)
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 10.7), keys: Data("1".utf8))
        report(.working, at: 10.8)
        report(.done, at: 10.9)
        XCTAssertEqual(refusal(), .draft, "a key typed before a dialog stays: its turn began before it")
        report(.working, at: 11)
        report(.idle, at: 11.5)
        XCTAssertEqual(refusal(), .draft, "stopped with Esc: its box may hold its prompt again")
        report(.working, at: 11.6)
        report(.done, at: 11.7)
        XCTAssertNil(refusal())
        // A dialog answered with several keys: the heartbeat drops its status at the first.
        report(.working, at: 11.8)
        report(.blocked, kind: "question", at: 11.85)
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 11.86), keys: Data("\u{1B}[B".utf8))
        _ = machine.tick(fgName: "agy", isUserFocused: true, now: Date(timeIntervalSince1970: t0 + 11.87))
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 11.88), keys: Data("\r".utf8))
        report(.working, at: 11.9)
        report(.done, at: 11.95)
        XCTAssertNil(refusal(), "every key that answered its dialog")
        // ^Z then fg drops its status, not its turn.
        _ = machine.tick(fgName: "zsh", isUserFocused: true, now: Date(timeIntervalSince1970: t0 + 11.96))
        _ = machine.tick(fgName: "agy", isUserFocused: true, now: Date(timeIntervalSince1970: t0 + 11.97))
        XCTAssertNil(refusal(), "its turn ended done")
        report(.error, at: 12)
        XCTAssertEqual(refusal(), .failedTurn)
        report(.done, at: 13, from: ProcessInstance(pid: 9, startedAt: t0))
        XCTAssertEqual(refusal(ForegroundProcess(instance: ProcessInstance(pid: 9, startedAt: t0), name: "agy", arguments: ["agy"])),
                       .noPromptYet, "its own turn, not another agy's")

        func at(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: t0 + offset) }
        // Keys typed after the Enter that sent its prompt, before its working is read, stay in its box.
        machine.noteKeystroke(now: at(20), keys: Data("go".utf8))
        machine.noteKeystroke(now: at(20.1), keys: Data("\r".utf8))
        machine.noteKeystroke(now: at(20.12), keys: Data("x".utf8))
        report(.working, at: 20.2)
        report(.done, at: 21)
        XCTAssertEqual(refusal(), .draft, "a key after the Enter that sent its prompt")
        // Its dialog answered, text typed before it says it works again.
        report(.working, at: 22)
        report(.blocked, kind: "permission", at: 22.1)
        machine.noteKeystroke(now: at(22.2), keys: Data("\r".utf8))
        machine.noteKeystroke(now: at(22.3), keys: Data("y".utf8))
        report(.working, at: 22.4)
        report(.done, at: 23)
        XCTAssertEqual(refusal(), .draft, "text typed once its dialog was answered")
        // A turn whose end was missed (^Z and fg dropped its status): the next prompt starts a new one.
        report(.working, at: 24)
        _ = machine.tick(fgName: "zsh", isUserFocused: true, now: at(25))
        _ = machine.tick(fgName: "agy", isUserFocused: true, now: at(26))
        machine.noteKeystroke(now: at(86), keys: Data("next".utf8))
        machine.noteKeystroke(now: at(86.1), keys: Data("\r".utf8))
        report(.working, at: 86.2)
        report(.done, at: 87)
        XCTAssertNil(refusal(), "its prompt's own keys aren't a draft")
        report(.working, at: 88)
        report(.error, at: 89)
        machine.noteKeystroke(now: at(89.5), keys: Data("z".utf8))
        report(.idle, at: 89.6)
        XCTAssertEqual(refusal(), .failedTurn, "a failed turn says so, a key after it notwithstanding")

        // An agy that left with its dialog open: the keys of what runs next are drafts.
        var after = AgentStatusMachine()
        _ = after.tick(fgName: "agy", isUserFocused: true, now: Date(timeIntervalSince1970: t0))
        _ = after.noteProgramStatus(AgentProgramStatus(state: .working, kind: nil, message: nil, agent: .agy), from: claudeProcess,
                                    isUserFocused: true, now: Date(timeIntervalSince1970: t0 + 1))
        _ = after.noteProgramStatus(AgentProgramStatus(state: .blocked, kind: "permission", message: nil, agent: .agy), from: claudeProcess,
                                    isUserFocused: true, now: Date(timeIntervalSince1970: t0 + 2))
        _ = after.tick(fgName: "claude", isUserFocused: true, now: Date(timeIntervalSince1970: t0 + 3))
        after.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 4), keys: Data("x".utf8))
        XCTAssertTrue(after.hasDraft, "Claude Code's draft")
    }

    func testPromptIsFreeOnlyAtTheIdlePromptOfTheClaudeThatWasTold() {
        var machine = idleMachine()
        XCTAssertTrue(isFree(machine))
        XCTAssertEqual(machine.promptRefusal(foreground: nil, runningSince: t0 + 100), .noClaude)
        XCTAssertFalse(isFree(machine, foreground: ForegroundProcess(instance: claudeProcess, name: "zsh", arguments: [])))
        XCTAssertFalse(isFree(machine, foreground: claude(arguments: ["claude", "-p"])), "headless")
        XCTAssertEqual(machine.promptRefusal(foreground: claude(ProcessInstance(pid: 7, startedAt: t0 + 6)), runningSince: t0 + 100),
                       .noPromptYet, "a claude that took no prompt since it started")
        XCTAssertEqual(machine.promptRefusal(foreground: claude(), runningSince: claudeProcess.startedAt - 1), .restarted,
                       "a claude started after the tell, such as one restored after a relaunch")

        _ = machine.apply(hook(.userPromptSubmit, at: 6), isUserFocused: false)
        XCTAssertEqual(refusal(machine), .working)
        _ = machine.apply(hook(.permissionRequest, at: 7, tool: "Bash", key: "k"), isUserFocused: false)
        XCTAssertEqual(refusal(machine), .working, "a dialog mid-turn")
        _ = machine.apply(hook(.stop, at: 9), isUserFocused: false)
        XCTAssertTrue(isFree(machine))
        // A subagent's dialog outlives the turn.
        _ = machine.apply(hook(.userPromptSubmit, at: 10), isUserFocused: false)
        _ = machine.apply(AgentHookEvent(
            kind: .claude, name: .permissionRequest, sessionID: "lead", toolName: "Bash", toolKey: "s", agentID: "sub",
            timestamp: t0 + 11
        ), isUserFocused: false)
        _ = machine.apply(hook(.stop, at: 12), isUserFocused: false)
        XCTAssertEqual(refusal(machine), .dialog)
    }

    /// A message Claude takes in by itself (a peer's, a task notification)
    /// follows no key: a subagent's dialog stays listed through it, and no
    /// message is typed into that dialog once the turn ends. A prompt typed
    /// at the box closes the dialogs listed at its Enter (one denied with
    /// Esc fires no hook), not one raised since.
    func testOnlyAPromptTypedAtTheBoxClosesDialogs() {
        var machine = idleMachine()
        press("\r", at: 9.5, into: &machine)
        _ = machine.apply(hook(.userPromptSubmit, at: 10), isUserFocused: false)
        _ = machine.apply(subagentDialog(at: 11), isUserFocused: false)
        _ = machine.apply(hook(.userPromptSubmit, at: 12), isUserFocused: false)
        _ = machine.apply(hook(.stop, at: 13), isUserFocused: false)
        XCTAssertEqual(refusal(machine), .dialog)

        press("\u{1B}", at: 20, into: &machine)
        press("go on\r", at: 21, into: &machine)
        _ = machine.apply(subagentDialog(at: 21.5, agent: "other"), isUserFocused: false)
        _ = machine.apply(hook(.userPromptSubmit, at: 22), isUserFocused: false)
        XCTAssertEqual(machine.pendingDialogs.map(\.agentID), ["other"])
    }

    /// Keys typed during a turn stay in the box when Claude takes in a
    /// message by itself: a draft no message joins, until the Enter of a
    /// prompt typed there.
    func testAMessageClaudeTakesInLeavesTheDraft() {
        var machine = idleMachine()
        press("\r", at: 9.5, into: &machine)
        _ = machine.apply(hook(.userPromptSubmit, at: 10), isUserFocused: false)
        press("x", at: 11, into: &machine)
        press("\u{1B}\r", at: 11.5, into: &machine) // Option-Enter adds a line
        _ = machine.apply(hook(.userPromptSubmit, at: 12), isUserFocused: false)
        _ = machine.apply(hook(.stop, at: 13), isUserFocused: false)
        XCTAssertEqual(refusal(machine), .draft)
        press("\r", at: 20, into: &machine)
        _ = machine.apply(hook(.userPromptSubmit, at: 20.1), isUserFocused: false)
        _ = machine.apply(hook(.stop, at: 21), isUserFocused: false)
        XCTAssertNil(refusal(machine))
    }

    /// Read through its transcript (`readsTranscript`), a prompt was typed
    /// at the box only when its line says so. A peer's message never was,
    /// even right after a line added with backslash-Enter, and closes no
    /// dialog. A typed one was sent by the last Enter before its hook,
    /// however late that hook (Claude held the prompt) and whatever Enter
    /// came before it was applied, and closes the dialogs listed then. A
    /// prompt queued mid-turn records no `prompt_id`: its line goes with the
    /// oldest hook before it.
    func testTheTranscriptSaysWhichPromptWasTyped() {
        func readMachine() -> AgentStatusMachine {
            var machine = idleMachine()
            machine.readsTranscript = true
            return machine
        }
        func read(_ id: String?, at offset: TimeInterval, typed: Bool, into machine: inout AgentStatusMachine) {
            _ = machine.noteTranscriptPrompt(TranscriptPrompt(promptID: id, at: t0 + offset, typed: typed))
        }
        var machine = readMachine()
        press("fix it \\", at: 10, into: &machine)
        press("\r", at: 10.5, into: &machine)
        _ = machine.apply(prompt("peer", at: 11), isUserFocused: false)
        read("peer", at: 11.2, typed: false, into: &machine)
        _ = machine.apply(hook(.stop, at: 13), isUserFocused: false)
        XCTAssertEqual(refusal(machine), .draft)
        press("\r", at: 20, into: &machine)
        _ = machine.apply(prompt("held", at: 20 + AgentStatusMachine.promptHookDelay + 1), isUserFocused: false)
        read("held", at: 27, typed: true, into: &machine)
        _ = machine.apply(hook(.stop, at: 30), isUserFocused: false)
        XCTAssertNil(refusal(machine))

        // Its line read before its hook, a line added before that hook was applied.
        var early = readMachine()
        press("\r", at: 40, into: &early)
        press("more \\", at: 40.3, into: &early)
        press("\r", at: 40.4, into: &early)
        read("early", at: 40.2, typed: true, into: &early)
        _ = early.apply(prompt("early", at: 40.1), isUserFocused: false)
        _ = early.apply(hook(.stop, at: 41), isUserFocused: false)
        XCTAssertEqual(early.boxEmptiedAt, t0 + 40)
        XCTAssertEqual(refusal(early), .draft)

        var queued = readMachine()
        press("\r", at: 50, into: &queued)
        _ = queued.apply(prompt("queued", at: 50.1), isUserFocused: false)
        read(nil, at: 55, typed: true, into: &queued)
        XCTAssertEqual(queued.boxEmptiedAt, t0 + 50)

        var dialogs = readMachine()
        _ = dialogs.apply(subagentDialog(at: 60), isUserFocused: false)
        _ = dialogs.apply(prompt("peer", at: 61), isUserFocused: false)
        read("peer", at: 61.1, typed: false, into: &dialogs)
        press("\u{1B}", at: 62, into: &dialogs)
        press("go on\r", at: 63, into: &dialogs)
        _ = dialogs.apply(prompt("typed", at: 63.1), isUserFocused: false)
        XCTAssertEqual(dialogs.pendingDialogs.count, 1, "until its line says it was typed")
        read("typed", at: 63.2, typed: true, into: &dialogs)
        XCTAssertEqual(dialogs.pendingDialogs.count, 0)
    }

    /// A column follows the transcript its own `claude` names in its hooks,
    /// and reads it before saying whether keys wait in the prompt.
    func testTheColumnReadsWhoSentEachPromptInItsTranscript() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-prompts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("lead.jsonl")
        try Data().write(to: transcript)
        let pty = PtySession()
        func record(_ id: String, origin: String) throws {
            let time = Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            let handle = try FileHandle(forWritingTo: transcript)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((#"{"type":"user","origin":{"kind":""# + origin + #""},"promptId":""# + id
                + #"","timestamp":""# + time + #"","message":{"role":"user","content":"…"}}"# + "\n").utf8))
        }
        func submit(_ id: String) {
            pty.applyAgentHook(AgentHookEvent(
                kind: .claude, name: .userPromptSubmit, sessionID: "lead", promptID: id, transcriptPath: transcript.path,
                timestamp: Date().timeIntervalSince1970
            ), isUserFocused: false)
        }
        pty.sendRaw("fix it \\")
        pty.sendRaw("\r")
        submit("peer")
        try record("peer", origin: "peer")
        XCTAssertTrue(pty.hasPromptDraft)
        pty.sendRaw("\r")
        submit("typed")
        try record("typed", origin: "human")
        XCTAssertFalse(pty.hasPromptDraft)
    }

    /// A column says when the user typed a prompt to its agent, with that
    /// prompt's time: at its hook without a transcript, once its line is
    /// read with one. Never for one Nirux typed, nor one Claude took in by
    /// itself.
    func testTheColumnSaysWhenTheUserTypedAPrompt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-typed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("task.jsonl")
        try Data().write(to: transcript)
        let pty = PtySession()
        var typed: [TimeInterval] = []
        pty.onUserPrompt = { typed.append($0) }
        func submit(_ id: String? = nil, transcript: URL? = nil) -> TimeInterval {
            let at = Date().timeIntervalSince1970
            _ = pty.applyAgentHook(AgentHookEvent(
                kind: .claude, name: .userPromptSubmit, sessionID: "s", promptID: id, transcriptPath: transcript?.path, timestamp: at
            ), isUserFocused: false)
            return at
        }
        func record(_ id: String, origin: String) throws {
            let time = Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            let handle = try FileHandle(forWritingTo: transcript)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((#"{"type":"user","origin":{"kind":""# + origin + #""},"promptId":""# + id
                + #"","timestamp":""# + time + #"","message":{"role":"user","content":"…"}}"# + "\n").utf8))
        }
        _ = submit()
        XCTAssertEqual(typed, [], "no Enter sent it")
        pty.sendRaw(": tell\r", typedByNirux: true)
        _ = submit()
        XCTAssertEqual(typed, [], "Nirux typed it")
        pty.sendRaw(": go\r")
        let first = submit()
        XCTAssertEqual(typed, [first])

        _ = submit("peer", transcript: transcript)
        try record("peer", origin: "peer")
        pty.readTranscriptPrompts()
        XCTAssertEqual(typed, [first], "a peer's message")
        pty.sendRaw("\r")
        let second = submit("typed", transcript: transcript)
        XCTAssertEqual(typed, [first], "until its line says so")
        try record("typed", origin: "human")
        pty.readTranscriptPrompts()
        XCTAssertEqual(typed, [first, second])
    }

    /// Without a transcript, an Enter stands for the prompt whose hook
    /// follows it within moments: Claude runs the hook as the box sends. An
    /// older one sent nothing (a line added after a backslash), one that
    /// reached a dialog whose hook came after it answered that dialog, and a
    /// prompt Claude Code says came from elsewhere took none.
    func testAnEnterSendsOnlyThePromptItsHookFollows() {
        func afterAnEnter(source: String? = nil, hookAfter delay: TimeInterval) -> AgentStatusMachine {
            var machine = idleMachine()
            press("fix it", at: 10, into: &machine)
            press("\r", at: 10.5, into: &machine)
            _ = machine.apply(hook(.userPromptSubmit, at: 10.5 + delay, source: source), isUserFocused: false)
            _ = machine.apply(hook(.stop, at: 20), isUserFocused: false)
            return machine
        }
        XCTAssertNil(refusal(afterAnEnter(hookAfter: 0.5)))
        XCTAssertEqual(refusal(afterAnEnter(hookAfter: AgentStatusMachine.promptHookDelay)), .draft)
        XCTAssertEqual(refusal(afterAnEnter(source: "system", hookAfter: 0.5)), .draft)

        var answered = idleMachine()
        press("\r", at: 30.2, into: &answered)
        _ = answered.apply(subagentDialog(at: 30), isUserFocused: false)
        _ = answered.apply(hook(.userPromptSubmit, at: 31), isUserFocused: false)
        _ = answered.apply(hook(.stop, at: 32), isUserFocused: false)
        XCTAssertEqual(refusal(answered), .dialog)
    }

    /// A claude launched at the shell took no key since it started: what the
    /// shell got is no draft, its prompt given as an argument went in with
    /// no key, and what was typed into it since is a draft. Resumed in a new
    /// process too, but not by a `/resume` inside it, which may show a
    /// screen no hook reports (an offer to resume from a summary).
    func testAClaudeStartsWithAnEmptyBox() {
        func launched(_ command: String, source: String, by process: ProcessInstance?) -> AgentStatusMachine {
            var machine = AgentStatusMachine()
            press(command, at: 0, into: &machine)
            _ = machine.tick(fgName: "claude", isUserFocused: false, now: Date(timeIntervalSince1970: t0 + 0.5))
            _ = machine.apply(AgentHookEvent(
                kind: .claude, name: .sessionStart, sessionID: "lead", emitterProcess: process, source: source, timestamp: t0 + 1
            ), isUserFocused: false)
            _ = machine.apply(hook(.userPromptSubmit, at: 2), isUserFocused: false)
            _ = machine.apply(hook(.stop, at: 5), isUserFocused: false)
            return machine
        }
        XCTAssertEqual(refusal(launched("claude\n", source: "startup", by: nil)), .draft, "nothing names its process")
        var started = launched("claude \"Read .claude-handover.md\"\n", source: "startup", by: ProcessInstance(pid: 7, startedAt: t0 + 0.01))
        XCTAssertNil(refusal(started))
        press("y", at: 6, into: &started)
        _ = started.apply(hook(.userPromptSubmit, at: 7), isUserFocused: false)
        _ = started.apply(hook(.stop, at: 8), isUserFocused: false)
        XCTAssertEqual(refusal(started), .draft)
        XCTAssertNil(refusal(launched("claude --resume 1234\n", source: "resume", by: ProcessInstance(pid: 7, startedAt: t0 + 0.01))))

        var resumed = idleMachine()
        press("/resume\r", at: 10, into: &resumed)
        press("\r", at: 11, into: &resumed)
        _ = resumed.apply(AgentHookEvent(
            kind: .claude, name: .sessionStart, sessionID: "lead", emitterProcess: claudeProcess, source: "resume", timestamp: t0 + 12
        ), isUserFocused: false)
        XCTAssertEqual(refusal(resumed), .draft)
    }

    /// A `claude` that took no prompt since it started, as one Nirux resumed
    /// at a relaunch, is free once its REPL says it sits idle at its prompt,
    /// while nothing works or waits there and no key reached its terminal;
    /// without that word, never.
    func testAClaudeThatTookNoPromptIsFreeOnlyOnItsREPLsWord() {
        let resumed = ProcessInstance(pid: 7, startedAt: t0 + 6)
        func refusal(_ machine: AgentStatusMachine, idle: Bool = true) -> AgentPromptRefusal? {
            machine.promptRefusal(foreground: claude(resumed), runningSince: t0 + 100) { $0 == resumed && idle }
        }
        // Without Nirux's hooks from it, nothing would say a message went in:
        // never, and keys say nothing of a draft.
        var hookless = AgentStatusMachine()
        XCTAssertEqual(refusal(hookless), .noPromptYet)
        hookless.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 8), keys: Data("x".utf8))
        XCTAssertEqual(refusal(hookless), .noPromptYet, "not held by a draft")
        var earlier = AgentStatusMachine()
        _ = earlier.apply(hook(.sessionStart, at: 5), isUserFocused: false)
        XCTAssertEqual(refusal(earlier), .noPromptYet, "an earlier claude's hooks")

        var machine = AgentStatusMachine()
        _ = machine.apply(hook(.sessionStart, at: 7, source: "resume"), isUserFocused: false)
        XCTAssertEqual(refusal(machine, idle: false), .noPromptYet)
        XCTAssertNil(refusal(machine))

        var typed = machine
        typed.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 8), keys: Data("x".utf8))
        XCTAssertEqual(refusal(typed), .draft, "typed since it started")
        var early = machine
        early.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 5), keys: Data("x".utf8))
        XCTAssertEqual(refusal(early), .noPromptYet, "typed while its shell loaded: seeded into its prompt")
        var scrolled = machine
        scrolled.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 8), keys: Data("\u{1B}[6~".utf8))
        XCTAssertEqual(refusal(scrolled), .noPromptYet, "a key that leaves no draft, as one that answers a screen")
        var recalled = machine
        recalled.notePromptRecall(now: Date(timeIntervalSince1970: t0 + 8))
        XCTAssertEqual(refusal(recalled), .draft, "an old prompt a wheel scroll recalled")
        // A background agent it resumed works, then asks past the turn.
        var working = machine
        _ = working.apply(hook(.preToolUse, at: 8, tool: "Bash"), isUserFocused: false)
        XCTAssertEqual(refusal(working), .noPromptYet)
        var asking = machine
        _ = asking.apply(AgentHookEvent(
            kind: .claude, name: .permissionRequest, sessionID: "lead", toolName: "Bash", toolKey: "s", agentID: "sub",
            timestamp: t0 + 8
        ), isUserFocused: false)
        _ = asking.apply(hook(.stop, at: 9), isUserFocused: false)
        XCTAssertEqual(refusal(asking), .noPromptYet, "its dialog outlives the turn")
        var failed = machine
        _ = failed.apply(AgentHookEvent(
            kind: .claude, name: .stopFailure, sessionID: "lead", errorKind: "rate_limit", timestamp: t0 + 8
        ), isUserFocused: false)
        XCTAssertEqual(refusal(failed), .noPromptYet, "a usage limit would fail what it is sent")

        // The user, who saw its screen, says it sits at its prompt: keys that
        // leave no text don't hold it, nor an Enter that answered a screen;
        // text that may sit in its prompt and the rest still do.
        func seen(_ machine: AgentStatusMachine, idle: Bool = true) -> AgentPromptRefusal? {
            machine.promptRefusal(foreground: claude(resumed), runningSince: t0 + 100, seenByUser: true) { $0 == resumed && idle }
        }
        var answered = machine
        answered.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 8), keys: Data("\u{1B}[B".utf8))
        answered.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 9), keys: Data("\r".utf8))
        XCTAssertEqual(refusal(answered), .draft)
        XCTAssertNil(seen(answered))
        XCTAssertNil(seen(scrolled))
        var completed = machine
        completed.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 8), keys: Data("@".utf8))
        completed.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 9), keys: Data("\r".utf8))
        XCTAssertEqual(seen(completed), .draft, "an Enter that took an @file completion: its text stays")
        var suggested = machine
        suggested.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 8), keys: Data("\u{1B}[C".utf8))
        XCTAssertEqual(seen(suggested), .draft, "Right takes in a suggested prompt")
        var givenBack = machine
        givenBack.notePromptGivenBack(now: t0 + 8)
        XCTAssertEqual(seen(givenBack), .draft, "a prompt Esc gave back to its box")
        XCTAssertEqual(seen(typed), .draft, "text in its prompt")
        XCTAssertNil(seen(early), "keys before it started, Nirux's launch line too: what they left, the user sees")
        XCTAssertEqual(seen(recalled), .draft, "an old prompt in its box")
        XCTAssertEqual(seen(answered, idle: false), .noPromptYet, "its record says a screen of its own is up")
        XCTAssertEqual(seen(asking), .noPromptYet)
        XCTAssertEqual(seen(working), .noPromptYet)
    }

    /// A dialog takes the keys while it waits for one, a paste too: none is a
    /// draft at the prompt, nor becomes one when it closes, and once its turn
    /// is over a message goes in. A question waits until its submit; an
    /// approval or a plan until Enter, Esc, Ctrl-C or a number answers it. A
    /// wheel scroll's arrows move among its options. Once it is answered, a
    /// key may be a draft.
    func testPromptIsFreeAfterADialogAnsweredWithItsKeys() {
        let down = "\u{1B}[B", up = "\u{1B}[A", esc = "\u{1B}"
        func dialog(_ tool: String, keys: [String], scrolls: Bool = false) -> AgentStatusMachine {
            var machine = idleMachine()
            _ = machine.apply(hook(.userPromptSubmit, at: 10), isUserFocused: false)
            _ = machine.apply(hook(.preToolUse, at: 15, tool: tool), isUserFocused: false)
            _ = machine.apply(hook(.permissionRequest, at: 15, tool: tool, key: "k"), isUserFocused: false)
            _ = machine.apply(AgentHookEvent(
                kind: .claude, name: .notification, sessionID: "lead", notificationType: "permission_prompt", timestamp: t0 + 21
            ), isUserFocused: false)
            if scrolls { machine.notePromptRecall(now: Date(timeIntervalSince1970: t0 + 25)) }
            for (index, key) in keys.enumerated() {
                machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 30 + Double(index)), keys: Data(key.utf8))
            }
            _ = machine.apply(hook(.postToolUse, at: 50, tool: tool, key: "k"), isUserFocused: false)
            _ = machine.apply(hook(.stop, at: 60), isUserFocused: false)
            return machine
        }
        // Two questions: an option for the first, two for the second, sent.
        XCTAssertNil(refusal(dialog("AskUserQuestion", keys: [down, "\r", down, " ", down, " ", "\t", "\r"])))
        XCTAssertNil(refusal(dialog("Bash", keys: [down, "\r"])))
        XCTAssertNil(refusal(dialog("ExitPlanMode", keys: [down, down, up, "\r"])))
        XCTAssertNil(refusal(dialog("Bash", keys: ["2"])), "an option's number")
        XCTAssertNil(refusal(dialog("Bash", keys: ["n", "2"])), "a letter out of habit, then the number")
        XCTAssertNil(refusal(dialog("Bash", keys: [down, down, "\t", "u", "s", "e", " ", "r", "g", "\u{7F}", "\r"])), "why not")
        XCTAssertNil(refusal(dialog("Bash", keys: [down, "\u{1B}[200~/tmp/x\u{1B}[201~", "\r"])), "a paste, which an approval drops")
        XCTAssertNil(refusal(dialog("Bash", keys: [down, down])), "answered with a click")
        XCTAssertNil(refusal(dialog("Bash", keys: [down, down, esc])), "denied with Esc after moving")
        XCTAssertNil(refusal(dialog("AskUserQuestion", keys: [down, "\u{1B}[200~yes\u{1B}[201~", "\r"])), "a paste in a question's text")
        XCTAssertNil(refusal(dialog("AskUserQuestion", keys: ["\r"], scrolls: true)), "a wheel scroll in the dialog")
        XCTAssertNil(refusal(dialog("Bash", keys: [], scrolls: true)))

        XCTAssertEqual(refusal(dialog("Bash", keys: [down, "\r", "x"])), .draft, "typed while the approved call ran")
        XCTAssertEqual(refusal(dialog("Bash", keys: [down, "\t", "v", "2", "x", "\r"])), .draft,
                       "known limit: a number in an amendment reads as the answer")
        var typedAfter = dialog("Bash", keys: [down, "\r"])
        typedAfter.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 70), keys: Data("x".utf8))
        XCTAssertEqual(refusal(typedAfter), .draft, "typed once it closed")
        XCTAssertEqual(refusal(dialog("Bash", keys: [down, esc, "x"])), .draft, "typed once Esc ended it")
        var scrolled = dialog("Bash", keys: ["\r"])
        scrolled.notePromptRecall(now: Date(timeIntervalSince1970: t0 + 70))
        XCTAssertEqual(refusal(scrolled), .draft, "at the prompt, Up recalls an old one")
    }

    /// Keys that move the view or the cursor leave the prompt as it was:
    /// reading the reply with Page Up and Down (Claude Code scrolls its
    /// conversation) keeps no message out. Up recalls an old prompt; Right
    /// and End may take in a suggested one.
    func testPromptStaysFreeWhileTheUserScrollsItsConversation() {
        var machine = idleMachine()
        let reading = ["\u{1B}[5~", "\u{1B}[6~", "\u{1B}[5;2~", "\u{1B}[1;5H", "\u{1B}[1;5F", "\u{1B}[H", "\u{1B}OH",
                       "\u{1B}[1;2D", "\u{1B}[1;5D", "\u{1B}b", "\u{1B}[Z"]
        for (index, key) in reading.enumerated() {
            machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 10 + Double(index)), keys: Data(key.utf8))
        }
        XCTAssertTrue(isFree(machine))
        XCTAssertTrue(machine.promptFacts(now: t0 + 100).contains(" draft=- "), machine.promptFacts(now: t0 + 100))
        // Left alone opens the agents view from an empty prompt, Shift-Down a
        // finished task's view.
        for key in ["\u{1B}[A", "\u{1B}[C", "\u{1B}[F", "\u{1B}f", "\u{1B}[1;5A", "\u{1B}[3~", "\u{1B}[D", "\u{1B}OD",
                    "\u{1B}[1;2A", "\u{1B}[1;2B"] {
            var moved = idleMachine()
            moved.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 10), keys: Data(key.utf8))
            XCTAssertEqual(refusal(moved), .draft, key.debugDescription)
        }
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 30), keys: Data("\u{1B}[A".utf8))
        XCTAssertTrue(machine.promptFacts(now: t0 + 100).contains(" draft=upDown/70s "), machine.promptFacts(now: t0 + 100))
    }

    func testPromptIsNotFreeOverADraftOrTextNotSubmittedYet() {
        var machine = idleMachine()
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 7))
        XCTAssertFalse(isFree(machine), "the user's draft, or a tell not yet submitted")
        _ = machine.apply(hook(.userPromptSubmit, at: 8), isUserFocused: false)
        _ = machine.apply(hook(.stop, at: 9), isUserFocused: false)
        XCTAssertTrue(isFree(machine))
    }

    /// Enter adds no draft while a turn is in flight and no dialog waits: an
    /// empty prompt queues nothing then (a second Return a second after the
    /// Lead's prompt once kept a question out for hours). At an idle prompt
    /// it may run text Nirux never saw: a draft, as Backspace is.
    func testEnterAloneMidTurnIsNoDraft() {
        let enter = Data([0x0D])
        func at(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: t0 + offset) }
        var machine = idleMachine()
        _ = machine.apply(hook(.userPromptSubmit, at: 10), isUserFocused: false)
        machine.noteKeystroke(now: at(11), keys: enter)
        _ = machine.apply(hook(.stop, at: 20), isUserFocused: false)
        XCTAssertTrue(isFree(machine), machine.promptFacts(now: t0 + 100))
        XCTAssertTrue(machine.promptFacts(now: t0 + 100).contains(" draft=- input=89s "), machine.promptFacts(now: t0 + 100))

        for (key, name) in [(enter, "Enter"), (Data([0x7F]), "Backspace")] {
            var idle = idleMachine()
            idle.noteKeystroke(now: at(30), keys: key)
            XCTAssertEqual(refusal(idle), .draft, "\(name) at an idle prompt")
        }
        var background = idleMachine()
        _ = background.apply(AgentHookEvent(
            kind: .claude, name: .preToolUse, sessionID: "lead", toolName: "Bash", agentID: "sub", timestamp: t0 + 25
        ), isUserFocused: false)
        background.noteKeystroke(now: at(30), keys: enter)
        XCTAssertTrue(background.hasDraft, "a background subagent at work after the Stop: the prompt is idle")

        var approval = idleMachine()
        _ = approval.apply(hook(.userPromptSubmit, at: 10), isUserFocused: false)
        _ = approval.apply(hook(.permissionRequest, at: 15, tool: "Bash", key: "k"), isUserFocused: false)
        approval.noteKeystroke(now: at(20), keys: enter)
        XCTAssertNil(approval.visibleDialog(foreground: claude()), "Enter answers an approval")
        approval.noteKeystroke(now: at(21), keys: enter)
        _ = approval.apply(hook(.postToolUse, at: 25, tool: "Bash", key: "k"), isUserFocused: false)
        _ = approval.apply(hook(.stop, at: 30), isUserFocused: false)
        XCTAssertTrue(isFree(approval), "nor is a second Enter while its tool runs")
    }

    /// `/clear` fires SessionStart, not UserPromptSubmit: the text went in.
    func testClearEmptiesThePrompt() {
        var machine = idleMachine()
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 7)) // "/clear" typed by a tell
        _ = machine.apply(hook(.sessionStart, at: 8, source: "clear"), isUserFocused: false)
        XCTAssertTrue(isFree(machine))
    }

    /// A failed turn (a usage limit) would fail every message typed after
    /// it, one after the other: the prompt stays busy until one goes in.
    func testAFailedTurnKeepsThePromptBusy() {
        var machine = idleMachine()
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 5.5))
        _ = machine.apply(hook(.userPromptSubmit, at: 6), isUserFocused: false)
        _ = machine.apply(hook(.stopFailure, at: 7), isUserFocused: false)
        XCTAssertNotNil(machine.turnFailure)
        XCTAssertFalse(isFree(machine))
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 8))
        _ = machine.apply(hook(.userPromptSubmit, at: 9), isUserFocused: false)
        _ = machine.apply(hook(.stop, at: 10), isUserFocused: false)
        XCTAssertTrue(isFree(machine))
    }

    /// A question typed into the parent: its turn took it and ended, so the
    /// parent didn't answer. Not while the turn runs, nor before it went in.
    func testATurnThatTookAMessageAndEndedIsSeen() {
        var machine = idleMachine()
        // Recorded once its Enter went out.
        let typedAt = t0 + 6.01
        XCTAssertFalse(machine.finishedTurn(afterTypingAt: typedAt), "not typed in yet")
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 6))
        _ = machine.apply(hook(.userPromptSubmit, at: 6.5), isUserFocused: false)
        XCTAssertFalse(machine.finishedTurn(afterTypingAt: typedAt), "working on it")
        _ = machine.apply(hook(.stop, at: 9), isUserFocused: false)
        XCTAssertTrue(machine.finishedTurn(afterTypingAt: typedAt))

        // Left in the prompt, its Enter refused: a message Claude took in by
        // itself since is not that one.
        var left = idleMachine()
        press("\u{1B}[200~Keep date=?\u{1B}[201~", at: 6, into: &left)
        _ = left.apply(hook(.userPromptSubmit, at: 6.5), isUserFocused: false)
        _ = left.apply(hook(.stop, at: 9), isUserFocused: false)
        XCTAssertFalse(left.finishedTurn(afterTypingAt: typedAt))
    }

    /// Who typed the last prompt: Nirux when it pressed its Enter (a paste
    /// and its Enter in one write, or the Enter after a long paste), the
    /// user at the box, or elsewhere (Remote Control) when the transcript
    /// says a person typed one with no Enter at the box. Nobody before any:
    /// the first prompt given at launch, though its line says a person
    /// typed it, and Claude's own messages.
    func testWhoTypedTheLastPrompt() {
        var machine = AgentStatusMachine()
        _ = machine.tick(fgName: "claude", isUserFocused: false, now: Date(timeIntervalSince1970: t0))
        _ = machine.apply(hook(.sessionStart, at: 0), isUserFocused: false)
        machine.readsTranscript = true
        // Its transcript says a person typed it, as Claude Code writes a
        // prompt given at launch.
        _ = machine.apply(prompt("handover", at: 1), isUserFocused: false)
        _ = machine.noteTranscriptPrompt(TranscriptPrompt(promptID: "handover", at: t0 + 1.1, typed: true))
        _ = machine.apply(hook(.stop, at: 5), isUserFocused: false)
        XCTAssertEqual(machine.lastPromptTyper, .nobody, "its handover came with its launch")
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 6), keys: Data("\u{1B}[200~Go on\u{1B}[201~\r".utf8), byNirux: true)
        _ = machine.apply(prompt("tell", at: 6.5), isUserFocused: false)
        _ = machine.noteTranscriptPrompt(TranscriptPrompt(promptID: "tell", at: t0 + 6.6, typed: true))
        _ = machine.apply(hook(.stop, at: 7), isUserFocused: false)
        XCTAssertEqual(machine.lastPromptTyper, .nirux)
        _ = machine.apply(prompt("peer", at: 7.5), isUserFocused: false)
        _ = machine.noteTranscriptPrompt(TranscriptPrompt(promptID: "peer", at: t0 + 7.6, typed: false))
        XCTAssertEqual(machine.lastPromptTyper, .nirux, "a peer's message")
        press("which one?\r", at: 8, into: &machine)
        _ = machine.apply(prompt("typed", at: 8.2), isUserFocused: false)
        _ = machine.noteTranscriptPrompt(TranscriptPrompt(promptID: "typed", at: t0 + 8.3, typed: true))
        XCTAssertEqual(machine.lastPromptTyper, .user)
        press("\u{1B}[200~Rebase on main\u{1B}[201~", at: 10, into: &machine)
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 10.5), keys: Data("\r".utf8), byNirux: true)
        _ = machine.apply(prompt("long", at: 10.6), isUserFocused: false)
        _ = machine.noteTranscriptPrompt(TranscriptPrompt(promptID: "long", at: t0 + 10.7, typed: true))
        XCTAssertEqual(machine.lastPromptTyper, .nirux, "Nirux's Enter after its paste")
        _ = machine.apply(prompt("phone", at: 12), isUserFocused: false)
        _ = machine.noteTranscriptPrompt(TranscriptPrompt(promptID: "phone", at: t0 + 12.1, typed: true))
        XCTAssertEqual(machine.lastPromptTyper, .user, "typed elsewhere")
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
