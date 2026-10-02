import Foundation

// MARK: - The confirmation sheet (docs/project-board.md, section 4)

extension MergeQueue {
    /// What the confirmation sheet read when Start opened it: GitHub's
    /// answers for the queue as a whole and for each pull request, with
    /// the pull request's worktrees on this Mac.
    struct ConfirmationReading: Equatable, Sendable {
        struct Candidate: Equatable, Sendable {
            let number: Int
            var pullRequest: PullRequestSnapshot?
            var details: PullRequestDetails?
            var checks: CommitChecks?
            /// `compare/{base}...{head}`; `.some(nil)` when GitHub doesn't
            /// know the head.
            var comparison: Comparison??
            var local: LocalState?
            /// Why it couldn't be read in full: it is left out.
            var error: String?
            /// Its checks or its files couldn't be read: shown, not left out
            /// (the queue reads the checks again anyway).
            var checksError: String?
            var detailsError: String?
            var compareError: String?

            init(number: Int) {
                self.number = number
            }
        }

        let settings: BoardConfig.QueueSettings
        let isDryRun: Bool
        /// Why GitHub couldn't be read for the queue as a whole: gh
        /// missing, signed out, no answer. Start is refused.
        var setupError: String?
        var rateLimit: RateLimit?
        var baseMergeQueue: Bool?
        /// The post-merge workflow's recent runs on the base, newest first.
        var baseRuns: [Run]?
        /// In the order the next Start proposes.
        var candidates: [Candidate] = []
    }

    /// The sheet's content: the pull requests that join, in order, those
    /// left out with why, what may go wrong, and what will happen. Only
    /// the user reorders it.
    struct Confirmation: Equatable, Sendable {
        struct Item: Equatable, Sendable {
            let entry: ConfirmedEntry
            let title: String?
            let url: String?
            /// The required checks on the confirmed head: "test ✓".
            let checks: String
            /// What the queue will do with it: "Behind main by 3 commits…".
            var notes: [String] = []
            /// What may stop the queue, or deserves a look.
            var warnings: [String] = []
        }

        struct Excluded: Equatable, Sendable {
            let number: Int
            let title: String?
            let reason: String
            let url: String?
        }

        let settings: BoardConfig.QueueSettings
        let isDryRun: Bool
        private(set) var items: [Item]
        let excluded: [Excluded]
        /// Top of the sheet: the base may be broken, a run is going on it.
        let warnings: [String]
        /// Why Start is refused.
        let refusals: [String]

        var canStart: Bool { refusals.isEmpty && !items.isEmpty }
        var entries: [ConfirmedEntry] { items.map(\.entry) }

        /// Moves an item up (-1) or down (+1): the user's order, never
        /// Nirux's.
        mutating func move(_ index: Int, by offset: Int) {
            let target = index + offset
            guard items.indices.contains(index), items.indices.contains(target) else { return }
            items.swapAt(index, target)
        }

        /// What will happen, line by line (section 4).
        var plan: [String] {
            let base = settings.baseBranch
            let workflow = settings.postMergeWorkflow
            let label = MergeQueue.workflowLabel(workflow)
            let count = items.count
            let method = settings.mergeMethod == .squash ? "Squash and merge it" : "Merge it with a merge commit"
            var lines = [
                "In this order, for each pull request:",
                "• If its branch is behind \(base), merge \(base) into it on GitHub (never a rebase or a force push), "
                    + "at most \(Limits.maxUpdates) times.",
                "• Wait for the required checks on its head: \(settings.requiredChecks.joined(separator: ", ")) "
                    + "(up to \(settings.checksTimeoutMinutes) minutes). A failed one is rerun once; a second failure stops "
                    + "the queue.",
                "• \(method), pinned to the head shown here, or to the queue’s own updates of it "
                    + "(gh pr merge --\(settings.mergeMethod.rawValue) --match-head-commit).",
            ]
            if let workflow {
                lines.append("• Wait for \(workflow) on \(base) (up to \(settings.postMergeTimeoutMinutes) minutes), "
                    + "then go on to the next one.")
                let merges = "\(count) merge\(count == 1 ? "" : "s")"
                // A nightly publishes: say how many; another workflow, how often it runs.
                if label.lowercased().contains("nightly") {
                    let nightlies = "\(count) \(count == 1 ? label : MergeQueue.plural(label))"
                    lines.append(isDryRun
                        ? "A real queue would publish \(nightlies), one after each merge. This dry run publishes none."
                        : "This queue publishes \(nightlies): \(workflow) runs after each of its \(merges).")
                } else {
                    lines.append(isDryRun
                        ? "A real queue would run \(workflow) \(count) time\(count == 1 ? "" : "s"), after each merge. This "
                            + "dry run merges nothing, so it runs none."
                        : "This queue runs \(workflow) \(count) time\(count == 1 ? "" : "s"): after each of its \(merges).")
                }
            } else {
                lines.append("• Go on to the next one right away: no post-merge workflow.")
                lines.append(isDryRun
                    ? "A real queue would make \(count) merge\(count == 1 ? "" : "s") into \(base). This dry run makes none."
                    : "This queue makes \(count) merge\(count == 1 ? "" : "s") into \(base), one right after the other.")
            }
            lines.append("It stops at the first problem. Stop is in the board and in the status bar; a call already "
                + "sent to GitHub finishes.")
            return lines
        }
    }

    /// The sheet's content from what it read. A pull request is left out
    /// when the queue would stop on it at once (section 4): not open, a
    /// draft, another base, a fork, auto-merge or GitHub's merge queue, a
    /// conflict, a busy agent, tracked changes or unpushed commits in its
    /// worktree, or anything Nirux couldn't read.
    static func confirmation(_ reading: ConfirmationReading, now: Date = Date()) -> Confirmation {
        let settings = reading.settings
        var items: [Confirmation.Item] = []
        var excluded: [Confirmation.Excluded] = []
        if reading.setupError == nil {
            for candidate in reading.candidates {
                switch confirmationItem(candidate, settings: settings) {
                case .joins(let item): items.append(item)
                case .leftOut(let left): excluded.append(left)
                }
            }
        }
        var refusals: [String] = []
        if let error = reading.setupError {
            refusals.append(error)
        } else {
            if let limit = reading.rateLimit {
                let remaining = min(limit.coreRemaining, limit.graphQLRemaining)
                if remaining < Limits.minimumRateLimit {
                    // Start works again once every pool short of requests has reset.
                    let reset = [(limit.coreRemaining, limit.coreReset), (limit.graphQLRemaining, limit.graphQLReset)]
                        .filter { $0.0 < Limits.minimumRateLimit }.map(\.1).max() ?? limit.coreReset
                    refusals.append("Only \(remaining) GitHub request\(remaining == 1 ? " is" : "s are") left until "
                        + "\(ProjectBoard.clockTime(reset, now: now)) (REST \(limit.coreRemaining), GraphQL "
                        + "\(limit.graphQLRemaining)): the queue needs \(Limits.minimumRateLimit) in each.")
                }
            }
            if reading.baseMergeQueue == true {
                refusals.append("\(settings.baseBranch) requires GitHub’s merge queue: gh pr merge would queue pull "
                    + "requests there instead of merging them, without waiting for the post-merge workflow.")
            }
            if items.isEmpty { refusals.append("No pull request can join the queue.") }
        }
        return Confirmation(
            settings: settings,
            isDryRun: reading.isDryRun,
            items: items,
            excluded: excluded,
            warnings: reading.setupError == nil ? baseWarnings(reading.baseRuns, settings: settings) : [],
            refusals: refusals
        )
    }

    /// The last post-merge run on the base failed: the base may already be
    /// broken. One still running: the first merge waits for it.
    private static func baseWarnings(_ runs: [Run]?, settings: BoardConfig.QueueSettings) -> [String] {
        guard let workflow = settings.postMergeWorkflow, let runs else { return [] }
        let label = MergeQueue.workflowLabel(workflow)
        var warnings: [String] = []
        if let last = runs.first(where: \.isCompleted), runFailed(last) {
            warnings.append("The last \(label) on \(settings.baseBranch) failed (\(Engine.short(last.headSha))"
                + (last.title.map { ", “\($0)”" } ?? "") + "): the base may already be broken.")
        }
        if runs.contains(where: { !$0.isCompleted }) {
            warnings.append("A \(label) is running on \(settings.baseBranch): the first merge waits for it, and the "
                + "queue stops if it fails.")
        }
        return warnings
    }

    private enum Placement {
        case joins(Confirmation.Item)
        case leftOut(Confirmation.Excluded)
    }

    private static func confirmationItem(
        _ candidate: ConfirmationReading.Candidate, settings: BoardConfig.QueueSettings
    ) -> Placement {
        let pullRequest = candidate.pullRequest
        let title = candidate.details?.title
        let leftOut = { (reason: String) in
            Placement.leftOut(Confirmation.Excluded(number: candidate.number, title: title, reason: reason, url: pullRequest?.url))
        }
        guard let pullRequest else {
            return leftOut(candidate.error.map { "Couldn’t read it on GitHub: \($0)" } ?? "Couldn’t read it on GitHub.")
        }
        if let reason = exclusionReason(pullRequest, settings: settings) { return leftOut(reason) }
        if let error = candidate.error { return leftOut("Couldn’t read it in full: \(error)") }
        let entry = ConfirmedEntry(number: pullRequest.number, head: pullRequest.headOid, branch: pullRequest.headRefName)
        if let problem = MergeQueueController.problem(with: [entry]) { return leftOut(problem) }
        if case .some(nil) = candidate.comparison {
            return leftOut("GitHub can’t compare its head \(Engine.short(pullRequest.headOid)) with \(settings.baseBranch).")
        }
        guard let local = candidate.local else { return leftOut("Its worktrees on this Mac couldn’t be checked.") }
        if !local.busyAgents.isEmpty {
            return leftOut(local.busyAgents.joined(separator: "; ") + ": wait until it is back at its prompt.")
        }
        if let reason = local.worktrees.lazy.compactMap(localProblem).first { return leftOut(reason) }

        var item = Confirmation.Item(
            entry: entry,
            title: title,
            url: pullRequest.url,
            checks: candidate.checks.map { checksText($0, required: settings.requiredChecks) }
                ?? "checks unknown" + (candidate.checksError.map { ": \($0)" } ?? "")
        )
        if case .some(.some(let comparison)) = candidate.comparison, comparison.behindBy > 0 {
            item.notes.append("Behind \(settings.baseBranch) by \(comparison.behindBy) "
                + "commit\(comparison.behindBy == 1 ? "" : "s"): the queue merges \(settings.baseBranch) into it first.")
        } else if candidate.comparison == nil {
            item.notes.append("Nirux couldn’t tell whether it is behind \(settings.baseBranch)"
                + (candidate.compareError.map { " (\($0))" } ?? "") + ": the queue checks again.")
        }
        if pullRequest.mergeable == "UNKNOWN" {
            item.notes.append("GitHub is still computing whether it merges cleanly: the queue waits up to "
                + "\(Int(Limits.mergeableUnknown / 60)) minutes for it.")
        }
        if let checks = candidate.checks {
            let verdict = judge(checks, required: settings.requiredChecks)
            if !verdict.failed.isEmpty || !verdict.failedStatuses.isEmpty {
                item.notes.append("A required check failed on this head: the queue reruns it once if it can, and stops "
                    + "if it fails again.")
            }
            if !verdict.notGreen.isEmpty {
                item.warnings.append("\(verdict.notGreen.joined(separator: ", ")): only a new run can turn it green, so "
                    + "the queue will stop on it.")
            }
            if !verdict.otherFailures.isEmpty {
                item.warnings.append("Red, though not required: \(verdict.otherFailures.joined(separator: ", ")). The "
                    + "queue never merges with a check red.")
            }
        }
        if let details = candidate.details {
            if details.changesWorkflows {
                item.warnings.append("It changes .github/workflows/: its checks ran its own version of the workflows.")
            } else if details.hasMoreFiles {
                item.warnings.append("It changes more than \(PullRequestDetails.maxFiles) files: Nirux didn’t check them "
                    + "all for .github/workflows/.")
            }
        } else {
            item.warnings.append("Nirux couldn’t read the files it changes"
                + (candidate.detailsError.map { " (\($0))" } ?? "") + ": check .github/workflows/ yourself.")
        }
        return .joins(item)
    }

    /// Why the queue would stop on this pull request at once.
    static func exclusionReason(_ pullRequest: PullRequestSnapshot, settings: BoardConfig.QueueSettings) -> String? {
        switch openExclusion(state: pullRequest.state, isDraft: pullRequest.isDraft, baseRefName: pullRequest.baseRefName,
                             mergeable: pullRequest.mergeable, baseBranch: settings.baseBranch) {
        case .notOpen(let state)?: return "It is \(state)."
        case .draft?: return "It is a draft."
        case .otherBase(let base)?: return "It targets \(base), not \(settings.baseBranch)."
        case .conflict?: return "It conflicts with \(settings.baseBranch): resolve that first."
        case nil: break
        }
        if pullRequest.headRepository != settings.gitHubRepository {
            return "It comes from a fork: the queue only merges branches of \(settings.repository)."
        }
        if pullRequest.hasAutoMerge {
            return "It is set to auto-merge: disable that first (gh pr merge \(pullRequest.number) --disable-auto)."
        }
        if pullRequest.isInMergeQueue { return "It is in GitHub’s merge queue: remove it from there first." }
        return nil
    }

    /// What keeps a pull request out that the board knows too, from its
    /// `gh pr list` row: the board's Queue column and the sheet share it.
    enum OpenExclusion: Equatable, Sendable {
        /// "merged", "closed".
        case notOpen(String)
        case draft
        case otherBase(String)
        case conflict
    }

    static func openExclusion(
        state: String, isDraft: Bool, baseRefName: String?, mergeable: String?, baseBranch: String?
    ) -> OpenExclusion? {
        if state.uppercased() != "OPEN" { return .notOpen(state.lowercased()) }
        if isDraft { return .draft }
        if let baseRefName, let baseBranch, baseRefName != baseBranch { return .otherBase(baseRefName) }
        if mergeable?.uppercased() == "CONFLICTING" { return .conflict }
        return nil
    }

    private static func localProblem(_ worktree: LocalWorktree) -> String? {
        let path = worktree.path.abbreviatedPath(maxComponents: 2)
        switch worktree.problem {
        case nil: return nil
        case .trackedChanges?: return "Tracked files changed in \(path): commit or discard them first."
        case .unpushed?: return "Commits not on GitHub in \(path): push them first."
        case .unreadable(let reason)?: return "\(path) can’t be checked: \(reason)."
        }
    }

    /// "nightlies" for "nightly", "deploys" for "deploy".
    static func plural(_ word: String) -> String {
        guard word.hasSuffix("y"), let before = word.dropLast().last, !"aeiou".contains(before) else { return word + "s" }
        return word.dropLast() + "ies"
    }

    /// Each required check on the head: "test ✓", "test ✗", "test ●",
    /// "test not started", "test skipped".
    static func checksText(_ checks: CommitChecks, required: [String]) -> String {
        required.map { name in
            let verdict = judge(checks, required: [name])
            if verdict.allRequiredGreen { return "\(name) ✓" }
            if !verdict.failed.isEmpty || !verdict.failedStatuses.isEmpty { return "\(name) ✗" }
            if let notGreen = verdict.notGreen.first { return notGreen }
            if verdict.pending.contains("\(name) (not started)") { return "\(name) not started" }
            return "\(name) ●"
        }.joined(separator: " · ")
    }
}
