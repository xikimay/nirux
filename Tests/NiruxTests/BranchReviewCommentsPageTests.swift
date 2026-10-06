import XCTest
@testable import Nirux

/// Comments on the page (docs/branch-review.md, section 6.1), against the
/// real page and a review file in a folder of the test's own: the gutter's
/// button and the file's opens an editor, what is typed is saved as a
/// draft, Comment makes it a comment, and cards offer what each comment
/// allows.
final class BranchReviewCommentsPageTests: XCTestCase, CommentFixtures {
    private typealias Store = BranchReview.Store

    private var state: URL!
    private let repository = "/repos/widgets/.git"
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        state = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-comments-page-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let state { try? FileManager.default.removeItem(at: state) }
    }

    // MARK: - Helpers

    private func store() throws -> Store {
        try XCTUnwrap(Store(repository: repository, branch: "feat/keep-awake", stateDirectory: state))
    }

    /// The review file with `change` made, as another column would have.
    private func stored(_ snapshot: BranchReview.Snapshot, _ change: @escaping (inout BranchReview.Record) -> Void) throws {
        let store = try store()
        let opened = store.open(head: snapshot.head, pullRequest: snapshot.pullRequest, history: BranchReview.History(
            isOwnCommit: { _ in true }, isInReflog: { _ in true }
        ))
        _ = store.update(try XCTUnwrap(opened.access), change)
    }

    /// The page's fixture: in KeepAwake.swift (id 0), "import IOKit" (line
    /// 1, both sides), "let a = 1" removed (line 2 of the base), "let a = 2"
    /// added (line 2).
    /// Opens the review file in the test's folder, as the column does.
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
    private func page(_ snapshot: BranchReview.Snapshot = BranchReviewPageTests.snapshot()) throws -> ReviewPage {
        let page = try ReviewPage(snapshot: snapshot, handover: nil, reviewOpener: opener)
        page.waitUntil("the review") { page.controller.review != nil }
        try wait(page, until: "document.querySelector('.review-progress:not([hidden]), .review-problem:not([hidden])')")
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

    /// Opens file `id`'s row and waits for its diff's lines.
    @MainActor
    private func openFile(_ page: ReviewPage, _ id: Int) throws {
        _ = try page.run(#"document.querySelector('.file[data-id="\#(id)"] .file-row').click(); return "";"#)
        try wait(page, until: #"document.querySelector('.file[data-id="\#(id)"] diffs-container')?.shadowRoot?.querySelectorAll("[data-column-number]").length > 0"#)
    }

    /// Script that clicks the gutter's button by the number cell `index`
    /// of file `id`'s diff, as a pointer does, or drags it to cell `to`.
    private func gutterClick(_ id: Int, _ index: Int, to: Int? = nil) -> String {
        """
        const shadow = document.querySelector('.file[data-id="\(id)"] diffs-container').shadowRoot;
        const pointer = (target, type) => target.dispatchEvent(new PointerEvent(type, {
          bubbles: true, composed: true, cancelable: true, pointerId: 1, pointerType: "mouse", button: 0, isPrimary: true
        }));
        const cells = shadow.querySelectorAll("[data-column-number]");
        pointer(cells[\(index)], "pointermove");
        const button = shadow.querySelector("[data-utility-button]");
        pointer(button, "pointerdown");
        \(to.map { "pointer(cells[\($0)], \"pointermove\"); pointer(cells[\($0)], \"pointerup\");" } ?? "pointer(button, \"pointerup\");")
        """
    }

    /// Types `text` into the focused comment editor, as keys do.
    private func type(_ text: String) -> String {
        """
        const field = document.activeElement;
        field.value = \(String(decoding: try! JSONSerialization.data(withJSONObject: [text]), as: UTF8.self))[0];
        field.dispatchEvent(new Event("input", { bubbles: true }));
        """
    }

    // MARK: - Writing a comment

    @MainActor
    func testGutterOpensAnEditorWhoseDraftBecomesAComment() throws {
        let page = try page()
        defer { page.close() }
        try openFile(page, 0)
        // The added line, 2: the third number cell.
        _ = try page.run(gutterClick(0, 2) + "return '';")
        try wait(page, until: "document.activeElement?.classList.contains('comment-text')")
        XCTAssertEqual(
            try page.run("return document.activeElement.getAttribute('aria-label');"), "New comment on line 2"
        )
        // Under its line: slotted in the diff.
        XCTAssertEqual(try page.run("return String(document.activeElement.closest('[data-annotation-slot]')?.slot);"), "annotation-additions-2")

        _ = try page.run(type("Why 2?") + "return '';")
        let store = try store()
        page.waitUntil("the draft") { store.load().record.drafts.first?.text == "Why 2?" }
        let draft = try XCTUnwrap(store.load().record.drafts.first)
        XCTAssertEqual(draft.anchor?.rows.map(\.text), ["let a = 2"])

        _ = try page.run("document.querySelector('.comment-editor .action:not(.secondary)').click(); return '';")
        page.waitUntil("the comment") { store.load().record.comment(id: draft.id) != nil }
        XCTAssertEqual(store.load().record.comment(id: draft.id)?.text, "Why 2?")
        XCTAssertTrue(store.load().record.drafts.isEmpty)
        try wait(page, until: "document.querySelector('.comment-card .comment-body')?.textContent === 'Why 2?'")
        XCTAssertEqual(try page.run("return String(document.querySelectorAll('.comment-editor').length);"), "0")
        XCTAssertEqual(try page.run(#"return document.querySelector('.file[data-id="0"] .comment-count').textContent;"#), "1 comment")
    }

    // MARK: - What each comment allows

    @MainActor
    func testUnsentCommentIsEditedAndDeleted() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        let anchor = try XCTUnwrap(BranchReview.CommentAnchor(
            file: snapshot.files[0], from: .init(side: .additions, line: 2), to: .init(side: .additions, line: 2)
        ))
        try stored(snapshot) { $0.addComment(id: "c1", anchor: anchor, text: "Why 2?", at: self.date) }
        let page = try page(snapshot)
        defer { page.close() }
        try openFile(page, 0)
        try wait(page, until: "document.querySelector('.comment-card .comment-body')?.textContent === 'Why 2?'")
        XCTAssertEqual(try page.run("return [...document.querySelectorAll('.comment-card .action')].map((b) => b.textContent).join(',');"), "Edit,Delete")

        _ = try page.run("document.querySelector('.comment-card .action').click(); return '';")
        try wait(page, until: "document.activeElement?.classList.contains('comment-text')")
        XCTAssertEqual(try page.run("return document.activeElement.value;"), "Why 2?")
        XCTAssertEqual(try page.run("return document.activeElement.getAttribute('aria-label');"), "Editing your comment on line 2")
        _ = try page.run(type("Why 2, not 3?") + "return '';")
        let store = try store()
        page.waitUntil("the edit's draft") { store.load().record.drafts.first?.editing == "c1" }
        _ = try page.run("document.querySelector('.comment-editor .action:not(.secondary)').click(); return '';")
        page.waitUntil("the edit") { store.load().record.comment(id: "c1")?.text == "Why 2, not 3?" }
        XCTAssertTrue(store.load().record.drafts.isEmpty)
        try wait(page, until: "document.querySelector('.comment-card .comment-body')?.textContent === 'Why 2, not 3?'")

        // Delete asks first; Keep leaves it.
        _ = try page.run("document.querySelector('.comment-card .action:last-child').click(); return '';")
        XCTAssertEqual(try page.run("return document.querySelector('.comment-confirm').textContent;"), "Delete this comment?")
        _ = try page.run("[...document.querySelectorAll('.comment-card .action')].find((b) => b.textContent === 'Keep').click(); return '';")
        XCTAssertEqual(try page.run("return String(document.querySelector('.comment-confirm'));"), "null")
        _ = try page.run("document.querySelector('.comment-card .action:last-child').click(); return '';")
        _ = try page.run(Self.focusSpy + "[...document.querySelectorAll('.comment-card .action')].find((b) => b.textContent === 'Delete').click(); return '';")
        page.waitUntil("the comment gone") { store.load().record.comments.isEmpty }
        try wait(page, until: "document.querySelectorAll('.comment-card').length === 0")
        XCTAssertEqual(try page.run("return JSON.stringify(window.focused);"), #"[{"fileComment":true,"preventScroll":true}]"#, "the page stays")
    }

    /// A sent comment can only be deleted; one whose lines changed is
    /// listed with its file, with its lines as they were.
    @MainActor
    func testSentAndOutdatedCommentsShowWhatTheyAre() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        let added = try XCTUnwrap(BranchReview.CommentAnchor(
            file: snapshot.files[0], from: .init(side: .additions, line: 2), to: .init(side: .additions, line: 2)
        ))
        var rewritten = snapshot.files[0]
        rewritten.hunks = [BranchReview.Hunk(oldStart: 1, oldCount: 2, newStart: 1, newCount: 2, section: "", lines: [
            .init(kind: .context, text: "import IOKit"), .init(kind: .removed, text: "let a = 1"), .init(kind: .added, text: "let a = 0")
        ])]
        let gone = try XCTUnwrap(BranchReview.CommentAnchor(file: rewritten, from: .init(side: .additions, line: 2), to: .init(side: .additions, line: 2)))
        try stored(snapshot) { record in
            record.addComment(id: "c1", anchor: added, text: "Sent one", at: self.date)
            record.markSent(ids: ["c1"], head: String(repeating: "b", count: 40), at: self.date)
            record.addComment(id: "c2", anchor: gone, text: "Was on 0", at: self.date + 1)
        }
        let page = try page(snapshot)
        defer { page.close() }
        try openFile(page, 0)
        try wait(page, until: "document.querySelectorAll('.comment-card').length === 2")
        let sent = try page.run("""
            const card = [...document.querySelectorAll('.comment-card')].find((c) => c.querySelector('.comment-body').textContent === 'Sent one');
            return JSON.stringify({ label: card.querySelector('.comment-label').textContent,
              actions: [...card.querySelectorAll('.action')].map((b) => b.textContent), slotted: Boolean(card.closest('[data-annotation-slot]')) });
            """)
        XCTAssertEqual(sent, #"{"label":"Sent at bbbbbbb","actions":["Delete"],"slotted":true}"#)
        let outdated = try page.run("""
            const card = document.querySelector('.file-comments .comment-card');
            return JSON.stringify({ body: card.querySelector('.comment-body').textContent, where: card.querySelector('.comment-where').textContent,
              note: card.querySelector('.comment-note').textContent,
              excerpt: [...card.querySelectorAll('.excerpt-row')].map((row) => row.className + ' ' + row.textContent) });
            """)
        XCTAssertEqual(
            outdated,
            #"{"body":"Was on 0","where":"on line 2","note":"Outdated: its lines changed.","excerpt":["excerpt-row added 2let a = 0"]}"#
        )
        XCTAssertEqual(try page.run(#"return document.querySelector('.file[data-id="0"] .comment-count').textContent;"#), "2 comments")
    }

    // MARK: - Files, drafts and limits

    /// The file's button opens an editor by the keyboard too, and the
    /// comment is on the whole file.
    @MainActor
    func testFileButtonCommentsOnTheWholeFile() throws {
        let page = try page()
        defer { page.close() }
        _ = try page.run(#"document.querySelector('.file[data-id="0"] .file-comment').click(); return "";"#)
        try wait(page, until: "document.activeElement?.classList.contains('comment-text')")
        XCTAssertEqual(try page.run("return document.activeElement.getAttribute('aria-label');"), "New comment on the file")
        XCTAssertEqual(try page.run(#"return String(Boolean(document.activeElement.closest('.file[data-id="0"] .file-comments')));"#), "true")
        _ = try page.run(type("Split this file.") + """
            document.activeElement.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", metaKey: true, bubbles: true }));
            return '';
            """)
        let store = try store()
        page.waitUntil("the comment") { store.load().record.comments.first?.text == "Split this file." }
        XCTAssertEqual(store.load().record.comments.first?.anchor, .file("Sources/KeepAwake.swift"))
        try wait(page, until: "document.querySelector('.file-comments .comment-body')?.textContent === 'Split this file.'")
    }

    /// A draft outlives the page: it shows again in its editor, and
    /// Cancel removes it.
    @MainActor
    func testDraftShowsAgainAndCancelRemovesIt() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        let anchor = try XCTUnwrap(BranchReview.CommentAnchor(
            file: snapshot.files[0], from: .init(side: .deletions, line: 2), to: .init(side: .additions, line: 2)
        ))
        try stored(snapshot) { $0.saveDraft(id: "d1", anchor: anchor, text: "Half typed", at: self.date) }
        let page = try page(snapshot)
        defer { page.close() }
        try openFile(page, 0)
        try wait(page, until: "document.querySelector('.comment-editor .comment-text')?.value === 'Half typed'")
        XCTAssertEqual(
            try page.run("return document.querySelector('.comment-editor .comment-text').getAttribute('aria-label');"),
            "New comment on removed line 2 to line 2"
        )
        _ = try page.run(Self.focusSpy + "document.querySelector('.comment-editor .action.secondary').click(); return '';")
        let store = try store()
        page.waitUntil("the draft gone") { store.load().record.drafts.isEmpty }
        try wait(page, until: "document.querySelectorAll('.comment-editor').length === 0")
        XCTAssertEqual(try page.run("return JSON.stringify(window.focused);"), #"[{"fileComment":true,"preventScroll":true}]"#, "the page stays")
    }

    /// Records each focus asked for: whether on a file's Comment button,
    /// and whether it scrolls.
    private static let focusSpy = """
        window.focused = [];
        const focus = HTMLElement.prototype.focus;
        HTMLElement.prototype.focus = function (options) {
          window.focused.push({ fileComment: this.classList.contains("file-comment"), preventScroll: options?.preventScroll === true });
          return focus.call(this, options);
        };

        """

    /// A comment whose file no longer differs from the base is at the top.
    @MainActor
    func testCommentOnAFileGoneIsAtTheTop() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        // A branch's path and lines, crafted: text, their hidden characters
        // shown.
        let path = "Sources/<img src=x onerror=\"window.pwned = 1\">\u{202E}Old.swift"
        let old = file([hunk(old: 1, new: 1, [" x()", "+<b>bold</b>\u{202E}evil"])], path: path)
        let rows = try XCTUnwrap(BranchReview.CommentAnchor(file: old, from: .init(side: .additions, line: 2), to: .init(side: .additions, line: 2)))
        try stored(snapshot) { record in
            record.addComment(id: "c1", anchor: .file("Sources/Old.swift"), text: "Gone now", at: self.date)
            record.addComment(id: "c2", anchor: rows, text: "Crafted", at: self.date + 1)
        }
        let page = try page(snapshot)
        defer { page.close() }
        try wait(page, until: "!document.querySelector('.gone-comments').hidden")
        XCTAssertEqual(try page.run("return document.querySelector('.gone-comments .comment-body').textContent;"), "Gone now")
        XCTAssertEqual(try page.run("return document.querySelector('.gone-comments .comment-where').textContent;"), "on Sources/Old.swift, the file")
        let crafted = try page.run("""
            const card = document.querySelectorAll('.gone-comments .comment-card')[1];
            return JSON.stringify({ where: card.querySelector('.comment-where').textContent,
              row: card.querySelector('.excerpt-text').textContent,
              elements: document.querySelectorAll('.comment img, .comment b').length, pwned: window.pwned ?? null });
            """)
        XCTAssertEqual(crafted, #"{"where":"on Sources/<img src=x onerror=\"window.pwned = 1\">⟨U+202E⟩Old.swift, line 2","row":"<b>bold</b>⟨U+202E⟩evil","elements":0,"pwned":null}"#)
        XCTAssertEqual(try page.run("return document.querySelector('.gone-comments .comment-note').textContent;"), "Its file no longer differs from the base.")
    }

    /// A comment being typed holds the next page back, as a selection
    /// does: it would move the editor, and take its focus.
    @MainActor
    func testCommentBeingTypedHoldsTheNextPageBack() throws {
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
        }, reviewOpener: opener)
        defer { page.close() }
        page.waitUntil("the review") { page.controller.review?.canWrite == true }
        try wait(page, until: "document.querySelector('.review-progress:not([hidden])')")
        _ = try page.run(#"document.querySelector('.file[data-id="0"] .file-comment').click(); return "";"#)
        try wait(page, until: "document.activeElement?.classList.contains('comment-text')")
        // The editor's message comes before the script's answer.
        _ = try page.run("return '';")
        page.controller.worktreeChanged(.worktree)
        page.waitUntil("the second read") { calls.values.count == 2 && !page.controller.isReading }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(page.controller.snapshot?.files.count, 3, "shown under the editor")
        XCTAssertEqual(try page.run("return String(document.activeElement.classList.contains('comment-text'));"), "true")

        _ = try page.run("document.activeElement.blur(); return '';")
        page.waitUntil("the held page") { page.controller.snapshot?.files.count == 4 }
    }

    /// Lines selected by their numbers offer a button for a comment on
    /// them.
    @MainActor
    func testSelectedLinesOfferAComment() throws {
        let page = try page()
        defer { page.close() }
        try openFile(page, 0)
        _ = try page.run("""
            const shadow = document.querySelector('.file[data-id="0"] diffs-container').shadowRoot;
            const pointer = (target, type) => target.dispatchEvent(new PointerEvent(type, {
              bubbles: true, composed: true, cancelable: true, pointerId: 1, pointerType: "mouse", button: 0, isPrimary: true
            }));
            const cells = shadow.querySelectorAll("[data-column-number]");
            pointer(cells[1], "pointerdown");
            pointer(cells[2], "pointermove");
            pointer(cells[2], "pointerup");
            return "";
            """)
        try wait(page, until: "document.querySelector('.file-comments .action')?.textContent === 'Comment on removed line 2 to line 2'")
        _ = try page.run("document.querySelector('.file-comments .action').click(); return '';")
        try wait(page, until: "document.activeElement?.getAttribute('aria-label') === 'New comment on removed line 2 to line 2'")
    }

    /// A review that can't be written takes no comment, and says why.
    @MainActor
    func testReviewThatCantBeWrittenSaysWhy() throws {
        let page = try ReviewPage(snapshot: BranchReviewPageTests.snapshot(), handover: nil, reviewOpener: { _ in nil })
        defer { page.close() }
        page.waitUntil("the review") { page.controller.review != nil }
        _ = try page.run(#"document.querySelector('.file[data-id="0"] .file-comment').click(); return "";"#)
        try wait(page, until: #"document.querySelector('.file[data-id="0"] .comment-notice')"#)
        XCTAssertEqual(
            try page.run("return document.querySelector('.comment-notice').textContent;"),
            "Nirux couldn’t open this branch’s review file: git couldn’t tell its repository."
        )
        XCTAssertEqual(try page.run("return String(document.querySelectorAll('.comment-editor').length);"), "0")
    }

    /// ⌘↩ sends the comment from the keyboard: the comment takes the focus
    /// (WebKit says nothing when a focused element goes), the page stops
    /// holding the next one back, and the lines chosen are let go.
    @MainActor
    func testKeyboardCommentLetsTheNextPageShow() throws {
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
        }, reviewOpener: opener)
        defer { page.close() }
        page.waitUntil("the review") { page.controller.review?.canWrite == true }
        try openFile(page, 0)
        _ = try page.run(gutterClick(0, 2) + "return '';")
        try wait(page, until: "document.activeElement?.classList.contains('comment-text')")
        _ = try page.run(type("Why 2?") + """
            document.activeElement.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", metaKey: true, bubbles: true }));
            return '';
            """)
        try wait(page, until: "document.activeElement?.classList.contains('comment') && document.activeElement.textContent.includes('Why 2?')")
        let selected = #"document.querySelector('.file[data-id="0"] diffs-container').shadowRoot.querySelectorAll('[data-selected-line]').length"#
        try wait(page, until: "\(selected) === 0")
        page.controller.worktreeChanged(.worktree)
        page.waitUntil("the next page") { page.controller.snapshot?.files.count == 4 }
        XCTAssertGreaterThanOrEqual(calls.values.count, 2)
    }

    /// Rows built after the page (a folded group opened) show their
    /// comments, and a closed file's row counts its drafts.
    @MainActor
    func testRowsShowTheirCommentsAndDraftsWhateverOpenedThem() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        let anchor = try XCTUnwrap(BranchReview.CommentAnchor(
            file: snapshot.files[0], from: .init(side: .additions, line: 2), to: .init(side: .additions, line: 2)
        ))
        try stored(snapshot) { record in
            record.addComment(id: "c1", anchor: .file("Package.resolved"), text: "Pin it", at: self.date)
            record.saveDraft(id: "d1", anchor: anchor, text: "Half typed", at: self.date)
        }
        let page = try page(snapshot)
        defer { page.close() }
        try wait(page, until: #"document.querySelector('.file[data-id="0"] .comment-count')?.textContent === '1 draft'"#)
        XCTAssertEqual(try page.run(#"return String(document.querySelector('.file[data-id="1"]'));"#), "null", "folded")
        _ = try page.run(#"document.querySelector('.group[data-key="folded.lockfile"] .group-header').click(); return "";"#)
        try wait(page, until: #"document.querySelector('.file[data-id="1"] .comment-count')?.textContent === '1 comment'"#)
        XCTAssertEqual(try page.run(#"return document.querySelector('.file[data-id="1"] .comment-body').textContent;"#), "Pin it")
    }

    /// A drag over two hunks, or in a diff dimmed while its new one is read,
    /// opens nothing and says why by the file, until the next choice that
    /// opens an editor.
    @MainActor
    func testLinesThatTakeNoCommentSayWhyUntilTheNextChoice() throws {
        let made = BranchReviewPageTests.snapshot()
        let twoHunks = BranchReviewControllerTests.snapshot(made, files: made.files.map { file in
            guard file.path == "Sources/KeepAwake.swift" else { return file }
            var both = file
            both.hunks.append(BranchReview.Hunk(oldStart: 40, oldCount: 1, newStart: 40, newCount: 2, section: "", lines: [
                .init(kind: .context, text: "func stop() {"), .init(kind: .added, text: "release()")
            ]))
            return both
        })
        let page = try page(twoHunks)
        defer { page.close() }
        try openFile(page, 0)
        _ = try page.run(gutterClick(0, 2, to: 4) + "return '';")
        try wait(page, until: "document.querySelector('.comment-notice')")
        XCTAssertEqual(try page.run("return document.querySelector('.comment-notice').textContent;"), "Comment on the lines of one hunk at a time.")
        XCTAssertEqual(try page.run("return String(document.querySelectorAll('.comment-editor').length);"), "0")
        _ = try page.run(#"document.querySelector('.file[data-id="0"] .diff-box').classList.add('stale'); return "";"#)
        _ = try page.run(gutterClick(0, 2) + "return '';")
        try wait(page, until: "document.querySelector('.comment-notice')?.textContent === 'This diff is being read again: choose the lines once it shows.'")
        _ = try page.run(#"document.querySelector('.file[data-id="0"] .diff-box').classList.remove('stale'); return "";"#)
        _ = try page.run(gutterClick(0, 2) + "return '';")
        try wait(page, until: "document.activeElement?.classList.contains('comment-text')")
        XCTAssertEqual(try page.run("return String(document.querySelector('.comment-notice'));"), "null")
    }

    /// An edit whose comment was deleted elsewhere keeps what was typed,
    /// as a new comment where the comment was.
    @MainActor
    func testEditOfACommentDeletedElsewhereStays() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        let anchor = try XCTUnwrap(BranchReview.CommentAnchor(
            file: snapshot.files[0], from: .init(side: .additions, line: 2), to: .init(side: .additions, line: 2)
        ))
        try stored(snapshot) { $0.addComment(id: "c1", anchor: anchor, text: "Why 2?", at: self.date) }
        let page = try page(snapshot)
        defer { page.close() }
        try openFile(page, 0)
        try wait(page, until: "document.querySelector('.comment-card')")
        _ = try page.run("document.querySelector('.comment-card .action').click(); return '';")
        try wait(page, until: "document.activeElement?.classList.contains('comment-text')")
        _ = try page.run(type("Why 2, really?") + "return '';")
        let store = try store()
        page.waitUntil("the edit's draft") { store.load().record.drafts.first?.editing == "c1" }
        try stored(snapshot) { $0.deleteComment(id: "c1") }
        page.controller.reloadReview()
        try wait(page, until: "document.querySelector('.comment-editor .comment-problem')?.textContent === 'Its comment was deleted: Comment saves this as a new one.'")
        XCTAssertEqual(try page.run("return document.activeElement.getAttribute('aria-label');"), "New comment on line 2", "the focus kept")
        XCTAssertEqual(try page.run("return document.activeElement.value;"), "Why 2, really?")
        // Typed on, it is saved, and Comment makes it a comment, once.
        _ = try page.run(type("Why 2, really? Yes.") + "return '';")
        page.waitUntil("the new draft") { store.load().record.drafts.contains { $0.editing == nil && $0.text == "Why 2, really? Yes." } }
        page.waitUntil("the page told") { page.controller.pageComments?.contains { $0.state == "draft" } == true }
        _ = try page.run("return '';")
        XCTAssertEqual(try page.run("return String(document.querySelectorAll('.comment-editor').length);"), "1")
        XCTAssertEqual(try page.run("return String(document.activeElement.classList.contains('comment-text'));"), "true")
        _ = try page.run("document.querySelector('.comment-editor .action:not(.secondary)').click(); return '';")
        page.waitUntil("the comment") { store.load().record.comments.first?.text == "Why 2, really? Yes." }
        try wait(page, until: "document.querySelectorAll('.comment-editor').length === 0 && document.querySelectorAll('.comment-card').length === 1")
    }

    // MARK: - What the premortem found

    /// Lines chosen in a page a new read replaced before the first save:
    /// the rows saved are those chosen, found where they are now, and the
    /// editor names where; meanwhile it shows with its file, not under the
    /// new page's line of that number.
    @MainActor
    func testLinesChosenBeforeANewPageAreTheOnesSaved() throws {
        let first = BranchReviewPageTests.snapshot()
        let moved = BranchReviewControllerTests.snapshot(first, files: first.files.map { file in
            guard file.path == "Sources/KeepAwake.swift" else { return file }
            var later = file
            later.patchHash = "moved"
            let above: [BranchReview.Line] = ["// one", "// two", "// three"].map { .init(kind: .added, text: $0) }
            later.hunks = [BranchReview.Hunk(oldStart: 1, oldCount: 2, newStart: 1, newCount: 5, section: "", lines: above + file.hunks[0].lines)]
            return later
        })
        let reads = BranchReviewControllerTests.Answers(answers: [(.snapshot(first), nil), (.snapshot(moved), nil)])
        let page = try ReviewPage(reader: { _, _, _ in reads.next() }, reviewOpener: opener)
        defer { page.close() }
        page.waitUntil("the review") { page.controller.review?.canWrite == true }
        try openFile(page, 0)
        _ = try page.run(gutterClick(0, 2) + "return '';")
        try wait(page, until: "document.activeElement?.getAttribute('aria-label') === 'New comment on line 2'")
        // Left before typing: the next page shows.
        _ = try page.run("document.activeElement.blur(); return '';")
        let before = page.controller.snapshotCount
        page.controller.worktreeChanged(.worktree)
        page.waitUntil("the next page") { page.controller.snapshotCount > before }
        // Its line 2 isn't this page's: it shows with its file.
        try wait(page, until: "document.querySelector('.comment-editor .comment-text')?.getAttribute('aria-label') === 'New comment on line 2, as the diff was'")
        XCTAssertEqual(try page.run("return String(Boolean(document.querySelector('.comment-editor').closest('[data-annotation-slot]')));"), "false")
        _ = try page.run("document.querySelector('.comment-editor .comment-text').focus(); return '';")
        _ = try page.run(type("Why 2?") + "return '';")
        let store = try store()
        page.waitUntil("the draft") { store.load().record.drafts.first?.text == "Why 2?" }
        XCTAssertEqual(store.load().record.drafts.first?.anchor?.rows.map(\.text), ["let a = 2"])
        try wait(page, until: "document.querySelector('.comment-editor .comment-text')?.getAttribute('aria-label') === 'New comment on line 5'")
    }

    /// What couldn't be written is written once it can: a draft whose save
    /// was refused is saved, and one closed whose removal was refused stays
    /// closed, and goes.
    @MainActor
    func testWhatCouldntBeWrittenIsWrittenOnceItCan() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        let anchor = try XCTUnwrap(BranchReview.CommentAnchor(
            file: snapshot.files[0], from: .init(side: .additions, line: 2), to: .init(side: .additions, line: 2)
        ))
        try stored(snapshot) { $0.saveDraft(id: "d1", anchor: anchor, text: "Half typed", at: self.date) }
        let store = try store()
        let page = try page(snapshot)
        defer { page.close() }
        try openFile(page, 0)
        try wait(page, until: "document.querySelector('.comment-editor .comment-text')?.value === 'Half typed'")
        _ = try page.run(#"document.querySelector('.file[data-id="0"] .file-comment').click(); return "";"#)
        try wait(page, until: "document.activeElement?.getAttribute('aria-label') === 'New comment on the file'")

        let folder = store.folder.path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder) }
        let refused = page.controller.commentProblems.count
        _ = try page.run(type("On the file") + """
            const halfTyped = [...document.querySelectorAll('.comment-editor')].find((e) => e.querySelector('.comment-text').value === 'Half typed');
            halfTyped.querySelector('.action.secondary').click();
            return '';
            """)
        page.waitUntil("both refused") { page.controller.commentProblems.count >= refused + 2 }
        try wait(page, until: "document.querySelectorAll('.comment-editor').length === 1")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(try page.run("return String(document.querySelectorAll('.comment-editor').length);"), "1", "the draft closed stays closed")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
        page.controller.reloadReview()
        page.waitUntil("both written") { store.load().record.drafts.map(\.text) == ["On the file"] }
        XCTAssertEqual(try page.run("return String(document.querySelectorAll('.comment-editor').length);"), "1")
    }

    /// A draft shown with its file while its diff is read, typed in: once
    /// the diff shows, it moves under its lines, and keeps the focus.
    @MainActor
    func testEditorMovedUnderItsLinesKeepsTheFocus() throws {
        XCTAssertEqual(try focusAfterMove(pressElsewhere: false), #"["Half typed",4,true]"#)
    }

    /// Unless the user pressed elsewhere meanwhile.
    @MainActor
    func testFocusIsntTakenBackAfterAPressElsewhere() throws {
        XCTAssertEqual(try focusAfterMove(pressElsewhere: true), #"[null,null,false]"#)
    }

    /// What has the focus once a draft typed in moved under its lines:
    /// the value, caret and whether it is under them.
    @MainActor
    private func focusAfterMove(pressElsewhere: Bool) throws -> String {
        let made = BranchReviewPageTests.snapshot()
        let anchor = try XCTUnwrap(BranchReview.CommentAnchor(
            file: made.files[0], from: .init(side: .additions, line: 2), to: .init(side: .additions, line: 2)
        ))
        let read = made.files[0]
        let unread = BranchReviewControllerTests.snapshot(made, files: made.files.map { file in
            guard file.path == read.path else { return file }
            var later = file
            later.hunks = []
            later.omission = .onDemand
            return later
        })
        try stored(made) { $0.saveDraft(id: "d1", anchor: anchor, text: "Half typed", at: self.date) }
        let gate = DispatchSemaphore(value: 0)
        let page = try ReviewPage(snapshot: unread, handover: nil, patchReader: { file, _ in
            guard file.path == read.path else { return nil }
            gate.wait()
            return read
        }, reviewOpener: opener)
        defer { page.close() }
        page.waitUntil("the review") { page.controller.review != nil }
        _ = try page.run(#"document.querySelector('.file[data-id="0"] .file-row').click(); return "";"#)
        try wait(page, until: "document.querySelector('.comment-editor .comment-text')?.value === 'Half typed'")
        _ = try page.run("""
            const text = document.querySelector('.comment-editor .comment-text');
            text.focus();
            text.setSelectionRange(4, 4);
            \(pressElsewhere ? "document.body.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));" : "")
            return '';
            """)
        gate.signal()
        page.waitUntil("placed") { page.controller.pageComments?.first?.placement == "placed" }
        try wait(page, until: "document.querySelector('.comment-editor')?.closest('[data-annotation-slot]')")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return try page.run("""
            const text = document.activeElement.classList.contains('comment-text') ? document.activeElement : null;
            return JSON.stringify([text?.value ?? null, text?.selectionStart ?? null, Boolean(text?.closest('[data-annotation-slot]'))]);
            """)
    }

    /// A draft made a comment in another column: its editor here, idle,
    /// gives way to the comment.
    @MainActor
    func testDraftMadeACommentElsewhereShowsAsTheComment() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        try stored(snapshot) { $0.saveDraft(id: "d1", anchor: .file("Sources/KeepAwake.swift"), text: "Half typed", at: self.date) }
        let page = try page(snapshot)
        defer { page.close() }
        try openFile(page, 0)
        try wait(page, until: "document.querySelector('.comment-editor .comment-text')?.value === 'Half typed'")
        try stored(snapshot) { $0.addComment(id: "d1", anchor: .file("Sources/KeepAwake.swift"), text: "Done elsewhere", at: self.date) }
        page.controller.reloadReview()
        try wait(page, until: "document.querySelector('.comment-card .comment-body')?.textContent === 'Done elsewhere'")
        XCTAssertEqual(try page.run("return String(document.querySelectorAll('.comment-editor').length);"), "0")

        // An edit saved elsewhere: its editor here gives way too.
        try stored(snapshot) { $0.saveDraft(id: "e1", anchor: .file(""), text: "Done, really", editing: "d1", at: self.date) }
        page.controller.reloadReview()
        try wait(page, until: "document.querySelector('.comment-editor .comment-text')?.value === 'Done, really'")
        try stored(snapshot) { _ = $0.editComment(id: "d1", text: "Done, really", at: self.date) }
        page.controller.reloadReview()
        try wait(page, until: "document.querySelector('.comment-card .comment-body')?.textContent === 'Done, really'")
        XCTAssertEqual(try page.run("return String(document.querySelectorAll('.comment-editor').length);"), "0")
    }

    /// An edit of an outdated comment deleted elsewhere: its rows aren't
    /// this page's, so the new comment is on the file.
    @MainActor
    func testEditOfAnOutdatedCommentDeletedElsewhereGoesOnTheFile() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        var rewritten = snapshot.files[0]
        rewritten.hunks = [BranchReview.Hunk(oldStart: 1, oldCount: 2, newStart: 1, newCount: 2, section: "", lines: [
            .init(kind: .context, text: "import IOKit"), .init(kind: .removed, text: "let a = 1"), .init(kind: .added, text: "let a = 0")
        ])]
        let gone = try XCTUnwrap(BranchReview.CommentAnchor(file: rewritten, from: .init(side: .additions, line: 2), to: .init(side: .additions, line: 2)))
        try stored(snapshot) { $0.addComment(id: "c1", anchor: gone, text: "Was on 0", at: self.date) }
        let page = try page(snapshot)
        defer { page.close() }
        try openFile(page, 0)
        try wait(page, until: "document.querySelector('.comment-card')")
        _ = try page.run("document.querySelector('.comment-card .action').click(); return '';")
        try wait(page, until: "document.activeElement?.classList.contains('comment-text')")
        _ = try page.run(type("Was on 0, really?") + "return '';")
        let store = try store()
        page.waitUntil("the edit's draft") { store.load().record.drafts.first?.editing == "c1" }
        try stored(snapshot) { $0.deleteComment(id: "c1") }
        page.controller.reloadReview()
        try wait(page, until: "document.activeElement?.getAttribute('aria-label') === 'New comment on the file'")
        _ = try page.run(type("Was on 0, really? Yes.") + "return '';")
        page.waitUntil("the new draft") { store.load().record.drafts.contains { $0.editing == nil && $0.text == "Was on 0, really? Yes." } }
        XCTAssertEqual(store.load().record.drafts.first { $0.editing == nil }?.anchor, .file("Sources/KeepAwake.swift"))
    }

    /// An edit whose save was refused stays, whatever answers come meanwhile,
    /// and is saved once something can be written.
    @MainActor
    func testRefusedEditStaysUntilItIsSaved() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        let anchor = try XCTUnwrap(BranchReview.CommentAnchor(
            file: snapshot.files[0], from: .init(side: .additions, line: 2), to: .init(side: .additions, line: 2)
        ))
        try stored(snapshot) { $0.addComment(id: "c1", anchor: anchor, text: "Why 2?", at: self.date) }
        let store = try store()
        let page = try page(snapshot)
        defer { page.close() }
        try openFile(page, 0)
        try wait(page, until: "document.querySelector('.comment-card')")
        _ = try page.run("document.querySelector('.comment-card .action').click(); return '';")
        try wait(page, until: "document.activeElement?.classList.contains('comment-text')")
        let folder = store.folder.path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder) }
        let refused = page.controller.commentProblems.count
        _ = try page.run(type("Why 2, not 3?") + "return '';")
        page.waitUntil("refused") { page.controller.commentProblems.count > refused }
        _ = try page.run("document.activeElement.blur(); return '';")
        page.controller.reloadReview()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(try page.run("return document.querySelector('.comment-editor .comment-text')?.value ?? 'gone';"), "Why 2, not 3?")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
        page.controller.reloadReview()
        page.waitUntil("saved") { store.load().record.drafts.contains { $0.editing == "c1" && $0.text == "Why 2, not 3?" } }
    }

    /// An edit of a comment deleted elsewhere whose file left the diff:
    /// with the comments whose file is gone, saying it can't be saved.
    @MainActor
    func testEditWhoseFileLeftTheDiffShowsWithTheCommentsOfGoneFiles() throws {
        let first = BranchReviewPageTests.snapshot()
        let without = BranchReviewControllerTests.snapshot(first, files: Array(first.files.dropFirst()))
        let anchor = try XCTUnwrap(BranchReview.CommentAnchor(
            file: first.files[0], from: .init(side: .additions, line: 2), to: .init(side: .additions, line: 2)
        ))
        try stored(first) { $0.addComment(id: "c1", anchor: anchor, text: "Why 2?", at: self.date) }
        let reads = BranchReviewControllerTests.Answers(answers: [(.snapshot(first), nil), (.snapshot(without), nil)])
        let page = try ReviewPage(reader: { _, _, _ in reads.next() }, reviewOpener: opener)
        defer { page.close() }
        page.waitUntil("the review") { page.controller.review?.canWrite == true }
        try openFile(page, 0)
        try wait(page, until: "document.querySelector('.comment-card')")
        _ = try page.run("document.querySelector('.comment-card .action').click(); return '';")
        try wait(page, until: "document.activeElement?.classList.contains('comment-text')")
        _ = try page.run(type("Why 2, really?") + "return '';")
        let store = try store()
        page.waitUntil("the edit's draft") { store.load().record.drafts.first?.editing == "c1" }
        _ = try page.run("document.activeElement.blur(); return '';")
        try stored(first) { $0.deleteComment(id: "c1") }
        let before = page.controller.snapshotCount
        page.controller.worktreeChanged(.worktree)
        page.waitUntil("the next page") { page.controller.snapshotCount > before }
        page.controller.reloadReview()
        try wait(page, until: "document.querySelector('.gone-comments .comment-editor .comment-problem')?.textContent === 'Its comment was deleted, and its file is no longer in the diff: this can’t be saved.'")
        XCTAssertEqual(try page.run("return document.querySelector('.gone-comments .comment-text').value;"), "Why 2, really?")
    }

    /// A comment on the file takes the file as the page shows it when it is
    /// saved: pages that replaced the one it was opened in don't refuse it.
    @MainActor
    func testCommentOnTheFileOutlivesNewPages() throws {
        let first = BranchReviewPageTests.snapshot()
        let reads = BranchReviewControllerTests.Answers(answers: [(.snapshot(first), nil)] + (1...4).map { index in
            var added = BranchReview.FileChange(path: "Sources/Later\(index).swift", status: .added)
            added.patchHash = "later\(index)"
            return (.snapshot(BranchReviewControllerTests.snapshot(first, files: first.files + [added])), nil)
        })
        let page = try ReviewPage(reader: { _, _, _ in reads.next() }, reviewOpener: opener)
        defer { page.close() }
        page.waitUntil("the review") { page.controller.review?.canWrite == true }
        try wait(page, until: "document.querySelector('.review-progress:not([hidden])')")
        _ = try page.run(#"document.querySelector('.file[data-id="0"] .file-comment').click(); return "";"#)
        try wait(page, until: "document.activeElement?.getAttribute('aria-label') === 'New comment on the file'")
        _ = try page.run("document.activeElement.blur(); return '';")
        for _ in 1...4 {
            let before = page.controller.snapshotCount
            page.controller.worktreeChanged(.worktree)
            page.waitUntil("the next page") { page.controller.snapshotCount > before }
        }
        _ = try page.run("document.querySelector('.comment-editor .comment-text').focus(); return '';")
        _ = try page.run(type("Split this file") + "return '';")
        let store = try store()
        page.waitUntil("the draft") { store.load().record.drafts.first?.anchor == .file("Sources/KeepAwake.swift") }
    }

    /// An edit of a comment that moved, then was deleted elsewhere: the new
    /// comment goes where the comment last showed.
    @MainActor
    func testEditOfAMovedCommentDeletedElsewhereGoesWhereItLastShowed() throws {
        let first = BranchReviewPageTests.snapshot()
        let moved = BranchReviewControllerTests.snapshot(first, files: first.files.map { file in
            guard file.path == "Sources/KeepAwake.swift" else { return file }
            var later = file
            later.patchHash = "moved"
            let above: [BranchReview.Line] = ["// one", "// two", "// three"].map { .init(kind: .added, text: $0) }
            later.hunks = [BranchReview.Hunk(oldStart: 1, oldCount: 2, newStart: 1, newCount: 5, section: "", lines: above + file.hunks[0].lines)]
            return later
        })
        let anchor = try XCTUnwrap(BranchReview.CommentAnchor(
            file: first.files[0], from: .init(side: .additions, line: 2), to: .init(side: .additions, line: 2)
        ))
        try stored(first) { $0.addComment(id: "c1", anchor: anchor, text: "Why 2?", at: self.date) }
        let reads = BranchReviewControllerTests.Answers(answers: [(.snapshot(first), nil), (.snapshot(moved), nil)])
        let page = try ReviewPage(reader: { _, _, _ in reads.next() }, reviewOpener: opener)
        defer { page.close() }
        page.waitUntil("the review") { page.controller.review?.canWrite == true }
        try openFile(page, 0)
        try wait(page, until: "document.querySelector('.comment-card')")
        _ = try page.run("document.querySelector('.comment-card .action').click(); return '';")
        try wait(page, until: "document.activeElement?.classList.contains('comment-text')")
        _ = try page.run(type("Why 2, really?") + "return '';")
        let store = try store()
        page.waitUntil("the edit's draft") { store.load().record.drafts.first?.editing == "c1" }
        _ = try page.run("document.activeElement.blur(); return '';")
        let before = page.controller.snapshotCount
        page.controller.worktreeChanged(.worktree)
        page.waitUntil("the next page") { page.controller.snapshotCount > before }
        try stored(first) { $0.deleteComment(id: "c1") }
        page.controller.reloadReview()
        try wait(page, until: "document.querySelector('.comment-editor .comment-text')?.getAttribute('aria-label') === 'New comment on line 5'")
        _ = try page.run("document.querySelector('.comment-editor .comment-text').focus(); return '';")
        _ = try page.run(type("Why 2, really? Yes.") + "return '';")
        page.waitUntil("the new draft") { store.load().record.drafts.contains { $0.editing == nil } }
        XCTAssertEqual(store.load().record.drafts.first { $0.editing == nil }?.anchor?.rows.map(\.text), ["let a = 2"])
    }

    /// Claude's notes and the comments share their lines: both show under
    /// the line, the note first, and each keeps working as the other
    /// changes.
    @MainActor
    func testClaudesNotesAndCommentsShareTheirLines() throws {
        let (page, store, _, cleanUp) = try BranchReviewExplainNotesTests.pageWithANote()
        defer { cleanUp() }
        let snapshot = BranchReviewPageTests.snapshot()
        let anchor = try XCTUnwrap(BranchReview.CommentAnchor(
            file: snapshot.files[0], from: .init(side: .additions, line: 2), to: .init(side: .additions, line: 2)
        ))
        let history = BranchReview.History(isOwnCommit: { _ in true }, isInReflog: { _ in true })
        let access = try XCTUnwrap(store.open(head: snapshot.head, pullRequest: snapshot.pullRequest, history: history).access)
        _ = store.update(access) { $0.addComment(id: "c1", anchor: anchor, text: "Why 2?", at: self.date) }
        page.controller.reloadReview()
        page.waitUntil("the comment") { page.controller.pageComments?.isEmpty == false }
        _ = try page.run("\(BranchReviewExplainNotesTests.keepAwakeRow).click(); return ''")
        try wait(page, until: "document.querySelector('.note') && document.querySelector('.comment-card')")
        let slots = "[...document.querySelectorAll('.note, .comment-card')].map((n) => n.closest('[data-annotation-slot]')?.slot).join('|')"
        XCTAssertEqual(try page.run("return \(slots);"), "annotation-additions-2|annotation-additions-2")

        // A new editor under that line: the note stays, and still marks.
        _ = try page.run(gutterClick(0, 2) + "return '';")
        try wait(page, until: "document.activeElement?.classList.contains('comment-text')")
        XCTAssertEqual(try page.run("return String(document.querySelector('.note').isConnected);"), "true")
        _ = try page.run("document.querySelector('.note .more').click(); return ''")
        page.waitUntil("the mark written") { store.load().record.explanation?.files[snapshot.files[0].path]?.notes.first?.isWrong == true }
        XCTAssertEqual(
            try page.run("return [...document.querySelectorAll('.note, .comment-card, .comment-editor')].map((n) => n.className.split(' ')[0]).join('|');"),
            "note|comment-card|comment-editor"
        )
    }

    /// A note's "check this" made a comment: an editor under the note's
    /// line holds it, said to be Claude's, and Comment makes it one of the
    /// review's comments. Asked again, the same editor; Cancel gives the
    /// focus back; once it is a comment, the button says so; not in a diff
    /// read again.
    @MainActor
    func testCheckThisBecomesAComment() throws {
        let (page, store, _, cleanUp) = try BranchReviewExplainNotesTests.pageWithANote()
        defer { cleanUp() }
        _ = try page.run("\(BranchReviewExplainNotesTests.keepAwakeRow).click(); return ''")
        try wait(page, until: "document.querySelector('.note .note-comment')")
        let button = "document.querySelector('.note .note-comment')"
        XCTAssertEqual(try page.run("return \(button).textContent;"), "Comment on this")
        XCTAssertEqual(
            try page.run("return document.getElementById(\(button).getAttribute('aria-describedby')).textContent;"), "Is <i>a</i> read?"
        )
        _ = try page.run("\(button).click(); return '';")
        try wait(page, until: "document.activeElement?.classList.contains('comment-text')")
        XCTAssertEqual(try page.run("return document.activeElement.value;"), "Claude’s check: Is <i>a</i> read?")
        XCTAssertEqual(try page.run("return document.activeElement.getAttribute('aria-label');"), "New comment on line 2")
        XCTAssertEqual(try page.run("return document.activeElement.closest('[data-annotation-slot]')?.slot;"), "annotation-additions-2")
        // Saved as it is, a draft: the button still shows its editor again.
        _ = try page.run("document.activeElement.dispatchEvent(new Event('input', { bubbles: true })); return '';")
        page.waitUntil("the draft") { store.load().record.drafts.first?.text == "Claude’s check: Is <i>a</i> read?" }
        page.waitUntil("Swift's answer") { page.controller.pageComments?.contains { $0.state == "draft" } == true }
        _ = try page.run("return '';")
        XCTAssertEqual(try page.run("return String(\(button).getAttribute('aria-disabled'));"), "null")
        _ = try page.run("\(button).focus(); \(button).click(); return '';")
        try wait(page, until: "document.activeElement?.classList.contains('comment-text')")
        XCTAssertEqual(try page.run("return String(document.querySelectorAll('.comment-editor').length);"), "1")
        // Cancel: the focus goes back to the button.
        _ = try page.run("document.querySelector('.comment-editor .action.secondary').click(); return '';")
        try wait(page, until: "document.activeElement?.classList.contains('note-comment')")

        _ = try page.run("\(button).click(); return '';")
        try wait(page, until: "document.activeElement?.classList.contains('comment-text')")
        _ = try page.run("document.querySelector('.comment-editor .action:not(.secondary)').click(); return '';")
        page.waitUntil("the comment") { store.load().record.comments.count == 1 }
        let comment = try XCTUnwrap(store.load().record.comments.first)
        XCTAssertEqual(comment.text, "Claude’s check: Is <i>a</i> read?")
        XCTAssertEqual(comment.anchor.rows.map(\.text), ["let a = 2"])
        try wait(page, until: "\(button).getAttribute('aria-disabled') === 'true'")
        XCTAssertEqual(try page.run("return \(button).title;"), "This check is in a comment or a draft already.")
        _ = try page.run("\(button).click(); return '';")
        XCTAssertEqual(try page.run("return String(document.querySelectorAll('.comment-editor').length);"), "0")

        // Dimmed while its new diff is read: nothing opens, and it says why.
        let snapshot = BranchReviewPageTests.snapshot()
        let history = BranchReview.History(isOwnCommit: { _ in true }, isInReflog: { _ in true })
        let access = try XCTUnwrap(store.open(head: snapshot.head, pullRequest: snapshot.pullRequest, history: history).access)
        _ = store.update(access) { $0.deleteComment(id: comment.id) }
        page.controller.reloadReview()
        try wait(page, until: "\(button).getAttribute('aria-disabled') !== 'true'")
        _ = try page.run("document.querySelector('.file[data-path=\"Sources/KeepAwake.swift\"] .diff-box').classList.add('stale'); \(button).click(); return '';")
        try wait(page, until: "document.querySelector('.comment-notice')?.textContent === 'This diff is being read again: comment on the note once it shows.'")
        XCTAssertEqual(try page.run("return String(document.querySelectorAll('.comment-editor').length);"), "0")
    }

    /// A review that can't be written takes no comment from a note: the
    /// button says why.
    @MainActor
    func testANoteOffersNoCommentWhileNothingCanBeWritten() throws {
        let (page, store, _, cleanUp) = try BranchReviewExplainNotesTests.pageWithANote()
        defer { cleanUp() }
        // As a newer Nirux would write it.
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        json["version"] = 99
        try JSONSerialization.data(withJSONObject: json).write(to: store.fileURL)
        page.controller.reloadReview()
        page.waitUntil("read-only") { page.controller.review?.canWrite == false }
        _ = try page.run("\(BranchReviewExplainNotesTests.keepAwakeRow).click(); return ''")
        try wait(page, until: "document.querySelector('.note .note-comment')?.getAttribute('aria-disabled') === 'true'")
        XCTAssertNotEqual(try page.run("return document.querySelector('.note .note-comment').title;"), "")
    }

    /// Marked wrong, a note's check doesn't become a comment.
    @MainActor
    func testANoteMarkedWrongOffersNoComment() throws {
        let (page, store, path, cleanUp) = try BranchReviewExplainNotesTests.pageWithANote()
        defer { cleanUp() }
        _ = try page.run("\(BranchReviewExplainNotesTests.keepAwakeRow).click(); return ''")
        try wait(page, until: "document.querySelector('.note .note-comment')")
        _ = try page.run("document.querySelector('.note .more').click(); return ''")
        page.waitUntil("the mark written") { store.load().record.explanation?.files[path]?.notes.first?.isWrong == true }
        try wait(page, until: "document.querySelector('.note .note-comment').getAttribute('aria-disabled') === 'true'")
        XCTAssertEqual(try page.run("return document.querySelector('.note .note-comment').title;"), "This note is marked wrong.")
    }

    /// Comment, or Cancel, before the save a moment after the last key:
    /// no draft is left, nor an editor brought back.
    @MainActor
    func testNothingTypedOutlivesCommentOrCancel() throws {
        let page = try page()
        defer { page.close() }
        try openFile(page, 0)
        _ = try page.run(gutterClick(0, 2) + "return '';")
        try wait(page, until: "document.activeElement?.classList.contains('comment-text')")
        _ = try page.run(type("Sent at once") + """
            document.activeElement.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", metaKey: true, bubbles: true }));
            return '';
            """)
        let store = try store()
        page.waitUntil("the comment") { store.load().record.comments.count == 1 }
        _ = try page.run(#"document.querySelector('.file[data-id="0"] .file-comment').click(); return "";"#)
        try wait(page, until: "document.activeElement?.classList.contains('comment-text')")
        _ = try page.run(type("Dropped at once") + "document.querySelector('.comment-editor .action.secondary').click(); return '';")
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        _ = try page.run("return '';")
        XCTAssertTrue(store.load().record.drafts.isEmpty)
        XCTAssertEqual(try page.run("return String(document.querySelectorAll('.comment-editor').length);"), "0")
    }

    /// Two on one line keep their order while one is typed in (its draft's
    /// time moves past the other's).
    @MainActor
    func testOrderOnALineHoldsWhileTyping() throws {
        let snapshot = BranchReviewPageTests.snapshot()
        let anchor = try XCTUnwrap(BranchReview.CommentAnchor(
            file: snapshot.files[0], from: .init(side: .additions, line: 2), to: .init(side: .additions, line: 2)
        ))
        try stored(snapshot) { record in
            record.saveDraft(id: "d1", anchor: anchor, text: "Draft", at: self.date)
            record.addComment(id: "c1", anchor: anchor, text: "Comment", at: self.date + 1)
        }
        let page = try page(snapshot)
        defer { page.close() }
        try openFile(page, 0)
        let order = "[...document.querySelectorAll('.comment')].map((node) => node.dataset.key).join(',')"
        try wait(page, until: "\(order) === 'd1,c1'")
        _ = try page.run("document.querySelector('.comment-editor .comment-text').focus(); return '';")
        _ = try page.run(type("Draft, longer") + "return '';")
        let store = try store()
        page.waitUntil("the save") { store.load().record.draft(id: "d1")?.text == "Draft, longer" }
        page.waitUntil("the answer") { page.controller.pageComments?.last?.id == "d1" }
        _ = try page.run("return '';")
        XCTAssertEqual(try page.run("return \(order);"), "d1,c1")
        XCTAssertEqual(try page.run("return String(document.activeElement.classList.contains('comment-text'));"), "true")
    }
}
