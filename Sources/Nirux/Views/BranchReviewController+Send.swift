import Foundation

// MARK: - Sending the comments to the agent (docs/branch-review.md, section 6.2)

extension BranchReviewController {
    /// What "Send N Comments to Agent" sends now: the unsent comments,
    /// oldest first, in one message, and what the sheet says of the rest.
    struct AgentSend: Equatable, Sendable {
        let message: BranchReview.AgentMessage
        /// The text of each comment in the message, as it goes: one edited
        /// before Claude takes it isn't marked sent.
        let texts: [String: String]
        /// Unsent comments already pasted into a prompt, not submitted.
        let inPrompt: Int
        /// Drafts of new comments: they don't go.
        let drafts: Int
        /// Edits under way of comments that go: each goes as it was saved,
        /// and what the edit changed stays as a new comment's draft.
        let edits: Int
        let branch: String
        let head: String
        /// The worktree the agent must run in.
        let root: String
        let pullRequest: Int?

        /// The line Claude's prompt holds once it took the message.
        var header: String { message.text.split(separator: "\n").first.map(String.init) ?? "" }
    }

    /// Nil when the review isn't open or no comment is unsent.
    func agentSend() -> AgentSend? {
        guard let snapshot, let review, review.isKnown, review.branch == snapshot.branch else { return nil }
        let record = review.record
        // Oldest first, as the record lists them.
        let unsent = record.comments.filter { $0.sent == nil }
        guard !unsent.isEmpty else { return nil }
        let waiting = unsent.filter { pastedComments[$0.id] == $0.text }
        let files = snapshot.files.indices.map { readFiles[$0] ?? snapshot.files[$0] }
        let message = BranchReview.agentMessage(
            for: unsent.filter { pastedComments[$0.id] != $0.text }, snapshot: snapshot, files: files
        )
        let included = Set(message.ids)
        return AgentSend(
            message: message,
            texts: Dictionary(unsent.filter { included.contains($0.id) }.map { ($0.id, $0.text) }) { first, _ in first },
            inPrompt: waiting.count,
            drafts: record.drafts.filter { $0.editing == nil }.count,
            edits: record.drafts.filter { $0.editing.map(included.contains) ?? false }.count,
            branch: snapshot.branch, head: snapshot.head, root: snapshot.root,
            pullRequest: snapshot.pullRequest.pullRequest?.number
        )
    }

    /// The comments of `send` were pasted into a prompt: Send leaves them
    /// out until Claude takes it, or the paste is let go.
    func notePasted(_ send: AgentSend) {
        pastedComments.merge(send.texts) { _, pasted in pasted }
        sendReview()
    }

    /// The prompt `send` was pasted into went in (`taken`), or can't any
    /// more: its comments, still as they went and unsent, are marked sent
    /// at the head they went at, on the branch they are of. Not another
    /// branch's review, if it shows by then.
    func pasteSettled(_ send: AgentSend, taken: Bool) {
        for (id, text) in send.texts where pastedComments[id] == text { pastedComments[id] = nil }
        sendReview()
        guard taken else { return }
        markSent(send.texts, branch: send.branch, head: send.head)
    }

    /// The comments of `texts` marked sent at `head`, those still unsent
    /// and as they were when they went.
    func markSent(_ texts: [String: String], branch: String, head: String) {
        guard snapshot?.branch == branch else { return }
        let date = Date()
        writeReview { record in
            let ids = texts.filter { id, text in record.comment(id: id).map { $0.sent == nil && $0.text == text } ?? false }.keys
            _ = record.markSent(ids: Array(ids).sorted(), head: head, at: date)
        }
    }
}
