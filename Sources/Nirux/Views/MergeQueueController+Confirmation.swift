import Foundation

// MARK: - What the confirmation sheet reads (docs/project-board.md, section 4)

extension MergeQueueController {
    /// Pull requests read at once: a few, so a long list reads quickly
    /// without a burst of gh processes. Each next one starts as soon as one
    /// is done.
    nonisolated static let confirmationReadWidth = 4

    /// Reads what the sheet shows, with this queue's client: the queue's
    /// own setup reads, then each pull request, off the main thread; then,
    /// on it, the agents busy in their worktrees. Nothing is changed.
    /// Cancelling the returned token (the sheet closed) stops the reads
    /// still to come, and `completion` isn't called.
    @discardableResult
    func readConfirmation(
        settings: BoardConfig.QueueSettings,
        numbers: [Int],
        then completion: @escaping @MainActor @Sendable (MergeQueue.ConfirmationReading) -> Void
    ) -> MergeQueueReadCancellation {
        let client = self.client
        let folders = local.folders()
        let inspect = local.inspect
        let isDryRun = self.isDryRun
        let cancellation = MergeQueueReadCancellation()
        MergeQueueDriver.runOffMain({
            Self.fetchConfirmation(
                settings: settings, numbers: numbers, isDryRun: isDryRun, client: client, folders: folders, inspect: inspect,
                cancellation: cancellation
            )
        }, then: { [weak self] fetched in
            guard let self, !cancellation.isCancelled else { return }
            var reading = fetched.reading
            for index in reading.candidates.indices {
                guard let inspection = fetched.inspections[reading.candidates[index].number] else { continue }
                let worktrees = inspection.worktrees.map(\.path)
                reading.candidates[index].local = MergeQueue.LocalState(
                    busyAgents: worktrees.isEmpty ? [] : self.local.busyAgents(worktrees, inspection.allWorktreePaths),
                    worktrees: inspection.worktrees
                )
            }
            completion(reading)
        })
        return cancellation
    }

    struct ConfirmationFetch: Sendable {
        var reading: MergeQueue.ConfirmationReading
        /// By pull request: its worktrees, whose agents are read on the main thread.
        var inspections: [Int: MergeQueue.LocalInspection] = [:]
    }

    /// The setup reads first (a signed-out gh stops everything there), then
    /// each pull request: its snapshot, and for one that could join, its
    /// details, checks, comparison with the base and worktrees.
    nonisolated static func fetchConfirmation(
        settings: BoardConfig.QueueSettings,
        numbers: [Int],
        isDryRun: Bool,
        client: any MergeQueueGitHub,
        folders: [String],
        inspect: MergeQueueLocalAccess.Inspect,
        cancellation: MergeQueueReadCancellation = MergeQueueReadCancellation()
    ) -> ConfirmationFetch {
        var fetch = ConfirmationFetch(reading: MergeQueue.ConfirmationReading(settings: settings, isDryRun: isDryRun))
        var setup: [MergeQueue.Read] = [.auth, .rateLimit, .baseMergeQueue]
        if settings.postMergeWorkflow != nil { setup.append(.baseRuns) }
        for read in setup {
            guard !cancellation.isCancelled else { return fetch }
            switch client.read(read, settings: settings) {
            case .success(.signedIn) where read == .auth: break
            case .success(.rateLimit(let limit)) where read == .rateLimit: fetch.reading.rateLimit = limit
            case .success(.baseMergeQueue(let required)) where read == .baseMergeQueue:
                fetch.reading.baseMergeQueue = required
            case .success(.runs(let runs)) where read == .baseRuns: fetch.reading.baseRuns = runs
            case .success:
                // An answer Nirux didn't ask for: nothing is judged on it.
                fetch.reading.setupError = "GitHub’s answers were incomplete. Start again to retry."
                return fetch
            case .failure(let error):
                fetch.reading.setupError = setupMessage(error)
                return fetch
            }
        }
        let results = ConfirmationResults(count: numbers.count)
        // A sliding window: a slow pull request holds up no other.
        let window = DispatchSemaphore(value: confirmationReadWidth)
        DispatchQueue.concurrentPerform(iterations: numbers.count) { index in
            window.wait()
            defer { window.signal() }
            guard !cancellation.isCancelled else { return }
            let read = readCandidate(
                numbers[index], settings: settings, client: client, folders: folders, inspect: inspect,
                cancellation: cancellation
            )
            results.set(read, at: index)
        }
        for (candidate, inspection) in results.values {
            fetch.reading.candidates.append(candidate)
            if let inspection { fetch.inspections[candidate.number] = inspection }
        }
        return fetch
    }

    private nonisolated static func readCandidate(
        _ number: Int,
        settings: BoardConfig.QueueSettings,
        client: any MergeQueueGitHub,
        folders: [String],
        inspect: MergeQueueLocalAccess.Inspect,
        cancellation: MergeQueueReadCancellation
    ) -> (MergeQueue.ConfirmationReading.Candidate, MergeQueue.LocalInspection?) {
        var candidate = MergeQueue.ConfirmationReading.Candidate(number: number)
        switch client.read(.pullRequest(number), settings: settings) {
        case .success(.pullRequest(let pullRequest)): candidate.pullRequest = pullRequest
        case .success: candidate.error = "unexpected answer"
        case .failure(let error): candidate.error = GitHubCLIQueueClient.message(of: error)
        }
        // Unread (a rate limit, say): no more calls for it.
        guard candidate.pullRequest != nil, !cancellation.isCancelled else { return (candidate, nil) }
        switch client.read(.pullRequestDetails(number), settings: settings) {
        case .success(.pullRequestDetails(let details)): candidate.details = details
        case .success: candidate.detailsError = "unexpected answer"
        case .failure(let error): candidate.detailsError = GitHubCLIQueueClient.message(of: error)
        }
        // A pull request left out anyway needs nothing more.
        guard !cancellation.isCancelled, let pullRequest = candidate.pullRequest,
              MergeQueue.exclusionReason(pullRequest, settings: settings) == nil,
              MergeQueueController.problem(with: [MergeQueue.ConfirmedEntry(
                number: number, head: pullRequest.headOid, branch: pullRequest.headRefName
              )]) == nil
        else { return (candidate, nil) }
        let head = pullRequest.headOid
        switch client.read(.checks(head), settings: settings) {
        case .success(.checks(let checks)): candidate.checks = checks
        case .success: candidate.checksError = "unexpected answer"
        case .failure(let error): candidate.checksError = GitHubCLIQueueClient.message(of: error)
        }
        switch client.read(.compare(base: settings.baseBranch, head: head), settings: settings) {
        case .success(.comparison(let comparison)): candidate.comparison = .some(comparison)
        case .success: candidate.compareError = "unexpected answer"
        case .failure(let error): candidate.compareError = GitHubCLIQueueClient.message(of: error)
        }
        switch inspect(folders, pullRequest.headRefName, head, settings, client) {
        case .success(let inspection):
            return (candidate, inspection)
        case .failure(let error):
            candidate.error = "its worktrees couldn’t be checked: \(GitHubCLIQueueClient.message(of: error))"
            return (candidate, nil)
        }
    }

    /// Why the sheet can't read GitHub for the queue.
    nonisolated static func setupMessage(_ error: MergeQueue.ClientError) -> String {
        switch error {
        case .ghMissing:
            return "The GitHub CLI (gh) isn’t installed: install it, sign in with gh auth login, then Start again."
        case .notSignedIn(let message):
            return "gh isn’t signed in to github.com (\(message)): run gh auth login in a terminal, then Start again."
        case .rateLimited, .secondaryRateLimit:
            return "GitHub’s rate limit is reached: Start again later."
        case .refused, .noAnswer, .unreadable:
            return "Couldn’t read GitHub: \(GitHubCLIQueueClient.message(of: error)). Start again to retry."
        }
    }
}

/// Set when the sheet closes: the reads still to come don't run.
final class MergeQueueReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }
}

/// The reads of pull requests read together, by position.
private final class ConfirmationResults: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [(MergeQueue.ConfirmationReading.Candidate, MergeQueue.LocalInspection?)?]

    init(count: Int) {
        slots = Array(repeating: nil, count: count)
    }

    func set(_ value: (MergeQueue.ConfirmationReading.Candidate, MergeQueue.LocalInspection?), at index: Int) {
        lock.withLock { slots[index] = value }
    }

    var values: [(MergeQueue.ConfirmationReading.Candidate, MergeQueue.LocalInspection?)] {
        lock.withLock { slots.compactMap { $0 } }
    }
}
