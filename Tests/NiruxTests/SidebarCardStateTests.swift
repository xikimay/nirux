import AppKit
import XCTest
@testable import Nirux

/// What a workspace card says before how it looks: its state, the signal
/// the collapsed sidebar shows, its one-line form, its action block.
@MainActor
final class SidebarCardStateTests: XCTestCase {
    private func column(
        _ index: Int = 0, status: AgentStatus = .idle, reason: AgentAttentionReason? = nil,
        stuck: SidebarStuckState? = nil, focused: Bool = false
    ) -> ColumnInfo {
        ColumnInfo(
            index: index, processName: "claude", abbreviatedCwd: nil, isFocused: focused, isWebView: false,
            webTitle: nil, terminalTitle: nil, agentStatus: status, isEditor: false, editorFileName: nil,
            attentionReason: reason, stuck: stuck
        )
    }

    private func pullRequest(state: String = "OPEN", ci: String? = nil) -> PRInfo {
        PRInfo(
            number: 7, state: state, isDraft: false, ciStatus: ci, checks: [], reviewDecision: nil, mergeable: nil,
            url: "https://example.test/pull/7", additions: nil, deletions: nil, changedFiles: nil
        )
    }

    private func workspace(
        _ columns: [ColumnInfo], pullRequest: PRInfo? = nil, isActive: Bool = false, isInactive: Bool = false,
        notification: AttentionSignal? = nil, blocker: String? = nil, cleanup: MergedCleanupOffer? = nil
    ) -> WorkspaceInfo {
        WorkspaceInfo(
            id: "ws", index: 1, title: "checkout", profileID: WorkspaceProfile.defaultID, isInactive: isInactive,
            columnCount: columns.count, focusedColumn: 0, gitBranch: "feat/checkout", notification: notification,
            isActive: isActive, columns: columns, prInfo: pullRequest, diffStats: nil, purpose: nil, nextStep: nil,
            blocker: blocker, phase: .active, lastSummary: nil, lastActivityAt: nil, mergedCleanup: cleanup
        )
    }

    private let stopped = SidebarStuckState.stoppedOnError(kind: "rate_limit", detail: nil, failedAt: 1, resume: .offered)

    // MARK: - State

    func testWaitingOutranksErrorWhichOutranksWork() {
        let working = column(0, status: .working)
        let asking = column(1, status: .needsAttention, reason: .question("Which one?"))
        let broken = column(2, stuck: stopped)
        XCTAssertEqual(workspace([working, broken, asking]).cardState, .waiting)
        XCTAssertEqual(workspace([working, broken]).cardState, .error)
        XCTAssertEqual(workspace([working]).cardState, .working)
        XCTAssertEqual(workspace([column()]).cardState, .idle)
    }

    /// A finished turn asks nothing: the card stays idle, not amber.
    func testFinishedTurnLeavesTheCardIdle() {
        let finished = column(status: .needsAttention, reason: .turnFinished)
        XCTAssertEqual(finished.attention, .finished)
        XCTAssertEqual(workspace([finished]).cardState, .idle)
    }

    /// A long wait stays amber, focused or not: the dialog is still open.
    func testStuckDialogWaitsWhateverItsStatus() {
        let stuck = column(stuck: .waiting(.permission(tool: "Bash", summary: nil), duration: "2h05m"), focused: true)
        XCTAssertEqual(stuck.attention, .waiting)
        XCTAssertEqual(workspace([stuck]).cardState, .waiting)
    }

    /// A red check is an error once no agent works: one may be fixing it.
    func testRedCheckIsAnErrorUnlessAnAgentWorks() {
        let red = pullRequest(ci: "FAILURE")
        XCTAssertEqual(workspace([column()], pullRequest: red).cardState, .error)
        XCTAssertEqual(workspace([column(status: .working)], pullRequest: red).cardState, .working)
        XCTAssertEqual(workspace([column()], pullRequest: pullRequest(ci: "PENDING")).cardState, .idle)
        XCTAssertEqual(workspace([column()], pullRequest: pullRequest(state: "MERGED", ci: "FAILURE")).cardState, .done)
    }

    // MARK: - Collapsed dots

    func testCollapsedDotTakesTheMostUrgentSignal() {
        let finished = column(0, status: .needsAttention, reason: .turnFinished)
        let failed = column(1, status: .needsAttention, reason: .apiError(kind: nil, detail: nil))
        XCTAssertEqual(workspace([finished]).attention, .finished)
        XCTAssertEqual(workspace([finished, failed]).attention, .error)
        XCTAssertEqual(workspace([finished], notification: .waiting).attention, .waiting, "a question while away")
        XCTAssertNil(workspace([column()]).attention)
    }

    /// What happened while the user was away is cleared by coming back:
    /// the workspace on screen shows only what its columns still ask.
    func testWorkspaceOnScreenIgnoresItsNotification() {
        XCTAssertNil(workspace([column()], isActive: true, notification: .error).attention)
    }

    func testNotificationKeepsTheMostUrgentKind() {
        let state = WorkspaceState(title: "t", cwd: "/tmp")
        state.raiseNotification(.finished)
        state.raiseNotification(.waiting)
        state.raiseNotification(.error)
        XCTAssertEqual(state.notification, .waiting)
        XCTAssertTrue(state.hasNotification)
    }

    // MARK: - One line

    func testInactiveWorkspaceIsOneLineUnlessItNeedsTheUser() {
        XCTAssertTrue(workspace([column()], isInactive: true).showsCompactRow)
        XCTAssertFalse(workspace([column()], isActive: true, isInactive: true).showsCompactRow, "on screen")
        XCTAssertFalse(workspace([column(stuck: stopped)], isInactive: true).showsCompactRow, "broken")
        XCTAssertFalse(
            workspace([column(status: .needsAttention, reason: .question(nil))], isInactive: true).showsCompactRow,
            "waiting"
        )
        XCTAssertFalse(workspace([column()], isInactive: true, blocker: "API access").showsCompactRow, "blocked")
        XCTAssertFalse(workspace([column()]).showsCompactRow, "active section")

        let row = workspace([column()], isInactive: true)
        let result = SidebarWorkspaceCardRenderer(workspace: row, sidebarWidth: 260, yOffset: 500).render()
        XCTAssertEqual(500 - result.bottomY, SidebarExpandedMetrics.compactRowHeight)
        XCTAssertEqual(SidebarExpandedMetrics.workspaceHeight(for: row, sidebarWidth: 260), SidebarExpandedMetrics.compactRowHeight)
        XCTAssertTrue(result.views.contains { ($0 as? NSTextField)?.stringValue == "checkout" })
        XCTAssertTrue(result.hitAreas.contains { if case .workspaceMenu(1) = $0.region { return true }; return false })
        XCTAssertTrue(result.hitAreas.contains { if case .workspace(1) = $0.region { return true }; return false })
    }

    // MARK: - Action block

    func testActionBlockOrderAndHeight() throws {
        let deferred = SidebarDeferredAgent(processName: "codex", summary: "codex session", columnID: UUID())
        let resting = ColumnInfo(
            index: 2, processName: nil, abbreviatedCwd: nil, isFocused: false, isWebView: false, webTitle: nil,
            terminalTitle: nil, agentStatus: .idle, isEditor: false, editorFileName: nil, deferredAgent: deferred
        )
        let info = workspace(
            [column(0, stuck: stopped), resting], pullRequest: pullRequest(state: "MERGED"), isActive: true,
            blocker: "API access", cleanup: .available
        )
        XCTAssertEqual(info.cardActions, [
            .resume(columnIndex: 0, kind: "rate_limit", detail: nil, failedAt: 1, resume: .offered),
            .deferredResume(columnIndex: 2, deferred),
            .blocker("Blocker: API access"),
            .cleanup(.available, pullRequest: 7)
        ])
        let result = SidebarWorkspaceCardRenderer(workspace: info, sidebarWidth: 260, yOffset: 900).render()
        XCTAssertEqual(
            900 - result.bottomY, SidebarExpandedMetrics.workspaceHeight(for: info, sidebarWidth: 260), accuracy: 0.5,
            "layout matches the metrics the scroll view is sized with"
        )
        XCTAssertEqual(result.approvalButtons.count, 2, "Resume twice")
    }

    // MARK: - Chips

    func testChipsWrapInsteadOfOverflowing() {
        let one = workspace([column(0)])
        let many = workspace((0..<9).map { column($0, status: .working) })
        let oneHeight = SidebarExpandedMetrics.workspaceHeight(for: one, sidebarWidth: 260)
        let manyLayout = SidebarCardLayout(workspace: many, sidebarWidth: 260)
        XCTAssertGreaterThan(manyLayout.chipRows.count, 1)
        XCTAssertEqual(
            manyLayout.height - oneHeight,
            CGFloat(manyLayout.chipRows.count - 1) * (SidebarExpandedMetrics.chipHeight + SidebarExpandedMetrics.chipGap)
        )
        let result = SidebarWorkspaceCardRenderer(workspace: many, sidebarWidth: 260, yOffset: 500).render()
        let chips = result.hitAreas.filter { if case .column = $0.region { return true }; return false }
        XCTAssertEqual(chips.count, 9, "every column keeps its click")
        let maxX = 260 - SidebarExpandedMetrics.workspaceInsetX
        XCTAssertTrue(chips.allSatisfy { $0.frame.maxX <= maxX }, "inside the card")
    }

    // MARK: - "⋯"

    func testMenuButtonShowsOnTheSelectedCardAndOnHover() throws {
        let selected = SidebarWorkspaceCardRenderer(
            workspace: workspace([column()], isActive: true), sidebarWidth: 260, yOffset: 500
        ).render()
        XCTAssertEqual(selected.menuBadge?.hidesUntilHover, false)

        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        sidebar.isExpanded = true
        sidebar.update(profiles: [], workspaces: [workspace([column()])])
        let badge = try XCTUnwrap(sidebar.menuBadgeViews[1])
        XCTAssertTrue(badge.hidesUntilHover)
        sidebar.setHoverTarget(.workspaceCard(1))
        XCTAssertTrue(badge.isCardHovered)
        sidebar.setHoverTarget(nil)
        XCTAssertFalse(badge.isCardHovered)
    }

    // MARK: - Activity feed

    /// Amber only for a row that waits on the user; a row older builds
    /// wrote doesn't say, and stays amber.
    func testActivityRowColorFollowsItsSignal() throws {
        func entry(_ signal: AttentionSignal?) -> ActivityEntry {
            ActivityEntry(
                category: .attention, agentKind: "claude", workspaceID: "ws", columnIndex: 0, workspaceTitle: "t",
                detail: nil, timestamp: 1, signal: signal
            )
        }
        XCTAssertEqual(SidebarView.activityColor(for: entry(.waiting)), Theme.Color.waiting)
        XCTAssertEqual(SidebarView.activityColor(for: entry(.error)), Theme.Color.error)
        XCTAssertEqual(SidebarView.activityColor(for: entry(.finished)), SidebarRenderer.color(for: .finished))
        XCTAssertEqual(SidebarView.activityColor(for: entry(nil)), Theme.Color.waiting)

        let legacy = Data(#"[{"category":"attention","agentKind":"claude","workspaceTitle":"t","timestamp":1}]"#.utf8)
        XCTAssertNil(try JSONDecoder().decode([ActivityEntry].self, from: legacy).first?.signal)
        let newer = Data(#"[{"category":"attention","agentKind":"claude","workspaceTitle":"t","timestamp":1,"signal":"later"}]"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode([ActivityEntry].self, from: newer).first?.signal, .waiting)
        let roundTrip = try JSONDecoder().decode(ActivityEntry.self, from: JSONEncoder().encode(entry(.finished)))
        XCTAssertEqual(roundTrip.signal, .finished)
    }

    func testIdlePromptRowIsAFinishedTurnNotAWait() throws {
        let event = AgentHookEvent(
            kind: .claude, name: .notification, sessionID: "s", detail: "Claude is waiting for your input",
            notificationType: "idle_prompt", timestamp: 10
        )
        let row = try XCTUnwrap(ActivityEntry(event: event, workspaceTitle: "t", columnIndex: 0))
        XCTAssertEqual(row.category, .attention)
        XCTAssertEqual(row.signal, .finished)
    }

    // MARK: - Header

    func testSpaceHeaderCountsWaitingWorkspaces() throws {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        sidebar.isExpanded = true
        let profile = ProfileInfo(
            id: WorkspaceProfile.defaultID, name: "acme", colorHex: "#78A3F7", isActive: true, workspaceCount: 2,
            attention: .waiting
        )
        sidebar.update(profiles: [profile], workspaces: [
            workspace([column(status: .needsAttention, reason: .question(nil))]),
            WorkspaceInfo(
                id: "other", index: 2, title: "other", profileID: WorkspaceProfile.defaultID, isInactive: false,
                columnCount: 1, focusedColumn: 0, gitBranch: nil, notification: nil, isActive: true, columns: [column()],
                prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .active,
                lastSummary: nil, lastActivityAt: nil
            )
        ])
        XCTAssertTrue(sidebar.expandedViews.contains { ($0 as? NSTextField)?.stringValue == "2 workspaces · 1 waiting" })
    }
}
