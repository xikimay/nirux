import AppKit

// MARK: - Each task's Board station, once a pass (docs/design/glass-interface.md, phase 5)

extension NiruxShellView {
    /// Each task's station, every space's, read once a sidebar pass before
    /// anything draws: the rows, the rail, the command bar, the catch-up
    /// card, ⌘P and the Board's lines all show `taskStations`. The Lead and
    /// a task without a repository have none.
    func refreshTaskStations() {
        let spaces = Set(workspaces.map(\.profileID))
        let entries = Dictionary(uniqueKeysWithValues: spaces.map { ($0, boardEntries(of: $0)) })
        var queues: [MergeQueueKey: ProjectBoard.QueueState] = [:]
        var stations: [String: BoardStages.Station] = [:]
        for workspace in workspaces where !workspace.isClosing && !workspace.isLead && workspace.gitContext != nil {
            let pullRequest = workspace.prInfo
            let repository = pullRequest.flatMap(Self.repository(of:))
            let queue = repository.flatMap { repository -> ProjectBoard.QueueState? in
                let key = MergeQueueKey(projectID: workspace.profileID, repository: repository)
                if let state = queues[key] { return state }
                // Only a queue the app already holds: making one reads its file.
                guard let controller = mergeQueues[key] else { return nil }
                queues[key] = queueState(of: controller)
                return queues[key]
            }
            let spaceEntries = entries[workspace.profileID] ?? nil
            let required = repository.flatMap { repository in spaceEntries.flatMap { Self.requiredChecks(of: repository, in: $0) } }
            stations[workspace.id] = Self.station(
                pullRequest: pullRequest, reviews: workspace.reviewBadges, reviewsInFlight: Set(workspace.reviewsRunning.map(\.pass)),
                branch: workspace.gitContext?.branchName, required: required, queue: queue
            )
        }
        taskStations = stations
    }

    /// A task's station through the Board's rule (`BoardStages.station(of:rules:)`):
    /// - its pull request as its row read it; a closed one is none, as on
    ///   the Board, which reads open and merged ones, and one the queue
    ///   merged is merged;
    /// - the review runs recorded on its branch, and the passes running;
    /// - the checks its space requires (`required`); nil when no config names
    ///   its repository: every check counts, and none reported yet is still
    ///   to come;
    /// - the merge queue's step.
    static func station(
        pullRequest: PRInfo?, reviews: ReviewBadges?, reviewsInFlight: Set<ReviewPass>, branch: String?, required: [String]?,
        queue: ProjectBoard.QueueState?
    ) -> BoardStages.Station {
        var facts = BoardStages.Facts(id: "", title: "")
        facts.reviews = reviews.map { ReviewBadges(runs: $0.runs, head: $0.head, branch: branch) }
        facts.reviewsInFlight = reviewsInFlight
        if let pr = pullRequest, pr.state != "CLOSED" {
            let mergedByQueue = queue?.entries.contains { $0.number == pr.number && $0.mergeCommit != nil } ?? false
            var pullRequest = BoardStages.PullRequest(number: pr.number, base: "")
            pullRequest.isMerged = pr.state == "MERGED" || mergedByQueue
            pullRequest.isDraft = pr.isDraft
            let latest = ProjectBoard.latest(pr.checks)
            pullRequest.checks = pullRequest.isMerged ? .passed
                : required == nil && latest.isEmpty ? .pending(since: nil)
                : BoardStages.checks(latest: latest, required: required ?? [])
            facts.pullRequest = pullRequest
            facts.queue = BoardStages.queue(of: pr.number, head: nil, in: queue)
        }
        return BoardStages.station(of: facts, rules: BoardStages.Rules())
    }

    /// `spaceID`'s board.json entries; nil while they are read, once, off
    /// the main thread (its Board and Board Settings keep them current).
    func boardEntries(of spaceID: String) -> [BoardConfigStore.Entry]? {
        if let entries = boardEntriesBySpace[spaceID] { return entries }
        guard let store = BoardConfigStore(spaceID: spaceID) else { return [] }
        guard boardEntriesReading.insert(spaceID).inserted else { return nil }
        ProjectBoardController.readOffMain({ store.load() }, then: { [weak self] loaded in
            guard let self else { return }
            self.boardEntriesReading.remove(spaceID)
            // Its Board may have read the file meanwhile.
            if self.boardEntriesBySpace[spaceID] == nil {
                self.boardEntriesBySpace[spaceID] = loaded.status == .unreadable ? [] : loaded.entries
            }
        })
        return nil
    }

    /// The checks `repository`'s pull requests must pass: the config naming
    /// it, an anchor's before schema 1's (`BoardSections` gives the latter
    /// only to an anchor without its own). Nil when none names it.
    static func requiredChecks(of repository: GitHubRepository, in entries: [BoardConfigStore.Entry]) -> [String]? {
        let naming = entries.filter { $0.config.gitHubRepository == repository }
        return (naming.first { $0.slot != .legacy } ?? naming.first)?.config.requiredChecks
    }

    /// The repository a pull request's URL names, on github.com.
    static func repository(of pullRequest: PRInfo) -> GitHubRepository? {
        guard let path = URL(string: pullRequest.url)?.pathComponents, path.count >= 3 else { return nil }
        return GitHubRepository(ownerAndName: "\(path[1])/\(path[2])")
    }
}
