import AppKit
import XCTest
@testable import Nirux

/// The title bar's New, Board and Search (docs/spaces.md, Interface).
@MainActor
final class TitleBarActionsTests: XCTestCase {
    /// Three buttons in one capsule, each saying its name (to VoiceOver,
    /// which reads the cell) and its shortcut, each running its action.
    func testButtonsSayTheirNameAndRunTheirAction() throws {
        let actions = TitleBarActions()
        _ = actions.view
        var ran: [TitleBarActions.Action] = []
        actions.onAction = { ran.append($0) }

        let buttons = try TitleBarActions.Action.allCases.map { try XCTUnwrap(actions.buttons[$0]) }
        XCTAssertEqual(buttons.map { $0.cell?.accessibilityLabel() }, ["New…", "Board", "Search"])
        XCTAssertEqual(buttons.map(\.toolTip), ["New… (⌘N)", "Board (⌃⌘B)", "Search (⌘P, ⇧⌘P in the editor)"])
        XCTAssertTrue(buttons.allSatisfy { $0.superview === buttons[0].superview }, "one capsule")
        buttons.forEach { $0.performClick(nil) }
        XCTAssertEqual(ran, [.new, .board, .search])
    }

    /// Added first, it keeps the window's edge: the usage limits, then the
    /// cup, added after it as Nirux does, line up on its left. Laid out as
    /// KeepAwakeControllerTests lays out its title bar, never shown.
    func testItKeepsTheWindowsEdge() throws {
        let (window, actions) = titleBar()
        defer { window.close() }
        let usage = ClaudeUsageIndicator()
        window.addTitlebarAccessoryViewController(usage)
        let now = Date().timeIntervalSince1970
        usage.update(limits: ClaudeUsageLimits(fiveHour: .init(usedPercentage: 42, resetsAt: now + 3600, reportedAt: now)), now: now)
        let cup = KeepAwakeIndicator()
        window.addTitlebarAccessoryViewController(cup)
        cup.update(isActive: true, workingAgentCount: 1)

        let capsule = Self.frameInWindow(actions.view, of: window)
        let limits = Self.frameInWindow(usage.view, of: window)
        let cupFrame = Self.frameInWindow(cup.view, of: window)
        XCTAssertTrue([capsule, limits, cupFrame].allSatisfy { $0.width > 0 })
        XCTAssertEqual(limits.maxX, capsule.minX, accuracy: 0.5)
        XCTAssertEqual(cupFrame.maxX, limits.minX, accuracy: 0.5)
    }

    /// Search pressed while the palette shows closes it: the palette takes
    /// that press on mouse-down, so the button doesn't open it again on
    /// mouse-up. Pressed again, it opens it. New opens its sheet.
    func testSearchClosesAnOpenPaletteAndTheButtonsReachTheShell() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let actions = TitleBarActions()
            harness.window.addTitlebarAccessoryViewController(actions)
            let search = try XCTUnwrap(actions.buttons[.search])
            let board = try XCTUnwrap(actions.buttons[.board])
            @MainActor func press(_ button: NSButton, _ type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
                let point = Self.frameInWindow(button, of: harness.window)
                return try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: point.midX, y: point.midY), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: harness.window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                ))
            }
            XCTAssertTrue(CommandPalette.isSearchButtonPress(try press(search)))
            XCTAssertFalse(CommandPalette.isSearchButtonPress(try press(board)))

            shell.performTitleBarAction(.search)
            XCTAssertEqual(shell.commandPalette?.isVisible, true)
            // The release queued first: a button that took the press would
            // end its tracking on it (and open the palette again) instead
            // of waiting forever.
            NSApp.postEvent(try press(search, .leftMouseUp), atStart: false)
            NSApp.sendEvent(try press(search))
            while let queued = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(queued)
            }
            XCTAssertEqual(shell.commandPalette?.isVisible, false)
            shell.performTitleBarAction(.search)
            XCTAssertEqual(shell.commandPalette?.isVisible, true)
            shell.commandPalette?.dismiss()

            shell.performTitleBarAction(.new)
            harness.waitUntil("the New sheet") { shell.newTaskPanel?.panel?.isSheet == true }
        }
    }

    private func titleBar() -> (NSWindow, TitleBarActions) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let actions = TitleBarActions()
        window.addTitlebarAccessoryViewController(actions)
        return (window, actions)
    }

    private static func frameInWindow(_ view: NSView, of window: NSWindow) -> NSRect {
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        return view.convert(view.bounds, to: nil)
    }
}
