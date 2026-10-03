import AppKit

/// What a terminal column's header shows of its agent: the agent's icon,
/// and a status pill only while the agent works, waits on the user (the
/// only amber), or stopped on an error. A finished turn or a plain shell
/// shows no pill.
extension ColumnHeaderView.Status {
    /// `wait` is what blocks the agent on the user now
    /// (`PtySession.agentBlockedWait`): unlike `column.agentStatus`, it
    /// stays while the user looks at the column, as long as the dialog is
    /// open, like ⌘J and the sidebar's dialog block.
    static func agent(_ column: ColumnInfo, wait: AgentWait?, now: TimeInterval) -> Self? {
        if let deferred = column.deferredAgent {
            return Self("not resumed", tone: .neutral, symbol: Theme.Symbol.resume, toolTip: deferred.tooltip)
        }
        if let wait {
            return attention(wait.reason, waited: now - wait.since)
        }
        switch column.agentStatus {
        case .idle:
            return nil
        case .working:
            return Self(column.elapsedDisplay.map { "working · \($0)" } ?? "working", tone: .working)
        case .needsAttention:
            // An agent without hooks that falls silent may sit in its own
            // approval prompt: amber, so a dialog is never missed.
            guard let reason = column.attentionReason else {
                return Self("needs you", tone: .waiting, toolTip: "The agent went quiet: it may wait for you, or have finished.")
            }
            return attention(reason, waited: nil)
        }
    }

    /// A dialog's pill reads how long it has waited, from a minute on.
    private static func attention(_ reason: AgentAttentionReason, waited: TimeInterval?) -> Self? {
        var dialog = reason
        if case .stillWaiting(let inner, _) = reason { dialog = inner }
        let detail = dialog.detailLine.flatMap { AgentText.clean($0, maxLength: 300) }
        let toolTip = [dialog.headline, detail].compactMap { $0 }.joined(separator: " — ")
        if dialog.isBlockingDialog {
            let duration = waited.flatMap { $0 >= 60 ? SidebarRenderer.shortDuration($0) : nil }
            let symbol: String
            if case .question = dialog { symbol = Theme.Symbol.question } else { symbol = Theme.Symbol.permission }
            return Self(
                [dialog.shortLabel, duration].compactMap { $0 }.joined(separator: " · "),
                tone: .waiting, symbol: symbol, toolTip: toolTip
            )
        }
        if dialog.isFailure {
            let text: String
            if case .exitedMidTurn = dialog { text = dialog.shortLabel } else { text = "stopped" }
            return Self(text, tone: .error, symbol: Theme.Symbol.agentError, toolTip: toolTip)
        }
        if case .message = dialog {
            return Self(dialog.shortLabel, tone: .waiting, toolTip: toolTip)
        }
        return nil
    }
}

extension ColumnHeaderView.Icon {
    /// A terminal's icon: the type's, or the logo of the agent running in
    /// it (its app icon, else its symbol).
    @MainActor
    static func terminal(processName: String?) -> Self {
        guard let processName else { return .symbol(Theme.Symbol.terminal) }
        if let image = SidebarRenderer.agentAppIcon(processName: processName) { return .image(image) }
        return .symbol(SidebarRenderer.agentSymbol(processName: processName) ?? Theme.Symbol.terminal)
    }
}
