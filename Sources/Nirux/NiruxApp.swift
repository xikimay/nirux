import AppKit
import GhosttyTerminal
import Sparkle

@main @MainActor
final class NiruxApp: NSObject, NSApplicationDelegate, SPUUpdaterDelegate, NSMenuItemValidation {
    var mainWindow: NSWindow?
    var shell: NiruxShellView?
    var updaterController: SPUStandardUpdaterController?
    var updateDot: NSView?
    var settingsWindow: NSWindow?
    weak var settingsKeepAwakeCheckbox: NSButton?
    weak var settingsUsageLimitsCheckbox: NSButton?
    weak var settingsAgentResumePopup: NSPopUpButton?
    weak var settingsLaunchModePopup: NSPopUpButton?
    weak var settingsNoFlickerCheckbox: NSButton?
    weak var settingsCodexLaunchModePopup: NSPopUpButton?
    weak var settingsMissionHandoffsCheckbox: NSButton?
    weak var settingsSidebarApprovalsCheckbox: NSButton?
    weak var settingsStuckAgentPopup: NSPopUpButton?
    weak var settingsExplainModelPopup: NSPopUpButton?
    weak var settingsExplainEffortPopup: NSPopUpButton?
    weak var settingsTelegramEnabledCheckbox: NSButton?
    weak var settingsTelegramTokenField: NSSecureTextField?
    weak var settingsTelegramCompletionCheckbox: NSButton?
    weak var settingsTelegramAttentionCheckbox: NSButton?
    weak var settingsTelegramStatusLabel: NSTextField?
    weak var settingsTelegramPairButton: NSButton?
    var telegramRemoteAccessController: TelegramRemoteAccessController?
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
    /// Keychain access used by the Settings window; tests stub it.
    var telegramTokenLoader: () throws -> String? = { try TelegramTokenStore.load() }
    var telegramTokenSaver: (String) throws -> Void = { try TelegramTokenStore.save($0) }
    var telegramTokenDeleter: () throws -> Void = { try TelegramTokenStore.delete() }
    var isManualUpdateCheck = false
    var updaterReady = false
    var urlConfirmations = URLConfirmationQueue()
    var urlConfirmationRestoreApp: NSRunningApplication?
    var launchURLBacklog: [URL] = []
    var lastExternalApp: NSRunningApplication?
    var niruxActivatedAt: TimeInterval = 0

    static func main() {
        // Hook-receiver mode: `Nirux --hook claude|codex [payload-json]`.
        // Claude Code hooks and Codex's notify command invoke the app binary
        // this way (see AgentHookInstaller); the process appends one event
        // line and exits — it must never launch the app UI.
        let args = CommandLine.arguments
        // Status line mode: Claude Code runs `Nirux --hook claude
        // --statusline` with the session's state on stdin while the usage
        // limits indicator is on. Spelled as a hook so that an older build at
        // the same path (a rollback) reads a hook payload without an event
        // and exits, instead of launching its UI on every response.
        if args.count >= 4, args[1] == "--hook", args[2] == "claude", args[3] == "--statusline" {
            exit(ClaudeStatusLineCLI.run())
        }
        // Tools server mode: Claude Code runs `Nirux --hook claude --mcp`
        // for the agents Nirux launches (NiruxMCPServer), spelled as a hook
        // for the same reason.
        if args.count >= 4, args[1] == "--hook", args[2] == "claude", args[3] == "--mcp" {
            exit(NiruxMCPServer.run())
        }
        if args.count >= 3, args[1] == "--hook", let kind = AgentHookEvent.Kind(rawValue: args[2]) {
            let payload = args.count > 3 ? args.last : nil
            exit(AgentHookCLI.run(kind: kind, payload: payload))
        }
        if args.count >= 2, args[1] == "--mission" {
            exit(MissionEventCLI.main(Array(args.dropFirst(2))))
        }
        // The nightly checks the app it publishes the way the merge queue
        // checks itself; with a path, another app (a downloaded nightly).
        if args.count >= 2, args[1] == "--check-release-signature" {
            exit(MergeQueue.checkReleaseSignatureCommand(Array(args.dropFirst(2))))
        }
        // Only the installed app opens the real state; any other copy needs
        // a state of its own (see RealStateGuard). Command-line modes stay
        // above this: they run from any copy and any parent (agent hooks,
        // NIRUX_CLI_PATH, the nightly's checks), which this would stop.
        if let refused = RealStateGuard.refusedExecutable() {
            RealStateGuard.refuseLaunch(executablePath: refused)
        }

        let app = NSApplication.shared
        let delegate = NiruxApp()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MergeQueue.checkSignatureAtLaunch()
        if ProcessInfo.processInfo.environment["NIRUX_TERM_DEBUG"] != nil {
            TerminalDebugLog.enable([.metrics, .lifecycle])
        }
        NSApp.setActivationPolicy(.regular)
        setupKeyInterceptor()
        setupClickToFocus()
        setupMenus()

        let rect = Self.initialMainWindowFrame()
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.backgroundColor = Theme.Color.canvas
        window.minSize = NSSize(width: 600, height: 400)
        window.title = "Nirux"
        window.appearance = Theme.appearance
        // Its close button quits Nirux: a running merge queue asks first.
        window.delegate = self

        let shellView = NiruxShellView(frame: rect)
        shellView.autoresizingMask = [.width, .height]
        window.contentView = shellView
        shell = shellView
        setUpUsageLimits(window: window)
        setUpKeepAwake(window: window, shell: shellView)
        setupStatusBarNotices()
        // Copies of a branch an Explain run left when Nirux quit or crashed.
        BranchReview.ExplainCopy.sweepInBackground()

        // Native notifications: click focuses the originating workspace/column.
        NiruxNotifier.shared.setup()
        NiruxNotifier.shared.onActivate = { [weak shellView] workspaceID, columnIndex in
            shellView?.focusWorkspace(id: workspaceID, column: columnIndex)
        }
        NiruxNotifier.shared.onCIFailureAction = { [weak shellView] workspaceID, action in
            shellView?.handleCIFailureAction(action, workspaceID: workspaceID)
        }

        window.makeKeyAndOrderFront(nil)
        mainWindow = window

        // Restore previous session if available
        shellView.restoreState()

        // Agent lifecycle hooks: install into ~/.claude/settings.json and
        // ~/.codex/config.toml, then start routing events to columns. Must
        // run AFTER restoreState so queued events resolve to live columns.
        installAgentHooks(reportingTo: shellView)
        ActivityStore.shared.load()
        MissionStore.shared.load()
        ActivityStore.shared.onChange = { [weak shellView] in
            shellView?.refreshActivitySidebar()
        }
        shellView.refreshActivitySidebar()
        let hooks = AgentHookCenter.shared
        // Before the backlog replay in start(): it releases what it can't hold.
        hooks.applySidebarApprovals(enabled: NiruxShellView.currentSidebarApprovalsEnabled())
        hooks.resolver = { [weak shellView] uuid in
            shellView?.resolveAgentColumn(uuid: uuid)
        }
        hooks.onEventsApplied = { [weak shellView] events in
            shellView?.applyAgentHookEvents(events)
        }
        let remoteAccess = TelegramRemoteAccessController(
            sessions: { [weak shellView] in shellView?.remoteAgentSessions() ?? [] },
            sendPrompt: { [weak shellView] agentUUID, prompt in
                shellView?.sendRemotePrompt(agentUUID: agentUUID, prompt: prompt) ?? .sessionUnavailable
            },
            liveLayout: { [weak shellView] in shellView?.persistedState() }
        )
        telegramRemoteAccessController = remoteAccess
        shellView.onStuckAgentAlert = { [weak remoteAccess] reason, workspace, columnIndex, column in
            remoteAccess?.handleStuckAgent(
                reason, workspaceTitle: workspace.title, columnIndex: columnIndex, agentUUID: column.agentUUID
            )
        }
        remoteAccess.onStateChange = { [weak self] in
            self?.refreshTelegramSettingsState()
        }
        hooks.onEventReceived = { [weak remoteAccess] event, resolution, outcome in
            ActivityStore.shared.record(
                event,
                workspaceTitle: resolution?.workspace.title ?? event.cwd ?? "External agent",
                columnIndex: resolution?.columnIndex, outcome: outcome
            )
            remoteAccess?.handleAgentEvent(event, resolution: resolution, outcome: outcome)
        }
        hooks.start()
        // Start after the hook backlog drain so events queued while Nirux was
        // closed are recorded locally but never replayed as Telegram alerts.
        remoteAccess.reloadFromPersistence()

        let missionEvents = MissionEventCenter.shared
        missionEvents.onEvent = { [weak shellView] mission, event in
            shellView?.recordMissionActivity(mission, event: event) ?? false
        }
        missionEvents.start()

        // Focus first terminal
        shellView.focusActiveTerminal(in: window)

        // Force all terminal views to re-evaluate focus state.
        // Terminals created before makeFirstResponder never received
        // resignFirstResponder, so they default to "focused" (blinking cursor).
        // Posting didBecomeKeyNotification causes each ghostty surface to
        // check window.firstResponder === self and set focus accordingly.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        NSApp.activate(ignoringOtherApps: true)
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// A running merge queue asks first; the queue stops before its next
    /// command, and a call already sent is waited for.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shell else { return .terminateNow }
        return shell.mergeQueueTerminateReply { quit in
            NSApp.reply(toApplicationShouldTerminate: quit)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Apply hooks still inside the drain debounce (a first prompt just
        // sent) so the saved Claude restore targets are current.
        AgentHookCenter.shared.drain()
        shell?.saveState(snapshot: ProcessSnapshot())
        // A queue's last step is written before the process ends.
        MergeQueueController.waitForFiles()
        keepAwakeController?.shutdown()
        // A claude left running would go on reading, on the user's plan.
        ExplainQueue.shared.cancelAll(waitingUpTo: 2)
        telegramRemoteAccessController?.shutdown()
        NiruxNotifier.shared.updateDockBadge(attentionCount: 0)
        ActivityStore.shared.flush()
        // Every agent goes with its terminal; a restore resumes the session.
        shell?.sessionLedger.closeAllSessions(at: Date().timeIntervalSince1970)
        // Receivers stop waiting on an app that is gone.
        shell?.releaseAllPermissionApprovals()
        AgentHookCenter.shared.approvalChannel().stopListening(for: ProcessInstance.running(pid: getpid()))
        AgentHookCenter.shared.stop()
        MissionEventCenter.shared.stop()
    }

    // MARK: - URL Scheme

    enum WorkspaceAgent: String, CaseIterable {
        case claude, codex
    }

    // MARK: - NSMenuItemValidation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(resumeAllAgents(_:)) {
            return (shell?.deferredAgentCount ?? 0) > 0
        }
        if menuItem.action == #selector(toggleInactiveWorkspaces(_:)) {
            guard let shell else { return false }
            menuItem.state = shell.sidebar.isInactiveSectionCollapsed ? .off : .on
            return shell.sidebar.hasInactiveWorkspaces
        }
        return validateMenuItemForUpdate(menuItem)
    }
}
