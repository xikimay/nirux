import Foundation

// MARK: - Stuck agents: what the column shows, and whether Resume or a Mission `tell` may type

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
        if let turnFailure, turnFailure.failedAt >= foreground.instance.startedAt { return .stoppedOnError(turnFailure) }
        if let waitThreshold, let dialog = visibleDialog(foreground: foreground),
           now - dialog.requestedAt >= waitThreshold {
            return .waiting(dialog.reason, since: dialog.requestedAt)
        }
        return nil
    }

    /// The dialog the foreground `claude` is showing, if any: open, raised
    /// by this very `claude` (not one before it: events queued while Nirux
    /// was closed replay at launch), and not reached by a keystroke since.
    /// A keystroke went to it: it was answered (the tool may then run long,
    /// silently) or denied with Esc, which fires no hook. Claude's reminder
    /// clears the keystroke once a dialog sits unanswered.
    func visibleDialog(foreground: ForegroundProcess?) -> AgentPermissionRequest? {
        guard let foreground, foreground.name == "claude" else { return nil }
        return openDialogs.first {
            $0.requestedAt >= foreground.instance.startedAt && $0.requestedAt >= lastKeystrokeAt
        }
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
        // Text typed at the prompt since the failed turn's own prompt went
        // in — during the turn or after — is a draft: `continue` would join
        // it, and Enter would send it. Keys that answered a dialog aren't.
        let promptWentIn = max(turnFailure.promptAt ?? 0, turnFailure.resumeKeystrokeAt ?? 0)
        guard lastDraftInputAt <= promptWentIn else { return .userTyped }
        return nil
    }

    /// Whether a Mission `tell` sent at `time` may be typed now, into an
    /// empty prompt of `foreground`: the column's interactive `claude`,
    /// already running at `time`, that took a prompt since it started (Claude
    /// Code shows some dialogs, such as trust or MCP servers, before any
    /// hook could list them), whose turn is over, with no dialog listed and
    /// nothing typed since its last prompt went in (a draft, or text typed
    /// by Nirux that Claude has not submitted yet).
    func isPromptFree(foreground: ForegroundProcess?, runningSince time: TimeInterval) -> Bool {
        guard let foreground, foreground.name == "claude", !AgentHookCenter.isHeadlessClaude(foreground),
              foreground.instance.startedAt <= time,
              let lastPromptAt, lastPromptAt >= foreground.instance.startedAt
        else { return false }
        return pendingDialogs.isEmpty && !hookWorking && turnStartedAt == nil && lastDraftInputAt <= lastPromptAt
    }
}
