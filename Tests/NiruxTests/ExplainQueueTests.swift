import XCTest
@testable import Nirux

/// One Explain run at a time in the whole app (docs/design/branch-review.md,
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

        waitUntil("only “first runs” (saw \(order.values))", timeout: 10) { order.values == ["first runs"] }
        XCTAssertEqual(queue.waitingCount, 1)
        XCTAssertFalse(second.isRunning)
        gate.signal()
        waitUntil("4 steps (saw \(order.values))", timeout: 10) { order.values.count == 4 }
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

        waitUntil("only “first runs” (saw \(order.values))", timeout: 10) { order.values == ["first runs"] }
        second.cancel()
        XCTAssertEqual(order.values, ["first runs", "second nil"])
        XCTAssertEqual(queue.waitingCount, 0)
        XCTAssertTrue(first.isRunning)
        first.cancel()
        waitUntil("3 steps (saw \(order.values))", timeout: 10) { order.values.count == 3 }
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
        waitUntil("6 steps (saw \(order.values))", timeout: 10) { order.values.count == 6 }
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
        waitUntil("only “first starts” (saw \(order.values))", timeout: 10) { order.values == ["first starts"] }
        queue.cancelAll()
        waitUntil("3 steps (saw \(order.values))", timeout: 10) { order.values.count == 3 }
        XCTAssertEqual(order.values, ["first starts", "second nil", "first stopped"])
    }

    /// Quitting waits, a bounded time, for the run under way to return: the
    /// main thread can't take its completion then, and its claude would
    /// run on.
    @MainActor
    func testCancelAllWaitsForTheRunUnderWay() {
        let queue = ExplainQueue()
        let order = Order()
        queue.submit({ cancellation in
            while !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
            Thread.sleep(forTimeInterval: 0.2)
            order.append("returned")
            return 1
        }, onStart: { order.append("starts") }, completion: { _ in })
        waitUntil("only “starts” (saw \(order.values))", timeout: 10) { order.values == ["starts"] }
        queue.cancelAll(waitingUpTo: 5)
        XCTAssertEqual(order.values, ["starts", "returned"])
    }

    /// Clean Up stops the worktree's runs and waits for the one under way
    /// to return before it deletes the review file; the worktree takes no
    /// run until it resumes. Other worktrees' runs wait as before.
    @MainActor
    func testStoppingAWorktreeWaitsForItsRunAndRefusesNewOnes() {
        let queue = ExplainQueue()
        let order = Order()
        queue.submit(worktree: "/a", { cancellation in
            order.append("a runs")
            while !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
            Thread.sleep(forTimeInterval: 0.1)
            return "stopped"
        }, completion: { order.append("a \($0 ?? "nil")") })
        queue.submit(worktree: "/a", { _ in "ran" }, completion: { order.append("a2 \($0 ?? "nil")") })
        queue.submit(worktree: "/b", { _ in
            order.append("b runs")
            return "ran"
        }, completion: { order.append("b \($0 ?? "nil")") })
        waitUntil("only “a runs” (saw \(order.values))", timeout: 10) { order.values == ["a runs"] }

        queue.stop(worktree: "/a") { order.append("clean up") }
        XCTAssertEqual(order.values, ["a runs", "a2 nil"])
        XCTAssertEqual(queue.waitingCount, 1)
        queue.submit(worktree: "/a", { _ in "ran" }, completion: { order.append("a3 \($0 ?? "nil")") })
        XCTAssertEqual(order.values, ["a runs", "a2 nil", "a3 nil"])
        waitUntil("7 steps (saw \(order.values))", timeout: 10) { order.values.count == 7 }
        XCTAssertEqual(order.values, ["a runs", "a2 nil", "a3 nil", "a stopped", "clean up", "b runs", "b ran"])

        // Nothing under way for it: at once.
        var stoppedAgain = false
        queue.stop(worktree: "/a") { stoppedAgain = true }
        XCTAssertTrue(stoppedAgain)
        queue.resume(worktree: "/a")
        queue.submit(worktree: "/a", { _ in "ran" }, completion: { order.append("a4 \($0 ?? "nil")") })
        XCTAssertFalse(order.values.contains("a4 ran"), "still stopped once")
        queue.resume(worktree: "/a")
        queue.submit(worktree: "/a", { _ in "ran" }, completion: { order.append("a5 \($0 ?? "nil")") })
        waitUntil("“a5 ran” (saw \(order.values))", timeout: 10) { order.values.contains("a5 ran") }
        XCTAssertTrue(order.values.contains("a4 nil"))
    }

    /// Clean Up's own wait: it runs once the worktree's run returned, and
    /// the worktree takes runs again once it lets go, by the folder's
    /// resolved path.
    @MainActor
    func testCleanUpRunsOnceTheWorktreesExplainReturned() {
        let queue = ExplainQueue()
        let order = Order()
        queue.submit(worktree: ExplainQueue.worktreeKey("/w"), { cancellation in
            while !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
            Thread.sleep(forTimeInterval: 0.1)
            order.append("run returned")
            return 0
        }, onStart: { order.append("runs") }, completion: { _ in })
        waitUntil("only “runs” (saw \(order.values))", timeout: 10) { order.values == ["runs"] }
        var resume: (@MainActor () -> Void)?
        NiruxShellView.stoppingExplains(in: "/w/", queue: queue) { letGo in
            order.append("clean up")
            resume = letGo
        }
        waitUntil("3 steps (saw \(order.values))", timeout: 10) { order.values.count == 3 }
        XCTAssertEqual(order.values, ["runs", "run returned", "clean up"])
        queue.submit(worktree: ExplainQueue.worktreeKey("/w"), { _ in 1 }, completion: { order.append("refused \($0 == nil)") })
        XCTAssertEqual(order.values.last, "refused true")
        resume?()
        queue.submit(worktree: ExplainQueue.worktreeKey("/w"), { _ in 1 }, completion: { order.append("ran \($0 ?? 0)") })
        waitUntil("“ran 1” last (saw \(order.values))", timeout: 10) { order.values.last == "ran 1" }
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
