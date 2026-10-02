import AppKit
import XCTest
@testable import Nirux

/// The card's "merged · Clean up": shown only when the merged pull request
/// is the branch of the worktree the clean-up would remove, and a click
/// runs the ⋯ menu's "Clean Up Worktree…".
@MainActor
final class MergedCleanupLinkTests: XCTestCase {
    func testCleanUpShowsForTheMergedWorktreeAndRunsTheCleanup() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.isSidebarExpanded = true
            shell.sidebar.isExpanded = true
            shell.relayout(animated: false)
            let mainCheckout = try XCTUnwrap(shell.activeWorkspace)
            shell.addWorkspace(title: "in worktree", cwd: harness.worktree)
            let worktreeWorkspace = try XCTUnwrap(shell.activeWorkspace)

            // The card's pull request is the focused folder's branch's: on
            // an editor of the main checkout, it isn't the worktree's.
            worktreeWorkspace.addEditorColumn(workspaceCwd: harness.repo)
            waitForGitContext(of: worktreeWorkspace, at: harness.repo, shell: shell, harness: harness)
            // Set and read in one run-loop turn: a git refresh can't clear
            // them in between.
            worktreeWorkspace.prInfo = pullRequest(state: "MERGED")
            mainCheckout.prInfo = pullRequest(state: "MERGED")
            shell.updateSidebar()
            XCTAssertEqual(cleanupTexts(in: shell.sidebar), [], "merged, but in the main checkout")

            shell.focusColumnByIndex(0)
            waitForGitContext(of: worktreeWorkspace, at: harness.worktree, shell: shell, harness: harness)
            worktreeWorkspace.prInfo = pullRequest(state: "OPEN")
            shell.updateSidebar()
            XCTAssertEqual(cleanupTexts(in: shell.sidebar), [], "open")

            worktreeWorkspace.prInfo = pullRequest(state: "MERGED")
            shell.updateSidebar()
            XCTAssertEqual(cleanupTexts(in: shell.sidebar), ["Clean up"])

            let worktreeIndex = try XCTUnwrap(shell.workspaces.firstIndex { $0 === worktreeWorkspace })
            let link = try XCTUnwrap(cleanupLink(in: shell.sidebar))
            guard case .link(let url, _) = link.region else { return XCTFail("not a link") }
            XCTAssertEqual(url, SidebarView.cleanupActionURL(workspaceIndex: worktreeIndex))

            try click(link.frame, in: shell.sidebar, window: harness.window)
            XCTAssertEqual(cleanupTexts(in: shell.sidebar), ["Cleaning up…"])
            XCTAssertNil(cleanupLink(in: shell.sidebar), "a second click does nothing")
            // No GitHub remote: the checks refuse, and nothing goes.
            harness.waitUntil("the clean-up verdict") { !harness.alerts.isEmpty && shell.worktreeCleanupsInFlight.isEmpty }
            XCTAssertTrue(harness.alerts.last?.hasPrefix("Can’t clean up") == true, "\(harness.alerts)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: harness.worktree))
            worktreeWorkspace.prInfo = pullRequest(state: "MERGED")
            shell.updateSidebar()
            XCTAssertEqual(cleanupTexts(in: shell.sidebar), ["Clean up"])
        }
    }

    private func waitForGitContext(of workspace: WorkspaceState, at folder: String, shell: NiruxShellView, harness: UIFlowHarness) {
        let expected = NiruxShellView.comparablePath(folder)
        XCTAssertEqual(NiruxShellView.comparablePath(workspace.focusedWorkingDirectory), expected)
        shell.refreshGitContextNow(for: workspace)
        harness.waitUntil("the git context of \(folder)") {
            workspace.gitContext.map { NiruxShellView.comparablePath($0.identity.repositoryRoot) } == expected
        }
    }

    private func pullRequest(state: String) -> PRInfo {
        PRInfo(
            number: 7, state: state, isDraft: false, ciStatus: nil, failedCheckUrl: nil, reviewDecision: nil,
            mergeable: nil, url: "https://example.test/pull/7", additions: nil, deletions: nil, changedFiles: nil
        )
    }

    /// What follows "#7 merged ·" on the cards.
    private func cleanupTexts(in sidebar: SidebarView) -> [String] {
        sidebar.expandedViews.compactMap { ($0 as? NSTextField)?.stringValue }
            .filter { $0 == "Clean up" || $0 == "Cleaning up…" }
    }

    private func cleanupLink(in sidebar: SidebarView) -> SidebarHitArea? {
        sidebar.hitAreas.first { area in
            guard case .link(let url, _) = area.region else { return false }
            return url.hasPrefix("action:cleanup:")
        }
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
