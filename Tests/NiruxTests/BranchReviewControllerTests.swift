import AppKit
import WebKit
import XCTest
@testable import Nirux

/// The column's reads, against its real page: reads that overlap, a diff
/// read for an earlier snapshot, and what the page says when there is no
/// branch to show. Readers answer off the main thread, as git does.
final class BranchReviewControllerTests: XCTestCase {
    /// The user opens a file read on demand, then refreshes before it
    /// comes: the new snapshot lists another file under that id, and the
    /// old diff must not show under it.
    @MainActor
    func testADiffReadForAnEarlierSnapshotIsDropped() throws {
        let first = BranchReviewPageTests.snapshot()
        var added = BranchReview.FileChange(path: "AAA.swift", status: .added)
        added.additions = 1
        added.patchHash = "h"
        let second = Self.snapshot(first, files: [added] + first.files)
        let reads = Answers(answers: [(.snapshot(first), nil), (.snapshot(second), nil)])
        let gate = Gate()
        var lockfile = first.files[1]
        lockfile.omission = nil
        lockfile.hunks = [.init(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, section: "", lines: [
            .init(kind: .removed, text: "old"), .init(kind: .added, text: "new")
        ])]
        let read = lockfile
        let page = try ReviewPage(reader: { _, _, _ in reads.next() }, patchReader: { file, _ in
            gate.wait()
            return file.path == read.path ? read : nil
        })
        defer { page.close() }
        _ = try page.run("""
            document.querySelector(".group.folded .group-header").click();
            document.querySelector('.file[data-id="1"] .file-row').click();
            return "";
            """)
        page.controller.reload(fetchBase: true)
        try page.waitForPage()
        // The new page opens the lockfile again, under its new id.
        gate.open(times: 2)
        let result = try page.run("""
            const lines = (id) => [...(document.querySelector(`.file[data-id="${id}"] diffs-container`)?.shadowRoot?.querySelectorAll("[data-line]") ?? [])];
            const deadline = Date.now() + 10000;
            while (lines(2).length === 0 && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
            await new Promise((resolve) => setTimeout(resolve, 200));
            const row = (id) => document.querySelector(`.file[data-id="${id}"]`);
            return JSON.stringify({
              path1: row(1).querySelector(".path").textContent, diff1: row(1).querySelector(".diff").childElementCount,
              path2: row(2).querySelector(".path").textContent, lines2: lines(2).map((line) => line.textContent)
            });
            """)
        // Row 1 never opened in the new page: nothing went into it.
        XCTAssertEqual(result, #"{"path1":"Sources/KeepAwake.swift","diff1":0,"path2":"Package.resolved","lines2":["old","new"]}"#)
    }

    /// The page drops a diff for another of its generations, or for another
    /// file than its row's, whatever Swift sends.
    @MainActor
    func testThePageDropsADiffThatIsntItsRows() throws {
        let page = try ReviewPage(snapshot: BranchReviewPageTests.snapshot(), handover: nil)
        defer { page.close() }
        let result = try page.run("""
            document.querySelector('.file[data-id="0"] .file-row').click();
            const deadline = Date.now() + 10000;
            const box = () => document.querySelector('.file[data-id="0"] .diff');
            while (!box().querySelector("diffs-container") && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
            const before = box().querySelectorAll("diffs-container").length;
            const hunks = [{ oldStart: 1, newStart: 1, section: "", lines: [{ kind: "added", text: "stale" }] }];
            const generation = 1;
            NiruxReview.showDiff(JSON.stringify({ id: 0, path: "Sources/KeepAwake.swift", generation: generation + 1, hunks }));
            NiruxReview.showDiff(JSON.stringify({ id: 0, path: "Other.swift", generation, hunks }));
            const lines = [...box().querySelector("diffs-container").shadowRoot.querySelectorAll("[data-line]")].map((line) => line.textContent);
            return JSON.stringify({ before, lines });
            """)
        XCTAssertEqual(result, #"{"before":1,"lines":["import IOKit","let a = 1","let a = 2"]}"#)
    }

    /// Refresh during a read: once it ends, one more read, with a fetch.
    @MainActor
    func testRefreshDuringAReadReadsOnceMoreWithAFetch() throws {
        let gate = Gate()
        let fetches = Recorder<Bool>()
        let page = try ReviewPage(reader: { _, fetchBase, _ in
            if fetches.append(fetchBase) == 1 { gate.wait() }
            return (.snapshot(BranchReviewPageTests.snapshot()), nil)
        }, waitsForPage: false)
        defer { page.close() }
        page.controller.reload(fetchBase: true)
        page.controller.reload(fetchBase: true)
        XCTAssertTrue(page.controller.isReading)
        gate.open(times: 1)
        page.waitUntil("both reads") { fetches.values.count == 2 && !page.controller.isReading }
        try page.waitForPage()
        XCTAssertEqual(fetches.values, [false, true])
    }

    @MainActor
    func testWithoutABranchToShowThePageSaysWhy() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        let reads = Answers(answers: [
            (.snapshot(snapshot), nil), (.paused(.rebase), nil), (.snapshot(snapshot), nil),
            (.snapshot(Self.snapshot(snapshot, branch: "other")), nil)
        ])
        let page = try ReviewPage(reader: { _, _, _ in reads.next() })
        defer { page.close() }
        page.controller.reload()
        page.waitUntil("the pause") { page.controller.snapshot == nil && !page.controller.isReading }
        XCTAssertEqual(try Self.shown(page), #"{"page":false,"status":"A rebase is in progress in this worktree. The review comes back once it’s over.","action":null}"#)

        page.controller.reload()
        try page.waitForPage()
        XCTAssertEqual(try Self.shown(page), #"{"page":true,"status":null,"action":null}"#)

        // Another branch: the column offers to review it instead.
        page.controller.reload()
        page.waitUntil("the switch") { page.controller.snapshot == nil && !page.controller.isReading }
        XCTAssertEqual(try Self.shown(page), #"{"page":false,"status":"The worktree is on other now, not feat/keep-awake.","action":"Review other"}"#)
        XCTAssertEqual(page.controller.branch, "feat/keep-awake")
        _ = try page.run("document.querySelector('#status .action').click(); return '';")
        page.waitUntil("the other branch") { page.controller.snapshot?.branch == "other" }
        try page.waitForPage()
        XCTAssertEqual(page.controller.branch, "other")
        XCTAssertEqual(try Self.shown(page), #"{"page":true,"status":null,"action":null}"#)
    }

    @MainActor
    func testRefreshDropsAHandoverDeletedSince() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        let reads = Answers(answers: [
            (.snapshot(snapshot), .init(name: ".claude-handover.md", text: "Notes", isCut: false)), (.snapshot(snapshot), nil)
        ])
        let page = try ReviewPage(reader: { _, _, _ in reads.next() })
        defer { page.close() }
        let sources = "return JSON.stringify([...document.querySelectorAll('.source span')].map((s) => s.textContent));"
        XCTAssertEqual(try page.run(sources), #"[".claude-handover.md","2 commits"]"#)
        page.controller.reload()
        page.waitUntil("the second read") { !page.controller.isReading }
        try page.waitForPage()
        XCTAssertEqual(try page.run(sources), #"["2 commits"]"#)
    }

    /// A page that fails to show leaves no earlier page up as if it were
    /// this one: its rows' ids would be another snapshot's.
    @MainActor
    func testAPageThatFailsToShowSaysSoInsteadOfTheOldOne() throws {
        let page = try ReviewPage(snapshot: BranchReviewPageTests.snapshot(), handover: nil)
        defer { page.close() }
        page.controller.view.show(pageJSON: #"{"header":null}"#)
        let result = try page.run("""
            const deadline = Date.now() + 10000;
            while (!document.getElementById("status").classList.contains("shown") && Date.now() < deadline) {
              await new Promise((resolve) => setTimeout(resolve, 20));
            }
            return JSON.stringify({ hidden: document.getElementById("page").hidden, status: document.getElementById("status").textContent });
            """)
        let shown = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertEqual(shown["hidden"] as? Bool, true)
        XCTAssertTrue((shown["status"] as? String)?.hasPrefix("The page couldn’t show this review: ") == true, "\(shown)")
    }

    /// A review that crashes the page's process doesn't reload it forever:
    /// the second time, the column says why, until Refresh.
    @MainActor
    func testAPageThatKeepsCrashingStopsReloading() throws {
        let page = try ReviewPage(snapshot: BranchReviewPageTests.snapshot(), handover: nil)
        defer { page.close() }
        let view = page.controller.view
        let webView = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        let status = "return document.getElementById('status').classList.contains('shown') ? document.getElementById('status').textContent : ''"
        // Once: the page loads again, and shows the review.
        view.webViewWebContentProcessDidTerminate(webView)
        page.waitUntil("the page again") { view.isPageReady }
        try page.waitForPage()
        XCTAssertEqual(try page.run(status), "")
        // Twice, even with the page shown in between: it could die while
        // laying the review out.
        view.webViewWebContentProcessDidTerminate(webView)
        page.waitUntil("the page again") { view.isPageReady }
        page.waitUntil("the reason") { (try? page.run(status)) == "The review page stopped while showing this branch. Refresh to try again." }

        view.onRefresh?()
        page.waitUntil("the refresh") { !page.controller.isReading }
        try page.waitForPage()
        XCTAssertEqual(try page.run(status), "")
    }

    /// The page's process dies while a file's diff is read: the diff that
    /// comes during the reload has no row to go to, and the page that
    /// loads again still shows the review.
    @MainActor
    func testTheReviewComesBackWhenThePageDiesDuringADiffRead() throws {
        let gate = Gate()
        let snapshot = BranchReviewPageTests.snapshot()
        let page = try ReviewPage(snapshot: snapshot, handover: nil, patchReader: { file, _ in
            gate.wait()
            return file
        })
        defer { page.close() }
        _ = try page.run("""
            document.querySelector(".group.folded .group-header").click();
            document.querySelector('.file[data-id="1"] .file-row').click();
            return "";
            """)
        let view = page.controller.view
        let webView = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        view.webViewWebContentProcessDidTerminate(webView)
        gate.open(times: 1)
        page.waitUntil("the page again") { view.isPageReady }
        try page.waitForPage()
        XCTAssertEqual(try page.run("return String(document.querySelectorAll('.file').length)"), "2")
    }

    // MARK: - Helpers

    /// Whether the page shows, and the status and its button otherwise.
    @MainActor
    static func shown(_ page: ReviewPage) throws -> String {
        try page.run("""
            const status = document.getElementById("status");
            return JSON.stringify({
              page: !document.getElementById("page").hidden && getComputedStyle(document.getElementById("page")).display !== "none",
              status: status.classList.contains("shown") ? status.firstChild.textContent : null,
              action: status.classList.contains("shown") ? (status.querySelector(".action")?.textContent ?? null) : null
            });
            """)
    }

    static func snapshot(
        _ base: BranchReview.Snapshot, branch: String? = nil, files: [BranchReview.FileChange]? = nil
    ) -> BranchReview.Snapshot {
        BranchReview.Snapshot(
            root: base.root, branch: branch ?? base.branch, head: base.head, base: base.base,
            pullRequest: base.pullRequest, fetchProblem: base.fetchProblem, upstream: base.upstream,
            pullRequestHead: base.pullRequestHead, hasUncommittedChanges: base.hasUncommittedChanges,
            commits: base.commits, files: files ?? base.files, testsAgainstCode: base.testsAgainstCode
        )
    }

    /// A reader's answers in turn; the last one again once they run out.
    final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [(BranchReview.Outcome, BranchReview.Handover?)]

        init(answers: [(BranchReview.Outcome, BranchReview.Handover?)]) {
            self.answers = answers
        }

        func next() -> (BranchReview.Outcome, BranchReview.Handover?) {
            lock.lock()
            defer { lock.unlock() }
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
    }

    /// Holds a background read until the test lets it go.
    final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)

        func wait() {
            XCTAssertFalse(Thread.isMainThread)
            _ = semaphore.wait(timeout: .now() + 30)
        }

        func open(times: Int) {
            for _ in 0..<times { semaphore.signal() }
        }
    }

    final class Recorder<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Value] = []

        /// The count once added.
        func append(_ value: Value) -> Int {
            lock.lock()
            defer { lock.unlock() }
            stored.append(value)
            return stored.count
        }

        var values: [Value] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}
