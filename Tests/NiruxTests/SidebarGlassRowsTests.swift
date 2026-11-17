import AppKit
import XCTest
@testable import Nirux

/// The rows on glass (docs/design/glass-interface.md, steps 3.4 and 3.4b): the
/// state icons in the rows, the selected row's pane of glass, the rows'
/// buttons in `NiruxButton`'s looks, and the navigator rows.
@MainActor
final class SidebarGlassRowsTests: XCTestCase {
    private func column(_ status: AgentStatus = .idle, reason: AgentAttentionReason? = nil) -> ColumnInfo {
        ColumnInfo(
            index: 0, processName: "claude", abbreviatedCwd: nil, isFocused: false, isWebView: false, webTitle: nil,
            terminalTitle: nil, agentStatus: status, isEditor: false, editorFileName: nil, attentionReason: reason
        )
    }

    private func row(
        _ columns: [ColumnInfo], id: String = "ws", index: Int = 0, active: Bool = false, blocker: String? = nil,
        pullRequest: PRInfo? = nil
    ) -> WorkspaceInfo {
        WorkspaceInfo(
            id: id, index: index, title: "checkout \(index)", profileID: WorkspaceProfile.defaultID, isInactive: false,
            columnCount: columns.count, focusedColumn: 0, gitBranch: "feat/checkout", notification: nil, isActive: active,
            columns: columns, prInfo: pullRequest, diffStats: nil, purpose: nil, nextStep: nil, blocker: blocker,
            phase: .active, lastSummary: nil, lastActivityAt: nil
        )
    }

    private func pullRequest(state: String = "OPEN", ci: String?) -> PRInfo {
        PRInfo(
            number: 39, state: state, isDraft: false, ciStatus: ci, checks: [], reviewDecision: nil, mergeable: nil,
            url: "https://example.test/pull/39", additions: nil, deletions: nil, changedFiles: nil
        )
    }

    private func views(_ info: WorkspaceInfo) -> [NSView] {
        SidebarWorkspaceCardRenderer(workspace: info, sidebarWidth: 260, yOffset: 500, now: 5_000).render().views
    }

    /// The state icons drawn, with where each one's centre is.
    private func icons(in views: [NSView]) -> [(icon: StateIcon, center: NSPoint)] {
        // An icon fills the view that holds it.
        views.compactMap { view in
            guard let icon = (view as? StateIconView) ?? view.subviews.first as? StateIconView else { return nil }
            return (icon.icon, NSPoint(x: view.frame.midX, y: view.frame.midY))
        }
    }

    // MARK: - State icons

    /// Each row's mark is the state icon the rail and the inbox show, where
    /// the dot was: a wait says why, from the column that waits.
    func testEachRowMarkDrawsItsStateIcon() {
        let permission = AgentAttentionReason.permission(tool: "Bash", summary: "npm test")
        var finished = row([column(.needsAttention, reason: .turnFinished)])
        finished.turnStatusLine = "fix pushed"
        let cases: [(String, WorkspaceInfo, SidebarRowMark, StateIcon)] = [
            ("a permission", row([column(.needsAttention, reason: permission)]), .needsYou, StateIcon(.needsYou(.command))),
            ("a question", row([column(.needsAttention, reason: .question("Ship it?"))]), .needsYou, StateIcon(.needsYou(.question))),
            ("work", row([column(.working)]), .working, StateIcon(.working)),
            ("nothing", row([column()]), .idle, StateIcon(.idle)),
            ("a finished turn", finished, .finished, StateIcon(.finished)),
            ("failed checks", row([column()], pullRequest: pullRequest(ci: "FAILURE")), .error, StateIcon(.error)),
            ("a blocker", row([column()], blocker: "waiting for the staging key"), .blocked, StateIcon(.blocked)),
            ("merged", row([column()], pullRequest: pullRequest(state: "MERGED", ci: "SUCCESS")), .merged, StateIcon(.merged)),
        ]
        for (name, info, mark, icon) in cases {
            XCTAssertEqual(info.rowSummary.mark, mark, name)
            let drawn = icons(in: views(info))
            XCTAssertEqual(drawn.map(\.icon), [icon], name)
            XCTAssertEqual(drawn.first?.center.x ?? 0, SidebarExpandedMetrics.markCenterX, accuracy: 0.5, "\(name): where the dot was")
        }
    }

    /// The Lead keeps its sparkle; its state shows as a small icon at the
    /// end of its line while it works, needs you or broke.
    func testTheLeadsStateIsASmallIcon() {
        var lead = row([column(.needsAttention, reason: .permission(tool: "Bash", summary: "npm test"))])
        lead.isLead = true
        let drawn = icons(in: views(lead))
        XCTAssertEqual(drawn.map(\.icon), [StateIcon(.needsYou(.command))])
        XCTAssertGreaterThan(drawn.first?.center.x ?? 0, 200, "at the end of its line")
        var quiet = row([column()])
        quiet.isLead = true
        XCTAssertTrue(icons(in: views(quiet)).isEmpty, "nothing going on: its sparkle alone")
    }

    /// Checks that run: an arc turning at the icons' size; still, the
    /// family's own dashed ring.
    func testRunningChecksRingIsTheIconsSize() throws {
        let running = row([column()], pullRequest: pullRequest(ci: "PENDING"))
        let size = NSSize(width: SidebarExpandedMetrics.stateIconSize, height: SidebarExpandedMetrics.stateIconSize)
        let turning = views(running)
        let ring = try XCTUnwrap(turning.first { $0.identifier == SidebarWorkspaceCardRenderer.checksRingID })
        XCTAssertEqual(ring.frame.size, size)
        XCTAssertEqual(ring.frame.midX, SidebarExpandedMetrics.markCenterX, accuracy: 0.5)
        XCTAssertTrue(icons(in: turning).isEmpty, "the arc alone")

        let still = SidebarWorkspaceCardRenderer(workspace: running, sidebarWidth: 260, yOffset: 500, animates: false, now: 5_000)
            .render().views
        let stillRing = try XCTUnwrap(still.first { $0.identifier == SidebarWorkspaceCardRenderer.checksRingID })
        XCTAssertEqual(stillRing.frame.size, size)
        XCTAssertEqual(icons(in: still).map(\.icon), [StateIcon(.waiting)], "the family's dashed ring")
    }

    /// The catch-up card's rows show their rows' icons; a turn over, the
    /// grey check.
    func testTheCatchUpCardShowsTheRowsIcons() {
        let asks = SidebarCatchUp.row(for: row([column(.needsAttention, reason: .permission(tool: "Bash", summary: "npm test"))]))
        XCTAssertEqual(asks.kind, .asks)
        XCTAssertEqual(asks.icon, StateIcon(.needsYou(.command)))
        XCTAssertEqual(SidebarCatchUp.row(for: row([column(.working)])).icon, StateIcon(.working))
        XCTAssertEqual(SidebarCatchUp.row(for: row([column(.needsAttention, reason: .turnFinished)])).icon, StateIcon(.finished))
        XCTAssertEqual(SidebarCatchUp.row(for: row([column()], blocker: "the staging key")).icon, StateIcon(.blocked))
        let broke = SidebarCatchUp.row(for: row([column()], pullRequest: pullRequest(ci: "FAILURE")))
        XCTAssertEqual(broke.icon, StateIcon(.error))
    }

    /// A card row keeps only the icon it shows: a change of its task row's
    /// icon the card doesn't draw leaves the card equal, so its presses
    /// don't wait again.
    func testACatchUpRowChangesOnlyWithWhatItShows() {
        var finished = row([column(.needsAttention, reason: .turnFinished)])
        finished.turnStatusLine = "fix pushed"
        var idle = row([column()])
        idle.turnStatusLine = "fix pushed"
        XCTAssertNotEqual(finished.rowSummary.mark, idle.rowSummary.mark, "the task rows differ")
        XCTAssertEqual(SidebarCatchUp.row(for: finished), SidebarCatchUp.row(for: idle), "the card draws the same grey check")
        let checks = row([column()], pullRequest: pullRequest(ci: "PENDING"))
        let passed = row([column()], pullRequest: pullRequest(ci: "SUCCESS"))
        XCTAssertEqual(SidebarCatchUp.row(for: checks).text, SidebarCatchUp.row(for: passed).text)
        XCTAssertEqual(SidebarCatchUp.row(for: checks), SidebarCatchUp.row(for: passed))
    }

    // MARK: - The selection

    /// The selected row lies on a pane of glass: a translucent fill, a rim
    /// and the light on its top edge. Other rows have none.
    func testTheSelectedRowLiesOnAPaneOfGlass() throws {
        let rendered = SidebarWorkspaceCardRenderer(workspace: row([column()], active: true), sidebarWidth: 260, yOffset: 500, now: 5_000).render()
        let pane = try XCTUnwrap(rendered.views.first { $0.identifier == SidebarWorkspaceCardRenderer.selectionGlassID })
        XCTAssertEqual(pane.frame, rendered.hitAreas.last?.frame, "the whole row")
        XCTAssertEqual(pane.layer?.backgroundColor, Theme.Color.selectionGlass.cgColor)
        XCTAssertEqual(pane.layer?.borderWidth, 1)
        XCTAssertEqual(pane.layer?.borderColor, Theme.Color.line.cgColor)
        let light = try XCTUnwrap(pane.layer?.sublayers?.first)
        XCTAssertEqual(light.backgroundColor, Theme.Color.lineStrong.cgColor)
        XCTAssertEqual(light.frame.maxY, pane.bounds.height - 1, accuracy: 0.5, "along its top edge")
        XCTAssertLessThanOrEqual(light.frame.height, 1)
        XCTAssertNil(views(row([column()])).first { $0.identifier == SidebarWorkspaceCardRenderer.selectionGlassID })
    }

    // MARK: - Buttons

    /// Allow, Deny, Dismiss: the looks and the small size of `NiruxButton`,
    /// as in the inbox and the callout.
    func testTheRowsButtonsLookLikeNiruxButtons() {
        let buttons: [(SidebarBadgeView, NiruxButton.Kind)] = [
            (SidebarActionButton.primary("Allow", label: "Allow"), .primary),
            (SidebarActionButton.secondary("Deny", label: "Deny"), .secondary),
            (SidebarActionButton.quiet("Dismiss", label: "Dismiss"), .quiet),
        ]
        for (button, kind) in buttons {
            let rest = NiruxButton.look(kind, hovered: false, pressed: false, enabled: true)
            let hover = NiruxButton.look(kind, hovered: true, pressed: false, enabled: true)
            XCTAssertEqual(button.fillColor, rest.fill, "\(kind)")
            XCTAssertEqual(button.textColor, rest.text, "\(kind)")
            XCTAssertEqual(button.borderColor, rest.border, "\(kind)")
            XCTAssertEqual(button.hoverFillColor, hover.fill, "\(kind)")
            XCTAssertEqual(button.hoverTextColor, hover.text, "\(kind)")
            XCTAssertEqual(button.font, NiruxButton.Size.small.font, "\(kind)")
            XCTAssertEqual(button.cornerRadius, SidebarExpandedMetrics.buttonHeight / 2, "\(kind): a capsule")
        }
        XCTAssertEqual(SidebarExpandedMetrics.buttonHeight, NiruxButton.Size.small.height)
    }

    // MARK: - The navigator rows

    /// A sidebar in a window taller than it, `below` points under it: the
    /// window's points there fall on rows of the list out of view.
    private func windowed(_ rows: [WorkspaceInfo], height: CGFloat = 600, below: CGFloat = 0) -> (SidebarView, NSWindow) {
        _ = NSApplication.shared
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: height + below))
        let sidebar = SidebarView(frame: NSRect(x: 0, y: below, width: 260, height: height))
        host.addSubview(sidebar)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        sidebar.isExpanded = true
        sidebar.update(profiles: [space], workspaces: rows)
        host.layoutSubtreeIfNeeded()
        return (sidebar, window)
    }

    private let space = ProfileInfo(
        id: WorkspaceProfile.defaultID, name: "Acme", colorHex: "#9ECE6A", isActive: true, workspaceCount: 2, taskCount: 2, attention: nil
    )

    private func frame(of region: (SidebarHitRegion) -> Bool, in sidebar: SidebarView) throws -> NSRect {
        try XCTUnwrap(sidebar.hitAreas.first { region($0.region) }?.frame)
    }

    /// The Board row sits under the space's header, History at the bottom
    /// with Archived above it; the list takes the whole height. Board reads
    /// open ("Board, open", its symbol in the accent) while the space's
    /// Board column shows, as the rail's Board button does, never on the
    /// selection's glass: that stays the task's. History opens its panel and
    /// is never selected.
    func testTheNavigatorRows() throws {
        let archived = WorkspaceInfo(
            id: "old", index: 1, title: "old", profileID: WorkspaceProfile.defaultID, isInactive: true,
            columnCount: 1, focusedColumn: 0, gitBranch: nil, notification: nil, isActive: false, columns: [column()],
            prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .parked, lastSummary: nil, lastActivityAt: nil
        )
        let rows = [row([column()], active: true), archived]
        let (sidebar, window) = windowed(rows)
        defer { window.close() }
        /// As the shell does: the state, then the rows, rebuilt once.
        func show(_ navigation: SidebarNavigation) {
            sidebar.navigation = navigation
            sidebar.update(profiles: [space], workspaces: rows)
        }
        XCTAssertEqual(sidebar.contentScrollView.frame, sidebar.bounds, "no foot: the list has the whole height")

        let picker = try frame(of: { if case .spacePicker = $0 { true } else { false } }, in: sidebar)
        let board = try frame(of: { if case .board = $0 { true } else { false } }, in: sidebar)
        let history = try frame(of: { if case .history = $0 { true } else { false } }, in: sidebar)
        let archivedRow = try XCTUnwrap(sidebar.inactiveSectionHeaderFrame)
        let firstTask = try frame(of: { if case .workspace = $0 { true } else { false } }, in: sidebar)
        XCTAssertLessThan(board.maxY, picker.minY, "under the space's header")
        XCTAssertGreaterThan(board.minY, firstTask.maxY, "above the tasks")
        XCTAssertEqual(history.minY, SidebarExpandedMetrics.bottomPadding, "at the bottom")
        XCTAssertGreaterThan(archivedRow.minY, history.maxY, "Archived above History")
        let controls = sidebar.expandedViews.compactMap { $0 as? SidebarSectionToggleView }
        let historyAt = try XCTUnwrap(controls.firstIndex { $0.frame == history })
        let archivedAt = try XCTUnwrap(controls.firstIndex { $0.frame == archivedRow })
        XCTAssertGreaterThan(historyAt, archivedAt, "VoiceOver reads Archived, then History")

        var opened = 0
        var shown = 0
        sidebar.onOpenBoard = { opened += 1 }
        sidebar.onShowHistory = { shown += 1 }
        func control(at frame: NSRect) throws -> SidebarSectionToggleView {
            try XCTUnwrap(sidebar.expandedViews.compactMap { $0 as? SidebarSectionToggleView }.first { $0.frame == frame })
        }
        func selected(_ frame: NSRect) -> Bool {
            sidebar.expandedViews.contains { $0.identifier == SidebarWorkspaceCardRenderer.selectionGlassID && $0.frame == frame }
        }
        XCTAssertFalse(selected(board), "the Board isn't shown")
        func boardSymbol() throws -> Data? {
            try XCTUnwrap(sidebar.expandedViews.first { $0.identifier?.rawValue == "nirux.sidebar.navigator.Board" } as? SidebarImageView)
                .image?.tiffRepresentation
        }
        let plainSymbol = try boardSymbol()
        XCTAssertEqual(try control(at: board).accessibilityLabel(), "Board")
        XCTAssertTrue(try control(at: board).toolTip?.hasPrefix("Board (") == true, "its shortcut")
        XCTAssertEqual(try control(at: history).toolTip, "Session History")
        XCTAssertTrue(try control(at: board).accessibilityPerformPress())
        XCTAssertTrue(try control(at: history).accessibilityPerformPress())
        XCTAssertEqual([opened, shown], [1, 1])

        show(SidebarNavigation(boardShown: true, boardAvailable: true))
        XCTAssertEqual(try control(at: board).accessibilityLabel(), "Board, open", "the Board column on screen")
        XCTAssertNotEqual(try boardSymbol(), plainSymbol)
        XCTAssertEqual(
            try boardSymbol(), SidebarRenderer.symbol(Theme.Symbol.projectBoard, color: Theme.Color.accent, pointSize: 12)?.tiffRepresentation,
            "its symbol in the accent"
        )
        XCTAssertFalse(selected(board), "one selection: the task's")
        XCTAssertTrue(selected(firstTask))
        XCTAssertFalse(selected(history))
        XCTAssertTrue(sidebar.iconRail.boardButton.isSelected, "the rail's Board button too")
        XCTAssertEqual(sidebar.iconRail.boardButton.spokenLabel, "Board, open")
        XCTAssertEqual(sidebar.iconRail.boardButton.label, "Board", "its own label stays")

        // No task open: nothing to open the Board beside, nor a press, a
        // first click or a hover.
        show(SidebarNavigation(boardShown: false, boardAvailable: false))
        XCTAssertFalse(try control(at: board).accessibilityPerformPress())
        XCTAssertFalse(try control(at: board).acceptsFirstMouse(for: nil))
        XCTAssertEqual(try control(at: board).toolTip, "Open a task to show its space’s Board")
        XCTAssertTrue(sidebar.hitAreas.contains { $0.frame == board && $0.region.isInert }, "it takes the click and does nothing")
        XCTAssertEqual(opened, 1)
        XCTAssertFalse(sidebar.iconRail.boardButton.isEnabled)
        XCTAssertFalse(sidebar.iconRail.boardButton.isSelected)
        XCTAssertEqual(sidebar.iconRail.boardButton.toolTip, "Open a task to show its space’s Board", "the rail says why too")
    }

    /// A double-click on Board or History acts once: its second press would
    /// focus the Board just opened, or show the panel again.
    func testADoubleClickOnANavigatorRowActsOnce() throws {
        let (sidebar, window) = windowed([row([column()], active: true)])
        defer { window.close() }
        var opened = 0
        var shown = 0
        sidebar.onOpenBoard = { opened += 1 }
        sidebar.onShowHistory = { shown += 1 }
        // Seconds apart: one double-click never covers the other's.
        var start = ProcessInfo.processInfo.systemUptime
        func doubleClick(_ region: (SidebarHitRegion) -> Bool) throws {
            let frame = try frame(of: region, in: sidebar)
            let point = sidebar.contentDocumentView.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
            start += 10
            for clicks in 1...2 {
                sidebar.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: [], timestamp: start + Double(clicks) / 10,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
                )))
            }
        }
        try doubleClick { if case .board = $0 { true } else { false } }
        try doubleClick { if case .history = $0 { true } else { false } }
        XCTAssertEqual([opened, shown], [1, 1])
    }

    /// The Board row reads open while the space's Board column shows, and
    /// follows it as the columns are laid out: an edge dragged pushes the
    /// Board out of view at once, with no refresh of the whole sidebar.
    func testTheBoardRowFollowsItsColumn() throws {
        _ = NSApplication.shared
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        shell.stopHeartbeat()
        let workspace = try XCTUnwrap(shell.activeWorkspace)
        workspace.addProjectBoardColumn(shell.makeProjectBoard(projectID: workspace.profileID, offersSettings: true))
        let agent = try XCTUnwrap(workspace.columns.firstIndex { $0.projectBoard == nil })
        workspace.focusedIndex = agent
        shell.relayout(animated: false)
        XCTAssertEqual(shell.sidebar.navigation, SidebarNavigation(boardShown: true, boardAvailable: true), "beside the agent")
        XCTAssertTrue(shell.sidebar.iconRail.boardButton.isSelected)

        shell.isMetadataRefreshScheduled = false
        let agentView = workspace.columns[agent].view
        let handle = try XCTUnwrap(agentView.superview?.subviews.compactMap { $0 as? ColumnResizeHandle }.first {
            $0.frame.minX <= agentView.frame.maxX && agentView.frame.maxX <= $0.frame.maxX
        }, "the handle on the agent's right edge")
        handle.onDrag?(WorkspaceState.maxWidthFraction)
        XCTAssertFalse(shell.sidebar.navigation.boardShown, "pushed out of view")
        XCTAssertFalse(shell.sidebar.iconRail.boardButton.isSelected)
        XCTAssertFalse(shell.isMetadataRefreshScheduled, "no process-table scan for one row")

        // Closing, it no longer counts.
        handle.onDrag?(ColumnWidth.half.fraction)
        XCTAssertTrue(shell.sidebar.navigation.boardShown)
        let board = try XCTUnwrap(workspace.columns.first { $0.projectBoard != nil })
        board.isClosing = true
        XCTAssertFalse(shell.sidebarNavigation.boardShown, "closing")
        board.isClosing = false
    }

    /// A task's station, through the Board's rule, from what the app holds
    /// of it (5.1b).
    func testATasksStationFromWhatTheAppHolds() {
        let head = String(repeating: "a", count: 40)
        func check(_ name: String, _ result: ProjectBoard.CheckResult) -> ProjectBoard.Check {
            ProjectBoard.Check(name: name, workflowName: nil, result: result, startedAt: "2026-11-11T12:00:00Z", url: nil)
        }
        func pr(_ checks: [ProjectBoard.Check], state: String = "OPEN") -> PRInfo {
            PRInfo(
                number: 12, state: state, isDraft: false, ciStatus: nil, checks: checks, reviewDecision: nil, mergeable: nil,
                url: "https://github.com/Acme/Widgets/pull/12", additions: nil, deletions: nil, changedFiles: nil
            )
        }
        let reviewed = ReviewBadges(runs: [.codeReview: ReviewRun(head: head, at: 10, branch: "feat/x")], head: head)
        func station(
            _ pullRequest: PRInfo?, required: [String]?, branch: String = "feat/x", queue: ProjectBoard.QueueState? = nil
        ) -> BoardStages.Station {
            NiruxShellView.station(
                pullRequest: pullRequest, reviews: reviewed, reviewsInFlight: [], branch: branch, required: required, queue: queue
            )
        }
        let green = [check("test", .success)]
        XCTAssertEqual(station(pr(green), required: nil), .merge)
        XCTAssertEqual(station(pr(green, state: "CLOSED"), required: nil), .checks, "a closed pull request is none")
        XCTAssertEqual(station(pr([]), required: nil), .checks, "no check reported yet: still to come")
        XCTAssertEqual(station(pr([]), required: []), .merge, "its space requires none")
        XCTAssertEqual(station(pr([]), required: ["test"]), .checks)
        let running = green + [check("lint", .pending)]
        XCTAssertEqual(station(pr(running), required: ["test"]), .merge, "lint isn't required")
        XCTAssertEqual(station(pr(running), required: nil), .checks, "every check counts")
        XCTAssertEqual(station(pr(green), required: nil, branch: "feat/y"), .reviews, "a review of another branch")

        var entry = MergeQueue.Entry(MergeQueue.ConfirmedEntry(number: 12, head: head, branch: "feat/x"))
        entry.step = .preflight
        var queue = ProjectBoard.QueueState(run: .running(isStopping: false), isDryRun: false, entries: [entry], workflow: nil, selection: [])
        XCTAssertEqual(station(pr(green), required: nil, queue: queue), .checks, "the queue's step")
        queue.entries[0].mergeCommit = String(repeating: "d", count: 40)
        queue.entries[0].step = .done
        XCTAssertEqual(station(pr(running), required: nil, queue: queue), .merge, "the queue merged it")

        var config = BoardConfig()
        config.repository = "acme/widgets"
        config.requiredChecks = ["test"]
        var legacy = config
        legacy.requiredChecks = ["lint"]
        let widgets = GitHubRepository(owner: "Acme", name: "Widgets")
        let entries = [
            BoardConfigStore.Entry(slot: .legacy, config: legacy),
            BoardConfigStore.Entry(slot: .anchor(commonDir: "/p/widgets/.git"), config: config)
        ]
        XCTAssertEqual(NiruxShellView.requiredChecks(of: widgets, in: entries), ["test"], "an anchor's config before schema 1's")
        XCTAssertNil(NiruxShellView.requiredChecks(of: GitHubRepository(owner: "acme", name: "gadgets"), in: entries))
        XCTAssertEqual(NiruxShellView.repository(of: pr([])), widgets)
    }

    /// One station per task, read once a pass: the row, the rail, the
    /// command bar, ⌘P and the Board's lines show it; opening the Board
    /// moves none; a read that changes it reaches the row and the Board in
    /// the same pass. The Lead has none.
    func testEverySurfaceShowsTheTasksOneStation() throws {
        _ = NSApplication.shared
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        shell.stopHeartbeat()
        let workspace = try XCTUnwrap(shell.activeWorkspace)
        let head = String(repeating: "a", count: 40)
        shell.boardEntriesBySpace[workspace.profileID] = []
        _ = workspace.updateGitContext(GitContext(branch: "feat/x", identity: GitIdentity(repositoryRoot: "/tmp/widgets", head: head)))
        workspace.reviewRuns = [.codeReview: ReviewRun(head: head, at: 10, branch: "feat/x")]
        func read(_ result: ProjectBoard.CheckResult) {
            workspace.prInfo = PRInfo(
                number: 12, state: "OPEN", isDraft: false, ciStatus: nil,
                checks: [ProjectBoard.Check(name: "test", workflowName: nil, result: result, startedAt: "2026-11-11T12:00:00Z", url: nil)],
                reviewDecision: nil, mergeable: nil, url: "https://github.com/acme/widgets/pull/12", additions: nil, deletions: nil,
                changedFiles: nil
            )
        }
        let board = shell.makeProjectBoard(projectID: workspace.profileID, offersSettings: true)
        func surfaces() throws -> [BoardStages.Station?] {
            let row = try XCTUnwrap(shell.sidebar.lastInfos.first { $0.id == workspace.id })
            let bar = NiruxShellView.commandBarContent(space: WorkspaceProfile.defaultProfile, task: row, waitingCount: 0)
            let palette = PaletteBadge(.working, station: shell.taskStations[workspace.id], now: 0)
            let inputs = shell.stagesInputs(of: board, members: [workspace], workspaces: [], readings: [:], order: .sidebar)
            let stage = { (icon: StateIcon?) in BoardStages.Station.allCases.first { StateIcon.stage(of: $0) == icon?.stage } }
            return [row.station, stage(row.stateIcon), stage(row.railIcon), stage(bar.taskIcon), stage(palette.icon), inputs.stations[workspace.id]]
        }
        let unread = ProcessSnapshot(entries: [])
        read(.success)
        shell.updateSidebar(snapshot: unread)
        XCTAssertEqual(try surfaces(), Array(repeating: .merge, count: 6))

        workspace.addProjectBoardColumn(board)
        shell.updateSidebar(snapshot: unread)
        XCTAssertEqual(try surfaces(), Array(repeating: .merge, count: 6), "opening the Board moves no station")

        read(.pending)
        shell.updateSidebar(snapshot: unread)
        XCTAssertEqual(try surfaces(), Array(repeating: .checks, count: 6), "one pass: the row and the Board")

        workspace.isLead = true
        shell.updateSidebar(snapshot: unread)
        XCTAssertNil(shell.taskStations[workspace.id], "the Lead isn't a task")
    }

    /// A working row's own icon fills up to its station: the card's and the
    /// catch-up card's, not only the rail's.
    func testTheCardsIconFillsUpToItsStation() {
        var info = row([column(.working)])
        info.station = .reviews
        XCTAssertEqual(icons(in: views(info)).first?.icon, StateIcon(.working, stage: 2))
        XCTAssertEqual(SidebarCatchUp.icon(for: .working, row: info.stateIcon), StateIcon(.working, stage: 2))
    }

    /// A row of the list out of view takes no press, no hover and no menu
    /// where the window shows something else (under the sidebar here).
    func testRowsOutOfViewTakeNoPress() throws {
        let (sidebar, window) = windowed((0..<20).map { row([column()], id: "ws\($0)", index: $0) }, height: 300, below: 60)
        defer { window.close() }
        var clicked: [Int] = []
        sidebar.onWorkspaceClicked = { clicked.append($0) }
        XCTAssertGreaterThan(sidebar.contentDocumentView.frame.height, 300, "a long list")
        let under = NSPoint(x: 30, y: 30)
        let hidden = sidebar.contentDocumentView.convert(under, from: nil)
        XCTAssertTrue(sidebar.hitAreas.contains { if case .workspace = $0.region { $0.frame.contains(hidden) } else { false } },
                      "a row lies there, out of view")
        XCTAssertNil(sidebar.hitArea(at: hidden), "out of view: no area")
        XCTAssertNil(sidebar.cardIndex(at: hidden), "nor a card")
        func event(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
            ))
        }
        XCTAssertNil(sidebar.menu(for: try event(.rightMouseDown, at: under)), "no row's menu")
        sidebar.mouseMoved(with: try event(.mouseMoved, at: under))
        XCTAssertNil(sidebar.hoveredTarget, "no row lit")
        sidebar.mouseDown(with: try event(.leftMouseDown, at: under))
        XCTAssertEqual(clicked, [], "no row pressed")
        // A row's click, then a second one out of view: no double-click
        // renames that row.
        var actions: [Int] = []
        sidebar.onWorkspaceAction = { _, index in actions.append(index) }
        sidebar.lastRowPress = (0, ProcessInfo.processInfo.systemUptime)
        sidebar.mouseDown(with: try event(.leftMouseDown, at: under, clicks: 2))
        XCTAssertEqual(actions, [], "no rename")

        // A row in view still answers.
        let visible = sidebar.contentScrollView.documentVisibleRect
        let inView = try XCTUnwrap(sidebar.hitAreas.first { area in
            if case .workspace = area.region { visible.contains(area.frame) } else { false }
        })
        let onRow = sidebar.contentDocumentView.convert(NSPoint(x: inView.frame.midX, y: inView.frame.midY), to: nil)
        XCTAssertNotNil(sidebar.menu(for: try event(.rightMouseDown, at: onRow)), "a row in view has its menu")
    }
}
