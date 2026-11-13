import Foundation

/// The Board as stages (docs/design/board-stages.md): where each task of a space
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
    /// or left out.
    enum Mark: Equatable, Sendable {
        case done, current, ahead
        /// Reviews, where none is waited for or none was seen: a pull
        /// request with no task here, one the queue took or that merged
        /// without the reviews that count, rules that ask for none.
        case skipped
    }

    struct Rail: Equatable, Sendable {
        /// One per station, in order.
        var marks: [Mark]
        /// A review that counts ran on another commit than HEAD, an
        /// earlier one unless HEAD moved back: said in the Reviews
        /// station's tooltip, not drawn, since fixes follow nearly every
        /// review.
        var reviewIsOlderThanHead = false
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
            case .retarget(_, let onto): return "Retarget to \(BoardStages.branch(onto))"
            case .cleanUp: return "Clean up"
            }
        }

        /// What a click does, for the link's tooltip.
        var hint: String {
            switch self {
            case .retarget(let number, let onto):
                return "Bases #\(number) on \(BoardStages.branch(onto)), as GitHub does when a merged branch is deleted"
            case .cleanUp:
                return "Checks the worktree, then asks what goes"
            }
        }
    }

    struct Phrase: Equatable, Sendable {
        var text: String
        /// `text` ends with its title. Nil where a click would do
        /// nothing: the words stay, and `detail` says why.
        var link: Link?
        /// What the line can't hold, for its tooltip.
        var detail: String?

        /// The words before the link, for whoever draws the link apart:
        /// "Merged ·". Nil without a link.
        var wordsBeforeLink: String? {
            guard let link, text.hasSuffix(link.title) else { return nil }
            return String(text.dropLast(link.title.count)).trimmingCharacters(in: .whitespaces)
        }
    }

    /// What a click on a line's Merge station changes in the next Start's
    /// list, which stays the user's.
    struct QueueOffer: Equatable, Sendable {
        enum Change: Equatable, Sendable {
            case add, remove
        }

        var change: Change
        /// The pull request it is about.
        var number: Int
        /// Why a click changes nothing: the pull request can't join, or
        /// the list can't change for now.
        var blocked: String?

        var title: String { change == .add ? "Add to Queue" : "Remove from Queue" }
    }

    /// How a stopped agent of a task can go on, as the sidebar offers it.
    struct Resume: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// Its turn stopped on an error: "continue" is typed into it.
            case afterError
            /// It exited in the middle of a turn: its conversation is
            /// opened again.
            case afterExit
        }

        var kind: Kind
        /// The agent's column, in the task's workspace.
        var column: UUID
        /// The failed turn a Resume after an error answers: whoever acts
        /// sends "continue" only while it is still that one.
        var failedAt: TimeInterval?
        /// Why it does nothing for now: "Resuming…", a key typed since.
        var blocked: String?
    }

    /// Where a line's work is on disk, for Clean Up Worktree… and Open.
    struct Folder: Equatable, Sendable {
        /// The worktree's top level, or a folder already gone.
        var path: String
        /// What a shell opened there is called: its branch, else the
        /// folder's name.
        var title: String
        /// Clean Up Worktree… applies: a linked worktree of the project,
        /// or a folder already gone (`ProjectBoard.Row.canCleanUp`).
        var canCleanUp = false
        /// No workspace is open there: Open makes one.
        var canOpen = false
        /// A clean-up of it runs.
        var isCleaningUp = false
    }

    /// One item of a line's menu (docs/design/board-stages.md, section 7),
    /// whatever its phrase says. One that does nothing for now says why.
    enum MenuItem: Equatable, Sendable {
        /// Its address on GitHub: offered only for one of github.com.
        case openPullRequest(url: String)
        case queue(QueueOffer)
        case retarget(Link, blocked: String?)
        case resume(Resume)
        /// Clean Up Worktree… of `path`: checks it, then asks what goes.
        case cleanUp(path: String, blocked: String?)
        /// A shell in a worktree where no workspace is open.
        case openWorktree(path: String, title: String)

        var title: String {
            switch self {
            case .openPullRequest: return "Open Pull Request"
            case .queue(let offer): return offer.title
            case .retarget(let link, _): return link.title
            case .resume: return "Resume"
            case .cleanUp: return "Clean Up…"
            case .openWorktree: return "Open"
            }
        }

        /// Why it does nothing for now; nil when it acts.
        var blocked: String? {
            switch self {
            case .queue(let offer): return offer.blocked
            case .retarget(_, let blocked), .cleanUp(_, let blocked): return blocked
            case .resume(let resume): return resume.blocked
            case .openPullRequest, .openWorktree: return nil
            }
        }
    }

    /// What a line says under the pointer, beside its words when they
    /// are cut.
    struct Tooltips: Equatable, Sendable {
        /// Where its work is: "feat/login · /Users/me/app.feat-login".
        var title: String?
        /// The stations that have something to add: Reviews, each pass
        /// that ran and whether on this commit; Checks, each check by
        /// name; Merge, what a click does or why it does nothing.
        var stations: [Station: String] = [:]
        /// Its stack, its address.
        var pullRequest: String?
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
        /// Nil where a click on its Merge station does nothing: no open
        /// pull request, no merge queue.
        var offer: QueueOffer?
        var tooltips = Tooltips()
        /// Its menu, in order; empty where it offers nothing.
        var menu: [MenuItem] = []
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
        case absent

        /// Nothing in them holds a merge.
        var allowMerge: Bool { self == .passed || self == .absent }
    }

    /// What can be done with a merged pull request's worktree.
    enum CleanUp: Equatable, Sendable {
        /// "Clean up" runs Clean Up Worktree….
        case offered
        /// A clean-up is being checked, confirmed or run.
        case running

        /// What a line or an entry says while one runs.
        static let runningWords = "cleaning up…"
        /// Why Clean Up does nothing meanwhile.
        static let runningReason = "A clean-up of this worktree is running."
    }

    /// What GitHub still asks of a green pull request, as the sidebar's
    /// "Ready to merge" counts it.
    enum ReviewRequest: Equatable, Sendable {
        case changesRequested, reviewRequired
        /// Review comments wait to be dealt with (docs/design/pr-feedback-inbox.md).
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
        /// Its place in a stack (docs/design/pr-stacks.md).
        var stack: ProjectBoard.StackPlace?
        var url: String?
        /// Each check with its result, those that hold it first.
        var checkLines: [CheckLine] = []
    }

    /// A check as the Checks station's tooltip names it: "Tests / unit: ✗".
    struct CheckLine: Equatable, Sendable {
        /// Its workflow, when one made it.
        var workflow: String?
        /// As whoever posted the check named it.
        var name: String
        /// "✓", "✗", "●", "skipped", "no run yet".
        var result: String
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
        /// The queue had merged it when it stopped: its post-merge run
        /// failed, or was never watched to its end. A stop from before
        /// its merge is moot once the pull request merged.
        var isAfterMerge = false

        /// It still says something of a pull request in this state.
        func stands(merged: Bool) -> Bool { isProblem && (isAfterMerge || !merged) }
    }

    /// The next Start's list, as far as the user can change it.
    enum QueueList: Equatable, Sendable {
        /// The repository isn't saved in Board Settings: no merge queue
        /// to join, and nothing here changes its pull requests (no
        /// Retarget).
        case none
        case open
        /// A queue runs, or its confirmation sheet is open: why, in a
        /// sentence.
        case locked(String)
    }

    struct Queue: Equatable, Sendable {
        var list = QueueList.none
        /// The queue's list holds it, or the queue works on it: not one
        /// to retarget.
        var holds: Bool { order != nil || step != nil }

        /// Why Retarget does nothing for now: the list is locked (it
        /// waits for the queue, as adding and removing do), or this build
        /// can't change GitHub.
        var retargetBlocked: String? {
            if case .locked(let why) = list { return BoardStages.text(why) ?? why }
            return BoardStages.text(dryRun)
        }
        /// Its place in the queue's list, from 1: in the running queue's
        /// as the queue counts it ("3 of 7"), else in the next Start's.
        var order: Int?
        /// Nil while it waits its turn, or no queue runs.
        var step: QueueStep?
        /// While it still stands: whoever fills the facts drops one a
        /// push answers once the pull request's head moved
        /// (`BoardStages.queue(of:head:in:)`).
        var stop: QueueStop?
        /// Why its pull request can't join the list, as the queue's own
        /// rule says it in a word or two ("draft", "after #52"). Nil: it can.
        var refusal: String?
        /// Why this build changes nothing on GitHub: no Retarget.
        var dryRun: String?
    }

    /// Everything one line is derived from.
    struct Facts: Equatable, Sendable {
        /// Its first workspace's id; a pull request's or a folder's own
        /// when it has none.
        var id: String
        var title: String
        /// Where its work is, for the title's tooltip: its branch, its
        /// worktree or folder, what there is to know of them.
        var location: [String] = []
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
        /// What the user wrote of the task: said while an agent works too.
        var summary: String?
        /// Where the task stood when its last turn ended, as that turn
        /// end's line says. Said at rest only: while an agent works, it is
        /// about the turn before.
        var statusLine: String?
        /// The user's, else the Lead's.
        var nextStep: String?
        var blocker: String?
        /// Why the red checks look flaky, when the triage said so.
        var flakyReason: String?
        var lastActivityAt: TimeInterval?
        /// Its merged pull request's worktree is still there.
        var cleanUp: CleanUp?
        /// Where its work is on disk; nil for a pull request checked out
        /// nowhere here.
        var folder: Folder?
        /// How its stopped agent can go on, when it can.
        var resume: Resume?
    }

    /// What the Board asks of a task before it moves on. Constants today;
    /// built to become space settings.
    struct Rules: Equatable, Sendable {
        /// The review passes the Reviews station waits for. None: the
        /// rail has no Reviews station.
        var requiredReviews: Set<ReviewPass> = [.codeReview]
        /// Each must have run on the current HEAD. Off: once a pass ran, a
        /// commit after it doesn't send the line back, since fixes always
        /// follow a review; the station's tooltip says the review is older.
        var reviewsMustBeOnHead = false
    }
}

// MARK: - Deriving a line

extension BoardStages {
    static func line(_ facts: Facts, rules: Rules = Rules()) -> Line {
        let station = station(of: facts, rules: rules)
        let reading = reading(of: facts, at: station, rules: rules)
        let rail = rail(of: facts, at: station, rules: rules)
        let offer = rail == nil ? nil : offer(facts)
        return Line(
            id: facts.id,
            title: facts.title,
            station: station,
            state: reading.state,
            rail: rail,
            phrase: reading.phrase,
            pullRequest: pullRequestText(facts),
            since: reading.since,
            offer: offer,
            tooltips: tooltips(of: facts, rail: rail, offer: offer, rules: rules),
            menu: menu(of: facts, rail: rail, offer: offer)
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
        let isSettled = pullRequest?.isMerged == true && facts.queue.step == nil
            && facts.queue.stop?.stands(merged: true) != true
        // A pass on an earlier commit, or one that still runs, ran.
        let ranReviews = !reviewGaps(facts, rules: rules).contains { $0.gap == .never }
        let marks = Station.allCases.map { candidate -> Mark in
            let isPast = isSettled || candidate < station
            if candidate == .reviews, !facts.hasTask || rules.requiredReviews.isEmpty || (isPast && !ranReviews) { return .skipped }
            if isPast { return .done }
            return candidate == station ? .current : .ahead
        }
        return Rail(
            marks: marks, reviewIsOlderThanHead: marks[Station.reviews.rawValue] == .done && reviewIsOlderThanHead(facts, rules: rules),
            queueOrder: pullRequest == nil || isSettled ? nil : facts.queue.order
        )
    }

    /// The Merge station is the list's control (docs/design/board-stages.md,
    /// section 7): a pull request in the list leaves it, another one
    /// joins unless the queue's rule refuses it, at whatever station.
    private static func offer(_ facts: Facts) -> QueueOffer? {
        guard let pullRequest = facts.pullRequest, !pullRequest.isMerged else { return nil }
        let lock: String?
        switch facts.queue.list {
        case .none: return nil
        case .open: lock = nil
        case .locked(let why): lock = text(why) ?? why
        }
        let number = pullRequest.number
        if facts.queue.order != nil { return QueueOffer(change: .remove, number: number, blocked: lock) }
        if let refusal = text(facts.queue.refusal) {
            return QueueOffer(change: .add, number: number, blocked: "Can’t join the queue: \(refusal)")
        }
        return QueueOffer(change: .add, number: number, blocked: lock)
    }

    /// The line's menu: Open Pull Request, Add to or Remove from Queue,
    /// Retarget, Resume, Clean Up…, Open. What a link of its phrase does
    /// is there whatever the phrase says (a red check, an agent at work),
    /// as are its stopped agent's Resume and its folder's Clean Up.
    private static func menu(of facts: Facts, rail: Rail?, offer: QueueOffer?) -> [MenuItem] {
        var items: [MenuItem] = []
        let pullRequest = rail == nil ? nil : facts.pullRequest
        if let url = pullRequest?.url, isGitHubAddress(url) { items.append(.openPullRequest(url: url)) }
        if let offer { items.append(.queue(offer)) }
        // Not while the queue's list holds it, nor while the queue works on it.
        if let pullRequest, !pullRequest.isMerged, let merged = pullRequest.stack?.mergedBase, facts.queue.list != .none,
           !facts.queue.holds {
            items.append(.retarget(.retarget(number: pullRequest.number, onto: merged.onto), blocked: facts.queue.retargetBlocked))
        }
        if facts.hasTask, var resume = facts.resume {
            // Without the failed turn it answers, it can't make sure to resume that one.
            let unknown = resume.kind == .afterError && resume.failedAt == nil ? "The failed turn isn't known." : nil
            resume.blocked = resume.blocked.map { text($0) ?? "Resume isn't offered." } ?? unknown
            items.append(.resume(resume))
        }
        if let folder = facts.folder {
            if folder.canCleanUp {
                let isRunning = folder.isCleaningUp || facts.cleanUp == .running
                items.append(.cleanUp(path: folder.path, blocked: isRunning ? CleanUp.runningReason : nil))
            }
            if folder.canOpen { items.append(.openWorktree(path: folder.path, title: folder.title)) }
        }
        return items
    }

    /// A pull request's address on github.com, which the Board reads:
    /// whoever posted it can't send a click elsewhere.
    static func isGitHubAddress(_ url: String) -> Bool {
        guard let parsed = URL(string: url) else { return false }
        return parsed.scheme == "https" && parsed.host?.lowercased() == "github.com"
    }

    /// This many checks under the pointer, then how many more: a tooltip
    /// stays on screen.
    static let checkLinesShown = 12

    private static func tooltips(of facts: Facts, rail: Rail?, offer: QueueOffer?, rules: Rules) -> Tooltips {
        // Each part cleaned alone: a long path doesn't cut what follows it.
        let location = facts.location.compactMap { text($0) }
        var tooltips = Tooltips(title: location.isEmpty ? nil : location.joined(separator: " · "))
        guard let rail else { return tooltips }
        if rail.marks[Station.reviews.rawValue] != .skipped {
            tooltips.stations[.reviews] = reviewsTooltip(facts, rules: rules)
        }
        if let pullRequest = facts.pullRequest {
            tooltips.stations[.checks] = checksTooltip(pullRequest.checkLines)
            // A stack's branches are named on GitHub, as its address is given there.
            let address = [text(pullRequest.stack?.tooltip), text(pullRequest.url)].compactMap { $0 }
            tooltips.pullRequest = address.isEmpty ? nil : address.joined(separator: "\n")
        }
        tooltips.stations[.merge] = offer.map { $0.blocked ?? $0.title }
        return tooltips
    }

    /// The first checks by name. A workflow's name and a job's are each
    /// cleaned and cut before the result: a long one still says which
    /// job it is, and how it ended.
    private static func checksTooltip(_ lines: [CheckLine]) -> String? {
        guard !lines.isEmpty else { return nil }
        // "and 1 more" would take the line of the check it stands for.
        let shown = lines.count == checkLinesShown + 1 ? lines.count : checkLinesShown
        let named = lines.prefix(shown).map { line -> String in
            let name = [line.workflow, line.name].compactMap { $0.flatMap { AgentText.clean($0, maxLength: 40) } }
            return "\(name.isEmpty ? "unnamed check" : name.joined(separator: " / ")): \(line.result)"
        }
        let more = lines.count - shown
        return (named + (more > 0 ? ["and \(more) more"] : [])).joined(separator: "\n")
    }

    /// Each pass that ran, and whether on this commit; a required one
    /// that didn't. The station is drawn, so a pass is asked for.
    private static func reviewsTooltip(_ facts: Facts, rules: Rules) -> String {
        ReviewPass.allCases.compactMap { pass -> String? in
            let name = pass.displayName
            guard let reviews = facts.reviews, reviews.runs[pass] != nil else {
                return rules.requiredReviews.contains(pass) ? "No \(name.lowercased()) yet" : nil
            }
            if facts.reviewsInFlight.contains(pass) { return "\(name) running" }
            // While HEAD isn't known, nothing says which commit it ran on.
            if reviews.head == nil { return "\(name) ran" }
            // Another commit, not an earlier one: HEAD may have moved back.
            return reviews.isFresh(pass) ? "\(name) ran on this commit" : "\(name) ran on another commit"
        }.joined(separator: "\n")
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
            return Reading(.working, text(facts.summary) ?? "Working", since: since ?? last)
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
            if let stop = facts.queue.stop, stop.stands(merged: pullRequest.isMerged) {
                let label = text(stop.label).map { "Queue stopped: \($0)" } ?? "Queue stopped"
                return Reading(.failed, label, since: last, detail: text(stop.message))
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
                case .running?: return Reading(.merged, "Merged · \(CleanUp.runningWords)")
                case nil: return Reading(.merged, "Merged")
                }
            }
            // Whatever its station: nothing lands on a merged branch.
            if let merged = pullRequest.stack?.mergedBase {
                // A repository that isn't saved has nothing here to move it;
                // one the queue's list holds leaves it first (its Merge station).
                guard facts.queue.list != .none, !facts.queue.holds else { return Reading(.idle, "Base #\(merged.number) merged", since: last) }
                let link = Link.retarget(number: pullRequest.number, onto: merged.onto)
                // Locked, or a build that can't change GitHub: the words say what to do, and why they are no link.
                let blocked = facts.queue.retargetBlocked
                return Reading(
                    .idle, "Base #\(merged.number) merged · \(link.title)", since: last, link: blocked == nil ? link : nil, detail: blocked
                )
            }
            let parent = pullRequest.stack?.parent
            switch station {
            case .checks:
                // Pending: red checks were said above, green ones are at Merge.
                var since: TimeInterval?
                var missing: [String] = []
                if case .pending(let start, let names) = pullRequest.checks { (since, missing) = (start, names.compactMap(text)) }
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
                if !pullRequest.isOnBaseBranch { return Reading(.idle, "Targets \(branch(pullRequest.base))", since: last) }
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
        if let line = text(facts.summary) ?? text(facts.statusLine) { return line }
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
        if pullRequest.isConflicting { return ("Conflicts with \(branch(pullRequest.base))", nil) }
        guard case .failed(let failed) = pullRequest.checks else { return nil }
        if let flakyReason { return ("Checks failed · likely flaky", flakyReason) }
        let names = failed.compactMap(text)
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
            if facts.reviewsInFlight.contains(pass) { return (pass, .running) }
            return rules.reviewsMustBeOnHead && reviews.head != nil && !reviews.isFresh(pass) ? (pass, .earlier) : nil
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

    /// Safe to show, on one line, bounded; nil when empty. The facts come
    /// as their sources hold them: a command to allow may span lines, and
    /// a check's name is whatever its author posted.
    static func text(_ value: String?) -> String? {
        value.flatMap { AgentText.clean($0, maxLength: 300) }
    }

    /// A branch's name as shown: it is named on GitHub, by whoever
    /// pushed it.
    static func branch(_ name: String) -> String {
        text(name) ?? name
    }
}
