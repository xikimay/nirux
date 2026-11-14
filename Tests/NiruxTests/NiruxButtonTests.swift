import AppKit
import XCTest
@testable import Nirux

/// The glass interface's one button (docs/design/glass-interface.md).
@MainActor
final class NiruxButtonTests: XCTestCase {
    private func rgb(_ color: NSColor) -> [CGFloat] {
        guard let c = color.usingColorSpace(.sRGB) else { return [] }
        return [c.redComponent, c.greenComponent, c.blueComponent].map { ($0 * 100).rounded() / 100 }
    }

    /// No button is ever amber, in any state: amber is an agent waiting for
    /// the user. Hover and press show; a disabled title greys out.
    func testNoButtonIsAmberAndItsStatesShow() {
        let amber = rgb(Theme.Color.waiting)
        for kind in NiruxButton.Kind.allCases {
            var fills: [CGFloat] = []
            for (hovered, pressed) in [(false, false), (true, false), (true, true)] {
                let look = NiruxButton.look(kind, hovered: hovered, pressed: pressed, enabled: true)
                XCTAssertNotEqual(rgb(look.fill), amber, "\(kind)")
                XCTAssertNotEqual(rgb(look.text), amber, "\(kind)")
                fills.append(look.fill.alphaComponent)
            }
            if kind == .primary {
                XCTAssertGreaterThan(fills[0], fills[1], "hover softens the primary")
                XCTAssertGreaterThan(fills[1], fills[2], "a press softens it more")
            } else {
                XCTAssertLessThan(fills[0], fills[1], "\(kind): hover shows")
                XCTAssertLessThan(fills[1], fills[2], "\(kind): a press shows")
            }
            XCTAssertEqual(NiruxButton.look(kind, hovered: true, pressed: true, enabled: false).text, Theme.Color.textDisabled)
        }
        XCTAssertEqual(NiruxButton.look(.danger, hovered: false, pressed: false, enabled: true).text, Theme.Color.error)
    }

    /// A capsule of the size's height, as wide as its title, which keeps the
    /// button's font and colour when it changes.
    func testACapsuleAsWideAsItsTitle() {
        let start = NiruxButton(title: "Start", kind: .primary)
        let small = NiruxButton(title: "Start", kind: .primary, size: .small)
        XCTAssertEqual(start.frame.height, 24)
        XCTAssertEqual(small.frame.height, 20)
        XCTAssertEqual(start.layer?.cornerRadius, 12)
        let wider = NiruxButton(title: "Existing Branch…", kind: .quiet)
        XCTAssertGreaterThan(wider.intrinsicContentSize.width, start.intrinsicContentSize.width)
        start.title = "Allow"
        XCTAssertEqual(start.title, "Allow")
        let attributes = start.attributedTitle.attributes(at: 0, effectiveRange: nil)
        XCTAssertEqual(attributes[.foregroundColor] as? NSColor, Theme.Color.canvas)
        XCTAssertEqual(attributes[.font] as? NSFont, Theme.Font.button)
    }

    /// A click acts; the glass kind is macOS 26's own glass bezel there, and
    /// looks secondary where macOS has no glass.
    func testAClickActsAndGlassFallsBack() {
        final class Target: NSObject {
            var presses = 0
            @objc func press(_ sender: Any?) { presses += 1 }
        }
        let target = Target()
        let button = NiruxButton(title: "Allow", kind: .secondary, target: target, action: #selector(Target.press(_:)))
        button.performClick(nil)
        XCTAssertEqual(target.presses, 1)
        let glass = NiruxButton(title: "Board", kind: .glass)
        if #available(macOS 26, *) {
            XCTAssertEqual(glass.bezelStyle, .glass)
        } else {
            XCTAssertFalse(glass.isBordered)
            XCTAssertEqual(glass.layer?.backgroundColor, button.layer?.backgroundColor)
        }
    }
}
