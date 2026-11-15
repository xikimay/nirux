import AppKit
import XCTest
@testable import Nirux

/// The window's toolbar holding the command bar (docs/design/
/// glass-interface.md, step 3.1). Windows are laid out, never shown.
@MainActor
final class CommandBarToolbarTests: XCTestCase {
    private func window() -> (NSWindow, CommandBarToolbar) {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1100, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let toolbar = CommandBarToolbar(bar: CommandBarView(level: .opaque))
        toolbar.install(in: window)
        return (window, toolbar)
    }

    /// An empty unified toolbar with the bar as its centred item, which asks
    /// macOS 26 for none of its own glass; the bar takes the strip's width
    /// within its bounds.
    func testTheBarIsTheToolbarsCentredItem() throws {
        let (window, toolbar) = window()
        defer { window.close() }
        XCTAssertTrue(window.toolbar === toolbar.toolbar)
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertEqual(toolbar.toolbar.centeredItemIdentifiers, [CommandBarToolbar.barItemID])
        let item = try XCTUnwrap(toolbar.toolbar.items.first { $0.itemIdentifier == CommandBarToolbar.barItemID })
        XCTAssertTrue(item.view === toolbar.bar)
        XCTAssertFalse(item.isBordered, "no bordered background behind the bar's own glass")
        if #available(macOS 26, *) { XCTAssertEqual(item.style, .plain) }
        XCTAssertEqual(toolbar.toolbar.items.map(\.itemIdentifier).filter { $0 != .flexibleSpace }, [CommandBarToolbar.barItemID], "nothing else")

        window.contentView?.superview?.layoutSubtreeIfNeeded()
        XCTAssertEqual(toolbar.bar.frame.width, CommandBarToolbar.maximumBarWidth, accuracy: 0.5, "a wide window: the widest bar")
        XCTAssertEqual(toolbar.bar.frame.height, CommandBarView.height)
        let bar = toolbar.bar.convert(toolbar.bar.bounds, to: nil)
        XCTAssertEqual(bar.midX, window.frame.width / 2, accuracy: 1, "centred")
        XCTAssertGreaterThan(window.frame.height - window.contentLayoutRect.height, 40, "a title bar tall enough for the bar")
    }

    /// The usage limits keep the window's edge, the cup on their left, both
    /// right of the bar.
    func testTheIndicatorsStayAtTheRightEnd() throws {
        let (window, toolbar) = window()
        defer { window.close() }
        let usage = ClaudeUsageIndicator()
        window.addTitlebarAccessoryViewController(usage)
        let now = Date().timeIntervalSince1970
        usage.update(limits: ClaudeUsageLimits(fiveHour: .init(usedPercentage: 42, resetsAt: now + 3600, reportedAt: now)), now: now)
        let cup = KeepAwakeIndicator()
        window.addTitlebarAccessoryViewController(cup)
        cup.update(isActive: true, workingAgentCount: 1)
        window.contentView?.superview?.layoutSubtreeIfNeeded()

        let bar = toolbar.bar.convert(toolbar.bar.bounds, to: nil)
        let limits = usage.view.convert(usage.view.bounds, to: nil)
        let cupFrame = cup.view.convert(cup.view.bounds, to: nil)
        XCTAssertTrue([limits, cupFrame].allSatisfy { $0.width > 0 })
        XCTAssertEqual(cupFrame.maxX, limits.minX, accuracy: 0.5)
        XCTAssertGreaterThan(limits.maxX, window.frame.width - 40, "at the window's edge")
        XCTAssertLessThanOrEqual(bar.maxX, cupFrame.minX)
    }
}
