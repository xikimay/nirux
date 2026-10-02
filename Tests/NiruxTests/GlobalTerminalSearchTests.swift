import XCTest
@testable import Nirux

/// Search Everywhere streams each terminal's matches as it is read, and a
/// newer search silences the one it replaced.
@MainActor
final class GlobalTerminalSearchTests: XCTestCase {
    /// What the callbacks saw: a main-actor object, not captured vars,
    /// which Swift 6.1 won't let `@Sendable` closures mutate.
    private final class Calls {
        var matches: [(Int, [String])] = []
        var done = 0
    }

    func testMatchesArriveTerminalByTerminalThenTheSearchEnds() {
        let search = GlobalTerminalSearch()
        let calls = Calls()
        let done = expectation(description: "done")
        search.start(
            needle: "needle",
            readers: [{ "a needle" }, { nil }, { "nothing" }, { "needle\nneedle 2" }],
            onMatches: { index, result in calls.matches.append((index, result.matches.map(\.excerpt))) },
            onDone: { done.fulfill() }
        )
        XCTAssertTrue(search.isRunning)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(calls.matches.map(\.0), [0, 3])
        XCTAssertEqual(calls.matches.map(\.1), [["a needle"], ["needle 2", "needle"]])
        XCTAssertFalse(search.isRunning)
    }

    func testASupersededOrCancelledSearchStaysSilent() {
        let search = GlobalTerminalSearch()
        let stale = Calls()
        // Its second terminal is read once the first one's match is on its
        // way to the main queue, ahead of anything sent after.
        func startStaleSearch() {
            let firstDelivered = DispatchSemaphore(value: 0)
            search.start(
                needle: "old",
                readers: [{ "old" }, { firstDelivered.signal(); return nil }],
                onMatches: { index, _ in stale.matches.append((index, [])) },
                onDone: { stale.done += 1 }
            )
            firstDelivered.wait()
        }

        startStaleSearch()
        let fresh = Calls()
        let done = expectation(description: "done")
        search.start(
            needle: "new",
            readers: [{ "new" }],
            onMatches: { index, _ in fresh.matches.append((index, [])) },
            onDone: { done.fulfill() }
        )
        wait(for: [done], timeout: 5)
        XCTAssertEqual(fresh.matches.count, 1)

        startStaleSearch()
        search.cancel()
        XCTAssertFalse(search.isRunning)
        // The search queue is serial: this answers after the cancelled
        // scan's last word.
        let drained = expectation(description: "drained")
        let anyMatch = ScrollbackSearch.Match(line: 1, excerpt: "", highlight: NSRange(), fromBottom: 0, context: 0)
        GlobalTerminalSearch.relocate(anyMatch, of: "old", read: { nil }) { _ in drained.fulfill() }
        wait(for: [drained], timeout: 5)
        XCTAssertTrue(stale.matches.isEmpty)
        XCTAssertEqual(stale.done, 0)
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
