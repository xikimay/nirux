import XCTest
@testable import Nirux

/// Comments in the column (docs/branch-review.md, section 6.1): what the
/// page gets of them, what it can ask, and what the column writes.
final class BranchReviewPageCommentsTests: XCTestCase, CommentFixtures {
    private typealias Record = BranchReview.Record
    private typealias Request = BranchReviewView.CommentRequest
    private typealias Store = BranchReview.Store

    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    private var state: URL!
    private let repository = "/repos/widgets/.git"

    override func setUpWithError() throws {
        state = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-comments-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let state { try? FileManager.default.removeItem(at: state) }
    }

    // MARK: - What the page gets

    func testEachCommentIsUnderItsRowsOrListedWithItsFile() throws {
        let kept = [" let a = 1", "+let b = 2", "-let c = 3", " let d = 4"]
        let files = [
            file([hunk(old: 1, new: 1, kept)]),
            file([hunk(old: 1, new: 1, [" x()", "+y()"])], path: "b.swift"),
            file([], path: "c.swift", omission: .onDemand)
        ]
        var record = Record()
        // On an added row and the removed one under it.
        record.addComment(id: "c1", anchor: try made([hunk(old: 1, new: 1, kept)], at(.additions, 2), at(.deletions, 2)), text: "Both", at: date)
        // Its row rewritten since.
        record.addComment(id: "c2", anchor: try made([hunk(old: 1, new: 1, [" x()", "+z()"])], at(.additions, 2), path: "b.swift"), text: "Gone", at: date + 1)
        record.addComment(id: "c3", anchor: .file("b.swift"), text: "File", at: date + 2)
        record.addComment(id: "c4", anchor: .file("gone.swift"), text: "Elsewhere", at: date + 3)
        record.addComment(id: "c5", anchor: try made([hunk(old: 1, new: 1, [" p()", "+q()"])], at(.additions, 2), path: "c.swift"), text: "Not read", at: date + 4)
        record.markSent(ids: ["c3"], head: String(repeating: "d", count: 40), at: date + 5)
        record.saveDraft(id: "e1", anchor: .file(""), text: "Typing over c1", editing: "c1", at: date + 6)
        record.saveDraft(id: "d1", anchor: try made([hunk(old: 1, new: 1, kept)], at(.additions, 1)), text: "New", at: date + 7)

        let comments = BranchReview.pageComments(of: record, files: files)
        XCTAssertEqual(comments.map(\.id), ["c1", "c2", "c3", "c4", "c5", "d1"])
        let byID = Dictionary(uniqueKeysWithValues: comments.map { ($0.id, $0) })
        typealias Position = BranchReview.Page.Comment.Position
        XCTAssertEqual(byID["c1"]?.placement, "placed")
        XCTAssertEqual(byID["c1"]?.file, 0)
        XCTAssertEqual(byID["c1"]?.start, Position(side: "additions", line: 2))
        XCTAssertEqual(byID["c1"]?.end, Position(side: "deletions", line: 2))
        XCTAssertNil(byID["c1"]?.excerpt)
        XCTAssertEqual(byID["c1"]?.state, "unsent")
        XCTAssertEqual(byID["c1"]?.edit, BranchReview.Page.Comment.Edit(id: "e1", text: "Typing over c1"))
        XCTAssertEqual(byID["c2"]?.placement, "outdated")
        XCTAssertEqual(byID["c2"]?.file, 1)
        XCTAssertEqual(byID["c2"]?.excerpt, [BranchReview.Page.Comment.Row(kind: "added", line: 2, text: "z()")])
        XCTAssertEqual(byID["c3"]?.placement, "placed")
        XCTAssertEqual(byID["c3"]?.onFile, true)
        XCTAssertEqual(byID["c1"]?.onFile, false)
        XCTAssertNil(byID["c3"]?.start)
        XCTAssertNil(byID["c3"]?.excerpt)
        XCTAssertEqual(byID["c3"]?.state, "sent")
        XCTAssertEqual(byID["c3"]?.sentAt, "ddddddd")
        XCTAssertNil(byID["c3"]?.edit)
        XCTAssertEqual(byID["c4"]?.placement, "fileGone")
        XCTAssertNil(byID["c4"]?.file)
        XCTAssertEqual(byID["c4"]?.path, "gone.swift")
        XCTAssertEqual(byID["c5"]?.placement, "unread")
        XCTAssertEqual(byID["c5"]?.file, 2)
        XCTAssertEqual(byID["d1"]?.state, "draft")
        XCTAssertEqual(byID["d1"]?.text, "New")
        XCTAssertEqual(byID["d1"]?.start, Position(side: "additions", line: 1))
    }

    private func made(
        _ hunks: [BranchReview.Hunk], _ start: BranchReview.DiffPosition, _ end: BranchReview.DiffPosition? = nil,
        path: String = "a.swift"
    ) throws -> BranchReview.CommentAnchor {
        try XCTUnwrap(BranchReview.CommentAnchor(file: file(hunks, path: path), from: start, to: end ?? start))
    }

    // MARK: - What the page can ask

    func testCommentRequestsAreTakenOnlyWellFormed() {
        typealias FilePlace = Request.FilePlace
        let rows: [String: Any] = ["start": ["side": "additions", "line": 2], "end": ["side": "deletions", "line": 3]]
        let onRows = ["id": "d1", "text": "Hi", "file": 0, "generation": 4].merging(rows) { $1 }
        let place = FilePlace(file: 0, generation: 4, start: at(.additions, 2), end: at(.deletions, 3))
        XCTAssertEqual(Request(type: "saveDraft", body: onRows), .saveDraft(id: "d1", place: .file(place), text: "Hi"))
        XCTAssertEqual(
            Request(type: "addComment", body: ["id": "d1", "text": "Hi", "file": 0, "generation": 4, "onFile": true]),
            .addComment(id: "d1", place: FilePlace(file: 0, generation: 4, start: nil, end: nil), text: "Hi")
        )
        // No place: a draft that exists keeps its own.
        XCTAssertEqual(Request(type: "saveDraft", body: ["id": "d1", "text": "Hi"]), .saveDraft(id: "d1", place: nil, text: "Hi"))
        XCTAssertEqual(Request(type: "addComment", body: ["id": "d1", "text": "Hi"]), .addComment(id: "d1", place: nil, text: "Hi"))
        XCTAssertEqual(
            Request(type: "saveDraft", body: ["id": "e1", "text": "", "editing": "c1"]),
            .saveDraft(id: "e1", place: .editing("c1"), text: "")
        )
        // JavaScript's null reads as absent.
        XCTAssertEqual(
            Request(type: "saveDraft", body: onRows.merging(["editing": NSNull()]) { $1 }), .saveDraft(id: "d1", place: .file(place), text: "Hi")
        )
        XCTAssertEqual(Request(type: "editComment", body: ["id": "c1", "text": "Hi"]), .editComment(id: "c1", text: "Hi"))
        XCTAssertEqual(Request(type: "removeDraft", body: ["id": "d1", "text": NSNull()]), .removeDraft(id: "d1"))
        XCTAssertEqual(Request(type: "deleteComment", body: ["id": "c1"]), .deleteComment(id: "c1"))

        // An id that can't be a key of the review file, text that isn't,
        // a row that isn't one, half a range, a file neither on rows nor
        // on the whole file, an edit made a comment.
        XCTAssertNil(Request(type: "saveDraft", body: onRows.merging(["id": "../x"]) { $1 }))
        XCTAssertNil(Request(type: "saveDraft", body: onRows.merging(["text": 3]) { $1 }))
        XCTAssertNil(Request(type: "saveDraft", body: onRows.merging(["start": ["side": "both", "line": 2]]) { $1 }))
        XCTAssertNil(Request(type: "saveDraft", body: onRows.merging(["end": ["side": "additions", "line": 0]]) { $1 }))
        XCTAssertNil(Request(type: "saveDraft", body: ["id": "d1", "text": "Hi", "file": 0, "generation": 4, "start": rows["start"]!]))
        XCTAssertNil(Request(type: "addComment", body: ["id": "d1", "text": "Hi", "file": 0, "generation": 4]))
        XCTAssertNil(Request(type: "addComment", body: onRows.merging(["onFile": true]) { $1 }))
        XCTAssertNil(Request(type: "saveDraft", body: ["id": "d1", "text": "Hi", "generation": 4]))
        XCTAssertNil(Request(type: "addComment", body: ["id": "e1", "text": "Hi", "editing": "c1"]))
        XCTAssertNil(Request(type: "saveDraft", body: ["id": "e1", "text": "Hi", "editing": "c/1"]))
        XCTAssertNil(Request(type: "saveDraft", body: onRows.merging(["text": String(repeating: "x", count: 1_000_001)]) { $1 }))
    }

    // MARK: - What the column writes

    /// The page's fixture: in KeepAwake.swift, "import IOKit" (line 1, on
    /// both sides), "let a = 1" removed (line 2 of the base), "let a = 2"
    /// added (line 2).
    @MainActor
    private func page(
        _ snapshot: BranchReview.Snapshot = BranchReviewPageTests.snapshot(),
        patchReader: @escaping BranchReviewController.PatchReader = { _, _ in nil },
        branchCheck: @escaping BranchReviewController.BranchCheck = { _ in true }
    ) throws -> ReviewPage {
        let state = state!
        let repository = repository
        let page = try ReviewPage(snapshot: snapshot, handover: nil, patchReader: patchReader, reviewOpener: { snapshot in
            guard let store = Store(repository: repository, branch: snapshot.branch, stateDirectory: state) else { return nil }
            let history = BranchReview.History(isOwnCommit: { _ in true }, isInReflog: { _ in true })
            return (store, store.open(head: snapshot.head, pullRequest: snapshot.pullRequest, history: history))
        }, branchCheck: branchCheck)
        page.waitUntil("the review") { page.controller.review != nil }
        return page
    }

    private func store() throws -> Store {
        try XCTUnwrap(Store(repository: repository, branch: "feat/keep-awake", stateDirectory: state))
    }

    /// The review file with `change` made, as another column would have.
    private func stored(_ snapshot: BranchReview.Snapshot, _ change: @escaping (inout Record) -> Void) throws {
        let store = try store()
        let opened = store.open(head: snapshot.head, pullRequest: snapshot.pullRequest, history: BranchReview.History(
            isOwnCommit: { _ in true }, isInReflog: { _ in true }
        ))
        _ = store.update(try XCTUnwrap(opened.access), change)
    }

    /// Posts `body` to the column as the page does.
    @MainActor
    private func post(_ page: ReviewPage, _ body: [String: Any]) throws {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        _ = try page.run("window.webkit.messageHandlers.review.postMessage(\(json)); return '';")
    }

    /// Posts a request with the next click's sequence, and waits until the
    /// column answers it. Returns the sequence.
    @MainActor
    @discardableResult
    private func ask(_ page: ReviewPage, _ type: String, _ body: [String: Any]) throws -> Int {
        let sequence = page.controller.reviewAcknowledged + 1
        try post(page, body.merging(["type": type, "sequence": sequence]) { $1 })
        page.waitUntil("the answer to \(type)") { page.controller.reviewAcknowledged >= sequence }
        return sequence
    }

    /// Why the click `sequence` wasn't saved; nil when it was.
    @MainActor
    private func problem(_ page: ReviewPage, _ sequence: Int) -> String? {
        page.controller.commentProblems.first { $0.sequence == sequence }?.message
    }

    @MainActor
    func testDraftBecomesACommentWhereItsRowsWere() throws {
        let page = try page()
        defer { page.close() }
        let generation = page.controller.snapshotCount
        let rows: [String: Any] = [
            "file": 0, "generation": generation,
            "start": ["side": "deletions", "line": 2], "end": ["side": "additions", "line": 2]
        ]
        try ask(page, "saveDraft", rows.merging(["id": "d1", "text": "Why a"]) { $1 })
        let draft = try XCTUnwrap(store().load().record.draft(id: "d1"))
        XCTAssertEqual(draft.anchor?.rows.map(\.text), ["let a = 1", "let a = 2"])
        XCTAssertEqual(draft.text, "Why a")
        XCTAssertEqual(page.controller.pageComments?.map(\.id), ["d1"])

        // Comment: where the draft was fixed, whatever rows come with it.
        try ask(page, "addComment", ["id": "d1", "text": "Why a?"])
        let comment = try XCTUnwrap(store().load().record.comment(id: "d1"))
        XCTAssertEqual(comment.anchor, draft.anchor)
        XCTAssertEqual(comment.text, "Why a?")
        XCTAssertNil(try store().load().record.draft(id: "d1"))

        try ask(page, "saveDraft", ["id": "e1", "text": "Why a, really?", "editing": "d1"])
        XCTAssertEqual(try store().load().record.draft(id: "e1")?.editing, "d1")
        try ask(page, "editComment", ["id": "d1", "text": "Why a, really?"])
        XCTAssertEqual(try store().load().record.comment(id: "d1")?.text, "Why a, really?")
        XCTAssertNil(try store().load().record.draft(id: "e1"))

        // A comment on the file; then both deleted.
        try ask(page, "addComment", ["id": "c2", "text": "Split this file", "file": 0, "generation": generation, "onFile": true])
        XCTAssertEqual(try store().load().record.comment(id: "c2")?.anchor, .file("Sources/KeepAwake.swift"))
        try ask(page, "deleteComment", ["id": "d1"])
        try ask(page, "deleteComment", ["id": "c2"])
        XCTAssertTrue(try store().load().record.comments.isEmpty)
        XCTAssertTrue(page.controller.commentProblems.isEmpty)
    }

    @MainActor
    func testWhatCantBeSavedSaysWhy() throws {
        let page = try page()
        defer { page.close() }
        let generation = page.controller.snapshotCount
        // A row that isn't one of the diff's.
        var sequence = try ask(page, "saveDraft", [
            "id": "d1", "text": "Here", "file": 0, "generation": generation,
            "start": ["side": "additions", "line": 2], "end": ["side": "additions", "line": 9]
        ])
        XCTAssertEqual(page.controller.commentProblems.last?.id, "d1")
        XCTAssertEqual(
            problem(page, sequence),
            "These lines can’t take one comment: keep to one hunk, 100 lines and 32,000 bytes, or comment on the file."
        )
        // The page's data of before.
        sequence = try ask(page, "addComment", ["id": "c1", "text": "Here", "file": 0, "generation": generation - 1, "onFile": true])
        XCTAssertEqual(problem(page, sequence), "The diff changed since these lines were chosen: choose them again.")
        // A draft gone, and no place for a new one; nothing to say.
        sequence = try ask(page, "addComment", ["id": "c1", "text": "Here"])
        XCTAssertEqual(problem(page, sequence), "This draft is gone: write it again.")
        sequence = try ask(page, "addComment", ["id": "c1", "text": "  ", "file": 0, "generation": generation, "onFile": true])
        XCTAssertEqual(problem(page, sequence), "A comment needs some text.")
        // What the page sent that isn't a request is answered all the same.
        sequence = try ask(page, "addComment", ["id": "c1", "text": "Here", "file": "zero"])
        XCTAssertEqual(problem(page, sequence), "Nirux couldn’t read this request from the page: nothing was saved.")
        // An edit of a comment that isn't there.
        sequence = try ask(page, "editComment", ["id": "c9", "text": "Again"])
        XCTAssertEqual(page.controller.commentProblems.last, BranchReview.Page.CommentProblem(
            id: "c9", sequence: sequence, message: "This comment was sent or deleted meanwhile: it can’t be changed."
        ))
        XCTAssertNil(try store().load().record.comment(id: "c1"))
        XCTAssertNil(try store().load().record.draft(id: "d1"))

        // Saved: no problem for it, and those before stay.
        let saved = try ask(page, "addComment", ["id": "c1", "text": "Here", "file": 0, "generation": generation, "onFile": true])
        XCTAssertNil(problem(page, saved))
        XCTAssertNotNil(problem(page, sequence))
    }

    /// A refusal answered together with a save that follows it stays for
    /// the page, and so it does over a new read of the same branch.
    @MainActor
    func testRefusalOutlivesTheSavesAfterItAndANewRead() throws {
        let first = BranchReviewPageTests.snapshot()
        var added = BranchReview.FileChange(path: "Sources/Later.swift", status: .added)
        added.patchHash = "later"
        let reads = BranchReviewControllerTests.Answers(answers: [
            (.snapshot(first), nil), (.snapshot(BranchReviewControllerTests.snapshot(first, files: first.files + [added])), nil)
        ])
        let state = state!
        let repository = repository
        let page = try ReviewPage(reader: { _, _, _ in reads.next() }, reviewOpener: { snapshot in
            guard let store = Store(repository: repository, branch: snapshot.branch, stateDirectory: state) else { return nil }
            let history = BranchReview.History(isOwnCommit: { _ in true }, isInReflog: { _ in true })
            return (store, store.open(head: snapshot.head, pullRequest: snapshot.pullRequest, history: history))
        })
        defer { page.close() }
        page.waitUntil("the review") { page.controller.review?.canWrite == true }
        let generation = page.controller.snapshotCount
        let refused = page.controller.reviewAcknowledged + 1
        try post(page, ["type": "editComment", "sequence": refused, "id": "c9", "text": "Again"])
        try post(page, [
            "type": "saveDraft", "sequence": refused + 1, "id": "d1", "text": "Why?", "file": 0, "generation": generation, "onFile": true
        ])
        page.waitUntil("both answers") { page.controller.reviewAcknowledged >= refused + 1 }
        XCTAssertEqual(problem(page, refused), "This comment was sent or deleted meanwhile: it can’t be changed.")
        XCTAssertNil(problem(page, refused + 1))

        page.controller.worktreeChanged(.worktree)
        page.waitUntil("the next read") { page.controller.snapshot?.files.count == 4 }
        XCTAssertEqual(problem(page, refused), "This comment was sent or deleted meanwhile: it can’t be changed.")
    }

    /// A page that reads the branch again, its rows moved, before a new
    /// comment's first save: the rows are those of the page they were
    /// chosen in, of its last few, and found where they are now.
    @MainActor
    func testRowsChosenInAPageReplacedSinceAreThatPages() throws {
        let first = BranchReviewPageTests.snapshot()
        let moved = Self.moved(first)
        let page = try readingPage([first, moved])
        defer { page.close() }
        let chosen = page.controller.snapshotCount
        page.controller.worktreeChanged(.worktree)
        page.waitUntil("the next read") { page.controller.snapshotCount > chosen }
        let rows: [String: Any] = [
            "file": 0, "generation": chosen, "start": ["side": "additions", "line": 2], "end": ["side": "additions", "line": 2]
        ]
        let saved = try ask(page, "saveDraft", rows.merging(["id": "d1", "text": "Why 2?"]) { $1 })
        XCTAssertNil(problem(page, saved))
        XCTAssertEqual(try store().load().record.draft(id: "d1")?.anchor?.rows.map(\.text), ["let a = 2"])
        XCTAssertEqual(page.controller.pageComments?.first?.end, .init(side: "additions", line: 5))
        // A page this branch never showed (or one too old).
        let refused = try ask(page, "saveDraft", rows.merging(["id": "d2", "text": "Why?", "generation": chosen - 1]) { $1 })
        XCTAssertEqual(problem(page, refused), "The diff changed since these lines were chosen: choose them again.")
        XCTAssertEqual(page.controller.earlierFiles.map(\.generation), [chosen])
    }

    /// A new read of the branch, placed from what earlier reads placed: a
    /// comment in a file left as it was keeps its place, under the file's
    /// id in the new page; one in a file whose rows moved follows, and one
    /// whose file no longer differs reads so.
    @MainActor
    func testCommentsKeepUpWithNewReadsOfTheBranch() throws {
        let first = BranchReviewPageTests.snapshot()
        var added = BranchReview.FileChange(path: "Sources/Added.swift", status: .added)
        added.patchHash = "added"
        let inserted = BranchReviewControllerTests.snapshot(first, files: [added] + first.files)
        let moved = BranchReviewControllerTests.snapshot(first, files: [added] + Self.moved(first).files)
        let gone = BranchReviewControllerTests.snapshot(first, files: [added] + first.files.dropFirst())
        let kept = try XCTUnwrap(BranchReview.CommentAnchor(file: first.files[0], from: at(.additions, 2), to: at(.additions, 2)))
        try stored(first) { $0.addComment(id: "c1", anchor: kept, text: "Why 2?", at: self.date) }
        let page = try readingPage([first, inserted, moved, gone])
        defer { page.close() }
        XCTAssertEqual(page.controller.pageComments?.first?.file, 0)
        for (read, file, line) in [(2, 1, 2), (3, 1, 5), (4, nil, nil)] as [(Int, Int?, Int?)] {
            let before = page.controller.snapshotCount
            page.controller.worktreeChanged(.worktree)
            page.waitUntil("read \(read)") { page.controller.snapshotCount > before && page.controller.pageComments != nil }
            XCTAssertEqual(page.controller.pageComments?.first?.file, file, "read \(read)")
            XCTAssertEqual(page.controller.pageComments?.first?.end, line.map { .init(side: "additions", line: $0) }, "read \(read)")
        }
        XCTAssertEqual(page.controller.pageComments?.first?.placement, "fileGone")
    }

    /// What a new read changes for the placements: the files that differ,
    /// came or went, and the path a file was renamed from (a comment there
    /// read as gone, and is found in it now).
    func testChangedPathsTakeInWhatAFileWasRenamedFrom() {
        let same = file([hunk(old: 1, new: 1, ["+a"])], path: "Same.swift")
        let renamed = file([hunk(old: 1, new: 1, ["+b"])], path: "New.swift", oldPath: "Old.swift")
        XCTAssertEqual(BranchReview.PlacementCache.changedPaths(from: [same], to: [same, renamed]), ["New.swift", "Old.swift"])
        XCTAssertEqual(BranchReview.PlacementCache.changedPaths(from: [same, renamed], to: [same, renamed]), [])
    }

    /// The fixture with three lines added above KeepAwake.swift's hunk.
    private static func moved(_ snapshot: BranchReview.Snapshot) -> BranchReview.Snapshot {
        BranchReviewControllerTests.snapshot(snapshot, files: snapshot.files.map { file in
            guard file.path == "Sources/KeepAwake.swift" else { return file }
            var later = file
            later.patchHash = "moved"
            later.hunks = [BranchReview.Hunk(oldStart: 1, oldCount: 2, newStart: 4, newCount: 2, section: "", lines: file.hunks[0].lines)]
            return later
        })
    }

    /// A page whose reads of the branch answer `reads` in turn, its review
    /// opened.
    @MainActor
    private func readingPage(_ reads: [BranchReview.Snapshot]) throws -> ReviewPage {
        let answers = BranchReviewControllerTests.Answers(answers: reads.map { (.snapshot($0), nil) })
        let state = state!
        let repository = repository
        let page = try ReviewPage(reader: { _, _, _ in answers.next() }, reviewOpener: { snapshot in
            guard let store = Store(repository: repository, branch: snapshot.branch, stateDirectory: state) else { return nil }
            let history = BranchReview.History(isOwnCommit: { _ in true }, isInReflog: { _ in true })
            return (store, store.open(head: snapshot.head, pullRequest: snapshot.pullRequest, history: history))
        })
        page.waitUntil("the review") { page.controller.review?.canWrite == true && page.controller.pageComments != nil }
        return page
    }

    /// Where a comment was last found is recorded once the review opens,
    /// so that the next read looks for it from there: only in a review
    /// that has comments, never created for it.
    @MainActor
    func testCommentsFollowTheirRowsOnceTheReviewOpens() throws {
        let made = BranchReviewPageTests.snapshot()
        let kept = try XCTUnwrap(BranchReview.CommentAnchor(
            file: made.files[0], from: at(.additions, 2), to: at(.additions, 2)
        ))
        // Three lines added above since.
        let moved = BranchReviewControllerTests.snapshot(made, files: made.files.map { file in
            guard file.path == "Sources/KeepAwake.swift" else { return file }
            var later = file
            later.hunks = [BranchReview.Hunk(oldStart: 1, oldCount: 2, newStart: 4, newCount: 2, section: "", lines: file.hunks[0].lines)]
            return later
        })
        let store = try store()
        let opened = store.open(head: made.head, pullRequest: made.pullRequest, history: BranchReview.History(
            isOwnCommit: { _ in true }, isInReflog: { _ in true }
        ))
        _ = store.update(try XCTUnwrap(opened.access)) { $0.addComment(id: "c1", anchor: kept, text: "Why 2?", at: self.date) }

        let page = try page(moved)
        defer { page.close() }
        page.waitUntil("the move recorded") { store.load().record.comment(id: "c1")?.moved != nil }
        XCTAssertEqual(store.load().record.comment(id: "c1")?.moved?.rows.map(\.line), [5])
        XCTAssertEqual(page.controller.pageComments?.first?.end, .init(side: "additions", line: 5))
    }

    /// A comment on a file whose diff wasn't read with the page is placed
    /// once its row reads it, whether its rows moved since (where to is
    /// recorded then) or not (nothing to write).
    @MainActor
    func testCommentOnAFileNotReadIsPlacedOnceItsRowReadsIt() throws {
        let made = BranchReviewPageTests.snapshot()
        let kept = try XCTUnwrap(BranchReview.CommentAnchor(file: made.files[0], from: at(.additions, 2), to: at(.additions, 2)))
        let notRead = BranchReviewControllerTests.snapshot(made, files: made.files.map { file in
            guard file.path == made.files[0].path else { return file }
            var unread = file
            unread.hunks = []
            unread.patchHash = nil
            unread.omission = .notRead
            return unread
        })
        let store = try store()
        for (newStart, line) in [(4, 5), (1, 2)] {
            try? FileManager.default.removeItem(at: store.fileURL)
            var later = made.files[0]
            later.hunks = [BranchReview.Hunk(
                oldStart: 1, oldCount: 2, newStart: newStart, newCount: 2, section: "", lines: later.hunks[0].lines
            )]
            later.patchHash = "h9"
            let read = later
            let opened = store.open(head: made.head, pullRequest: made.pullRequest, history: BranchReview.History(
                isOwnCommit: { _ in true }, isInReflog: { _ in true }
            ))
            _ = store.update(try XCTUnwrap(opened.access)) { $0.addComment(id: "c1", anchor: kept, text: "Why 2?", at: self.date) }

            let page = try page(notRead, patchReader: { file, _ in file.path == read.path ? read : nil })
            defer { page.close() }
            page.waitUntil("the comments") { page.controller.pageComments != nil }
            XCTAssertEqual(page.controller.pageComments?.first?.placement, "unread")

            try post(page, ["type": "loadFile", "id": 0, "generation": page.controller.snapshotCount])
            page.waitUntil("the comment placed") { page.controller.pageComments?.first?.placement == "placed" }
            XCTAssertEqual(page.controller.pageComments?.first?.end, .init(side: "additions", line: line))
            if line != 2 {
                page.waitUntil("the move recorded") { store.load().record.comment(id: "c1")?.moved != nil }
            } else {
                XCTAssertNil(store.load().record.comment(id: "c1")?.moved, "nothing moved")
            }
        }
    }

    /// A file read on demand (folded, or past the page's size) has its
    /// hunks once its row reads them, its hash unchanged: its lines take a
    /// comment then.
    @MainActor
    func testFileReadOnDemandTakesComments() throws {
        let made = BranchReviewPageTests.snapshot()
        var read = made.files[1]
        read.hunks = [BranchReview.Hunk(oldStart: 10, oldCount: 1, newStart: 10, newCount: 2, section: "", lines: [
            .init(kind: .context, text: "\"pins\" : ["), .init(kind: .added, text: "{ \"identity\" : \"swift-log\" },")
        ])]
        let hunks = read
        XCTAssertEqual(read.patchHash, made.files[1].patchHash)
        XCTAssertEqual(made.files[1].omission, .onDemand)
        let page = try page(made, patchReader: { file, _ in file.path == hunks.path ? hunks : nil })
        defer { page.close() }
        let generation = page.controller.snapshotCount
        try post(page, ["type": "loadFile", "id": 1, "generation": generation])
        page.waitUntil("its hunks") { page.controller.readFiles[1] != nil }
        let sequence = try ask(page, "saveDraft", [
            "id": "d1", "text": "Pin it", "file": 1, "generation": generation,
            "start": ["side": "additions", "line": 11], "end": ["side": "additions", "line": 11]
        ])
        XCTAssertNil(problem(page, sequence))
        XCTAssertEqual(try store().load().record.draft(id: "d1")?.anchor?.path, "Package.resolved")
    }

    /// A request that isn't written (the review can't be, or the write
    /// fails) says why, so that the page keeps what was typed.
    @MainActor
    func testRequestNotWrittenSaysWhy() throws {
        let page = try page(branchCheck: { _ in nil })
        defer { page.close() }
        let sequence = try ask(page, "addComment", [
            "id": "c1", "text": "Here", "file": 0, "generation": page.controller.snapshotCount, "onFile": true
        ])
        XCTAssertEqual(page.controller.commentProblems.last, BranchReview.Page.CommentProblem(
            id: "c1", sequence: sequence, message: "Nirux couldn’t check that feat/keep-awake still exists. Try again."
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store().fileURL.path))
    }

    /// A request made, then not written (the review's folder refuses the
    /// file), says why too.
    @MainActor
    func testRequestWhoseWriteFailsSaysWhy() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        try stored(snapshot) { $0.addComment(id: "c0", anchor: .file("Sources/KeepAwake.swift"), text: "First", at: self.date) }
        let page = try page(snapshot)
        defer { page.close() }
        let folder = try store().folder.path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder) }
        let sequence = try ask(page, "addComment", [
            "id": "c1", "text": "Here", "file": 0, "generation": page.controller.snapshotCount, "onFile": true
        ])
        XCTAssertEqual(page.controller.commentProblems.last?.id, "c1")
        XCTAssertTrue(problem(page, sequence)?.hasPrefix("Nirux couldn’t save the review") == true, problem(page, sequence) ?? "")
        XCTAssertNil(try store().load().record.comment(id: "c1"), "not written")
    }

    /// A review full of comments and drafts takes no new one.
    @MainActor
    func testFullReviewTakesNoNewComment() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        try stored(snapshot) { record in
            for index in 0..<BranchReviewController.maxComments {
                record.addComment(id: "c\(index)", anchor: .file("Sources/KeepAwake.swift"), text: "Note \(index)", at: self.date)
            }
        }
        let page = try page(snapshot)
        defer { page.close() }
        let full = "This review holds 1000 comments and drafts: delete some to write more."
        let place: [String: Any] = ["file": 0, "generation": page.controller.snapshotCount, "onFile": true]
        var sequence = try ask(page, "saveDraft", ["id": "d1", "text": "One more"].merging(place) { $1 })
        XCTAssertEqual(problem(page, sequence), full)
        XCTAssertNil(try store().load().record.draft(id: "d1"))
        // An edit's draft is one more too; a refusal for another reason
        // says that reason.
        sequence = try ask(page, "saveDraft", ["id": "e1", "text": "Again", "editing": "c1"])
        XCTAssertEqual(problem(page, sequence), full)
        sequence = try ask(page, "editComment", ["id": "missing", "text": "Again"])
        XCTAssertEqual(problem(page, sequence), "This comment was sent or deleted meanwhile: it can’t be changed.")
        // Room again once one goes.
        try ask(page, "deleteComment", ["id": "c0"])
        sequence = try ask(page, "saveDraft", ["id": "d1", "text": "One more"].merging(place) { $1 })
        XCTAssertNil(problem(page, sequence))
    }

    /// A review takes no new comment once it holds three quarters of what
    /// a review file can: what is left keeps Reviewed marks, edits and
    /// deletes written.
    @MainActor
    func testLargeReviewTakesNoNewComment() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        // 80,000 bytes each.
        let text = String(repeating: "😀", count: 20_000)
        let count = BranchReviewController.maxBytesForNew / 80_000 + 1
        try stored(snapshot) { record in
            for index in 0..<count {
                record.addComment(id: "c\(index)", anchor: .file("Sources/KeepAwake.swift"), text: text, at: self.date)
            }
        }
        XCTAssertEqual(BranchReviewController.noRoom(try store().load().record), .tooLarge)
        XCTAssertNil(BranchReviewController.noRoom(Record()))
        let page = try page(snapshot)
        defer { page.close() }
        let place: [String: Any] = ["file": 0, "generation": page.controller.snapshotCount, "onFile": true]
        let sequence = try ask(page, "saveDraft", ["id": "d1", "text": "One more"].merging(place) { $1 })
        XCTAssertEqual(problem(page, sequence), "This review is too large to take another comment: delete some to write more.")
        // An edit of one goes, from its first draft.
        let draft = try ask(page, "saveDraft", ["id": "e0", "text": "Shorter", "editing": "c0"])
        XCTAssertNil(problem(page, draft))
        let edited = try ask(page, "editComment", ["id": "c0", "text": "Shorter"])
        XCTAssertNil(problem(page, edited))
    }

    /// The page takes Swift's data as what it answered: a click answered at
    /// once (one on a page of before) waits for the writes asked for before
    /// it.
    @MainActor
    func testAnswerWaitsForTheWritesBeforeIt() throws {
        let lockf = "/usr/bin/lockf"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: lockf), "no lockf")
        let page = try page()
        defer { page.close() }
        let store = try store()
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        // Another process holds the review's lock until its input closes.
        let holder = Process()
        let input = Pipe()
        holder.executableURL = URL(fileURLWithPath: lockf)
        holder.arguments = ["-k", store.lockURL.path, "/bin/sh", "-c", "read line"]
        holder.standardInput = input
        try holder.run()
        defer {
            try? input.fileHandleForWriting.close()
            holder.waitUntilExit()
        }
        page.waitUntil("the lock held") {
            let probe = open(store.lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard probe >= 0 else { return false }
            defer { close(probe) }
            return flock(probe, LOCK_EX | LOCK_NB) != 0
        }
        let generation = page.controller.snapshotCount
        let first = page.controller.reviewAcknowledged + 1
        try post(page, ["type": "saveDraft", "sequence": first, "id": "d1", "text": "Why?", "file": 0, "generation": generation, "onFile": true])
        try post(page, ["type": "reviewed", "sequence": first + 1, "ids": [0], "reviewed": true, "generation": generation - 1])
        // Both clicks taken (a script's answer comes after the messages it
        // posted); the write waits for the lock.
        _ = try page.run("return '';")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertLessThan(page.controller.reviewAcknowledged, first, "answered before the draft was written")
        try? input.fileHandleForWriting.close()
        page.waitUntil("the answers") { page.controller.reviewAcknowledged >= first + 1 }
        XCTAssertNotNil(store.load().record.draft(id: "d1"))
    }

    @MainActor
    func testReviewWithoutCommentsIsntCreated() throws {
        let page = try page()
        defer { page.close() }
        // Asked of a review not created yet: nothing to remove or change.
        try ask(page, "removeDraft", ["id": "d0"])
        try ask(page, "deleteComment", ["id": "c0"])
        try ask(page, "editComment", ["id": "c0", "text": "Again"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store().fileURL.path))
        XCTAssertEqual(page.controller.review?.canWrite, true)
    }
}
