import AppKit
import XCTest
@testable import Nirux

/// The window's toolbar holding the command bar (docs/design/
/// glass-interface.md, step 3.1). Windows are laid out, never shown.
@MainActor
final class CommandBarToolbarTests: XCTestCase {
    /// Nirux's main window, `width` wide, with the toolbar; the test closes
    /// it.
    private func window(width: CGFloat = 1100, indicators: Bool = false) -> (NSWindow, CommandBarToolbar, cup: KeepAwakeIndicator?) {
        let window = NiruxApp.makeMainWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 400))
        window.isReleasedWhenClosed = false
        let toolbar = CommandBarToolbar(bar: CommandBarView(level: .opaque))
        toolbar.bar.show(CommandBarView.Content(
            spaceName: "Acme", spaceColor: Theme.Color.working, taskTitle: "Fix checkout rounding",
            taskIcon: StateIcon(.working), taskDetail: "Working 12m", waitingCount: 2
        ))
        toolbar.install(in: window)
        var cup: KeepAwakeIndicator?
        if indicators {
            let usage = ClaudeUsageIndicator()
            window.addTitlebarAccessoryViewController(usage)
            let now = Date().timeIntervalSince1970
            usage.update(limits: ClaudeUsageLimits(fiveHour: .init(usedPercentage: 42, resetsAt: now + 3600, reportedAt: now)), now: now)
            let indicator = KeepAwakeIndicator()
            window.addTitlebarAccessoryViewController(indicator)
            indicator.update(isActive: true, workingAgentCount: 1)
            cup = indicator
        }
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        return (window, toolbar, cup)
    }

    /// An empty unified toolbar with the bar as its centred item, which asks
    /// macOS 26 for none of its own glass; the bar takes the strip's width
    /// within its bounds.
    func testTheBarIsTheToolbarsCentredItem() throws {
        let (window, toolbar, _) = window()
        defer { window.close() }
        XCTAssertTrue(window.toolbar === toolbar.toolbar)
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertEqual(toolbar.toolbar.centeredItemIdentifiers, [CommandBarToolbar.barItemID])
        let item = try XCTUnwrap(toolbar.toolbar.items.first { $0.itemIdentifier == CommandBarToolbar.barItemID })
        XCTAssertTrue(item.view === toolbar.bar)
        XCTAssertFalse(item.isBordered, "no bordered background behind the bar's own glass")
        if #available(macOS 26, *) { XCTAssertEqual(item.style, .plain) }
        XCTAssertEqual(toolbar.toolbar.items.map(\.itemIdentifier), [CommandBarToolbar.barItemID], "nothing else")
        toolbar.toolbar.displayMode = .labelOnly
        XCTAssertEqual(toolbar.toolbar.displayMode, .iconOnly, "never a text item in the bar's place")
        XCTAssertEqual(toolbar.bar.frame.width, CommandBarToolbar.maximumBarWidth, accuracy: 0.5, "a wide window: the widest bar")
        XCTAssertEqual(toolbar.bar.frame.height, CommandBarView.height)
        let bar = toolbar.bar.convert(toolbar.bar.bounds, to: nil)
        XCTAssertEqual(bar.midX, window.frame.width / 2, accuracy: 1, "centred")
        XCTAssertGreaterThan(window.frame.height - window.contentLayoutRect.height, 40, "a title bar tall enough for the bar")
    }

    /// The usage limits keep the window's edge, the cup on their left, and
    /// the bar stays in the window at every width down to the minimum, left
    /// of them: never sent to the toolbar's » menu.
    func testTheBarStaysInNarrowWindowsLeftOfTheIndicators() throws {
        for width: CGFloat in [1100, 760, 600] {
            let (window, toolbar, cup) = window(width: width, indicators: true)
            defer { window.close() }
            let cupView = try XCTUnwrap(cup?.view)
            let limits = try XCTUnwrap(window.titlebarAccessoryViewControllers.first { $0 is ClaudeUsageIndicator }?.view)
            XCTAssertTrue(toolbar.bar.window === window, "in the window at \(width) pt")
            XCTAssertTrue(toolbar.toolbar.visibleItems?.contains { $0.itemIdentifier == CommandBarToolbar.barItemID } == true,
                          "not in the » menu at \(width) pt")
            let bar = toolbar.bar.convert(toolbar.bar.bounds, to: nil)
            let cupFrame = cupView.convert(cupView.bounds, to: nil)
            let limitsFrame = limits.convert(limits.bounds, to: nil)
            XCTAssertGreaterThanOrEqual(bar.width, CommandBarToolbar.minimumBarWidth, "at \(width) pt")
            XCTAssertLessThanOrEqual(bar.maxX, cupFrame.minX, "left of the cup at \(width) pt")
            XCTAssertEqual(cupFrame.maxX, limitsFrame.minX, accuracy: 0.5)
            XCTAssertGreaterThan(limitsFrame.maxX, width - 40, "the limits at the window's edge")
        }
    }
}
