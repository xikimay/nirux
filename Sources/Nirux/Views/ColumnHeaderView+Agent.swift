import AppKit

/// What a terminal column's header shows of its agent: the agent's icon,
/// and a status pill only while the agent works, waits on the user (the
/// only amber), or stopped on an error. A finished turn or a plain shell
/// shows no pill.
extension ColumnHeaderView.Status {
    /// `wait` is what blocks the agent on the user now
    /// (`PtySession.agentBlockedWait`): unlike `column.agentStatus`, it
    /// stays while the user looks at the column, as long as the dialog is
    /// open, like ⌘J and the sidebar's dialog block. Its mark is the state
    /// icon its row draws, through the row's own path
    /// (`StateIcon(mark:reason:station:)`, `WorkspaceInfo.waitReason`), at
    /// its task's `station`.
    @MainActor
    static func agent(
        _ column: ColumnInfo, wait: AgentWait?, now: TimeInterval, station: BoardStages.Station? = nil
    ) -> Self? {
        if let deferred = column.deferredAgent {
            return Self("not resumed", tone: .neutral, symbol: Theme.Symbol.resume, toolTip: deferred.tooltip)
        }
        let icon = { (mark: SidebarRowMark) in
            StateIcon(mark: mark, reason: mark == .needsYou ? WorkspaceInfo.waitReason(of: column) : nil, station: station)
        }
        if let wait {
            return attention(wait.reason, waited: now - wait.since, icon: icon)
        }
        switch column.agentStatus {
        case .idle:
            return nil
        case .working:
            return Self(column.elapsedDisplay.map { "working · \($0)" } ?? "working", tone: .working, icon: icon(.working))
        case .needsAttention:
            // An agent without hooks that falls silent may sit in its own
            // approval prompt: amber, so a dialog is never missed.
            guard let reason = column.attentionReason else {
                return Self(
                    "needs you", tone: .waiting, icon: icon(.needsYou),
                    toolTip: "The agent went quiet: it may wait for you, or have finished."
                )
            }
            return attention(reason, waited: nil, icon: icon)
        }
    }

    /// A dialog's pill reads how long it has waited, from a minute on.
    private static func attention(
        _ reason: AgentAttentionReason, waited: TimeInterval?, icon: (SidebarRowMark) -> StateIcon
    ) -> Self? {
        var dialog = reason
        if case .stillWaiting(let inner, _) = reason { dialog = inner }
        let detail = dialog.detailLine.flatMap { AgentText.clean($0, maxLength: 300) }
        let toolTip = [dialog.headline, detail].compactMap { $0 }.joined(separator: " — ")
        if dialog.isBlockingDialog {
            let duration = waited.flatMap { $0 >= 60 ? $0.shortDuration : nil }
            return Self(
                [dialog.shortLabel, duration].compactMap { $0 }.joined(separator: " · "),
                tone: .waiting, icon: icon(.needsYou), toolTip: toolTip
            )
        }
        if dialog.isFailure {
            let text = switch dialog {
            case .exitedMidTurn, .silent: dialog.shortLabel
            default: "stopped"
            }
            return Self(text, tone: .error, icon: icon(.error), toolTip: toolTip)
        }
        switch dialog {
        case .message, .askedInReply:
            return Self(dialog.shortLabel, tone: .waiting, icon: icon(.needsYou), toolTip: toolTip)
        default:
            return nil
        }
    }
}

extension ColumnHeaderView.Icon {
    /// A terminal's icon: the type's, or the logo of the agent running in
    /// it (its app icon, else its symbol).
    @MainActor
    static func terminal(processName: String?) -> Self {
        guard let agent = processName.flatMap(CodingAgent.init(rawValue:)) else { return .symbol(Theme.Symbol.terminal) }
        return agent.appIcon.map(Self.image) ?? .symbol(agent.symbolName)
    }
}
