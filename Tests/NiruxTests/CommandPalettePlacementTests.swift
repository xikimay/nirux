import AppKit
import XCTest
@testable import Nirux

/// ⌘P's placement: centred as today, or unfolding from the glass
/// interface's command bar (docs/design/glass-interface.md). The panel is
/// placed and dressed, never shown.
@MainActor
final class CommandPalettePlacementTests: XCTestCase {
    private let window = NSRect(x: 100, y: 100, width: 1200, height: 800)

    /// Centred, the palette opens where it always has.
    func testCenteredStaysWhereItWas() {
        XCTAssertEqual(CommandPalette.frame(for: .centered, in: window), NSRect(x: 440, y: 540, width: 520, height: 340))
    }

    /// Under the bar, it hangs from the bar, centred on it, and stays inside
    /// the window when the bar sits near an edge.
    func testUnderTheBarItUnfoldsFromIt() {
        let bar = NSRect(x: 400, y: 840, width: 600, height: 36)
        let frame = CommandPalette.frame(for: .underBar(bar, level: .glass), in: window)
        XCTAssertEqual(frame.maxY, bar.minY - CommandPalette.barGap)
        XCTAssertEqual(frame.midX, bar.midX)
        XCTAssertEqual(frame.size, CommandPalette.size)
        let left = CommandPalette.frame(for: .underBar(NSRect(x: 110, y: 840, width: 200, height: 36), level: .glass), in: window)
        XCTAssertEqual(left.minX, window.minX + Theme.Space.sm)
        let right = CommandPalette.frame(for: .underBar(NSRect(x: 1180, y: 840, width: 100, height: 36), level: .glass), in: window)
        XCTAssertEqual(right.maxX, window.maxX - Theme.Space.sm)
    }

    /// Under the bar, the field and the rows sit on floating glass that
    /// fills the panel and leaves the shadow to it; centred again, today's
    /// background comes back. Nothing shows.
    func testItDressesForEachPlacement() throws {
        let palette = CommandPalette()
        let bar = NSRect(x: 400, y: 840, width: 600, height: 36)
        palette.apply(.underBar(bar, level: .tinted), in: window)
        let panel = try XCTUnwrap(palette.panel)
        let background = try XCTUnwrap(panel.contentView)
        let glass = try XCTUnwrap(palette.glass)
        XCTAssertTrue(glass.superview === background)
        XCTAssertTrue(background.subviews.first === glass, "behind the field and the rows")
        XCTAssertEqual(glass.frame, background.bounds)
        XCTAssertEqual(glass.level, .tinted)
        XCTAssertTrue(glass.fillsWindow)
        XCTAssertNil(background.layer?.backgroundColor)
        XCTAssertEqual(panel.frame, CommandPalette.frame(for: .underBar(bar, level: .tinted), in: window))

        palette.apply(.underBar(bar, level: .clear), in: window)
        XCTAssertTrue(palette.glass === glass, "one glass, its level followed")
        XCTAssertEqual(glass.level, .clear)

        palette.apply(.centered, in: window)
        XCTAssertNil(palette.glass)
        XCTAssertNil(glass.superview)
        XCTAssertEqual(background.layer?.backgroundColor, Theme.Color.base.withAlphaComponent(0.98).cgColor)
        XCTAssertEqual(panel.frame, CommandPalette.frame(for: .centered, in: window))
        XCTAssertFalse(panel.isVisible)
    }
}
