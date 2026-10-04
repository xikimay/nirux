import AppKit
import XCTest
@testable import Nirux

/// What a workspace card says before how it looks: its state, the signal
/// the project switcher and the collapsed rail show, its one-line form,
/// its action block.
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

    /// Coming back to the app clears every column's attention, not the
    /// dialog on screen: the card stays amber until it is answered.
    func testOpenDialogWaitsAfterTheAttentionIsCleared() {
        var dialog = column()
        dialog.openDialog = .permission(tool: "Bash", summary: "git push")
        XCTAssertEqual(dialog.attention, .waiting)
        XCTAssertEqual(dialog.attentionLabel, "permission")
        XCTAssertEqual(SidebarRenderer.attentionTooltip(for: dialog), "needs permission — Bash: git push")
        XCTAssertEqual(workspace([dialog]).cardState, .waiting)
        XCTAssertEqual(dialog.offScreenAttention, .waiting, "the column border, glow and indicator too")
    }

    /// The most urgent cause wins: a subagent's dialog after a failed turn
    /// waits on the user.
    func testDialogOutranksAStaleError() {
        var both = column(stuck: stopped)
        both.openDialog = .question("Which?")
        XCTAssertEqual(both.attention, .waiting)
        XCTAssertEqual(both.attentionLabel, "question")
        XCTAssertEqual(SidebarRenderer.attentionTooltip(for: both), "has a question — Which?", "the tooltip follows the chip")
    }

    /// A child agent's question (`nirux ask`) is something that happened
    /// while the user was away: the rail's tile and the ring say it, the
    /// card says what its column does, the activity feed keeps the question.
    func testChildAgentQuestionLightsTheTileNotTheCard() {
        let asking = workspace([column(status: .working)], isInactive: true, notification: .waiting)
        XCTAssertEqual(asking.attention, .waiting)
        XCTAssertEqual(asking.railState, .waiting)
        XCTAssertEqual(asking.cardState, .working)
        XCTAssertFalse(asking.asksUser)
    }

    func testFocusedColumnShowsItsOwnAttention() {
        let focused = column(status: .needsAttention, reason: .question(nil), focused: true)
        XCTAssertEqual(focused.attention, .waiting)
        XCTAssertNil(focused.offScreenAttention, "on screen: no glow, border or indicator pulse")
        XCTAssertEqual(column(status: .needsAttention, reason: .turnFinished).offScreenAttention, .finished)
    }

    /// No seconds on a card: they would rebuild the sidebar (and drop its
    /// tooltips) every heartbeat.
    func testCardTimesChangeByTheMinute() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(SidebarView.cardAge(since: 10_000 - 42, now: now), "now")
        XCTAssertEqual(SidebarView.cardAge(since: 10_000 - 720, now: now), "12m")
        var working = column(status: .working)
        working.agentElapsedSeconds = 42
        XCTAssertNil(working.elapsedDisplay)
        working.agentElapsedSeconds = 61
        XCTAssertEqual(working.elapsedDisplay, "1m")
    }

    /// A red check is an error once no agent works: one may be fixing it.
    func testRedCheckIsAnErrorUnlessAnAgentWorks() {
        let red = pullRequest(ci: "FAILURE")
        XCTAssertEqual(workspace([column()], pullRequest: red).cardState, .error)
        XCTAssertEqual(workspace([column(status: .working)], pullRequest: red).cardState, .working)
        XCTAssertEqual(workspace([column()], pullRequest: pullRequest(ci: "PENDING")).cardState, .idle)
        XCTAssertEqual(workspace([column()], pullRequest: pullRequest(state: "MERGED", ci: "FAILURE")).cardState, .done)
    }

    // MARK: - Project switcher ring

    func testRingTakesTheMostUrgentSignal() {
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
        let info = workspace(
            [column(0, stuck: stopped)], pullRequest: pullRequest(state: "MERGED"), isActive: true,
            blocker: "API access", cleanup: .available
        )
        XCTAssertEqual(info.cardActions, [
            .resume(columnIndex: 0, kind: "rate_limit", detail: nil, failedAt: 1, resume: .offered),
            .blocker("Blocker: API access"),
            .cleanup(.available, pullRequest: 7)
        ])
        let result = SidebarWorkspaceCardRenderer(workspace: info, sidebarWidth: 260, yOffset: 900).render()
        XCTAssertEqual(
            900 - result.bottomY, SidebarExpandedMetrics.workspaceHeight(for: info, sidebarWidth: 260), accuracy: 0.5,
            "layout matches the metrics the scroll view is sized with"
        )
        XCTAssertEqual(result.approvalButtons.count, 1, "Resume")
    }

    /// A restored agent's chip is its Resume button: after every launch the
    /// cards keep their size, the parked ones their single line.
    func testRestoredAgentResumesFromItsChip() throws {
        let deferred = SidebarDeferredAgent(processName: "codex", summary: "codex session", columnID: UUID())
        let resting = ColumnInfo(
            index: 2, processName: nil, abbreviatedCwd: nil, isFocused: false, isWebView: false, webTitle: nil,
            terminalTitle: nil, agentStatus: .idle, isEditor: false, editorFileName: nil, deferredAgent: deferred
        )
        let card = workspace([column(0), resting])
        XCTAssertEqual(card.cardActions, [])
        XCTAssertEqual(SidebarColumnChip(resting).style, .resume)
        XCTAssertTrue(workspace([resting], isInactive: true).showsCompactRow)

        let result = SidebarWorkspaceCardRenderer(workspace: card, sidebarWidth: 260, yOffset: 500).render()
        let resume = try XCTUnwrap(result.hitAreas.first {
            if case .deferredAgentResume(1, 2, deferred.columnID) = $0.region { return true }
            return false
        })
        let button = try XCTUnwrap(result.approvalButtons[SidebarHoverTarget.deferredResumeButtonKey(columnID: deferred.columnID)])
        XCTAssertTrue(resume.frame.contains(NSPoint(x: button.frame.midX, y: button.frame.midY)))
        let icon = try XCTUnwrap(result.hitAreas.first { if case .column(1, 2) = $0.region { return true }; return false })
        XCTAssertFalse(icon.frame.intersects(resume.frame), "the icon focuses the column, as the row did")
        XCTAssertEqual(
            500 - result.bottomY,
            SidebarExpandedMetrics.workspaceHeight(for: workspace([column(0), column(2)]), sidebarWidth: 260)
        )
    }

    /// A press of a double-click after a button acted does nothing: the
    /// rebuild may have put anything under it.
    func testSecondPressAfterAButtonActedDoesNothing() {
        let interval = NSEvent.doubleClickInterval
        XCTAssertTrue(SidebarView.isLeftoverPress(clickCount: 2, at: 10 + interval / 2, after: 10))
        XCTAssertFalse(SidebarView.isLeftoverPress(clickCount: 1, at: 10 + interval / 2, after: 10))
        XCTAssertFalse(SidebarView.isLeftoverPress(clickCount: 2, at: 10 + interval * 2, after: 10))
        XCTAssertFalse(SidebarView.isLeftoverPress(clickCount: 2, at: 10, after: -.infinity))
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

    /// A first chip too wide for the space left of the PR links starts on
    /// the next line: never under them, never losing clicks to them.
    func testChipsNeverRunUnderThePullRequestLinks() {
        let stuck = column(stuck: .waiting(.question(nil), duration: "12h05m"))
        var info = workspace([stuck, column(1)], pullRequest: PRInfo(
            number: 12345, state: "OPEN", isDraft: false, ciStatus: "FAILURE", checks: [], reviewDecision: nil,
            mergeable: nil, url: "https://example.test/pull/12345", additions: nil, deletions: nil, changedFiles: nil
        ))
        info.prFeedback = SidebarPRFeedback(humans: 12, bots: 34)
        let result = SidebarWorkspaceCardRenderer(workspace: info, sidebarWidth: 260, yOffset: 500).render()
        let links = result.hitAreas.filter { if case .link = $0.region { return true }; return false }
        let chips = result.hitAreas.filter { if case .column = $0.region { return true }; return false }
        XCTAssertEqual(chips.count, 2)
        for link in links {
            XCTAssertFalse(chips.contains { $0.frame.intersects(link.frame) }, "\(link.frame)")
        }
        XCTAssertEqual(500 - result.bottomY, SidebarExpandedMetrics.workspaceHeight(for: info, sidebarWidth: 260))
    }

    /// The folded INACTIVE section still shows an agent that waits on the
    /// user or broke; the rest stays folded.
    func testFoldedSectionListsWaitingWorkspaces() {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        sidebar.isExpanded = true
        let asking = workspace([column(status: .needsAttention, reason: .question(nil))], isInactive: true)
        let parked = WorkspaceInfo(
            id: "parked", index: 2, title: "parked", profileID: WorkspaceProfile.defaultID, isInactive: true,
            columnCount: 1, focusedColumn: 0, gitBranch: nil, notification: nil, isActive: false, columns: [column()],
            prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .parked,
            lastSummary: nil, lastActivityAt: nil
        )
        sidebar.update(profiles: [], workspaces: [asking, parked])
        XCTAssertEqual(sidebar.railWorkspaceInfos.map(\.id), ["ws"])
        let cards = sidebar.hitAreas.compactMap { area -> Int? in
            if case .workspace(let index) = area.region { return index }
            return nil
        }
        XCTAssertEqual(cards, [1])
    }

    /// The approval request's lines are never cut: the rendered field holds
    /// a full line.
    func testFullRequestLineFitsItsField() throws {
        var request = AgentPermissionRequest(
            toolName: "Bash", summary: "x", key: "k", agentID: nil, sessionID: "lead", requestedAt: 0
        )
        let text = String(repeating: "W", count: SidebarExpandedMetrics.approvalCharactersPerLine * 2)
        request.approval = PermissionApprovalTicket(requestID: "r", deadline: 100, text: text)
        let approval = try XCTUnwrap(SidebarPermissionApproval(request, now: 1))
        var asking = column(status: .needsAttention, reason: .permission(tool: "Bash", summary: "x"))
        asking.permissionApproval = approval
        let result = SidebarWorkspaceCardRenderer(workspace: workspace([asking]), sidebarWidth: 260, yOffset: 500).render()
        let field = try XCTUnwrap(result.views.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("WWW") })
        let needed = try XCTUnwrap(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 1000, height: field.frame.height)))
        XCTAssertLessThanOrEqual(needed.width, field.frame.width)
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

    /// An idle reminder after a failed turn neither hides nor handles it.
    func testIdleReminderLeavesAFailedTurnRed() throws {
        func row(_ name: AgentHookEvent.Name, type: String? = nil, at time: TimeInterval) throws -> ActivityEntry {
            let event = AgentHookEvent(
                kind: .claude, name: name, agentUUID: "agent", workspaceID: "ws", sessionID: "s",
                detail: "rate_limit", notificationType: type, errorKind: name == .stopFailure ? "rate_limit" : nil,
                timestamp: time
            )
            return try XCTUnwrap(ActivityEntry(event: event, workspaceTitle: "t", columnIndex: 0))
        }
        let failed = try row(.stopFailure, at: 10)
        let reminder = try row(.notification, type: "idle_prompt", at: 70)
        XCTAssertEqual(failed.signal, .error)
        let store = ActivityStore(persistsToDisk: false)
        store.record(failed)
        store.record(reminder)
        let feed = store.feedEntries
        XCTAssertEqual(feed.map(\.signal), [.finished, .error])
        XCTAssertFalse(ActivityStore.isAttentionSuperseded(at: 1, in: feed))

        // A dialog's row: the reminder says the agent is back at its
        // prompt, the dialog closed.
        let asked = ActivityEntry(
            category: .attention, agentKind: "claude", agentUUID: "agent", workspaceID: "ws", columnIndex: 0,
            workspaceTitle: "t", detail: "permission: Bash", timestamp: 5, signal: .waiting
        )
        XCTAssertTrue(ActivityStore.isAttentionSuperseded(at: 1, in: [reminder, asked]))
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
