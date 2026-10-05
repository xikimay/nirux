import XCTest
@testable import Nirux

/// Explain from the page (docs/branch-review.md, section 4.3): claude and
/// its account checked, the user asked, one run at a time, Cancel, and
/// what Claude found shown as text. The run is a fake: no claude runs.
final class BranchReviewExplainFlowTests: XCTestCase {
    static let account = BranchReview.ExplainAccount(isLoggedIn: true, method: "claude.ai", subscription: "max", email: "dev@example.test")
    static let ready: BranchReviewController.ExplainChecker = { .ready(.init(path: "/fake/claude"), account) }
    static let explainButton = "[...document.querySelectorAll('#explain-bar button')].find((b) => b.textContent.startsWith('Explain'))"
    static let cancelButton = "[...document.querySelectorAll('#explain-bar button')].find((b) => b.textContent === 'Cancel')"

    /// The text of the first element `selector` matches, as a JavaScript
    /// expression.
    static func text(_ selector: String) -> String {
        "document.querySelector('\(selector)').textContent"
    }

    /// After the notice, the run explains the changed files with the
    /// account's rules; Claude's text shows as text, its groups replace the
    /// path groups and each file says what it does.
    @MainActor
    func testExplainAsksFirstThenShowsWhatClaudeFound() throws {
        let jobs = BranchReviewControllerTests.Recorder<BranchReview.ExplainJob>()
        var explained = BranchReviewExplainPageTests.explanation()
        explained.overview = "Holds an assertion <img src=x onerror=\"window.hacked = 1\">\nwhile agents work."
        explained.groups = [.init(intent: .behaviorChange, title: "Keep <b>awake</b>", paths: ["Sources/KeepAwake.swift"])]
        explained.files["Sources/KeepAwake.swift"] = .init(patchHash: "h0", summary: "Takes <i>one</i> assertion.", importance: 3)
        explained.claims = [.init(claim: "Released on quit.", verdict: .contradicts, evidence: "Never released.")]
        explained.questions = ["Why 60 s?"]
        let page = try ReviewPage(reader: BranchReviewPageTests.reader, explainChecker: Self.ready) { [explained] job, _, progress in
            _ = jobs.append(job)
            progress(.init(part: 1, parts: 1, run: .init(toolUses: 3, retries: 0)))
            return .init(ending: .explained, explanation: explained)
        }
        defer { page.close() }
        var asked: [String] = []
        page.controller.confirmExplain = { account, files, _ in
            asked.append("\(account.label) \(files)")
            return true
        }
        XCTAssertEqual(
            try page.waitFor("\(Self.explainButton) && !\(Self.explainButton).disabled", then: Self.text(".explain-status")),
            "Claude can read this branch and its repository, read-only, and explain it file by file: about a minute or two, "
                + "on claude.ai, Max."
        )

        _ = try page.run("\(Self.explainButton).click(); return ''")
        let overview = try page.waitFor("document.querySelector('.overview')", then: Self.text(".overview"))
        XCTAssertEqual(overview, "Holds an assertion <img src=x onerror=\"window.hacked = 1\">\nwhile agents work.")
        XCTAssertEqual(asked, ["claude.ai, Max 1"])
        XCTAssertEqual(jobs.values.map(\.fresh), [false])
        XCTAssertEqual(jobs.values.map(\.includeUntracked), [false])
        XCTAssertEqual(jobs.values.map(\.requiresSubscription), [true])
        XCTAssertEqual(try page.run("""
            return [...document.querySelectorAll('#page img, .overview *, .file-summary *, .group-title *, .claim *:not(div):not(span)')]
              .length + String(window.hacked)
            """), "0undefined")
        XCTAssertEqual(try page.run("return document.querySelector('.groups').previousElementSibling.textContent"), "Changes · by intent (Claude)")
        XCTAssertEqual(
            try page.run("return \(Self.text(".intent")) + ' ' + \(Self.text(".intent + .group-title"))"), "Behavior change Keep <b>awake</b>"
        )
        XCTAssertEqual(try page.run("return \(Self.text(".file-summary"))"), "Takes <i>one</i> assertion.")
        XCTAssertEqual(
            try page.run("return [...document.querySelectorAll('.claim')].map((c) => c.textContent).join('|')"),
            "ContradictsReleased on quit.Never released."
        )
        XCTAssertEqual(try page.run("return \(Self.text(".questions"))"), "Why 60 s?")
        XCTAssertEqual(try page.run("return \(Self.text(".explain-status"))"), "Explained by Claude at aaaaaaa · Opus 5.5")
        XCTAssertEqual(
            try page.run("return [...document.querySelectorAll('#explain-bar button')].map((b) => b.textContent).join('|')"), "Explain Again"
        )

        // Explain again: every file, without the cache as context. The
        // same answer leaves the page as it is.
        _ = try page.run("document.querySelector('.groups').dataset.mark = 'kept'; \(Self.explainButton).click(); return ''")
        page.waitUntil("the second run") { jobs.values.count == 2 }
        XCTAssertEqual(jobs.values.last?.fresh, true)
        _ = try page.waitFor("!\(Self.explainButton).disabled")
        XCTAssertEqual(try page.run("return document.querySelector('.groups').dataset.mark ?? 'redrawn'"), "kept")
    }

    /// Cancel stops the run under way, which keeps what it reported, and
    /// the bar says so; the header's pill shows while it runs.
    @MainActor
    func testCancelStopsTheRunAndTheBarSaysSo() throws {
        let page = try ReviewPage(reader: BranchReviewPageTests.reader, explainChecker: Self.ready) { _, cancellation, progress in
            progress(.init(part: 1, parts: 2, run: .init(toolUses: 12, retries: 1)))
            while !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
            return .init(ending: .stopped(.cancelled))
        }
        defer { page.close() }
        page.controller.confirmExplain = { _, _, _ in true }
        _ = try page.waitFor("\(Self.explainButton) && !\(Self.explainButton).disabled")
        _ = try page.run("\(Self.explainButton).click(); return ''")
        let progress = try page.waitFor(
            "document.querySelector('.explain-progress')?.textContent.includes('reads')",
            then: "document.querySelector('.explain-progress').textContent"
        )
        XCTAssertTrue(progress.hasPrefix("Explaining · part 1 of 2 · 12 reads · 1 retry (servers busy) · 0:0"), progress)
        XCTAssertEqual(page.controller.view.header.status?.text, "Explaining")

        _ = try page.run("\(Self.cancelButton).click(); return ''")
        XCTAssertEqual(
            try page.waitFor("document.querySelector('.explain-message')", then: Self.text(".explain-message")),
            "Explain stopped. What Claude finished is kept; Explain again sends the rest."
        )
        XCTAssertNil(page.controller.view.header.status)
    }

    /// The column closes: its Explain stops, waiting or under way.
    @MainActor
    func testClosingTheColumnStopsItsExplain() throws {
        let stopped = BranchReviewControllerTests.Recorder<Bool>()
        let page = try ReviewPage(reader: BranchReviewPageTests.reader, explainChecker: Self.ready) { _, cancellation, progress in
            progress(.init(part: 1, parts: 1, run: .init()))
            while !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
            _ = stopped.append(true)
            return .init(ending: .stopped(.cancelled))
        }
        page.controller.confirmExplain = { _, _, _ in true }
        _ = try page.waitFor("\(Self.explainButton) && !\(Self.explainButton).disabled")
        _ = try page.run("\(Self.explainButton).click(); return ''")
        _ = try page.waitFor("document.querySelector('.explain-progress')")
        page.close()
        page.waitUntil("the run to stop") { stopped.values == [true] }
    }

    /// Without a claude that can run, Explain is disabled with the reason;
    /// Refresh checks again.
    @MainActor
    func testExplainIsDisabledWithTheReasonUntilClaudeCanRun() throws {
        let availability = BranchReviewControllerTests.Recorder<BranchReview.ExplainAvailability>()
        _ = availability.append(.unavailable("claude isn’t logged in. Run claude in a terminal and log in, then Refresh."))
        // The check answers before the first read: the page keeps why.
        let page = try ReviewPage(reader: { path, fetch, known in
            Thread.sleep(forTimeInterval: 0.3)
            return BranchReviewPageTests.reader(path, fetch, known)
        }, explainChecker: { availability.values.last! })
        defer { page.close() }
        XCTAssertEqual(
            try page.waitFor("document.querySelector('.explain-message')", then: Self.text(".explain-message")),
            "claude isn’t logged in. Run claude in a terminal and log in, then Refresh."
        )
        XCTAssertEqual(try page.run("return String(\(Self.explainButton).disabled)"), "true")

        _ = availability.append(Self.ready())
        page.controller.view.onRefresh?()
        _ = try page.waitFor("!document.querySelector('.explain-message') && !\(Self.explainButton).disabled")
    }

    /// Declined, nothing runs. An account billed per call runs once
    /// accepted, without requiring a subscription; included untracked
    /// files are sent and counted.
    @MainActor
    func testTheNoticeDecidesAndTheAccountSetsTheRules() throws {
        let billed = BranchReview.ExplainAccount(isLoggedIn: true, method: "api_key", subscription: nil, email: nil)
        let jobs = BranchReviewControllerTests.Recorder<BranchReview.ExplainJob>()
        let page = try ReviewPage(
            reader: BranchReviewPageTests.reader, explainChecker: { .ready(.init(path: "/fake/claude"), billed) }
        ) { job, _, _ in
            _ = jobs.append(job)
            return .init(ending: .nothingToSend)
        }
        defer { page.close() }
        var answers = [false, true]
        var asked: [Int] = []
        var noticed: [String] = []
        page.controller.confirmExplain = { _, files, settings in
            asked.append(files)
            noticed.append("\(settings.model) \(settings.effort)")
            // Asked from the run loop, not from a main-queue block: the
            // notice's modal loop would hold every other one.
            var drained = false
            DispatchQueue.main.async { drained = true }
            let deadline = Date().addingTimeInterval(5)
            while !drained, Date() < deadline { RunLoop.current.run(mode: .modalPanel, before: deadline) }
            XCTAssertTrue(drained)
            return answers.removeFirst()
        }
        _ = try page.waitFor("document.querySelector('.explain-untracked input') && !\(Self.explainButton).disabled")
        _ = try page.run("\(Self.explainButton).click(); return ''")
        page.waitUntil("the notice") { asked.count == 1 }
        _ = try page.waitFor("!\(Self.explainButton).disabled")
        XCTAssertEqual(jobs.values.count, 0)

        _ = try page.run("document.querySelector('.explain-untracked input').click(); return ''")
        _ = try page.waitFor("document.querySelector('.explain-untracked input').checked")
        // Settings' model and effort, read once: the notice names what
        // the run asks for, even if Settings changed right after.
        var reads = 0
        page.controller.explainSettings = {
            reads += 1
            var chosen = BranchReview.ExplainSettings()
            if reads == 1 {
                chosen.model = "claude-sonnet-5-5"
                chosen.effort = "high"
            }
            return chosen
        }
        _ = try page.run("\(Self.explainButton).click(); return ''")
        page.waitUntil("the run") { jobs.values.count == 1 }
        XCTAssertEqual(asked, [1, 2])
        XCTAssertEqual(jobs.values.first?.requiresSubscription, false)
        XCTAssertEqual(jobs.values.first?.includeUntracked, true)
        XCTAssertEqual(jobs.values.first.map { [$0.settings.model, $0.settings.effort] }, ["claude-sonnet-5-5", "high"])
        // The notice named what the run asks for.
        XCTAssertEqual(noticed.last, "claude-sonnet-5-5 high")
        XCTAssertEqual(
            try page.waitFor("document.querySelector('.explain-message')", then: Self.text(".explain-message")),
            "Nothing for Claude to read: only folded, binary, secret or untracked files changed."
        )
    }

    /// What Explain kept shows with the branch, before any click; a new
    /// explanation waits for the user's selection to go.
    @MainActor
    func testAKeptExplanationShowsAndANewOneWaitsForTheSelection() throws {
        var kept = BranchReviewExplainPageTests.explanation()
        kept.overview = "Kept."
        kept.files["Sources/KeepAwake.swift"] = .init(patchHash: "h0", summary: "S.", importance: 1)
        var fresh = kept
        fresh.overview = "Fresh."
        let runs = BranchReviewControllerTests.Recorder<Bool>()
        let page = try ReviewPage(
            reader: BranchReviewPageTests.reader, explanationReader: { [kept] _ in kept }, explainChecker: Self.ready
        ) { [fresh] job, _, _ in
            _ = runs.append(job.fresh)
            return .init(ending: .explained, explanation: fresh)
        }
        defer { page.close() }
        page.controller.confirmExplain = { _, _, _ in true }
        XCTAssertEqual(try page.waitFor("document.querySelector('.overview')", then: Self.text(".overview")), "Kept.")

        page.controller.view.onSelection?(true)
        _ = try page.waitFor("!\(Self.explainButton).disabled")
        _ = try page.run("\(Self.explainButton).click(); return ''")
        page.waitUntil("the run") { runs.values == [true] }
        _ = try page.waitFor("\(Self.explainButton).textContent === 'Explain Again' && !\(Self.explainButton).disabled")
        XCTAssertEqual(try page.run("return document.querySelector('.overview').textContent"), "Kept.")
        page.controller.view.onSelection?(false)
        XCTAssertEqual(
            try page.waitFor("document.querySelector('.overview').textContent === 'Fresh.'", then: "document.querySelector('.overview').textContent"),
            "Fresh."
        )
    }

    /// A read that began before an Explain ended keeps what that Explain
    /// found, for its branch only: a page of another branch shows its own.
    @MainActor
    func testAReadDuringAnExplainKeepsItsResultForItsBranchOnly() throws {
        let branchA = BranchReviewExplainPageTests.snapshot()
        let branchB = BranchReviewExplainPageTests.snapshot(branch: "feat/other")
        let readGate = DispatchSemaphore(value: 0)
        let explainGate = DispatchSemaphore(value: 0)
        let script = ReadScript([(branchA, nil), (branchA, readGate), (branchB, nil), (branchB, readGate)])
        var kept = BranchReviewExplainPageTests.explanation()
        kept.overview = "Kept."
        let runs = BranchReviewControllerTests.Recorder<Bool>()
        let page = try ReviewPage(
            reader: { _, _, _ in (.snapshot(script.next()), nil) },
            explanationReader: { [kept] snapshot in snapshot.branch == "feat/keep-awake" ? kept : nil },
            explainChecker: Self.ready
        ) { [kept] _, _, _ in
            explainGate.wait()
            var found = kept
            let first = runs.append(true) == 1
            found.overview = first ? "Found." : "Found again."
            return .init(ending: first ? .explained : .stopped(.usageLimit(resetsAt: nil)), explanation: found)
        }
        defer { page.close() }
        page.controller.confirmExplain = { _, _, _ in true }
        _ = try page.waitFor("!\(Self.explainButton).disabled")

        // The same branch: the read finds what was kept before the run.
        _ = try page.run("\(Self.explainButton).click(); return ''")
        _ = try page.waitFor("document.querySelector('.explain-progress')")
        page.controller.reload()
        explainGate.signal()
        page.waitUntil("the run's explanation") { page.controller.explanation?.overview == "Found." }
        readGate.signal()
        page.waitUntil("the read") { !page.controller.isReading }
        XCTAssertEqual(page.controller.explanation?.overview, "Found.")
        XCTAssertEqual(try page.waitFor("document.querySelector('.overview')", then: Self.text(".overview")), "Found.")

        // The worktree moves to another branch during a run; reviewing it
        // shows none of the run's findings.
        _ = try page.waitFor("!\(Self.explainButton).disabled")
        _ = try page.run("\(Self.explainButton).click(); return ''")
        _ = try page.waitFor("document.querySelector('.explain-progress')")
        page.controller.reload()
        page.waitUntil("the other branch's status") { page.controller.snapshot == nil && !page.controller.isReading }
        page.controller.view.onStatusAction?()
        explainGate.signal()
        page.waitUntil("the run's explanation") { page.controller.explanation?.overview == "Found again." }
        readGate.signal()
        page.waitUntil("the other branch") { page.controller.snapshot?.branch == "feat/other" }
        XCTAssertNil(page.controller.explanation)
        // Nor how it ended: that was the other branch's run.
        _ = try page.waitFor(
            "document.querySelector('.groups') && !document.querySelector('.overview') && !document.querySelector('.explain-message')"
        )
    }

    /// A new head read during the run waits behind the Reload banner with
    /// what the run found, not what was kept before it.
    @MainActor
    func testANewHeadWaitingBehindTheBannerGetsTheRunsExplanation() throws {
        let moved = BranchReviewExplainPageTests.snapshot(head: String(repeating: "b", count: 40))
        let script = ReadScript([(BranchReviewExplainPageTests.snapshot(), nil), (moved, nil)])
        let explainGate = DispatchSemaphore(value: 0)
        var kept = BranchReviewExplainPageTests.explanation()
        kept.overview = "Kept."
        let page = try ReviewPage(
            reader: { _, _, _ in (.snapshot(script.next()), nil) }, explanationReader: { [kept] _ in kept }, explainChecker: Self.ready
        ) { [kept] _, _, _ in
            explainGate.wait()
            var found = kept
            found.overview = "Found."
            return .init(ending: .explained, explanation: found)
        }
        defer { page.close() }
        page.controller.confirmExplain = { _, _, _ in true }
        _ = try page.waitFor("!\(Self.explainButton).disabled")
        _ = try page.run("\(Self.explainButton).click(); return ''")
        _ = try page.waitFor("document.querySelector('.explain-progress')")
        page.controller.worktreeChanged(.metadata)
        page.waitUntil("the new head behind the banner") { page.controller.pending != nil }
        explainGate.signal()
        page.waitUntil("the run's explanation") { page.controller.explanation?.overview == "Found." }
        page.controller.view.onReload?()
        page.waitUntil("the new head") { page.controller.snapshot?.head == moved.head }
        XCTAssertEqual(page.controller.explanation?.overview, "Found.")
    }

    /// Clean Up stops the worktree's Explain and refuses new ones until it
    /// is over; the bar says why.
    @MainActor
    func testCleanUpStopsTheWorktreesExplainAndRefusesNewOnes() throws {
        let queue = ExplainQueue()
        let runs = BranchReviewControllerTests.Recorder<Bool>()
        let page = try ReviewPage(
            reader: BranchReviewPageTests.reader, explainChecker: Self.ready,
            explainer: { _, cancellation, progress in
                _ = runs.append(true)
                progress(.init(part: 1, parts: 1, run: .init()))
                while !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
                return .init(ending: .stopped(.cancelled))
            },
            explainQueue: queue
        )
        defer { page.close() }
        page.controller.confirmExplain = { _, _, _ in true }
        _ = try page.waitFor("!\(Self.explainButton).disabled")
        _ = try page.run("\(Self.explainButton).click(); return ''")
        _ = try page.waitFor("document.querySelector('.explain-progress')")

        var cleaning = false
        queue.stop(worktree: ExplainQueue.worktreeKey("/repo/")) { cleaning = true }
        XCTAssertEqual(
            try page.waitFor("document.querySelector('.explain-message')", then: Self.text(".explain-message")),
            "Explain stopped: this worktree is being cleaned up."
        )
        XCTAssertTrue(cleaning)
        _ = try page.run("\(Self.explainButton).click(); return ''")
        XCTAssertEqual(
            try page.waitFor(
                "document.querySelector('.explain-message')?.textContent.startsWith('Explain didn')",
                then: "document.querySelector('.explain-message').textContent"
            ),
            "Explain didn’t run: this worktree is being cleaned up."
        )
        XCTAssertEqual(runs.values.count, 1)

        queue.resume(worktree: ExplainQueue.worktreeKey("/repo"))
        _ = try page.run("\(Self.explainButton).click(); return ''")
        page.waitUntil("the run") { runs.values.count == 2 }
    }

    /// A column closing while its Explain waits in line takes it out of the
    /// line; the run under way, another column's, goes on.
    @MainActor
    func testClosingAColumnWhoseExplainWaitsLeavesTheLine() throws {
        let queue = ExplainQueue()
        let runs = BranchReviewControllerTests.Recorder<String>()
        func page(_ name: String) throws -> ReviewPage {
            let page = try ReviewPage(
                reader: BranchReviewPageTests.reader, explainChecker: Self.ready,
                explainer: { _, cancellation, progress in
                    _ = runs.append("\(name) runs")
                    progress(.init(part: 1, parts: 1, run: .init()))
                    while !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
                    _ = runs.append("\(name) stopped")
                    return .init(ending: .stopped(.cancelled))
                },
                explainQueue: queue
            )
            page.controller.confirmExplain = { _, _, _ in true }
            _ = try page.waitFor("!\(Self.explainButton).disabled")
            _ = try page.run("\(Self.explainButton).click(); return ''")
            return page
        }
        let first = try page("first")
        _ = try first.waitFor("document.querySelector('.explain-progress')")
        let second = try page("second")
        _ = try second.waitFor("document.querySelector('.explain-status')?.textContent.startsWith('Waiting')")
        XCTAssertEqual(second.controller.view.header.status?.text, "Queued")
        second.close()
        XCTAssertEqual(queue.waitingCount, 0)
        XCTAssertEqual(runs.values, ["first runs"])
        first.close()
        first.waitUntil("the run to stop") { runs.values == ["first runs", "first stopped"] }
    }
}

/// The snapshots a column's reads find, in turn, the last one again; a
/// gate holds a read until a test lets it go.
private final class ReadScript: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [(BranchReview.Snapshot, DispatchSemaphore?)]

    init(_ answers: [(BranchReview.Snapshot, DispatchSemaphore?)]) {
        self.answers = answers
    }

    func next() -> BranchReview.Snapshot {
        let (snapshot, gate) = lock.withLock { answers.count > 1 ? answers.removeFirst() : answers[0] }
        gate?.wait()
        return snapshot
    }
}
