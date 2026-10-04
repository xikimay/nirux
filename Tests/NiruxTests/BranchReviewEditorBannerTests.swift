import AppKit
import XCTest
@testable import Nirux

/// The editor's "Full Branch Diff" tab offers the same branch in a Branch
/// Review column, through a native banner a click reaches
/// (docs/branch-review.md, section 1). The flow harness enumerates the
/// palette and the sidebar's menus, not this banner: it has its own test.
final class BranchReviewEditorBannerTests: XCTestCase {
    @MainActor
    func testFullBranchDiffOffersTheBranchReview() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.branchReviewReader = BranchReviewPageTests.reader
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            // An editor on another folder than the workspace's: the review
            // is of the editor's branch.
            XCTAssertNotEqual(workspace.cwd, harness.worktree)
            workspace.addEditorColumn(workspaceCwd: harness.worktree)
            let editor = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.editorColumn)
            shell.wireEditor(editor)
            shell.relayout(animated: false)
            let banner = editor.branchReviewBanner

            editor.showDiffCollection(title: "Full Branch Diff (1)", paths: [harness.worktree + "/README.md"], mode: .branch)
            XCTAssertFalse(banner.isHidden)
            // Not over the uncommitted changes.
            editor.showDiffCollection(title: "Uncommitted Changes (1)", paths: [harness.worktree + "/README.md"], mode: .head)
            XCTAssertTrue(banner.isHidden)
            editor.showDiffCollection(title: "Full Branch Diff (1)", paths: [harness.worktree + "/README.md"], mode: .branch)
            XCTAssertFalse(banner.isHidden)
            editor.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(banner.frame.width, 0)

            // A click, through hit-testing as AppKit routes one. A workspace
            // switch's snapshot lies over the viewport until its animation
            // ends, which a CI runner may not reach by now.
            shell.viewport.subviews.filter { $0 is NSImageView }.forEach { $0.removeFromSuperview() }
            let button = banner.openButton
            let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            let hit = harness.window.contentView?.hitTest(harness.window.contentView?.convert(center, from: nil) ?? center)
            let clicked = try XCTUnwrap(hit as? NSButton, "the banner's button isn't what a click there reaches: \(String(describing: hit))")
            XCTAssertIdentical(clicked, button)
            clicked.performClick(nil)

            let review = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.branchReview)
            XCTAssertEqual(review.worktree, harness.worktree)
            harness.waitUntil("the review to read its branch") { review.snapshot != nil }

            // Again: the same review comes to the front.
            shell.focusColumnByIndex(try XCTUnwrap(workspace.columns.firstIndex { $0.editorColumn === editor }))
            button.performClick(nil)
            XCTAssertIdentical(workspace.columns[safe: workspace.focusedIndex]?.branchReview, review)
            XCTAssertEqual(workspace.columns.filter(\.isBranchReview).count, 1)
        }
    }
}
