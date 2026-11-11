import XCTest
@testable import Nirux

/// One line of the Board as stages (docs/board-stages.md): the station a
/// task is at, its state, its rail, its phrase, its pull request and its
/// time, from what Nirux knows of it. Pure: nothing runs git or gh.
final class BoardStagesLineTests: XCTestCase {
    private typealias Facts = BoardStages.Facts

    private let head = String(repeating: "a", count: 40)
    private let now: TimeInterval = 100_000

    /// Review passes on the current HEAD (`fresh`) or on an earlier commit
    /// (`stale`), each started at `at`.
    private func reviews(fresh: [ReviewPass] = [], stale: [ReviewPass] = [], at: TimeInterval = 500) -> ReviewBadges {
        var runs: [ReviewPass: ReviewRun] = [:]
        for pass in fresh { runs[pass] = ReviewRun(head: head, at: at) }
        for pass in stale { runs[pass] = ReviewRun(head: String(repeating: "b", count: 40), at: at) }
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

    /// A reviewed task with an open pull request, unless told otherwise.
    private func facts(
        _ pullRequest: BoardStages.PullRequest? = nil, reviews: ReviewBadges? = nil,
        activity: BoardStages.Activity = .idle(), queue: BoardStages.Queue = BoardStages.Queue()
    ) -> Facts {
        var facts = Facts(id: "w1", title: "Agent loop hint")
        facts.pullRequest = pullRequest
        facts.reviews = reviews ?? self.reviews(fresh: [.codeReview])
        facts.activity = activity
        facts.queue = queue
        return facts
    }

    private func stack(parent: Int? = nil, chain: [Int] = [52, 53, 54], order: Int = 1, mergedBase: ProjectBoard.MergedBase? = nil)
        -> ProjectBoard.StackPlace {
        ProjectBoard.StackPlace(parent: parent, chain: chain, rootBase: "main", mergedBase: mergedBase, root: 52, order: order)
    }

    private func line(_ facts: Facts, rules: BoardStages.Rules = BoardStages.Rules()) -> BoardStages.Line {
        BoardStages.line(facts, rules: rules, now: now)
    }

    // MARK: - Stations

    func testTheStationIsTheFirstOneNotDone() {
        let none = reviews()
        let cases: [(Facts, BoardStages.Station, String)] = [
            (facts(reviews: none), .code, "no review and no pull request: still coding"),
            (facts(pullRequest(draft: true), reviews: none), .code, "a draft nobody reviewed is still code"),
            (facts(reviews: reviews(stale: [.premortem])), .reviews, "any pass, on any commit, ends Code"),
            (facts(pullRequest(), reviews: none), .reviews, "a pull request marked ready ends Code"),
            (facts(pullRequest(), reviews: reviews(stale: [.codeReview])), .merge, "a commit after the code review doesn't send it back"),
            (facts(pullRequest(), reviews: reviews(fresh: [.premortem, .adversarial])), .reviews, "only the code review counts"),
            (facts(), .checks, "reviewed, no pull request yet: Checks can't start"),
            (facts(pullRequest(checks: .pending(since: nil))), .checks, "checks run"),
            (facts(pullRequest(checks: .failed(["test"]))), .checks, "a red check keeps it at Checks"),
            (facts(pullRequest()), .merge, "reviewed and green"),
            (facts(pullRequest(draft: true)), .merge, "a reviewed green draft waits at Merge"),
            (facts(pullRequest(merged: true), reviews: none), .merge, "merged, whatever its reviews")
        ]
        for (facts, station, why) in cases {
            XCTAssertEqual(BoardStages.station(of: facts), station, why)
        }
        var folder = facts()
        folder.hasRepository = false
        XCTAssertEqual(BoardStages.station(of: folder), .code, "a task without a repository has no stations to go through")
    }

    func testReviewsStaysCurrentUntilTheTurnThatStartedTheReviewIsOver() {
        // The badge is recorded as the pass starts, at 500.
        let reviewing = facts(pullRequest(), activity: .working(since: 400))
        XCTAssertEqual(BoardStages.station(of: reviewing), .reviews, "the review still runs")
        let laterTurn = facts(pullRequest(), activity: .working(since: 600))
        XCTAssertEqual(BoardStages.station(of: laterTurn), .merge, "a turn started after the review doesn't undo it")
        XCTAssertEqual(BoardStages.station(of: facts(pullRequest(), activity: .working(since: nil))), .merge)
    }

    func testTheRulesNameTheReviewsThatCount() {
        let both = BoardStages.Rules(requiredReviews: [.codeReview, .premortem])
        XCTAssertEqual(line(facts(pullRequest()), rules: both).station, .reviews, "the premortem is missing")
        XCTAssertEqual(line(facts(pullRequest()), rules: both).phrase.text, "No premortem yet")
        let reviewed = facts(pullRequest(), reviews: reviews(fresh: [.codeReview, .premortem]))
        XCTAssertEqual(BoardStages.station(of: reviewed, rules: both), .merge)
        let unreviewed = facts(pullRequest(), reviews: reviews())
        XCTAssertEqual(BoardStages.station(of: unreviewed, rules: BoardStages.Rules(requiredReviews: [])), .merge,
                       "no review asked for: none to wait for")
    }

    func testTheRulesMayAskForReviewsOnTheCurrentHead() {
        let strict = BoardStages.Rules(reviewsMustBeOnHead: true)
        let earlier = facts(pullRequest(), reviews: reviews(stale: [.codeReview]))
        XCTAssertEqual(line(earlier, rules: strict).station, .reviews, "a commit landed after the review")
        XCTAssertEqual(line(earlier, rules: strict).phrase.text, "No code review on this commit")
        XCTAssertEqual(line(facts(pullRequest()), rules: strict).station, .merge)
    }

    func testThePullRequestTheQueueWorksOnIsWhereTheQueueHasIt() {
        let unreviewed = reviews()
        var updating = facts(
            pullRequest(checks: .failed(["test"])), reviews: unreviewed,
            queue: BoardStages.Queue(order: 1, step: .checks("Updating branch"))
        )
        updating.blocker = "waits for the release"
        updating.lastActivityAt = now - 600
        let checking = line(updating)
        XCTAssertEqual(checking.station, .checks, "the user confirmed its head at Start: its reviews don't hold it")
        XCTAssertEqual(checking.state, .waiting, "the queue reruns a red check once: not a failure yet")
        XCTAssertEqual(checking.phrase.text, "Updating branch")
        XCTAssertEqual(checking.time, "", "the queue's steps have no clock of the task's")
        let merging = line(facts(pullRequest(), reviews: unreviewed, queue: BoardStages.Queue(order: 1, step: .merge("Waiting for nightly"))))
        XCTAssertEqual(merging.station, .merge)
        XCTAssertEqual(merging.phrase.text, "Waiting for nightly")
    }

    // MARK: - The rail

    func testTheRailFillsWhatIsDoneAndCarriesTheQueueOrder() {
        let checking = line(facts(pullRequest(checks: .pending(since: nil)), queue: BoardStages.Queue(order: 2)))
        XCTAssertEqual(checking.rail, BoardStages.Rail(marks: [.done, .done, .current, .ahead], queueOrder: 2))
        let queuedUnreviewed = line(facts(pullRequest(), reviews: reviews(), queue: BoardStages.Queue(order: 1)))
        XCTAssertEqual(queuedUnreviewed.rail, BoardStages.Rail(marks: [.done, .current, .ahead, .ahead], queueOrder: 1),
                       "the list is the user's: its number shows before the line reaches Merge")
        let merged = line(facts(pullRequest(merged: true), queue: BoardStages.Queue(order: 1)))
        XCTAssertEqual(merged.rail, BoardStages.Rail(marks: [.done, .done, .done, .done], queueOrder: nil))
    }

    func testAReviewOlderThanHeadMarksItsStation() {
        let earlier = reviews(fresh: [.premortem], stale: [.codeReview])
        XCTAssertEqual(line(facts(pullRequest(checks: .pending(since: nil)), reviews: earlier)).rail?.marks,
                       [.done, .doneEarlier, .current, .ahead], "commits landed since the code review")
        XCTAssertEqual(line(facts(pullRequest(merged: true), reviews: earlier)).rail?.marks, [.done, .doneEarlier, .done, .done])
        let unknownHead = ReviewBadges(runs: earlier.runs, head: nil)
        XCTAssertEqual(line(facts(pullRequest(), reviews: unknownHead)).rail?.marks, [.done, .done, .done, .current],
                       "HEAD not read yet: no review reads as older")
        let otherPassEarlier = reviews(fresh: [.codeReview], stale: [.premortem])
        XCTAssertEqual(line(facts(pullRequest(), reviews: otherPassEarlier)).rail?.marks, [.done, .done, .done, .current],
                       "only the reviews that count mark the station")
    }

    func testAPullRequestWithoutATaskHasNoReviewsStation() {
        var remote = facts(pullRequest(checks: .pending(since: nil)), reviews: reviews())
        remote.hasTask = false
        XCTAssertEqual(line(remote).rail?.marks, [.done, .skipped, .current, .ahead], "nothing here could have seen a review")
        remote.pullRequest = pullRequest()
        XCTAssertEqual(line(remote).phrase.text, "Ready · checks green")
        remote.pullRequest = pullRequest(draft: true)
        XCTAssertEqual(line(remote).rail?.marks, [.current, .skipped, .ahead, .ahead])
        XCTAssertEqual(line(remote).phrase.text, "Draft")
    }

    func testATaskWithoutARepositoryHasNoRailAndNoPullRequestCell() {
        var folder = facts(reviews: reviews())
        folder.hasRepository = false
        XCTAssertNil(line(folder).rail)
        XCTAssertEqual(line(folder).pullRequest, "")
        XCTAssertEqual(line(folder).phrase.text, "No activity yet")
    }

    // MARK: - States

    func testTheStateIsTheFirstThatHolds() {
        let green = pullRequest()
        let red = pullRequest(checks: .failed(["test"]))
        let problem = BoardStages.QueueStop(label: "changed", message: "#52 changed since you confirmed it.", isProblem: true)
        let byUser = BoardStages.QueueStop(label: "by you", message: "Stopped.", isProblem: false)
        var blocked = facts(pullRequest(checks: .pending(since: nil)))
        blocked.blocker = "  waits for upstream \n"
        var blockedRed = facts(red)
        blockedRed.blocker = "waits for upstream"
        var blockedWithoutPullRequest = facts(reviews: reviews())
        blockedWithoutPullRequest.blocker = "waits for upstream"
        var blockedWorking = facts(green, activity: .working(since: nil))
        blockedWorking.blocker = "waits for upstream"
        let cases: [(Facts, BoardStages.State, String)] = [
            (facts(pullRequest(merged: true), activity: .needsYou("a question")), .needsYou, "amber is never hidden, even once merged"),
            (facts(pullRequest(merged: true), activity: .working(since: nil)), .merged, "merged, whatever its agent does next"),
            (facts(red, activity: .needsYou("a question")), .needsYou, "the user comes before a red check"),
            (facts(green, activity: .failed("Stopped on an API error")), .failed, "an agent that stopped"),
            (facts(red, activity: .working(since: nil)), .working, "an agent is on the red check"),
            (blockedWorking, .working, "work goes on despite the blocker"),
            (facts(green, queue: BoardStages.Queue(stop: problem)), .failed, "the last queue stopped on it"),
            (facts(green, queue: BoardStages.Queue(stop: byUser)), .ready, "Stop pressed is no failure"),
            (facts(pullRequest(conflicting: true)), .failed, "a conflict"),
            (facts(red, reviews: reviews()), .failed, "a red check shows at any station"),
            (blockedRed, .failed, "a red check comes before the blocker, as on the sidebar"),
            (blocked, .blocked, "a blocker comes before what the station waits for"),
            (blockedWithoutPullRequest, .blocked, "a blocker needs no pull request"),
            (facts(pullRequest(checks: .pending(since: nil))), .waiting, "checks run"),
            (facts(pullRequest(checks: .pending(since: nil)), reviews: reviews()), .idle,
             "at Reviews, running checks aren't what it waits for"),
            (facts(green), .ready, "at Merge, nothing refuses it"),
            (facts(pullRequest(draft: true)), .idle, "a draft isn't ready"),
            (facts(pullRequest(base: "release")), .idle, "the queue takes the base branch only"),
            (facts(pullRequest(53, base: "stack/a", stack: stack(parent: 52))), .waiting, "waits for the one before in its stack"),
            (facts(pullRequest(53, base: "stack/a", stack: stack(mergedBase: ProjectBoard.MergedBase(number: 52, onto: "main")))),
             .idle, "waits for the user's Retarget"),
            (facts(reviews: reviews()), .idle, "nothing goes on")
        ]
        for (facts, state, why) in cases {
            XCTAssertEqual(line(facts).state, state, why)
        }
    }

    // MARK: - Phrases

    func testThePhraseSaysWhatTheLineDoesAtItsStation() {
        let red = pullRequest(checks: .failed(["test", "lint"]))
        var flaky = facts(red)
        flaky.flakyReason = "CatchUpTests timed out on a slow runner"
        var working = facts(red, activity: .working(since: nil))
        working.statusLine = "Round 1 fixes\nafter the code review"
        var asking = facts(pullRequest(checks: .pending(since: nil)), activity: .idle(note: "Asking Lead"))
        asking.blocker = "waits for upstream"
        var blocked = facts(pullRequest())
        blocked.blocker = "waits for upstream"
        var atRest = facts(pullRequest(), reviews: reviews())
        atRest.statusLine = "Fixes pushed"
        var withNext = atRest
        withNext.nextStep = "run the confirmation review"
        var archived = facts(pullRequest(), reviews: reviews())
        archived.isArchived = true
        var idle = facts(reviews: reviews())
        idle.lastActivityAt = now - 60
        var cleanUp = facts(pullRequest(merged: true))
        cleanUp.offersCleanUp = true
        let stop = BoardStages.QueueStop(label: "changed", message: "#52 changed since you confirmed it.", isProblem: true)
        let mergedBase = stack(chain: [53], order: 0, mergedBase: ProjectBoard.MergedBase(number: 52, onto: "main"))
        let cases: [(Facts, String, String)] = [
            (facts(red, activity: .needsYou("Bash(swift test)")), "Needs you · Bash(swift test)", "the sidebar's words"),
            (facts(red, activity: .failed("Stopped on an API error")), "Stopped on an API error", "the agent's failure"),
            (working, "Round 1 fixes after the code review", "where the task stands, on one line"),
            (facts(red, activity: .working(since: nil)), "Working", "no status line yet"),
            (facts(pullRequest(conflicting: true), queue: BoardStages.Queue(stop: stop)), "Queue stopped: changed", "the stop first"),
            (facts(pullRequest(checks: .failed([]), conflicting: true, base: "develop")), "Conflicts with develop", "its own base"),
            (facts(red), "Checks failed: test, lint", "the red checks by name"),
            (flaky, "Checks failed · likely flaky", "only the triage's verdict says more"),
            (asking, "Asking Lead", "what it waits for comes before the blocker"),
            (blocked, "Blocked · waits for upstream", "the blocker before Ready"),
            (facts(pullRequest(53, checks: .pending(since: nil), base: "stack/a", stack: stack(parent: 52))),
             "Checks running · lands after #52", "a stack says what it follows"),
            (facts(pullRequest(53, base: "stack/a", stack: stack(parent: 52))), "Lands after #52", "green, but not its turn"),
            (facts(pullRequest(53, checks: .pending(since: nil), base: "stack/a", stack: mergedBase)),
             "Base #52 merged · Retarget to main", "whatever its station: nothing lands on a merged branch"),
            (facts(pullRequest(draft: true)), "Draft · checks green", "why a green one isn't ready"),
            (facts(pullRequest(base: "release")), "Targets release", "another base than the queue's"),
            (facts(pullRequest()), "Ready · reviews done, checks green", "ready"),
            (withNext, "Next · run the confirmation review", "at rest, the next step first"),
            (atRest, "Fixes pushed", "then where the task stands"),
            (archived, "Archived", "an archived task with nothing to say"),
            (facts(pullRequest(), reviews: reviews()), "No code review yet", "what Reviews waits for"),
            (facts(), "No pull request yet", "what Checks waits for"),
            (idle, "Idle", "at Code, after some activity"),
            (facts(pullRequest(merged: true), activity: .failed("Stopped on an API error")), "Merged", "merged"),
            (facts(pullRequest(merged: true), activity: .needsYou("a question")), "Needs you · a question", "asked after the merge"),
            (cleanUp, "Merged · Clean up", "its worktree is still there")
        ]
        for (facts, text, why) in cases {
            XCTAssertEqual(line(facts).phrase.text, text, why)
        }
        XCTAssertEqual(line(flaky).phrase.detail, "CatchUpTests timed out on a slow runner")
        XCTAssertEqual(line(facts(pullRequest(), queue: BoardStages.Queue(stop: stop))).phrase.detail,
                       "#52 changed since you confirmed it.")
        XCTAssertEqual(line(cleanUp).phrase.link, .cleanUp)
        let retarget = line(facts(pullRequest(53, base: "stack/a", stack: mergedBase))).phrase
        XCTAssertEqual(retarget.link, .retarget(number: 53, onto: "main"))
        XCTAssertTrue(retarget.text.hasSuffix(BoardStages.Link.retarget(number: 53, onto: "main").title), "the link ends the phrase")
    }

    // MARK: - Pull request and time

    func testThePullRequestCellSaysItsPlaceInAStack() {
        XCTAssertEqual(line(facts(pullRequest())).pullRequest, "#52")
        XCTAssertEqual(line(facts(pullRequest(53, stack: stack(parent: 52)))).pullRequest, "#53 · 2/3")
        XCTAssertEqual(line(facts(pullRequest(53, stack: stack(parent: 52, chain: [])))).pullRequest, "#53 · on #52", "a fork")
        XCTAssertEqual(line(facts()).pullRequest, "no PR yet")
    }

    func testTheTimeCountsWhatTheLineWaitsOn() {
        var working = facts(pullRequest(), activity: .working(since: now - 12 * 60))
        working.lastActivityAt = now - 5
        XCTAssertEqual(line(working).time, "12 min", "the turn's time")
        var checking = facts(pullRequest(checks: .pending(since: now - 4 * 60)))
        checking.lastActivityAt = now - 3 * 3600
        XCTAssertEqual(line(checking).time, "4 min", "since the checks started")
        checking.pullRequest = pullRequest(checks: .pending(since: nil))
        XCTAssertEqual(line(checking).time, "3 h", "no check started yet: since the last activity")
        var failed = facts(pullRequest(checks: .failed(["test"])))
        failed.lastActivityAt = now - 2 * 86_400
        XCTAssertEqual(line(failed).time, "2 d")
        var ready = facts(pullRequest())
        ready.lastActivityAt = now - 600
        XCTAssertEqual(line(ready).time, "", "ready: no clock runs")
        ready.blocker = "waits for upstream"
        XCTAssertEqual(line(ready).time, "", "blocked: no clock runs")
        XCTAssertEqual(BoardStages.duration(59), "now")
        XCTAssertEqual(BoardStages.duration(59 * 60 + 59), "59 min")
        XCTAssertEqual(BoardStages.duration(3600), "1 h")
        XCTAssertEqual(BoardStages.duration(-120), "now", "a clock that went back")
    }
}
