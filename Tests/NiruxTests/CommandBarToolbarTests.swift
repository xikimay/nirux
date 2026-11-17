import AppKit
import XCTest
@testable import Nirux

/// The window's toolbar holding the command bar (docs/design/
/// glass-interface.md, step 3.1). Windows are laid out, never shown.
@MainActor
final class CommandBarToolbarTests: XCTestCase {
    /// Nirux's main window, `width` wide, with the toolbar; the test closes
    /// it.
    private func window(
        width: CGFloat = 1100, level: InterfaceTransparency = .opaque, indicators: Bool = false
    ) -> (NSWindow, CommandBarToolbar, cup: KeepAwakeIndicator?) {
        let window = NiruxApp.makeMainWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 400))
        window.isReleasedWhenClosed = false
        let bar = CommandBarView(level: level)
        // The level as picked: CI's runners reduce transparency.
        bar.resolveLevel = { $0 }
        let toolbar = CommandBarToolbar(bar: bar)
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
        let again = toolbar.toolbar(toolbar.toolbar, itemForItemIdentifier: CommandBarToolbar.barItemID, willBeInsertedIntoToolbar: true)
        XCTAssertTrue(again === item && item.view === toolbar.bar, "one item: asked again (full screen), it keeps the bar")
        XCTAssertEqual(toolbar.toolbar.items.map(\.itemIdentifier), [CommandBarToolbar.barItemID], "nothing else")
        // What macOS 14's strip menu offers (AppKit itself refuses label
        // only on a unified toolbar).
        toolbar.toolbar.displayMode = .iconAndLabel
        XCTAssertEqual(toolbar.toolbar.displayMode, .iconOnly, "never a label under the bar, nor a taller title bar")
        XCTAssertEqual(toolbar.bar.frame.width, CommandBarToolbar.maximumBarWidth, accuracy: 0.5, "a wide window: the widest bar")
        XCTAssertEqual(toolbar.bar.frame.height, CommandBarView.height)
        let bar = toolbar.bar.convert(toolbar.bar.bounds, to: nil)
        XCTAssertEqual(bar.midX, window.frame.width / 2, accuracy: 1, "centred")
        XCTAssertGreaterThan(window.frame.height - window.contentLayoutRect.height, 40, "a title bar tall enough for the bar")
    }

    /// At every level the bar takes the strip's width, the widest in a wide
    /// window and less in a narrow one: macOS 26's glass, which draws it
    /// above Opaque, asks the toolbar for no size.
    func testTheBarTakesTheStripsWidthAtEveryLevel() {
        for level in InterfaceTransparency.allCases {
            let (wide, toolbar, _) = window(width: 1560, level: level)
            XCTAssertEqual(toolbar.bar.frame.width, CommandBarToolbar.maximumBarWidth, accuracy: 0.5, "\(level), wide")
            wide.close()
            let (narrow, narrowToolbar, _) = window(width: 700, level: level)
            let width = narrowToolbar.bar.frame.width
            XCTAssertTrue(narrowToolbar.bar.window === narrow, "\(level), narrow: in the window, not the » menu")
            XCTAssertGreaterThanOrEqual(width, CommandBarToolbar.minimumBarWidth, "\(level), narrow")
            XCTAssertLessThan(width, CommandBarToolbar.maximumBarWidth, "\(level), narrow")
            narrow.close()
        }
    }

    /// At the minimum width, the cup coming after the bar was laid out makes
    /// the bar give it room, and its going gives the room back.
    func testTheBarMakesRoomWhenTheCupComes() throws {
        let (window, toolbar, cup) = window(width: 600, indicators: true)
        defer { window.close() }
        let indicator = try XCTUnwrap(cup)
        let frameView = try XCTUnwrap(window.contentView?.superview)
        indicator.update(isActive: false, workingAgentCount: 0)
        frameView.layoutSubtreeIfNeeded()
        let wide = toolbar.bar.frame.width
        indicator.update(isActive: true, workingAgentCount: 2)
        frameView.layoutSubtreeIfNeeded()
        let bar = toolbar.bar.convert(toolbar.bar.bounds, to: nil)
        let cupFrame = indicator.view.convert(indicator.view.bounds, to: nil)
        XCTAssertGreaterThan(cupFrame.width, 0)
        XCTAssertLessThanOrEqual(bar.maxX, cupFrame.minX, "the cup came: the bar made room")
        XCTAssertTrue(toolbar.toolbar.visibleItems?.contains { $0.itemIdentifier == CommandBarToolbar.barItemID } == true)
        indicator.update(isActive: false, workingAgentCount: 0)
        frameView.layoutSubtreeIfNeeded()
        XCTAssertEqual(toolbar.bar.frame.width, wide, accuracy: 0.5, "it went: the room came back")
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
