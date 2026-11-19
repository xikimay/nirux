import AppKit
import WebKit
import XCTest
@testable import Nirux

/// The editor never loses unsaved edits nor a change made on disk
/// (EditorColumn, NiruxShellView+UnsavedEdits), in a real window on
/// throwaway state (see UIFlowHarness): ⌘S writes only over the version
/// last read or written, else shows the conflict; a tab, a column, a
/// workspace or Nirux holding unsaved edits asks Save, Cancel or Don't Save
/// before it closes; close_task refuses.
@MainActor
final class EditorUnsavedEditsFlowTests: XCTestCase {
    /// ⌘S over a change made on disk writes nothing: a clean buffer takes
    /// the disk's version; unsaved edits show the conflict, where Compare
    /// puts the disk's version beside them, Keep Mine writes them and Take
    /// Disk drops them. A clean tab the watcher reloads stays clean.
    func testCommandSNeverWritesOverAChangeMadeOnDisk() throws {
        try UIFlowHarness.run { harness in
            let notes = harness.repo + "/notes.txt"
            let other = harness.repo + "/other.txt"
            try write("other\n", to: other)
            try write("first\n", to: notes)
            let (editor, _) = try openEditor(other, in: harness)
            let (_, webView) = try openEditor(notes, in: harness)

            // In the background, a clean tab takes the disk's version and
            // stays clean.
            try write("other, by an agent\n", to: other)
            waitForModel(holding: "other, by an agent\n", in: webView) {
                // An app deactivation pauses the watcher.
                editor.resumeFileWatch()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            XCTAssertEqual(editor.unsavedPaths, [], "the reload left the tab unsaved")

            // An agent writes the file between two checks of the watcher.
            editor.pauseFileWatch()
            try write("agent\n", to: notes)
            pressCommandS(in: webView)
            waitForBuffer("agent\n", in: webView)
            XCTAssertEqual(try read(notes), "agent\n", "⌘S wrote a clean buffer over the change")

            try setBuffer("agent\nmine\n", in: webView)
            harness.waitUntil("the edit") { editor.unsavedPaths == [notes] }
            try write("agent 2\n", to: notes)
            pressCommandSRefused(in: webView, harness: harness)
            let banner = try XCTUnwrap(UIFlowHarness.descendant(of: editor, as: EditorConflictBanner.self))
            XCTAssertFalse(banner.isHidden)
            XCTAssertEqual(try read(notes), "agent 2\n", "⌘S wrote over the change made on disk")
            XCTAssertEqual(harness.shell.toast?.message, "Not saved: “notes.txt” changed on disk")
            // Again, the conflict on screen.
            pressCommandSRefused(in: webView, harness: harness)
            XCTAssertEqual(try read(notes), "agent 2\n", "⌘S wrote over the conflict on screen")

            try click("Compare", in: banner)
            XCTAssertEqual(editor.diffActivePath, notes)
            XCTAssertEqual(editor.diffActiveBase, .disk)
            UIFlowHarness.waitForAnswer("the disk's version beside the buffer", to: Self.diffSides, in: webView) {
                $0 == "agent 2\n|agent\nmine\n"
            }

            try click("Keep Mine", in: banner)
            harness.waitUntil("the buffer written") { (try? read(notes)) == "agent\nmine\n" && editor.unsavedPaths.isEmpty }
            XCTAssertTrue(banner.isHidden)
            XCTAssertNil(editor.diffActivePath, "the compare stayed")

            // A copy keeping its older date is a change too.
            try setBuffer("agent\nmine again\n", in: webView)
            harness.waitUntil("the edit") { editor.unsavedPaths == [notes] }
            try write("agent 3\n", to: notes, dated: Date(timeIntervalSinceNow: -3600))
            pressCommandSRefused(in: webView, harness: harness)
            XCTAssertFalse(banner.isHidden)
            XCTAssertEqual(try read(notes), "agent 3\n", "⌘S wrote over an older-dated change")
            // Its edits undone in the compare, nothing is left to keep: the
            // disk's version comes in.
            try click("Compare", in: banner)
            try setBuffer("agent\nmine\n", in: webView)
            waitForBuffer("agent 3\n", in: webView)
            XCTAssertTrue(banner.isHidden)
            XCTAssertEqual(editor.unsavedPaths, [])
            XCTAssertNil(editor.diffActivePath, "the compare stayed")

            try setBuffer("agent 3\nmine\n", in: webView)
            harness.waitUntil("the edit") { editor.unsavedPaths == [notes] }
            try write("agent 4\n", to: notes)
            pressCommandSRefused(in: webView, harness: harness)
            try click("Take Disk", in: banner)
            waitForBuffer("agent 4\n", in: webView)
            harness.waitUntil("the buffer clean") { editor.unsavedPaths.isEmpty }
            XCTAssertTrue(banner.isHidden)
            XCTAssertEqual(try read(notes), "agent 4\n")

            // Through a symlink, the file it names is checked and written.
            let agents = harness.repo + "/AGENTS.md"
            let claude = harness.repo + "/CLAUDE.md"
            try write("rules\n", to: agents)
            try FileManager.default.createSymbolicLink(atPath: claude, withDestinationPath: "AGENTS.md")
            _ = try openEditor(claude, in: harness)
            try setBuffer("rules\nmine\n", in: webView)
            harness.waitUntil("the edit") { editor.unsavedPaths == [claude] }
            try write("rules, by an agent\n", to: agents)
            pressCommandSRefused(in: webView, harness: harness)
            XCTAssertEqual(try read(agents), "rules, by an agent\n", "⌘S wrote over the change made through the link")
            try click("Keep Mine", in: banner)
            harness.waitUntil("mine written") { (try? read(agents)) == "rules\nmine\n" && editor.unsavedPaths.isEmpty }
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: claude), "AGENTS.md", "the link was replaced")
        }
    }

    /// A tab, a column, a workspace and Nirux holding unsaved edits ask
    /// Save, Cancel or Don't Save before they close; Save closes once the
    /// file is written.
    func testClosingWithUnsavedEditsAsksFirst() throws {
        try UIFlowHarness.run { harness in
            try harness.withApp {
                let shell = harness.shell
                let workspace = try XCTUnwrap(shell.activeWorkspace)
                let tab = harness.repo + "/tab.txt"
                try write("first\n", to: tab)
                let (editor, webView) = try openEditor(tab, in: harness)
                try setBuffer("tab\n", in: webView)
                harness.waitUntil("the edit") { editor.unsavedPaths == [tab] }

                // ⌘W closes the tab: Cancel keeps it.
                let asked = harness.alerts.count
                harness.alertResponses = [.alertSecondButtonReturn]
                harness.press("w", keyCode: 0x0D, .command)
                XCTAssertEqual(harness.alerts.dropFirst(asked), ["Save the changes to “tab.txt”?"])
                XCTAssertEqual(editor.openPaths, [tab], "Cancel")
                // Its ×: Save writes it, then closes it.
                let tabBar = try XCTUnwrap(UIFlowHarness.descendant(of: editor, as: EditorTabBar.self))
                harness.alertResponses = [.alertFirstButtonReturn]
                tabBar.onClose?(tab)
                harness.waitUntil("the tab saved, then closed") { editor.openPaths.isEmpty }
                XCTAssertEqual(try read(tab), "tab\n")
                XCTAssertEqual(harness.alerts.count, asked + 2)

                // The column: Don't Save closes it as it is.
                let column = harness.repo + "/column.txt"
                try write("first\n", to: column)
                _ = try openEditor(column, in: harness)
                try setBuffer("column\n", in: webView)
                harness.waitUntil("the edit") { editor.unsavedPaths == [column] }
                harness.alertResponses = [.alertThirdButtonReturn]
                shell.closeActiveColumn()
                XCTAssertEqual(harness.alerts.count, asked + 3)
                XCTAssertEqual(harness.alerts.last, "Save the changes to “column.txt”?")
                harness.waitUntil("the column closed") { !workspace.columns.contains { $0.editorColumn === editor } }
                XCTAssertEqual(try read(column), "first\n", "Don't Save")

                // From the sidebar, and the workspace: Cancel keeps them;
                // Save closes the workspace once written.
                shell.addWorkspace(title: "Draft", cwd: harness.repo)
                let draft = try XCTUnwrap(shell.activeWorkspace)
                let draftFile = harness.repo + "/draft.txt"
                try write("first\n", to: draftFile)
                let (draftEditor, draftWebView) = try openEditor(draftFile, in: harness)
                try setBuffer("draft\n", in: draftWebView)
                harness.waitUntil("the edit") { draftEditor.unsavedPaths == [draftFile] }
                let draftIndex = try XCTUnwrap(shell.workspaces.firstIndex { $0 === draft })
                let editorIndex = try XCTUnwrap(draft.columns.firstIndex { $0.editorColumn === draftEditor })
                harness.alertResponses = [.alertSecondButtonReturn]
                shell.closeColumn(workspaceIndex: draftIndex, columnIndex: editorIndex)
                XCTAssertEqual(harness.alerts.count, asked + 4)
                XCTAssertTrue(draft.columns.contains { $0.editorColumn === draftEditor }, "Cancel")
                // Close Workspace for its two columns, then Cancel.
                harness.alertResponses = [.alertSecondButtonReturn, .alertSecondButtonReturn]
                shell.requestCloseWorkspace(at: draftIndex)
                XCTAssertEqual(harness.alerts.suffix(2), ["Close workspace “Draft”?", "Save the changes to “draft.txt”?"])
                XCTAssertFalse(draft.isClosing, "Cancel")
                harness.alertResponses = [.alertSecondButtonReturn, .alertFirstButtonReturn]
                shell.requestCloseWorkspace(at: draftIndex)
                harness.waitUntil("the workspace saved, then closing") { draft.isClosing }
                XCTAssertEqual(try read(draftFile), "draft\n")

                // Quitting: Cancel stays, Don't Save quits, Save quits once
                // written.
                harness.waitUntil("the workspace gone") { !shell.workspaces.contains { $0 === draft } }
                let quit = harness.repo + "/quit.txt"
                try write("first\n", to: quit)
                let (quitEditor, quitWebView) = try openEditor(quit, in: harness)
                try setBuffer("quit\n", in: quitWebView)
                harness.waitUntil("the edit") { quitEditor.unsavedPaths == [quit] }
                let app = try XCTUnwrap(NSApp.delegate as? NiruxApp)
                harness.alertResponses = [.alertSecondButtonReturn]
                XCTAssertEqual(app.applicationShouldTerminate(NSApp), .terminateCancel)
                XCTAssertEqual(harness.alerts.count, asked + 9)
                XCTAssertEqual(harness.alerts.last, "Save the changes to “quit.txt”?")
                var replies: [Bool] = []
                harness.alertResponses = [.alertThirdButtonReturn]
                XCTAssertEqual(shell.terminateReply { replies.append($0) }, .terminateNow, "Don't Save")
                // The window's close button quits: it stays meanwhile.
                var quitRequests = 0
                shell.sideEffects.requestQuit = { quitRequests += 1 }
                XCTAssertFalse(shell.mainWindowShouldClose())
                XCTAssertEqual(quitRequests, 1)
                harness.alertResponses = [.alertFirstButtonReturn]
                XCTAssertEqual(shell.terminateReply { replies.append($0) }, .terminateLater)
                harness.waitUntil("saved, then quitting") { replies == [true] }
                XCTAssertEqual(try read(quit), "quit\n")
                XCTAssertEqual(harness.alerts.count, asked + 11, "asked once each")
            }
        }
    }

    /// close_task leaves a task whose editor holds unsaved edits to the
    /// user.
    func testCloseTaskRefusesATaskWithUnsavedEdits() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            shell.addWorkspace(title: "Draft", cwd: harness.worktree, profileID: lead.space)
            let draft = try XCTUnwrap(shell.workspaces.first { $0.title == "Draft" })
            let readme = harness.worktree + "/README.md"
            let (editor, webView) = try openEditor(readme, in: harness, workspace: draft)
            try setBuffer("# Draft\n", in: webView)
            harness.waitUntil("the edit") { editor.unsavedPaths == [readme] }
            // Not in front: the user isn't typing in it.
            shell.sideEffects.appIsActive = { false }
            let answer = try harness.callLeadTool(LeadTools.closeTask, ["task": "Draft"], lead: lead)
            XCTAssertTrue(answer.isError, answer.text)
            XCTAssertTrue(answer.text.contains("has unsaved editor changes"), answer.text)
        }
    }

    // MARK: - Helpers

    /// The page's own Monaco editor: the diff editor's sides are editors
    /// too.
    private static let mainEditor = "monaco.editor.getEditors().filter(function (e) { return e.getContainerDomNode().id === 'editor'; })[0]"

    /// The diff on screen: its two sides, "|" between.
    private static let diffSides = "(function () { var d = monaco.editor.getDiffEditors()[0]; var m = d && d.getModel(); "
        + "return m ? m.original.getValue() + '|' + m.modified.getValue() : ''; })()"

    /// Opens `path` in the editor column of `workspace` (the active one by
    /// default), its Monaco holding the file.
    private func openEditor(
        _ path: String, in harness: UIFlowHarness, workspace: WorkspaceState? = nil
    ) throws -> (EditorColumn, WKWebView) {
        let workspace = try XCTUnwrap(workspace ?? harness.shell.activeWorkspace)
        harness.shell.openInEditorColumn(path: path, in: workspace)
        let editor = try XCTUnwrap(workspace.columns.lazy.compactMap(\.editorColumn).first)
        harness.waitUntil("the editor on \(path)") { editor.activePath == path }
        let webView = try XCTUnwrap(UIFlowHarness.descendant(of: editor, as: WKWebView.self))
        waitForBuffer(try read(path), in: webView)
        return (editor, webView)
    }

    /// Replaces Monaco's text, as typing does.
    private func setBuffer(_ text: String, in webView: WKWebView) throws {
        UIFlowHarness.run("\(Self.mainEditor).getModel().setValue(\(try Self.literal(text)))", in: webView)
    }

    private func waitForBuffer(_ text: String, in webView: WKWebView, file: StaticString = #filePath, line: UInt = #line) {
        let script = "(function () { var e = \(Self.mainEditor); return e && e.getModel() ? e.getModel().getValue() : ''; })()"
        UIFlowHarness.waitForAnswer("Monaco to hold \(text.debugDescription)", to: script, in: webView, file: file, line: line) {
            $0 == text
        }
    }

    /// Any tab's text, shown or not; `meanwhile` runs at each check.
    private func waitForModel(holding text: String, in webView: WKWebView, meanwhile: () -> Void) {
        guard let literal = try? Self.literal(text) else { return XCTFail("no literal for \(text)") }
        let script = "monaco.editor.getModels().some(function (m) { return m.getValue() === \(literal); }) ? 'yes' : 'no'"
        UIFlowHarness.waitForAnswer("a tab to hold \(text.debugDescription)", to: script, in: webView) {
            meanwhile()
            return $0 == "yes"
        }
    }

    /// ⌘S, refused: the toast says why.
    private func pressCommandSRefused(
        in webView: WKWebView, harness: UIFlowHarness, file: StaticString = #filePath, line: UInt = #line
    ) {
        let toasts = harness.shell.toastGeneration
        pressCommandS(in: webView, file: file, line: line)
        harness.waitUntil("the refusal", file: file, line: line) { harness.shell.toastGeneration > toasts }
    }

    /// ⌘S in Monaco: the key interceptor hands it to the page (no menu
    /// item has it), which posts the save.
    private func pressCommandS(in webView: WKWebView, file: StaticString = #filePath, line: UInt = #line) {
        let script = "\(Self.mainEditor).hasTextFocus() ? 'focused' : ''"
        UIFlowHarness.waitForAnswer("Monaco to take text", to: script, in: webView, file: file, line: line) {
            $0 == "focused" && webView.inputContext != nil
        }
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: webView.window?.windowNumber ?? 0,
            context: nil,
            characters: "s",
            charactersIgnoringModifiers: "s",
            isARepeat: false,
            keyCode: 0x01
        ) else { return XCTFail("no key event", file: file, line: line) }
        XCTAssertTrue(webView.performKeyEquivalent(with: event), "the web view didn't take ⌘S", file: file, line: line)
    }

    private func click(_ title: String, in banner: EditorConflictBanner, file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTUnwrap(UIFlowHarness.button(titled: title, in: banner), "no \(title)", file: file, line: line).performClick(nil)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private func write(_ text: String, to path: String, dated date: Date? = nil) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path) }
    }

    /// `text` as a JavaScript string literal.
    private static func literal(_ text: String) throws -> String {
        try XCTUnwrap(String(data: JSONEncoder().encode(text), encoding: .utf8))
    }
}
