import AppKit
import XCTest
@testable import Nirux

/// Clicks on the Board's column in a window that is never shown: CI drops
/// events sent with `sendEvent`, so what is under the pointer is hit-tested
/// by hand, as AppKit finds it for a real click, then pressed as AppKit
/// would press it.
@MainActor
enum BoardStagesClicks {
    /// The button must be what the window hit-tests under its middle; then
    /// `performClick`, since a button's own tracking never ends in a window
    /// that isn't shown.
    static func click(_ button: NSButton, file: StaticString = #filePath, line: UInt = #line) throws {
        layOut(button)
        let hit = try hitView(over: button, at: NSPoint(x: button.bounds.midX, y: button.bounds.midY))
        XCTAssertTrue(hit === button, "\(hit) is under the pointer, not \(button.title)", file: file, line: line)
        XCTAssertTrue(button.isEnabled, "\(button.title) is disabled", file: file, line: line)
        (hit as? NSButton)?.performClick(nil)
    }

    /// Presses and releases the mouse on `view` at `point` (its own
    /// coordinates), which must be on `view` as the window hit-tests it.
    static func press(_ view: NSView, at point: NSPoint, file: StaticString = #filePath, line: UInt = #line) throws {
        let hit = try hitView(over: view, at: point)
        XCTAssertTrue(hit === view || hit.isDescendant(of: view), "\(hit) is under the pointer, not \(view)", file: file, line: line)
        let location = view.convert(point, to: nil)
        view.mouseDown(with: try mouse(.leftMouseDown, at: location, in: view.window))
        view.mouseUp(with: try mouse(.leftMouseUp, at: location, in: view.window))
    }

    /// Lays the window out, as AppKit does before a real click lands: a
    /// window that is never shown gets no layout pass of its own, and what
    /// a view placed or hid in `layout()` waits for one.
    static func layOut(_ view: NSView) {
        view.window?.contentView?.layoutSubtreeIfNeeded()
    }

    /// A click on a line's title: it opens its task.
    static func open(_ line: BoardStagesLineView, file: StaticString = #filePath, line number: UInt = #line) throws {
        layOut(line)
        try press(line, at: NSPoint(x: line.titleLabel.frame.minX + 4, y: line.bounds.midY), file: file, line: number)
    }

    /// A click on a line's Merge station.
    static func pressMerge(_ line: BoardStagesLineView, file: StaticString = #filePath, line number: UInt = #line) throws {
        layOut(line)
        let merge = try XCTUnwrap(BoardStagesView.Columns(width: line.bounds.width, height: line.bounds.height).stations.last)
        try press(line, at: NSPoint(x: merge, y: line.bounds.midY), file: file, line: number)
    }

    /// A click on the link ending a line's phrase.
    static func pressLink(_ line: BoardStagesLineView, file: StaticString = #filePath, line number: UInt = #line) throws {
        layOut(line)
        XCTAssertFalse(line.linkLabel.isHidden, "no link on \(line.line.title)", file: file, line: number)
        try press(line, at: NSPoint(x: line.linkLabel.frame.midX, y: line.bounds.midY), file: file, line: number)
    }

    /// A click on a "Merged today" entry's "Clean up".
    static func pressCleanUp(_ entry: BoardStagesMergedEntryView, file: StaticString = #filePath, line: UInt = #line) throws {
        layOut(entry)
        XCTAssertFalse(entry.linkLabel.isHidden, "no Clean up on \(entry.pullRequest.title)", file: file, line: line)
        let point = NSPoint(x: entry.linkLabel.frame.midX, y: entry.bounds.midY)
        XCTAssertEqual(entry.target(at: point), .cleanUp, file: file, line: line)
        try press(entry, at: point, file: file, line: line)
    }

    /// Chooses `title` in `menu`: there, and enabled.
    static func choose(_ title: String, in menu: NSMenu?, file: StaticString = #filePath, line: UInt = #line) throws {
        let menu = try XCTUnwrap(menu, "no menu", file: file, line: line)
        let index = menu.indexOfItem(withTitle: title)
        guard index >= 0 else { return XCTFail("no “\(title)” in \(menu.items.map(\.title))", file: file, line: line) }
        XCTAssertTrue(menu.items[index].isEnabled, "“\(title)” is disabled: \(menu.items[index].toolTip ?? "")", file: file, line: line)
        menu.performActionForItem(at: index)
    }

    /// The line titled `title` on the Board.
    static func line(_ title: String, in board: ProjectBoardController, file: StaticString = #filePath, line: UInt = #line) throws
        -> BoardStagesLineView {
        board.view.stages.layoutSubtreeIfNeeded()
        return try XCTUnwrap(
            board.view.stages.lineViews.first { $0.line.title == title }, "no line “\(title)”: \(board.view.stages.lineViews.map(\.line.title))",
            file: file, line: line
        )
    }

    /// The line titled `title`, if the Board shows one: for a wait, which
    /// mustn't fail while it waits (`XCTUnwrap` records its failure).
    static func shownLine(_ title: String, in board: ProjectBoardController) -> BoardStagesLineView? {
        board.view.stages.lineViews.first { $0.line.title == title }
    }

    /// The section titled `title`, if the Board shows one: for a wait.
    static func shownSection(_ title: String, in board: ProjectBoardController) -> BoardStagesView.Section? {
        board.view.stages.content?.sections.first { $0.title == title }
    }

    /// The Board's section of this title (its repository's, "No repository").
    static func section(_ title: String, in board: ProjectBoardController, file: StaticString = #filePath, line: UInt = #line) throws
        -> BoardStagesView.Section {
        let sections = board.view.stages.content?.sections ?? []
        return try XCTUnwrap(sections.first { $0.title == title }, "no section “\(title)”: \(sections.map(\.title))", file: file, line: line)
    }

    /// The space the ⋯ menu's Space submenu checks.
    static func checkedSpace(_ board: ProjectBoardController) -> String? {
        let checked = board.view.spaceMenu().items.filter { $0.state == .on }
        return checked.count == 1 ? checked[0].title : nil
    }

    /// Refresh's tooltip says when the Board last read GitHub.
    static func wasUpdated(_ board: ProjectBoardController) -> Bool {
        board.view.refreshButton.toolTip?.hasPrefix("Refresh · Updated ") == true
    }

    private static func hitView(over view: NSView, at point: NSPoint) throws -> NSView {
        let window = try XCTUnwrap(view.window, "\(view) is in no window")
        let contentView = try XCTUnwrap(window.contentView)
        contentView.layoutSubtreeIfNeeded()
        let frameView = try XCTUnwrap(contentView.superview)
        return try XCTUnwrap(frameView.hitTest(view.convert(point, to: nil)))
    }

    private static func mouse(_ type: NSEvent.EventType, at location: NSPoint, in window: NSWindow?) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }
}
