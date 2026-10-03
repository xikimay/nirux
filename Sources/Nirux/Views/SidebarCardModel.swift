import Foundation

/// The open PR's feedback counts the card shows (`PRFeedback`).
struct SidebarPRFeedback: Hashable {
    let humans: Int
    let bots: Int
}

/// What a workspace card's first line says, from its columns and its PR.
enum SidebarCardState: Hashable {
    case working, waiting, error, done, idle
}

extension ColumnInfo {
    /// What the column asks of the user, if anything. A stuck agent says
    /// so whatever its status, and so does an approval the card offers:
    /// focusing the column clears attention, not the dialog.
    var attention: AttentionSignal? {
        if let stuck { return stuck.isFailure ? .error : .waiting }
        if permissionApproval != nil { return .waiting }
        guard agentStatus == .needsAttention else { return nil }
        return AttentionSignal.of(attentionReason)
    }

    /// The word a chip says for `attention`: "permission", "stopped",
    /// "done"…
    var attentionLabel: String? {
        if let stuck { return stuck.chipLabel }
        if let attentionReason, agentStatus == .needsAttention { return attentionReason.chipLabel }
        if let permissionApproval { return permissionApproval.toolName == "ExitPlanMode" ? "plan" : "permission" }
        guard agentStatus == .needsAttention else { return nil }
        return AttentionSignal.of(nil) == .waiting ? "needs you" : "done"
    }
}

extension AgentAttentionReason {
    /// One word for a column chip.
    var chipLabel: String {
        switch self {
        case .permission(let tool, _): return tool == "ExitPlanMode" ? "plan" : "permission"
        case .question: return "question"
        case .message: return "needs you"
        case .turnFinished: return "done"
        case .apiError: return "stopped"
        case .exitedMidTurn: return "exited"
        case .stillWaiting(let dialog, _): return dialog.chipLabel
        }
    }
}

extension SidebarStuckState {
    var chipLabel: String {
        switch self {
        case .waiting: return label
        case .stoppedOnError: return "stopped"
        case .exitedMidTurn: return "exited"
        }
    }
}

@MainActor
extension WorkspaceInfo {
    /// Waiting on the user first, then something broken, then work; a red
    /// check only once no agent works (it may be fixing it).
    var cardState: SidebarCardState {
        let signals = columns.compactMap(\.attention)
        if signals.contains(.waiting) { return .waiting }
        if signals.contains(.error) { return .error }
        if columns.contains(where: { $0.agentStatus == .working }) { return .working }
        if prInfo?.state == "OPEN", prInfo?.ciStatus == "FAILURE" { return .error }
        if prInfo?.state == "MERGED" { return .done }
        return .idle
    }

    /// The collapsed sidebar's dot: what the columns ask, and what happened
    /// while the user looked elsewhere.
    var attention: AttentionSignal? {
        let away = isActive ? nil : notification
        return (columns.compactMap(\.attention) + [away].compactMap { $0 }).max()
    }

    /// One line in the INACTIVE section: parked work that asks nothing and
    /// isn't on screen.
    var showsCompactRow: Bool {
        isInactive && !isActive && !cardActions.contains { !$0.isQuiet }
            && ![.waiting, .error, .working].contains(cardState)
    }

    /// The card's action block, top to bottom; empty hides it.
    var cardActions: [SidebarCardAction] {
        var actions: [SidebarCardAction] = []
        let names = columns.map(SidebarRenderer.columnName)
        for column in columns {
            if let approval = column.permissionApproval {
                // Two agents of a name: which one asks.
                let name = SidebarRenderer.columnName(column)
                let agent = names.filter { $0 == name }.count > 1 ? "\(name) (column \(column.index + 1))" : name
                actions.append(.approval(columnIndex: column.index, agent: agent, approval))
            }
            if case let .stoppedOnError(kind, detail, failedAt, resume)? = column.stuck {
                actions.append(.resume(
                    columnIndex: column.index, kind: kind, detail: detail, failedAt: failedAt, resume: resume
                ))
            }
            if let deferred = column.deferredAgent {
                actions.append(.deferredResume(columnIndex: column.index, deferred))
            }
        }
        if let action = sidebarAction {
            if action.isBlocker {
                actions.append(.blocker(action.text))
            } else if isActive, let nextStep = nextStep?.trimmingCharacters(in: .whitespacesAndNewlines) {
                actions.append(.next(nextStep))
            }
        }
        if let mergedCleanup, let prInfo {
            actions.append(.cleanup(mergedCleanup, pullRequest: prInfo.number))
        }
        if isActive, let reviewBadges {
            actions.append(.reviewBadges(reviewBadges))
        }
        return actions
    }
}

/// A row of a card's action block.
enum SidebarCardAction: Hashable {
    /// Allow / Deny a permission request.
    case approval(columnIndex: Int, agent: String, SidebarPermissionApproval)
    /// Resume an agent whose turn failed on an API error.
    case resume(
        columnIndex: Int, kind: String?, detail: String?, failedAt: TimeInterval, resume: SidebarStuckState.Resume
    )
    /// Resume a restored agent that hasn't resumed yet.
    case deferredResume(columnIndex: Int, SidebarDeferredAgent)
    case blocker(String)
    /// "Clean up" a merged pull request's worktree.
    case cleanup(MergedCleanupOffer, pullRequest: Int)
    case reviewBadges(ReviewBadges)
    /// The next step, on the selected card.
    case next(String)

    /// Information rather than something to do: no separator above.
    var isQuiet: Bool {
        switch self {
        case .next, .reviewBadges: return true
        case .approval, .resume, .deferredResume, .blocker, .cleanup: return false
        }
    }
}
