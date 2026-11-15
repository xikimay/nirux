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
    /// was closed replay at launch), and not reached by a keystroke since
    /// (`waitsForKeys`): it was answered (the tool may then run long,
    /// silently) or denied with Esc, which fires no hook. A question dialog
    /// waits until its submit's PostToolUse, or an Esc or Ctrl-C. Claude's
    /// reminder clears the keystroke once a dialog sits unanswered.
    func visibleDialog(foreground: ForegroundProcess?) -> AgentPermissionRequest? {
        guard let foreground, foreground.name == "claude" else { return nil }
        return openDialogs.first { $0.requestedAt >= foreground.instance.startedAt && waitsForKeys($0) }
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

    /// Whether a Mission message may be typed now, into an empty prompt of
    /// `foreground`: the column's interactive `claude`, already running at
    /// `time`, that took a prompt since it started (Claude Code shows some
    /// dialogs, such as trust or MCP servers, before any hook could list
    /// them), whose turn is over and didn't fail (a usage limit would fail
    /// every message typed, one after the other), with no dialog listed and
    /// nothing typed since its last prompt went in (a draft, or text typed
    /// by Nirux that Claude has not submitted yet), and no turn end waiting
    /// for its verdict (`awaitsAnyVerdict`).
    func isPromptFree(foreground: ForegroundProcess?, runningSince time: TimeInterval) -> Bool {
        promptRefusal(foreground: foreground, runningSince: time) == nil
    }

    /// Why `isPromptFree` says no, nil when it says yes.
    func promptRefusal(foreground: ForegroundProcess?, runningSince time: TimeInterval) -> AgentPromptRefusal? {
        guard let foreground, foreground.name == "claude", !AgentHookCenter.isHeadlessClaude(foreground) else { return .noClaude }
        guard foreground.instance.startedAt <= time else { return .restarted }
        guard let lastPromptAt = prompt(since: foreground.instance.startedAt) else { return .noPromptYet }
        if hookWorking || turnStartedAt != nil { return .working }
        if !pendingDialogs.isEmpty { return .dialog }
        if turnFailure != nil { return .failedTurn }
        if lastDraftInputAt > lastPromptAt { return .draft }
        if awaitsAnyVerdict { return .verdict }
        return nil
    }

    /// What `promptRefusal` reads, for the log: ages in seconds and names,
    /// no text.
    func promptFacts(now: TimeInterval) -> String {
        func age(_ time: TimeInterval?) -> String { time.map { String(Int(min(max(now - $0, 0), 1e7))) + "s" } ?? "-" }
        let verdict = switch quietTurnEnd {
        case .pending?: "pending"
        case .done?: "done"
        case .superseded?: "superseded"
        case nil: "none"
        }
        let dialogs = pendingDialogs.map { "\($0.toolName ?? "?")/\($0.agentID == nil ? "main" : "sub")/\(age($0.requestedAt))" }
        let draft = lastDraftInputAt > (lastPromptAt ?? 0) ? "\(lastDraftKind ?? "?")/\(age(lastDraftInputAt))" : "-"
        return "working=\(hookWorking ? 1 : 0) inFlight=\(hookTurnInFlight ? 1 : 0) turn=\(age(turnStartedAt)) "
            + "dialogs=[\(dialogs.joined(separator: ","))] prompt=\(age(lastPromptAt)) draft=\(draft) verdict=\(verdict) "
            + "failed=\(turnFailure == nil ? 0 : 1) last=\(lastEventName ?? "-")/\(age(lastEventAt > 0 ? lastEventAt : nil))"
    }

    /// When the last prompt went in, if one did since `startedAt`, the
    /// start of the `claude` in front (`/clear` counts): before one, it may
    /// still show a screen no hook reports, a startup dialog or, once
    /// resumed, an offer to resume from a summary.
    func prompt(since startedAt: TimeInterval) -> TimeInterval? {
        lastPromptAt.flatMap { $0 >= startedAt ? $0 : nil }
    }

    /// Whether a message typed at `typedAt` went in and the turn that took
    /// it is over: nothing works, no dialog waits.
    func finishedTurn(afterTypingAt typedAt: TimeInterval) -> Bool {
        guard let lastPromptAt, lastPromptAt >= typedAt else { return false }
        return pendingDialogs.isEmpty && !hookWorking && turnStartedAt == nil
    }
}

/// Why a Mission message isn't typed into an agent's prompt now (see
/// `AgentStatusMachine.isPromptFree`).
enum AgentPromptRefusal: String, Equatable, Sendable {
    /// The column doesn't run an interactive `claude`.
    case noClaude
    /// Its `claude` started after the message was sent, which goes only to
    /// the one that ran then.
    case restarted
    /// Its `claude` took no prompt since it started.
    case noPromptYet
    case dialog
    case working
    case failedTurn
    /// Something was typed at its prompt since its last prompt went in.
    case draft
    /// Its last turn end waits for its verdict.
    case verdict
}
