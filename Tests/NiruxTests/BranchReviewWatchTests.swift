import AppKit
import WebKit
import XCTest
@testable import Nirux

/// The column follows its worktree (docs/branch-review.md, section 7): a
/// change reads the branch again once changes stop; the same head updates
/// the page, a new head waits behind a Reload banner; off screen, the
/// column only marks itself stale. The watcher is faked: tests report
/// changes as it would.
final class BranchReviewWatchTests: XCTestCase {
    /// An uncommitted file appears at the same head: the page shows it,
    /// without a banner, and an open diff whose patch didn't change stays
    /// as it was.
    @MainActor
    func testAChangeAtTheSameHeadUpdatesThePageAndKeepsOpenDiffs() throws {
        let first = BranchReviewPageTests.snapshot()
        var added = BranchReview.FileChange(path: "Sources/Later.swift", status: .added)
        added.additions = 3
        added.isUntracked = true
        added.isUncommitted = true
        added.patchHash = "later"
        let reads = BranchReviewControllerTests.Answers(answers: [
            (.snapshot(first), nil), (.snapshot(BranchReviewControllerTests.snapshot(first, files: first.files + [added])), nil)
        ])
        let page = try ReviewPage(reader: { _, _, _ in reads.next() })
        defer { page.close() }
        _ = try page.run("""
            document.querySelector('.file[data-id="0"] .file-row').click();
            const deadline = Date.now() + 10000;
            while (!document.querySelector('.file[data-id="0"] diffs-container') && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
            document.querySelector('.file[data-id="0"] .diff-box').marked = true;
            return "";
            """)
        // Read inside the open diff, below the top: it stays where it is,
        // though the header grew.
        let top = "return String(Math.round(document.querySelector('.file[data-id=\"0\"]').getBoundingClientRect().top));"
        _ = try page.run("document.body.style.minHeight = '4000px'; window.scrollTo(0, 600); return '';")
        let before = try page.run(top)
        page.controller.worktreeChanged(.worktree)
        page.waitUntil("the second read") { page.controller.snapshot?.files.count == 4 }
        try page.waitForPage()
        let result = try page.run("""
            const box = document.querySelector('.file[data-id="0"] .diff-box');
            return JSON.stringify({
              files: document.querySelectorAll(".file").length, banner: !document.getElementById("banner").hidden,
              kept: box?.marked === true, loading: document.querySelector('.file[data-id="0"] .diff').textContent.includes("Loading")
            });
            """)
        // The folded lockfile's row isn't built: two rows, and the new one.
        XCTAssertEqual(result, #"{"files":3,"banner":false,"kept":true,"loading":false}"#)
        XCTAssertEqual(try page.run(top), before)
    }

    /// A new head never re-renders the page under the user: it stays, and a
    /// banner offers the new one.
    @MainActor
    func testANewHeadWaitsBehindTheReloadBanner() throws {
        let first = BranchReviewPageTests.snapshot()
        let second = Self.snapshot(first, head: String(repeating: "d", count: 40), newCommit: "feat: one more")
        let reads = BranchReviewControllerTests.Answers(answers: [(.snapshot(first), nil), (.snapshot(second), nil)])
        let page = try ReviewPage(reader: { _, _, _ in reads.next() })
        defer { page.close() }
        page.controller.worktreeChanged(.metadata)
        page.waitUntil("the banner") { page.controller.pending != nil }
        XCTAssertEqual(page.controller.snapshot?.head, first.head)
        let banner = "return document.getElementById('banner').hidden ? 'hidden' : document.querySelector('#banner span').textContent;"
        page.waitUntil("the banner on the page") { (try? page.run(banner)) == "The branch moved to ddddddd: 1 new commit." }
        XCTAssertEqual(try page.run("return document.querySelector('.meta .mono').textContent;"), "aaaaaaa")

        _ = try page.run("document.querySelector('#banner .action').click(); return '';")
        page.waitUntil("the new head") { page.controller.snapshot?.head == second.head }
        try page.waitForPage()
        XCTAssertEqual(try page.run(banner), "hidden")
        XCTAssertEqual(try page.run("return document.querySelector('.meta .mono').textContent;"), "ddddddd")
    }

    /// Off screen, a change only marks the column stale; it reads once it
    /// shows.
    @MainActor
    func testOffScreenTheColumnOnlyMarksItselfStale() throws {
        let reads = BranchReviewControllerTests.Recorder<Bool>()
        let page = try ReviewPage(reader: { _, fetchBase, _ in
            _ = reads.append(fetchBase)
            return (.snapshot(BranchReviewPageTests.snapshot()), nil)
        })
        defer { page.close() }
        let onScreen = Flag()
        page.controller.isOnScreen = { onScreen.value }
        page.controller.worktreeChanged(.worktree)
        XCTAssertTrue(page.controller.isStale)
        RunLoop.main.run(until: Date().addingTimeInterval(page.controller.watchTiming.maxWait + 0.2))
        XCTAssertEqual(reads.values.count, 1, "read while off screen")

        onScreen.value = true
        // The metadata refresh calls it several times a second.
        for _ in 0..<5 { page.controller.becameVisible() }
        page.waitUntil("the read once it shows") { reads.values.count == 2 && !page.controller.isReading }
        RunLoop.main.run(until: Date().addingTimeInterval(page.controller.watchTiming.maxWait))
        XCTAssertEqual(reads.values, [false, false], "one read, without a fetch: the base is fetched on Refresh only")
        XCTAssertFalse(page.controller.isStale)
    }

    /// A burst of changes reads once, after it settles; a burst that never
    /// stops (a build) still reads at its max wait, twice as long after
    /// each read that found nothing new.
    @MainActor
    func testABurstReadsOnceAndAnEndlessOneStillReads() throws {
        let reads = BranchReviewControllerTests.Recorder<Date>()
        let page = try ReviewPage(reader: { _, _, _ in
            _ = reads.append(Date())
            return (.snapshot(BranchReviewPageTests.snapshot()), nil)
        })
        defer { page.close() }
        let timing = page.controller.watchTiming
        for _ in 0..<5 { page.controller.worktreeChanged(.worktree) }
        page.waitUntil("the read after the burst") { reads.values.count == 2 && !page.controller.isReading }
        RunLoop.main.run(until: Date().addingTimeInterval(timing.settle * 2))
        XCTAssertEqual(reads.values.count, 2)

        // Changes that never settle, past twice the max wait and twice
        // again: that read found nothing new either. A settle longer than
        // the run, so a slow machine's pause between changes doesn't read.
        page.controller.watchTiming.settle = 30
        let start = Date()
        while Date().timeIntervalSince(start) < timing.maxWait * 8 {
            page.controller.worktreeChanged(.worktree)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let times = reads.values
        XCTAssertEqual(times.count, 4, "a read at twice the max wait, then at four times")
        guard times.count == 4 else { return }
        XCTAssertGreaterThan(times[3].timeIntervalSince(times[2]), times[2].timeIntervalSince(start) * 1.4)
    }

    /// A column opened during a rebase watches already: the page comes
    /// back once it's over.
    @MainActor
    func testAColumnOpenedDuringARebaseComesBackOnceItsOver() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-review-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reads = BranchReviewControllerTests.Answers(answers: [
            (.paused(.rebase), nil), (.snapshot(BranchReviewPageTests.snapshot()), nil)
        ])
        let watched = BranchReviewControllerTests.Recorder<String>()
        let page = try ReviewPage(reader: { _, _, _ in reads.next() }, waitsForPage: false, makeWatcher: { layout, _, _ in
            _ = watched.append(layout.worktreeRoot)
            return nil
        }, worktree: root.appendingPathComponent("Sources").path)
        defer { page.close() }
        page.waitUntil("the pause") { !page.controller.isReading }
        page.waitUntil("the watcher") { !watched.values.isEmpty }
        XCTAssertEqual(watched.values, [try XCTUnwrap(root.path.realPath)], "the top level, before any snapshot")
        page.controller.worktreeChanged(.metadata)
        try page.waitForPage()
        XCTAssertEqual(try BranchReviewControllerTests.shown(page), #"{"page":true,"status":null,"action":null}"#)
    }

    /// A watched read that fails while the page shows the review (the agent
    /// committed during it) keeps the page, under a banner.
    @MainActor
    func testAFailedWatchedReadKeepsThePage() throws {
        let reads = BranchReviewControllerTests.Answers(answers: [
            (.snapshot(BranchReviewPageTests.snapshot()), nil), (.unavailable("feat/keep-awake kept moving while it was read."), nil)
        ])
        let page = try ReviewPage(reader: { _, _, _ in reads.next() })
        defer { page.close() }
        page.controller.worktreeChanged(.metadata)
        let banner = "return document.getElementById('banner').hidden ? 'hidden' : document.querySelector('#banner span').textContent;"
        page.waitUntil("the banner") {
            (try? page.run(banner)) == "Nirux couldn’t read the branch again: feat/keep-awake kept moving while it was read."
        }
        XCTAssertNotNil(page.controller.snapshot)
        XCTAssertEqual(try BranchReviewControllerTests.shown(page), #"{"page":true,"status":null,"action":null}"#)
    }

    /// A diff that failed to read isn't kept: the next page reads it again.
    @MainActor
    func testAFailedDiffIsReadAgainByTheNextPage() throws {
        let attempts = BranchReviewControllerTests.Recorder<String>()
        var lockfile = BranchReviewPageTests.snapshot().files[1]
        lockfile.omission = nil
        lockfile.hunks = [.init(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, section: "", lines: [
            .init(kind: .removed, text: "old"), .init(kind: .added, text: "new")
        ])]
        let read = lockfile
        let page = try ReviewPage(snapshot: BranchReviewPageTests.snapshot(), handover: nil, patchReader: { file, _ in
            attempts.append(file.path) == 1 ? nil : read
        })
        defer { page.close() }
        let open = """
            const row = () => document.querySelector('.file[data-id="1"]');
            if (!row()) document.querySelector(".group.folded .group-header").click();
            if (row().querySelector(".diff").hidden) row().querySelector(".file-row").click();
            const deadline = Date.now() + 10000;
            while (row().querySelector(".diff").textContent.includes("Loading") && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
            return row().querySelector(".diff diffs-container") ? "diff" : row().querySelector(".diff").textContent;
            """
        XCTAssertTrue(try page.run(open).hasPrefix("Nirux couldn’t read this file’s diff"))
        page.controller.reload()
        page.waitUntil("the refresh") { !page.controller.isReading }
        try page.waitForPage()
        page.waitUntil("the second attempt") { attempts.values.count == 2 }
        XCTAssertEqual(try page.run(open), "diff")
    }

    /// A rebase while the page shows the review: the page stays, under a
    /// banner; once it's over, the new head waits behind Reload.
    @MainActor
    func testARebaseNeverMovesThePageUnderTheUser() throws {
        let first = BranchReviewPageTests.snapshot()
        let rebased = Self.snapshot(first, head: String(repeating: "e", count: 40), newCommit: "feat: rebased")
        let reads = BranchReviewControllerTests.Answers(answers: [
            (.snapshot(first), nil), (.paused(.rebase), nil), (.snapshot(rebased), nil)
        ])
        let page = try ReviewPage(reader: { _, _, _ in reads.next() })
        defer { page.close() }
        page.controller.worktreeChanged(.metadata)
        page.waitUntil("the pause banner") {
            (try? page.run(Self.banner)) == "A rebase is in progress in this worktree. The review comes back once it’s over."
        }
        XCTAssertEqual(try BranchReviewControllerTests.shown(page), #"{"page":true,"status":null,"action":null}"#)
        XCTAssertEqual(page.controller.snapshot?.head, first.head)

        page.controller.worktreeChanged(.metadata)
        page.waitUntil("the new head") { page.controller.pending?.snapshot.head == rebased.head }
        page.waitUntil("the reload banner") { (try? page.run(Self.banner)) == "The branch moved to eeeeeee: 1 new commit." }
        _ = try page.run("document.querySelector('#banner .action').click(); return '';")
        page.waitUntil("the rebased page") { page.controller.snapshot?.head == rebased.head }
    }

    /// The worktree switches branch while the page shows the review: a
    /// banner offers to review the other one in this column.
    @MainActor
    func testAnotherBranchIsOfferedOverThePage() throws {
        let first = BranchReviewPageTests.snapshot()
        let other = BranchReviewControllerTests.snapshot(first, branch: "other")
        let reads = BranchReviewControllerTests.Answers(answers: [(.snapshot(first), nil), (.snapshot(other), nil)])
        let page = try ReviewPage(reader: { _, _, _ in reads.next() })
        defer { page.close() }
        page.controller.worktreeChanged(.metadata)
        page.waitUntil("the banner") { (try? page.run(Self.banner)) == "The worktree is on other now, not feat/keep-awake." }
        XCTAssertEqual(try page.run("return document.querySelector('#banner .action').textContent;"), "Review other")
        XCTAssertEqual(page.controller.branch, "feat/keep-awake")
        _ = try page.run("document.querySelector('#banner .action').click(); return '';")
        page.waitUntil("the other branch") { page.controller.branch == "other" }
        try page.waitForPage()
        XCTAssertEqual(try page.run(Self.banner), "hidden")
    }

    /// The worktree is back on what the page shows (a rebase aborted, the
    /// branch checked out again): the banner goes.
    @MainActor
    func testTheBannerGoesOnceTheWorktreeIsBack() throws {
        let first = BranchReviewPageTests.snapshot()
        let reads = BranchReviewControllerTests.Answers(answers: [
            (.snapshot(first), nil), (.paused(.rebase), nil), (.snapshot(first), nil)
        ])
        let page = try ReviewPage(reader: { _, _, _ in reads.next() })
        defer { page.close() }
        page.controller.worktreeChanged(.metadata)
        page.waitUntil("the pause banner") { (try? page.run(Self.banner)) != "hidden" }
        page.controller.worktreeChanged(.metadata)
        page.waitUntil("no banner") { (try? page.run(Self.banner)) == "hidden" }
    }

    /// "Review other" reads the worktree again: back on the reviewed
    /// branch since, the column keeps it.
    @MainActor
    func testReviewingTheOtherBranchChecksTheWorktreeFirst() throws {
        let first = BranchReviewPageTests.snapshot()
        let other = BranchReviewControllerTests.snapshot(first, branch: "other")
        let reads = BranchReviewControllerTests.Answers(answers: [(.snapshot(first), nil), (.snapshot(other), nil), (.snapshot(first), nil)])
        let page = try ReviewPage(reader: { _, _, _ in reads.next() })
        defer { page.close() }
        page.controller.worktreeChanged(.metadata)
        page.waitUntil("the banner") { (try? page.run(Self.banner)) == "The worktree is on other now, not feat/keep-awake." }
        _ = try page.run("document.querySelector('#banner .action').click(); return '';")
        page.waitUntil("no banner") { (try? page.run(Self.banner)) == "hidden" }
        XCTAssertFalse(page.controller.isReading)
        XCTAssertEqual(page.controller.branch, "feat/keep-awake")
    }

    /// A page at the same head keeps the row the reader is at where it
    /// was, though rows were added above it.
    @MainActor
    func testRowsAddedAboveTheReaderDontMoveIt() throws {
        let first = BranchReviewPageTests.snapshot()
        func file(_ name: String) -> BranchReview.FileChange {
            var file = BranchReview.FileChange(path: "Sources/Feature/\(name).swift", status: .added)
            file.additions = 1
            file.patchHash = name
            return file
        }
        let rows = (10..<70).map { file("F\($0)") }
        let reads = BranchReviewControllerTests.Answers(answers: [
            (.snapshot(BranchReviewControllerTests.snapshot(first, files: rows)), nil),
            (.snapshot(BranchReviewControllerTests.snapshot(first, files: ["A1", "A2", "A3"].map(file) + rows)), nil)
        ])
        let page = try ReviewPage(reader: { _, _, _ in reads.next() })
        defer { page.close() }
        let top = """
            const row = [...document.querySelectorAll(".file")].find((node) => node.dataset.path === "Sources/Feature/F40.swift");
            return String(Math.round(row.getBoundingClientRect().top));
            """
        _ = try page.run("""
            const row = [...document.querySelectorAll(".file")].find((node) => node.dataset.path === "Sources/Feature/F40.swift");
            window.scrollBy(0, row.getBoundingClientRect().top - 100);
            return "";
            """)
        XCTAssertEqual(try page.run(top), "100")
        page.controller.worktreeChanged(.worktree)
        page.waitUntil("the second read") { page.controller.snapshot?.files.count == 63 }
        try page.waitForPage()
        XCTAssertEqual(try page.run("return String(document.querySelectorAll('.file').length);"), "63")
        XCTAssertEqual(try page.run(top), "100")
    }

    /// A page at the same head waits while the user selects text in the
    /// page, which it would drop, and shows once the selection goes. The
    /// text is in a diff, drawn in a shadow root.
    @MainActor
    func testASelectionHoldsTheNextPageBack() throws {
        let first = BranchReviewPageTests.snapshot()
        var added = BranchReview.FileChange(path: "Sources/Later.swift", status: .added)
        added.patchHash = "later"
        let calls = BranchReviewControllerTests.Recorder<Bool>()
        let reads = BranchReviewControllerTests.Answers(answers: [
            (.snapshot(first), nil), (.snapshot(BranchReviewControllerTests.snapshot(first, files: first.files + [added])), nil)
        ])
        let page = try ReviewPage(reader: { _, _, _ in
            _ = calls.append(true)
            return reads.next()
        })
        defer { page.close() }
        XCTAssertEqual(try page.run("""
            document.querySelector('.file[data-id="0"] .file-row').click();
            const deadline = Date.now() + 10000;
            let host;
            while (!(host = document.querySelector('.file[data-id="0"] diffs-container'))?.shadowRoot && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
            const lines = () => document.createTreeWalker(host.shadowRoot, NodeFilter.SHOW_TEXT, {
              acceptNode: (node) => node.textContent.includes("IOKit") ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP
            }).nextNode();
            while (!lines() && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
            const text = lines();
            getSelection().setBaseAndExtent(text, 0, text, text.textContent.length);
            return getSelection().toString().trim();
            """), "IOKit")
        // The selection's message comes before the script's answer.
        _ = try page.run("return '';")
        page.controller.worktreeChanged(.worktree)
        page.waitUntil("the second read") { calls.values.count == 2 && !page.controller.isReading }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(page.controller.snapshot?.files.count, 3, "shown under the selection")
        XCTAssertNotEqual(try page.run("return getSelection().toString();"), "")

        _ = try page.run("getSelection().removeAllRanges(); return '';")
        page.waitUntil("the held page") { page.controller.snapshot?.files.count == 4 }
    }

    /// A page held for a selection was of before a read that shows a
    /// status (a Refresh during a rebase): the selection going doesn't
    /// bring it back over the status.
    @MainActor
    func testAHeldPageGoesWithTheNextStatus() throws {
        let first = BranchReviewPageTests.snapshot()
        var added = BranchReview.FileChange(path: "Sources/Later.swift", status: .added)
        added.patchHash = "later"
        let calls = BranchReviewControllerTests.Recorder<Bool>()
        let reads = BranchReviewControllerTests.Answers(answers: [
            (.snapshot(first), nil), (.snapshot(BranchReviewControllerTests.snapshot(first, files: first.files + [added])), nil),
            (.paused(.rebase), nil)
        ])
        let page = try ReviewPage(reader: { _, _, _ in
            _ = calls.append(true)
            return reads.next()
        })
        defer { page.close() }
        _ = try page.run("getSelection().selectAllChildren(document.querySelector('.meta')); return '';")
        _ = try page.run("return '';")
        page.controller.worktreeChanged(.worktree)
        page.waitUntil("the held read") { calls.values.count == 2 && !page.controller.isReading }
        XCTAssertEqual(page.controller.snapshot?.files.count, 3)
        page.controller.reload()
        page.waitUntil("the pause") { page.controller.snapshot == nil && !page.controller.isReading }
        _ = try page.run("getSelection().removeAllRanges(); return '';")
        _ = try page.run("return '';")
        XCTAssertNil(page.controller.snapshot)
        XCTAssertEqual(
            try BranchReviewControllerTests.shown(page),
            #"{"page":false,"status":"A rebase is in progress in this worktree. The review comes back once it’s over.","action":null}"#
        )
    }

    /// A diff drawn, then read again without being kept (its file grew past
    /// the inline limit), then back as it was: the row draws it again
    /// rather than reuse the one it let go.
    @MainActor
    func testADiffLetGoIsDrawnAgain() throws {
        let first = BranchReviewPageTests.snapshot()
        var onDemand = first.files
        onDemand[0].omission = .onDemand
        onDemand[0].hunks = []
        let reads = BranchReviewControllerTests.Answers(answers: [
            (.snapshot(first), nil), (.snapshot(BranchReviewControllerTests.snapshot(first, files: onDemand)), nil),
            (.snapshot(first), nil)
        ])
        let page = try ReviewPage(reader: { _, _, _ in reads.next() })
        defer { page.close() }
        let drawn = """
            const row = () => document.querySelector('.file[data-id="0"]');
            if (row().querySelector(".diff").hidden) row().querySelector(".file-row").click();
            const deadline = Date.now() + 10000;
            while (!row().querySelector("diffs-container") && !row().querySelector(".diff-message:not(:empty)")?.textContent.startsWith("Nirux") && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
            return row().querySelector("diffs-container") ? "diff" : row().querySelector(".diff").textContent;
            """
        XCTAssertEqual(try page.run(drawn), "diff")
        page.controller.worktreeChanged(.worktree)
        page.waitUntil("the on-demand page") { page.controller.snapshot?.files.first?.omission == .onDemand }
        try page.waitForPage()
        XCTAssertTrue(try page.run(drawn).hasPrefix("Nirux couldn’t read this file’s diff"))
        page.controller.worktreeChanged(.worktree)
        page.waitUntil("the page as it was") { page.controller.snapshot?.files.first?.omission == nil }
        try page.waitForPage()
        XCTAssertEqual(try page.run(drawn), "diff")
    }

    /// A banner a watched read finds again isn't drawn again: a click on
    /// its button at that moment isn't lost.
    @MainActor
    func testTheSameBannerIsntDrawnAgain() throws {
        let first = BranchReviewPageTests.snapshot()
        let second = Self.snapshot(first, head: String(repeating: "d", count: 40), newCommit: "feat: one more")
        let calls = BranchReviewControllerTests.Recorder<Bool>()
        let reads = BranchReviewControllerTests.Answers(answers: [(.snapshot(first), nil), (.snapshot(second), nil)])
        let page = try ReviewPage(reader: { _, _, _ in
            _ = calls.append(true)
            return reads.next()
        })
        defer { page.close() }
        page.controller.worktreeChanged(.metadata)
        page.waitUntil("the banner") { (try? page.run(Self.banner)) == "The branch moved to ddddddd: 1 new commit." }
        _ = try page.run("document.querySelector('#banner .action').marked = true; return '';")
        page.controller.worktreeChanged(.metadata)
        page.waitUntil("the read again") { calls.values.count == 3 && !page.controller.isReading }
        _ = try page.run("return '';")
        XCTAssertEqual(try page.run("return String(document.querySelector('#banner .action').marked === true);"), "true")
    }

    /// A Refresh asked for during a watched read says it reads.
    @MainActor
    func testARefreshDuringAWatchedReadShowsReading() throws {
        let calls = BranchReviewControllerTests.Recorder<Bool>()
        let page = try ReviewPage(reader: { _, _, _ in
            // The watched read takes a while.
            if calls.append(true) == 2 { Thread.sleep(forTimeInterval: 0.5) }
            return (.snapshot(BranchReviewPageTests.snapshot()), nil)
        })
        defer { page.close() }
        page.controller.worktreeChanged(.metadata)
        page.waitUntil("the watched read") { page.controller.isReading }
        XCTAssertNil(page.controller.view.header.status, "a watched read stays quiet")
        page.controller.reload(fetchBase: true)
        XCTAssertEqual(page.controller.view.header.status?.text, "Reading")
        page.waitUntil("both reads") { calls.values.count == 3 && !page.controller.isReading }
    }

    /// Watched reads reuse the pull request the last read found, until the
    /// remote branch moves (a push): the next read asks gh again.
    @MainActor
    func testAPushAsksForThePullRequestAgain() throws {
        let known = BranchReviewControllerTests.Recorder<Bool>()
        let snapshot = BranchReviewPageTests.snapshot()
        let reads = BranchReviewControllerTests.Answers(answers: [
            (.snapshot(snapshot), nil), (.snapshot(snapshot), nil), (.paused(.rebase), nil), (.snapshot(snapshot), nil)
        ])
        let page = try ReviewPage(reader: { _, _, pullRequest in
            _ = known.append(pullRequest != nil)
            return reads.next()
        })
        defer { page.close() }
        page.controller.worktreeChanged(.worktree)
        page.waitUntil("the watched read") { known.values.count == 2 && !page.controller.isReading }
        // `git pull --rebase`: the push's read finds a rebase, and asks
        // nothing; the next one does.
        page.controller.worktreeChanged(.remoteBranch)
        page.waitUntil("the read after the push") { known.values.count == 3 && !page.controller.isReading }
        page.controller.worktreeChanged(.metadata)
        page.waitUntil("the read after the rebase") { known.values.count == 4 && !page.controller.isReading }
        page.controller.worktreeChanged(.worktree)
        page.waitUntil("one more") { known.values.count == 5 && !page.controller.isReading }
        XCTAssertEqual(known.values, [false, true, false, false, true])
    }

    /// A failed fetch holds until the next Refresh fetches: watched reads
    /// don't fetch, and don't clear it.
    @MainActor
    func testAFailedFetchStaysUntilTheNextRefresh() throws {
        var failed = BranchReviewPageTests.snapshot()
        failed.fetchProblem = "origin can’t be reached."
        var added = BranchReview.FileChange(path: "Sources/Later.swift", status: .added)
        added.patchHash = "later"
        let reads = BranchReviewControllerTests.Answers(answers: [
            (.snapshot(failed), nil),
            (.snapshot(BranchReviewControllerTests.snapshot(BranchReviewPageTests.snapshot(), files: failed.files + [added])), nil)
        ])
        let page = try ReviewPage(reader: { _, _, _ in reads.next() })
        defer { page.close() }
        page.controller.worktreeChanged(.worktree)
        page.waitUntil("the watched read") { page.controller.snapshot?.files.count == 4 }
        XCTAssertEqual(page.controller.snapshot?.fetchProblem, "origin can’t be reached.")
    }

    /// The top level is the nearest folder above with a `.git`; a folder
    /// in no repository has none, and the walk ends at the root.
    func testTheTopLevelIsTheNearestFolderWithAGit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-review-top-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(BranchReviewController.topLevel(of: root.appendingPathComponent("Sources/Deep").path), root.path)
        XCTAssertNil(BranchReviewController.topLevel(of: "/nirux-missing-\(UUID().uuidString)/x"))
    }

    /// The watcher follows the column's window: it stops when the column
    /// leaves it (closed), and watches again once back.
    @MainActor
    func testTheWatcherStopsWhenTheColumnLeavesItsWindow() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-review-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let made = BranchReviewControllerTests.Recorder<String>()
        let page = try ReviewPage(reader: { _, _, _ in (.snapshot(BranchReviewPageTests.snapshot()), nil) }, makeWatcher: { layout, branch, change in
            _ = made.append(layout.worktreeRoot)
            // A real watcher: a second one is made only if the first stopped.
            return GitRepositoryWatcher(layout: .resolve(worktreeRoot: folder.path), branch: branch, onChange: change)
        })
        defer { page.close() }
        page.waitUntil("the watcher") { made.values.count == 1 }
        page.controller.reload()
        page.waitUntil("another read") { !page.controller.isReading }
        XCTAssertEqual(made.values.count, 1, "a read of the same root keeps the watcher")
        let view = page.controller.view
        page.window.contentView = nil
        page.window.contentView = view
        page.waitUntil("watched again once back in a window, after a stop") { made.values.count == 2 }
        XCTAssertTrue(page.controller.isStale, "changes made meanwhile are read once it shows")
    }

    /// A Reload banner survives the page's process dying: the page that
    /// loads again shows it too.
    @MainActor
    func testTheReloadBannerSurvivesThePageReloading() throws {
        let first = BranchReviewPageTests.snapshot()
        let second = Self.snapshot(first, head: String(repeating: "d", count: 40), newCommit: "feat: one more")
        let reads = BranchReviewControllerTests.Answers(answers: [(.snapshot(first), nil), (.snapshot(second), nil)])
        let page = try ReviewPage(reader: { _, _, _ in reads.next() })
        defer { page.close() }
        page.controller.worktreeChanged(.metadata)
        page.waitUntil("the banner") { page.controller.pending != nil }
        let view = page.controller.view
        let webView = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        view.webViewWebContentProcessDidTerminate(webView)
        page.waitUntil("the page again") { view.isPageReady }
        let banner = "return document.getElementById('banner').hidden ? 'hidden' : document.querySelector('#banner span').textContent;"
        page.waitUntil("the banner again") { (try? page.run(banner)) == "The branch moved to ddddddd: 1 new commit." }
    }

    // MARK: - Helpers

    static let banner = "return document.getElementById('banner').hidden ? 'hidden' : document.querySelector('#banner span').textContent;"

    /// A flag a main-actor closure reads after the test changes it.
    @MainActor
    final class Flag {
        var value = false
    }

    /// `base` at another head, with one more commit of its own.
    static func snapshot(_ base: BranchReview.Snapshot, head: String, newCommit: String) -> BranchReview.Snapshot {
        BranchReview.Snapshot(
            root: base.root, branch: base.branch, head: head, base: base.base, pullRequest: base.pullRequest,
            fetchProblem: nil, upstream: nil, pullRequestHead: nil, hasUncommittedChanges: false,
            commits: [.init(oid: head, parents: [base.head], subject: newCommit, body: "", isMergeFromBase: false)] + base.commits,
            files: base.files, testsAgainstCode: base.testsAgainstCode
        )
    }
}
