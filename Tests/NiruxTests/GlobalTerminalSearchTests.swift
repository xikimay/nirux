import XCTest
@testable import Nirux

/// Search Everywhere streams each terminal's matches as it is read, and a
/// newer search silences the one it replaced.
@MainActor
final class GlobalTerminalSearchTests: XCTestCase {
    func testMatchesArriveTerminalByTerminalThenTheSearchEnds() {
        let search = GlobalTerminalSearch()
        var delivered: [(Int, [String])] = []
        let done = expectation(description: "done")
        search.start(
            needle: "needle",
            readers: [{ "a needle" }, { nil }, { "nothing" }, { "needle\nneedle 2" }],
            onMatches: { index, result in delivered.append((index, result.matches.map(\.excerpt))) },
            onDone: { done.fulfill() }
        )
        XCTAssertTrue(search.isRunning)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(delivered.map(\.0), [0, 3])
        XCTAssertEqual(delivered.map(\.1), [["a needle"], ["needle 2", "needle"]])
        XCTAssertFalse(search.isRunning)
    }

    func testANewSearchSilencesTheOneItReplaced() {
        let search = GlobalTerminalSearch()
        var stale = 0
        search.start(needle: "old", readers: [{ "old" }], onMatches: { _, _ in stale += 1 }, onDone: { stale += 1 })
        let done = expectation(description: "done")
        var matches = 0
        search.start(needle: "new", readers: [{ "new" }], onMatches: { _, _ in matches += 1 }, onDone: { done.fulfill() })
        wait(for: [done], timeout: 5)
        XCTAssertEqual(matches, 1)

        search.start(needle: "new", readers: [{ "new" }], onMatches: { _, _ in stale += 1 }, onDone: { stale += 1 })
        search.cancel()
        XCTAssertFalse(search.isRunning)
        // Both scans have delivered by the time this block runs.
        let drained = expectation(description: "drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { drained.fulfill() }
        wait(for: [drained], timeout: 5)
        XCTAssertEqual(stale, 0)
    }

    func testTheStatusLineCountsMatchesAndTerminals() {
        let status = GlobalSearchPanel.status
        XCTAssertEqual(status(0, 0, 0, 0, false), "No terminal to search")
        XCTAssertEqual(status(3, 0, 0, 0, true), "Searching 3 terminals…")
        XCTAssertEqual(status(3, 1, 1, 1, true), "Searching 3 terminals… 1 match so far")
        XCTAssertEqual(status(1, 0, 0, 0, false), "No matches in 1 terminal")
        XCTAssertEqual(status(3, 2, 7, 7, false), "7 matches in 2 of 3 terminals")
        XCTAssertEqual(status(3, 2, 900, 500, false), "900 matches in 2 of 3 terminals · 500 shown")
    }
}
