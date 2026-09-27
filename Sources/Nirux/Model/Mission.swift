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
        /// Internal inbox acknowledgement: from the parent for a question or
        /// completion, from the child for a response. It updates the target
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
    /// Set on a response once the child's `ask` has printed it. Asking the
    /// same question again replays the answer for a short window (a rerun
    /// after a cut-off command), then starts a new exchange.
    var childConsumedAt: TimeInterval?

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
        parentConsumedAt: TimeInterval? = nil,
        childConsumedAt: TimeInterval? = nil
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
        self.childConsumedAt = childConsumedAt
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
    private enum LedgerState: Equatable {
        case notLoaded
        case available
        case unavailable
    }
    private var ledgerState: LedgerState

    nonisolated static var defaultFileURL: URL {
        Persistence.stateDirectory.appendingPathComponent("missions.json")
    }

    init(fileURL: URL = MissionStore.defaultFileURL, persistsToDisk: Bool = true) {
        self.fileURL = fileURL
        self.persistsToDisk = persistsToDisk
        ledgerState = persistsToDisk ? .notLoaded : .available
    }

    @discardableResult
    func load() -> Bool {
        guard persistsToDisk else {
            ledgerState = .available
            return true
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            missions = []
            ledgerState = .available
            return true
        }
        do {
            let data = try Data(contentsOf: fileURL)
            missions = try JSONDecoder().decode([Mission].self, from: data)
            ledgerState = .available
            return true
        } catch {
            ledgerState = .unavailable
            NSLog("[MissionStore] Failed to load missions: %@", error.localizedDescription)
            return false
        }
    }

    func ensureLoaded() -> Bool {
        ledgerState == .available || load()
    }

    @discardableResult
    func create(
        _ request: MissionCreationRequest,
        enabled: Bool,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Mission? {
        guard enabled,
              ensureLoaded(),
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

    // This single transition keeps validation and its in-memory mutation
    // adjacent so persistence commits exactly one candidate Mission ledger.
    func process(_ incoming: MissionEvent, enabled: Bool) -> ProcessingResult {
        guard ensureLoaded() else { return .persistenceFailed }
        guard enabled,
              incoming.deliveredAt == nil,
              incoming.parentConsumedAt == nil,
              incoming.childConsumedAt == nil,
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
            return processAcknowledgement(incoming, missionIndex: index)
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

    /// Acknowledgements update their target and are not retained: the parent
    /// consumes a question or completion, the child receives a response.
    private func processAcknowledgement(
        _ incoming: MissionEvent, missionIndex index: Int
    ) -> ProcessingResult {
        let mission = missions[index]
        let fromChild = incoming.parentWorkspaceID == nil && incoming.parentAgentUUID == nil
        guard fromChild
                || (incoming.parentWorkspaceID == mission.parentWorkspaceID
                    && incoming.parentAgentUUID == mission.parentAgentUUID)
        else { return .rejected }
        let targetKinds: Set<MissionEvent.Kind> = fromChild ? [.response] : [.question, .completed]
        guard let targetID = incoming.inReplyTo,
              let targetIndex = mission.events.firstIndex(where: {
                  $0.id == targetID && targetKinds.contains($0.kind)
              })
        else { return .rejected }
        let consumedAt: WritableKeyPath<MissionEvent, TimeInterval?> =
            fromChild ? \.childConsumedAt : \.parentConsumedAt
        guard mission.events[targetIndex][keyPath: consumedAt] == nil else { return .accepted(nil) }
        var updated = missions
        updated[index].events[targetIndex][keyPath: consumedAt] = incoming.timestamp
        return commit(updated) ? .accepted(nil) : .persistenceFailed
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
        guard ledgerState == .available else { return false }
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
