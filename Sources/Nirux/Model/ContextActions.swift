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
    /// Its budget no longer holds it for 7 days: no warning, no pause.
    case keepGoing
    /// Its worker, same agent and model, in a new conversation with a
    /// handover; only while its columns rest. Lifts the budget too.
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
/// A task in the title bar popover's "what spends your session": its share
/// of Claude's spend over `UsageReport.burnSpan`, about that many points of
/// the 5-hour window (`QuotaCalibration`), why, and what its row offers.
struct QuotaBurnRow: Equatable {
    enum Action: Equatable {
        case contextOffer(ContextOffer.Choice, column: Int)
        case compactAtTurnEnd(column: Int)
        case budget(BudgetChoice)

        var title: String {
            switch self {
            case .contextOffer(let choice, _): choice.title
            case .compactAtTurnEnd: "Compact at turn end"
            case .budget(let choice): choice.title
            }
        }
    }

    var workspaceID: String
    var title: String
    /// 0…1 of Claude's spend over the span.
    var share: Double
    var points: Double?
    var tokens: Double
    var cause: String?
    var actions: [Action]
}

/// What a queued "Compact at turn end" does at a sidebar pass, given what
/// holds its claude (nil once its column is gone or runs no claude).
enum QueuedCompact: Equatable {
    case wait, send, drop

    static func of(_ holdings: LeadHoldings?) -> QueuedCompact {
        guard let holdings else { return .drop }
        // The user's words in its prompt win over a compaction.
        if holdings.hasDraft { return .drop }
        if holdings.isBusy || holdings.hasDialog || holdings.hasQuestion { return .wait }
        return .send
    }
}

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
