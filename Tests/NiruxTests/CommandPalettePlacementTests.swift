import AppKit
import XCTest
@testable import Nirux

/// ⌘P's placement: centred as today, or unfolding from the glass
/// interface's command bar (docs/design/glass-interface.md). The panel is
/// placed and dressed, never shown; the windows here are never shown either,
/// so the palette is told they show.
@MainActor
final class CommandPalettePlacementTests: XCTestCase {
    private let windowFrame = NSRect(x: 100, y: 100, width: 1200, height: 800)
    private let screen = NSRect(x: 0, y: 25, width: 1440, height: 875)

    /// A window that is never shown, at `windowFrame`, with a bar along its
    /// top; the test closes it.
    private func windowWithBar() -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: windowFrame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.setFrame(windowFrame, display: false)
        let bar = NSView(frame: NSRect(x: 300, y: windowFrame.height - 12 - 36, width: 600, height: 36))
        window.contentView?.addSubview(bar)
        return (window, bar)
    }

    private func palette() -> CommandPalette {
        let palette = CommandPalette()
        palette.windowShows = { _ in true }
        return palette
    }

    /// Centred, the palette opens where it always has.
    func testCenteredStaysWhereItWas() {
        XCTAssertEqual(CommandPalette.centeredFrame(in: windowFrame), NSRect(x: 440, y: 540, width: 520, height: 340))
    }

    /// Under the bar, it hangs from the bar, centred on it, inside the
    /// window and then on the screen; near the screen's bottom it goes above
    /// the bar rather than over it, and it unfolds from the bar's side.
    func testUnderTheBarItUnfoldsFromIt() throws {
        let (window, bar) = windowWithBar()
        defer { window.close() }
        let onScreen = try XCTUnwrap(CommandPalette.barOnScreen(bar, in: window, windowShows: { _ in true }))
        XCTAssertEqual(onScreen, NSRect(x: 400, y: 852, width: 600, height: 36), "the bar's rect on screen")
        let under = CommandPalette.place(underBar: onScreen, in: windowFrame, screen: nil)
        XCTAssertFalse(under.isAbove)
        XCTAssertEqual(under.frame.maxY, onScreen.minY - CommandPalette.barGap)
        XCTAssertEqual(under.frame.midX, onScreen.midX)
        XCTAssertEqual(under.frame.size, CommandPalette.size)

        let left = CommandPalette.place(underBar: NSRect(x: 110, y: 852, width: 200, height: 36), in: windowFrame, screen: nil)
        XCTAssertEqual(left.frame.minX, windowFrame.minX + Theme.Space.sm)
        let right = CommandPalette.place(underBar: NSRect(x: 1180, y: 852, width: 100, height: 36), in: windowFrame, screen: nil)
        XCTAssertEqual(right.frame.maxX, windowFrame.maxX - Theme.Space.sm)
        let narrow = NSRect(x: 100, y: 100, width: 500, height: 800)
        XCTAssertEqual(CommandPalette.place(underBar: NSRect(x: 150, y: 852, width: 400, height: 36), in: narrow, screen: nil).frame.minX,
                       narrow.minX + Theme.Space.sm, "a window narrower than the palette keeps its left edge")
        let pastTheEdge = NSRect(x: 1000, y: 100, width: 1200, height: 800)
        XCTAssertEqual(CommandPalette.place(underBar: NSRect(x: 1300, y: 852, width: 600, height: 36), in: pastTheEdge, screen: screen)
            .frame.maxX, screen.maxX - Theme.Space.sm, "a window past the screen's edge: the palette stays on the screen")

        let lowBar = NSRect(x: 400, y: 200, width: 600, height: 36)
        let low = CommandPalette.place(underBar: lowBar, in: windowFrame, screen: screen)
        XCTAssertTrue(low.isAbove, "no room below the bar: above it")
        XCTAssertEqual(low.frame.minY, 236 + CommandPalette.barGap, "never over the bar")
        XCTAssertEqual(CommandPalette.unfoldOrigin(of: low, bar: lowBar), NSPoint(x: lowBar.midX - low.frame.minX, y: 0),
                       "above the bar, it unfolds from its bottom edge")
        let high = CommandPalette.place(underBar: NSRect(x: 400, y: 960, width: 600, height: 36), in: windowFrame, screen: screen)
        XCTAssertEqual(high.frame.maxY, screen.maxY - Theme.Space.sm, "a bar above the screen: the palette stays on it")

        let palette = palette()
        palette.apply(.underBar(bar, level: .glass), relativeTo: window)
        XCTAssertEqual(palette.unfoldsFrom, NSPoint(x: onScreen.midX - under.frame.minX, y: under.frame.height), "from the bar's middle, at its top")
        let origin = try XCTUnwrap(palette.unfoldsFrom)
        let start = CommandPalette.unfoldStart(from: origin)
        XCTAssertEqual(origin.applying(start), origin, "that point stays put")
        XCTAssertGreaterThan(NSPoint.zero.applying(start).y, 0, "the bottom starts higher, toward the bar")
    }

    /// Under the bar, the field and the rows sit inside floating glass that
    /// fills the panel; centred again, they come back on today's background
    /// and the glass waits, hidden. While nobody sees the bar, the palette
    /// opens centred. Nothing shows.
    func testItDressesForEachPlacement() throws {
        let (window, bar) = windowWithBar()
        defer { window.close() }
        let palette = palette()
        palette.apply(.underBar(bar, level: .tinted), relativeTo: window)
        let panel = try XCTUnwrap(palette.panel)
        let background = try XCTUnwrap(panel.contentView)
        let glass = try XCTUnwrap(palette.glass)
        let field = try XCTUnwrap(palette.searchField)
        XCTAssertTrue(background.subviews.first === glass)
        XCTAssertEqual(glass.frame, background.bounds)
        XCTAssertTrue(field.isDescendant(of: glass.contentView), "inside the glass, which adapts what it holds")
        XCTAssertTrue(try XCTUnwrap(palette.listContainer).isDescendant(of: glass.contentView))
        XCTAssertEqual(glass.level, .tinted)
        XCTAssertTrue(glass.fillsWindow)
        XCTAssertNil(background.layer?.backgroundColor)
        XCTAssertEqual(background.layer?.cornerCurve, .continuous)
        let onScreen = try XCTUnwrap(CommandPalette.barOnScreen(bar, in: window, windowShows: { _ in true }))
        XCTAssertEqual(panel.frame, CommandPalette.place(underBar: onScreen, in: windowFrame, screen: window.screen?.visibleFrame).frame)

        palette.apply(.underBar(bar, level: .clear), relativeTo: window)
        XCTAssertTrue(palette.glass === glass, "one glass, its level followed")
        XCTAssertEqual(glass.level, .clear)

        palette.apply(.centered, relativeTo: window)
        XCTAssertTrue(palette.glass === glass && glass.isHidden, "kept, hidden")
        XCTAssertTrue(palette.fieldContainer?.superview === background, "the field back on today's background")
        XCTAssertFalse(field.isDescendant(of: glass))
        XCTAssertEqual(background.layer?.backgroundColor, Theme.Color.base.withAlphaComponent(0.98).cgColor)
        XCTAssertEqual(background.layer?.cornerCurve, .circular)
        XCTAssertEqual(panel.frame, CommandPalette.centeredFrame(in: windowFrame))
        XCTAssertNil(palette.unfoldsFrom)

        func opensCentred(_ why: String) {
            XCTAssertTrue(glass.isHidden, why)
            XCTAssertEqual(panel.frame, CommandPalette.centeredFrame(in: windowFrame), why)
        }
        bar.isHidden = true
        palette.apply(.underBar(bar, level: .glass), relativeTo: window)
        opensCentred("a hidden bar")
        bar.isHidden = false
        bar.alphaValue = 0
        palette.apply(.underBar(bar, level: .glass), relativeTo: window)
        opensCentred("a transparent bar")
        bar.alphaValue = 1
        palette.windowShows = { _ in false }
        palette.apply(.underBar(bar, level: .glass), relativeTo: window)
        opensCentred("its window ordered out, minimized or on another Space")
        palette.windowShows = { _ in true }
        let other = NSWindow(contentRect: windowFrame, styleMask: .borderless, backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        palette.apply(.underBar(bar, level: .glass), relativeTo: other)
        XCTAssertTrue(glass.isHidden, "a bar in another window than the host")
        palette.apply(.underBar(NSView(), level: .glass), relativeTo: window)
        opensCentred("a bar in no window")
        bar.frame.origin.x = 5000
        palette.apply(.underBar(bar, level: .glass), relativeTo: window)
        opensCentred("a bar outside its window")
        XCTAssertFalse(panel.isVisible)
    }
}
