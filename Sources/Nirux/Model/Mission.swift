import Foundation

/// A small, explicit parent/child handoff created with a Nirux worktree.
/// The event list is a durable mailbox for correlated questions, responses,
/// the child's explicit completion result, and the parent's instructions.
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
    /// The parent is a space's Lead (docs/design/spaces.md, "The Lead"): the
    /// Mission works even with Mission handoffs off in Settings. Nil (an
    /// older build's record) means no.
    var reportsToLead: Bool?
    /// The parent is a task's agent, which started this sub-task with its
    /// tools (`start_task`, see TaskTools): the Mission works with Mission
    /// handoffs off too. Nil means no.
    var reportsToTask: Bool?
    /// The parent is a space's Lead telling a task of its space that
    /// doesn't report to it: the Mission carries the Lead's instructions
    /// only, never the task's questions or result, and code counting a
    /// parent's Missions or a child's leaves it out. Nil means no.
    var oneWay: Bool?

    /// Carried whatever the Mission handoffs setting: a Lead's task, a
    /// sub-task a task's agent started with its tools, or a Lead's tells.
    var isAlwaysCarried: Bool { reportsToLead == true || reportsToTask == true || oneWay == true }

    /// Whether Nirux carries this Mission's messages, given the Mission
    /// handoffs setting.
    func isCarried(handoffsEnabled: Bool) -> Bool {
        handoffsEnabled || isAlwaysCarried
    }

    /// The agent its child runs, as Nirux's lines name it, when Nirux
    /// delivers its parent's messages to it (`agentName(ofKind:)`).
    var childAgentName: String? { Self.agentName(ofKind: childAgentKind) }

    /// An agent kind (its process's name too), as Nirux's lines name it,
    /// when Nirux delivers messages to it: typed into Claude Code's or
    /// Antigravity's prompt, or handed to Codex's queue.
    static func agentName(ofKind kind: String) -> String? {
        switch kind {
        case NiruxApp.WorkspaceAgent.claude.rawValue: "Claude Code"
        case NiruxApp.WorkspaceAgent.codex.rawValue: "Codex"
        case NiruxApp.WorkspaceAgent.agy.rawValue: "Antigravity"
        default: nil
        }
    }
}

/// An explicit mailbox event. `deliveredAt` is set once the app has acted
/// on the event (a notification, the child's card, typing it into a prompt
/// is then retried from the ledger), so a relaunch doesn't act twice.
struct MissionEvent: Codable, Equatable {
    enum Kind: String, Codable {
        case question
        case completed
        case response
        /// Parent → child (`tell`): typed into the child's prompt once it
        /// is free, which sets `childConsumedAt`.
        case instruction
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
    /// Separate from `deliveredAt`: whether the parent agent CLI has
    /// consumed this child event. UI display must not consume an agent inbox.
    var parentConsumedAt: TimeInterval?
    /// Set on a response once the child's `ask` has printed it, or Nirux
    /// typed it into the child's prompt. Asking the same question again
    /// replays the answer for a short window (a rerun after a cut-off
    /// command), then starts a new exchange. Set on an instruction once
    /// Nirux typed it into the child's prompt.
    var childConsumedAt: TimeInterval?
    /// Set on a question or a completion once Nirux typed it into the
    /// parent's prompt. Builds before it ignore the key.
    var parentTypedAt: TimeInterval?
    /// On a question: the child ended its turn after asking (a Claude Code
    /// child), so Nirux types the answer into its prompt. A child whose
    /// `ask` waits for the answer (Codex), or a question an older build
    /// recorded, leaves it nil.
    var expectsTypedAnswer: Bool?
    /// On a response: the user wrote it in Nirux, not the parent agent.
    var answeredByUser: Bool?
    /// On a question: what blocks the child (`ask --kind`). Nil: it didn't say.
    var questionKind: QuestionKind?
    /// On a question: the answer the child would pick (`ask --recommend`),
    /// one line; for an `access` question, what is needed and where.
    var recommendation: String?
    /// On a response: it is the question's recommendation, accepted.
    var acceptedRecommendation: Bool?
    /// On a question: the parent (a space's Lead, `ask_user`) handed it to
    /// the user, for this reason. Its row turns amber at once.
    var handedToUserBecause: String?
    /// When, epoch seconds; nil on one an older build handed over.
    var handedToUserAt: TimeInterval?
    /// On an instruction: Nirux types it at the child's next free prompt
    /// until then (`MissionEventCLI.instructionLifetime` after it was sent).
    /// Nil on one an older build recorded, which had an hour.
    var typableUntil: TimeInterval?
    /// On an instruction: the conversation its child's `claude` held when
    /// Nirux recorded it. A `claude` holding it after a restart (resuming
    /// it) takes it too.
    var childSessionID: String?
    /// On an instruction still untyped `MissionEventCLI.instructionHeldNotice`
    /// after it was sent: when its sender heard what held it.
    var heldNoticeAt: TimeInterval?
    /// On an instruction Nirux gave up untyped (its time ran out, or its
    /// child can't take it any more): when, its sender told.
    var expiredAt: TimeInterval?
    /// On an instruction: the space's Lead that sent it on this Mission,
    /// whose parent is another agent. Its held and given-up lines go to
    /// the Lead, and Nirux types it under a line saying it's the Lead's.
    var leadSender: NewTask.MissionParent?

    /// What blocks a child that asks, so the parent or the user settles it
    /// in one step. Open: a kind a later build adds decodes here too, as its
    /// raw value, instead of making the whole ledger unreadable.
    struct QuestionKind: RawRepresentable, Codable, Hashable {
        let rawValue: String

        /// A choice the task leaves open.
        static let decision = QuestionKind(rawValue: "decision")
        /// Something only a person can give: a login, a secret, a permission.
        static let access = QuestionKind(rawValue: "access")
        /// The task contradicts the code or itself.
        static let specMismatch = QuestionKind(rawValue: "spec-mismatch")
        /// The kinds `ask --kind` takes.
        static let known = [decision, access, specMismatch]

        init(rawValue: String) {
            self.rawValue = rawValue
        }

        init(from decoder: Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// The recommendation a reply may send as the answer: an access
    /// question's says what is needed, which accepting doesn't give, and a
    /// kind this build doesn't know may be like it.
    var acceptableRecommendation: String? {
        guard let kind = questionKind else { return recommendation }
        return [.decision, .specMismatch].contains(kind) ? recommendation : nil
    }

    /// Until when Nirux may type this instruction.
    var instructionDeadline: TimeInterval {
        typableUntil ?? timestamp + MissionEventCLI.olderInstructionLifetime
    }

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
        childConsumedAt: TimeInterval? = nil,
        parentTypedAt: TimeInterval? = nil,
        expectsTypedAnswer: Bool? = nil,
        answeredByUser: Bool? = nil
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
        self.parentTypedAt = parentTypedAt
        self.expectsTypedAnswer = expectsTypedAnswer
        self.answeredByUser = answeredByUser
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
    /// The parent is a space's Lead (see `Mission.reportsToLead`).
    var reportsToLead = false
    /// The parent is a task's agent and its tools (see `Mission.reportsToTask`).
    var reportsToTask = false
    /// A Lead's tells to a task that doesn't report to it (see `Mission.oneWay`).
    var oneWay = false
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
        guard enabled || request.reportsToLead || request.reportsToTask || request.oneWay,
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
            events: [],
            reportsToLead: request.reportsToLead ? true : nil,
            reportsToTask: request.reportsToTask ? true : nil,
            oneWay: request.oneWay ? true : nil
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
    /// reports must match the child; responses, instructions and
    /// acknowledgements must match the parent, and a response or an
    /// acknowledgement must reference a real pending child event.
    func accept(_ incoming: MissionEvent, enabled: Bool) -> AcceptedEvent? {
        guard case let .accepted(event) = process(incoming, enabled: enabled) else { return nil }
        return event
    }

    // This single transition keeps validation and its in-memory mutation
    // adjacent so persistence commits exactly one candidate Mission ledger.
    /// `fromUser` is the trusted UI path (`respond`): only it may mark a
    /// response as the user's; `lead`, the app's (a Lead's `tell`): only it
    /// may mark an instruction as a Lead's.
    func process(_ incoming: MissionEvent, enabled: Bool, fromUser: Bool = false, lead: NewTask.MissionParent? = nil) -> ProcessingResult {
        guard ensureLoaded() else { return .persistenceFailed }
        guard incoming.deliveredAt == nil,
              incoming.parentConsumedAt == nil,
              incoming.childConsumedAt == nil,
              incoming.parentTypedAt == nil,
              Self.isIdentifier(incoming.id),
              Self.isIdentifier(incoming.missionID),
              Self.isIdentifier(incoming.childWorkspaceID),
              Self.isIdentifier(incoming.childAgentUUID),
              let index = missions.firstIndex(where: { $0.id == incoming.missionID }),
              missions[index].isCarried(handoffsEnabled: enabled),
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
        guard MissionEventCLI.fits(message, limit: MissionEventCLI.maxLength(of: incoming.kind)) else {
            return .rejected
        }
        // A recommendation this build can't carry (a later CLI's) stays out;
        // the question goes through.
        let recommendation = incoming.kind == .question ? incoming.recommendation.flatMap(MissionEventCLI.recommendation) : nil

        var updated = missions
        let fromParent = incoming.parentWorkspaceID == missions[index].parentWorkspaceID
            && incoming.parentAgentUUID == missions[index].parentAgentUUID

        switch incoming.kind {
        case .question, .completed:
            guard missions[index].status == .active,
                  missions[index].oneWay != true,
                  incoming.parentWorkspaceID == nil,
                  incoming.parentAgentUUID == nil,
                  incoming.inReplyTo == nil
            else { return .rejected }

        case .response:
            guard missions[index].status == .active,
                  fromParent,
                  let questionID = incoming.inReplyTo,
                  let questionIndex = missions[index].events.firstIndex(where: {
                      $0.id == questionID && $0.kind == .question
                  }),
                  !missions[index].events.contains(where: {
                      $0.kind == .response && $0.inReplyTo == questionID
                  }),
                  incoming.acceptedRecommendation != true
                      || missions[index].events[questionIndex].acceptableRecommendation == message
            else { return .rejected }
            updated[index].events[questionIndex].parentConsumedAt = incoming.timestamp

        case .instruction:
            // Any status: a follow-up after `completed` reopens the Mission
            // once it is typed (see `markInstructionTyped`).
            guard fromParent, incoming.inReplyTo == nil else { return .rejected }

        case .acknowledged:
            return processAcknowledgement(incoming, missionIndex: index)
        }

        var event = MissionEvent(
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
            parentConsumedAt: nil,
            // A Claude Code child's `ask` ends its turn (MissionEventCLI.ask):
            // the store decides from the recorded child, not from the queue.
            expectsTypedAnswer: incoming.kind == .question
                && missions[index].childAgentKind == NiruxApp.WorkspaceAgent.claude.rawValue ? true : nil,
            answeredByUser: incoming.kind == .response && fromUser ? true : nil
        )
        if event.kind == .instruction {
            event.typableUntil = event.timestamp + MissionEventCLI.instructionLifetime
            event.leadSender = lead
        }
        if event.kind == .question {
            // A kind this build doesn't know (a later CLI's) may not be an
            // answer: it stays out with its recommendation.
            let known = incoming.questionKind.map(MissionEvent.QuestionKind.known.contains) ?? true
            event.questionKind = known ? incoming.questionKind : nil
            event.recommendation = known ? recommendation : nil
        }
        if event.kind == .response, incoming.acceptedRecommendation == true {
            event.acceptedRecommendation = true
        }
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

    /// Trusted UI response path: the user answers instead of the parent. It
    /// uses the same validation and persistence as a parent-agent CLI
    /// response, then returns the accepted event for the caller to act on.
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
        guard case let .accepted(accepted) = process(response, enabled: enabled, fromUser: true) else { return nil }
        return accepted
    }

    /// The Lead's `ask_user`: a question that still waits for an answer
    /// goes to the user, with the Lead's reason. Nil when there is no such
    /// question, or the ledger couldn't be saved.
    func handToUser(questionID: String, because why: String, now: TimeInterval = Date().timeIntervalSince1970) -> Mission? {
        guard ensureLoaded(),
              let missionIndex = missions.firstIndex(where: { $0.events.contains { $0.id == questionID && $0.kind == .question } }),
              missions[missionIndex].status == .active,
              !missions[missionIndex].events.contains(where: { $0.kind == .response && $0.inReplyTo == questionID }),
              let eventIndex = missions[missionIndex].events.firstIndex(where: { $0.id == questionID })
        else { return nil }
        var updated = missions
        updated[missionIndex].events[eventIndex].handedToUserBecause = why
        updated[missionIndex].events[eventIndex].handedToUserAt = now
        updated[missionIndex].updatedAt = now
        return commit(updated) ? updated[missionIndex] : nil
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

    /// The instruction is in the child's prompt: the child has work again,
    /// so its Mission is active, even after `completed`.
    @discardableResult
    func markInstructionTyped(
        eventID: String, at timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        for missionIndex in missions.indices {
            guard let eventIndex = missions[missionIndex].events.firstIndex(where: {
                $0.id == eventID && $0.kind == .instruction && $0.childConsumedAt == nil
            }) else { continue }
            var updated = missions
            updated[missionIndex].events[eventIndex].childConsumedAt = timestamp
            updated[missionIndex].status = .active
            updated[missionIndex].updatedAt = timestamp
            return commit(updated)
        }
        return false
    }

    /// Messages Nirux may type into an agent's prompt, oldest first: a
    /// child's question or completion into its parent's, an answer or an
    /// instruction into the child's. Questions and completions are typed
    /// within `MissionEventCLI.parentMessageLifetime` (a parent busy longer
    /// leaves the question to the user, see `waitingQuestion`), instructions
    /// until `MissionEvent.instructionDeadline` unless given up; an answer is typed whenever the child is
    /// free, since the child ended its turn to wait for it.
    func pendingPromptDeliveries(now: TimeInterval = Date().timeIntervalSince1970) -> [AcceptedEvent] {
        missions.flatMap { mission in
            mission.events.compactMap { event -> AcceptedEvent? in
                Self.isPendingDelivery(event, in: mission, now: now) ? AcceptedEvent(mission: mission, event: event) : nil
            }
        }.sorted { $0.event.timestamp < $1.event.timestamp }
    }

    /// The answer waiting to be typed into this child's prompt, if any.
    func pendingAnswer(childWorkspaceID: String, childAgentUUID: String) -> AcceptedEvent? {
        missions.lazy
            .filter { $0.childWorkspaceID == childWorkspaceID && $0.childAgentUUID == childAgentUUID }
            .flatMap { mission in
                mission.events.lazy.filter {
                    $0.kind == .response && Self.isPendingDelivery($0, in: mission, now: 0)
                }.map { AcceptedEvent(mission: mission, event: $0) }
            }
            .first
    }

    private static func isPendingDelivery(_ event: MissionEvent, in mission: Mission, now: TimeInterval) -> Bool {
        switch event.kind {
        case .instruction:
            return event.childConsumedAt == nil && event.expiredAt == nil && now < event.instructionDeadline
        case .response:
            // Not once the child completed after asking: a `tell` may have
            // reopened the Mission since, for other work.
            guard mission.status == .active, event.childConsumedAt == nil,
                  let question = mission.events.first(where: { $0.id == event.inReplyTo && $0.kind == .question }),
                  question.expectsTypedAnswer == true
            else { return false }
            return !mission.events.contains { $0.kind == .completed && $0.timestamp > question.timestamp }
        case .question:
            // Not once its parent handed it to the user (`ask_user`).
            return mission.status == .active && event.parentTypedAt == nil && event.parentConsumedAt == nil
                && event.handedToUserBecause == nil
                && now - event.timestamp < MissionEventCLI.parentMessageLifetime
                && !mission.events.contains { $0.kind == .response && $0.inReplyTo == event.id }
        case .completed:
            // Not once the child got more work from the parent: it moved on.
            return event.parentTypedAt == nil && event.parentConsumedAt == nil
                && now - event.timestamp < MissionEventCLI.parentMessageLifetime
                && !mission.events.contains {
                    $0.kind == .instruction && $0.timestamp > event.timestamp && $0.childConsumedAt != nil
                }
        case .acknowledged:
            return false
        }
    }

    /// The message is in its recipient's prompt. Recorded before typing, so
    /// a failed save never types it twice. A completion the parent read
    /// this way is consumed, as if `receive` had printed it; a question
    /// stays open until it is answered.
    @discardableResult
    func markTyped(
        _ delivery: AcceptedEvent, at timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        let eventID = delivery.event.id
        if delivery.event.kind == .instruction { return markInstructionTyped(eventID: eventID, at: timestamp) }
        guard let missionIndex = missions.firstIndex(where: { $0.id == delivery.mission.id }),
              let eventIndex = missions[missionIndex].events.firstIndex(where: { $0.id == eventID })
        else { return false }
        var updated = missions
        switch delivery.event.kind {
        case .response:
            guard updated[missionIndex].events[eventIndex].childConsumedAt == nil else { return false }
            updated[missionIndex].events[eventIndex].childConsumedAt = timestamp
        case .question, .completed:
            guard updated[missionIndex].events[eventIndex].parentTypedAt == nil else { return false }
            updated[missionIndex].events[eventIndex].parentTypedAt = timestamp
            if delivery.event.kind == .completed, updated[missionIndex].events[eventIndex].parentConsumedAt == nil {
                updated[missionIndex].events[eventIndex].parentConsumedAt = timestamp
            }
        case .instruction, .acknowledged:
            return false
        }
        return commit(updated)
    }

    /// The oldest question this child asked that nobody answered yet, in an
    /// active Mission: the child waits for it.
    func waitingQuestion(childWorkspaceID: String, childAgentUUID: String) -> AcceptedEvent? {
        missions.lazy
            .filter {
                $0.status == .active && $0.childWorkspaceID == childWorkspaceID && $0.childAgentUUID == childAgentUUID
            }
            .flatMap { mission in
                mission.events.lazy.filter { question in
                    question.kind == .question && question.parentConsumedAt == nil
                        && !mission.events.contains { $0.kind == .response && $0.inReplyTo == question.id }
                }.map { AcceptedEvent(mission: mission, event: $0) }
            }
            .min { $0.event.timestamp < $1.event.timestamp }
    }

    /// The instructions not typed nor given up yet, for the sweep that
    /// tells their senders (`NiruxShellView.sweepWaitingInstructions`).
    func untypedInstructions() -> [AcceptedEvent] {
        guard ensureLoaded() else { return [] }
        return missions.flatMap { mission in
            mission.events.filter { $0.kind == .instruction && $0.childConsumedAt == nil && $0.expiredAt == nil }
                .map { AcceptedEvent(mission: mission, event: $0) }
        }
    }

    /// Records the conversation an instruction is for (`MissionEvent.childSessionID`),
    /// unless one is already.
    @discardableResult
    func noteConversation(_ sessionID: String, ofInstruction eventID: String) -> Bool {
        guard ensureLoaded(),
              let missionIndex = missions.firstIndex(where: { $0.events.contains { $0.id == eventID } }),
              let eventIndex = missions[missionIndex].events.firstIndex(where: { $0.id == eventID && $0.kind == .instruction }),
              missions[missionIndex].events[eventIndex].childSessionID == nil
        else { return false }
        var updated = missions
        updated[missionIndex].events[eventIndex].childSessionID = sessionID
        return commit(updated)
    }

    /// Marks the instructions whose sender heard they still wait, and those
    /// Nirux gave up. False when the ledger isn't written.
    func noteInstructions(heldNotice: Set<String>, expired: Set<String>, at now: TimeInterval) -> Bool {
        guard ensureLoaded() else { return false }
        var updated = missions
        for missionIndex in updated.indices {
            for eventIndex in updated[missionIndex].events.indices where updated[missionIndex].events[eventIndex].kind == .instruction {
                let id = updated[missionIndex].events[eventIndex].id
                if heldNotice.contains(id) { updated[missionIndex].events[eventIndex].heldNoticeAt = now }
                if expired.contains(id) { updated[missionIndex].events[eventIndex].expiredAt = now }
            }
        }
        return commit(updated)
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
