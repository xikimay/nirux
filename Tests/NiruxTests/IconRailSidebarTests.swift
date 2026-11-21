import AppKit
import XCTest
@testable import Nirux

/// The folded sidebar is the icon rail (docs/design/glass-interface.md,
/// step 3.2): what it lists, what a click on it does, and when the sidebar
/// folds by itself.
@MainActor
final class IconRailSidebarTests: XCTestCase {
    private func column(_ index: Int, _ status: AgentStatus, reason: AgentAttentionReason? = nil) -> ColumnInfo {
        ColumnInfo(
            index: index, processName: "claude", abbreviatedCwd: "~/app", isFocused: index == 0, isWebView: false,
            webTitle: nil, terminalTitle: nil, agentStatus: status, isEditor: false, editorFileName: nil, attentionReason: reason
        )
    }

    private func row(
        _ id: String, index: Int, archived: Bool = false, active: Bool = false, lead: Bool = false,
        columns: [ColumnInfo] = [], notification: AttentionSignal? = nil, purpose: String? = nil, nextStep: String? = nil
    ) -> WorkspaceInfo {
        var info = WorkspaceInfo(
            id: id, index: index, title: id.capitalized, profileID: WorkspaceProfile.defaultID, isInactive: archived,
            columnCount: max(1, columns.count), focusedColumn: 0, gitBranch: "feat/\(id)", notification: notification,
            isActive: active, columns: columns, prInfo: nil, diffStats: nil, purpose: purpose, nextStep: nextStep, blocker: nil,
            phase: archived ? .parked : .active, lastSummary: nil, lastActivityAt: nil
        )
        info.isLead = lead
        return info
    }

    private var rows: [WorkspaceInfo] {
        [
            row("lead", index: 0, lead: true, columns: [column(0, .working)]),
            row("checkout", index: 1, active: true, columns: [column(0, .working)]),
            row("export", index: 2, columns: [column(0, .idle), column(1, .needsAttention, reason: .permission(tool: "Bash", summary: "npm run migrate"))]),
            row("parked", index: 3, archived: true),
            row("asks", index: 4, archived: true, columns: [column(0, .needsAttention, reason: .question("Which date?"))]),
            row("handed", index: 5, archived: true, columns: [column(0, .working)], notification: .waiting),
        ]
    }

    private func sidebar(_ rows: [WorkspaceInfo], width: CGFloat = SidebarView.foldedWidth) -> SidebarView {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        sidebar.update(profiles: [], workspaces: rows)
        return sidebar
    }

    /// Folded, the sidebar is the rail, in the 52 pt it had, without the
    /// cards' scroll view: the Lead apart, the active tasks in order, then of
    /// the archived ones those that wait on the user, never the whole
    /// archived list (it has nowhere to show); the task on screen chosen; the
    /// archived ones counted. Unfolded, the rail goes.
    func testFoldedTheSidebarIsTheRail() {
        let sidebar = sidebar(rows)
        let rail = sidebar.iconRail
        XCTAssertFalse(rail.isHidden)
        XCTAssertEqual(sidebar.layer?.backgroundColor, Theme.Color.canvas.cgColor, "the capsule reads on the window's colour")
        XCTAssertTrue(sidebar.contentScrollView.isHidden, "no cards, no scroller")
        XCTAssertEqual(rail.frame, NSRect(x: 7, y: 10, width: IconRail.width, height: 600 - Theme.Space.md - 10))
        XCTAssertEqual(rail.content.lead?.id, "lead")
        XCTAssertEqual(rail.content.tasks.map(\.id), ["checkout", "export", "asks", "handed"])
        XCTAssertEqual(rail.content.selectedID, "checkout")
        XCTAssertEqual(rail.content.archivedCount, 3)

        sidebar.toggleInactiveSection()
        XCTAssertEqual(rail.content.tasks.map(\.id), ["checkout", "export", "asks", "handed"], "the archived list stays out")

        sidebar.isExpanded = true
        XCTAssertTrue(rail.isHidden)
        XCTAssertEqual(sidebar.layer?.backgroundColor, Theme.Color.base.cgColor, "the cards on the sidebar's")
        XCTAssertFalse(sidebar.contentScrollView.isHidden)
        sidebar.isExpanded = false
        XCTAssertFalse(rail.isHidden)
    }

    /// Each icon is its row's state: a wait says its reason from the column
    /// that waits; a question a Mission child handed to the user shows
    /// amber, as its tile did.
    func testEachIconIsItsRowsState() {
        let icons = Dictionary(uniqueKeysWithValues: sidebar(rows).iconRail.content.tasks.map { ($0.id, $0.icon) })
        XCTAssertEqual(icons["checkout"], StateIcon(.working))
        XCTAssertEqual(icons["export"], StateIcon(.needsYou(.command)), "the waiting column's, not the focused one's")
        XCTAssertEqual(icons["asks"], StateIcon(.needsYou(.question)))
        XCTAssertEqual(icons["handed"], StateIcon(.needsYou(.question)), "handed to the user")
        XCTAssertEqual(sidebar(rows).iconRail.content.lead?.icon, StateIcon(.working))

        // The tooltip says what the row says; the icon's state where the
        // row would print the branch.
        let rail = sidebar(rows + [row("audit", index: 6)]).iconRail
        XCTAssertEqual(rail.itemViews["export"]?.toolTip, "Export · Needs you · Bash: npm run migrate")
        XCTAssertEqual(rail.itemViews["checkout"]?.toolTip, "Checkout · Working")
        XCTAssertEqual(rail.itemViews["audit"]?.toolTip, "Audit · Idle")
        XCTAssertEqual(rail.itemViews["handed"]?.toolTip, "Handed · Needs you: a question", "as amber as its icon")
    }

    /// A click on an icon does what a click on its row does: a task whose
    /// agent waits goes to that column, another to the task; a right-click
    /// opens the task's menu; the buttons reach the shell.
    func testTheRailActsAsTheRowsDo() throws {
        let sidebar = sidebar(rows)
        var columns: [[Int]] = [], workspaces: [Int] = [], pressed: [String] = []
        sidebar.onColumnClicked = { columns.append([$0, $1]) }
        sidebar.onWorkspaceClicked = { workspaces.append($0) }
        sidebar.onShowArchived = { pressed.append("archived") }
        sidebar.onNewWorkspace = { pressed.append("new") }
        sidebar.onOpenBoard = { pressed.append("board") }
        let rail = sidebar.iconRail
        XCTAssertTrue(try XCTUnwrap(rail.itemViews["export"]).accessibilityPerformPress())
        XCTAssertTrue(try XCTUnwrap(rail.itemViews["lead"]).accessibilityPerformPress())
        XCTAssertEqual(columns, [[2, 1]], "the column that waits")
        XCTAssertEqual(workspaces, [0])

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ))
        let menu = try XCTUnwrap(rail.itemViews["checkout"]?.menu(for: event))
        XCTAssertTrue(menu.items.contains { $0.title == "Rename Workspace" }, "the task's menu")

        rail.onArchived?()
        rail.onNew?()
        rail.onBoard?()
        XCTAssertEqual(pressed, ["archived", "new", "board"])
    }

    /// The working icons breathe while rows may move and the rail shows,
    /// not otherwise.
    func testTheRailBreathesWhileRowsMayMove() throws {
        let sidebar = sidebar(rows)
        let checkout = try XCTUnwrap(sidebar.iconRail.itemViews["checkout"])
        XCTAssertNotNil(checkout.iconView.layer?.animation(forKey: RailItemView.breathKey))
        sidebar.animates = false
        XCTAssertNil(checkout.iconView.layer?.animation(forKey: RailItemView.breathKey))
        sidebar.animates = true
        XCTAssertNotNil(checkout.iconView.layer?.animation(forKey: RailItemView.breathKey))
        sidebar.isExpanded = true
        XCTAssertNil(checkout.iconView.layer?.animation(forKey: RailItemView.breathKey), "hidden: still")
        sidebar.isExpanded = false
        XCTAssertNotNil(checkout.iconView.layer?.animation(forKey: RailItemView.breathKey))
    }

    /// The rail's archived tasks, folded: the list is open when the cards
    /// come in, its header in view below a long list. Unfolded, it opens
    /// (and stays open), and without archived tasks nothing happens.
    func testShowingTheArchivedListWhileFolded() throws {
        let many = (0..<20).map { row("task\($0)", index: $0, active: $0 == 0) } + [row("parked", index: 20, archived: true)]
        let sidebar = sidebar(many, width: 260)
        let window = NSWindow(contentRect: sidebar.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        defer { window.close() }
        sidebar.layoutSubtreeIfNeeded()
        sidebar.showInactiveSection()
        XCTAssertFalse(sidebar.isInactiveSectionCollapsed)
        sidebar.isExpanded = true
        let header = try XCTUnwrap(sidebar.inactiveSectionHeaderFrame)
        XCTAssertGreaterThan(sidebar.contentDocumentView.frame.height, 600, "a long list")
        XCTAssertTrue(sidebar.contentScrollView.contentView.bounds.contains(header), "its header in view")
        XCTAssertNotNil(sidebar.rowFrame(workspaceID: "parked"), "the archived row is listed")
        sidebar.showInactiveSection()
        XCTAssertFalse(sidebar.isInactiveSectionCollapsed, "it opens, never folds")

        let none = self.sidebar([row("a", index: 0, active: true)])
        none.showInactiveSection()
        XCTAssertTrue(none.isInactiveSectionCollapsed)

        // Folded again before the cards came: the list stays folded, and a
        // later unfold doesn't jump to it.
        let cancelled = self.sidebar(many, width: 260)
        cancelled.showInactiveSection()
        cancelled.isExpanded = false
        XCTAssertTrue(cancelled.isInactiveSectionCollapsed)
        XCTAssertFalse(cancelled.revealsInactiveSectionOnNextBuild)
        // Already open: it stays open.
        let open = self.sidebar(many, width: 260)
        open.toggleInactiveSection()
        open.showInactiveSection()
        open.isExpanded = false
        XCTAssertFalse(open.isInactiveSectionCollapsed)

        // Another space before the cards came: nothing to bring into view.
        let switched = self.sidebar(many, width: 260)
        switched.showInactiveSection()
        switched.update(profiles: [ProfileInfo(
            id: "other", name: "Other", colorHex: "#7AA2F7", isActive: true, workspaceCount: 1, taskCount: 1, attention: nil
        )], workspaces: many)
        XCTAssertFalse(switched.revealsInactiveSectionOnNextBuild)
    }

    /// Faded out for an unfold, the rail stays hidden through rebuilds
    /// until the cards come in; folding brings it back.
    func testAFadedRailStaysHiddenUntilTheCardsComeIn() {
        let sidebar = sidebar(rows)
        var done = false
        sidebar.fadeOutRail { done = true }
        XCTAssertTrue(sidebar.iconRail.isHidden)
        XCTAssertEqual(sidebar.layer?.sublayers?.last?.backgroundColor, Theme.Color.canvas.cgColor, "the picture fades from the rail's colour")
        sidebar.update(profiles: [], workspaces: rows.reversed())
        XCTAssertTrue(sidebar.iconRail.isHidden, "a refresh doesn't bring it back")
        sidebar.isExpanded = true
        XCTAssertTrue(sidebar.iconRail.isHidden)
        sidebar.isExpanded = false
        XCTAssertFalse(sidebar.iconRail.isHidden)
        _ = done
    }

    // MARK: - Folding by itself

    /// Below 900 pt the sidebar folds by itself and widening past 940 pt
    /// gives it back to the user's choice, which is what is saved; a toggle
    /// while narrow is the user's choice until the window gets wide and
    /// narrow again.
    func testANarrowWindowFoldsTheSidebar() {
        var fold = SidebarFold(chosenExpanded: true)
        fold.windowResized(to: 1200)
        XCTAssertTrue(fold.isExpanded)
        fold.windowResized(to: 899)
        XCTAssertFalse(fold.isExpanded, "narrow: folded")
        XCTAssertTrue(fold.chosenExpanded, "the choice stays")
        fold.windowResized(to: 939)
        XCTAssertFalse(fold.isExpanded, "back about the width: still folded")
        fold.windowResized(to: 940)
        XCTAssertTrue(fold.isExpanded, "wide again: unfolded")
        fold.windowResized(to: 900)
        XCTAssertTrue(fold.isExpanded, "900 isn't narrow")

        fold.windowResized(to: 700)
        fold.choose(true)
        XCTAssertTrue(fold.isExpanded, "unfolded while narrow")
        fold.windowResized(to: 650)
        XCTAssertTrue(fold.isExpanded, "narrower still: the choice holds")
        fold.windowResized(to: 1000)
        fold.windowResized(to: 800)
        XCTAssertFalse(fold.isExpanded, "narrow again: folded")

        var folded = SidebarFold(chosenExpanded: false)
        folded.windowResized(to: 700)
        folded.windowResized(to: 1400)
        XCTAssertFalse(folded.isExpanded, "folded by the user: it stays folded")
    }

    /// A first launch in a narrow window still shows the Getting Started
    /// checklist, which lives in the sidebar: it unfolds whatever the width.
    func testAFirstLaunchUnfoldsEvenNarrow() {
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        shell.stopHeartbeat()
        // As saved before the window's width was known.
        shell.sidebarFold = SidebarFold(chosenExpanded: true)
        shell.relayoutForNewSize()
        XCTAssertFalse(shell.isSidebarExpanded, "narrow: folded")
        shell.decideOnboardingChecklist(persisted: nil, hasUnreadableState: false)
        XCTAssertTrue(shell.isSidebarExpanded, "the checklist shows")
        XCTAssertTrue(shell.sidebar.isExpanded)
    }

    /// Unfolded back by a widening window, the cards are laid out at the
    /// sidebar's width, not the rail's.
    func testAnAutomaticUnfoldLaysTheCardsOutWide() {
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
        shell.stopHeartbeat()
        shell.sidebarFold = SidebarFold(chosenExpanded: true)
        shell.setFrameSize(NSSize(width: 800, height: 600))
        XCTAssertFalse(shell.sidebar.isExpanded, "narrow: folded")
        shell.setFrameSize(NSSize(width: 1200, height: 600))
        XCTAssertTrue(shell.sidebar.isExpanded, "wide: unfolded")
        XCTAssertGreaterThan(shell.sidebar.listWidth, 200)
    }

    /// The archived list opened from the rail stays open when ⌘P's
    /// Show/Hide Archived comes before the cards: the sidebar still shows
    /// the rail, whatever the choice says.
    func testShowArchivedWhileTheCardsAreOnTheirWay() {
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
        shell.stopHeartbeat()
        shell.sidebar.update(profiles: [], workspaces: [row("a", index: 0, active: true), row("parked", index: 1, archived: true)])
        shell.sidebarFold.choose(true)
        shell.sidebar.showInactiveSection()
        XCTAssertFalse(shell.sidebar.isExpanded, "the cards not in yet")
        shell.toggleArchivedTasks()
        XCTAssertFalse(shell.sidebar.isInactiveSectionCollapsed, "still open")
    }

    /// Only a change of size folds or unfolds the sidebar by itself: not a
    /// relayout for the status bar or an animated toggle.
    func testOnlyASizeChangeFoldsTheSidebar() {
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
        shell.stopHeartbeat()
        shell.isSidebarExpanded = true
        shell.sidebar.isExpanded = true
        // The width a relayout reads, without a resize.
        shell.setBoundsSize(NSSize(width: 800, height: 600))
        shell.relayout(animated: true)
        XCTAssertTrue(shell.sidebar.isExpanded, "a relayout alone decides nothing")
        shell.relayoutForNewSize()
        XCTAssertFalse(shell.sidebar.isExpanded)
    }

    func testInitialsDropTheBranchTypeAndNumberRepeats() {
        XCTAssertEqual(TaskInitials.initials(of: "Fix login rate limit"), "FL")
        XCTAssertEqual(TaskInitials.initials(of: "feat/crash-report"), "CR")
        XCTAssertEqual(TaskInitials.initials(of: "main"), "MA")
        XCTAssertEqual(TaskInitials.initials(of: "CelticFantasyMusicLofi"), "CF")
        XCTAssertEqual(TaskInitials.initials(of: "ws 12"), "W12")
        XCTAssertEqual(TaskInitials.initials(of: "nirux-101"), "N101")
        XCTAssertEqual(TaskInitials.initials(of: "Update CI/CD pipeline"), "UC")
        XCTAssertEqual(TaskInitials.initials(of: "  "), "?")
        XCTAssertEqual(
            TaskInitials.initials(for: ["feat/merge-queue-engine", "feat/merge-queue-ui", "docs/merge-queue"]),
            ["MQ", "MQ2", "MQ3"]
        )
    }

    /// Each task's icon carries its initials, numbered over every task of
    /// the space (listed or not, so none renumbers as tasks come and go);
    /// the Lead has its sign. An amber icon shows its glyph instead.
    func testEachIconCarriesItsTasksInitials() throws {
        // An archived task the rail doesn't list, before "Asks": "AS".
        var all = rows
        all.insert(row("ascent", index: 6, archived: true), at: 3)
        let rail = sidebar(all).iconRail
        let labels = Dictionary(uniqueKeysWithValues: rail.content.tasks.map { ($0.id, $0.label) })
        XCTAssertFalse(labels.keys.contains("ascent"), "not listed")
        XCTAssertEqual(labels["checkout"], "CH")
        XCTAssertEqual(labels["asks"], "AS2", "numbered over every task")
        XCTAssertNil(rail.content.lead?.label)
        XCTAssertEqual(try XCTUnwrap(rail.itemViews["checkout"]).iconView.shownLabel, "CH")
        XCTAssertNil(try XCTUnwrap(rail.itemViews["export"]).iconView.shownLabel, "its amber glyph instead")
    }

    func testTaskPreviewOpensFromTheRowAndRailWithTheSameWorkspaceID() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 500))
        host.addSubview(sidebar)
        sidebar.isExpanded = true
        let task = row("fix login", index: 4, purpose: "Keep users signed in", nextStep: "Run the login tests")
        sidebar.update(profiles: [], workspaces: [task])
        host.layoutSubtreeIfNeeded()
        let responder = window.firstResponder
        var selected: Int?
        var opened: [String] = []
        sidebar.onWorkspaceClicked = { selected = $0 }
        func card() throws -> TaskPreviewCard {
            waitUntil("the task preview appears", timeout: 3) { sidebar.taskPreview.card != nil }
            return try XCTUnwrap(sidebar.taskPreview.card)
        }
        func press(_ title: String, in preview: TaskPreviewCard) throws {
            try XCTUnwrap(preview.subviews.compactMap { $0 as? NSButton }.first { $0.title == title }).performClick(nil)
        }

        func moveOverRow() throws {
            let frame = try XCTUnwrap(sidebar.rowFrame(workspaceID: task.id))
            let point = sidebar.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            sidebar.mouseMoved(with: event)
        }

        try moveOverRow()
        let expanded = try card()
        let lines = expanded.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertEqual(lines, ["Fix Login", "Keep users signed in", "Active", "Next · Run the login tests"])
        XCTAssertTrue(window.firstResponder === responder)
        XCTAssertGreaterThanOrEqual(expanded.frame.minX, sidebar.frame.maxX)
        try press("Open task", in: expanded)
        XCTAssertEqual(selected, task.index)
        XCTAssertNil(sidebar.taskPreview.card)

        sidebar.onOpenTaskThread = { opened.append($0) }
        try moveOverRow()
        try press("Open task thread", in: card())
        sidebar.isExpanded = false
        sidebar.frame.size.width = SidebarView.foldedWidth
        host.layoutSubtreeIfNeeded()
        let icon = try XCTUnwrap(sidebar.iconRail.itemViews[task.id])
        icon.mouseEntered(with: NSEvent())
        let rail = try card()
        XCTAssertLessThan(rail.frame.minX, expanded.frame.minX)
        try press("Open task thread", in: rail)
        XCTAssertEqual(opened, [task.id, task.id])

        icon.mouseExited(with: NSEvent())
        icon.mouseEntered(with: NSEvent())
        let refreshed = try card()
        sidebar.update(profiles: [], workspaces: [row(task.id, index: task.index)])
        let visible = refreshed.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
        XCTAssertEqual(visible.map(\.stringValue), ["Fix Login", "Active"])
        XCTAssertLessThan(refreshed.frame.height, rail.frame.height)
        sidebar.update(profiles: [], workspaces: [row("replacement", index: task.index)])
        XCTAssertNil(sidebar.taskPreview.card)
        refreshed.onOpen?()
        XCTAssertEqual(opened.count, 2)
    }

}
