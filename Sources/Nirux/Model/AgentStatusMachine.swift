import Foundation

/// Agent status state machine for one terminal column.
///
/// Two information sources, in decreasing order of reliability:
/// 1. **Hook events** (Claude Code hooks / Codex notify, routed via
///    `AgentHookCenter`) — exact lifecycle signals. Once a Claude session
///    proves it emits hooks, they are authoritative: `working` means a turn
///    is in flight; a dialog (PermissionRequest), `Stop` or a
///    `Notification` stops it, with the reason attached. No output
///    heuristic can misfire on redraws, spinners, or long silent tool
///    calls — except in the one stretch hooks leave silent, right after
///    the user answers a dialog (`isRunningAnsweredDialog`).
/// 2. **Output activity fallback** (agents without hooks — Codex between
///    turns, Claude sessions started before the hooks were installed):
///    recent PTY output means working; silence means the turn ended.
///
/// Pure value type with injected time — fully unit-testable. `PtySession`
/// owns one instance and feeds it reads, writes, resizes and hook events.
struct AgentStatusMachine {
    private(set) var state: AgentStatus = .idle {
        // Leaving attention ends the episode: the next one alerts again.
        didSet { if state != .needsAttention { attentionAlerted = false } }
    }
    /// Set by UserPromptSubmit/PreToolUse/PostToolUse, cleared by
    /// Stop/SessionEnd and by a dialog opening.
    private var hookWorking = false
    /// Dialogs Claude may be showing (permission, AskUserQuestion,
    /// elicitation), oldest first. Independent of `state`: a focused
    /// column shows `.idle` while its dialog stays open. Entries leave only
    /// on hook evidence that the dialog closed — the matching tool call
    /// finishing, a new prompt, the turn or session ending — never on a
    /// guess: remote prompts are refused while any is pending, and a
    /// prompt typed into an open dialog would answer it. A manual denial
    /// fires no hook, so an entry can outlive its dialog until then.
    private(set) var pendingDialogs: [AgentPermissionRequest] = []
    /// Why the column last asked for attention (turn finished, message…);
    /// a pending dialog outranks it — see `attentionReason`.
    private var lastAttentionReason: AgentAttentionReason?
    /// The external alert went out for the current attention episode.
    private var attentionAlerted = false
    /// Epoch seconds a dialog last closed (and when it had opened), and of
    /// the event being applied.
    private var lastDialogClosedAt: TimeInterval = 0
    private var lastClosedDialogRequestedAt: TimeInterval = 0
    private var lastEventAt: TimeInterval = 0
    /// Codex's last turnComplete: output before it is the finished turn's.
    private var turnEndedAt: TimeInterval = 0
    /// Start of the current turn (epoch seconds): UserPromptSubmit, else
    /// the first turn event seen (a turn already running at launch). Nil
    /// between turns. Drives the "working · 12m" display.
    private(set) var turnStartedAt: TimeInterval?
    /// Agent kind ("claude") once this session has emitted a hook event —
    /// proof that hooks are installed and authoritative for this session.
    private(set) var hookKind: String?
    /// Epoch seconds of the last PTY read that wasn't input echo (drives
    /// the fallback heuristic). 0 = never. Plain TimeInterval — a single
    /// aligned 8-byte store — because noteRead runs on the PTY read queue
    /// while tick reads it on the main queue; an Optional<Date> could tear.
    private var lastReadAt: TimeInterval = 0
    /// Epoch seconds of the last write or resize — output within the echo
    /// window after one of these is the terminal answering the user, not
    /// agent work. 0 = never.
    private var lastInteractionAt: TimeInterval = 0
    /// Epoch seconds of the last keystroke Nirux sent (`PtySession.sendRaw`)
    /// — unlike `lastInteractionAt`, never terminal replies or resizes.
    private var lastKeystrokeAt: TimeInterval = 0

    /// The user has typed at least once since the shell started. Fallback
    /// attention is gated on this: output before the first keystroke is
    /// launch noise (banners, session replay, redraws), never a turn.
    private(set) var hasUserInput = false

    /// Foreground-process tracking (the isAgent gate and startup window in
    /// `tick`).
    private(set) var lastForegroundName: String?
    private(set) var foregroundSince: Date?

    private static let echoWindow: TimeInterval = 0.3
    private static let activityWindow: TimeInterval = 3.0
    /// Ignore fallback transitions right after a foreground-process change —
    /// startup output of the new command is not a completed turn either.
    private static let startupWindow: TimeInterval = 5.0
    /// An async `permission_prompt` landing this soon after a dialog closed
    /// is about that dialog — if it was open long enough for Claude's
    /// reminder (~6 s without typing) to be due.
    private static let reminderRaceWindow: TimeInterval = 3.0
    private static let reminderDelay: TimeInterval = 5.0

    /// Central capability gate shared by local status and remote prompt
    /// routing. Bot commands remain agent-agnostic even as this allowlist
    /// grows with Nirux's supported terminal agents.
    static func isRecognizedAgentProcess(_ name: String) -> Bool {
        name == "claude" || name == "codex"
    }

    /// Why the column wants the user, while it does: the oldest dialog
    /// still believed open, else the last attention event's reason.
    var attentionReason: AgentAttentionReason? {
        guard state == .needsAttention else { return nil }
        return openDialogs.first?.reason ?? lastAttentionReason
    }

    /// Pending dialogs no later tool event of their agent has superseded —
    /// what the column's own status believes is on screen.
    private var openDialogs: [AgentPermissionRequest] {
        pendingDialogs.filter { !$0.mayBeAnswered }
    }

    /// Name-only entry point (a hook event without payload details).
    /// Returns true when the column should alert.
    mutating func applyHook(
        _ name: AgentHookEvent.Name,
        kind: AgentHookEvent.Kind,
        source: String? = nil,
        isUserFocused: Bool
    ) -> Bool {
        apply(AgentHookEvent(kind: kind, name: name, source: source), isUserFocused: isUserFocused).firedAttention
    }

    /// Apply one hook event. `firedAttention` asks for the external alert
    /// (dock bounce, notification) once per attention episode, and only
    /// for events Claude itself alerts on: a turn's end, its notifications.
    /// A PermissionRequest shows at once in the column but leaves the alert
    /// to Claude's `permission_prompt` notification, sent ~6 s later only
    /// if the dialog is really on screen and unanswered — another
    /// PermissionRequest hook may have answered it, and nobody was asked.
    mutating func apply(_ event: AgentHookEvent, isUserFocused: Bool) -> AgentHookOutcome {
        let now = event.timestamp
        lastEventAt = now
        var outcome = AgentHookOutcome()
        switch event.name {
        case .sessionStart where event.source == "compact":
            // Auto (mid-turn) or /compact: same conversation, no turn ends.
            hookKind = event.kind.rawValue
        case .sessionStart:
            // A new conversation in this process (startup, /clear, /resume):
            // whatever dialogs the old one showed are gone.
            hookKind = event.kind.rawValue
            endTurn()
            closeDialogs { _ in true }
            lastAttentionReason = nil
            state = .idle
        case .userPromptSubmit:
            hookKind = event.kind.rawValue
            // A prompt was typed at the session's input, which no dialog of
            // it covered: they are all closed. This also frees the subagent
            // dialogs an interrupt (Esc) left behind with no hook. (Missed
            // race: a message queued earlier and sent while a background
            // subagent's dialog is up.)
            closeDialogs { $0.sessionID == event.sessionID }
            turnStartedAt = now
            resumeUnlessBlocked()
        case .preToolUse:
            hookKind = event.kind.rawValue
            noteTurnActivity(at: now)
            noteProgress(of: event)
            resumeUnlessBlocked()
        case .postToolUse:
            hookKind = event.kind.rawValue
            noteTurnActivity(at: now)
            // The call ran: its dialog, if it had one, was answered.
            if let key = event.toolKey,
               let index = pendingDialogs.firstIndex(where: { $0.isSameCall(key: key, as: event) }) {
                noteClosed(pendingDialogs.remove(at: index))
            }
            noteProgress(of: event)
            resumeUnlessBlocked()
        case .permissionRequest:
            hookKind = event.kind.rawValue
            noteTurnActivity(at: now)
            let request = AgentPermissionRequest(
                toolName: event.toolName,
                summary: event.toolSummary,
                key: event.toolKey,
                agentID: event.agentID,
                sessionID: event.sessionID,
                requestedAt: now
            )
            // The same call asked again (a plan re-proposed after "keep
            // planning"): the earlier dialog is gone.
            if let key = request.key { pendingDialogs.removeAll { $0.isSameCall(key: key, as: event) } }
            pendingDialogs.append(request)
            outcome.attention = request.reason
            _ = block(for: request.reason, isUserFocused: isUserFocused, alert: false)
        case .notification:
            hookKind = event.kind.rawValue
            applyNotification(event, now: now, isUserFocused: isUserFocused, outcome: &outcome)
        case .subagentStop:
            // Its dialogs closed with it (a denial fires no hook).
            if let agentID = event.agentID {
                closeDialogs { $0.agentID == agentID }
            }
        case .stop:
            hookKind = event.kind.rawValue
            // The main thread finished: none of its dialogs is open.
            closeDialogs { $0.agentID == nil && $0.sessionID == event.sessionID }
            endTurn()
            outcome.attention = .turnFinished
            outcome.firedAttention = block(for: .turnFinished, isUserFocused: isUserFocused)
        case .sessionEnd:
            endTurn()
            closeDialogs { event.sessionID == nil || $0.sessionID == event.sessionID }
            lastAttentionReason = nil
            hookKind = nil
            state = .idle
        case .turnComplete:
            // Codex: no working-state hooks — output fallback covers that.
            // The notify payload only marks the end of a turn.
            endTurn()
            turnEndedAt = now
            outcome.attention = .turnFinished
            outcome.firedAttention = block(for: .turnFinished, isUserFocused: isUserFocused)
        }
        return outcome
    }

    /// What an event asks of the user, read without column state (its
    /// column is gone): as if it reached a fresh, focused column.
    static func standaloneOutcome(for event: AgentHookEvent) -> AgentHookOutcome {
        var machine = AgentStatusMachine()
        return machine.apply(event, isUserFocused: true)
    }

    /// Claude notifications by `notification_type`. Informational types
    /// change nothing; untyped ones (older Claude) keep asking for
    /// attention with their message, as before types existed.
    private mutating func applyNotification(
        _ event: AgentHookEvent,
        now: TimeInterval,
        isUserFocused: Bool,
        outcome: inout AgentHookOutcome
    ) {
        let reason: AgentAttentionReason
        switch event.notificationType {
        case "auth_success", "agent_completed", "quota_auto_resume_fired":
            return
        case "elicitation_complete", "elicitation_response":
            // The form was answered: its dialog is gone.
            if let index = pendingDialogs.firstIndex(where: {
                $0.isQuestion && $0.key == nil && $0.agentID == event.agentID
            }) {
                noteClosed(pendingDialogs.remove(at: index))
            }
            return
        case "permission_prompt":
            // Sent ~6 s into a dialog nobody touched — after its
            // PermissionRequest, or alone (a sandboxed command's network
            // request fires no PermissionRequest). Either way a dialog is
            // on screen and no keystroke answered it.
            lastKeystrokeAt = 0
            if let open = openDialogs.first {
                reason = open.reason
                outcome.isRepeat = true
            } else if !pendingDialogs.isEmpty {
                // Every entry looked answered, yet one waits: the newest
                // (older ones were likely denied, which fires no hook).
                pendingDialogs[pendingDialogs.count - 1].mayBeAnswered = false
                reason = pendingDialogs[pendingDialogs.count - 1].reason
                outcome.isRepeat = true
            } else if now - lastDialogClosedAt < Self.reminderRaceWindow,
                      now - lastClosedDialogRequestedAt >= Self.reminderDelay {
                // The hook is async: this reminder raced the close of the
                // dialog it was about (old enough for its reminder).
                return
            } else {
                reason = .permission(tool: nil, summary: event.detail)
                pendingDialogs.append(AgentPermissionRequest(
                    toolName: nil, summary: event.detail, key: nil,
                    agentID: event.agentID, sessionID: event.sessionID, requestedAt: now
                ))
            }
        case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
            lastKeystrokeAt = 0
            reason = .question(event.detail)
            pendingDialogs.append(AgentPermissionRequest(
                toolName: nil, summary: event.detail, key: nil,
                agentID: event.agentID, sessionID: event.sessionID, requestedAt: now, isQuestion: true
            ))
        case "idle_prompt":
            // Claude finished responding a minute ago: the main thread sits
            // at its prompt, not in a dialog.
            closeDialogs { $0.agentID == nil && $0.sessionID == event.sessionID }
            endTurn()
            reason = .turnFinished
        default:
            reason = .message(event.detail)
        }
        outcome.attention = reason
        outcome.firedAttention = block(for: reason, isUserFocused: isUserFocused)
    }

    /// The agent waits on the user: it no longer works (leave hookWorking
    /// set and the next tick would flip needsAttention straight back to
    /// `.working` while the agent sits idle). True when the external alert
    /// should go out: once per attention episode.
    private mutating func block(for reason: AgentAttentionReason, isUserFocused: Bool, alert: Bool = true) -> Bool {
        hookWorking = false
        lastAttentionReason = reason
        if isUserFocused {
            state = .idle
            return false
        }
        state = .needsAttention
        guard alert, !attentionAlerted else { return false }
        attentionAlerted = true
        return true
    }

    /// A tool event from an agent: it got past its dialogs — answered, or
    /// denied, which fires no hook. The status believes it; the Telegram
    /// gate keeps the entries until proof (a call can run beside an open
    /// dialog). Claude's `permission_prompt` reopens them if one still waits.
    private mutating func noteProgress(of event: AgentHookEvent) {
        for index in pendingDialogs.indices
        where pendingDialogs[index].agentID == event.agentID && pendingDialogs[index].sessionID == event.sessionID {
            pendingDialogs[index].mayBeAnswered = true
        }
    }

    /// A tool event: the agent works — unless a dialog still waits. Other
    /// subagents keep calling tools while one waits on the user, and the
    /// column must keep saying it is blocked.
    private mutating func resumeUnlessBlocked() {
        guard openDialogs.isEmpty else { return }
        hookWorking = true
        state = .working
    }

    private mutating func closeDialogs(where shouldClose: (AgentPermissionRequest) -> Bool) {
        for dialog in pendingDialogs where shouldClose(dialog) { noteClosed(dialog) }
        pendingDialogs.removeAll(where: shouldClose)
    }

    private mutating func noteClosed(_ dialog: AgentPermissionRequest) {
        lastDialogClosedAt = lastEventAt
        lastClosedDialogRequestedAt = dialog.requestedAt
    }

    /// A turn already running when Nirux first heard of it starts here.
    private mutating func noteTurnActivity(at timestamp: TimeInterval) {
        if turnStartedAt == nil { turnStartedAt = timestamp }
    }

    private mutating func endTurn() {
        hookWorking = false
        turnStartedAt = nil
    }

    /// PTY output arrived. Echo right after a keystroke/resize is not work.
    mutating func noteRead(now: Date) {
        let timestamp = now.timeIntervalSince1970
        if lastInteractionAt > 0, timestamp - lastInteractionAt < Self.echoWindow { return }
        lastReadAt = timestamp
    }

    /// A keystroke went to the PTY — marks both the echo window and real
    /// user engagement (fallback attention only counts after this).
    mutating func noteUserInput(now: Date) {
        hasUserInput = true
        lastInteractionAt = now.timeIntervalSince1970
    }

    /// Nirux sent typed input (keys, a paste) — the only way a dialog gets
    /// answered, which terminal replies and focus reports never do.
    mutating func noteKeystroke(now: Date) {
        lastKeystrokeAt = now.timeIntervalSince1970
    }

    /// The terminal resized/redrew — following output is echo, not work.
    /// Does NOT count as user engagement.
    mutating func noteInteraction(now: Date) {
        lastInteractionAt = now.timeIntervalSince1970
    }

    /// Reconcile with the foreground process (heartbeat tick). `fgName` is
    /// the foreground process name, "" when unknown.
    @discardableResult
    mutating func tick(fgName: String, isUserFocused: Bool, now: Date) -> AgentStatus {
        let isAgent = Self.isRecognizedAgentProcess(fgName)
        if fgName != lastForegroundName { foregroundChanged(to: fgName, isAgent: isAgent, now: now) }

        guard isAgent else {
            hookWorking = false
            hookKind = nil
            state = .idle
            return state
        }

        // Hook-authoritative path (Claude with installed hooks): events own
        // every transition; output silence mid-turn means nothing.
        if hookKind == "claude", fgName == "claude" {
            if hookWorking || isRunningAnsweredDialog(now: now) {
                state = .working
            } else if state == .needsAttention {
                if isUserFocused { state = .idle }
            } else if state == .working {
                state = .idle
            }
            return state
        }

        // Fallback: recent output = working; silence ends the turn.
        // Suppressed until the user has actually engaged (first keystroke)
        // and the new foreground command has settled — startup banners,
        // session replay and redraws otherwise fabricate a working →
        // needsAttention cycle for an agent that never ran a turn.
        let settled = foregroundSince.map { now.timeIntervalSince($0) >= Self.startupWindow } ?? false
        guard hasUserInput, settled else {
            state = .idle
            turnStartedAt = nil
            return state
        }
        // Output from before Codex reported its turn over is that turn's.
        let recentlyActive = lastReadAt > turnEndedAt
            && now.timeIntervalSince1970 - lastReadAt < Self.activityWindow
        // Without turn hooks, a turn is a stretch of output.
        switch state {
        case .idle:
            if recentlyActive { startFallbackTurn(now: now) }
        case .working:
            if !recentlyActive {
                state = isUserFocused ? .idle : .needsAttention
                // Silence can be a finished turn or the agent's own
                // approval prompt: no reason to claim.
                lastAttentionReason = nil
                turnStartedAt = nil
            }
        case .needsAttention:
            if recentlyActive {
                startFallbackTurn(now: now)
            } else if isUserFocused {
                state = .idle
            }
        }
        return state
    }

    /// A different foreground command inherits nothing from the previous
    /// one — except hook capability, which stays: the hook event
    /// (SessionStart) can arrive BEFORE the next process-table snapshot
    /// notices the change, and clearing it here would knock the session
    /// back into the flaky fallback for no reason.
    private mutating func foregroundChanged(to fgName: String, isAgent: Bool, now: Date) {
        lastForegroundName = fgName
        foregroundSince = now
        hookWorking = false
        lastReadAt = 0 // the old command's dying output is not this one's work
        lastAttentionReason = nil
        // Another agent took over the terminal: a `claude` that died without
        // SessionEnd left its dialogs behind. (A shell in front may just
        // mean it's suspended; a new claude's SessionStart clears them.)
        if isAgent, fgName != "claude" { pendingDialogs.removeAll() }
    }

    private mutating func startFallbackTurn(now: Date) {
        state = .working
        turnStartedAt = now.timeIntervalSince1970
    }

    /// Hooks go quiet once a dialog is answered: an approved tool fires
    /// nothing until it finishes, however long it runs. After the user
    /// typed into the column (the answer), sustained output — Claude's
    /// spinner while the tool runs — shows the column working; silence
    /// (a denial ends the turn) shows it idle. Never raises attention, and
    /// only with a single dialog open: with several, typing may have
    /// answered one while another still waits.
    private func isRunningAnsweredDialog(now: Date) -> Bool {
        let open = openDialogs
        guard open.count == 1, lastKeystrokeAt > open[0].requestedAt else { return false }
        return lastReadAt > lastKeystrokeAt
            && now.timeIntervalSince1970 - lastReadAt < Self.activityWindow
    }

    /// User saw the attention signal (focus, app activate).
    mutating func clearAttention() {
        if state == .needsAttention { state = .idle }
    }

    /// New shell in the same terminal (start/restart) — everything resets.
    mutating func reset() {
        state = .idle
        hookWorking = false
        hookKind = nil
        pendingDialogs.removeAll()
        lastAttentionReason = nil
        lastDialogClosedAt = 0
        lastClosedDialogRequestedAt = 0
        lastEventAt = 0
        turnEndedAt = 0
        turnStartedAt = nil
        lastReadAt = 0
        lastInteractionAt = 0
        lastKeystrokeAt = 0
        hasUserInput = false
        lastForegroundName = nil
        foregroundSince = nil
    }
}
