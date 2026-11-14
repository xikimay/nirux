import XCTest
@testable import Nirux

/// The glass interface's levels and shapes (docs/design/glass-interface.md).
final class AppearanceTests: XCTestCase {
    /// Accessibility wins: Reduce transparency or Increase contrast make
    /// every level opaque, and only they change the level.
    func testMacOSAccessibilityMakesEveryLevelOpaque() {
        for level in InterfaceTransparency.allCases {
            XCTAssertEqual(level.effective(reducesTransparency: true, increasesContrast: false), .opaque, "\(level)")
            XCTAssertEqual(level.effective(reducesTransparency: false, increasesContrast: true), .opaque, "\(level)")
            XCTAssertEqual(level.effective(reducesTransparency: false, increasesContrast: false), level)
        }
    }

    /// Each level shows more of the desktop than the one before it; Opaque
    /// shows none of it.
    func testEachLevelIsMoreTransparentThanTheLast() {
        let levels = InterfaceTransparency.allCases
        XCTAssertEqual(levels, [.opaque, .tinted, .glass, .clear], "the Settings order")
        XCTAssertEqual(InterfaceTransparency.opaque.windowBackgroundAlpha, 1)
        for (more, less) in zip(levels, levels.dropFirst()) {
            XCTAssertGreaterThan(more.windowBackgroundAlpha, less.windowBackgroundAlpha, "\(more) → \(less)")
            XCTAssertGreaterThan(more.chromeTintAlpha, less.chromeTintAlpha, "\(more) → \(less)")
        }
        XCTAssertEqual(levels.filter(\.usesClearGlass), [.clear])
    }

    /// A shape inset in a rounded container shares its corners' centre, and
    /// never falls under the minimum.
    func testConcentricCorners() {
        XCTAssertEqual(Theme.Radius.concentric(outer: 22, inset: 8), 14)
        XCTAssertEqual(Theme.Radius.concentric(outer: 10, inset: 8), Theme.Radius.chip)
        XCTAssertEqual(Theme.Radius.concentric(outer: 10, inset: 8, minimum: 0), 2)
    }
}
