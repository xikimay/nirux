import Foundation

/// Agent status state machine for one terminal column.
///
/// Two information sources, in decreasing order of reliability:
/// 1. **Hook events** (Claude Code hooks / Codex notify, routed via
///    `AgentHookCenter`) — exact lifecycle signals. Once a Claude session
///    proves it emits hooks, they are authoritative: `working` means a turn
///    is in flight, `Stop`/`Notification` end it. No output heuristic can
///    misfire on redraws, spinners, or long silent tool calls.
/// 2. **Output activity fallback** (agents without hooks — Codex between
///    turns, Claude sessions started before the hooks were installed):
///    recent PTY output means working; silence means the turn ended.
///
/// Pure value type with injected time — fully unit-testable. `PtySession`
/// owns one instance and feeds it reads, writes, resizes and hook events.
struct AgentStatusMachine {
    private(set) var state: AgentStatus = .idle
    /// Set by UserPromptSubmit/PreToolUse, cleared by Stop/SessionEnd.
    private var hookWorking = false
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

    /// Foreground-process tracking (drives the "working · 12m" display and
    /// the isAgent gate in `tick`).
    private(set) var lastForegroundName: String?
    private(set) var foregroundSince: Date?

    private static let echoWindow: TimeInterval = 0.3
    private static let activityWindow: TimeInterval = 3.0

    /// True when a hook event should flip the column to `.needsAttention`:
    /// the transition into attention fires a callback (dock bounce, sidebar
    /// badge); already-attention stays quiet.
    mutating func applyHook(_ name: AgentHookEvent.Name, kind: AgentHookEvent.Kind, isUserFocused: Bool) -> Bool {
        switch name {
        case .sessionStart:
            hookKind = kind.rawValue
            hookWorking = false
            state = .idle
        case .userPromptSubmit, .preToolUse:
            hookKind = kind.rawValue
            hookWorking = true
            state = .working
        case .notification:
            hookKind = kind.rawValue
            return requestAttention(isUserFocused: isUserFocused)
        case .stop:
            hookKind = kind.rawValue
            hookWorking = false
            return requestAttention(isUserFocused: isUserFocused)
        case .sessionEnd:
            hookWorking = false
            hookKind = nil
            state = .idle
        case .turnComplete:
            // Codex: no working-state hooks — output fallback covers that.
            // The notify payload only marks the end of a turn.
            return requestAttention(isUserFocused: isUserFocused)
        }
        return false
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
        let t = now.timeIntervalSince1970
        if lastInteractionAt > 0, t - lastInteractionAt < Self.echoWindow { return }
        lastReadAt = t
    }

    /// User typed or the terminal resized/redrew — following output is echo.
    mutating func noteInteraction(now: Date) {
        lastInteractionAt = now.timeIntervalSince1970
    }

    /// Reconcile with the foreground process (heartbeat tick). `fgName` is
    /// the foreground process name, "" when unknown.
    @discardableResult
    mutating func tick(fgName: String, isUserFocused: Bool, now: Date) -> AgentStatus {
        let isAgent = fgName == "claude" || fgName == "codex"

        if fgName != lastForegroundName {
            lastForegroundName = fgName
            foregroundSince = now
            // A different foreground command inherits nothing from the
            // previous one — except hook capability, which stays: the hook
            // event (SessionStart) can arrive BEFORE the next process-table
            // snapshot notices the change, and clearing it here would knock
            // the session back into the flaky fallback for no reason.
            hookWorking = false
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
            if hookWorking {
                state = .working
            } else if state == .needsAttention {
                if isUserFocused { state = .idle }
            } else if state == .working {
                state = .idle
            }
            return state
        }

        // Fallback: recent output = working; silence ends the turn.
        let recentlyActive = lastReadAt > 0
            && now.timeIntervalSince1970 - lastReadAt < Self.activityWindow
        switch state {
        case .idle:
            if recentlyActive { state = .working }
        case .working:
            if !recentlyActive {
                state = isUserFocused ? .idle : .needsAttention
            }
        case .needsAttention:
            if recentlyActive {
                state = .working
            } else if isUserFocused {
                state = .idle
            }
        }
        return state
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
        lastReadAt = 0
        lastInteractionAt = 0
        lastForegroundName = nil
        foregroundSince = nil
    }
}
