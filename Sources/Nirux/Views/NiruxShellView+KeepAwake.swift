import AppKit

// MARK: - Keep Mac Awake

extension NiruxShellView {
    static func currentKeepMacAwakeEnabled() -> Bool {
        Persistence.load()?.settings?.keepMacAwakeWhileAgentsWork ?? true
    }

    /// Agents mid-turn in every workspace, other spaces included, as of the
    /// last sidebar refresh (which ticks them all). An agent waiting on the
    /// user is not working.
    var workingAgentCount: Int {
        Self.workingAgentCount(of: workspaces.flatMap { $0.columns.compactMap(\.pty) })
    }

    static func workingAgentCount(of ptys: [PtySession], now: Date = Date()) -> Int {
        ptys.filter { pty in
            KeepAwakeController.countsAsWorking(
                pty.cachedAgentState, lastActivityAt: pty.lastAgentActivityAt, now: now.timeIntervalSince1970
            )
        }.count
    }

    func updateKeepAwake() {
        keepAwake?.update(workingAgentCount: workingAgentCount)
    }

    /// Longer than the heartbeat's 2 s, with slack for a busy main thread.
    static let heartbeatStaleAfter: TimeInterval = 10

    /// Keep-awake's poll. The heartbeat refreshes every 2 s, but it stops in
    /// the background and its timer waits out a modal alert; then only hook
    /// events and title changes refresh, so the turn of an agent without
    /// hooks — Codex, Gemini CLI, OpenCode, or one a Telegram prompt
    /// started — would neither start nor end.
    func refreshAgentStatusInBackground() {
        let sinceRefresh = ProcessInfo.processInfo.systemUptime - lastMetadataRefreshAt
        guard sinceRefresh > Self.heartbeatStaleAfter else { return }
        let now = Date()
        let ptys = workspaces.flatMap { $0.columns.compactMap(\.pty) }
        guard ptys.contains(where: { Self.needsBackgroundRefresh($0, now: now) }) else {
            // Nothing to re-read, but a turn may have gone silent since the
            // last count (a Claude interrupted with Esc stays "working" with
            // no hook to end it): the controller must drop it.
            updateKeepAwake()
            return
        }
        updateSidebar()
    }

    /// A turn in progress, to see it end; or an agent whose turn would
    /// start unseen. A Claude with hooks needs no poll — its hook events
    /// refresh the sidebar — except with a dialog open: once answered, the
    /// approved tool runs without a hook, seen only by a tick.
    static func needsBackgroundRefresh(_ pty: PtySession, now: Date = Date()) -> Bool {
        KeepAwakeController.countsAsWorking(
            pty.cachedAgentState, lastActivityAt: pty.lastAgentActivityAt, now: now.timeIntervalSince1970
        )
            || pty.pendingAgentDialog != nil
            || (pty.lastSeenRunningAgent && pty.agentHookKind != "claude")
    }
}
