import XCTest
@testable import Nirux

/// Claude's notes under the hunks they explain, and marking them wrong
/// (docs/branch-review.md, section 4.3).
final class BranchReviewExplainNotesTests: XCTestCase {
    static let usage = "[...document.querySelectorAll('.explain-usage')].map((line) => line.textContent).join('|')"
    static let keepAwakeRow = "document.querySelector('.file[data-path=\"Sources/KeepAwake.swift\"] .file-row')"

    /// A note sits under its hunk's last changed line: an addition by its
    /// new number, a removal by its old one.
    func testANoteSitsUnderItsHunksLastChangedLine() {
        func hunk(_ kinds: [BranchReview.Line.Kind], old: Int = 10, new: Int = 20) -> BranchReview.Hunk {
            .init(oldStart: old, oldCount: 0, newStart: new, newCount: 0, section: "", lines: kinds.map { .init(kind: $0, text: "x") })
        }
        XCTAssertEqual(BranchReview.lastChangedLine(of: hunk([.context, .removed, .added, .context]))?.side, "additions")
        XCTAssertEqual(BranchReview.lastChangedLine(of: hunk([.context, .removed, .added, .context]))?.number, 21)
        XCTAssertEqual(BranchReview.lastChangedLine(of: hunk([.added, .removed, .context]))?.side, "deletions")
        XCTAssertEqual(BranchReview.lastChangedLine(of: hunk([.added, .removed, .context]))?.number, 10)
        XCTAssertEqual(BranchReview.lastChangedLine(of: hunk([.removed, .removed, .noNewlineMarker]))?.number, 11)
        XCTAssertNil(BranchReview.lastChangedLine(of: hunk([.context])))
    }

    /// Found by its hunk's changed lines, wherever the hunk moved; hidden
    /// when no hunk has them, or when the note has no anchor.
    func testNotesFollowTheirHunkByItsAnchor() throws {
        let file = try XCTUnwrap(BranchReviewPageTests.snapshot().files.first)
        let anchor = BranchReview.hunkAnchor(try XCTUnwrap(file.hunks.first))
        var explanation = BranchReviewExplainPageTests.explanation()
        explanation.files[file.path] = .init(patchHash: "older", summary: "S.", importance: 2, notes: [
            .init(id: "kept", hunk: 3, anchor: anchor, text: "Sets a.", check: "Is a used?", isWrong: true),
            .init(id: "gone", hunk: 0, anchor: "0000000000000000", text: "Elsewhere.", check: nil),
            .init(id: "old", hunk: 0, anchor: nil, text: "No anchor.", check: nil)
        ], head: "bbb", model: "claude-sonnet-5-5")
        XCTAssertEqual(BranchReview.diffNotes(for: file, explanation: explanation), [.init(
            id: "kept", side: "additions", lineNumber: 2, text: "Sets a.", check: "Is a used?", isWrong: true,
            model: "Sonnet 5.5", head: "bbb"
        )])
        XCTAssertEqual(BranchReview.diffNotes(for: file, explanation: nil), [])
    }

    /// A mark counts once, and its undo takes it back.
    func testMarkingANoteWrongCountsOnce() {
        var explanation = BranchReviewExplainPageTests.explanation()
        explanation.files["a"] = .init(patchHash: "h", summary: nil, importance: nil, notes: [
            .init(id: "n1", hunk: 0, anchor: "x", text: "T.", check: nil)
        ])
        XCTAssertTrue(explanation.mark(note: "n1", wrong: true))
        XCTAssertFalse(explanation.mark(note: "n1", wrong: true))
        XCTAssertEqual(explanation.wrongCount, 1)
        XCTAssertEqual(explanation.note(id: "n1")?.isWrong, true)
        XCTAssertTrue(explanation.mark(note: "n1", wrong: false))
        XCTAssertEqual(explanation.wrongCount, 0)
        XCTAssertFalse(explanation.mark(note: "unknown", wrong: true))
    }

    /// On the page: the note under its line, Claude's text as text, and
    /// Mark wrong written to the review file, counted, then undone. Shown
    /// again with the same notes, the diff isn't read again.
    @MainActor
    func testNotesShowUnderTheirLinesAndAreMarkedWrongFromThePage() throws {
        let (page, store, path, cleanUp) = try Self.pageWithANote()
        defer { cleanUp() }
        _ = try page.run("\(Self.keepAwakeRow).click(); return ''")
        XCTAssertEqual(
            try page.waitFor("document.querySelector('.note')", then: "[...document.querySelectorAll('.note-text')].map((n) => n.textContent).join('|')"),
            "Sets <b>a</b> to 2.|Is <i>a</i> read?"
        )
        XCTAssertEqual(try page.run("return String(document.querySelectorAll('.note b, .note i').length)"), "0")
        XCTAssertEqual(try page.run("return document.querySelector('.note .source').textContent"), "Claude · Opus 5.5 · read aaaaaaa")

        _ = try page.run("document.querySelector('.note .more').click(); return ''")
        XCTAssertEqual(try page.run("return document.querySelector('.note').className"), "note wrong")
        page.waitUntil("the mark written") { store.load().record.explanation?.files[path]?.notes.first?.isWrong == true }
        XCTAssertEqual(store.load().record.explanation?.wrongCount, 1)
        XCTAssertEqual(
            try page.waitFor("document.querySelector('.explain-usage')?.textContent.includes('marked wrong')", then: Self.usage),
            "Claude’s notes marked wrong: 1 of 4"
        )

        // The same notes again: the diff drawn stays.
        let loadFile = page.controller.view.onLoadFile
        var loads = 0
        page.controller.view.onLoadFile = { id, generation in
            loads += 1
            loadFile?(id, generation)
        }
        _ = try page.run("document.querySelector('.groups').dataset.mark = 'before'; return ''")
        page.controller.reload()
        _ = try page.waitFor("!document.querySelector('.groups').dataset.mark && document.querySelector('.note.wrong')")
        XCTAssertEqual(loads, 0)

        _ = try page.run("document.querySelector('.note .more').click(); return ''")
        page.waitUntil("the undo written") { store.load().record.explanation?.files[path]?.notes.first?.isWrong == false }
        XCTAssertEqual(store.load().record.explanation?.wrongCount, 0)
        XCTAssertEqual(
            try page.waitFor("document.querySelector('.note').className === 'note'", then: "document.querySelector('.note').className"), "note"
        )
    }

    /// A mark the review file can't take (saved by a newer Nirux) goes back
    /// on the page, and the button can't be used.
    @MainActor
    func testAMarkThatCantBeWrittenGoesBack() throws {
        let (page, store, _, cleanUp) = try Self.pageWithANote()
        defer { cleanUp() }
        _ = try page.run("\(Self.keepAwakeRow).click(); return ''")
        _ = try page.waitFor("document.querySelector('.note .more')")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        json["version"] = 999
        try JSONSerialization.data(withJSONObject: json).write(to: store.fileURL)

        _ = try page.run("document.querySelector('.note .more').click(); return ''")
        XCTAssertEqual(
            try page.waitFor(
                "document.querySelector('.note .more').getAttribute('aria-disabled') === 'true'",
                then: "document.querySelector('.note').className"
            ),
            "note"
        )
    }

    /// An Explain that ends while a diff is open: the diff is read again
    /// with the new notes.
    @MainActor
    func testAnOpenDiffGetsTheNotesOfAFreshExplain() throws {
        let file = try XCTUnwrap(BranchReviewPageTests.snapshot().files.first)
        var explanation = BranchReviewExplainPageTests.explanation()
        explanation.files[file.path] = .init(patchHash: "h0", summary: "S.", importance: 2, notes: [.init(
            id: "fresh", hunk: 0, anchor: BranchReview.hunkAnchor(try XCTUnwrap(file.hunks.first)), text: "Fresh note.", check: nil
        )], model: "claude-opus-5-5")
        // The second run finds the same notes, and adds its usage.
        var again = explanation
        again.runs = [BranchReviewExplainPageTests.run(date: Date(), tokens: 900, cost: 0.1, isComplete: true)]
        let runs = BranchReviewControllerTests.Recorder<Bool>()
        let page = try ReviewPage(
            reader: BranchReviewPageTests.reader, explainChecker: BranchReviewExplainFlowTests.ready
        ) { [explanation, again] _, _, _ in .init(ending: .explained, explanation: runs.append(true) == 1 ? explanation : again) }
        defer { page.close() }
        page.controller.confirmExplain = { _, _, _ in true }
        _ = try page.run("\(Self.keepAwakeRow).click(); return ''")
        _ = try page.waitFor("document.querySelector('.diff-box')")
        XCTAssertEqual(try page.run("return String(document.querySelectorAll('.note').length)"), "0")
        _ = try page.waitFor("!\(BranchReviewExplainFlowTests.explainButton).disabled")
        _ = try page.run("\(BranchReviewExplainFlowTests.explainButton).click(); return ''")
        XCTAssertEqual(
            try page.waitFor("document.querySelector('.note .note-text')", then: "document.querySelector('.note .note-text').textContent"),
            "Fresh note."
        )

        // Again: the same notes, one more run. The page shows the new
        // usage, and the diff drawn stays.
        let loadFile = page.controller.view.onLoadFile
        var loads = 0
        page.controller.view.onLoadFile = { id, generation in
            loads += 1
            loadFile?(id, generation)
        }
        _ = try page.waitFor("!\(BranchReviewExplainFlowTests.explainButton).disabled")
        page.controller.view.onExplain?(true)
        _ = try page.waitFor("document.querySelector('.explain-usage')?.textContent.includes('1 run')")
        XCTAssertEqual(loads, 0)
    }

    /// The mark's write brings another writer's notes (another Nirux, a
    /// part of a run): the page shows them, not only the mark.
    @MainActor
    func testAMarkThatBringsOtherNotesRedrawsThePage() throws {
        let (page, store, path, cleanUp) = try Self.pageWithANote()
        defer { cleanUp() }
        _ = try page.run("\(Self.keepAwakeRow).click(); return ''")
        _ = try page.waitFor("document.querySelectorAll('.note').length === 1")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        var explain = try XCTUnwrap(json["explain"] as? [String: Any])
        var files = try XCTUnwrap(explain["files"] as? [String: Any])
        var entry = try XCTUnwrap(files[path] as? [String: Any])
        var notes = try XCTUnwrap(entry["notes"] as? [[String: Any]])
        var other = notes[0]
        other["id"] = "n2"
        other["text"] = "Another Nirux's note."
        notes.append(other)
        entry["notes"] = notes
        files[path] = entry
        explain["files"] = files
        json["explain"] = explain
        try JSONSerialization.data(withJSONObject: json).write(to: store.fileURL)

        _ = try page.run("document.querySelector('.note .more').click(); return ''")
        XCTAssertEqual(
            try page.waitFor(
                "document.querySelectorAll('.note').length === 2",
                then: "[...document.querySelectorAll('.note')].map((n) => n.className + ':' + n.querySelector('.note-text').textContent).join('|')"
            ),
            "note wrong:Sets <b>a</b> to 2.|note:Another Nirux's note."
        )
    }

    /// The page shows older notes than the column's (an Explain ended
    /// while text was selected): a mark on an old note keeps nothing old,
    /// and the new notes show once the selection goes.
    @MainActor
    func testAMarkWhileThePageIsBehindKeepsNoOldNotes() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        let file = try XCTUnwrap(snapshot.files.first)
        let anchor = BranchReview.hunkAnchor(try XCTUnwrap(file.hunks.first))
        // What the run found: the note `n1` replaced by another.
        let found = BranchReviewControllerTests.Recorder<BranchReview.Explanation>()
        let (page, store, path, cleanUp) = try Self.pageWithANote(explainer: { _, _, _ in
            .init(ending: .explained, explanation: found.values.last)
        })
        defer { cleanUp() }
        var fresh = try XCTUnwrap(store.load().record.explanation)
        fresh.files[path]?.notes = [.init(id: "new", hunk: 0, anchor: anchor, text: "New note.", check: nil)]
        _ = found.append(fresh)
        page.controller.confirmExplain = { [fresh] _, _, _ in
            // The run saves its notes before it ends.
            _ = store.update(keepingHead: snapshot.head) { $0.setExplanation(fresh) }
            return true
        }
        _ = try page.run("\(Self.keepAwakeRow).click(); return ''")
        _ = try page.waitFor("document.querySelector('.note .more') && !document.querySelector('.note .more').disabled")

        page.controller.view.onSelection?(true)
        _ = try page.waitFor("!\(BranchReviewExplainFlowTests.explainButton).disabled")
        _ = try page.run("\(BranchReviewExplainFlowTests.explainButton).click(); return ''")
        page.waitUntil("the run's notes") { page.controller.explanation?.note(id: "new") != nil }
        _ = try page.run("document.querySelector('.note .more').click(); return ''")
        _ = try page.waitFor("document.querySelector('.note').className === 'note'")
        page.controller.view.onSelection?(false)
        XCTAssertEqual(
            try page.waitFor(
                "document.querySelector('.note-text')?.textContent === 'New note.'", then: "document.querySelector('.note-text').textContent"
            ),
            "New note."
        )
    }

    /// A new head read before a mark waits behind the Reload banner: once
    /// shown, it keeps the mark.
    @MainActor
    func testANewHeadWaitingBehindTheBannerKeepsAMark() throws {
        let moved = BranchReviewExplainPageTests.snapshot(head: String(repeating: "b", count: 40))
        let reads = BranchReviewControllerTests.Recorder<Bool>()
        let (page, store, path, cleanUp) = try Self.pageWithANote(reader: { path, fetch, known in
            reads.append(true) == 1 ? BranchReviewPageTests.reader(path, fetch, known) : (.snapshot(moved), nil)
        })
        defer { cleanUp() }
        _ = try page.run("\(Self.keepAwakeRow).click(); return ''")
        _ = try page.waitFor("document.querySelector('.note .more') && !document.querySelector('.note .more').disabled")
        page.controller.worktreeChanged(.metadata)
        page.waitUntil("the new head behind the banner") { page.controller.pending != nil }

        _ = try page.run("document.querySelector('.note .more').click(); return ''")
        page.waitUntil("the mark written") { store.load().record.explanation?.files[path]?.notes.first?.isWrong == true }
        page.waitUntil("the mark shown") { page.controller.explanation?.note(id: "n1")?.isWrong == true }
        page.controller.view.onReload?()
        page.waitUntil("the new head") { page.controller.snapshot?.head == moved.head }
        XCTAssertEqual(page.controller.explanation?.note(id: "n1")?.isWrong, true)
    }

    /// A page whose review file holds a note on Sources/KeepAwake.swift's
    /// hunk, Claude's text with markup in it, among 4 notes kept; and its
    /// clean-up.
    @MainActor
    static func pageWithANote(
        reader: @escaping BranchReviewController.Reader = BranchReviewPageTests.reader,
        explainer: @escaping BranchReviewController.Explainer = { _, _, _ in .init(ending: .nothingToSend) }
    ) throws -> (ReviewPage, BranchReview.Store, String, () -> Void) {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-notes-\(UUID().uuidString)")
        let snapshot = BranchReviewPageTests.snapshot()
        let file = try XCTUnwrap(snapshot.files.first)
        let store = try XCTUnwrap(BranchReview.Store(repository: "/r/.git", branch: snapshot.branch, stateDirectory: state))
        let history = BranchReview.History(isOwnCommit: { _ in true }, isInReflog: { _ in true })
        var explanation = BranchReviewExplainPageTests.explanation()
        explanation.noteCount = 4
        explanation.files[file.path] = .init(patchHash: "h0", summary: "S.", importance: 2, notes: [.init(
            id: "n1", hunk: 0, anchor: BranchReview.hunkAnchor(try XCTUnwrap(file.hunks.first)),
            text: "Sets <b>a</b> to 2.", check: "Is <i>a</i> read?"
        )], model: "claude-opus-5-5")
        let access = try XCTUnwrap(store.open(head: snapshot.head, pullRequest: snapshot.pullRequest, history: history).access)
        XCTAssertNotNil(try? store.update(access) { $0.setExplanation(explanation) }.get())
        let page = try ReviewPage(
            reader: reader,
            reviewOpener: { snapshot in
                let history = BranchReview.History(isOwnCommit: { _ in true }, isInReflog: { _ in true })
                return (store, store.open(head: snapshot.head, pullRequest: snapshot.pullRequest, history: history))
            },
            explanationReader: { _ in store.load().record.explanation },
            explainChecker: BranchReviewExplainFlowTests.ready, explainer: explainer
        )
        page.waitUntil("the review file") { page.controller.reviewRecord != nil }
        return (page, store, file.path, {
            page.close()
            try? FileManager.default.removeItem(at: state)
        })
    }
}
