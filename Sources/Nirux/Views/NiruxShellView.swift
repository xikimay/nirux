import AppKit
import GhosttyTerminal

/// Root AppKit view: sidebar + niri-style 2D scrolling viewport
final class NiruxShellView: NSView {
    private static let collapsedSidebarWidth: CGFloat = 16
    private static let expandedSidebarWidth: CGFloat = 260
    var isSidebarExpanded = false
    private var sidebarWidth: CGFloat {
        isSidebarExpanded ? Self.expandedSidebarWidth : Self.collapsedSidebarWidth
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
    let projectStore = ProjectStore()
    /// Each space's agent sessions (see AgentSessionLedger).
    var sessionLedger = AgentSessionLedger()
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

    // Heartbeat
    var heartbeatTimer: Timer?
    var heartbeatTick: UInt = 0
    /// Event-driven git/PR refresh scheduling (FSEvents + throttles).
    let gitRefresh = GitRefreshCoordinator()
    /// See scheduleMetadataRefresh(): one process-table scan per window.
    var isMetadataRefreshScheduled = false
    var lastMetadataRefreshAt: TimeInterval = 0

    /// Dwell timer that marks visible Activity entries as read. The
    /// generation invalidates a fired timer whose MainActor task is queued.
    var activityReadTimer: Timer?
    var activityReadGeneration: UInt = 0

    /// Owned by NiruxApp; nil in tests, which never touch power settings.
    weak var keepAwake: KeepAwakeController?

    /// First-launch checklist state; nil for a user set up before it existed
    /// (see OnboardingChecklist.launchState).
    var onboardingState: OnboardingChecklistState?

    /// How long a dialog may wait on the user before its agent reads as
    /// stuck (Settings); nil turns the check off.
    var stuckAgentWaitThreshold: TimeInterval? = NiruxShellView.stuckWaitThreshold(
        minutes: NiruxShellView.currentStuckAgentMinutes()
    )
    /// Keeps stuck-agent alerts going while the heartbeat is stopped.
    var stuckWatchTimer: Timer?
    /// Where stuck-agent alerts are recorded (tests use their own).
    var stuckAgentActivity = ActivityStore.shared
    /// A stuck-agent alert went out (Telegram relays it): the reason, the
    /// workspace, the column's index, the column.
    var onStuckAgentAlert: ((AgentAttentionReason, WorkspaceState, Int, ColumnState) -> Void)?
    /// ⌘P's workspace rows and Next Waiting Agent (⌘J).
    let quickSwitch = QuickSwitchState()

    /// Agent launches, the home folder, cookies and modal alerts; tests
    /// replace them (see ShellSideEffects).
    var sideEffects = ShellSideEffects()

    // Panel references (stored properties must live in main class declaration)
    var nameInputPanel: NameInputPanel?
    var workspaceContextPanel: WorkspaceContextPanel?
    var worktreePanel: WorktreePanel?
    var commandPalette: CommandPalette?
    var urlPanel: URLInputPanel?
    var filePickerPanel: FilePickerPanel?
    var searchPanel: EditorSearchPanel?
    var worktreeCleanupPanel: WorktreeCleanupPanel?
    /// Worktrees a "Clean Up Worktree…" is checking or confirming, so a
    /// second click doesn't start another. Their cards say so.
    var worktreeCleanupsInFlight: Set<String> = [] {
        didSet { if worktreeCleanupsInFlight != oldValue { updateSidebar() } }
    }
    var boardSettingsPanel: BoardSettingsPanel?
    /// A "Board Settings…" reading board.json and the checkouts, so a
    /// second click doesn't open a second form.
    var isReadingBoardSettings = false
    /// The Project Board's `gh` reads. Tests set a fake before a board opens.
    lazy var projectBoardClient: any ProjectBoardGitHub = GitHubCLIBoardClient.installed
    /// Reloads the boards whose board.json was saved.
    var boardConfigSaveObserver: NSObjectProtocol?
    /// The merge queue's `gh` client. Nil: each new queue gets
    /// `MergeQueue.client()`, a dry run unless Nirux is the notarized
    /// release on the real state. Tests set a fake first.
    var mergeQueueClient: (any MergeQueueGitHub)?
    /// Each project's merge queue, by project id (see `mergeQueue(projectID:)`).
    var mergeQueues: [String: MergeQueueController] = [:]
    /// Where live queues lock their repository. Tests use their own.
    var mergeQueueLockFolder = MergeQueueLock.defaultFolder
    /// The merge queue's confirmation sheet: one at a time.
    var mergeQueueConfirmation: MergeQueueConfirmationPanel?
    /// Projects whose ended queue the user dismissed from the status bar.
    var dismissedMergeQueueNotices: Set<String> = []
    /// A quit waiting on the running queues: asked, then waiting for them
    /// to stop (see `mergeQueueTerminateReply`).
    var mergeQueueQuit: MergeQueueQuit?

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
        statusBar.onContentChange = { [weak self] in self?.relayout(animated: false) }

        let workspace = WorkspaceState(
            title: "ws 1",
            cwd: NSHomeDirectory(),
            profileID: activeProfileID,
            missionHandoffsEnabled: Self.currentMissionHandoffsEnabled()
        )
        wireWorkspace(workspace)
        workspaces.append(workspace)
        verticalStrip.addSubview(workspace.containerView)
        sidebar.onWorkspaceClicked = { [weak self] index in self?.switchToWorkspace(index) }
        sidebar.onWorkspaceAction = { [weak self] action, index in self?.handleWorkspaceSidebarAction(action, workspaceIndex: index) }
        sidebar.offersWorktreeCleanup = { [weak self] index in self?.offersWorktreeCleanup(workspaceIndex: index) ?? false }
        sidebar.onWorkspaceReordered = { [weak self] index, position in
            self?.handleWorkspaceReorder(workspaceIndex: index, targetPosition: position)
        }
        sidebar.onProfileClicked = { [weak self] profileID in self?.selectProfile(profileID) }
        sidebar.onCreateProfile = { [weak self] in self?.createProfileFromActiveContext() }
        sidebar.onRenameProfile = { [weak self] profileID in self?.showRenameSpacePanel(profileID: profileID) }
        sidebar.onEditProfileBrief = { [weak self] profileID in self?.editSpaceBrief(profileID: profileID) }
        sidebar.onEditBoardSettings = { [weak self] profileID in self?.showBoardSettings(profileID: profileID) }
        sidebar.onRecolorProfile = { [weak self] profileID, hex in self?.recolorSpace(profileID: profileID, colorHex: hex) }
        sidebar.onDeleteProfile = { [weak self] profileID in self?.confirmDeleteSpace(profileID: profileID) }
        sidebar.onMoveWorkspaceToProfile = { [weak self] workspaceID, profileID in
            self?.moveWorkspaceToSpace(workspaceID: workspaceID, profileID: profileID)
        }
        sidebar.onDiffStatsClicked = { [weak self] index in self?.openDiffInEditor(workspaceIndex: index) }
        sidebar.onOnboardingAction = { [weak self] action in self?.handleOnboardingAction(action) }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSidebarActivityActivation(_:)),
            name: .niruxSidebarActivityEntryActivated,
            object: sidebar
        )
        sidebar.onPermissionDecision = { [weak self] wsIndex, colIndex, requestID, behavior in
            self?.decidePermission(
                workspaceIndex: wsIndex, columnIndex: colIndex, requestID: requestID, behavior: behavior
            )
        }
        sidebar.onAgentResume = { [weak self] wsIndex, colIndex, failedAt in
            self?.resumeFailedAgent(workspaceIndex: wsIndex, columnIndex: colIndex, failedAt: failedAt)
        }
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
                // Git and PR reads are event-driven; the tick only starts
                // the ones that are due (see GitRefreshPolicy).
                self.refreshGitAndPullRequests()
                self.refreshMetadata(snapshot: snapshot)
                // Save state every ~10s (every 5th tick)
                if self.heartbeatTick % 5 == 0 {
                    self.saveState(snapshot: snapshot)
                    // Picks up an agent CLI installed from a terminal, while
                    // the card can be seen (opening the sidebar refreshes too).
                    if self.onboardingState == .pending, self.isSidebarExpanded {
                        self.refreshOnboardingChecklist()
                    }
                }
            }
        }
    }

    func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// Single place that wires a workspace's shell-facing callbacks —
    /// sidebar refresh, terminal link opening. Used by init, addWorkspace
    /// and session restore.
    func wireWorkspace(_ workspace: WorkspaceState) {
        wireMetadataAndGitRefresh(workspace)
        workspace.onTerminalOpenURL = { [weak self] targetWorkspace, url in
            self?.openWebView(url: url, in: targetWorkspace)
        }
        workspace.onTerminalOpenFile = { [weak self] targetWorkspace, path, line in
            self?.openInEditorColumn(path: path, line: line, in: targetWorkspace)
        }
        workspace.onResumeExitedAgent = { [weak self] targetWorkspace, column in
            self?.resumeExitedAgent(in: targetWorkspace, column: column)
        }
        wireLocalServerProposals(for: workspace)
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
        // Status bar: only when it has content (update, crash, merge queue)
        statusBar.isHidden = !statusBar.hasContent
        let statusH = statusBar.isHidden ? CGFloat(0) : StatusBarView.height
        let viewportH = bounds.height - statusH; let viewportW = bounds.width - sidebarW - 1
        guard viewportH > 0, viewportW > 0 else { return }
        NiruxDebugLog.log(
            "relayout bounds=\(bounds.width)x\(bounds.height) "
                + "window=\(window?.frame.width ?? -1)x\(window?.frame.height ?? -1) "
                + "viewport=\(viewportW)x\(viewportH)"
        )

        let glowWidth: CGFloat = 32
        let vpX = sidebarW + 1

        let frames = ChromeFrames(
            sidebar: NSRect(x: 0, y: statusH, width: sidebarW, height: bounds.height - statusH),
            divider: NSRect(x: sidebarW, y: statusH, width: 1, height: bounds.height - statusH),
            viewport: NSRect(x: vpX, y: statusH, width: viewportW, height: viewportH),
            glowLeft: NSRect(x: vpX, y: statusH, width: glowWidth, height: viewportH),
            glowRight: NSRect(x: vpX + viewportW - glowWidth, y: statusH, width: glowWidth, height: viewportH),
            glowTop: NSRect(x: vpX, y: statusH + viewportH - glowWidth, width: viewportW, height: glowWidth),
            glowBottom: NSRect(x: vpX, y: statusH, width: viewportW, height: glowWidth),
            indicator: NSRect(x: vpX, y: 4, width: viewportW, height: 16),
            statusBar: NSRect(x: 0, y: 0, width: bounds.width, height: statusH)
        )
        applyChromeLayout(frames, animated: animated)

        // Each workspace fills the viewport; the strip stacks them and is
        // positioned so the active workspace is the one on screen.
        let totalH = viewportH * CGFloat(visibleWorkspaceIndices.count)
        let activePosition = CGFloat(activeVisibleWorkspacePosition ?? 0)
        layoutWorkspaceStrip(StripLayout(
            viewportW: viewportW, totalH: totalH, rowH: viewportH,
            targetY: (activePosition + 1) * viewportH - totalH, animated: animated
        ))

        syncTerminalOcclusion()
    }

    // MARK: - Terminal Occlusion

    /// Tell each Ghostty terminal whether it's actually on screen. Workspaces
    /// in the vertical strip stay in the view hierarchy even when scrolled
    /// out of view, so the host window's occlusion state isn't enough — every
    /// surface's CVDisplayLink would still hit `waitUntilCompleted` on the
    /// main thread, which freezes the app once a few Claude/Codex sessions
    /// pile up. Only the active workspace is visible.
    private func syncTerminalOcclusion() {
        // A minimized or fully covered window reports itself non-visible via
        // occlusionState; without this AND every surface keeps drawing.
        let windowVisible = window?.occlusionState.contains(.visible) ?? true
        for (index, workspace) in workspaces.enumerated() {
            let isInActiveProfile = workspace.profileID == activeProfileID
            let visible = windowVisible && isInActiveProfile && index == activeWSIndex
            for col in workspace.columns {
                col.terminalView?.setSurfaceVisible(visible)
            }
        }
    }

    // MARK: - Title Bar Labels

    func refreshTitleBarLabels(snapshot: ProcessSnapshot? = nil) {
        guard let workspace = activeWorkspace else { return }
        let snap = snapshot ?? ProcessSnapshot()
        for col in workspace.columns {
            col.updateTitleBarLabel(snapshot: snap)
            col.refreshAgentUsage(snapshot: snap)
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
            NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.syncTerminalOcclusion()
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clearAllAgentAttention()
                self.resumeGitRefresh()
                self.stopStuckWatch()
                self.startHeartbeat()
                self.forEachEditorColumn { $0.resumeFileWatch() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.gitRefresh.isSuspended = true
                // Nobody sees the buttons now: a background subagent's
                // dialog must not wait on them (the heartbeat stops too).
                if AgentHookCenter.shared.approvalsEnabled { self.updateSidebar() }
                self.stopHeartbeat()
                self.startStuckWatch()
                self.forEachEditorColumn { $0.pauseFileWatch() }
            }
        }
    }
}

extension NiruxShellView {

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
            animated: true
        )

        updateSidebar()
        focusActiveTerminal(in: window)
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

    // MARK: - Workspace naming

    func showNewWorkspacePanel() {
        guard let window else { return }
        if nameInputPanel == nil {
            nameInputPanel = NameInputPanel()
        }
        nameInputPanel?.onSubmit = { [weak self] title in
            self?.addWorkspace(title: title)
            self?.saveState()
        }
        nameInputPanel?.show(
            relativeTo: window,
            currentValue: "",
            placeholder: "Name this workspace for the task"
        )
    }

    func showWorkspaceContextPanel(workspaceIndex: Int) {
        guard let window, let workspace = workspaces[safe: workspaceIndex] else { return }
        if workspaceContextPanel == nil {
            workspaceContextPanel = WorkspaceContextPanel()
        }

        let presentedSummary = WorkspaceState.normalizedContextText(workspace.lastSummary)
        workspaceContextPanel?.onSave = { [weak self, weak workspace] values in
            guard let self, let workspace,
                  self.workspaces.contains(where: { $0 === workspace }) else { return }
            workspace.purpose = WorkspaceState.normalizedContextText(values.purpose)
            workspace.phase = values.phase
            if values.phase != nil {
                workspace.unknownPhaseRawValue = nil
            }
            workspace.nextStep = WorkspaceState.normalizedContextText(values.nextStep)
            workspace.blocker = WorkspaceState.normalizedContextText(values.blocker)

            let savedSummary = WorkspaceState.normalizedContextText(values.lastSummary)
            if savedSummary != presentedSummary {
                workspace.lastSummary = savedSummary
                workspace.lastSummaryIsManual = savedSummary != nil
            }
            self.updateSidebar()
            self.saveState()
        }

        let configuration = WorkspaceContextPanelConfiguration(
            title: workspace.title,
            cwd: workspace.focusedWorkingDirectory,
            purpose: workspace.purpose,
            phaseOverride: workspace.phase,
            effectivePhase: workspace.effectivePhase,
            lastSummary: workspace.lastSummary,
            lastSummaryIsManual: workspace.lastSummaryIsManual,
            lastActivityAt: workspace.lastActivityAt,
            nextStep: workspace.nextStep,
            blocker: workspace.blocker,
            gitBranch: workspace.gitBranch,
            diffStats: workspace.diffStats,
            prInfo: workspace.prInfo,
            agentStatuses: workspace.columns.map { $0.pty?.cachedAgentState ?? .idle }
        )
        workspaceContextPanel?.show(relativeTo: window, configuration: configuration)
    }

    /// Rename a workspace by index; defaults to the active one (main menu,
    /// command palette). The sidebar context menu passes an explicit index.
    func showRenamePanel(workspaceIndex: Int? = nil) {
        guard let window, let workspace = workspaces[safe: workspaceIndex ?? activeWSIndex] else { return }
        if nameInputPanel == nil {
            nameInputPanel = NameInputPanel()
        }
        nameInputPanel?.onSubmit = { [weak self, weak workspace] newTitle in
            guard let self, let workspace else { return }
            workspace.title = newTitle
            workspace.titleIsManual = true
            self.updateSidebar()
            self.saveState()
        }
        nameInputPanel?.show(relativeTo: window, currentValue: workspace.title, placeholder: "Workspace name")
    }

    func showRenameSpacePanel(profileID: String) {
        guard let window,
              let profile = profiles.first(where: { $0.id == profileID })
        else { return }
        if nameInputPanel == nil {
            nameInputPanel = NameInputPanel()
        }
        nameInputPanel?.onSubmit = { [weak self] newName in
            guard let self else { return }
            guard self.workspaceStore.renameProfile(id: profileID, to: newName) else { return }
            self.updateSidebar()
            self.saveState()
        }
        nameInputPanel?.show(relativeTo: window, currentValue: profile.name, placeholder: "Space name")
    }

    // MARK: - Worktree

    func showWorktreePanel() {
        guard let window else { return }
        guard let cwd = activeWorkspace?.focusedWorkingDirectory,
              let repoRoot = GitWorktree.repoRoot(at: cwd)
        else { return }

        if worktreePanel == nil {
            worktreePanel = WorktreePanel()
            worktreePanel?.onCreated = { [weak self] branch, path, repoRoot, checkedOutBranch in
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
                    // Pre-created (O_EXCL, unguessable name) so the agent writes
                    // into a file the user owns, never through a planted symlink.
                    guard let handoverPath = HandoverFile.makeEmptySource(agent: runningAgent.rawValue) else {
                        self.presentProblem("Couldn’t create a handover file in /tmp", "The worktree opens without one.")
                        self.addWorkspace(
                            title: branch, cwd: path, agent: runningAgent, worktreeBranch: checkedOutBranch
                        )
                        return
                    }
                    let isMission = Self.currentMissionHandoffsEnabled()
                    let request = NiruxURLRequest.NewWorktree(
                        branch: branch, repo: repoRoot, agent: runningAgent, handoverPath: handoverPath,
                        parentWorkspaceID: isMission ? self.activeWorkspace?.id : nil,
                        parentAgentUUID: isMission ? col?.agentUUID : nil
                    )
                    var expected = request
                    expected.repo = repoRoot.realPath ?? repoRoot
                    InAppWorktreeTickets.issue(
                        for: expected, profileID: self.activeProfileID, now: ProcessInfo.processInfo.systemUptime
                    )
                    let url = Self.inAppWorktreeURL(for: request, profileID: self.activeProfileID)
                    let prompt = "Write a concise session handover into \(handoverPath) "
                        + "(sections: Goal, Context, Done so far, Next steps; Nirux created the file empty). "
                        + "Nirux will move it into the new worktree as \(Self.handoverFilename(for: runningAgent)). "
                        + "Then run: open \"\(url)\"\n"
                    col?.pty?.sendRaw(prompt)
                } else {
                    // No agent — open workspace directly (worktree already created by panel)
                    self.addWorkspace(title: branch, cwd: path, agent: .claude, worktreeBranch: checkedOutBranch)
                }
            }
        }
        worktreePanel?.show(relativeTo: window, repoRoot: repoRoot)
    }

    func showWorktreeListPalette() {
        guard let window else { return }
        guard let cwd = activeWorkspace?.focusedWorkingDirectory,
              let repoRoot = GitWorktree.repoRoot(at: cwd)
        else { return }
        // Not the active one: its folder is where it was opened, not where
        // its terminal is now, and going back to it would do nothing.
        let openWorkspaces = workspaces.filter { !$0.isClosing && $0 !== activeWorkspace }.map { (id: $0.id, cwd: $0.cwd) }

        // List worktrees on background thread, then show palette
        DispatchQueue.global(qos: .userInitiated).async {
            let worktrees = GitWorktree.list(repoRoot: repoRoot)
            let current = Self.comparablePath(repoRoot)
            let comparablePaths = worktrees.map { Self.comparablePath($0.path) }
            // The worktree each workspace is open in (the main checkout may
            // hold the others), and whether at its root.
            let workspaceWorktrees = openWorkspaces.compactMap { workspace in
                let cwd = Self.comparablePath(workspace.cwd)
                return ProjectBoard.innermost(of: comparablePaths, holding: cwd).map {
                    (id: workspace.id, path: comparablePaths[$0], isAtRoot: cwd == comparablePaths[$0])
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Leave out the checkout the palette was opened from
                let entries = zip(worktrees, comparablePaths).filter { _, path in path != current }
                guard !entries.isEmpty else { return }

                // Build palette actions from worktree entries
                let actions = entries.map { entry, comparablePath in
                    let title = entry.branch ?? URL(fileURLWithPath: entry.path).lastPathComponent
                    let open = self.preferredWorkspace(among: workspaceWorktrees.filter { $0.path == comparablePath })
                    let subtitle = (open.map { self.alreadyOpenNote(for: $0) + " · " } ?? "") + entry.path.abbreviatedPath()
                    let openID = open?.id
                    return PaletteAction(icon: "🌿", title: title, subtitle: subtitle, shortcut: nil) { [weak self] in
                        self?.openWorktree(path: entry.path, title: title, workspaceID: openID)
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

    /// "Open Worktree" goes back to a workspace already open in the
    /// worktree instead of opening another: one in the active space first,
    /// then a live one before a parked one, then one at the worktree's root
    /// before one in a subfolder; sidebar order last.
    private func preferredWorkspace(among matches: [(id: String, path: String, isAtRoot: Bool)]) -> WorkspaceState? {
        let ranked = matches.compactMap { match -> (workspace: WorkspaceState, rank: [Int])? in
            guard let workspace = workspaces.first(where: { $0.id == match.id && !$0.isClosing }) else { return nil }
            let rank = [workspace.profileID == activeProfileID, !workspace.isInactive, match.isAtRoot]
            return (workspace, rank.map { $0 ? 1 : 0 })
        }
        return ranked.max { $0.rank.lexicographicallyPrecedes($1.rank) }?.workspace
    }

    /// Before the path, in the palette row; the row's title is the branch,
    /// usually the workspace's name too.
    private func alreadyOpenNote(for workspace: WorkspaceState) -> String {
        guard workspace.profileID != activeProfileID,
              let space = profiles.first(where: { $0.id == workspace.profileID })
        else { return "Already open" }
        return "Already open in “\(space.name)”"
    }

    private func openWorktree(path: String, title: String, workspaceID: String?) {
        if let workspaceID, workspaces.contains(where: { $0.id == workspaceID && !$0.isClosing }) {
            focusWorkspace(id: workspaceID)
        } else {
            addWorkspace(title: title, cwd: path)
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

        commandPalette?.actions = columnPaletteActions() + agentPaletteActions() + workspacePaletteActions()
        commandPalette?.show(relativeTo: window, sections: paletteSections())
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
        } else if let board = col.projectBoard {
            window.makeFirstResponder(board.view)
        } else if col.isFindBarOpen {
            // An open find bar keeps the keyboard: text typed for it must
            // not reach the agent. A click on the terminal takes it back.
            if !col.isEditingFind { col.findBar?.focusField() }
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
