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
    weak var settingsLaunchModePopup: NSPopUpButton?
    weak var settingsNoFlickerCheckbox: NSButton?
    weak var settingsCodexLaunchModePopup: NSPopUpButton?
    weak var settingsMissionHandoffsCheckbox: NSButton?
    var isManualUpdateCheck = false
    var updaterReady = false

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
            guard args.count >= 3 else { exit(2) }
            let arguments = Array(args.dropFirst(3))
            switch args[2] {
            case "ask": exit(MissionEventCLI.ask(arguments: arguments))
            case "receive": exit(MissionEventCLI.receive(arguments: arguments))
            case "reply": exit(MissionEventCLI.reply(arguments: arguments))
            default:
                guard let kind = MissionEvent.Kind(rawValue: args[2]) else { exit(2) }
                exit(MissionEventCLI.run(kind: kind, arguments: arguments))
            }
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

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let rect = NSRect(x: screen.origin.x + 50, y: screen.origin.y + 50,
                          width: screen.width - 100, height: screen.height - 100)

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
        setupUpdater()

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
        AgentHookInstaller.installAll()
        ActivityStore.shared.load()
        MissionStore.shared.load()
        ActivityStore.shared.onChange = { [weak shellView] in
            shellView?.refreshActivitySidebar()
        }
        shellView.refreshActivitySidebar()
        let hooks = AgentHookCenter.shared
        hooks.resolver = { [weak shellView] uuid in
            shellView?.resolveAgentColumn(uuid: uuid)
        }
        hooks.onEventsApplied = { [weak shellView] events in
            shellView?.applyAgentHookEvents(events)
        }
        hooks.start()

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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        shell?.saveState(snapshot: ProcessSnapshot())
        NiruxNotifier.shared.updateDockBadge(attentionCount: 0)
        ActivityStore.shared.flush()
        AgentHookCenter.shared.stop()
        MissionEventCenter.shared.stop()
    }

    // MARK: - URL Scheme

    enum WorkspaceAgent: String {
        case claude, codex
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "nirux" else { continue }
            let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            let profileID = workspaceProfileID(from: params)
            switch url.host {

            // nirux://new-workspace?cwd=...&title=...&agent=claude|codex&profile=...
            case "new-workspace":
                let cwd = params?.first(where: { $0.name == "cwd" })?.value
                let title = params?.first(where: { $0.name == "title" })?.value
                let agent = params?.first(where: { $0.name == "agent" })?.value
                    .flatMap { WorkspaceAgent(rawValue: $0) }
                shell?.addWorkspace(title: title, cwd: cwd, agent: agent, profileID: profileID)

            // nirux://new-worktree?branch=...&repo=...&agent=claude|codex&handover=/tmp/file.md&profile=...
            case "new-worktree":
                let branch = params?.first(where: { $0.name == "branch" })?.value
                let repo = params?.first(where: { $0.name == "repo" })?.value
                let agent = params?.first(where: { $0.name == "agent" })?.value
                    .flatMap { WorkspaceAgent(rawValue: $0) }
                let handover = params?.first(where: { $0.name == "handover" })?.value
                let parentWorkspaceID = params?.first(where: { $0.name == "parentWorkspace" })?.value
                let parentAgentUUID = params?.first(where: { $0.name == "parentAgent" })?.value
                if let branch, let repo {
                    shell?.createWorktreeWorkspace(
                        branch: branch,
                        repoRoot: repo,
                        agent: agent,
                        handoverPath: handover,
                        profileID: profileID,
                        parentWorkspaceID: parentWorkspaceID,
                        parentAgentUUID: parentAgentUUID
                    )
                }

            // nirux://open-editor?file=<absolute path>&line=42&endLine=57&workspace=<id>
            // Validation stats (and prefix-reads) the file, which can block
            // on a dead network mount — run it off the main actor, then hop
            // back. Activation is gated on acceptance so a rejected request
            // can't be used to yank Nirux frontmost.
            case "open-editor":
                let urlString = url.absoluteString
                Task { [weak self] in
                    let request = await Task.detached {
                        OpenEditorRequest(queryItems: URLComponents(string: urlString)?.queryItems)
                    }.value
                    guard let request else {
                        NSLog("[OpenEditor] rejected open-editor URL (missing/non-regular/oversized/binary file?)")
                        return
                    }
                    guard let self else { return }
                    self.shell?.openEditorFromURL(request)
                    NSApp.activate(ignoringOtherApps: true)
                    self.mainWindow?.makeKeyAndOrderFront(nil)
                }
                continue

            default:
                break
            }
            NSApp.activate(ignoringOtherApps: true)
            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func workspaceProfileID(from queryItems: [URLQueryItem]?) -> String? {
        queryItems?.first(where: { ["profile", "profileID", "space"].contains($0.name) })?.value
    }

    // MARK: - NSMenuItemValidation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validateMenuItemForUpdate(menuItem)
    }
}
