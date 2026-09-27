import Foundation

// MARK: - Stuck agents: what the column shows, and whether Resume may type

extension AgentStatusMachine {
    /// What keeps the agent from going on, if anything. `foreground` is
    /// the column's foreground process now; `waitThreshold` nil turns the
    /// long-wait check off.
    func stuckState(now: TimeInterval, waitThreshold: TimeInterval?, foreground: ForegroundProcess?) -> AgentStuckState? {
        if let midTurnExit {
            let agentInFront = foreground.map { Self.isRecognizedAgentProcess($0.name) } ?? false
            guard !agentInFront, now - midTurnExit.exitedAt >= Self.exitConfirmationDelay else { return nil }
            return .exitedMidTurn(midTurnExit)
        }
        // A failure and dialogs are the foreground claude's own: not those
        // of one suspended behind a shell, nor of an earlier claude (events
        // queued while Nirux was closed replay at launch).
        guard let foreground, foreground.name == "claude" else { return nil }
        let startedAt = foreground.instance.startedAt
        if let turnFailure, turnFailure.failedAt >= startedAt { return .stoppedOnError(turnFailure) }
        // A keystroke since a dialog opened went to it: it was answered
        // (the tool may then run long, silently) or denied with Esc, which
        // fires no hook. Claude's reminder clears the keystroke once a
        // dialog sits unanswered.
        if let waitThreshold, let dialog = openDialogs.first(where: {
            $0.requestedAt >= startedAt && $0.requestedAt >= lastKeystrokeAt
        }), now - dialog.requestedAt >= waitThreshold {
            return .waiting(dialog.reason, since: dialog.requestedAt)
        }
        return nil
    }

    /// Whether Resume may type `continue`: a failed turn with nothing
    /// since, an error `continue` can get past, `foreground` is the
    /// interactive `claude` that failed (`ownsEmitter` says whether it is,
    /// or runs, the process that reported the failure), back at an empty
    /// prompt — no dialog listed, no work going on, nothing typed since.
    func resumeRefusal(
        foreground: ForegroundProcess?,
        ownsEmitter: (ProcessInstance) -> Bool,
        now: TimeInterval
    ) -> AgentResumeRefusal? {
        guard let turnFailure else { return .notStopped }
        guard let foreground, foreground.name == "claude", !AgentHookCenter.isHeadlessClaude(foreground),
              turnFailure.failedAt >= foreground.instance.startedAt,
              turnFailure.emitter.map(ownsEmitter) ?? true else { return .notClaude }
        guard turnFailure.isResumable else { return .needsFix }
        // Any dialog still listed may be on screen, where typed text
        // answers it instead of reaching the prompt.
        guard pendingDialogs.isEmpty, !hookWorking, turnStartedAt == nil else { return .notAtPrompt }
        // (A clock set back since reads as the delay over.)
        if let sent = turnFailure.resumeSentAt, (0..<Self.resumeRetryDelay).contains(now - sent) { return .alreadySent }
        guard lastKeystrokeAt <= max(turnFailure.failedAt, turnFailure.resumeKeystrokeAt ?? 0) else { return .userTyped }
        return nil
    }
}
