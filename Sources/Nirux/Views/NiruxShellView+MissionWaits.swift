import os
import AppKit

// MARK: - Mission messages that wait too long for a prompt: the row's line, the log, one more try

/// Mission messages waiting for an agent's prompt past
/// `NiruxShellView.missionMessageStallAge` while the agent doesn't work.
struct SidebarWaitingMessages: Hashable {
    let count: Int
    /// When the oldest was sent.
    let since: TimeInterval
    /// Why the oldest isn't typed; nil: the prompt is free, and it goes in
    /// at the next try.
    let refusal: AgentPromptRefusal?

    /// "2 messages waiting since 22:21".
    func line(now: TimeInterval) -> String {
        let time = ProjectBoard.clockTime(Date(timeIntervalSince1970: since), now: Date(timeIntervalSince1970: now))
        return "\(count == 1 ? "1 message" : "\(count) messages") waiting since \(time)"
    }

    var tooltip: String {
        let why = switch refusal {
        case .noClaude?: "its terminal doesn't run Claude Code"
        case .restarted?: "its Claude Code restarted since, and Nirux types a message sent to the one before into no other"
        case .noPromptYet?: "its Claude Code hasn't taken a prompt since it started; they go in after its first one"
        case .dialog?: "a dialog may be open there; they go in once it closes and the turn ends"
        case .failedTurn?: "its last turn failed; they go in after its next turn"
        case .draft?: "keys reached its prompt since its last prompt, so it may hold a draft; they go in after its next prompt"
        case .working?, .verdict?: "its turn isn't over yet"
        case nil: "its prompt looks free, and Nirux tries again"
        }
        return "Mission messages not typed into this agent's prompt yet: \(why)."
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
    /// When Nirux last typed into each column: until that prompt goes in, its
    /// text reads as a draft.
    var typedAt: [UUID: TimeInterval] = [:]

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

    private struct WaitingMessage {
        let id: String
        let kind: String
        let sentAt: TimeInterval
        let runningSince: TimeInterval
    }

    /// The Mission messages and Lead notices waiting for each column's
    /// prompt (by `ColumnState.id`) past `missionMessageStallAge` while its
    /// agent doesn't work: not those an agent other than Claude Code
    /// collects itself, nor those Nirux types into no `claude` running now
    /// (sent to one since restarted, or to one without Nirux's hooks). Each
    /// message's reason, with what it was read from, goes to the log once
    /// (`missionWaitLogAge`). A free prompt gets one more try, at most once
    /// a stuck-watch interval: a prompt can free up with no turn end to try
    /// at (a subagent's dialog closing after the turn).
    func waitingMissionMessages(
        snapshot: ProcessSnapshot, now: TimeInterval, store: MissionStore = .shared
    ) -> [UUID: SidebarWaitingMessages] {
        if snapshot.isEmpty { return missionWaits.shown }
        if let checkedAt = missionWaits.checkedAt, (0..<Self.missionWaitCheckInterval).contains(now - checkedAt) {
            return missionWaits.shown
        }
        missionWaits.checkedAt = now
        missionWaits.typedAt = missionWaits.typedAt.filter { now - $0.value < Self.typedTextGrace }
        var waiting: [UUID: (column: ColumnState, messages: [WaitingMessage])] = [:]
        func add(_ column: ColumnState?, _ message: WaitingMessage) {
            guard let column else { return }
            waiting[column.id, default: (column, [])].messages.append(message)
        }
        let deliveries = store.pendingPromptDeliveries(now: now)
        if !deliveries.isEmpty {
            let handoffsEnabled = Self.currentMissionHandoffsEnabled()
            for delivery in deliveries where delivery.mission.isCarried(handoffsEnabled: handoffsEnabled) {
                add(missionRecipient(of: delivery), WaitingMessage(
                    id: delivery.event.id, kind: delivery.event.kind.rawValue, sentAt: delivery.event.timestamp,
                    runningSince: Self.runningSince(of: delivery.event, now: now)
                ))
            }
        }
        for notice in pendingLeadNotices where now - notice.queuedAt < MissionEventCLI.parentMessageLifetime {
            add(workspaces.first { $0.id == notice.workspaceID && !$0.isClosing }?.columns.first { $0.agentUUID == notice.agentUUID },
                WaitingMessage(id: "notice-\(notice.queuedAt)", kind: "notice", sentAt: notice.queuedAt, runningSince: now))
        }
        var shown: [UUID: SidebarWaitingMessages] = [:]
        var retries = false
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
            // so within seconds; a turn at work only once no hook came for a
            // stall's length.
            let silentFor = now - (pty?.lastAgentHookAt ?? 0)
            let overdue = refused.filter { message, refusal in
                let age = now - message.sentAt
                switch refusal {
                case nil, .draft?: return age >= Self.missionWaitLogAge
                case .working?: return age >= Self.missionMessageStallAge && silentFor >= Self.missionMessageStallAge
                default: return age >= Self.missionMessageStallAge
                }
            }
            retries = retries || overdue.contains { $0.refusal == nil }
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
            let held = refused.filter { $0.refusal != .working }
            let typable = held.filter { $0.refusal != .restarted && ($0.refusal != .noPromptYet || pty?.agentHookKind == "claude") }
            guard typable.contains(where: { now - $0.message.sentAt >= Self.missionMessageStallAge }),
                  let oldest = typable.min(by: { $0.message.sentAt < $1.message.sentAt })
            else { continue }
            shown[id] = SidebarWaitingMessages(count: typable.count, since: oldest.message.sentAt, refusal: oldest.refusal)
        }
        let pending = Set(waiting.values.flatMap { $0.messages.map(\.id) })
        missionWaits.logged = missionWaits.logged.filter { pending.contains(String($0.prefix { $0 != " " })) }
        missionWaits.shown = shown
        if retries, now - missionWaits.lastRetryAt >= Self.stuckWatchInterval {
            missionWaits.lastRetryAt = now
            DispatchQueue.main.async { [weak self] in self?.typeMissionMessages() }
        }
        return shown
    }
}
