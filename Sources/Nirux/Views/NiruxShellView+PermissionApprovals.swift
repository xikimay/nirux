import AppKit

// MARK: - Sidebar permission approvals (Settings → Agents)

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

    /// Whether Nirux may hold the requests of a column: its buttons are
    /// offered, for a column the user is not looking at (its terminal
    /// dialog answers; once it comes on screen the request goes back there
    /// at the next refresh). Unfolded, on its card: not for another space
    /// (`listed` holds the listed workspaces) or a workspace in the folded
    /// inactive section (listed there when it waits, without its buttons).
    /// Folded, in the inbox and the rail's callout, which list every
    /// space's requests (decided with the Lead, 2026-11-16). Never under
    /// VoiceOver, which the buttons don't serve.
    func approvalHold(workspaceIndex: Int, columnIndex: Int, listed: Set<Int>) -> PermissionApprovalHold {
        guard workspaces.indices.contains(workspaceIndex) else { return .never }
        let workspace = workspaces[workspaceIndex]
        let isOnScreen = columnIndex == workspace.focusedIndex && workspaceIndex == activeWSIndex
        let cardShown = Self.offersApprovalButtons(
            sidebarShowsCards: sidebar.isExpanded, isOnScreen: isOnScreen,
            cardHasButtons: listed.contains(workspaceIndex)
                && sidebar.listsWorkspace(isInactive: workspace.isInactive, isActive: workspaceIndex == activeWSIndex),
            voiceOver: NSWorkspace.shared.isVoiceOverEnabled
        )
        let userSeesSidebar = Self.showsApprovalButtonsNow(
            sidebarShowsCards: sidebar.isExpanded, requestPanelOpen: requestsState.isInboxOpen || requestsState.isCalloutOpen
        ) && NSApp.isActive && window?.isVisible == true && window?.isMiniaturized == false
            && window?.occlusionState.contains(.visible) == true
        return PermissionApprovalHold(cardShown: cardShown, userSeesSidebar: userSeesSidebar)
    }

    /// Whether a column's Allow / Deny are offered somewhere: on its card
    /// while the sidebar shows the cards (`cardHasButtons`), in the inbox
    /// and the callout while it is folded; never for the column on screen
    /// or under VoiceOver.
    /// Whether Allow / Deny are drawn right now, which a background
    /// subagent's request waits for (its dialog waits for the hook): on the
    /// cards while the sidebar shows them; folded, only while the inbox or
    /// the callout is open, not behind the bar's count.
    static func showsApprovalButtonsNow(sidebarShowsCards: Bool, requestPanelOpen: Bool) -> Bool {
        sidebarShowsCards || requestPanelOpen
    }

    static func offersApprovalButtons(sidebarShowsCards: Bool, isOnScreen: Bool, cardHasButtons: Bool, voiceOver: Bool) -> Bool {
        guard !isOnScreen, !voiceOver else { return false }
        return sidebarShowsCards ? cardHasButtons : true
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
        PersistedSettings.effective(Persistence.load()?.settings).sidebarApprovalsEnabled
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
