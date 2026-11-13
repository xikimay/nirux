import XCTest
@testable import Nirux

/// One line of the Board as stages (docs/design/board-stages.md): the station a
/// task is at, its rail, its state and phrase, its pull request and what
/// its clock counts from, from what Nirux knows of it. Pure: nothing runs
/// git or gh.
final class BoardStagesLineTests: XCTestCase {
    private typealias Facts = BoardStages.Facts
    private typealias Queue = BoardStages.Queue

    private static let head = String(repeating: "a", count: 40)
    /// A code review on the current HEAD.
    private static let reviewed = reviews(fresh: [.codeReview])

    /// Review passes on the current HEAD (`fresh`) or on an earlier commit
    /// (`earlier`).
    private static func reviews(fresh: [ReviewPass] = [], earlier: [ReviewPass] = [], head: String? = head) -> ReviewBadges {
        var runs: [ReviewPass: ReviewRun] = [:]
        for pass in fresh { runs[pass] = ReviewRun(head: Self.head, at: 500) }
        for pass in earlier { runs[pass] = ReviewRun(head: String(repeating: "b", count: 40), at: 500) }
        return ReviewBadges(runs: runs, head: head)
    }

    private func pullRequest(
        _ number: Int = 52, checks: BoardStages.Checks = .passed, draft: Bool = false, merged: Bool = false,
        conflicting: Bool = false, base: String = "main", stack: ProjectBoard.StackPlace? = nil
    ) -> BoardStages.PullRequest {
        BoardStages.PullRequest(
            number: number, isMerged: merged, isDraft: draft, isConflicting: conflicting, base: base,
            isOnBaseBranch: base == "main", checks: checks, stack: stack
        )
    }

    /// A task whose code review is over, unless told otherwise. `reviews`
    /// nil is a task no review pass ever ran in, as the app gives it.
    private func facts(
        _ pullRequest: BoardStages.PullRequest? = nil, reviews: ReviewBadges? = reviewed,
        activity: BoardStages.Activity = .idle, queue: Queue = Queue()
    ) -> Facts {
        var facts = Facts(id: "w1", title: "Agent loop hint")
        facts.pullRequest = pullRequest
        facts.reviews = reviews
        facts.activity = activity
        facts.queue = queue
        return facts
    }

    /// #53, on #52's branch in an open stack of three.
    private var child: ProjectBoard.StackPlace {
        ProjectBoard.StackPlace(parent: 52, chain: [52, 53, 54], rootBase: "main", mergedBase: nil, root: 52, order: 1)
    }

    /// #53 alone, on the branch of #52, merged into main.
    private var onMergedBase: ProjectBoard.StackPlace {
        ProjectBoard.StackPlace(
            parent: nil, chain: [53], rootBase: "stack/a", mergedBase: ProjectBoard.MergedBase(number: 52, onto: "main"),
            root: 53, order: 0
        )
    }

    private func line(_ facts: Facts, rules: BoardStages.Rules = BoardStages.Rules()) -> BoardStages.Line {
        BoardStages.line(facts, rules: rules)
    }

    // MARK: - Stations

    func testTheStationIsTheFirstOneNotDone() {
        let pending = BoardStages.Checks.pending(since: nil)
        let cases: [(Facts, BoardStages.Station, String)] = [
            (facts(reviews: nil), .code, "a new task"),
            (facts(pullRequest(draft: true), reviews: nil), .code, "a draft nobody reviewed is still code"),
            (facts(reviews: Self.reviews(earlier: [.premortem, .adversarial])), .code,
             "only a review that counts ends Code: a prompt that names an adversarial review records one"),
            (facts(pullRequest(), reviews: nil), .reviews, "a pull request marked ready ends Code"),
            (facts(pullRequest(), reviews: Self.reviews(fresh: [.premortem])), .reviews, "only the code review counts"),
            (facts(pullRequest(), reviews: Self.reviews(earlier: [.codeReview])), .merge,
             "a commit after the code review doesn't send it back"),
            (facts(), .checks, "reviewed, no pull request yet: Checks can't start"),
            (with(facts()) { $0.reviewsInFlight = [.codeReview] }, .reviews, "no pull request yet, and its code review still runs"),
            (facts(pullRequest(checks: pending)), .checks, "checks run"),
            (facts(pullRequest(checks: .failed(["test"]))), .checks, "a red check keeps it at Checks"),
            (facts(pullRequest()), .merge, "reviewed and green"),
            (facts(pullRequest(checks: .absent)), .merge, "no check at all, and none required"),
            (facts(pullRequest(checks: pending, draft: true)), .checks, "a reviewed draft goes on"),
            (facts(pullRequest(merged: true), reviews: nil), .merge, "merged, whatever its reviews")
        ]
        for (facts, station, why) in cases {
            XCTAssertEqual(line(facts).station, station, why)
        }
        var folder = facts()
        folder.hasRepository = false
        XCTAssertEqual(line(folder).station, .code, "a task without a repository has no stations to go through")
    }

    func testReviewsStaysCurrentWhileTheReviewsTurnIsNotOver() {
        // A pass is recorded as it starts: here its turn asks for a permission.
        var reviewing = facts(pullRequest(), activity: .needsYou("Bash(swift test)"))
        reviewing.reviewsInFlight = [.codeReview]
        XCTAssertEqual(line(reviewing).rail?.marks, [.done, .current, .ahead, .ahead], "whatever its agent does meanwhile")
        reviewing.activity = .idle
        XCTAssertEqual(line(reviewing).phrase.text, "Review running", "its agent at rest between two of the review's turns")
        reviewing.reviewsInFlight = [.premortem]
        XCTAssertEqual(line(reviewing).station, .merge, "a pass that doesn't count holds nothing")
    }

    func testTheRulesNameTheReviewsThatCount() {
        let both = BoardStages.Rules(requiredReviews: [.premortem, .codeReview])
        XCTAssertEqual(line(facts(pullRequest()), rules: both).station, .reviews, "the premortem is missing")
        XCTAssertEqual(line(facts(pullRequest()), rules: both).phrase.text, "No premortem yet")
        XCTAssertEqual(line(facts(pullRequest(), reviews: nil), rules: both).phrase.text, "No code review, premortem yet",
                       "in the badges' order")
        let reviewed = facts(pullRequest(), reviews: Self.reviews(fresh: [.codeReview, .premortem]))
        XCTAssertEqual(line(reviewed, rules: both).station, .merge)

        let none = line(facts(pullRequest(), reviews: nil), rules: BoardStages.Rules(requiredReviews: []))
        XCTAssertEqual(none.rail?.marks, [.done, .skipped, .done, .current], "no review asked for: no Reviews station")
        XCTAssertEqual(none.phrase.text, "Ready · checks green", "and none claimed")
    }

    func testTheRulesMayAskForReviewsOnTheCurrentHead() {
        let strict = BoardStages.Rules(reviewsMustBeOnHead: true)
        let earlier = facts(pullRequest(), reviews: Self.reviews(earlier: [.codeReview]))
        XCTAssertEqual(line(earlier, rules: strict).rail?.marks, [.done, .current, .ahead, .ahead], "a commit landed after the review")
        XCTAssertEqual(line(earlier, rules: strict).phrase.text, "No code review on this commit")
        XCTAssertEqual(line(facts(pullRequest()), rules: strict).station, .merge)
        let unknownHead = facts(pullRequest(), reviews: Self.reviews(earlier: [.codeReview], head: nil))
        XCTAssertEqual(line(unknownHead, rules: strict).station, .merge, "HEAD not read yet: the line doesn't move back")
        let both = BoardStages.Rules(requiredReviews: [.codeReview, .premortem], reviewsMustBeOnHead: true)
        XCTAssertEqual(line(earlier, rules: both).phrase.text, "No premortem yet", "what never ran before what ran earlier")
        XCTAssertEqual(line(with(earlier) { $0.reviewsInFlight = [.codeReview] }, rules: strict).phrase.text, "Review running",
                       "run again: running, not missing")
        XCTAssertEqual(line(with(earlier) { $0.pullRequest?.isMerged = true }, rules: strict).rail?.marks,
                       [.done, .done, .done, .done], "merged on an earlier review: one ran")
    }

    // MARK: - The merge queue

    func testThePullRequestTheQueueWorksOnIsWhereTheQueueHasIt() {
        var updating = facts(
            pullRequest(checks: .failed(["test"])), reviews: nil, queue: Queue(order: 2, step: .checks("Updating branch"))
        )
        updating.blocker = "waits for the release"
        updating.lastActivityAt = 600
        let checking = line(updating)
        XCTAssertEqual(checking.rail, BoardStages.Rail(marks: [.done, .skipped, .current, .ahead], queueOrder: 2),
                       "the user confirmed its head at Start: its reviews don't hold it, and none is claimed")
        XCTAssertEqual(checking.state, .waiting, "the queue reruns a red check once: not a failure yet")
        XCTAssertEqual(checking.phrase.text, "Updating branch")
        XCTAssertNil(checking.since, "the queue's steps have no clock of the task's")
        updating.activity = .working(since: nil)
        XCTAssertEqual(line(updating).state, .working, "its agent's word comes first")
        XCTAssertEqual(line(facts(pullRequest(), queue: Queue(step: .merge(" ")))).phrase.text, "In the queue")
        let merging = line(facts(pullRequest(checks: .pending(since: nil)), reviews: nil, queue: Queue(step: .merge("Merging"))))
        XCTAssertEqual(merging.rail?.marks, [.done, .skipped, .done, .current], "merging, whatever the Board last read of it")
        updating.reviewsInFlight = [.codeReview]
        updating.reviews = Self.reviewed
        XCTAssertEqual(line(updating).rail?.marks, [.done, .done, .current, .ahead], "a review that still runs was not skipped")
    }

    func testTheQueueKeepsAMergedPullRequestUntilItIsThroughWithIt() {
        // GitHub says merged within a minute; the post-merge run takes ten.
        let waiting = line(facts(pullRequest(merged: true), queue: Queue(order: 1, step: .merge("Waiting for nightly"))))
        XCTAssertEqual(waiting.rail, BoardStages.Rail(marks: [.done, .done, .done, .current], queueOrder: 1),
                       "its number stays while the queue has it")
        XCTAssertEqual(waiting.state, .waiting)
        XCTAssertEqual(waiting.phrase.text, "Waiting for nightly")
        var stop = BoardStages.QueueStop(
            label: "nightly failed", message: "The nightly of #52 failed.", isProblem: true, isAfterMerge: true
        )
        let failed = line(facts(pullRequest(merged: true), queue: Queue(stop: stop)))
        XCTAssertEqual(failed.rail?.marks, [.done, .done, .done, .current], "red at Merge, not settled")
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.phrase, BoardStages.Phrase(text: "Queue stopped: nightly failed", detail: "The nightly of #52 failed."))
        // Stopped before its merge, then merged by hand: the stop is moot.
        stop.isAfterMerge = false
        let byHand = line(with(facts(pullRequest(checks: .failed(["test"]), merged: true, conflicting: true), queue: Queue(order: 1, stop: stop))) {
            $0.cleanUp = .offered
        })
        XCTAssertEqual(byHand.rail, BoardStages.Rail(marks: [.done, .done, .done, .done], queueOrder: nil))
        XCTAssertEqual(byHand.state, .merged, "nor do its last checks matter")
        XCTAssertEqual(byHand.phrase.text, "Merged · Clean up")
        let stopped = BoardStages.QueueStop(label: "by you", message: "Stopped.", isProblem: false, isAfterMerge: true)
        XCTAssertEqual(line(facts(pullRequest(merged: true), queue: Queue(stop: stopped))).rail?.marks, [.done, .done, .done, .done],
                       "Stop pressed during the post-merge run: settled")
    }

    // MARK: - The rail

    func testTheRailFillsWhatIsDoneAndCarriesTheQueueOrder() {
        let checking = line(facts(pullRequest(checks: .pending(since: nil)), queue: Queue(order: 2)))
        XCTAssertEqual(checking.rail, BoardStages.Rail(marks: [.done, .done, .current, .ahead], queueOrder: 2))
        let queuedUnreviewed = line(facts(pullRequest(), reviews: nil, queue: Queue(order: 1)))
        XCTAssertEqual(queuedUnreviewed.rail, BoardStages.Rail(marks: [.done, .current, .ahead, .ahead], queueOrder: 1),
                       "the list is the user's: its number shows before the line reaches Merge")
        let merged = line(facts(pullRequest(merged: true), queue: Queue(order: 1)))
        XCTAssertEqual(merged.rail, BoardStages.Rail(marks: [.done, .done, .done, .done], queueOrder: nil))
    }

    func testTheRailSaysAReviewIsOlderThanHeadWithoutDrawingIt() {
        let older = { (facts: Facts, rules: BoardStages.Rules) in self.line(facts, rules: rules).rail?.reviewIsOlderThanHead }
        let earlier = Self.reviews(fresh: [.premortem], earlier: [.codeReview])
        let checking = facts(pullRequest(checks: .pending(since: nil)), reviews: earlier)
        XCTAssertEqual(line(checking).rail?.marks, [.done, .done, .current, .ahead], "fixes follow nearly every review: no mark for it")
        XCTAssertEqual(older(checking, BoardStages.Rules()), true, "commits landed since the code review: the tooltip says so")
        XCTAssertEqual(older(facts(pullRequest()), BoardStages.Rules()), false, "reviewed on HEAD")
        XCTAssertEqual(older(facts(pullRequest(), reviews: Self.reviews(earlier: [.codeReview], head: nil)), BoardStages.Rules()), false,
                       "HEAD not read yet: no review reads as older")
        XCTAssertEqual(older(facts(pullRequest(), reviews: Self.reviews(fresh: [.codeReview], earlier: [.premortem])), BoardStages.Rules()),
                       false, "only the reviews that count")
        XCTAssertEqual(older(facts(pullRequest(), reviews: earlier), BoardStages.Rules(reviewsMustBeOnHead: true)), false,
                       "at Reviews, not past it: the phrase says it")
        XCTAssertEqual(older(with(checking) { $0.hasTask = false }, BoardStages.Rules()), false, "no Reviews station, nothing to say of it")
        XCTAssertEqual(older(facts(pullRequest(merged: true), reviews: earlier), BoardStages.Rules()), true, "still true once merged")
    }

    func testReviewsIsSkippedWhereNoneWasSeen() {
        XCTAssertEqual(line(facts(pullRequest(merged: true), reviews: nil)).rail?.marks, [.done, .skipped, .done, .done],
                       "merged without a review: none is claimed")
        var remote = facts(pullRequest(checks: .pending(since: nil)), reviews: nil)
        remote.hasTask = false
        XCTAssertEqual(line(remote).rail?.marks, [.done, .skipped, .current, .ahead], "no workspace here could have seen one")
        remote.pullRequest = pullRequest()
        XCTAssertEqual(line(remote).phrase.text, "Ready · checks green", "no review to claim")
        remote.pullRequest = pullRequest(checks: .absent)
        XCTAssertEqual(line(remote).phrase.text, "Ready", "nor any check")
        remote.pullRequest = pullRequest(draft: true)
        XCTAssertEqual(line(remote).rail?.marks, [.current, .skipped, .ahead, .ahead])
        XCTAssertEqual(line(remote).phrase.text, "Draft")
    }

    func testATaskWithoutARepositoryHasNoRailAndNoPullRequestCell() {
        var folder = facts(reviews: nil)
        folder.hasRepository = false
        XCTAssertNil(line(folder).rail)
        XCTAssertEqual(line(folder).pullRequest, "")
        XCTAssertEqual(line(folder).phrase.text, "No activity yet")
    }

    // MARK: - State and phrase

    /// `facts` with a few more of them set.
    private func with(_ facts: Facts, _ change: (inout Facts) -> Void) -> Facts {
        var facts = facts
        change(&facts)
        return facts
    }

    func testWhatItsAgentsSayComesFirst() {
        let red = pullRequest(checks: .failed(["test"]))
        let cases: [(Facts, BoardStages.State, String, String)] = [
            (facts(red, activity: .needsYou(" swift test \\\n  --filter Board ")), .needsYou,
             "Needs you · swift test \\ --filter Board", "the user before a red check, on one line"),
            (facts(pullRequest(merged: true), activity: .needsYou("")), .needsYou, "Needs you", "amber is never hidden, even once merged"),
            (facts(red, activity: .failed("Stopped on an API error")), .failed, "Stopped on an API error", "an agent that stopped"),
            (facts(pullRequest(), activity: .failed(" ")), .failed, "Stopped", "whatever it said"),
            (with(facts(red, activity: .working(since: nil))) { $0.statusLine = "Waits for the go-ahead"; $0.blocker = "upstream" },
             .working, "Working", "work goes on, and the last turn's line is about the turn before"),
            (with(facts(red, activity: .working(since: nil))) { $0.statusLine = "Waits for the go-ahead"; $0.summary = " Triage\nrules " },
             .working, "Triage rules", "what the user wrote of the task still holds"),
            (facts(pullRequest(merged: true), activity: .working(since: nil)), .working, "Working", "as on the sidebar"),
            (facts(pullRequest(), activity: .asking("Lead"), queue: Queue(step: .merge("Merging"))), .waiting, "Merging",
             "the queue's step before what its agent waits for")
        ]
        for (facts, state, text, why) in cases {
            XCTAssertEqual(line(facts).state, state, why)
            XCTAssertEqual(line(facts).phrase.text, text, why)
        }
    }

    func testWhatIsWrongNowComesBeforeTheLastQueuesStop() {
        let red = pullRequest(checks: .failed(["test", "lint"]))
        let stop = BoardStages.QueueStop(label: "changed", message: "#52 changed since you confirmed it.", isProblem: true)
        let byUser = BoardStages.QueueStop(label: "by you", message: "Stopped.", isProblem: false)
        let flaky = with(facts(red)) { $0.flakyReason = "CatchUpTests timed out on a slow runner" }
        let cases: [(Facts, BoardStages.State, String, String)] = [
            (facts(pullRequest(checks: .failed([]), conflicting: true, base: "develop"), queue: Queue(stop: stop)), .failed,
             "Conflicts with develop", "its own base; the conflict before the stop"),
            (facts(red, reviews: nil, queue: Queue(stop: stop)), .failed, "Checks failed: test, lint", "at any station, by name"),
            (facts(pullRequest(checks: .failed([]))), .failed, "Checks failed", "red checks without a name"),
            (flaky, .failed, "Checks failed · likely flaky", "only the triage's verdict says more"),
            (with(flaky) { $0.flakyReason = " \n" }, .failed, "Checks failed: test, lint", "an empty reason is none"),
            (facts(pullRequest(), queue: Queue(stop: stop)), .failed, "Queue stopped: changed", "nothing wrong now: the stop stands"),
            (facts(pullRequest(), queue: Queue(stop: byUser)), .ready, "Ready · reviews done, checks green", "Stop pressed is no failure"),
            (with(facts(red, activity: .asking("Lead"))) { $0.blocker = "upstream" }, .failed, "Checks failed: test, lint",
             "red before what it waits for, as on the sidebar"),
            (with(facts(pullRequest(), activity: .asking("Lead"), queue: Queue(stop: stop))) { $0.blocker = "upstream" }, .failed,
             "Queue stopped: changed", "the stop before what it waits for"),
            (with(facts(pullRequest(checks: .failed(["test"]), conflicting: true))) { $0.flakyReason = "slow runner" }, .failed,
             "Conflicts with main", "a conflict before its checks, flaky or not"),
            (facts(pullRequest(checks: .failed(["te\u{1B}[31mst\u{202E}"]))), .failed, "Checks failed: te[31mst",
             "a check's name is whatever its author posted: nothing invisible reaches the line")
        ]
        for (facts, state, text, why) in cases {
            XCTAssertEqual(line(facts).state, state, why)
            XCTAssertEqual(line(facts).phrase.text, text, why)
        }
        XCTAssertEqual(line(flaky).phrase.detail, "CatchUpTests timed out on a slow runner")
        XCTAssertEqual(line(facts(pullRequest(), queue: Queue(stop: stop))).phrase.detail, "#52 changed since you confirmed it.")
    }

    func testThenWhatItWaitsFor() {
        let pending = BoardStages.Checks.pending(since: nil)
        let blocked = with(facts(pullRequest(checks: pending))) { $0.blocker = "  waits for\nupstream " }
        let cases: [(Facts, BoardStages.State, String, String)] = [
            (with(facts(pullRequest(), activity: .asking("Lead"))) { $0.blocker = "upstream" }, .waiting, "Asking Lead",
             "its agent asked its parent: not ready, and before the blocker"),
            (facts(pullRequest(), activity: .asking(" ")), .waiting, "Asking its parent", "whoever that is"),
            (blocked, .blocked, "Blocked · waits for upstream", "a blocker before what the station waits for"),
            (with(facts(reviews: nil)) { $0.blocker = "upstream" }, .blocked, "Blocked · upstream", "a blocker needs no pull request"),
            (with(facts(pullRequest())) { $0.blocker = " \n " }, .ready, "Ready · reviews done, checks green", "an empty blocker is none"),
            (with(facts(pullRequest(merged: true))) { $0.blocker = "upstream" }, .blocked, "Blocked · upstream", "as on the sidebar"),
            (facts(pullRequest(merged: true), activity: .asking("Lead")), .waiting, "Asking Lead", "asked after the merge"),
            (facts(pullRequest(merged: true)), .merged, "Merged", "merged"),
            (with(facts(pullRequest(merged: true))) { $0.cleanUp = .running }, .merged, "Merged · cleaning up…", "its clean-up runs"),
            (facts(pullRequest(53, checks: pending, base: "stack/a", stack: onMergedBase), queue: Queue(list: .open)), .idle,
             "Base #52 merged · Retarget to main", "whatever its station: nothing lands on a merged branch, the user moves it"),
            (with(facts(pullRequest(53, draft: true, base: "stack/a", stack: onMergedBase), reviews: nil, queue: Queue(list: .open))) {
                $0.nextStep = "rebase"
            }, .idle, "Base #52 merged · Retarget to main", "at Code too, before the next step"),
            (facts(pullRequest(53, base: "stack/a", stack: onMergedBase)), .idle, "Base #52 merged",
             "a repository without a merge queue: nothing here can retarget it"),
            (facts(pullRequest(checks: pending)), .waiting, "Checks running", "checks run"),
            (facts(pullRequest(checks: .pending(since: nil, missing: ["test", "lint"]))), .waiting, "No test, lint run yet",
             "a required check that hasn't reported isn't running"),
            (facts(pullRequest(53, checks: pending, base: "stack/a", stack: child)), .waiting,
             "Checks running · lands after #52", "a stack says what it follows"),
            (facts(pullRequest(53, base: "stack/a", stack: child)), .waiting, "Lands after #52", "green, but not its turn"),
            (facts(with(pullRequest(53, draft: true, base: "stack/a", stack: child)) { $0.reviewRequest = .changesRequested }),
             .waiting, "Lands after #52", "what holds it, the furthest first: its place in the stack"),
            (facts(with(pullRequest(draft: true, base: "release")) { $0.reviewRequest = .changesRequested }), .idle,
             "Draft · reviews done, checks green", "then a draft, which isn't ready"),
            (facts(with(pullRequest(base: "release")) { $0.reviewRequest = .changesRequested }), .idle, "Targets release",
             "then its base: the queue takes the base branch only"),
            (facts(with(pullRequest()) { $0.reviewRequest = .changesRequested }), .idle, "Changes requested",
             "then GitHub's review, as the sidebar's Ready to merge counts it"),
            (facts(with(pullRequest()) { $0.reviewRequest = .feedback }), .idle, "Feedback to answer", "review comments wait"),
            (facts(pullRequest(checks: .absent)), .ready, "Ready · reviews done", "no check to claim"),
            (facts(pullRequest(checks: pending), reviews: nil), .idle, "No code review yet",
             "at Reviews, running checks aren't what it waits for")
        ]
        for (facts, state, text, why) in cases {
            XCTAssertEqual(line(facts).state, state, why)
            XCTAssertEqual(line(facts).phrase.text, text, why)
        }
        let cleanUp = line(with(facts(pullRequest(merged: true))) { $0.cleanUp = .offered }).phrase
        XCTAssertEqual(cleanUp, BoardStages.Phrase(text: "Merged · Clean up", link: .cleanUp))
        let onto = BoardStages.Link.retarget(number: 53, onto: "main")
        let retarget = line(facts(pullRequest(53, base: "stack/a", stack: onMergedBase), queue: Queue(list: .open))).phrase
        XCTAssertEqual(retarget, BoardStages.Phrase(text: "Base #52 merged · Retarget to main", link: onto))
        XCTAssertTrue(retarget.text.hasSuffix(onto.title), "the link ends the phrase")
        // For whoever draws the link apart: the words before it.
        XCTAssertEqual([retarget.wordsBeforeLink, cleanUp.wordsBeforeLink], ["Base #52 merged ·", "Merged ·"])
        XCTAssertNil(BoardStages.Phrase(text: "Base #52 merged · Retarget to main").wordsBeforeLink, "no link")
        XCTAssertNil(BoardStages.Phrase(text: "Retarget to main, then merge", link: onto).wordsBeforeLink, "a text that doesn't end with it")
        XCTAssertNil(line(facts(pullRequest(53, base: "stack/a", stack: onMergedBase))).phrase.link, "no merge queue: no link")
        // Retargeting is the Board's own call, not the queue's: a queue that runs, or that holds it, changes nothing.
        let held = Queue(list: .locked("The queue is running."), order: 2)
        XCTAssertEqual(line(facts(pullRequest(53, base: "stack/a", stack: onMergedBase), queue: held)).phrase.link, onto)
        // A build that can't change GitHub: the words stay, as what to do, and say why they are no link.
        let dryRun = "Dry run: this build doesn’t change GitHub."
        let inert = line(facts(pullRequest(53, base: "stack/a", stack: onMergedBase), queue: Queue(list: .open, dryRun: " \(dryRun)\n"))).phrase
        XCTAssertEqual(inert, BoardStages.Phrase(text: "Base #52 merged · Retarget to main", link: nil, detail: dryRun))
        let listed = Queue(list: .open, order: 1, dryRun: dryRun)
        XCTAssertNil(line(facts(pullRequest(53, base: "stack/a", stack: onMergedBase), queue: listed)).phrase.link, "in the list or not")
        let cleaning = line(with(facts(pullRequest(merged: true), queue: Queue(list: .open, dryRun: dryRun))) { $0.cleanUp = .offered }).phrase
        XCTAssertEqual(cleaning, cleanUp, "a clean-up changes nothing on GitHub")
        // What is wrong now comes first: the phrase has no link then, and the Merge station still says the base merged.
        let red = line(facts(
            pullRequest(53, checks: .failed(["test"]), base: "stack/a", stack: onMergedBase),
            queue: Queue(list: .open, refusal: "base #52 merged")
        ))
        XCTAssertEqual(red.phrase, BoardStages.Phrase(text: "Checks failed: test"))
        XCTAssertEqual(red.tooltips.stations[.merge], "Can’t join the queue: base #52 merged")
        // What a click on a link does, for its tooltip.
        XCTAssertEqual(onto.hint, "Bases #53 on main, as GitHub does when a merged branch is deleted")
        XCTAssertEqual(BoardStages.Link.cleanUp.hint, "Checks the worktree, then asks what goes")
        // A branch is named on GitHub, by whoever pushed it: shown cleaned, wherever a line names one.
        let odd = BoardStages.Link.retarget(number: 53, onto: "ma\u{202E}in")
        XCTAssertEqual([odd.title, odd.hint], ["Retarget to main", "Bases #53 on main, as GitHub does when a merged branch is deleted"])
        XCTAssertEqual(line(facts(pullRequest(base: "rel\u{202E}ease"))).phrase.text, "Targets release")
        XCTAssertEqual(line(facts(pullRequest(conflicting: true, base: "rel\u{202E}ease"))).phrase.text, "Conflicts with release")
    }

    // MARK: - The Merge station's click

    func testTheMergeStationIsTheListsControl() {
        typealias Offer = BoardStages.QueueOffer
        let running = "The queue is running: change the list once it stops."
        let pending = BoardStages.Checks.pending(since: nil)
        let stop = BoardStages.QueueStop(label: "checks", message: "test failed.", isProblem: true)
        let add = Offer(change: .add, number: 52)
        let remove = Offer(change: .remove, number: 52)
        let refused = Offer(change: .add, number: 52, blocked: "Can’t join the queue: draft")
        // The offer, and what the station says under the pointer.
        let cases: [(Facts, Offer?, String?, String)] = [
            (facts(pullRequest(), queue: Queue(list: .open)), add, "Add to Queue", "ready, outside the list: a click adds it"),
            (facts(pullRequest(checks: pending), reviews: nil, queue: Queue(list: .open)), add, "Add to Queue",
             "at any station: the queue asks for no review, and waits for the checks itself"),
            (facts(pullRequest(), queue: Queue(list: .open, order: 2)), remove, "Remove from Queue", "in the list: a click takes it out"),
            (facts(pullRequest(), queue: Queue(list: .open, order: 2, refusal: "draft")), remove, "Remove from Queue",
             "one the queue would refuse now can still leave the list"),
            (facts(pullRequest(), queue: Queue(list: .open, order: 1, stop: stop)), remove, "Remove from Queue",
             "the last queue stopped on it: still in the next Start's list"),
            (facts(pullRequest(), queue: Queue(list: .open, stop: stop)), add, "Add to Queue", "or out of it"),
            (facts(pullRequest(draft: true), queue: Queue(list: .open, refusal: " draft\n")), refused, "Can’t join the queue: draft",
             "refused, and why, as the queue's rule says it"),
            (facts(pullRequest(), queue: Queue(list: .open, refusal: " ")), add, "Add to Queue", "an empty refusal is none"),
            (facts(pullRequest(), queue: Queue(list: .locked(running))), Offer(change: .add, number: 52, blocked: running), running,
             "the list can't change while a queue runs"),
            (facts(pullRequest(), queue: Queue(list: .locked(running), order: 1, step: .merge("Merging"))),
             Offer(change: .remove, number: 52, blocked: running), running, "nor lose the pull request the queue works on"),
            (facts(pullRequest(draft: true), queue: Queue(list: .locked(running), refusal: "draft")), refused,
             "Can’t join the queue: draft", "what won't change when the queue ends comes first"),
            (facts(pullRequest(), queue: Queue(list: .locked(" The sheet\nis open. "))),
             Offer(change: .add, number: 52, blocked: "The sheet is open."), "The sheet is open.", "why, cleaned"),
            (facts(pullRequest(), queue: Queue(order: 1)), nil, nil, "a repository without a merge queue has no list"),
            (facts(pullRequest(merged: true), queue: Queue(list: .locked(running), order: 1, step: .merge("Waiting for nightly"))), nil, nil,
             "merged, though the queue still waits for its post-merge run: nothing left to queue"),
            (facts(queue: Queue(list: .open)), nil, nil, "no pull request yet"),
            (with(facts(pullRequest(), queue: Queue(list: .open))) { $0.hasRepository = false }, nil, nil, "no rail, no station to click")
        ]
        for (facts, offer, tooltip, why) in cases {
            XCTAssertEqual(line(facts).offer, offer, why)
            XCTAssertEqual(line(facts).tooltips.stations[.merge], tooltip, why)
        }
        XCTAssertNotNil(line(facts(pullRequest(), queue: Queue(list: .locked(" ")))).offer?.blocked, "locked, whatever its reason")
        let withoutTask = with(facts(pullRequest(14), reviews: nil, queue: Queue(list: .open))) { $0.hasTask = false }
        XCTAssertEqual(line(withoutTask).offer, Offer(change: .add, number: 14), "a pull request without a task can be queued too")
        let stacked = facts(pullRequest(53, base: "stack/a", stack: child), queue: Queue(list: .open, order: 2))
        XCTAssertEqual(line(stacked).offer, Offer(change: .remove, number: 53), "its own number, not its stack's root")
    }

    // MARK: - Under the pointer

    func testALineSaysUnderThePointerWhatItCantHold() {
        typealias Check = BoardStages.CheckLine
        var busy = facts(
            with(pullRequest(53, checks: .failed(["test"]), base: "stack/a", stack: child)) {
                $0.url = " https://github.com/acme/widgets/pull/53 "
                $0.checkLines = [
                    Check(workflow: "Tests", name: "test", result: "✗"), Check(workflow: "", name: " \n", result: "●"),
                    Check(workflow: " ", name: "lint\nfast", result: "✓")
                ]
            },
            reviews: Self.reviews(fresh: [.premortem], earlier: [.codeReview, .adversarial]), queue: Queue(list: .open)
        )
        busy.location = [" feat/hint\n", " ", "/p/app.hint"]
        busy.reviewsInFlight = [.adversarial]
        XCTAssertEqual(line(busy).tooltips, BoardStages.Tooltips(
            title: "feat/hint · /p/app.hint",
            stations: [
                .reviews: "Code review ran on another commit\nPremortem ran on this commit\nAdversarial review running",
                .checks: "Tests / test: ✗\nunnamed check: ●\nlint fast: ✓",
                .merge: "Add to Queue"
            ],
            pullRequest: "Stack: #52 → #53 → #54, on main\nhttps://github.com/acme/widgets/pull/53"
        ), "each text cleaned, on its own line; a pass that never ran and isn't asked for says nothing")
        // Each part of the title's is cut alone: what follows a long path stays.
        let long = with(busy) { $0.location = ["feat/hint", String(repeating: "/deep", count: 80), "folder is gone"] }
        XCTAssertEqual(line(long).tooltips.title?.hasSuffix("… · folder is gone"), true)
        XCTAssertNil(line(with(busy) { $0.location = [] }).tooltips.title)

        // Reviews: what is asked for and didn't run; no commit is named while HEAD isn't known.
        let reviewsSay = { (facts: Facts, rules: BoardStages.Rules) in self.line(facts, rules: rules).tooltips.stations[.reviews] }
        XCTAssertEqual(reviewsSay(facts(pullRequest(), reviews: nil), BoardStages.Rules()), "No code review yet")
        XCTAssertEqual(reviewsSay(facts(pullRequest(), reviews: Self.reviews(fresh: [.premortem])), BoardStages.Rules()),
                       "No code review yet\nPremortem ran on this commit")
        let unknownHead = facts(pullRequest(), reviews: Self.reviews(fresh: [.premortem], earlier: [.codeReview], head: nil))
        XCTAssertEqual(reviewsSay(unknownHead, BoardStages.Rules()), "Code review ran\nPremortem ran")
        XCTAssertEqual(reviewsSay(with(unknownHead) { $0.reviewsInFlight = [.codeReview] }, BoardStages.Rules()),
                       "Code review running\nPremortem ran", "running, whatever its commit")
        XCTAssertEqual(reviewsSay(with(facts(reviews: nil)) { $0.reviewsInFlight = [.codeReview] }, BoardStages.Rules()),
                       "No code review yet", "a pass in flight is recorded as it starts: without a run, it didn't")
        var both = BoardStages.Rules()
        both.requiredReviews = [.codeReview, .codeStyleReview]
        XCTAssertEqual(reviewsSay(facts(), both), "Code review ran on this commit\nNo code style review yet")
        // No Reviews station, nothing under it: a pull request without a task, one merged that nobody
        // reviewed, rules that ask for none.
        XCTAssertNil(reviewsSay(with(facts(pullRequest())) { $0.hasTask = false }, BoardStages.Rules()))
        XCTAssertNil(reviewsSay(facts(pullRequest(merged: true), reviews: nil), BoardStages.Rules()))
        var none = BoardStages.Rules()
        none.requiredReviews = []
        XCTAssertNil(reviewsSay(facts(pullRequest()), none))

        // Checks: twelve as given, then how many more; a thirteenth takes that line's place.
        let many = (1...14).map { Check(name: "job \($0)", result: "✓") }
        let said = { (count: Int) in
            self.line(self.facts(self.with(self.pullRequest()) { $0.checkLines = Array(many.prefix(count)) })).tooltips.stations[.checks]
        }
        let lines = many.map { "\($0.name): ✓" }
        XCTAssertEqual(said(14), (lines.prefix(12) + ["and 2 more"]).joined(separator: "\n"))
        XCTAssertEqual(said(13), lines.prefix(13).joined(separator: "\n"), "the thirteenth takes no more room than \"and 1 more\"")
        XCTAssertEqual(said(12), lines.prefix(12).joined(separator: "\n"))
        XCTAssertNil(said(0), "no check to name")
        // A workflow's name and a job's are each cut, before the result: a long one still says which job, and how it ended.
        let wordy = line(facts(with(pullRequest()) {
            $0.checkLines = [
                Check(workflow: String(repeating: "w", count: 90), name: "unit", result: "✗"),
                Check(name: String(repeating: "x", count: 200), result: "●")
            ]
        }))
        XCTAssertEqual(wordy.tooltips.stations[.checks],
                       String(repeating: "w", count: 39) + "… / unit: ✗\n" + String(repeating: "x", count: 39) + "…: ●")

        // The pull request: its address alone outside a stack; nothing without either; both cleaned.
        let merged = line(facts(with(pullRequest(merged: true)) { $0.url = "https://github.com/acme/widgets/pull/52" })).tooltips
        XCTAssertEqual(merged.pullRequest, "https://github.com/acme/widgets/pull/52", "a merged one too")
        XCTAssertEqual(merged.stations, [.reviews: "Code review ran on this commit"], "as what its reviews were")
        XCTAssertNil(line(facts(pullRequest())).tooltips.pullRequest)
        let renamed = ProjectBoard.StackPlace(parent: 52, chain: [52, 53], rootBase: "ma\u{202E}in", mergedBase: nil, root: 52, order: 1)
        XCTAssertEqual(line(facts(pullRequest(53, base: "stack/a", stack: renamed))).tooltips.pullRequest, "Stack: #52 → #53, on main")
        XCTAssertEqual(line(facts()).tooltips, BoardStages.Tooltips(stations: [.reviews: "Code review ran on this commit"]))
        // Without a rail, its title alone says more.
        XCTAssertEqual(line(with(busy) { $0.hasRepository = false }).tooltips, BoardStages.Tooltips(title: "feat/hint · /p/app.hint"))
    }

    private func with(_ pullRequest: BoardStages.PullRequest, _ change: (inout BoardStages.PullRequest) -> Void)
        -> BoardStages.PullRequest {
        var pullRequest = pullRequest
        change(&pullRequest)
        return pullRequest
    }

    func testAtRestTheLineSaysTheNextStepThenWhereTheTaskStands() {
        let unreviewed = facts(pullRequest(), reviews: nil)
        let atRest = with(unreviewed) { $0.statusLine = " Fixes pushed,\nwaits for a review " }
        let cases: [(Facts, String, String)] = [
            (with(atRest) { $0.nextStep = "run the confirmation review" }, "Next · run the confirmation review", "the next step first"),
            (with(atRest) { $0.nextStep = " " }, "Fixes pushed, waits for a review", "then where the task stands, on one line"),
            (with(atRest) { $0.summary = "Triage rules" }, "Triage rules", "the user's own words before the last turn's line"),
            (with(atRest) { $0.summary = " \n" }, "Fixes pushed, waits for a review", "an empty summary is none"),
            (with(atRest) { $0.isArchived = true }, "Fixes pushed, waits for a review", "archived, with something to say"),
            (with(unreviewed) { $0.isArchived = true }, "Archived", "an archived task with nothing to say"),
            (unreviewed, "No code review yet", "what Reviews waits for"),
            (facts(), "No pull request yet", "what Checks waits for"),
            (with(facts(reviews: nil)) { $0.lastActivityAt = 60 }, "Idle", "at Code, after some activity"),
            (facts(pullRequest(draft: true), reviews: nil), "Draft", "at Code, with a draft open")
        ]
        for (facts, text, why) in cases {
            XCTAssertEqual(line(facts).state, .idle, why)
            XCTAssertEqual(line(facts).phrase.text, text, why)
        }
    }

    // MARK: - Pull request and clock

    func testThePullRequestCellSaysItsPlaceInAStack() {
        XCTAssertEqual(line(facts(pullRequest())).pullRequest, "#52")
        XCTAssertEqual(line(facts(pullRequest(53, base: "stack/a", stack: child))).pullRequest, "#53 · 2/3")
        XCTAssertEqual(line(facts()).pullRequest, "no PR yet")
    }

    func testTheClockCountsWhatTheLineWaitsOn() {
        let last = { (facts: Facts) in self.with(facts) { $0.lastActivityAt = 900 } }
        XCTAssertEqual(line(last(facts(pullRequest(), activity: .working(since: 700)))).since, 700, "the turn's start")
        XCTAssertEqual(line(last(facts(pullRequest(), activity: .working(since: nil)))).since, 900, "a turn whose start isn't known")
        let stop = BoardStages.QueueStop(label: "changed", message: "", isProblem: true)
        let sinceLastActivity: [(Facts, String)] = [
            (facts(pullRequest(), activity: .failed("Stopped")), "an agent that stopped"),
            (facts(pullRequest(), activity: .asking("Lead")), "asking"),
            (facts(pullRequest(), queue: Queue(stop: stop)), "a queue's stop"),
            (facts(pullRequest(53, base: "stack/a", stack: onMergedBase), queue: Queue(list: .open)), "a base to retarget"),
            (facts(pullRequest(53, base: "stack/a", stack: onMergedBase), queue: Queue(list: .open, dryRun: "Dry run.")),
             "one this build can't retarget"),
            (facts(pullRequest(53, base: "stack/a", stack: onMergedBase)), "one nothing here can retarget"),
            (facts(pullRequest(draft: true)), "a draft"),
            (facts(pullRequest(base: "release")), "another base"),
            (facts(with(pullRequest()) { $0.reviewRequest = .reviewRequired }), "a review required")
        ]
        for (facts, why) in sinceLastActivity {
            XCTAssertEqual(line(last(facts)).since, 900, why)
        }
        XCTAssertEqual(line(facts(with(pullRequest()) { $0.reviewRequest = .reviewRequired })).phrase.text, "Review required")
        XCTAssertEqual(line(last(facts(pullRequest(checks: .pending(since: 800))))).since, 800, "the checks' start")
        XCTAssertNil(line(last(facts(pullRequest(checks: .pending(since: nil))))).since, "no check started: no clock runs")
        XCTAssertEqual(line(last(facts(pullRequest(checks: .failed(["test"]))))).since, 900, "since its last activity")
        XCTAssertEqual(line(last(facts(pullRequest(), activity: .needsYou("a question")))).since, 900, "how long it has waited")
        XCTAssertEqual(line(last(facts(pullRequest(53, base: "stack/a", stack: child)))).since, 900)
        XCTAssertEqual(line(last(facts(pullRequest(), reviews: nil))).since, 900, "at rest: since its last activity")
        XCTAssertNil(line(last(facts(pullRequest()))).since, "ready: no clock runs")
        XCTAssertNil(line(last(with(facts(pullRequest())) { $0.blocker = "upstream" })).since, "blocked: no clock runs")
        XCTAssertNil(line(last(facts(pullRequest(merged: true)))).since, "merged: no clock runs")
    }
}
