import Foundation

/// The Board as stages (docs/board-stages.md): where each task of a space
/// stands on the way to its base branch, and what comes next.
/// Every task goes through the same four stations, Code, Reviews, Checks
/// and Merge; its line says which one it is at, in what state, and what it
/// does there.
///
/// This file derives one line from what Nirux already knows of a task
/// (`Facts`): its agents, its review badges, its pull request, its checks
/// and the merge queue. It is pure: whoever draws the Board fills the facts.
enum BoardStages {}

// MARK: - What a line says

extension BoardStages {
    /// The stations, in the order a task goes through them.
    enum Station: Int, CaseIterable, Comparable, Sendable {
        case code, reviews, checks, merge

        static func < (lhs: Station, rhs: Station) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// What the line's dot and its current station say, by colour. Amber
    /// is `needsYou` and nothing else.
    enum State: Equatable, Sendable {
        /// An agent waits for the user.
        case needsYou
        /// An agent stopped, a check is red, the pull request conflicts,
        /// the queue stopped on it.
        case failed
        case working
        /// A blocker is set: nothing moves until it goes.
        case blocked
        /// On something else than the user: checks run, the queue works
        /// on it, the one before it in its stack hasn't merged, its agent
        /// asked its parent.
        case waiting
        /// At Merge, and nothing holds it.
        case ready
        case merged
        /// Nothing goes on: its agent is at its prompt.
        case idle
    }

    /// A station as drawn: filled, larger in the state's colour, hollow,
    /// filled with a ring, or left out.
    enum Mark: Equatable, Sendable {
        case done, current, ahead
        /// Reviews, done by a review that ran before the last commits:
        /// filled, with a ring.
        case doneEarlier
        /// Reviews, where none is waited for or none was seen: a pull
        /// request with no task here, one the queue took or that merged
        /// without the reviews that count, rules that ask for none.
        case skipped
    }

    struct Rail: Equatable, Sendable {
        /// One per station, in order.
        var marks: [Mark]
        /// The pull request's place in the queue's list, from 1: the
        /// number on the Merge station.
        var queueOrder: Int?
    }

    /// What ends a phrase as a link: the one click that moves the line on.
    enum Link: Equatable, Sendable {
        /// Its base's pull request merged: base it on that one's base.
        case retarget(number: Int, onto: String)
        /// Its pull request merged: clean up its worktree.
        case cleanUp

        var title: String {
            switch self {
            case .retarget(_, let onto): return "Retarget to \(onto)"
            case .cleanUp: return "Clean up"
            }
        }
    }

    struct Phrase: Equatable, Sendable {
        var text: String
        /// `text` ends with its title.
        var link: Link?
        /// What the line can't hold, for its tooltip.
        var detail: String?
    }

    struct Line: Equatable, Sendable {
        let id: String
        var title: String
        /// The first station not done; Merge once merged.
        var station: Station
        var state: State
        /// Nil for a task without a repository, which has no stations.
        var rail: Rail?
        var phrase: Phrase
        /// "#52", "#53 · 2/3", "no PR yet"; empty without a repository.
        var pullRequest: String
        /// What the line's clock counts from: its turn's start while an
        /// agent works, its checks' while it waits for them, else its last
        /// activity. Nil where no clock of its own runs: a line that is
        /// ready, blocked, merged or in the queue's hands.
        var since: TimeInterval?
    }
}

// MARK: - What a line is derived from

extension BoardStages {
    /// What the task's agents do, the most pressing first, as its sidebar
    /// row reads them. Not `ProjectBoard.AgentState`, which the merge
    /// queue reads: there only a dialog waits, here a turn that ended on a
    /// question does too.
    enum Activity: Equatable, Sendable {
        /// An agent waits for the user: "a question", the command to allow.
        case needsYou(String)
        /// An agent stopped: "Stopped on an API error".
        case failed(String)
        /// An agent asked the agent that started it, named here, and
        /// waits for its answer.
        case asking(String)
        /// An agent works, since when if known.
        case working(since: TimeInterval?)
        /// At its prompt, or no agent.
        case idle
    }

    /// The pull request's checks as the merge queue counts them.
    enum Checks: Equatable, Sendable {
        /// A check runs, or a required one hasn't reported yet (`missing`,
        /// by name: a check not started, or a name no check has); since
        /// the oldest of those that run started, when one did.
        case pending(since: TimeInterval?, missing: [String] = [])
        /// By name: the red checks, and the required ones that ended
        /// without passing (skipped, neutral), which no wait turns green.
        case failed([String])
        /// Every required check is green, none is red, and with no
        /// required check none still runs.
        case passed
        /// No check at all, and none required: nothing to wait for.
        case none

        /// Nothing in them holds a merge.
        var allowMerge: Bool { self == .passed || self == .none }
    }

    /// What can be done with a merged pull request's worktree.
    enum CleanUp: Equatable, Sendable {
        /// "Clean up" runs Clean Up Worktree….
        case offered
        /// A clean-up is being checked, confirmed or run.
        case running
    }

    /// What GitHub still asks of a green pull request, as the sidebar's
    /// "Ready to merge" counts it.
    enum ReviewRequest: Equatable, Sendable {
        case changesRequested, reviewRequired
        /// Review comments wait to be dealt with (docs/pr-feedback-inbox.md).
        case feedback

        var text: String {
            switch self {
            case .changesRequested: return "Changes requested"
            case .reviewRequired: return "Review required"
            case .feedback: return "Feedback to answer"
            }
        }
    }

    struct PullRequest: Equatable, Sendable {
        var number: Int
        var isMerged = false
        var isDraft = false
        var isConflicting = false
        /// The branch it targets.
        var base: String
        /// That branch is the repository's base branch: the queue takes
        /// no other.
        var isOnBaseBranch = true
        var checks: Checks = .pending(since: nil)
        var reviewRequest: ReviewRequest?
        /// Its place in a stack (docs/pr-stacks.md).
        var stack: ProjectBoard.StackPlace?
    }

    /// What the running queue does with a pull request.
    enum QueueStep: Equatable, Sendable {
        /// Before its merge: "Updating branch", "Waiting for checks".
        case checks(String)
        /// "Merging", then "Waiting for nightly" once it merged.
        case merge(String)
    }

    /// Why the last queue stopped on a pull request.
    struct QueueStop: Equatable, Sendable {
        /// In a word or two: "changed".
        var label: String
        var message: String
        /// Not Stop pressed, nor a dry run reaching its first change.
        var isProblem: Bool
    }

    struct Queue: Equatable, Sendable {
        /// Its place in the queue's list, from 1: in the running queue's
        /// as the queue counts it ("3 of 7"), else in the next Start's.
        var order: Int?
        /// Nil while it waits its turn, or no queue runs.
        var step: QueueStep?
        /// While it still stands: whoever fills the facts drops it once
        /// the pull request's head moved.
        var stop: QueueStop?
    }

    /// Everything one line is derived from.
    struct Facts: Equatable, Sendable {
        /// Its first workspace's id; a pull request's or a folder's own
        /// when it has none.
        var id: String
        var title: String
        /// False for a task without a repository: no rail.
        var hasRepository = true
        /// False for a pull request with no workspace here: no agent, and
        /// no review Nirux could have seen.
        var hasTask = true
        var isArchived = false
        var activity: Activity = .idle
        /// Each review pass's latest run, against the current HEAD.
        var reviews: ReviewBadges?
        /// The passes whose turn isn't over: a pass is recorded as it starts.
        var reviewsInFlight: Set<ReviewPass> = []
        var pullRequest: PullRequest?
        var queue = Queue()
        /// Where the task stood when its last turn ended: the user's
        /// summary, else that turn end's line. Said at rest only: while an
        /// agent works, it is about the turn before.
        var statusLine: String?
        /// The user's, else the Lead's.
        var nextStep: String?
        var blocker: String?
        /// Why the red checks look flaky, when the triage said so.
        var flakyReason: String?
        var lastActivityAt: TimeInterval?
        /// Its merged pull request's worktree is still there.
        var cleanUp: CleanUp?
    }

    /// What the Board asks of a task before it moves on. Constants today;
    /// built to become space settings.
    struct Rules: Equatable, Sendable {
        /// The review passes the Reviews station waits for. None: the
        /// rail has no Reviews station.
        var requiredReviews: Set<ReviewPass> = [.codeReview]
        /// Each must have run on the current HEAD. Off: once a pass ran, a
        /// commit after it doesn't send the line back, since fixes always
        /// follow a review; the station's mark says the review is older.
        var reviewsMustBeOnHead = false
    }
}

// MARK: - Deriving a line

extension BoardStages {
    static func line(_ facts: Facts, rules: Rules = Rules()) -> Line {
        let station = station(of: facts, rules: rules)
        let reading = reading(of: facts, at: station, rules: rules)
        return Line(
            id: facts.id,
            title: facts.title,
            station: station,
            state: reading.state,
            rail: rail(of: facts, at: station, rules: rules),
            phrase: reading.phrase,
            pullRequest: pullRequestText(facts),
            since: reading.since
        )
    }

    /// The first station not done, in order.
    /// - Code is done once a required review pass ran (on any commit), or
    ///   the pull request is open and no longer a draft. Not any pass: a
    ///   prompt that only names an adversarial review records one.
    /// - Reviews, once each required pass ran (on any commit, unless the
    ///   rules ask for the current HEAD) and its turn is over. A pass
    ///   started again is waited for again.
    /// - Checks, once the open pull request's checks passed.
    /// A pull request the running queue works on is where the queue has
    /// it: the user confirmed its head at Start, whatever its reviews.
    private static func station(of facts: Facts, rules: Rules) -> Station {
        guard facts.hasRepository else { return .code }
        guard let pullRequest = facts.pullRequest else {
            if !hasEnteredReview(facts, rules: rules) { return .code }
            return reviewsAreDone(facts, rules: rules) ? .checks : .reviews
        }
        switch facts.queue.step {
        case .checks?: return .checks
        case .merge?: return .merge
        case nil: break
        }
        if pullRequest.isMerged { return .merge }
        if pullRequest.isDraft, !hasEnteredReview(facts, rules: rules) { return .code }
        if !reviewsAreDone(facts, rules: rules) { return .reviews }
        return pullRequest.checks.allowMerge ? .merge : .checks
    }

    private static func rail(of facts: Facts, at station: Station, rules: Rules) -> Rail? {
        guard facts.hasRepository else { return nil }
        let pullRequest = facts.pullRequest
        // Merged, and the queue is through with it: nothing is current.
        let isSettled = pullRequest?.isMerged == true && facts.queue.step == nil && facts.queue.stop?.isProblem != true
        let gaps = reviewGaps(facts, rules: rules)
        let ranReviews = !gaps.contains { $0.gap != .running }
        let marks = Station.allCases.map { candidate -> Mark in
            let isPast = isSettled || candidate < station
            if candidate == .reviews {
                if !facts.hasTask || rules.requiredReviews.isEmpty || (isPast && !ranReviews) { return .skipped }
                if isPast, reviewIsOlderThanHead(facts, rules: rules) { return .doneEarlier }
            }
            if isPast { return .done }
            return candidate == station ? .current : .ahead
        }
        return Rail(marks: marks, queueOrder: pullRequest.flatMap { $0.isMerged ? nil : facts.queue.order })
    }

    /// "#52", "#53 · 2/3" in a straight stack, "#53 · on #52" in a fork.
    private static func pullRequestText(_ facts: Facts) -> String {
        guard facts.hasRepository else { return "" }
        guard let pullRequest = facts.pullRequest else { return "no PR yet" }
        return (["#\(pullRequest.number)"] + (pullRequest.stack?.label.map { [$0] } ?? [])).joined(separator: " · ")
    }

    // MARK: State and phrase

    /// A line's state, its phrase and what its clock counts from: one
    /// answer, so the three never disagree.
    private struct Reading {
        var state: State
        var phrase: Phrase
        var since: TimeInterval?

        init(_ state: State, _ text: String, since: TimeInterval? = nil, link: Link? = nil, detail: String? = nil) {
            self.state = state
            phrase = Phrase(text: text, link: link, detail: detail)
            self.since = since
        }
    }

    /// The first that holds, in the sidebar row's order:
    /// 1. what its agents say: they need the user, they stopped, they work;
    /// 2. the queue working on its pull request;
    /// 3. what is wrong with it now (a conflict, a red check), then the
    ///    last queue's stop: the present comes before what stopped a queue;
    /// 4. its agent asking its parent; a blocker;
    /// 5. its pull request merged, or on a merged base;
    /// 6. what its station waits for; at rest, the next step, where the
    ///    task stands, else what the station needs.
    private static func reading(of facts: Facts, at station: Station, rules: Rules) -> Reading {
        let last = facts.lastActivityAt
        switch facts.activity {
        case .needsYou(let what):
            return Reading(.needsYou, text(what).map { "Needs you · \($0)" } ?? "Needs you", since: last)
        case .failed(let what):
            return Reading(.failed, text(what) ?? "Stopped", since: last)
        case .working(let since):
            return Reading(.working, "Working", since: since)
        case .asking, .idle:
            break
        }
        let pullRequest = facts.pullRequest
        if let pullRequest {
            switch facts.queue.step {
            case .checks(let label)?, .merge(let label)?: return Reading(.waiting, text(label) ?? "In the queue")
            case nil: break
            }
            if !pullRequest.isMerged, let problem = problem(of: pullRequest, flakyReason: text(facts.flakyReason)) {
                return Reading(.failed, problem.text, since: last, detail: problem.detail)
            }
            if let stop = facts.queue.stop, stop.isProblem {
                return Reading(.failed, "Queue stopped: \(stop.label)", since: last, detail: stop.message)
            }
        }
        if case .asking(let parent) = facts.activity {
            return Reading(.waiting, text(parent).map { "Asking \($0)" } ?? "Asking its parent", since: last)
        }
        if let blocker = text(facts.blocker) { return Reading(.blocked, "Blocked · \(blocker)") }
        if let pullRequest {
            if pullRequest.isMerged {
                switch facts.cleanUp {
                case .offered?: return Reading(.merged, "Merged · \(Link.cleanUp.title)", link: .cleanUp)
                case .running?: return Reading(.merged, "Merged · cleaning up…")
                case nil: return Reading(.merged, "Merged")
                }
            }
            // Whatever its station: nothing lands on a merged branch.
            if let merged = pullRequest.stack?.mergedBase {
                let link = Link.retarget(number: pullRequest.number, onto: merged.onto)
                return Reading(.idle, "Base #\(merged.number) merged · \(link.title)", since: last, link: link)
            }
            let parent = pullRequest.stack?.parent
            switch station {
            case .checks:
                guard case .pending(let since, let missing) = pullRequest.checks else { break }
                let checks = missing.isEmpty ? "Checks running" : "No \(missing.joined(separator: ", ")) run yet"
                return Reading(.waiting, checks + (parent.map { " · lands after #\($0)" } ?? ""), since: since)
            case .merge:
                // What it passed, as far as anything was asked of it.
                let reviewed = !rules.requiredReviews.isEmpty && reviewGaps(facts, rules: rules).isEmpty
                let passed = [reviewed ? "reviews done" : nil, pullRequest.checks == .passed ? "checks green" : nil]
                    .compactMap { $0 }.joined(separator: ", ")
                let with = { (word: String) in passed.isEmpty ? word : "\(word) · \(passed)" }
                if let parent { return Reading(.waiting, "Lands after #\(parent)", since: last) }
                if pullRequest.isDraft { return Reading(.idle, with("Draft"), since: last) }
                if !pullRequest.isOnBaseBranch { return Reading(.idle, "Targets \(pullRequest.base)", since: last) }
                if let request = pullRequest.reviewRequest { return Reading(.idle, request.text, since: last) }
                return Reading(.ready, with("Ready"))
            case .code, .reviews:
                break
            }
        }
        return Reading(.idle, atRest(facts, at: station, rules: rules), since: last)
    }

    /// What an idle line says: the next step, where the task stands, else
    /// what its station needs.
    private static func atRest(_ facts: Facts, at station: Station, rules: Rules) -> String {
        if let next = text(facts.nextStep) { return "Next · \(next)" }
        if let line = text(facts.statusLine) { return line }
        if facts.isArchived { return "Archived" }
        switch station {
        case .code:
            if facts.pullRequest?.isDraft == true { return "Draft" }
            return facts.lastActivityAt == nil ? "No activity yet" : "Idle"
        case .reviews:
            let gaps = reviewGaps(facts, rules: rules)
            let names = { (gap: ReviewGap) in
                gaps.filter { $0.gap == gap }.map { $0.pass.displayName.lowercased() }.joined(separator: ", ")
            }
            if gaps.contains(where: { $0.gap == .never }) { return "No \(names(.never)) yet" }
            return gaps.contains { $0.gap == .earlier } ? "No \(names(.earlier)) on this commit" : "Review running"
        case .checks, .merge:
            return "No pull request yet"
        }
    }

    /// What is wrong with an open pull request that nobody works on: it
    /// conflicts with its base, a check is red. Only a likely flake says
    /// more than which checks.
    private static func problem(of pullRequest: PullRequest, flakyReason: String?) -> (text: String, detail: String?)? {
        if pullRequest.isConflicting { return ("Conflicts with \(pullRequest.base)", nil) }
        guard case .failed(let names) = pullRequest.checks else { return nil }
        if let flakyReason { return ("Checks failed · likely flaky", flakyReason) }
        return ("Checks failed" + (names.isEmpty ? "" : ": " + names.joined(separator: ", ")), nil)
    }

    // MARK: Reviews

    /// Why a required pass doesn't count yet.
    private enum ReviewGap {
        /// It never ran here.
        case never
        /// It ran on another commit, and the rules ask for the current HEAD.
        case earlier
        /// Its turn isn't over.
        case running
    }

    /// The required passes that don't count yet, in the badges' order.
    /// While HEAD isn't known, no pass reads as run on another commit:
    /// the line doesn't move back for a git context not read yet.
    private static func reviewGaps(_ facts: Facts, rules: Rules) -> [(pass: ReviewPass, gap: ReviewGap)] {
        ReviewPass.allCases.compactMap { pass in
            guard rules.requiredReviews.contains(pass) else { return nil }
            guard let reviews = facts.reviews, reviews.runs[pass] != nil else { return (pass, .never) }
            if rules.reviewsMustBeOnHead, reviews.head != nil, !reviews.isFresh(pass) { return (pass, .earlier) }
            return facts.reviewsInFlight.contains(pass) ? (pass, .running) : nil
        }
    }

    private static func hasEnteredReview(_ facts: Facts, rules: Rules) -> Bool {
        rules.requiredReviews.contains { facts.reviews?.runs[$0] != nil }
    }

    private static func reviewsAreDone(_ facts: Facts, rules: Rules) -> Bool {
        // Nothing to wait for where no review could be seen.
        facts.hasTask ? reviewGaps(facts, rules: rules).isEmpty : true
    }

    /// A required pass ran on another commit than the current HEAD.
    private static func reviewIsOlderThanHead(_ facts: Facts, rules: Rules) -> Bool {
        guard let reviews = facts.reviews, reviews.head != nil else { return false }
        return rules.requiredReviews.contains { reviews.runs[$0] != nil && !reviews.isFresh($0) }
    }

    /// Trimmed, on one line; nil when empty. The facts come as their
    /// sources hold them: a command to allow may span lines.
    private static func text(_ value: String?) -> String? {
        let words = (value ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
