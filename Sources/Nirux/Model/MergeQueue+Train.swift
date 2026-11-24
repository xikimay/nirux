import Foundation

// MARK: - Train: one writer on the base, one CI run per batch

extension MergeQueue {
    /// The batch a Train cadence lands: a branch of Nirux's at the base's
    /// tip, one merge commit per pull request on it, made by GitHub, and the
    /// pull request that lands it. The pull requests' heads never change:
    /// each reads merged once the train brings its head into the base, which
    /// the queue checks rather than assumes.
    struct Train: Equatable, Codable, Sendable {
        enum Step: Equatable, Codable, Sendable {
            case composing
            case opening
            case waitingForChecks
            case merging
            /// Merged as this commit: each pull request must read merged.
            case verifying(String)
            case waitingForPostMerge(String)
            case done
            /// A stop for this reason closes its pull request.
            case closing(StopReason)
            /// Its pull request is no longer open, merged by none of the queue's calls.
            case closed
        }

        struct Part: Equatable, Codable, Sendable {
            let number: Int
            /// The train's merge commit of its head.
            let commit: String
        }

        let branch: String
        /// The base's tip it is built on.
        let base: String
        var head: String
        var parts: [Part] = []
        /// Its pull request into the base, once open.
        var number: Int?
        var mergeCommit: String?
        /// The workflow run its one rerun went to.
        var rerunOf: Int?
        var step = Step.composing

        /// Its part for this pull request, once the train landed.
        func landedPart(_ number: Int) -> Part? {
            mergeCommit == nil ? nil : parts.first { $0.number == number }
        }

        /// "train #781", or its branch until it has a pull request.
        var name: String { number.map { "train #\($0)" } ?? "the train \(branch)" }

        /// What a stop leaves on GitHub, named so nobody merges it later: its
        /// open pull request, one that may have opened, or its branch.
        var leftBehind: String? {
            guard mergeCommit == nil, step != .closed else { return nil }
            if let number { return " Train #\(number) stays open on GitHub: close it rather than merge it." }
            if step == .composing { return " The train’s branch \(branch) stays on GitHub." }
            return " A pull request of the train may be open from \(branch): close it rather than merge it."
        }

        func stepDescription(workflow: String?) -> String {
            switch step {
            case .composing: "composing \(name)"
            case .opening: "opening the pull request of \(name)"
            case .waitingForChecks: "waiting for the checks of \(name)"
            case .merging: "merging \(name)"
            case .verifying: "checking that the pull requests of \(name) read merged"
            case .waitingForPostMerge: "waiting for the \(GitHub.workflowLabel(workflow)) of \(name)"
            case .done: "\(name) merged"
            case .closing(let reason): "closing \(name): \(reason.message)"
            case .closed: "\(name) closed"
            }
        }
    }

    /// `work`'s answer, or `late` once `seconds` pass first; `work` isn't
    /// cancelled, its answer is dropped.
    static func answer<Value: Sendable>(
        within seconds: TimeInterval, or late: Value, _ work: @escaping @Sendable () async -> Value
    ) async -> Value {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? late
        }
    }

    /// `nirux-train/2026-11-23-183400`: a new branch for each Start (UTC).
    static func trainBranch(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "nirux-train/" + formatter.string(from: date)
    }
}

extension MergeQueue.Engine {
    /// Why a train request was sent.
    enum TrainPurpose: Equatable, Sendable {
        case preflight
        case base
        case create(base: String)
        case created(base: String, result: MergeQueue.MutationResult)
        case part(index: Int, from: String)
        case partTip(index: Int, from: String, result: MergeQueue.MutationResult)
        case partCommit(index: Int, from: String, tip: String)
        case open
        case opened(MergeQueue.MutationResult)
        case checks(head: String)
        case mergeChecks(head: String)
        case baseRunWait(head: String)
        case land(head: String, baseTip: String)
        case landConfirm(head: String, baseTip: String, result: MergeQueue.MutationResult)
        case landed(commit: String)
        case postMerge(commit: String)
        case postMergeOutcome(commit: String, run: GitHub.WorkflowRun)
        /// The train's pull request closed before the queue stops for this.
        case close(MergeQueue.StopReason)
        /// The CI triage asked about a failed run: `red` stops unless it is flaky.
        case triage(head: String, runID: Int, replaced: Set<Int>, red: MergeQueue.StopReason, retried: Bool)
        case rerun(head: String, runID: Int, replaced: Set<Int>)
        case rerunCheck(head: String, replaced: Set<Int>, message: String)
        case deleteLanded(commit: String)
        /// The train's branch deleted before the queue stops for this.
        case cleanup(MergeQueue.StopReason)
        /// A Stop came while the pull request opened: which one, to name it.
        case openedWhileStopping(message: String)
    }

    /// "waiting for the checks of train #781 (#12, #14)".
    var trainStatusText: String {
        let numbers = Self.numbers(riders.map { entries[$0].number })
        guard let train else { return "checking \(numbers) for a train" }
        if case .train(.baseRunWait)? = purpose {
            return "\(train.name) waiting for the \(GitHub.workflowLabel(settings.postMergeWorkflow)) on "
                + "\(settings.baseBranch) before merging (\(numbers))"
        }
        return train.stepDescription(workflow: settings.postMergeWorkflow) + " (\(numbers))"
    }

    /// A stop leaves no pull request half-way: one stopped on its own sends
    /// the others back to waiting; a stop of the whole train stops them all.
    /// Once the train landed, the others' heads are on the base: landed.
    mutating func settleTrainEntries(after reason: MergeQueue.StopReason) {
        for index in entries.indices where entries[index].step.isActive {
            if let part = train?.landedPart(entries[index].number) {
                entries[index].step = .done
                entries[index].mergeCommit = entries[index].mergeCommit ?? part.commit
            } else {
                entries[index].step = current == nil ? .stopped(reason) : .waiting
            }
        }
    }

    /// The train's branch to delete before the queue stops: on a stop the
    /// train found itself, once its pull request is closed or before it had
    /// one (deleting it would close an open one), never after someone else
    /// pushed to it.
    func trainCleanup(for reason: MergeQueue.StopReason) -> MergeQueue.Mutation? {
        switch purpose {
        case .train(.cleanup)?, .train(.partCommit)?: return nil
        default: break
        }
        // A push to the train's own branch: its head isn't the queue's any more.
        if reason.kind == .changed, current == nil { return nil }
        guard ![.interrupted, .dryRun, .setup, .github].contains(reason.kind), let train else { return nil }
        // A Stop deletes only a branch no pull request was opened from yet.
        if reason.kind == .user { return train.number == nil && train.step == .composing ? .deleteBranch(name: train.branch) : nil }
        guard train.number == nil || train.step == .closed else { return nil }
        return .deleteBranch(name: train.branch)
    }

    /// A train's pull request that a stop leaves open, named so nobody merges it later.
    var trainLeftover: String? {
        switch purpose {
        // The merge may have landed.
        case .train(.land)?: return nil
        case .train(.landConfirm(_, _, let result))? where result == .sent || result.isUncertain: return nil
        default: return train?.leftBehind
        }
    }

    /// The entries still in the batch: all but those a stop left out.
    var riders: [Int] {
        entries.indices.filter { index in
            if case .stopped = entries[index].step { return false }
            return true
        }
    }

    /// A pull request that conflicts leaves the train, which goes on without
    /// it; once the train lands, the queue stops on it for its agent.
    mutating func drop(_ index: Int, _ reason: MergeQueue.StopReason) {
        entries[index].step = .stopped(reason.appending(" It left the train."))
        note("#\(entries[index].number) left the train: \(reason.message)")
    }

    /// The train's pull request to close before the queue stops: on a stop
    /// the train found itself, never on Stop, a dry run or GitHub not
    /// answering, nor once the train may have landed.
    func trainToClose(for reason: MergeQueue.StopReason) -> Int? {
        if case .train(.close)? = purpose { return nil }
        guard ![.user, .interrupted, .dryRun, .setup, .github].contains(reason.kind), trainLeftover != nil else { return nil }
        return train?.number
    }

    /// The queue stops on a pull request that left the train, a conflict
    /// first (Ask Agent to Resolve offers it); one stopped after its head
    /// landed (pushed after the last check) only if none left. Those the
    /// train landed are named.
    private mutating func stopOnLeftOut() {
        let stopped = entries.indices.filter { if case .stopped = entries[$0].step { true } else { false } }
        let partNumbers = Set(train?.parts.map(\.number) ?? [])
        let left = stopped.filter { !partNumbers.contains(entries[$0].number) }
        guard let first = left.first ?? stopped.first, case .stopped(let reason) = entries[first].step else { return missingAnswer() }
        let others = left.filter { $0 != first }.map { entries[$0].number }
        let too = others.isEmpty ? nil : " \(Self.numbers(others)) left the train too."
        let landed = train.flatMap { train in
            train.mergeCommit == nil ? nil : train.number.map { " Train #\($0) landed \(Self.numbers(train.parts.map(\.number)))." }
        }
        stop(reason.appending(too).appending(landed), on: first)
    }

    /// A stop that is one pull request's own: the others go back to waiting.
    private mutating func stop(_ reason: MergeQueue.StopReason, on index: Int) {
        current = index
        stop(reason)
    }

    func trainUnconfirmedMutation(_ step: TrainPurpose) -> MergeQueue.Mutation? {
        if case .created(let base, _) = step { return .createBranch(name: trainBranch, commit: base) }
        guard let train else { return nil }
        switch step {
        case .partTip(let index, _, _): return partMutation(index, into: train.branch)
        case .opened: return openMutation(train)
        case .landConfirm(let head, _, _): return train.number.map { .merge(number: $0, head: head, method: .merge) }
        default: return nil
        }
    }

    // MARK: Preflight: every pull request at once

    mutating func trainStart(now: TimeInterval) {
        clocks.step = now
        trainPreflight()
    }

    /// GitHub's view of each pull request, its checks, its worktrees here.
    private mutating func trainPreflight(after delay: TimeInterval = 0) {
        current = nil
        var reads: [MergeQueue.Read] = []
        for index in riders {
            if entries[index].step == .waiting { entries[index].step = .preflight }
            let entry = entries[index]
            reads += [.pullRequest(entry.number), .checks(entry.confirmedHead), .local(branch: entry.branch, head: entry.confirmedHead)]
        }
        read(reads, after: delay, for: .train(.preflight))
    }

    /// Each pull request must be open on the base, at its confirmed head,
    /// free of conflicts, its agents idle and its checks green: a train only
    /// takes green pull requests. Checks still running are waited for.
    private mutating func trainPreflightRead(_ answers: [MergeQueue.Read: MergeQueue.ReadResult], now: TimeInterval) {
        var locals: [(index: Int, local: MergeQueue.LocalState)] = []
        var verdicts: [MergeQueue.ChecksVerdict] = []
        for index in riders {
            let entry = entries[index]
            guard let pullRequest = answers.pullRequest(entry.number), let checks = answers.checks(entry.confirmedHead),
                  let local = answers.local(branch: entry.branch, head: entry.confirmedHead)
            else { return missingAnswer() }
            if let problem = problem(with: pullRequest) { return stop(problem, on: index) }
            guard pullRequest.headOid == entry.confirmedHead else {
                return stop(changed(index: index, head: pullRequest.headOid), on: index)
            }
            if pullRequest.mergeable == "CONFLICTING" {
                drop(index, conflict(pullRequest))
                continue
            }
            let verdict = MergeQueue.judge(checks, required: settings.requiredChecks)
            if let refusal = trainRefusal(verdict, entry: entry, url: pullRequest.url) { return stop(refusal, on: index) }
            locals.append((index: index, local: local))
            verdicts.append(verdict)
        }
        guard !locals.isEmpty else { return stopOnLeftOut() }
        let isHeld = holdForLocal(locals, now: now) { engine in engine.trainPreflight(after: MergeQueue.Limits.pollInterval) }
        guard !isHeld else { return }
        var pending: [String] = []
        for (index, verdict) in zip(locals.map(\.index), verdicts) where !verdict.pending.isEmpty {
            entries[index].step = .waitingForChecks(entries[index].confirmedHead)
            pending += verdict.pending.map { "\($0) of #\(entries[index].number)" }
        }
        guard pending.isEmpty else {
            guard now - clocks.step < TimeInterval(settings.checksTimeoutMinutes * 60) else {
                return stop(MergeQueue.StopReason(kind: .checks, message: "After \(settings.checksTimeoutMinutes) minutes, required "
                    + "checks are still missing or running: \(pending.joined(separator: ", ")). A train only takes pull requests "
                    + "whose checks are green.", checksTimedOut: true))
            }
            return trainPreflight(after: MergeQueue.Limits.pollInterval)
        }
        for index in riders { entries[index].step = .inTrain }
        read([.branch(settings.baseBranch)], for: .train(.base))
    }

    /// Why a pull request's own checks keep it out of a train.
    private func trainRefusal(_ verdict: MergeQueue.ChecksVerdict, entry: MergeQueue.Entry, url: String) -> MergeQueue.StopReason? {
        let at = "#\(entry.number) at \(Self.short(entry.confirmedHead))"
        let red = verdict.failed.map { GitHub.qualifiedName(name: $0.name, workflow: $0.workflow) ?? $0.name } + verdict.failedStatuses
        if !red.isEmpty {
            return MergeQueue.StopReason(kind: .checks, message: "Required check \(red.joined(separator: ", ")) failed on \(at): a "
                + "train only takes pull requests whose checks are green.", url: url)
        }
        if !verdict.notGreen.isEmpty {
            return MergeQueue.StopReason(kind: .checks, message: "Required check \(verdict.notGreen.joined(separator: ", ")) isn’t "
                + "green on \(at): neutral and skipped don’t count.", url: url)
        }
        if !verdict.otherFailures.isEmpty {
            return MergeQueue.StopReason(kind: .checks, message: "\(verdict.otherFailures.joined(separator: ", ")) failed on \(at): "
                + "any red check keeps it out of a train, required or not.", url: url)
        }
        return nil
    }

    // MARK: Compose: the base's tip, then one merge per pull request

    private mutating func trainBaseRead(_ answers: [MergeQueue.Read: MergeQueue.ReadResult]) {
        guard case .branch(let tip)? = answers[.branch(settings.baseBranch)] else { return missingAnswer() }
        guard let tip else {
            return stop(MergeQueue.StopReason(kind: .github, message: "GitHub doesn’t know \(settings.baseBranch)."))
        }
        mutate(.createBranch(name: trainBranch, commit: tip), for: .train(.create(base: tip)))
    }

    /// The next pull request's head merged into the train, in the confirmed
    /// order; then the train's pull request.
    private mutating func mergeNextPart() {
        guard let train else { return missingAnswer() }
        guard !riders.isEmpty else { return stopOnLeftOut() }
        guard let index = riders.first(where: { index in
            !train.parts.contains { $0.number == entries[index].number }
        }) else { return openTrain() }
        mutate(partMutation(index, into: train.branch), for: .train(.part(index: index, from: train.head)))
    }

    private func partMutation(_ index: Int, into branch: String) -> MergeQueue.Mutation {
        let entry = entries[index]
        let owner = settings.repository.prefix { $0 != "/" }
        return .mergeIntoBranch(branch: branch, head: entry.confirmedHead,
                                message: "Merge pull request #\(entry.number) from \(owner)/\(entry.branch)")
    }

    /// GitHub's merge of the pull request's head: on top of the train's
    /// previous head, made by GitHub (`web-flow`).
    private mutating func partCommitRead(_ commit: MergeQueue.CommitInfo, index: Int, from: String, tip: String) {
        guard let train else { return missingAnswer() }
        let entry = entries[index]
        guard commit.committerLogin == "web-flow", commit.parents == [from, entry.confirmedHead] else {
            return stop(MergeQueue.StopReason(kind: .train, message: "The train’s branch \(train.branch) moved to "
                + "\(Self.short(tip)), which isn’t GitHub’s merge of #\(entry.number) into \(Self.short(from)): someone else "
                + "pushed to it.", url: compareURL(from, tip)))
        }
        self.train?.parts.append(MergeQueue.Train.Part(number: entry.number, commit: tip))
        self.train?.head = tip
        note("Merged #\(entry.number) into the train as \(Self.short(tip))")
        mergeNextPart()
    }

    private mutating func openTrain() {
        guard let train else { return missingAnswer() }
        self.train?.step = .opening
        mutate(openMutation(train), for: .train(.open))
    }

    private func openMutation(_ train: MergeQueue.Train) -> MergeQueue.Mutation {
        let list = riders.map { "- #\(entries[$0].number) at \(entries[$0].confirmedHead)" }.joined(separator: "\n")
        let body = "Nirux’s merge queue lands these pull requests in one CI run, merged in this order on "
            + "\(settings.baseBranch) at \(train.base):\n\n\(list)\n\nTheir heads don’t change: each one reads merged once this "
            + "pull request is merged."
        return .openPullRequest(base: settings.baseBranch, head: train.branch,
                                title: "Merge train: \(Self.numbers(riders.map { entries[$0].number }))", body: body)
    }

    /// GitHub's 409: a conflict with the base, or with the pull requests
    /// merged before it, which are on the base too once the train lands, so
    /// its agent resolves it by merging the base then.
    private func partConflict(_ index: Int, after parts: [MergeQueue.Train.Part]) -> MergeQueue.StopReason {
        let number = entries[index].number
        let url = "https://\(settings.gitHubRepository.host)/\(settings.repository)/pull/\(number)"
        let with = parts.isEmpty ? settings.baseBranch
            : "\(settings.baseBranch) or with \(Self.numbers(parts.map(\.number))), merged before it in the train"
        return MergeQueue.StopReason(kind: .conflict, message: "#\(number) conflicts with \(with).", url: url)
    }

    /// Why the train's pull request can't go on; one no longer open is left as it is.
    private mutating func trainProblem(_ pullRequest: MergeQueue.PullRequestSnapshot) -> MergeQueue.StopReason? {
        if !pullRequest.isOpen { train?.step = .closed }
        return problem(with: pullRequest)
    }

    private func trainMoved(to head: String) -> MergeQueue.StopReason {
        let name = train?.name ?? "the train"
        let expected = train?.head ?? head
        return MergeQueue.StopReason(kind: .changed, message: "Someone pushed to \(name): its head is \(Self.short(head)), not "
            + "\(Self.short(expected)).", url: compareURL(expected, head))
    }

    // MARK: Checks and merge of the train's pull request

    private mutating func waitForTrainChecks(head: String, after delay: TimeInterval = 0) {
        guard let number = train?.number else { return missingAnswer() }
        read([.pullRequest(number), .checks(head)] + riders.map { .pullRequest(entries[$0].number) }, after: delay,
             for: .train(.checks(head: head)))
    }

    private mutating func decideOnTrain(_ checks: MergeQueue.CommitChecks, head: String, now: TimeInterval) {
        guard let train else { return missingAnswer() }
        let verdict = MergeQueue.judge(checks, required: settings.requiredChecks, replaced: clocks.replacedChecks)
        let red = verdict.failed.map { GitHub.qualifiedName(name: $0.name, workflow: $0.workflow) ?? $0.name } + verdict.failedStatuses
        if !red.isEmpty {
            let url = verdict.failed.first?.workflowRunID.map {
                "https://\(settings.gitHubRepository.host)/\(settings.repository)/actions/runs/\($0)"
            }
            let again = train.rerunOf.map { run in verdict.failed.contains { $0.workflowRunID == run } } ?? false
            let stopRed = MergeQueue.StopReason(kind: .checks, message: "Required check \(red.joined(separator: ", ")) failed on "
                + "\(train.name) at \(Self.short(head))" + (again ? " again after its rerun." : "."), url: url)
            return rerunOrStop(stopRed, verdict: verdict, checks: checks, head: head, now: now)
        }
        if !verdict.notGreen.isEmpty {
            return stop(MergeQueue.StopReason(kind: .checks, message: "Required check \(verdict.notGreen.joined(separator: ", ")) "
                + "isn’t green on \(train.name): neutral and skipped don’t count."))
        }
        guard verdict.pending.isEmpty else {
            guard now - clocks.step < TimeInterval(settings.checksTimeoutMinutes * 60) else {
                return stop(MergeQueue.StopReason(kind: .checks, message: "The checks of \(train.name) timed out after "
                    + "\(settings.checksTimeoutMinutes) minutes: \(verdict.pending.joined(separator: ", ")) still missing or running "
                    + "on \(Self.short(head)). If runners are busy, raise the checks timeout in Board Settings.", checksTimedOut: true))
            }
            return waitForTrainChecks(head: head, after: MergeQueue.Limits.pollInterval)
        }
        trainMergeChecks(head: head)
    }

    /// The one workflow run a red train's failures all come from, if it
    /// wasn't rerun yet: only such failures can be rerun.
    private func rerunnableRun(_ verdict: MergeQueue.ChecksVerdict) -> Int? {
        let runIDs = Set(verdict.failed.compactMap(\.workflowRunID))
        guard train?.rerunOf == nil, verdict.failedStatuses.isEmpty, verdict.failed.allSatisfy({ $0.workflowRunID != nil }),
              runIDs.count == 1 else { return nil }
        return runIDs.first
    }

    /// Required checks only cancelled (no runner came within GitHub's wait,
    /// say) run again, once; other failures do when the CI triage, on at
    /// Start, calls them likely flaky; anything else stops.
    private mutating func rerunOrStop(
        _ red: MergeQueue.StopReason, verdict: MergeQueue.ChecksVerdict, checks: MergeQueue.CommitChecks, head: String, now: TimeInterval
    ) {
        let cancelled = verdict.failed.allSatisfy { $0.conclusion?.uppercased() == "CANCELLED" }
        guard let runID = rerunnableRun(verdict), let number = train?.number, cancelled || triagesFlakes else { return stop(red) }
        if isRunning(runID, in: checks) {
            let since = clocks.redSince ?? now
            clocks.redSince = since
            guard now - since < MergeQueue.Limits.rerunJobsWait, now - clocks.step < TimeInterval(settings.checksTimeoutMinutes * 60) else {
                return stop(red.appending(" Its run’s other jobs still ran \(Int(MergeQueue.Limits.rerunJobsWait / 60)) minutes later, "
                    + "so it wasn’t rerun."))
            }
            train?.step = .waitingForChecks
            return waitForTrainChecks(head: head, after: MergeQueue.Limits.pollInterval)
        }
        guard !cancelled else { return rerun(runID, because: "was cancelled", head: head, checks: checks) }
        askTriage(runID: runID, pullRequest: number, checks: checks, head: head, red: red, retried: false)
    }

    private mutating func askTriage(
        runID: Int, pullRequest: Int, checks: MergeQueue.CommitChecks, head: String, red: MergeQueue.StopReason, retried: Bool,
        after delay: TimeInterval = 0
    ) {
        let replaced = MergeQueue.runsReplaced(byRerunOf: runID, in: checks, required: settings.requiredChecks)
        // The triage reads every red job of the run, required or not.
        let redJobs = MergeQueue.latestRuns(checks.runs).filter { $0.workflowRunID == runID && GitHub.isRedCheck($0.conclusion) }
        read([.triage(run: runID, pullRequest: pullRequest, checks: redJobs.map(\.name))], after: delay,
             for: .train(.triage(head: head, runID: runID, replaced: replaced, red: red, retried: retried)))
    }

    /// GitHub reruns a run's failed jobs only once all its jobs are done.
    private func isRunning(_ runID: Int, in checks: MergeQueue.CommitChecks) -> Bool {
        MergeQueue.latestRuns(checks.runs).contains { $0.workflowRunID == runID && $0.status.uppercased() != "COMPLETED" }
    }

    private mutating func rerun(_ runID: Int, because why: String, head: String, checks: MergeQueue.CommitChecks) {
        rerun(runID, because: why, head: head, replaced: MergeQueue.runsReplaced(byRerunOf: runID, in: checks, required: settings.requiredChecks))
    }

    private mutating func rerun(_ runID: Int, because why: String, head: String, replaced: Set<Int>) {
        note("Required check \(why): rerunning the failed jobs of run \(runID), once")
        train?.rerunOf = runID
        train?.step = .waitingForChecks
        mutate(.rerun(runID: runID), for: .train(.rerun(head: head, runID: runID, replaced: replaced)))
    }

    private mutating func rerunStarted(head: String, replaced: Set<Int>, now: TimeInterval) {
        clocks.redSince = nil
        clocks.replacedChecks.formUnion(replaced)
        // The rerun takes the checks' whole time again.
        clocks.step = now
        waitForTrainChecks(head: head, after: MergeQueue.Limits.pollInterval)
    }

    private mutating func trainMergeChecks(head: String, after delay: TimeInterval = 0) {
        guard let number = train?.number else { return missingAnswer() }
        current = nil
        train?.step = .merging
        var reads: [MergeQueue.Read] = [.pullRequest(number), .checks(head), .compare(base: settings.baseBranch, head: head)]
        for entry in riders.map({ entries[$0] }) {
            reads += [.pullRequest(entry.number), .local(branch: entry.branch, head: entry.confirmedHead)]
        }
        if settings.postMergeWorkflow != nil { reads.append(.baseRuns) }
        read(reads, after: delay, for: .train(.mergeChecks(head: head)))
    }

    /// Everything again before the merge: the train's pull request, its
    /// checks, the base still at the tip it was built on, and each pull
    /// request still open at its confirmed head with its agents idle.
    private mutating func trainMergeChecksRead(_ answers: [MergeQueue.Read: MergeQueue.ReadResult], head: String, now: TimeInterval) {
        guard let train, let number = train.number, let pullRequest = answers.pullRequest(number),
              let checks = answers.checks(head), let comparison = answers.comparison(base: settings.baseBranch, head: head)
        else { return missingAnswer() }
        if let problem = trainProblem(pullRequest) { return stop(problem) }
        guard pullRequest.headOid == head else { return stop(trainMoved(to: pullRequest.headOid)) }
        if pullRequest.mergeable == "CONFLICTING" {
            return stop(MergeQueue.StopReason(kind: .train, message: "GitHub says \(train.name) conflicts with "
                + "\(settings.baseBranch).", url: pullRequest.url))
        }
        guard let comparison else { return cannotCompare(head) }
        guard comparison.behindBy == 0 else {
            return stop(MergeQueue.StopReason(kind: .train, message: "\(settings.baseBranch) moved to "
                + "\(Self.short(comparison.baseCommit)) while \(train.name) ran: something else merged into it. A train lands "
                + "only on the tip it was tested on: start again.", url: pullRequest.url))
        }
        let verdict = MergeQueue.judge(checks, required: settings.requiredChecks, replaced: clocks.replacedChecks)
        guard verdict.allRequiredGreen else {
            if verdict.failed.isEmpty, verdict.failedStatuses.isEmpty, verdict.notGreen.isEmpty {
                note("A required check runs again: waiting for it")
                self.train?.step = .waitingForChecks
                clocks.step = now
                return waitForTrainChecks(head: head)
            }
            return decideOnTrain(checks, head: head, now: now)
        }
        guard verdict.otherFailures.isEmpty else {
            return stop(MergeQueue.StopReason(kind: .checks, message: "\(verdict.otherFailures.joined(separator: ", ")) failed on "
                + "\(train.name): any red check blocks the merge, required or not.", url: pullRequest.url))
        }
        var locals: [(index: Int, local: MergeQueue.LocalState)] = []
        for index in riders {
            let entry = entries[index]
            guard let part = answers.pullRequest(entry.number),
                  let local = answers.local(branch: entry.branch, head: entry.confirmedHead)
            else { return missingAnswer() }
            if let problem = problem(with: part) { return stop(problem, on: index) }
            guard part.headOid == entry.confirmedHead else { return stop(changed(index: index, head: part.headOid), on: index) }
            locals.append((index: index, local: local))
        }
        let isHeld = holdForLocal(locals, now: now) { engine in
            engine.trainMergeChecks(head: head, after: MergeQueue.Limits.pollInterval)
        }
        guard !isHeld else { return }
        guard pullRequest.mergeable == "MERGEABLE" else {
            guard let delay = unknownDelay(now: now) else {
                return stop(MergeQueue.StopReason(kind: .merge, message: "GitHub still can’t say whether \(train.name) can merge "
                    + "(mergeable: \(pullRequest.mergeable)) after 2 minutes."))
            }
            return trainMergeChecks(head: head, after: delay)
        }
        clocks.unknownSince = nil
        clocks.unknownReads = 0
        if settings.postMergeWorkflow != nil {
            guard let runs = answers.runs(.baseRuns) else { return missingAnswer() }
            if waitForTrainBaseRuns(runs, head: head, now: now) { return }
        }
        note("Merging \(Self.short(head)) into \(settings.baseBranch) at \(Self.short(comparison.baseCommit)): "
            + MergeQueue.checksSummary(checks, required: settings.requiredChecks) + "; mergeable, not behind")
        mutate(.merge(number: number, head: head, method: .merge), for: .train(.land(head: head, baseTip: comparison.baseCommit)))
    }

    private mutating func waitForTrainBaseRuns(_ runs: [GitHub.WorkflowRun], head: String, now: TimeInterval) -> Bool {
        waitForBaseRuns(runs, deferring: [], subject: train?.name ?? "the train", poll: .train(.baseRunWait(head: head)), now: now) { engine in
            engine.trainMergeChecks(head: head)
        }
    }

    // MARK: Landed: each pull request must read merged

    private mutating func trainLanded(_ commit: String, now: TimeInterval) {
        train?.step = .verifying(commit)
        clocks.step = now
        read(riders.map { .pullRequest(entries[$0].number) }, for: .train(.landed(commit: commit)))
    }

    /// GitHub marks a pull request merged once its head reaches the base.
    /// That is observed, not documented: a pull request that doesn't read
    /// merged in time stops the queue loudly.
    private mutating func trainLandedRead(_ answers: [MergeQueue.Read: MergeQueue.ReadResult], commit: String, now: TimeInterval) {
        guard let train else { return missingAnswer() }
        current = nil
        var open: [Int] = []
        for index in entries.indices where entries[index].step == .inTrain {
            let entry = entries[index]
            guard let pullRequest = answers.pullRequest(entry.number) else { return missingAnswer() }
            switch pullRequest.state {
            case .open where pullRequest.headOid != entry.confirmedHead:
                // Pushed after the last check: the train landed the confirmed head only.
                entries[index].step = .stopped(MergeQueue.StopReason(kind: .changed, message: "#\(entry.number) moved to "
                    + "\(Self.short(pullRequest.headOid)) after \(train.name)’s last check: the train landed "
                    + "\(Self.short(entry.confirmedHead)), and #\(entry.number) stays open with the commits after it.",
                    url: compareURL(entry.confirmedHead, pullRequest.headOid)))
            case .merged:
                guard pullRequest.headOid == entry.confirmedHead else {
                    return stop(MergeQueue.StopReason(kind: .merge, message: "#\(entry.number) reads merged at "
                        + "\(Self.short(pullRequest.headOid)), not at \(Self.short(entry.confirmedHead)), the head \(train.name) merged.",
                        url: pullRequest.url), on: index)
                }
                entries[index].mergeCommit = pullRequest.mergeCommit
                entries[index].step = .done
            case .open:
                open.append(entry.number)
            case .closed:
                return stop(MergeQueue.StopReason(kind: .merge, message: "#\(entry.number) was closed instead of reading merged "
                    + "once \(train.name) landed as \(Self.short(commit)).", url: pullRequest.url), on: index)
            }
        }
        guard open.isEmpty else {
            guard now - clocks.step < MergeQueue.Limits.trainMarkedMerged else {
                // Open on GitHub though their heads landed: theirs is the stop, not a merge.
                let reason = notMarkedMerged(open, commit: commit)
                for index in entries.indices where open.contains(entries[index].number) { entries[index].step = .stopped(reason) }
                return stop(reason)
            }
            return read(open.map { .pullRequest($0) }, after: MergeQueue.Limits.mergeConfirmInterval,
                        for: .train(.landed(commit: commit)))
        }
        note("\(Self.numbers(entries.filter { $0.step == .done }.map(\.number))) read merged")
        mutate(.deleteBranch(name: train.branch), for: .train(.deleteLanded(commit: commit)))
    }

    private mutating func trainPostMerge(_ commit: String, now: TimeInterval) {
        guard settings.postMergeWorkflow != nil else { return finishTrain() }
        train?.step = .waitingForPostMerge(commit)
        clocks.step = now
        read([.pushRuns(commit: commit)], after: MergeQueue.Limits.firstRunPoll, for: .train(.postMerge(commit: commit)))
    }

    private func notMarkedMerged(_ numbers: [Int], commit: String) -> MergeQueue.StopReason {
        let list = Self.numbers(numbers)
        let heads = numbers.count == 1 ? "its head is" : "their heads are"
        return MergeQueue.StopReason(kind: .merge, message: "The train landed on \(settings.baseBranch) as \(Self.short(commit)), "
            + "but GitHub still shows \(list) open \(Int(MergeQueue.Limits.trainMarkedMerged / 60)) minutes later, though \(heads) in "
            + "\(settings.baseBranch). A train relies on "
            + "GitHub marking each pull request merged once its head lands, and that didn’t happen: close \(list) by hand, and "
            + "find out why before starting another train.")
    }

    /// The end, once the post-merge run is read: a pull request stopped after
    /// the train landed stops the queue there.
    private mutating func finishTrain() {
        train?.step = .done
        if riders.count < entries.count { return stopOnLeftOut() }
        current = nil
        phase = .finished
        note("Finished: \(entries.filter { $0.step == .done }.count) merged")
    }

    // MARK: Answers

    mutating func trainObserved(_ answers: [MergeQueue.Read: MergeQueue.ReadResult], _ step: TrainPurpose, now: TimeInterval) {
        switch step {
        case .preflight: return trainPreflightRead(answers, now: now)
        case .base: return trainBaseRead(answers)
        case .created(let base, let result):
            guard case .branch(let tip)? = answers[.branch(trainBranch)] else { return missingAnswer() }
            guard tip == base else {
                if tip == nil, result == .sent || result.isUncertain, now - clocks.step < MergeQueue.Limits.mergeConfirm {
                    return read([.branch(trainBranch)], after: MergeQueue.Limits.mergeConfirmInterval,
                                for: .train(.created(base: base, result: result)))
                }
                let why = tip.map { "it is at \(Self.short($0))" } ?? Self.describe(result)
                return stop(MergeQueue.StopReason(kind: .train, message: "GitHub didn’t create the train’s branch \(trainBranch) "
                    + "at \(Self.short(base)): \(why)."))
            }
            // Only a branch the queue created is ever the train's, to delete.
            train = MergeQueue.Train(branch: trainBranch, base: base, head: base)
            note("Composing the train \(trainBranch) on \(settings.baseBranch) at \(Self.short(base))")
            return mergeNextPart()
        case .openedWhileStopping(let message):
            guard case .pullRequests(let found)? = answers[.pullRequests(head: trainBranch)] else { return missingAnswer() }
            let base = settings.baseBranch
            guard let opened = found.first(where: { $0.isOpen && $0.baseRefName == base })?.number else {
                // A pull request just opened may take a moment to show.
                guard now - clocks.step >= MergeQueue.Limits.mergeConfirm else {
                    return read([.pullRequests(head: trainBranch)], after: MergeQueue.Limits.mergeConfirmInterval,
                                for: .train(.openedWhileStopping(message: message)))
                }
                return stop(MergeQueue.StopReason(kind: .user, message: message))
            }
            train?.number = opened
            return stop(MergeQueue.StopReason(kind: .user, message: message))
        default: break
        }
        guard let train else { return missingAnswer() }
        switch step {
        case .partTip(let index, let from, let result):
            guard case .branch(let tip)? = answers[.branch(train.branch)] else { return missingAnswer() }
            guard let tip else {
                return stop(MergeQueue.StopReason(kind: .train, message: "The train’s branch \(train.branch) is gone."))
            }
            guard tip != from else {
                // A merge may take a moment to show; still none: GitHub had
                // nothing to merge, the head is in the train already.
                if result == .sent || result.isUncertain, now - clocks.step < MergeQueue.Limits.mergeConfirm {
                    return read([.branch(train.branch)], after: MergeQueue.Limits.mergeConfirmInterval,
                                for: .train(.partTip(index: index, from: from, result: result)))
                }
                guard result == .sent else {
                    return stop(MergeQueue.StopReason(kind: .train, message: "GitHub didn’t merge #\(entries[index].number) into the "
                        + "train: \(Self.describe(result))."), on: index)
                }
                note("Its head is in the train already")
                self.train?.parts.append(MergeQueue.Train.Part(number: entries[index].number, commit: from))
                return mergeNextPart()
            }
            read([.commit(tip)], for: .train(.partCommit(index: index, from: from, tip: tip)))
        case .partCommit(let index, let from, let tip):
            guard let commit = answers.commit(tip) else { return missingAnswer() }
            partCommitRead(commit, index: index, from: from, tip: tip)
        case .opened(let result):
            guard case .pullRequests(let found)? = answers[.pullRequests(head: train.branch)] else { return missingAnswer() }
            guard let pullRequest = found.first(where: { $0.isOpen && $0.baseRefName == settings.baseBranch }) else {
                // A pull request just opened may take a moment to show.
                if result == .sent || result.isUncertain, now - clocks.step < MergeQueue.Limits.mergeConfirm {
                    return read([.pullRequests(head: train.branch)], after: MergeQueue.Limits.mergeConfirmInterval,
                                for: .train(.opened(result)))
                }
                return stop(MergeQueue.StopReason(kind: .train, message: "GitHub didn’t open the train’s pull request from "
                    + "\(train.branch): \(Self.describe(result))."))
            }
            self.train?.number = pullRequest.number
            if let problem = trainProblem(pullRequest) { return stop(problem) }
            guard pullRequest.headOid == train.head else { return stop(trainMoved(to: pullRequest.headOid)) }
            self.train?.step = .waitingForChecks
            note("Opened for \(Self.numbers(riders.map { entries[$0].number }))")
            clocks.step = now
            waitForTrainChecks(head: train.head)
        case .checks(let head):
            guard let number = train.number, let pullRequest = answers.pullRequest(number), let checks = answers.checks(head) else {
                return missingAnswer()
            }
            if let problem = trainProblem(pullRequest) { return stop(problem) }
            guard pullRequest.headOid == head else { return stop(trainMoved(to: pullRequest.headOid)) }
            // A push to a pull request of the batch makes the run moot: stop now, not at the merge.
            for index in riders {
                guard let rider = answers.pullRequest(entries[index].number) else { return missingAnswer() }
                if let problem = problem(with: rider) { return stop(problem, on: index) }
                guard rider.headOid == entries[index].confirmedHead else {
                    return stop(changed(index: index, head: rider.headOid), on: index)
                }
            }
            decideOnTrain(checks, head: head, now: now)
        case .mergeChecks(let head):
            trainMergeChecksRead(answers, head: head, now: now)
        case .triage(let head, let runID, let replaced, let red, let retried):
            guard let (asked, value) = answers.first, case .triage(let answer) = value, case .triage(_, let number, let names) = asked
            else { return missingAnswer() }
            switch answer {
            case .verdict(let verdict):
                guard let reason = verdict.flakyReason else {
                    return stop(red.appending(verdict == .real ? " The CI triage found a real failure."
                        : " The CI triage read the run and couldn’t tell it from a flake."))
                }
                rerun(runID, because: "is likely flaky (\(reason))", head: head, replaced: replaced)
            case .unread(let why) where !retried:
                note("The CI triage didn’t read run \(runID) (\(why)): asking once more")
                read([.triage(run: runID, pullRequest: number, checks: names)], after: MergeQueue.Limits.pollInterval,
                     for: .train(.triage(head: head, runID: runID, replaced: replaced, red: red, retried: true)))
            case .unread(let why):
                stop(red.appending(" The CI triage didn’t read run \(runID) (\(why)), so it wasn’t rerun."))
            case .off:
                stop(red.appending(" The CI triage is off, so it wasn’t rerun."))
            }
        case .rerunCheck(let head, let replaced, let message):
            guard let checks = answers.checks(head) else { return missingAnswer() }
            let latest = Set(MergeQueue.latestRuns(checks.runs).map(\.id))
            guard replaced.contains(where: { !latest.contains($0) }) else {
                return stop(MergeQueue.StopReason(kind: .checks, message: "Nirux couldn’t rerun the failed checks of \(train.name): "
                    + "\(message)"))
            }
            note("The rerun started despite the error")
            rerunStarted(head: head, replaced: replaced, now: now)
        case .baseRunWait(let head):
            guard let runs = answers.runs(.baseRuns) else { return missingAnswer() }
            if !waitForTrainBaseRuns(runs, head: head, now: now) { trainMergeChecks(head: head) }
        case .landConfirm(let head, let baseTip, let result):
            guard let number = train.number, let pullRequest = answers.pullRequest(number) else { return missingAnswer() }
            if pullRequest.state == .merged { self.train?.mergeCommit = pullRequest.mergeCommit }
            confirmMerge(pullRequest, head: head, baseTip: baseTip, result: result, now: now,
                         poll: .train(.landConfirm(head: head, baseTip: baseTip, result: result))) { engine, commit in
                engine.trainLanded(commit, now: now)
            }
        case .landed(let commit):
            trainLandedRead(answers, commit: commit, now: now)
        case .postMerge(let commit):
            guard let runs = answers.runs(.pushRuns(commit: commit)) else { return missingAnswer() }
            postMergeRead(runs, commit: commit, subject: train.name, now: now, poll: .train(.postMerge(commit: commit)),
                          outcome: { .train(.postMergeOutcome(commit: commit, run: $0)) }) { engine in engine.finishTrain() }
        case .postMergeOutcome(let commit, let run):
            guard let runs = answers.runs(.baseRuns),
                  let comparison = answers.comparison(base: commit, head: settings.baseBranch)
            else { return missingAnswer() }
            postMergeFailed(run, commit: commit, baseRuns: runs, comparison: comparison, subject: train.name)
        case .preflight, .base, .create, .created, .openedWhileStopping, .part, .open, .land, .close, .deleteLanded, .cleanup, .rerun:
            missingAnswer()
        }
    }

    /// Whatever GitHub answered a train's call, a read says what it did.
    mutating func trainMutated(_ result: MergeQueue.MutationResult, _ step: TrainPurpose, now: TimeInterval) {
        if case .create(let base) = step {
            clocks.step = now
            // GitHub created it: the train's, to delete on a stop, even before it shows.
            if result == .sent { train = MergeQueue.Train(branch: trainBranch, base: base, head: base) }
            return read([.branch(trainBranch)], for: .train(.created(base: base, result: result)))
        }
        guard let train else { return missingAnswer() }
        switch step {
        case .cleanup(let reason):
            if result == .sent { self.train?.step = .closed }
            stop(reason.appending(result == .sent ? " Nirux deleted the train’s branch \(train.branch)."
                : " Nirux couldn’t delete the train’s branch \(train.branch): \(Self.describe(result))."))
        case .deleteLanded(let commit):
            if result != .sent { note("Nirux couldn’t delete the train’s branch \(train.branch): \(Self.describe(result))") }
            trainPostMerge(commit, now: now)
        case .part(let index, let from):
            clocks.step = now
            if case .refused(409?, _) = result {
                drop(index, partConflict(index, after: train.parts))
                return mergeNextPart()
            }
            read([.branch(train.branch)], for: .train(.partTip(index: index, from: from, result: result)))
        case .open:
            clocks.step = now
            read([.pullRequests(head: train.branch)], for: .train(.opened(result)))
        case .close(let reason):
            guard let number = train.number else { return missingAnswer() }
            if result == .sent { self.train?.step = .closed }
            stop(reason.appending(result == .sent ? " Nirux closed train #\(number)."
                : " Nirux couldn’t close train #\(number): \(Self.describe(result))."))
        case .rerun(let head, _, let replaced):
            guard result == .sent else {
                // It may have started all the same: the checks say.
                return read([.checks(head)], after: result.isUncertain ? MergeQueue.Limits.pollInterval : 0,
                            for: .train(.rerunCheck(head: head, replaced: replaced, message: Self.describe(result))))
            }
            rerunStarted(head: head, replaced: replaced, now: now)
        case .land(let head, let baseTip):
            guard let number = train.number else { return missingAnswer() }
            clocks.step = now
            read([.pullRequest(number)], for: .train(.landConfirm(head: head, baseTip: baseTip, result: result)))
        default:
            missingAnswer()
        }
    }

    /// "#12, #14".
    static func numbers(_ numbers: [Int]) -> String {
        numbers.map { "#\($0)" }.joined(separator: ", ")
    }
}
