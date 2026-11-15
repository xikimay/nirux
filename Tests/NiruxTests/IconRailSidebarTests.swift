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
        columns: [ColumnInfo] = [], notification: AttentionSignal? = nil
    ) -> WorkspaceInfo {
        var info = WorkspaceInfo(
            id: id, index: index, title: id.capitalized, profileID: WorkspaceProfile.defaultID, isInactive: archived,
            columnCount: max(1, columns.count), focusedColumn: 0, gitBranch: "feat/\(id)", notification: notification,
            isActive: active, columns: columns, prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil,
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
        shell.relayout(animated: false)
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
}
