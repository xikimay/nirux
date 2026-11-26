import AppKit
import WebKit
import XCTest
@testable import Nirux

/// Reading modes (EditorColumn, bridge.js): a Markdown file reads rendered in
/// the front editor and as source in an editor of the row, its header's
/// toggle switching; a draft reads as source, wrapped, with Copy Draft.
@MainActor
class EditorReadingModeFlowTests: XCTestCase {
    /// DO NOT MERGE: the revert this class runs with (`zzMutant`).
    nonisolated class var mutant: String? { nil }

    nonisolated override func setUp() {
        super.setUp()
        zzMutant = Self.mutant
    }

    /// Opened in the front editor, a Markdown file shows rendered, the
    /// reading view taking the keyboard with the column, its table drawn,
    /// only its web link live, and drawn again when the file changes on
    /// disk. ⌘S and ⌘P do what they do in Monaco, Esc first clears a
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
            UIFlowHarness.run(Self.command("s"), in: webView)
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
            UIFlowHarness.run(Self.command("p"), in: webView)
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

            UIFlowHarness.run(Self.command("f"), in: webView)
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

    /// A draft, in the nirux-draft skill's folder, reads as source even in
    /// the front editor, wrapped and without line numbers; Copy Draft puts
    /// its text, unsaved edits included, on the pasteboard. Another tab
    /// keeps the wrap it had, Toggle Word Wrap on the draft included, and
    /// its line numbers.
    func testDraftWrapsAndCopiesItsText() throws {
        try UIFlowHarness.run { harness in
            let folder = harness.root + "/nirux-draft-Ab12Cd"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let draft = folder + "/reply.md"
            try "# Reply\n\nFirst.\n".write(toFile: draft, atomically: true, encoding: .utf8)
            harness.shell.openInEditorColumn(path: draft)
            let editor = try XCTUnwrap(harness.shell.activeWorkspace?.front?.editorColumn)
            editor.pasteboard = NSPasteboard.withUniqueName()
            let webView = try XCTUnwrap(UIFlowHarness.descendant(of: editor, as: WKWebView.self))
            waitForView("source:# Reply", in: webView)
            XCTAssertTrue(editor.header.accessories.contains { $0 === editor.copyDraftButton })
            XCTAssertFalse(editor.header.trailingButtons.contains(editor.renderButton))
            UIFlowHarness.waitForAnswer("a wrapped draft", to: Self.options, in: webView) { $0 == "on:off" }
            editor.toggleWordWrap()

            UIFlowHarness.run("\(Self.mainEditor).getModel().setValue('# Reply\\n\\nEdited.\\n')", in: webView)
            editor.copyDraftButton.performClick(nil)
            harness.waitUntil("the draft on the pasteboard") { editor.pasteboard.string(forType: .string) == "# Reply\n\nEdited.\n" }
            XCTAssertEqual(editor.copyDraftButton.title, "Copied ✓")

            harness.shell.openInEditorColumn(path: harness.repo + "/" + UIFlowHarness.searchTarget)
            UIFlowHarness.waitForAnswer("the user's wrap on another tab", to: Self.options, in: webView) { $0 == "off:on" }
            XCTAssertTrue(editor.header.accessories.isEmpty)
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

    /// ⌘ and `key` as the page gets them.
    private static func command(_ key: String) -> String {
        "document.activeElement.dispatchEvent(new KeyboardEvent('keydown', "
            + "{ key: '\(key)', code: 'Key\(key.uppercased())', metaKey: true, bubbles: true, cancelable: true }))"
    }

    private func waitForView(_ expected: String, in webView: WKWebView, file: StaticString = #filePath, line: UInt = #line) {
        UIFlowHarness.waitForAnswer("the page to show \(expected)", to: Self.shownView, in: webView, file: file, line: line) {
            $0 == expected
        }
    }
}

// DO NOT MERGE: one class per revert; each must fail, the class above must pass.
final class ZZ_s1: EditorReadingModeFlowTests { nonisolated override class var mutant: String? { "s1" } }
final class ZZ_s2: EditorReadingModeFlowTests { nonisolated override class var mutant: String? { "s2" } }
final class ZZ_s3: EditorReadingModeFlowTests { nonisolated override class var mutant: String? { "s3" } }
final class ZZ_s4: EditorReadingModeFlowTests { nonisolated override class var mutant: String? { "s4" } }
final class ZZ_s5: EditorReadingModeFlowTests { nonisolated override class var mutant: String? { "s5" } }
final class ZZ_s6: EditorReadingModeFlowTests { nonisolated override class var mutant: String? { "s6" } }
final class ZZ_s7: EditorReadingModeFlowTests { nonisolated override class var mutant: String? { "s7" } }
final class ZZ_s8: EditorReadingModeFlowTests { nonisolated override class var mutant: String? { "s8" } }
final class ZZ_s9: EditorReadingModeFlowTests { nonisolated override class var mutant: String? { "s9" } }
final class ZZ_s10: EditorReadingModeFlowTests { nonisolated override class var mutant: String? { "s10" } }
final class ZZ_j1: EditorReadingModeFlowTests { nonisolated override class var mutant: String? { "j1" } }
final class ZZ_j2: EditorReadingModeFlowTests { nonisolated override class var mutant: String? { "j2" } }
final class ZZ_j3: EditorReadingModeFlowTests { nonisolated override class var mutant: String? { "j3" } }
final class ZZ_j5: EditorReadingModeFlowTests { nonisolated override class var mutant: String? { "j5" } }
final class ZZ_j6: EditorReadingModeFlowTests { nonisolated override class var mutant: String? { "j6" } }
final class ZZ_j7: EditorReadingModeFlowTests { nonisolated override class var mutant: String? { "j7" } }
final class ZZ_j8: EditorReadingModeFlowTests { nonisolated override class var mutant: String? { "j8" } }
final class ZZ_j9: EditorReadingModeFlowTests { nonisolated override class var mutant: String? { "j9" } }
final class ZZ_j10: EditorReadingModeFlowTests { nonisolated override class var mutant: String? { "j10" } }
