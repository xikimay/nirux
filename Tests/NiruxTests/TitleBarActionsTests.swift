import AppKit
import XCTest
@testable import Nirux

/// The title bar's New, Board and Search (docs/spaces.md, Interface).
@MainActor
final class TitleBarActionsTests: XCTestCase {
    /// Three buttons in one capsule, in that order, each saying its name
    /// and shortcut, each running its action.
    func testButtonsSayTheirNameAndRunTheirAction() throws {
        let actions = TitleBarActions()
        _ = actions.view
        var ran: [TitleBarActions.Action] = []
        actions.onAction = { ran.append($0) }

        let buttons = try TitleBarActions.Action.allCases.map { try XCTUnwrap(actions.buttons[$0]) }
        XCTAssertEqual(buttons.map { $0.accessibilityLabel() }, ["New…", "Board", "Search"])
        XCTAssertEqual(buttons.map(\.toolTip), ["New… (⌘N)", "Board (⌃⌘B)", "Search (⌘P)"])
        XCTAssertEqual(buttons.map(\.frame.minX), buttons.map(\.frame.minX).sorted())
        XCTAssertTrue(buttons.allSatisfy { $0.superview === buttons[0].superview }, "one capsule")
        buttons.forEach { $0.performClick(nil) }
        XCTAssertEqual(ran, [.new, .board, .search])
    }

    /// Added first, it keeps the window's edge: the usage limits and the
    /// cup, added after it, line up on its left.
    func testItKeepsTheWindowsEdge() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let actions = TitleBarActions()
        window.addTitlebarAccessoryViewController(actions)
        let cup = KeepAwakeIndicator()
        window.addTitlebarAccessoryViewController(cup)
        cup.update(isActive: true, workingAgentCount: 1)
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.contentView?.superview?.layoutSubtreeIfNeeded()

        let frameView = try XCTUnwrap(window.contentView?.superview)
        let capsule = frameView.convert(actions.view.bounds, from: actions.view)
        let cupFrame = frameView.convert(cup.view.bounds, from: cup.view)
        XCTAssertGreaterThan(capsule.width, 0)
        XCTAssertGreaterThan(cupFrame.width, 0)
        XCTAssertEqual(capsule.maxX, frameView.bounds.maxX, accuracy: 1, "at the edge")
        XCTAssertLessThanOrEqual(cupFrame.maxX, capsule.minX + 0.5)
    }
}
