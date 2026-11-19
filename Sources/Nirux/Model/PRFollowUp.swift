import Foundation

/// Nirux keeps a task's open pull request mergeable while its Claude sits
/// idle (docs/design/pr-follow-up.md): it types the fix for a conflict with
/// the base, a failed check, or new review feedback, `maxRounds` rounds per
/// pull request at most, then hands the pull request to the user. This
/// file decides; the shell types the prompts and keeps each pull request's
/// `Entry` (`PRFollowUpStore`).
enum PRFollowUp {
    /// In the order rounds take them: a conflicting pull request runs no
    /// `pull_request` workflow.
    enum Kind: String, Codable, CaseIterable, Sendable {
        case conflict, ci, feedback
    }

    static let maxRounds = 3
    /// The user's own Rerun or Why Failed goes first.
    static let ciGrace: TimeInterval = 2 * 60
    /// Review bots post their comments over a minute or two.
    static let feedbackQuiet: TimeInterval = 3 * 60
    /// The read a push triggers comes 10 s after it
    /// (`PullRequestRefreshPolicy.pushSettleDelay`).
    static let readSettle: TimeInterval = 15
    /// How long after a round's turn the checkout may differ from the pull
    /// request, or what the round did stay unknown (a job waiting on an
    /// approval stays pending), before the round is settled.
    static let settleLimit: TimeInterval = 10 * 60
    /// A round whose turn end never came (Esc sends no Stop, a turn can
    /// stall) counts as ended this long after it was typed.
    static let roundLimit: TimeInterval = 2 * 60 * 60
    /// What a commit can fix: a cancelled job, or one that never started,
    /// isn't the branch's doing.
    static let fixableConclusions: Set<String> = ["FAILURE", "TIMED_OUT"]

    /// A prompt Nirux typed.
    struct Round: Codable, Equatable, Sendable {
        let kind: Kind
        /// The pull request's head when it was typed.
        let head: String
        let typedAt: TimeInterval
        /// The feedback it handed, by URL.
        var items: [String] = []
        /// When the turn that took it ended (`Entry.endRound`).
        var endedAt: TimeInterval?
        /// When a read after it told whether it moved the pull request.
        var settledAt: TimeInterval?
    }

    /// The pull request is the user's: no round until its head moves or
    /// what stopped it goes away.
    struct Stop: Codable, Equatable, Sendable {
        enum Cause: String, Codable, Sendable {
            /// Another round was due after `maxRounds`.
            case rounds
            /// A round ended with nothing pushed, its signal still there.
            case nothingPushed
            /// After a round, the checkout isn't at the pull request's head:
            /// commits left unpushed, or a push from elsewhere not pulled.
            case checkoutDiffers
        }

        let kind: Kind
        let cause: Cause
        let head: String
        let at: TimeInterval
        /// Of feedback, the items it is about.
        var items: [String] = []
    }

    /// One pull request's follow-up.
    struct Entry: Codable, Equatable, Sendable {
        /// When Nirux started following it: feedback from before is the
        /// user's.
        var since: TimeInterval = 0
        var rounds: [Round] = []
        /// Feedback handed already, by a round or the user's Address: never
        /// handed again.
        var handedFeedback: [String] = []
        /// Failures (`PRFollowUp.failureSignature`) the user's Why Failed
        /// took.
        var userFailures: [String] = []
        var stop: Stop?
        /// When it last changed (`PRFollowUpStore.update`).
        var updatedAt: TimeInterval = 0

        /// The turn that took the last round ended at `time`.
        mutating func endRound(at time: TimeInterval) {
            guard let last = rounds.indices.last, rounds[last].endedAt == nil, rounds[last].typedAt <= time else { return }
            rounds[last].endedAt = time
        }

        /// The last round never reached the agent: typing it failed.
        mutating func cancelRound() {
            guard let last = rounds.last, last.endedAt == nil, last.settledAt == nil else { return }
            rounds.removeLast()
            handedFeedback.removeAll(where: last.items.contains)
        }
    }

    /// What a decision reads besides the entry.
    struct Facts {
        var pullRequest: PRInfo
        /// Nil until read.
        var feedback: PRFeedback?
        /// When the read that gave `feedback` started.
        var feedbackReadAt: TimeInterval?
        var triage: Triage
        /// When Nirux first saw red the checks that are red now.
        var redSince: TimeInterval?
        /// Nil when git couldn't say.
        var localHead: String?
        /// The checkout's remote for the pull request's repository.
        var baseRemote: String?
        /// Nil when git couldn't say.
        var hasTrackedChanges: Bool?
        var isInMergeQueue = false
        /// When the read that gave `pullRequest` started.
        var readAt: TimeInterval?
        /// Why the agent's prompt takes no round now; nil when it does.
        var agentRefusal: String?
        /// Its turn goes on, or the user's may: a dialog, a question, a
        /// draft, a turn end being read.
        var agentIsBusy = false
        /// When this Nirux started following: a round typed before whose
        /// end it never saw ended then.
        var trackedSince: TimeInterval
        var now: TimeInterval
    }

    /// The triage of the checks that are red now.
    enum Triage: Equatable, Sendable {
        /// Turned off: every failure is unsure.
        case off
        case pending
        case done(CITriage.Verdict)
    }

    enum Action: Equatable, Sendable {
        case none
        /// Something to follow up, not now: why, for the log.
        case wait(String)
        /// Type `prompt`. The round is in the entry already, so that no
        /// read types it again; `Entry.cancelRound` when typing fails.
        case type(Round, prompt: String)
    }

    /// What to do about the pull request now. Records the round it types,
    /// settles the last one, sets or clears `entry.stop`.
    static func next(_ entry: inout Entry, _ facts: Facts) -> Action {
        let pullRequest = facts.pullRequest
        guard pullRequest.state.uppercased() == "OPEN", let head = pullRequest.headRefOid else { return .none }
        // The queue reruns checks and stops on its own; auto-merge would
        // merge a round's commit unseen.
        if facts.isInMergeQueue { return .wait("the merge queue holds it") }
        if pullRequest.autoMerges { return .wait("auto-merge is on") }
        if let stop = entry.stop {
            if stop.head == head, holds(stop, facts) { return .wait("stopped: \(stop.cause.rawValue)") }
            entry.stop = nil
        }
        if let wait = settleLastRound(&entry, facts, head: head) { return wait }
        var firstWait: String?
        for kind in Kind.allCases {
            switch signal(kind, entry, facts) {
            case nil:
                continue
            case .hold(let why)?:
                return .wait(why)
            case .wait(let why)?:
                // A check that never ends must not hold the next kinds.
                firstWait = firstWait ?? why
            case .ready(let prompt, let items)?:
                // Else the read may be older than a push.
                guard facts.localHead == head else { return .wait("the checkout's HEAD isn't the pull request's") }
                guard entry.rounds.count < maxRounds else {
                    entry.stop = Stop(kind: kind, cause: .rounds, head: head, at: facts.now, items: items)
                    return .wait("stopped: rounds")
                }
                guard facts.hasTrackedChanges == false else { return .wait("tracked files changed, or unknown") }
                if let refusal = facts.agentRefusal { return .wait(refusal) }
                let round = Round(kind: kind, head: head, typedAt: facts.now, items: items)
                entry.rounds.append(round)
                entry.handedFeedback += items
                return .type(round, prompt: prompt + " (Nirux follow-up, round \(entry.rounds.count) of \(maxRounds).)")
            }
        }
        return firstWait.map(Action.wait) ?? .none
    }

    /// Waits for the last round's turn to end and for reads after it, then
    /// stops the pull request when the round moved nothing. Nil once it's
    /// settled.
    private static func settleLastRound(_ entry: inout Entry, _ facts: Facts, head: String) -> Action? {
        guard let index = entry.rounds.indices.last, entry.rounds[index].settledAt == nil else { return nil }
        let round = entry.rounds[index]
        let lostTrack = round.typedAt < facts.trackedSince ? facts.trackedSince : nil
        let givenUp = facts.now >= round.typedAt + roundLimit ? round.typedAt + roundLimit : nil
        guard let endedAt = round.endedAt ?? lostTrack ?? givenUp else { return .wait("its round runs") }
        if facts.agentIsBusy { return .wait("its agent is busy") }
        guard let readAt = facts.readAt, readAt >= endedAt + readSettle else { return .wait("no read since its round") }
        guard let localHead = facts.localHead else { return .wait("the checkout's HEAD is unknown") }
        let cause: Stop.Cause?
        let isLate = facts.now - endedAt >= settleLimit
        if localHead != head {
            guard isLate else { return .wait("the checkout isn't at the pull request's head") }
            cause = .checkoutDiffers
        } else if round.head == head {
            if round.kind == .feedback, (facts.feedbackReadAt ?? 0) < endedAt + readSettle {
                return .wait("no feedback read since its round")
            }
            let present = isPresent(round.kind, items: round.items, facts)
            if present == nil, !isLate { return .wait("GitHub is still computing") }
            cause = present == true ? .nothingPushed : nil
        } else {
            cause = nil
        }
        entry.rounds[index].settledAt = facts.now
        guard let cause else { return nil }
        entry.stop = Stop(kind: round.kind, cause: cause, head: head, at: facts.now, items: round.items)
        return .wait("stopped: \(cause.rawValue)")
    }

    /// While unknown, a stop holds.
    private static func holds(_ stop: Stop, _ facts: Facts) -> Bool {
        guard stop.cause != .checkoutDiffers else { return facts.localHead.map { $0 != stop.head } ?? true }
        return isPresent(stop.kind, items: stop.items, facts) ?? true
    }

    /// Whether the pull request still shows that kind of trouble (of
    /// feedback, one of `items`); nil while that isn't known: GitHub
    /// computing `mergeable`, a run of the pull request's going, feedback
    /// not read.
    private static func isPresent(_ kind: Kind, items: [String], _ facts: Facts) -> Bool? {
        let pullRequest = facts.pullRequest
        switch kind {
        case .conflict:
            if pullRequest.mergeable == "UNKNOWN" { return nil }
            return pullRequest.mergeable == "CONFLICTING"
        case .ci:
            if !fixableFailures(pullRequest).isEmpty { return true }
            return hasRunGoing(pullRequest) ? nil : false
        case .feedback:
            return facts.feedback.map { $0.items.contains { items.contains($0.url) } }
        }
    }

    private enum Signal {
        /// Not now, and nothing else either.
        case hold(String)
        /// Not now; the next kinds may go.
        case wait(String)
        case ready(prompt: String, items: [String])
    }

    /// Nil when there is nothing of that kind a round may take.
    private static func signal(_ kind: Kind, _ entry: Entry, _ facts: Facts) -> Signal? {
        let pullRequest = facts.pullRequest
        switch kind {
        case .conflict:
            guard pullRequest.mergeable == "CONFLICTING" else { return nil }
            // No pull_request workflow runs on a conflict: no other round
            // would get its checks.
            guard let base = pullRequest.baseRefName, let remote = facts.baseRemote, isPlainName(base), isPlainName(remote)
            else { return .hold("no plain remote and base to merge") }
            return .ready(prompt: "PR #\(pullRequest.number) conflicts with \(base). Run `git fetch \(remote) \(base)`, "
                + "merge \(remote)/\(base) into this branch, resolve the conflicts, run the checks, commit and push.", items: [])
        case .ci:
            let runs = CIFailure.runs(of: fixableFailures(pullRequest), in: pullRequest)
            guard !runs.isEmpty, !entry.userFailures.contains(failureSignature(pullRequest)) else { return nil }
            if hasRunGoing(pullRequest) { return .wait("checks still run") }
            switch facts.triage {
            case .pending: return .wait("the triage reads the failure")
            // Rerunning it stays the user's.
            case .done(let verdict) where verdict.flakyReason != nil: return nil
            case .off, .done: break
            }
            guard let redSince = facts.redSince, facts.now - redSince >= ciGrace else { return .wait("the failure is new") }
            return .ready(prompt: CIFailure.fixPrompt(pullRequest: pullRequest.number, runs: runs), items: [])
        case .feedback:
            let items = (facts.feedback?.items ?? []).filter {
                takesRound($0) && $0.createdAt.timeIntervalSince1970 >= entry.since && !entry.handedFeedback.contains($0.url)
            }
            guard let newest = items.map(\.createdAt).max() else { return nil }
            guard facts.now - newest.timeIntervalSince1970 >= feedbackQuiet else { return .wait("feedback may still come") }
            return .ready(prompt: PRFeedback.addressPrompt(for: pullRequest, items: items) + " Commit and push the fixes.",
                          items: items.map(\.url))
        }
    }

    /// Review threads, and what people (not bots) write besides an
    /// approval: a bot's or an approval's summary asks for nothing.
    private static func takesRound(_ item: PRFeedback.Item) -> Bool {
        !item.isOutdated && (item.isThread || (!item.isBot && !item.isApproval))
    }

    /// The red checks a commit can fix.
    private static func fixableFailures(_ pullRequest: PRInfo) -> [ProjectBoard.Check] {
        CIFailure.redChecks(pullRequest).filter { $0.conclusion.map(fixableConclusions.contains) ?? false }
    }

    /// What tells one failure a round may take from the next: what the
    /// user's Why Failed records in `Entry.userFailures`.
    static func failureSignature(_ pullRequest: PRInfo) -> String {
        CITriage.signature(of: fixableFailures(pullRequest))
    }

    /// A run of the pull request's own still going: its failures may come
    /// back, or go.
    private static func hasRunGoing(_ pullRequest: PRInfo) -> Bool {
        CIFailure.ownRunResults(pullRequest).contains { $0.result == .pending }
    }

    /// A name GitHub or the checkout gave goes into a prompt only when plain.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && !name.contains("..")
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-/".contains($0)) }
    }
}

// What another build wrote differently is read on the side of typing less:
// an unreadable round still counts, settled; an unreadable start is the
// last change.

extension PRFollowUp.Round {
    static let unreadable = PRFollowUp.Round(kind: .ci, head: "", typedAt: 0, settledAt: 0)

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try values.decode(PRFollowUp.Kind.self, forKey: .kind),
            head: try values.decode(String.self, forKey: .head),
            typedAt: try values.decode(TimeInterval.self, forKey: .typedAt),
            items: values.lenient(.items, []),
            endedAt: values.lenient(.endedAt, nil),
            settledAt: values.lenient(.settledAt, nil)
        )
    }
}

extension PRFollowUp.Stop {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try values.decode(PRFollowUp.Kind.self, forKey: .kind),
            cause: try values.decode(Cause.self, forKey: .cause),
            head: try values.decode(String.self, forKey: .head),
            at: try values.decode(TimeInterval.self, forKey: .at),
            items: values.lenient(.items, [])
        )
    }
}

extension PRFollowUp.Entry {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            since: values.lenient(.since, values.lenient(.updatedAt, 0)),
            rounds: values.lenient(.rounds, [LenientValue<PRFollowUp.Round>]()).map { $0.value ?? .unreadable },
            handedFeedback: values.lenient(.handedFeedback, []),
            userFailures: values.lenient(.userFailures, []),
            stop: values.lenient(.stop, nil),
            updatedAt: values.lenient(.updatedAt, 0)
        )
    }
}
