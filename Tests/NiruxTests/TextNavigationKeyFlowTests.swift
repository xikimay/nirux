import AppKit
import WebKit
import XCTest
@testable import Nirux

/// Cmd+Arrow in an editor or browser column, through the app's key
/// interceptor and menu bar: it edits the text that has the keyboard,
/// and Control+Cmd+Arrow still navigates from there. A focused editor
/// column has the keyboard, unless an agent's open focused it.
@MainActor
final class TextNavigationKeyFlowTests: XCTestCase {
    private enum Arrow: UInt16 {
        case left = 0x7B, right = 0x7C, down = 0x7D, up = 0x7E

        var character: Int {
            switch self {
            case .left: NSLeftArrowFunctionKey
            case .right: NSRightArrowFunctionKey
            case .down: NSDownArrowFunctionKey
            case .up: NSUpArrowFunctionKey
            }
        }
    }

    func testCommandArrowsEditTheEditorText() throws {
        try UIFlowHarness.run { harness in
            try withApp(on: harness) {
                let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
                let (editor, webView) = try openEditorWithKeyboard(in: harness)
                let editorIndex = workspace.focusedIndex

                press(.right, [.command], in: harness)
                press(.left, [.command, .shift], in: harness)
                waitForSelection("# Flow", in: editor, harness: harness)
                press(.down, [.command], in: harness)
                press(.up, [.command, .shift], in: harness)
                waitForSelection("# Flow\n\nEdited.\n", in: editor, harness: harness)

                // Control+Cmd+Arrow navigates from the text, and back: the
                // editor column takes the keyboard as it gets the focus.
                press(.left, [.command, .control], in: harness)
                XCTAssertEqual(workspace.focusedIndex, editorIndex - 1)
                press(.right, [.command, .control], in: harness)
                XCTAssertEqual(workspace.focusedIndex, editorIndex)
                XCTAssertIdentical(harness.window.firstResponder, webView)
            }
        }
    }

    /// The diff hides Monaco: Cmd+Arrow navigates again.
    func testCommandArrowsNavigateFromTheEditorDiff() throws {
        try UIFlowHarness.run { harness in
            try withApp(on: harness) {
                let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
                let (editor, webView) = try openEditorWithKeyboard(in: harness)
                let editorIndex = workspace.focusedIndex
                harness.shell.toggleEditorDiff()
                harness.waitUntil("the diff of README.md") { editor.diffActivePath == harness.repo + "/README.md" }
                harness.waitUntil("the diff to hide Monaco's text", timeout: 10) { webView.inputContext == nil }

                press(.left, [.command], in: harness)
                XCTAssertEqual(workspace.focusedIndex, editorIndex - 1)
            }
        }
    }

    func testCommandArrowsEditTheAddressBar() throws {
        try UIFlowHarness.run { harness in
            try withApp(on: harness) {
                let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
                let page = URL(fileURLWithPath: harness.repo + "/README.md").absoluteString
                workspace.addColumn(webViewURL: page)
                let browserIndex = workspace.focusedIndex
                let browser = try XCTUnwrap(workspace.columns[safe: browserIndex]?.webViewColumn)
                browser.focusAddressBar()
                let fieldEditor = try XCTUnwrap(harness.window.firstResponder as? NSTextView)
                let length = (fieldEditor.string as NSString).length
                XCTAssertGreaterThan(length, 0)
                fieldEditor.setSelectedRange(NSRange(location: length, length: 0))

                press(.left, [.command], in: harness)
                XCTAssertEqual(workspace.focusedIndex, browserIndex)
                XCTAssertEqual(fieldEditor.selectedRange(), NSRange(location: 0, length: 0))
                press(.right, [.command, .shift], in: harness)
                XCTAssertEqual(fieldEditor.selectedRange(), NSRange(location: 0, length: length))
            }
        }
    }

    /// Outside text, Cmd+Arrow keeps navigating, even where WebKit would
    /// take it: on a page that scrolls, Cmd+Down switches workspace.
    func testCommandArrowsNavigateOutsideText() throws {
        try UIFlowHarness.run { harness in
            try withApp(on: harness) {
                let shell = harness.shell
                let workspace = try XCTUnwrap(shell.activeWorkspace)
                let page = harness.repo + "/long.html"
                try String(repeating: "<p>Line</p>\n", count: 400).write(toFile: page, atomically: true, encoding: .utf8)
                workspace.addColumn(webViewURL: URL(fileURLWithPath: page).absoluteString)
                let webView = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.webViewColumn?.webView)
                harness.waitUntil("the page to load") { webView.url != nil && !webView.isLoading }
                shell.addWorkspace(title: "below", cwd: harness.repo)
                let below = try XCTUnwrap(shell.activeWorkspace)
                shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0 === workspace }))
                harness.window.makeFirstResponder(webView)
                XCTAssertIdentical(shell.activeWorkspace, workspace)
                XCTAssertNil(webView.inputContext, "the page has text with the keyboard")

                press(.down, [.command], in: harness)
                harness.waitUntil("the workspace below", timeout: 5) { shell.activeWorkspace === below }
            }
        }
    }

    /// An agent's open never takes the keyboard from where the user may be
    /// typing, not even once an earlier open focused the editor column, in
    /// the workspace in front or in another one.
    func testAgentOpensLeaveTheKeyboardWhereItWas() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            @MainActor func open(_ file: String) throws {
                shell.openEditorFromURL(try XCTUnwrap(OpenEditorRequest(
                    queryItems: [
                        URLQueryItem(name: "file", value: harness.repo + "/" + file),
                        URLQueryItem(name: "workspace", value: workspace.id)
                    ],
                    canonicalize: { $0 },
                    isOpenableFile: { _ in true }
                )))
                XCTAssertIdentical(shell.activeWorkspace, workspace)
                XCTAssertNotNil(workspace.columns[safe: workspace.focusedIndex]?.editorColumn)
            }
            let terminal = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.terminalView)
            harness.window.makeFirstResponder(terminal)
            try open("README.md")
            try open(UIFlowHarness.searchTarget)
            XCTAssertIdentical(harness.window.firstResponder, terminal)

            shell.addWorkspace(title: "other", cwd: harness.repo)
            XCTAssertNotIdentical(shell.activeWorkspace, workspace)
            try open("README.md")
            XCTAssertFalse(harness.window.firstResponder is WKWebView, "the editor took the keyboard")
        }
    }

    /// A search result or a terminal's file link opens the editor with the
    /// keyboard, whether it adds the column or reuses it.
    func testUserOpensGiveTheEditorTheKeyboard() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let terminal = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.terminalView)
            for file in ["README.md", UIFlowHarness.searchTarget] {
                harness.window.makeFirstResponder(terminal)
                shell.openInEditorColumn(path: harness.repo + "/" + file)
                let editor = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.editorColumn)
                XCTAssertIdentical(
                    harness.window.firstResponder, UIFlowHarness.descendant(of: editor, as: WKWebView.self),
                    "opening \(file) left the keyboard behind"
                )
            }
        }
    }

    // MARK: - Helpers

    /// Runs `body` with the app's key interceptor and menu bar on the
    /// harness window, as `applicationDidFinishLaunching` sets them up.
    private func withApp(on harness: UIFlowHarness, _ body: () throws -> Void) throws {
        let app = NiruxApp()
        app.shell = harness.shell
        app.mainWindow = harness.window
        let previousMenu = NSApp.mainMenu
        let previousDelegate = NSApp.delegate
        NSApp.mainMenu = app.makeMainMenu()
        // Menu items without a target reach the app delegate.
        NSApp.delegate = app
        let monitors = app.setupKeyInterceptor()
        defer {
            monitors.forEach(NSEvent.removeMonitor)
            NSApp.delegate = previousDelegate
            NSApp.mainMenu = previousMenu
        }
        try body()
    }

    /// Opens README.md in a new editor column, its Monaco with the keyboard.
    private func openEditorWithKeyboard(in harness: UIFlowHarness) throws -> (EditorColumn, WKWebView) {
        let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
        harness.shell.openEditorColumn()
        let editor = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.editorColumn)
        harness.waitUntil("the editor to open README.md") { editor.activePath == harness.repo + "/README.md" }
        // A click in Monaco gives it the keyboard.
        let webView = try XCTUnwrap(UIFlowHarness.descendant(of: editor, as: WKWebView.self))
        harness.window.makeFirstResponder(webView)
        harness.waitUntil("Monaco to take text") { webView.inputContext != nil }
        return (editor, webView)
    }

    /// A key press, through the app's event dispatch and so its key
    /// interceptor. The test process never has a key window: a key the
    /// interceptor returns to AppKit reaches the menu, not the window's
    /// views.
    private func press(_ arrow: Arrow, _ modifiers: NSEvent.ModifierFlags, in harness: UIFlowHarness) {
        let characters = String(Character(UnicodeScalar(arrow.character)!))
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            // Arrow keys always carry these flags.
            modifierFlags: modifiers.union([.function, .numericPad]),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: arrow.rawValue
        ) else { return XCTFail("no key event") }
        NSApp.sendEvent(event)
    }

    /// Asks Monaco for its selection until it is `expected`: the page
    /// handles keys one at a time, after they were sent.
    private func waitForSelection(
        _ expected: String, in editor: EditorColumn, harness: UIFlowHarness,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var latest: String?
        var asking = false
        harness.waitUntil("Monaco to select \(expected.debugDescription)", timeout: 10, file: file, line: line) {
            if !asking {
                asking = true
                editor.requestSelection { selection in
                    latest = selection?.text
                    asking = false
                }
            }
            return latest == expected
        }
    }
}
