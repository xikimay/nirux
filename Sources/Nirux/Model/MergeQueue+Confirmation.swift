import Foundation

// MARK: - The confirmation sheet (docs/design/project-board.md, section 4)

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
            /// The review passes the Board asks for that no task recorded on
            /// its head branch, by name: "Code review". None where no task
            /// is on that branch here, as the Board's Reviews station has
            /// nothing to say then either.
            var missingReviews: [String] = []

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
        var baseRuns: [GitHub.WorkflowRun]?
        /// In the order the next Start proposes.
        var candidates: [Candidate] = []

        func leadStartRefusal(
            confirmation: Confirmation, numbers: [Int], cadence: Cadence, allowWithoutLocalReview: Bool = false
        ) -> String? {
            if isDryRun { return "Dry runs need your confirmation." }
            if let exclusion = confirmation.excluded.first { return "#\(exclusion.number): \(exclusion.reason)" }
            if let reason = confirmation.refusals.first ?? confirmation.warnings.first { return reason }
            guard rateLimit != nil, baseMergeQueue == false,
                  confirmation.entries.map(\.number) == numbers, candidates.map(\.number) == numbers else {
                return "The queue preflight was incomplete."
            }
            if let workflow = settings.postMergeWorkflow {
                guard let last = baseRuns?.first(where: \.isCompleted) else {
                    return "No completed run of \(workflow) on \(settings.baseBranch) was found."
                }
                guard GitHub.isSucceededRun(last.conclusion) else {
                    return "The last completed run of \(workflow) on \(settings.baseBranch) didn’t succeed."
                }
            }
            for (item, candidate) in zip(confirmation.items, candidates) {
                let itemWarnings = allowWithoutLocalReview ? item.otherWarnings : item.warnings
                if let warning = itemWarnings.first { return "#\(candidate.number): \(warning)" }
                guard case .some(.some) = candidate.comparison else {
                    return "GitHub couldn’t compare #\(candidate.number) with \(settings.baseBranch)."
                }
            }
            if let reason = confirmation.refusal(for: cadence) { return reason }
            if cadence == .expressDisjoint { return nil }
            return MergeQueue.strictCandidateRefusal(for: candidates, settings: settings, requireDisjoint: false)
        }
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
            /// Missing local review passes on its branch ("No code review yet…"),
            /// kept separate so Lead auto-start can opt out of it without
            /// suppressing any other warning.
            var missingReviewWarning: String?
            /// Warnings other than missing local review passes.
            var otherWarnings: [String] = []
            /// What may stop the queue, or deserves a look.
            var warnings: [String] { (missingReviewWarning.map { [$0] } ?? []) + otherWarnings }
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
        /// Top of the sheet: the base may be broken.
        let warnings: [String]
        /// What the first merge waits for: a run going on the base. Said, never
        /// a reason to refuse.
        var waits: [String] = []
        /// Why Start is refused.
        let refusals: [String]

        let expressRefusal: String?
        /// A train only takes green pull requests: why not, when one is red.
        let trainRefusal: String?
        private(set) var cadence: Cadence = .standard

        var offeredCadences: [Cadence] {
            Cadence.allCases.filter { Self.unavailability(of: $0, settings: settings) == nil }
        }

        func refusal(for cadence: Cadence) -> String? {
            if let reason = Self.unavailability(of: cadence, settings: settings) { return reason }
            switch cadence {
            case .expressDisjoint: return expressRefusal
            case .train: return trainRefusal
            case .standard, .batchPostMerge: return nil
            }
        }

        /// Why these settings don't offer a cadence.
        static func unavailability(of cadence: Cadence, settings: BoardConfig.QueueSettings) -> String? {
            switch cadence {
            case .batchPostMerge where settings.postMergeWorkflow == nil:
                "Batch post-merge needs a configured post-merge workflow."
            case .train where settings.mergeMethod != .merge:
                "A train needs the merge method “merge”: it lands each pull request’s own commits, which a squash would replace."
            default:
                nil
            }
        }

        /// Why a cadence can't be chosen: "Train unavailable. …".
        var unavailableNotes: [String] {
            [Cadence.expressDisjoint, .train].compactMap { cadence in refusal(for: cadence).map { "\(cadence.title) unavailable. " + $0 } }
        }

        mutating func select(_ cadence: Cadence) {
            guard refusal(for: cadence) == nil else { return }
            self.cadence = cadence
        }

        var canStart: Bool { refusals.isEmpty && !items.isEmpty }
        var entries: [ConfirmedEntry] { items.map(\.entry) }

        /// Moves an item up (-1) or down (+1): the user's order, never
        /// Nirux's.
        mutating func move(_ index: Int, by offset: Int) {
            let target = index + offset
            guard items.indices.contains(index), items.indices.contains(target) else { return }
            items.swapAt(index, target)
        }

        var summary: String {
            let count = items.count
            if cadence == .train {
                let lands = "land \(count) pull request\(count == 1 ? "" : "s") into \(settings.baseBranch) in one train: one run "
                    + "of the required checks" + (settings.postMergeWorkflow.map { ", then \($0) once" } ?? "")
                return isDryRun ? "A real queue would \(lands). This dry run changes nothing on GitHub." : "The queue will \(lands)."
            }
            let merges = "\(count) merge\(count == 1 ? "" : "s")"
            guard let workflow = settings.postMergeWorkflow else {
                return isDryRun ? "A real queue would make \(merges) into \(settings.baseBranch). This dry run makes none."
                    : "This queue makes \(merges) into \(settings.baseBranch), one right after the other."
            }
            if cadence != .standard {
                let final = "verify \(workflow) once, on the final merge of \(count) pull request\(count == 1 ? "" : "s")"
                return isDryRun ? "A real queue would \(final). This dry run publishes nothing." : "The queue will \(final)."
            }
            let label = GitHub.workflowLabel(workflow)
            if label.lowercased().contains("nightly") {
                let nightlies = "\(count) \(count == 1 ? label : MergeQueue.plural(label))"
                return isDryRun ? "A real queue would publish \(nightlies), one after each merge. This dry run publishes none."
                    : "This queue publishes \(nightlies): \(workflow) runs after each of its \(merges)."
            }
            let times = "\(count) time\(count == 1 ? "" : "s")"
            return isDryRun ? "A real queue would run \(workflow) \(times), after each merge. This dry run merges nothing, so it runs none."
                : "This queue runs \(workflow) \(times): after each of its \(merges)."
        }

        /// What will happen, line by line (section 4).
        var plan: [String] {
            let base = settings.baseBranch
            let stops = "It stops at the first problem. Stop is in the board and in the status bar; a call already "
                + "sent to GitHub finishes."
            if cadence == .train { return trainPlan + [stops] }
            let method = settings.mergeMethod == .squash ? "Squash and merge it" : "Merge it with a merge commit"
            var lines = ["In this order, for each pull request:"]
            if cadence == .expressDisjoint {
                lines += [
                    "• Keep its confirmed head, even if it is behind \(base).",
                    "• Require green checks (\(settings.requiredChecks.joined(separator: ", "))). Stop if its head changes, "
                        + "it is no longer mergeable, or any check is red.",
                    "• \(method), pinned to the confirmed head (gh pr merge --\(settings.mergeMethod.rawValue) --match-head-commit)."
                ]
            } else {
                lines += [
                    "• If its branch is behind \(base), merge \(base) into it on GitHub (never a rebase or a force push), "
                        + "at most \(Limits.maxUpdates) times.",
                    "• Wait for the required checks on its head: \(settings.requiredChecks.joined(separator: ", ")) "
                        + "(up to \(settings.checksTimeoutMinutes) minutes). A failed one is rerun once; a second failure stops "
                        + "the queue. One that ran only as “<name> (selected)” gets the label \(fullRunLabel), which asks for "
                        + "its full run.",
                    "• \(method), pinned to the head shown here, or to the queue’s own updates of it "
                        + "(gh pr merge --\(settings.mergeMethod.rawValue) --match-head-commit).",
                ]
            }
            if let workflow = settings.postMergeWorkflow {
                if cadence == .standard {
                    lines.append("• Wait for \(workflow) on \(base) (up to \(settings.postMergeTimeoutMinutes) minutes), "
                        + "then go on to the next one.")
                } else {
                    lines.append("• After the final merge, wait up to \(settings.postMergeTimeoutMinutes) minutes for \(workflow).")
                }
            } else {
                lines.append("• Go on to the next one right away: no post-merge workflow.")
            }
            lines.append(stops)
            return lines
        }

        private var trainPlan: [String] {
            let base = settings.baseBranch
            let checks = "\(settings.requiredChecks.joined(separator: ", ")) (up to \(settings.checksTimeoutMinutes) minutes)"
            return [
                "In one train, in this order:",
                "• Check each pull request: open, at the head shown here, none of its checks red. Its required checks aren’t "
                    + "awaited: the train runs them.",
                "• On GitHub, start a branch nirux-train/… at the tip of \(base) and merge each head into it. The heads stay as "
                    + "shown: no branch update, rebase or force push.",
                "• Open a pull request of the train into \(base) and wait for its required checks: \(checks).",
                "• Merge it with a merge commit, pinned to its head (gh pr merge --merge --match-head-commit), if \(base) hasn’t "
                    + "moved and each pull request is still at its head. Each pull request then reads merged; the queue checks it.",
                "• A red train closes, and its pull requests ride again in two halves, one train at a time. A pull request alone "
                    + "on a red train leaves it; the others still ride.",
                settings.postMergeWorkflow.map { "• Then wait up to \(settings.postMergeTimeoutMinutes) minutes for \($0), after each train that lands." }
                    ?? "• No post-merge workflow: done once they read merged."
            ]
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
        var joining: [ConfirmationReading.Candidate] = []
        if reading.setupError == nil {
            for candidate in reading.candidates {
                switch confirmationItem(candidate, settings: settings) {
                case .joins(let item):
                    items.append(item)
                    joining.append(candidate)
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
            waits: reading.setupError == nil ? baseWaits(reading.baseRuns, settings: settings) : [],
            refusals: refusals,
            expressRefusal: strictCandidateRefusal(for: joining, settings: settings, requireDisjoint: true),
            trainRefusal: trainCandidateRefusal(for: joining, settings: settings)
        )
    }

    /// The first pull request a red check keeps out of a train. Checks not
    /// read yet don't refuse it: the train reads them again. Required ones
    /// missing or running don't either: the train runs them.
    static func trainCandidateRefusal(for candidates: [ConfirmationReading.Candidate], settings: BoardConfig.QueueSettings) -> String? {
        for candidate in candidates {
            guard let checks = candidate.checks else { continue }
            if let first = judge(checks, required: []).otherFailures.first {
                return "A train only takes pull requests whose checks are green: \(first) isn’t green on #\(candidate.number)."
            }
        }
        return nil
    }

    /// The last post-merge run on the base failed: the base may already be
    /// broken.
    private static func baseWarnings(_ runs: [GitHub.WorkflowRun]?, settings: BoardConfig.QueueSettings) -> [String] {
        guard let workflow = settings.postMergeWorkflow, let last = runs?.first(where: \.isCompleted),
              GitHub.isFailedRun(last.conclusion)
        else { return [] }
        return ["The last \(GitHub.workflowLabel(workflow)) on \(settings.baseBranch) failed (\(Engine.short(last.headSha))"
            + (last.title.map { ", “\($0)”" } ?? "") + "): the base may already be broken."]
    }

    /// A post-merge run still going on the base: the first merge waits for it.
    private static func baseWaits(_ runs: [GitHub.WorkflowRun]?, settings: BoardConfig.QueueSettings) -> [String] {
        guard let workflow = settings.postMergeWorkflow, runs?.contains(where: { !$0.isCompleted }) == true else { return [] }
        return ["A \(GitHub.workflowLabel(workflow)) is running on \(settings.baseBranch): the first merge waits for it, "
            + "and the queue stops if it fails."]
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
        if let problem = MergeQueue.ConfirmedEntry.problem(in: [entry]) { return leftOut(problem) }
        if case .some(nil) = candidate.comparison {
            return leftOut("GitHub can’t compare its head \(Engine.short(pullRequest.headOid)) with \(settings.baseBranch).")
        }
        guard let local = candidate.local else { return leftOut("Its worktrees on this Mac couldn’t be checked.") }
        if let reason = local.worktrees.lazy.compactMap(localProblem).first { return leftOut(reason) }
        // What the Board's Reviews station says of it, the sheet says too: a click on its Merge station lists it for Start.
        let unreviewed: String? = candidate.missingReviews.isEmpty ? nil
            : "No \(spoken(candidate.missingReviews.map { $0.lowercased() })) yet: Nirux saw none run on its branch."

        var item = Confirmation.Item(
            entry: entry,
            title: title,
            url: pullRequest.url,
            checks: candidate.checks.map { checksText($0, required: settings.requiredChecks) }
                ?? "checks unknown" + (candidate.checksError.map { ": \($0)" } ?? ""),
            missingReviewWarning: unreviewed
        )
        if case .some(.some(let comparison)) = candidate.comparison, comparison.behindBy > 0 {
            item.notes.append("Behind \(settings.baseBranch) by \(comparison.behindBy) "
                + "commit\(comparison.behindBy == 1 ? "" : "s").")
        } else if candidate.comparison == nil {
            item.notes.append("Nirux couldn’t tell whether it is behind \(settings.baseBranch)"
                + (candidate.compareError.map { " (\($0))" } ?? "") + ".")
        }
        if !local.busyAgents.isEmpty {
            item.notes.append(local.busyAgents.joined(separator: "; ") + ": the queue waits up to "
                + "\(Int(Limits.agentWait / 60)) minutes for it to be back at its prompt before merging, then leaves it "
                + "for the next queue (a train goes on without it).")
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
                item.otherWarnings.append("\(verdict.notGreen.joined(separator: ", ")): only a new run can turn it green, so "
                    + "the queue will stop on it.")
            }
            if !verdict.otherFailures.isEmpty {
                item.otherWarnings.append("Red, though not required: \(verdict.otherFailures.joined(separator: ", ")). The "
                    + "queue never merges with a check red.")
            }
        }
        if let details = candidate.details {
            if details.changesWorkflows {
                item.otherWarnings.append("It changes .github/workflows/: its checks ran its own version of the workflows.")
            } else if details.hasMoreFiles {
                item.otherWarnings.append("It changes more than \(PullRequestDetails.maxFiles) files: Nirux didn’t check them "
                    + "all for .github/workflows/.")
            }
        } else {
            item.otherWarnings.append("Nirux couldn’t read the files it changes"
                + (candidate.detailsError.map { " (\($0))" } ?? "") + ": check .github/workflows/ yourself.")
        }
        return .joins(item)
    }

    /// The `required` review passes that no task recorded on `branch`
    /// (`ReviewRun.counts(onBranch:)`, the Board's Reviews station's rule),
    /// in whatever task they ran, by name in the badges' order; none where
    /// no task is on that branch here.
    static func missingReviews(branch: String, tasks: [ReviewTask], required: Set<ReviewPass>) -> [String] {
        guard tasks.contains(where: { $0.branch == branch }) else { return [] }
        let ran = Set(tasks.flatMap { $0.runs.filter { $0.value.counts(onBranch: branch) }.keys })
        return ReviewPass.allCases.filter { required.contains($0) && !ran.contains($0) }.map(\.displayName)
    }

    /// "a", "a or b", "a, b or c".
    static func spoken(_ names: [String]) -> String {
        names.count < 3 ? names.joined(separator: " or ") : names.dropLast().joined(separator: ", ") + " or " + (names.last ?? "")
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
    /// `gh pr list` row: the Board's Merge station and the sheet share it.
    enum OpenExclusion: Equatable, Sendable {
        /// "merged", "closed".
        case notOpen(String)
        case draft
        case otherBase(String)
        case conflict
    }

    static func openExclusion(
        state: GitHub.PullRequestState, isDraft: Bool, baseRefName: String?, mergeable: String?, baseBranch: String?
    ) -> OpenExclusion? {
        if state != .open { return .notOpen(state.word) }
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
