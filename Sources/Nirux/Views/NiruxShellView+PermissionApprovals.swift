import AppKit

// MARK: - Sidebar permission approvals (Settings → Experimental)

extension NiruxShellView {
    /// Allow / Deny clicked under a column (see `PermissionApproval`).
    func decidePermission(
        workspaceIndex: Int,
        columnIndex: Int,
        requestID: String,
        behavior: PermissionApproval.Behavior
    ) {
        defer { updateSidebar() }
        let hooks = AgentHookCenter.shared
        guard hooks.approvalsEnabled, behavior != .release,
              workspaces.indices.contains(workspaceIndex),
              let column = workspaces[workspaceIndex].columns[safe: columnIndex],
              let pty = column.pty,
              let agentUUID = column.agentUUID else { return }
        let now = Date().timeIntervalSince1970
        // Still open: not closed, expired or decided since the sidebar drew it.
        guard let request = pty.markApprovalSent(requestID: requestID, behavior: behavior, now: now) else {
            NSSound.beep()
            return
        }
        // The column's `claude` must still run the session that asked.
        let foreground = pty.foregroundProcess(snapshot: ProcessSnapshot())
        let sent = request.sessionID.map { sessionID in
            column.confirmedClaudeSessionID(foregroundProcess: foreground) == sessionID
                && hooks.approvalChannel().send(PermissionApprovalDecision(
                    requestID: requestID,
                    sessionID: sessionID,
                    agentUUID: agentUUID,
                    behavior: behavior,
                    issuedAt: now
                ))
        } ?? false
        guard sent else {
            // Nothing reached the receiver: the terminal dialog answers.
            if let dropped = pty.dropApproval(requestID: requestID) {
                hooks.release(dropped, agentUUID: agentUUID)
            }
            NSSound.beep()
            return
        }
        NSLog("[Approvals] %@ sent for %@ request %@", behavior.rawValue, request.toolName ?? "?", requestID)
    }

    /// What the column's card offers. A column on screen answers in its
    /// terminal, and so does every column while no card can show Allow /
    /// Deny (collapsed sidebar, pilot mode): their requests are released.
    func sidebarApproval(for column: ColumnState, isOnScreen: Bool) -> SidebarPermissionApproval? {
        guard isSidebarExpanded, !isPilotMode, !isOnScreen else {
            releaseHeldApprovals(of: column)
            return nil
        }
        return column.pty?.sidebarApproval(now: Date().timeIntervalSince1970).flatMap(SidebarPermissionApproval.init)
    }

    /// The sidebar holds requests only for columns the user is not looking
    /// at, while its cards can show them: otherwise the terminal dialog
    /// answers. Releasing also lets a background subagent's dialog, which
    /// waits for the hook, show at once.
    func releaseHeldApprovals(of column: ColumnState) {
        guard let pty = column.pty else { return }
        for request in pty.takeUndecidedApprovals() {
            AgentHookCenter.shared.release(request, agentUUID: column.agentUUID)
        }
    }

    /// The option was turned off: every held request goes back to its
    /// terminal dialog.
    func releaseAllPermissionApprovals() {
        for workspace in workspaces {
            for column in workspace.columns { releaseHeldApprovals(of: column) }
        }
        updateSidebar()
    }

    static func currentSidebarApprovalsEnabled() -> Bool {
        Persistence.load()?.settings?.sidebarApprovalsEnabled == true
    }
}

extension AgentHookCenter {
    /// Turn sidebar approvals on or off for hook receivers: the marker in
    /// the channel names this process while on. Stale decisions of an
    /// earlier run are swept either way.
    func applySidebarApprovals(enabled: Bool) {
        approvalsEnabled = enabled
        let channel = approvalChannel()
        channel.setListening(enabled ? ProcessInstance.running(pid: getpid()) : nil)
        channel.sweep()
    }
}
