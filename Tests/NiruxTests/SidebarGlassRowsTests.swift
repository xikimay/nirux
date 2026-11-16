import AppKit
import XCTest
@testable import Nirux

/// The rows on glass (docs/design/glass-interface.md, step 3.4): the state
/// icons in the rows, the selected row's pane of glass, the rows' buttons in
/// `NiruxButton`'s looks, and the unfolded sidebar's foot.
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

    /// Checks that run: the family's ring, at the icons' size.
    func testRunningChecksRingIsTheIconsSize() throws {
        let running = row([column()], pullRequest: pullRequest(ci: "PENDING"))
        let ring = try XCTUnwrap(views(running).first { $0.identifier == SidebarWorkspaceCardRenderer.checksRingID })
        XCTAssertEqual(ring.frame.size, NSSize(width: SidebarExpandedMetrics.stateIconSize, height: SidebarExpandedMetrics.stateIconSize))
        XCTAssertEqual(ring.frame.midX, SidebarExpandedMetrics.markCenterX, accuracy: 0.5)
        XCTAssertTrue(icons(in: views(running)).isEmpty, "the ring alone")
    }

    /// The catch-up card's rows show their rows' icons; a turn over, the
    /// grey check.
    func testTheCatchUpCardShowsTheRowsIcons() {
        let asks = SidebarCatchUp.row(for: row([column(.needsAttention, reason: .permission(tool: "Bash", summary: "npm test"))]))
        XCTAssertEqual(asks.kind, .asks)
        XCTAssertEqual(asks.shownIcon, StateIcon(.needsYou(.command)))
        XCTAssertEqual(SidebarCatchUp.row(for: row([column(.working)])).shownIcon, StateIcon(.working))
        XCTAssertEqual(SidebarCatchUp.row(for: row([column(.needsAttention, reason: .turnFinished)])).shownIcon, StateIcon(.finished))
        XCTAssertEqual(SidebarCatchUp.row(for: row([column()], blocker: "the staging key")).shownIcon, StateIcon(.blocked))
        let broke = SidebarCatchUp.row(for: row([column()], pullRequest: pullRequest(ci: "FAILURE")))
        XCTAssertEqual(broke.shownIcon, StateIcon(.error))
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
        XCTAssertEqual(light.backgroundColor, Theme.Color.selectionHighlight.cgColor)
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

    // MARK: - The foot

    private func windowed(_ rows: [WorkspaceInfo], height: CGFloat = 600) -> (SidebarView, NSWindow) {
        _ = NSApplication.shared
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: height))
        let window = NSWindow(contentRect: sidebar.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.isExpanded = true
        sidebar.update(profiles: [], workspaces: rows)
        sidebar.layoutSubtreeIfNeeded()
        return (sidebar, window)
    }

    /// Unfolded, the foot sits at the bottom, the list above it; Board and
    /// History open theirs, Tasks shows as the current list. Folded, the
    /// rail has the whole height.
    func testTheFootSitsUnderTheList() {
        let (sidebar, window) = windowed([row([column()])])
        defer { window.close() }
        let footer = sidebar.footer
        XCTAssertFalse(footer.isHidden)
        XCTAssertEqual(footer.frame, NSRect(x: 10, y: 10, width: 240, height: SidebarFooterView.height))
        XCTAssertEqual(sidebar.contentScrollView.frame, NSRect(x: 0, y: SidebarFooterView.room, width: 260, height: 600 - SidebarFooterView.room))
        XCTAssertEqual(footer.tasksPill.layer?.backgroundColor, Theme.Color.selectionGlass.cgColor, "the current list")

        var board = 0
        var history = 0
        sidebar.onOpenBoard = { board += 1 }
        sidebar.onShowHistory = { history += 1 }
        footer.boardButton.performClick(nil)
        XCTAssertEqual([board, history], [1, 0])
        footer.historyButton.performClick(nil)
        XCTAssertEqual([board, history], [1, 1])

        sidebar.isExpanded = false
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertTrue(footer.isHidden)
        XCTAssertTrue(sidebar.backdrop.isHidden)
        XCTAssertEqual(sidebar.contentScrollView.frame, sidebar.bounds)
    }

    /// A row scrolled under the foot takes no press, no hover and no menu
    /// there: the foot is not the list.
    func testTheFootHidesTheRowsUnderIt() throws {
        let (sidebar, window) = windowed((0..<20).map { row([column()], id: "ws\($0)", index: $0) }, height: 300)
        defer { window.close() }
        var clicked: [Int] = []
        sidebar.onWorkspaceClicked = { clicked.append($0) }
        XCTAssertGreaterThan(sidebar.contentDocumentView.frame.height, 300, "a long list")
        // In the foot's margin, under the capsule's left end.
        let inFoot = sidebar.convert(NSPoint(x: 30, y: 4), to: nil)
        let hidden = sidebar.contentDocumentView.convert(inFoot, from: nil)
        XCTAssertNotNil(sidebar.cardIndex(at: hidden), "a row lies there, out of view")
        func event(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
            ))
        }
        XCTAssertNil(sidebar.menu(for: try event(.rightMouseDown, at: inFoot)), "no row's menu")
        sidebar.mouseMoved(with: try event(.mouseMoved, at: inFoot))
        XCTAssertNil(sidebar.hoveredTarget, "no row lit")
        sidebar.mouseDown(with: try event(.leftMouseDown, at: inFoot))
        XCTAssertEqual(clicked, [], "no row pressed")
        // A row's click, then a second one in the foot: no double-click
        // renames that row.
        var actions: [Int] = []
        sidebar.onWorkspaceAction = { _, index in actions.append(index) }
        sidebar.lastRowPress = (0, ProcessInfo.processInfo.systemUptime)
        sidebar.mouseDown(with: try event(.leftMouseDown, at: inFoot, clicks: 2))
        XCTAssertEqual(actions, [], "no rename")

        // A scroll over the foot goes to the list's scroll view (a made-up
        // scroll moves no list off screen: it is seen arriving there).
        var scrolled = 0
        let noted = sidebar.contentScrollView.onScrollWheel
        sidebar.contentScrollView.onScrollWheel = { scrolled += 1; noted?() }
        let scroll = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0
        ).flatMap { NSEvent(cgEvent: $0) })
        sidebar.scrollWheel(with: scroll)
        XCTAssertEqual(scrolled, 1, "the list's scroll view has it")

        // A row in view still answers.
        let visible = sidebar.contentScrollView.documentVisibleRect
        let inView = try XCTUnwrap(sidebar.hitAreas.first { area in
            if case .workspace = area.region { visible.contains(area.frame) } else { false }
        })
        let onRow = sidebar.contentDocumentView.convert(NSPoint(x: inView.frame.midX, y: inView.frame.midY), to: nil)
        XCTAssertNotNil(sidebar.menu(for: try event(.rightMouseDown, at: onRow)), "a row in view has its menu")
    }
}
