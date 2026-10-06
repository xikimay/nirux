import AppKit
import os

// MARK: - Sending a review's comments to its agent (docs/branch-review.md, section 6.2)

extension NiruxShellView {
    /// An agent column the comments could go to, as listed now.
    struct ReviewSendColumn: Equatable {
        let workspaceID: String
        let columnID: UUID
        let label: String
        let refusal: ReviewSendRefusal?
        let hasDraft: Bool
        /// The process in front the paste must stay in front of.
        let process: ProcessInstance?
    }

    /// "Send N Comments to Agent": the sheet, once the worktrees nested in
    /// the reviewed one are known (an agent in one of those works on
    /// another branch).
    func sendReviewComments(from review: BranchReviewController) {
        guard reviewSendPanel == nil, let send = review.agentSend() else { return }
        let root = send.root
        BranchReviewController.inBackground(on: .global(qos: .userInitiated), {
            WorktreeCleanup.worktreeListing(in: root, tools: WorktreeCleanup.Tools())?.map(\.path)
        }, then: { [weak self, weak review] worktrees in
            guard let self, let review, self.reviewSendPanel == nil else { return }
            self.showReviewSendSheet(for: review, worktrees: worktrees)
        })
    }

    /// What the sheet shows and sends, read again as the review and the
    /// columns change.
    final class ReviewSendSession {
        weak var review: BranchReviewController?
        /// Nil when git couldn't list them: nothing is offered then.
        let worktrees: [String]?
        var send: BranchReviewController.AgentSend?
        var columns: [ReviewSendColumn] = []
        var refreshedAt: TimeInterval = 0
        let cancelled = OSAllocatedUnfairLock(initialState: false)

        init(review: BranchReviewController, worktrees: [String]?) {
            self.review = review
            self.worktrees = worktrees
        }
    }

    private func showReviewSendSheet(for review: BranchReviewController, worktrees: [String]?) {
        AgentHookCenter.shared.drain()
        let session = ReviewSendSession(review: review, worktrees: worktrees)
        guard let content = readReviewSend(session, snapshot: ProcessSnapshot()) else { return }
        let panel = ReviewSendPanel(content: content)
        panel.onSend = { [weak self, weak panel] id in
            guard let self, let panel else { return }
            self.send(session, to: id, panel: panel)
        }
        panel.onCancelSending = { session.cancelled.withLock { $0 = true } }
        panel.onRefresh = { [weak self, weak panel] snapshot in
            // Once a second at most: the metadata refresh runs several
            // times a second while agents work.
            let now = ProcessInfo.processInfo.systemUptime
            guard let self, let panel, !panel.isSending, now - session.refreshedAt >= 1 else { return }
            session.refreshedAt = now
            guard let content = self.readReviewSend(session, snapshot: snapshot) else { return panel.dismiss() }
            panel.update(content)
        }
        panel.onDismiss = { [weak self] in self?.reviewSendPanel = nil }
        reviewSendPanel = panel
        panel.show(attachedTo: window)
    }

    /// The review's comments and the columns, read again; nil once the
    /// review is gone.
    private func readReviewSend(_ session: ReviewSendSession, snapshot: ProcessSnapshot) -> ReviewSendPanel.Content? {
        guard let review = session.review else { return nil }
        session.send = review.agentSend()
        guard let send = session.send else {
            return ReviewSendPanel.Content(
                title: "Send Comments to Agent", subtitle: "", message: "", targets: [],
                refusal: "No comment is left to send: they went, or were deleted.", canCopy: false
            )
        }
        session.columns = session.worktrees.map {
            reviewSendColumns(root: send.root, allWorktrees: $0, snapshot: snapshot)
        } ?? []
        var content = Self.reviewSendContent(send, columns: session.columns, queued: isQueued(send, of: review))
        if session.worktrees == nil {
            content.refusal = "Nirux couldn’t list this repository’s worktrees, so it can’t tell which agent works on "
                + "this branch: Copy Message, and paste it there yourself."
        }
        return content
    }

    /// Send, to the column `id`: checked again (Claude may have started a
    /// turn, the comments changed), then pasted; once Claude takes the
    /// prompt (the user submitted it), the comments in it are sent.
    private func send(_ session: ReviewSendSession, to id: UUID, panel: ReviewSendPanel) {
        AgentHookCenter.shared.drain()
        let shown = session.send
        guard let content = readReviewSend(session, snapshot: ProcessSnapshot()) else { return panel.dismiss() }
        panel.update(content)
        guard let review = session.review, let send = session.send, send == shown else {
            return panel.showError("The comments changed meanwhile: read the message again, then Send.")
        }
        guard let column = session.columns.first(where: { $0.columnID == id }) else {
            return panel.showError("That column closed, or no longer runs an agent: pick another.")
        }
        if let refusal = column.refusal { return panel.showError(refusal.message) }
        guard let pty = workspaces.first(where: { $0.id == column.workspaceID })?.columns.first(where: { $0.id == id })?.pty else {
            return panel.showError("That column closed: pick another.")
        }
        let pastedAt = Date().timeIntervalSince1970
        session.cancelled.withLock { $0 = false }
        panel.showSending()
        let cancelled = session.cancelled
        pty.pasteInBackground(
            BranchReview.agentPaste(send.message.text), keepingInFront: column.process,
            cancelled: { cancelled.withLock { $0 } }
        ) { [weak self, weak review, weak panel] outcome in
            guard outcome == .pasted else {
                panel?.showError(Self.pasteProblem(outcome))
                return
            }
            review?.notePasted(send)
            pty.onNextPrompt(after: pastedAt, from: column.process, header: send.header) { [weak review] taken in
                MainActor.assumeIsolated { review?.pasteSettled(send, taken: taken) }
            }
            panel?.dismiss()
            // The user reads it there, and submits it.
            guard let self, let workspace = self.workspaces.first(where: { $0.id == column.workspaceID }),
                  let index = workspace.columns.firstIndex(where: { $0.id == id }) else { return }
            self.focusWorkspace(id: workspace.id, column: index)
        }
    }

    /// Why a paste didn't go in full.
    static func pasteProblem(_ outcome: PtySession.PasteOutcome) -> String {
        switch outcome {
        case .pasted: return ""
        case .closed: return "Nirux couldn’t paste the message: the terminal closed."
        case .agentLeft:
            return "The agent left the terminal before the message was all in: Nirux typed no more. "
                + "Clear what reached it before sending again."
        case .cancelled:
            return "Cancelled: Nirux ended the paste. Clear what reached the agent’s prompt before sending again."
        case .timedOut:
            return "The agent stopped reading the paste: Nirux ended it. Clear what reached its prompt before sending again."
        }
    }

    /// The agent columns of `root`: those whose agent, by its own folder
    /// (where `claude --worktree` works) or else the shell's, runs inside
    /// `root`, not inside a worktree nested in it (`allWorktrees`): opened
    /// from the main checkout, the review never offers the agent of another
    /// worktree. In sidebar order, each with why the comments can't go
    /// there now. The label names the workspace, the agent, the column's
    /// place and folder: a terminal title changes as the agent works.
    func reviewSendColumns(root: String, allWorktrees: [String], snapshot: ProcessSnapshot) -> [ReviewSendColumn] {
        let roots = [Self.comparablePath(root)]
        let others = allWorktrees.map(Self.comparablePath)
        var columns: [ReviewSendColumn] = []
        for workspace in workspaces where !workspace.isClosing {
            for (index, column) in workspace.columns.enumerated() where !column.isClosing {
                guard let pty = column.pty, let name = pty.runningAgentName(snapshot: snapshot),
                      let folder = pty.agentCwd(snapshot: snapshot),
                      MergeQueue.isInside(Self.comparablePath(folder), roots: roots, allWorktrees: others) else { continue }
                let foreground = pty.foregroundProcess(snapshot: snapshot)
                let inFront = foreground.map { AgentStatusMachine.isRecognizedAgentProcess($0.name) } == true
                let refusal: ReviewSendRefusal? = if inFront {
                    pty.reviewSendRefusal(snapshot: snapshot)
                } else if let foreground, Self.interactiveShells.contains(foreground.name) {
                    .notInFront
                } else {
                    .underLauncher(foreground?.name ?? "another program")
                }
                columns.append(ReviewSendColumn(
                    workspaceID: workspace.id, columnID: column.id,
                    label: "\(workspace.title) — \(name), column \(index + 1) · \((folder as NSString).abbreviatingWithTildeInPath)",
                    refusal: refusal,
                    hasDraft: pty.reviewSendHasDraft, process: inFront ? foreground?.instance : nil
                ))
            }
        }
        return columns
    }

    /// Shells: one in front of an agent of its own runs it stopped or in
    /// the background, not as a launcher.
    static let interactiveShells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "elvish"]

    /// What the sheet says of `send` and the columns it could go to.
    static func reviewSendContent(
        _ send: BranchReviewController.AgentSend, columns: [ReviewSendColumn], queued: Bool
    ) -> ReviewSendPanel.Content {
        let count = send.message.ids.count
        let comments = { (count: Int) in count == 1 ? "1 comment" : "\(count) comments" }
        var notes: [String] = []
        if send.inPrompt > 0 {
            notes.append("\(comments(send.inPrompt).capitalizedFirst) \(send.inPrompt == 1 ? "is" : "are") already in an "
                + "agent’s prompt, not submitted: \(send.inPrompt == 1 ? "it doesn’t" : "they don’t") go again.")
        }
        if send.message.leftOut > 0 {
            let leftOut = send.message.leftOut
            notes.append("\(comments(leftOut).capitalizedFirst) \(leftOut == 1 ? "doesn’t" : "don’t") fit in one message: "
                + "\(leftOut == 1 ? "it stays" : "they stay") unsent, for another send.")
        }
        if send.edits > 0 {
            notes.append("\(comments(send.edits).capitalizedFirst) being edited \(send.edits == 1 ? "goes" : "go") as saved; "
                + "what \(send.edits == 1 ? "its edit" : "their edits") changed stays as a new comment’s draft.")
        }
        if send.drafts > 0 {
            notes.append("\(send.drafts == 1 ? "1 draft doesn’t" : "\(send.drafts) drafts don’t") go: Comment "
                + "\(send.drafts == 1 ? "it" : "them") first.")
        }
        var refusal: String?
        if count == 0, send.message.leftOut == 0 {
            refusal = "These comments are already in an agent’s prompt: submit it there."
        } else if count == 0 {
            refusal = "No comment fits in one message: shorten them."
        } else if columns.isEmpty {
            refusal = "No agent runs in this worktree: start Claude Code in a column there (or resume it), or Copy Message."
        }
        return ReviewSendPanel.Content(
            title: count == 1 ? "Send 1 Comment to Agent" : "Send \(count) Comments to Agent",
            subtitle: "\(BranchReview.visible(send.branch)) · head \(send.head.prefix(7))",
            message: send.message.text,
            targets: columns.map { column in
                ReviewSendPanel.Content.Target(
                    id: column.columnID, label: column.label, refusal: column.refusal?.message,
                    warnings: column.hasDraft ? ["Something was typed at its prompt since its last prompt: the comments join it."] : []
                )
            },
            warnings: queued && send.pullRequest != nil
                ? ["#\(send.pullRequest ?? 0) is in the merge queue: the agent’s push will stop the queue."] : [],
            notes: notes,
            refusal: refusal,
            canCopy: count > 0
        )
    }

    /// Whether the review's pull request is in its project's merge queue,
    /// under way here or in another Nirux.
    private func isQueued(_ send: BranchReviewController.AgentSend, of review: BranchReviewController) -> Bool {
        guard let number = send.pullRequest,
              let project = workspaces.first(where: { $0.columns.contains { $0.branchReview === review } })?.profileID
        else { return false }
        return mergeQueues[project]?.queues(number) == true
    }
}

extension MergeQueueController {
    /// Pull request `number` waits or is under way in this queue, here or
    /// in another Nirux: a push to its branch stops the queue.
    func queues(_ number: Int) -> Bool {
        let entries = isRunning ? engine?.entries.map { ($0.number, $0.step) } : runsElsewhere ? saved?.entries.map { ($0.number, $0.step) } : nil
        return entries?.contains { $0.0 == number && $0.1 != .done } == true
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
