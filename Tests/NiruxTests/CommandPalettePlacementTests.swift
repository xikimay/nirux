import AppKit
import XCTest
@testable import Nirux

/// ⌘P's placement: centred as today, or unfolding from the glass
/// interface's command bar (docs/design/glass-interface.md). The panel is
/// placed and dressed, never shown.
@MainActor
final class CommandPalettePlacementTests: XCTestCase {
    private let windowFrame = NSRect(x: 100, y: 100, width: 1200, height: 800)

    /// A window that is never shown, at `windowFrame`, with a bar along its
    /// top at `barX`; the test closes it.
    private func windowWithBar(barX: CGFloat = 300, width: CGFloat = 600) -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: windowFrame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.setFrame(windowFrame, display: false)
        let bar = NSView(frame: NSRect(x: barX, y: windowFrame.height - 12 - 36, width: width, height: 36))
        window.contentView?.addSubview(bar)
        return (window, bar)
    }

    /// Centred, the palette opens where it always has.
    func testCenteredStaysWhereItWas() {
        XCTAssertEqual(CommandPalette.centeredFrame(in: windowFrame), NSRect(x: 440, y: 540, width: 520, height: 340))
    }

    /// Under the bar, it hangs from the bar, centred on it, inside the
    /// window when the bar sits near an edge, and above the screen's bottom.
    func testUnderTheBarItUnfoldsFromIt() throws {
        let (window, bar) = windowWithBar()
        defer { window.close() }
        let onScreen = try XCTUnwrap(CommandPalette.barOnScreen(bar))
        XCTAssertEqual(onScreen.rect, NSRect(x: 400, y: 852, width: 600, height: 36), "the bar's rect on screen")
        let frame = CommandPalette.frame(underBar: onScreen.rect, in: windowFrame, screen: nil)
        XCTAssertEqual(frame.maxY, onScreen.rect.minY - CommandPalette.barGap)
        XCTAssertEqual(frame.midX, onScreen.rect.midX)
        XCTAssertEqual(frame.size, CommandPalette.size)

        let left = CommandPalette.frame(underBar: NSRect(x: 110, y: 852, width: 200, height: 36), in: windowFrame, screen: nil)
        XCTAssertEqual(left.minX, windowFrame.minX + Theme.Space.sm)
        let right = CommandPalette.frame(underBar: NSRect(x: 1180, y: 852, width: 100, height: 36), in: windowFrame, screen: nil)
        XCTAssertEqual(right.maxX, windowFrame.maxX - Theme.Space.sm)
        let narrow = NSRect(x: 100, y: 100, width: 500, height: 800)
        XCTAssertEqual(CommandPalette.frame(underBar: NSRect(x: 150, y: 852, width: 400, height: 36), in: narrow, screen: nil).minX,
                       narrow.minX + Theme.Space.sm, "a window narrower than the palette keeps its left edge")
        let low = CommandPalette.frame(underBar: NSRect(x: 400, y: 200, width: 600, height: 36), in: windowFrame,
                                       screen: NSRect(x: 0, y: 25, width: 1440, height: 875))
        XCTAssertEqual(low.minY, 25 + Theme.Space.sm, "the rows stay on the screen")
        let high = CommandPalette.frame(underBar: NSRect(x: 400, y: 960, width: 600, height: 36), in: windowFrame,
                                        screen: NSRect(x: 0, y: 25, width: 1440, height: 875))
        XCTAssertEqual(high.maxY, 900 - Theme.Space.sm, "a bar above the screen: the palette stays on it")

        // It unfolds from the bar's middle: that point stays put, the rest
        // grows from it.
        let origin = NSPoint(x: frame.width / 2, y: frame.height)
        let start = CommandPalette.unfoldStart(from: origin)
        XCTAssertEqual(origin.applying(start), origin)
        XCTAssertLessThan(NSPoint.zero.applying(start).y, origin.y)
        XCTAssertGreaterThan(NSPoint.zero.applying(start).y, 0, "the bottom starts higher, toward the bar")
    }

    /// A press on the command bar's search segment counts as one on the
    /// title bar's Search: it closes an open palette instead of opening it
    /// again.
    func testThePressOnTheBarsSearchClosesThePalette() throws {
        let bar = CommandBarView(level: .opaque)
        bar.show(CommandBarView.Content(
            spaceName: "Acme", spaceColor: Theme.Color.working, taskTitle: "Fix checkout rounding",
            taskIcon: StateIcon(.working, stage: 1), taskDetail: nil, waitingCount: 0
        ))
        bar.frame = NSRect(x: 20, y: 400, width: 600, height: CommandBarView.height)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 460), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(bar)
        bar.layoutSubtreeIfNeeded()
        func press(_ button: NSButton) throws -> NSEvent {
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        XCTAssertTrue(CommandPalette.isSearchButtonPress(try press(bar.searchButton)))
        XCTAssertFalse(CommandPalette.isSearchButtonPress(try press(bar.taskButton)))
    }

    /// Under the bar, the field and the rows sit on floating glass that
    /// fills the panel, with its continuous corners; centred again, or with
    /// the bar showing nowhere, today's background comes back. Nothing shows.
    func testItDressesForEachPlacement() throws {
        let (window, bar) = windowWithBar()
        defer { window.close() }
        let palette = CommandPalette()
        palette.apply(.underBar(bar, level: .tinted), relativeTo: window)
        let panel = try XCTUnwrap(palette.panel)
        let background = try XCTUnwrap(panel.contentView)
        let glass = try XCTUnwrap(palette.glass)
        XCTAssertTrue(glass.superview === background)
        XCTAssertTrue(background.subviews.first === glass, "behind the field and the rows")
        XCTAssertEqual(glass.frame, background.bounds)
        XCTAssertEqual(glass.level, .tinted)
        XCTAssertTrue(glass.fillsWindow)
        XCTAssertNil(background.layer?.backgroundColor)
        XCTAssertEqual(background.layer?.cornerCurve, .continuous)
        let onScreen = try XCTUnwrap(CommandPalette.barOnScreen(bar))
        XCTAssertEqual(panel.frame, CommandPalette.frame(underBar: onScreen.rect, in: windowFrame, screen: window.screen?.visibleFrame))

        palette.apply(.underBar(bar, level: .clear), relativeTo: window)
        XCTAssertTrue(palette.glass === glass, "one glass, its level followed")
        XCTAssertEqual(glass.level, .clear)

        palette.apply(.centered, relativeTo: window)
        XCTAssertNil(palette.glass)
        XCTAssertNil(glass.superview)
        XCTAssertEqual(background.layer?.backgroundColor, Theme.Color.base.withAlphaComponent(0.98).cgColor)
        XCTAssertEqual(background.layer?.cornerCurve, .circular)
        XCTAssertEqual(panel.frame, CommandPalette.centeredFrame(in: windowFrame))

        bar.isHidden = true
        palette.apply(.underBar(bar, level: .glass), relativeTo: window)
        XCTAssertNil(palette.glass, "a hidden bar: centred")
        XCTAssertEqual(panel.frame, CommandPalette.centeredFrame(in: windowFrame))
        palette.apply(.underBar(NSView(), level: .glass), relativeTo: window)
        XCTAssertNil(palette.glass, "a bar in no window: centred")
        bar.isHidden = false
        bar.frame.origin.x = 5000
        palette.apply(.underBar(bar, level: .glass), relativeTo: window)
        XCTAssertNil(palette.glass, "a bar outside its window: centred")
        XCTAssertFalse(panel.isVisible)
    }
}
