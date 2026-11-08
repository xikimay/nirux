import XCTest
@testable import Nirux

/// The Reviewed checkboxes (docs/branch-review.md, section 6.3), against
/// the real page and a review file in a folder of the test's own: what a
/// click writes, what the page shows of the file, and when nothing can be
/// written.
final class BranchReviewReviewedTests: XCTestCase {
    private typealias Store = BranchReview.Store
    private typealias Recorder = BranchReviewControllerTests.Recorder

    private var state: URL!
    private let repository = "/repos/widgets/.git"
    private let head = String(repeating: "a", count: 40)
    /// Whether each open ran on the main thread: it never should.
    private let opensOnMain = Recorder<Bool>()

    override func setUpWithError() throws {
        state = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-reviewed-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let state {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.appendingPathComponent("reviews").path)
            try? FileManager.default.removeItem(at: state)
        }
    }

    // MARK: - Helpers

    private func store(_ branch: String = "feat/keep-awake") throws -> Store {
        try XCTUnwrap(Store(repository: repository, branch: branch, stateDirectory: state))
    }

    private var yes: BranchReview.History {
        BranchReview.History(isOwnCommit: { _ in true }, isInReflog: { _ in true })
    }

    /// Opens the review file in the test's folder, as the column does;
    /// git's answers are all yes.
    private var opener: BranchReviewController.ReviewOpener {
        let state = state!
        let repository = repository
        let opensOnMain = opensOnMain
        return { snapshot in
            _ = opensOnMain.append(Thread.isMainThread)
            guard let store = Store(repository: repository, branch: snapshot.branch, stateDirectory: state) else { return nil }
            let history = BranchReview.History(isOwnCommit: { _ in true }, isInReflog: { _ in true })
            return (store, store.open(head: snapshot.head, pullRequest: snapshot.pullRequest, history: history))
        }
    }

    /// The page's fixture, with a second code file so that a group holds
    /// two.
    private func snapshot() -> BranchReview.Snapshot {
        let base = BranchReviewPageTests.snapshot()
        var other = BranchReview.FileChange(path: "Sources/Other.swift", status: .modified)
        other.additions = 2
        other.patchHash = "h3"
        other.hunks = [BranchReview.Hunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, section: "", lines: [
            .init(kind: .removed, text: "let b = 1"), .init(kind: .added, text: "let b = 2")
        ])]
        return BranchReviewControllerTests.snapshot(base, files: base.files + [other])
    }

    @MainActor
    private func page(
        _ snapshot: BranchReview.Snapshot? = nil,
        patchReader: @escaping BranchReviewController.PatchReader = { _, _ in nil },
        opener: BranchReviewController.ReviewOpener? = nil,
        branchCheck: @escaping BranchReviewController.BranchCheck = { _ in true },
        headOrder: @escaping BranchReviewController.HeadOrder = { _, ancestor, descendant in ancestor == descendant }
    ) throws -> ReviewPage {
        let page = try ReviewPage(
            snapshot: snapshot ?? self.snapshot(), handover: nil, patchReader: patchReader, reviewOpener: opener ?? self.opener,
            branchCheck: branchCheck, headOrder: headOrder
        )
        // The review opens after the page shows.
        page.waitUntil("the review") { page.controller.review != nil }
        try wait(page, until: #"document.querySelector(".review-problem:not([hidden]), .review-progress:not([hidden])")"#)
        return page
    }

    /// Until `condition`, a script expression, holds in the page.
    @MainActor
    private func wait(_ page: ReviewPage, until condition: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let held = try page.run("""
            const deadline = Date.now() + 10000;
            while (!(\(condition)) && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
            return String(Boolean(\(condition)));
            """)
        XCTAssertEqual(held, "true", "timed out waiting for \(condition)", file: file, line: line)
    }

    /// What the page shows of a row's Reviewed state, and of the review.
    @MainActor
    private func shown(_ page: ReviewPage, _ id: Int) throws -> String {
        try page.run("""
            const box = document.querySelector('.file[data-id="\(id)"]');
            const check = box.querySelector(".file-check");
            const problem = document.querySelector(".review-problem");
            return JSON.stringify({
              checked: check.getAttribute("aria-checked"), disabled: check.getAttribute("aria-disabled") === "true",
              note: box.querySelector(".review-note").textContent,
              progress: document.querySelector(".review-progress").textContent,
              problem: problem.hidden ? null : problem.textContent
            });
            """)
    }

    @MainActor
    private func click(_ page: ReviewPage, _ selector: String) throws {
        _ = try page.run("document.querySelector('\(selector)').click(); return '';")
    }

    private func reviewedJSON(_ checked: Bool, progress: Int, note: String = "", problem: String? = nil) -> String {
        let problemJSON = problem.map { #""\#($0)""# } ?? "null"
        return #"{"checked":"\#(checked)","disabled":false,"note":"\#(note)","#
            + #""progress":"·Reviewed \#(progress) of 4 files","problem":\#(problemJSON)}"#
    }

    // MARK: - States

    func testEachFilesStateComesFromItsMark() {
        func file(_ path: String, _ hash: String?) -> BranchReview.FileChange {
            BranchReview.FileChange(path: path, status: .modified, patchHash: hash)
        }
        var record = BranchReview.Record()
        XCTAssertEqual(record.markReviewed([file("a", "h1"), file("b", "h1"), file("c", "h3"), file("x", nil)], head: "b", at: Date()), 3)
        let files = [file("a", "h1"), file("b", "h2"), file("c", nil), file("d", "h4"), file("e", nil)]
        let review = BranchReview.review(of: record, files: files, generation: 3, problem: "Why", canWrite: false, acknowledged: 2)
        XCTAssertEqual(review, BranchReview.Page.Review(
            files: ["reviewed", "changed", "unverified", "none", "unmarkable"], generation: 3, problem: "Why", canWrite: false,
            acknowledged: 2, comments: [], commentProblems: []
        ))
        record.clearReviewed(paths: ["a", "c"])
        XCTAssertEqual(Set(record.reviewedMarks.keys), ["b"])
    }

    // MARK: - Clicks

    @MainActor
    func testTickingAFileMarksItReviewedAndFoldsItsDiff() throws {
        let page = try page()
        defer { page.close() }
        try click(page, #".file[data-id=\"0\"] .file-row"#)
        try wait(page, until: #"document.querySelector('.file[data-id="0"] diffs-container')"#)

        try click(page, #".file[data-id=\"0\"] .file-check"#)
        let store = try store()
        page.waitUntil("the mark") { store.load().record.reviewedMarks["Sources/KeepAwake.swift"] != nil }
        let mark = try XCTUnwrap(store.load().record.reviewedMarks["Sources/KeepAwake.swift"])
        XCTAssertEqual(mark.patchHash, "h0")
        XCTAssertEqual(mark.head, head)
        // Swift answered the click.
        page.waitUntil("the answer") { page.controller.review?.record.reviewedMarks.isEmpty == false }
        XCTAssertEqual(try shown(page, 0), reviewedJSON(true, progress: 1))
        XCTAssertEqual(try page.run(#"return String(document.querySelector('.file[data-id="0"] .diff').hidden);"#), "true")
        XCTAssertEqual(opensOnMain.values, [false])

        // And back.
        try click(page, #".file[data-id=\"0\"] .file-check"#)
        page.waitUntil("the mark to go") { store.load().record.reviewedMarks.isEmpty }
        try wait(page, until: #"document.querySelector('.file[data-id="0"] .file-check').getAttribute('aria-checked') === 'false'"#)
    }

    @MainActor
    func testGroupCheckboxMarksEveryFileThenClearsThem() throws {
        let page = try page()
        defer { page.close() }
        let group = #".group[data-key=\"code\"] .group-check"#
        func waitForGroup(_ expected: String) throws {
            try wait(page, until: """
                document.querySelector('.group[data-key="code"] .group-check').getAttribute("aria-checked")
                    + document.querySelector('.group[data-key="code"] .group-progress').textContent === "\(expected)"
                """)
        }
        try waitForGroup("false · 0/2 reviewed")
        try click(page, #".file[data-id=\"0\"] .file-check"#)
        try waitForGroup("mixed · 1/2 reviewed")

        try click(page, group)
        let store = try store()
        page.waitUntil("both marks") { store.load().record.reviewedMarks.count == 2 }
        XCTAssertEqual(Set(store.load().record.reviewedMarks.keys), ["Sources/KeepAwake.swift", "Sources/Other.swift"])
        try waitForGroup("true · 2/2 reviewed")

        try click(page, group)
        page.waitUntil("no mark") { store.load().record.reviewedMarks.isEmpty }
        try waitForGroup("false · 0/2 reviewed")
    }

    @MainActor
    func testStoredMarksShowWhenThePageOpensAndWhenItShowsAgain() throws {
        let store = try store()
        let access = try XCTUnwrap(store.open(head: "b", pullRequest: .notFound, history: yes).access)
        let files = snapshot().files
        _ = try store.update(access) { record in
            record.markReviewed(files[0], head: "b", at: Date())
            var changed = files[3]
            changed.patchHash = "an earlier patch"
            record.markReviewed(changed, head: "b", at: Date())
        }.get()

        let page = try page()
        defer { page.close() }
        XCTAssertEqual(try shown(page, 0), reviewedJSON(true, progress: 1))
        XCTAssertEqual(try shown(page, 3), reviewedJSON(false, progress: 1, note: "changed since reviewed"))

        // The same branch read again: the new page carries the review.
        _ = try page.run("document.querySelector('.file').dataset.before = 'yes'; return '';")
        page.controller.reload()
        try wait(page, until: #"document.querySelector('.file') && !document.querySelector('.file[data-before]')"#)
        XCTAssertEqual(try shown(page, 0), reviewedJSON(true, progress: 1))
    }

    /// A click Swift hasn't written yet survives a new page of the same
    /// branch, which carries the review as it was before it.
    @MainActor
    func testClickSurvivesAPageShownBeforeItsWrite() throws {
        let gate = BranchReviewControllerTests.Gate()
        let checks = Recorder<Bool>()
        let page = try page(branchCheck: { _ in
            if checks.append(true) == 1 { gate.wait() }
            return true
        })
        defer { page.close() }
        try click(page, #".file[data-id=\"0\"] .file-check"#)
        page.waitUntil("the write to start") { checks.values.count == 1 }
        _ = try page.run("document.querySelector('.file').dataset.before = 'yes'; return '';")
        page.controller.reload()
        try wait(page, until: #"document.querySelector('.file') && !document.querySelector('.file[data-before]')"#)
        XCTAssertEqual(try page.run(#"return document.querySelector('.file[data-id="0"] .file-check').getAttribute('aria-checked');"#), "true")

        gate.open(times: 1)
        let store = try store()
        page.waitUntil("the mark") { store.load().record.reviewedMarks["Sources/KeepAwake.swift"] != nil }
        page.waitUntil("the answer") { page.controller.review?.record.reviewedMarks.isEmpty == false }
        XCTAssertEqual(try shown(page, 0), reviewedJSON(true, progress: 1))
    }

    /// A click on a page another replaced since isn't written, but it is
    /// answered: the page shows the review again.
    @MainActor
    func testClickOnAnEarlierPageIsAnsweredWithoutWriting() throws {
        let page = try page()
        defer { page.close() }
        _ = try page.run("""
            window.webkit.messageHandlers.review.postMessage({ type: "reviewed", ids: [0], reviewed: true, generation: -1, sequence: 5 });
            return "";
            """)
        page.waitUntil("the answer") { page.controller.reviewAcknowledged == 5 }
        XCTAssertEqual(try store().load().status, .missing)
    }

    @MainActor
    func testAnswerForAnEarlierPageIsDropped() throws {
        let page = try page()
        defer { page.close() }
        let result = try page.run("""
            NiruxReview.showReview(JSON.stringify({
              files: ["reviewed", "reviewed", "reviewed", "reviewed"], generation: -1, problem: null, canWrite: true, acknowledged: 0
            }));
            return document.querySelector('.file[data-id="0"] .file-check').getAttribute("aria-checked");
            """)
        XCTAssertEqual(result, "false")
    }

    /// A file whose patch wasn't read has no hash to mark: its checkbox
    /// waits for its row to open and read it.
    @MainActor
    func testFileNotReadIsMarkedOnceItsRowReadsIt() throws {
        var snapshot = snapshot()
        snapshot = BranchReviewControllerTests.snapshot(snapshot, files: snapshot.files.map { file in
            guard file.path == "Sources/Other.swift" else { return file }
            var notRead = file
            notRead.patchHash = nil
            notRead.hunks = []
            notRead.omission = .notRead
            return notRead
        })
        let read = self.snapshot().files[3]
        let page = try page(snapshot, patchReader: { file, _ in file.path == read.path ? read : nil })
        defer { page.close() }
        XCTAssertEqual(try page.run(#"return document.querySelector('.file[data-id="3"] .file-check').getAttribute("aria-disabled");"#), "true")

        try click(page, #".file[data-id=\"3\"] .file-row"#)
        try wait(page, until: #"document.querySelector('.file[data-id="3"] .file-check').getAttribute("aria-disabled") !== "true""#)
        try click(page, #".file[data-id=\"3\"] .file-check"#)
        let store = try store()
        page.waitUntil("the mark") { store.load().record.reviewedMarks["Sources/Other.swift"] != nil }
        XCTAssertEqual(store.load().record.reviewedMarks["Sources/Other.swift"]?.patchHash, "h3")
    }

    // MARK: - When nothing can be written

    @MainActor
    func testReviewThatCantBeOpenedSaysWhy() throws {
        let page = try page(opener: { _ in nil })
        defer { page.close() }
        let shown = try page.run("""
            const check = document.querySelector('.file[data-id="0"] .file-check');
            return JSON.stringify({
              disabled: check.getAttribute("aria-disabled"), title: check.title,
              progress: document.querySelector(".review-progress").hidden,
              problem: document.querySelector(".review-problem").textContent
            });
            """)
        let problem = "Nirux couldn’t open this branch’s review file: git couldn’t tell its repository."
        XCTAssertEqual(shown, #"{"disabled":"true","title":"\#(problem)","progress":true,"problem":"\#(problem)"}"#)
    }

    /// Clean Up deleted the branch: a page still showing it mustn't create
    /// its review again.
    @MainActor
    func testNothingIsCreatedOnceTheBranchIsGone() throws {
        let page = try page(branchCheck: { _ in false })
        defer { page.close() }
        try click(page, #".file[data-id=\"0\"] .file-check"#)
        try wait(page, until: #"!document.querySelector(".review-problem").hidden"#)
        XCTAssertEqual(
            try shown(page, 0),
            #"{"checked":"false","disabled":true,"note":"","progress":"·Reviewed 0 of 4 files","#
                + #""problem":"feat/keep-awake was deleted: Nirux won’t create its review."}"#
        )
        XCTAssertEqual(try store().load().status, .missing)
    }

    @MainActor
    func testFailedWriteUndoesTheClickAndSaysWhy() throws {
        let page = try page()
        defer { page.close() }
        try click(page, #".file[data-id=\"0\"] .file-check"#)
        let store = try store()
        page.waitUntil("the mark") { store.load().record.reviewedMarks.count == 1 }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.folder.path)

        try click(page, #".file[data-id=\"3\"] .file-check"#)
        try wait(page, until: #"!document.querySelector(".review-problem").hidden"#)
        let shown = try shown(page, 3)
        let expected = #"{"checked":"false","disabled":false,"note":"","progress":"·Reviewed 1 of 4 files","#
            + #""problem":"Nirux couldn’t save the review"#
        XCTAssertTrue(shown.hasPrefix(expected), shown)
    }

    @MainActor
    func testReviewFromANewerNiruxIsShownButCantBeChanged() throws {
        let store = try store()
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "version": 2, "branch": "feat/keep-awake", "repository": repository, "lastHead": "b",
            "reviewed": ["Sources/KeepAwake.swift": ["patchHash": "h0"]]
        ]).write(to: store.fileURL)
        let before = try Data(contentsOf: store.fileURL)

        let page = try page()
        defer { page.close() }
        let shown = try shown(page, 0)
        let expected = #"{"checked":"true","disabled":true,"note":"","progress":"·Reviewed 1 of 4 files","#
            + #""problem":"This review was saved by a newer Nirux"#
        XCTAssertTrue(shown.hasPrefix(expected), shown)
        let groupDisabled = try page.run(#"return document.querySelector('.group[data-key="code"] .group-check').getAttribute("aria-disabled");"#)
        XCTAssertEqual(groupDisabled, "true")
        try click(page, #".file[data-id=\"0\"] .file-check"#)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    }

    // MARK: - A review opened elsewhere since

    /// Opened since at an older head (another Nirux): opened again at the
    /// page's head, and written.
    @MainActor
    func testReviewOpenedSinceAtAnOlderHeadIsOpenedAgain() throws {
        let page = try page(headOrder: { _, ancestor, descendant in ancestor == descendant || ancestor == "b" })
        defer { page.close() }
        let store = try store()
        _ = try store.update(try XCTUnwrap(store.open(head: "b", pullRequest: .notFound, history: yes).access)) { _ in }.get()

        try click(page, #".file[data-id=\"0\"] .file-check"#)
        page.waitUntil("the mark") { store.load().record.reviewedMarks["Sources/KeepAwake.swift"] != nil }
        XCTAssertEqual(store.load().record.lastHead, head)
    }

    /// Opened since at a later head (the page waits behind its Reload
    /// banner): written without moving it back.
    @MainActor
    func testReviewOpenedSinceAtALaterHeadKeepsIt() throws {
        let later = String(repeating: "c", count: 40)
        let page = try page(headOrder: { _, ancestor, descendant in ancestor == descendant || descendant == later })
        defer { page.close() }
        let store = try store()
        _ = try store.update(try XCTUnwrap(store.open(head: later, pullRequest: .notFound, history: yes).access)) { _ in }.get()

        try click(page, #".file[data-id=\"0\"] .file-check"#)
        page.waitUntil("the mark") { store.load().record.reviewedMarks["Sources/KeepAwake.swift"] != nil }
        XCTAssertEqual(store.load().record.lastHead, later)
        XCTAssertEqual(store.load().record.reviewedMarks["Sources/KeepAwake.swift"]?.head, head)
    }

    /// Opened since at a head neither before nor after the page's: the
    /// page doesn't write over it.
    @MainActor
    func testReviewOpenedSinceAtAnotherHeadIsntWritten() throws {
        let page = try page()
        defer { page.close() }
        let store = try store()
        let other = String(repeating: "d", count: 40)
        _ = try store.update(try XCTUnwrap(store.open(head: other, pullRequest: .notFound, history: yes).access)) { _ in }.get()

        try click(page, #".file[data-id=\"0\"] .file-check"#)
        try wait(page, until: #"!document.querySelector(".review-problem").hidden"#)
        XCTAssertEqual(try shown(page, 0), reviewedJSON(
            false, progress: 0, problem: "The review was opened at another head since. Reload or Refresh to change it."
        ))
        XCTAssertEqual(store.load().record.lastHead, other)
        XCTAssertEqual(store.load().record.reviewedMarks, [:])
    }

    // MARK: - The page's other checkboxes

    /// A pull request's task list keeps its own look: the Reviewed
    /// checkboxes' style is theirs alone.
    @MainActor
    func testTaskListsInThePullRequestStayInline() throws {
        let pullRequest = BranchReview.PullRequest(
            number: 57, title: "Keep awake", body: "- [x] Tests pass", url: "https://github.com/o/r/pull/57", baseRefName: "main",
            headRefOid: head, isDraft: false
        )
        let base = snapshot()
        let snapshot = BranchReview.Snapshot(
            root: base.root, branch: base.branch, head: base.head, base: base.base, pullRequest: .found(pullRequest),
            fetchProblem: nil, upstream: nil, pullRequestHead: nil, hasUncommittedChanges: false, commits: base.commits,
            files: base.files, testsAgainstCode: base.testsAgainstCode
        )
        let page = try page(snapshot)
        defer { page.close() }
        XCTAssertEqual(try page.run(#"return getComputedStyle(document.querySelector(".markdown .check")).display;"#), "inline")
    }
}

/// The review file's worker on its own, without a page: what it opens,
/// writes and refuses.
final class BranchReviewFileTests: XCTestCase {
    private var state: URL!

    override func setUpWithError() throws {
        state = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-review-file-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let state { try? FileManager.default.removeItem(at: state) }
    }

    private var yes: BranchReview.History {
        BranchReview.History(isOwnCommit: { _ in true }, isInReflog: { _ in true })
    }

    /// `historyFails`: whether git fails to read the history, in turn.
    private func worker(
        opens: BranchReviewControllerTests.Recorder<String>, branchCheck: @escaping BranchReviewController.BranchCheck = { _ in true },
        historyFails: BranchReviewControllerTests.Answers? = nil,
        isAncestor: @escaping BranchReviewController.HeadOrder = { _, ancestor, descendant in ancestor == descendant }
    ) -> BranchReviewFile {
        let state = state!
        return BranchReviewFile(opener: { snapshot in
            let fails = historyFails.map { if case .unavailable = $0.next().0 { true } else { false } } ?? false
            _ = opens.append(snapshot.head)
            guard let store = BranchReview.Store(repository: "/r/.git", branch: snapshot.branch, stateDirectory: state) else { return nil }
            let history = BranchReview.History(isOwnCommit: { _ in fails ? nil : true }, isInReflog: { _ in fails ? nil : true })
            return (store, store.open(head: snapshot.head, pullRequest: snapshot.pullRequest, history: history))
        }, branchCheck: branchCheck, isAncestor: isAncestor)
    }

    private func snapshot(_ branch: String = "feat/keep-awake", head: Character = "a") -> BranchReview.Snapshot {
        let base = BranchReviewPageTests.snapshot()
        return BranchReview.Snapshot(
            root: base.root, branch: branch, head: String(repeating: head, count: 40), base: base.base,
            pullRequest: base.pullRequest, fetchProblem: nil, upstream: nil, pullRequestHead: nil, hasUncommittedChanges: false,
            commits: [], files: [], testsAgainstCode: base.testsAgainstCode
        )
    }

    private func mark(_ path: String) -> BranchReviewFile.Change {
        { record in record.markReviewed(BranchReview.FileChange(path: path, status: .modified, patchHash: "h"), head: "x", at: Date()) }
    }

    func testChangesAskedForMeanwhileAreWrittenTogetherAndOnlyForTheirBranch() throws {
        let file = worker(opens: BranchReviewControllerTests.Recorder<String>())
        let snapshot = snapshot()
        _ = file.open(snapshot)
        file.enqueue(id: 1, branch: snapshot.branch, mark("a"))
        file.enqueue(id: 2, branch: "another", mark("b"))
        file.enqueue(id: 3, branch: snapshot.branch, mark("c"))

        let written = try XCTUnwrap(file.write(through: 3))
        XCTAssertEqual(written.ids, [1, 2, 3])
        XCTAssertEqual(Set(written.state.record.reviewedMarks.keys), ["a", "c"])
        XCTAssertNil(file.write(through: 3), "nothing left")
    }

    /// Clicks asked for while a write waits are written with it.
    func testChangesForTheBranchShownAreWrittenWithTheFirst() throws {
        let file = worker(opens: BranchReviewControllerTests.Recorder<String>())
        let snapshot = snapshot()
        _ = file.open(snapshot)
        file.enqueue(id: 1, branch: snapshot.branch, mark("a"))
        file.enqueue(id: 2, branch: snapshot.branch, mark("b"))
        XCTAssertEqual(file.write(through: 1)?.ids, [1, 2])
        XCTAssertNil(file.write(through: 2))
    }

    /// A failed write's problem goes with the next open at the same head.
    func testRefreshAfterAFailedWriteOpensAgain() throws {
        let checks = BranchReviewControllerTests.Recorder<Bool>()
        let opens = BranchReviewControllerTests.Recorder<String>()
        let file = worker(opens: opens, branchCheck: { _ in checks.append(true) == 1 ? nil : true })
        let snapshot = snapshot()
        _ = file.open(snapshot)
        file.enqueue(id: 1, branch: snapshot.branch, mark("a"))
        XCTAssertNotNil(file.write(through: 1)?.state.problem)
        XCTAssertNil(file.open(snapshot).problem)
        XCTAssertEqual(opens.values.count, 2)
    }

    /// A click on the next branch shown, asked for while a write for the
    /// one before waits, is written once that branch is open.
    func testChangeForTheNextBranchWaitsForItsOwnWrite() throws {
        let file = worker(opens: BranchReviewControllerTests.Recorder<String>())
        _ = file.open(snapshot("feat/a"))
        file.enqueue(id: 1, branch: "feat/a", mark("a"))
        file.enqueue(id: 2, branch: "feat/b", mark("b"))
        XCTAssertEqual(file.write(through: 1)?.ids, [1])
        _ = file.open(snapshot("feat/b"))
        let written = try XCTUnwrap(file.write(through: 2))
        XCTAssertEqual(written.ids, [2])
        XCTAssertEqual(Set(written.state.record.reviewedMarks.keys), ["b"])
    }

    func testSameHeadAndFileIsntOpenedAgain() throws {
        let opens = BranchReviewControllerTests.Recorder<String>()
        let file = worker(opens: opens)
        let snapshot = snapshot()
        _ = file.open(snapshot)
        _ = file.open(snapshot)
        XCTAssertEqual(opens.values.count, 1)

        // After a write, opened once more: the write changed the file.
        file.enqueue(id: 1, branch: snapshot.branch, mark("a"))
        _ = file.write(through: 1)
        XCTAssertEqual(file.open(snapshot).record.reviewedMarks.count, 1)
        _ = file.open(snapshot)
        XCTAssertEqual(opens.values.count, 2)

        // Another writer's save is seen; `reload` reads it without opening.
        let store = try XCTUnwrap(BranchReview.Store(repository: "/r/.git", branch: snapshot.branch, stateDirectory: state))
        let access = try XCTUnwrap(store.open(head: snapshot.head, pullRequest: .notFound, history: yes).access)
        _ = try store.update(access, mark("b")).get()
        let reloaded = try XCTUnwrap(file.reload())
        XCTAssertEqual(reloaded.record.reviewedMarks.count, 2)
        XCTAssertTrue(reloaded.canWrite)
        XCTAssertNil(reloaded.problem)
        XCTAssertEqual(opens.values.count, 2)
        _ = try store.update(access, mark("c")).get()
        XCTAssertEqual(file.open(snapshot).record.reviewedMarks.count, 3)
        XCTAssertEqual(opens.values.count, 3)
    }

    /// An open that failed in a way that may pass (git couldn't read the
    /// history) is tried again by the next one, at the same head.
    func testFailedOpenIsTriedAgain() throws {
        let opens = BranchReviewControllerTests.Recorder<String>()
        let fails = BranchReviewControllerTests.Answers(answers: [
            (.paused(.rebase), nil), (.unavailable("git"), nil), (.paused(.rebase), nil)
        ])
        let file = worker(opens: opens, historyFails: fails)
        let snapshot = snapshot()
        // A review stamped at another head: opening asks the history.
        let store = try XCTUnwrap(BranchReview.Store(repository: "/r/.git", branch: snapshot.branch, stateDirectory: state))
        func stampElsewhere() throws {
            _ = try store.update(try XCTUnwrap(store.open(head: "b", pullRequest: .notFound, history: yes).access), mark("x")).get()
        }
        try stampElsewhere()
        XCTAssertTrue(file.open(snapshot).canWrite)
        try stampElsewhere()
        XCTAssertFalse(file.open(snapshot).canWrite)
        XCTAssertTrue(file.open(snapshot).canWrite)
        XCTAssertEqual(opens.values.count, 3)
    }

    /// Another writer saved while the review opened: the next open reads
    /// what it saved, rather than keep what was read before.
    func testSaveDuringAnOpenIsReadByTheNext() throws {
        let state = state!
        let saves = BranchReviewControllerTests.Recorder<Bool>()
        let addZ = mark("z")
        let file = BranchReviewFile(opener: { snapshot in
            guard let store = BranchReview.Store(repository: "/r/.git", branch: snapshot.branch, stateDirectory: state) else { return nil }
            let history = BranchReview.History(isOwnCommit: { _ in true }, isInReflog: { _ in true })
            let opened = store.open(head: snapshot.head, pullRequest: snapshot.pullRequest, history: history)
            if saves.append(true) == 2, let access = opened.access { _ = store.update(access, addZ) }
            return (store, opened)
        }, branchCheck: { _ in true }, isAncestor: { _, ancestor, descendant in ancestor == descendant })
        let snapshot = snapshot()
        let store = try XCTUnwrap(BranchReview.Store(repository: "/r/.git", branch: snapshot.branch, stateDirectory: state))
        _ = try store.update(try XCTUnwrap(store.open(head: snapshot.head, pullRequest: .notFound, history: yes).access), mark("x")).get()
        _ = file.open(snapshot)
        _ = try store.update(try XCTUnwrap(store.open(head: snapshot.head, pullRequest: .notFound, history: yes).access), mark("y")).get()
        XCTAssertEqual(Set(file.open(snapshot).record.reviewedMarks.keys), ["x", "y"])
        XCTAssertEqual(Set(file.open(snapshot).record.reviewedMarks.keys), ["x", "y", "z"])
    }

    /// Written at a later head once found there, without asking git again
    /// for each write.
    func testLaterHeadIsKeptWithoutAskingAgain() throws {
        let asked = BranchReviewControllerTests.Recorder<Bool>()
        let branchAsked = BranchReviewControllerTests.Recorder<Bool>()
        let later = String(repeating: "c", count: 40)
        let file = worker(opens: BranchReviewControllerTests.Recorder<String>(), branchCheck: { _ in
            _ = branchAsked.append(true)
            return true
        }, isAncestor: { _, ancestor, descendant in
            _ = asked.append(true)
            return ancestor == descendant || descendant == later
        })
        let snapshot = snapshot()
        _ = file.open(snapshot)
        let store = try XCTUnwrap(BranchReview.Store(repository: "/r/.git", branch: snapshot.branch, stateDirectory: state))
        _ = try store.update(try XCTUnwrap(store.open(head: later, pullRequest: .notFound, history: yes).access), mark("x")).get()

        file.enqueue(id: 1, branch: snapshot.branch, mark("a"))
        XCTAssertNil(file.write(through: 1)?.state.problem)
        let afterFirst = asked.values.count
        file.enqueue(id: 2, branch: snapshot.branch, mark("b"))
        XCTAssertNil(file.write(through: 2)?.state.problem)
        XCTAssertEqual(asked.values.count, afterFirst)
        // Opened before the review existed, it asked once: a kept head
        // never creates it.
        XCTAssertEqual(branchAsked.values.count, 1)
        XCTAssertEqual(store.load().record.lastHead, later)
        XCTAssertEqual(store.load().record.reviewedMarks.count, 3)
    }

    /// Only a write that would create the review asks whether the branch
    /// exists: one that exists was deleted with it.
    func testBranchIsAskedOnlyBeforeTheReviewIsCreated() throws {
        let asked = BranchReviewControllerTests.Recorder<Bool>()
        let file = worker(opens: BranchReviewControllerTests.Recorder<String>(), branchCheck: { _ in
            asked.append(true) == 1
        })
        let snapshot = snapshot()
        _ = file.open(snapshot)
        file.enqueue(id: 1, branch: snapshot.branch, mark("a"))
        XCTAssertNil(file.write(through: 1)?.state.problem)
        file.enqueue(id: 2, branch: snapshot.branch, mark("b"))
        XCTAssertEqual(file.write(through: 2)?.state.record.reviewedMarks.count, 2)
        XCTAssertEqual(asked.values.count, 1)
    }

    /// Once found gone, the branch writes nothing until its worktree is
    /// read on it again, which says it exists.
    func testDeletedBranchWritesNothingUntilItsOpenedAgain() throws {
        let exists = BranchReviewControllerTests.Recorder<Bool>()
        let file = worker(opens: BranchReviewControllerTests.Recorder<String>(), branchCheck: { _ in exists.values.last ?? false })
        let snapshot = snapshot()
        _ = file.open(snapshot)
        file.enqueue(id: 1, branch: snapshot.branch, mark("a"))
        XCTAssertEqual(file.write(through: 1)?.state.problem, "feat/keep-awake was deleted: Nirux won’t create its review.")
        _ = exists.append(true)
        file.enqueue(id: 2, branch: snapshot.branch, mark("a"))
        XCTAssertEqual(file.write(through: 2)?.state.canWrite, false)

        // Read again at the same head (Refresh): it exists again.
        let reopened = file.open(snapshot)
        XCTAssertTrue(reopened.canWrite)
        XCTAssertNil(reopened.problem)
    }

    // MARK: - With git

    private func git(_ arguments: [String], in directory: URL) throws -> String {
        try BranchReviewRepositoryTestCase.git(arguments, at: directory.path, environment: [:])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testBranchAndAncestryAreAskedOfTheRepository() throws {
        let root = state.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try git(["init", "-q", "-b", "main"], in: root)
        _ = try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "one"], in: root)
        _ = try git(["branch", "Fix/A"], in: root)
        _ = try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "two"], in: root)
        let common = try XCTUnwrap(BranchReview.repositoryIdentity(root: root.path))
        func store(_ branch: String) throws -> BranchReview.Store {
            try XCTUnwrap(BranchReview.Store(repository: common, branch: branch, stateDirectory: state))
        }
        XCTAssertEqual(BranchReviewController.branchExists(try store("main")), true)
        XCTAssertEqual(BranchReviewController.branchExists(try store("Fix/A")), true)
        XCTAssertEqual(BranchReviewController.branchExists(try store("fix/a")), false, "not by another case")
        XCTAssertEqual(BranchReviewController.branchExists(try store("Fix")), false, "not by a prefix")
        _ = try git(["pack-refs", "--all"], in: root)
        XCTAssertEqual(BranchReviewController.branchExists(try store("Fix/A")), true, "packed")
        _ = try git(["branch", "-D", "Fix/A"], in: root)
        XCTAssertEqual(BranchReviewController.branchExists(try store("Fix/A")), false)
        XCTAssertNil(BranchReviewController.branchExists(try XCTUnwrap(BranchReview.Store(
            repository: state.appendingPathComponent("missing/.git").path, branch: "main", stateDirectory: state
        ))))

        let first = try git(["rev-parse", "HEAD~1"], in: root)
        let second = try git(["rev-parse", "HEAD"], in: root)
        XCTAssertEqual(BranchReviewController.isAncestor(try store("main"), first, second), true)
        XCTAssertEqual(BranchReviewController.isAncestor(try store("main"), second, first), false)
        XCTAssertEqual(BranchReviewController.isAncestor(try store("main"), "b", second), false, "not a commit id")
    }
}
