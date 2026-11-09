import AppKit
import WebKit
import XCTest
@testable import Nirux

/// Cmd+Arrow in an editor or browser column, through the app's key
/// interceptor and menu bar: it edits the text that has the keyboard,
/// and Control+Cmd+Arrow still navigates from there, as does Cmd+Arrow
/// with the editor's caret already at that edge. A focused editor column
/// has the keyboard, unless an agent's open focused it.
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
            try harness.withApp {
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

    /// Cmd+Left at column 1 and Cmd+Right at the line end leave the editor
    /// for the column beside. Before the edge, they move the caret; with a
    /// selection, held down or with Shift, they stay in the text. With no
    /// workspace above, Cmd+Up on the first line still moves the caret, and
    /// a late edge key never moves the keyboard from where it went.
    func testCommandLeftAndRightLeaveTheEditorAtTheLineEdge() throws {
        try UIFlowHarness.run { harness in
            try harness.withApp {
                let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
                XCTAssertNil(harness.shell.workspaceStore.adjacentWorkspaceIndex(delta: -1), "a workspace above")
                let (editor, webView) = try openEditorWithKeyboard(in: harness)
                let editorIndex = workspace.focusedIndex
                workspace.addColumn()
                harness.shell.relayout(animated: false)
                press(.left, [.command, .control], in: harness)
                XCTAssertEqual(workspace.focusedIndex, editorIndex)
                waitForMonacoText(in: webView, harness: harness)
                moveCaretToTheDocumentStart(in: harness)

                // At column 1, then at the end of "# Flow", then back.
                press(.left, [.command, .shift], in: harness)
                press(.left, [.command], in: harness, isARepeat: true)
                press(.right, [.command], in: harness)
                press(.left, [.command], in: harness)
                press(.right, [.command, .shift], in: harness)
                waitForSelection("# Flow", in: editor, harness: harness)
                XCTAssertEqual(workspace.focusedIndex, editorIndex, "Shift, a held key or a caret before the edge left")
                // The selection ends at the line end.
                press(.right, [.command], in: harness)
                press(.down, [.command, .shift], in: harness)
                waitForSelection("\n\nEdited.\n", in: editor, harness: harness)
                XCTAssertEqual(workspace.focusedIndex, editorIndex, "a selection left")

                press(.up, [.command], in: harness)
                press(.right, [.command], in: harness)
                waitForCaret("1:7", in: webView, harness: harness)
                press(.up, [.command], in: harness)
                waitForCaret("1:1", in: webView, harness: harness)
                XCTAssertEqual(workspace.focusedIndex, editorIndex)

                press(.left, [.command], in: harness)
                harness.waitUntil("the column on the left", timeout: 5) { workspace.focusedIndex == editorIndex - 1 }
                evaluate("window.webkit.messageHandlers.nirux.postMessage({ type: 'textEdgeKey', edge: 'right' }); 0", in: webView, harness: harness)
                XCTAssertEqual(workspace.focusedIndex, editorIndex - 1, "a late edge key moved the keyboard")

                press(.right, [.command], in: harness)
                XCTAssertEqual(workspace.focusedIndex, editorIndex)
                waitForMonacoText(in: webView, harness: harness)
                press(.right, [.command], in: harness)
                press(.right, [.command], in: harness)
                harness.waitUntil("the column on the right", timeout: 5) { workspace.focusedIndex == editorIndex + 1 }

                // An agent's open focuses the editor column, the keyboard
                // stays in the terminal.
                let terminal = harness.window.firstResponder
                harness.shell.openEditorFromURL(try agentOpen(harness.repo + "/README.md", in: workspace))
                XCTAssertEqual(workspace.focusedIndex, editorIndex)
                evaluate("window.webkit.messageHandlers.nirux.postMessage({ type: 'textEdgeKey', edge: 'left' }); 0", in: webView, harness: harness)
                XCTAssertEqual(workspace.focusedIndex, editorIndex, "an edge key navigated without the editor's keyboard")
                XCTAssertIdentical(harness.window.firstResponder, terminal)
            }
        }
    }

    /// Opened at an indented line, as a terminal's file link does, the caret
    /// is at column 1: Cmd+Left goes to the indent, then back to column 1,
    /// and only then leaves the editor.
    func testCommandLeftOnAnIndentedLineGoesToTheIndentFirst() throws {
        try UIFlowHarness.run { harness in
            try harness.withApp {
                let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
                let path = harness.repo + "/indented.txt"
                try "first\n    code();\n".write(toFile: path, atomically: true, encoding: .utf8)
                harness.shell.openInEditorColumn(path: path, line: 2)
                let editorIndex = workspace.focusedIndex
                let editor = try XCTUnwrap(workspace.columns[safe: editorIndex]?.editorColumn)
                let webView = try XCTUnwrap(UIFlowHarness.descendant(of: editor, as: WKWebView.self))
                XCTAssertIdentical(harness.window.firstResponder, webView)
                waitForMonacoText(in: webView, harness: harness)
                waitForCaret("2:1", in: webView, harness: harness)

                press(.left, [.command], in: harness)
                waitForCaret("2:5", in: webView, harness: harness)
                press(.left, [.command], in: harness)
                waitForCaret("2:1", in: webView, harness: harness)
                XCTAssertEqual(workspace.focusedIndex, editorIndex)
                press(.left, [.command], in: harness)
                harness.waitUntil("the column on the left", timeout: 5) { workspace.focusedIndex == editorIndex - 1 }
            }
        }
    }

    /// Cmd+Up on the first line and Cmd+Down on the last switch workspace;
    /// elsewhere they move the caret to the top or bottom of the file, and
    /// in Monaco's suggestion list, through the list.
    func testCommandUpAndDownSwitchWorkspaceFromTheFirstAndLastLine() throws {
        try UIFlowHarness.run { harness in
            try harness.withApp {
                let shell = harness.shell
                let top = try XCTUnwrap(shell.activeWorkspace)
                shell.addWorkspace(title: "middle", cwd: harness.repo)
                let middle = try XCTUnwrap(shell.activeWorkspace)
                let (editor, webView) = try openEditorWithKeyboard(in: harness)
                shell.addWorkspace(title: "bottom", cwd: harness.repo)
                let bottom = try XCTUnwrap(shell.activeWorkspace)
                shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0 === middle }))
                waitForMonacoText(in: webView, harness: harness)
                moveCaretToTheDocumentStart(in: harness)

                press(.down, [.command], in: harness)
                press(.up, [.command, .shift], in: harness)
                waitForSelection("# Flow\n\nEdited.\n", in: editor, harness: harness)
                XCTAssertIdentical(shell.activeWorkspace, middle, "Cmd+Down before the last line switched")
                press(.down, [.command], in: harness)
                waitForCaret("4:1", in: webView, harness: harness)
                evaluate(Self.showTwoSuggestions, in: webView, harness: harness)
                waitForSuggestions(focusedRow: 0, in: webView, harness: harness)
                press(.down, [.command], in: harness)
                waitForSuggestions(focusedRow: 1, in: webView, harness: harness)
                XCTAssertIdentical(shell.activeWorkspace, middle, "Cmd+Down in the suggestion list switched")
                evaluate("\(Self.focusedMonaco).trigger('test', 'hideSuggestWidget', {}); 0", in: webView, harness: harness)
                press(.down, [.command], in: harness)
                harness.waitUntil("the workspace below", timeout: 5) { shell.activeWorkspace === bottom }

                shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0 === middle }))
                waitForMonacoText(in: webView, harness: harness)
                press(.up, [.command], in: harness)
                press(.down, [.command, .shift], in: harness)
                waitForSelection("# Flow\n\nEdited.\n", in: editor, harness: harness)
                XCTAssertIdentical(shell.activeWorkspace, middle, "Cmd+Up after the first line switched")
                press(.up, [.command], in: harness)
                press(.up, [.command], in: harness)
                harness.waitUntil("the workspace above", timeout: 5) { shell.activeWorkspace === top }
            }
        }
    }

    /// The diff hides Monaco: Cmd+Arrow navigates again.
    func testCommandArrowsNavigateFromTheEditorDiff() throws {
        try UIFlowHarness.run { harness in
            try harness.withApp {
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
            try harness.withApp {
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
            try harness.withApp {
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
    /// typing: not even once an earlier open focused the editor column, nor
    /// when a panel closes afterwards, in the workspace in front or in
    /// another one.
    func testAgentOpensLeaveTheKeyboardWhereItWas() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            @MainActor func open(_ file: String) throws {
                shell.openEditorFromURL(try agentOpen(harness.repo + "/" + file, in: workspace))
                XCTAssertIdentical(shell.activeWorkspace, workspace)
                XCTAssertNotNil(workspace.columns[safe: workspace.focusedIndex]?.editorColumn)
            }
            let terminal = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.terminalView)
            harness.window.makeFirstResponder(terminal)
            try open("README.md")
            try open(UIFlowHarness.searchTarget)
            XCTAssertIdentical(harness.window.firstResponder, terminal)
            shell.showCommandPalette()
            shell.commandPalette?.dismiss()
            XCTAssertIdentical(harness.window.firstResponder, terminal, "closing the palette took the keyboard")

            shell.addWorkspace(title: "other", cwd: harness.repo)
            let other = try XCTUnwrap(shell.activeWorkspace?.columns.first?.terminalView)
            XCTAssertIdentical(harness.window.firstResponder, other)
            try open("README.md")
            XCTAssertIdentical(harness.window.firstResponder, other)
        }
    }

    /// A search result or a terminal's file link opens the editor with the
    /// keyboard, whether it adds the column or reuses it, and so does the
    /// palette's Open Editor.
    func testUserOpensGiveTheEditorTheKeyboard() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let terminal = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.terminalView)
            let opens: [(String, () -> Void)] = [
                ("README.md", { shell.openInEditorColumn(path: harness.repo + "/README.md") }),
                (UIFlowHarness.searchTarget, { shell.openInEditorColumn(path: harness.repo + "/" + UIFlowHarness.searchTarget) }),
                ("a new editor", { shell.openEditorColumn() })
            ]
            for (name, open) in opens {
                harness.window.makeFirstResponder(terminal)
                open()
                let editor = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.editorColumn)
                XCTAssertIdentical(
                    harness.window.firstResponder, UIFlowHarness.descendant(of: editor, as: WKWebView.self),
                    "opening \(name) left the keyboard behind"
                )
            }
        }
    }

    /// The user's moves to an editor column give it the keyboard, even to
    /// the one an agent's open focused without it: Cmd+1…9, the sidebar, a
    /// workspace switch, Cmd+W on its neighbour.
    func testUserMovesGiveTheEditorTheKeyboard() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let terminal = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.terminalView)
            harness.window.makeFirstResponder(terminal)
            shell.openEditorFromURL(try agentOpen(harness.repo + "/README.md", in: workspace))
            let editorIndex = workspace.focusedIndex
            let editor = try XCTUnwrap(workspace.columns[safe: editorIndex]?.editorColumn)
            let webView = try XCTUnwrap(UIFlowHarness.descendant(of: editor, as: WKWebView.self))
            XCTAssertIdentical(harness.window.firstResponder, terminal)

            shell.focusColumn(number: editorIndex + 1)
            XCTAssertIdentical(harness.window.firstResponder, webView, "Cmd+\(editorIndex + 1)")
            harness.window.makeFirstResponder(terminal)
            shell.sidebar.onColumnClicked?(shell.activeWSIndex, editorIndex)
            XCTAssertIdentical(harness.window.firstResponder, webView, "the sidebar")

            shell.addWorkspace(title: "other", cwd: harness.repo)
            shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0 === workspace }))
            XCTAssertIdentical(harness.window.firstResponder, webView, "the workspace switch")

            workspace.addColumn()
            shell.relayout(animated: false)
            harness.window.makeFirstResponder(workspace.columns[safe: editorIndex + 1]?.terminalView)
            XCTAssertEqual(workspace.focusedIndex, editorIndex + 1)
            shell.closeActiveColumn()
            harness.waitUntil("the column to close", timeout: 10) { workspace.columns.count == editorIndex + 1 }
            XCTAssertIdentical(harness.window.firstResponder, webView, "Cmd+W")

            // Unless an agent's open focused the editor while the column
            // closed.
            workspace.addColumn()
            shell.relayout(animated: false)
            harness.window.makeFirstResponder(workspace.columns[safe: editorIndex + 1]?.terminalView)
            shell.closeActiveColumn()
            shell.openEditorFromURL(try agentOpen(harness.repo + "/README.md", in: workspace))
            XCTAssertEqual(workspace.focusedIndex, editorIndex)
            harness.waitUntil("the column to close", timeout: 10) { workspace.columns.count == editorIndex + 1 }
            XCTAssertNotIdentical(harness.window.firstResponder, webView, "Cmd+W during an agent's open")
        }
    }

    /// An agent's open in the workspace in front leaves the address bar
    /// being typed in alone.
    func testAgentOpensLeaveTheAddressBarTheKeyboard() throws {
        try UIFlowHarness.run { harness in
            let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
            workspace.addColumn(webViewURL: URL(fileURLWithPath: harness.repo + "/README.md").absoluteString)
            let browser = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.webViewColumn)
            browser.focusAddressBar()
            let fieldEditor = try XCTUnwrap(harness.window.firstResponder as? NSTextView)

            harness.shell.openEditorFromURL(try agentOpen(harness.repo + "/README.md", in: workspace))
            XCTAssertNotNil(workspace.columns[safe: workspace.focusedIndex]?.editorColumn)
            XCTAssertIdentical(harness.window.firstResponder, fieldEditor)
            XCTAssertTrue((fieldEditor.delegate as? NSView)?.isDescendant(of: browser) == true, "another field has the keyboard")
        }
    }

    // MARK: - Helpers

    /// What `nirux://open-editor` asks for when an agent opens `path`.
    private func agentOpen(_ path: String, in workspace: WorkspaceState) throws -> OpenEditorRequest {
        try XCTUnwrap(OpenEditorRequest(
            queryItems: [URLQueryItem(name: "file", value: path), URLQueryItem(name: "workspace", value: workspace.id)],
            canonicalize: { $0 },
            isOpenableFile: { _ in true }
        ))
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

    private func press(_ arrow: Arrow, _ modifiers: NSEvent.ModifierFlags, in harness: UIFlowHarness, isARepeat: Bool = false) {
        // Arrow keys always carry these flags.
        harness.press(
            String(Character(UnicodeScalar(arrow.character)!)), keyCode: arrow.rawValue,
            modifiers.union([.function, .numericPad]), isARepeat: isARepeat
        )
    }

    /// The Monaco editor whose text has the keyboard, in the page's script.
    private static let focusedMonaco = "monaco.editor.getEditors().filter(function (e) { return e.hasTextFocus(); })[0]"

    /// Opens Monaco's suggestion list with two suggestions. The page has no
    /// worker, so its word suggestions never come: a provider for the file's
    /// language answers first.
    private static let showTwoSuggestions = """
        (function () {
            var editor = \(focusedMonaco);
            monaco.languages.registerCompletionItemProvider(editor.getModel().getLanguageId(), {
                provideCompletionItems: function (model, position) {
                    var range = new monaco.Range(position.lineNumber, position.column, position.lineNumber, position.column);
                    return { suggestions: ["alpha", "beta"].map(function (word) {
                        return { label: word, kind: monaco.languages.CompletionItemKind.Text, insertText: word, range: range };
                    }) };
                }
            });
            editor.trigger("test", "editor.action.triggerSuggest", {});
            return 0;
        })()
        """

    /// Runs `script` in the page and waits for it. Messages it posts to the
    /// app arrive first.
    private func evaluate(
        _ script: String, in webView: WKWebView, harness: UIFlowHarness,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let answer = PageAnswer()
        answer.isAsking = true
        webView.evaluateJavaScript(script) { _, _ in
            MainActor.assumeIsolated { answer.isAsking = false }
        }
        harness.waitUntil("the page to run a script", timeout: 10, file: file, line: line) { !answer.isAsking }
    }

    /// Asks the page `script` until it answers what `matches` accepts.
    private func waitForAnswer(
        _ description: String, to script: String, in webView: WKWebView, harness: UIFlowHarness,
        file: StaticString, line: UInt, matches: @escaping (String) -> Bool
    ) {
        let answer = PageAnswer()
        harness.waitUntil(description, timeout: 10, file: file, line: line) {
            if !answer.isAsking {
                answer.isAsking = true
                webView.evaluateJavaScript(script) { result, _ in
                    MainActor.assumeIsolated {
                        answer.latest = result as? String
                        answer.isAsking = false
                    }
                }
            }
            return answer.latest.map(matches) == true
        }
    }

    /// Waits until the page says Monaco's text has the keyboard. After the
    /// keyboard comes back, the web view's input context can still be the
    /// one from before: a key sent then would reach the page ahead of the
    /// focus.
    private func waitForMonacoText(
        in webView: WKWebView, harness: UIFlowHarness, file: StaticString = #filePath, line: UInt = #line
    ) {
        let script = "(\(Self.focusedMonaco)) ? 'focused' : ''"
        waitForAnswer("Monaco to take text", to: script, in: webView, harness: harness, file: file, line: line) {
            $0 == "focused"
        }
    }

    /// Asks the page for Monaco's caret ("line:column") until it is
    /// `expected`: the page handles keys one at a time, after they were sent.
    private func waitForCaret(
        _ expected: String, in webView: WKWebView, harness: UIFlowHarness,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let script = "(function () { var e = \(Self.focusedMonaco); if (!e) return ''; "
            + "var p = e.getPosition(); return p.lineNumber + ':' + p.column; })()"
        waitForAnswer("Monaco's caret at \(expected)", to: script, in: webView, harness: harness, file: file, line: line) {
            $0 == expected
        }
    }

    /// Waits until Monaco's suggestion list shows two suggestions or more,
    /// row `focusedRow` focused.
    private func waitForSuggestions(
        focusedRow: Int, in webView: WKWebView, harness: UIFlowHarness,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let script = "(function () { var list = document.querySelector('.suggest-widget.visible'); if (!list) return ''; "
            + "var focused = list.querySelector('.monaco-list-row.focused'); "
            + "return list.querySelectorAll('.monaco-list-row').length + ':' + (focused ? focused.getAttribute('data-index') : ''); })()"
        waitForAnswer("suggestions with row \(focusedRow) focused", to: script, in: webView, harness: harness, file: file, line: line) {
            let parts = $0.split(separator: ":", omittingEmptySubsequences: false)
            return parts.count == 2 && (Int(parts[0]) ?? 0) >= 2 && parts[1] == "\(focusedRow)"
        }
    }

    private final class PageAnswer {
        var latest: String?
        var isAsking = false
    }

    /// Puts Monaco's caret at the start of README.md wherever it was, without
    /// a key that could leave the editor: Shift+Cmd+Down selects to the end
    /// (or nothing, from there), then Cmd+Up collapses the selection or
    /// moves up from the last line.
    private func moveCaretToTheDocumentStart(in harness: UIFlowHarness) {
        press(.down, [.command, .shift], in: harness)
        press(.up, [.command], in: harness)
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
