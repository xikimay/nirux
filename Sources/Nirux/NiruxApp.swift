import AppKit
import GhosttyTerminal
import Sparkle

@main @MainActor
final class NiruxApp: NSObject, NSApplicationDelegate, SPUUpdaterDelegate, NSMenuItemValidation {
    var mainWindow: NSWindow?
    var shell: NiruxShellView?
    var updaterController: SPUStandardUpdaterController?
    var updateDot: NSView?
    var settingsPanel: NSPanel?
    weak var settingsKeepAwakeCheckbox: NSButton?
    weak var settingsLaunchModePopup: NSPopUpButton?
    weak var settingsNoFlickerCheckbox: NSButton?
    weak var settingsCodexLaunchModePopup: NSPopUpButton?
    weak var settingsMissionHandoffsCheckbox: NSButton?
    weak var settingsSidebarApprovalsCheckbox: NSButton?
    weak var settingsStuckAgentPopup: NSPopUpButton?
    weak var settingsTelegramEnabledCheckbox: NSButton?
    weak var settingsTelegramTokenField: NSSecureTextField?
    weak var settingsTelegramCompletionCheckbox: NSButton?
    weak var settingsTelegramAttentionCheckbox: NSButton?
    weak var settingsTelegramStatusLabel: NSTextField?
    weak var settingsTelegramPairButton: NSButton?
    var telegramRemoteAccessController: TelegramRemoteAccessController?
    var keepAwakeController: KeepAwakeController?
    var keepAwakeIndicator: KeepAwakeIndicator?
    /// Keychain access used by the Settings panel; tests stub it.
    var telegramTokenLoader: () throws -> String? = { try TelegramTokenStore.load() }
    var telegramTokenSaver: (String) throws -> Void = { try TelegramTokenStore.save($0) }
    /// Screen height the Settings panel may take; tests stub it.
    var settingsVisibleHeight: @MainActor () -> CGFloat? = { NSScreen.main?.visibleFrame.height }
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
        if args.count >= 3, args[1] == "--hook", let kind = AgentHookEvent.Kind(rawValue: args[2]) {
            let payload = args.count > 3 ? args.last : nil
            exit(AgentHookCLI.run(kind: kind, payload: payload))
        }
        if args.count >= 2, args[1] == "--mission" {
            exit(MissionEventCLI.main(Array(args.dropFirst(2))))
        }

        let app = NSApplication.shared
        let delegate = NiruxApp()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        window.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
        window.minSize = NSSize(width: 600, height: 400)
        window.title = "Nirux"
        window.appearance = NSAppearance(named: .darkAqua)

        let shellView = NiruxShellView(frame: rect)
        shellView.autoresizingMask = [.width, .height]
        window.contentView = shellView
        shell = shellView
        setUpKeepAwake(window: window, shell: shellView)
        setupStatusBarNotices()

        // Native notifications: click focuses the originating workspace/column.
        NiruxNotifier.shared.setup()
        NiruxNotifier.shared.onActivate = { [weak shellView] workspaceID, columnIndex in
            shellView?.focusWorkspace(id: workspaceID, column: columnIndex)
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
        AgentHookInstaller.installAll()
        shellView.refreshOnboardingChecklist()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Apply hooks still inside the drain debounce (a first prompt just
        // sent) so the saved Claude restore targets are current.
        AgentHookCenter.shared.drain()
        shell?.saveState(snapshot: ProcessSnapshot())
        keepAwakeController?.shutdown()
        telegramRemoteAccessController?.shutdown()
        NiruxNotifier.shared.updateDockBadge(attentionCount: 0)
        ActivityStore.shared.flush()
        // Receivers stop waiting on an app that is gone.
        shell?.releaseAllPermissionApprovals()
        AgentHookCenter.shared.approvalChannel().stopListening(for: ProcessInstance.running(pid: getpid()))
        AgentHookCenter.shared.stop()
        MissionEventCenter.shared.stop()
    }

    // MARK: - URL Scheme

    enum WorkspaceAgent: String {
        case claude, codex
    }

    // MARK: - NSMenuItemValidation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleInactiveWorkspaces(_:)) {
            guard let shell else { return false }
            menuItem.state = shell.sidebar.isInactiveSectionCollapsed ? .off : .on
            return shell.sidebar.hasInactiveWorkspaces
        }
        return validateMenuItemForUpdate(menuItem)
    }
}
