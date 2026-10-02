import CryptoKit
import Foundation

/// Filesystem mailbox CLI used by both sides of a Mission. Commands append
/// events to the app-owned queue; wait commands only read the atomically
/// written mission ledger, so no CLI process races the app for state writes.
///
/// Exit statuses, as the installed skill and the child's startup prompt
/// explain them to agents: 0 done, 1 Nirux state could not be read or
/// written, 2 invalid usage, 3 nothing yet (run the same command again),
/// 4 stop (handoffs off, Mission over, or not this terminal's to answer).
enum MissionEventCLI {
    static let maxMessageLength = 500
    /// Agent shell tools stop foreground commands after a few minutes (two
    /// by default in Claude Code), so a wait never lasts longer than this and
    /// the agent runs the same command again to keep waiting.
    static let defaultWaitTimeout: TimeInterval = 90
    /// Upper bound of the wait-loop backoff while the ledger is unchanged.
    static let maxPollInterval: TimeInterval = 1
    /// How long an identical `ask` still prints an answer the child already
    /// received, so rerunning a command whose output the shell tool cut short
    /// is harmless. After that, the same text is a new question.
    static let answerReplayWindow: TimeInterval = 60

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

    /// Entry point for `Nirux --mission <command> [options]`.
    static func main(
        _ arguments: [String],
        handoffsEnabled: () -> Bool? = {
            Persistence.load().map { $0.settings?.missionHandoffsEnabled == true }
        }
    ) -> Int32 {
        let commands = "ask|completed|receive|reply|tell [options]"
        guard let command = arguments.first else { return usage(commands) }
        // Terminals keep their Mission environment after the setting is
        // turned off, while Nirux drops their events: say so, don't wait.
        guard handoffsEnabled() != false else {
            writeStandardError("Mission handoffs are turned off in Nirux Settings; stop using Mission commands.")
            return 4
        }
        let options = Array(arguments.dropFirst())
        switch command {
        case "ask": return ask(arguments: options)
        case "receive": return receive(arguments: options)
        case "reply": return reply(arguments: options)
        case "tell": return tell(arguments: options)
        case MissionEvent.Kind.question.rawValue: return run(kind: .question, arguments: options)
        case MissionEvent.Kind.completed.rawValue: return run(kind: .completed, arguments: options)
        default: return usage(commands)
        }
    }

    static func run(
        kind: MissionEvent.Kind,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: TimeInterval = Date().timeIntervalSince1970,
        eventsURL: URL = MissionEventCenter.defaultEventsURL,
        missionsURL: URL = MissionStore.defaultFileURL
    ) -> Int32 {
        guard kind == .question || kind == .completed else { return usage("completed --message <text>") }
        guard let context = childContext(environment) else { return notAMissionTerminal(child: true) }
        guard let options = parseOptions(arguments, allowed: ["--message"]),
              let message = validMessage(options["--message"])
        else { return usage("\(kind.rawValue) --message <1-\(maxMessageLength) characters>") }

        // An unreadable ledger still queues the event, as before: Nirux
        // validates it again when draining the queue.
        var ledger = MissionLedgerReader(url: missionsURL)
        if ledger.refresh(), case let .unavailable(problem) = childMission(context, in: ledger.missions) {
            writeStandardError(problem)
            return 4
        }
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
        output: (String) -> Void = writeStandardOutput
    ) -> Int32 {
        guard let context = childContext(environment) else { return notAMissionTerminal(child: true) }
        guard let options = parseOptions(arguments, allowed: ["--message", "--timeout"]),
              let message = validMessage(options["--message"]),
              let timeout = validTimeout(options["--timeout"])
        else {
            return usage("ask --message <1-\(maxMessageLength) characters> [--timeout <seconds>]")
        }

        var ledger = MissionLedgerReader(url: missionsURL)
        guard loadLedger(&ledger) else { return unreadableLedger(missionsURL) }
        let mission: Mission
        switch childMission(context, in: ledger.missions) {
        case let .active(active):
            mission = active
        case let .unavailable(problem):
            writeStandardError(problem)
            return 4
        }
        let questionID = questionID(for: message, context: context, in: mission, now: now())
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
            return mission.status == .active ? nil : .missionCompleted
        }
        switch outcome {
        case let .answered(response):
            output(response.message)
            // The answer is printed either way; a lost receipt only means a
            // later identical `ask` prints it once more and queues another.
            _ = append(receipt(for: response, at: now()), to: eventsURL)
            return 0
        case .missionCompleted:
            writeStandardError("This Mission completed before the question was answered.")
            return 4
        case nil:
            writeStandardError(
                "No answer yet; the question stays queued and appears in Nirux Activity. "
                    + "Run the exact same command again to keep waiting."
            )
            return 3
        }
    }

    private enum AskOutcome {
        case answered(MissionEvent)
        case missionCompleted
    }

    private enum ChildMission {
        case active(Mission)
        case unavailable(String)
    }

    /// The Mission this child terminal may ask or report to, or why not.
    private static func childMission(_ context: ChildContext, in missions: [Mission]) -> ChildMission {
        guard let mission = missions.first(where: { $0.id == context.missionID }) else {
            return .unavailable("Nirux has no record of this Mission.")
        }
        // Every column of the child workspace sees the Mission ID, but Nirux
        // only accepts events from the agent it launched for the Mission.
        guard mission.childWorkspaceID == context.workspaceID,
              mission.childAgentUUID == context.agentUUID
        else {
            return .unavailable(
                "Only the agent Nirux launched for this Mission can ask or report; this terminal is another one."
            )
        }
        guard mission.status == .active else {
            return .unavailable("This Mission has already completed.")
        }
        return .active(mission)
    }

    /// Identical questions share a derived ID, so a retry after a shell-tool
    /// timeout never queues a duplicate. An answer the child received more
    /// than `answerReplayWindow` ago moves the same text to a new ID.
    private static func questionID(
        for message: String, context: ChildContext, in mission: Mission, now: TimeInterval
    ) -> String {
        func derivedID(_ generation: Int) -> String {
            derivedEventID([
                "nirux.mission.question",
                context.missionID,
                context.workspaceID,
                context.agentUUID,
                String(generation),
                message
            ])
        }
        let recorded = Set(mission.events.lazy.filter { $0.kind == .question }.map(\.id))
        let settled = Set(mission.events.compactMap { event -> String? in
            guard event.kind == .response,
                  let receivedAt = event.childConsumedAt,
                  now - receivedAt >= answerReplayWindow
            else { return nil }
            return event.inReplyTo
        })
        // A later generation also closes an earlier one, so a clock moved
        // back never reopens an old question and replays its answer.
        var current = derivedID(0)
        var generation = 0
        while recorded.contains(current) {
            let next = derivedID(generation + 1)
            guard settled.contains(current) || recorded.contains(next) else { break }
            current = next
            generation += 1
        }
        return current
    }

    /// RFC 9562 version 8 UUID from a SHA-256 digest. Only the last
    /// component may contain newlines, so the joined input is unambiguous.
    private static func derivedEventID(_ components: [String]) -> String {
        var bytes = Array(SHA256.hash(data: Data(components.joined(separator: "\n").utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return (NSUUID(uuidBytes: bytes) as UUID).uuidString
    }

    /// Child acknowledgement that its agent received this response.
    private static func receipt(for response: MissionEvent, at timestamp: TimeInterval) -> MissionEvent {
        MissionEvent(
            id: UUID().uuidString,
            missionID: response.missionID,
            childWorkspaceID: response.childWorkspaceID,
            childAgentUUID: response.childAgentUUID,
            kind: .acknowledged,
            message: "acknowledged",
            inReplyTo: response.id,
            timestamp: timestamp
        )
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
        guard let context = parentContext(environment) else { return notAMissionTerminal(child: false) }
        guard let options = parseOptions(arguments, allowed: ["--timeout"]),
              let timeout = validTimeout(options["--timeout"])
        else { return usage("receive [--timeout <seconds>]") }

        var ledger = MissionLedgerReader(url: missionsURL)
        ledger.refresh()
        let next = waitForLedger(&ledger, timeout: timeout, pollInterval: pollInterval) { missions in
            nextParentEvent(context: context, in: missions)
        }
        guard let (mission, event) = next else {
            if !ledger.hasRead, !ledger.isMissing { return unreadableLedger(missionsURL) }
            // A parent that never had a Mission keeps waiting: Nirux records
            // one only after creating its worktree, which can take a while.
            let missions = ledger.missions.filter {
                $0.parentWorkspaceID == context.workspaceID && $0.parentAgentUUID == context.agentUUID
            }
            if !missions.isEmpty, !missions.contains(where: { $0.status == .active }) {
                writeStandardError("No active Mission for this terminal; stop waiting.")
                return 4
            }
            writeStandardError("No Mission event yet. Run the same command again to keep waiting.")
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
        guard let context = parentContext(environment) else { return notAMissionTerminal(child: false) }
        guard let options = parseOptions(arguments, allowed: ["--event", "--message"]),
              let eventID = options["--event"],
              UUID(uuidString: eventID) != nil,
              let message = validMessage(options["--message"])
        else {
            return usage("reply --event <question-event-id> --message <1-\(maxMessageLength) characters>")
        }
        var ledger = MissionLedgerReader(url: missionsURL)
        guard loadLedger(&ledger) else { return unreadableLedger(missionsURL) }
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
        }) else {
            writeStandardError(
                "This question is not waiting for an answer from this terminal: it was already answered "
                    + "(perhaps from Nirux Activity), its Mission ended, or it belongs to another parent. "
                    + "Do not resend it; keep using `receive` for the child's other events."
            )
            return 4
        }

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
        writeStandardError("The answer is queued but Nirux has not confirmed it yet; do not send it again.")
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

    /// `--timeout` can shorten a wait but never extend it past the default:
    /// skills installed before waits were bounded still pass 900 seconds.
    static func validTimeout(_ raw: String?) -> TimeInterval? {
        guard let raw else { return defaultWaitTimeout }
        guard let value = TimeInterval(raw), value >= 0 else { return nil }
        return min(value, defaultWaitTimeout)
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
        guard fd >= 0 else {
            reportQueueFailure(url, code: errno)
            return false
        }
        let written = line.withUnsafeBytes { buffer -> Int in
            guard let pointer = buffer.baseAddress else { return 0 }
            return write(fd, pointer, buffer.count)
        }
        let writeError = errno
        close(fd)
        guard written == line.count else {
            reportQueueFailure(url, code: written < 0 ? writeError : EIO)
            return false
        }
        return true
    }

    /// Agent sandboxes often allow reads but block writes outside the
    /// project, so name the path and the cause instead of failing silently.
    private static func reportQueueFailure(_ url: URL, code: Int32) {
        writeStandardError(
            "Could not write the Mission queue at \(url.path): \(String(cString: strerror(code))). "
                + "If a sandbox blocks writes there, run the command outside the sandbox."
        )
    }

    /// Read the ledger once. A missing file is an empty ledger, since Nirux
    /// creates it with the first Mission; any other failure is status 1.
    private static func loadLedger(_ ledger: inout MissionLedgerReader) -> Bool {
        ledger.refresh() || ledger.isMissing
    }

    private static func unreadableLedger(_ url: URL) -> Int32 {
        writeStandardError("Could not read the Mission ledger at \(url.path).")
        return 1
    }

    private static func usage(_ synopsis: String) -> Int32 {
        writeStandardError("Usage: \"$NIRUX_CLI_PATH\" --mission \(synopsis)")
        return 2
    }

    private static func notAMissionTerminal(child: Bool) -> Int32 {
        writeStandardError(child
            ? "Run this from the agent terminal of a Nirux Mission workspace."
            : "Run this from a Nirux terminal opened after Mission handoffs were enabled.")
        return 2
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

extension MissionEventCLI {
    /// Parent-agent instruction for the child on `--branch`: Nirux types it
    /// into the child's prompt once it is free (see
    /// `AgentStatusMachine.isPromptFree`). Waits for that like `ask` waits
    /// for an answer, and running the same command again resumes the wait
    /// instead of sending the text twice.
    static func tell(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: () -> TimeInterval = { Date().timeIntervalSince1970 },
        eventsURL: URL = MissionEventCenter.defaultEventsURL,
        missionsURL: URL = MissionStore.defaultFileURL,
        pollInterval: TimeInterval = 0.2
    ) -> Int32 {
        guard let context = parentContext(environment) else { return notAMissionTerminal(child: false) }
        guard let options = parseOptions(arguments, allowed: ["--branch", "--message", "--timeout"]),
              let branch = options["--branch"],
              let message = validMessage(options["--message"]),
              let timeout = validTimeout(options["--timeout"])
        else {
            return usage("tell --branch <child-branch> --message <1-\(maxMessageLength) characters>")
        }
        var ledger = MissionLedgerReader(url: missionsURL)
        guard loadLedger(&ledger) else { return unreadableLedger(missionsURL) }
        // A branch reopened in a new worktree has a newer Mission.
        guard let mission = ledger.missions.filter({
            $0.parentWorkspaceID == context.workspaceID
                && $0.parentAgentUUID == context.agentUUID
                && $0.branch == branch
        }).max(by: { $0.createdAt < $1.createdAt }) else {
            writeStandardError("No Mission on branch \(branch) was started from this terminal.")
            return 4
        }
        guard mission.childAgentKind == NiruxApp.WorkspaceAgent.claude.rawValue else {
            writeStandardError("Nirux types messages only into a Claude Code child; this one runs \(mission.childAgentKind).")
            return 4
        }
        let sentAt = now()
        let existing = mission.events.last(where: {
            $0.kind == .instruction && $0.message == message
                && $0.childConsumedAt.map { sentAt - $0 < answerReplayWindow } ?? true
        })
        let instructionID = existing?.id ?? UUID().uuidString
        if existing == nil {
            let instruction = MissionEvent(
                id: instructionID,
                missionID: mission.id,
                childWorkspaceID: mission.childWorkspaceID,
                childAgentUUID: mission.childAgentUUID,
                parentWorkspaceID: context.workspaceID,
                parentAgentUUID: context.agentUUID,
                kind: .instruction,
                message: message,
                timestamp: sentAt
            )
            guard append(instruction, to: eventsURL) else { return 1 }
        }

        let typed = waitForLedger(&ledger, timeout: timeout, pollInterval: pollInterval) { missions in
            missions.lazy.flatMap(\.events).contains(where: {
                $0.id == instructionID && $0.childConsumedAt != nil
            }) ? true : nil
        }
        guard typed == nil else {
            writeStandardOutput("Nirux typed the message into the child's prompt.")
            return 0
        }
        writeStandardError(
            "Not typed yet: the child is working, a dialog is open, or someone is typing at its prompt. "
                + "Nirux types it once the child's turn ends. Run the exact same command again to keep "
                + "waiting; it does not send the message twice."
        )
        return 3
    }
}
