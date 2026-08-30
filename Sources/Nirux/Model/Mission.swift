import Foundation

/// A small, explicit parent/child handoff created with a Nirux worktree.
/// The event list is a durable mailbox for correlated questions, responses,
/// and the child's explicit completion result.
struct Mission: Codable, Equatable {
    enum Status: String, Codable {
        case active
        case completed
    }

    let id: String
    let parentWorkspaceID: String
    let parentAgentUUID: String
    let childWorkspaceID: String
    let childAgentUUID: String
    let childAgentKind: String
    let branch: String
    var status: Status
    let createdAt: TimeInterval
    var updatedAt: TimeInterval
    var events: [MissionEvent]
}

/// An explicit mailbox event. `deliveredAt` is set only after the event has
/// been durably mirrored into the activity feed.
struct MissionEvent: Codable, Equatable {
    enum Kind: String, Codable {
        case question
        case completed
        case response
        /// Internal parent-inbox acknowledgement. It updates the target
        /// event and is not retained as a user-visible Mission event.
        case acknowledged
    }

    let id: String
    let missionID: String
    let childWorkspaceID: String
    let childAgentUUID: String
    let parentWorkspaceID: String?
    let parentAgentUUID: String?
    let kind: Kind
    let message: String
    /// Question/completion event this response or acknowledgement targets.
    let inReplyTo: String?
    let timestamp: TimeInterval
    var deliveredAt: TimeInterval?
    /// Separate from Activity delivery: whether the parent agent CLI has
    /// consumed this child event. UI display must not consume an agent inbox.
    var parentConsumedAt: TimeInterval?

    init(
        id: String,
        missionID: String,
        childWorkspaceID: String,
        childAgentUUID: String,
        parentWorkspaceID: String? = nil,
        parentAgentUUID: String? = nil,
        kind: Kind,
        message: String,
        inReplyTo: String? = nil,
        timestamp: TimeInterval,
        deliveredAt: TimeInterval? = nil,
        parentConsumedAt: TimeInterval? = nil
    ) {
        self.id = id
        self.missionID = missionID
        self.childWorkspaceID = childWorkspaceID
        self.childAgentUUID = childAgentUUID
        self.parentWorkspaceID = parentWorkspaceID
        self.parentAgentUUID = parentAgentUUID
        self.kind = kind
        self.message = message
        self.inReplyTo = inReplyTo
        self.timestamp = timestamp
        self.deliveredAt = deliveredAt
        self.parentConsumedAt = parentConsumedAt
    }
}

struct MissionCreationRequest {
    let id: String
    let parentWorkspaceID: String
    let parentAgentUUID: String
    let childWorkspaceID: String
    let childAgentUUID: String
    let childAgentKind: String
    let branch: String
}

/// Durable mission state. Writes are immediate because this store is also
/// the restart-safe delivery ledger for pending child events.
@MainActor
final class MissionStore {
    static let shared = MissionStore()

    private(set) var missions: [Mission] = []
    private let fileURL: URL
    private let persistsToDisk: Bool

    nonisolated static var defaultFileURL: URL {
        Persistence.stateDirectory.appendingPathComponent("missions.json")
    }

    init(fileURL: URL = MissionStore.defaultFileURL, persistsToDisk: Bool = true) {
        self.fileURL = fileURL
        self.persistsToDisk = persistsToDisk
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Mission].self, from: data)
        else { return }
        missions = decoded
    }

    @discardableResult
    func create(
        _ request: MissionCreationRequest,
        enabled: Bool,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Mission? {
        guard enabled,
              Self.isIdentifier(request.id),
              Self.isIdentifier(request.parentWorkspaceID),
              Self.isIdentifier(request.parentAgentUUID),
              Self.isIdentifier(request.childWorkspaceID),
              Self.isIdentifier(request.childAgentUUID),
              !request.childAgentKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !missions.contains(where: { $0.id == request.id })
        else { return nil }

        let mission = Mission(
            id: request.id,
            parentWorkspaceID: request.parentWorkspaceID,
            parentAgentUUID: request.parentAgentUUID,
            childWorkspaceID: request.childWorkspaceID,
            childAgentUUID: request.childAgentUUID,
            childAgentKind: request.childAgentKind,
            branch: request.branch,
            status: .active,
            createdAt: now,
            updatedAt: now,
            events: []
        )
        var updated = missions
        updated.append(mission)
        return commit(updated) ? mission : nil
    }

    struct AcceptedEvent {
        let mission: Mission
        let event: MissionEvent
    }

    enum ProcessingResult {
        case rejected
        case persistenceFailed
        case accepted(AcceptedEvent?)
    }

    /// Validate routing identities against the recorded Mission. Child
    /// reports must match the child; responses and acknowledgements must
    /// match the parent and reference a real pending child event.
    func accept(_ incoming: MissionEvent, enabled: Bool) -> AcceptedEvent? {
        guard case let .accepted(event) = process(incoming, enabled: enabled) else { return nil }
        return event
    }

    func process(_ incoming: MissionEvent, enabled: Bool) -> ProcessingResult {
        guard enabled,
              incoming.deliveredAt == nil,
              incoming.parentConsumedAt == nil,
              Self.isIdentifier(incoming.id),
              Self.isIdentifier(incoming.missionID),
              Self.isIdentifier(incoming.childWorkspaceID),
              Self.isIdentifier(incoming.childAgentUUID),
              let index = missions.firstIndex(where: { $0.id == incoming.missionID }),
              missions[index].childWorkspaceID == incoming.childWorkspaceID,
              missions[index].childAgentUUID == incoming.childAgentUUID
        else { return .rejected }

        if let existing = missions[index].events.first(where: { $0.id == incoming.id }) {
            let pending = existing.deliveredAt == nil
                ? AcceptedEvent(mission: missions[index], event: existing)
                : nil
            return .accepted(pending)
        }

        let message = incoming.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.count <= MissionEventCLI.maxMessageLength else {
            return .rejected
        }

        var updated = missions

        switch incoming.kind {
        case .question, .completed:
            guard missions[index].status == .active,
                  incoming.parentWorkspaceID == nil,
                  incoming.parentAgentUUID == nil,
                  incoming.inReplyTo == nil
            else { return .rejected }

        case .response:
            guard missions[index].status == .active,
                  incoming.parentWorkspaceID == missions[index].parentWorkspaceID,
                  incoming.parentAgentUUID == missions[index].parentAgentUUID,
                  let questionID = incoming.inReplyTo,
                  let questionIndex = missions[index].events.firstIndex(where: {
                      $0.id == questionID && $0.kind == .question
                  }),
                  !missions[index].events.contains(where: {
                      $0.kind == .response && $0.inReplyTo == questionID
                  })
            else { return .rejected }
            updated[index].events[questionIndex].parentConsumedAt = incoming.timestamp

        case .acknowledged:
            guard incoming.parentWorkspaceID == missions[index].parentWorkspaceID,
                  incoming.parentAgentUUID == missions[index].parentAgentUUID,
                  let targetID = incoming.inReplyTo,
                  let targetIndex = missions[index].events.firstIndex(where: {
                      $0.id == targetID && ($0.kind == .question || $0.kind == .completed)
                  })
            else { return .rejected }
            guard missions[index].events[targetIndex].parentConsumedAt == nil else {
                return .accepted(nil)
            }
            updated[index].events[targetIndex].parentConsumedAt = incoming.timestamp
            return commit(updated) ? .accepted(nil) : .persistenceFailed
        }

        let event = MissionEvent(
            id: incoming.id,
            missionID: incoming.missionID,
            childWorkspaceID: incoming.childWorkspaceID,
            childAgentUUID: incoming.childAgentUUID,
            parentWorkspaceID: incoming.parentWorkspaceID,
            parentAgentUUID: incoming.parentAgentUUID,
            kind: incoming.kind,
            message: message,
            inReplyTo: incoming.inReplyTo,
            timestamp: incoming.timestamp,
            deliveredAt: nil,
            parentConsumedAt: nil
        )
        updated[index].events.append(event)
        updated[index].updatedAt = event.timestamp
        if event.kind == .completed {
            let answered = Set(updated[index].events.compactMap { candidate in
                candidate.kind == .response ? candidate.inReplyTo : nil
            })
            for eventIndex in updated[index].events.indices
            where updated[index].events[eventIndex].kind == .question
                && updated[index].events[eventIndex].parentConsumedAt == nil
                && !answered.contains(updated[index].events[eventIndex].id) {
                updated[index].events[eventIndex].parentConsumedAt = event.timestamp
            }
            updated[index].status = .completed
        }
        guard commit(updated) else { return .persistenceFailed }
        return .accepted(AcceptedEvent(mission: missions[index], event: event))
    }

    /// Trusted UI response path. It uses the same validation and persistence
    /// as a parent-agent CLI response, then returns the accepted event so the
    /// caller can mirror it into Activity.
    func respond(
        to questionID: String,
        message: String,
        enabled: Bool,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> AcceptedEvent? {
        guard let mission = missions.first(where: { candidate in
            candidate.events.contains(where: { $0.id == questionID && $0.kind == .question })
        }) else { return nil }
        let response = MissionEvent(
            id: UUID().uuidString,
            missionID: mission.id,
            childWorkspaceID: mission.childWorkspaceID,
            childAgentUUID: mission.childAgentUUID,
            parentWorkspaceID: mission.parentWorkspaceID,
            parentAgentUUID: mission.parentAgentUUID,
            kind: .response,
            message: message,
            inReplyTo: questionID,
            timestamp: now
        )
        return accept(response, enabled: enabled)
    }

    func response(to questionID: String) -> MissionEvent? {
        missions.lazy.flatMap(\.events).first(where: {
            $0.kind == .response && $0.inReplyTo == questionID
        })
    }

    func pendingEvents() -> [AcceptedEvent] {
        missions.flatMap { mission in
            mission.events.compactMap { event in
                event.deliveredAt == nil ? AcceptedEvent(mission: mission, event: event) : nil
            }
        }.sorted { $0.event.timestamp < $1.event.timestamp }
    }

    @discardableResult
    func markDelivered(
        eventID: String, at timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        for missionIndex in missions.indices {
            guard let eventIndex = missions[missionIndex].events.firstIndex(where: { $0.id == eventID }),
                  missions[missionIndex].events[eventIndex].deliveredAt == nil
            else { continue }
            var updated = missions
            updated[missionIndex].events[eventIndex].deliveredAt = timestamp
            return commit(updated)
        }
        return false
    }

    private static func isIdentifier(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    private func commit(_ updated: [Mission]) -> Bool {
        guard persistsToDisk else {
            missions = updated
            return true
        }
        do {
            let data = try JSONEncoder().encode(updated)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            missions = updated
            return true
        } catch {
            NSLog("[MissionStore] Failed to save missions: %@", error.localizedDescription)
            return false
        }
    }
}

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
                    guard (event.kind == .question || event.kind == .completed),
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

/// Watches and drains the explicit mission-event queue using the same
/// rename-aside JSONL pattern as AgentHookCenter.
@MainActor
final class MissionEventCenter {
    static let shared = MissionEventCenter(store: .shared)

    nonisolated static var defaultEventsURL: URL {
        Persistence.stateDirectory.appendingPathComponent("mission-events.jsonl")
    }

    private let store: MissionStore
    private let eventsURL: URL
    private let isEnabled: () -> Bool
    /// Return true only after the event is durably represented to the user.
    var onEvent: ((Mission, MissionEvent) -> Bool)?

    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirFd: Int32 = -1
    private var pendingDrain: DispatchWorkItem?
    private var started = false

    init(
        store: MissionStore,
        eventsURL: URL = MissionEventCenter.defaultEventsURL,
        isEnabled: @escaping () -> Bool = {
            Persistence.load()?.settings?.missionHandoffsEnabled == true
        }
    ) {
        self.store = store
        self.eventsURL = eventsURL
        self.isEnabled = isEnabled
    }

    func start() {
        guard !started else { return }
        started = true

        let dirPath = eventsURL.deletingLastPathComponent().path
        dirFd = open(dirPath, O_RDONLY | O_DIRECTORY)
        if dirFd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: dirFd,
                eventMask: [.write, .extend, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                self?.watchEventsFileIfPresent()
                self?.scheduleDrain()
            }
            source.setCancelHandler { [dirFd] in close(dirFd) }
            source.resume()
            dirSource = source
        } else {
            NSLog("[MissionEvents] cannot watch state dir %@", dirPath)
        }
        watchEventsFileIfPresent()
        drain()
        deliverPendingEvents()
    }

    private func watchEventsFileIfPresent() {
        guard fileSource == nil else { return }
        let fd = open(eventsURL.path, O_RDONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if !source.data.isDisjoint(with: [.delete, .rename, .revoke]) {
                self.fileSource?.cancel()
                self.fileSource = nil
                return
            }
            self.scheduleDrain()
        }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        fileSource = source
    }

    private func scheduleDrain() {
        guard pendingDrain == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.pendingDrain = nil
            self?.drain()
        }
        pendingDrain = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    func drain() {
        let aside = eventsURL.deletingPathExtension().appendingPathExtension("processing")
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: aside.path), !process(aside, fileManager: fileManager) {
            return
        }
        do {
            try fileManager.moveItem(at: eventsURL, to: aside)
        } catch {
            return
        }
        _ = process(aside, fileManager: fileManager)
    }

    private func process(_ source: URL, fileManager: FileManager) -> Bool {
        guard let data = try? Data(contentsOf: source) else { return false }
        let decoder = JSONDecoder()
        var persistenceFailed = false
        for line in data.split(separator: 0x0A) {
            guard let incoming = try? decoder.decode(MissionEvent.self, from: Data(line)) else {
                continue
            }
            switch store.process(incoming, enabled: isEnabled()) {
            case .rejected:
                continue
            case .persistenceFailed:
                persistenceFailed = true
            case let .accepted(accepted):
                if let accepted { deliver(accepted) }
            }
        }
        guard !persistenceFailed else { return false }
        do {
            try fileManager.removeItem(at: source)
            return true
        } catch {
            return false
        }
    }

    func deliverPendingEvents() {
        guard isEnabled() else { return }
        for pending in store.pendingEvents() {
            deliver(pending)
        }
    }

    private func deliver(_ accepted: MissionStore.AcceptedEvent) {
        guard onEvent?(accepted.mission, accepted.event) == true else { return }
        store.markDelivered(eventID: accepted.event.id)
    }

    func stop() {
        pendingDrain?.cancel()
        pendingDrain = nil
        dirSource?.cancel()
        dirSource = nil
        dirFd = -1
        fileSource?.cancel()
        fileSource = nil
        started = false
    }
}
