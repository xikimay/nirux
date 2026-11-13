import AppKit
import XCTest
@testable import Nirux

/// With legacy scrollers (the Mac's "Show scroll bars: Always", or a mouse)
/// the sidebar's rows and the Board's lines take the width the scroller
/// leaves, as in Finder's sidebar; with overlay ones, the whole width. The
/// style is set as AppKit sets it on a live scroll view when the preferred
/// one changes: through its setter. Nothing is put on screen.
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

    private func sidebar(rows count: Int, style: NSScroller.Style) -> SidebarView {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 300))
        show(sidebar)
        sidebar.contentScrollView.scrollerStyle = style
        sidebar.isExpanded = true
        sidebar.update(profiles: [], workspaces: (0..<count).map { index in
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
        })
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

    func testTheBoardsLinesAndTitlesSitBesideALegacyScroller() throws {
        let board = BoardStagesView(frame: NSRect(x: 0, y: 0, width: 940, height: 300))
        show(board)
        let lines = (0..<20).map { index in
            BoardStages.Line(
                id: "task\(index)", title: "Task \(index)", station: .checks, state: .waiting,
                rail: BoardStages.Rail(marks: [.done, .done, .current, .ahead]),
                phrase: BoardStages.Phrase(text: "Checks running", detail: nil), pullRequest: "#\(index)", since: nil
            )
        }
        board.scrollView.scrollerStyle = .overlay
        board.show(BoardStagesView.Content(
            header: BoardStagesView.Header(name: "nirux-public", color: Theme.Color.accent, summary: "20 tasks", lead: nil),
            order: .sidebar,
            sections: [BoardStagesView.Section(
                id: "nirux", title: "nirux", detail: nil, status: nil,
                lines: BoardStages.Section(id: "nirux", units: lines.map { .task($0, subtasks: []) }, withoutTask: [], merged: [])
            )],
            now: 1_794_405_600
        ))
        board.layoutSubtreeIfNeeded()
        let scroll = board.scrollView
        let document = try XCTUnwrap(scroll.documentView)
        func lineWidths() -> Set<CGFloat> {
            Set(document.subviews.compactMap { $0 as? BoardStagesLineView }.map(\.frame.width))
        }
        func pullRequestTitle() -> CGFloat { board.columnTitles[2].frame.minX }
        XCTAssertEqual(lineWidths(), [940], "overlay: the lines take the whole width")
        XCTAssertEqual(pullRequestTitle(), try XCTUnwrap(BoardStagesView.Columns(width: 940).pullRequest).minX)

        // As AppKit sets it on a Mac with a mouse.
        scroll.scrollerStyle = .legacy
        board.layoutSubtreeIfNeeded()
        let beside = scroll.contentView.frame.width
        XCTAssertLessThan(beside, 940, "a legacy scroller takes width")
        XCTAssertEqual(document.frame.width, beside, "the list is as wide as the clip")
        XCTAssertEqual(lineWidths(), [beside], "and so is each line")
        XCTAssertEqual(
            pullRequestTitle(), try XCTUnwrap(BoardStagesView.Columns(width: beside).pullRequest).minX,
            "the titles keep over their columns"
        )
    }
}
