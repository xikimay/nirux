import AppKit
import XCTest
@testable import Nirux

/// The merge on a task's row: the checks' ring, the check drawn when they
/// pass, the sweep at the merge, and the row folding away when its task is
/// archived or closed.
@MainActor
final class SidebarMergeMotionTests: XCTestCase {
    private func pullRequest(_ state: String = "OPEN", ci: String? = nil) -> PRInfo {
        PRInfo(
            number: 39, state: state, isDraft: false, ciStatus: ci, checks: [], reviewDecision: nil, mergeable: nil,
            url: "https://example.test/pull/39", additions: nil, deletions: nil, changedFiles: nil
        )
    }

    private func row(_ id: String, index: Int, pr: PRInfo? = nil, archived: Bool = false) -> WorkspaceInfo {
        WorkspaceInfo(
            id: id, index: index, title: id, profileID: WorkspaceProfile.defaultID, isInactive: archived, columnCount: 0,
            focusedColumn: 0, gitBranch: "feat/\(id)", notification: nil, isActive: false, columns: [], prInfo: pr,
            diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: archived ? .parked : .active,
            lastSummary: nil, lastActivityAt: nil
        )
    }

    private func sidebar(_ rows: [WorkspaceInfo]) -> SidebarView {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 660))
        sidebar.isExpanded = true
        sidebar.update(profiles: [], workspaces: rows)
        return sidebar
    }

    private func views(in sidebar: SidebarView, _ id: NSUserInterfaceItemIdentifier) -> [NSView] {
        sidebar.expandedViews.filter { $0.identifier == id }
    }

    // MARK: - The checks' ring

    /// While its checks run, a row's mark is a ring that turns; a still,
    /// dashed one while rows may not move.
    func testRunningChecksTurnARing() throws {
        let running = row("pr", index: 0, pr: pullRequest(ci: "PENDING"))
        XCTAssertEqual(running.rowSummary.mark, .checksRunning)
        XCTAssertEqual(running.rowSummary.status.text, "#39 · checks running")

        let ring = { (animates: Bool) -> CAShapeLayer? in
            SidebarWorkspaceCardRenderer(workspace: running, sidebarWidth: 260, yOffset: 500, animates: animates).render()
                .views.first { $0.identifier == SidebarWorkspaceCardRenderer.checksRingID }?.layer?.sublayers?.first as? CAShapeLayer
        }
        let turning = try XCTUnwrap(ring(true))
        XCTAssertEqual(turning.animation(forKey: SidebarWorkspaceCardRenderer.checksRingKey)?.repeatCount, .infinity)
        XCTAssertNil(turning.lineDashPattern)
        let still = try XCTUnwrap(ring(false))
        XCTAssertNil(still.animation(forKey: SidebarWorkspaceCardRenderer.checksRingKey))
        XCTAssertNotNil(still.lineDashPattern)

        let passed = SidebarWorkspaceCardRenderer(
            workspace: row("pr", index: 0, pr: pullRequest(ci: "SUCCESS")), sidebarWidth: 260, yOffset: 500
        ).render().views
        XCTAssertTrue(passed.allSatisfy { $0.identifier != SidebarWorkspaceCardRenderer.checksRingID })
    }

    // MARK: - Ready, merged

    /// The check is drawn when the checks pass between two refreshes, and
    /// the sweep plays when the pull request is merged between two: never
    /// for a row that was already there at first sight.
    func testChecksPassingAndTheMergePlayOnce() {
        let now = CACurrentMediaTime()
        let sidebar = sidebar([
            row("ready", index: 0, pr: pullRequest(ci: "SUCCESS")), row("merged", index: 1, pr: pullRequest("MERGED")),
            row("running", index: 2, pr: pullRequest(ci: "PENDING")), row("open", index: 3, pr: pullRequest(ci: "SUCCESS")),
            row("loading", index: 4)
        ])
        XCTAssertTrue(sidebar.readyAt.isEmpty, "already ready at first sight")
        XCTAssertTrue(sidebar.mergedAt.isEmpty, "already merged at first sight")
        XCTAssertTrue(views(in: sidebar, SidebarWorkspaceCardRenderer.mergeSweepID).isEmpty)

        sidebar.update(profiles: [], workspaces: [
            row("ready", index: 0, pr: pullRequest(ci: "SUCCESS")), row("merged", index: 1, pr: pullRequest("MERGED")),
            row("running", index: 2, pr: pullRequest(ci: "SUCCESS")), row("open", index: 3, pr: pullRequest("MERGED")),
            // Its pull request's state was only just read: merged long ago.
            row("loading", index: 4, pr: pullRequest("MERGED"))
        ])
        XCTAssertEqual(Array(sidebar.readyAt.keys), ["running"])
        XCTAssertEqual(Array(sidebar.mergedAt.keys), ["open"])
        XCTAssertEqual(views(in: sidebar, SidebarWorkspaceCardRenderer.mergeSweepID).count, 1)
        XCTAssertEqual(views(in: sidebar, SidebarWorkspaceCardRenderer.turnEndCheckID).count, 1, "the check, drawn")

        // Once played they are forgotten.
        sidebar.noteRowMoments(from: [], to: [row("x", index: 0)], now: now + 5)
        XCTAssertTrue(sidebar.readyAt.isEmpty)
        XCTAssertTrue(sidebar.mergedAt.isEmpty)
    }

    /// Another space coming on screen lists other rows: nothing of theirs
    /// plays, and nothing folds.
    func testASpaceSwitchPlaysNothing() {
        let here = ProfileInfo(id: "a", name: "a", colorHex: "#7AA2F7", isActive: true, workspaceCount: 1, taskCount: 1, attention: nil)
        let there = ProfileInfo(id: "b", name: "b", colorHex: "#7AA2F7", isActive: true, workspaceCount: 1, taskCount: 1, attention: nil)
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 660))
        sidebar.isExpanded = true
        sidebar.update(profiles: [here], workspaces: [row("pr", index: 0, pr: pullRequest(ci: "SUCCESS")), row("other", index: 1)])
        sidebar.update(profiles: [there], workspaces: [row("pr", index: 0, pr: pullRequest("MERGED"))])
        XCTAssertTrue(sidebar.mergedAt.isEmpty)
        XCTAssertTrue(sidebar.folds.isEmpty)
        XCTAssertNil(sidebar.archivedBumpAt)
    }

    // MARK: - The fold

    /// An archived task's row folds away where it was, the tasks under it
    /// come up, and the Archived count bumps. A closed one folds without a
    /// bump. The rows above don't move.
    func testAnArchivedRowFoldsAndTheCountBumps() throws {
        let rows = [row("above", index: 0), row("leaving", index: 1), row("under", index: 2)]
        let sidebar = sidebar(rows)
        let leaving = try XCTUnwrap(sidebar.rowFrame(workspaceID: "leaving"))

        sidebar.update(profiles: [], workspaces: [rows[0], row("leaving", index: 1, archived: true), rows[2]])
        XCTAssertEqual(sidebar.folds.count, 1)
        XCTAssertNotNil(sidebar.archivedBumpAt)
        let ghost = try XCTUnwrap(views(in: sidebar, SidebarView.foldGhostID).first)
        XCTAssertEqual(sidebar.convert(ghost.frame, from: ghost.superview), leaving, "where the row was")
        XCTAssertNotNil(ghost.layer?.animation(forKey: SidebarView.foldLeaveKey))
        let pulled = sidebar.expandedViews.filter { $0.layer?.animation(forKey: SidebarView.foldPullKey) != nil }
        let under = try XCTUnwrap(sidebar.rowFrame(workspaceID: "under"))
        let above = try XCTUnwrap(sidebar.rowFrame(workspaceID: "above"))
        let frame = { (view: NSView) in sidebar.convert(view.frame, from: view.superview) }
        XCTAssertFalse(pulled.isEmpty)
        XCTAssertTrue(pulled.allSatisfy { under.insetBy(dx: -1, dy: -1).contains(frame($0)) }, "only the task under it")
        XCTAssertFalse(pulled.contains { above.insetBy(dx: -1, dy: -1).contains(frame($0)) })
        XCTAssertNotNil(sidebar.archivedCountLabel?.layer?.animation(forKey: SidebarView.archivedBumpKey))
        XCTAssertEqual(sidebar.archivedCountLabel?.stringValue, "1")

        // Closed: gone from the list, not archived.
        let closing = self.sidebar(rows)
        closing.update(profiles: [], workspaces: [rows[0], rows[2]])
        XCTAssertEqual(closing.folds.count, 1)
        XCTAssertNil(closing.archivedBumpAt)
        XCTAssertEqual(views(in: closing, SidebarView.foldGhostID).count, 1)
    }

    /// Nothing folds, sweeps or bumps while rows may not move, and an
    /// archived row that comes back, or one that was archived all along,
    /// folds nothing.
    func testNothingPlaysWithoutMovementOrWithoutADeparture() {
        let rows = [row("a", index: 0, pr: pullRequest(ci: "SUCCESS")), row("b", index: 1), row("old", index: 2, archived: true)]
        let still = sidebar(rows)
        still.animates = false
        still.update(profiles: [], workspaces: [row("a", index: 0, pr: pullRequest("MERGED")), row("b", index: 1, archived: true), rows[2]])
        XCTAssertTrue(still.mergedAt.isEmpty)
        XCTAssertTrue(still.folds.isEmpty)
        XCTAssertNil(still.archivedBumpAt)
        XCTAssertTrue(views(in: still, SidebarView.foldGhostID).isEmpty)

        let moving = sidebar(rows)
        moving.update(profiles: [], workspaces: [rows[0], rows[1], row("old", index: 2)])
        XCTAssertTrue(moving.folds.isEmpty, "back from the archive")
        moving.update(profiles: [], workspaces: [rows[0], rows[1]])
        XCTAssertEqual(moving.folds.count, 1, "an active row that goes")
        let archivedGone = sidebar(rows)
        archivedGone.update(profiles: [], workspaces: [rows[0], rows[1]])
        XCTAssertTrue(archivedGone.folds.isEmpty, "an archived row that goes folds nothing")
    }
}
