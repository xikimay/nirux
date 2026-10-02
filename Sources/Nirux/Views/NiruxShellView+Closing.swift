import AppKit

// MARK: - Closing Columns & Workspaces

/// Every path that closes a column or a workspace — ⌘W and the sidebar's
/// Close Column / Close Workspace — goes through `WorkspaceClosePolicy`,
/// so a live agent is never killed without confirmation.
extension NiruxShellView {
    func closeActiveColumn() {
        guard let workspace = activeWorkspace,
              let closingColumn = workspace.columns[safe: workspace.focusedIndex],
              !closingColumn.isClosing // repeat ⌘W during its exit animation
        else { return }
        // Last column closes the workspace — same confirmation as the sidebar.
        guard workspace.openColumns.count > 1 else { return requestCloseWorkspace(at: activeWSIndex) }
        guard confirmCloseColumn(closingColumn, in: workspace) else { return }
        closingColumn.isClosing = true
        let closingView = closingColumn.view

        // Animate out, then remove
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
            closingView.animator().alphaValue = 0
            closingView.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.92, y: 0.92))
        }, completionHandler: {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                closingView.layer?.setAffineTransform(.identity)
                // By identity: the index can shift during the animation.
                guard workspace.columns.count > 1,
                      let closingIndex = workspace.columns.firstIndex(where: { $0 === closingColumn })
                else {
                    // Nothing to remove after all — don't leave it invisible.
                    closingColumn.isClosing = false
                    closingView.alphaValue = 1
                    return
                }
                // Still focused: the user lands on its neighbour. An
                // agent's open during the animation focused its editor
                // without the keyboard instead.
                let landsOnNeighbour = workspace.columns[safe: workspace.focusedIndex] === closingColumn
                workspace.closeColumn(at: closingIndex)
                self.relayout(animated: false)
                // Animate remaining columns sliding into place
                workspace.layoutAndScroll(
                    viewportWidth: self.viewport.frame.width,
                    height: workspace.containerView.frame.height,
                    animated: true
                )
                self.updateSidebar()
                self.focusActiveTerminal(
                    in: self.window, editorTakesKeyboard: landsOnNeighbour && self.activeWorkspace === workspace
                )
            }
        })
    }

    /// Close-workspace entry point for the sidebar menu and for ⌘W on a
    /// workspace's last column: confirm before killing live agent sessions
    /// or multi-column workspaces.
    func requestCloseWorkspace(at index: Int) {
        let remaining = workspaceStore.remainingWorkspaceCount
        guard let workspace = workspaces[safe: index], !workspace.isClosing,
              WorkspaceClosePolicy.canClose(totalWorkspaceCount: remaining)
        else { return }
        let columns = workspace.openColumns
        let snapshot = ProcessSnapshot()
        let context = WorkspaceClosePolicy.Context(
            totalWorkspaceCount: remaining,
            columnCount: columns.count,
            liveAgents: columns.compactMap { $0.liveAgent(snapshot: snapshot) },
            isWorktreeBacked: GitWorktree.isLinkedWorktree(at: workspace.cwd)
        )
        switch WorkspaceClosePolicy.decision(for: context) {
        case .blocked:
            return
        case .close:
            closeWorkspace(at: index)
        case .confirm(let details):
            guard confirmDestructiveClose(
                message: "Close workspace “\(workspace.title)”?",
                details: details,
                confirmTitle: "Close Workspace"
            ) else { return }
            // Main-queue work can mutate `workspaces` while the modal runs
            // (worktree creation finishing, a prior close's deferred removal) —
            // re-resolve the index by identity before closing.
            guard let currentIndex = workspaces.firstIndex(where: { $0 === workspace }) else { return }
            closeWorkspace(at: currentIndex)
        }
    }

    /// Confirmation gate for closing one column of a multi-column workspace
    /// (⌘W, sidebar Close Column). True when the column runs no live agent,
    /// or the user confirmed and the column is still there to close —
    /// main-queue work keeps running under the modal alert.
    func confirmCloseColumn(_ column: ColumnState, in workspace: WorkspaceState) -> Bool {
        let agent = column.pty == nil ? nil : column.liveAgent(snapshot: ProcessSnapshot())
        guard let details = WorkspaceClosePolicy.columnConfirmation(for: agent), let agent else { return true }
        guard confirmDestructiveClose(
            message: "Close column running \(agent.displayName)?",
            details: details,
            confirmTitle: "Close Column"
        ) else { return false }
        return workspaces.contains { $0 === workspace } && !workspace.isClosing
            && workspace.openColumns.count > 1 && workspace.openColumns.contains { $0 === column }
    }

    /// Close a specific column of a specific workspace (sidebar context
    /// menu). The ⌘W path only reaches the focused column of the active
    /// workspace; this mirrors its non-animated bookkeeping.
    func closeColumn(workspaceIndex: Int, columnIndex: Int) {
        guard let workspace = workspaces[safe: workspaceIndex], !workspace.isClosing,
              workspace.openColumns.count > 1,
              let column = workspace.columns[safe: columnIndex], !column.isClosing,
              confirmCloseColumn(column, in: workspace),
              let currentIndex = workspace.columns.firstIndex(where: { $0 === column })
        else { return }
        workspace.closeColumn(at: currentIndex)
        relayout(animated: false)
        workspace.layoutAndScroll(
            viewportWidth: viewport.frame.width,
            height: workspace.containerView.frame.height,
            animated: true
        )
        updateSidebar()
        focusActiveTerminal(in: window)
        saveState()
    }

    func closeWorkspace(at index: Int) {
        guard workspaceStore.remainingWorkspaceCount > 1,
              let wsToRemove = workspaces[safe: index], !wsToRemove.isClosing
        else { return }
        // The store keeps it until the exit animation ends — flag it so a
        // quick second ⌘W neither counts nor selects it meanwhile.
        wsToRemove.isClosing = true
        // Only move the selection when the *active* workspace is going away —
        // closing another workspace from its context menu must not steal focus.
        if index == activeWSIndex,
           let target = workspaceStore.fallbackIndexAfterClosingWorkspace(at: index) {
            let changesSpace = workspaces[target].profileID != activeProfileID
            workspaceStore.selectWorkspace(at: target)
            // As any switch: its badge, git context and title bars. Another
            // space shows at once, as when picked in the sidebar: a slide
            // from this space's strip would mean nothing there.
            refreshAfterWorkspaceSelection(animated: !changesSpace)
        } else {
            relayout(animated: true)
            updateSidebar()
            focusActiveTerminal(in: window)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            guard let removed = self.workspaceStore.removeWorkspace(wsToRemove) else { return }

            removed.containerView.removeFromSuperview()
            self.relayout(animated: false)
            self.updateSidebar()
        }
    }

    /// Return and Escape cancel; closing takes a click or ⌘D. The ⌘W that
    /// opened the alert may be an accident mid-prompt, and the keys that
    /// come next — Return to send, ⌘⌫ to clear the line — must not confirm
    /// the kill. Plain ⌘D is unbound in Nirux, so no reflex reaches it.
    /// Also used for other destructive confirmations (Delete Space, worktree
    /// clean-up). Past a dozen lines (or as much text), the details scroll
    /// instead of growing the alert.
    func confirmDestructiveClose(message: String, details: [String], confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        if details.count > Self.inlineAlertDetailLimit
            || details.reduce(0, { $0 + $1.count }) > Self.inlineAlertCharacterLimit {
            alert.accessoryView = Self.scrollingDetails(details)
        } else {
            alert.informativeText = details.joined(separator: "\n")
        }
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        let confirm = alert.addButton(withTitle: confirmTitle)
        confirm.hasDestructiveAction = true
        confirm.keyEquivalent = "d"
        confirm.keyEquivalentModifierMask = .command
        // A button holds one key equivalent and Cancel's is Return — route
        // Escape to it while the alert is up.
        let alertWindow = alert.window
        let escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 0x35, NSApp.modalWindow === alertWindow else { return event }
            cancel.performClick(nil)
            return nil
        }
        defer { escapeMonitor.map(NSEvent.removeMonitor) }
        return runModal(alert) == .alertSecondButtonReturn
    }

    private static let inlineAlertDetailLimit = 12
    private static let inlineAlertCharacterLimit = 1_200

    private static func scrollingDetails(_ lines: [String]) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 240))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        text.string = lines.joined(separator: "\n")
        text.textContainerInset = NSSize(width: 4, height: 4)
        text.autoresizingMask = [.width]
        scroll.documentView = text
        return scroll
    }
}

extension WorkspaceState {
    /// Columns not already on their way out.
    var openColumns: [ColumnState] { columns.filter { !$0.isClosing } }
}

extension ColumnState {
    /// The recognized agent closing this column would kill, with the
    /// status its machine last computed.
    func liveAgent(snapshot: ProcessSnapshot) -> WorkspaceClosePolicy.LiveAgent? {
        guard let pty, let name = pty.agentProcessName(snapshot: snapshot) else { return nil }
        return WorkspaceClosePolicy.LiveAgent(
            processName: name,
            machineStatus: pty.cachedAgentState,
            hookKind: pty.agentHookKind
        )
    }
}
