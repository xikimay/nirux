import XCTest
@testable import Nirux

/// The glass interface's transparency levels (docs/design/glass-interface.md).
final class AppearanceTests: XCTestCase {
    /// Accessibility wins: Reduce transparency or Increase contrast make
    /// every level opaque, only they change the level, and Opaque draws no
    /// glass at all.
    func testMacOSAccessibilityMakesEveryLevelOpaque() {
        for level in InterfaceTransparency.allCases {
            XCTAssertEqual(level.effective(reducesTransparency: true, increasesContrast: false), .opaque, "\(level)")
            XCTAssertEqual(level.effective(reducesTransparency: false, increasesContrast: true), .opaque, "\(level)")
            XCTAssertEqual(level.effective(reducesTransparency: false, increasesContrast: false), level)
        }
        XCTAssertEqual(InterfaceTransparency.allCases.filter { !$0.usesGlass }, [.opaque])
    }
}
