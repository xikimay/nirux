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
    private(set) var state: AgentStatus = .idle
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

    /// Central capability gate shared by local status and remote prompt
    /// routing. Bot commands remain agent-agnostic even as this allowlist
    /// grows with Nirux's supported terminal agents.
    static func isRecognizedAgentProcess(_ name: String) -> Bool {
        name == "claude" || name == "codex"
    }

    /// Why the column wants the user, while it does: the oldest pending
    /// dialog, else the last attention event's reason.
    var attentionReason: AgentAttentionReason? {
        guard state == .needsAttention else { return nil }
        return pendingDialogs.first?.reason ?? lastAttentionReason
    }

    /// Name-only entry point (a hook event without payload details).
    /// Returns true when the column flipped into `.needsAttention`.
    mutating func applyHook(
        _ name: AgentHookEvent.Name,
        kind: AgentHookEvent.Kind,
        source: String? = nil,
        isUserFocused: Bool
    ) -> Bool {
        apply(AgentHookEvent(kind: kind, name: name, source: source), isUserFocused: isUserFocused).firedAttention
    }

    /// Apply one hook event. `firedAttention` is set on the transition into
    /// `.needsAttention` (dock bounce, notification); already-attention
    /// stays quiet.
    mutating func apply(_ event: AgentHookEvent, isUserFocused: Bool) -> AgentHookOutcome {
        let now = event.timestamp
        var outcome = AgentHookOutcome()
        switch event.name {
        case .sessionStart where event.source == "compact":
            // Auto (mid-turn) or /compact: same conversation, no turn ends.
            hookKind = event.kind.rawValue
        case .sessionStart:
            hookKind = event.kind.rawValue
            endTurn()
            pendingDialogs.removeAll()
            state = .idle
        case .userPromptSubmit:
            hookKind = event.kind.rawValue
            // A prompt was typed at the main input: no dialog is on screen.
            pendingDialogs.removeAll()
            turnStartedAt = now
            hookWorking = true
            state = .working
        case .preToolUse:
            hookKind = event.kind.rawValue
            noteTurnActivity(at: now)
            resumeUnlessBlocked()
        case .postToolUse:
            hookKind = event.kind.rawValue
            noteTurnActivity(at: now)
            // The call ran: its dialog, if it had one, was answered.
            if let key = event.toolKey,
               let index = pendingDialogs.firstIndex(where: { $0.key == key && $0.agentID == event.agentID }) {
                pendingDialogs.remove(at: index)
            }
            resumeUnlessBlocked()
        case .permissionRequest:
            hookKind = event.kind.rawValue
            noteTurnActivity(at: now)
            let request = AgentPermissionRequest(
                toolName: event.toolName,
                summary: event.toolSummary,
                key: event.toolKey,
                agentID: event.agentID,
                requestedAt: now
            )
            pendingDialogs.append(request)
            outcome.attention = request.reason
            outcome.firedAttention = block(for: request.reason, isUserFocused: isUserFocused)
        case .notification:
            hookKind = event.kind.rawValue
            applyNotification(event, now: now, isUserFocused: isUserFocused, outcome: &outcome)
        case .subagentStop:
            // Its dialogs closed with it (a denial fires no hook).
            if let agentID = event.agentID {
                pendingDialogs.removeAll { $0.agentID == agentID }
            }
        case .stop:
            hookKind = event.kind.rawValue
            // The main thread finished: none of its dialogs is open.
            pendingDialogs.removeAll { $0.agentID == nil }
            endTurn()
            outcome.attention = .turnFinished
            outcome.firedAttention = block(for: .turnFinished, isUserFocused: isUserFocused)
        case .sessionEnd:
            endTurn()
            pendingDialogs.removeAll()
            hookKind = nil
            state = .idle
        case .turnComplete:
            // Codex: no working-state hooks — output fallback covers that.
            // The notify payload only marks the end of a turn.
            endTurn()
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
        case "auth_success", "elicitation_complete", "elicitation_response",
             "agent_completed", "quota_auto_resume_fired":
            return
        case "permission_prompt":
            // Sent ~6 s into a dialog nobody answered — after its
            // PermissionRequest, or alone (a sandboxed command's network
            // request, which fires no PermissionRequest).
            if let pending = pendingDialogs.first {
                reason = pending.reason
                outcome.isRepeat = true
            } else {
                reason = .permission(tool: nil, summary: event.detail)
                pendingDialogs.append(AgentPermissionRequest(
                    toolName: nil, summary: event.detail, key: nil, agentID: nil, requestedAt: now
                ))
            }
        case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
            reason = .question(event.detail)
            pendingDialogs.append(AgentPermissionRequest(
                toolName: nil, summary: event.detail, key: nil, agentID: nil, requestedAt: now, isQuestion: true
            ))
        case "idle_prompt":
            // Claude finished responding a minute ago: the main thread sits
            // at its prompt, not in a dialog.
            pendingDialogs.removeAll { $0.agentID == nil }
            reason = .turnFinished
        default:
            reason = .message(event.detail)
        }
        outcome.attention = reason
        outcome.firedAttention = block(for: reason, isUserFocused: isUserFocused)
    }

    /// The agent waits on the user: it no longer works (leave hookWorking
    /// set and the next tick would flip needsAttention straight back to
    /// `.working` while the agent sits idle).
    private mutating func block(for reason: AgentAttentionReason, isUserFocused: Bool) -> Bool {
        hookWorking = false
        lastAttentionReason = reason
        return requestAttention(isUserFocused: isUserFocused)
    }

    /// A tool event: the agent works — unless a dialog still waits. Other
    /// subagents keep calling tools while one waits on the user, and the
    /// column must keep saying it is blocked.
    private mutating func resumeUnlessBlocked() {
        guard pendingDialogs.isEmpty else { return }
        hookWorking = true
        state = .working
    }

    /// A turn already running when Nirux first heard of it starts here.
    private mutating func noteTurnActivity(at timestamp: TimeInterval) {
        if turnStartedAt == nil { turnStartedAt = timestamp }
    }

    private mutating func endTurn() {
        hookWorking = false
        turnStartedAt = nil
    }

    private mutating func requestAttention(isUserFocused: Bool) -> Bool {
        if isUserFocused {
            state = .idle
            return false
        }
        if state == .needsAttention { return false }
        state = .needsAttention
        return true
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

        if fgName != lastForegroundName {
            lastForegroundName = fgName
            foregroundSince = now
            // A different foreground command inherits nothing from the
            // previous one — except hook capability, which stays: the hook
            // event (SessionStart) can arrive BEFORE the next process-table
            // snapshot notices the change, and clearing it here would knock
            // the session back into the flaky fallback for no reason.
            hookWorking = false
            lastReadAt = 0 // the old command's dying output is not this one's work
        }

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
        let recentlyActive = lastReadAt > 0
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

    private mutating func startFallbackTurn(now: Date) {
        state = .working
        turnStartedAt = now.timeIntervalSince1970
    }

    /// Hooks go quiet once a dialog is answered: an approved tool fires
    /// nothing until it finishes, however long it runs. After the user
    /// typed into the column (the answer), sustained output — Claude's
    /// spinner while the tool runs — shows the column working; silence
    /// (a denial ends the turn) shows it idle. Never raises attention.
    private func isRunningAnsweredDialog(now: Date) -> Bool {
        guard let latest = pendingDialogs.last, lastKeystrokeAt > latest.requestedAt else { return false }
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
        turnStartedAt = nil
        lastReadAt = 0
        lastInteractionAt = 0
        lastKeystrokeAt = 0
        hasUserInput = false
        lastForegroundName = nil
        foregroundSince = nil
    }
}
