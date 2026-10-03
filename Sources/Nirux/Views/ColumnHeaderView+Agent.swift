import AppKit

/// What a terminal column's header shows of its agent: the agent's icon,
/// and a status pill only while the agent works, waits on the user's
/// answer (the only amber), or stopped on an error. A finished turn or a
/// plain shell shows no pill.
extension ColumnHeaderView.Status {
    static func agent(_ column: ColumnInfo) -> Self? {
        if let deferred = column.deferredAgent {
            return Self("not resumed", tone: .neutral, symbol: Theme.Symbol.resume, toolTip: deferred.tooltip)
        }
        if let stuck = column.stuck {
            switch stuck {
            case .waiting(let reason, let duration):
                return waiting(reason, duration: duration, toolTip: stuck.tooltip)
            case .stoppedOnError, .exitedMidTurn:
                return failure(stuck.label, toolTip: stuck.tooltip)
            }
        }
        switch column.agentStatus {
        case .idle:
            return nil
        case .working:
            return Self(column.elapsedDisplay.map { "working · \($0)" } ?? "working", tone: .working)
        case .needsAttention:
            guard let reason = column.attentionReason else { return nil }
            return attention(reason)
        }
    }

    private static func attention(_ reason: AgentAttentionReason) -> Self? {
        let toolTip = [reason.headline, reason.detailLine.flatMap { AgentText.clean($0, maxLength: 300) }]
            .compactMap { $0 }.joined(separator: " — ")
        switch reason {
        case .permission, .question:
            return waiting(reason, duration: nil, toolTip: toolTip)
        case .stillWaiting(let dialog, _):
            return attention(dialog)
        case .apiError:
            return failure("stopped", toolTip: toolTip)
        case .exitedMidTurn:
            return failure(reason.shortLabel, toolTip: toolTip)
        case .turnFinished, .message:
            return nil
        }
    }

    private static func waiting(_ reason: AgentAttentionReason, duration: String?, toolTip: String) -> Self {
        let isQuestion: Bool
        switch reason {
        case .question: isQuestion = true
        case .stillWaiting(.question, _): isQuestion = true
        default: isQuestion = false
        }
        let text = [reason.shortLabel, duration].compactMap { $0 }.joined(separator: " · ")
        return Self(
            text, tone: .waiting, symbol: isQuestion ? Theme.Symbol.question : Theme.Symbol.permission, toolTip: toolTip
        )
    }

    private static func failure(_ text: String, toolTip: String) -> Self {
        Self(text, tone: .error, symbol: Theme.Symbol.agentError, toolTip: toolTip)
    }
}

extension ColumnHeaderView.Icon {
    /// A terminal's icon: the agent's app icon, else its symbol, else the
    /// terminal's.
    @MainActor
    static func terminal(processName: String?) -> Self {
        guard let processName else { return .symbol(Theme.Symbol.terminal) }
        if let image = SidebarRenderer.agentAppIcon(processName: processName) { return .image(image) }
        return .symbol(SidebarRenderer.agentSymbol(processName: processName) ?? Theme.Symbol.terminal)
    }
}
