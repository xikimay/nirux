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
        XCTAssertEqual(buttons.map(\.toolTip), ["New… (⌘N)", "Board (⌃⌘B)", "Search (⌘P, ⇧⌘P in the editor)"])
        XCTAssertTrue(buttons.allSatisfy { $0.acceptsFirstMouse(for: nil) }, "Nirux in the background")
        XCTAssertEqual(buttons.map(\.frame.minX), buttons.map(\.frame.minX).sorted())
        XCTAssertTrue(buttons.allSatisfy { $0.superview === buttons[0].superview }, "one capsule")
        buttons.forEach { $0.performClick(nil) }
        XCTAssertEqual(ran, [.new, .board, .search])
    }

    /// Added first, it keeps the window's edge: the usage limits, then the
    /// cup, added after it as Nirux does, line up on its left. Laid out as
    /// KeepAwakeControllerTests lays out its title bar, never shown.
    func testItKeepsTheWindowsEdge() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let actions = TitleBarActions()
        window.addTitlebarAccessoryViewController(actions)
        let usage = ClaudeUsageIndicator()
        window.addTitlebarAccessoryViewController(usage)
        let now = Date().timeIntervalSince1970
        usage.update(limits: ClaudeUsageLimits(fiveHour: .init(usedPercentage: 42, resetsAt: now + 3600, reportedAt: now)), now: now)
        let cup = KeepAwakeIndicator()
        window.addTitlebarAccessoryViewController(cup)
        cup.update(isActive: true, workingAgentCount: 1)
        func frameInWindow(_ view: NSView) -> NSRect {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            return view.convert(view.bounds, to: nil)
        }

        let capsule = frameInWindow(actions.view)
        let limits = frameInWindow(usage.view)
        let cupFrame = frameInWindow(cup.view)
        XCTAssertTrue([capsule, limits, cupFrame].allSatisfy { $0.width > 0 })
        XCTAssertEqual(limits.maxX, capsule.minX, accuracy: 0.5)
        XCTAssertEqual(cupFrame.maxX, limits.minX, accuracy: 0.5)
    }

    /// Search pressed to close the palette: the click closed it on
    /// mouse-down, and the button, on mouse-up, doesn't open it again. A
    /// later press opens it.
    func testSearchClosesAnOpenPalette() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.showCommandPalette()
            XCTAssertEqual(shell.commandPalette?.isVisible, true)
            // A press outside the palette, in a window where it hits nothing.
            let elsewhere = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            elsewhere.isReleasedWhenClosed = false
            defer { elsewhere.close() }
            let press = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: NSPoint(x: 50, y: 50), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: elsewhere.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            NSApp.sendEvent(press)
            XCTAssertEqual(shell.commandPalette?.isVisible, false, "the click outside closed it")

            shell.toggleCommandPaletteFromTitleBar(now: press.timestamp + 0.2)
            XCTAssertEqual(shell.commandPalette?.isVisible, false)
            shell.toggleCommandPaletteFromTitleBar(now: press.timestamp + 5)
            XCTAssertEqual(shell.commandPalette?.isVisible, true)
            shell.commandPalette?.dismiss()
        }
    }
}
