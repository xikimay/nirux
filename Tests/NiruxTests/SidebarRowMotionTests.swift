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

    /// A clock the test moves by hand.
    private final class Clock {
        var time: CFTimeInterval = 5_000
    }

    private func sidebar(_ rows: [WorkspaceInfo], clock: Clock = Clock()) -> SidebarView {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 660))
        sidebar.clock = { clock.time }
        sidebar.isExpanded = true
        sidebar.update(profiles: [], workspaces: rows)
        return sidebar
    }

    private func checkStart(in sidebar: SidebarView) -> CFTimeInterval? {
        checks(in: sidebar.expandedViews).first?.layer?.sublayers?.first?
            .animation(forKey: SidebarWorkspaceCardRenderer.checkDrawKey)?.beginTime
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
        XCTAssertEqual(run.preferredFrameRateRange.maximum, 15, "no more frames than the lights ask for")
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
        let check = try XCTUnwrap(checks(in: during).first?.layer?.sublayers?.first as? CAShapeLayer)
        XCTAssertEqual(check.opacity, 0, "gone by itself once its time is over")
        XCTAssertNotNil(check.path)
        XCTAssertEqual(check.strokeColor, Theme.Color.working.cgColor, "a green stroke")
        XCTAssertGreaterThan(check.lineWidth, 0)
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

        let after = views(done, turnEndedAt: now - SidebarWorkspaceCardRenderer.checkDuration - 0.01)
        XCTAssertEqual(checks(in: after).count, 0)
        XCTAssertTrue(after.allSatisfy { $0.layer?.animation(forKey: "wait") == nil })

        XCTAssertEqual(checks(in: views(done)).count, 0, "no turn ended")
        XCTAssertEqual(checks(in: views(done, animates: false, turnEndedAt: now)).count, 0, "rows may not move")
    }

    /// The check takes the grey dot's place on a task's full row, nowhere
    /// else: a row that says something else keeps its mark, and an
    /// archived task's compact row stays quiet.
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
    }

    // MARK: - In the sidebar

    /// The sidebar redraws the row whose turn ended, that row only, keeps
    /// the check across its other rebuilds, and forgets it once it is over.
    func testTheSidebarShowsATurnsEndOnItsRow() throws {
        let clock = Clock()
        let other = row([column()], id: "other", index: 1)
        let sidebar = sidebar([row([finished]), other], clock: clock)
        XCTAssertEqual(checks(in: sidebar.expandedViews).count, 0)

        let start = clock.time
        sidebar.noteTurnEnded(workspaceIDs: ["ws"])
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
        clock.time = start + 1
        sidebar.update(profiles: [], workspaces: [row([finished]), row([column(.working)], id: "other", index: 1)])
        let rebuilt = try XCTUnwrap(checks(in: sidebar.expandedViews).first)
        XCTAssertFalse(rebuilt === check, "a new view")
        XCTAssertEqual(checkStart(in: sidebar), start)

        sidebar.noteTurnEnded(workspaceIDs: [])
        XCTAssertEqual(Array(sidebar.turnEndNotedAt.keys), ["ws"], "still drawing")
        // Over: forgotten, and a rebuild draws the dot alone.
        clock.time = start + SidebarWorkspaceCardRenderer.checkDuration + 0.1
        sidebar.update(profiles: [], workspaces: [row([finished]), other])
        XCTAssertEqual(checks(in: sidebar.expandedViews).count, 0)
        sidebar.noteTurnEnded(workspaceIDs: [])
        XCTAssertTrue(sidebar.turnEndNotedAt.isEmpty)
    }

    /// Nothing is noted, and nothing rebuilt, for a turn end that can't
    /// show: a row that waits on the user, an archived task's row (compact
    /// or folded away), the Lead, the rail, rows that may not move.
    func testATurnEndThatCannotShowIsNotNoted() {
        // Archived, not compact (it offers its clean-up), and not listed
        // while Archived is folded.
        var folded = row([finished], id: "folded", index: 4, archived: true)
        folded.mergedCleanup = .available
        XCTAssertFalse(folded.showsCompactRow)
        XCTAssertEqual(folded.rowSummary.mark, .idle)
        let rows = [
            row([finished, column(.needsAttention, reason: permission)], id: "waits", index: 0),
            row([finished], id: "lead", index: 1, isLead: true),
            row([finished], id: "archived", index: 2, archived: true), row([finished], id: "done", index: 3), folded
        ]
        let sidebar = sidebar(rows)
        let built = sidebar.expandedViews.first
        for id in ["waits", "lead", "archived", "folded", "gone"] {
            sidebar.noteTurnEnded(workspaceIDs: [id])
            XCTAssertNil(sidebar.turnEndNotedAt[id], id)
            XCTAssertNil(sidebar.owedTurnEnds[id], id)
        }
        XCTAssertTrue(sidebar.expandedViews.first === built, "no rebuild for nothing")

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

        // Archived unfolded: its full row is on screen and draws its
        // check; a compact one still doesn't.
        sidebar.toggleInactiveSection()
        sidebar.noteTurnEnded(workspaceIDs: ["archived"])
        XCTAssertNil(sidebar.turnEndNotedAt["archived"])
        sidebar.noteTurnEnded(workspaceIDs: ["folded"])
        XCTAssertNotNil(sidebar.turnEndNotedAt["folded"])
    }

    /// A row still at work when its turn end is noted (Codex's closing
    /// output reads as work for a few seconds; another agent of the task
    /// works on) is owed its check: it draws from its start when the row
    /// turns grey, if that comes soon, and never half-way.
    func testARowStillAtWorkIsOwedItsCheckForAMoment() {
        let clock = Clock()
        let busy = row([finished, column(.working)], id: "busy")
        let grey = row([finished, finished], id: "busy")
        let sidebar = sidebar([busy], clock: clock)
        let start = clock.time
        sidebar.noteTurnEnded(workspaceIDs: ["busy"])
        XCTAssertTrue(sidebar.turnEndNotedAt.isEmpty, "nothing to draw on a working row")
        XCTAssertEqual(Array(sidebar.owedTurnEnds.keys), ["busy"])
        XCTAssertEqual(checks(in: sidebar.expandedViews).count, 0)

        // Still at work at the next refresh: still owed.
        clock.time = start + 1
        sidebar.update(profiles: [], workspaces: [busy])
        XCTAssertEqual(Array(sidebar.owedTurnEnds.keys), ["busy"])

        // It turns grey: the check starts now, not when it was noted.
        clock.time = start + 3
        sidebar.update(profiles: [], workspaces: [grey])
        XCTAssertEqual(checks(in: sidebar.expandedViews).count, 1)
        XCTAssertEqual(checkStart(in: sidebar), start + 3)
        XCTAssertTrue(sidebar.owedTurnEnds.isEmpty)

        // Too late: no check for old news.
        let late = self.sidebar([busy], clock: clock)
        late.noteTurnEnded(workspaceIDs: ["busy"])
        clock.time += SidebarView.turnEndGrace + 0.1
        late.update(profiles: [], workspaces: [grey])
        XCTAssertEqual(checks(in: late.expandedViews).count, 0)
        XCTAssertTrue(late.owedTurnEnds.isEmpty)

        // Something else to say by then: the row's wait, not a check.
        let asked = self.sidebar([busy], clock: clock)
        asked.noteTurnEnded(workspaceIDs: ["busy"])
        clock.time += 1
        asked.update(profiles: [], workspaces: [row([finished, column(.needsAttention, reason: permission)], id: "busy")])
        XCTAssertTrue(asked.owedTurnEnds.isEmpty)
        clock.time += 1
        asked.update(profiles: [], workspaces: [grey])
        XCTAssertEqual(checks(in: asked.expandedViews).count, 0)

        // Rows may no longer move: nothing is owed.
        let still = self.sidebar([busy], clock: clock)
        still.noteTurnEnded(workspaceIDs: ["busy"])
        still.animates = false
        still.update(profiles: [], workspaces: [grey])
        XCTAssertTrue(still.owedTurnEnds.isEmpty)
        still.animates = true
        XCTAssertEqual(checks(in: still.expandedViews).count, 0)
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
