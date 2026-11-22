import AppKit
import XCTest
@testable import Nirux

/// The editor's tab of several files' diff ("Uncommitted Changes", "Full
/// Branch Diff"), on a real, temporary repository.
final class EditorDiffGroupTests: BranchReviewRepositoryTestCase {
    @MainActor
    func testCheckpointDiffIsAVirtualTabAndRetainsItsWarning() throws {
        let editor = EditorColumn(workspaceCwd: repo)
        editor.showCheckpointDiff(.init(warning: "Incomplete checkpoint", text: "No changes."), title: "Saved → Working Tree")
        let tab = try XCTUnwrap(editor.activePath)
        XCTAssertNil(editor.currentPath)
        XCTAssertTrue(editor.openPaths.isEmpty)
        XCTAssertTrue(editor.unsavedPaths.isEmpty)
        editor.showDiff(path: "README.md")
        editor.switchTo(path: tab)
        XCTAssertEqual(editor.diffGroupTabs[tab]?.checkpoint?.warning, "Incomplete checkpoint")
        editor.close(path: tab)
        XCTAssertEqual(editor.currentPath, repo + "/README.md")
    }

    /// A file's diff opened while the tab reads its files doesn't stop that
    /// read: back on the tab, they show.
    @MainActor
    func testAGroupTabLoadsWhileAFileDiffOpens() throws {
        try write("README.md", "widgets and gadgets\n")
        try write("Sources/App.swift", "let a = 1\n")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let editor = EditorColumn(workspaceCwd: repo)
        window.contentView?.addSubview(editor)
        defer {
            editor.removeFromSuperview()
            window.close()
        }

        editor.showDiffCollection(title: "Uncommitted Changes (2)", paths: ["README.md", "Sources/App.swift"], mode: .head)
        let group = try XCTUnwrap(editor.activePath)
        editor.showDiff(path: "Sources/App.swift")
        XCTAssertEqual(editor.activePath, repo + "/Sources/App.swift")
        editor.switchTo(path: group)
        waitUntil("the tab's files") { editor.diffGroupTabs[group]?.isLoading == false }
        XCTAssertEqual(editor.diffGroupTabs[group]?.files.count, 2)
    }

    /// A tab whose files can't be read closes, and the toast names it: the
    /// user may be reading another tab's diff by then.
    @MainActor
    func testAGroupTabThatCantReadItsFilesSaysWhich() throws {
        let previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", root + "/state", 1)
        defer {
            if let previousStateDirectory { setenv("NIRUX_STATE_DIR", previousStateDirectory, 1) } else { unsetenv("NIRUX_STATE_DIR") }
        }
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        shell.stopHeartbeat()
        let window = NSWindow(contentRect: shell.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = shell
        let editor = EditorColumn(workspaceCwd: repo)
        shell.addSubview(editor)
        defer {
            editor.removeFromSuperview()
            window.close()
        }

        try write("README.md", "widgets and gadgets\n")
        editor.showDiffCollection(title: "Outside (1)", paths: [root + "/outside.txt"], mode: .head)
        editor.showDiff(path: "README.md")
        waitUntil("the tab closed") { editor.diffGroupTabs.isEmpty }
        XCTAssertEqual(shell.toast?.message, "Couldn’t read the changes of “Outside (1)”")
    }
}
