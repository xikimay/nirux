import os
import AppKit

// MARK: - Mission messages that wait too long for a prompt: the row's line, the log, one more try

/// Mission messages waiting for an agent's prompt past
/// `NiruxShellView.missionMessageStallAge` while the agent doesn't work.
struct SidebarWaitingMessages: Hashable {
    let count: Int
    /// When the oldest was sent.
    let since: TimeInterval
    /// Why the oldest isn't typed; nil: the prompt is free.
    let refusal: AgentPromptRefusal?
    /// The prompt looks free, yet the tries at typing failed.
    var untypable = false
    /// "2 messages waiting since 22:21 · a dialog may be open", written at
    /// the check: the day shows once it is another.
    let line: String

    init(count: Int, since: TimeInterval, refusal: AgentPromptRefusal?, untypable: Bool = false, now: TimeInterval) {
        self.count = count
        self.since = since
        self.refusal = refusal
        self.untypable = untypable
        let time = ProjectBoard.clockTime(Date(timeIntervalSince1970: since), now: Date(timeIntervalSince1970: now))
        line = "\(count == 1 ? "1 message" : "\(count) messages") waiting since \(time) · \(Self.why(refusal, untypable: untypable).short)"
    }

    var tooltip: String {
        "Mission messages not typed into this agent's prompt yet: \(Self.why(refusal, untypable: untypable).long)."
    }

    /// Why they wait: a few words for the row, the whole of it for the tooltip.
    static func why(_ refusal: AgentPromptRefusal?, untypable: Bool) -> (short: String, long: String) {
        switch refusal {
        case .noClaude?: ("no Claude Code there", "its terminal doesn't run Claude Code")
        case .restarted?: (
            "its Claude Code restarted",
            "its Claude Code restarted since, and Nirux types a message sent to the one before into no other"
        )
        case .noPromptYet?: (
            "no prompt since it started",
            "its Claude Code hasn't taken a prompt since it started; they go in after its first one"
        )
        case .dialog?: ("a dialog may be open", "a dialog may be open there; they go in once it closes and the turn ends")
        case .failedTurn?: ("its last turn failed", "its last turn failed; they go in after its next turn")
        case .draft?: (
            "held by a draft until its next prompt",
            "keys reached its prompt since its last prompt, so it may hold a draft; they go in after its next prompt"
        )
        case .working?, .verdict?: ("its turn isn't over", "its turn isn't over yet")
        case nil where untypable: (
            "typing failed",
            "its prompt looks free, but typing them failed; they go in at its next turn end if they can"
        )
        case nil: ("Nirux tries again", "its prompt looks free, and Nirux tries again")
        }
    }
}

/// What the shell keeps of waiting messages between refreshes.
struct MissionWaitState {
    /// The last check, by column, and when it ran: the sidebar asks several
    /// times a second, and the setting it reads is on disk.
    var shown: [UUID: SidebarWaitingMessages] = [:]
    var checkedAt: TimeInterval?
    /// "<message id> <reason>" of each line written to the log, while the
    /// message waits: one line per message and reason.
    var logged: Set<String> = []
    var lastRetryAt: TimeInterval = 0
    /// Tries at typing each message whose prompt looked free.
    var tries: [String: Int] = [:]
    /// Mission handoffs, read from disk when the waiting messages change.
    var handoffsEnabled: (for: Set<String>, enabled: Bool)?
    /// When Nirux last typed into each column: until that prompt goes in, its
    /// text reads as a draft.
    var typedAt: [UUID: TimeInterval] = [:]
    /// Mission messages Nirux is typing (a long paste, then Enter), or typed
    /// without being able to record it: none is typed or given up twice.
    var typing: Set<String> = []

    /// Nirux typed into `column`'s prompt: it says nothing of it until the
    /// next check.
    mutating func noteTyped(into column: ColumnState, at time: TimeInterval) {
        typedAt[column.id] = time
        shown[column.id] = nil
    }
}

/// `log show --predicate 'subsystem == "com.xikimay.nirux" AND category == "missions"'`.
enum MissionWaitLog {
    static let logger = Logger(subsystem: "com.xikimay.nirux", category: "missions")
}

extension NiruxShellView {
    /// How long a message may wait for the prompt of an agent that doesn't
    /// work before its row says so and the log says why: well past a turn
    /// end's verdict.
    nonisolated static let missionMessageStallAge: TimeInterval = 180
    nonisolated static let missionWaitCheckInterval: TimeInterval = 5
    /// How long a message may wait over a draft, or at a free prompt, before
    /// the log says why: past a turn end's verdict.
    nonisolated static let missionWaitLogAge: TimeInterval = 30
    /// What Nirux types goes in within a second: a draft before then is
    /// its own text.
    nonisolated static let typedTextGrace: TimeInterval = 10

    /// Tries at typing a message whose prompt looks free, before its row
    /// says typing failed.
    nonisolated static let missionTypingTries = 3

    private struct WaitingMessage {
        let id: String
        let kind: String
        let sentAt: TimeInterval
        let runningSince: TimeInterval
    }

    /// Tells a `tell`'s sender, once, what holds it when it is still
    /// untyped `MissionEventCLI.instructionHeldNotice` after it was sent;
    /// gives it up, telling the sender, once its task closed, its Claude Code
    /// restarted on another conversation, or its day ran out. One whose day ran out long ago (an
    /// older build's, kept an hour) is given up silently.
    func sweepWaitingInstructions(now: TimeInterval, snapshot: ProcessSnapshot, store: MissionStore = .shared) {
        var held: [(delivery: MissionStore.AcceptedEvent, text: String)] = []
        var givenUp: [(delivery: MissionStore.AcceptedEvent, text: String)] = []
        // Read once, and only for a notice that names what holds a message.
        lazy var handoffsEnabled = missionWaits.handoffsEnabled?.enabled ?? Self.currentMissionHandoffsEnabled()
        for delivery in store.untypedInstructions() where !missionWaits.typing.contains(delivery.event.id) {
            let (mission, event) = (delivery.mission, delivery.event)
            let child = missionEnd(mission, parent: false)
            let sent = ProjectBoard.clockTime(Date(timeIntervalSince1970: event.timestamp), now: Date(timeIntervalSince1970: now))
            let yours = "Your message to “\(MissionPromptText.quoted(child?.workspace.title ?? mission.branch))” (sent \(sent))"
            guard let child, !child.workspace.isClosing else {
                givenUp.append((delivery, "\(yours) was never typed: its task closed first."))
                continue
            }
            guard let column = child.column else {
                givenUp.append((delivery, "\(yours) was never typed: its agent's terminal closed first."))
                continue
            }
            let since = runningSince(of: event, in: column, snapshot: snapshot, now: now)
            let refusal = column.pty?.missionPromptRefusal(runningSince: since, snapshot: snapshot) ?? .noClaude
            let holder = {
                mission.childAgentKind != NiruxApp.WorkspaceAgent.claude.rawValue ? "its agent hasn't collected it"
                    : !mission.isCarried(handoffsEnabled: handoffsEnabled) ? "Mission handoffs are off"
                    : SidebarWaitingMessages.why(refusal, untypable: self.missionWaits.tries[event.id, default: 0] >= Self.missionTypingTries).short
            }
            // Restarted, `runningSince` says, on another conversation once it confirmed one.
            let other = conversation(of: column, foreground: column.pty?.foregroundProcess(snapshot: snapshot)) != nil
            if refusal == .restarted, other, mission.childAgentKind == NiruxApp.WorkspaceAgent.claude.rawValue {
                givenUp.append((delivery, "\(yours) won't be typed: its Claude Code restarted on another conversation, and Nirux "
                    + "types a message only into the conversation it was sent to. Send it again if it still applies."))
            } else if now >= event.instructionDeadline {
                // One an older build recorded had an hour.
                let span = event.typableUntil == nil ? "an hour" : "a day"
                givenUp.append((delivery, "\(yours) was never typed: its prompt wasn't free for \(span) (\(holder())). "
                    + "Send it again if it still applies."))
            } else if event.heldNoticeAt == nil, now - event.timestamp >= MissionEventCLI.instructionHeldNotice {
                held.append((delivery, "\(yours) isn't typed yet: \(holder()). Nirux keeps it for its next free prompt, "
                    + "a day at most."))
            }
        }
        guard !(held.isEmpty && givenUp.isEmpty), store.noteInstructions(
            heldNotice: Set(held.map(\.delivery.event.id)), expired: Set(givenUp.map(\.delivery.event.id)), at: now
        ) else { return }
        for (delivery, text) in held + givenUp where now - delivery.event.instructionDeadline < MissionEventCLI.parentMessageLifetime {
            let sender = delivery.event.leadSender
                ?? NewTask.MissionParent(workspaceID: delivery.mission.parentWorkspaceID, agentUUID: delivery.mission.parentAgentUUID)
            tellProposer(sender, text)
        }
    }

    /// Keeps, for the sidebar to read (`missionWaits.shown`, by
    /// `ColumnState.id`), the Mission messages and Lead notices waiting for
    /// each column's prompt past `missionMessageStallAge` while its agent
    /// doesn't work: not those an agent other than Claude Code collects
    /// itself, nor those Nirux types into no `claude` running now (sent to
    /// one since restarted, or to one without Nirux's hooks). Each message's
    /// reason, with what it was read from, goes to the log once
    /// (`missionWaitLogAge`). A free prompt gets a few more tries
    /// (`missionTypingTries`), at most once a stuck-watch interval: a prompt
    /// can free up with no turn end to try at (a subagent's dialog closing
    /// after the turn). The heartbeat runs it, the stuck watch in the
    /// background.
    func checkMissionWaits(snapshot: ProcessSnapshot, now: TimeInterval, store: MissionStore = .shared) {
        guard !snapshot.isEmpty else { return }
        if let checkedAt = missionWaits.checkedAt, (0..<Self.missionWaitCheckInterval).contains(now - checkedAt) { return }
        missionWaits.checkedAt = now
        sweepWaitingInstructions(now: now, snapshot: snapshot, store: store)
        missionWaits.typedAt = missionWaits.typedAt.filter { now - $0.value < Self.typedTextGrace }
        var waiting: [UUID: (column: ColumnState, messages: [WaitingMessage])] = [:]
        func add(_ column: ColumnState?, _ message: WaitingMessage) {
            guard let column else { return }
            waiting[column.id, default: (column, [])].messages.append(message)
        }
        let deliveries = store.pendingPromptDeliveries(now: now)
        let deliveryIDs = Set(deliveries.map(\.event.id))
        if !deliveries.isEmpty {
            let handoffsEnabled = missionWaits.handoffsEnabled.flatMap { $0.for == deliveryIDs ? $0.enabled : nil }
                ?? Self.currentMissionHandoffsEnabled()
            missionWaits.handoffsEnabled = (deliveryIDs, handoffsEnabled)
            for delivery in deliveries where delivery.mission.isCarried(handoffsEnabled: handoffsEnabled) {
                // A child other than Claude Code collects its own.
                guard Self.goesToParent(delivery.event)
                    || delivery.mission.childAgentKind == NiruxApp.WorkspaceAgent.claude.rawValue
                else { continue }
                let recipient = missionRecipient(of: delivery)
                add(recipient, WaitingMessage(
                    id: delivery.event.id, kind: delivery.event.kind.rawValue, sentAt: delivery.event.timestamp,
                    runningSince: runningSince(of: delivery.event, in: recipient, snapshot: snapshot, now: now)
                ))
            }
        }
        for notice in pendingLeadNotices where now - notice.queuedAt < MissionEventCLI.parentMessageLifetime {
            add(workspaces.first { $0.id == notice.workspaceID && !$0.isClosing }?.columns.first { $0.agentUUID == notice.agentUUID },
                WaitingMessage(id: "notice-\(notice.queuedAt)", kind: "notice", sentAt: notice.queuedAt, runningSince: now))
        }
        var shown: [UUID: SidebarWaitingMessages] = [:]
        var retries: [String] = []
        for (id, entry) in waiting {
            let pty = entry.column.pty
            let foreground = pty?.foregroundProcess(snapshot: snapshot)
            if let name = foreground?.name, name != "claude", AgentStatusMachine.isRecognizedAgentProcess(name) { continue }
            let refused = entry.messages.compactMap { message -> (message: WaitingMessage, refusal: AgentPromptRefusal?)? in
                let refusal = pty.map { $0.missionPromptRefusal(runningSince: message.runningSince, snapshot: snapshot) } ?? .noClaude
                guard refusal != .draft || missionWaits.typedAt[id] == nil else { return nil }
                return (message, refusal)
            }
            // A draft or a free prompt, which nothing on screen explains, says
            // so within seconds; anything else, a long turn too, after a
            // stall's length.
            let overdue = refused.filter { message, refusal in
                now - message.sentAt >= (refusal == nil || refusal == .draft ? Self.missionWaitLogAge : Self.missionMessageStallAge)
            }
            retries += overdue.filter { $0.refusal == nil && missionWaits.tries[$0.message.id, default: 0] < Self.missionTypingTries }
                .map(\.message.id)
            for (message, refusal) in overdue {
                let reason = refusal?.rawValue ?? "free"
                guard missionWaits.logged.insert("\(message.id) \(reason)").inserted else { continue }
                let waited = Int(min(now - message.sentAt, MissionEventCLI.parentMessageLifetime * 24))
                sideEffects.logMissionWait(
                    "untyped mission message id=\(message.id.prefix(8)) kind=\(message.kind) "
                        + "agent=\(entry.column.agentUUID?.prefix(8) ?? "-") waited=\(waited)s reason=\(reason) messages=\(refused.count) "
                        + "fg=\(foreground.map { "\($0.name)/\(Int(max(now - $0.instance.startedAt, 0)))s" } ?? "-") "
                        + (pty?.missionPromptFacts(now: now) ?? "")
                )
            }
            let typable = refused.filter {
                $0.refusal != .working && $0.refusal != .restarted && ($0.refusal != .noPromptYet || pty?.agentHookKind == "claude")
            }
            guard typable.contains(where: { now - $0.message.sentAt >= Self.missionMessageStallAge }),
                  let oldest = typable.min(by: { $0.message.sentAt < $1.message.sentAt })
            else { continue }
            shown[id] = SidebarWaitingMessages(
                count: typable.count, since: oldest.message.sentAt, refusal: oldest.refusal,
                untypable: oldest.refusal == nil && missionWaits.tries[oldest.message.id, default: 0] >= Self.missionTypingTries,
                now: now
            )
        }
        let pending = Set(waiting.values.flatMap { $0.messages.map(\.id) })
        missionWaits.logged = missionWaits.logged.filter { pending.contains(String($0.prefix { $0 != " " })) }
        missionWaits.tries = missionWaits.tries.filter { pending.contains($0.key) }
        missionWaits.shown = shown
        if !retries.isEmpty, now - missionWaits.lastRetryAt >= Self.stuckWatchInterval {
            missionWaits.lastRetryAt = now
            for retry in retries { missionWaits.tries[retry, default: 0] += 1 }
            DispatchQueue.main.async { [weak self] in self?.typeMissionMessages() }
        }
    }
}
