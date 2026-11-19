import Foundation

/// Nirux keeps a task's open pull request mergeable while its Claude sits
/// idle (docs/design/pr-follow-up.md): it types the fix for a conflict with
/// the base, a failed check that isn't a likely flake, or new review
/// feedback, `maxRounds` rounds per pull request at most, then hands the
/// pull request to the user. This file decides; the shell types the
/// prompts and keeps each pull request's `Entry` (`PRFollowUpStore`).
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
    static let unpushedLimit: TimeInterval = 10 * 60

    /// A prompt Nirux typed.
    struct Round: Codable, Equatable, Sendable {
        let kind: Kind
        /// The pull request's head when it was typed.
        let head: String
        let typedAt: TimeInterval
        /// The feedback it handed, by URL.
        var items: [String] = []
        /// When the turn that took it ended. Nil while it runs, or when the
        /// Nirux that typed it quit first.
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
            /// A round left commits that aren't on the pull request.
            case unpushed
        }

        let kind: Kind
        let cause: Cause
        let head: String
        let at: TimeInterval
    }

    /// One pull request's follow-up.
    struct Entry: Codable, Equatable, Sendable {
        var rounds: [Round] = []
        /// Feedback handed already, by a round or the user's Address: never
        /// handed again.
        var handedFeedback: [String] = []
        /// Failures (`CITriage.signature`) the user's Why Failed took.
        var userFailures: [String] = []
        var stop: Stop?
        /// When it last changed (`PRFollowUpStore.update`).
        var updatedAt: TimeInterval = 0

        mutating func record(_ round: Round) {
            rounds.append(round)
            handedFeedback += round.items.filter { !handedFeedback.contains($0) }
        }

        /// The turn that took the last round ended at `time`.
        mutating func endRound(at time: TimeInterval) {
            guard let last = rounds.indices.last, rounds[last].endedAt == nil, rounds[last].typedAt <= time else { return }
            rounds[last].endedAt = time
        }
    }

    /// What a decision reads besides the entry.
    struct Facts {
        var pullRequest: PRInfo
        var feedback: PRFeedback?
        var triage: Triage = .off
        /// When Nirux first saw red the checks that are red now.
        var redSince: TimeInterval?
        var localHead: String?
        var hasTrackedChanges = false
        var isInMergeQueue = false
        /// When the read that gave `pullRequest` started.
        var readAt: TimeInterval?
        /// Why the agent's prompt isn't free; nil when it is.
        var agentRefusal: String?
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
        /// Type `prompt`, then `Entry.record` the round.
        case type(Round, prompt: String)
    }

    /// What to do about the pull request now. Sets or clears
    /// `entry.stop`, and settles the last round.
    static func next(_ entry: inout Entry, _ facts: Facts) -> Action {
        let pullRequest = facts.pullRequest
        guard pullRequest.state.uppercased() == "OPEN", let head = pullRequest.headRefOid else { return .none }
        // It reruns checks and stops on its own.
        if facts.isInMergeQueue { return .wait("the merge queue holds it") }
        if let stop = entry.stop {
            if stop.head == head, holds(stop, facts) { return .wait("stopped: \(stop.cause.rawValue)") }
            entry.stop = nil
        }
        if let wait = settleLastRound(&entry, facts, head: head) { return wait }
        for kind in Kind.allCases {
            switch signal(kind, entry, facts) {
            case nil:
                continue
            case .wait(let why)?:
                return .wait(why)
            case .ready(let prompt, let items)?:
                // Else the read may be older than a push.
                guard facts.localHead == head else { return .wait("the checkout's HEAD isn't the pull request's") }
                guard entry.rounds.count < maxRounds else {
                    entry.stop = Stop(kind: kind, cause: .rounds, head: head, at: facts.now)
                    return .wait("stopped: rounds")
                }
                if facts.hasTrackedChanges { return .wait("tracked files changed") }
                if let refusal = facts.agentRefusal { return .wait(refusal) }
                let round = Round(kind: kind, head: head, typedAt: facts.now, items: items)
                return .type(round, prompt: prompt + " (Nirux follow-up, round \(entry.rounds.count + 1) of \(maxRounds).)")
            }
        }
        return .none
    }

    /// Waits for the last round's turn to end and a read after it, then
    /// stops the pull request when the round moved nothing. Nil once it's
    /// settled.
    private static func settleLastRound(_ entry: inout Entry, _ facts: Facts, head: String) -> Action? {
        guard let index = entry.rounds.indices.last, entry.rounds[index].settledAt == nil else { return nil }
        let round = entry.rounds[index]
        guard let endedAt = round.endedAt ?? (round.typedAt < facts.trackedSince ? facts.trackedSince : nil)
        else { return .wait("its round runs") }
        guard let readAt = facts.readAt, readAt >= endedAt + readSettle else { return .wait("no read since its round") }
        let cause: Stop.Cause?
        if facts.localHead != head {
            guard facts.now - endedAt >= unpushedLimit else { return .wait("its round's commits aren't on the pull request yet") }
            cause = .unpushed
        } else {
            cause = round.head == head && isPresent(round.kind, items: round.items, facts) ? .nothingPushed : nil
        }
        entry.rounds[index].settledAt = facts.now
        guard let cause else { return nil }
        entry.stop = Stop(kind: round.kind, cause: cause, head: head, at: facts.now)
        return .wait("stopped: \(cause.rawValue)")
    }

    private static func holds(_ stop: Stop, _ facts: Facts) -> Bool {
        guard stop.cause != .unpushed else { return facts.localHead != stop.head }
        // GitHub computes it again after each push to the base.
        if stop.kind == .conflict, facts.pullRequest.mergeable == "UNKNOWN" { return true }
        return isPresent(stop.kind, items: nil, facts)
    }

    /// Whether the pull request still shows that kind of trouble: of the
    /// feedback, one of `items` (nil: any) still listed.
    private static func isPresent(_ kind: Kind, items: [String]?, _ facts: Facts) -> Bool {
        switch kind {
        case .conflict: return facts.pullRequest.mergeable == "CONFLICTING"
        case .ci: return !CIFailure.redChecks(facts.pullRequest).isEmpty
        case .feedback:
            let listed = facts.feedback?.items ?? []
            return items.map { handed in listed.contains { handed.contains($0.url) } } ?? !listed.isEmpty
        }
    }

    private enum Signal {
        case wait(String)
        case ready(prompt: String, items: [String])
    }

    /// Nil when there is nothing of that kind a round may take.
    private static func signal(_ kind: Kind, _ entry: Entry, _ facts: Facts) -> Signal? {
        let pullRequest = facts.pullRequest
        switch kind {
        case .conflict:
            guard pullRequest.mergeable == "CONFLICTING",
                  let base = pullRequest.baseRefName, isPlainBranchName(base)
            else { return nil }
            return .ready(prompt: "PR #\(pullRequest.number) conflicts with \(base). Run `git fetch origin \(base)`, "
                + "merge origin/\(base) into this branch, resolve the conflicts, run the checks, commit and push.", items: [])
        case .ci:
            let red = CIFailure.redChecks(pullRequest)
            let runs = CIFailure.runs(pullRequest)
            guard !red.isEmpty, !runs.isEmpty, !entry.userFailures.contains(CITriage.signature(of: red)) else { return nil }
            if pullRequest.checks.contains(where: { $0.result == .pending }) { return .wait("checks still run") }
            switch facts.triage {
            case .pending: return .wait("the triage reads the failure")
            // Rerunning it stays the user's.
            case .done(let verdict) where verdict.flakyReason != nil: return nil
            case .off, .done: break
            }
            guard let redSince = facts.redSince, facts.now - redSince >= ciGrace else { return .wait("the failure is new") }
            return .ready(prompt: CIFailure.fixPrompt(pullRequest: pullRequest.number, runs: runs), items: [])
        case .feedback:
            let items = (facts.feedback?.items ?? []).filter { !$0.isOutdated && !entry.handedFeedback.contains($0.url) }
            guard let newest = items.map(\.createdAt).max() else { return nil }
            guard facts.now - newest.timeIntervalSince1970 >= feedbackQuiet else { return .wait("feedback may still come") }
            return .ready(prompt: PRFeedback.addressPrompt(for: pullRequest, items: items) + " Commit and push the fixes.",
                          items: items.map(\.url))
        }
    }

    /// A base branch name GitHub gave goes into a prompt only when plain.
    static func isPlainBranchName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && !name.contains("..")
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-/".contains($0)) }
    }
}
