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
    /// What the column asks of the user, if anything: the most urgent of
    /// its causes.
    var attention: AttentionSignal? { attentionCauses.map(\.signal).max() }

    /// `attention` while the user looks elsewhere: the focused column of
    /// the workspace on screen shows its own (column indicator, edge
    /// glows, borders).
    var offScreenAttention: AttentionSignal? { isFocused ? nil : attention }

    /// The word a chip says for `attention`: "permission", "stopped",
    /// "done"…
    var attentionLabel: String? { winningCause?.label }

    /// What exactly the column waits on ("needs permission — Bash: git
    /// push"), for the cause the chip shows.
    var attentionToolTip: String? { winningCause?.toolTip }

    private var winningCause: AttentionCause? {
        guard let attention else { return nil }
        return attentionCauses.first { $0.signal == attention }
    }

    private struct AttentionCause {
        let signal: AttentionSignal
        let label: String
        let toolTip: String?
    }

    /// A stuck agent says so whatever its status, and so do an approval the
    /// card offers and a dialog on screen: focusing the column, or the app,
    /// clears the attention, not the dialog.
    private var attentionCauses: [AttentionCause] {
        var causes: [AttentionCause] = []
        if let stuck {
            causes.append(AttentionCause(signal: stuck.isFailure ? .error : .waiting, label: stuck.chipLabel, toolTip: stuck.tooltip))
        }
        if let approval = permissionApproval {
            causes.append(AttentionCause(
                signal: .waiting, label: approval.toolName == "ExitPlanMode" ? "plan" : "permission",
                toolTip: "needs permission — \(approval.toolName): \(approval.text)"
            ))
        }
        if let openDialog {
            causes.append(AttentionCause(signal: openDialog.signal, label: openDialog.chipLabel, toolTip: openDialog.toolTip))
        }
        if agentStatus == .needsAttention {
            let signal = AttentionSignal.of(attentionReason)
            causes.append(AttentionCause(
                signal: signal, label: attentionReason?.chipLabel ?? (signal == .waiting ? "needs you" : "done"),
                toolTip: attentionReason?.toolTip
            ))
        }
        return causes
    }
}

extension AgentAttentionReason {
    /// "needs permission — Bash: git push": a chip's tooltip.
    var toolTip: String {
        let detail = detailLine.flatMap { AgentText.clean($0, maxLength: 300) }
        return [headline, detail].compactMap { $0 }.joined(separator: " — ")
    }

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
    /// Short enough for a chip, the rest in the tooltip (and the Resume
    /// block).
    var chipLabel: String {
        switch self {
        case .waiting(_, let duration): return "waiting \(duration)"
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

    /// The project switcher's ring: what the columns ask, then what
    /// happened while the user looked elsewhere (a child agent's question,
    /// a red check: a pulse for as long as a check stays red would be
    /// noise).
    var attention: AttentionSignal? {
        let away = isActive ? nil : notification
        return (columns.compactMap(\.attention) + [away].compactMap { $0 }).max()
    }

    /// An agent waits on the user or broke: the folded INACTIVE section
    /// lists the workspace anyway.
    var asksUser: Bool {
        columns.contains { $0.attention == .waiting || $0.attention == .error }
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
        case .approval, .resume, .blocker, .cleanup: return false
        }
    }
}
