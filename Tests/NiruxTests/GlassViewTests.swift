import AppKit
import XCTest
@testable import Nirux

/// The glass interface's glass (docs/design/glass-interface.md). CI runs on
/// macOS 15, so it draws the frost; a Mac on macOS 26 or later, the glass.
@MainActor
final class GlassViewTests: XCTestCase {
    /// Opaque is solid on every Mac; the other levels are glass where macOS
    /// has it, frost where it doesn't.
    func testTheBackingFollowsTheLevelAndTheMac() {
        for hasGlass in [true, false] {
            XCTAssertEqual(GlassView.backing(for: .opaque, hasGlass: hasGlass), .solid)
            for level in [InterfaceTransparency.tinted, .glass, .clear] {
                XCTAssertEqual(GlassView.backing(for: level, hasGlass: hasGlass), hasGlass ? .glass : .frosted, "\(level)")
            }
        }
    }

    /// The chrome lets more through as the level rises; what floats over the
    /// work stays thick at every level: no glass on glass.
    func testWhatFloatsStaysThickAtEveryLevel() {
        let levels = InterfaceTransparency.allCases
        for level in levels {
            XCTAssertGreaterThanOrEqual(GlassView.tintAlpha(for: level, role: .floating), 0.85, "\(level)")
        }
        XCTAssertEqual(GlassView.tintAlpha(for: .opaque, role: .chrome), 1)
        for (more, less) in zip(levels, levels.dropFirst()) {
            XCTAssertGreaterThan(GlassView.tintAlpha(for: more, role: .chrome), GlassView.tintAlpha(for: less, role: .chrome))
        }
    }

    /// On this Mac: the glass or the frost under the content, a solid fill
    /// once Opaque, and the floating shadow only where the system draws none.
    func testItDrawsWithWhatThisMacHas() {
        let view = GlassView(role: .floating, level: .glass, cornerRadius: 18)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        let label = NSTextField(labelWithString: "Waiting for you")
        view.contentView.addSubview(label)
        view.layoutSubtreeIfNeeded()
        func effectViews() -> [NSView] {
            view.subviews.filter { $0 is NSVisualEffectView || String(describing: type(of: $0)).contains("Glass") }
        }
        if #available(macOS 26, *) {
            XCTAssertEqual(view.backing, .glass)
            let glass = effectViews().compactMap { $0 as? NSGlassEffectView }.first
            XCTAssertTrue(glass?.contentView === view.contentView, "the content sits in the glass")
            XCTAssertEqual(view.layer?.shadowOpacity, 0, "the system draws the glass's edge")
        } else {
            XCTAssertEqual(view.backing, .frosted)
            let frost = effectViews().compactMap { $0 as? NSVisualEffectView }.first
            XCTAssertEqual(frost?.state, .active, "frosted even in a window that isn't key")
            XCTAssertTrue(view.contentView.superview === view)
            XCTAssertEqual(view.layer?.shadowOpacity, Theme.Elevation.floatingOpacity)
        }
        view.level = .opaque
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.backing, .solid)
        XCTAssertEqual(effectViews().count, 0)
        XCTAssertTrue(label.superview === view.contentView && view.contentView.superview === view)
        XCTAssertEqual(view.layer?.backgroundColor, Theme.Color.raised.cgColor)
        XCTAssertEqual(view.layer?.shadowOpacity, Theme.Elevation.floatingOpacity)
    }
}
