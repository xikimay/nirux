import Foundation
import XCTest

/// The tests' one wait: spins the main run loop until `condition` holds,
/// else fails the test after `timeout` with "timed out waiting for
/// `description`", at the caller's line. `description` is read at the
/// failure, so it can tell what the test saw last. A condition that throws
/// counts as not holding yet, until the last look, which rethrows. Returns
/// whether it held.
@MainActor
@discardableResult
func waitUntil(
    _ description: @autoclosure () -> String,
    timeout: TimeInterval = 30,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () throws -> Bool
) rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while (try? condition()) != true {
        guard Date() < deadline else {
            guard try condition() else {
                XCTFail("timed out waiting for \(description())", file: file, line: line)
                return false
            }
            return true
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return true
}

/// `waitUntil` for an async test, which doesn't spin the run loop: it
/// sleeps between looks.
@MainActor
@discardableResult
func waitUntil(
    _ description: @autoclosure () -> String,
    timeout: TimeInterval = 30,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            XCTFail("timed out waiting for \(description())", file: file, line: line)
            return false
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    return true
}
