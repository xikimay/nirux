import XCTest

// DO NOT MERGE: a flake the gate must see, failing one run in three.
final class ZZFlakeGateProbeTests: XCTestCase {
    func testFailsOneRunInThree() {
        XCTAssertNotEqual(Int.random(in: 0..<3), 0, "a flake the gate must see")
    }
}
