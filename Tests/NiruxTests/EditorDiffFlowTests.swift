import AppKit
import WebKit
import XCTest
@testable import Nirux

/// The editor's diffs (bridge.js drawOwnDiff, drawGroup) read as Branch
/// Review's do: unified, one file after another, in Theme's colours; a
/// tab's own file under its tab, a group's and a checkpoint's files under a
/// row each. A draft's stays Monaco's, which wraps.
@MainActor
final class EditorDiffFlowTests: XCTestCase {
    /// A file's diff reads unified with no header of its own (its tab names
    /// it), on the editor's surface colour, and follows the buffer's edits
    /// and the file read again from disk.
    func testFileDiffReadsUnifiedUnderItsTab() throws {
        try UIFlowHarness.run { harness in
            let readme = harness.repo + "/README.md"
            harness.shell.openInEditorColumn(path: readme)
            let editor = try XCTUnwrap(harness.shell.activeWorkspace?.front?.editorColumn)
            let webView = try XCTUnwrap(UIFlowHarness.descendant(of: editor, as: WKWebView.self))
            editor.toggleDiff()
            harness.waitUntil("README.md's diff") { editor.diffActivePath == readme }
            let shown = waitForDiffs("README.md's diff", in: webView) { $0.types.count == 1 && $0.lines[0].contains("Edited.") }
            XCTAssertEqual(shown?.types, ["single"])
            XCTAssertEqual(shown?.rows, [])
            XCTAssertEqual(shown?.background, "rgb(32, 32, 42)")

            // Written again on disk, as an agent does: the diff stays, drawn again.
            try "# Flow\n\nBy an agent.\n".write(toFile: readme, atomically: true, encoding: .utf8)
            waitForDiffs("the agent's line", in: webView) { $0.types == ["single"] && $0.lines[0].contains("By an agent.") }
            XCTAssertEqual(editor.diffActivePath, readme)

            UIFlowHarness.run("\(Self.mainEditor).getModel().setValue('# Flow\\n\\nTyped.\\n')", in: webView)
            waitForDiffs("the typed line", in: webView) { $0.types == ["single"] && $0.lines[0].contains("Typed.") }

            // Drawn again, the diff keeps the reader's place.
            let long = (1...300).map { "Line \($0)." }.joined(separator: "\\n")
            UIFlowHarness.run("\(Self.mainEditor).getModel().setValue('\(long)')", in: webView)
            UIFlowHarness.waitForAnswer("a long diff", to: "String(document.getElementById('pierre-diff').scrollHeight > 4000)", in: webView) { $0 == "true" }
            UIFlowHarness.run("document.getElementById('pierre-diff').scrollTop = 2000", in: webView)
            UIFlowHarness.run("\(Self.mainEditor).getModel().setValue('\(long.replacingOccurrences(of: "Line 105.", with: "Line 105 changed."))')", in: webView)
            UIFlowHarness.waitForAnswer("the place kept", to: Self.placeAfterRedraw, in: webView) { $0 == "2000" }
        }
    }

    /// Uncommitted Changes: a row for each file that changed (an unchanged
    /// one has none), naming its folder and file and its lines added and
    /// removed, then its diff, or why it isn't compared; a click on the row
    /// folds it.
    func testGroupDiffHasOneRowPerChangedFile() throws {
        try UIFlowHarness.run { harness in
            let repo = harness.repo
            try "Same.\n".write(toFile: repo + "/docs/same.txt", atomically: true, encoding: .utf8)
            let big = String(repeating: "x\n", count: 210_000)
            try big.write(toFile: repo + "/big.txt", atomically: true, encoding: .utf8)
            try UIFlowHarness.git(["add", "docs/same.txt", "big.txt"], at: repo)
            try UIFlowHarness.git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", "same"], at: repo)
            try "Find it elsewhere.\n".write(toFile: repo + "/" + UIFlowHarness.searchTarget, atomically: true, encoding: .utf8)
            try (big + "y\n").write(toFile: repo + "/big.txt", atomically: true, encoding: .utf8)
            harness.shell.openInEditorColumn(path: repo + "/README.md")
            let editor = try XCTUnwrap(harness.shell.activeWorkspace?.front?.editorColumn)
            let webView = try XCTUnwrap(UIFlowHarness.descendant(of: editor, as: WKWebView.self))
            editor.showDiffCollection(title: "Uncommitted Changes (4)", paths: ["README.md", UIFlowHarness.searchTarget, "docs/same.txt", "big.txt"], mode: .head)
            let shown = waitForDiffs("the changed files", in: webView) { $0.rows.count == 3 && $0.types.count == 2 }
            XCTAssertEqual(shown?.rows, ["|README.md|+2|−0", "docs/|search-target.txt|+1|−1", "|big.txt"])
            XCTAssertEqual(shown?.types, ["single", "single"])
            XCTAssertEqual(shown?.notes, ["Too large to compare (\(big.utf8.count + 2) bytes)."])
            // The folder reads left to right, its end by the name.
            UIFlowHarness.waitForAnswer("docs/ in order", to: Self.folderOrder, in: webView) { $0 == "d<" }

            UIFlowHarness.run("document.querySelector('#pierre-diff .nirux-pierre-file-header').click()", in: webView)
            UIFlowHarness.waitForAnswer("README.md folded", to: "document.querySelector('#pierre-diff .nirux-diff-file').hidden ? 'folded' : 'open'", in: webView) {
                $0 == "folded"
            }
        }
    }

    /// A checkpoint's diff reads file by file too, from the hunks Swift
    /// made, what it skipped above the files.
    func testCheckpointDiffReadsFileByFile() throws {
        try UIFlowHarness.run { harness in
            harness.shell.openInEditorColumn(path: harness.repo + "/README.md")
            let editor = try XCTUnwrap(harness.shell.activeWorkspace?.front?.editorColumn)
            let webView = try XCTUnwrap(UIFlowHarness.descendant(of: editor, as: WKWebView.self))
            let file = try XCTUnwrap(LocalCheckpoints.fileDiff(path: "A.swift", before: Data("let a = 1\n-- old\n".utf8), after: Data("let a = 2\n".utf8)))
            editor.showCheckpointDiff(LocalCheckpoints.Diff(
                warning: "Incomplete checkpoint. Some changes may be missing.", notes: ["Skipped B.bin — Binary file"], files: [file]
            ), title: "Since the checkpoint")
            let shown = waitForDiffs("the checkpoint's file", in: webView) { $0.rows.count == 1 && $0.types.count == 1 && $0.lines[0].contains("-- old") }
            XCTAssertEqual(shown?.notes, ["Incomplete checkpoint. Some changes may be missing.", "Skipped B.bin — Binary file"])
            XCTAssertEqual(shown?.rows, ["|A.swift|+1|−2"])

            // Nothing changed: it says so under the warning.
            editor.showCheckpointDiff(LocalCheckpoints.Diff(
                warning: "Incomplete checkpoint. Some changes may be missing.", notes: [], files: []
            ), title: "Since the checkpoint")
            waitForDiffs("no changes", in: webView) { $0.notes == ["Incomplete checkpoint. Some changes may be missing.", "No changes"] }
        }
    }

    /// A draft's diff is Monaco's, which Toggle Word Wrap reaches (pierre's
    /// can't wrap) and which keeps the lines an agent showed highlighted, as
    /// the header says.
    func testDraftDiffFollowsWordWrap() throws {
        try UIFlowHarness.run { harness in
            let folder = harness.repo + "/nirux-draft-reply"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let draft = folder + "/reply.md"
            try "# Reply\n".write(toFile: draft, atomically: true, encoding: .utf8)
            harness.shell.openInEditorColumn(path: draft, line: 1, endLine: 1, takeFocus: false)
            let editor = try XCTUnwrap(harness.shell.activeWorkspace?.front?.editorColumn)
            let webView = try XCTUnwrap(UIFlowHarness.descendant(of: editor, as: WKWebView.self))
            XCTAssertTrue(editor.draftPaths.contains(draft))
            harness.waitUntil("the shown line") { editor.header.context == "Line 1" }
            editor.toggleDiff()
            harness.waitUntil("the draft's diff") { editor.diffActivePath == draft }
            XCTAssertEqual(editor.header.context, "Line 1")
            UIFlowHarness.waitForAnswer("Monaco's diff", to: Self.diffWrap, in: webView) { $0 == "off" }
            editor.toggleWordWrap()
            UIFlowHarness.waitForAnswer("the diff wrapped", to: Self.diffWrap, in: webView) { $0 == "on" }
        }
    }

    // MARK: - Helpers

    /// The diff's scroll once line 105 reads changed; empty before.
    private static let placeAfterRedraw = """
        (function () {
          var root = document.getElementById('pierre-diff');
          var host = root.querySelector('diffs-container');
          var text = host && host.shadowRoot ? host.shadowRoot.textContent : '';
          return text.indexOf('Line 105 changed.') < 0 ? '' : String(Math.round(root.scrollTop));
        })()
        """

    /// The word wrap of the Monaco diff on screen; empty without one.
    private static let diffWrap = "(function () { var d = monaco.editor.getDiffEditors()[0]; "
        + "if (!d || !d.getModel() || getComputedStyle(document.getElementById('diff-editor')).display === 'none') return ''; "
        + "return d.getModifiedEditor().getOption(monaco.editor.EditorOption.wordWrap); })()"

    /// Where the second row's folder ("docs/") draws its first character
    /// against its last: "d<" when "d" is left of "/".
    private static let folderOrder = """
        (function () {
          var folder = document.querySelectorAll('#pierre-diff .nirux-pierre-file-folder')[1];
          var walker = document.createTreeWalker(folder, NodeFilter.SHOW_TEXT);
          var text = walker.nextNode();
          var at = function (index) { var range = document.createRange(); range.setStart(text, index); range.setEnd(text, index + 1); return range.getBoundingClientRect().left; };
          return text.data[0] + (at(0) < at(text.data.length - 1) ? '<' : '>');
        })()
        """

    private static let mainEditor = "monaco.editor.getEditors().filter(function (e) { return e.getContainerDomNode().id === 'editor'; })[0]"

    /// What the diff surface shows: each file's diff style ("single" is
    /// unified, "+header" when pierre draws its own), the rows naming files
    /// (folder|name|added|removed), each file's lines, the notes, and the
    /// first diff's background.
    private struct Shown: Decodable {
        let types: [String]
        let rows: [String]
        let lines: [String]
        let notes: [String]
        let background: String
    }

    private static let shown = """
        (function () {
          var root = document.getElementById('pierre-diff');
          if (getComputedStyle(root).display === 'none') return '';
          var hosts = [...root.querySelectorAll('diffs-container')];
          return JSON.stringify({
            types: hosts.map(function (host) {
              var pre = host.shadowRoot && host.shadowRoot.querySelector('pre');
              return pre ? pre.getAttribute('data-diff-type') + (host.shadowRoot.querySelector('[data-diffs-header]') ? '+header' : '') : '';
            }),
            rows: [...root.querySelectorAll('.nirux-pierre-file-header')].map(function (row) {
              return [...row.children].slice(1).map(function (part) { return part.textContent; }).join('|');
            }),
            lines: hosts.map(function (host) {
              return [...(host.shadowRoot ? host.shadowRoot.querySelectorAll('[data-line]') : [])].map(function (line) { return line.textContent; }).join('/');
            }),
            notes: [...root.querySelectorAll('.nirux-diff-note')].map(function (note) { return note.textContent; }),
            background: hosts[0] ? getComputedStyle(hosts[0]).backgroundColor : ''
          });
        })()
        """

    @discardableResult
    private func waitForDiffs(
        _ description: String, in webView: WKWebView, file: StaticString = #filePath, line: UInt = #line,
        _ matches: @escaping (Shown) -> Bool
    ) -> Shown? {
        var latest: Shown?
        UIFlowHarness.waitForAnswer(description, to: Self.shown, in: webView, file: file, line: line) { answer in
            guard let shown = try? JSONDecoder().decode(Shown.self, from: Data(answer.utf8)) else { return false }
            latest = shown
            return matches(shown)
        }
        return latest
    }
}
