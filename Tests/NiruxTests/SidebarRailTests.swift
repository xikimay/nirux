import XCTest
@testable import Nirux

/// The collapsed sidebar: a rail of workspace tiles.
@MainActor
final class SidebarRailTests: XCTestCase {
    private func workspace(
        _ id: String, index: Int, isInactive: Bool = false, isActive: Bool = false,
        columns: [ColumnInfo] = [], prInfo: PRInfo? = nil, notification: AttentionSignal? = nil
    ) -> WorkspaceInfo {
        WorkspaceInfo(
            id: id, index: index, title: id, profileID: "p", isInactive: isInactive, columnCount: columns.count,
            focusedColumn: 0, gitBranch: nil, notification: notification, isActive: isActive, columns: columns, prInfo: prInfo,
            diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: isInactive ? .parked : .active,
            lastSummary: nil, lastActivityAt: Date().timeIntervalSince1970 - 240
        )
    }

    private func agent(
        _ status: AgentStatus, reason: AgentAttentionReason? = nil, stuck: SidebarStuckState? = nil
    ) -> ColumnInfo {
        ColumnInfo(
            index: 0, processName: "claude", abbreviatedCwd: nil, isFocused: false, isWebView: false, webTitle: nil,
            terminalTitle: nil, agentStatus: status, isEditor: false, editorFileName: nil, attentionReason: reason,
            stuck: stuck
        )
    }

    private var permission: ColumnInfo { agent(.needsAttention, reason: .permission(tool: "Bash", summary: "git push")) }

    private func failedPullRequest(_ number: Int) -> PRInfo {
        PRInfo(
            number: number, state: "OPEN", isDraft: false, ciStatus: "FAILURE", checks: [], reviewDecision: nil,
            mergeable: nil, url: "", additions: nil, deletions: nil, changedFiles: nil
        )
    }

    private func profile(_ id: String, isActive: Bool) -> ProfileInfo {
        ProfileInfo(id: id, name: id, colorHex: "#78A3F7", isActive: isActive, workspaceCount: 3, attention: nil)
    }

    /// A collapsed sidebar in a window that is never shown.
    private func rail(_ workspaces: [WorkspaceInfo], profiles: [ProfileInfo] = []) -> (SidebarView, NSWindow) {
        _ = NSApplication.shared
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: SidebarRailMetrics.width, height: 500))
        host.addSubview(sidebar)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        sidebar.railHoverNeedsLivePointer = false
        sidebar.update(profiles: profiles, workspaces: workspaces)
        host.layoutSubtreeIfNeeded()
        return (sidebar, window)
    }

    private func regions(_ sidebar: SidebarView) -> [String] {
        sidebar.hitAreas.map {
            switch $0.region {
            case .workspace(let index): return "\(index)"
            case .railButton(let button): return "\(button)"
            default: return "other"
            }
        }
    }

    private func frame(of wanted: String, in sidebar: SidebarView) throws -> NSRect {
        let index = try XCTUnwrap(regions(sidebar).firstIndex(of: wanted))
        return sidebar.hitAreas[index].frame
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in sidebar: SidebarView, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: sidebar.contentDocumentView.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        ))
    }

    private func click(_ wanted: String, in sidebar: SidebarView, window: NSWindow) throws {
        let frame = try frame(of: wanted, in: sidebar)
        sidebar.mouseDown(with: try mouseEvent(.leftMouseDown, at: NSPoint(x: frame.midX, y: frame.midY), in: sidebar, window: window))
    }

    func testInitialsDropTheBranchTypeAndNumberRepeats() {
        XCTAssertEqual(SidebarRailInitials.initials(of: "Fix login rate limit"), "FL")
        XCTAssertEqual(SidebarRailInitials.initials(of: "feat/crash-report"), "CR")
        XCTAssertEqual(SidebarRailInitials.initials(of: "main"), "MA")
        XCTAssertEqual(SidebarRailInitials.initials(of: "CelticFantasyMusicLofi"), "CF")
        XCTAssertEqual(SidebarRailInitials.initials(of: "ws 12"), "W12")
        XCTAssertEqual(SidebarRailInitials.initials(of: "nirux-101"), "N101")
        XCTAssertEqual(SidebarRailInitials.initials(of: "Update CI/CD pipeline"), "UC")
        XCTAssertEqual(SidebarRailInitials.initials(of: "  "), "?")
        XCTAssertEqual(
            SidebarRailInitials.initials(for: ["feat/merge-queue-engine", "feat/merge-queue-ui", "docs/merge-queue"]),
            ["MQ", "MQ2", "MQ3"]
        )
    }

    /// The project, the active workspaces, the INACTIVE toggle (folded:
    /// only the inactive workspace on screen, and an amber one), then "+".
    func testRailListsTheProjectTheWorkspacesTheToggleAndPlus() throws {
        let (sidebar, window) = rail([
            workspace("a", index: 0),
            workspace("b", index: 1),
            workspace("on-screen", index: 2, isInactive: true, isActive: true),
            workspace("parked", index: 3, isInactive: true),
            workspace("child asked", index: 4, isInactive: true, notification: .waiting)
        ], profiles: [profile("p", isActive: true)])
        defer { window.close() }

        XCTAssertEqual(regions(sidebar), ["project", "0", "1", "inactiveSection", "2", "4", "newWorkspace"])

        try click("inactiveSection", in: sidebar, window: window)

        XCTAssertFalse(sidebar.isInactiveSectionCollapsed)
        XCTAssertEqual(regions(sidebar), ["project", "0", "1", "inactiveSection", "2", "3", "4", "newWorkspace"])
    }

    func testTileClickSelectsItsWorkspaceAndPlusAsksForANewOne() throws {
        let (sidebar, window) = rail([workspace("a", index: 0, isActive: true), workspace("b", index: 1)])
        defer { window.close() }
        var clicked: [Int] = []
        var newWorkspaces = 0
        sidebar.onWorkspaceClicked = { clicked.append($0) }
        sidebar.onNewWorkspace = { newWorkspaces += 1 }

        // The press is followed by its release: the drag loop takes it as a click.
        NSApp.postEvent(try mouseEvent(.leftMouseUp, at: try frame(of: "1", in: sidebar).center, in: sidebar, window: window), atStart: false)
        try click("1", in: sidebar, window: window)
        try click("newWorkspace", in: sidebar, window: window)

        XCTAssertEqual(clicked, [1])
        XCTAssertEqual(newWorkspaces, 1)
    }

    func testDraggingATileReordersTheWorkspaces() throws {
        let (sidebar, window) = rail([workspace("a", index: 0), workspace("b", index: 1), workspace("c", index: 2)])
        defer { window.close() }
        var moves: [[Int]] = []
        sidebar.onWorkspaceReordered = { moves.append([$0, $1]) }

        let start = try frame(of: "0", in: sidebar).center
        let below = try frame(of: "2", in: sidebar).minY + 2
        NSApp.postEvent(try mouseEvent(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 10), in: sidebar, window: window), atStart: false)
        NSApp.postEvent(try mouseEvent(.leftMouseDragged, at: NSPoint(x: start.x, y: below), in: sidebar, window: window), atStart: false)
        NSApp.postEvent(try mouseEvent(.leftMouseUp, at: NSPoint(x: start.x, y: below), in: sidebar, window: window), atStart: false)
        sidebar.mouseDown(with: try mouseEvent(.leftMouseDown, at: start, in: sidebar, window: window))

        XCTAssertEqual(moves, [[0, 2]])
    }

    func testRightClickOpensTheTilesMenu() throws {
        let (sidebar, window) = rail(
            [workspace("a", index: 0, isActive: true), workspace("b", index: 1)],
            profiles: [profile("p", isActive: true), profile("q", isActive: false)]
        )
        defer { window.close() }
        func menuTitles(_ wanted: String) throws -> [String] {
            let frame = try frame(of: wanted, in: sidebar)
            let menu = sidebar.menu(for: try mouseEvent(.rightMouseDown, at: frame.center, in: sidebar, window: window))
            return try XCTUnwrap(menu).items.map(\.title)
        }

        let workspaceMenu = try menuTitles("1")
        XCTAssertTrue(workspaceMenu.contains("Close Workspace"))
        XCTAssertTrue(workspaceMenu.contains("Move to Inactive"))
        XCTAssertEqual(Array(try menuTitles("project").prefix(2)), ["p", "q"])
    }

    func testProjectMenuSwitchesProjects() throws {
        let (sidebar, window) = rail(
            [workspace("a", index: 0, isActive: true)],
            profiles: [profile("p", isActive: true), profile("q", isActive: false)]
        )
        defer { window.close() }
        var selected: [String] = []
        sidebar.onProfileClicked = { selected.append($0) }

        let menu = sidebar.projectMenu()
        XCTAssertEqual(menu.items.prefix(2).map(\.state), [.on, .off])
        menu.performActionForItem(at: 1)

        XCTAssertEqual(selected, ["q"])
        XCTAssertTrue(menu.items.contains { $0.title == "New Project" })
    }

    /// The cards' rule: amber only for a wait on the user; a red check
    /// only once no agent works. Plus a question a Mission child asked.
    func testTilesTakeTheCardsState() {
        let (sidebar, window) = rail([
            workspace("selected", index: 0, isActive: true),
            workspace("permission", index: 1, columns: [agent(.needsAttention, reason: .permission(tool: "Bash", summary: "git push"))]),
            workspace("finished", index: 2, columns: [agent(.needsAttention, reason: .turnFinished)]),
            workspace("red", index: 3, prInfo: failedPullRequest(7)),
            workspace("fixing", index: 4, columns: [agent(.working)], prInfo: failedPullRequest(8)),
            workspace("child asked", index: 5, notification: .waiting)
        ])
        defer { window.close() }
        func style(_ index: Int) -> SidebarRailTileStyle? { sidebar.railTileViews[.workspaceCard(index)]?.style }

        XCTAssertEqual(style(0)?.border, Theme.Color.accent)
        XCTAssertEqual(style(1)?.badge, Theme.Color.waiting)
        XCTAssertEqual(style(1)?.textColor, Theme.Color.waiting)
        XCTAssertNil(style(2)?.badge)
        XCTAssertEqual(style(2)?.textColor, Theme.Color.textSecondary)
        XCTAssertEqual(style(3)?.badge, Theme.Color.error)
        XCTAssertEqual(style(4)?.badge, Theme.Color.working)
        // The cards leave a Mission child's question to Activity, which
        // the rail doesn't show.
        XCTAssertEqual(style(5)?.badge, Theme.Color.waiting)
    }

    func testHoveredTileShowsItsTooltipBesideTheRail() throws {
        let (sidebar, window) = rail([workspace("a", index: 0, isActive: true), workspace("asking", index: 1, columns: [permission])])
        defer { window.close() }
        let host = try XCTUnwrap(sidebar.superview)
        func tooltips() -> [SidebarRailTooltipView] { host.subviews.compactMap { $0 as? SidebarRailTooltipView } }

        sidebar.setHoverTarget(.workspaceCard(1))

        let tooltip = try XCTUnwrap(tooltips().first)
        XCTAssertEqual(tooltip.frame.minX, sidebar.frame.maxX + SidebarRailMetrics.tooltipGap)
        let tile = try XCTUnwrap(sidebar.railTileViews[.workspaceCard(1)])
        XCTAssertEqual(tooltip.frame.midY, host.convert(SidebarRailTileView.tileRect, from: tile).midY, accuracy: 1)

        sidebar.setHoverTarget(nil)
        XCTAssertTrue(tooltips().isEmpty)
        sidebar.isExpanded = true
        sidebar.setHoverTarget(.workspaceCard(1))
        XCTAssertTrue(tooltips().isEmpty)
    }

    /// A click hides the tooltip, rebuilds included, until the pointer
    /// moves: it would cover the terminal the click brought up.
    func testClickHidesTheTooltipUntilThePointerMoves() throws {
        let (sidebar, window) = rail([workspace("a", index: 0, isActive: true), workspace("b", index: 1)])
        defer { window.close() }
        let host = try XCTUnwrap(sidebar.superview)
        func showsTooltip() -> Bool { host.subviews.contains { $0 is SidebarRailTooltipView } }
        let center = try frame(of: "1", in: sidebar).center

        NSApp.postEvent(try mouseEvent(.leftMouseUp, at: center, in: sidebar, window: window), atStart: false)
        sidebar.mouseDown(with: try mouseEvent(.leftMouseDown, at: center, in: sidebar, window: window))
        sidebar.update(profiles: [], workspaces: [workspace("a", index: 0), workspace("b", index: 1, isActive: true)])
        sidebar.setHoverTarget(.workspaceCard(1))
        XCTAssertFalse(showsTooltip())

        sidebar.mouseMoved(with: try mouseEvent(.mouseMoved, at: center, in: sidebar, window: window))
        XCTAssertTrue(showsTooltip())
    }

    /// The tooltip says what the card's state line and chips say.
    func testTooltipsSayWhatTheWorkspaceIsDoing() {
        let stopped = agent(.idle, stuck: .stoppedOnError(kind: "overloaded", detail: nil, failedAt: 0, resume: .offered))
        let (sidebar, window) = rail([
            workspace("asking", index: 0, columns: [permission]),
            workspace("stopped", index: 1, columns: [stopped]),
            workspace("finished", index: 2, columns: [agent(.needsAttention, reason: .turnFinished)]),
            workspace("child asked", index: 3, notification: .waiting)
        ], profiles: [profile("p", isActive: true)])
        defer { window.close() }
        let age = SidebarView.cardAge(since: Date().timeIntervalSince1970 - 240)

        XCTAssertEqual(sidebar.railTooltip(for: .workspaceCard(0)), SidebarRailTooltip(
            title: "asking", detail: "claude needs permission · \(age)", detailColor: Theme.Color.waiting, note: "Bash: git push"
        ))
        XCTAssertEqual(sidebar.railTooltip(for: .workspaceCard(1)), SidebarRailTooltip(
            title: "stopped", detail: "claude stopped on an API error", detailColor: Theme.Color.error, note: "overloaded"
        ))
        XCTAssertEqual(sidebar.railTooltip(for: .workspaceCard(2)), SidebarRailTooltip(
            title: "finished", detail: "claude finished its turn · \(age)", detailColor: Theme.Color.textSecondary
        ))
        XCTAssertEqual(sidebar.railTooltip(for: .workspaceCard(3))?.detailColor, Theme.Color.waiting)
        // A finished turn isn't a wait.
        XCTAssertEqual(sidebar.railTooltip(for: .railButton(.project))?.detail, "2 waiting")
    }

    /// A heredoc or a plan to approve stays one line in the tooltip.
    func testMultilineRequestKeepsTheTooltipOneLine() throws {
        var request = AgentPermissionRequest(
            toolName: "Bash", summary: "git commit", key: "k", agentID: nil, sessionID: "lead", requestedAt: 0
        )
        request.approval = PermissionApprovalTicket(requestID: "r", deadline: 100, text: "git commit -F - <<'EOF'\nfix\n\nbody\nEOF")
        var asking = permission
        asking.permissionApproval = try XCTUnwrap(SidebarPermissionApproval(request, now: 1))
        let (sidebar, window) = rail([workspace("asking", index: 0, columns: [asking])])
        defer { window.close() }

        let tooltip = try XCTUnwrap(sidebar.railTooltip(for: .workspaceCard(0)))
        XCTAssertEqual(tooltip.note, "Bash: git commit -F - <<'EOF' fix body EOF")
        let oneLine = SidebarRailTooltipView()
        oneLine.show(SidebarRailTooltip(title: "t", detail: "d", note: "n"))
        let manyLines = SidebarRailTooltipView()
        manyLines.show(SidebarRailTooltip(title: "t", detail: "d", note: "1\n2\n3\n4"))
        XCTAssertEqual(manyLines.frame.height, oneLine.frame.height)
    }

    /// VoiceOver presses do what clicks do.
    func testTilesAreButtonsForVoiceOver() throws {
        let (sidebar, window) = rail(
            [workspace("a", index: 0, isActive: true), workspace("parked", index: 1, isInactive: true)],
            profiles: [profile("p", isActive: true)]
        )
        defer { window.close() }
        var clicked: [Int] = []
        sidebar.onWorkspaceClicked = { clicked.append($0) }

        let tile = try XCTUnwrap(sidebar.railTileViews[.workspaceCard(0)])
        XCTAssertEqual(tile.accessibilityRole(), .button)
        XCTAssertTrue(tile.accessibilityPerformPress())
        XCTAssertEqual(clicked, [0])
        XCTAssertEqual(sidebar.railTileViews[.railButton(.project)]?.accessibilityRole(), .menuButton)
        XCTAssertTrue(try XCTUnwrap(sidebar.railTileViews[.railButton(.inactiveSection)]).accessibilityPerformPress())
        XCTAssertFalse(sidebar.isInactiveSectionCollapsed)
        XCTAssertNotNil(sidebar.railTileViews[.workspaceCard(1)])
    }

    /// The sidebar widens empty: tiles don't come back behind the fade or
    /// during the widening, only once collapsed again.
    func testFadedRailStaysEmptyUntilTheCardsComeIn() {
        let (sidebar, window) = rail([workspace("a", index: 0, isActive: true)])
        defer { window.close() }

        sidebar.fadeOutRail {}
        sidebar.frame.size.width = 150
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertTrue(sidebar.railTileViews.isEmpty)

        sidebar.isExpanded = true
        XCTAssertTrue(sidebar.railTileViews.isEmpty)
        sidebar.isExpanded = false
        XCTAssertNotNil(sidebar.railTileViews[.workspaceCard(0)])
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
