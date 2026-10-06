import XCTest
@testable import Nirux

/// Comments and drafts (docs/branch-review.md, section 6.1): what can be
/// written, edited, sent and deleted, and how the review file keeps them.
final class BranchReviewCommentsTests: XCTestCase, CommentFixtures {
    private typealias Record = BranchReview.Record

    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    private let later = Date(timeIntervalSince1970: 1_790_000_600)

    // MARK: - Drafts and comments

    func testDraftIsStoredAsTypedAndBecomesAComment() throws {
        var record = Record()
        let clicked = try lineAnchor()
        XCTAssertTrue(record.saveDraft(id: "d1", anchor: clicked, text: "  Why not", at: date))
        XCTAssertEqual(record.draft(id: "d1")?.text, "  Why not", "as typed")

        // Later saves, and the comment, keep where the draft was made,
        // whatever the page sends.
        let elsewhere = try lineAnchor("let other = 9")
        XCTAssertTrue(record.saveDraft(id: "d1", anchor: elsewhere, text: "  Why not a guard?\n", at: later))
        XCTAssertEqual(record.draft(id: "d1")?.anchor, clicked)
        XCTAssertTrue(record.saveDraft(id: "d1", anchor: elsewhere, text: "  Why not a guard?\n", at: later.addingTimeInterval(60)))
        XCTAssertEqual(record.draft(id: "d1")?.updated, later, "the same text again changes nothing")

        XCTAssertTrue(record.addComment(id: "d1", anchor: elsewhere, text: "  Why not a guard?\n", at: later))
        XCTAssertNil(record.draft(id: "d1"))
        XCTAssertEqual(record.comments, [BranchReview.Comment(id: "d1", anchor: clicked, text: "Why not a guard?", created: later, updated: later)])

        XCTAssertFalse(record.addComment(id: "d1", anchor: clicked, text: "Again", at: later), "taken")
        XCTAssertFalse(record.addComment(id: "d2", anchor: clicked, text: " \n ", at: later), "empty")
        XCTAssertFalse(record.addComment(id: "d/2", anchor: clicked, text: "Bad id", at: later))
        XCTAssertFalse(record.saveDraft(id: String(repeating: "a", count: 65), anchor: clicked, text: "x", at: date))

        XCTAssertTrue(record.saveDraft(id: "d3", anchor: clicked, text: "Gone", at: date))
        XCTAssertTrue(record.saveDraft(id: "d3", anchor: clicked, text: "", at: date))
        XCTAssertNil(record.draft(id: "d3"), "emptied")
    }

    func testCommentKeepsWhereItsDraftWasLastFound() throws {
        var record = Record()
        let kept = [" let a = 1", "+let b = 2", " let c = 3"]
        let clicked = try anchor([hunk(old: 1, new: 1, kept)], at(.additions, 2))
        record.saveDraft(id: "d1", anchor: clicked, text: "Typing", at: date)
        record.reanchor(in: [file([hunk(old: 1, new: 6, kept)])])
        let moved = try XCTUnwrap(record.draft(id: "d1")?.moved)

        record.addComment(id: "d1", anchor: clicked, text: "Typed", at: later)
        XCTAssertEqual(record.comment(id: "d1")?.moved, moved)
    }

    /// A save the page sent before Comment, arriving after it, mustn't
    /// leave a draft no comment can be made from.
    func testDraftCantTakeACommentsID() throws {
        var record = Record()
        record.addComment(id: "c1", anchor: try lineAnchor(), text: "Done", at: date)
        XCTAssertFalse(record.saveDraft(id: "c1", anchor: try lineAnchor(), text: "Don", at: later))
        XCTAssertEqual(record.drafts, [])

        // And an edit's draft never becomes a comment of its own.
        record.saveDraft(id: "e1", anchor: try lineAnchor(), text: "Done!", editing: "c1", at: later)
        XCTAssertFalse(record.addComment(id: "e1", anchor: try lineAnchor(), text: "Done!", at: later))
        XCTAssertNil(record.comment(id: "e1"))
    }

    func testUnstorableAnchorsAreRefused() throws {
        var record = Record()
        let rows = (1...(Anchor.maxRows + 1)).map { row(.added, 1, $0, "x") }
        let anchors = [
            Anchor.file(""), Anchor(path: "a.swift", rows: rows, before: [], after: []),
            Anchor(path: "a.swift", rows: [row(.added, 1, 0, "x")], before: [], after: [])
        ]
        for anchor in anchors {
            XCTAssertFalse(record.addComment(id: "c1", anchor: anchor, text: "x", at: date))
            XCTAssertFalse(record.saveDraft(id: "d1", anchor: anchor, text: "x", at: date))
        }
        XCTAssertNil(record.fields["comments"])
        XCTAssertNil(record.fields["drafts"])
    }

    func testTextIsCutThenTrimmed() throws {
        var record = Record()
        let limit = BranchReview.Comment.maxCharacters
        record.addComment(id: "c1", anchor: try lineAnchor(), text: String(repeating: "a", count: limit - 1) + " b", at: date)
        XCTAssertEqual(record.comment(id: "c1")?.text, String(repeating: "a", count: limit - 1))

        record.saveDraft(id: "d1", anchor: try lineAnchor(), text: String(repeating: "é", count: limit + 1), at: date)
        XCTAssertEqual(record.draft(id: "d1")?.text.count, limit)
        record.saveDraft(id: "d2", anchor: try lineAnchor(), text: String(repeating: "👨‍👩‍👧", count: limit), at: date)
        let heavy = try XCTUnwrap(record.draft(id: "d2")?.text.utf8.count)
        XCTAssertLessThanOrEqual(heavy, BranchReview.Comment.maxBytes)
        XCTAssertGreaterThan(heavy, BranchReview.Comment.maxBytes - 18)
    }

    func testOnlyAnUnsentCommentCanBeEdited() throws {
        var record = Record()
        let made = try lineAnchor()
        record.addComment(id: "c1", anchor: made, text: "First", at: date)

        XCTAssertTrue(record.saveDraft(id: "e1", anchor: .file("other.swift"), text: "First, edited", editing: "c1", at: later))
        XCTAssertNil(record.draft(id: "e1")?.anchor, "an edit is where its comment is")
        XCTAssertFalse(record.saveDraft(id: "e1", anchor: made, text: "Now a new one", at: later), "saved for something else")
        XCTAssertTrue(record.editComment(id: "c1", text: "First, edited", at: later))
        XCTAssertNil(record.draft(id: "e1"), "the edit's draft goes")
        XCTAssertEqual(record.comment(id: "c1")?.text, "First, edited")
        XCTAssertEqual(record.comment(id: "c1")?.updated, later)
        XCTAssertEqual(record.comment(id: "c1")?.created, date)
        // The same text: nothing to record, and the draft still goes.
        record.saveDraft(id: "e2", anchor: made, text: "First, edited", editing: "c1", at: later)
        XCTAssertTrue(record.editComment(id: "c1", text: "First, edited", at: later.addingTimeInterval(60)))
        XCTAssertEqual(record.comment(id: "c1")?.updated, later)
        XCTAssertNil(record.draft(id: "e2"))

        XCTAssertFalse(record.saveDraft(id: "e3", anchor: made, text: "x", editing: "gone", at: later))
        XCTAssertFalse(record.editComment(id: "c1", text: "  ", at: later))

        record.markSent(ids: ["c1"], head: "db9ac66", at: later)
        XCTAssertFalse(record.editComment(id: "c1", text: "Changed after sending", at: later))
        XCTAssertFalse(record.saveDraft(id: "e4", anchor: made, text: "Changed", editing: "c1", at: later))
        XCTAssertEqual(record.comment(id: "c1")?.text, "First, edited")
        XCTAssertEqual(record.comment(id: "c1")?.sent, BranchReview.SentMark(date: later, head: "db9ac66"))
    }

    /// Sending under an edit: the comment goes as it was, and what was
    /// being typed becomes a new comment's draft rather than lost.
    func testSendingTurnsAnEditIntoANewCommentsDraft() throws {
        var record = Record()
        let kept = [" let a = 1", "+let b = 2", " let c = 3"]
        let made = try anchor([hunk(old: 1, new: 1, kept)], at(.additions, 2))
        record.addComment(id: "c1", anchor: made, text: "First", at: date)
        record.reanchor(in: [file([hunk(old: 1, new: 6, kept)])])
        let moved = try XCTUnwrap(record.comment(id: "c1")?.moved)
        record.saveDraft(id: "e1", anchor: made, text: "First, and more", editing: "c1", at: later)
        record.saveDraft(id: "e2", anchor: made, text: "First ", editing: "c1", at: later)

        XCTAssertEqual(record.markSent(ids: ["c1", "gone", "c1"], head: "db9ac66", at: later), ["c1"])
        let draft = try XCTUnwrap(record.draft(id: "e1"))
        XCTAssertNil(draft.editing)
        XCTAssertEqual(draft.anchor, made)
        XCTAssertEqual(draft.moved, moved)
        XCTAssertEqual(draft.text, "First, and more")
        XCTAssertNil(record.fields["drafts"]?.objectValue?["e2"], "an edit that changed nothing goes")
        XCTAssertTrue(record.addComment(id: "e1", anchor: .file("x.swift"), text: draft.text, at: later))
        XCTAssertEqual(record.comment(id: "e1")?.anchor, made)
    }

    func testEditOfASentCommentIsLeftOutAndCanBeCleared() throws {
        var record = Record()
        let made = try lineAnchor()
        record.addComment(id: "c1", anchor: made, text: "First", at: date)
        // Written by another Nirux, which sent c1 without this one's
        // `markSent`.
        let edit = BranchReview.Draft(id: "e1", anchor: nil, text: "x", updated: date, editing: "c1")
        record.fields["drafts"] = .object(["e1": edit.json(over: nil)])
        var sent = try XCTUnwrap(record.comment(id: "c1"))
        sent.sent = BranchReview.SentMark(date: later, head: "db9ac66")
        record.fields["comments"] = .object(["c1": sent.json(over: nil)])

        XCTAssertEqual(record.drafts, [])
        XCTAssertTrue(record.saveDraft(id: "e1", anchor: made, text: "", editing: "c1", at: later))
        XCTAssertNil(record.fields["drafts"])
    }

    func testDeletingACommentTakesItsDraftsAlong() throws {
        var record = Record()
        let made = try lineAnchor()
        record.addComment(id: "c1", anchor: made, text: "One", at: date)
        record.saveDraft(id: "e1", anchor: made, text: "One more", editing: "c1", at: later)
        record.saveDraft(id: "d2", anchor: made, text: "Another", at: later)
        record.addComment(id: "c3", anchor: made, text: "Sent", at: date)
        record.markSent(ids: ["c3"], head: "db9ac66", at: later)

        record.deleteComment(id: "c1")
        record.deleteComment(id: "c3")
        XCTAssertEqual(record.comments, [])
        XCTAssertEqual(record.fields["drafts"]?.objectValue?.keys.sorted(), ["d2"], "gone from the file, not just hidden")
        XCTAssertNil(record.fields["comments"], "no empty object left")
    }

    func testReanchoringRecordsMovesAndKeepsWhatIsOutdated() throws {
        var record = Record()
        let kept = [" let a = 1", "+let b = 2", " let c = 3"]
        let moving = try anchor([hunk(old: 1, new: 1, kept)], at(.additions, 2))
        let fixed = try XCTUnwrap(Anchor(
            file: file([hunk(old: 1, new: 1, [" let x = 1", "+let y = 2", " let z = 3"])], path: "b.swift"),
            from: at(.additions, 2), to: at(.additions, 2)
        ))
        record.addComment(id: "c1", anchor: moving, text: "Moves", at: date)
        record.addComment(id: "c2", anchor: fixed, text: "Answered", at: date)
        record.saveDraft(id: "d1", anchor: moving, text: "Typing", at: date)
        record.addComment(id: "c3", anchor: .file("gone.swift"), text: "File", at: date)

        let files = [
            file([hunk(old: 1, new: 6, kept)]),
            file([hunk(old: 1, new: 1, [" let x = 1", "+let Y = 2", " let z = 3"])], path: "b.swift")
        ]
        XCTAssertTrue(record.reanchor(in: files))
        XCTAssertEqual(record.comment(id: "c1")?.current.rows.map(\.line), [7])
        XCTAssertEqual(record.comment(id: "c1")?.anchor, moving, "where it was made stays")
        XCTAssertEqual(record.draft(id: "d1")?.moved?.rows.map(\.line), [7])
        XCTAssertNil(record.comment(id: "c2")?.moved, "outdated: keeps its excerpt")
        XCTAssertEqual(record.comment(id: "c3")?.current, .file("gone.swift"))
        XCTAssertFalse(record.reanchor(in: files), "nothing moved since")

        // Back where they were made.
        XCTAssertTrue(record.reanchor(in: [file([hunk(old: 1, new: 1, kept)])]))
        XCTAssertNil(record.comment(id: "c1")?.moved)
        XCTAssertNil(record.draft(id: "d1")?.moved)
    }

    /// A file read records where the comments on it are, not the others';
    /// a review opened at another head since records nothing.
    func testReanchoringKeepsToItsPathsAndItsHead() throws {
        let kept = [" let a = 1", "+let b = 2", " let c = 3"]
        var record = Record()
        record.stamp(branch: "b", repository: "/r/.git", head: "aaa", pullRequest: nil)
        record.addComment(id: "c1", anchor: try anchor([hunk(old: 1, new: 1, kept)], at(.additions, 2)), text: "A", at: date)
        record.addComment(id: "c2", anchor: try XCTUnwrap(Anchor(
            file: file([hunk(old: 1, new: 1, kept)], path: "b.swift"), from: at(.additions, 2), to: at(.additions, 2)
        )), text: "B", at: date)
        let files = [file([hunk(old: 1, new: 6, kept)]), file([hunk(old: 1, new: 6, kept)], path: "b.swift")]
        var other = record
        BranchReviewController.reanchor(&other, in: files, paths: nil, at: "bbb")
        XCTAssertNil(other.comment(id: "c1")?.moved, "opened at another head since")
        BranchReviewController.reanchor(&record, in: files, paths: ["b.swift"], at: "aaa")
        XCTAssertNil(record.comment(id: "c1")?.moved)
        XCTAssertEqual(record.comment(id: "c2")?.moved?.rows.map(\.line), [7])
    }

    /// Found from where it was last found, back on the rows it was made on
    /// but with other rows around them: that is recorded, or the next read,
    /// with nothing changed, would look for it only from where it was made,
    /// and not find it.
    func testCommentBackOnItsRowsAmongNewNeighborsIsStillFound() throws {
        func source(imports: [String] = [], above: String = "read(url)", below: String = "cache(model)") -> [BranchReview.Hunk] {
            [hunk(old: 0, new: 1, imports + [
                "+func load() -> Model? {", "+    let url = locate()", "+    let data = \(above)",
                "+    guard let model = decode(data) else { return nil }", "+    \(below)", "+    return model", "+}"
            ])]
        }
        var record = Record()
        record.addComment(id: "c1", anchor: try anchor(source(), at(.additions, 4)), text: "Check", at: date)
        // An import added above, the line above edited, then the import
        // removed and the line below edited.
        let last = source(above: "try read(url)", below: "cache(model, for: url)")
        for hunks in [source(imports: ["+import Foundation"]), source(imports: ["+import Foundation"], above: "try read(url)"), last] {
            record.reanchor(in: [file(hunks)])
        }
        let comment = try XCTUnwrap(record.comment(id: "c1"))
        XCTAssertEqual(comment.moved?.rows.map(\.line), [4], "back on its rows, among new neighbors")
        XCTAssertEqual(placed(comment.anchor, last, moved: comment.moved), [4])
        XCTAssertFalse(record.reanchor(in: [file(last)]), "nothing moved since")
    }

    /// Where it was last found is recorded only when it finds the comment
    /// where it is: back on its rows as made, with a twin pasted since, the
    /// search from where it was made alone would leave it outdated on the
    /// next read, with nothing changed.
    func testWhatIsRecordedFindsTheCommentAgain() throws {
        func block(_ first: String = "o()") -> [String] {
            [" let w = \(first)", " let x = p()", "+act()", " let y = q()", " let z = r()"]
        }
        var record = Record()
        record.addComment(id: "c1", anchor: try anchor([hunk(old: 10, new: 10, block())], at(.additions, 12)), text: "Why?", at: date)
        record.reanchor(in: [file([hunk(old: 10, new: 10, block("o2()"))])])
        XCTAssertNotNil(record.comment(id: "c1")?.moved)
        // Its neighbor back as it was, and the block pasted further down.
        let pasted = [hunk(old: 10, new: 10, block()), hunk(old: 50, new: 50, block().map { "+" + $0.dropFirst() })]
        for _ in 0..<2 {
            record.reanchor(in: [file(pasted)])
            let comment = try XCTUnwrap(record.comment(id: "c1"))
            XCTAssertEqual(placed(comment.anchor, pasted, moved: comment.moved), [12])
        }
    }

    // MARK: - In the review file

    func testAnchorReadFromTheFileIsCheckedAndCut() throws {
        func anchor(_ rows: [JSONValue], before: [JSONValue] = []) -> Anchor? {
            Anchor(json: .object(["path": .string("a.swift"), "rows": .array(rows), "before": .array(before)]))
        }
        func row(_ kind: String, _ new: JSONValue, _ text: String = "x") -> JSONValue {
            .object(["kind": .string(kind), "old": .int(1), "new": new, "text": .string(text)])
        }
        XCTAssertNil(anchor([row("added", .int(0))]))
        XCTAssertNil(anchor([row("added", .int(-3))]))
        XCTAssertNil(anchor([row("added", .double(3.5))]))
        XCTAssertNil(anchor([row("moved", .int(3))]))
        XCTAssertNil(anchor([.object(["kind": .string("added"), "new": .int(3), "text": .string("x")])]), "no old line")
        XCTAssertEqual(anchor([row("added", .double(3))])?.rows, [self.row(.added, 1, 3, "x")])
        // A later build's longer ranges and texts read here, cut.
        XCTAssertEqual(anchor((1...(Anchor.maxRows + 1)).map { row("added", .int(Int64($0))) })?.rows.count, Anchor.maxRows + 1)
        let long = String(repeating: "y", count: Anchor.maxRowCharacters + 5)
        XCTAssertEqual(anchor([row("added", .int(1), long)])?.rows.first?.text, Anchor.cut(long))
        XCTAssertEqual(anchor([row("added", .int(1))], before: [.string(long)])?.before, [Anchor.cut(long)])
        XCTAssertEqual(anchor([row("added", .int(1))], before: [.string("a"), .int(1), .string("b")])?.before, [], "context with a hole")
    }

    func testDraftReadFromTheFileIsChecked() throws {
        let made = try lineAnchor()
        func draft(_ fields: [String: JSONValue]) -> BranchReview.Draft? {
            BranchReview.Draft(id: "d1", json: .object(fields.merging(["text": .string("x"), "updated": .string("2026-10-04T10:00:00Z")]) { $1 }))
        }
        XCTAssertNotNil(draft(["anchor": made.json]))
        XCTAssertNotNil(draft(["editing": .string("c1")]))
        XCTAssertNil(draft([:]), "a new comment's draft without an anchor")
        XCTAssertNil(draft(["anchor": made.json, "editing": .object(["id": .string("c1")])]), "not read as a new comment's")
        XCTAssertNil(draft(["anchor": made.json, "editing": .string("c/1")]))

        var record = Record()
        let hidden = BranchReview.Comment(id: "x", anchor: made, text: "x", created: date, updated: date)
        record.fields["comments"] = .object(["bad/id": hidden.json(over: nil)])
        XCTAssertNil(record.comment(id: "bad/id"))
        XCTAssertFalse(record.editComment(id: "bad/id", text: "y", at: later))
        record.fields["drafts"] = .object(["bad/id": BranchReview.Draft(id: "x", anchor: made, text: "x", updated: date).json(over: nil)])
        XCTAssertNil(record.draft(id: "bad/id"))

        // A copy's rank is kept with it.
        let block = [" func testReset() {", "+    store.reset()", " }"]
        let copy = try anchor([hunk(old: 10, new: 10, block), hunk(old: 50, new: 50, block)], at(.additions, 51))
        record.addComment(id: "c2", anchor: copy, text: "Copy", at: date)
        XCTAssertEqual(record.comment(id: "c2")?.anchor.copy, BranchReview.CopyRank(index: 1, count: 2))
        XCTAssertNil(Anchor(json: .object(["path": .string("a.swift"), "rows": .array([]), "copy": .object(["index": .int(2), "count": .int(2)])])))
        // And a near copy's score.
        let near = try anchor([
            hunk(old: 10, new: 10, [" p()", " q()", "+    return nil", " r()"]), hunk(old: 50, new: 50, [" p()", " q9()", "+    return nil", " r()"])
        ], at(.additions, 12))
        record.addComment(id: "c3", anchor: near, text: "Near", at: date)
        XCTAssertEqual(record.comment(id: "c3")?.anchor.rival, 1)
        // And how many frames stood elsewhere.
        func setUp(_ client: String) -> [String] {
            [" func setUp() {", " super.setUp()", "+client = \(client)", " user = makeUser()", " url = base"]
        }
        let framed = try anchor([hunk(old: 10, new: 10, setUp("Client()")), hunk(old: 40, new: 40, setUp("Client(auth: true)"))], at(.additions, 12))
        record.addComment(id: "c4", anchor: framed, text: "Framed", at: date)
        XCTAssertEqual(record.comment(id: "c4")?.anchor.frames, 1)
        // And the landmark that tells a copy, which a null leaves out.
        func test(_ name: String) -> [String] {
            ["+func test\(name)() {", "+    let store = Store()", "+    store.reset()", "+    XCTAssertTrue(store.isEmpty)", "+}"]
        }
        let named = try anchor([hunk(old: 0, new: 1, test("A") + test("B"))], at(.additions, 9))
        XCTAssertNotNil(named.copy?.landmark)
        XCTAssertEqual(Anchor(json: named.json), named)
        guard case .object(var object) = named.json, case .object(var rank)? = object["copy"] else { return XCTFail("no copy") }
        rank["landmark"] = .null
        object["copy"] = .object(rank)
        XCTAssertEqual(Anchor(json: .object(object))?.copy, BranchReview.CopyRank(index: 1, count: 2))
    }

    func testCommentsAndDraftsGoThroughTheReviewFile() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-review-comments-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let store = try XCTUnwrap(BranchReview.Store(repository: "/repos/widgets/.git", branch: "feat/x", stateDirectory: state))
        let access = try XCTUnwrap(store.open(head: "a1", pullRequest: .notFound, history: BranchReview.History(
            isOwnCommit: { _ in true }, isInReflog: { _ in true }
        )).access)
        let made = try lineAnchor()

        // The older comment has the larger id: the order is by date.
        let written = try store.update(access) { record in
            record.addComment(id: "z1", anchor: made, text: "Why?", at: self.date)
            record.addComment(id: "a2", anchor: .file("a.swift"), text: "Test this file.", at: self.later)
            record.saveDraft(id: "d1", anchor: made, text: "Half a thou", at: self.later)
        }.get()
        let loaded = store.load().record
        XCTAssertEqual(loaded.comments, written.record.comments)
        XCTAssertEqual(loaded.comments.map(\.id), ["z1", "a2"], "oldest first")
        XCTAssertEqual(loaded.drafts, written.record.drafts)

        // A later build's keys, in an entry, its anchor or its mark, and
        // entries this build can't read, stay.
        var fields = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: store.fileURL))
        var comments = try XCTUnwrap(fields["comments"]?.objectValue)
        var z1 = try XCTUnwrap(comments["z1"]?.objectValue)
        var anchor = try XCTUnwrap(z1["anchor"]?.objectValue)
        anchor["section"] = .string("func load()")
        z1["anchor"] = .object(anchor)
        z1["reaction"] = .string("👍")
        z1["sent"] = .object(["date": .string("2026-10-04T10:00:00Z"), "head": .string("a0"), "target": .string("claude")])
        comments["z1"] = .object(z1)
        comments["broken"] = .object(["text": .string("no anchor")])
        comments["sentBadly"] = .object([
            "anchor": made.json, "text": .string("x"), "created": .string("2026-10-04T10:00:00Z"), "sent": .string("yes")
        ])
        comments["bad/id"] = .object(["anchor": made.json, "text": .string("x"), "created": .string("2026-10-04T10:00:00Z")])
        fields["comments"] = .object(comments)
        try JSONEncoder().encode(fields).write(to: store.fileURL)

        let next = try XCTUnwrap(written.access)
        let moved = try store.update(next) { record in
            XCTAssertFalse(record.addComment(id: "broken", anchor: made, text: "Over it", at: self.later), "its id is taken")
            record.markSent(ids: ["z1"], head: "b2", at: self.later)
            record.reanchor(in: [self.file([self.hunk(old: 1, new: 4, [" let a = 1", "+let b = 2", " let c = 3"])])])
        }.get()
        XCTAssertEqual(moved.record.comment(id: "z1")?.current.rows.map(\.line), [5])
        let stored = try XCTUnwrap(store.load().record.fields["comments"]?.objectValue)
        let entry = try XCTUnwrap(stored["z1"]?.objectValue)
        XCTAssertEqual(entry["reaction"], .string("👍"))
        XCTAssertEqual(entry["anchor"]?.objectValue?["section"], .string("func load()"))
        XCTAssertEqual(entry["sent"]?.objectValue?["target"], .string("claude"))
        XCTAssertEqual(entry["sent"]?.objectValue?["head"], .string("b2"))
        XCTAssertEqual(stored["broken"], .object(["text": .string("no anchor")]))
        XCTAssertEqual(store.load().record.comments.map(\.id), ["z1", "a2"], "a malformed `sent` hides its comment, and so does a bad id")
    }
}
