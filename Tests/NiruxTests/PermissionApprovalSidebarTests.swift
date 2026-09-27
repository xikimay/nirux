import AppKit
import XCTest
@testable import Nirux

/// The column's side of sidebar approvals (status machine) and the
/// Allow / Deny block on the workspace card.
@MainActor
final class PermissionApprovalSidebarTests: XCTestCase {
    private var machine = AgentStatusMachine()
    private let t0: TimeInterval = 1_000
    private let requestID = UUID().uuidString

    private func event(
        _ name: AgentHookEvent.Name,
        at offset: TimeInterval = 0,
        tool: String? = "Bash",
        summary: String? = "git push",
        key: String? = "k1",
        agent: String? = nil,
        requestID: String? = nil,
        deadline: TimeInterval? = nil,
        outcome: PermissionApproval.Outcome? = nil
    ) -> AgentHookEvent {
        AgentHookEvent(
            kind: .claude, name: name, sessionID: "lead", detail: tool,
            toolName: tool, toolSummary: summary, toolKey: key, agentID: agent,
            approvalRequestID: requestID, approvalDeadline: deadline,
            approvalText: requestID == nil ? nil : summary, approvalOutcome: outcome,
            timestamp: t0 + offset
        )
    }

    /// Mid-turn, then a held PermissionRequest (window of 55 s).
    @discardableResult
    private func holdRequest(agent: String? = nil) -> AgentHookOutcome {
        _ = machine.tick(fgName: "claude", isUserFocused: false, now: Date(timeIntervalSince1970: t0))
        _ = machine.apply(event(.sessionStart, tool: nil), isUserFocused: false)
        _ = machine.apply(event(.userPromptSubmit, tool: nil), isUserFocused: false)
        return machine.apply(
            event(.permissionRequest, at: 1, agent: agent, requestID: requestID, deadline: t0 + 56),
            isUserFocused: false
        )
    }

    private func resolve(_ outcome: PermissionApproval.Outcome, agent: String? = nil) -> AgentHookOutcome {
        machine.apply(event(.approvalResolved, at: 3, agent: agent, requestID: requestID, outcome: outcome), isUserFocused: false)
    }

    // MARK: - Status machine

    func testHeldRequestIsOfferedUntilShortlyBeforeItsDeadline() {
        holdRequest()
        XCTAssertEqual(machine.sidebarApproval(now: t0 + 2)?.approval?.requestID, requestID)
        XCTAssertEqual(machine.sidebarApproval(now: t0 + 2)?.summary, "git push")
        XCTAssertNil(machine.sidebarApproval(now: t0 + 56 - PermissionApproval.sendMargin))
        XCTAssertEqual(machine.state, .needsAttention)
    }

    func testRequestWithoutTicketIsNotOffered() {
        _ = machine.apply(event(.permissionRequest), isUserFocused: false)
        XCTAssertNil(machine.sidebarApproval(now: t0))
    }

    func testDecisionIsSentOnceAndShownUntilReported() {
        holdRequest()
        XCTAssertNotNil(machine.markApprovalSent(requestID: requestID, behavior: .allow, now: t0 + 2))
        XCTAssertNil(machine.markApprovalSent(requestID: requestID, behavior: .deny, now: t0 + 2), "already decided")
        XCTAssertEqual(machine.sidebarApproval(now: t0 + 2)?.approval?.display(now: t0 + 2), .sending(.allow))
        XCTAssertNil(machine.markApprovalSent(requestID: "other", behavior: .allow, now: t0 + 2))
    }

    /// No report from the receiver: the card says the decision didn't arrive,
    /// then hands the dialog back to the terminal.
    func testSentDecisionThatNeverArrivesIsReported() {
        let ticket = { () -> PermissionApprovalTicket in
            var ticket = PermissionApprovalTicket(requestID: "r", deadline: 100, text: "ls")
            ticket.sent = .deny
            ticket.sentAt = 10
            return ticket
        }()
        XCTAssertEqual(ticket.display(now: 12), .sending(.deny))
        XCTAssertEqual(ticket.display(now: 10 + PermissionApproval.deliveryTimeout), .undelivered)
        XCTAssertNil(ticket.display(now: 10 + PermissionApproval.deliveryTimeout + PermissionApproval.failureNoticeDuration))

        holdRequest()
        _ = machine.markApprovalSent(requestID: requestID, behavior: .allow, now: t0 + 2)
        _ = resolve(.invalid)
        XCTAssertEqual(machine.sidebarApproval(now: t0 + 3)?.approval?.display(now: t0 + 3), .undelivered)
        XCTAssertEqual(machine.pendingDialogs.count, 1, "the terminal dialog still waits")
    }

    func testExpiredRequestCannotBeDecided() {
        holdRequest()
        XCTAssertNil(machine.markApprovalSent(requestID: requestID, behavior: .allow, now: t0 + 55))
    }

    /// A held request is unanswered (its column was never on screen): a
    /// sibling call's progress neither hides it nor unblocks the column.
    func testSiblingCallProgressKeepsTheHeldRequest() {
        holdRequest()
        _ = machine.apply(event(.postToolUse, at: 2, tool: "Read", summary: "b", key: "k2"), isUserFocused: false)
        XCTAssertNotNil(machine.sidebarApproval(now: t0 + 3))
        XCTAssertNotNil(machine.markApprovalSent(requestID: requestID, behavior: .allow, now: t0 + 3))
        XCTAssertEqual(machine.state, .needsAttention)
    }

    /// Once the sidebar let go, #38's rule applies again: a later tool
    /// event suggests the dialog was answered at the terminal.
    func testReleasedRequestFollowsTheTerminalAgain() {
        holdRequest()
        _ = machine.takeUndecidedApprovals()
        _ = machine.apply(event(.preToolUse, at: 2, key: nil), isUserFocused: false)
        XCTAssertEqual(machine.state, .working)
        XCTAssertNil(machine.sidebarApproval(now: t0 + 3))
    }

    func testAllowReachingClaudeClosesTheDialogAndTheAgentWorks() {
        holdRequest()
        _ = machine.markApprovalSent(requestID: requestID, behavior: .allow, now: t0 + 2)
        let outcome = resolve(.allow)
        XCTAssertTrue(machine.pendingDialogs.isEmpty)
        XCTAssertEqual(machine.state, .working)
        XCTAssertEqual(outcome.abandonedApprovals, [])
        XCTAssertFalse(outcome.firedAttention)
    }

    /// The denial never interrupts: the agent reads it and goes on.
    func testMainThreadDenialLetsTheTurnGoOn() {
        holdRequest()
        _ = machine.markApprovalSent(requestID: requestID, behavior: .deny, now: t0 + 2)
        let outcome = resolve(.deny)
        XCTAssertTrue(machine.pendingDialogs.isEmpty)
        XCTAssertEqual(machine.state, .working)
        XCTAssertNotNil(machine.turnStartedAt)
        XCTAssertFalse(outcome.firedAttention)
    }

    func testSubagentDenialLetsTheTurnGoOn() {
        holdRequest(agent: "a1")
        let outcome = resolve(.deny, agent: "a1")
        XCTAssertTrue(machine.pendingDialogs.isEmpty)
        XCTAssertEqual(machine.state, .working)
        XCTAssertNotNil(machine.turnStartedAt)
        XCTAssertFalse(outcome.firedAttention)
    }

    func testUndecidedEndsLeaveTheDialogToTheTerminal() {
        for outcome in [PermissionApproval.Outcome.release, .expired, .invalid] {
            machine = AgentStatusMachine()
            holdRequest()
            _ = resolve(outcome)
            XCTAssertEqual(machine.pendingDialogs.count, 1, "\(outcome)")
            XCTAssertNil(machine.pendingDialogs.first?.approval, "\(outcome)")
            XCTAssertNil(machine.sidebarApproval(now: t0 + 4), "\(outcome)")
            XCTAssertEqual(machine.state, .needsAttention, "\(outcome)")
        }
    }

    /// A dialog answered at the terminal (its call ran) leaves a receiver
    /// waiting for nothing: the outcome names it for release.
    func testDialogClosedOtherwiseAbandonsItsReceiver() {
        holdRequest()
        let outcome = machine.apply(event(.postToolUse, at: 2), isUserFocused: false)
        XCTAssertEqual(outcome.abandonedApprovals.map { $0.approval?.requestID }, [requestID])

        machine = AgentStatusMachine()
        holdRequest()
        let prompt = machine.apply(event(.userPromptSubmit, at: 2, tool: nil), isUserFocused: false)
        XCTAssertEqual(prompt.abandonedApprovals.count, 1)
    }

    func testSentDecisionIsNotReleased() {
        holdRequest()
        _ = machine.markApprovalSent(requestID: requestID, behavior: .allow, now: t0 + 2)
        let outcome = machine.apply(event(.postToolUse, at: 2), isUserFocused: false)
        XCTAssertEqual(outcome.abandonedApprovals, [], "its receiver reports on its own")
    }

    func testRepeatedRequestForTheSameCallReleasesTheOldReceiver() {
        holdRequest()
        let again = machine.apply(
            event(.permissionRequest, at: 2, requestID: UUID().uuidString, deadline: t0 + 57), isUserFocused: false
        )
        XCTAssertEqual(again.abandonedApprovals.map { $0.approval?.requestID }, [requestID])
    }

    func testTakingUndecidedRequestsStopsOfferingThem() {
        holdRequest()
        let taken = machine.takeUndecidedApprovals()
        XCTAssertEqual(taken.map { $0.approval?.requestID }, [requestID])
        XCTAssertNil(machine.sidebarApproval(now: t0 + 2))
        XCTAssertEqual(machine.pendingDialogs.count, 1, "the dialog itself stays")
        XCTAssertEqual(machine.takeUndecidedApprovals(), [])
    }

    func testDroppingARequestReturnsItsTicket() {
        holdRequest()
        _ = machine.markApprovalSent(requestID: requestID, behavior: .allow, now: t0 + 2)
        XCTAssertEqual(machine.dropApproval(requestID: requestID)?.approval?.requestID, requestID)
        XCTAssertNil(machine.sidebarApproval(now: t0 + 2))
        XCTAssertNil(machine.dropApproval(requestID: requestID))
    }

    // MARK: - Workspace card

    private func column(_ approval: SidebarPermissionApproval?) -> ColumnInfo {
        ColumnInfo(
            index: 1, processName: "claude", abbreviatedCwd: "~/p", isFocused: false, isWebView: false,
            webTitle: nil, terminalTitle: nil, agentStatus: .needsAttention, isEditor: false, editorFileName: nil,
            attentionReason: .permission(tool: "Bash", summary: "x"), permissionApproval: approval
        )
    }

    private func approval(_ text: String, sent: PermissionApproval.Behavior? = nil) -> SidebarPermissionApproval? {
        var request = AgentPermissionRequest(
            toolName: "Bash", summary: text, key: "k", agentID: nil, sessionID: "lead", requestedAt: 0
        )
        var ticket = PermissionApprovalTicket(requestID: requestID, deadline: 100, text: text)
        ticket.sent = sent
        ticket.sentAt = sent.map { _ in 10 }
        request.approval = ticket
        return SidebarPermissionApproval(request, now: 11)
    }

    private func workspace(_ columns: [ColumnInfo]) -> WorkspaceInfo {
        WorkspaceInfo(
            id: "ws", index: 2, title: "fix-login", profileID: WorkspaceProfile.defaultID, isInactive: false,
            columnCount: columns.count, focusedColumn: 0, gitBranch: nil, hasNotification: false, isActive: false,
            columns: columns, prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil,
            phase: .active, lastSummary: nil, lastActivityAt: nil
        )
    }

    func testRequestTextWrapsIntoExactLines() {
        let text = String(repeating: "abcdefgh", count: 20)
        let lines = SidebarExpandedMetrics.approvalLines(text)
        XCTAssertEqual(lines.joined(), text)
        XCTAssertEqual(lines.count, 5)
        XCTAssertTrue(lines.dropLast().allSatisfy { $0.count == SidebarExpandedMetrics.approvalCharactersPerLine })
        XCTAssertEqual(SidebarExpandedMetrics.approvalLines("ls"), ["ls"])
    }

    /// Every character of a full line fits the card: nothing is clipped.
    func testFullLineFitsTheExpandedSidebar() {
        let line = String(repeating: "W", count: SidebarExpandedMetrics.approvalCharactersPerLine)
        let width = (line as NSString).size(withAttributes: [.font: SidebarExpandedMetrics.approvalFont]).width
        XCTAssertLessThanOrEqual(width, 260 - SidebarExpandedMetrics.padding * 2)
    }

    func testCardGrowsByTheApprovalBlock() throws {
        let block = try XCTUnwrap(approval(String(repeating: "x", count: 40)))
        let plain = SidebarExpandedMetrics.workspaceHeight(for: workspace([column(nil)]))
        let held = SidebarExpandedMetrics.workspaceHeight(for: workspace([column(block)]))
        XCTAssertEqual(held - plain, SidebarExpandedMetrics.approvalBlockHeight(for: block) + SidebarExpandedMetrics.approvalBottomGap)
        XCTAssertGreaterThan(
            SidebarExpandedMetrics.approvalBlockHeight(for: block),
            SidebarExpandedMetrics.approvalBlockHeight(for: try XCTUnwrap(approval("ls")))
        )
    }

    private struct DecisionRegion: Equatable {
        let workspace: Int
        let column: Int
        let requestID: String
        let behavior: PermissionApproval.Behavior
    }

    private func decisionRegions(_ hitAreas: [SidebarHitArea]) -> [DecisionRegion] {
        hitAreas.compactMap {
            if case let .permissionDecision(workspace, column, id, behavior) = $0.region {
                return DecisionRegion(workspace: workspace, column: column, requestID: id, behavior: behavior)
            }
            return nil
        }
    }

    private func labels(_ views: [NSView]) -> [String] {
        views.compactMap { ($0 as? NSTextField)?.stringValue }
    }

    func testCardShowsTheExactRequestWithAllowAndDeny() throws {
        let text = "git push --force-with-lease origin feat/permission-approval"
        let result = SidebarWorkspaceCardRenderer(
            workspace: workspace([column(approval(text))]), sidebarWidth: 260, padding: 20, yOffset: 800
        ).render()

        XCTAssertEqual(decisionRegions(result.hitAreas), [
            DecisionRegion(workspace: 2, column: 1, requestID: requestID, behavior: .deny),
            DecisionRegion(workspace: 2, column: 1, requestID: requestID, behavior: .allow)
        ], "Allow last, away from where row labels start")
        XCTAssertTrue(
            labels(result.views).contains(SidebarExpandedMetrics.approvalLines(text).joined(separator: "\n")),
            "the whole request, split only into lines"
        )
        // The rest of the block swallows clicks meant for what was there.
        let blockHit = try XCTUnwrap(result.hitAreas.firstIndex {
            if case .actionBlock(2) = $0.region { return true }
            return false
        })
        XCTAssertGreaterThan(blockHit, try XCTUnwrap(result.hitAreas.lastIndex {
            if case .permissionDecision = $0.region { return true }
            return false
        }))
        XCTAssertEqual(result.approvalButtons.count, 2)
        // The buttons are hit before the card (first match wins).
        let workspaceHit = try XCTUnwrap(result.hitAreas.firstIndex {
            if case .workspace = $0.region { return true }
            return false
        })
        let allowHit = try XCTUnwrap(result.hitAreas.firstIndex {
            if case .permissionDecision = $0.region { return true }
            return false
        })
        XCTAssertLessThan(allowHit, workspaceHit)
        XCTAssertEqual(
            800 - result.bottomY,
            SidebarExpandedMetrics.workspaceHeight(for: workspace([column(approval(text))])),
            accuracy: 0.5,
            "layout matches the metrics the scroll view is sized with"
        )
    }

    func testSentDecisionShowsProgressInsteadOfButtons() {
        let result = SidebarWorkspaceCardRenderer(
            workspace: workspace([column(approval("ls", sent: .deny))]), sidebarWidth: 260, padding: 20, yOffset: 800
        ).render()
        XCTAssertTrue(decisionRegions(result.hitAreas).isEmpty)
        XCTAssertTrue(labels(result.views).contains("Denying…"))
        XCTAssertTrue(result.approvalButtons.isEmpty)
    }

    func testUndeliveredDecisionSaysToAnswerInTheTerminal() {
        var request = AgentPermissionRequest(
            toolName: "Bash", summary: "ls", key: "k", agentID: nil, sessionID: "lead", requestedAt: 0
        )
        var ticket = PermissionApprovalTicket(requestID: requestID, deadline: 100, text: "ls")
        ticket.sent = .allow
        ticket.sentAt = 10
        ticket.undelivered = true
        request.approval = ticket
        let result = SidebarWorkspaceCardRenderer(
            workspace: workspace([column(SidebarPermissionApproval(request, now: 11))]),
            sidebarWidth: 260, padding: 20, yOffset: 800
        ).render()
        XCTAssertTrue(labels(result.views).contains("Not delivered — answer in the terminal"))
        XCTAssertTrue(decisionRegions(result.hitAreas).isEmpty)
    }

    /// A line break never hides a space: `rm -rf ./dist/assets/old-bundle *`
    /// must not read as `old-bundle*`.
    func testSpacesAtLineBreaksStayVisible() {
        let text = "rm -rf ./dist/assets/old-bundle *"
        let lines = SidebarExpandedMetrics.approvalLines(text)
        XCTAssertEqual(lines, ["rm -rf ./dist/assets/old-bundle ", "*"])
        let shown = SidebarApprovalBlockRenderer.attributedLines(lines).string
        XCTAssertEqual(shown, "rm -rf ./dist/assets/old-bundle\u{2423}\n*")
        for line in shown.split(separator: "\n") {
            XCTAssertFalse(line.hasPrefix(" ") || line.hasSuffix(" "), String(line))
        }
        let inner = SidebarApprovalBlockRenderer.attributedLines(["a b"]).string
        XCTAssertEqual(inner, "a b", "spaces inside a line stay plain")
        XCTAssertEqual(
            SidebarApprovalBlockRenderer.attributedLines(SidebarExpandedMetrics.approvalLines("x" + String(repeating: "y", count: 30) + " z")).string,
            "x" + String(repeating: "y", count: 30) + "\u{2423}\nz"
        )
    }

    /// A button that just appeared or moved takes no click for a moment.
    func testButtonsArmOnlyAfterStayingPut() {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 800))
        let key = SidebarHoverTarget.approvalButtonKey(requestID: requestID, behavior: .allow)
        let button = SidebarBadgeView(text: "Allow", textColor: .white, fillColor: .clear, font: .systemFont(ofSize: 11))
        button.frame = NSRect(x: 20, y: 100, width: 58, height: 20)
        sidebar.approvalButtonViews = [key: button]

        sidebar.refreshApprovalArming(now: 10)
        XCTAssertFalse(sidebar.isApprovalButtonArmed(key, now: 10.5))
        XCTAssertTrue(sidebar.isApprovalButtonArmed(key, now: 10 + SidebarView.approvalArmingDelay))

        sidebar.refreshApprovalArming(now: 11)
        XCTAssertTrue(sidebar.isApprovalButtonArmed(key, now: 11), "same place: still armed")

        button.frame.origin.y = 160
        sidebar.refreshApprovalArming(now: 12)
        XCTAssertFalse(sidebar.isApprovalButtonArmed(key, now: 12.1), "moved: armed again later")

        sidebar.approvalButtonViews = [:]
        sidebar.refreshApprovalArming(now: 13)
        XCTAssertFalse(sidebar.isApprovalButtonArmed(key, now: 20), "gone")
    }

    /// Scrolling slides buttons under a still pointer; collapsing drops them.
    func testScrollingAndCollapsingDisarmButtons() {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 800))
        let key = SidebarHoverTarget.approvalButtonKey(requestID: requestID, behavior: .allow)
        let button = SidebarBadgeView(text: "Allow", textColor: .white, fillColor: .clear, font: .systemFont(ofSize: 11))
        button.frame = NSRect(x: 20, y: 100, width: 58, height: 20)
        sidebar.approvalButtonViews = [key: button]
        sidebar.refreshApprovalArming(now: 0)
        XCTAssertTrue(sidebar.isApprovalButtonArmed(key))

        sidebar.approvalClipViewScrolled(Notification(name: NSView.boundsDidChangeNotification))
        XCTAssertFalse(sidebar.isApprovalButtonArmed(key))

        sidebar.refreshApprovalArming(now: 0)
        sidebar.isExpanded = false
        XCTAssertFalse(sidebar.isApprovalButtonArmed(key, now: 1_000_000))
    }

    func testOnlyASingleClickReleasedOnTheSameButtonDecides() {
        let allow = SidebarHitRegion.permissionDecision(workspaceIndex: 2, columnIndex: 1, requestID: "r", behavior: .allow)
        let deny = SidebarHitRegion.permissionDecision(workspaceIndex: 2, columnIndex: 1, requestID: "r", behavior: .deny)
        let moved = SidebarHitRegion.permissionDecision(workspaceIndex: 0, columnIndex: 3, requestID: "r", behavior: .allow)
        let other = SidebarHitRegion.permissionDecision(workspaceIndex: 2, columnIndex: 1, requestID: "s", behavior: .allow)
        func decides(
            _ released: SidebarHitRegion?, clicks: Int = 1, armedAtPress: Bool = true, armedAtRelease: Bool = true
        ) -> Bool {
            SidebarView.approvalClickDecision(
                pressed: allow, released: released, clickCount: clicks,
                armedAtPress: armedAtPress, armedAtRelease: armedAtRelease
            ) != nil
        }
        XCTAssertTrue(decides(allow))
        XCTAssertFalse(decides(deny), "released on the other button")
        XCTAssertFalse(decides(other), "released on another request's button")
        XCTAssertFalse(decides(.actionBlock(workspaceIndex: 2)))
        XCTAssertFalse(decides(nil))
        XCTAssertFalse(decides(allow, clicks: 2), "second click of a double click")
        XCTAssertFalse(decides(allow, armedAtPress: false))
        XCTAssertFalse(decides(allow, armedAtRelease: false), "moved during the press")
        let decision = SidebarView.approvalClickDecision(
            pressed: allow, released: moved, clickCount: 1, armedAtPress: true, armedAtRelease: true
        )
        XCTAssertEqual(decision?.workspaceIndex, 0, "the indices where it was released")
        XCTAssertEqual(decision?.columnIndex, 3)
    }

    /// A receiver killed without a report: once its deadline passes, #38's
    /// rule applies again and a later tool event unblocks the column.
    func testHeldRequestPastItsDeadlineFollowsTheTerminalAgain() {
        holdRequest()
        _ = machine.apply(event(.postToolUse, at: 60, tool: "Read", summary: "b", key: "k2"), isUserFocused: false)
        XCTAssertEqual(machine.state, .working)
        XCTAssertNil(machine.sidebarApproval(now: t0 + 61))
    }

    func testRequestWithoutTheToolIsNotShown() {
        var request = AgentPermissionRequest(
            toolName: nil, summary: "ls", key: nil, agentID: nil, sessionID: "lead", requestedAt: 0
        )
        request.approval = PermissionApprovalTicket(requestID: requestID, deadline: 100, text: "ls")
        XCTAssertNil(SidebarPermissionApproval(request, now: 1))
    }
}
