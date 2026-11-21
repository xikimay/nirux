import AppKit
import GhosttyTerminal

/// Root AppKit view: sidebar + niri-style 2D scrolling viewport
final class NiruxShellView: NSView {
    private static let collapsedSidebarWidth = SidebarView.foldedWidth
    private static let expandedSidebarWidth: CGFloat = 260
    /// The requests waiting for the user, the inbox and the callout (see
    /// NiruxShellView+Requests).
    let requestsState = RequestsState()
    /// The user's choice and the window's width (see `SidebarFold`).
    var sidebarFold = SidebarFold()
    /// Whether the sidebar is unfolded; set, the user's choice.
    var isSidebarExpanded: Bool {
        get { sidebarFold.isExpanded }
        set { sidebarFold.choose(newValue) }
    }
    /// Counts sidebar toggles: an expansion's delayed step checks that no
    /// toggle came after it.
    var sidebarToggleGeneration = 0
    /// Counts passes under the rail: a pass's end acts only on its own (see
    /// NiruxShellView+UnderGlass).
    var underGlassGeneration = 0
    /// The workspace whose cards pass under the rail, until its edge closes.
    weak var passingUnderRail: WorkspaceState?
    /// Counts space crossings: a crossing's end acts only on its own, and
    /// its pictures over the viewport (NiruxShellView+SpaceCrossing).
    var spaceCrossingGeneration = 0
    var crossingPictures: [FrozenView] = []
    /// The workspace a crossing brings on screen.
    var crossingWorkspaceID: String?
    /// The space as a plan, while it shows (NiruxShellView+SpacePlan); the
    /// workspaces drawing once before it shows; a count so that a step or a
    /// motion's end acts only on its own.
    var spacePlan: SpacePlanView?
    var planDrawing: Set<String> = []
    var spacePlanGeneration = 0
    /// The pinch on the work under way (NiruxShellView+SpacePlan).
    var pinch = PinchGesture()
    /// The size of the workspace on screen, as `relayout` lays it out.
    var workspaceViewportSize: NSSize {
        let statusH = statusBar.hasContent ? StatusBarView.height : 0
        return NSSize(width: bounds.width - sidebarWidth - 1, height: bounds.height - statusH)
    }
    /// The viewport size hidden terminals were last given (see
    /// `resizeTerminalsOffScreen`).
    var offScreenViewportSize = NSSize.zero

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
    /// What the columns' lights and the edge glows show (see
    /// NiruxShellView+AgentLights).
    let agentLights = AgentLightState()
    let sidebarStaleLog = SidebarStaleLogState()
    let workspaceSwitch = WorkspaceSwitchState()
    let workspaceNameCard = WorkspaceNameCard()
    /// Settings › Appearance › "Animate the interface": off, states show
    /// without moving.
    var animatesInterface: Bool {
        didSet { if animatesInterface != oldValue { applyAgentLights() } }
    }
    /// Settings › Appearance: how much of the desktop shows through the
    /// chrome (NiruxShellView+Appearance).
    var interfaceTransparency: InterfaceTransparency {
        didSet { if interfaceTransparency != oldValue { applyInterfaceTransparency() } }
    }
    /// Settings › Appearance › Terminals: the terminals' background opacity,
    /// apart from the interface's level (`TerminalOpacity`).
    var terminalOpacity: Double {
        didSet { if terminalOpacity != oldValue { applyTerminalOpacity() } }
    }

    let workspaceStore = WorkspaceStore()
    let projectStore = ProjectStore()
    /// Each space's agent sessions (see AgentSessionLedger).
    var sessionLedger = AgentSessionLedger()
    /// Resumes under way, and columns just launched to resume a session.
    let sessionResume = SessionResumeState()
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
    lazy var pinnedThreadReader: TaskThreadContentView.Read = { [weak self] id, space, done in
        guard let self else { return done(nil) }
        readThreadTimeline(workspaceID: id, spaceID: space, completion: done)
    }

    var heartbeatTimer: Timer?
    var heartbeatTick: UInt = 0
    /// Event-driven git/PR refresh scheduling (FSEvents + throttles).
    let gitRefresh = GitRefreshCoordinator()
    /// See scheduleMetadataRefresh(): one process-table scan per window.
    var isMetadataRefreshScheduled = false
    /// Restored agents on screen resume after a wait (see
    /// NiruxShellView+LazyRestore.swift).
    var isOnScreenResumeScheduled = false
    var lastMetadataRefreshAt: TimeInterval = 0

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
    /// Reads of Claude's transcript, half a second apart, before an Esc
    /// Nirux sent reads as ignored: a tool can be slow to stop (see
    /// `followInterrupt`).
    var interruptReads = 60
    /// A working agent that may be going in circles says so on its row
    /// (Settings; see `AgentCirclingHint`). Read with the restored state.
    var circlingHintEnabled = PersistedSettings().agentCirclingHint
    /// Rows show their task's status line (Settings → Notifications).
    var turnStatusEnabled = PersistedSettings().showTurnStatus
    /// The card of what happened while the user was away (Settings →
    /// Notifications; see `SidebarCatchUp`).
    var catchUpEnabled = PersistedSettings().showCatchUp
    /// The order of the Board's lines (its switch; saved in the settings).
    var boardOrder = PersistedSettings().boardOrder
    var catchUpState = CatchUpState(tracker: AwayTracker(now: Date().timeIntervalSince1970))
    let catchUpObservers = ObserverBag()
    /// Mission questions handed to the user (the child's card turned
    /// amber), by question ID: the child workspace whose notification they
    /// raised, once.
    var missionQuestionsHandedToUser: [String: String] = [:]
    /// What Nirux saw of each waiting question's parent, by question ID
    /// (see `missionParentGrace`).
    var missionParentWatch: [String: MissionParentWatch] = [:]
    /// The reply popover, and the question it shows.
    var missionReplyPopover: NSPopover?
    var missionReplyQuestionID: String?
    /// The Reply… popover of a turn's question, and that question
    /// (`showTurnReplyPopover`, `closeStaleTurnReply`).
    var turnReplyPopover: NSPopover?
    var turnReplyQuestion: SidebarTurnQuestion?
    /// Lines for a Lead's prompt (the user answered a question it handed
    /// over), typed once that prompt is free (`typeMissionMessages`).
    var pendingLeadNotices: [LeadNotice] = []
    /// Mission messages that wait too long for a prompt (`waitingMissionMessages`).
    var missionWaits = MissionWaitState()
    /// A Lead's tasks waiting to be proposed in the New sheet, one sheet at
    /// a time, and the timer that shows the next once no sheet is up.
    var pendingLeadProposals: [LeadProposal] = []
    var leadProposalTimer: Timer?
    /// Sub-tasks a task's `start_task` is starting (fetching, making the
    /// worktree), by the task's id: they count against its limit before
    /// their workspace exists, so calls made at once can't pass it.
    var pendingSubtaskStarts: [String: Int] = [:]
    /// The list each repository's queue last got from a Lead
    /// (`queue_merge`), by `<space id> <owner/name>`: a Lead may replace its
    /// own, never the user's.
    var leadQueueProposals: [String: [Int]] = [:]
    /// The rules each space's Lead proposed, by space id, read from
    /// RuleProposalStore once and kept current by the app's own changes
    /// (the sidebar asks several times a second).
    var ruleProposals: [String: RuleProposalStore.Loaded] = [:]
    /// Each space's daily pass, by space id, read once and kept by the
    /// app's own changes, for the Lead row's note.
    var dailyPassStates: [String: DailyPassState] = [:]
    /// The spaces whose due pass is being read (GitHub), so a minute's
    /// check doesn't start another.
    var dailyPassChecks: Set<String> = []
    /// The spaces whose due pass waits, after GitHub didn't answer or a
    /// pass couldn't be recorded, until then.
    var dailyPassRetryAt: [String: TimeInterval] = [:]
    /// Reads GitHub may answer next time, in a row, by space.
    var dailyPassRereads: [String: DailyPass.Rereads] = [:]
    /// When the Mac last woke: the user's absence counts from there.
    var dailyPassWokeAt: TimeInterval = 0
    var dailyPassTimer: Timer?
    var dailyPassWakeObservers: [NSObjectProtocol] = []
    /// The sheet that adds a rule to a space's brief (LearnedRuleSheet).
    var learnedRuleSheet: LearnedRuleSheet?
    /// ⌘P's workspace rows and Next Waiting Agent (⌘J).
    let quickSwitch = QuickSwitchState()

    /// Agent launches, the home folder, cookies and modal alerts; tests
    /// replace them (see ShellSideEffects).
    var sideEffects = ShellSideEffects()
    /// The CI failure triage's state (docs/design/ci-failure-triage.md).
    let ciTriageCenter = CITriageCenter()
    let prFollowUpCenter = PRFollowUpCenter()

    // Panel references (stored properties must live in main class declaration)
    var nameInputPanel: NameInputPanel?
    var workspaceContextPanel: WorkspaceContextPanel?
    var commandPalette: CommandPalette?
    /// The window's toolbar holding the command bar (step 3.1 of the glass
    /// interface), once `installCommandBar` gave the window one.
    var commandBarToolbar: CommandBarToolbar?
    /// A cookie import is under way, from reading the profiles to its
    /// result: one at a time (see importBrowserCookies).
    var isImportingCookies = false
    /// Its profiles are being read; the import that started the read.
    var isReadingCookieProfiles = false
    var cookieImportGeneration = 0
    var filePickerPanel: FilePickerPanel?
    var searchPanel: EditorSearchPanel?
    var globalSearchPanel: GlobalSearchPanel?
    var sessionHistoryPanel: SessionHistoryPanel?
    var projectMemoryPanel: ProjectMemoryPanel?
    /// Counts "Space Memory…" requests: only the latest one's read shows.
    var projectMemoryRequest = 0
    var worktreeCleanupPanel: WorktreeCleanupPanel?
    /// Worktrees a "Clean Up Worktree…" is checking or confirming, so a
    /// second click doesn't start another. Their cards say so.
    var worktreeCleanupsInFlight: Set<String> = [] {
        didSet { if worktreeCleanupsInFlight != oldValue { updateSidebar() } }
    }
    /// The toast on screen (see NiruxShellView+Toast), and a count that
    /// tells a pending dismissal whether it still applies.
    var toast: ToastView?
    var toastGeneration = 0
    var toastShownAt: TimeInterval = 0
    /// The Board tab's form (see NiruxShellView+BoardSettings).
    var boardSettingsPanel: BoardSettingsPanel?
    /// Each task's station by workspace id: its line's on its space's Board
    /// (`noteTaskStations`), drawn or not. No Board, none.
    var taskStations: [String: BoardStages.Station] = [:]
    /// The Board tab reading board.json and the checkouts: one read at a
    /// time.
    var isReadingBoardSettings = false
    /// Space Settings, for one space at a time (see
    /// NiruxShellView+SpaceSettings), its setup script sheet, and the
    /// GitHub repositories read for its rows, by anchor key.
    var spaceSettings: SpaceSettingsSection?
    /// Nirux's one Settings window (docs/design/glass-interface.md, 4.1): the
    /// app's panes come from NiruxApp, the space's from here.
    lazy var settingsWindow: SettingsWindow = makeSettingsWindow()
    var setupScriptSheet: (panel: NSPanel, editor: SpaceFileEditorPane)?
    var spaceSettingsGitHub: [String: String] = [:]
    var newTaskPanel: NewTaskPanel?
    /// ⌘N sheets closed while their task starts, set aside for a new one:
    /// each comes back if its start fails.
    var startingTaskPanels: [NewTaskPanel] = []
    /// The picture of the ⌘N sheet whose task is opening, until its fold
    /// plays (see NiruxShellView+TaskBirth).
    var pendingTaskSheet: TaskSheetPicture?
    var newSpacePanel: NewSpacePanel?
    /// The banner of a workspace that opened in the default space (see
    /// NiruxShellView+SpaceRouting), and a count that tells a pending
    /// dismissal whether it still applies.
    var spaceArrivalBanner: SpaceArrivalBanner?
    var spaceArrivalGeneration = 0
    var spaceArrivalShownAt: TimeInterval = 0
    /// Over the viewport while the active space has no workspace (see
    /// NiruxShellView+EmptySpace).
    let emptySpaceView = EmptySpaceView()
    /// The Project Board's `gh` reads. Tests set a fake before a board opens.
    lazy var projectBoardClient: any ProjectBoardGitHub = GitHubCLIBoardClient.installed
    /// The worktree clean-ups' git, gh and Trash, looked up at each use (gh
    /// may be installed meanwhile). Tests set a stub gh and a Trash of their
    /// own.
    var worktreeCleanupTools: () -> WorktreeCleanup.Tools = { .installed }
    /// How Branch Review columns read their worktree: git and gh, or a
    /// test's fixture.
    lazy var branchReviewReader: BranchReviewController.Reader = BranchReviewController.readWorktree
    /// The review files Branch Review columns open: tests give theirs.
    lazy var branchReviewOpener: BranchReviewController.ReviewOpener = BranchReviewController.openReviewFile
    /// Reloads the boards whose board.json was saved.
    var boardConfigSaveObserver: NSObjectProtocol?
    /// The merge queue's `gh` client. Nil: each new queue gets
    /// `MergeQueue.client()`, a dry run unless Nirux is the notarized
    /// release on the real state. Tests set a fake first.
    var mergeQueueClient: (any MergeQueueGitHub)?
    /// Each project's merge queues, one per repository (see
    /// `mergeQueue(projectID:repository:)`).
    var mergeQueues: [MergeQueueKey: MergeQueueController] = [:]
    /// Where live queues lock their repository. Tests use their own.
    var mergeQueueLockFolder = MergeQueueLock.defaultFolder
    /// The merge queue's confirmation sheet: one at a time.
    var mergeQueueConfirmation: MergeQueueConfirmationPanel?
    /// "Send N Comments to Agent", while it shows.
    var reviewSendPanel: ReviewSendPanel?
    /// Queues whose end the user dismissed from the status bar.
    var dismissedMergeQueueNotices: Set<MergeQueueKey> = []
    /// A quit waiting on the running queues: asked, then waiting for them
    /// to stop (see `mergeQueueTerminateReply`).
    var mergeQueueQuit: MergeQueueQuit?

    /// Debounce timer used to nudge TUI agents (claude, codex, vim…) to
    /// redraw after the window stops resizing. Without this, agents that
    /// painted before the resize end up with broken text because their
    /// internal grid still matches the old size.
    private var resizeRedrawTimer: Timer?
    /// Displays woke or changed since terminals were last told theirs
    /// (see `sendDisplayToTerminals`).
    var needsDisplayResync = false
    /// The app-wide display observers are added once, whatever the windows.
    private var observesDisplays = false

    override init(frame: NSRect) {
        // How Nirux looks, from one read of the settings.
        let settings = Persistence.load()?.settings
        animatesInterface = settings?.animatesInterface ?? true
        interfaceTransparency = settings?.interfaceTransparency ?? .defaultValue
        terminalOpacity = settings?.terminalOpacity ?? 1
        super.init(frame: frame)
        // A Board shows its workspace's space, every way a workspace changes space.
        workspaceStore.onWorkspacesChangedSpace = { [weak self] change in self?.boardsFollowTheirWorkspaces(change) }
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.canvas.cgColor
        divider.boxType = .separator
        viewport.wantsLayer = true
        viewport.clipsToBounds = true
        verticalStrip.wantsLayer = true
        viewport.addSubview(verticalStrip)
        viewport.addSubview(emptySpaceView)
        sidebar.show(level: interfaceTransparency, resolveLevel: sideEffects.drawnTransparency)
        addSubview(divider)
        addSubview(viewport)
        // Over the work: the cards pass under the rail (NiruxShellView+UnderGlass).
        addSubview(sidebar)
        sidebar.onRailShownChange = { [weak self] in self?.railMayHaveChanged(animated: true) }
        addSubview(columnIndicator)
        addSubview(edgeGlowLeft)
        addSubview(edgeGlowRight)
        addSubview(edgeGlowTop)
        addSubview(edgeGlowBottom)
        addSubview(workspaceNameCard)
        addSubview(statusBar)
        statusBar.onContentChange = { [weak self] in self?.relayout(animated: false) }

        let workspace = WorkspaceState(
            title: NewTask.folderTitle(NSHomeDirectory(), home: NSHomeDirectory()),
            cwd: NSHomeDirectory(),
            profileID: activeProfileID,
            missionHandoffsEnabled: Self.currentMissionHandoffsEnabled()
        )
        wireWorkspace(workspace)
        workspaces.append(workspace)
        verticalStrip.addSubview(workspace.containerView)
        sidebar.onOpenTaskThread = { [weak self] id, card in
            guard let self else { return }
            let space = activeProfileID
            sidebar.taskPreview.pin(workspaceID: id, card: card) { [weak self, weak card] questionID, text in
                guard let self, let card, sidebar.taskPreview.card === card,
                      sidebar.taskPreview.workspaceID == id, activeProfileID == space,
                      workspaces.contains(where: { $0.id == id && $0.profileID == space && !$0.isClosing })
                else { return .noLongerOpen }
                return replyToThreadQuestion(questionID, in: id, text: text)
            }
            refreshPinnedTaskThread()
        }
        sidebar.onWorkspaceClicked = { [weak self] index in self?.switchToWorkspace(index) }
        sidebar.onWorkspaceAction = { [weak self] action, index in self?.handleWorkspaceSidebarAction(action, workspaceIndex: index) }
        sidebar.worktreeCleanupOffer = { [weak self] index in self?.worktreeCleanupOffer(workspaceIndex: index) }
        sidebar.workspaceIndexForID = { [weak self] id in self?.workspaces.firstIndex { $0.id == id && !$0.isClosing } }
        sidebar.workspaceIDForIndex = { [weak self] index in self?.workspaces[safe: index].flatMap { $0.isClosing ? nil : $0.id } }
        sidebar.columnIndexForID = { [weak self] workspaceID, columnID in
            self?.workspaces.first { $0.id == workspaceID && !$0.isClosing }?.columns.firstIndex { $0.id == columnID && !$0.isClosing }
        }
        sidebar.offersSubtask = { [weak self] index in
            guard let self, let workspace = self.workspaces[safe: index], !workspace.isClosing else { return false }
            return self.offersSubtask(workspace)
        }
        sidebar.onWorkspaceReordered = { [weak self] index, position in
            self?.handleWorkspaceReorder(workspaceIndex: index, targetPosition: position)
        }
        sidebar.onProfileClicked = { [weak self] profileID in self?.selectProfile(profileID) }
        sidebar.onCreateProfile = { [weak self] in self?.showNewSpacePanel() }
        sidebar.onShowSpaceSettings = { [weak self] profileID in self?.showSpaceSettings(profileID: profileID) }
        sidebar.onNewWorkspace = { [weak self] in self?.showNewPanel() }
        sidebar.onShowArchived = { [weak self] in self?.showArchivedTasks() }
        sidebar.onOpenBoard = { [weak self] in self?.openProjectBoard() }
        sidebar.onShowHistory = { [weak self] in self?.showSessionHistory() }
        sidebar.onRailRequest = { [weak self] taskID, icon in self?.openCallout(taskID: taskID, anchor: icon) ?? false }
        sidebar.onDeleteProfile = { [weak self] profileID in self?.confirmDeleteSpace(profileID: profileID) }
        sidebar.onMoveWorkspaceToProfile = { [weak self] workspaceID, profileID in
            self?.moveWorkspaceToSpace(workspaceID: workspaceID, profileID: profileID)
        }
        sidebar.onDiffStatsClicked = { [weak self] index in self?.openDiffInEditor(workspaceIndex: index) }
        sidebar.prFeedbackMenu = { [weak self] workspaceID in self?.prFeedbackMenu(workspaceID: workspaceID) }
        sidebar.onWorkspaceURLClicked = { [weak self] index, url in
            guard let self else { return }
            if self.activeWSIndex != index { self.switchToWorkspace(index) }
            self.openWebView(url: url, in: self.workspaces[index])
        }
        sidebar.onOnboardingAction = { [weak self] action in self?.handleOnboardingAction(action) }
        wireEmptySpaceView()
        sidebar.onMissionQuestionClicked = { [weak self] wsIndex, colIndex, anchor in
            self?.showMissionReplyPopover(workspaceIndex: wsIndex, columnIndex: colIndex, anchor: anchor)
        }
        sidebar.onRuleProposalsClicked = { [weak self] spaceID in self?.showRuleProposal(spaceID: spaceID) }
        sidebar.onPermissionDecision = { [weak self] wsIndex, colIndex, requestID, behavior in
            self?.noteCatchUpTaskAnswered(workspaceIndex: wsIndex)
            self?.decidePermission(
                workspaceIndex: wsIndex, columnIndex: colIndex, requestID: requestID, behavior: behavior
            )
        }
        sidebar.onAgentResume = { [weak self] wsIndex, colIndex, failedAt in
            self?.noteCatchUpTaskAnswered(workspaceIndex: wsIndex)
            self?.resumeFailedAgent(workspaceIndex: wsIndex, columnIndex: colIndex, failedAt: failedAt)
        }
        sidebar.onAgentInterrupt = { [weak self] wsIndex, colIndex, since in
            self?.noteCatchUpTaskAnswered(workspaceIndex: wsIndex)
            self?.interruptSilentAgent(workspaceIndex: wsIndex, columnIndex: colIndex, since: since)
        }
        sidebar.onMissionTypeNow = { [weak self] wsIndex, colIndex, since in
            self?.typeWaitingMessagesNow(workspaceIndex: wsIndex, columnIndex: colIndex, since: since)
        }
        sidebar.onTurnAnswer = { [weak self] question, answer, button in
            self?.answerFromCard(answer, to: question, button: button)
        }
        sidebar.onMissionAnswer = { [weak self] click, button in
            guard let self else { return }
            if click.accepts {
                _ = self.acceptMissionRecommendation(click.questionID)
            } else {
                self.showMissionReplyPopover(
                    workspaceIndex: click.workspaceIndex, columnIndex: click.columnIndex, anchor: button, questionID: click.questionID
                )
            }
        }
        sidebar.onQuestionDismissed = { [weak self] columnID, askedAt in
            self?.dismissTurnQuestion(columnID: columnID, askedAt: askedAt)
        }
        wireDeferredAgentResume()
        wireAgentLights()
        wireAppearance()
        wireSidebarStaleLog()
        sidebar.onCatchUpAction = { [weak self] action in self?.handleCatchUpAction(action) }
        sidebar.onColumnClicked = { [weak self] wsIndex, colIndex in
            guard let self else { return }
            if self.activeWSIndex != wsIndex { self.switchToWorkspace(wsIndex) }
            guard self.activeWSIndex == wsIndex else { return }
            self.goToColumn(colIndex)
        }
        updateSidebar()
        relayoutForNewSize()

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
                self.checkMissionWaits(snapshot: snapshot, now: Date().timeIntervalSince1970)
                self.refreshMetadata(snapshot: snapshot)
                self.refreshPinnedTaskThread()
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
        workspace.onTerminalStarting = { [weak self] targetWorkspace, column in
            guard !column.hasSurface else { return }
            self?.sizeTerminalOffScreen(column, in: targetWorkspace)
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
        endSpaceCrossingIfStale(animated: animated)
        // A pass under the rail goes on through a layout; a travel the
        // layout starts begins another.
        restUnderGlass()
        let sidebarW = sidebarWidth
        // Status bar: only when it has content (update, crash, merge queue)
        statusBar.isHidden = !statusBar.hasContent
        let statusH = statusBar.isHidden ? CGFloat(0) : StatusBarView.height
        let viewportH = bounds.height - statusH; let viewportW = bounds.width - sidebarW - 1
        guard viewportH > 0, viewportW > 0 else { return endUnderGlass() }
        NiruxDebugLog.log(
            "relayout bounds=\(bounds.width)x\(bounds.height) "
                + "window=\(window?.frame.width ?? -1)x\(window?.frame.height ?? -1) "
                + "viewport=\(viewportW)x\(viewportH)"
        )

        // Each edge's view is as deep as its glow.
        let edgeDepth = min(viewportW, viewportH, EdgeGlowView.depth)
        let vpX = sidebarW + 1

        let frames = ChromeFrames(
            sidebar: NSRect(x: 0, y: statusH, width: sidebarW, height: bounds.height - statusH),
            divider: NSRect(x: sidebarW, y: statusH, width: 1, height: bounds.height - statusH),
            viewport: NSRect(x: vpX, y: statusH, width: viewportW, height: viewportH),
            glowLeft: NSRect(x: vpX, y: statusH, width: edgeDepth, height: viewportH),
            glowRight: NSRect(x: vpX + viewportW - edgeDepth, y: statusH, width: edgeDepth, height: viewportH),
            glowTop: NSRect(x: vpX, y: statusH + viewportH - edgeDepth, width: viewportW, height: edgeDepth),
            glowBottom: NSRect(x: vpX, y: statusH, width: viewportW, height: edgeDepth),
            indicator: NSRect(x: vpX, y: 4, width: viewportW, height: 16),
            statusBar: NSRect(x: 0, y: 0, width: bounds.width, height: statusH)
        )
        closeSpacePlanIfStale(viewport: frames.viewport.size)
        // A fold moves the camera too, which is no travel of the columns.
        let sidebarStays = sidebar.frame.width == sidebarW
        applyChromeLayout(frames, animated: animated)
        railMayHaveChanged(animated: animated)
        layoutToast(frames)
        layOutWorkspaceCard(in: frames.viewport)

        // Each workspace fills the viewport; the strip stacks them and is
        // positioned so the active workspace is the one on screen.
        let totalH = viewportH * CGFloat(visibleWorkspaceIndices.count)
        let activePosition = CGFloat(activeVisibleWorkspacePosition ?? 0)
        let shown = workspaceOnScreenBeforeLayout()
        let camera = activeWorkspace?.lastCameraX
        layoutWorkspaceStrip(StripLayout(
            viewportW: viewportW, totalH: totalH, rowH: viewportH,
            targetY: (activePosition + 1) * viewportH - totalH, animated: animated
        ))

        refreshEmptySpaceView()
        syncTerminalOcclusion()
        // The columns in view changed, or the focused one.
        applyAgentLights()
        scheduleDeferredAgentsOnScreen()
        scheduleBranchReviewsOnScreen()
        refreshStaleBranchReviewsOnScreen()
        // A column opened since takes the terminals' opacity.
        applyTerminalOpacity()
        if !sidebarStays {
            endUnderGlass()
        } else if animated, let workspace = activeWorkspace, workspace === shown, workspace.lastCameraX != camera {
            passUnderRail(workspace, for: WorkspaceState.slideDuration)
        } else {
            keepUnderGlass()
        }
    }

    // MARK: - Terminal Occlusion

    /// Tell each Ghostty terminal whether it's actually on screen. Workspaces
    /// in the vertical strip stay in the view hierarchy even when scrolled
    /// out of view, so the host window's occlusion state isn't enough — every
    /// surface's CVDisplayLink would still hit `waitUntilCompleted` on the
    /// main thread, which freezes the app once a few Claude/Codex sessions
    /// pile up. Only the active workspace is visible.
    func syncTerminalOcclusion() {
        // A minimized or fully covered window reports itself non-visible via
        // occlusionState; without this AND every surface keeps drawing.
        let windowVisible = window.map { sideEffects.windowShows($0) } ?? true
        for (index, workspace) in workspaces.enumerated() {
            let isInActiveProfile = workspace.profileID == activeProfileID
            // The one the strip is leaving too, until it has left (see
            // NiruxShellView+WorkspaceSwitch).
            let visible = windowVisible && isInActiveProfile
                && drawsTerminals(of: workspace, isActive: index == activeWSIndex)
            for col in workspace.columns {
                sideEffects.setSurfaceVisible(col, visible)
            }
        }
    }

    /// Tell every terminal the display it is on: one whose surface was
    /// built while no display was active gets its display link then (see
    /// `TerminalDisplayID`).
    func sendDisplayToTerminals() {
        needsDisplayResync = false
        for workspace in workspaces {
            for column in workspace.columns {
                guard let terminal = column.terminalView, let session = column.pty?.terminalSession else { continue }
                sideEffects.sendTerminalDisplay(session, TerminalDisplayID.display(of: terminal))
            }
        }
    }

    // MARK: - Header Titles

    func refreshHeaderTitles(snapshot: ProcessSnapshot? = nil) {
        guard let workspace = activeWorkspace else { return }
        let snap = snapshot ?? ProcessSnapshot()
        for col in workspace.columns {
            col.updateHeaderTitle(snapshot: snap)
            col.refreshAgentUsage(snapshot: snap)
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        relayoutForNewSize()
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

    /// A pinch the views under the fingers leave (a terminal does).
    override func magnify(with event: NSEvent) {
        if !pinched(by: event.magnification, phase: event.phase, at: convert(event.locationInWindow, from: nil)) { super.magnify(with: event) }
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
                    // Covered or minimized: no light moves unseen.
                    self?.applyAgentLights()
                    // Uncovered: a stale review reads its branch again.
                    self?.refreshStaleBranchReviewsOnScreen()
                    // Shown, so on a display that is on: told again after a
                    // wake, when the woken display may not have been usable.
                    if self?.window?.occlusionState.contains(.visible) == true, self?.needsDisplayResync == true {
                        self?.sendDisplayToTerminals()
                    }
                }
            }
            NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendDisplayToTerminals() }
            }
            if !observesDisplays {
                observesDisplays = true
                let displayChanges = [
                    (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification),
                    (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
                    (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification)
                ]
                for (center, name) in displayChanges {
                    center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.sendDisplayToTerminals()
                            self?.needsDisplayResync = true
                            self?.retryTerminalSurfacesOffScreen()
                        }
                    }
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sidebarStaleLogCameToFront()
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
        // The strip glides to its new place, a centred one aside; the new
        // column comes in at its own.
        relayout(animated: true)
        arrive(ws.columns[ws.focusedIndex], in: ws)
        updateSidebar()
        focusActiveTerminal(in: window)
    }

    /// A card comes in from the front, a little larger, and leaves
    /// receding (study P8).
    static let arrivalScale: CGFloat = 1.05
    static let arrivalDuration: TimeInterval = 0.38
    static let closeScale: CGFloat = 0.93
    static let closeDuration: TimeInterval = 0.24

    /// A column comes in at its place from the front, over its neighbours:
    /// a little larger and transparent. Its shadow and its light come once
    /// it is in. Nothing moves while the interface may not, nor before the
    /// column is laid out (a viewport with no size yet).
    func arrive(_ column: ColumnState, in workspace: WorkspaceState) {
        let size = column.view.frame.size
        guard agentLightsMayMove, size.width > 0, size.height > 0 else { return }
        column.isArriving = true
        column.updateDepth()
        workspace.showShadows()
        applyAgentLights()
        column.pass(
            from: (Self.arrivalScale, 0), to: 1, alpha: 1, duration: Self.arrivalDuration,
            curve: CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        ) { [weak self, weak column, weak workspace] in
            guard let self, let column, let workspace else { return }
            column.isArriving = false
            column.updateDepth()
            workspace.showShadows()
            self.applyAgentLights()
        }
    }

    enum HDir { case left, right }
    func focusColumn(_ dir: HDir) {
        guard let workspace = activeWorkspace else { return }
        if let index = adjacentColumnIndex(dir) { workspace.focusedIndex = index }
        relayout(animated: true)
        updateSidebar()
        focusActiveTerminal(in: window, editorTakesKeyboard: true)
    }

    /// The column beside the focused one in the active workspace, if any.
    func adjacentColumnIndex(_ dir: HDir) -> Int? {
        guard let workspace = activeWorkspace else { return nil }
        let index = workspace.focusedIndex + (dir == .left ? -1 : 1)
        return workspace.columns.indices.contains(index) ? index : nil
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
        let from = workspace.focusedIndex
        workspace.moveColumn(dir)
        relayout(animated: true)
        if agentLightsMayMove, workspace.focusedIndex != from,
           let moved = workspace.columns[safe: workspace.focusedIndex], let passed = workspace.columns[safe: from] {
            moved.lift(over: passed)
        }
        focusActiveTerminal(in: window)
    }

    // MARK: - Workspace naming

    func showWorkspaceContextPanel(workspaceIndex: Int) {
        guard let window, let workspace = workspaces[safe: workspaceIndex] else { return }
        if workspaceContextPanel == nil {
            workspaceContextPanel = WorkspaceContextPanel()
        }

        let presentedSummary = WorkspaceState.normalizedContextText(workspace.lastSummary)
        let presentedNextStep = workspace.nextStep
        let presentedBlocker = workspace.blocker
        workspaceContextPanel?.onSave = { [weak self, weak workspace] values in
            guard let self, let workspace,
                  self.workspaces.contains(where: { $0 === workspace }) else { return }
            workspace.setPurpose(values.purpose, by: .user)
            workspace.phase = values.phase
            if values.phase != nil {
                workspace.unknownPhaseRawValue = nil
            }
            // What the user typed is theirs: the Lead leaves it.
            workspace.setContextByHand(.nextStep, values.nextStep, presented: presentedNextStep)
            workspace.setContextByHand(.blocker, values.blocker, presented: presentedBlocker)

            if WorkspaceState.normalizedContextText(values.lastSummary) != presentedSummary {
                workspace.setSummaryByHand(values.lastSummary)
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
            contextHelp: WorkspaceContextPanel.contextHelp(
                nextStepIsFromLead: workspace.nextStepIsFromLead, blockerIsFromLead: workspace.blockerIsFromLead,
                reportsToLead: workspace.reportsToLead
            ),
            gitBranch: workspace.gitBranch,
            diffStats: workspace.diffStats,
            prInfo: workspace.prInfo,
            agentStatuses: workspace.columns.map { $0.pty?.cachedAgentState ?? .idle }
        )
        workspaceContextPanel?.show(relativeTo: window, configuration: configuration)
    }

    /// A name the user or the Lead gave: kept over the agents' titles.
    func renameWorkspace(_ workspace: WorkspaceState, to title: String) {
        workspace.title = title
        workspace.titleIsManual = true
        updateSidebar()
        saveState()
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
            self.renameWorkspace(workspace, to: newTitle)
        }
        nameInputPanel?.show(relativeTo: window, currentValue: workspace.title, placeholder: "Workspace name")
    }

    // MARK: - Worktree

    /// "Open Worktree": the worktrees of the focused terminal's repository,
    /// that one left out. "Existing Branch…" in the ⌘N sheet: those of
    /// `repositoryFolder`'s repository (a space's anchor), then its
    /// branches that have no worktree, which get one when picked.
    func showWorktreeListPalette(repositoryFolder: String? = nil) {
        guard let window else { return }
        let folder = repositoryFolder ?? activeWorkspace?.focusedWorkingDirectory
        guard let folder, let repoRoot = GitWorktree.repoRoot(at: folder)
        else { return showToast("Not in a git repository: \(folder?.abbreviatedPath() ?? "")") }
        let excluded = repositoryFolder == nil ? Self.comparablePath(repoRoot) : nil
        // From the focused terminal, not the active workspace: its folder is
        // where it was opened, not where its terminal is now, and going back
        // to it would do nothing. From the sheet it counts, so picking its
        // worktree goes back to it rather than opening a second one.
        let openWorkspaces = workspaces.filter { !$0.isClosing && (repositoryFolder != nil || $0 !== activeWorkspace) }
            .map { (id: $0.id, cwd: $0.cwd) }

        // List worktrees on background thread, then show palette
        let listsBranches = repositoryFolder != nil
        DispatchQueue.global(qos: .userInitiated).async {
            let worktrees = GitWorktree.list(repoRoot: repoRoot)
            let branches = listsBranches ? GitWorktree.branchesWithoutWorktree(repoRoot: repoRoot, worktrees: worktrees) : []
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
                let entries = zip(worktrees, comparablePaths).filter { _, path in path != excluded }
                guard !entries.isEmpty || !branches.isEmpty else {
                    return self.showToast("No other worktree found in this repository")
                }

                // Build palette actions from worktree entries
                let actions = entries.map { entry, comparablePath in
                    let title = entry.branch ?? URL(fileURLWithPath: entry.path).lastPathComponent
                    let open = self.preferredWorkspace(among: workspaceWorktrees.filter { $0.path == comparablePath })
                    let subtitle = (open.map { self.alreadyOpenNote(for: $0) + " · " } ?? "") + entry.path.abbreviatedPath()
                    let openID = open?.id
                    return PaletteAction(icon: .symbol("folder"), title: title, subtitle: subtitle, shortcut: nil) { [weak self] in
                        self?.openWorktree(path: entry.path, title: title, workspaceID: openID)
                    }
                } + branches.map { branch in
                    PaletteAction(
                        icon: .symbol(Theme.Symbol.branch), title: branch.name,
                        subtitle: "No worktree yet · " + (branch.isRemote ? "origin/\(branch.name)" : "local branch"), shortcut: nil
                    ) { [weak self] in
                        self?.openBranchInNewWorktree(branch.name, repoRoot: repoRoot)
                    }
                }

                self.makeCommandPaletteIfNeeded()
                self.commandPalette?.actions = actions
                self.commandPalette?.show(relativeTo: window, placement: self.commandPalettePlacement)
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

    /// A branch without a worktree, picked in "Existing Branch…": its
    /// worktree is made off the main thread (one of origin's tracks it),
    /// then opens as a plain workspace.
    private func openBranchInNewWorktree(_ branch: String, repoRoot: String) {
        let spaceID = activeProfileID
        Self.createBranchWorktree(branch, repoRoot: repoRoot) { [weak self] path, checkedOutBranch, error in
            guard let self else { return }
            guard let path else {
                return self.presentProblem("Couldn’t create worktree “\(branch)”", error ?? "git worktree add failed")
            }
            self.openRoutedWorkspace(title: branch, cwd: path, startedFromSpaceID: spaceID, worktreeBranch: checkedOutBranch)
        }
    }

    /// Off the main thread through a nonisolated function, so the closure
    /// can't inherit this view's main-actor isolation (see NewTask).
    nonisolated private static func createBranchWorktree(
        _ branch: String, repoRoot: String,
        completion: @escaping @MainActor @Sendable (String?, String?, String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            // An existing branch: a path, or an error, never both.
            let (path, error) = GitWorktree.create(branch: branch, repoRoot: repoRoot)
            let checkedOutBranch = path.flatMap(GitWorktree.currentBranch(at:))
            DispatchQueue.main.async { @MainActor in completion(path, checkedOutBranch, error) }
        }
    }

    private func openWorktree(path: String, title: String, workspaceID: String?) {
        if let workspaceID, workspaces.contains(where: { $0.id == workspaceID && !$0.isClosing }) {
            focusWorkspace(id: workspaceID)
        } else {
            openRoutedWorkspace(title: title, cwd: path, startedFromSpaceID: activeProfileID)
        }
    }

    // MARK: - Command Palette (Cmd+P)

    func showCommandPalette() {
        guard let window else { return }
        // The palette takes the keyboard and the place under the bar.
        closeInbox(.byClickElsewhere)
        closeCallout(.byClickElsewhere)

        if commandPalette?.isVisible == true {
            commandPalette?.dismiss()
            return
        }

        makeCommandPaletteIfNeeded()
        commandPalette?.actions = columnPaletteActions() + agentPaletteActions() + workspacePaletteActions()
        commandPalette?.show(relativeTo: window, sections: paletteSections(), placement: commandPalettePlacement)
    }

    private func makeCommandPaletteIfNeeded() {
        guard commandPalette == nil else { return }
        let palette = CommandPalette()
        palette.onURLSubmit = { [weak self] url in
            self?.openWebView(url: url)
        }
        palette.onDismiss = { [weak self] in
            self?.focusActiveTerminal(in: self?.window)
        }
        // Whether the window with the bar shows, as the shell sees it (a
        // flow test's window never shows on screen).
        palette.windowShows = { [weak self] window in self?.sideEffects.windowShows(window) ?? false }
        commandPalette = palette
    }

    /// Under the command bar once the window has one (a press on its search
    /// segment while ⌘P shows closes it: `CommandPalette.isSearchButtonPress`);
    /// centred otherwise.
    var commandPalettePlacement: CommandPalette.Placement {
        commandBarToolbar.map { .underBar($0.bar, level: $0.bar.level) } ?? .centered
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

    /// Gives the keyboard to the focused column of the active workspace.
    /// An editor column only takes it when the user went to it
    /// (`editorTakesKeyboard`): an agent's open focuses its column but
    /// leaves the keyboard where the user types, and closing a panel later
    /// must not hand that editor the keys.
    func focusActiveTerminal(in window: NSWindow?, editorTakesKeyboard: Bool = false) {
        guard let window else { return }
        guard let col = activeWorkspace?.columns[safe: activeWorkspace?.focusedIndex ?? 0] else {
            // An empty space: its view takes the keyboard, so Return
            // presses New… and no key reaches a terminal hidden behind it.
            if activeWorkspace == nil { window.makeFirstResponder(emptySpaceView) }
            return
        }
        if col.isFindBarOpen {
            // An open find bar keeps the keyboard: text typed for it must
            // reach neither the agent nor the page's shortcuts. A click on
            // the terminal or page takes it back.
            if !col.isEditingFind { col.findBar?.focusField() }
        } else if let webView = col.webViewColumn {
            window.makeFirstResponder(webView.webView)
        } else if let editor = col.editorColumn {
            if editorTakesKeyboard { editor.takeKeyboard() }
        } else if let board = col.projectBoard {
            window.makeFirstResponder(board.view)
        } else if let review = col.branchReview {
            review.view.takeKeyboard()
        } else if let terminal = col.terminalView {
            window.makeFirstResponder(terminal)
        }
    }

    func focusColumnByIndex(_ index: Int) {
        guard let workspace = activeWorkspace, workspace.columns.indices.contains(index), workspace.focusedIndex != index else { return }
        workspace.focusedIndex = index
        relayout(animated: true)
        updateSidebar()
        focusActiveTerminal(in: window, editorTakesKeyboard: true)
    }

    /// The pointer went down in the window. The column a click landed on
    /// (`index`) takes the focus without moving the strip, so that the
    /// click, a double-click or a drag land on what was under the pointer;
    /// the strip goes where it wants once the button is up and a
    /// double-click had its chance.
    func clickBegan(onColumn index: Int?) {
        if let index, let workspace = activeWorkspace, workspace.columns.indices.contains(index),
           workspace.focusedIndex != index {
            workspace.holdCamera(for: index)
            focusColumnByIndex(index)
        }
        scheduleCameraRelease()
    }

    /// From the mouse-down, as the local monitor never sees a mouse-up a
    /// button's or a menu's tracking takes; the default run loop mode runs
    /// it once that tracking is over.
    private func scheduleCameraRelease(after delay: TimeInterval = NSEvent.doubleClickInterval) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(releaseHeldCameras), object: nil)
        perform(#selector(releaseHeldCameras), with: nil, afterDelay: delay)
    }

    @objc private func releaseHeldCameras() {
        // A drag or a long press goes on; a double-click's interval counts
        // from the mouse-up.
        let wait = NSEvent.pressedMouseButtons & 1 != 0
            ? NSEvent.doubleClickInterval : NSEvent.doubleClickInterval - sideEffects.secondsSinceMouseUp()
        guard wait <= 0 else { return scheduleCameraRelease(after: wait) }
        let held = workspaces.filter { $0.heldCamera != nil }
        guard !held.isEmpty else { return }
        for workspace in held { workspace.heldCamera = nil }
        relayout(animated: true)
    }

    /// Gives the focus to the column of `header`, for the header's ⋯ items
    /// that act on the focused column. False when that column isn't in the
    /// active workspace (gone, or in a workspace sliding away).
    func focusColumn(withHeader header: ColumnHeaderView) -> Bool {
        guard let workspace = activeWorkspace,
              let index = workspace.columns.firstIndex(where: { $0.header === header && !$0.isClosing })
        else { return false }
        focusColumnByIndex(index)
        return true
    }

    /// Focuses column `index` of the active workspace at the user's request
    /// (Cmd+1…9, the sidebar). An agent's open focuses its editor column
    /// without the keyboard: going to it then hands the keyboard over.
    func goToColumn(_ index: Int) {
        guard let workspace = activeWorkspace, workspace.columns.indices.contains(index) else { return }
        if workspace.focusedIndex == index, workspace.columns[index].isEditor {
            focusActiveTerminal(in: window, editorTakesKeyboard: true)
        } else {
            focusColumnByIndex(index)
        }
    }

    var activeWorkspace: WorkspaceState? { workspaceStore.activeWorkspace }
    var activeWorkspaceForKeyIntercept: WorkspaceState? { activeWorkspace }

    var isOverlayActive: Bool {
        if commandPalette?.isVisible == true { return true }
        // The space's plan takes the keys over hidden terminals; diving, it
        // leaves them to the workspace it goes to, which shows under it.
        if let spacePlan, !spacePlan.isDiving { return true }
        if NSApp.keyWindow is NSPanel { return true }
        if let body = sidebar.taskPreview.pinnedBody, let responder = window?.firstResponder as? NSView,
           responder.isDescendant(of: body) { return true }
        // A popover hanging from the window has the keyboard (the Mission
        // reply's field): AppKit keeps the window key, gives it the
        // popover's first responder and hands it the keys. Not once that
        // popover is gone.
        if let responder = window?.firstResponder as? NSView, let owner = responder.window,
           owner !== window, owner.isVisible {
            return true
        }
        return false
    }
}
