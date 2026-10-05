import AppKit

// MARK: - Explain's work, cache read and notice (docs/branch-review.md, section 4.3)

extension BranchReviewController {
    /// The queue's work: `explainer` with progress sent to the main actor.
    /// Nonisolated, so that neither closure is a main-actor one run off the
    /// main thread (#48).
    nonisolated static func explainWork(
        _ job: BranchReview.ExplainJob, explainer: @escaping Explainer,
        progress: @escaping @MainActor @Sendable (BranchReview.ExplainJobProgress) -> Void
    ) -> @Sendable (BoundedProcess.Cancellation) -> BranchReview.ExplainResult {
        { cancellation in
            explainer(job, cancellation) { update in
                DispatchQueue.main.async { progress(update) }
            }
        }
    }

    /// `BranchReview.explain`, once the worktree is still on the job's
    /// branch: Claude reads the worktree's files, and a run that waited in
    /// line, or was asked for under a banner saying the worktree moved on,
    /// would explain one branch's diff with another's files.
    nonisolated static func explainOnItsBranch(
        _ job: BranchReview.ExplainJob, cancellation: BoundedProcess.Cancellation,
        progress: @escaping @Sendable (BranchReview.ExplainJobProgress) -> Void
    ) -> BranchReview.ExplainResult {
        // The full ref: a tag of the same name shortens it to `heads/…`.
        let current = BranchReview.git(["symbolic-ref", "-q", "HEAD"], in: job.snapshot.root, options: job.options)
        guard current?.status == 0, current?.text.trimmingCharacters(in: .newlines) == "refs/heads/" + job.snapshot.branch else {
            return BranchReview.ExplainResult(ending: .cantKeep(
                "The worktree isn’t on \(job.snapshot.branch) anymore: Explain didn’t run. Review the branch it’s on, then Explain."
            ))
        }
        return BranchReview.explain(job, cancellation: cancellation, progress: progress)
    }

    /// What Explain kept for `snapshot`'s branch, without recording a head
    /// or writing anything: only from the branch's own review, as opening
    /// it would keep it (`BranchReview.disposition`), never from an
    /// earlier branch of that name. Runs git: call it off the main thread.
    nonisolated static func readExplanation(
        for snapshot: BranchReview.Snapshot, stateDirectory: URL = Persistence.stateDirectory,
        options: BranchReview.Options = BranchReview.Options()
    ) -> BranchReview.Explanation? {
        guard let repository = BranchReview.repositoryIdentity(root: snapshot.root, options: options),
              let store = BranchReview.Store(repository: repository, branch: snapshot.branch, stateDirectory: stateDirectory)
        else { return nil }
        let loaded = store.load()
        guard let explanation = loaded.record.explanation else { return nil }
        let disposition = BranchReview.disposition(
            of: loaded.record, branch: snapshot.branch, repository: repository, head: snapshot.head,
            pullRequest: snapshot.pullRequest, history: BranchReview.history(of: snapshot, options: options)
        )
        return disposition == .keep ? explanation : nil
    }

    /// The first-use notice: what Explain sends, where, and under which
    /// account. Its first button explains.
    static func explainAlert(account: BranchReview.ExplainAccount, files: Int) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Explain this branch with Claude?"
        alert.informativeText = explainNotice(account: account, files: files)
        alert.addButton(withTitle: "Explain")
        alert.addButton(withTitle: "Cancel")
        if account.isBilledPerCall { alert.alertStyle = .warning }
        return alert
    }

    nonisolated static func explainNotice(account: BranchReview.ExplainAccount, files: Int) -> String {
        let who = account.email.map { "\(account.label) (\($0))" } ?? account.label
        let cost = account.isBilledPerCall
            ? "This account is billed per call: each run can cost up to $3 at API prices, and a large branch takes "
                + "several runs. Nirux asks again each time."
            : "It counts toward your plan’s usage limits. Nirux asks again if the account changes."
        return "Claude reads the diff of \(BranchReview.count(files, "file")), the pull request, the handover and the commits, "
            + "and a read-only copy of the branch’s files (secrets and instruction files left out). "
            + "They go to Anthropic under \(who).\n\nAbout a minute or two. \(cost)"
    }
}
