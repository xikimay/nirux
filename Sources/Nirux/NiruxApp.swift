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
    var isManualUpdateCheck = false
    var updaterReady = false

    static func main() {
        let app = NSApplication.shared
        let delegate = NiruxApp()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        window.makeKeyAndOrderFront(nil)
        mainWindow = window

        // Restore previous session if available
        shellView.restoreState()

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
                if let branch, let repo {
                    shell?.createWorktreeWorkspace(
                        branch: branch,
                        repoRoot: repo,
                        agent: agent,
                        handoverPath: handover,
                        profileID: profileID
                    )
                }

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
