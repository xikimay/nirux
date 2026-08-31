import AppKit

// MARK: - Sidebar, Git, PR, Terminal Redraw, Status Bar

extension NiruxShellView {
    func updateSidebar(snapshot: ProcessSnapshot? = nil) {
        let snapshot = snapshot ?? ProcessSnapshot()
        var foregroundProcesses: [ObjectIdentifier: ForegroundProcess] = [:]
        var invalidatedCodexBinding = false
        for workspace in workspaces {
            for column in workspace.columns {
                let foregroundProcess = column.pty?.foregroundProcess(snapshot: snapshot)
                if let foregroundProcess {
                    foregroundProcesses[ObjectIdentifier(column)] = foregroundProcess
                }
                if column.invalidateCodexSessionIfProcessChanged(
                    foregroundProcess: foregroundProcess
                ) {
                    invalidatedCodexBinding = true
                }
            }
        }
        let visibleIndices = visibleWorkspaceIndices
        let infos = visibleIndices.map { index in
            let workspace = workspaces[index]
            let isActive = index == activeWSIndex
            let colInfos = workspace.columns.enumerated().map { colIndex, col in
                // In pilot mode the user sees every workspace's focused column
                // through its pilot panel, so treat any focused column as
                // user-focused — otherwise agents in non-active workspaces get
                // stuck in .needsAttention even while the user is watching
                // them, and that state persists incorrectly across mode
                // switches.
                let isFocusedCol = colIndex == workspace.focusedIndex
                let isUserFocused = isFocusedCol && (isActive || isPilotMode)
                let foregroundProcess = foregroundProcesses[ObjectIdentifier(col)]
                let editorFile = col.editorColumn?.currentPath.map {
                    ($0 as NSString).lastPathComponent
                }
                return ColumnInfo(
                    index: colIndex,
                    processName: foregroundProcess?.name,
                    abbreviatedCwd: col.pty?.childCwd?.abbreviatedPath(),
                    isFocused: isFocusedCol && isActive,
                    isWebView: col.isWebView,
                    webTitle: col.webViewColumn?.pageTitle,
                    terminalTitle: col.terminalTitle,
                    agentStatus: col.pty?.agentStatus(
                        foregroundProcess: foregroundProcess,
                        isUserFocused: isUserFocused
                    ) ?? .idle,
                    isEditor: col.isEditor,
                    editorFileName: editorFile,
                    editorIsDirty: col.editorColumn?.isDirty ?? false,
                    agentElapsedSeconds: col.pty?.foregroundProcessStartedAt
                        .map { Date().timeIntervalSince($0) }
                )
            }
            return WorkspaceInfo(id: workspace.id, index: index, title: workspace.title,
                          profileID: workspace.profileID, isInactive: workspace.isInactive,
                          columnCount: workspace.columns.count,
                          focusedColumn: workspace.focusedIndex,
                          gitBranch: workspace.gitBranch, hasNotification: workspace.hasNotification, isActive: index == activeWSIndex,
                          columns: colInfos, prInfo: workspace.prInfo, diffStats: workspace.diffStats,
                          purpose: workspace.purpose, nextStep: workspace.nextStep,
                          blocker: workspace.blocker, phase: workspace.effectivePhase,
                          lastSummary: workspace.lastSummary, lastActivityAt: workspace.lastActivityAt)
        }
        let profileInfos = workspaceStore.navigableProfiles.map { profile in
            let profileWorkspaces = workspaces.filter { $0.profileID == profile.id }
            let hasAttention = profileWorkspaces.contains { workspace in
                workspace.hasNotification || workspace.columns.contains { $0.pty?.cachedAgentState == .needsAttention }
            }
            return ProfileInfo(
                id: profile.id,
                name: profile.name,
                colorHex: profile.colorHex,
                isActive: profile.id == activeProfileID,
                workspaceCount: profileWorkspaces.count,
                hasAttention: hasAttention
            )
        }
        sidebar.update(profiles: profileInfos, workspaces: infos)
        updateSidebarAttention(infos: infos)
        if invalidatedCodexBinding { saveState(snapshot: snapshot) }
        scheduleActivityReadMark()
    }

    private func updateSidebarAttention(infos: [WorkspaceInfo]) {
        // Dock badge: workspaces currently waiting for attention.
        let attentionCount = workspaces.filter { workspace in
            workspace.hasNotification
                || workspace.columns.contains { $0.pty?.cachedAgentState == .needsAttention }
        }.count
        NiruxNotifier.shared.updateDockBadge(attentionCount: attentionCount)

        // Update per-workspace pilot panels
        if isPilotMode {
            for info in infos {
                workspaces[info.index].updatePilotPanel(info: info)
            }
        }

        if let workspace = activeWorkspace,
           let wsInfo = infos.first(where: { $0.index == activeWSIndex }) {
            let statuses = wsInfo.columns.map { $0.agentStatus }
            columnIndicator.update(columnCount: workspace.columns.count, focusedIndex: workspace.focusedIndex, columnStatuses: statuses)

            // Horizontal edge glow: column needs attention left/right of focused column
            let focused = workspace.focusedIndex
            let hasLeft = wsInfo.columns.enumerated().contains { idx, col in idx < focused && col.agentStatus == .needsAttention }
            let hasRight = wsInfo.columns.enumerated().contains { idx, col in idx > focused && col.agentStatus == .needsAttention }
            edgeGlowLeft.setVisible(hasLeft)
            edgeGlowRight.setVisible(hasRight)
        } else {
            edgeGlowLeft.setVisible(false)
            edgeGlowRight.setVisible(false)
        }

        // Vertical edge glow: workspace above/below active has agent needing attention
        let activePosition = infos.firstIndex { $0.index == activeWSIndex } ?? 0
        let hasAbove = infos.enumerated().contains { position, wsInfo in
            position < activePosition && wsInfo.columns.contains { $0.agentStatus == .needsAttention }
        }
        let hasBelow = infos.enumerated().contains { position, wsInfo in
            position > activePosition && wsInfo.columns.contains { $0.agentStatus == .needsAttention }
        }
        edgeGlowTop.setVisible(hasAbove)
        edgeGlowBottom.setVisible(hasBelow)

        updateAttentionBorders(infos: infos)
    }

    /// Pulsing orange border on columns with agent needing attention.
    private func updateAttentionBorders(infos: [WorkspaceInfo]) {
        let orangeBorder = NSColor.systemOrange.cgColor
        let infoByIndex = Dictionary(uniqueKeysWithValues: infos.map { ($0.index, $0) })
        for (wsIndex, workspace) in workspaces.enumerated() {
            for (colIndex, col) in workspace.columns.enumerated() {
                let needsAttention = infoByIndex[wsIndex]?.columns[safe: colIndex]?.agentStatus == .needsAttention
                let colLayer = col.view.layer
                if needsAttention {
                    colLayer?.cornerRadius = 6
                    colLayer?.borderWidth = 2
                    colLayer?.borderColor = orangeBorder
                    if colLayer?.animation(forKey: "attentionPulse") == nil {
                        let pulse = CABasicAnimation(keyPath: "borderColor")
                        pulse.fromValue = orangeBorder
                        pulse.toValue = NSColor.systemOrange.withAlphaComponent(0.15).cgColor
                        pulse.duration = 0.6
                        pulse.autoreverses = true
                        pulse.repeatCount = .infinity
                        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        colLayer?.add(pulse, forKey: "attentionPulse")
                    }
                } else if colLayer?.animation(forKey: "attentionPulse") != nil {
                    colLayer?.removeAnimation(forKey: "attentionPulse")
                    // Restore focus border if this is the focused column
                    let isFocus = (wsIndex == activeWSIndex && colIndex == workspace.focusedIndex)
                    let accent = NSColor.niruxAccent.withAlphaComponent(0.7).cgColor
                    colLayer?.cornerRadius = isFocus ? 6 : 0
                    colLayer?.borderWidth = isFocus ? 2 : 0
                    colLayer?.borderColor = isFocus ? accent : nil
                }
            }
        }
    }

    func clearAllAgentAttention() {
        // Called from `didBecomeActiveNotification`. Must stay cheap — the
        // full `updateSidebar()` does a `sysctl(KERN_PROC_ALL)` plus a
        // `proc_pidinfo` per column, and on resume that can land in the same
        // tick as Metal restoring every Ghostty surface, freezing the UI for
        // seconds when many agents are running. Just clear the flags and the
        // attention borders directly; the next heartbeat (2s) refreshes the
        // sidebar with fresh process info.
        NiruxNotifier.shared.updateDockBadge(attentionCount: 0)
        NiruxNotifier.shared.clearDelivered()
        for (wsIndex, workspace) in workspaces.enumerated() {
            workspace.hasNotification = false
            for (colIndex, col) in workspace.columns.enumerated() {
                col.pty?.clearAgentAttention()
                let colLayer = col.view.layer
                guard colLayer?.animation(forKey: "attentionPulse") != nil else { continue }
                colLayer?.removeAnimation(forKey: "attentionPulse")
                let isFocus = (wsIndex == activeWSIndex && colIndex == workspace.focusedIndex)
                let accent = NSColor.niruxAccent.withAlphaComponent(0.7).cgColor
                colLayer?.cornerRadius = isFocus ? 6 : 0
                colLayer?.borderWidth = isFocus ? 2 : 0
                colLayer?.borderColor = isFocus ? accent : nil
            }
        }
    }

    private static let flashOverlayID = NSUserInterfaceItemIdentifier("nirux.focusFlashOverlay")

    @objc func handleSidebarActivityActivation(_ notification: Notification) {
        guard let entry = notification.userInfo?["entry"] as? ActivityEntry else { return }
        handleActivityEntry(entry)
    }

    /// Mission questions are actionable mailbox rows: clicking offers a
    /// reply without stealing focus from the parent workspace. Other rows
    /// keep click-to-focus behavior.
    func handleActivityEntry(_ entry: ActivityEntry) {
        guard entry.category == .missionQuestion,
              let questionID = entry.missionEventID,
              MissionStore.shared.response(to: questionID) == nil
        else {
            focusActivityEntry(entry)
            return
        }
        ActivityStore.shared.markRead(upTo: entry.timestamp)
        showMissionReplyPanel(entry: entry, questionID: questionID)
    }

    private func showMissionReplyPanel(entry: ActivityEntry, questionID: String) {
        let alert = NSAlert()
        alert.messageText = "Reply to \(entry.workspaceTitle)"
        alert.informativeText = entry.detail ?? "The child mission needs input."
        alert.alertStyle = .informational

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.placeholderString = "Concise answer for the child agent"
        alert.accessoryView = input
        alert.addButton(withTitle: "Reply")
        alert.addButton(withTitle: "Open Child")
        alert.addButton(withTitle: "Cancel")

        let result = alert.runModal()
        if result == .alertSecondButtonReturn {
            focusActivityEntry(entry)
            return
        }
        guard result == .alertFirstButtonReturn else { return }

        guard let accepted = MissionStore.shared.respond(
            to: questionID,
            message: input.stringValue,
            enabled: Self.currentMissionHandoffsEnabled()
        ) else {
            NSSound.beep()
            return
        }
        if recordMissionActivity(accepted.mission, event: accepted.event) {
            MissionStore.shared.markDelivered(eventID: accepted.event.id)
        }
    }

    /// Click-through for an activity row. Prefers the agent's identity —
    /// unlike the frozen columnIndex it survives column reordering and
    /// closures, so the flash confirms the RIGHT column. Falls back to the
    /// event-time workspace/column when the agent has exited. Clicking is
    /// also an explicit acknowledgment: everything up to that entry is read.
    func focusActivityEntry(_ entry: ActivityEntry) {
        ActivityStore.shared.markRead(upTo: entry.timestamp)
        if let uuid = entry.agentUUID,
           let resolution = resolveAgentColumn(uuid: uuid),
           let wsIndex = workspaces.firstIndex(where: { $0 === resolution.workspace }) {
            switchToWorkspace(wsIndex)
            focusColumnByIndex(resolution.columnIndex)
            flashColumnBorder(workspaceIndex: wsIndex, columnIndex: resolution.columnIndex)
        } else if let workspaceID = entry.workspaceID {
            focusWorkspace(id: workspaceID, column: entry.columnIndex)
        }
    }

    /// Expanded, active, visible window with part of Activity in the viewport.
    var activityFeedIsVisibleToUser: Bool {
        isSidebarExpanded
            && NSApp.isActive
            && window?.isMiniaturized == false
            && window?.occlusionState.contains(.visible) == true
            && sidebar.isActivityFeedVisible
    }

    /// Unread entries become read after they have actually been visible.
    func scheduleActivityReadMark() {
        guard activityFeedIsVisibleToUser, ActivityStore.shared.unreadCount > 0 else { return }
        guard activityReadTimer == nil else { return }
        guard let cutoff = ActivityStore.shared.newestTimestamp else { return }
        let generation = activityReadGeneration
        activityReadTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, generation == self.activityReadGeneration else { return }
                self.activityReadTimer = nil
                guard self.activityFeedIsVisibleToUser else { return }
                ActivityStore.shared.markRead(upTo: cutoff)
            }
        }
    }

    /// Invalidates the pending dwell. Bumping the generation also
    /// neutralizes a timer that already fired but whose MainActor task
    /// hasn't run yet — that stale task must not touch a newer timer.
    func cancelActivityReadMark() {
        activityReadGeneration &+= 1
        activityReadTimer?.invalidate()
        activityReadTimer = nil
    }

    /// Rebuild Activity explicitly because the upstream sidebar render
    /// signature intentionally only tracks workspace navigation state.
    func refreshActivitySidebar() {
        updateSidebar()
        sidebar.rebuildContent()
        scheduleActivityReadMark()
    }

    /// One-shot border pulse on a column — click feedback for Activity and
    /// notification click-through, which are otherwise a visual no-op
    /// when the target is already focused. Runs as an overlay so it can't
    /// clobber the focus border or the attention pulse. The overlay's model
    /// opacity is 0: if the animation never runs or is dropped (layer
    /// rebuilt, view detached mid-flash), the failure mode is an invisible
    /// view, never a stuck border — and a delayed backstop removes it even
    /// if the CATransaction completion is lost.
    func flashColumnBorder(workspaceIndex: Int, columnIndex: Int?) {
        guard let workspace = workspaces[safe: workspaceIndex] else { return }
        let colIndex = columnIndex.flatMap { workspace.columns.indices.contains($0) ? $0 : nil }
            ?? workspace.focusedIndex
        guard let col = workspace.columns[safe: colIndex] else { return }

        // A notification storm can flash the same column repeatedly —
        // never stack overlays.
        col.view.subviews.filter { $0.identifier == Self.flashOverlayID }
            .forEach { $0.removeFromSuperview() }

        let overlay = SidebarBackgroundView(frame: col.view.bounds)
        overlay.identifier = Self.flashOverlayID
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 6
        overlay.layer?.borderWidth = 3
        overlay.layer?.borderColor = NSColor.niruxAccent.cgColor
        overlay.layer?.opacity = 0
        col.view.addSubview(overlay)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak overlay] in
            overlay?.removeFromSuperview()
        }
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1.0
        blink.toValue = 0.0
        blink.duration = 0.3
        blink.repeatCount = 2
        overlay.layer?.add(blink, forKey: "focusFlash")
        CATransaction.commit()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak overlay] in
            overlay?.removeFromSuperview()
        }
    }

    func applyAgentHookEvents(_ events: [AgentHookCenter.AppliedEvent]) {
        let snapshot = ProcessSnapshot()
        var changed = false
        for appliedEvent in events {
            let event = appliedEvent.event
            if event.kind == .codex,
               appliedEvent.resolution.column.captureCodexSession(
                   sessionID: event.sessionID,
                   emitterProcess: event.emitterProcess,
                   snapshot: snapshot
               ) {
                changed = true
            }

            if appliedEvent.resolution.workspace.recordAgentHookActivity(event) {
                changed = true
            }
        }
        updateSidebar(snapshot: snapshot)
        if changed { saveState(snapshot: snapshot) }
    }

    /// MissionEventCenter delivery target. The activity write is flushed
    /// before returning so the mission ledger can safely mark the event as
    /// delivered; replay remains idempotent through missionEventID.
    func recordMissionActivity(_ mission: Mission, event: MissionEvent) -> Bool {
        let workspace = workspaces.first(where: { $0.id == mission.childWorkspaceID })
        let columnIndex = workspace?.columns.firstIndex(where: { $0.agentUUID == mission.childAgentUUID })
        let category: ActivityEntry.Category
        switch event.kind {
        case .question: category = .missionQuestion
        case .completed: category = .missionCompleted
        case .response: category = .missionResponse
        case .acknowledged: return false
        }
        let entry = ActivityEntry(
            category: category,
            agentKind: event.kind == .response ? "parent" : mission.childAgentKind,
            agentUUID: mission.childAgentUUID,
            workspaceID: mission.childWorkspaceID,
            columnIndex: columnIndex,
            workspaceTitle: workspace?.title ?? mission.branch,
            detail: event.message,
            timestamp: event.timestamp,
            missionID: mission.id,
            missionEventID: event.id,
            missionReplyToEventID: event.inReplyTo
        )
        ActivityStore.shared.record(entry)
        ActivityStore.shared.flush()
        if event.kind == .question {
            workspace?.hasNotification = true
        } else if event.kind == .response {
            workspace?.hasNotification = false
        }
        if event.kind == .question || event.kind == .completed {
            NiruxNotifier.shared.postMissionEvent(
                workspaceID: mission.childWorkspaceID,
                workspaceTitle: workspace?.title ?? mission.branch,
                columnIndex: columnIndex,
                kind: event.kind,
                message: event.message
            )
        }
        refreshActivitySidebar()
        return true
    }

    func refreshGitBranches() {
        for workspace in workspaces {
            if let col = workspace.columns[safe: workspace.focusedIndex], let cwd = col.pty?.childCwd {
                let observation = workspace.beginGitContextObservation()
                GitDetect.contextAsync(at: cwd) { [weak workspace] context in
                    workspace?.applyGitContextObservation(
                        context,
                        observation: observation
                    )
                }
            }
        }
    }

    func refreshPRInfo() {
        refreshPRInfo(for: workspaces)
    }

    func refreshPRInfo(for candidates: [WorkspaceState]) {
        for workspace in candidates {
            guard PRDetect.shouldRefresh(
                isInactive: workspace.isInactive,
                branch: workspace.gitBranch
            ), let requestedContext = workspace.gitContext else { continue }
            let branch = requestedContext.branch
            let cwd = workspace.columns[safe: workspace.focusedIndex]?.pty?.childCwd ?? workspace.cwd
            PRDetect.fetchAsync(branch: branch, cwd: cwd) { [weak self, weak workspace] result in
                guard case .success(let queriedContext, let info) = result,
                      let workspace, !workspace.isInactive,
                      workspace.gitContext == queriedContext else { return }
                let currentCwd = workspace.columns[safe: workspace.focusedIndex]?.pty?.childCwd
                    ?? workspace.cwd
                GitDetect.contextAsync(at: currentCwd) { [weak self, weak workspace] currentContext in
                    guard let workspace, !workspace.isInactive,
                          workspace.gitContext == queriedContext,
                          currentContext == queriedContext,
                          workspace.applyPullRequestInfo(info, for: queriedContext)
                    else { return }
                    self?.updateSidebar()
                }
            }
            PRDetect.diffStatsAsync(cwd: cwd) { [weak self, weak workspace] stats in
                guard let workspace, !workspace.isInactive,
                      workspace.gitContext == requestedContext,
                      workspace.diffStats != stats else { return }
                workspace.diffStats = stats
                self?.updateSidebar()
            }
        }
    }

    // MARK: - Status Bar

    func showUpdateAvailable(version: String) {
        statusBar.showUpdate(version: version)
        relayout(animated: false)
    }

    // MARK: - Terminal Redraw

    private static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "-zsh", "-bash"]
    /// Processes that redraw correctly from SIGWINCH alone — Ctrl+L clears their session/screen.
    /// Claude Code rebinds Ctrl+L to `/clear`, so broadcasting it on every layout
    /// change (e.g. Cmd+E width cycle, pilot-mode toggle) wiped active sessions.
    private static let sigwinchOnly: Set<String> = ["codex", "claude"]

    /// Light redraw: ask every terminal to refresh its surface and mark its
    /// view dirty. No keystrokes are sent to the TUI — use
    /// `redrawAllTerminals()` when you also need to nudge TUI apps with Ctrl+L.
    func refreshTerminalSurfaces() {
        for workspace in workspaces {
            for col in workspace.columns {
                col.terminalView?.fitToSize()
                col.pty?.forceRedraw()
                col.terminalView?.needsDisplay = true
            }
        }
    }

    /// Heavy redraw: refresh every terminal surface and additionally send
    /// Ctrl+L (0x0C) to any foreground process that isn't a plain shell
    /// (claude, codex, vim, htop, etc.) so TUI apps repaint their buffer.
    func redrawAllTerminals() {
        let snap = ProcessSnapshot()
        for workspace in workspaces {
            for col in workspace.columns {
                col.terminalView?.fitToSize()
                col.pty?.forceRedraw()
                col.terminalView?.needsDisplay = true
                // Ctrl+L to any non-shell TUI (claude, vim, htop, etc.)
                // Skip processes that handle SIGWINCH correctly on their own.
                if let name = col.pty?.foregroundProcessName(snapshot: snap),
                   !Self.shells.contains(name),
                   !Self.sigwinchOnly.contains(name) {
                    col.pty?.sendRaw(Data([0x0C]))
                }
            }
        }
    }
}
