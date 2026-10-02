import AppKit
import XCTest
@testable import Nirux

/// A Nirux window on throwaway state, for tests that drive the real UI:
/// the command palette, the sidebar menus and the panels they open. Use it
/// through `UIFlowHarness.run`.
///
/// Nothing a command does may leave the test:
/// - NIRUX_STATE_DIR points at a temporary folder (state, spaces, briefs,
///   URL history), and stays there until the window and everything it
///   deferred are gone;
/// - HOME points at a fake home folder, so the terminals' shells and git
///   read no startup or config file of the user's;
/// - agent launches, the home folder, browser cookies and app-modal alerts
///   go through `ShellSideEffects` doubles that record what they got;
/// - the workspace sits in a temporary git repository with no remote, so
///   git, gh and the worktree clean-up never reach the network.
///
/// Every wait is a bounded spin of the main run loop, never a fixed sleep:
/// work a panel sends off the main thread really runs, so a closure that
/// traps there (as in #46) crashes the test run.
@MainActor
final class UIFlowHarness {
    /// Main checkout: one commit holding README.md and `searchTarget`, plus
    /// an uncommitted change to README.md (the editor diff has something to
    /// show).
    let repo: String
    /// A linked worktree of `repo`, on `worktreeBranch`.
    let worktree: String
    let worktreeBranch = "feat/flow"
    /// Fake home folder: agent skills install here, the checklist reads it,
    /// the shells start with it.
    let home: String
    let stateDirectory: String
    /// Holds every path above, resolved (`/private/var/…`) as a shell
    /// reports its working directory.
    let root: String
    /// A committed file, the only one holding `searchNeedle`.
    static let searchTarget = "docs/search-target.txt"
    static let searchNeedle = "flow-harness-needle"

    let shell: NiruxShellView
    let window: NSWindow

    /// Launch lines typed into terminals, in order.
    private(set) var agentLaunches: [String] = []
    /// `messageText` of every app-modal alert, in order.
    private(set) var alerts: [String] = []
    /// Answers to the next alerts, in order; the first button once empty.
    var alertResponses: [NSApplication.ModalResponse] = []
    /// Browsers the cookie double reports as installed.
    var cookieBrowsers: [CookieImporter.Browser] = []
    /// Browsers the cookie double was asked to import from.
    private(set) var cookieImports: [CookieImporter.Browser] = []

    /// Palette commands and sidebar menu items the current test ran, for
    /// the coverage checks (see UIFlowTestCase).
    static var itemsRun: [UIFlowCoverage.Kind: Set<String>] = [:]

    private let windowsBefore: Set<ObjectIdentifier>
    private var modalWatchdog: Timer?

    /// Runs `body` on a fresh harness, then tears it down. The environment
    /// comes back only once the shell is gone, so nothing it deferred (a
    /// save, a shell start) can reach the real state or home folder.
    static func run(
        file: StaticString = #filePath, line: UInt = #line, _ body: @MainActor (UIFlowHarness) throws -> Void
    ) throws {
        let environment = IsolatedEnvironment()
        defer { environment.restore() }
        weak var released: NiruxShellView?
        // Before the restore, even when `body` throws.
        defer {
            let deadline = Date().addingTimeInterval(10)
            while released != nil, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            XCTAssertNil(released, "the shell outlived its test: work it deferred could reach the real state", file: file, line: line)
            waitForChildProcesses()
        }
        try autoreleasepool {
            let harness = try UIFlowHarness(root: environment.root)
            released = harness.shell
            defer { harness.closeWindows() }
            try body(harness)
        }
    }

    /// Waits (5 s at most) until no process the test started still runs:
    /// a git or gh a background thread is spawning reads the environment,
    /// which must not change under it.
    private static func waitForChildProcesses() {
        let deadline = Date().addingTimeInterval(5)
        while liveChildProcessCount() > 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Children still running: a killed shell nobody reaped is left as a
    /// zombie, which `proc_pidinfo` no longer describes.
    private static func liveChildProcessCount() -> Int {
        var pids = [pid_t](repeating: 0, count: 1024)
        let count = proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(count, 0))).filter { pid in
            var info = proc_bsdinfo()
            return pid > 0 && proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0
        }.count
    }

    private init(root: String) throws {
        self.root = root
        repo = root + "/repo"
        worktree = root + "/repo.feat-flow"
        home = root + "/home"
        stateDirectory = root + "/state"
        try Self.makeRepository(repo, worktree: worktree, branch: worktreeBranch)

        windowsBefore = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        shell.stopHeartbeat()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = shell
        window.orderFront(nil)
        installDoubles()
        installModalWatchdog()

        // The default workspace opens in the real home folder: work in the
        // repository instead.
        let homeWorkspace = shell.workspaces.first
        shell.addWorkspace(title: "repo", cwd: repo)
        shell.closeWorkspace(at: 0)
        waitUntil("the home-folder workspace to close") {
            !self.shell.workspaces.contains { $0 === homeWorkspace }
        }
    }

    /// Dismisses what the test left open and closes the windows it created.
    private func closeWindows() {
        modalWatchdog?.invalidate()
        shell.stopHeartbeat()
        shell.commandPalette?.dismiss()
        shell.searchPanel?.dismiss()
        shell.globalSearchPanel?.dismiss()
        shell.filePickerPanel?.dismiss()
        shell.worktreeCleanupPanel?.dismiss()
        shell.boardSettingsPanel?.dismiss()
        shell.newTaskPanel?.dismiss()
        for other in NSApp.windows where other !== window && !windowsBefore.contains(ObjectIdentifier(other)) {
            if let sheet = other.attachedSheet { other.endSheet(sheet) }
            other.orderOut(nil)
        }
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.close()
        window.contentView = nil
    }

    private func installDoubles() {
        shell.sideEffects.launchAgent = { [weak self] _, command in
            self?.agentLaunches.append(command)
        }
        shell.sideEffects.homeDirectory = { [home] in home }
        shell.sideEffects.cookieBrowsers = { [weak self] in self?.cookieBrowsers ?? [] }
        shell.sideEffects.importCookies = { [weak self] browser in
            self?.cookieImports.append(browser)
            return CookieImporter.ImportResult(imported: 2, failed: 0, browser: browser)
        }
        shell.sideEffects.runModal = { [weak self] alert in
            guard let self else { return .alertFirstButtonReturn }
            alerts.append(alert.messageText)
            return alertResponses.isEmpty ? .alertFirstButtonReturn : alertResponses.removeFirst()
        }
    }

    /// An app-modal window opened without the `runModal` double would wait
    /// for a click forever and hang the CI job: stop it and fail instead.
    /// The timer only fires in the modal run loop mode, so only then.
    private func installModalWatchdog() {
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let modal = NSApp.modalWindow else { return }
                let texts = modal.contentView.map(Self.texts(in:)) ?? []
                XCTFail("an app-modal window bypassed ShellSideEffects.runModal: \(texts)")
                NSApp.stopModal(withCode: .cancel)
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        modalWatchdog = timer
    }

    private static func texts(in view: NSView) -> [String] {
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap(texts(in:))
    }

    // MARK: - Palette

    /// Opens the palette, types `title` into it, selects that row with the
    /// arrow keys and presses Return, as a user would.
    func runPaletteCommand(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        if shell.commandPalette?.isVisible == true { shell.commandPalette?.dismiss() }
        shell.showCommandPalette()
        guard let palette = shell.commandPalette, palette.isVisible, let field = palette.searchField else {
            return XCTFail("the palette didn't open", file: file, line: line)
        }
        type(title, into: field)
        guard let position = palette.filteredActions.firstIndex(where: { $0.title == title }) else {
            return XCTFail("no palette command is titled \(title)", file: file, line: line)
        }
        for _ in 0..<position { press(.down, in: palette.panel) }
        guard palette.filteredActions[safe: palette.selectedIndex]?.title == title else {
            return XCTFail("the arrow keys didn't select \(title)", file: file, line: line)
        }
        press(.returnKey, in: palette.panel)
        // The palette closes, or turns to URL input, once the command ran.
        guard !palette.isVisible || palette.mode == .urlInput else {
            return XCTFail("Return didn't run \(title)", file: file, line: line)
        }
        Self.itemsRun[.paletteCommand, default: []].insert(title)
    }

    /// Every command the palette lists now.
    func paletteCommandTitles() -> [String] {
        if shell.commandPalette?.isVisible == true { shell.commandPalette?.dismiss() }
        shell.showCommandPalette()
        defer { shell.commandPalette?.dismiss() }
        return shell.commandPalette?.actions.map(\.title) ?? []
    }

    // MARK: - Keyboard and fields

    enum Key {
        case returnKey, down

        var code: UInt16 {
            switch self {
            case .returnKey: 0x24
            case .down: 0x7D
            }
        }

        var characters: String {
            switch self {
            case .returnKey: "\r"
            case .down: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
            }
        }
    }

    /// A key press, through the app's event dispatch: the panels read keys
    /// with local event monitors, which run for it.
    func press(_ key: Key, in target: NSWindow?) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: target?.windowNumber ?? 0,
            context: nil,
            characters: key.characters,
            charactersIgnoringModifiers: key.characters,
            isARepeat: false,
            keyCode: key.code
        ) else { return XCTFail("no key event") }
        NSApp.sendEvent(event)
    }

    /// Replaces a field's text and tells its delegate, as typing does.
    func type(_ text: String, into field: NSTextField) {
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    /// Types into a field and presses Return in it (its action).
    func submit(_ text: String, into field: NSTextField, file: StaticString = #filePath, line: UInt = #line) {
        field.stringValue = text
        guard let action = field.action else { return XCTFail("the field has no action", file: file, line: line) }
        NSApp.sendAction(action, to: field.target, from: field)
    }

    /// The text field with this placeholder in a visible window.
    func visibleField(placeholder: String) -> NSTextField? {
        for candidate in NSApp.windows where candidate.isVisible {
            guard let content = candidate.contentView else { continue }
            if let field = Self.descendant(of: content, as: NSTextField.self, where: { $0.placeholderString == placeholder }) {
                return field
            }
        }
        return nil
    }

    /// Waits for a visible field with this placeholder.
    func waitForField(placeholder: String, file: StaticString = #filePath, line: UInt = #line) -> NSTextField? {
        waitUntil("a field “\(placeholder)” on screen", file: file, line: line) {
            self.visibleField(placeholder: placeholder) != nil
        }
        return visibleField(placeholder: placeholder)
    }

    static func descendant<View: NSView>(
        of root: NSView, as type: View.Type, where matches: (View) -> Bool = { _ in true }
    ) -> View? {
        if let view = root as? View, matches(view) { return view }
        for subview in root.subviews {
            if let found = descendant(of: subview, as: type, where: matches) { return found }
        }
        return nil
    }

    static func button(titled title: String, in root: NSView) -> NSButton? {
        descendant(of: root, as: NSButton.self) { $0.title == title }
    }

    /// Runs the item at `path` (titles, through submenus) of `menu`.
    func perform(_ path: [String], in menu: NSMenu, file: StaticString = #filePath, line: UInt = #line) {
        var current = menu
        for (depth, title) in path.enumerated() {
            guard let index = current.items.firstIndex(where: { $0.title == title }) else {
                return XCTFail("no menu item \(path[...depth].joined(separator: " ▸ "))", file: file, line: line)
            }
            let item = current.items[index]
            if depth == path.count - 1 {
                guard item.isEnabled else { return XCTFail("\(title) is disabled", file: file, line: line) }
                current.performActionForItem(at: index)
            } else if let submenu = item.submenu {
                current = submenu
            } else {
                return XCTFail("\(title) has no submenu", file: file, line: line)
            }
        }
        if let first = path.first { Self.itemsRun[.sidebarMenuItem, default: []].insert(first) }
    }

    // MARK: - Waiting

    /// Spins the main run loop until `condition` holds, failing after
    /// `timeout`.
    @discardableResult
    func waitUntil(
        _ description: String,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(description)", file: file, line: line)
                return false
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    // MARK: - Repository

    private static func makeRepository(_ repo: String, worktree: String, branch: String) throws {
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let readme = repo + "/README.md"
        try "# Flow\n".write(toFile: readme, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: repo + "/docs", withIntermediateDirectories: true)
        try "Find \(searchNeedle) here.\n".write(toFile: repo + "/" + searchTarget, atomically: true, encoding: .utf8)
        try git(["init", "-q", "-b", "main"], at: repo)
        try git(["add", "README.md", searchTarget], at: repo)
        try git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", "init"], at: repo)
        try git(["worktree", "add", "-q", "-b", branch, worktree], at: repo)
        try "# Flow\n\nEdited.\n".write(toFile: readme, atomically: true, encoding: .utf8)
    }

    /// Runs git in `directory`, never in a repository a GIT_* variable
    /// points at (`swift test` run from a git hook exports GIT_DIR).
    @discardableResult
    static func git(_ arguments: [String], at directory: String) throws -> String {
        let process = Process()
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
        }
        return text
    }
}

/// The temporary folders a harness works in, and the environment that
/// points at them: NIRUX_STATE_DIR, HOME (the shells' startup files, git's
/// config), and none of the variables that would lead them elsewhere
/// (GIT_DIR and the other GIT_* ones included).
@MainActor
private struct IsolatedEnvironment {
    let root: String
    private let saved: [String: String?]

    init() {
        // Memoized from HOME on first use: let the real one set it.
        _ = PtySession.effectivePath
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-ui-flow-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.path.realPath ?? base.path
        for folder in ["home", "state"] {
            try? FileManager.default.createDirectory(atPath: root + "/" + folder, withIntermediateDirectories: true)
        }
        let environment = ProcessInfo.processInfo.environment
        let cleared = ["ZDOTDIR", "XDG_CONFIG_HOME", "RIPGREP_CONFIG_PATH"]
            + environment.keys.filter { $0.hasPrefix("GIT_") }
        let names = ["NIRUX_STATE_DIR", "HOME"] + cleared
        saved = Dictionary(uniqueKeysWithValues: names.map { ($0, environment[$0]) })
        setenv("NIRUX_STATE_DIR", root + "/state", 1)
        setenv("HOME", root + "/home", 1)
        cleared.forEach { unsetenv($0) }
    }

    func restore() {
        for (name, value) in saved {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
        try? FileManager.default.removeItem(atPath: root)
    }
}
