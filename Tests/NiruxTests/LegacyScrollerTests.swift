import AppKit
import XCTest
@testable import Nirux

/// With legacy scrollers (the Mac's "Show scroll bars: Always", or a mouse)
/// the sidebar's rows and the Board's lines take the width the scroller
/// leaves, as in Finder's sidebar; with overlay ones, the whole width. The
/// style is set as AppKit sets it on a live scroll view when the preferred
/// one changes: through its setter. No test spins the run loop, so AppKit's
/// own switch (on CI, a moment into the process) can't land mid-test.
/// Nothing is put on screen.
@MainActor
final class LegacyScrollerTests: XCTestCase {
    /// Never shown; kept for as long as the test runs.
    private var windows: [NSWindow] = []

    private func show(_ view: NSView) {
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        windows.append(window)
    }

    private func rows(_ count: Int) -> [WorkspaceInfo] {
        (0..<count).map { index in
            WorkspaceInfo(
                id: "ws\(index)", index: index, title: "task \(index)", profileID: WorkspaceProfile.defaultID,
                isInactive: false, columnCount: 1, focusedColumn: 0, gitBranch: "feat/\(index)", notification: nil,
                isActive: index == 0, columns: [ColumnInfo(
                    index: 0, processName: "claude", abbreviatedCwd: nil, isFocused: false, isWebView: false, webTitle: nil,
                    terminalTitle: nil, agentStatus: .idle, isEditor: false, editorFileName: nil, attentionReason: nil
                )],
                prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .active,
                lastSummary: nil, lastActivityAt: nil
            )
        }
    }

    /// `width`: the rail's or the list's, as `expanded` says, unless given.
    private func sidebar(rows count: Int, style: NSScroller.Style, expanded: Bool = true, width: CGFloat? = nil) -> SidebarView {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: width ?? (expanded ? 260 : SidebarRailMetrics.width), height: 300))
        show(sidebar)
        sidebar.contentScrollView.scrollerStyle = style
        sidebar.isExpanded = expanded
        sidebar.update(profiles: [], workspaces: rows(count))
        sidebar.catchUp = SidebarCatchUp(
            since: "since 12:40",
            rows: [SidebarCatchUp.Row(workspaceID: "ws1", title: "task 1", kind: .done, text: "Done")],
            otherSpaces: []
        )
        sidebar.refreshCatchUpCard(reveal: false)
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    /// Where the rows end and where the card's × ends, as built.
    private func rightEdges(_ sidebar: SidebarView) throws -> (rows: CGFloat, dismiss: CGFloat) {
        let rows = sidebar.hitAreas.filter { area in
            guard case .workspace = area.region else { return false }
            return true
        }
        let dismiss = try XCTUnwrap(sidebar.hitAreas.first { area in
            guard case .catchUp(.dismiss) = area.region else { return false }
            return true
        }, "the card's ×")
        return (try XCTUnwrap(rows.map(\.frame.maxX).max(), "the rows"), dismiss.frame.maxX)
    }

    func testTheSidebarsRowsSitBesideALegacyScroller() throws {
        // As on a Mac set to show scroll bars always, from the start.
        let sidebar = sidebar(rows: 30, style: .legacy)
        let scroll = sidebar.contentScrollView
        let beside = scroll.contentView.frame.width
        XCTAssertLessThan(beside, 260, "a list taller than the sidebar shows a legacy scroller, which takes width")
        XCTAssertEqual(sidebar.contentDocumentView.frame.width, beside, "the list is as wide as the clip")
        let legacy = try rightEdges(sidebar)
        XCTAssertLessThanOrEqual(legacy.dismiss, beside, "the card's × is beside the scroller, not under it")

        // AppKit turns it overlay (a trackpad, the setting changed).
        scroll.scrollerStyle = .overlay
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.frame.width, 260, "an overlay scroller takes no width")
        XCTAssertEqual(sidebar.contentDocumentView.frame.width, 260, "the list takes the whole width")
        let overlay = try rightEdges(sidebar)
        XCTAssertEqual(overlay.rows, legacy.rows + 260 - beside, "the rows end as far from the right edge")
        XCTAssertEqual(overlay.dismiss, legacy.dismiss + 260 - beside, "and the card's × too")

        // And legacy again, on rows already laid out (a mouse plugged in).
        scroll.scrollerStyle = .legacy
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertEqual(sidebar.contentDocumentView.frame.width, beside, "the list is as wide as the clip again")
        XCTAssertEqual(try rightEdges(sidebar).rows, legacy.rows, "the rows end beside the scroller")
    }

    func testASidebarListShorterThanTheSidebarKeepsTheWholeWidth() throws {
        // No scroller shows: the rows don't make room for one.
        let sidebar = sidebar(rows: 2, style: .legacy)
        XCTAssertEqual(sidebar.contentScrollView.contentView.frame.width, 260, "no scroller")
        XCTAssertEqual(sidebar.contentDocumentView.frame.width, 260, "the list takes the whole width")
    }

    func testRowsThatMakeTheListOverflowComeBesideTheScrollerAtOnce() throws {
        let sidebar = sidebar(rows: 2, style: .legacy)
        XCTAssertEqual(sidebar.contentDocumentView.frame.width, 260, "two rows fit whole")
        // No layout pass after: the rows never show under the scroller.
        sidebar.update(profiles: [], workspaces: rows(30))
        let beside = sidebar.contentScrollView.contentView.frame.width
        XCTAssertLessThan(beside, 260, "thirty rows show a legacy scroller")
        XCTAssertEqual(sidebar.contentDocumentView.frame.width, beside, "and come beside it")
        sidebar.update(profiles: [], workspaces: rows(2))
        XCTAssertEqual(sidebar.contentScrollView.contentView.frame.width, 260, "two again: no scroller")
        XCTAssertEqual(sidebar.contentDocumentView.frame.width, 260, "and the whole width")
    }

    func testOpeningAndClosingTheListUnderALegacyScrollerRebuildsItOnce() throws {
        // The rail, in a sidebar already as wide as the list.
        let sidebar = sidebar(rows: 30, style: .legacy, expanded: false, width: 260)
        XCTAssertFalse(sidebar.needsLayout)
        sidebar.isExpanded = true
        XCTAssertFalse(sidebar.needsLayout, "opened: no second rebuild waits for the next layout pass")
        let beside = sidebar.contentScrollView.contentView.frame.width
        XCTAssertLessThan(beside, 260, "the list shows a legacy scroller")
        XCTAssertEqual(sidebar.contentDocumentView.frame.width, beside, "and the rows come beside it")
        sidebar.isExpanded = false
        XCTAssertFalse(sidebar.needsLayout, "closed: none either")
        XCTAssertFalse(sidebar.contentScrollView.hasVerticalScroller, "the rail shows no legacy scroller")
    }

    func testTheRailShowsAnOverlayScrollerButNoLegacyOne() throws {
        // 52 pt: a legacy scroller would cover the tiles' right edge and
        // their badges.
        let rail = sidebar(rows: 30, style: .legacy, expanded: false)
        let scroll = rail.contentScrollView
        XCTAssertGreaterThan(rail.contentDocumentView.frame.height, 300, "the rail is longer than it is tall")
        XCTAssertFalse(scroll.hasVerticalScroller, "no legacy scroller")
        XCTAssertEqual(scroll.contentView.frame.width, SidebarRailMetrics.width, "nothing takes its width")
        // As AppKit sets it when the Mac's preferred style changes.
        scroll.scrollerStyle = .overlay
        XCTAssertTrue(scroll.hasVerticalScroller, "an overlay one tells how far the rail goes")
        XCTAssertEqual(scroll.contentView.frame.width, SidebarRailMetrics.width, "and takes no width")
        scroll.scrollerStyle = .legacy
        XCTAssertFalse(scroll.hasVerticalScroller, "legacy again: none")
    }

    func testADocumentIsLaidOutWholeWhenItFitsWhole() throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 300))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .legacy
        // A legacy scroller shows now, beside a taller document.
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 245, height: 900))
        scroll.tile()
        let beside = scroll.contentView.frame.width
        XCTAssertLessThan(beside, 260)
        func width(_ height: @escaping (CGFloat) -> CGFloat) -> (width: CGFloat, measures: Int) {
            var measures = 0
            let width = scroll.documentWidth(frameSize: scroll.frame.size) { width in
                measures += 1
                return (height(width), ())
            }.width
            return (width, measures)
        }
        XCTAssertEqual(width { _ in 100 }.width, 260, "a short document: whole")
        XCTAssertEqual(width { _ in 100 }.measures, 1, "measured once")
        XCTAssertEqual(width { $0 < 260 ? 310 : 290 }.width, 260, "one that overflows only beside the scroller: whole, without it")
        XCTAssertEqual(width { _ in 900 }.width, beside, "a tall one: beside the scroller")
        XCTAssertEqual(width { _ in 900 }.measures, 2, "measured whole, then beside it")
        scroll.scrollerStyle = .overlay
        XCTAssertEqual(width { _ in 900 }.width, 260, "an overlay scroller takes no width")
        XCTAssertEqual(width { _ in 900 }.measures, 1, "measured once")
    }

    private func board(style: NSScroller.Style, lines count: Int = 20) -> BoardStagesView {
        let board = BoardStagesView(frame: NSRect(x: 0, y: 0, width: 940, height: 300))
        show(board)
        board.scrollView.scrollerStyle = style
        board.show(content(lines: count))
        board.layoutSubtreeIfNeeded()
        return board
    }

    private func content(lines count: Int) -> BoardStagesView.Content {
        let lines = (0..<count).map { index in
            BoardStages.Line(
                id: "task\(index)", title: "Task \(index)", station: .checks, state: .waiting,
                rail: BoardStages.Rail(marks: [.done, .done, .current, .ahead]),
                phrase: BoardStages.Phrase(text: "Checks running", detail: nil), pullRequest: "#\(index)", since: nil
            )
        }
        return BoardStagesView.Content(
            header: BoardStagesView.Header(name: "nirux-public", color: Theme.Color.accent, summary: "\(count) tasks", lead: nil),
            order: .sidebar,
            sections: [BoardStagesView.Section(
                id: "nirux", title: "nirux", detail: nil, status: nil,
                lines: BoardStages.Section(id: "nirux", units: lines.map { .task($0, subtasks: []) }, withoutTask: [], merged: [])
            )],
            now: 1_794_405_600
        )
    }

    /// The list, each line and the "Pull request" title at `width`.
    private func assertBoard(_ board: BoardStagesView, at width: CGFloat, _ when: String, line: UInt = #line) throws {
        let document = try XCTUnwrap(board.scrollView.documentView)
        let lines = Set(document.subviews.compactMap { $0 as? BoardStagesLineView }.map(\.frame.width))
        XCTAssertEqual(document.frame.width, width, "\(when): the list", line: line)
        XCTAssertEqual(lines, [width], "\(when): each line", line: line)
        XCTAssertEqual(
            board.columnTitles[2].frame.minX, try XCTUnwrap(BoardStagesView.Columns(width: width).pullRequest).minX,
            "\(when): the titles keep over their columns", line: line
        )
    }

    func testTheBoardsLinesAndTitlesSitBesideALegacyScroller() throws {
        // As on a Mac set to show scroll bars always, from the start.
        let board = board(style: .legacy)
        let beside = board.scrollView.contentView.frame.width
        XCTAssertLessThan(beside, 940, "a list taller than the Board shows a legacy scroller, which takes width")
        try assertBoard(board, at: beside, "legacy")
    }

    func testLinesThatMakeTheBoardOverflowComeBesideTheScrollerAtOnce() throws {
        let board = board(style: .legacy, lines: 2)
        try assertBoard(board, at: 940, "two lines fit whole")
        // No layout pass after: the lines never show under the scroller.
        board.show(content(lines: 20))
        let beside = board.scrollView.contentView.frame.width
        XCTAssertLessThan(beside, 940, "twenty lines show a legacy scroller")
        try assertBoard(board, at: beside, "twenty lines")
    }

    func testTheBoardFollowsTheScrollerStyle() throws {
        let board = board(style: .overlay)
        try assertBoard(board, at: 940, "overlay")
        // As AppKit sets it on a Mac with a mouse.
        board.scrollView.scrollerStyle = .legacy
        board.layoutSubtreeIfNeeded()
        let beside = board.scrollView.contentView.frame.width
        XCTAssertLessThan(beside, 940, "a legacy scroller takes width")
        try assertBoard(board, at: beside, "switched to legacy")
        board.scrollView.scrollerStyle = .overlay
        board.layoutSubtreeIfNeeded()
        try assertBoard(board, at: 940, "overlay again")
    }
}
