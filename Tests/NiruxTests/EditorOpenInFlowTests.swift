import AppKit
import WebKit
import XCTest
@testable import Nirux

/// The user's own editor (Zed, Cursor, VS Code), with doubles for the apps:
/// ⋯'s Open in at the caret, Reveal in Finder, and Settings › General's
/// "Open files in" for what the user opens.
@MainActor
final class EditorOpenInFlowTests: XCTestCase {
    private static let zed = URL(fileURLWithPath: "/Applications/Zed.app")
    private static let vscode = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
    private static let mainEditor = "monaco.editor.getEditors().filter(function (e) { return e.getContainerDomNode().id === 'editor'; })[0]"

    /// ⋯ lists the editors installed (Zed and VS Code here, not Cursor),
    /// then Reveal in Finder; Open in opens the file at the caret's line and
    /// column, through that editor's URL, or says it couldn't.
    func testOpenInTakesTheFileAtTheCaret() throws {
        try UIFlowHarness.run { harness in
            var opened: [String] = []
            var revealed: [String] = []
            var opens = true
            harness.shell.sideEffects.applicationURL = { ["dev.zed.Zed": Self.zed, "com.microsoft.VSCode": Self.vscode][$0] }
            harness.shell.sideEffects.openInApplication = { url, application, done in
                opened.append(url.absoluteString + " in " + application.lastPathComponent)
                done(opens)
            }
            harness.shell.sideEffects.revealInFinder = { revealed.append($0.path) }
            let notes = harness.repo + "/docs/My notes #2.txt"
            try "one\ntwo\nthree four\n".write(toFile: notes, atomically: true, encoding: .utf8)
            harness.shell.openInEditorColumn(path: notes)
            let editor = try XCTUnwrap(harness.shell.activeWorkspace?.front?.editorColumn)
            let webView = try XCTUnwrap(UIFlowHarness.descendant(of: editor, as: WKWebView.self))
            // Monaco's first load: slow on a runner busy with heavier tests.
            UIFlowHarness.waitForAnswer("the page to show the file", to: "\(Self.mainEditor).getModel().getValue()", in: webView, timeout: 30) {
                $0.hasPrefix("one")
            }
            UIFlowHarness.run("(function () { \(Self.mainEditor).setPosition({ lineNumber: 3, column: 7 }); })()", in: webView)
            let menu = editor.header.currentMenu()
            let titles = menu.items.map(\.title)
            XCTAssertEqual(titles.filter { $0.hasPrefix("Open in ") || $0 == "Reveal in Finder" }, ["Open in Zed", "Open in VS Code", "Reveal in Finder"])

            menu.performActionForItem(at: try XCTUnwrap(titles.firstIndex(of: "Open in VS Code")))
            harness.waitUntil("VS Code asked") { !opened.isEmpty }
            let encoded = notes.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "#", with: "%23")
            XCTAssertEqual(opened, ["vscode://file" + encoded + ":3:7 in Visual Studio Code.app"])
            menu.performActionForItem(at: try XCTUnwrap(titles.firstIndex(of: "Reveal in Finder")))
            XCTAssertEqual(revealed, [notes])
            opens = false
            menu.performActionForItem(at: try XCTUnwrap(titles.firstIndex(of: "Open in Zed")))
            harness.waitUntil("the failure said") { harness.shell.toast?.message == "Couldn’t open “My notes #2.txt” in Zed" }
            opens = true

            // With unsaved edits: saved, then opened.
            UIFlowHarness.run("(function () { var m = \(Self.mainEditor).getModel(); m.setValue(m.getValue() + 'five\\n'); })()", in: webView)
            harness.waitUntil("the edit") { editor.unsavedPaths == [notes] }
            let dirty = editor.header.currentMenu()
            let dirtyTitles = dirty.items.map(\.title)
            XCTAssertEqual(dirtyTitles.filter { $0.contains("Open in ") }, ["Save and Open in Zed", "Save and Open in VS Code"])
            dirty.performActionForItem(at: try XCTUnwrap(dirtyTitles.firstIndex(of: "Save and Open in VS Code")))
            harness.waitUntil("saved, then opened") { opened.count == 3 }
            XCTAssertEqual(try String(contentsOfFile: notes, encoding: .utf8), "one\ntwo\nthree four\nfive\n")
            // The page says the tab is clean once it hears the save was written.
            harness.waitUntil("the tab clean") { editor.unsavedPaths.isEmpty }

            // A save refused (changed on disk under the edit): nothing opens.
            UIFlowHarness.run("(function () { var m = \(Self.mainEditor).getModel(); m.setValue(m.getValue() + 'six\\n'); })()", in: webView)
            harness.waitUntil("another edit") { editor.unsavedPaths == [notes] }
            try "Changed on disk.\n".write(toFile: notes, atomically: true, encoding: .utf8)
            let banner = try XCTUnwrap(UIFlowHarness.descendant(of: editor, as: EditorConflictBanner.self))
            harness.waitUntil("the conflict") { !banner.isHidden }
            let refused = editor.header.currentMenu()
            refused.performActionForItem(at: try XCTUnwrap(refused.items.map(\.title).firstIndex(of: "Save and Open in VS Code")))
            harness.waitUntil("the save refused") { harness.shell.toast?.message.hasPrefix("Not saved") == true }
            // The page has answered the save once it answers this.
            UIFlowHarness.waitForAnswer("the page", to: "'ok'", in: webView) { $0 == "ok" }
            XCTAssertEqual(opened.count, 3)
        }
    }

    /// Save and Open reads the caret before it saves: an agent's open that
    /// switches the tab meanwhile doesn't move it.
    func testSaveAndOpenKeepsItsFilesCaret() throws {
        try UIFlowHarness.run { harness in
            var opened: [String] = []
            harness.shell.sideEffects.applicationURL = { $0 == "com.microsoft.VSCode" ? Self.vscode : nil }
            harness.shell.sideEffects.openInApplication = { url, _, done in
                opened.append(url.absoluteString)
                done(true)
            }
            let notes = harness.repo + "/docs/notes.txt"
            try "one\ntwo\nthree\n".write(toFile: notes, atomically: true, encoding: .utf8)
            harness.shell.openInEditorColumn(path: notes)
            let editor = try XCTUnwrap(harness.shell.activeWorkspace?.front?.editorColumn)
            let webView = try XCTUnwrap(UIFlowHarness.descendant(of: editor, as: WKWebView.self))
            UIFlowHarness.waitForAnswer("the page to show the file", to: "\(Self.mainEditor).getModel().getValue()", in: webView, timeout: 30) {
                $0.hasPrefix("one")
            }
            UIFlowHarness.run("""
                (function () {
                  var e = \(Self.mainEditor);
                  e.getModel().setValue('one\\ntwo\\nthree four\\n');
                  e.setPosition({ lineNumber: 3, column: 5 });
                })()
                """, in: webView)
            harness.waitUntil("the edit") { editor.unsavedPaths == [notes] }
            let menu = editor.header.currentMenu()
            menu.performActionForItem(at: try XCTUnwrap(menu.items.map(\.title).firstIndex(of: "Save and Open in VS Code")))
            harness.shell.openInEditorColumn(path: harness.repo + "/" + UIFlowHarness.searchTarget, takeFocus: false)
            harness.waitUntil("saved, then opened") { !opened.isEmpty }
            XCTAssertEqual(opened, ["vscode://file\(notes):3:5"])
        }
    }

    /// A Markdown tab read rendered has no caret: Open in opens the file with
    /// no line.
    func testOpenInFromARenderedTabTakesNoLine() throws {
        try UIFlowHarness.run { harness in
            var opened: [String] = []
            harness.shell.sideEffects.applicationURL = { $0 == "com.microsoft.VSCode" ? Self.vscode : nil }
            harness.shell.sideEffects.openInApplication = { url, _, done in
                opened.append(url.absoluteString)
                done(true)
            }
            let notes = harness.repo + "/docs/notes.md"
            try "# Notes\n\nOne.\n".write(toFile: notes, atomically: true, encoding: .utf8)
            harness.shell.openInEditorColumn(path: notes)
            let editor = try XCTUnwrap(harness.shell.activeWorkspace?.front?.editorColumn)
            let webView = try XCTUnwrap(UIFlowHarness.descendant(of: editor, as: WKWebView.self))
            UIFlowHarness.waitForAnswer("the page to show it rendered", to: Self.rendered, in: webView, timeout: 30) { $0 == "rendered" }
            let menu = editor.header.currentMenu()
            menu.performActionForItem(at: try XCTUnwrap(menu.items.map(\.title).firstIndex(of: "Open in VS Code")))
            harness.waitUntil("VS Code asked") { !opened.isEmpty }
            XCTAssertEqual(opened, ["vscode://file" + notes])
        }
    }

    /// "rendered" while the page shows the tab's Markdown view.
    private static let rendered = "(function () { var view = document.getElementById('markdown-view'); "
        + "return view && getComputedStyle(view).display !== 'none' ? 'rendered' : 'source'; })()"

    /// With "Open files in" on Zed, a terminal's file link goes to Zed (at
    /// its line, a column always), while Open Editor and what an agent shows
    /// stay in Nirux's editor; once Zed is gone, or fails to open it, a link
    /// opens in Nirux's.
    func testOpenFilesInSendsTerminalLinksOut() throws {
        try UIFlowHarness.run { harness in
            var opened: [String] = []
            var installed = ["dev.zed.Zed": Self.zed]
            var opens = true
            harness.shell.sideEffects.applicationURL = { installed[$0] }
            harness.shell.sideEffects.openInApplication = { url, _, done in
                opened.append(url.absoluteString)
                done(opens)
            }
            XCTAssertTrue(Persistence.updateSettings(liveLayout: nil) { $0.openFilesIn = "dev.zed.Zed" })
            let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
            let readme = harness.repo + "/README.md"
            workspace.onTerminalOpenFile?(workspace, readme, 7)
            XCTAssertEqual(opened, ["zed://file\(readme):7:1"])
            XCTAssertNil(workspace.front?.editorColumn?.currentPath)

            harness.shell.openEditorColumn()
            harness.waitUntil("Open Editor in Nirux's") { workspace.front?.editorColumn?.currentPath != nil }
            let target = harness.repo + "/" + UIFlowHarness.searchTarget
            let shown = try XCTUnwrap(OpenEditorRequest(queryItems: [URLQueryItem(name: "file", value: target), URLQueryItem(name: "line", value: "1")]))
            harness.shell.openEditorFromURL(shown)
            harness.waitUntil("Nirux's editor showing what the agent shows") { workspace.front?.editorColumn?.currentPath == shown.file }
            XCTAssertEqual(opened.count, 1)

            installed = [:]
            workspace.onTerminalOpenFile?(workspace, readme, nil)
            harness.waitUntil("Nirux's editor once Zed is gone") { workspace.front?.editorColumn?.currentPath == readme }
            XCTAssertEqual(opened.count, 1)
            installed = ["dev.zed.Zed": Self.zed]
            opens = false
            workspace.onTerminalOpenFile?(workspace, shown.file, nil)
            harness.waitUntil("Nirux's editor when Zed can't") { workspace.front?.editorColumn?.currentPath == shown.file }
            XCTAssertEqual(opened.last, "zed://file\(shown.file):1:1")
        }
    }
}
