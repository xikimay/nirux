import AppKit

// MARK: - Sidebar, Git, PR, Terminal Redraw, Status Bar

extension NiruxShellView {
    func updateSidebar(snapshot: ProcessSnapshot? = nil) {
        let snapshot = snapshot ?? ProcessSnapshot()
        let infos = workspaces.enumerated().map { index, workspace in
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
                    editorFileName: editorFile
                )
            }
            return WorkspaceInfo(index: index, title: workspace.title, columnCount: workspace.columns.count,
                          focusedColumn: workspace.focusedIndex,
                          gitBranch: workspace.gitBranch, hasNotification: workspace.hasNotification, isActive: index == activeWSIndex,
                          columns: colInfos, prInfo: workspace.prInfo, diffStats: workspace.diffStats)
        }
        sidebar.update(workspaces: infos)

        // Update per-workspace pilot panels
        if isPilotMode {
            for (index, workspace) in workspaces.enumerated() {
                workspace.updatePilotPanel(info: infos[index])
            }
        }

        if let workspace = activeWorkspace {
            let wsInfo = infos[activeWSIndex]
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
        let hasAbove = infos.enumerated().contains { idx, wsInfo in
            idx < activeWSIndex && wsInfo.columns.contains { $0.agentStatus == .needsAttention }
        }
        let hasBelow = infos.enumerated().contains { idx, wsInfo in
            idx > activeWSIndex && wsInfo.columns.contains { $0.agentStatus == .needsAttention }
        }
        edgeGlowTop.setVisible(hasAbove)
        edgeGlowBottom.setVisible(hasBelow)

        updateAttentionBorders(infos: infos)
    }

    /// Pulsing orange border on columns with agent needing attention.
    private func updateAttentionBorders(infos: [WorkspaceInfo]) {
        let orangeBorder = NSColor.systemOrange.cgColor
        for (wsIndex, workspace) in workspaces.enumerated() {
            for (colIndex, col) in workspace.columns.enumerated() {
                let needsAttention = infos[wsIndex].columns[safe: colIndex]?.agentStatus == .needsAttention
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
