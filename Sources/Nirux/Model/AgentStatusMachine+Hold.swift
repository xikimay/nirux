import Foundation

/// What an agent's session still holds, which ending it would lose (see
/// `AgentStatusMachine.hold`).
enum AgentHold: Equatable, Sendable {
    case working
    /// A dialog, a question its turn ended on, or another reason it waits
    /// on the user.
    case waitsOnUser(AgentAttentionReason?)
    /// Text typed at its prompt and not sent.
    case draft
    /// Its turn end is still being read: it may ask the user something.
    case verdict
}

extension AgentStatusMachine {
    /// What ending the agent's session now would lose, nil when it sits
    /// idle at a free prompt, as its hooks and keys say (the agent under a
    /// launcher too). A turn that just ended reads "needs attention" until
    /// the user looks: that alone holds nothing.
    var hold: AgentHold? {
        // One answered at the terminal stays listed while its tool runs.
        if pendingDialogs.contains(where: waitsForKeys) { return .waitsOnUser(attentionReason) }
        if hookWorking || turnStartedAt != nil || !pendingDialogs.isEmpty { return .working }
        if let askedQuestion { return .waitsOnUser(.askedInReply(askedQuestion.text)) }
        if let reason = attentionReason, reason != .turnFinished { return .waitsOnUser(reason) }
        if awaitsAnyVerdict { return .verdict }
        if hasDraft { return .draft }
        return nil
    }
}
