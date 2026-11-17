import Foundation
import XCTest

/// The tests' one wait (`waitUntil`): it returns once its condition holds,
/// and a timeout says what it waited for, as the test saw it last.
@MainActor
final class WaitUntilTests: XCTestCase {
    private struct NotYet: Error {}

    func testItReturnsOnceTheConditionHolds() {
        var held = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { held = true }
        let start = Date()
        XCTAssertTrue(waitUntil("the flag") { held })
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testATimeoutSaysWhatItWaitedForAsLastSeen() {
        var looks = 0
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { issue in
            issue.compactDescription.contains("timed out waiting for the door (looked") && !issue.compactDescription.contains("looked 0 ")
        }
        XCTExpectFailure("a door that never opens", options: options) {
            XCTAssertFalse(waitUntil("the door (looked \(looks) times)", timeout: 0.1) {
                looks += 1
                return false
            })
        }
        XCTAssertGreaterThan(looks, 1, "it looked again until the timeout")
    }

    func testAThrowingConditionCountsAsNotYetUntilTheLastLook() throws {
        var looks = 0
        XCTAssertTrue(try waitUntil("the third look") {
            looks += 1
            if looks < 3 { throw NotYet() }
            return true
        })
        XCTAssertThrowsError(try waitUntil("a condition that always throws", timeout: 0.05) { throw NotYet() })
    }

    func testTheAsyncWaitSleepsUntilTheConditionHolds() async throws {
        var held = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { held = true }
        let wasHeld = try await waitUntil("the flag") { held }
        XCTAssertTrue(wasHeld)
    }
}
