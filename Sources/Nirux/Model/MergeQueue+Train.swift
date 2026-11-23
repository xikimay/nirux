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
        var step = Step.composing

        /// "train #781", or its branch until it has a pull request.
        var name: String { number.map { "train #\($0)" } ?? "the train \(branch)" }

        func stepDescription(workflow: String?) -> String {
            switch step {
            case .composing: "composing \(name)"
            case .opening: "opening the pull request of \(name)"
            case .waitingForChecks: "waiting for the checks of \(name)"
            case .merging: "merging \(name)"
            case .verifying: "checking that the pull requests of \(name) read merged"
            case .waitingForPostMerge: "waiting for the \(GitHub.workflowLabel(workflow)) of \(name)"
            case .done: "\(name) merged"
            }
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
        case create
        case created(MergeQueue.MutationResult)
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
    }

    /// "waiting for the checks of train #781 (#12, #14)".
    var trainStatusText: String {
        let numbers = Self.numbers(entries.map(\.number))
        guard let train else { return "checking \(numbers) for a train" }
        if case .train(.baseRunWait)? = purpose {
            return "\(train.name) waiting for the \(GitHub.workflowLabel(settings.postMergeWorkflow)) on "
                + "\(settings.baseBranch) before merging (\(numbers))"
        }
        return train.stepDescription(workflow: settings.postMergeWorkflow) + " (\(numbers))"
    }

    /// A stop leaves no pull request half-way: one stopped on its own sends
    /// the others back to waiting; a stop of the whole train stops them all.
    mutating func settleTrainEntries(after reason: MergeQueue.StopReason) {
        for index in entries.indices where entries[index].step.isActive {
            entries[index].step = current == nil ? .stopped(reason) : .waiting
        }
    }

    func trainUnconfirmedMutation(_ step: TrainPurpose) -> MergeQueue.Mutation? {
        guard let train else { return nil }
        switch step {
        case .created: return .createBranch(name: train.branch, commit: train.base)
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
        for index in entries.indices {
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
        var pending: [String] = []
        for index in entries.indices {
            let entry = entries[index]
            guard let pullRequest = answers.pullRequest(entry.number), let checks = answers.checks(entry.confirmedHead),
                  let local = answers.local(branch: entry.branch, head: entry.confirmedHead)
            else { return missingAnswer() }
            current = index
            if let problem = problem(with: pullRequest) { return stop(problem) }
            guard pullRequest.headOid == entry.confirmedHead else { return stop(changed(index: index, head: pullRequest.headOid)) }
            if pullRequest.mergeable == "CONFLICTING" { return stop(conflict(pullRequest)) }
            let isHeld = holdForLocal(local, index: index, now: now) { engine in
                engine.trainPreflight(after: MergeQueue.Limits.pollInterval)
            }
            guard !isHeld else { return }
            let verdict = MergeQueue.judge(checks, required: settings.requiredChecks)
            if let refusal = trainRefusal(verdict, entry: entry, url: pullRequest.url) { return stop(refusal) }
            if !verdict.pending.isEmpty {
                entries[index].step = .waitingForChecks(entry.confirmedHead)
                pending += verdict.pending.map { "\($0) of #\(entry.number)" }
            }
        }
        current = nil
        guard pending.isEmpty else {
            guard now - clocks.step < TimeInterval(settings.checksTimeoutMinutes * 60) else {
                return stop(MergeQueue.StopReason(kind: .checks, message: "After \(settings.checksTimeoutMinutes) minutes, required "
                    + "checks are still missing or running: \(pending.joined(separator: ", ")). A train only takes pull requests "
                    + "whose checks are green.", checksTimedOut: true))
            }
            return trainPreflight(after: MergeQueue.Limits.pollInterval)
        }
        for index in entries.indices { entries[index].step = .inTrain }
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
        train = MergeQueue.Train(branch: trainBranch, base: tip, head: tip)
        note("Composing the train \(trainBranch) on \(settings.baseBranch) at \(Self.short(tip))")
        mutate(.createBranch(name: trainBranch, commit: tip), for: .train(.create))
    }

    /// The next pull request's head merged into the train, in the confirmed
    /// order; then the train's pull request.
    private mutating func mergeNextPart() {
        guard let train else { return missingAnswer() }
        guard let index = entries.indices.first(where: { index in
            !train.parts.contains { $0.number == entries[index].number }
        }) else { return openTrain() }
        current = index
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
        note("Merged into the train as \(Self.short(tip))")
        mergeNextPart()
    }

    private mutating func openTrain() {
        guard let train else { return missingAnswer() }
        current = nil
        self.train?.step = .opening
        mutate(openMutation(train), for: .train(.open))
    }

    private func openMutation(_ train: MergeQueue.Train) -> MergeQueue.Mutation {
        let list = entries.map { "- #\($0.number) at \($0.confirmedHead)" }.joined(separator: "\n")
        let body = "Nirux’s merge queue lands these pull requests in one CI run, merged in this order on "
            + "\(settings.baseBranch) at \(train.base):\n\n\(list)\n\nTheir heads don’t change: each one reads merged once this "
            + "pull request is merged."
        return .openPullRequest(base: settings.baseBranch, head: train.branch,
                                title: "Merge train: \(Self.numbers(entries.map(\.number)))", body: body)
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
        read([.pullRequest(number), .checks(head)], after: delay, for: .train(.checks(head: head)))
    }

    private mutating func decideOnTrain(_ checks: MergeQueue.CommitChecks, head: String, now: TimeInterval) {
        guard let train else { return missingAnswer() }
        let verdict = MergeQueue.judge(checks, required: settings.requiredChecks)
        let red = verdict.failed.map { GitHub.qualifiedName(name: $0.name, workflow: $0.workflow) ?? $0.name } + verdict.failedStatuses
        if !red.isEmpty {
            let url = verdict.failed.first?.workflowRunID.map {
                "https://\(settings.gitHubRepository.host)/\(settings.repository)/actions/runs/\($0)"
            }
            return stop(MergeQueue.StopReason(kind: .checks, message: "Required check \(red.joined(separator: ", ")) failed on "
                + "\(train.name) at \(Self.short(head)).", url: url))
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

    private mutating func trainMergeChecks(head: String, after delay: TimeInterval = 0) {
        guard let number = train?.number else { return missingAnswer() }
        current = nil
        train?.step = .merging
        var reads: [MergeQueue.Read] = [.pullRequest(number), .checks(head), .compare(base: settings.baseBranch, head: head)]
        for entry in entries {
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
        if let problem = problem(with: pullRequest) { return stop(problem) }
        guard pullRequest.headOid == head else { return stop(trainMoved(to: pullRequest.headOid)) }
        if pullRequest.mergeable == "CONFLICTING" {
            return stop(MergeQueue.StopReason(kind: .train, message: "GitHub says \(train.name) conflicts with "
                + "\(settings.baseBranch).", url: pullRequest.url))
        }
        guard let comparison else { return cannotCompare(head) }
        guard comparison.behindBy == 0 else {
            return stop(MergeQueue.StopReason(kind: .update, message: "\(settings.baseBranch) moved to "
                + "\(Self.short(comparison.baseCommit)) while \(train.name) ran: something else merged into it. A train lands "
                + "only on the tip it was tested on: start again.", url: pullRequest.url))
        }
        let verdict = MergeQueue.judge(checks, required: settings.requiredChecks)
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
        for index in entries.indices {
            let entry = entries[index]
            guard let part = answers.pullRequest(entry.number),
                  let local = answers.local(branch: entry.branch, head: entry.confirmedHead)
            else { return missingAnswer() }
            current = index
            if let problem = problem(with: part) { return stop(problem) }
            guard part.headOid == entry.confirmedHead else { return stop(changed(index: index, head: part.headOid)) }
            let isHeld = holdForLocal(local, index: index, now: now) { engine in
                engine.trainMergeChecks(head: head, after: MergeQueue.Limits.pollInterval)
            }
            guard !isHeld else { return }
        }
        current = nil
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
        read(entries.map { .pullRequest($0.number) }, for: .train(.landed(commit: commit)))
    }

    /// GitHub marks a pull request merged once its head reaches the base.
    /// That is observed, not documented: a pull request that doesn't read
    /// merged within a minute stops the queue loudly.
    private mutating func trainLandedRead(_ answers: [MergeQueue.Read: MergeQueue.ReadResult], commit: String, now: TimeInterval) {
        guard let train else { return missingAnswer() }
        current = nil
        var open: [Int] = []
        for index in entries.indices where entries[index].step != .done {
            let entry = entries[index]
            guard let pullRequest = answers.pullRequest(entry.number) else { return missingAnswer() }
            switch pullRequest.state {
            case .merged:
                guard pullRequest.headOid == entry.confirmedHead else {
                    return stop(MergeQueue.StopReason(kind: .merge, message: "#\(entry.number) reads merged at "
                        + "\(Self.short(pullRequest.headOid)), not at \(Self.short(entry.confirmedHead)), the head \(train.name) merged.",
                        url: pullRequest.url))
                }
                entries[index].mergeCommit = pullRequest.mergeCommit
                entries[index].step = .done
            case .open:
                open.append(entry.number)
            case .closed:
                return stop(MergeQueue.StopReason(kind: .merge, message: "#\(entry.number) was closed instead of reading merged once "
                    + "\(train.name) landed as \(Self.short(commit)).", url: pullRequest.url))
            }
        }
        guard open.isEmpty else {
            guard now - clocks.step < MergeQueue.Limits.mergeConfirm else { return stop(notMarkedMerged(open, commit: commit)) }
            return read(open.map { .pullRequest($0) }, after: MergeQueue.Limits.mergeConfirmInterval,
                        for: .train(.landed(commit: commit)))
        }
        note("\(Self.numbers(entries.map(\.number))) read merged")
        guard settings.postMergeWorkflow != nil else { return finishTrain() }
        self.train?.step = .waitingForPostMerge(commit)
        clocks.step = now
        read([.pushRuns(commit: commit)], after: MergeQueue.Limits.firstRunPoll, for: .train(.postMerge(commit: commit)))
    }

    private func notMarkedMerged(_ numbers: [Int], commit: String) -> MergeQueue.StopReason {
        let list = Self.numbers(numbers)
        let heads = numbers.count == 1 ? "its head is" : "their heads are"
        return MergeQueue.StopReason(kind: .merge, message: "The train landed on \(settings.baseBranch) as \(Self.short(commit)), "
            + "but GitHub still shows \(list) open a minute later, though \(heads) in \(settings.baseBranch). A train relies on "
            + "GitHub marking each pull request merged once its head lands, and that didn’t happen: close \(list) by hand, and "
            + "find out why before starting another train.")
    }

    private mutating func finishTrain() {
        train?.step = .done
        current = nil
        phase = .finished
        note("Finished: \(entries.filter { $0.step == .done }.count) merged")
    }

    // MARK: Answers

    mutating func trainObserved(_ answers: [MergeQueue.Read: MergeQueue.ReadResult], _ step: TrainPurpose, now: TimeInterval) {
        switch step {
        case .preflight: return trainPreflightRead(answers, now: now)
        case .base: return trainBaseRead(answers)
        default: break
        }
        guard let train else { return missingAnswer() }
        switch step {
        case .created(let result):
            guard case .branch(let tip)? = answers[.branch(train.branch)] else { return missingAnswer() }
            guard tip == train.base else {
                let why = tip.map { "it is at \(Self.short($0))" } ?? Self.describe(result)
                return stop(MergeQueue.StopReason(kind: .train, message: "GitHub didn’t create the train’s branch \(train.branch) "
                    + "at \(Self.short(train.base)): \(why)."))
            }
            mergeNextPart()
        case .partTip(let index, let from, let result):
            guard case .branch(let tip)? = answers[.branch(train.branch)] else { return missingAnswer() }
            guard let tip else {
                return stop(MergeQueue.StopReason(kind: .train, message: "The train’s branch \(train.branch) is gone."))
            }
            guard tip != from else {
                // GitHub had nothing to merge: the head is in the train already.
                guard result == .sent else {
                    return stop(MergeQueue.StopReason(kind: .train, message: "GitHub didn’t merge #\(entries[index].number) into the "
                        + "train: \(Self.describe(result))."))
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
                return stop(MergeQueue.StopReason(kind: .train, message: "GitHub didn’t open the train’s pull request from "
                    + "\(train.branch): \(Self.describe(result))."))
            }
            self.train?.number = pullRequest.number
            if let problem = problem(with: pullRequest) { return stop(problem) }
            guard pullRequest.headOid == train.head else { return stop(trainMoved(to: pullRequest.headOid)) }
            self.train?.step = .waitingForChecks
            note("Opened for \(Self.numbers(entries.map(\.number)))")
            clocks.step = now
            waitForTrainChecks(head: train.head)
        case .checks(let head):
            guard let number = train.number, let pullRequest = answers.pullRequest(number), let checks = answers.checks(head) else {
                return missingAnswer()
            }
            if let problem = problem(with: pullRequest) { return stop(problem) }
            guard pullRequest.headOid == head else { return stop(trainMoved(to: pullRequest.headOid)) }
            decideOnTrain(checks, head: head, now: now)
        case .mergeChecks(let head):
            trainMergeChecksRead(answers, head: head, now: now)
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
        case .preflight, .base, .create, .part, .open, .land:
            missingAnswer()
        }
    }

    /// Whatever GitHub answered a train's call, a read says what it did.
    mutating func trainMutated(_ result: MergeQueue.MutationResult, _ step: TrainPurpose, now: TimeInterval) {
        guard let train else { return missingAnswer() }
        switch step {
        case .create:
            read([.branch(train.branch)], for: .train(.created(result)))
        case .part(let index, let from):
            if case .refused(409?, _) = result {
                let entry = entries[index]
                return stop(MergeQueue.StopReason(kind: .conflict, message: "#\(entry.number) conflicts with "
                    + "\(settings.baseBranch) or with a pull request before it in the train.",
                    url: "https://github.com/\(settings.repository)/pull/\(entry.number)"))
            }
            read([.branch(train.branch)], for: .train(.partTip(index: index, from: from, result: result)))
        case .open:
            read([.pullRequests(head: train.branch)], for: .train(.opened(result)))
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
