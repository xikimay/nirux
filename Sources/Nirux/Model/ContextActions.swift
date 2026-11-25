import Foundation

/// What a click on Compact or Fresh start does (`takeContextOffer`).
enum ContextOfferAction: Equatable {
    case typeCompact
    case refuse(String)
    /// Restart Lead, which asks first.
    case confirmLeadRestart
    /// The task's worker on Claude in a new conversation, on its model.
    case resumeTask(model: String?)

    static let draftRefusal = "Claude’s prompt holds a draft: send or clear it, then Compact."

    /// `/compact` typed after a draft would send both.
    static func of(_ choice: ContextOffer.Choice, hasDraft: Bool, isLead: Bool, workerModel: String?) -> ContextOfferAction {
        switch choice {
        case .compact: hasDraft ? .refuse(draftRefusal) : .typeCompact
        case .freshStart: isLead ? .confirmLeadRestart : .resumeTask(model: workerModel)
        }
    }
}

/// What a task past its budget offers on its card (`SidebarCardAction.budget`).
enum BudgetChoice: String, Hashable, Sendable, CaseIterable {
    /// Its budget no longer holds it: no warning, no pause.
    case keepGoing
    /// Its worker, same agent and model, in a new conversation with a handover.
    case freshStart
    /// Close Workspace, which asks first.
    case close

    var title: String {
        switch self {
        case .keepGoing: "Continue"
        case .freshStart: "Fresh start"
        case .close: "Close…"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .keepGoing: "Continue past its budget: its pull request's follow-ups go on"
        case .freshStart: "Fresh start: a new conversation with a handover"
        case .close: "Close this task"
        }
    }
}

/// What a Lead holds that a fresh start would lose.
struct LeadHoldings: Equatable {
    /// Working, or a status Nirux can't trust.
    var isBusy = false
    /// A dialog or a permission prompt.
    var hasDialog = false
    /// Its reply or its turn ended on a question to the user.
    var hasQuestion = false
    var hasDraft = false
    /// A task's question it hasn't answered.
    var owesMissionReply = false
    /// A merge queue it started still runs.
    var runsItsQueue = false

    var isEmpty: Bool { self == LeadHoldings() }
}

/// Whether Nirux starts a cold Lead afresh by itself (`startColdLeadsAfresh`):
/// its own Claude session cold with a heavy context
/// (`ContextOffer.restartsLead`), its space allows it, and it holds
/// nothing. The space and the holdings are read only for such a session.
enum ColdLead {
    static func startsFresh(
        latest: UsageReport.LatestSession?, sessionID: String?, runningSince: TimeInterval, now: TimeInterval,
        spaceAllows: @autoclosure () -> Bool, holdings: @autoclosure () -> LeadHoldings
    ) -> Bool {
        guard let latest, let sessionID, latest.key == UsageSessionKey(.claude, sessionID),
              ContextOffer.restartsLead(latest, runningSince: runningSince, now: now) else { return false }
        return spaceAllows() && holdings().isEmpty
    }
}

extension Mission {
    /// Whether its task waits for `parentID` to answer a question that
    /// wasn't handed to the user.
    func awaitsReply(from parentID: String) -> Bool {
        parentWorkspaceID == parentID && status == .active && events.contains { question in
            question.kind == .question && question.handedToUserBecause == nil
                && !events.contains { $0.kind == .response && $0.inReplyTo == question.id }
        }
    }
}
