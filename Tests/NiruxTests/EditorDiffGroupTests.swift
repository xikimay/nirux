import AppKit
import XCTest
@testable import Nirux

/// The editor's tab of several files' diff ("Uncommitted Changes", "Full
/// Branch Diff"), on a real, temporary repository.
final class EditorDiffGroupTests: BranchReviewRepositoryTestCase {
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
}
