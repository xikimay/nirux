import Foundation

/// Filesystem mailbox CLI used by both sides of a Mission. Commands append
/// events to the app-owned queue; wait commands only read the atomically
/// written mission ledger, so no CLI process races the app for state writes.
enum MissionEventCLI {
    static let maxMessageLength = 500
    static let defaultWaitTimeout: TimeInterval = 900

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
    /// injection or heuristic idle detection is involved.
    static func ask(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: TimeInterval = Date().timeIntervalSince1970,
        eventID: String = UUID().uuidString,
        eventsURL: URL = MissionEventCenter.defaultEventsURL,
        missionsURL: URL = MissionStore.defaultFileURL,
        pollInterval: TimeInterval = 0.2
    ) -> Int32 {
        guard let context = childContext(environment),
              UUID(uuidString: eventID) != nil,
              let options = parseOptions(arguments, allowed: ["--message", "--timeout"]),
              let message = validMessage(options["--message"]),
              let timeout = validTimeout(options["--timeout"])
        else { return 2 }

        let question = MissionEvent(
            id: eventID,
            missionID: context.missionID,
            childWorkspaceID: context.workspaceID,
            childAgentUUID: context.agentUUID,
            kind: .question,
            message: message,
            timestamp: now
        )
        guard append(question, to: eventsURL) else { return 1 }

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let response = response(
                to: eventID, missionID: context.missionID, missionsURL: missionsURL
            ) {
                writeStandardOutput(response.message)
                return 0
            }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: max(0.01, pollInterval))
        } while true
        writeStandardError("Timed out waiting for a Mission response.")
        return 3
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

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let (mission, event) = nextParentEvent(context: context, missionsURL: missionsURL) {
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
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: max(0.01, pollInterval))
        } while true
        writeStandardError("Timed out waiting for a Mission event.")
        return 3
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
              let message = validMessage(options["--message"]),
              let mission = loadMissions(from: missionsURL).first(where: { mission in
                  mission.parentWorkspaceID == context.workspaceID
                      && mission.parentAgentUUID == context.agentUUID
                      && mission.status == .active
                      && mission.events.contains(where: {
                          $0.id == eventID && $0.kind == .question
                      })
                      && !mission.events.contains(where: {
                          $0.kind == .response && $0.inReplyTo == eventID
                      })
              })
        else { return 2 }

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

        let deadline = Date().addingTimeInterval(confirmationTimeout)
        repeat {
            if loadMissions(from: missionsURL).contains(where: { mission in
                mission.events.contains(where: { $0.id == responseID })
            }) {
                return 0
            }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: max(0.01, pollInterval))
        } while true
        writeStandardError("Mission response was queued but not confirmed by Nirux.")
        return 3
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

    private static func loadMissions(from url: URL) -> [Mission] {
        guard let data = try? Data(contentsOf: url),
              let missions = try? JSONDecoder().decode([Mission].self, from: data)
        else { return [] }
        return missions
    }

    private static func response(
        to questionID: String, missionID: String, missionsURL: URL
    ) -> MissionEvent? {
        loadMissions(from: missionsURL)
            .first(where: { $0.id == missionID })?
            .events.first(where: { $0.kind == .response && $0.inReplyTo == questionID })
    }

    private static func nextParentEvent(
        context: ParentContext, missionsURL: URL
    ) -> (Mission, MissionEvent)? {
        loadMissions(from: missionsURL)
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
