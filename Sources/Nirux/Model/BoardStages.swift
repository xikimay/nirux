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
        /// On machines or on another pull request: checks run, the queue
        /// works on it, the one before it in its stack hasn't merged.
        case waiting
        /// At Merge, and nothing refuses it.
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
        /// Reviews, for a pull request with no task here: nothing can
        /// tell whether one ran.
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
        /// Nil for a task without a repository: "no pull request".
        var rail: Rail?
        var phrase: Phrase
        /// "#52", "#53 · 2/3", "no PR yet"; empty without a repository.
        var pullRequest: String
        /// "12 min": how long its turn or its checks have run, else since
        /// its last activity. Empty where time says nothing.
        var time: String
    }
}

// MARK: - What a line is derived from

extension BoardStages {
    /// What the task's agents do, as its sidebar row reads them.
    enum Activity: Equatable, Sendable {
        /// An agent waits for the user: "a question", the command to allow.
        case needsYou(String)
        /// An agent stopped: "Stopped on an API error".
        case failed(String)
        /// An agent works, since when if known.
        case working(since: TimeInterval?)
        /// At its prompt, or no agent. `note` is what it waits for
        /// without needing the user: "Asking Lead", "Paused".
        case idle(note: String? = nil)
    }

    /// The pull request's checks as the merge queue counts them: every
    /// required check green and none red is `passed`.
    enum Checks: Equatable, Sendable {
        /// A check runs, or a required one hasn't reported yet; since the
        /// oldest of those that run started.
        case pending(since: TimeInterval?)
        /// The red checks, by name.
        case failed([String])
        case passed
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
        /// Its place in a stack (docs/pr-stacks.md).
        var stack: ProjectBoard.StackPlace?
    }

    /// What the running queue does with a pull request.
    enum QueueStep: Equatable, Sendable {
        /// Before its merge: "Updating branch", "Waiting for checks".
        case checks(String)
        /// "Merging", "Waiting for nightly".
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
        /// Its place in the queue's list, from 1: among the running
        /// queue's pull requests not merged yet, else in the next Start's.
        var order: Int?
        /// Nil while it waits its turn, or no queue runs.
        var step: QueueStep?
        var stop: QueueStop?
    }

    /// Everything one line is derived from.
    struct Facts: Equatable, Sendable {
        /// Its first workspace's id; a pull request's or a folder's own
        /// when it has none.
        var id: String
        var title: String
        /// The task it is listed under in the sidebar.
        var parentID: String?
        /// False for a task without a repository: no rail.
        var hasRepository = true
        /// False for a pull request with no worktree here: no agent, and
        /// no review Nirux could have seen.
        var hasTask = true
        var isArchived = false
        var activity: Activity = .idle()
        /// Each review pass's latest run, against the current HEAD.
        var reviews: ReviewBadges?
        var pullRequest: PullRequest?
        var queue = Queue()
        /// Where the task stands: the user's summary, else the last turn
        /// end's line.
        var statusLine: String?
        /// The user's, else the Lead's.
        var nextStep: String?
        var blocker: String?
        /// Why the red checks look flaky, when the triage said so.
        var flakyReason: String?
        var lastActivityAt: TimeInterval?
        /// Its merged pull request's worktree can be cleaned up.
        var offersCleanUp = false
    }

    /// What the Board asks of a task before it moves on. Constants today;
    /// built to become space settings.
    struct Rules: Equatable, Sendable {
        /// The review passes the Reviews station waits for.
        var requiredReviews: Set<ReviewPass> = [.codeReview]
        /// Each must have run on the current HEAD. Off: once a pass ran, a
        /// commit after it doesn't send the line back, since fixes always
        /// follow a review; the station's mark says the review is older.
        var reviewsMustBeOnHead = false
    }
}

// MARK: - Deriving a line

extension BoardStages {
    static func line(_ facts: Facts, rules: Rules = Rules(), now: TimeInterval) -> Line {
        let station = station(of: facts, rules: rules)
        let state = state(of: facts, at: station)
        return Line(
            id: facts.id,
            title: facts.title,
            station: station,
            state: state,
            rail: rail(of: facts, at: station, rules: rules),
            phrase: phrase(of: facts, at: station, rules: rules),
            pullRequest: pullRequestText(facts),
            time: time(of: facts, state: state, now: now)
        )
    }

    /// The first station not done, in order.
    /// - Code is done once a review pass ran (any pass, on any commit), or
    ///   the pull request is open and no longer a draft.
    /// - Reviews, once each required pass ran (on any commit, unless the
    ///   rules ask for the current HEAD) and the turn it started in is
    ///   over: a pass is recorded as it starts.
    /// - Checks, once the open pull request's checks passed.
    /// A pull request the running queue works on is where the queue has
    /// it: the user confirmed its head at Start, whatever its reviews.
    static func station(of facts: Facts, rules: Rules = Rules()) -> Station {
        guard facts.hasRepository else { return .code }
        guard let pullRequest = facts.pullRequest else {
            if !hasEnteredReview(facts) { return .code }
            return reviewsAreDone(facts, rules: rules) ? .checks : .reviews
        }
        if pullRequest.isMerged { return .merge }
        switch facts.queue.step {
        case .checks?: return .checks
        case .merge?: return .merge
        case nil: break
        }
        if pullRequest.isDraft, !hasEnteredReview(facts) { return .code }
        if !reviewsAreDone(facts, rules: rules) { return .reviews }
        return pullRequest.checks == .passed ? .merge : .checks
    }

    private static func hasEnteredReview(_ facts: Facts) -> Bool {
        facts.reviews?.runs.isEmpty == false
    }

    private static func reviewsAreDone(_ facts: Facts, rules: Rules) -> Bool {
        // Nothing to wait for where no review could be seen.
        facts.hasTask ? missingReviews(facts, rules: rules).isEmpty : true
    }

    /// The required passes that haven't run, or that still run, in the
    /// badges' order.
    private static func missingReviews(_ facts: Facts, rules: Rules) -> [ReviewPass] {
        ReviewPass.allCases.filter { pass in
            guard rules.requiredReviews.contains(pass) else { return false }
            guard let reviews = facts.reviews, let run = reviews.runs[pass] else { return true }
            if rules.reviewsMustBeOnHead, !reviews.isFresh(pass) { return true }
            if case .working(let since?) = facts.activity, run.at >= since { return true }
            return false
        }
    }

    /// The first that holds: an agent needs the user (never hidden, even
    /// once merged); the pull request merged; what its agents say (they
    /// stopped, they work); the queue working on it; what is wrong with
    /// the pull request (the last queue's stop, a conflict, a red check);
    /// a blocker; then what its station waits for.
    static func state(of facts: Facts, at station: Station) -> State {
        let pullRequest = facts.pullRequest
        if case .needsYou = facts.activity { return .needsYou }
        if pullRequest?.isMerged == true { return .merged }
        switch facts.activity {
        case .failed: return .failed
        case .working: return .working
        case .needsYou, .idle: break
        }
        guard let pullRequest else { return text(facts.blocker) == nil ? .idle : .blocked }
        if facts.queue.step != nil { return .waiting }
        if problem(of: pullRequest, facts: facts) != nil { return .failed }
        if text(facts.blocker) != nil { return .blocked }
        switch station {
        case .code, .reviews:
            return .idle
        case .checks:
            return .waiting
        case .merge:
            if pullRequest.stack?.parent != nil { return .waiting }
            return hold(on: pullRequest) == nil ? .ready : .idle
        }
    }

    static func rail(of facts: Facts, at station: Station, rules: Rules = Rules()) -> Rail? {
        guard facts.hasRepository else { return nil }
        let pullRequest = facts.pullRequest
        let isMerged = pullRequest?.isMerged == true
        let marks = Station.allCases.map { candidate -> Mark in
            if candidate == .reviews, !facts.hasTask { return .skipped }
            if candidate == station, !isMerged { return .current }
            guard isMerged || candidate < station else { return .ahead }
            return candidate == .reviews && reviewIsOlderThanHead(facts, rules: rules) ? .doneEarlier : .done
        }
        return Rail(marks: marks, queueOrder: isMerged || pullRequest == nil ? nil : facts.queue.order)
    }

    /// A required pass ran, on another commit than the current HEAD. Not
    /// while HEAD isn't known: every review would read as older.
    private static func reviewIsOlderThanHead(_ facts: Facts, rules: Rules) -> Bool {
        guard let reviews = facts.reviews, reviews.head != nil else { return false }
        return rules.requiredReviews.contains { reviews.runs[$0] != nil && !reviews.isFresh($0) }
    }

    /// What the line does at its station, in the order of `state`; at
    /// rest, the next step, where the task stands, else what the station
    /// waits for.
    static func phrase(of facts: Facts, at station: Station, rules: Rules = Rules()) -> Phrase {
        let pullRequest = facts.pullRequest
        if case .needsYou(let what) = facts.activity { return Phrase(text: "Needs you · \(what)") }
        if pullRequest?.isMerged == true {
            return facts.offersCleanUp ? Phrase(text: "Merged · \(Link.cleanUp.title)", link: .cleanUp) : Phrase(text: "Merged")
        }
        switch facts.activity {
        case .failed(let what): return Phrase(text: what)
        case .working: return Phrase(text: text(facts.statusLine) ?? "Working")
        case .needsYou, .idle: break
        }
        if let pullRequest {
            switch facts.queue.step {
            case .checks(let label)?, .merge(let label)?: return Phrase(text: label)
            case nil: break
            }
            if let problem = problem(of: pullRequest, facts: facts) { return problem }
        }
        if case .idle(let note?) = facts.activity { return Phrase(text: note) }
        if let blocker = text(facts.blocker) { return Phrase(text: "Blocked · \(blocker)") }
        if let pullRequest {
            // Whatever its station: nothing lands on a merged branch.
            if let retarget = retarget(pullRequest) { return retarget }
            let parent = pullRequest.stack?.parent
            switch station {
            case .checks:
                return Phrase(text: "Checks running" + (parent.map { " · lands after #\($0)" } ?? ""))
            case .merge:
                if let parent { return Phrase(text: "Lands after #\(parent)") }
                if let hold = hold(on: pullRequest) { return hold }
                return Phrase(text: facts.hasTask ? "Ready · reviews done, checks green" : "Ready · checks green")
            case .code, .reviews:
                break
            }
        }
        if let next = text(facts.nextStep) { return Phrase(text: "Next · \(next)") }
        if let line = text(facts.statusLine) { return Phrase(text: line) }
        if facts.isArchived { return Phrase(text: "Archived") }
        switch station {
        case .code:
            if pullRequest?.isDraft == true { return Phrase(text: "Draft") }
            return Phrase(text: facts.lastActivityAt == nil ? "No activity yet" : "Idle")
        case .reviews:
            let missing = missingReviews(facts, rules: rules).map { $0.displayName.lowercased() }.joined(separator: ", ")
            let ranEarlier = rules.reviewsMustBeOnHead && reviewIsOlderThanHead(facts, rules: rules)
            return Phrase(text: "No \(missing) " + (ranEarlier ? "on this commit" : "yet"))
        case .checks, .merge: return Phrase(text: "No pull request yet")
        }
    }

    /// "#52", "#53 · 2/3" in a straight stack, "#53 · on #52" in a fork.
    static func pullRequestText(_ facts: Facts) -> String {
        guard facts.hasRepository else { return "" }
        guard let pullRequest = facts.pullRequest else { return "no PR yet" }
        return (["#\(pullRequest.number)"] + (pullRequest.stack?.label.map { [$0] } ?? [])).joined(separator: " · ")
    }

    /// How long the turn has run while an agent works, the checks while
    /// the line waits for them, else since the last activity. Nothing for
    /// a line that is ready, blocked, merged or in the queue's hands: no
    /// clock of its own runs there.
    static func time(of facts: Facts, state: State, now: TimeInterval) -> String {
        let since: TimeInterval?
        switch state {
        case .ready, .blocked, .merged:
            return ""
        case .working:
            if case .working(let start) = facts.activity { since = start } else { since = nil }
        case .waiting:
            if facts.queue.step != nil { return "" }
            if case .pending(let start?)? = facts.pullRequest?.checks { since = start } else { since = facts.lastActivityAt }
        case .needsYou, .failed, .idle:
            since = facts.lastActivityAt
        }
        return since.map { duration(now - $0) } ?? ""
    }

    /// "now", "12 min", "3 h", "2 d".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes < 24 * 60 ? "\(minutes / 60) h" : "\(minutes / (24 * 60)) d"
    }

    // MARK: The pull request

    /// What is wrong with an open pull request that nobody works on: the
    /// last queue stopped on it, it conflicts with its base, a check is
    /// red. Only a likely flake says more than which checks.
    private static func problem(of pullRequest: PullRequest, facts: Facts) -> Phrase? {
        if let stop = facts.queue.stop, stop.isProblem {
            return Phrase(text: "Queue stopped: \(stop.label)", detail: stop.message)
        }
        if pullRequest.isConflicting { return Phrase(text: "Conflicts with \(pullRequest.base)") }
        guard case .failed(let names) = pullRequest.checks else { return nil }
        if let reason = text(facts.flakyReason) { return Phrase(text: "Checks failed · likely flaky", detail: reason) }
        return Phrase(text: "Checks failed" + (names.isEmpty ? "" : ": " + names.joined(separator: ", ")))
    }

    /// Its base is the branch of a merged pull request: the link bases it
    /// on that one's base (docs/pr-stacks.md).
    private static func retarget(_ pullRequest: PullRequest) -> Phrase? {
        pullRequest.stack?.mergedBase.map { merged in
            let link = Link.retarget(number: pullRequest.number, onto: merged.onto)
            return Phrase(text: "Base #\(merged.number) merged · \(link.title)", link: link)
        }
    }

    /// Why a pull request whose checks passed can't merge yet, when the
    /// user is the one to move it; nil when nothing holds it. (One on a
    /// merged base targets another branch than the base.)
    private static func hold(on pullRequest: PullRequest) -> Phrase? {
        if pullRequest.isDraft { return Phrase(text: "Draft · checks green") }
        return pullRequest.isOnBaseBranch ? nil : Phrase(text: "Targets \(pullRequest.base)")
    }

    /// Trimmed, on one line; nil when empty.
    private static func text(_ value: String?) -> String? {
        let words = (value ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
