import Foundation
import XCTest

final class FirstFailureTests: XCTestCase {
    func testAssertionReachesObserverWhileThisMethodIsRunning() {
        XCTAssertEqual(1, 0, "early XCTest diagnostic fixture")
        let signal = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RUNNER_TEMP"]!)
            .appendingPathComponent("consumer-read-diagnostic")
        let deadline = Date().addingTimeInterval(90)
        while !FileManager.default.fileExists(atPath: signal.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: signal.path), "the observer didn't receive the diagnostic in time")
    }
}
