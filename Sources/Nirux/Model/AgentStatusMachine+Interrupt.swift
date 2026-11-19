import Foundation

/// Why Nirux doesn't press Esc in an agent's turn (see
/// `AgentStatusMachine.interruptRefusal`).
enum AgentInterruptRefusal: Equatable, Sendable {
    /// No interactive `claude` with Nirux's hooks in front.
    case noClaude
    case notWorking
    /// An Esc went into this turn already: a second would open the rewind.
    case alreadySent
    /// Esc would answer the dialog.
    case dialog
    /// No tool call since its prompt: Claude may not have begun its reply.
    case notAnswered
    /// Keys reached its prompt since: queued messages, or a draft.
    case typed
}

extension AgentStatusMachine {
    /// Why Nirux may not interrupt the turn of `foreground` with Esc now,
    /// nil when it may. Claude Code gives the prompt box back a prompt it
    /// hasn't begun answering, and the prompts queued meanwhile: only a
    /// turn that called a tool, with nothing typed since its prompt, leaves
    /// the box empty for the next message.
    func interruptRefusal(foreground: ForegroundProcess?) -> AgentInterruptRefusal? {
        guard let foreground, foreground.interactiveAgent == .claude, hookAgent == .claude else { return .noClaude }
        // The main thread's turn: a subagent at work after its Stop isn't one.
        guard promptTurnInFlight, let lastPromptAt, lastPromptAt >= foreground.instance.startedAt else { return .notWorking }
        guard interruptSentAt < lastPromptAt else { return .alreadySent }
        // One answered at the terminal stays listed until its tool ends.
        guard !pendingDialogs.contains(where: waitsForKeys) else { return .dialog }
        guard lastMainToolAt >= lastPromptAt else { return .notAnswered }
        guard lastDraftInputAt <= lastPromptAt else { return .typed }
        return nil
    }
}
