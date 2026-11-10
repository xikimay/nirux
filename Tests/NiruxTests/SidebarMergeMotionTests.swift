import AppKit
import XCTest
@testable import Nirux

/// The merge on a task's row: the checks' ring, the check drawn when they
/// pass, the sweep at the merge, and the row folding away when its task is
/// archived or closed.
@MainActor
final class SidebarMergeMotionTests: XCTestCase {
    /// A clock the test moves by hand.
    private final class Clock {
        var time: CFTimeInterval = 9_000
    }

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

    private func sidebar(_ rows: [WorkspaceInfo], clock: Clock = Clock()) -> SidebarView {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 660))
        sidebar.clock = { clock.time }
        sidebar.isExpanded = true
        sidebar.update(profiles: [], workspaces: rows)
        return sidebar
    }

    private func views(in sidebar: SidebarView, _ id: NSUserInterfaceItemIdentifier) -> [NSView] {
        sidebar.expandedViews.filter { $0.identifier == id }
    }

    /// The sidebar's views that lie in `frame`, itself in the sidebar's
    /// coordinates.
    private func views(in sidebar: SidebarView, inside frame: NSRect) -> [NSView] {
        sidebar.expandedViews.filter { frame.insetBy(dx: -1, dy: -1).contains(sidebar.convert($0.frame, from: $0.superview)) }
    }

    private func identities(_ views: [NSView]) -> Set<ObjectIdentifier> {
        Set(views.map(ObjectIdentifier.init))
    }

    // MARK: - The checks' ring

    /// While its checks run, a row's mark is a ring that turns, in step
    /// with every other one and under the lights' frame rate; a still,
    /// dashed one while rows may not move.
    func testRunningChecksTurnARing() throws {
        let running = row("pr", index: 0, pr: pullRequest(ci: "PENDING"))
        XCTAssertEqual(running.rowSummary.mark, .checksRunning)
        XCTAssertEqual(running.rowSummary.status.text, "#39 · checks running")

        let now: CFTimeInterval = 9_000.5
        let ring = { (animates: Bool) -> CAShapeLayer? in
            SidebarWorkspaceCardRenderer(workspace: running, sidebarWidth: 260, yOffset: 500, animates: animates, now: now)
                .render().views.first { $0.identifier == SidebarWorkspaceCardRenderer.checksRingID }?
                .layer?.sublayers?.first as? CAShapeLayer
        }
        let turning = try XCTUnwrap(ring(true))
        let turn = try XCTUnwrap(turning.animation(forKey: SidebarWorkspaceCardRenderer.checksRingKey))
        XCTAssertEqual(turn.repeatCount, .infinity)
        XCTAssertEqual(turn.preferredFrameRateRange.maximum, 15, "endless: no more frames than the lights ask for")
        let pass = SidebarWorkspaceCardRenderer.checksRingDuration
        XCTAssertEqual(turn.beginTime, now - now.truncatingRemainder(dividingBy: pass), accuracy: 0.001, "from the clock")
        XCTAssertNil(turning.lineDashPattern)
        XCTAssertLessThan(turning.strokeEnd, 1, "an arc")
        let still = try XCTUnwrap(ring(false))
        XCTAssertNil(still.animationKeys())
        XCTAssertNotNil(still.lineDashPattern)
        XCTAssertEqual(still.strokeEnd, 1, "a whole ring, dashed")

        let passed = SidebarWorkspaceCardRenderer(
            workspace: row("pr", index: 0, pr: pullRequest(ci: "SUCCESS")), sidebarWidth: 260, yOffset: 500, now: now
        ).render().views
        XCTAssertTrue(passed.allSatisfy { $0.identifier != SidebarWorkspaceCardRenderer.checksRingID })
    }

    // MARK: - Ready, merged

    /// The check is drawn when the checks pass between two refreshes, and
    /// the sweep plays when the pull request is merged between two: on
    /// their own rows, once, carried across rebuilds, and never for a row
    /// that was already so at first sight.
    func testChecksPassingAndTheMergePlayOnce() throws {
        let clock = Clock()
        let before = [
            row("ready", index: 0, pr: pullRequest(ci: "SUCCESS")), row("merged", index: 1, pr: pullRequest("MERGED")),
            row("running", index: 2, pr: pullRequest(ci: "PENDING")), row("open", index: 3, pr: pullRequest(ci: "SUCCESS")),
            row("loading", index: 4)
        ]
        let sidebar = sidebar(before, clock: clock)
        XCTAssertTrue(sidebar.readyAt.isEmpty, "already ready at first sight")
        XCTAssertTrue(sidebar.mergedAt.isEmpty, "already merged at first sight")
        XCTAssertTrue(views(in: sidebar, SidebarWorkspaceCardRenderer.mergeSweepID).isEmpty)
        XCTAssertTrue(views(in: sidebar, SidebarWorkspaceCardRenderer.turnEndCheckID).isEmpty)

        let after = [
            before[0], before[1], row("running", index: 2, pr: pullRequest(ci: "SUCCESS")),
            row("open", index: 3, pr: pullRequest("MERGED")),
            // Its pull request's state was only just read: merged long ago.
            row("loading", index: 4, pr: pullRequest("MERGED"))
        ]
        clock.time += 10
        let moment = clock.time
        sidebar.update(profiles: [], workspaces: after)
        XCTAssertEqual(sidebar.readyAt, ["running": moment])
        XCTAssertEqual(sidebar.mergedAt, ["open": moment])

        let sweeps = views(in: sidebar, SidebarWorkspaceCardRenderer.mergeSweepID)
        XCTAssertEqual(sweeps.count, 1)
        let sweep = try XCTUnwrap(sweeps.first)
        let merged = try XCTUnwrap(sidebar.rowFrame(workspaceID: "open"))
        XCTAssertEqual(sidebar.convert(sweep.frame, from: sweep.superview), merged, "across its own row")
        XCTAssertEqual(sweep.layer?.masksToBounds, true, "and no further")
        let band = try XCTUnwrap(sweep.layer?.sublayers?.first)
        XCTAssertLessThanOrEqual(band.frame.maxX, 0, "out of sight at rest")
        XCTAssertEqual(band.animation(forKey: SidebarWorkspaceCardRenderer.mergeSweepKey)?.beginTime, moment)
        XCTAssertNotEqual(band.animation(forKey: SidebarWorkspaceCardRenderer.mergeSweepKey)?.repeatCount, .infinity)

        let checks = views(in: sidebar, SidebarWorkspaceCardRenderer.turnEndCheckID)
        XCTAssertEqual(checks.count, 1)
        let check = try XCTUnwrap(checks.first)
        let ready = try XCTUnwrap(sidebar.rowFrame(workspaceID: "running"))
        XCTAssertTrue(ready.contains(sidebar.convert(check.frame, from: check.superview)), "on the row whose checks passed")
        let stroke = try XCTUnwrap(check.layer?.sublayers?.first)
        XCTAssertEqual(stroke.opacity, 0, "gone by itself")
        XCTAssertEqual(stroke.animation(forKey: SidebarWorkspaceCardRenderer.checkDrawKey)?.beginTime, moment)
        XCTAssertEqual(stroke.animation(forKey: "show")?.duration, SidebarWorkspaceCardRenderer.readyCheckDuration)

        // A rebuild in the middle: both carry on from the same moment.
        clock.time = moment + 0.3
        sidebar.update(profiles: [], workspaces: after + [row("another", index: 5)])
        XCTAssertEqual(
            views(in: sidebar, SidebarWorkspaceCardRenderer.mergeSweepID).first?.layer?.sublayers?.first?
                .animation(forKey: SidebarWorkspaceCardRenderer.mergeSweepKey)?.beginTime, moment
        )
        XCTAssertEqual(
            views(in: sidebar, SidebarWorkspaceCardRenderer.turnEndCheckID).first?.layer?.sublayers?.first?
                .animation(forKey: SidebarWorkspaceCardRenderer.checkDrawKey)?.beginTime, moment
        )

        // Over: nothing is built again, and both are forgotten.
        clock.time = moment + 5
        sidebar.update(profiles: [], workspaces: after)
        XCTAssertTrue(views(in: sidebar, SidebarWorkspaceCardRenderer.mergeSweepID).isEmpty)
        XCTAssertTrue(views(in: sidebar, SidebarWorkspaceCardRenderer.turnEndCheckID).isEmpty)
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

    /// An archived task's row folds away where it was, the tasks that
    /// were under it come up, and the Archived count bumps. Nothing else
    /// moves: not the rows above, not the Archived row itself.
    func testAnArchivedRowFoldsAndTheCountBumps() throws {
        let clock = Clock()
        let rows = [row("above", index: 0), row("leaving", index: 1), row("under", index: 2)]
        let sidebar = sidebar(rows, clock: clock)
        let leaving = try XCTUnwrap(sidebar.rowFrame(workspaceID: "leaving"))

        clock.time += 10
        let moment = clock.time
        let after = [rows[0], row("leaving", index: 1, archived: true), rows[2]]
        sidebar.update(profiles: [], workspaces: after)
        XCTAssertEqual(sidebar.folds.map(\.workspaceID), ["leaving"])
        XCTAssertEqual(sidebar.folds.first?.under, ["under"])
        XCTAssertEqual(sidebar.archivedBumpAt, moment)

        let ghost = try XCTUnwrap(views(in: sidebar, SidebarView.foldGhostID).first)
        XCTAssertEqual(views(in: sidebar, SidebarView.foldGhostID).count, 1)
        XCTAssertEqual(sidebar.convert(ghost.frame, from: ghost.superview), leaving, "where the row was")
        XCTAssertNotNil(ghost.layer?.contents, "its picture")
        XCTAssertEqual(ghost.alphaValue, 0, "gone unless its fold runs")
        XCTAssertNil(ghost.hitTest(NSPoint(x: ghost.frame.midX, y: ghost.frame.midY)), "it takes no click")
        let leave = try XCTUnwrap(ghost.layer?.animation(forKey: SidebarView.foldLeaveKey))
        XCTAssertEqual(leave.beginTime, moment)
        XCTAssertEqual(leave.fillMode, .backwards)

        let pullKey = SidebarView.foldPullKey("leaving")
        let pulled = sidebar.expandedViews.filter { $0.layer?.animation(forKey: pullKey) != nil }
        let under = try XCTUnwrap(sidebar.rowFrame(workspaceID: "under"))
        XCTAssertFalse(pulled.isEmpty)
        XCTAssertEqual(identities(pulled), identities(views(in: sidebar, inside: under)), "the task under it, all of it")
        let pull = try XCTUnwrap(pulled.first?.layer?.animation(forKey: pullKey) as? CASpringAnimation)
        XCTAssertEqual(
            (pull.fromValue as? NSNumber)?.doubleValue, -Double(leaving.height + SidebarExpandedMetrics.workspaceGap),
            "from where it was, one row lower"
        )
        XCTAssertEqual(pull.beginTime, moment)
        XCTAssertTrue(pull.isAdditive)
        let above = try XCTUnwrap(sidebar.rowFrame(workspaceID: "above"))
        XCTAssertTrue(views(in: sidebar, inside: above).allSatisfy { $0.layer?.animationKeys() == nil }, "the rows above stay")

        let count = try XCTUnwrap(sidebar.archivedCountLabel)
        XCTAssertEqual(count.stringValue, "1")
        XCTAssertEqual(count.layer?.animation(forKey: SidebarView.archivedBumpKey)?.beginTime, moment)
        XCTAssertEqual(count.layer?.animation(forKey: SidebarView.archivedBumpKey)?.fillMode, .backwards)
        XCTAssertNil(count.layer?.animation(forKey: pullKey), "the Archived row didn't move")

        // A rebuild in the middle carries on from the same moment.
        clock.time = moment + 0.2
        sidebar.update(profiles: [], workspaces: after + [row("another", index: 3)])
        XCTAssertEqual(
            views(in: sidebar, SidebarView.foldGhostID).first?.layer?.animation(forKey: SidebarView.foldLeaveKey)?.beginTime,
            moment
        )

        // Over: nothing is built again, and it is forgotten.
        clock.time = moment + 2
        sidebar.update(profiles: [], workspaces: after)
        XCTAssertTrue(views(in: sidebar, SidebarView.foldGhostID).isEmpty)
        XCTAssertTrue(sidebar.expandedViews.allSatisfy { $0.layer?.animationKeys() == nil })
        XCTAssertTrue(sidebar.folds.isEmpty)
        XCTAssertNil(sidebar.archivedBumpAt)
    }

    /// A closed task's row folds without a bump. Two that leave together:
    /// the task that was under both comes up for both.
    func testClosedRowsFoldWithoutABump() throws {
        let rows = [row("first", index: 0), row("second", index: 1), row("under", index: 2)]
        let sidebar = sidebar(rows)
        sidebar.update(profiles: [], workspaces: [row("under", index: 0)])
        XCTAssertEqual(Set(sidebar.folds.map(\.workspaceID)), ["first", "second"])
        XCTAssertNil(sidebar.archivedBumpAt)
        XCTAssertEqual(views(in: sidebar, SidebarView.foldGhostID).count, 2)
        let under = views(in: sidebar, inside: try XCTUnwrap(sidebar.rowFrame(workspaceID: "under")))
            .filter { $0.identifier != SidebarView.foldGhostID }
        XCTAssertFalse(under.isEmpty)
        for view in under {
            XCTAssertNotNil(view.layer?.animation(forKey: SidebarView.foldPullKey("first")))
            XCTAssertNotNil(view.layer?.animation(forKey: SidebarView.foldPullKey("second")))
        }
    }

    /// Nothing folds, sweeps or bumps while rows may not move, nor at a
    /// rebuild after motion went off; an archived row that comes back, or
    /// one that was archived all along, folds nothing.
    func testNothingPlaysWithoutMovementOrWithoutADeparture() {
        let rows = [row("a", index: 0, pr: pullRequest(ci: "SUCCESS")), row("b", index: 1), row("old", index: 2, archived: true)]
        let changed = [row("a", index: 0, pr: pullRequest("MERGED")), row("b", index: 1, archived: true), rows[2]]
        let still = sidebar(rows)
        still.animates = false
        still.update(profiles: [], workspaces: changed)
        XCTAssertTrue(still.mergedAt.isEmpty)
        XCTAssertTrue(still.folds.isEmpty)
        XCTAssertNil(still.archivedBumpAt)
        XCTAssertTrue(views(in: still, SidebarView.foldGhostID).isEmpty)

        let stopped = sidebar(rows)
        stopped.update(profiles: [], workspaces: changed)
        XCTAssertEqual(views(in: stopped, SidebarView.foldGhostID).count, 1)
        stopped.animates = false
        XCTAssertTrue(views(in: stopped, SidebarView.foldGhostID).isEmpty, "motion went off in the middle")
        XCTAssertTrue(views(in: stopped, SidebarWorkspaceCardRenderer.mergeSweepID).isEmpty)
        XCTAssertTrue(stopped.expandedViews.allSatisfy { $0.layer?.animationKeys() == nil })

        let moving = sidebar(rows)
        moving.update(profiles: [], workspaces: [rows[0], rows[1], row("old", index: 2)])
        XCTAssertTrue(moving.folds.isEmpty, "back from the archive")
        moving.update(profiles: [], workspaces: [rows[0], rows[1]])
        XCTAssertEqual(moving.folds.count, 1, "an active row that goes")
        let archivedGone = sidebar(rows)
        archivedGone.update(profiles: [], workspaces: [rows[0], rows[1]])
        XCTAssertTrue(archivedGone.folds.isEmpty, "an archived row that goes folds nothing")
    }

    /// A list taller than the sidebar scrolls: the row folds, and no row
    /// is pulled from a place it may never have had on screen.
    func testNoRowIsPulledInAListThatScrolls() {
        let rows = (0..<40).map { row("task-\($0)", index: $0) }
        let sidebar = sidebar(rows)
        sidebar.update(profiles: [], workspaces: rows.filter { $0.id != "task-5" })
        XCTAssertGreaterThan(sidebar.contentDocumentView.frame.height, sidebar.bounds.height, "it scrolls")
        XCTAssertEqual(views(in: sidebar, SidebarView.foldGhostID).count, 1)
        XCTAssertTrue(sidebar.expandedViews.allSatisfy { $0.layer?.animation(forKey: SidebarView.foldPullKey("task-5")) == nil })
    }
}
