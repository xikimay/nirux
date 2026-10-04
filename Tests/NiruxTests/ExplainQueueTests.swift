import XCTest
@testable import Nirux

/// One Explain run at a time in the whole app (docs/branch-review.md,
/// section 4.3): a second waits in line, and either can be cancelled.
final class ExplainQueueTests: XCTestCase {
    @MainActor
    func testASecondRunWaitsForTheFirst() {
        let queue = ExplainQueue()
        let gate = DispatchSemaphore(value: 0)
        let order = Order()
        queue.submit({ _ in
            order.append("first runs")
            gate.wait()
            return 1
        }, completion: { _ in order.append("first done") })
        let second = queue.submit({ _ in
            order.append("second runs")
            return 2
        }, completion: { order.append("second done \($0.map(String.init) ?? "nil")") })

        waitUntil { order.values == ["first runs"] }
        XCTAssertEqual(queue.waitingCount, 1)
        XCTAssertFalse(second.isRunning)
        gate.signal()
        waitUntil { order.values.count == 4 }
        XCTAssertEqual(order.values, ["first runs", "first done", "second runs", "second done 2"])
    }

    /// A waiting run leaves the line and never runs; a run under way is
    /// told to stop through its cancellation.
    @MainActor
    func testRunsAreCancelledWaitingOrUnderWay() {
        let queue = ExplainQueue()
        let order = Order()
        let first = queue.submit({ cancellation in
            order.append("first runs")
            while !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
            return "stopped"
        }, completion: { order.append("first \($0 ?? "nil")") })
        let second = queue.submit({ _ in
            order.append("second runs")
            return "ran"
        }, completion: { order.append("second \($0 ?? "nil")") })

        waitUntil { order.values == ["first runs"] }
        second.cancel()
        XCTAssertEqual(order.values, ["first runs", "second nil"])
        XCTAssertEqual(queue.waitingCount, 0)
        XCTAssertTrue(first.isRunning)
        first.cancel()
        waitUntil { order.values.count == 3 }
        XCTAssertEqual(order.values, ["first runs", "second nil", "first stopped"])
    }

    /// A run a completion submits waits behind those already waiting, and
    /// the next run starts once the completion returned.
    @MainActor
    func testTheNextRunStartsAfterTheCompletion() {
        let queue = ExplainQueue()
        let gate = DispatchSemaphore(value: 0)
        let order = Order()
        queue.submit({ _ in
            gate.wait()
            return "a"
        }, completion: { _ in
            order.append("a done begins")
            queue.submit({ _ in "c" }, onStart: { order.append("c starts") }, completion: { _ in order.append("c done") })
            order.append("a done ends")
        })
        queue.submit({ _ in "b" }, onStart: { order.append("b starts") }, completion: { _ in order.append("b done") })
        gate.signal()
        waitUntil { order.values.count == 6 }
        XCTAssertEqual(order.values, ["a done begins", "a done ends", "b starts", "b done", "c starts", "c done"])
    }

    /// Nirux quits: every run, waiting or under way, stops.
    @MainActor
    func testCancelAllStopsEveryRun() {
        let queue = ExplainQueue()
        let order = Order()
        queue.submit({ cancellation in
            while !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
            return "stopped"
        }, onStart: { order.append("first starts") }, completion: { order.append("first \($0 ?? "nil")") })
        queue.submit({ _ in "ran" }, completion: { order.append("second \($0 ?? "nil")") })
        waitUntil { order.values == ["first starts"] }
        queue.cancelAll()
        waitUntil { order.values.count == 3 }
        XCTAssertEqual(order.values, ["first starts", "second nil", "first stopped"])
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition())
    }
}

/// Appended from the runs' threads and the main actor.
private final class Order: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ value: String) {
        lock.withLock { stored.append(value) }
    }

    var values: [String] { lock.withLock { stored } }
}
