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
        _ columns: [ColumnInfo], id: String = "ws", isLead: Bool = false, pullRequest: PRInfo? = nil
    ) -> WorkspaceInfo {
        WorkspaceInfo(
            id: id, index: 0, title: "checkout", profileID: WorkspaceProfile.defaultID, isInactive: false,
            columnCount: columns.count, focusedColumn: 0, gitBranch: "feat/checkout", notification: nil, isActive: false,
            columns: columns, prInfo: pullRequest, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil,
            phase: .active, lastSummary: nil, lastActivityAt: nil, isLead: isLead
        )
    }

    private func views(
        _ info: WorkspaceInfo, animates: Bool = true, turnEndedAt: CFTimeInterval? = nil
    ) -> [NSView] {
        SidebarWorkspaceCardRenderer(
            workspace: info, sidebarWidth: 260, yOffset: 500, animates: animates, turnEndedAt: turnEndedAt
        ).render().views
    }

    private func lines(in views: [NSView]) -> [NSView] {
        views.filter { $0.identifier == SidebarWorkspaceCardRenderer.workingLineID }
    }

    private func checks(in views: [NSView]) -> [NSView] {
        views.filter { $0.identifier == SidebarWorkspaceCardRenderer.turnEndCheckID }
    }

    // MARK: - The working line

    /// One thin line along the bottom of a working row, running for as
    /// long as the agent works; the dot itself stands still.
    func testAWorkingRowRunsALineOfLight() throws {
        let rendered = SidebarWorkspaceCardRenderer(workspace: row([column(.working)]), sidebarWidth: 260, yOffset: 500).render()
        let line = try XCTUnwrap(lines(in: rendered.views).first)
        XCTAssertEqual(lines(in: rendered.views).count, 1)
        let run = try XCTUnwrap(line.layer?.sublayers?.first?.animation(forKey: SidebarWorkspaceCardRenderer.workingLineKey))
        XCTAssertEqual(run.repeatCount, .infinity)
        XCTAssertEqual(line.frame.height, 2)
        let rowFrame = try XCTUnwrap(rendered.hitAreas.last?.frame)
        XCTAssertTrue(rowFrame.contains(line.frame), "inside the row")
        XCTAssertLessThan(line.frame.minY - rowFrame.minY, 3, "along its bottom edge")
        XCTAssertTrue(rendered.views.allSatisfy { $0.layer?.animation(forKey: "breathe") == nil }, "one movement, not two")

        XCTAssertEqual(lines(in: views(row([column(.working)], isLead: true))).count, 1, "the Lead's row too")
    }

    /// No line without work, nor while rows may not move.
    func testNoLineWithoutWorkOrWithoutMovement() {
        XCTAssertEqual(lines(in: views(row([column()]))).count, 0)
        XCTAssertEqual(
            lines(in: views(row([column(.needsAttention, reason: .permission(tool: "Bash", summary: "x"))]))).count, 0
        )
        XCTAssertEqual(lines(in: views(row([column(.working)]), animates: false)).count, 0)
    }

    // MARK: - The turn end's check

    /// A turn that just ended draws a check where the mark is, and the
    /// grey dot waits for it; once its time is over the dot alone shows.
    func testATurnsEndDrawsACheckThenTheDot() throws {
        let finished = row([column(.needsAttention, reason: .turnFinished)])
        let now = CACurrentMediaTime()

        let during = views(finished, turnEndedAt: now)
        let check = try XCTUnwrap(checks(in: during).first)
        XCTAssertNotNil(check.layer?.sublayers?.first?.animation(forKey: SidebarWorkspaceCardRenderer.checkDrawKey))
        XCTAssertEqual(during.filter { $0.layer?.animation(forKey: "wait") != nil }.count, 1, "the dot waits its turn")

        let after = views(finished, turnEndedAt: now - SidebarWorkspaceCardRenderer.checkDuration - 0.1)
        XCTAssertEqual(checks(in: after).count, 0)
        XCTAssertTrue(after.allSatisfy { $0.layer?.animation(forKey: "wait") == nil })

        XCTAssertEqual(checks(in: views(finished)).count, 0, "no turn ended")
        XCTAssertEqual(checks(in: views(finished, animates: false, turnEndedAt: now)).count, 0, "rows may not move")
    }

    /// Only a row whose mark is the grey dot: one that still works keeps
    /// its line, one that asks or broke its color, a merged one its sign.
    func testOnlyAnIdleMarkDrawsTheCheck() {
        let now = CACurrentMediaTime()
        let stillWorking = row([column(.needsAttention, reason: .turnFinished), column(.working)])
        XCTAssertEqual(checks(in: views(stillWorking, turnEndedAt: now)).count, 0)
        let asking = row([column(.needsAttention, reason: .permission(tool: "Bash", summary: "x"))])
        XCTAssertEqual(checks(in: views(asking, turnEndedAt: now)).count, 0)
        let merged = row([column()], pullRequest: PRInfo(
            number: 7, state: "MERGED", isDraft: false, ciStatus: nil, checks: [], reviewDecision: nil, mergeable: nil,
            url: "https://example.test/pull/7", additions: nil, deletions: nil, changedFiles: nil
        ))
        XCTAssertEqual(checks(in: views(merged, turnEndedAt: now)).count, 0)
    }

    // MARK: - In the sidebar

    /// The sidebar redraws the row when told its turn ended, keeps the
    /// check across its other rebuilds, and forgets it once it is over.
    func testTheSidebarShowsATurnsEndOnItsRow() {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 660))
        sidebar.isExpanded = true
        let finished = row([column(.needsAttention, reason: .turnFinished)])
        sidebar.update(profiles: [], workspaces: [finished, row([column()], id: "other")])
        XCTAssertEqual(checks(in: sidebar.expandedViews).count, 0)

        let now = CACurrentMediaTime()
        sidebar.noteTurnEnded(workspaceIDs: ["ws"], now: now)
        XCTAssertEqual(checks(in: sidebar.expandedViews).count, 1, "its row only")
        sidebar.noteTurnEnded(workspaceIDs: [], now: now + 0.5)
        XCTAssertEqual(sidebar.turnEndedAt.keys.map { $0 }, ["ws"], "still drawing")
        sidebar.noteTurnEnded(workspaceIDs: [], now: now + SidebarWorkspaceCardRenderer.checkDuration + 0.1)
        XCTAssertTrue(sidebar.turnEndedAt.isEmpty)

        sidebar.animates = false
        sidebar.noteTurnEnded(workspaceIDs: ["ws"])
        XCTAssertTrue(sidebar.turnEndedAt.isEmpty, "rows may not move")
        XCTAssertEqual(checks(in: sidebar.expandedViews).count, 0)
    }

    /// The working rows' lines come and go with `animates`.
    func testTheSidebarsLinesFollowAnimates() {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 660))
        sidebar.isExpanded = true
        sidebar.update(profiles: [], workspaces: [row([column(.working)])])
        XCTAssertEqual(lines(in: sidebar.expandedViews).count, 1)
        sidebar.animates = false
        XCTAssertEqual(lines(in: sidebar.expandedViews).count, 0)
        sidebar.animates = true
        XCTAssertEqual(lines(in: sidebar.expandedViews).count, 1)
    }
}
