import Foundation

// MARK: - A section's facts, from what the app holds (docs/design/board-stages.md, section 6)

extension BoardStages {
    /// What a task's sidebar row last read, on the main actor: the Board
    /// says the same thing of the task.
    struct TaskReading: Equatable, Sendable {
        var activity: Activity = .idle
        var isParked = false
        var terminalStatusKnown = true
        /// Each review pass's latest run, against the HEAD the sidebar reads.
        var reviews: ReviewBadges?
        var reviewsInFlight: Set<ReviewPass> = []
        var summary: String?
        var statusLine: String?
        var nextStep: String?
        var blocker: String?
        var lastActivityAt: TimeInterval?
        /// The worktree its git facts (below, and the reviews' HEAD) were
        /// read in, comparable like the rows' paths: the focused column's,
        /// which may be another one than the task's. Nil when unknown.
        var gitRoot: String?
        /// What GitHub still asks of its pull request.
        var reviewRequest: ReviewRequest?
        var flakyReason: String?
        var cleanUp: CleanUp?
        /// How its stopped agent can go on, as the sidebar offers it.
        var resume: Resume?
        /// The pull request of this repository its own detection says
        /// merged, at the HEAD it merged at: known before the Board's
        /// merged list is read again, and for one that list doesn't reach.
        var mergedPullRequest: Int?
        /// The repository that pull request is in, from its address: gh
        /// may find one in a fork, whose number means nothing here.
        var mergedPullRequestRepository: GitHubRepository?
    }

    /// One repository as today's Board holds it, or the workspaces in none.
    struct RepositoryReading: Equatable {
        var id: String
        var rows: [ProjectBoard.Row]
        /// False for a section without a repository on GitHub, until its
        /// open pull requests were read once, and for the workspaces in
        /// none: nothing says where their work stands, so their lines
        /// have no rail.
        var readsPullRequests = true
        var gitHubStatus: GitHubStatus = .current
        var requiredChecks: [String] = []
        var baseBranch: String?
        var queue: ProjectBoard.QueueState?
        /// The merged pull requests read, with their title and merge date.
        var merged: [ProjectBoard.PullRequest] = []
        /// Each worktree's HEAD as last listed, by its path.
        var heads: [String: String] = [:]
        /// The worktrees and folders a clean-up of which runs, by path.
        var cleaningUp: Set<String> = []
        /// The GitHub repository its pull requests are read from; nil
        /// without one.
        var gitHub: GitHubRepository?
        var checkTimeout: CheckTimeout?
    }

    /// The facts of a section's lines.
    /// - `tasks` are the space's tasks by workspace id, in the sidebar's
    ///   order, the Lead left out: it is no task. Each one in a row of
    ///   this repository is a line, in that order. Two tasks sharing a
    ///   worktree are two lines, on the same pull request.
    /// - `readings` is what the sidebar last read of each. A task it
    ///   hasn't read yet is a line all the same, at rest.
    /// - An open pull request no task's line shows is a pull request
    ///   without a task, after the tasks, in the rows' order, once.
    /// - A main checkout or another worktree with neither is no line.
    /// - A task in another repository's worktree is no line: it is under
    ///   "Other workspaces" (`otherWorkspaces`). One in no repository (a
    ///   folder) is a line without a rail: those rows are the "No
    ///   repository" section's.
    /// `parents` gives each sub-task's workspace id the id of the one it
    /// is listed under in the sidebar (`WorkspaceStore.activeParents`).
    /// `lead` is the space's Lead's workspace id: its worktree, when it is
    /// a linked one, is listed first under "Other worktrees", with Focus.
    static func sectionFacts(
        _ repository: RepositoryReading, tasks: [String], readings: [String: TaskReading], parents: [String: String] = [:],
        lead: String? = nil, waiting: [WaitingTask] = []
    ) -> SectionFacts {
        var places: [String: (row: ProjectBoard.Row, workspace: ProjectBoard.WorkspaceRef)] = [:]
        for row in repository.rows where !isInOtherRepository(row) {
            for workspace in row.workspaces { places[workspace.id] = (row, workspace) }
        }
        // Merged, as GitHub's lists say; and with what the tasks know of
        // their own, none of them has a place in the next Start's list.
        var merged = MergedNumbers()
        merged.read = Set((repository.merged + repository.rows.compactMap(\.pullRequest)).filter { $0.state == .merged }.map(\.number))
        merged.known = merged.read
        for id in tasks {
            guard let row = places[id]?.row else { continue }
            if let number = mergedNumber(of: row, reading: readings[id] ?? TaskReading(), in: repository) { merged.known.insert(number) }
        }
        var lines: [Facts] = []
        var listed = Set<String>()
        for id in tasks {
            guard let place = places[id], listed.insert(id).inserted else { continue }
            lines.append(task(
                id, reading: readings[id] ?? TaskReading(), workspace: place.workspace, row: place.row, in: repository, merged: merged
            ))
        }
        var shown = Set(lines.compactMap(\.pullRequest?.number))
        for row in repository.rows {
            guard let pullRequest = row.pullRequest, pullRequest.isOpen, shown.insert(pullRequest.number).inserted else { continue }
            // Its title is text from GitHub: cleaned, on one line.
            var facts = Facts(id: "\(repository.id)#\(pullRequest.number)", title: text(pullRequest.title) ?? row.branch ?? "")
            facts.location = location(of: row)
            facts.hasTask = false
            facts.gitHubStatus = repository.gitHubStatus
            facts.folder = folder(of: row, in: repository)
            facts.queue = queue(of: row, pullRequest, in: repository, merged: merged.known)
            facts.pullRequest = self.pullRequest(pullRequest, stack: row.stack, in: repository, merged: merged.read)
            lines.append(facts)
        }
        return SectionFacts(
            id: repository.id, lines: lines,
            parents: parents.filter { listed.contains($0.key) && listed.contains($0.value) },
            // One whose merge date gh didn't give isn't in "Merged today":
            // nothing says it merged today.
            merged: repository.merged.compactMap { pullRequest in
                guard pullRequest.state == .merged, let mergedAt = pullRequest.mergedAt else { return nil }
                return MergedFacts(number: pullRequest.number, title: pullRequest.title, mergedAt: mergedAt.timeIntervalSince1970)
            },
            otherWorktrees: (lead.map { lead in repository.rows.compactMap { leadWorktree($0, lead: lead, in: repository) } } ?? [])
                + repository.rows.compactMap { otherWorktree($0, in: repository) }
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
            knownMerged: merged.known, waiting: waiting
        )
    }

    /// The Lead's worktree when it is a linked one (the main checkout is
    /// the Lead's usual place, which the space header shows): "Lead · " and
    /// the worktree's name, its pull request (an open one is also a line
    /// without a task: the Lead is no task), with Focus and Clean Up…, as
    /// the table's row of the Lead offered them.
    private static func leadWorktree(_ row: ProjectBoard.Row, lead: String, in repository: RepositoryReading) -> OtherWorktree? {
        guard row.group != .main, row.group != .otherRepository, let path = row.worktreePath,
              row.workspaces.contains(where: { $0.id == lead })
        else { return nil }
        // A linked worktree: the clean-up may delete it. Its confirmation names the agents it would end, the Lead's too.
        let menu: [MenuItem] = [
            .focus(workspaceID: lead, columnID: column(of: lead, in: row)),
            .cleanUp(path: path, blocked: repository.cleaningUp.contains(path) ? CleanUp.runningReason : nil)
        ]
        return OtherWorktree(
            path: path, title: "Lead · \(row.worktreeName)",
            pullRequest: row.pullRequest.map { ProjectBoard.pullRequestText($0, baseBranch: repository.baseBranch) },
            url: row.pullRequest?.url, menu: menu
        )
    }

    /// A worktree of another repository with workspaces of the space: its
    /// tasks are "Other workspaces", no section's lines.
    private static func isInOtherRepository(_ row: ProjectBoard.Row) -> Bool {
        row.group == .otherRepository && row.worktreePath != nil
    }

    /// "Other workspaces": each worktree of another repository with
    /// workspaces of the space, until the Board has a section per
    /// repository of the space. Its folder, and Focus on the most urgent
    /// agent there, as the table's row did, titled by the workspace it
    /// focuses ("Docs +1"). A workspace in no repository is none of these:
    /// its line is under "No repository".
    static func otherWorkspaces(_ rows: [ProjectBoard.Row]) -> [OtherWorktree] {
        rows.compactMap { row in
            guard isInOtherRepository(row), let path = row.worktreePath, let first = row.workspaces.first else { return nil }
            let workspaceID = row.agent.state != .none ? row.agent.workspaceID ?? first.id : first.id
            let focused = row.workspaces.first { $0.id == workspaceID } ?? first
            let more = row.workspaces.count > 1 ? " +\(row.workspaces.count - 1)" : ""
            return OtherWorktree(
                path: path, title: focused.title + more, pullRequest: nil,
                menu: [.focus(workspaceID: focused.id, columnID: column(of: focused.id, in: row))]
            )
        }
    }

    /// The row's most urgent agent column, when it is that workspace's.
    private static func column(of workspaceID: String, in row: ProjectBoard.Row) -> UUID? {
        row.agent.state != .none && row.agent.workspaceID == workspaceID ? row.agent.columnID : nil
    }

    /// A worktree the table listed under "Other worktrees" (a linked one,
    /// with no workspace and no open pull request), with its buttons: Open,
    /// named as the table named it (its branch, or its folder), and Clean
    /// Up…, held back while one runs there.
    private static func otherWorktree(_ row: ProjectBoard.Row, in repository: RepositoryReading) -> OtherWorktree? {
        guard row.group == .otherWorktree, let path = row.worktreePath else { return nil }
        let folder = (path as NSString).lastPathComponent
        let title = row.worktreeName
        let menu: [MenuItem] = [
            .openWorktree(path: path, title: row.branch ?? folder),
            .cleanUp(path: path, blocked: repository.cleaningUp.contains(path) ? CleanUp.runningReason : nil)
        ]
        return OtherWorktree(
            path: path, title: title,
            pullRequest: row.pullRequest.map { ProjectBoard.pullRequestText($0, baseBranch: repository.baseBranch) },
            url: row.pullRequest?.url, menu: menu
        )
    }

    /// The section's merged pull requests, by number.
    private struct MergedNumbers {
        /// As GitHub's lists say: the merged list, a row's.
        var read = Set<Int>()
        /// Those, and the ones only a task's line knows merged.
        var known = Set<Int>()
    }

    // MARK: A task

    private static func task(
        _ id: String, reading: TaskReading, workspace: ProjectBoard.WorkspaceRef, row: ProjectBoard.Row,
        in repository: RepositoryReading, merged: MergedNumbers
    ) -> Facts {
        var facts = Facts(id: id, title: workspace.title)
        facts.location = location(of: row)
        // A workspace in no repository (a folder) has no rail: no pull
        // request is read there, and none of this one's is its own.
        facts.hasRepository = repository.readsPullRequests && row.group != .otherRepository
        facts.isArchived = workspace.isInactive
        facts.activity = reading.activity
        facts.isParked = reading.isParked
        facts.gitHubStatus = repository.gitHubStatus
        facts.reviewsInFlight = reading.reviewsInFlight
        facts.summary = reading.summary
        facts.statusLine = reading.statusLine
        facts.nextStep = reading.nextStep
        facts.blocker = reading.blocker
        facts.lastActivityAt = reading.lastActivityAt
        // What the sidebar read in another worktree (its focused column
        // is elsewhere) says nothing of this row's pull request, nor of
        // what its reviews are fresh on.
        let isAboutRow = reading.gitRoot == nil || reading.gitRoot == row.worktreePath
        // Its runs count when recorded on its branch, wherever they ran.
        facts.reviews = reading.reviews.map { ReviewBadges(runs: $0.runs, head: isAboutRow ? $0.head : nil, branch: row.branch) }
        facts.flakyReason = isAboutRow ? reading.flakyReason : nil
        // What its agent and its folder offer, with a repository or without.
        facts.resume = reading.resume
        facts.folder = folder(of: row, in: repository)
        guard facts.hasRepository else { return facts }
        if let pullRequest = row.pullRequest {
            facts.queue = queue(of: row, pullRequest, in: repository, merged: merged.known)
            facts.pullRequest = self.pullRequest(
                pullRequest, stack: row.stack, in: repository, reviewRequest: isAboutRow ? reading.reviewRequest : nil, merged: merged.read
            )
        } else if let number = mergedNumber(of: row, reading: reading, in: repository) {
            facts.queue = queue(of: number, head: nil, in: repository.queue, merged: merged.known)
            let read = repository.merged.first { $0.number == number }
            facts.pullRequest = PullRequest(
                number: number, isMerged: true, base: read?.baseRefName ?? repository.baseBranch ?? "", checks: .passed, url: read?.url
            )
        }
        // Its merged pull request's worktree, still there: the sidebar
        // offers the clean-up only at the head it merged at.
        facts.cleanUp = (isAboutRow ? reading.cleanUp : nil)
            ?? (facts.pullRequest?.isMerged == true && row.canCleanUp ? .offered : nil)
        // One that runs, as its path says: the phrase and "Merged today" say so too.
        if facts.cleanUp != nil, facts.folder?.isCleaningUp == true { facts.cleanUp = .running }
        return facts
    }

    /// The merged pull request of a task's row that shows none, in this
    /// repository. The queue's own branch update leaves the worktree a
    /// commit behind its merged head, at a head the queue knew: then it
    /// is the pull request of that branch in the queue shown, once it
    /// merged. (A worktree that moved on since has new work.) Else the
    /// one the task's own detection says merged, read in this row's
    /// worktree.
    private static func mergedNumber(of row: ProjectBoard.Row, reading: TaskReading, in repository: RepositoryReading) -> Int? {
        guard row.group != .otherRepository, row.pullRequest == nil else { return nil }
        if let branch = row.branch, let head = row.worktreePath.flatMap({ repository.heads[$0] }),
           let entry = repository.queue?.entries.first(where: { entry in
               // Merged as the queue saw it; or as GitHub's list says, at
               // a head the queue knew: its merge went unanswered.
               entry.branch == branch && entry.heads.contains(head) && (entry.mergeCommit != nil || repository.merged.contains {
                   $0.number == entry.number && $0.state == .merged && entry.heads.contains($0.headOid)
               })
           }) {
            return entry.number
        }
        guard reading.gitRoot == nil || reading.gitRoot == row.worktreePath else { return nil }
        // Another repository's (a fork's, where gh looked): its number isn't one of this repository's.
        if let theirs = reading.mergedPullRequestRepository, let ours = repository.gitHub, theirs != ours { return nil }
        return reading.mergedPullRequest
    }

    /// Where a row's work is on disk, as the table's buttons used it:
    /// Clean Up… where the row can be
    /// cleaned up, Open where no workspace is open in its worktree.
    private static func folder(of row: ProjectBoard.Row, in repository: RepositoryReading) -> Folder? {
        guard let path = row.worktreePath ?? row.folder else { return nil }
        return Folder(
            path: path, title: row.branch ?? (path as NSString).lastPathComponent, canCleanUp: row.canCleanUp,
            canOpen: row.workspaces.isEmpty, isCleaningUp: repository.cleaningUp.contains(path)
        )
    }

    /// "feat/login", "/Users/me/app.feat-login": the row's branch and its
    /// worktree, or its folder.
    private static func location(of row: ProjectBoard.Row) -> [String] {
        var parts: [String] = []
        if row.group == .main { parts.append("main checkout") }
        if let branch = row.branch {
            parts.append(branch)
        } else if let head = row.detachedHead {
            parts.append("detached HEAD (\(WorktreeCleanup.short(head)))")
        }
        if let path = row.worktreePath ?? row.folder { parts.append(path) }
        if row.folderIsGone { parts.append("folder is gone") }
        if row.worktreePath == nil, row.folder == nil { parts.append("not checked out") }
        return parts
    }

    // MARK: A pull request

    private static func pullRequest(
        _ pullRequest: ProjectBoard.PullRequest, stack: ProjectBoard.StackPlace?, in repository: RepositoryReading,
        reviewRequest: ReviewRequest? = nil, merged: Set<Int>
    ) -> PullRequest {
        // The queue merged it: GitHub's list says so a read later. Or
        // the merged list has it, read since the open one that still does.
        let mergedByQueue = repository.queue?.entries.contains { $0.number == pullRequest.number && $0.mergeCommit != nil } ?? false
        let isMerged = pullRequest.state == .merged || mergedByQueue || merged.contains(pullRequest.number)
        // A base gh didn't name holds nothing back, as for the queue.
        let isOnBaseBranch = repository.baseBranch == nil || pullRequest.baseRefName == nil
            || pullRequest.baseRefName == repository.baseBranch
        // Merged: its checks no longer hold anything, and none is named.
        let latest = isMerged ? [] : GitHub.latest(pullRequest.checks)
        let required = MergeQueue.selectedStandIns(repository.requiredChecks) { name in latest.contains { $0.matches(name) } }
        let request: ReviewRequest?
        switch pullRequest.reviewDecision {
        case "CHANGES_REQUESTED": request = .changesRequested
        case "REVIEW_REQUIRED": request = .reviewRequired
        case "APPROVED": request = reviewRequest == .feedback ? .feedback : nil
        default: request = reviewRequest
        }
        return PullRequest(
            number: pullRequest.number, isMerged: isMerged, isDraft: pullRequest.isDraft,
            autoMerges: pullRequest.autoMerges, mergeIsBlocked: pullRequest.mergeIsBlocked,
            mergeabilityUnknown: !isMerged && !pullRequest.isConflicting && pullRequest.mergeable != "MERGEABLE",
            isConflicting: pullRequest.isConflicting,
            base: pullRequest.baseRefName ?? repository.baseBranch ?? "", isOnBaseBranch: isOnBaseBranch,
            checks: isMerged ? .passed : checks(latest: latest, required: required),
            reviewRequest: request, stack: stack, url: pullRequest.url,
            checkLines: isMerged ? [] : checkLines(latest: latest, required: required)
        )
    }

    /// Each check's latest run by name, with its result as the Board
    /// writes it, in the order `checks` counts them: those that hold
    /// the pull request (the red ones, and a required one that ended
    /// skipped or neutral), the required ones no check reported, those
    /// it waits for, then the rest as the rollup lists them.
    static func checkLines(_ checks: [GitHub.Check], required: [String]) -> [CheckLine] {
        checkLines(latest: GitHub.latest(checks), required: required)
    }

    private static func checkLines(latest: [GitHub.Check], required: [String]) -> [CheckLine] {
        let isRequired = { (check: GitHub.Check) in required.contains { check.matches($0) } }
        let holds = { (check: GitHub.Check) in
            check.result == .failure || (isRequired(check) && (check.result == .skipped || check.result == .neutral))
        }
        // Without a required check, every one counts.
        let isWaitedFor = { (check: GitHub.Check) in check.result == .pending && (required.isEmpty || isRequired(check)) }
        let line = { (check: GitHub.Check) in
            CheckLine(workflow: check.workflowName, name: check.name, result: ProjectBoard.glyph(check.result))
        }
        let missing = required.filter { name in !latest.contains { $0.matches(name) } }.map { CheckLine(name: $0, result: "no run yet") }
        return latest.filter(holds).map(line) + missing + latest.filter(isWaitedFor).map(line)
            + latest.filter { !holds($0) && !isWaitedFor($0) }.map(line)
    }

    /// The rollup's checks, by the merge queue's rules (`MergeQueue.judge`;
    /// docs/design/project-board.md, section 3.2): the latest run of each;
    /// a required name is green when every check of that name is; skipped
    /// and neutral are neither green nor red. (Not `checkSummary`, which
    /// shows the worst of a name: there a success hides a skipped one.)
    /// As far as the rollup tells: it doesn't say a commit status from a
    /// check run, nor two workflows of one name apart (Known limits).
    static func checks(_ checks: [GitHub.Check], required: [String]) -> Checks {
        self.checks(latest: GitHub.latest(checks), required: required)
    }

    static func checks(latest: [GitHub.Check], required: [String]) -> Checks {
        guard !latest.isEmpty || !required.isEmpty else { return .absent }
        let name = { (check: GitHub.Check) in check.qualifiedName ?? check.name }
        var failed: [String] = []
        var missing: [String] = []
        var running: [GitHub.Check] = []
        for requiredName in required {
            let matching = latest.filter { $0.matches(requiredName) }
            if matching.isEmpty {
                missing.append(requiredName)
            } else if matching.contains(where: { $0.result == .failure }) {
                failed.append(requiredName)
            } else if matching.contains(where: { $0.result == .pending }) {
                running += matching.filter { $0.result == .pending }
            } else if matching.contains(where: { $0.result != .success }) {
                // Skipped or neutral: no wait turns it green.
                failed.append(requiredName)
            }
        }
        let others = latest.filter { check in !required.contains { check.matches($0) } }
        failed += others.filter { $0.result == .failure }.map(name)
        // Without a required check, every one counts: none may still run.
        if required.isEmpty { running += others.filter { $0.result == .pending } }
        if !failed.isEmpty { return .failed(failed) }
        guard running.isEmpty, missing.isEmpty else {
            // The oldest start is the least string: one date to read, not one a check.
            let oldest = running.compactMap { GitHub.startTime($0.startedAt) }.min()
            return .pending(since: oldest.flatMap { try? Date($0, strategy: .iso8601) }?.timeIntervalSince1970, missing: missing)
        }
        return .passed
    }

    // MARK: The queue

    /// What the queue says of pull request `number`. `head` is its head
    /// on GitHub now, when the Board knows it.
    /// - In the queue shown while it runs, here or in another Nirux, its
    ///   place is the queue's own ("3 of 7") until the queue is through
    ///   with it, and one that isn't in it has none: the numbers are one
    ///   list's. Else its place is the next Start's, among those that
    ///   haven't merged: one the queue merged has none, nor one of
    ///   `merged`, the numbers the Board reads as merged (by hand, say).
    ///   The list still holds them until Start, whose sheet drops them.
    /// - A stop a push answers (its checks, a conflict, a merge or an
    ///   update that failed, commits not pushed, a busy agent) is over
    ///   once the head moved. The others stay until the next Start:
    ///   "changed" is itself a head that moved, and a draft or another
    ///   base is no commit's. After its merge, every stop stays.
    /// - The list is the user's to change unless a queue runs, here or
    ///   in another Nirux, or its confirmation sheet is open: the sheet
    ///   shows the list as it was when it opened.
    static func queue(of number: Int, head: String?, in state: ProjectBoard.QueueState?, merged: Set<Int> = []) -> Queue {
        guard let state else { return Queue() }
        let proposed = nextStartList(state, knownMerged: merged).firstIndex(of: number).map { $0 + 1 }
        var queue = Queue(list: listLock(state).map(QueueList.locked) ?? .open, order: state.isLocked ? nil : proposed)
        if state.isDryRun {
            queue.dryRun = "Dry run: this build doesn’t change GitHub." + (state.dryRunReason.map { " This build: \($0)." } ?? "")
        }
        guard let index = state.entries.firstIndex(where: { $0.number == number }) else { return queue }
        let entry = state.entries[index]
        let isMerged = entry.mergeCommit != nil
        if state.isLocked { queue.order = entry.step == .done ? nil : index + 1 }
        switch entry.step {
        case .waiting: queue.awaitsTurn = state.isLocked
        case .done: break
        case .preflight, .updating, .waitingForChecks, .rerunning:
            queue.step = .checks(sentence(ProjectBoard.queueStepLabel(entry.step, workflow: state.workflow)))
        case .merging, .waitingForPostMerge, .inTrain:
            queue.step = .merge(sentence(ProjectBoard.queueStepLabel(entry.step, workflow: state.workflow)))
        case .stopped(let reason):
            let isAnsweredByAPush = [.checks, .conflict, .merge, .update, .local, .agentBusy].contains(reason.kind)
            let moved = head.map { !entry.heads.contains($0) } ?? false
            if isMerged || !isAnsweredByAPush || !moved {
                queue.stop = QueueStop(
                    label: ProjectBoard.queueStopLabel(reason, workflow: state.workflow), message: reason.message,
                    isProblem: reason.isProblem, isAfterMerge: isMerged
                )
            }
        }
        return queue
    }

    /// The next Start's list as the Board shows it, a place for each: the
    /// queue's list without the pull requests known merged (`knownMerged`,
    /// a section's `SectionFacts.knownMerged`) or that the queue merged.
    static func nextStartList(_ state: ProjectBoard.QueueState, knownMerged: Set<Int>) -> [Int] {
        let merged = knownMerged.union(state.entries.filter { $0.mergeCommit != nil }.map(\.number))
        return state.selection.filter { !merged.contains($0) }
    }

    /// What the queue says of a row's pull request, and, of an open
    /// one, why the queue's rule keeps it out of the list, as far as the
    /// Board knows without a call (`ProjectBoard.queueRefusal`).
    private static func queue(
        of row: ProjectBoard.Row, _ pullRequest: ProjectBoard.PullRequest, in repository: RepositoryReading, merged: Set<Int>
    ) -> Queue {
        var queue = queue(of: pullRequest.number, head: pullRequest.headOid, in: repository.queue, merged: merged)
        if let timeout = repository.checkTimeout, timeout.number == pullRequest.number {
            // The row's normal checks own its current state. The header keeps the history.
            if timeout.hasCurrentReading { queue.stop = nil }
            else if queue.stop != nil { queue.stop?.message = timeout.status }
        }
        queue.refusal = pullRequest.isOpen ? ProjectBoard.queueRefusal(row, baseBranch: repository.baseBranch) : nil
        if repository.queue?.isLocked == true, let entry = repository.queue?.entries.first(where: { $0.number == pullRequest.number }),
           case .waitingForChecks(let head) = entry.step, head == pullRequest.headOid, repository.gitHubStatus == .current {
            let names = GitHub.latest(pullRequest.checks).filter { check in
                check.result == .pending && (repository.requiredChecks.isEmpty || repository.requiredChecks.contains(where: check.matches))
            }.compactMap { text($0.name) }
            if !names.isEmpty { queue.step = .checks(names.joined(separator: ", ")) }
        }
        return queue
    }

    private static func listLock(_ state: ProjectBoard.QueueState) -> String? {
        if state.run == .elsewhere { return "Another Nirux runs this repository’s queue: wait until it ends." }
        if state.isRunning { return "The queue is running: change the list once it stops." }
        return state.isConfirming ? "The confirmation sheet is open: change the list once it closes." : nil
    }

    /// "waiting for checks" → "Waiting for checks".
    private static func sentence(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
