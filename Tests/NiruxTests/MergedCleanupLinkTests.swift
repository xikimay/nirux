import AppKit
import XCTest
@testable import Nirux

/// The card's "merged · Clean up": shown only for a merged pull request in
/// a linked worktree, and a click runs the ⋯ menu's "Clean Up Worktree…".
@MainActor
final class MergedCleanupLinkTests: XCTestCase {
    func testCleanUpShowsForAMergedWorktreeAndRunsTheCleanup() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.isSidebarExpanded = true
            shell.sidebar.isExpanded = true
            shell.relayout(animated: false)
            let mainCheckout = try XCTUnwrap(shell.activeWorkspace)
            shell.addWorkspace(title: "in worktree", cwd: harness.worktree)
            let worktreeWorkspace = try XCTUnwrap(shell.activeWorkspace)

            // Set and read in one run-loop turn: the git refresh the new
            // workspace started can't clear them in between.
            worktreeWorkspace.prInfo = pullRequest(state: "OPEN")
            mainCheckout.prInfo = pullRequest(state: "MERGED")
            shell.updateSidebar()
            XCTAssertEqual(cleanupLinkIndices(in: shell.sidebar), [], "open, or merged in the main checkout")

            worktreeWorkspace.prInfo = pullRequest(state: "MERGED")
            shell.updateSidebar()
            let worktreeIndex = try XCTUnwrap(shell.workspaces.firstIndex { $0 === worktreeWorkspace })
            XCTAssertEqual(cleanupLinkIndices(in: shell.sidebar), [worktreeIndex])

            try click(cleanupLinkFrame(in: shell.sidebar), in: shell.sidebar, window: harness.window)
            // No GitHub remote: the checks refuse, and nothing goes.
            harness.waitUntil("the clean-up verdict") { !harness.alerts.isEmpty && shell.worktreeCleanupsInFlight.isEmpty }
            XCTAssertTrue(harness.alerts.last?.hasPrefix("Can’t clean up") == true, "\(harness.alerts)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: harness.worktree))
            XCTAssertTrue(shell.workspaces.contains { $0 === worktreeWorkspace })
        }
    }

    private func pullRequest(state: String) -> PRInfo {
        PRInfo(
            number: 7, state: state, isDraft: false, ciStatus: nil, failedCheckUrl: nil, reviewDecision: nil,
            mergeable: nil, url: "https://example.test/pull/7", additions: nil, deletions: nil, changedFiles: nil
        )
    }

    private func cleanupLinkIndices(in sidebar: SidebarView) -> [Int] {
        sidebar.hitAreas.compactMap { area in
            guard case .link(let url, let label) = area.region, label.stringValue == "Clean up" else { return nil }
            return (0..<100).first { url == SidebarView.cleanupActionURL(workspaceIndex: $0) }
        }
    }

    private func cleanupLinkFrame(in sidebar: SidebarView) throws -> NSRect {
        try XCTUnwrap(sidebar.hitAreas.first { area in
            guard case .link(_, let label) = area.region else { return false }
            return label.stringValue == "Clean up"
        }?.frame)
    }

    /// Delivered by hand to the view the window hit-tests: a window that
    /// is never shown (CI) drops mouse events.
    private func click(_ frame: NSRect, in sidebar: SidebarView, window: NSWindow) throws {
        let locationInWindow = sidebar.contentDocumentView.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        let frameView = try XCTUnwrap(window.contentView?.superview)
        let hitView = try XCTUnwrap(frameView.hitTest(locationInWindow))
        hitView.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )))
    }
}
