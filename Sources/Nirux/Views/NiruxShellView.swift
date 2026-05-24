import AppKit
import GhosttyTerminal

/// Root AppKit view: sidebar + niri-style 2D scrolling viewport
final class NiruxShellView: NSView {
    private static let collapsedSidebarWidth: CGFloat = 16
    private static let expandedSidebarWidth: CGFloat = 180
    var isSidebarExpanded = false
    private var sidebarWidth: CGFloat {
        if isPilotMode { return 0 }
        return isSidebarExpanded ? Self.expandedSidebarWidth : Self.collapsedSidebarWidth
    }

    let sidebar = SidebarView()
    let divider = NSBox()
    let viewport = NSView()
    let verticalStrip = NSView()
    let columnIndicator = ColumnIndicatorView()
    let statusBar = StatusBarView()
    let edgeGlowLeft = EdgeGlowView(edge: .left)
    let edgeGlowRight = EdgeGlowView(edge: .right)
    let edgeGlowTop = EdgeGlowView(edge: .top)
    let edgeGlowBottom = EdgeGlowView(edge: .bottom)

    let workspaceStore = WorkspaceStore()
    var workspaces: [WorkspaceState] {
        get { workspaceStore.workspaces }
        set { workspaceStore.replaceWorkspaces(newValue) }
    }
    var activeWSIndex: Int {
        get { workspaceStore.activeWorkspaceIndex }
        set { workspaceStore.selectWorkspace(at: newValue) }
    }
    var profiles: [WorkspaceProfile] {
        get { workspaceStore.profiles }
        set { workspaceStore.replaceProfiles(newValue, activeProfileID: activeProfileID) }
    }
    var activeProfileID: String {
        get { workspaceStore.activeProfileID }
        set { workspaceStore.selectProfile(newValue) }
    }
    var isPilotMode = false
    var pilotRefreshTimer: Timer?
    static let pilotMaxRows = 3
    static let pilotGap: CGFloat = 0
    var pilotOverlays: [NSView] = []
    var pilotActiveHighlight: NSView?
    var pilotClickMonitor: Any?
    var pilotHoverMonitor: Any?

    // Heartbeat
    var heartbeatTimer: Timer?
    var heartbeatTick: UInt = 0

    // Panel references (stored properties must live in main class declaration)
    var renamePanel: RenamePanel?
    var worktreePanel: WorktreePanel?
    var commandPalette: CommandPalette?
    var urlPanel: URLInputPanel?
    var filePickerPanel: FilePickerPanel?
    var searchPanel: EditorSearchPanel?

    /// Debounce timer used to nudge TUI agents (claude, codex, vim…) to
    /// redraw after the window stops resizing. Without this, agents that
    /// painted before the resize end up with broken text because their
    /// internal grid still matches the old size.
    private var resizeRedrawTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1).cgColor
        divider.boxType = .separator
        viewport.wantsLayer = true
        viewport.layer?.masksToBounds = true
        verticalStrip.wantsLayer = true
        viewport.addSubview(verticalStrip)
        addSubview(sidebar)
        addSubview(divider)
        addSubview(viewport)
        addSubview(columnIndicator)
        addSubview(edgeGlowLeft)
        addSubview(edgeGlowRight)
        addSubview(edgeGlowTop)
        addSubview(edgeGlowBottom)
        addSubview(statusBar)

        let workspace = WorkspaceState(title: "ws 1", cwd: NSHomeDirectory())
        workspace.onMetadataChanged = { [weak self] in self?.updateSidebar(); self?.refreshTitleBarLabels() }
        workspace.onDiffStatsClicked = { [weak self, weak workspace] in
            guard let workspace else { return }
            self?.openDiffInEditor(for: workspace)
        }
        workspaces.append(workspace)
        verticalStrip.addSubview(workspace.containerView)
        sidebar.onWorkspaceClicked = { [weak self] index in self?.switchToWorkspace(index) }
        sidebar.onWorkspaceAction = { [weak self] action, index in self?.handleWorkspaceSidebarAction(action, workspaceIndex: index) }
        sidebar.onProfileClicked = { [weak self] profileID in self?.selectProfile(profileID) }
        sidebar.onCreateProfile = { [weak self] in self?.createProfileFromActiveContext() }
        sidebar.onDiffStatsClicked = { [weak self] index in self?.openDiffInEditor(workspaceIndex: index) }
        sidebar.onColumnClicked = { [weak self] wsIndex, colIndex in
            guard let self else { return }
            if self.activeWSIndex != wsIndex { self.switchToWorkspace(wsIndex) }
            guard self.workspaces[wsIndex].focusedIndex != colIndex else { return }
            self.workspaces[wsIndex].focusedIndex = colIndex
            self.relayout(animated: true)
            self.updateSidebar()
            self.focusActiveTerminal(in: self.window)
        }
        updateSidebar()
        relayout(animated: false)

        startHeartbeat()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Heartbeat

    func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let snapshot = ProcessSnapshot()
                self.heartbeatTick &+= 1
                self.refreshGitBranches()
                self.refreshTitleBarLabels(snapshot: snapshot)
                self.updateSidebar(snapshot: snapshot)
                // Save state every ~10s (every 5th tick)
                if self.heartbeatTick % 5 == 0 { self.saveState(snapshot: snapshot) }
                // PR info every ~30s (every 15th tick)
                if self.heartbeatTick % 15 == 0 { self.refreshPRInfo() }
            }
        }
    }

    func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// Iterate every editor column across all workspaces. Used by the
    /// background lifecycle hooks to pause/resume per-editor file watchers.
    func forEachEditorColumn(_ body: (EditorColumn) -> Void) {
        for workspace in workspaces {
            for col in workspace.columns {
                if let editor = col.editorColumn { body(editor) }
            }
        }
    }

    // MARK: - Layout

    func relayout(animated: Bool) {
        let sidebarW = sidebarWidth
        // Status bar: always visible in pilot mode, or when it has content (update)
        statusBar.isHidden = !isPilotMode && !statusBar.hasContent
        let statusH = statusBar.isHidden ? CGFloat(0) : StatusBarView.height
        let viewportH = bounds.height - statusH; let viewportW = bounds.width - sidebarW - 1
        guard viewportH > 0, viewportW > 0 else { return }

        let glowWidth: CGFloat = 32
        let vpX = sidebarW + (isPilotMode ? 0 : 1)
        let vpFullW = viewportW + (isPilotMode ? 1 : 0)

        let frames = ChromeFrames(
            sidebar: NSRect(x: 0, y: statusH, width: sidebarW, height: bounds.height - statusH),
            divider: NSRect(x: sidebarW, y: statusH, width: 1, height: bounds.height - statusH),
            viewport: NSRect(x: vpX, y: statusH, width: vpFullW, height: viewportH),
            glowLeft: NSRect(x: vpX, y: statusH, width: glowWidth, height: viewportH),
            glowRight: NSRect(x: vpX + vpFullW - glowWidth, y: statusH, width: glowWidth, height: viewportH),
            glowTop: NSRect(x: vpX, y: statusH + viewportH - glowWidth, width: vpFullW, height: glowWidth),
            glowBottom: NSRect(x: vpX, y: statusH, width: vpFullW, height: glowWidth),
            indicator: NSRect(x: sidebarW + 1, y: 4, width: viewportW, height: 16),
            statusBar: NSRect(x: 0, y: 0, width: bounds.width, height: statusH)
        )
        applyChromeLayout(frames, animated: animated)

        // Compute row height: in focus mode each ws = full viewport,
        // in pilot mode each ws shrinks to show multiple rows
        let gap = isPilotMode ? Self.pilotGap : CGFloat(0)
        let rowH: CGFloat
        if isPilotMode {
            // Always show at least 2 rows so even 1 workspace visibly shrinks
            let displayRows = CGFloat(max(2, min(visibleWorkspaceIndices.count, Self.pilotMaxRows)))
            rowH = (viewportH - gap * (displayRows - 1)) / displayRows
        } else {
            rowH = viewportH
        }

        let visibleIndices = visibleWorkspaceIndices
        let wsCount = CGFloat(visibleIndices.count)
        let totalH = rowH * wsCount + gap * max(wsCount - 1, 0)

        // Position the strip so the active workspace is visible
        let targetY: CGFloat
        let activePosition = activeVisibleWorkspacePosition ?? 0
        if totalH <= viewportH {
            targetY = viewportH - totalH
        } else if !isPilotMode {
            targetY = -(totalH - CGFloat(activePosition + 1) * rowH)
        } else {
            let wsCenter = totalH - (CGFloat(activePosition) + 0.5) * rowH - CGFloat(activePosition) * gap
            let raw = viewportH / 2 - wsCenter
            targetY = max(viewportH - totalH, min(0, raw))
        }

        layoutWorkspaceStrip(StripLayout(
            viewportW: viewportW, viewportH: viewportH,
            totalH: totalH, rowH: rowH, gap: gap,
            targetY: targetY, animated: animated
        ))

        syncTerminalOcclusion()
    }

    // MARK: - Terminal Occlusion

    /// Tell each Ghostty terminal whether it's actually on screen. Workspaces
    /// in the vertical strip stay in the view hierarchy even when scrolled
    /// out of view, so the host window's occlusion state isn't enough — every
    /// surface's CVDisplayLink would still hit `waitUntilCompleted` on the
    /// main thread, which freezes the app once a few Claude/Codex sessions
    /// pile up. In pilot mode every workspace is visible; otherwise only the
    /// active one is.
    private func syncTerminalOcclusion() {
        for (index, workspace) in workspaces.enumerated() {
            let isInActiveProfile = workspace.profileID == activeProfileID
            let visible = isInActiveProfile && (isPilotMode || index == activeWSIndex)
            for col in workspace.columns {
                col.terminalView?.setSurfaceVisible(visible)
            }
        }
    }

    // MARK: - Title Bar Labels

    func refreshTitleBarLabels(snapshot: ProcessSnapshot? = nil) {
        let snap = snapshot ?? ProcessSnapshot()
        let visibleWorkspaces = isPilotMode
            ? visibleWorkspaceIndices.compactMap { workspaces[safe: $0] }
            : (activeWorkspace.map { [$0] } ?? [])
        for workspace in visibleWorkspaces {
            for col in workspace.columns {
                col.updateTitleBarLabel(snapshot: snap)
            }
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        relayout(animated: false)
        scheduleRedrawAfterResize()
    }

    /// Coalesce resize events: defer the redraw until ~0.3s after the last
    /// resize tick, so we only nudge TUI agents once at the end of a drag.
    private func scheduleRedrawAfterResize() {
        resizeRedrawTimer?.invalidate()
        resizeRedrawTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.redrawAllTerminals()
            }
        }
    }

    /// Fullscreen transitions can deliver their notification before AppKit and
    /// Ghostty agree on the final backing size. Re-run layout/surface sync on a
    /// few short delays so Claude/Codex get the final PTY dimensions.
    private func scheduleTerminalStabilizationAfterFullscreen() {
        for delay in [0.05, 0.25, 0.75] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.relayout(animated: false)
                self.redrawAllTerminals()
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        relayout(animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.updateSidebar() }

        if let window {
            NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.relayout(animated: false)
                    self?.scheduleTerminalStabilizationAfterFullscreen()
                }
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.relayout(animated: false)
                    self?.scheduleTerminalStabilizationAfterFullscreen()
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clearAllAgentAttention()
                self.startHeartbeat()
                if self.isPilotMode { self.startPilotRefresh() }
                self.forEachEditorColumn { $0.resumeFileWatch() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stopHeartbeat()
                self.stopPilotRefresh()
                self.forEachEditorColumn { $0.pauseFileWatch() }
            }
        }
    }

    // MARK: - Columns

    func addColumn() {
        guard let ws = activeWorkspace else { return }
        ws.addColumn()

        // Start new column invisible
        let newCol = ws.columns[ws.focusedIndex]
        newCol.view.alphaValue = 0
        newCol.view.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.92, y: 0.92))

        // Layout at final positions, then animate the new column in
        relayout(animated: false)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
            newCol.view.animator().alphaValue = 1
            newCol.view.layer?.setAffineTransform(.identity)
        }

        // Animate strip to show the new column
        ws.layoutAndScroll(
            viewportWidth: viewport.frame.width,
            height: ws.containerView.frame.height,
            animated: true, pilotMode: isPilotMode
        )

        updateSidebar()
        focusActiveTerminal(in: window)
    }

    func closeActiveColumn() {
        guard let workspace = activeWorkspace else { return }
        if workspace.columns.count > 1 {
            let closingIndex = workspace.focusedIndex
            let closingView = workspace.columns[closingIndex].view

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
                    workspace.closeColumn(at: closingIndex)
                    self.relayout(animated: false)
                    // Animate remaining columns sliding into place
                    workspace.layoutAndScroll(
                        viewportWidth: self.viewport.frame.width,
                        height: workspace.containerView.frame.height,
                        animated: true, pilotMode: self.isPilotMode
                    )
                    self.updateSidebar()
                    self.focusActiveTerminal(in: self.window)
                }
            })
        } else if workspaces.count > 1 {
            closeWorkspace(at: activeWSIndex)
        }
    }

    enum HDir { case left, right }
    func focusColumn(_ dir: HDir) {
        guard let workspace = activeWorkspace else { return }
        switch dir {
        case .left: if workspace.focusedIndex > 0 { workspace.focusedIndex -= 1 }
        case .right: if workspace.focusedIndex < workspace.columns.count - 1 { workspace.focusedIndex += 1 }
        }
        relayout(animated: true)
        updateSidebar()
        focusActiveTerminal(in: window)
    }

    func cycleActiveColumnWidth() {
        guard let workspace = activeWorkspace else { return }
        workspace.columns[workspace.focusedIndex].cycleWidth()
        relayout(animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.redrawAllTerminals()
        }
    }

    func moveColumn(_ dir: WorkspaceState.MoveDir) {
        guard let workspace = activeWorkspace else { return }
        workspace.moveColumn(dir)
        relayout(animated: true)
        focusActiveTerminal(in: window)
    }

    // MARK: - Rename Workspace

    func showRenamePanel() {
        guard let window, let workspace = activeWorkspace else { return }
        if renamePanel == nil {
            renamePanel = RenamePanel()
            renamePanel?.onRename = { [weak self] newTitle in
                self?.activeWorkspace?.title = newTitle
                self?.activeWorkspace?.titleIsManual = true
                self?.updateSidebar()
            }
        }
        renamePanel?.show(relativeTo: window, currentTitle: workspace.title)
    }

    // MARK: - Worktree

    func showWorktreePanel() {
        guard let window else { return }
        guard let cwd = activeWorkspace?.columns[safe: activeWorkspace?.focusedIndex ?? 0]?.pty?.childCwd,
              let repoRoot = GitWorktree.repoRoot(at: cwd)
        else { return }

        if worktreePanel == nil {
            worktreePanel = WorktreePanel()
            worktreePanel?.onCreated = { [weak self] branch, path, repoRoot in
                guard let self else { return }
                let col = self.activeWorkspace?.columns[safe: self.activeWorkspace?.focusedIndex ?? 0]
                let snapshot = ProcessSnapshot()
                let fgName = col?.pty?.foregroundProcessName(snapshot: snapshot)

                // If an agent is running, ask it to write a session handover then open via URL scheme
                // (same flow as the nirux-worktree skill).
                let runningAgent: NiruxApp.WorkspaceAgent?
                if fgName == "claude" {
                    runningAgent = .claude
                } else if fgName == "codex" {
                    runningAgent = .codex
                } else {
                    runningAgent = nil
                }
                if let runningAgent {
                    let dirName = branch.replacingOccurrences(of: "/", with: "-")
                    let handoverFileName = Self.handoverFilename(for: runningAgent)
                    let handoverTmp = "/tmp/nirux-handover-\(runningAgent.rawValue)-\(dirName).md"
                    let queryAllowed = CharacterSet.urlQueryAllowed
                    let url = "nirux://new-worktree"
                        + "?branch=\(branch.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? branch)"
                        + "&repo=\(repoRoot.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? repoRoot)"
                        + "&agent=\(runningAgent.rawValue)"
                        + "&handover=\(handoverTmp.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? handoverTmp)"
                    let prompt = "Write a concise session handover to \(handoverTmp) "
                        + "(sections: Goal, Context, Done so far, Next steps). "
                        + "Nirux will move it into the new worktree as \(handoverFileName). "
                        + "Then run: open \"\(url)\"\n"
                    col?.pty?.sendRaw(prompt)
                } else {
                    // No agent — open workspace directly (worktree already created by panel)
                    self.addWorkspace(title: branch, cwd: path, agent: .claude)
                }
            }
        }
        worktreePanel?.show(relativeTo: window, repoRoot: repoRoot)
    }

    func showWorktreeListPalette() {
        guard let window else { return }
        guard let cwd = activeWorkspace?.columns[safe: activeWorkspace?.focusedIndex ?? 0]?.pty?.childCwd,
              let repoRoot = GitWorktree.repoRoot(at: cwd)
        else { return }

        // List worktrees on background thread, then show palette
        DispatchQueue.global(qos: .userInitiated).async {
            let worktrees = GitWorktree.list(repoRoot: repoRoot)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Filter out the main repo (first entry is usually the main worktree)
                let entries = worktrees.filter { $0.path != repoRoot }
                guard !entries.isEmpty else { return }

                // Build palette actions from worktree entries
                let actions = entries.map { entry in
                    let title = entry.branch ?? URL(fileURLWithPath: entry.path).lastPathComponent
                    let subtitle = entry.path.abbreviatedPath()
                    return PaletteAction(icon: "🌿", title: title, subtitle: subtitle, shortcut: "") { [weak self] in
                        self?.addWorkspace(title: title, cwd: entry.path)
                    }
                }

                if self.commandPalette == nil {
                    self.commandPalette = CommandPalette()
                    self.commandPalette?.onURLSubmit = { [weak self] url in
                        self?.openWebView(url: url)
                    }
                    self.commandPalette?.onDismiss = { [weak self] in
                        self?.focusActiveTerminal(in: self?.window)
                    }
                }
                self.commandPalette?.actions = actions
                self.commandPalette?.show(relativeTo: window)
            }
        }
    }

    // MARK: - Command Palette (Cmd+P)

    func showCommandPalette() {
        guard let window else { return }

        if commandPalette?.isVisible == true {
            commandPalette?.dismiss()
            return
        }

        if commandPalette == nil {
            commandPalette = CommandPalette()
            commandPalette?.onURLSubmit = { [weak self] url in
                self?.openWebView(url: url)
            }
            commandPalette?.onDismiss = { [weak self] in
                self?.focusActiveTerminal(in: self?.window)
            }
        }

        commandPalette?.actions = [
            PaletteAction(icon: "🌐", title: "Open Browser", subtitle: "Open a URL in a new WebView column", shortcut: "⌘B") { [weak self] in
                self?.commandPalette?.switchToURLMode()
            },
            PaletteAction(icon: "🔑", title: "Import Browser Cookies", subtitle: importCookieSubtitle(), shortcut: "") { [weak self] in
                self?.importBrowserCookies()
            },
            PaletteAction(icon: "▶", title: "New Terminal", subtitle: "Open a new terminal column", shortcut: "⌘T") { [weak self] in
                self?.addColumn()
            },
            PaletteAction(icon: "📝", title: "Open Editor", subtitle: "Edit files in the current workspace", shortcut: "") { [weak self] in
                self?.openEditorColumn()
            },
            PaletteAction(icon: "🔎", title: "Search Workspace", subtitle: "Find text across files in the current workspace", shortcut: "⇧⌘F") { [weak self] in
                self?.showWorkspaceSearch()
            },
            PaletteAction(icon: "🔀", title: "Toggle Editor Diff", subtitle: "Show the diff for the active editor file", shortcut: "⇧⌘D") { [weak self] in
                self?.toggleEditorDiff()
            },
            PaletteAction(icon: "🤖", title: "Open Claude Code", subtitle: "Launch Claude Code in a new terminal", shortcut: "") { [weak self] in
                self?.openClaudeCode()
            },
            PaletteAction(icon: "📦", title: "Open Codex", subtitle: "Launch OpenAI Codex in a new terminal", shortcut: "") { [weak self] in
                self?.openCodex()
            },
            PaletteAction(icon: "📂", title: "New Workspace", subtitle: "Create a new workspace", shortcut: "⌘N") { [weak self] in
                self?.addWorkspace()
            },
            PaletteAction(icon: "🌳", title: "New Worktree", subtitle: "Create a git worktree + workspace", shortcut: "") { [weak self] in
                self?.showWorktreePanel()
            },
            PaletteAction(icon: "🌿", title: "Open Worktree", subtitle: "Open an existing worktree as workspace", shortcut: "") { [weak self] in
                self?.showWorktreeListPalette()
            },
            PaletteAction(icon: "🔍", title: "Pilot Mode", subtitle: "Toggle overview of all workspaces", shortcut: "⌘O") { [weak self] in
                self?.togglePilotMode()
            },
            PaletteAction(icon: "✏", title: "Rename Workspace", subtitle: "Change the name of the current workspace", shortcut: "⌘R") { [weak self] in
                self?.showRenamePanel()
            },
            PaletteAction(
                icon: "⚙",
                title: "Install Worktree Skill",
                subtitle: "Auto-create workspaces when agents create worktrees",
                shortcut: ""
            ) { [weak self] in
                self?.installWorktreeSkill()
            }
        ]

        commandPalette?.show(relativeTo: window)
    }

    func showCommandPalette(prefilter: String) {
        if commandPalette?.isVisible == true {
            commandPalette?.dismiss()
            return
        }
        showCommandPalette()
        if !prefilter.isEmpty {
            commandPalette?.applyPrefilter(prefilter)
        }
    }

    func showCommandPaletteURLMode() {
        showCommandPalette()
        commandPalette?.switchToURLMode()
    }

    // MARK: - Focus + helpers

    func focusActiveTerminal(in window: NSWindow?) {
        guard let col = activeWorkspace?.columns[safe: activeWorkspace?.focusedIndex ?? 0],
              let window else { return }
        if let webView = col.webViewColumn {
            window.makeFirstResponder(webView.webView)
        } else if let terminal = col.terminalView {
            window.makeFirstResponder(terminal)
        }
    }

    func focusColumnByIndex(_ index: Int) {
        guard let workspace = activeWorkspace, workspace.columns.indices.contains(index), workspace.focusedIndex != index else { return }
        workspace.focusedIndex = index
        relayout(animated: true)
        updateSidebar()
        focusActiveTerminal(in: window)
    }

    var activeWorkspace: WorkspaceState? { workspaceStore.activeWorkspace }
    var activeWorkspaceForKeyIntercept: WorkspaceState? { activeWorkspace }

    var isOverlayActive: Bool {
        if commandPalette?.isVisible == true { return true }
        if NSApp.keyWindow is NSPanel { return true }
        return false
    }
}
