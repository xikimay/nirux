import AppKit
import XCTest
@testable import Nirux

/// Living rows: the line of light under a task whose agent works, and the
/// check its mark draws when a turn ends.
@MainActor
final class SidebarRowMotionTests: XCTestCase {
    private func column(_ status: AgentStatus = .idle, reason: AgentAttentionReason? = nil) -> ColumnInfo {
        ColumnInfo(
            index: 0, processName: "claude", abbreviatedCwd: nil, isFocused: false, isWebView: false, webTitle: nil,
            terminalTitle: nil, agentStatus: status, isEditor: false, editorFileName: nil, attentionReason: reason
        )
    }

    private func row(
        _ columns: [ColumnInfo], id: String = "ws", index: Int = 0, isLead: Bool = false, archived: Bool = false,
        pullRequest: PRInfo? = nil
    ) -> WorkspaceInfo {
        WorkspaceInfo(
            id: id, index: index, title: "checkout", profileID: WorkspaceProfile.defaultID, isInactive: archived,
            columnCount: columns.count, focusedColumn: 0, gitBranch: "feat/checkout", notification: nil, isActive: false,
            columns: columns, prInfo: pullRequest, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil,
            phase: archived ? .parked : .active, lastSummary: nil, lastActivityAt: nil, isLead: isLead
        )
    }

    private var finished: ColumnInfo { column(.needsAttention, reason: .turnFinished) }
    private let permission = AgentAttentionReason.permission(tool: "Bash", summary: "x")
    private let now: CFTimeInterval = 5_000

    private func views(
        _ info: WorkspaceInfo, animates: Bool = true, turnEndedAt: CFTimeInterval? = nil
    ) -> [NSView] {
        SidebarWorkspaceCardRenderer(
            workspace: info, sidebarWidth: 260, yOffset: 500, animates: animates, turnEndedAt: turnEndedAt, now: now
        ).render().views
    }

    private func lines(in views: [NSView]) -> [NSView] {
        views.filter { $0.identifier == SidebarWorkspaceCardRenderer.workingLineID }
    }

    private func checks(in views: [NSView]) -> [NSView] {
        views.filter { $0.identifier == SidebarWorkspaceCardRenderer.turnEndCheckID }
    }

    private func sidebar(_ rows: [WorkspaceInfo]) -> SidebarView {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 660))
        sidebar.isExpanded = true
        sidebar.update(profiles: [], workspaces: rows)
        return sidebar
    }

    // MARK: - The working line

    /// One thin line along the bottom of a working row, running for as
    /// long as the agent works, in step with every other row's and under
    /// the lights' frame rate; the dot itself stands still.
    func testAWorkingRowRunsALineOfLight() throws {
        let rendered = SidebarWorkspaceCardRenderer(
            workspace: row([column(.working)]), sidebarWidth: 260, yOffset: 500, now: now
        ).render()
        let line = try XCTUnwrap(lines(in: rendered.views).first)
        XCTAssertEqual(lines(in: rendered.views).count, 1)
        let band = try XCTUnwrap(line.layer?.sublayers?.first)
        let run = try XCTUnwrap(band.animation(forKey: SidebarWorkspaceCardRenderer.workingLineKey))
        XCTAssertEqual(run.repeatCount, .infinity)
        XCTAssertLessThanOrEqual(run.preferredFrameRateRange.maximum, 15, "no more frames than the lights ask for")
        // Timed from the clock: wherever the row is rebuilt, its pass
        // began when the clock's did.
        let pass = SidebarWorkspaceCardRenderer.workingLineDuration
        XCTAssertEqual(run.beginTime, now - now.truncatingRemainder(dividingBy: pass), accuracy: 0.001)
        XCTAssertEqual(run.timeOffset, 0)
        // The band rests out of sight, and what leaves the line is cut.
        XCTAssertLessThanOrEqual(band.frame.maxX, 0)
        XCTAssertEqual(line.layer?.masksToBounds, true)
        let rowFrame = try XCTUnwrap(rendered.hitAreas.last?.frame)
        XCTAssertTrue(rowFrame.contains(line.frame), "inside the row")
        XCTAssertLessThan(line.frame.minY - rowFrame.minY, 3, "along its bottom edge")
        XCTAssertLessThanOrEqual(line.frame.height, 2, "thin")
        XCTAssertTrue(rendered.views.allSatisfy { $0.layer?.animation(forKey: "breathe") == nil }, "one movement, not two")

        XCTAssertEqual(lines(in: views(row([column(.working)], isLead: true))).count, 1, "the Lead's row too")
        XCTAssertTrue(views(row([column(.working)], isLead: true)).allSatisfy { $0.layer?.animation(forKey: "breathe") == nil })
    }

    /// No line without work, nor while rows may not move; a row that
    /// needs the user says so, even while another of its columns works.
    func testNoLineWithoutWorkOrWithoutMovement() {
        XCTAssertEqual(lines(in: views(row([column()]))).count, 0)
        let waiting = row([column(.needsAttention, reason: permission), column(.working)])
        XCTAssertEqual(waiting.rowSummary.mark, .needsYou)
        XCTAssertEqual(lines(in: views(waiting)).count, 0)
        XCTAssertEqual(lines(in: views(row([column(.working)]), animates: false)).count, 0)
    }

    // MARK: - The turn end's check

    /// A turn that just ended draws a check where the mark is, and the
    /// grey dot waits for it. Both are timed from the turn's end, so a
    /// rebuilt row carries on; once the time is over the dot alone shows.
    func testATurnsEndDrawsACheckThenTheDot() throws {
        let done = row([finished])
        XCTAssertEqual(done.rowSummary.mark, .idle)

        let during = views(done, turnEndedAt: now - 0.5)
        let check = try XCTUnwrap(checks(in: during).first?.layer?.sublayers?.first)
        XCTAssertEqual(check.opacity, 0, "gone by itself once its time is over")
        let draw = try XCTUnwrap(check.animation(forKey: SidebarWorkspaceCardRenderer.checkDrawKey))
        let show = try XCTUnwrap(check.animation(forKey: "show") as? CAKeyframeAnimation)
        XCTAssertEqual(show.values?.first as? Int, 1, "visible while it draws")
        XCTAssertEqual(show.values?.last as? Int, 0)
        let waiting = during.compactMap { $0.layer?.animation(forKey: "wait") as? CAKeyframeAnimation }
        XCTAssertEqual(waiting.count, 1, "the dot waits its turn")
        XCTAssertEqual(waiting.first?.values?.first as? Int, 0)
        XCTAssertEqual(waiting.first?.values?.last as? Int, 1)
        for animation in [draw, show, try XCTUnwrap(waiting.first)] as [CAAnimation] {
            XCTAssertEqual(animation.beginTime, now - 0.5, "from the turn's end, not from this rebuild")
            XCTAssertEqual(animation.fillMode, .backwards)
        }

        let after = views(done, turnEndedAt: now - SidebarWorkspaceCardRenderer.checkDuration)
        XCTAssertEqual(checks(in: after).count, 0)
        XCTAssertTrue(after.allSatisfy { $0.layer?.animation(forKey: "wait") == nil })

        XCTAssertEqual(checks(in: views(done)).count, 0, "no turn ended")
        XCTAssertEqual(checks(in: views(done, animates: false, turnEndedAt: now)).count, 0, "rows may not move")
    }

    /// The check takes the grey dot's place on a task's full row, nowhere
    /// else: a row that says something else keeps its mark, an archived
    /// task's compact row stays quiet, and the Lead's row has no grey dot.
    func testOnlyATasksGreyDotDrawsTheCheck() {
        XCTAssertEqual(checks(in: views(row([finished]), turnEndedAt: now)).count, 1, "a grey dot")
        XCTAssertEqual(checks(in: views(row([column()]), turnEndedAt: now)).count, 1, "its branch line: grey as well")

        let stillWorking = row([finished, column(.working)])
        XCTAssertEqual(checks(in: views(stillWorking, turnEndedAt: now)).count, 0)
        let waiting = row([column(.needsAttention, reason: permission)])
        XCTAssertEqual(checks(in: views(waiting, turnEndedAt: now)).count, 0)
        let broke = row([column()], pullRequest: PRInfo(
            number: 7, state: "OPEN", isDraft: false, ciStatus: "FAILURE", checks: [], reviewDecision: nil, mergeable: nil,
            url: "https://example.test/pull/7", additions: nil, deletions: nil, changedFiles: nil
        ))
        XCTAssertEqual(broke.rowSummary.mark, .error)
        XCTAssertEqual(checks(in: views(broke, turnEndedAt: now)).count, 0)

        let archived = row([column()], archived: true)
        XCTAssertTrue(archived.showsCompactRow)
        XCTAssertEqual(checks(in: views(archived, turnEndedAt: now)).count, 0)
        XCTAssertEqual(checks(in: views(row([finished], isLead: true), turnEndedAt: now)).count, 0)
    }

    // MARK: - In the sidebar

    /// The sidebar redraws the row whose turn ended, that row only, keeps
    /// the check across its other rebuilds, and forgets it once it is over.
    func testTheSidebarShowsATurnsEndOnItsRow() throws {
        let other = row([column()], id: "other", index: 1)
        let sidebar = sidebar([row([finished]), other])
        XCTAssertEqual(checks(in: sidebar.expandedViews).count, 0)

        let start = CACurrentMediaTime()
        sidebar.noteTurnEnded(workspaceIDs: ["ws"], now: start)
        XCTAssertEqual(Array(sidebar.turnEndNotedAt.keys), ["ws"])
        let check = try XCTUnwrap(checks(in: sidebar.expandedViews).first)
        XCTAssertEqual(checks(in: sidebar.expandedViews).count, 1)
        // Both in the list's own coordinates.
        let ownRow = try XCTUnwrap(sidebar.hitAreas.first { area in
            if case .workspace(0) = area.region { return true }
            return false
        }?.frame)
        XCTAssertTrue(ownRow.contains(check.frame), "its row, not the other")

        // Another rebuild in the middle: the check carries on, timed from
        // the same moment.
        sidebar.update(profiles: [], workspaces: [row([finished]), row([column(.working)], id: "other", index: 1)])
        let rebuilt = try XCTUnwrap(checks(in: sidebar.expandedViews).first)
        XCTAssertFalse(rebuilt === check, "a new view")
        XCTAssertEqual(
            rebuilt.layer?.sublayers?.first?.animation(forKey: SidebarWorkspaceCardRenderer.checkDrawKey)?.beginTime, start
        )

        sidebar.noteTurnEnded(workspaceIDs: [], now: start + 0.5)
        XCTAssertEqual(Array(sidebar.turnEndNotedAt.keys), ["ws"], "still drawing")
        sidebar.noteTurnEnded(workspaceIDs: [], now: start + SidebarWorkspaceCardRenderer.checkDuration + 0.1)
        XCTAssertTrue(sidebar.turnEndNotedAt.isEmpty)
    }

    /// Nothing is noted, and nothing rebuilt, for a turn end that can't
    /// show now: a row that says something else (its check must not pop
    /// up half-drawn when the row turns grey a moment later), a folded
    /// archived row, the Lead, the rail, rows that may not move.
    func testATurnEndThatCannotShowIsNotKeptForLater() {
        let rows = [
            row([finished, column(.working)], id: "busy", index: 0), row([finished], id: "lead", index: 1, isLead: true),
            row([finished], id: "archived", index: 2, archived: true), row([finished], id: "done", index: 3)
        ]
        let sidebar = sidebar(rows)
        let built = sidebar.expandedViews.first
        sidebar.noteTurnEnded(workspaceIDs: ["busy", "lead", "archived", "gone"])
        XCTAssertTrue(sidebar.turnEndNotedAt.isEmpty)
        XCTAssertTrue(sidebar.expandedViews.first === built, "no rebuild for nothing")
        // The busy row's other agent stops a moment later: no check now.
        sidebar.update(profiles: [], workspaces: [row([finished, finished], id: "busy", index: 0)] + rows.dropFirst())
        XCTAssertEqual(checks(in: sidebar.expandedViews).count, 0)

        sidebar.isExpanded = false
        sidebar.noteTurnEnded(workspaceIDs: ["done"])
        XCTAssertTrue(sidebar.turnEndNotedAt.isEmpty, "the rail has no row to draw it on")
        sidebar.isExpanded = true
        sidebar.animates = false
        sidebar.noteTurnEnded(workspaceIDs: ["done"])
        XCTAssertTrue(sidebar.turnEndNotedAt.isEmpty, "rows may not move")

        sidebar.animates = true
        sidebar.noteTurnEnded(workspaceIDs: ["done"])
        XCTAssertEqual(Array(sidebar.turnEndNotedAt.keys), ["done"])
        XCTAssertEqual(checks(in: sidebar.expandedViews).count, 1)
    }

    /// The working rows' lines come and go with `animates`.
    func testTheSidebarsLinesFollowAnimates() {
        let sidebar = sidebar([row([column(.working)])])
        XCTAssertEqual(lines(in: sidebar.expandedViews).count, 1)
        sidebar.animates = false
        XCTAssertEqual(lines(in: sidebar.expandedViews).count, 0)
        sidebar.animates = true
        XCTAssertEqual(lines(in: sidebar.expandedViews).count, 1)
    }
}
