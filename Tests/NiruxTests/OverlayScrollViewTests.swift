import AppKit
import XCTest
@testable import Nirux

/// The sidebar and the Board are laid out at their full width: their
/// scrollers overlay it whatever scroller style the Mac prefers. Nothing is
/// put on screen.
@MainActor
final class OverlayScrollViewTests: XCTestCase {
    /// AppKit's own switch of every live scroll view, as it runs when the
    /// preferred style changes (on a Mac with a mouse, a moment after
    /// launch). Posting the notification by hand doesn't reach them.
    private func appKitSwitchesLiveScrollViews(to style: NSScroller.Style) throws {
        let pairs: AnyClass = try XCTUnwrap(NSClassFromString("NSScrollerImpPair"), "AppKit's scroller pairs")
        let selector = NSSelectorFromString("_updateAllScrollerImpPairsForNewRecommendedScrollerStyle:")
        let method = try XCTUnwrap(class_getClassMethod(pairs, selector), "AppKit's switch of every live scroll view")
        typealias Switch = @convention(c) (AnyClass, Selector, Int) -> Void
        unsafeBitCast(method_getImplementation(method), to: Switch.self)(pairs, selector, style.rawValue)
    }

    func testTheSidebarAndTheBoardKeepTheirWidthWhenAppKitTurnsScrollersLegacy() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1460, height: 300), styleMask: [.borderless], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1460, height: 300))
        window.contentView = container

        // Both longer than they are tall: a legacy scroller would show.
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 300))
        container.addSubview(sidebar)
        sidebar.isExpanded = true
        sidebar.update(profiles: [], workspaces: (0..<30).map { index in
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
        let board = BoardStagesView(frame: NSRect(x: 260, y: 0, width: 940, height: 300))
        container.addSubview(board)
        let lines = (0..<20).map { index in
            BoardStages.Line(
                id: "task\(index)", title: "Task \(index)", station: .checks, state: .waiting,
                rail: BoardStages.Rail(marks: [.done, .done, .current, .ahead]),
                phrase: BoardStages.Phrase(text: "Checks running", detail: nil), pullRequest: "#\(index)", since: nil
            )
        }
        board.show(BoardStagesView.Content(
            header: BoardStagesView.Header(name: "nirux-public", color: Theme.Color.accent, summary: "20 tasks", lead: nil),
            order: .sidebar,
            sections: [BoardStagesView.Section(
                id: "nirux", title: "nirux", detail: nil, status: nil,
                lines: BoardStages.Section(id: "nirux", units: lines.map { .task($0, subtasks: []) }, withoutTask: [], merged: [])
            )],
            now: 1_794_405_600
        ))
        // The proof that the switch below is AppKit's: it reaches a plain one.
        let plain = NSScrollView(frame: NSRect(x: 1200, y: 0, width: 260, height: 300))
        plain.hasVerticalScroller = true
        plain.autohidesScrollers = true
        plain.scrollerStyle = .overlay
        plain.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 900))
        container.addSubview(plain)
        container.layoutSubtreeIfNeeded()

        let scrollViews = [("the sidebar", sidebar.contentScrollView), ("the Board", board.scrollView), ("a plain one", plain)]
        for (name, scroll) in scrollViews {
            let document = try XCTUnwrap(scroll.documentView, name)
            XCTAssertGreaterThan(document.frame.height, scroll.contentView.frame.height, "\(name) is longer than it is tall")
            XCTAssertEqual(scroll.contentView.frame.width, scroll.frame.width, "\(name) starts whole")
        }

        try appKitSwitchesLiveScrollViews(to: .legacy)
        defer { try? appKitSwitchesLiveScrollViews(to: NSScroller.preferredScrollerStyle) }
        container.layoutSubtreeIfNeeded()

        XCTAssertEqual(plain.scrollerStyle, .legacy, "AppKit's switch reaches a plain scroll view")
        XCTAssertLessThan(plain.contentView.frame.width, plain.frame.width, "and its scroller takes width")
        for (name, scroll) in scrollViews.dropLast() {
            XCTAssertEqual(scroll.scrollerStyle, .overlay, "\(name)'s scroller stays overlay")
            XCTAssertEqual(scroll.contentView.frame.width, scroll.frame.width, "\(name) keeps its whole width")
        }
    }
}
