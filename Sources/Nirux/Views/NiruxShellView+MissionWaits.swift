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
        case .working?: "it's working; they go in when its turn ends"
        case .failedTurn?: "its last turn failed; they go in after its next turn"
        case .draft?: "keys reached its prompt since its last prompt, so it may hold a draft; they go in after its next prompt"
        case .verdict?: "its last turn end is still being read"
        case nil: "its prompt is free, and Nirux types them now"
        }
        return "Mission messages not typed into this agent's prompt yet: \(why)."
    }
}

/// What the shell keeps of waiting messages between refreshes.
struct MissionWaitState {
    /// The last check, and when it ran: the sidebar asks several times a
    /// second, and the setting it reads is on disk.
    var shown: [ObjectIdentifier: SidebarWaitingMessages] = [:]
    var checkedAt: TimeInterval?
    /// "<message id> <reason>" of each line written to the log, while the
    /// message waits: one line per message and reason.
    var logged: Set<String> = []
    var lastRetryAt: TimeInterval = 0
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

    private struct WaitingMessage {
        let column: ColumnState
        let id: String
        let kind: String
        let sentAt: TimeInterval
        let runningSince: TimeInterval
    }

    /// The Mission messages and Lead notices waiting for each column's
    /// prompt, once the oldest has waited `missionMessageStallAge` and its
    /// agent doesn't work. Each message's reason goes to the log once. A free
    /// prompt gets one more try, at most once a stuck-watch interval: a
    /// prompt can free up with no turn end to try at (a subagent's dialog
    /// closing after the turn).
    func waitingMissionMessages(
        snapshot: ProcessSnapshot, now: TimeInterval, store: MissionStore = .shared
    ) -> [ObjectIdentifier: SidebarWaitingMessages] {
        if snapshot.isEmpty { return missionWaits.shown }
        if let checkedAt = missionWaits.checkedAt, (0..<Self.missionWaitCheckInterval).contains(now - checkedAt) {
            return missionWaits.shown
        }
        missionWaits.checkedAt = now
        var waiting: [ObjectIdentifier: [WaitingMessage]] = [:]
        let handoffsEnabled = Self.currentMissionHandoffsEnabled()
        for delivery in store.pendingPromptDeliveries(now: now)
        where delivery.mission.isCarried(handoffsEnabled: handoffsEnabled) {
            guard let column = missionRecipient(of: delivery) else { continue }
            waiting[ObjectIdentifier(column), default: []].append(WaitingMessage(
                column: column, id: delivery.event.id, kind: delivery.event.kind.rawValue, sentAt: delivery.event.timestamp,
                runningSince: Self.runningSince(of: delivery.event, now: now)
            ))
        }
        for notice in pendingLeadNotices where now - notice.queuedAt < MissionEventCLI.parentMessageLifetime {
            guard let column = workspaces.first(where: { $0.id == notice.workspaceID && !$0.isClosing })?
                .columns.first(where: { $0.agentUUID == notice.agentUUID })
            else { continue }
            waiting[ObjectIdentifier(column), default: []].append(WaitingMessage(
                column: column, id: "notice-\(Int(notice.queuedAt))", kind: "notice", sentAt: notice.queuedAt, runningSince: now
            ))
        }
        var shown: [ObjectIdentifier: SidebarWaitingMessages] = [:]
        var retries = false
        for (key, messages) in waiting {
            guard let oldest = messages.min(by: { $0.sentAt < $1.sentAt }), now - oldest.sentAt >= Self.missionMessageStallAge
            else { continue }
            let refusal = oldest.column.pty.map { $0.missionPromptRefusal(runningSince: oldest.runningSince, snapshot: snapshot) }
                ?? .noClaude
            guard refusal != .working else { continue }
            shown[key] = SidebarWaitingMessages(count: messages.count, since: oldest.sentAt, refusal: refusal)
            retries = retries || refusal == nil
            let reason = refusal?.rawValue ?? "free"
            guard missionWaits.logged.insert("\(oldest.id) \(reason)").inserted else { continue }
            sideEffects.logMissionWait(
                "untyped mission message id=\(oldest.id.prefix(8)) kind=\(oldest.kind) "
                    + "agent=\(oldest.column.agentUUID?.prefix(8) ?? "-") waited=\(Int(now - oldest.sentAt))s "
                    + "reason=\(reason) waiting=\(messages.count)"
            )
        }
        let pending = Set(waiting.values.joined().map(\.id))
        missionWaits.logged = missionWaits.logged.filter { pending.contains(String($0.prefix { $0 != " " })) }
        missionWaits.shown = shown
        if retries, now - missionWaits.lastRetryAt >= Self.stuckWatchInterval {
            missionWaits.lastRetryAt = now
            DispatchQueue.main.async { [weak self] in self?.typeMissionMessages() }
        }
        return shown
    }
}
