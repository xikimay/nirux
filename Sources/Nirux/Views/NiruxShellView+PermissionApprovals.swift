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
        let snapshot = ProcessSnapshot()
        defer { updateSidebar(snapshot: snapshot) }
        let hooks = AgentHookCenter.shared
        guard hooks.approvalsEnabled, behavior != .release,
              workspaces.indices.contains(workspaceIndex),
              let column = workspaces[workspaceIndex].columns[safe: columnIndex],
              let pty = column.pty,
              let agentUUID = column.agentUUID else { return }
        let now = Date().timeIntervalSince1970
        // Still open: not closed, expired or decided since the sidebar drew it.
        guard let request = pty.markApprovalSent(requestID: requestID, behavior: behavior, now: now) else {
            showToast("This request was already answered, or it expired")
            return
        }
        // The column's `claude` must still run the session that asked.
        let foreground = pty.foregroundProcess(snapshot: snapshot)
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
            showToast("Couldn’t send the answer: answer it in the terminal", tone: .error)
            return
        }
        NSLog("[Approvals] %@ sent for %@ request %@", behavior.rawValue, request.toolName ?? "?", requestID)
    }

    /// Whether the sidebar may hold the requests of a column: its card is
    /// drawn with the buttons, for a column the user is not looking at
    /// (its terminal dialog answers). Not in a collapsed sidebar, another
    /// space (`listed` holds the listed workspaces), a workspace in the
    /// folded inactive section (listed there when it waits, without its
    /// buttons), or under VoiceOver, which the buttons don't serve.
    func approvalHold(workspaceIndex: Int, columnIndex: Int, listed: Set<Int>) -> PermissionApprovalHold {
        guard workspaces.indices.contains(workspaceIndex) else { return .never }
        let workspace = workspaces[workspaceIndex]
        let isOnScreen = columnIndex == workspace.focusedIndex && workspaceIndex == activeWSIndex
        let cardShown = isSidebarExpanded && !isOnScreen
            && listed.contains(workspaceIndex)
            && sidebar.listsWorkspace(isInactive: workspace.isInactive, isActive: workspaceIndex == activeWSIndex)
            && !NSWorkspace.shared.isVoiceOverEnabled
        let userSeesSidebar = NSApp.isActive && window?.isVisible == true && window?.isMiniaturized == false
            && window?.occlusionState.contains(.visible) == true
        return PermissionApprovalHold(cardShown: cardShown, userSeesSidebar: userSeesSidebar)
    }

    /// Release every request the sidebar can no longer hold (see
    /// `approvalHold`), across all workspaces. Returns each column's hold,
    /// for the cards.
    func releaseApprovalsNotHeld() -> [ObjectIdentifier: PermissionApprovalHold] {
        let listed = Set(visibleWorkspaceIndices)
        var holds: [ObjectIdentifier: PermissionApprovalHold] = [:]
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            for (columnIndex, column) in workspace.columns.enumerated() {
                let hold = approvalHold(workspaceIndex: workspaceIndex, columnIndex: columnIndex, listed: listed)
                holds[ObjectIdentifier(column)] = hold
                // A card shows one request: a subagent's held behind it
                // would only delay its dialog.
                let shown = column.pty?.sidebarApproval(now: Date().timeIntervalSince1970)?.approval?.requestID
                releaseHeldApprovals(of: column) {
                    !hold.holds(isSubagent: $0.agentID != nil)
                        || ($0.agentID != nil && $0.approval?.requestID != shown)
                }
            }
        }
        AgentHookCenter.shared.sweepApprovalsIfDue()
        return holds
    }

    /// What the column's card offers, if its card shows the buttons.
    func sidebarApproval(for column: ColumnState, hold: PermissionApprovalHold?) -> SidebarPermissionApproval? {
        guard hold?.cardShown == true else { return nil }
        let now = Date().timeIntervalSince1970
        return column.pty?.sidebarApproval(now: now).flatMap { SidebarPermissionApproval($0, now: now) }
    }

    /// Hand held requests back to their terminal dialog (all, or those
    /// `shouldRelease` picks). Releasing also lets a background subagent's
    /// dialog, which waits for the hook, show at once.
    func releaseHeldApprovals(
        of column: ColumnState,
        where shouldRelease: (AgentPermissionRequest) -> Bool = { _ in true }
    ) {
        guard let pty = column.pty else { return }
        for request in pty.takeUndecidedApprovals(where: shouldRelease) {
            AgentHookCenter.shared.release(request, agentUUID: column.agentUUID)
        }
    }

    /// The option was turned off, or the app quits: every held request
    /// goes back to its terminal dialog.
    func releaseAllPermissionApprovals() {
        for workspace in workspaces {
            for column in workspace.columns { releaseHeldApprovals(of: column) }
        }
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
        let channel = approvalChannel()
        let me = ProcessInstance.running(pid: getpid())
        var listening = false
        if enabled, let me {
            listening = channel.setListening(me)
            if !listening {
                NSLog("[Approvals] state directory not private to this user — sidebar approvals stay off")
            }
        } else {
            channel.stopListening(for: me)
        }
        approvalsEnabled = listening
        channel.sweep()
    }
}
