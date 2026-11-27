import AppKit
import WebKit
import XCTest
@testable import Nirux

/// Reading modes (EditorColumn, bridge.js): a Markdown file reads rendered in
/// the front editor and as source in an editor of the row, its header's
/// toggle switching; a draft reads as source, wrapped, with Copy Draft.
@MainActor
final class EditorReadingModeFlowTests: XCTestCase {
    /// Opened in the front editor, a Markdown file shows rendered, the
    /// reading view taking the keyboard with the column, its table drawn,
    /// only its web link live, and drawn again when the file changes on
    /// disk. ⌘S and ⌘P (here on a Russian layout, which types no Latin
    /// letter) do what they do in Monaco, Esc first clears a
    /// selection, and Send Selection finds nothing in it (the hidden
    /// source's selection isn't what the user sees). ⌘F there shows the
    /// source with Monaco's find, and the toggle
    /// brings the rendered text back. A diff ends the rendering, its tab
    /// showing the source after it, and so does an open at a line, of a new
    /// tab or of one rendered.
    func testMarkdownReadsRenderedInTheFrontEditor() throws {
        try UIFlowHarness.run { harness in
            let notes = harness.repo + "/notes.md"
            try "# Notes\n\n[site](https://example.com/a) and [local](file:///etc/hosts)\n\n| a | b |\n|---|--:|\n| 1 | 2 |\n"
                .write(toFile: notes, atomically: true, encoding: .utf8)
            var opened: [URL] = []
            harness.shell.sideEffects.openURL = { opened.append($0) }
            let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
            harness.shell.openInEditorColumn(path: notes, takeFocus: false)
            let editor = try XCTUnwrap(workspace.front?.editorColumn)
            let webView = try XCTUnwrap(UIFlowHarness.descendant(of: editor, as: WKWebView.self))
            waitForView("rendered:Notes", in: webView)
            harness.shell.focusColumnByIndex(try XCTUnwrap(workspace.frontIndex))
            waitForView("rendered:Notes:focused", in: webView)
            try String(contentsOfFile: notes, encoding: .utf8).replacingOccurrences(of: "# Notes", with: "# Rewritten")
                .write(toFile: notes, atomically: true, encoding: .utf8)
            waitForView("rendered:Rewritten:focused", in: webView)
            UIFlowHarness.run("(function () { var m = \(Self.mainEditor).getModel(); m.setValue(m.getValue() + '\\nSaved.\\n'); })()", in: webView)
            harness.waitUntil("the edit") { editor.unsavedPaths == [notes] }
            UIFlowHarness.run(Self.command("ы", code: "KeyS"), in: webView)
            harness.waitUntil("⌘S to save it") {
                editor.unsavedPaths.isEmpty && (try? String(contentsOfFile: notes, encoding: .utf8))?.hasSuffix("Saved.\n") == true
            }
            UIFlowHarness.run("\(Self.mainEditor).setSelection(new monaco.Selection(1, 1, 1, 5))", in: webView)
            var selection: EditorColumn.Selection?
            var answered = false
            editor.requestSelection {
                selection = $0
                answered = true
            }
            harness.waitUntil("the selection's answer") { answered }
            XCTAssertNil(selection)
            var pickerAsked = false
            editor.onFilePickerRequest = { _ in pickerAsked = true }
            UIFlowHarness.run(Self.command("з", code: "KeyP"), in: webView)
            XCTAssertTrue(pickerAsked)
            UIFlowHarness.run("getSelection().selectAllChildren(document.querySelector('#markdown-view h1')); "
                + "document.activeElement.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }))", in: webView)
            XCTAssertTrue(workspace.isFrontShown, "Esc on a selection sent the front editor back")
            UIFlowHarness.waitForAnswer("the selection cleared", to: "getSelection().isCollapsed ? 'yes' : 'no'", in: webView) { $0 == "yes" }
            XCTAssertEqual(editor.header.trailingButtons, [editor.renderButton, editor.diffButton, editor.searchButton])
            XCTAssertEqual(editor.renderButton.toolTip, "Show Source")
            UIFlowHarness.waitForAnswer("the table and the links", to: Self.drawn, in: webView) { $0 == "2:right:a:span" }

            UIFlowHarness.run("document.querySelector('#markdown-view a').click()", in: webView)
            harness.waitUntil("the link to open") { opened.map(\.absoluteString) == ["https://example.com/a"] }

            UIFlowHarness.run(Self.command("f", code: "KeyF"), in: webView)
            waitForView("source:# Rewritten:find", in: webView)
            XCTAssertEqual(editor.renderButton.toolTip, "Show Rendered")

            editor.renderButton.performClick(nil)
            waitForView("rendered:Rewritten:focused", in: webView)

            let readme = harness.repo + "/README.md"
            harness.shell.openInEditorColumn(path: readme)
            waitForView("rendered:Flow:focused", in: webView)
            editor.toggleDiff()
            harness.waitUntil("the diff of README.md") { editor.diffActivePath == readme }
            editor.toggleDiff()
            // Monaco's find, opened on the other tab, may still show.
            UIFlowHarness.waitForAnswer("README.md's source", to: Self.shownView, in: webView) { $0.hasPrefix("source:# Flow") }
            XCTAssertEqual(editor.renderButton.toolTip, "Show Rendered")

            harness.shell.openInEditorColumn(path: notes, line: 3)
            UIFlowHarness.waitForAnswer("notes.md's source", to: Self.shownView, in: webView) { $0.hasPrefix("source:# Rewritten") }
            let more = harness.repo + "/more.md"
            try "# More\n\nText.\n".write(toFile: more, atomically: true, encoding: .utf8)
            harness.shell.openInEditorColumn(path: more, line: 3)
            UIFlowHarness.waitForAnswer("more.md's source", to: Self.shownView, in: webView) { $0.hasPrefix("source:# More") }
            XCTAssertEqual(editor.renderedPaths, [])
        }
    }

    /// In an editor of the row, the same kind of file opens as source, its
    /// toggle offering the rendered text.
    func testMarkdownOpensAsSourceInARowEditor() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            workspace.addEditorColumn(workspaceCwd: harness.repo)
            let editor = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.editorColumn)
            shell.wireEditor(editor)
            shell.relayout(animated: false)
            shell.openInEditorColumn(path: harness.repo + "/README.md")
            XCTAssertNil(workspace.front)
            let webView = try XCTUnwrap(UIFlowHarness.descendant(of: editor, as: WKWebView.self))
            waitForView("source:# Flow", in: webView)
            XCTAssertEqual(editor.renderButton.toolTip, "Show Rendered")
            XCTAssertTrue(editor.header.trailingButtons.contains(editor.renderButton))
        }
    }

    /// A draft, in the folder the nirux-draft skill makes in the temporary
    /// directory, reads as source even in the front editor, wrapped and
    /// without line numbers; Copy Draft puts its text, unsaved edits
    /// included, on the pasteboard, from its button or ⋯ (where a narrow
    /// header has no room for it). A diff over it follows Toggle Word Wrap,
    /// as another tab does, which numbers its lines.
    func testDraftWrapsAndCopiesItsText() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-draft-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try UIFlowHarness.run { harness in
            let draft = folder + "/reply.md"
            try "# Reply\n\nFirst.\n".write(toFile: draft, atomically: true, encoding: .utf8)
            harness.shell.openInEditorColumn(path: draft)
            let editor = try XCTUnwrap(harness.shell.activeWorkspace?.front?.editorColumn)
            editor.pasteboard = NSPasteboard.withUniqueName()
            let webView = try XCTUnwrap(UIFlowHarness.descendant(of: editor, as: WKWebView.self))
            waitForView("source:# Reply", in: webView)
            XCTAssertTrue(editor.header.accessories.contains { $0 === editor.copyDraftButton })
            XCTAssertTrue(editor.header.currentMenu().items.contains { $0.title == "Copy Draft" })
            XCTAssertFalse(editor.header.trailingButtons.contains(editor.renderButton))
            UIFlowHarness.waitForAnswer("a wrapped draft", to: Self.options, in: webView) { $0 == "on:off" }

            UIFlowHarness.run("\(Self.mainEditor).getModel().setValue('# Reply\\n\\nEdited.\\n')", in: webView)
            editor.copyDraftButton.performClick(nil)
            harness.waitUntil("the draft on the pasteboard") { editor.pasteboard.string(forType: .string) == "# Reply\n\nEdited.\n" }
            XCTAssertEqual(editor.copyDraftButton.title, "Copied ✓")

            // Changed on disk under the edit: Compare shows a diff over it.
            try "# Reply\n\nBy an agent.\n".write(toFile: draft, atomically: true, encoding: .utf8)
            let banner = try XCTUnwrap(UIFlowHarness.descendant(of: editor, as: EditorConflictBanner.self))
            harness.waitUntil("the conflict") { !banner.isHidden }
            try XCTUnwrap(UIFlowHarness.button(titled: "Compare", in: banner)).performClick(nil)
            UIFlowHarness.waitForAnswer("the diff over the draft", to: Self.diffWrap, in: webView) { $0 == "off" }
            editor.toggleWordWrap()
            UIFlowHarness.waitForAnswer("the diff to wrap", to: Self.diffWrap, in: webView) { $0 == "on" }

            harness.shell.openInEditorColumn(path: harness.repo + "/" + UIFlowHarness.searchTarget)
            UIFlowHarness.waitForAnswer("the wrap toggled, with line numbers", to: Self.options, in: webView) { $0 == "on:on" }
            XCTAssertTrue(editor.header.accessories.isEmpty)
            XCTAssertFalse(editor.header.currentMenu().items.contains { $0.title == "Copy Draft" })
        }
    }

    /// One edit that takes lines out above the shown ones and adds one below
    /// them (Replace All, several carets) is reported, the lines moving up;
    /// Enter inside the last of them ends them.
    func testShownLinesUnderEditsAboveAndBelow() throws {
        try UIFlowHarness.run { harness in
            let sixty = harness.repo + "/sixty.txt"
            try (1...60).map { "line \($0)\n" }.joined().write(toFile: sixty, atomically: true, encoding: .utf8)
            harness.shell.openInEditorColumn(path: sixty, line: 40, endLine: 52, takeFocus: false)
            let editor = try XCTUnwrap(harness.shell.activeWorkspace?.front?.editorColumn)
            let webView = try XCTUnwrap(UIFlowHarness.descendant(of: editor, as: WKWebView.self))
            UIFlowHarness.waitForAnswer("the page to show the lines", to: Self.shownRange, in: webView) { $0.hasPrefix("40-52|") }
            UIFlowHarness.run("""
                (function () {
                  var m = \(Self.mainEditor).getModel();
                  var end = m.getLineMaxColumn(52);
                  m.pushEditOperations([], [
                    { range: new monaco.Range(1, 1, 21, 1), text: '' },
                    { range: new monaco.Range(52, end, 52, end), text: '\\n' }
                  ], function () { return null; });
                })()
                """, in: webView)
            harness.waitUntil("the edit reported") { editor.unsavedPaths == [sixty] }
            UIFlowHarness.waitForAnswer("the lines moved up", to: Self.shownRange, in: webView) { $0.hasPrefix("20-32|") }
            UIFlowHarness.run("\(Self.mainEditor).getModel().applyEdits([{ range: new monaco.Range(32, 3, 32, 3), text: '\\n' }])", in: webView)
            UIFlowHarness.waitForAnswer("the lines ended", to: Self.shownRange, in: webView) { $0.hasPrefix("none|") }
        }
    }

    /// A draft is a file in a nirux-draft- folder in a temporary directory
    /// or one inside it (a sandboxed agent's $TMPDIR), whichever link its
    /// path goes through, /tmp and /private/tmp alike; one elsewhere isn't.
    func testDraftIsInTheSkillsFolderInATemporaryDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let link = root + "-link"
        let tmp = "/private/tmp/nirux-draft-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/nirux-draft-Ab12", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/claude-504/nirux-draft-Cd34", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: tmp + "/nirux-draft-Ef56", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: root)
        defer {
            try? FileManager.default.removeItem(atPath: link)
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: tmp)
        }
        XCTAssertTrue(EditorColumn.isDraft(link + "/nirux-draft-Ab12/reply.md", temporaryDirectories: [root]))
        XCTAssertTrue(EditorColumn.isDraft(root + "/claude-504/nirux-draft-Cd34/reply.md", temporaryDirectories: [root]), "a sandbox's")
        XCTAssertTrue(EditorColumn.isDraft(tmp + "/nirux-draft-Ef56/reply.md", temporaryDirectories: ["/tmp"]), "/private/tmp")
        XCTAssertFalse(EditorColumn.isDraft(root + "-elsewhere/repo/nirux-draft-notes/plan.md", temporaryDirectories: [root]))
        XCTAssertFalse(EditorColumn.isDraft(root + "/drafts/reply.md", temporaryDirectories: [root]))
    }

    /// An open's range (nirux-show-code) is highlighted, not selected: the
    /// caret at its start, three lines above it in view, no sticky scroll
    /// over them, and the header names its lines, where they are. The file
    /// read again from disk keeps them and the user's place; Esc with
    /// nothing selected sends the front editor back and keeps them. An edit
    /// above moves them, one in them ends them, and so does the next open in
    /// the tab; lines asked past the end come back as asked once the file
    /// grows; an open at a line leaves a git diff to show its source,
    /// leaving the keyboard where it was. The line just above them taken
    /// out or added doesn't end them (Backspace at their start does), and a
    /// reload after an edit moved them
    /// keeps them where they moved.
    func testShownRangeIsHighlightedWithItsContext() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let long = harness.repo + "/long.txt"
            try (1...200).map { "line \($0)\n" }.joined().write(toFile: long, atomically: true, encoding: .utf8)
            shell.openInEditorColumn(path: long, line: 40, endLine: 52, takeFocus: false)
            let editor = try XCTUnwrap(workspace.front?.editorColumn)
            let webView = try XCTUnwrap(UIFlowHarness.descendant(of: editor, as: WKWebView.self))
            waitForRange("40-52|caret 40:1|context|flat", in: webView)
            XCTAssertEqual(editor.header.context, "Lines 40–52")
            try rewrite(long, with: "row", in: webView)
            waitForRange("40-52|caret 40:1|context|flat", in: webView)
            XCTAssertEqual(editor.header.context, "Lines 40–52")

            UIFlowHarness.run("document.body.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }))", in: webView)
            harness.waitUntil("the front editor to go back") { !workspace.isFrontShown }
            UIFlowHarness.run("var e = \(Self.mainEditor); e.setPosition({ lineNumber: 150, column: 1 }); e.setScrollTop(e.getTopForLineNumber(147))", in: webView)
            try rewrite(long, with: "item", in: webView)
            waitForRange("40-52|caret 150:1|context|flat", in: webView)

            UIFlowHarness.run("\(Self.mainEditor).getModel().applyEdits([{ range: new monaco.Range(30, 1, 36, 1), text: '' }])", in: webView)
            UIFlowHarness.waitForAnswer("the lines moved up", to: Self.shownRange, in: webView) { $0.hasPrefix("34-46|") }
            harness.waitUntil("the header to follow them") { editor.header.context == "Lines 34–46" }
            // The line just above them taken out: they move, as they were.
            UIFlowHarness.run("\(Self.mainEditor).getModel().applyEdits([{ range: new monaco.Range(33, 1, 34, 1), text: '' }])", in: webView)
            UIFlowHarness.waitForAnswer("the lines moved up again", to: Self.shownRange, in: webView) { $0.hasPrefix("33-45|") }
            harness.waitUntil("the header to follow them again") { editor.header.context == "Lines 33–45" }
            // A line added just above them (Enter at the caret): they move down, as they were.
            UIFlowHarness.run("\(Self.mainEditor).getModel().applyEdits([{ range: new monaco.Range(33, 1, 33, 1), text: '\\n' }])", in: webView)
            UIFlowHarness.waitForAnswer("the lines moved down", to: Self.shownRange, in: webView) { $0.hasPrefix("34-46|") }
            harness.waitUntil("the header to follow them down") { editor.header.context == "Lines 34–46" }
            // A line added below them (Enter at the end of the last): they stay.
            UIFlowHarness.run("var m = \(Self.mainEditor).getModel(); m.applyEdits([{ range: new monaco.Range(46, m.getLineMaxColumn(46), 46, m.getLineMaxColumn(46)), text: '\\n' }])", in: webView)
            UIFlowHarness.waitForAnswer("the line added", to: "String(\(Self.mainEditor).getModel().getLineCount())", in: webView) { $0 == "196" }
            UIFlowHarness.waitForAnswer("the lines still shown", to: Self.shownRange, in: webView) { $0.hasPrefix("34-46|") }
            XCTAssertEqual(editor.header.context, "Lines 34–46")
            // Saved, then written again on disk: still where they moved.
            editor.saveAll()
            harness.waitUntil("the edits saved") { editor.unsavedPaths.isEmpty }
            try rewrite(long, with: "again", in: webView)
            UIFlowHarness.waitForAnswer("the moved lines kept", to: Self.shownRange, in: webView) { $0.hasPrefix("34-46|") }
            XCTAssertEqual(editor.header.context, "Lines 34–46")
            UIFlowHarness.run("\(Self.mainEditor).getModel().applyEdits([{ range: new monaco.Range(40, 1, 40, 1), text: 'x' }])", in: webView)
            UIFlowHarness.waitForAnswer("the edit to end the lines", to: Self.shownRange, in: webView) { $0.hasPrefix("none|") && $0.hasSuffix("|sticky") }
            harness.waitUntil("the header's folder again") { editor.header.context == "" }

            shell.openInEditorColumn(path: long, line: 60, endLine: 60, takeFocus: false)
            waitForRange("60-60|caret 60:1|context|flat", in: webView)
            XCTAssertEqual(editor.header.context, "Line 60")
            // Backspace at its start merges it into the line above: an edit in it.
            UIFlowHarness.run("var m = \(Self.mainEditor).getModel(); m.applyEdits([{ range: new monaco.Range(59, m.getLineMaxColumn(59), 60, 1), text: '' }])", in: webView)
            UIFlowHarness.waitForAnswer("Backspace to end the line", to: Self.shownRange, in: webView) { $0.hasPrefix("none|") }
            harness.waitUntil("the header's folder after Backspace") { editor.header.context == "" }
            shell.openInEditorColumn(path: long, line: 70, endLine: 72, takeFocus: false)
            waitForRange("70-72|caret 70:1|context|flat", in: webView)
            XCTAssertEqual(editor.header.context, "Lines 70–72")
            // Ending before it starts: no range, here or in the header.
            shell.openInEditorColumn(path: long, line: 300, endLine: 250, takeFocus: false)
            UIFlowHarness.waitForAnswer("no lines shown", to: Self.shownRange, in: webView) { $0.hasPrefix("none|") }
            XCTAssertEqual(editor.header.context, "")
            shell.openInEditorColumn(path: long, line: 70, endLine: 72, takeFocus: false)
            waitForRange("70-72|caret 70:1|context|flat", in: webView)
            shell.openInEditorColumn(path: long, takeFocus: false)
            UIFlowHarness.waitForAnswer("the next open to end the lines", to: Self.shownRange, in: webView) { $0.hasPrefix("none|") && $0.hasSuffix("|sticky") }
            XCTAssertEqual(editor.header.context, "")

            // Asked past its end, then written longer: the lines as asked.
            let short = harness.repo + "/short.txt"
            try (1...20).map { "line \($0)\n" }.joined().write(toFile: short, atomically: true, encoding: .utf8)
            shell.openInEditorColumn(path: short, line: 30, endLine: 32, takeFocus: false)
            UIFlowHarness.waitForAnswer("its last line shown", to: Self.shownRange, in: webView) { $0.hasPrefix("21-21|") }
            harness.waitUntil("the header to name it") { editor.header.context == "Line 21" }
            try rewrite(short, with: "longer", in: webView)
            // The caret where it was put: it goes to them, with their context.
            waitForRange("30-32|caret 30:1|context|flat", in: webView)
            harness.waitUntil("the header to name them") { editor.header.context == "Lines 30–32" }

            let readme = harness.repo + "/README.md"
            shell.openInEditorColumn(path: readme, takeFocus: false)
            editor.toggleDiff()
            harness.waitUntil("the diff of README.md") { editor.diffActivePath == readme }
            let terminal = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.terminalView)
            harness.window.makeFirstResponder(terminal)
            UIFlowHarness.run("document.activeElement && document.activeElement.blur()", in: webView)
            shell.openInEditorColumn(path: readme, line: 1, endLine: 1, takeFocus: false)
            XCTAssertNil(editor.diffActivePath)
            waitForView("source:# Flow", in: webView)
            waitForRange("1-1|caret 1:1|context|flat", in: webView)
            XCTAssertEqual(editor.header.context, "Line 1")
            // An agent's open: the keyboard stays where the user types.
            XCTAssertIdentical(harness.window.firstResponder, terminal)
            UIFlowHarness.waitForAnswer("the page's focus", to: "document.activeElement === document.body ? 'none' : document.activeElement.tagName", in: webView) {
                $0 == "none"
            }
            // Its diff shows no highlight: the header names the folder over it.
            editor.toggleDiff()
            harness.waitUntil("the diff again") { editor.diffActivePath == readme }
            harness.waitUntil("the header over pierre's diff") { editor.header.context == "" }
            editor.toggleDiff()
            harness.waitUntil("the source again") { editor.diffActivePath == nil }
            XCTAssertEqual(editor.header.context, "Line 1")
        }
    }

    /// Writes `file` again, `lines` lines starting with `word`, and waits
    /// for the page to read it.
    private func rewrite(_ file: String, with word: String, lines: Int = 200, in webView: WKWebView) throws {
        try (1...lines).map { "\(word) \($0)\n" }.joined().write(toFile: file, atomically: true, encoding: .utf8)
        UIFlowHarness.waitForAnswer("the file read again", to: "\(Self.mainEditor).getModel().getLineContent(1)", in: webView) {
            $0 == "\(word) 1"
        }
    }

    // MARK: - Helpers

    /// The page's own Monaco editor: the diff editor's sides are editors too.
    private static let mainEditor = "monaco.editor.getEditors().filter(function (e) { return e.getContainerDomNode().id === 'editor'; })[0]"

    /// What the page shows: "rendered:<first heading>", ":focused" when the
    /// reading view has the page's focus; or "source:<first line>", ":find"
    /// with Monaco's find open.
    private static let shownView = """
        (function () {
          var reading = document.getElementById('markdown-view');
          if (getComputedStyle(reading).display !== 'none') {
            var heading = reading.querySelector('h1');
            return 'rendered:' + (heading ? heading.textContent : '') + (reading.contains(document.activeElement) ? ':focused' : '');
          }
          var editor = window.monaco && \(mainEditor);
          if (!editor || !editor.getModel() || getComputedStyle(editor.getContainerDomNode()).display === 'none') return '';
          var find = editor.getContainerDomNode().querySelector('.find-widget.visible');
          return 'source:' + editor.getModel().getValue().split('\\n')[0] + (find ? ':find' : '');
        })()
        """

    /// The reading view's table cells, its second column's alignment, and
    /// the tags its two links are drawn with.
    private static let drawn = """
        (function () {
          var view = document.getElementById('markdown-view');
          var links = view.querySelectorAll('p > a, p > .dead-link');
          return [view.querySelectorAll('td').length, view.querySelector('td + td').style.textAlign,
            links[0].tagName.toLowerCase(), links[1].tagName.toLowerCase()].join(':');
        })()
        """

    /// Monaco's word wrap and whether it numbers lines: "on:off" for a draft.
    private static let options = "(function () { var e = \(mainEditor); var o = monaco.editor.EditorOption; "
        + "return e.getOption(o.wordWrap) + ':' + (e.getOption(o.lineNumbers).renderType === monaco.editor.RenderLineNumbersType.Off ? 'off' : 'on'); })()"

    /// ⌘ and the key at `code`, typing `key`, as the page gets them.
    private static func command(_ key: String, code: String) -> String {
        "document.activeElement.dispatchEvent(new KeyboardEvent('keydown', "
            + "{ key: '\(key)', code: '\(code)', metaKey: true, bubbles: true, cancelable: true }))"
    }

    /// The word wrap of the Monaco diff on screen; empty without one.
    private static let diffWrap = "(function () { var d = monaco.editor.getDiffEditors()[0]; "
        + "if (!d || !d.getModel() || getComputedStyle(document.getElementById('diff-editor')).display === 'none') return ''; "
        + "return d.getModifiedEditor().getOption(monaco.editor.EditorOption.wordWrap); })()"

    /// The lines highlighted as shown ("40-52", "none"), then the caret
    /// ("caret 40:1") or "selection", whether the view starts three lines
    /// above the caret ("context"), and "sticky" or "flat".
    private static let shownRange = """
        (function () {
          var e = \(mainEditor);
          if (!e || !e.getModel()) return '';
          var shown = e.getModel().getAllDecorations().filter(function (d) { return d.options.className === 'nirux-shown-range'; })[0];
          var p = e.getPosition();
          return [
            shown ? shown.range.startLineNumber + '-' + shown.range.endLineNumber : 'none',
            e.getSelection().isEmpty() ? 'caret ' + p.lineNumber + ':' + p.column : 'selection',
            e.getScrollTop() === e.getTopForLineNumber(Math.max(1, p.lineNumber - 3)) ? 'context' : 'top ' + e.getScrollTop(),
            e.getOption(monaco.editor.EditorOption.stickyScroll).enabled ? 'sticky' : 'flat'
          ].join('|');
        })()
        """

    private func waitForRange(_ expected: String, in webView: WKWebView, file: StaticString = #filePath, line: UInt = #line) {
        UIFlowHarness.waitForAnswer("the page to show \(expected)", to: Self.shownRange, in: webView, file: file, line: line) {
            $0 == expected
        }
    }

    private func waitForView(_ expected: String, in webView: WKWebView, file: StaticString = #filePath, line: UInt = #line) {
        UIFlowHarness.waitForAnswer("the page to show \(expected)", to: Self.shownView, in: webView, file: file, line: line) {
            $0 == expected
        }
    }
}
