import AppKit

// MARK: - Sidebar, Git, PR, Terminal Redraw, Status Bar

extension NiruxShellView {
    func updateSidebar(snapshot: ProcessSnapshot? = nil) {
        let snapshot = snapshot ?? ProcessSnapshot()
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
                let editorFile = col.editorColumn?.currentPath.map {
                    ($0 as NSString).lastPathComponent
                }
                return ColumnInfo(
                    index: colIndex,
                    processName: col.pty?.foregroundProcessName(snapshot: snapshot),
                    abbreviatedCwd: col.pty?.childCwd?.abbreviatedPath(),
                    isFocused: isFocusedCol && isActive,
                    isWebView: col.isWebView,
                    webTitle: col.webViewColumn?.pageTitle,
                    terminalTitle: col.terminalTitle,
                    agentStatus: col.pty?.agentStatus(
                        snapshot: snapshot,
                        isUserFocused: isUserFocused
                    ) ?? .idle,
                    isEditor: col.isEditor,
                    editorFileName: editorFile,
                    editorIsDirty: col.editorColumn?.isDirty ?? false,
                    agentElapsedSeconds: col.pty?.foregroundProcessStartedAt
                        .map { Date().timeIntervalSince($0) }
                )
            }
            return WorkspaceInfo(index: index, title: workspace.title, profileID: workspace.profileID, isInactive: workspace.isInactive,
                          columnCount: workspace.columns.count,
                          focusedColumn: workspace.focusedIndex,
                          gitBranch: workspace.gitBranch, hasNotification: workspace.hasNotification, isActive: index == activeWSIndex,
                          columns: colInfos, prInfo: workspace.prInfo, diffStats: workspace.diffStats)
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
        sidebar.update(
            profiles: profileInfos, workspaces: infos,
            activity: ActivityStore.shared.feedEntries,
            activityReadTimestamp: ActivityStore.shared.lastReadTimestamp,
            liveWorkspaceIDs: Set(workspaces.map(\.id))
        )
        scheduleActivityReadMark()

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

    // MARK: - Activity feed

    /// Unread entries become read once they've actually been on screen for
    /// a beat: sidebar expanded, app active. A short dwell keeps the badge
    /// visible long enough to register ("3 new") before rows dim, and a
    /// collapse counts as "viewed" immediately (handled in toggleSidebar).
    private func scheduleActivityReadMark() {
        guard isSidebarExpanded, NSApp.isActive, ActivityStore.shared.unreadCount > 0 else { return }
        guard activityReadTimer == nil else { return }
        activityReadTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.activityReadTimer = nil
                guard self.isSidebarExpanded, NSApp.isActive else { return }
                ActivityStore.shared.markAllRead()
            }
        }
    }

    func cancelActivityReadMark() {
        activityReadTimer?.invalidate()
        activityReadTimer = nil
    }

    /// One-shot border pulse on a column — click feedback for activity-feed
    /// and notification click-through, which are otherwise a visual no-op
    /// when the target is already focused. Runs as an overlay so it can't
    /// clobber the focus border or the attention pulse.
    func flashColumnBorder(workspaceIndex: Int, columnIndex: Int?) {
        guard let workspace = workspaces[safe: workspaceIndex] else { return }
        let colIndex = columnIndex.flatMap { workspace.columns.indices.contains($0) ? $0 : nil }
            ?? workspace.focusedIndex
        guard let col = workspace.columns[safe: colIndex] else { return }

        let overlay = SidebarBackgroundView(frame: col.view.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 6
        overlay.layer?.borderWidth = 3
        overlay.layer?.borderColor = NSColor.niruxAccent.cgColor
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
        blink.fillMode = .forwards
        blink.isRemovedOnCompletion = false
        overlay.layer?.add(blink, forKey: "activityFlash")
        CATransaction.commit()
    }

    /// AgentHookCenter.onActivity entry point. Signal events become feed
    /// rows; prompt/tool pings are filtered out by ActivityEntry.init.
    func recordActivity(_ event: AgentHookEvent, resolution: AgentHookCenter.Resolution?) {
        let title = resolution?.workspace.title
            ?? event.workspaceID.flatMap { id in workspaces.first(where: { $0.id == id })?.title }
            ?? event.cwd.map { ($0 as NSString).lastPathComponent }
            ?? "agent"
        guard let entry = ActivityEntry(
            event: event, workspaceTitle: title, columnIndex: resolution?.columnIndex
        ) else { return }
        ActivityStore.shared.record(entry)
    }

    func refreshGitBranches() {
        for workspace in workspaces {
            if let col = workspace.columns[safe: workspace.focusedIndex], let cwd = col.pty?.childCwd {
                GitDetect.branchAsync(at: cwd) { [weak self, weak workspace] branch in
                    guard let workspace, workspace.gitBranch != branch else { return }
                    workspace.gitBranch = branch; self?.updateSidebar()
                }
            }
        }
    }

    func refreshPRInfo() {
        for workspace in workspaces {
            guard let branch = workspace.gitBranch, !branch.isEmpty else { continue }
            let cwd = workspace.columns[safe: workspace.focusedIndex]?.pty?.childCwd ?? workspace.cwd
            PRDetect.fetchAsync(branch: branch, cwd: cwd) { [weak self, weak workspace] info in
                guard let workspace,
                      workspace.prInfo?.number != info?.number
                      || workspace.prInfo?.ciStatus != info?.ciStatus
                      || workspace.prInfo?.reviewDecision != info?.reviewDecision
                      || workspace.prInfo?.mergeable != info?.mergeable
                      || workspace.prInfo?.isDraft != info?.isDraft else { return }
                workspace.prInfo = info
                self?.updateSidebar()
            }
            PRDetect.diffStatsAsync(cwd: cwd) { [weak self, weak workspace] stats in
                guard let workspace, workspace.diffStats != stats else { return }
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
