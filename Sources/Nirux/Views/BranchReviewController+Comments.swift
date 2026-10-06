import Foundation
import os

// MARK: - Comments (docs/branch-review.md, section 6.1)

extension BranchReviewController {
    private typealias FilePlace = BranchReviewView.CommentRequest.FilePlace

    /// A comment's button, or a draft saved as it is typed: written after
    /// what was asked before, then answered, saved or not, so that the page
    /// shows the review again. What isn't saved says why, by the click. A
    /// request that isn't one is answered so, without a write.
    func comment(_ request: BranchReviewView.CommentRequest?, sequence: Int) {
        guard let request else {
            note(BranchReview.Page.CommentProblem(id: "", sequence: sequence, message: Self.unreadMessage), branch: snapshot?.branch)
            return acknowledge(sequence)
        }
        let date = Date()
        switch request {
        case let .saveDraft(id, .editing(comment)?, text):
            write(id: id, sequence: sequence, refusal: Self.goneMessage) { record in
                // An edit's draft is one more, but within what is left
                // past `maxBytesForNew`: one per comment.
                if record.draft(id: id) == nil, let full = Self.noRoom(record, countingBytes: false) { return full }
                // An edit's draft is where its comment is.
                return record.saveDraft(id: id, anchor: .file(""), text: text, editing: comment, at: date) ? .saved : .refused
            }
        case let .saveDraft(id, place, text):
            var file: FilePlace?
            if case .file(let named)? = place { file = named }
            let made = newAnchor(id: id, at: file)
            write(id: id, sequence: sequence, refusal: made.problem ?? Self.draftMessage) { record in
                guard let anchor = made.anchor ?? (record.draft(id: id) == nil ? nil : .file("")) else { return text.isEmpty ? .saved : .refused }
                if record.draft(id: id) == nil, let full = Self.noRoom(record) { return full }
                return record.saveDraft(id: id, anchor: anchor, text: text, at: date) ? .saved : .refused
            }
        case let .addComment(id, place, text):
            let made = newAnchor(id: id, at: place)
            let refusal = Self.isBlank(text) ? Self.blankMessage : made.problem ?? Self.commentMessage
            write(id: id, sequence: sequence, refusal: refusal) { record in
                // Where its draft was fixed, when it has one.
                guard let anchor = made.anchor ?? (record.draft(id: id) == nil ? nil : .file("")) else { return .refused }
                if record.draft(id: id) == nil, let full = Self.noRoom(record) { return full }
                return record.addComment(id: id, anchor: anchor, text: text, at: date) ? .saved : .refused
            }
        case let .editComment(id, text):
            write(id: id, sequence: sequence, refusal: Self.isBlank(text) ? Self.blankMessage : Self.goneMessage) { record in
                record.editComment(id: id, text: text, at: date) ? .saved : .refused
            }
        case let .removeDraft(id):
            write(id: id, sequence: sequence, refusal: Self.draftMessage) { record in
                record.removeDraft(id: id)
                return .saved
            }
        case let .deleteComment(id):
            write(id: id, sequence: sequence, refusal: Self.commentMessage) { record in
                record.deleteComment(id: id)
                return .saved
            }
        }
    }

    private static let goneMessage = "This comment was sent or deleted meanwhile: it can’t be changed."
    private static let draftMessage = "Nirux couldn’t save this draft."
    private static let commentMessage = "Nirux couldn’t save this comment."
    private static let blankMessage = "A comment needs some text."
    private static let unreadMessage = "Nirux couldn’t read this request from the page: nothing was saved."
    private static let fullMessage = "This review holds \(maxComments) comments and drafts: delete some to write more."
    private static let largeMessage = "This review is too large to take another comment: delete some to write more."

    /// Past this, a review takes no new comment or draft: each is placed
    /// in the diff every time the page shows it.
    nonisolated static let maxComments = 1_000
    /// Past this many bytes, a review takes no new comment or draft: what
    /// is left of the file's limit keeps Reviewed marks, edits and
    /// deletes written.
    nonisolated static let maxBytesForNew = BranchReview.Store.maxFileBytes * 3 / 4

    /// Why `record` takes no new comment or draft; nil when it does.
    nonisolated static func noRoom(_ record: BranchReview.Record, countingBytes: Bool = true) -> CommentWrite? {
        guard record.comments.count + record.drafts.count < maxComments else { return .full }
        guard countingBytes else { return nil }
        let bytes = (try? JSONEncoder().encode(record.fields).count) ?? .max
        return bytes < maxBytesForNew ? nil : .tooLarge
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What a change made of a request.
    enum CommentWrite: Sendable {
        case saved
        case refused
        /// Refused: the review holds `maxComments`.
        case full
        /// Refused: the review holds `maxBytesForNew`.
        case tooLarge
    }

    /// `change` written; the page's click `sequence` answered after, with
    /// why when it wasn't saved: refused (`refusal`, or the review is
    /// full), or not written (the review's problem).
    private func write(
        id: String, sequence: Int, refusal: String, _ change: @escaping @Sendable (inout BranchReview.Record) -> CommentWrite
    ) {
        let outcome = OSAllocatedUnfairLock<CommentWrite?>(initialState: nil)
        let branch = snapshot?.branch
        writeReview({ record in
            let made = change(&record)
            outcome.withLock { $0 = made }
        }, completion: { [weak self] state in
            guard let self else { return }
            let made = outcome.withLock { $0 }
            if made != .saved || state.problem != nil {
                let message = state.problem ?? (made == .full ? Self.fullMessage : made == .tooLarge ? Self.largeMessage : refusal)
                note(BranchReview.Page.CommentProblem(id: id, sequence: sequence, message: message), branch: branch)
            }
            acknowledge(sequence)
        })
    }

    /// Keeps `problem` for the page, while `branch` shows: the latest 32.
    private func note(_ problem: BranchReview.Page.CommentProblem, branch: String?) {
        guard branch == snapshot?.branch else { return }
        commentProblems = Array((commentProblems + [problem]).suffix(32))
    }

    /// The anchor of a new comment, before its draft exists: nil once it
    /// does (its anchor is fixed), or when it can't be made, and why.
    private func newAnchor(id: String, at place: FilePlace?) -> (anchor: BranchReview.CommentAnchor?, problem: String?) {
        guard reviewRecord?.draft(id: id) == nil else { return (nil, nil) }
        guard let place else { return (nil, "This draft is gone: write it again.") }
        let rows = place.start.flatMap { start in place.end.map { (start: start, end: $0) } }
        return commentAnchor(file: place.file, generation: place.generation, rows: rows)
    }

    /// Where a new comment goes: the rows from `start` to `end` of file
    /// `id` of the page they were chosen in (`generation`: this branch's
    /// page, or one of its last), or the whole file. Nil, and why, when
    /// that page is another branch's or too old, or the rows can't be
    /// commented together.
    private func commentAnchor(
        file id: Int, generation: Int, rows: (start: BranchReview.DiffPosition, end: BranchReview.DiffPosition)?
    ) -> (anchor: BranchReview.CommentAnchor?, problem: String?) {
        let changed = (nil as BranchReview.CommentAnchor?, "The diff changed since these lines were chosen: choose them again.")
        let file: BranchReview.FileChange
        if generation == snapshotCount, let snapshot {
            guard snapshot.files.indices.contains(id) else { return changed }
            file = readFiles[id] ?? snapshot.files[id]
        } else if let earlier = earlierFiles.last(where: { $0.generation == generation }) {
            guard earlier.files.indices.contains(id) else { return changed }
            file = earlier.files[id]
        } else {
            return changed
        }
        guard let rows else { return (.file(file.path), nil) }
        guard let anchor = BranchReview.CommentAnchor(file: file, from: rows.start, to: rows.end) else {
            return (nil, "These lines can’t take one comment: keep to one hunk, 100 lines and 32,000 bytes, or comment on the file.")
        }
        return (anchor, nil)
    }

    /// Records where the comments are in the files as read now
    /// (`Record.reanchor`), so that each is looked for from there next
    /// time: once the review is open, and once a row's patch is read
    /// (`paths`: the file's, and the one it was renamed from). Only in a review that has comments on rows and can be
    /// written: it is never created for this.
    func reanchorComments(of paths: [String]? = nil) {
        guard let snapshot, let review, review.isKnown, review.canWrite, review.branch == snapshot.branch else { return }
        let paths = paths.map(Set.init)
        let anchors = review.record.comments.flatMap { [$0.anchor] + ($0.moved.map { [$0] } ?? []) }
            + review.record.drafts.flatMap { draft in [draft.anchor, draft.moved].compactMap { $0 } }
        guard anchors.contains(where: { !$0.isFile && (paths?.contains($0.path) ?? true) }) else { return }
        let files = snapshot.files.indices.map { readFiles[$0] ?? snapshot.files[$0] }
        let head = snapshot.head
        writeReview { Self.reanchor(&$0, in: files, paths: paths, at: head) }
    }

    /// `record`'s comments, those at `paths` or all, recorded where they
    /// are in `files`, read at `head`; not once the review was opened at
    /// another head since (a column at a later one): where they are is
    /// that head's to say.
    nonisolated static func reanchor(
        _ record: inout BranchReview.Record, in files: [BranchReview.FileChange], paths: Set<String>?, at head: String
    ) {
        guard record.lastHead == head else { return }
        _ = record.reanchor(in: files, paths: paths)
    }
}
