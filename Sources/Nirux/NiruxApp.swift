import AppKit
import GhosttyTerminal
import Sparkle

@main @MainActor
final class NiruxApp: NSObject, NSApplicationDelegate, SPUUpdaterDelegate, NSMenuItemValidation {
    var mainWindow: NSWindow?
    /// Open for a canary run only (see CanaryChannel).
    var canaryRequests: LeadRequestCenter?
    /// A canary run's copy never comes forward (CanaryPresentation).
    var presence = AppPresence(launchEnvironment: [:], bringForward: NiruxApp.bringNiruxForward)
    var drivenByCanary: Bool { !presence.mayComeForward }
    var canaryObservers: [NSObjectProtocol] = []
    var shell: NiruxShellView? {
        // Its Settings window holds Nirux's panes too.
        didSet { if let shell, shell !== oldValue { wireSettings(shell.settingsWindow) } }
    }
    var updaterController: SPUStandardUpdaterController?
    /// A quit is the user's unless an update relaunches the app or the Mac
    /// powers off (`setupUpdater`): the next launch resumes no work after it.
    var quitIsUsers = true
    /// Settings without a shell (tests); the app's are the shell's.
    var standaloneSettings: SettingsWindow?
    weak var settingsTaskNamesCheckbox: NSButton?
    weak var settingsKeepAwakeCheckbox: NSButton?
    weak var settingsAnimationsCheckbox: NSButton?
    weak var settingsTransparencyPicker: TransparencyPicker?
    weak var settingsTerminalOpacitySlider: NSSlider?
    weak var settingsTerminalOpacityLabel: NSTextField?
    /// The terminals' opacity, saved once the slider stays still.
    var settingsTerminalOpacitySave: DispatchWorkItem?
    weak var settingsTasksFolderLabel: NSTextField?
    weak var settingsUsageLimitsCheckbox: NSButton?
    weak var settingsAgentResumePopup: NSPopUpButton?
    weak var settingsLaunchModePopup: NSPopUpButton?
    weak var settingsNoFlickerCheckbox: NSButton?
    weak var settingsCodexLaunchModePopup: NSPopUpButton?
    weak var settingsAgyLaunchModePopup: NSPopUpButton?
    weak var settingsMissionHandoffsCheckbox: NSButton?
    weak var settingsSidebarApprovalsCheckbox: NSButton?
    weak var settingsStuckAgentPopup: NSPopUpButton?
    weak var settingsCirclingHintCheckbox: NSButton?
    weak var settingsExplainModelPopup: NSPopUpButton?
    weak var settingsExplainEffortPopup: NSPopUpButton?
    weak var settingsAlertOnlyWhenClaudeAsksCheckbox: NSButton?
    weak var settingsTurnStatusCheckbox: NSButton?
    weak var settingsCatchUpCheckbox: NSButton?
    weak var settingsTriageCIFailuresCheckbox: NSButton?
    var keepAwakeController: KeepAwakeController?
    var keepAwakeIndicator: KeepAwakeIndicator?
    var usageLimitsIndicator: ClaudeUsageIndicator?
    var usageLimitsMonitor: ClaudeUsageLimitsMonitor?
    /// What Settings reports about Claude Code's status line, and how it
    /// installs Nirux's; Settings tests stub both, so they never write to
    /// ~/.claude.
    var claudeStatusLineStateReader: () -> AgentHookInstaller.ClaudeStatusLineState = {
        AgentHookInstaller.claudeStatusLineState()
    }
    var claudeStatusLineInstaller: (Bool) -> Void = { AgentHookInstaller.applyClaudeStatusLine(enabled: $0) }
    var isManualUpdateCheck = false
    var updaterReady = false
    var urlConfirmations = URLConfirmationQueue()
    var urlConfirmationRestoreApp: NSRunningApplication?
    var launchURLBacklog: [URL] = []
    var lastExternalApp: NSRunningApplication?
    var niruxActivatedAt: TimeInterval = 0
    /// Held until Nirux quits (see StateFolderLock), marked quitting as it
    /// goes.
    static var stateFolderLock: StateFolderLock?

    static func main() {
        // A command-line mode never launches the app UI (see
        // LaunchArguments.Mode). Anything else opens the app only without
        // arguments or with -Key value defaults: any other argument used to
        // open it too, so `"$NIRUX_CLI_PATH" --help`, or a command an agent
        // guessed, started a second Nirux on the real state.
        switch LaunchArguments.decision(for: CommandLine.arguments) {
        case .mode(.statusLine):
            exit(ClaudeStatusLineCLI.run())
        case .mode(.toolsServer):
            exit(NiruxMCPServer.run())
        case .mode(.setupFailure(let workspaceID)):
            exit(SetupFailureSignal.run(workspaceID: workspaceID))
        case .mode(.hook(let kind, let payload)):
            exit(AgentHookCLI.run(kind: kind, payload: payload))
        case .mode(.mission(let arguments)):
            exit(MissionEventCLI.main(arguments))
        case .mode(.checkTerminalRuntime):
            // A terminal runtime that doesn't load (libghostty-spm's
            // resources left out of the app) fails the nightly, not users'
            // first terminal.
            exit(MainActor.assumeIsolated { TerminalAppearance.checkRuntime() })
        case .mode(.checkReleaseSignature(let arguments)):
            exit(MergeQueue.checkReleaseSignatureCommand(arguments))
        case .ignoredHook(let readsInput):
            if readsInput { LaunchArguments.readStandardInputToEnd() }
            exit(EXIT_SUCCESS)
        case .help:
            guard LaunchArguments.startedByLaunchServices else {
                FileHandle.standardOutput.write(Data(LaunchArguments.usage.utf8))
                exit(EXIT_SUCCESS)
            }
            LaunchArguments.refuse(
                standardError: LaunchArguments.usage, alertTitle: "Nirux didn't open",
                alertText: LaunchArguments.usage, status: EXIT_SUCCESS
            )
        case .unknown(let argument):
            LaunchArguments.refuse(
                standardError: LaunchArguments.unknownArgumentMessage(argument), alertTitle: "Nirux didn't open",
                alertText: LaunchArguments.unknownArgumentAlertText(argument), status: 2
            )
        case .launchApp:
            break
        }
        // Only the installed app opens the real state; any other copy needs
        // a state of its own (see RealStateGuard). Command-line modes stay
        // above this: they run from any copy and any parent (agent hooks,
        // NIRUX_CLI_PATH, the nightly's checks), which this would stop.
        if let refused = RealStateGuard.refusedExecutable() {
            RealStateGuard.refuseLaunch(executablePath: refused)
        }
        // One Nirux per state folder: a second one (the binary run from a
        // terminal, `open -n`) brings the first to the front and quits,
        // before reading anything. See StateFolderLock.
        switch StateFolderLock.acquire(in: Persistence.stateDirectory) {
        case .acquired(let lock):
            stateFolderLock = lock
        case .unavailable(let problem):
            NSLog("[Nirux] Opening without the state folder's lock: %@", problem)
        case .held(let holder):
            StateFolderLock.yield(to: holder)
        }

        let app = NSApplication.shared
        let delegate = NiruxApp()
        app.delegate = delegate
        app.run()
    }

    /// The main window as Nirux configures it, before its shell and its
    /// toolbar (`NiruxShellView.installCommandBar`); the tests build theirs
    /// with it.
    static func makeMainWindow(contentRect: NSRect) -> NSWindow {
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.backgroundColor = Theme.Color.canvas
        window.minSize = NSSize(width: 600, height: 400)
        window.title = "Nirux"
        window.appearance = Theme.appearance
        return window
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MergeQueue.checkSignatureAtLaunch()
        if ProcessInfo.processInfo.environment["NIRUX_TERM_DEBUG"] != nil {
            TerminalDebugLog.enable([.metrics, .lifecycle])
        }
        NSApp.setActivationPolicy(.regular)
        // A canary run drives this copy through its channel: behind the
        // user's windows, never taking the focus.
        let launchEnvironment = ProcessInfo.processInfo.environment
        presence = AppPresence(launchEnvironment: launchEnvironment, bringForward: Self.bringNiruxForward)
        if drivenByCanary {
            canaryObservers = CanaryPresentation.keepHidden(on: .default) { NSApp.hide(nil) }
            NSApp.hide(nil)
        }
        setupKeyInterceptor()
        setupClickToFocus()
        setupMenus()

        let rect = Self.initialMainWindowFrame()
        let window = Self.makeMainWindow(contentRect: rect)
        // Its close button quits Nirux: a running merge queue asks first.
        window.delegate = self

        let shellView = NiruxShellView(frame: rect)
        window.contentView = MainWindowContent(shell: shellView)
        shell = shellView
        connect(shellView, to: NiruxNotifier.shared)
        shellView.applyInterfaceTransparency()
        shellView.installCommandBar(in: window)
        // The frame the screen leaves, now that the toolbar set the title
        // bar's height: even margins all round.
        window.setFrame(rect, display: false)
        setUpUsageLimits(window: window)
        setUpKeepAwake(window: window, shell: shellView)
        setupStatusBarNotices()
        // Copies of a branch an Explain run left when Nirux quit or crashed.
        BranchReview.ExplainCopy.sweepInBackground()
        // Telegram Remote Access is gone: so is its bot token (Keychain).
        LegacyTelegramToken.removeAtLaunch()

        NiruxNotifier.shared.setup()

        if drivenByCanary { window.orderBack(nil) } else { window.makeKeyAndOrderFront(nil) }
        mainWindow = window

        // Before the restore relaunches agent sessions, which read the skills.
        updateAgentSkills(reportingTo: shellView)
        // Before the restore: its first layout lists Mission children under
        // their parent.
        MissionStore.shared.load()
        // Restore previous session if available
        shellView.restoreState()
        // After the restore: its first read, seconds long, credits the
        // restored tasks.
        shellView.startUsageMonitor { [weak self] _ in self?.showCodexLimits() }

        // Agent lifecycle hooks: install into ~/.claude/settings.json and
        // ~/.codex/config.toml, then start routing events to columns. Must
        // run AFTER restoreState so queued events resolve to live columns.
        installAgentHooks(reportingTo: shellView)
        // The app's shell only: whether the user is away is the app's.
        shellView.wireCatchUp()
        shellView.startDailyPassWatch()
        shellView.followSystemForSidebarStaleLog()
        // Message ids, kinds, reasons and counts: public.
        shellView.sideEffects.logMissionWait = { MissionWaitLog.logger.notice("\($0, privacy: .public)") }
        let hooks = AgentHookCenter.shared
        // Before the backlog replay in start(): it releases what it can't hold.
        hooks.applySidebarApprovals(enabled: NiruxShellView.currentSidebarApprovalsEnabled())
        hooks.turnEndClassifier = Self.turnEndClassifier(enabled: Self.currentAlertOnlyWhenClaudeAsks())
        hooks.turnStatusWriter = Self.turnStatusWriter(enabled: Self.currentShowTurnStatus())
        applyCITriage(enabled: Self.currentTriageCIFailures(), readsFinalMessages: hooks.readsFinalMessages)
        hooks.onTurnEndSettled = { [weak shellView] in
            // Not inside the drain that may have settled it.
            DispatchQueue.main.async { shellView?.turnEndSettled() }
        }
        hooks.onTurnStatus = { [weak shellView] _ in shellView?.turnStatusChanged() }
        hooks.onTurnDone = { [weak shellView] resolution, endedAt in
            shellView?.agentTurnDone(in: resolution.column, endedAt: endedAt)
        }
        hooks.resolver = { [weak shellView] uuid in
            shellView?.resolveAgentColumn(uuid: uuid)
        }
        hooks.asksParent = { [weak shellView] resolution, request, question in
            shellView?.askParent(for: resolution, request, asking: question) ?? false
        }
        hooks.onEventsApplied = { [weak shellView] events in
            shellView?.applyAgentHookEvents(events)
        }
        observeSetupFailures()
        hooks.start()

        let missionEvents = MissionEventCenter.shared
        missionEvents.onEvent = { [weak shellView] mission, event in
            shellView?.handleMissionEvent(mission, event: event) ?? false
        }
        missionEvents.start()

        // The Lead's tools (see LeadChannel).
        let leadRequests = LeadRequestCenter.shared
        leadRequests.handler = { [weak shellView] request, answer in
            guard let shellView else { return answer("Nirux is closing.", true) }
            shellView.handleLeadRequest(request, answer: answer)
        }
        leadRequests.owns = { [weak shellView] request in
            shellView?.workspaces.contains { $0.id == request.workspaceID } == true
        }
        leadRequests.start()
        canaryRequests = CanaryChannel.start(environment: launchEnvironment, stateDirectory: Persistence.stateDirectory) { [weak self] request, answer in
            guard let self else { return answer("Nirux is closing.", true) }
            self.performCanaryRequest(request, answer: answer)
        }

        // Focus first terminal
        shellView.focusActiveTerminal(in: window)

        // Force all terminal views to re-evaluate focus state.
        // Terminals created before makeFirstResponder never received
        // resignFirstResponder, so they default to "focused" (blinking cursor).
        // Posting didBecomeKeyNotification causes each ghostty surface to
        // check window.firstResponder === self and set focus accordingly.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        presence.comeForward()
        startTrackingFrontmostApp()
        drainLaunchURLBacklog()
    }

    /// The status bar's notices: an available update, a crash of an earlier
    /// session.
    private func setupStatusBarNotices() {
        setupUpdater()
        checkForCrashReports()
    }

    /// The main screen's visible area, inset by 50 pt.
    private static func initialMainWindowFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSRect(x: screen.origin.x + 50, y: screen.origin.y + 50,
                      width: screen.width - 100, height: screen.height - 100)
    }

    /// The Getting Started checklist refreshes after the install, so it
    /// reports the hooks as written.
    private func installAgentHooks(reportingTo shellView: NiruxShellView) {
        AgentHookInstaller.installAll(claudeStatusLine: Self.savedClaudeStatusLineOption())
        shellView.refreshOnboardingChecklist()
    }

    /// Brings the installed copies of Nirux's skills that Nirux wrote up to
    /// this version's text, off the main thread, then refreshes Getting
    /// Started, which keeps offering the update for copies the user edited.
    /// A development build or a copy on a state of its own would put its
    /// wording in every agent session, so only the installed app does it.
    private func updateAgentSkills(reportingTo shellView: NiruxShellView) {
        guard AgentHookInstaller.maintainsSharedAgentFiles(
            environment: ProcessInfo.processInfo.environment, bundleURL: Bundle.main.bundleURL
        ) else { return }
        AgentSkillsInstaller.updateNiruxCopiesInBackground(
            of: NiruxShellView.agentSkills, home: shellView.sideEffects.homeDirectory()
        ) { [weak shellView] in
            shellView?.refreshOnboardingChecklist()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Unsaved changes and a running merge queue ask first, an update's
    /// relaunch too (see `terminateReply`).
    /// A quit called off there (a shutdown's, an update's) leaves the next
    /// one the user's (`quitIsUsers`).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shell else { return .terminateNow }
        let reply = shell.terminateReply { [weak self] quit in
            if !quit { self?.quitIsUsers = true }
            NSApp.reply(toApplicationShouldTerminate: quit)
        }
        if reply == .terminateCancel { quitIsUsers = true }
        return reply
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A Nirux opened meanwhile (Sparkle's relaunch, a quick reopen)
        // waits for this one to go instead of bringing it to the front.
        Self.stateFolderLock?.markQuitting()
        // Apply hooks still inside the drain debounce (a first prompt just
        // sent) so the saved Claude restore targets are current.
        AgentHookCenter.shared.drain()
        shell?.quitsByUser = quitIsUsers
        shell?.saveState(snapshot: ProcessSnapshot())
        // A queue's last step is written before the process ends.
        MergeQueueController.waitForFiles()
        // So are the threads' last lines (local appends, quick).
        TaskThread.Store.queue.sync {}
        keepAwakeController?.shutdown()
        // A claude left running would go on reading, on the user's plan.
        ExplainQueue.shared.cancelAll(waitingUpTo: 2)
        NiruxNotifier.shared.updateDockBadge(attentionCount: 0)
        // Every agent goes with its terminal; a restore resumes the session.
        shell?.sessionLedger.closeAllSessions(at: Date().timeIntervalSince1970)
        // Receivers stop waiting on an app that is gone.
        shell?.releaseAllPermissionApprovals()
        // And stop writing final messages and account reports for it.
        TurnEndMarker.withdraw(app: ProcessInstance.running(pid: getpid()))
        AgentHookCenter.shared.approvalChannel().stopListening(for: ProcessInstance.running(pid: getpid()))
        AgentHookCenter.shared.stop()
        MissionEventCenter.shared.stop()
        LeadRequestCenter.shared.stop()
        canaryRequests?.stop()
    }

    // MARK: - NSMenuItemValidation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(resumeAllAgents(_:)) {
            return (shell?.deferredAgentCount ?? 0) > 0
        }
        if menuItem.action == #selector(focusLead(_:)) {
            return validateLeadItem(menuItem)
        }
        if menuItem.action == #selector(restartLead(_:)) {
            return shell.map { $0.leadWorkspace(inSpace: $0.activeProfileID) != nil } ?? false
        }
        if menuItem.action == #selector(newSubtask(_:)) {
            return shell?.activeWorkspaceOffersSubtask ?? false
        }
        if [#selector(showFind(_:)), #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:))].contains(menuItem.action) {
            return canFind
        }
        if menuItem.action == #selector(importBrowserCookies(_:)) {
            // Disabled while an import runs: a second one would wait behind it.
            return shell.map { !$0.isImportingCookies && !$0.sideEffects.cookieBrowsers().isEmpty } ?? false
        }
        if menuItem.action == #selector(selectSpaceByNumber(_:)) {
            return menuItem.tag <= (shell?.sidebar.lastProfiles.count ?? 0)
        }
        if menuItem.action == #selector(toggleInactiveWorkspaces(_:)) {
            guard let shell else { return false }
            // Folded, the list doesn't show, whatever its state.
            menuItem.state = shell.sidebar.isExpanded && !shell.sidebar.isInactiveSectionCollapsed ? .on : .off
            return shell.sidebar.hasInactiveWorkspaces
        }
        return validateMenuItemForUpdate(menuItem)
    }
}
