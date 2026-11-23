import Foundation

// MARK: - Limits (sections 3.2 and 4)

extension MergeQueue {
    enum Limits {
        /// Start refuses below this many requests left in either pool.
        static let minimumRateLimit = 500
        /// The pull request and its checks, while waiting.
        static let pollInterval: TimeInterval = 20
        /// Workflow runs, while waiting.
        static let runPollInterval: TimeInterval = 30
        /// The first look for the post-merge run: it starts within seconds.
        static let firstRunPoll: TimeInterval = 10
        /// A new head after `update-branch`: polled this often, this long.
        static let updatePollInterval: TimeInterval = 10
        static let updateTimeout: TimeInterval = 5 * 60
        /// Branch updates per pull request per Start.
        static let maxUpdates = 2
        /// A busy agent may keep a pull request waiting this long.
        static let agentWait: TimeInterval = 10 * 60
        /// `mergeable: UNKNOWN` is read again for this long.
        static let mergeableUnknown: TimeInterval = 2 * 60
        /// After `gh pr merge`, the pull request must read MERGED within this.
        static let mergeConfirm: TimeInterval = 60
        static let mergeConfirmInterval: TimeInterval = 5
        /// After a train lands, each of its pull requests must read MERGED within this.
        static let trainMarkedMerged: TimeInterval = 3 * 60
        /// The post-merge run must show within this after the merge.
        static let postMergeRunAppears: TimeInterval = 5 * 60
        /// Reads retry with back-off for this long, then stop.
        static let readRetry: TimeInterval = 5 * 60
        /// The first wait after a secondary rate limit, doubled each time.
        static let secondaryRateLimit: TimeInterval = 60
    }
}

// MARK: - Engine

extension MergeQueue {
    /// The merge queue as a pure state machine (section 3.5): each event,
    /// with the time it arrived, changes the state and returns at most one
    /// request, which the driver runs and answers with the next event.
    /// Nothing here reads a clock or runs a process.
    ///
    /// For each pull request, in order (section 3.2): preflight, update
    /// the branch if it is behind, wait for the required checks, check
    /// everything again and merge the confirmed head, wait for the
    /// post-merge workflow. Anything unexpected stops the queue.
    struct Engine: Sendable {
        struct Output: Equatable, Sendable {
            /// The request to run now; nil when the engine waits on none.
            var request: Request?
            var notes: [Note] = []
        }

        let settings: BoardConfig.QueueSettings
        let cadence: Cadence
        let startedByLead: Bool
        /// The branch a Train cadence composes its batch on: new for each Start.
        let trainBranch: String
        private var stopMessage = "Stopped by the user."
        // The train's flow (MergeQueue+Train) writes the state below too.
        var entries: [Entry]
        var phase: Phase = .idle
        /// The entry being worked on.
        var current: Int?
        var train: Train?
        /// The request whose answer the engine waits for. An answer to any
        /// other is ignored: it comes from before a Stop.
        private(set) var request: Request?
        var purpose: Purpose?
        private var nextRequestID = 1
        var clocks = Clocks()
        /// The post-merge runs on the base that had failed at Start, by run
        /// and attempt: the sheet warns of them. Any other that fails since,
        /// a run still going at Start or rerun since included, stops the
        /// queue before its next merge.
        private var baseRunsFailedAtStart: Set<String> = []
        private var outbox = Output()

        init(
            settings: BoardConfig.QueueSettings, entries: [ConfirmedEntry], cadence: Cadence = .standard, startedByLead: Bool = false,
            trainBranch: String = "nirux-train/queue"
        ) {
            self.startedByLead = startedByLead
            self.cadence = cadence
            self.trainBranch = trainBranch
            self.settings = settings
            self.entries = entries.map(Entry.init)
        }

        var currentEntry: Entry? { current.map { entries[$0] } }

        /// A mutation sent whose effect GitHub hasn't shown yet: in flight,
        /// a branch update whose new head hasn't shown, or a merge whose
        /// pull request doesn't read MERGED yet.
        var unconfirmedMutation: Mutation? {
            if case .mutate(let mutation)? = request?.action { return mutation }
            if case .train(let step)? = purpose { return trainUnconfirmedMutation(step) }
            guard let entry = currentEntry else { return nil }
            switch purpose {
            case .updatePoll(let from)?, .updateFailed(let from, _)?:
                return .updateBranch(number: entry.number, expectedHead: from)
            case .mergeConfirm(let head, _, _)?:
                return .merge(number: entry.number, head: head, method: settings.mergeMethod)
            default:
                return nil
            }
        }

        private var isWaitingOnBaseRun: Bool {
            if case .baseRunWait? = purpose { return true }
            return false
        }

        /// "#52 waiting for the nightly, 3 of 7".
        var statusText: String {
            switch phase {
            case .idle: return "Not started"
            case .finished: return "Finished: \(entries.filter { $0.step == .done }.count) merged"
            case .stopped(let reason): return "Stopped: \(reason.message)"
            case .running, .paused, .stopping:
                var text = cadence == .train ? trainStatusText : current.map { current in
                    let step = isWaitingOnBaseRun
                        ? "#\(entries[current].number) waiting for the \(GitHub.workflowLabel(settings.postMergeWorkflow)) "
                            + "on \(settings.baseBranch) before merging"
                        : entries[current].stepDescription(workflow: settings.postMergeWorkflow)
                    return "\(step), \(current + 1) of \(entries.count)"
                } ?? "Starting"
                if case .paused = phase { text += " (paused by GitHub’s rate limit)" }
                if phase == .stopping { text += " (stopping)" }
                return text
            }
        }

        mutating func handle(_ event: Event, now: TimeInterval) -> Output {
            outbox = Output()
            switch event {
            case .start:
                start()
            case .stop:
                userStop(message: "Stopped by the user.")
            case .stopByLead:
                userStop(message: "Stopped by Lead.")
            case .read(let id, let result):
                guard let request, id == request.id, case .read(let reads, _) = request.action, let purpose else { break }
                self.request = nil
                switch result {
                case .success(let answers):
                    clocks.readFailingSince = nil
                    clocks.readFailures = 0
                    clocks.secondaryLimits = 0
                    if case .paused = phase { phase = .running }
                    observed(answers, purpose: purpose, now: now)
                case .failure(let failure):
                    readFailed(failure, reads: reads, purpose: purpose, now: now)
                }
            case .mutated(let id, let result):
                guard let request, id == request.id, case .mutate(let mutation) = request.action, let purpose else { break }
                self.request = nil
                let endsInItsStop: Bool
                switch purpose {
                case .train(.close), .train(.cleanup): endsInItsStop = true
                default: endsInItsStop = false
                }
                // Closing or deleting the train ends in its own stop, whose reason a Stop mustn't hide.
                if phase == .stopping, !endsInItsStop {
                    var message = stopMessage + " The \(Self.describe(mutation)), already sent, answered: "
                        + "\(Self.describe(result))."
                    if case .merge(let number, _, _) = mutation, result == .sent || result.isUncertain {
                        message += " Check #\(number) on GitHub: it may be merged."
                    }
                    // A train's pull request left open is named: its merge's answer is kept, and one just opened is looked up.
                    switch purpose {
                    case .train(.open):
                        read([.pullRequests(head: trainBranch)], for: .train(.openedWhileStopping(message: message)))
                    case .train(.land(let head, let baseTip)):
                        self.purpose = .train(.landConfirm(head: head, baseTip: baseTip, result: result))
                        stop(StopReason(kind: .user, message: message))
                    default:
                        stop(StopReason(kind: .user, message: message))
                    }
                } else {
                    mutated(result, purpose: purpose, now: now)
                }
            }
            let output = outbox
            outbox = Output()
            return output
        }

        // MARK: Why a request was sent

        enum Purpose: Equatable, Sendable {
            case start
            case preflight
            case preflightLocal(head: String)
            case behind(head: String)
            case update(from: String)
            case updatePoll(from: String)
            case updateCommit(from: String, head: String)
            case updateBase(from: String, head: String, parent: String)
            case update422(from: String, message: String)
            case updateFailed(from: String, message: String)
            case checks(head: String)
            case rerun(head: String, replaced: Set<Int>)
            case rerunCheck(head: String, replaced: Set<Int>, message: String)
            case mergeChecks(head: String)
            /// Only the base's runs, until those step 4 waits for end.
            case baseRunWait(head: String)
            case merge(head: String, baseTip: String)
            case mergeConfirm(head: String, baseTip: String, result: MutationResult)
            case postMerge(commit: String)
            case postMergeOutcome(commit: String, run: GitHub.WorkflowRun)
            case train(TrainPurpose)
        }

        /// When each wait began (`systemUptime`), and what the current
        /// pull request's waits know. Reset for each pull request, except
        /// the read retries.
        struct Clocks: Equatable, Sendable {
            /// The update sent, the checks awaited, the merge sent, the merge made.
            var step: TimeInterval = 0
            var agentBusySince: TimeInterval?
            var unknownSince: TimeInterval?
            var unknownReads = 0
            var baseRunsSince: TimeInterval?
            var awaitedBaseRuns: Set<Int> = []
            /// Failed check runs a rerun replaces: pending until their new run shows.
            var replacedChecks: Set<Int> = []
            var readFailingSince: TimeInterval?
            var readFailures = 0
            var secondaryLimits = 0

            /// A pause for a rate limit doesn't count toward any timeout.
            mutating func shift(by seconds: TimeInterval) {
                step += seconds
                readFailingSince = readFailingSince.map { $0 + seconds }
                agentBusySince = agentBusySince.map { $0 + seconds }
                unknownSince = unknownSince.map { $0 + seconds }
                baseRunsSince = baseRunsSince.map { $0 + seconds }
            }

            mutating func resetForEntry() {
                self = Clocks(readFailingSince: readFailingSince, readFailures: readFailures, secondaryLimits: secondaryLimits)
            }
        }

        // MARK: Requests and stops

        mutating func read(_ reads: [Read], after delay: TimeInterval = 0, for purpose: Purpose) {
            issue(.read(reads, after: max(0, delay)), purpose)
        }

        mutating func mutate(_ mutation: Mutation, for purpose: Purpose) {
            issue(.mutate(mutation), purpose)
        }

        private mutating func issue(_ action: Request.Action, _ purpose: Purpose) {
            let request = Request(id: nextRequestID, action: action)
            nextRequestID += 1
            self.request = request
            self.purpose = purpose
            outbox.request = request
        }

        /// Who a note or a journal line is about: the entry worked on, else the train.
        var subject: (number: Int?, step: String) {
            if let entry = currentEntry { return (entry.number, Self.stepName(entry.step)) }
            if let train { return (train.number, "train") }
            return (nil, "queue")
        }

        mutating func note(_ message: String) {
            let subject = subject
            outbox.notes.append(Note(number: subject.number, step: subject.step, message: message))
        }

        /// Stops the queue, and the pull request it was working on. When
        /// reads stop it while GitHub hasn't shown the effect of a call
        /// sent, the reason says so.
        mutating func stop(_ reason: StopReason) {
            if cadence == .train, let number = trainToClose(for: reason) {
                note("Closing train #\(number)")
                train?.step = .closing(reason)
                return mutate(.closePullRequest(number: number), for: .train(.close(reason)))
            }
            if cadence == .train, let cleanup = trainCleanup(for: reason) {
                return mutate(cleanup, for: .train(.cleanup(reason)))
            }
            var reason = reason
            if reason.kind == .github || reason.kind == .setup, let mutation = unconfirmedMutation,
               let shown = train?.name ?? currentEntry.map({ "#\($0.number)" }) {
                reason = StopReason(kind: reason.kind, message: reason.message + " The \(Self.describe(mutation)) was sent "
                    + "and GitHub didn’t show its effect yet: check \(shown) on GitHub.", url: reason.url)
            }
            if cadence == .train { reason = reason.appending(trainLeftover) }
            note("Stopped: \(reason.message)")
            request = nil
            purpose = nil
            outbox.request = nil
            if let current, entries[current].step != .done { entries[current].step = .stopped(reason) }
            if cadence == .train { settleTrainEntries(after: reason) }
            phase = .stopped(reason)
        }

        /// Stop: at once, unless a mutating call runs. A read's late answer
        /// is ignored; a merge can't be taken back, so its answer is awaited.
        private mutating func userStop(message: String) {
            switch phase {
            case .running, .paused:
                if request?.isMutation == true {
                    stopMessage = message
                    phase = .stopping
                    note(message + " Stopping once the call already sent answers.")
                } else {
                    stop(StopReason(kind: .user, message: message))
                }
            case .idle, .stopping, .stopped, .finished:
                break
            }
        }

        private mutating func start() {
            guard phase == .idle else { return }
            guard !entries.isEmpty else {
                phase = .finished
                return
            }
            phase = .running
            note("Started: \(entries.map { "#\($0.number)" }.joined(separator: ", ")) into \(settings.baseBranch) of "
                + "\(settings.repository) (\(cadence.title))")
            read([.auth, .rateLimit, .baseMergeQueue] + (settings.postMergeWorkflow != nil ? [.baseRuns] : []), for: .start)
        }

        /// The next waiting pull request, or the end.
        private mutating func advance() {
            guard let next = entries.firstIndex(where: { $0.step == .waiting }) else {
                current = nil
                phase = .finished
                note("Finished: \(entries.filter { $0.step == .done }.count) merged")
                return
            }
            current = next
            clocks.resetForEntry()
            entries[next].step = .preflight
            read([.pullRequest(entries[next].number)], for: .preflight)
        }

        // MARK: Read failures (section 4)

        private mutating func readFailed(_ failure: ReadFailure, reads: [Read], purpose: Purpose, now: TimeInterval) {
            switch failure {
            case .ghMissing:
                stop(StopReason(kind: .setup, message: "\(GitHub.CLI.missing): the queue can’t read GitHub."))
            case .notSignedIn(let message):
                stop(StopReason(kind: .setup, message: "\(GitHub.CLI.signedOut) (run gh auth login)" + (message.map { ": \($0)" } ?? "")))
            case .refused(let message):
                stop(StopReason(kind: .github, message: "GitHub refused a read: \(message)"))
            case .rateLimited(let resumeAt):
                let until = max(resumeAt, now + 1)
                phase = .paused(until: until)
                clocks.shift(by: until - now)
                note("Paused by GitHub’s rate limit for \(Int((until - now).rounded(.up))) s")
                read(reads, after: until - now, for: purpose)
            case .secondaryRateLimit:
                let delay = min(Limits.secondaryRateLimit * pow(2, Double(clocks.secondaryLimits)), 16 * 60)
                clocks.secondaryLimits += 1
                phase = .paused(until: now + delay)
                clocks.shift(by: delay)
                note("Paused by GitHub’s secondary rate limit for \(Int(delay)) s")
                read(reads, after: delay, for: purpose)
            case .transient(let message):
                if case .paused = phase { phase = .running }
                let since = clocks.readFailingSince ?? now
                clocks.readFailingSince = since
                guard now - since < Limits.readRetry else {
                    return stop(StopReason(kind: .github, message: "GitHub didn’t answer for 5 minutes: \(message)"))
                }
                let delay = min(5 * pow(2, Double(clocks.readFailures)), 60)
                clocks.readFailures += 1
                note("A read failed (\(message)): trying again in \(Int(delay)) s")
                read(reads, after: delay, for: purpose)
            }
        }

        // MARK: Answers

        private mutating func observed(_ answers: [Read: ReadResult], purpose: Purpose, now: TimeInterval) {
            if case .train(let step) = purpose { return trainObserved(answers, step, now: now) }
            guard case .start = purpose else { return observedForEntry(answers, purpose: purpose, now: now) }
            startChecked(answers, now: now)
        }

        private mutating func observedForEntry(_ answers: [Read: ReadResult], purpose: Purpose, now: TimeInterval) {
            guard let index = current else { return missingAnswer() }
            let number = entries[index].number
            switch purpose {
            case .preflight:
                guard let pullRequest = answers.pullRequest(number) else { return missingAnswer() }
                preflight(pullRequest, index: index)
            case .preflightLocal(let head):
                guard let local = answers.local(branch: entries[index].branch, head: head) else { return missingAnswer() }
                preflightLocal(local, head: head, index: index, now: now)
            case .behind(let head):
                guard let comparison = answers.comparison(base: settings.baseBranch, head: head) else { return missingAnswer() }
                guard let comparison else { return cannotCompare(head) }
                behind(by: comparison.behindBy, head: head, index: index, now: now)
            case .updatePoll(let from):
                guard let pullRequest = answers.pullRequest(number) else { return missingAnswer() }
                updatePolled(pullRequest, from: from, index: index, now: now)
            case .updateCommit(let from, let head):
                guard let commit = answers.commit(head) else { return missingAnswer() }
                updateCommitRead(commit, from: from, head: head, index: index)
            case .updateBase(let from, let head, let parent):
                guard let comparison = answers.comparison(base: parent, head: settings.baseBranch) else {
                    return missingAnswer()
                }
                guard let comparison, comparison.behindBy == 0 else {
                    return stop(pushedDuringUpdate(index: index, from: from, head: head,
                                                   why: "its second parent isn’t a commit of \(settings.baseBranch)"))
                }
                entries[index].heads.append(head)
                note("GitHub updated the branch: new head \(Self.short(head))")
                read([.compare(base: settings.baseBranch, head: head)], for: .behind(head: head))
            case .update422(let from, let message):
                guard let pullRequest = answers.pullRequest(number) else { return missingAnswer() }
                updateRefused(pullRequest, from: from, message: message, index: index, now: now)
            case .updateFailed(let from, let message):
                guard let pullRequest = answers.pullRequest(number) else { return missingAnswer() }
                if let problem = problem(with: pullRequest) { return stop(problem) }
                guard pullRequest.headOid != from else {
                    return stop(StopReason(kind: .update, message: "The branch update of #\(number) failed: \(message)"))
                }
                // The update may have gone through after all: check it is GitHub's.
                read([.commit(pullRequest.headOid)], for: .updateCommit(from: from, head: pullRequest.headOid))
            case .checks(let head):
                guard let pullRequest = answers.pullRequest(number), let checks = answers.checks(head) else {
                    return missingAnswer()
                }
                if let problem = problem(with: pullRequest) { return stop(problem) }
                guard pullRequest.headOid == head else { return stop(changed(index: index, head: pullRequest.headOid)) }
                decide(on: checks, head: head, index: index, now: now)
            case .rerunCheck(let head, let replaced, let message):
                guard let checks = answers.checks(head) else { return missingAnswer() }
                let latest = Set(MergeQueue.latestRuns(checks.runs).map(\.id))
                guard replaced.contains(where: { !latest.contains($0) }) else {
                    return stop(StopReason(kind: .checks, message: "Nirux couldn’t rerun the failed checks of #\(number): \(message)"))
                }
                note("The rerun started despite the error")
                rerunStarted(head: head, replaced: replaced, now: now)
            case .mergeChecks(let head):
                mergeChecksRead(answers, head: head, index: index, now: now)
            case .baseRunWait(let head):
                guard let runs = answers.runs(.baseRuns) else { return missingAnswer() }
                if !waitForBaseRuns(runs, head: head, index: index, now: now) { mergeChecks(head: head, index: index) }
            case .mergeConfirm(let head, let baseTip, let result):
                guard let pullRequest = answers.pullRequest(number) else { return missingAnswer() }
                if pullRequest.state == .merged { entries[index].mergeCommit = pullRequest.mergeCommit }
                confirmMerge(pullRequest, head: head, baseTip: baseTip, result: result, now: now,
                             poll: .mergeConfirm(head: head, baseTip: baseTip, result: result)) { engine, commit in
                    engine.merged(commit, index: index, now: now)
                }
            case .postMerge(let commit):
                guard let runs = answers.runs(.pushRuns(commit: commit)) else { return missingAnswer() }
                postMergeRead(runs, commit: commit, subject: "#\(number)", now: now, poll: .postMerge(commit: commit),
                              outcome: { .postMergeOutcome(commit: commit, run: $0) }) { engine in engine.finishEntry(index) }
            case .postMergeOutcome(let commit, let run):
                guard let runs = answers.runs(.baseRuns),
                      let comparison = answers.comparison(base: commit, head: settings.baseBranch)
                else { return missingAnswer() }
                postMergeFailed(run, commit: commit, baseRuns: runs, comparison: comparison, subject: "#\(number)")
            case .start, .update, .rerun, .merge, .train:
                missingAnswer()
            }
        }

        mutating func missingAnswer() {
            stop(StopReason(kind: .github, message: "Nirux didn’t get every answer it asked GitHub for."))
        }

        mutating func cannotCompare(_ head: String) {
            stop(StopReason(kind: .github, message: "GitHub can’t compare \(Self.short(head)) with \(settings.baseBranch)."))
        }

        private mutating func startChecked(_ answers: [Read: ReadResult], now: TimeInterval) {
            guard case .signedIn? = answers[.auth], let limit = answers.rateLimit, let mergeQueue = answers.baseMergeQueue else {
                return missingAnswer()
            }
            let remaining = min(limit.coreRemaining, limit.graphQLRemaining)
            guard remaining >= Limits.minimumRateLimit else {
                let reset = limit.coreRemaining < limit.graphQLRemaining ? limit.coreReset : limit.graphQLReset
                return stop(StopReason(kind: .setup, message: "Only \(remaining) GitHub requests are left until "
                    + "\(ProjectBoard.clockTime(reset, now: reset)): the queue needs \(Limits.minimumRateLimit) in each pool "
                    + "(REST \(limit.coreRemaining), GraphQL \(limit.graphQLRemaining))."))
            }
            if settings.postMergeWorkflow != nil {
                guard let runs = answers.runs(.baseRuns) else { return missingAnswer() }
                baseRunsFailedAtStart = Set(runs.filter { GitHub.isFailedRun($0.conclusion) }.map(\.attemptKey))
            }
            guard !mergeQueue else {
                return stop(StopReason(kind: .setup, message: "\(settings.baseBranch) requires GitHub’s merge queue: gh pr merge "
                    + "would queue pull requests there instead of merging them, without waiting for the post-merge workflow. "
                    + "Nirux’s queue doesn’t run on such a base."))
            }
            cadence == .train ? trainStart(now: now) : advance()
        }

        // MARK: 1. Preflight

        /// Why a pull request can't go on, at any step: not open, a draft,
        /// another base, a fork, auto-merge, GitHub's merge queue.
        func problem(with pullRequest: PullRequestSnapshot) -> StopReason? {
            let number = "#\(pullRequest.number)"
            let url = pullRequest.url
            if !pullRequest.isOpen {
                return StopReason(kind: .notMergeable, message: "\(number) is \(pullRequest.state.word), no longer open.", url: url)
            }
            if pullRequest.isDraft {
                return StopReason(kind: .notMergeable, message: "\(number) is a draft.", url: url)
            }
            if pullRequest.baseRefName != settings.baseBranch {
                return StopReason(kind: .notMergeable,
                                  message: "\(number) targets \(pullRequest.baseRefName), not \(settings.baseBranch).", url: url)
            }
            if pullRequest.headRepository != settings.gitHubRepository {
                return StopReason(kind: .notMergeable, message: "\(number) comes from another repository (a fork): the queue "
                    + "only merges branches of \(settings.repository).", url: url)
            }
            if pullRequest.hasAutoMerge {
                return StopReason(kind: .notMergeable, message: "\(number) is set to auto-merge: GitHub could merge it at any "
                    + "moment, without waiting for the post-merge workflow. Disable auto-merge (gh pr merge "
                    + "\(pullRequest.number) --disable-auto), then start again.", url: url)
            }
            if pullRequest.isInMergeQueue {
                return StopReason(kind: .notMergeable, message: "\(number) is in GitHub’s merge queue, which would merge it "
                    + "without waiting for the post-merge workflow. Remove it from there, then start again.", url: url)
            }
            return nil
        }

        /// "#52 changed since you confirmed it", with the two heads compared.
        func changed(index: Int, head: String) -> StopReason {
            let entry = entries[index]
            return StopReason(
                kind: .changed,
                message: "#\(entry.number) changed since you confirmed it: its head is \(Self.short(head)), "
                    + "not \(Self.short(entry.heads.last ?? entry.confirmedHead)).",
                url: compareURL(entry.confirmedHead, head)
            )
        }

        func conflict(_ pullRequest: PullRequestSnapshot) -> StopReason {
            StopReason(kind: .conflict, message: "#\(pullRequest.number) conflicts with \(settings.baseBranch).", url: pullRequest.url)
        }

        private func mergeabilityProblem(_ pr: PullRequestSnapshot) -> StopReason? {
            if pr.mergeable == "CONFLICTING" { return conflict(pr) }
            if cadence == .expressDisjoint, pr.mergeable != "MERGEABLE" {
                return StopReason(kind: .notMergeable, message: "Express requires #\(pr.number) to be mergeable "
                    + "(GitHub reports \(pr.mergeable)).", url: pr.url)
            }
            return nil
        }

        func compareURL(_ base: String, _ head: String) -> String {
            "https://github.com/\(settings.repository)/compare/\(base)...\(head)"
        }

        private mutating func preflight(_ pullRequest: PullRequestSnapshot, index: Int) {
            if let problem = problem(with: pullRequest) { return stop(problem) }
            guard entries[index].heads.contains(pullRequest.headOid) else {
                return stop(changed(index: index, head: pullRequest.headOid))
            }
            if let problem = mergeabilityProblem(pullRequest) { return stop(problem) }
            entries[index].branch = pullRequest.headRefName
            if cadence == .expressDisjoint {
                return mergeChecks(head: pullRequest.headOid, index: index)
            }
            read([.local(branch: pullRequest.headRefName, head: pullRequest.headOid)], for: .preflightLocal(head: pullRequest.headOid))
        }

        private mutating func preflightLocal(_ local: LocalState, head: String, index: Int, now: TimeInterval) {
            let number = entries[index].number
            // Everything again after a wait: the agent may have pushed meanwhile.
            let isHeld = holdForLocal(local, index: index, now: now) { engine in
                engine.read([.pullRequest(number)], after: Limits.pollInterval, for: .preflight)
            }
            guard !isHeld else { return }
            read([.compare(base: settings.baseBranch, head: head)], for: .behind(head: head))
        }

        /// The branch on this Mac, at preflight and before each merge: a busy
        /// agent may still commit and push, so it is waited for (10 minutes
        /// at most) before its worktree is looked at; tracked changes and
        /// unpushed commits stop. Returns whether the pull request waits
        /// (`retry` was asked for) or stopped.
        mutating func holdForLocal(
            _ local: LocalState, index: Int, now: TimeInterval, retry: (inout Engine) -> Void
        ) -> Bool {
            holdForLocal([(index: index, local: local)], now: now, retry: retry)
        }

        /// The same for a train's entries at once: a busy agent in any of
        /// them holds them all, on one clock; a problem stops on its entry.
        mutating func holdForLocal(
            _ locals: [(index: Int, local: LocalState)], now: TimeInterval, retry: (inout Engine) -> Void
        ) -> Bool {
            for (index, local) in locals {
                if let worktree = local.worktrees.first(where: { if case .unreadable = $0.problem { return true }; return false }),
                   case .unreadable(let reason)? = worktree.problem {
                    current = index
                    stop(StopReason(kind: .local, message: "Nirux couldn’t check \(worktree.path): \(reason)"))
                    return true
                }
            }
            let busy = locals.filter { !$0.local.busyAgents.isEmpty }
            if let first = busy.first {
                let agents = busy.flatMap(\.local.busyAgents).joined(separator: ", ")
                if clocks.agentBusySince == nil { note("Waiting up to 10 minutes for \(agents)") }
                let since = clocks.agentBusySince ?? now
                clocks.agentBusySince = since
                guard now - since < Limits.agentWait else {
                    current = first.index
                    stop(StopReason(kind: .agentBusy, message: "An agent of #\(entries[first.index].number) is still busy after "
                        + "10 minutes: \(agents)."))
                    return true
                }
                retry(&self)
                return true
            }
            clocks.agentBusySince = nil
            for (index, local) in locals {
                if let worktree = local.worktrees.first(where: { $0.problem == .trackedChanges }) {
                    current = index
                    stop(StopReason(kind: .local, message: "\(worktree.path) has changes to tracked files: commit and push them, "
                        + "or discard them, then start again."))
                    return true
                }
                if let worktree = local.worktrees.first(where: { $0.problem == .unpushed }) {
                    current = index
                    stop(StopReason(kind: .local, message: "\(worktree.path) has commits that aren’t on GitHub: push them, "
                        + "then start again."))
                    return true
                }
            }
            return false
        }

        // MARK: 2. Update the branch

        private mutating func behind(by count: Int, head: String, index: Int, now: TimeInterval) {
            guard count > 0 else { return waitForChecks(head: head, index: index, now: now) }
            let number = entries[index].number
            guard entries[index].updates < Limits.maxUpdates else {
                return stop(StopReason(kind: .update, message: "#\(number) is behind \(settings.baseBranch) again after "
                    + "\(Limits.maxUpdates) updates: it moves faster than the checks run. Start again later."))
            }
            entries[index].updates += 1
            entries[index].step = .updating(from: head)
            clocks.step = now
            clocks.unknownSince = nil
            clocks.unknownReads = 0
            // A later wait for a base run starts its own clock.
            clocks.baseRunsSince = nil
            note("\(count) commit\(count == 1 ? "" : "s") behind \(settings.baseBranch): updating the branch")
            mutate(.updateBranch(number: number, expectedHead: head), for: .update(from: head))
        }

        private mutating func updatePolled(_ pullRequest: PullRequestSnapshot, from: String, index: Int, now: TimeInterval) {
            if let problem = problem(with: pullRequest) { return stop(problem) }
            guard pullRequest.headOid != from else {
                guard now - clocks.step < Limits.updateTimeout else {
                    return stop(StopReason(kind: .update, message: "GitHub didn’t update the branch of #\(pullRequest.number) "
                        + "within 5 minutes."))
                }
                return read([.pullRequest(pullRequest.number)], after: Limits.updatePollInterval, for: .updatePoll(from: from))
            }
            read([.commit(pullRequest.headOid)], for: .updateCommit(from: from, head: pullRequest.headOid))
        }

        /// The update's commit: made by GitHub (`web-flow`), on top of the
        /// previous head, merging a commit of the base branch.
        private mutating func updateCommitRead(_ commit: CommitInfo, from: String, head: String, index: Int) {
            guard commit.committerLogin == "web-flow", commit.parents.count == 2, commit.parents[0] == from else {
                return stop(pushedDuringUpdate(index: index, from: from, head: head,
                                               why: "it isn’t GitHub’s merge of \(settings.baseBranch) into \(Self.short(from))"))
            }
            read([.compare(base: commit.parents[1], head: settings.baseBranch)],
                 for: .updateBase(from: from, head: head, parent: commit.parents[1]))
        }

        private func pushedDuringUpdate(index: Int, from: String, head: String, why: String) -> StopReason {
            StopReason(kind: .changed, message: "Someone pushed to #\(entries[index].number) during its update: its new head "
                + "\(Self.short(head)) came from elsewhere (\(why)).", url: compareURL(from, head))
        }

        /// A 422 has several causes (section 3.2, step 2).
        private mutating func updateRefused(
            _ pullRequest: PullRequestSnapshot, from: String, message: String, index: Int, now: TimeInterval
        ) {
            if let problem = problem(with: pullRequest) { return stop(problem) }
            guard pullRequest.headOid == from else { return stop(changed(index: index, head: pullRequest.headOid)) }
            if message.lowercased().contains("no new commits on the base branch") {
                note("GitHub says the branch isn’t behind")
                return waitForChecks(head: from, index: index, now: now)
            }
            switch pullRequest.mergeable {
            case "CONFLICTING":
                stop(conflict(pullRequest))
            case "MERGEABLE":
                stop(StopReason(kind: .update, message: "GitHub refused to update the branch of #\(pullRequest.number): \(message)"))
            default:
                guard let delay = unknownDelay(now: now) else {
                    return stop(StopReason(kind: .update,
                                           message: "GitHub refused to update the branch of #\(pullRequest.number): \(message)"))
                }
                read([.pullRequest(pullRequest.number)], after: delay, for: .update422(from: from, message: message))
            }
        }

        /// `mergeable: UNKNOWN` is read again with back-off for 2 minutes;
        /// nil once they are up.
        mutating func unknownDelay(now: TimeInterval) -> TimeInterval? {
            let since = clocks.unknownSince ?? now
            clocks.unknownSince = since
            guard now - since < Limits.mergeableUnknown else { return nil }
            let delay = min(5 * pow(2, Double(clocks.unknownReads)), 30)
            clocks.unknownReads += 1
            return delay
        }

        // MARK: 3. Required checks

        private mutating func waitForChecks(head: String, index: Int, now: TimeInterval) {
            entries[index].step = .waitingForChecks(head)
            clocks.step = now
            clocks.unknownSince = nil
            clocks.unknownReads = 0
            read([.pullRequest(entries[index].number), .checks(head)], for: .checks(head: head))
        }

        private mutating func decide(on checks: CommitChecks, head: String, index: Int, now: TimeInterval) {
            let verdict = MergeQueue.judge(checks, required: settings.requiredChecks, replaced: clocks.replacedChecks)
            if !verdict.failed.isEmpty || !verdict.failedStatuses.isEmpty {
                return checksFailed(verdict, checks: checks, head: head, index: index, now: now)
            }
            if !verdict.notGreen.isEmpty {
                return stop(StopReason(kind: .checks, message: "Required check \(verdict.notGreen.joined(separator: ", ")) "
                    + "isn’t green on \(Self.short(head)): neutral and skipped don’t count."))
            }
            guard verdict.pending.isEmpty else {
                guard now - clocks.step < TimeInterval(settings.checksTimeoutMinutes * 60) else {
                    let advice = verdict.pending.contains { $0.hasSuffix("(not started)") }
                        ? "A check that never starts may be misspelled: check the names in Board Settings."
                        : "If runners are busy, raise the checks timeout in Board Settings."
                    return stop(StopReason(kind: .checks, message: "#\(entries[index].number) timed out after \(settings.checksTimeoutMinutes) minutes. "
                        + "Required checks were missing or running on \(Self.short(head)): "
                        + "\(verdict.pending.joined(separator: ", ")). \(advice)", checksTimedOut: true))
                }
                return read([.pullRequest(entries[index].number), .checks(head)], after: Limits.pollInterval,
                            for: .checks(head: head))
            }
            mergeChecks(head: head, index: index)
        }

        /// A failed required check is rerun once per pull request per
        /// Start, when its failures are one workflow run's.
        private mutating func checksFailed(
            _ verdict: ChecksVerdict, checks: CommitChecks, head: String, index: Int, now: TimeInterval
        ) {
            let names = (verdict.failed.map { run in GitHub.qualifiedName(name: run.name, workflow: run.workflow) ?? run.name }
                + verdict.failedStatuses).joined(separator: ", ")
            let failedRunURL = verdict.failed.first?.workflowRunID.map {
                "https://\(settings.gitHubRepository.host)/\(settings.repository)/actions/runs/\($0)"
            }
            guard !entries[index].hasRerun else {
                return stop(StopReason(kind: .checks, message: "Required check \(names) failed again on \(Self.short(head)) "
                    + "after its rerun.", url: failedRunURL))
            }
            let runIDs = Set(verdict.failed.compactMap(\.workflowRunID))
            guard verdict.failedStatuses.isEmpty, verdict.failed.allSatisfy({ $0.workflowRunID != nil }),
                  runIDs.count == 1, let runID = runIDs.first
            else {
                return stop(StopReason(kind: .checks, message: "Required check \(names) failed on \(Self.short(head)). "
                    + "Nirux reruns the failed jobs of one workflow run only, and this failure isn’t that."))
            }
            // GitHub reruns a workflow run's failed jobs once all its jobs are done.
            if MergeQueue.latestRuns(checks.runs).contains(where: {
                $0.workflowRunID == runID && $0.status.uppercased() != "COMPLETED"
            }) {
                guard now - clocks.step < TimeInterval(settings.checksTimeoutMinutes * 60) else {
                    return stop(StopReason(kind: .checks, message: "Required check \(names) failed on \(Self.short(head)), "
                        + "and its workflow run was still running after \(settings.checksTimeoutMinutes) minutes.", url: failedRunURL))
                }
                return read([.pullRequest(entries[index].number), .checks(head)], after: Limits.pollInterval,
                            for: .checks(head: head))
            }
            entries[index].hasRerun = true
            entries[index].step = .rerunning(head)
            note("Required check \(names) failed: rerunning the failed jobs of run \(runID), once")
            mutate(.rerun(runID: runID),
                   for: .rerun(head: head, replaced: MergeQueue.runsReplaced(byRerunOf: runID, in: checks,
                                                                             required: settings.requiredChecks)))
        }

        private mutating func rerunStarted(head: String, replaced: Set<Int>, now: TimeInterval) {
            guard let index = current else { return }
            clocks.replacedChecks.formUnion(replaced)
            // The rerun takes the checks' whole time again.
            clocks.step = now
            read([.pullRequest(entries[index].number), .checks(head)], after: Limits.pollInterval, for: .checks(head: head))
        }

        // MARK: 4. Merge

        private mutating func mergeChecks(head: String, index: Int, after delay: TimeInterval = 0) {
            entries[index].step = .merging(head)
            var reads: [Read] = [
                .pullRequest(entries[index].number), .checks(head), .compare(base: settings.baseBranch, head: head),
                .local(branch: entries[index].branch, head: head)
            ]
            if settings.postMergeWorkflow != nil { reads.append(.baseRuns) }
            read(reads, after: delay, for: .mergeChecks(head: head))
        }

        private mutating func mergeChecksRead(_ answers: [Read: ReadResult], head: String, index: Int, now: TimeInterval) {
            let number = entries[index].number
            guard let pullRequest = answers.pullRequest(number), let checks = answers.checks(head),
                  let comparison = answers.comparison(base: settings.baseBranch, head: head),
                  let local = answers.local(branch: entries[index].branch, head: head)
            else { return missingAnswer() }
            if let problem = problem(with: pullRequest) { return stop(problem) }
            guard pullRequest.headOid == head else { return stop(changed(index: index, head: pullRequest.headOid)) }
            if let problem = mergeabilityProblem(pullRequest) { return stop(problem) }
            guard let comparison else { return cannotCompare(head) }
            if cadence != .expressDisjoint, comparison.behindBy > 0 {
                note("\(settings.baseBranch) moved: #\(number) is behind again")
                return behind(by: comparison.behindBy, head: head, index: index, now: now)
            }
            let verdict = MergeQueue.judge(checks, required: settings.requiredChecks, replaced: clocks.replacedChecks)
            if cadence == .expressDisjoint, let reason = verdict.expressRefusal(number: number) {
                return stop(StopReason(kind: .checks, message: reason, url: pullRequest.url))
            }
            guard verdict.allRequiredGreen else {
                if verdict.failed.isEmpty, verdict.failedStatuses.isEmpty, verdict.notGreen.isEmpty {
                    note("A required check runs again: waiting for it")
                    return waitForChecks(head: head, index: index, now: now)
                }
                return decide(on: checks, head: head, index: index, now: now)
            }
            guard verdict.otherFailures.isEmpty else {
                return stop(StopReason(kind: .checks, message: "\(verdict.otherFailures.joined(separator: ", ")) failed on "
                    + "\(Self.short(head)): any red check blocks the merge, required or not."))
            }
            // An agent may have gone back to work since preflight.
            let isHeld = holdForLocal(local, index: index, now: now) { engine in
                engine.mergeChecks(head: head, index: index, after: Limits.pollInterval)
            }
            guard !isHeld else { return }
            guard pullRequest.mergeable == "MERGEABLE" else {
                guard let delay = unknownDelay(now: now) else {
                    return stop(StopReason(kind: .merge, message: "GitHub still can’t say whether #\(number) can merge "
                        + "(mergeable: \(pullRequest.mergeable)) after 2 minutes."))
                }
                return mergeChecks(head: head, index: index, after: delay)
            }
            clocks.unknownSince = nil
            clocks.unknownReads = 0
            if settings.postMergeWorkflow != nil {
                guard let runs = answers.runs(.baseRuns) else { return missingAnswer() }
                if waitForBaseRuns(runs, head: head, index: index, now: now) { return }
            }
            let mergeability = comparison.behindBy == 0 ? "mergeable, not behind" : "mergeable, \(comparison.behindBy) behind"
            note("Merging \(Self.short(head)) into \(settings.baseBranch) at \(Self.short(comparison.baseCommit)): "
                + MergeQueue.checksSummary(checks, required: settings.requiredChecks) + "; \(mergeability)")
            mutate(.merge(number: number, head: head, method: settings.mergeMethod),
                   for: .merge(head: head, baseTip: comparison.baseCommit))
        }

        /// A run of the post-merge workflow still unfinished on the base,
        /// whatever its event, is waited for; once it ends, a failure
        /// stops the queue and anything else checks step 4 again. Returns
        /// whether the merge waits.
        private mutating func waitForBaseRuns(_ runs: [GitHub.WorkflowRun], head: String, index: Int, now: TimeInterval) -> Bool {
            let deferred = cadence == .standard ? [] : Set(entries[..<index].compactMap(\.mergeCommit))
            return waitForBaseRuns(runs, deferring: deferred, subject: "#\(entries[index].number)", poll: .baseRunWait(head: head),
                                   now: now) { engine in
                engine.mergeChecks(head: head, index: index)
            }
        }

        /// The same for any merge: the queue's own push runs of `deferring`
        /// aren't waited for, `poll` reads the runs again, and `recheck`
        /// checks the merge again once the awaited runs ended.
        mutating func waitForBaseRuns(
            _ runs: [GitHub.WorkflowRun], deferring deferredCommits: Set<String>, subject: String, poll: Purpose, now: TimeInterval,
            recheck: (inout Engine) -> Void
        ) -> Bool {
            let label = GitHub.workflowLabel(settings.postMergeWorkflow)
            // One that failed between two looks is caught too.
            if let failed = runs.first(where: {
                GitHub.isFailedRun($0.conclusion)
                    && (!baseRunsFailedAtStart.contains($0.attemptKey) || clocks.awaitedBaseRuns.contains($0.id))
            }) {
                stop(StopReason(kind: .postMerge, message: "The \(label) of \(Self.short(failed.headSha)) on "
                    + "\(settings.baseBranch) failed: the base may be broken.", url: failed.url))
                return true
            }
            let unfinished = runs.filter { run in
                !run.isCompleted && !(run.event == "push" && run.attempt == 1 && deferredCommits.contains(run.headSha))
            }
            if !unfinished.isEmpty {
                if clocks.baseRunsSince == nil {
                    note("Waiting for the \(label) running on \(settings.baseBranch) before merging")
                }
                let since = clocks.baseRunsSince ?? now
                clocks.baseRunsSince = since
                clocks.awaitedBaseRuns.formUnion(unfinished.map(\.id))
                guard now - since < TimeInterval(settings.postMergeTimeoutMinutes * 60) else {
                    stop(StopReason(kind: .postMerge, message: "The \(label) on \(settings.baseBranch) still runs after "
                        + "\(settings.postMergeTimeoutMinutes) minutes.", url: unfinished.first?.url))
                    return true
                }
                read([.baseRuns], after: Limits.runPollInterval, for: poll)
                return true
            }
            guard !clocks.awaitedBaseRuns.isEmpty else { return false }
            let awaited = runs.filter { clocks.awaitedBaseRuns.contains($0.id) }
            guard awaited.count == clocks.awaitedBaseRuns.count else {
                stop(StopReason(kind: .postMerge, message: "Nirux lost track of the \(label) run it waited for on "
                    + "\(settings.baseBranch)."))
                return true
            }
            clocks.awaitedBaseRuns = []
            clocks.baseRunsSince = nil
            note("The \(label) on \(settings.baseBranch) finished: checking \(subject) again")
            recheck(&self)
            return true
        }

        /// The pull request must read MERGED, with the confirmed head, and
        /// its merge commit on top of the base tip step 4 compared with:
        /// `landed` goes on with that commit; `poll` reads it again.
        mutating func confirmMerge(
            _ pullRequest: PullRequestSnapshot, head: String, baseTip: String, result: MutationResult, now: TimeInterval,
            poll: Purpose, landed: (inout Engine, String) -> Void
        ) {
            let number = pullRequest.number
            let again = { (engine: inout Engine) in
                engine.read([.pullRequest(number)], after: Limits.mergeConfirmInterval, for: poll)
            }
            if pullRequest.state == .merged {
                guard pullRequest.headOid == head else {
                    return stop(StopReason(kind: .merge, message: "#\(number) was merged at \(Self.short(pullRequest.headOid)), "
                        + "not at \(Self.short(head)): outside the queue.", url: pullRequest.url))
                }
                guard let mergeCommit = pullRequest.mergeCommit else {
                    guard now - clocks.step < Limits.mergeConfirm else {
                        return stop(StopReason(kind: .merge, message: "#\(number) is merged, but GitHub doesn’t give its "
                            + "merge commit."))
                    }
                    return again(&self)
                }
                guard let parent = pullRequest.mergeCommitParents.first, parent == baseTip else {
                    return stop(StopReason(kind: .merge, message: "#\(number) merged onto an untested base: its merge commit "
                        + "\(Self.short(mergeCommit)) sits on \(Self.short(pullRequest.mergeCommitParents.first ?? "?")), "
                        + "not on \(Self.short(baseTip)), the tip of \(settings.baseBranch) it was checked against."))
                }
                note("Merged as \(Self.short(mergeCommit))")
                return landed(&self, mergeCommit)
            }
            if pullRequest.isOpen, pullRequest.hasAutoMerge {
                return stop(StopReason(kind: .merge, message: "GitHub enabled auto-merge on #\(number) instead of merging it. "
                    + "Disable it: gh pr merge \(number) --repo github.com/\(settings.repository) --disable-auto",
                    url: pullRequest.url))
            }
            if pullRequest.isOpen, pullRequest.isInMergeQueue {
                return stop(StopReason(kind: .merge, message: "GitHub added #\(number) to its merge queue instead of merging "
                    + "it. Remove it from the merge queue on GitHub.", url: pullRequest.url))
            }
            guard pullRequest.isOpen else {
                return stop(StopReason(kind: .merge, message: "#\(number) was closed instead of merged.", url: pullRequest.url))
            }
            switch result {
            case .sent, .uncertain:
                // A merge that timed out may still land: GitHub is read again.
                guard now - clocks.step < Limits.mergeConfirm else {
                    let why = result == .sent ? "gh said it merged" : "the merge got no clear answer (\(Self.describe(result)))"
                    return stop(StopReason(kind: .merge, message: "#\(number) is still open a minute after the merge: \(why).",
                                           url: pullRequest.url))
                }
                again(&self)
            case .refused, .rateLimited, .dryRun:
                stop(StopReason(kind: .merge, message: "GitHub refused to merge #\(number): \(Self.describe(result))",
                                url: pullRequest.url))
            }
        }

        // MARK: 5. Post-merge workflow

        private mutating func merged(_ mergeCommit: String, index: Int, now: TimeInterval) {
            guard settings.postMergeWorkflow != nil, cadence == .standard || index == entries.count - 1 else {
                return finishEntry(index)
            }
            entries[index].step = .waitingForPostMerge(mergeCommit)
            clocks.step = now
            read([.pushRuns(commit: mergeCommit)], after: Limits.firstRunPoll, for: .postMerge(commit: mergeCommit))
        }

        private mutating func finishEntry(_ index: Int) {
            entries[index].step = .done
            advance()
        }

        /// The post-merge run of `commit`, merged for `subject` ("#52"):
        /// `poll` reads it again, `outcome` asks why a run didn't succeed.
        mutating func postMergeRead(
            _ runs: [GitHub.WorkflowRun], commit: String, subject: String, now: TimeInterval, poll: Purpose,
            outcome: (GitHub.WorkflowRun) -> Purpose, succeeded: (inout Engine) -> Void
        ) {
            let label = GitHub.workflowLabel(settings.postMergeWorkflow)
            let again = { (engine: inout Engine) in
                engine.read([.pushRuns(commit: commit)], after: Limits.runPollInterval, for: poll)
            }
            guard let run = runs.filter({ $0.headSha == commit && $0.event == "push" }).max(by: { $0.id < $1.id }) else {
                guard now - clocks.step < Limits.postMergeRunAppears else {
                    return stop(StopReason(kind: .postMerge, message: "No \(label) run started for \(Self.short(commit)) "
                        + "within 5 minutes of merging \(subject)."))
                }
                return again(&self)
            }
            guard run.isCompleted else {
                guard now - clocks.step < TimeInterval(settings.postMergeTimeoutMinutes * 60) else {
                    return stop(StopReason(kind: .postMerge, message: "The \(label) of \(subject) still runs after "
                        + "\(settings.postMergeTimeoutMinutes) minutes.", url: run.url))
                }
                return again(&self)
            }
            if GitHub.isSucceededRun(run.conclusion) {
                note("The \(label) of \(subject) succeeded")
                return succeeded(&self)
            }
            read([.baseRuns, .compare(base: commit, head: settings.baseBranch)], for: outcome(run))
        }

        /// A run that didn't succeed: whether the base moved since the
        /// merge tells a push from outside from the pull request's own
        /// failure (section 3.4).
        mutating func postMergeFailed(
            _ run: GitHub.WorkflowRun, commit: String, baseRuns: [GitHub.WorkflowRun], comparison: Comparison?, subject: String
        ) {
            let label = GitHub.workflowLabel(settings.postMergeWorkflow)
            let base = settings.baseBranch
            // GitHub not knowing the merge commit on the base any more: moved too.
            let moved = comparison.map { $0.aheadBy > 0 || $0.behindBy > 0 } ?? true
            let newer = baseRuns.filter { $0.id > run.id && $0.headSha != commit }.max { $0.id < $1.id }
            let movedTo = newer.map { newer in
                "\(Self.short(newer.headSha))" + (newer.title.map { " (“\($0)”)" } ?? "")
            } ?? "another commit"
            let conclusion = run.conclusion ?? "no conclusion"
            let message: String
            if conclusion.lowercased() == "cancelled" {
                if moved {
                    message = "The \(label) of \(subject) was cancelled by a push: \(base) moved to \(movedTo) before it "
                        + "finished. Nirux doesn’t take a later run’s result as \(subject)’s."
                } else if baseRuns.contains(where: { $0.headSha == commit && $0.event != "push" && $0.id > run.id }) {
                    message = "The \(label) of \(subject) was cancelled by a manual run on the same commit."
                } else {
                    message = "The \(label) of \(subject) was cancelled."
                }
            } else if moved {
                message = "The \(label) of \(subject) failed (\(conclusion)), but \(base) moved to \(movedTo) after the merge: "
                    + "a run whose commit is no longer the tip may refuse to publish it, so \(subject) may not be at fault."
            } else {
                message = "The \(label) of \(subject) failed (\(conclusion))."
            }
            stop(StopReason(kind: .postMerge, message: message, url: run.url))
        }

        // MARK: Mutation answers

        private mutating func mutated(_ result: MutationResult, purpose: Purpose, now: TimeInterval) {
            if case .dryRun(let command, let reason) = result {
                return stop(StopReason(kind: .dryRun, message: "Dry run: this build doesn’t change GitHub, because "
                    + "\(reason). It stopped before running: \(command)"))
            }
            if case .train(let step) = purpose { return trainMutated(result, step, now: now) }
            guard let index = current else { return missingAnswer() }
            let number = entries[index].number
            switch purpose {
            case .update(let from):
                switch result {
                case .sent:
                    read([.pullRequest(number)], after: Limits.updatePollInterval, for: .updatePoll(from: from))
                case .refused(422?, let message):
                    read([.pullRequest(number)], for: .update422(from: from, message: message))
                case .rateLimited(let message):
                    stop(StopReason(kind: .update, message: "GitHub refused the branch update of #\(number): \(message)"))
                case .refused(_, let message):
                    read([.pullRequest(number)], for: .updateFailed(from: from, message: message))
                case .uncertain(let message):
                    // Asynchronous on GitHub's side: polled as if accepted.
                    note("The branch update got no clear answer (\(message)): watching for its new head")
                    read([.pullRequest(number)], after: Limits.updatePollInterval, for: .updatePoll(from: from))
                case .dryRun:
                    break
                }
            case .rerun(let head, let replaced):
                switch result {
                case .sent:
                    rerunStarted(head: head, replaced: replaced, now: now)
                case .rateLimited(let message):
                    stop(StopReason(kind: .checks, message: "GitHub refused to rerun the checks of #\(number): \(message)"))
                case .refused(_, let message):
                    read([.checks(head)], for: .rerunCheck(head: head, replaced: replaced, message: message))
                case .uncertain(let message):
                    // Its new runs take a moment to show.
                    read([.checks(head)], after: Limits.pollInterval,
                         for: .rerunCheck(head: head, replaced: replaced, message: message))
                case .dryRun:
                    break
                }
            case .merge(let head, let baseTip):
                // Whatever gh said, GitHub says what happened.
                clocks.step = now
                read([.pullRequest(number)], for: .mergeConfirm(head: head, baseTip: baseTip, result: result))
            default:
                missingAnswer()
            }
        }

        // MARK: Words

        static func short(_ sha: String) -> String { WorktreeCleanup.short(sha) }

        static func stepName(_ step: Step) -> String {
            switch step {
            case .waiting: return "waiting"
            case .preflight: return "preflight"
            case .updating: return "updating"
            case .waitingForChecks: return "checks"
            case .rerunning: return "rerunning"
            case .merging: return "merging"
            case .waitingForPostMerge: return "post-merge"
            case .inTrain: return "train"
            case .done: return "done"
            case .stopped: return "stopped"
            }
        }

        static func describe(_ mutation: Mutation) -> String {
            switch mutation {
            case .updateBranch(let number, let head): return "update-branch #\(number) from \(short(head))"
            case .rerun(let runID): return "rerun of run \(runID)"
            case .merge(let number, let head, let method): return "\(method.rawValue) of #\(number) at \(short(head))"
            case .createBranch(let name, let commit): return "creation of branch \(name) at \(short(commit))"
            case .mergeIntoBranch(let branch, let head, _): return "merge of \(short(head)) into \(branch)"
            case .openPullRequest(let base, let head, _, _): return "pull request of \(head) into \(base)"
            case .closePullRequest(let number): return "close of #\(number)"
            case .deleteBranch(let name): return "deletion of branch \(name)"
            }
        }

        static func describe(_ result: MutationResult) -> String {
            switch result {
            case .sent: return "done"
            case .refused(let status, let message): return status.map { "HTTP \($0): \(message)" } ?? message
            case .uncertain(let message): return "no clear answer: \(message)"
            case .rateLimited(let message): return "rate limited: \(message)"
            case .dryRun(let command, let reason): return "not sent, a dry run because \(reason): \(command)"
            }
        }
    }
}

// MARK: - Reading answers

extension Dictionary where Key == MergeQueue.Read, Value == MergeQueue.ReadResult {
    func pullRequest(_ number: Int) -> MergeQueue.PullRequestSnapshot? {
        if case .pullRequest(let value)? = self[.pullRequest(number)] { return value }
        return nil
    }

    func checks(_ sha: String) -> MergeQueue.CommitChecks? {
        if case .checks(let value)? = self[.checks(sha)] { return value }
        return nil
    }

    /// `.some(nil)`: GitHub doesn't know one of the commits.
    func comparison(base: String, head: String) -> MergeQueue.Comparison?? {
        if case .comparison(let value)? = self[.compare(base: base, head: head)] { return .some(value) }
        return nil
    }

    func commit(_ sha: String) -> MergeQueue.CommitInfo? {
        if case .commit(let value)? = self[.commit(sha)] { return value }
        return nil
    }

    func runs(_ read: MergeQueue.Read) -> [GitHub.WorkflowRun]? {
        if case .runs(let value)? = self[read] { return value }
        return nil
    }

    func local(branch: String, head: String) -> MergeQueue.LocalState? {
        if case .local(let value)? = self[.local(branch: branch, head: head)] { return value }
        return nil
    }

    var rateLimit: MergeQueue.RateLimit? {
        if case .rateLimit(let value)? = self[.rateLimit] { return value }
        return nil
    }

    var baseMergeQueue: Bool? {
        if case .baseMergeQueue(let value)? = self[.baseMergeQueue] { return value }
        return nil
    }
}
