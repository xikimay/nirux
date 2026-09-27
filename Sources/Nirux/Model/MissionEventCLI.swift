import CryptoKit
import Foundation

/// Filesystem mailbox CLI used by both sides of a Mission. Commands append
/// events to the app-owned queue; wait commands only read the atomically
/// written mission ledger, so no CLI process races the app for state writes.
enum MissionEventCLI {
    static let maxMessageLength = 500
    /// Agent shell tools stop foreground commands after a few minutes (two
    /// by default in Claude Code), so a wait ends on its own well before that
    /// and the agent runs the same command again to keep waiting.
    static let defaultWaitTimeout: TimeInterval = 90
    /// Upper bound of the wait-loop backoff while the ledger is unchanged.
    static let maxPollInterval: TimeInterval = 1

    private struct ChildContext {
        let missionID: String
        let workspaceID: String
        let agentUUID: String
    }

    private struct ParentContext {
        let workspaceID: String
        let agentUUID: String
    }

    private struct InboxMessage: Encodable {
        let eventID: String
        let missionID: String
        let kind: String
        let branch: String
        let message: String
    }

    static func run(
        kind: MissionEvent.Kind,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: TimeInterval = Date().timeIntervalSince1970,
        eventsURL: URL = MissionEventCenter.defaultEventsURL
    ) -> Int32 {
        guard kind == .question || kind == .completed,
              let context = childContext(environment),
              let options = parseOptions(arguments, allowed: ["--message"]),
              let message = validMessage(options["--message"])
        else { return 2 }

        let event = MissionEvent(
            id: UUID().uuidString,
            missionID: context.missionID,
            childWorkspaceID: context.workspaceID,
            childAgentUUID: context.agentUUID,
            kind: kind,
            message: message,
            timestamp: now
        )
        return append(event, to: eventsURL) ? 0 : 1
    }

    /// Emit a correlated question and wait until a response is persisted.
    /// The child opted into waiting by invoking this command, so no PTY
    /// injection or heuristic idle detection is involved. Running the same
    /// command again after a timeout resumes the same question.
    static func ask(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: () -> TimeInterval = { Date().timeIntervalSince1970 },
        eventsURL: URL = MissionEventCenter.defaultEventsURL,
        missionsURL: URL = MissionStore.defaultFileURL,
        pollInterval: TimeInterval = 0.2,
        confirmationTimeout: TimeInterval = 5,
        output: (String) -> Void = writeStandardOutput
    ) -> Int32 {
        guard let context = childContext(environment),
              let options = parseOptions(arguments, allowed: ["--message", "--timeout"]),
              let message = validMessage(options["--message"]),
              let timeout = validTimeout(options["--timeout"])
        else { return 2 }

        var ledger = MissionLedgerReader(url: missionsURL)
        ledger.refresh()
        guard let mission = ledger.missions.first(where: { $0.id == context.missionID }),
              mission.status == .active
        else {
            writeStandardError("This Mission is not active; there is no parent to ask.")
            return 1
        }
        let questionID = questionID(for: message, context: context, in: mission)
        if !mission.events.contains(where: { $0.id == questionID }) {
            let question = MissionEvent(
                id: questionID,
                missionID: context.missionID,
                childWorkspaceID: context.workspaceID,
                childAgentUUID: context.agentUUID,
                kind: .question,
                message: message,
                timestamp: now()
            )
            guard append(question, to: eventsURL) else { return 1 }
        }

        let outcome = waitForLedger(
            &ledger, timeout: timeout, pollInterval: pollInterval
        ) { missions -> AskOutcome? in
            guard let mission = missions.first(where: { $0.id == context.missionID }) else {
                return nil
            }
            if let response = mission.events.first(where: {
                $0.kind == .response && $0.inReplyTo == questionID
            }) {
                return .answered(response)
            }
            return mission.status == .active ? nil : .missionInactive
        }
        switch outcome {
        case let .answered(response):
            output(response.message)
            acknowledge(
                response,
                ledger: &ledger,
                timestamp: now(),
                eventsURL: eventsURL,
                confirmationTimeout: confirmationTimeout
            )
            return 0
        case .missionInactive:
            writeStandardError("This Mission completed before the question was answered.")
            return 1
        case nil:
            writeStandardError(
                "No Mission response yet. Run the same command again to keep waiting; "
                    + "it resumes this question instead of asking it twice."
            )
            return 3
        }
    }

    private enum AskOutcome {
        case answered(MissionEvent)
        case missionInactive
    }

    /// Identical questions share a derived ID, so a retry after a shell-tool
    /// timeout never queues a duplicate. Every answer the child has already
    /// printed for that text moves the next identical question to a new ID.
    private static func questionID(
        for message: String, context: ChildContext, in mission: Mission
    ) -> String {
        let received = Set(mission.events.compactMap { event in
            event.kind == .response && event.childConsumedAt != nil ? event.inReplyTo : nil
        })
        let generation = mission.events.filter { event in
            event.kind == .question && event.message == message && received.contains(event.id)
        }.count
        return derivedEventID([
            "nirux.mission.question",
            context.missionID,
            context.workspaceID,
            context.agentUUID,
            String(generation),
            message
        ])
    }

    /// RFC 9562 version 8 UUID from a SHA-256 digest. Only the last
    /// component may contain newlines, so the joined input is unambiguous.
    private static func derivedEventID(_ components: [String]) -> String {
        var bytes = Array(SHA256.hash(data: Data(components.joined(separator: "\n").utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return (NSUUID(uuidBytes: bytes) as UUID).uuidString
    }

    /// Record that the child agent received this response, and briefly wait
    /// for Nirux to persist it so an immediate identical question gets a new
    /// ID. The answer was already printed, so failures are only reported.
    private static func acknowledge(
        _ response: MissionEvent,
        ledger: inout MissionLedgerReader,
        timestamp: TimeInterval,
        eventsURL: URL,
        confirmationTimeout: TimeInterval
    ) {
        let acknowledgement = MissionEvent(
            id: UUID().uuidString,
            missionID: response.missionID,
            childWorkspaceID: response.childWorkspaceID,
            childAgentUUID: response.childAgentUUID,
            kind: .acknowledged,
            message: "acknowledged",
            inReplyTo: response.id,
            timestamp: timestamp
        )
        guard append(acknowledgement, to: eventsURL) else {
            writeStandardError("The answer could not be marked as received.")
            return
        }
        guard confirmationTimeout > 0 else { return }
        _ = waitForLedger(&ledger, timeout: confirmationTimeout, pollInterval: 0.05) { missions in
            missions.lazy.flatMap(\.events).contains(where: {
                $0.id == response.id && $0.childConsumedAt != nil
            }) ? true : nil
        }
    }

    /// Wait for the next unconsumed child question/completion belonging to
    /// this parent column. Questions stay pending until a response is sent;
    /// completion is acknowledged immediately after it is printed.
    static func receive(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        eventsURL: URL = MissionEventCenter.defaultEventsURL,
        missionsURL: URL = MissionStore.defaultFileURL,
        pollInterval: TimeInterval = 0.2
    ) -> Int32 {
        guard let context = parentContext(environment),
              let options = parseOptions(arguments, allowed: ["--timeout"]),
              let timeout = validTimeout(options["--timeout"])
        else { return 2 }

        var ledger = MissionLedgerReader(url: missionsURL)
        ledger.refresh()
        let next = waitForLedger(&ledger, timeout: timeout, pollInterval: pollInterval) { missions in
            nextParentEvent(context: context, in: missions)
        }
        guard let (mission, event) = next else {
            writeStandardError(
                "No Mission event yet. Run the same command again to keep waiting."
            )
            return 3
        }
        let output = InboxMessage(
            eventID: event.id,
            missionID: mission.id,
            kind: event.kind.rawValue,
            branch: mission.branch,
            message: event.message
        )
        guard let data = try? JSONEncoder().encode(output),
              let line = String(data: data, encoding: .utf8)
        else { return 1 }
        writeStandardOutput(line)

        if event.kind == .completed {
            let acknowledgement = MissionEvent(
                id: UUID().uuidString,
                missionID: mission.id,
                childWorkspaceID: mission.childWorkspaceID,
                childAgentUUID: mission.childAgentUUID,
                parentWorkspaceID: context.workspaceID,
                parentAgentUUID: context.agentUUID,
                kind: .acknowledged,
                message: "acknowledged",
                inReplyTo: event.id,
                timestamp: now()
            )
            guard append(acknowledgement, to: eventsURL) else { return 1 }
        }
        return 0
    }

    /// Parent-agent response. The question ID identifies the Mission; the
    /// current terminal identity must match its recorded parent.
    static func reply(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: TimeInterval = Date().timeIntervalSince1970,
        eventsURL: URL = MissionEventCenter.defaultEventsURL,
        missionsURL: URL = MissionStore.defaultFileURL,
        confirmationTimeout: TimeInterval = 5,
        pollInterval: TimeInterval = 0.05
    ) -> Int32 {
        guard let context = parentContext(environment),
              let options = parseOptions(arguments, allowed: ["--event", "--message"]),
              let eventID = options["--event"],
              UUID(uuidString: eventID) != nil,
              let message = validMessage(options["--message"])
        else { return 2 }
        var ledger = MissionLedgerReader(url: missionsURL)
        ledger.refresh()
        guard let mission = ledger.missions.first(where: { mission in
            mission.parentWorkspaceID == context.workspaceID
                && mission.parentAgentUUID == context.agentUUID
                && mission.status == .active
                && mission.events.contains(where: {
                    $0.id == eventID && $0.kind == .question
                })
                && !mission.events.contains(where: {
                    $0.kind == .response && $0.inReplyTo == eventID
                })
        }) else { return 2 }

        let responseID = UUID().uuidString
        let response = MissionEvent(
            id: responseID,
            missionID: mission.id,
            childWorkspaceID: mission.childWorkspaceID,
            childAgentUUID: mission.childAgentUUID,
            parentWorkspaceID: context.workspaceID,
            parentAgentUUID: context.agentUUID,
            kind: .response,
            message: message,
            inReplyTo: eventID,
            timestamp: now
        )
        guard append(response, to: eventsURL) else { return 1 }
        guard confirmationTimeout > 0 else { return 0 }

        let confirmed = waitForLedger(
            &ledger, timeout: confirmationTimeout, pollInterval: pollInterval
        ) { missions in
            missions.lazy.flatMap(\.events).contains(where: { $0.id == responseID }) ? true : nil
        }
        guard confirmed == nil else { return 0 }
        writeStandardError("Mission response was queued but not confirmed by Nirux.")
        return 3
    }

    /// Check `condition` against the ledger until it yields a value or
    /// `timeout` elapses (a zero timeout checks once). The ledger is decoded
    /// again only after Nirux saved it, and the poll interval backs off to
    /// `maxPollInterval` while nothing changes.
    private static func waitForLedger<Value>(
        _ ledger: inout MissionLedgerReader,
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        until condition: ([Mission]) -> Value?
    ) -> Value? {
        let deadline = Date().addingTimeInterval(timeout)
        let initialInterval = max(0.01, pollInterval)
        var interval = initialInterval
        var changed = true
        while true {
            if changed, let value = condition(ledger.missions) { return value }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            Thread.sleep(forTimeInterval: min(interval, remaining))
            changed = ledger.refresh()
            interval = changed ? initialInterval : max(initialInterval, min(maxPollInterval, interval * 2))
        }
    }

    private static func childContext(_ environment: [String: String]) -> ChildContext? {
        guard environment["NIRUX_MISSION_HANDOFFS"] == "1",
              let missionID = environment["NIRUX_MISSION_ID"],
              let workspaceID = environment["NIRUX_WORKSPACE_ID"],
              let agentUUID = environment["NIRUX_AGENT_UUID"],
              UUID(uuidString: missionID) != nil,
              UUID(uuidString: workspaceID) != nil,
              UUID(uuidString: agentUUID) != nil
        else { return nil }
        return ChildContext(missionID: missionID, workspaceID: workspaceID, agentUUID: agentUUID)
    }

    private static func parentContext(_ environment: [String: String]) -> ParentContext? {
        guard environment["NIRUX_MISSION_HANDOFFS"] == "1",
              let workspaceID = environment["NIRUX_WORKSPACE_ID"],
              let agentUUID = environment["NIRUX_AGENT_UUID"],
              UUID(uuidString: workspaceID) != nil,
              UUID(uuidString: agentUUID) != nil
        else { return nil }
        return ParentContext(workspaceID: workspaceID, agentUUID: agentUUID)
    }

    private static func parseOptions(
        _ arguments: [String], allowed: Set<String>
    ) -> [String: String]? {
        guard arguments.count.isMultiple(of: 2) else { return nil }
        var result: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard allowed.contains(key), result[key] == nil else { return nil }
            result[key] = arguments[index + 1]
            index += 2
        }
        return result
    }

    private static func validMessage(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !message.isEmpty && message.count <= maxMessageLength ? message : nil
    }

    private static func validTimeout(_ raw: String?) -> TimeInterval? {
        guard let raw else { return defaultWaitTimeout }
        guard let value = TimeInterval(raw), value >= 0, value <= 3600 else { return nil }
        return value
    }

    private static func nextParentEvent(
        context: ParentContext, in missions: [Mission]
    ) -> (Mission, MissionEvent)? {
        missions
            .filter {
                $0.parentWorkspaceID == context.workspaceID
                    && $0.parentAgentUUID == context.agentUUID
            }
            .flatMap { mission in
                mission.events.compactMap { event -> (Mission, MissionEvent)? in
                    guard event.kind == .question || event.kind == .completed,
                          event.parentConsumedAt == nil
                    else { return nil }
                    return (mission, event)
                }
            }
            .min(by: { $0.1.timestamp < $1.1.timestamp })
    }

    static func append(_ event: MissionEvent, to url: URL) -> Bool {
        guard var line = try? JSONEncoder().encode(event) else { return false }
        line.append(0x0A)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return false }
        let written = line.withUnsafeBytes { buffer -> Int in
            guard let pointer = buffer.baseAddress else { return 0 }
            return write(fd, pointer, buffer.count)
        }
        close(fd)
        return written == line.count
    }

    private static func writeStandardOutput(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
    }

    private static func writeStandardError(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}
