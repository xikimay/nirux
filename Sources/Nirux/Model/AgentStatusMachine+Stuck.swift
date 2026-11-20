import Foundation

// MARK: - Stuck agents: what the column shows, and whether Resume or a Mission `tell` may type

extension AgentStatusMachine {
    /// What keeps the agent from going on, if anything. `foreground` is
    /// the column's foreground process now; `waitThreshold` nil turns the
    /// long-wait check off. `silence`, past the threshold, is read only
    /// while the turn waits on the model.
    func stuckState(
        now: TimeInterval, waitThreshold: TimeInterval?, silence: AgentSilence? = nil, foreground: ForegroundProcess?
    ) -> AgentStuckState? {
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
        if let silence, awaitsModel(foreground: foreground) { return .silent(silence) }
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

    /// Why Interrupt may not press Esc in a silent turn: as
    /// `interruptRefusal`, but a prompt not answered yet is no refusal:
    /// Claude gives it back to the box, the user's to send again. Keys
    /// typed since the prompt refuse it, answered or not: Esc could close a
    /// screen they opened instead.
    func silentInterruptRefusal(foreground: ForegroundProcess?) -> AgentInterruptRefusal? {
        let refusal = interruptRefusal(foreground: foreground)
        guard refusal == nil || refusal == .notAnswered else { return refusal }
        return hasDraft ? .typed : nil
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
        // Text typed at the prompt since it last emptied — during the turn
        // or after — is a draft: `continue` would join it, and Enter would
        // send it. Keys that answered a dialog aren't.
        let emptiedAt = max(boxEmptiedAt ?? 0, turnFailure.resumeKeystrokeAt ?? 0)
        guard lastDraftInputAt <= emptiedAt else { return .userTyped }
        return nil
    }

    /// Whether a Mission message may be typed now, into an empty prompt of
    /// `foreground`: the column's interactive `claude`, already running at
    /// `time`, whose turn is over and didn't fail (a usage limit would fail
    /// every message typed, one after the other), with no dialog listed and
    /// no draft (`hasDraft`: text typed by Nirux that Claude has not
    /// submitted yet too), and no turn end waiting for its verdict
    /// (`awaitsAnyVerdict`). One that took no prompt since it started also
    /// needs its REPL to say it sits idle at its prompt (`showsIdlePrompt`,
    /// see `sitsAtFirstPrompt`), or the user who saw it to say so
    /// (`seenByUser`).
    func isPromptFree(
        foreground: ForegroundProcess?, runningSince time: TimeInterval,
        seenByUser: Bool = false, showsIdlePrompt: (ProcessInstance) -> Bool = { _ in false }
    ) -> Bool {
        promptRefusal(foreground: foreground, runningSince: time, seenByUser: seenByUser, showsIdlePrompt: showsIdlePrompt) == nil
    }

    /// Why `isPromptFree` says no, nil when it says yes. `agent`: the kind
    /// of agent the text is for, Claude Code unless an Antigravity Mission
    /// child's (`agyPromptRefusal`).
    func promptRefusal(
        foreground: ForegroundProcess?, runningSince time: TimeInterval, seenByUser: Bool = false,
        agent: String = NiruxApp.WorkspaceAgent.claude.rawValue, showsIdlePrompt: (ProcessInstance) -> Bool = { _ in false }
    ) -> AgentPromptRefusal? {
        if agent == AgentProgramStatus.agy { return agyPromptRefusal(foreground, runningSince: time) }
        guard let foreground, AgentHookCenter.isInteractiveClaude(foreground) else { return .noClaude }
        guard foreground.instance.startedAt <= time else { return .restarted }
        let startedAt = foreground.instance.startedAt
        guard prompt(since: startedAt) != nil else {
            if sitsAtFirstPrompt(foreground.instance, seenByUser: seenByUser, showsIdlePrompt: showsIdlePrompt) { return nil }
            // Typed since it started, when its hooks would have said a prompt
            // went in: not a screen of its own, unless the user's word passed
            // those keys.
            let typed = reportsHooks(since: startedAt) && lastDraftInputAt >= startedAt + 1
                && !keysLeftNoText(since: foreground.instance, seenByUser: seenByUser)
            return typed ? .draft : .noPromptYet
        }
        if hookWorking || turnStartedAt != nil { return .working }
        if !pendingDialogs.isEmpty { return .dialog }
        if turnFailure != nil { return .failedTurn }
        if hasDraft { return .draft }
        if awaitsAnyVerdict { return .verdict }
        return nil
    }

    /// `promptRefusal` for `agy`, the column's interactive Antigravity,
    /// already running at `time`, which says its state itself (OSC 7501):
    /// its prompt is free once its turn ended (`done`, or `idle` after it,
    /// at a key) and no key that may leave text reached the terminal since
    /// that turn began (`AgyTurn`): a key typed while it works stays in its
    /// box (agy 1.5.12), keys that answer its dialogs don't. Stopped with Esc
    /// (`idle` without `done`), its box may hold its prompt again. Before its
    /// first turn ends it may show a screen no state tells of: one that ended
    /// none since it started waits for that.
    private func agyPromptRefusal(_ agy: ForegroundProcess?, runningSince time: TimeInterval) -> AgentPromptRefusal? {
        guard let agy, agy.name == AgentProgramStatus.agy, !AgentHookCenter.isHeadlessAgy(agy) else { return .noClaude }
        guard agy.instance.startedAt <= time else { return .restarted }
        guard let turn = agyTurn, turn.process == agy.instance else { return .noPromptYet }
        // Its last word, else how its turn ended (another process in front, or
        // a silence, drops the status, not the turn).
        switch programStatus.flatMap({ $0.process == agy.instance ? $0.status.state : nil }) ?? turn.ended {
        case .working?, nil: return .working
        case .blocked?: return .dialog
        case .error?: return .failedTurn
        case .idle? where turn.ended == .error: return .failedTurn
        case .idle? where turn.ended != .done: return .draft
        case .idle?, .done?: return lastDraftInputAt > turn.startedAt ? .draft : nil
        }
    }

    /// Whether `process`, a `claude` that took no prompt since it started,
    /// sits at its empty prompt. No hook tells: Claude Code may show screens
    /// none reports, before its REPL mounts (trust, MCP servers) and after
    /// (a resume's offer to resume from a summary, a quota warning, a newer
    /// model, a startup offer), where typed text and Enter would pick an
    /// option. So: its hooks report (without them, no prompt would ever say
    /// that a message typed went in), nothing at work or listed, no key or
    /// recalled prompt since the terminal started (keys typed before a REPL
    /// mounts are seeded into its prompt, those typed while its shell still
    /// loads too;
    /// others open its agents or transcript views; one started by hand
    /// waits for its first prompt), and, read last, its REPL's own word
    /// (`showsIdlePrompt`, from `ClaudeSessionRecord`). `seenByUser`: the
    /// user, who saw its screen, says it sits at its prompt (see
    /// `keysLeftNoText`).
    func sitsAtFirstPrompt(
        _ process: ProcessInstance, seenByUser: Bool = false, showsIdlePrompt: (ProcessInstance) -> Bool
    ) -> Bool {
        reportsHooks(since: process.startedAt)
            && !hookWorking && turnStartedAt == nil && pendingDialogs.isEmpty && turnFailure == nil && !awaitsAnyVerdict
            && keysLeftNoText(since: process, seenByUser: seenByUser) && showsIdlePrompt(process)
    }

    /// Whether no key may have left text in the prompt of `process`: none
    /// since the terminal started, or, on the user's word, none that may
    /// leave text since it started (`lastTextInputAt`; keys before launched
    /// it, or the user sees them): an Enter or a move answers a screen of its
    /// own, but may also accept an `@file` completion after text. Its start is
    /// known to the second.
    private func keysLeftNoText(since process: ProcessInstance, seenByUser: Bool) -> Bool {
        lastInputAt == 0 && lastDraftInputAt == 0 || seenByUser && lastTextInputAt < process.startedAt + 1
    }

    /// Whether Nirux's hooks reported from the `claude` started at
    /// `startedAt`: an event stamped since (events of an earlier one, queued
    /// while Nirux was closed, carry their own time).
    func reportsHooks(since startedAt: TimeInterval) -> Bool {
        hookKind == "claude" && lastEventAt >= startedAt
    }

    /// Why a Mission message can't go into Codex's own queue now
    /// (`CodexQueue`), nil when it can: `foreground`, the column's
    /// interactive `codex`, already running at `time`, last reported its
    /// turn over: done, or idle (once ready, after a key, or after an Esc,
    /// when Codex's queue itself waits for another turn's end). Nothing is
    /// typed: Codex starts a queued message itself once that conversation is
    /// idle, so neither a dialog nor a draft can take it. Its turn is waited
    /// for all the same, so that what holds a message stays Nirux's to tell
    /// and to give up.
    func codexQueueRefusal(foreground: ForegroundProcess?, runningSince time: TimeInterval) -> AgentPromptRefusal? {
        guard let foreground, foreground.name == AgentProgramStatus.codex, !AgentHookCenter.isHeadlessCodex(foreground)
        else { return .noClaude }
        guard foreground.instance.startedAt <= time else { return .restarted }
        guard let reported = codexStatus, reported.isFrom(foreground.instance) else { return .noPromptYet }
        switch reported.status.state {
        case .done, .idle: return nil
        case .working: return .working
        case .blocked: return .dialog
        case .error: return .failedTurn
        }
    }

    /// What `promptRefusal` reads for an `agy`, for the log.
    func agyFacts(now: TimeInterval) -> String {
        func age(_ time: TimeInterval?) -> String { time.map { String(Int(min(max(now - $0, 0), 1e7))) + "s" } ?? "-" }
        let draft = lastDraftInputAt > (agyTurn?.startedAt ?? 0) ? age(lastDraftInputAt) : "-"
        return "agy=\(programStatus?.status.state.rawValue ?? "-")/\(age(programStatus?.at)) "
            + "turn=\(age(agyTurn?.startedAt))/\(agyTurn?.ended?.rawValue ?? "open") draft=\(draft)"
    }

    /// What `codexQueueRefusal` reads, for the log.
    func codexFacts(now: TimeInterval) -> String {
        guard let reported = codexStatus else { return "codex=-" }
        return "codex=\(reported.status.state.rawValue)/\(Int(min(max(now - reported.at, 0), 1e7)))s"
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
        let draft = hasDraft ? "\(lastDraftKind ?? "?")/\(age(lastDraftInputAt))" : "-"
        return "working=\(hookWorking ? 1 : 0) inFlight=\(hookTurnInFlight ? 1 : 0) turn=\(age(turnStartedAt)) "
            + "dialogs=[\(dialogs.joined(separator: ","))] prompt=\(age(lastPromptAt)) draft=\(draft) "
            + "input=\(age(lastInputAt > 0 ? lastInputAt : nil)) verdict=\(verdict) "
            + "failed=\(turnFailure == nil ? 0 : 1) last=\(lastEventName ?? "-")/\(age(lastEventAt > 0 ? lastEventAt : nil))"
    }

    /// When the last prompt went in, if one did since `startedAt`, the
    /// start of the `claude` in front (`/clear` counts): before one, it may
    /// still show a screen no hook reports (see `sitsAtFirstPrompt`).
    func prompt(since startedAt: TimeInterval) -> TimeInterval? {
        lastPromptAt.flatMap { $0 >= startedAt ? $0 : nil }
    }

    /// Whether a message typed at `typedAt` went in and the turn that took
    /// it is over: nothing works, no dialog waits. A message Claude took in
    /// by itself since is not that one.
    func finishedTurn(afterTypingAt typedAt: TimeInterval) -> Bool {
        guard let lastUserPromptAt, lastUserPromptAt >= typedAt else { return false }
        return pendingDialogs.isEmpty && !hookWorking && turnStartedAt == nil
    }
}

/// Why a Mission message isn't typed into an agent's prompt now (see
/// `AgentStatusMachine.isPromptFree`).
enum AgentPromptRefusal: String, Equatable, Sendable {
    /// The column doesn't run the agent the message is for: an interactive
    /// `claude`, or `codex`.
    case noClaude
    /// Its `claude` started after the message was sent, which goes only to
    /// the one that ran then.
    case restarted
    /// Its `claude` took no prompt since it started, and doesn't say it
    /// sits at its prompt (see `AgentStatusMachine.sitsAtFirstPrompt`); its
    /// `codex` reported no state since it started.
    case noPromptYet
    /// Nirux doesn't know which conversation its `codex` runs: one its
    /// launch prompt started, or one it resumed (`ForegroundSessionTracker`).
    case noConversation
    case dialog
    case working
    case failedTurn
    /// Something was typed at its prompt since its last prompt went in.
    case draft
    /// Its last turn end waits for its verdict.
    case verdict
}