import XCTest
@testable import Nirux

/// "Send N Comments to Agent" on the page and in the column
/// (docs/branch-review.md, section 6.2): what goes, the button, the
/// comments marked sent, and an edit under way of one that went.
final class BranchReviewSendPageTests: XCTestCase {
    private typealias Store = BranchReview.Store

    private var state: URL!
    private let repository = "/repos/widgets/.git"
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        state = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-send-page-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let state { try? FileManager.default.removeItem(at: state) }
    }

    private func store() throws -> Store {
        try XCTUnwrap(Store(repository: repository, branch: "feat/keep-awake", stateDirectory: state))
    }

    private func stored(_ snapshot: BranchReview.Snapshot, _ change: @escaping (inout BranchReview.Record) -> Void) throws {
        let store = try store()
        let opened = store.open(head: snapshot.head, pullRequest: snapshot.pullRequest, history: BranchReview.History(
            isOwnCommit: { _ in true }, isInReflog: { _ in true }
        ))
        _ = store.update(try XCTUnwrap(opened.access), change)
    }

    private var opener: BranchReviewController.ReviewOpener {
        let state = state!
        let repository = repository
        return { snapshot in
            guard let store = Store(repository: repository, branch: snapshot.branch, stateDirectory: state) else { return nil }
            let history = BranchReview.History(isOwnCommit: { _ in true }, isInReflog: { _ in true })
            return (store, store.open(head: snapshot.head, pullRequest: snapshot.pullRequest, history: history))
        }
    }

    @MainActor
    private func page(_ snapshot: BranchReview.Snapshot) throws -> ReviewPage {
        let page = try ReviewPage(snapshot: snapshot, handover: nil, reviewOpener: opener)
        page.waitUntil("the review") { page.controller.review?.canWrite == true && page.controller.pageComments != nil }
        try wait(page, until: "document.querySelector('.review-progress:not([hidden]), .review-problem:not([hidden])')")
        return page
    }

    @MainActor
    private func wait(_ page: ReviewPage, until condition: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let held = try page.run("""
            const deadline = Date.now() + 10000;
            while (!(\(condition)) && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
            return String(Boolean(\(condition)));
            """)
        XCTAssertEqual(held, "true", "timed out waiting for \(condition)", file: file, line: line)
    }

    private func anchor(_ snapshot: BranchReview.Snapshot) throws -> BranchReview.CommentAnchor {
        try XCTUnwrap(BranchReview.CommentAnchor(
            file: snapshot.files[0], from: .init(side: .additions, line: 2), to: .init(side: .additions, line: 2)
        ))
    }

    /// The unsent comments go, oldest first; a sent one doesn't, nor do
    /// drafts; an edit under way of one that goes is counted. Pasted, they
    /// don't go again until the paste is settled. Marked sent, at the head
    /// they went at, only on the branch they are of, those still unsent and
    /// as they went: one edited since, or sent since, stays as it is.
    @MainActor
    func testWhatGoesAndWhenItIsSent() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        let anchor = try anchor(snapshot)
        try stored(snapshot) { record in
            record.addComment(id: "c1", anchor: anchor, text: "Second", at: self.date + 2)
            record.addComment(id: "c2", anchor: anchor, text: "Went", at: self.date)
            _ = record.markSent(ids: ["c2"], head: "h0", at: self.date)
            record.addComment(id: "c3", anchor: .file("Sources/KeepAwake.swift"), text: "First", at: self.date + 1)
            record.saveDraft(id: "d1", anchor: anchor, text: "Not yet", at: self.date)
            record.saveDraft(id: "e1", anchor: .file(""), text: "Second, edited", editing: "c1", at: self.date)
        }
        let page = try page(snapshot)
        defer { page.close() }
        let send = try XCTUnwrap(page.controller.agentSend())
        XCTAssertEqual(send.message.ids, ["c3", "c1"])
        XCTAssertEqual(send.texts, ["c3": "First", "c1": "Second"])
        XCTAssertEqual(send.drafts, 1)
        XCTAssertEqual(send.edits, 1)
        XCTAssertEqual(send.head, snapshot.head)

        page.controller.notePasted(send)
        let waiting = try XCTUnwrap(page.controller.agentSend())
        XCTAssertEqual(waiting.message.ids, [])
        XCTAssertEqual(waiting.inPrompt, 2)
        page.controller.pasteSettled(send, taken: false)
        XCTAssertEqual(page.controller.agentSend()?.message.ids, ["c3", "c1"], "let go: they go again")

        page.controller.markSent(["c3": "First"], branch: "another", head: snapshot.head)
        page.controller.markSent(["c1": "Second", "c2": "Went"], branch: snapshot.branch, head: "h9")
        let store = try store()
        page.waitUntil("sent") { store.load().record.comment(id: "c1")?.sent != nil }
        XCTAssertEqual(store.load().record.comment(id: "c1")?.sent?.head, "h9")
        XCTAssertEqual(store.load().record.comment(id: "c2")?.sent?.head, "h0", "sent before: its mark stays")
        XCTAssertNil(store.load().record.comment(id: "c3")?.sent, "another branch's review isn't this one")
        XCTAssertEqual(page.controller.agentSend()?.message.ids, ["c3"])

        // Edited after it went: not what Claude got.
        try stored(snapshot) { _ = $0.editComment(id: "c3", text: "First, edited", at: self.date) }
        page.controller.reloadReview()
        page.waitUntil("the edit") { page.controller.review?.record.comment(id: "c3")?.text == "First, edited" }
        page.controller.markSent(["c3": "First"], branch: snapshot.branch, head: snapshot.head)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(store.load().record.comment(id: "c3")?.sent)
    }

    /// The page's button counts the unsent comments and asks the column;
    /// it is off while nothing can be written, and gone when none is left.
    @MainActor
    func testButtonCountsTheUnsentCommentsAndAsksTheColumn() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        let anchor = try anchor(snapshot)
        try stored(snapshot) { record in
            record.addComment(id: "c1", anchor: anchor, text: "One", at: self.date)
            record.addComment(id: "c2", anchor: anchor, text: "Two", at: self.date)
            record.saveDraft(id: "d1", anchor: anchor, text: "Not yet", at: self.date)
        }
        let page = try page(snapshot)
        defer { page.close() }
        var asked = 0
        page.controller.sendToAgent = { _ in asked += 1 }
        try wait(page, until: "document.querySelector('.send-comments:not([hidden])')?.textContent === 'Send 2 Comments to Agent'")
        _ = try page.run("document.querySelector('.send-comments').click(); return '';")
        page.waitUntil("asked") { asked == 1 }

        page.controller.markSent(["c1": "One"], branch: snapshot.branch, head: snapshot.head)
        try wait(page, until: "document.querySelector('.send-comments').textContent === 'Send 1 Comment to Agent'")
        // In a prompt, not submitted: not counted.
        let send = try XCTUnwrap(page.controller.agentSend())
        page.controller.notePasted(send)
        try wait(page, until: "document.querySelector('.send-comments').hidden")
        page.controller.pasteSettled(send, taken: false)
        try wait(page, until: "document.querySelector('.send-comments').textContent === 'Send 1 Comment to Agent'")
        page.controller.markSent(["c2": "Two"], branch: snapshot.branch, head: snapshot.head)
        try wait(page, until: "document.querySelector('.send-comments').hidden")
    }

    /// A review that can't be written (a newer Nirux's) can't mark its
    /// comments sent: the button is off, and says why.
    @MainActor
    func testButtonIsOffWhileTheReviewCantBeWritten() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        let anchor = try anchor(snapshot)
        try stored(snapshot) { $0.addComment(id: "c1", anchor: anchor, text: "One", at: self.date) }
        // As a newer Nirux would write it.
        let file = try store().fileURL
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["version"] = 99
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let page = try ReviewPage(snapshot: snapshot, handover: nil, reviewOpener: opener)
        defer { page.close() }
        page.waitUntil("the review") { page.controller.review?.isKnown == true }
        XCTAssertEqual(page.controller.review?.canWrite, false)
        try wait(page, until: "document.querySelector('.send-comments:not([hidden])')?.disabled === true")
        XCTAssertNotEqual(try page.run("return document.querySelector('.send-comments').title;"), "")
    }

    /// An edit under way of a comment that went: what was saved of it is a
    /// new comment's draft now, and its editor goes on as that draft; one
    /// that changed nothing goes.
    @MainActor
    func testEditOfACommentThatWentGoesOnAsANewComment() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        let anchor = try anchor(snapshot)
        try stored(snapshot) { record in
            record.addComment(id: "c1", anchor: anchor, text: "Why 2?", at: self.date)
            record.addComment(id: "c2", anchor: anchor, text: "And 3?", at: self.date + 1)
            record.saveDraft(id: "e1", anchor: .file(""), text: "Why 2, not 3?", editing: "c1", at: self.date)
            record.saveDraft(id: "e2", anchor: .file(""), text: "And 3?", editing: "c2", at: self.date)
        }
        let page = try page(snapshot)
        defer { page.close() }
        _ = try page.run(#"document.querySelector('.file[data-id="0"] .file-row').click(); return "";"#)
        try wait(page, until: "document.querySelectorAll('.comment-editor').length === 2")
        page.controller.markSent(["c1": "Why 2?", "c2": "And 3?"], branch: snapshot.branch, head: snapshot.head)
        try wait(page, until: "document.querySelector('.comment-editor .comment-problem')?.textContent === 'Its comment went to the agent: this is a new comment now.'")
        XCTAssertEqual(try page.run("""
            return JSON.stringify([...document.querySelectorAll('.comment-editor .comment-text')].map((text) => [text.value, text.getAttribute('aria-label')]));
            """), #"[["Why 2, not 3?","New comment on line 2"]]"#)
        // Typed on, it is saved as that draft.
        _ = try page.run("""
            const field = document.querySelector('.comment-editor .comment-text');
            field.focus();
            field.value = "Why 2, not 3? Really.";
            field.dispatchEvent(new Event("input", { bubbles: true }));
            return '';
            """)
        let store = try store()
        page.waitUntil("the draft") { store.load().record.draft(id: "e1")?.text == "Why 2, not 3? Really." }
        XCTAssertNil(store.load().record.draft(id: "e1")?.editing)
    }

    /// Typed in, not saved yet, when its comment went: what was typed stays,
    /// as a new comment where the comment was.
    @MainActor
    func testEditTypedButNotSavedWhenItsCommentWentStays() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        let anchor = try anchor(snapshot)
        try stored(snapshot) { record in
            record.addComment(id: "c1", anchor: anchor, text: "Why 2?", at: self.date)
            record.saveDraft(id: "e1", anchor: .file(""), text: "Why 2?", editing: "c1", at: self.date)
        }
        let page = try page(snapshot)
        defer { page.close() }
        _ = try page.run(#"document.querySelector('.file[data-id="0"] .file-row').click(); return "";"#)
        try wait(page, until: "document.querySelector('.comment-editor .comment-text')?.value === 'Why 2?'")
        // Typed: its save waits a moment after the last key.
        _ = try page.run("""
            const field = document.querySelector('.comment-editor .comment-text');
            field.value = "Why 2? Not 3.";
            field.dispatchEvent(new Event("input", { bubbles: true }));
            return '';
            """)
        page.controller.markSent(["c1": "Why 2?"], branch: snapshot.branch, head: snapshot.head)
        try wait(page, until: "document.querySelector('.comment-editor .comment-problem')?.textContent === 'Its comment went to the agent: Comment saves this as a new one.'")
        XCTAssertEqual(try page.run("return document.querySelector('.comment-editor .comment-text').value;"), "Why 2? Not 3.")
        let store = try store()
        page.waitUntil("the new draft") { store.load().record.drafts.contains { $0.editing == nil && $0.text == "Why 2? Not 3." } }
    }
}
