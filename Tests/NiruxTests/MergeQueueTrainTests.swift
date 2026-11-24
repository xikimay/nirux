import XCTest
@testable import Nirux

/// The Train cadence against a GitHub that answers its calls as the probe
/// on a throwaway base saw it (#779–#784): no branch update, one merge,
/// each pull request reads merged by itself.
final class MergeQueueTrainTests: XCTestCase {
    private let a = MQ.sha("a")
    private let b = MQ.sha("b")
    private let c = MQ.sha("c")
    private let branch = "nirux-train/queue"

    private func world() -> MQ.World {
        var world = MQ.World()
        world.pullRequests[12] = MQ.pullRequest(12, head: a)
        world.pullRequests[14] = MQ.pullRequest(14, head: b)
        world.defaultChecks = MQ.checks(MQ.checkRun(id: 1))
        return world
    }

    private func queue(triagesFlakes: Bool = false) -> MQ.Harness {
        var queue = MQ.Harness(entries: [], cadence: .train)
        queue.engine = MergeQueue.Engine(settings: MQ.settings(), entries: [MQ.entry(12, head: a), MQ.entry(14, head: b)],
                                         cadence: .train, triagesFlakes: triagesFlakes)
        queue.start()
        return queue
    }

    func testATrainLandsTheBatchInOneMergeAndEachPullRequestReadsMerged() throws {
        var github = TrainGitHub(world: world())
        var queue = queue()
        queue.drive(&github)

        XCTAssertEqual(queue.phase, .finished)
        let head = TrainGitHub.commit(2)
        XCTAssertEqual(queue.mutations.map(MergeQueue.Engine.describe), [
            "creation of branch \(branch) at \(MergeQueue.Engine.short(MQ.sha("0")))",
            "merge of aaaaaaa into \(branch)",
            "merge of bbbbbbb into \(branch)",
            "pull request of \(branch) into main",
            "merge of #900 at \(MergeQueue.Engine.short(head))",
            "deletion of branch \(branch)",
        ])
        XCTAssertNil(github.world.branches[branch], "the train's branch goes once it landed")
        XCTAssertEqual(queue.mutations[1], .mergeIntoBranch(branch: branch, head: a, message: "Merge pull request #12 from acme/feat/12"))
        guard case .openPullRequest(_, _, let title, let body) = queue.mutations[3] else { return XCTFail("no pull request opened") }
        XCTAssertEqual(title, "Merge train: #12, #14")
        XCTAssertTrue(body.contains("- #14 at \(b)"))
        let train = try XCTUnwrap(queue.engine.train)
        XCTAssertEqual(train.parts, [.init(number: 12, commit: TrainGitHub.commit(1)), .init(number: 14, commit: head)])
        XCTAssertEqual(train.mergeCommit, github.world.mainTip)
        XCTAssertEqual(queue.engine.entries.map(\.step), [.done, .done])
        XCTAssertEqual(queue.engine.entries.map(\.mergeCommit), [TrainGitHub.commit(1), head])
        XCTAssertEqual(queue.notes.filter { $0.message.contains("succeeded") }.map(\.message), ["The nightly of train #900 succeeded"])
        XCTAssertTrue(queue.notes.contains { $0.number == 900 && $0.step == "train" && $0.message == "#12, #14 read merged" })
    }

    func testATrainStopsLoudlyWhenAPullRequestDoesNotReadMergedOnceItLands() throws {
        var github = TrainGitHub(world: world())
        github.marksMerged = false
        var queue = queue()
        queue.drive(&github)

        let reason = try XCTUnwrap(queue.stopReason)
        XCTAssertEqual(reason.kind, .merge)
        XCTAssertTrue(reason.message.contains("GitHub still shows #12, #14 open 3 minutes later"), reason.message)
        XCTAssertEqual(github.world.pullRequests[900]?.state, .merged)
        XCTAssertEqual(queue.engine.entries.map(\.step), [.stopped(reason), .stopped(reason)])
    }

    func testATrainOnlyTakesPullRequestsWhoseChecksAreGreen() throws {
        var world = world()
        world.checks[b] = MQ.checks(MQ.checkRun(id: 2, conclusion: "FAILURE"))
        var github = TrainGitHub(world: world)
        var queue = queue()
        queue.drive(&github)

        let reason = try XCTUnwrap(queue.stopReason)
        XCTAssertEqual(reason.kind, .checks)
        XCTAssertTrue(reason.message.hasPrefix("Required check Tests / test failed on #14 at bbbbbbb"), reason.message)
        XCTAssertEqual(queue.mutations, [])
        XCTAssertEqual(queue.engine.entries.map(\.step), [.waiting, .stopped(reason)])
    }

    func testAPullRequestThatConflictsLeavesTheTrainWhichLandsTheOthers() throws {
        var github = TrainGitHub(world: world())
        github.conflicts = [b]
        var queue = queue()
        queue.drive(&github)

        let reason = try XCTUnwrap(queue.stopReason)
        XCTAssertEqual(reason.kind, .conflict)
        XCTAssertEqual(reason.message, "#14 conflicts with main or with #12, merged before it in the train. It left the train. "
            + "Train #900 landed #12.")
        guard case .openPullRequest(_, _, let title, _) = queue.mutations[3] else { return XCTFail("no pull request opened") }
        XCTAssertEqual(title, "Merge train: #12")
        XCTAssertEqual(queue.engine.entries.map(\.step), [.done, .stopped(reason)])
        XCTAssertEqual(github.world.pullRequests[12]?.state, .merged)
        let saved = MergeQueue.SavedQueue(engine: queue.engine, dryRun: false, savedAt: Date())
        XCTAssertEqual(MergeQueue.Conflict(saved: saved, repository: MQ.widgets, dryRun: false)?.number, 14,
                       "Ask Agent to Resolve: #12 is on main now")
        XCTAssertNil(github.world.branches[branch], "deleted once the train landed")

        var world = world()
        world.pullRequests[12] = MQ.pullRequest(12, head: a, mergeable: "CONFLICTING")
        var preflight = TrainGitHub(world: world)
        var second = self.queue()
        second.drive(&preflight)
        XCTAssertEqual(second.stopReason?.message, "#12 conflicts with main. It left the train. Train #900 landed #14.")
        XCTAssertEqual(second.mutations.filter { if case .mergeIntoBranch = $0 { true } else { false } }.count, 1)

        var both = TrainGitHub(world: self.world())
        both.conflicts = [a, b]
        var none = self.queue()
        none.drive(&both)
        XCTAssertEqual(none.stopReason?.message, "#12 conflicts with main. It left the train. #14 left the train too. Nirux deleted the train’s branch \(branch).")
        XCTAssertNil(both.world.pullRequests[900], "nothing left to open")
    }

    func testAStopTheTrainFindsClosesItsPullRequestAndAStopOfTheUserDoesNot() throws {
        var world = world()
        world.checks[TrainGitHub.commit(2)] = MQ.checks(MQ.checkRun(id: 9, conclusion: "FAILURE"))
        var red = TrainGitHub(world: world)
        var first = queue()
        first.drive(&red)
        let reason = try XCTUnwrap(first.stopReason)
        XCTAssertEqual(reason.kind, .checks)
        XCTAssertTrue(reason.message.hasSuffix("failed on train #900 at 0000002. Nirux closed train #900. Nirux deleted the train’s branch \(branch)."), reason.message)
        XCTAssertEqual(first.mutations.suffix(2), [.closePullRequest(number: 900), .deleteBranch(name: branch)])
        XCTAssertEqual(red.world.pullRequests[900]?.state, .closed)

        var refusing = TrainGitHub(world: world)
        refusing.refusesClose = true
        var second = queue()
        second.drive(&refusing)
        XCTAssertTrue(second.stopReason?.message.hasSuffix("Nirux couldn’t close train #900: HTTP 403: Resource not accessible. "
            + "Train #900 stays open on GitHub: close it rather than merge it.") == true, second.stopReason?.message ?? "")

        var waiting = TrainGitHub(world: self.world())
        var third = queue()
        while third.engine.request.map({ request in
            if case .read(let reads, _) = request.action { return !reads.contains(.checks(TrainGitHub.commit(2))) }
            return true
        }) == true {
            if let mutation = third.pendingMutation { third.mutated(waiting.apply(mutation)) } else { third.answer(waiting.world) }
        }
        third.send(.stop)
        XCTAssertEqual(third.stopReason?.message, "Stopped by the user. Train #900 stays open on GitHub: close it rather than merge it.")
        XCTAssertFalse(third.mutations.contains(.closePullRequest(number: 900)))
    }

    /// A busy agent holds the train 10 minutes at most: then its rider
    /// leaves the train, which lands the others; the queue stops on it after.
    func testABusyAgentsRiderLeavesTheTrainAfterTenMinutes() throws {
        var world = world()
        world.locals["feat/14"] = MergeQueue.LocalState(busyAgents: ["claude working in “api”"])
        var github = TrainGitHub(world: world)
        var queue = queue()
        let start = queue.now
        queue.drive(&github)

        let reason = try XCTUnwrap(queue.stopReason)
        XCTAssertEqual(reason.kind, .agentBusy)
        XCTAssertTrue(reason.message.hasPrefix("An agent of #14 is still busy after 10 minutes: claude working in “api”. It left the train."),
                      reason.message)
        XCTAssertTrue(queue.notes.contains { $0.message.hasPrefix("#14 left the train") })
        XCTAssertGreaterThanOrEqual(queue.now - start, MergeQueue.Limits.agentWait)
        XCTAssertEqual(queue.notes.filter { $0.message.hasPrefix("Waiting up to 10 minutes") }.count, 1)
        XCTAssertFalse(queue.mutations.isEmpty, "the others went on")
    }

    func testAPushAfterTheLastCheckStopsOnThatPullRequestOnceTheTrainLands() throws {
        var github = TrainGitHub(world: world())
        github.pushesAfterLanding = [14: c]
        var queue = queue()
        queue.drive(&github)

        let reason = try XCTUnwrap(queue.stopReason)
        XCTAssertEqual(reason.kind, .changed)
        XCTAssertEqual(reason.message, "#14 moved to ccccccc after train #900’s last check: the train landed bbbbbbb, and #14 stays "
            + "open with the commits after it. Train #900 landed #12, #14.")
        XCTAssertEqual(queue.engine.entries.map(\.step), [.done, .stopped(reason)])
        XCTAssertTrue(queue.notes.contains { $0.message == "#12 read merged" })
        XCTAssertTrue(queue.notes.contains { $0.message == "The nightly of train #900 succeeded" }, "the landed train's run is still read")
    }

    func testStopWhileComposingStopsTheWholeTrainAndDeletesItsBranch() throws {
        var github = TrainGitHub(world: world())
        var queue = queue()
        queue.run(&github) { if case .mergeIntoBranch(_, let head, _)? = $0.pendingMutation { head == b } else { false } }
        queue.send(.stop)
        queue.mutated(github.apply(try XCTUnwrap(queue.pendingMutation)))
        XCTAssertEqual(queue.pendingMutation, .deleteBranch(name: branch))
        queue.mutated(github.apply(try XCTUnwrap(queue.pendingMutation)))
        let reason = try XCTUnwrap(queue.stopReason)
        XCTAssertEqual(reason.kind, .user)
        XCTAssertTrue(reason.message.hasSuffix("Nirux deleted the train’s branch \(branch)."), reason.message)
        XCTAssertNil(github.world.branches[branch])
        XCTAssertEqual(queue.engine.entries.map(\.step), [.stopped(reason), .stopped(reason)])

        // GitHub not answering mid-compose: the branch stays, named.
        var failing = TrainGitHub(world: world())
        var second = self.queue()
        // The read after a part's merge: the train exists then.
        second.run(&failing) { $0.engine.train != nil && $0.pendingReads?.contains(.branch(self.branch)) == true }
        second.fail(.refused("HTTP 500"))
        XCTAssertTrue(second.stopReason?.message.hasSuffix("The train’s branch \(branch) stays on GitHub.") == true,
                      second.stopReason?.message ?? "")
    }

    func testAStopWhileTheTrainOpensWaitsForItOrNamesItsBranch() throws {
        var late = TrainGitHub(world: world())
        late.hidesTrainOnce = true
        var first = queue()
        first.run(&late) { if case .openPullRequest? = $0.pendingMutation { true } else { false } }
        first.send(.stop)
        first.mutated(late.apply(try XCTUnwrap(first.pendingMutation)))
        first.drive(&late)
        let named = try XCTUnwrap(first.stopReason?.message)
        XCTAssertTrue(named.hasPrefix("Stopped by the user.") && named.hasSuffix("Train #900 stays open on GitHub: close it rather than merge it."),
                      named)

        let maybe = "A pull request of the train may be open from \(branch): close it rather than merge it."
        var reading = TrainGitHub(world: world())
        var second = queue()
        second.run(&reading) { $0.pendingReads?.contains(.pullRequests(head: self.branch)) == true }
        second.send(.stop)
        let stopped = try XCTUnwrap(second.stopReason?.message)
        XCTAssertTrue(stopped.hasPrefix("Stopped by the user.") && stopped.hasSuffix(maybe), stopped)

        var refusing = TrainGitHub(world: world())
        var third = queue()
        third.run(&refusing) { if case .openPullRequest? = $0.pendingMutation { true } else { false } }
        third.send(.stop)
        third.mutated(refusing.apply(try XCTUnwrap(third.pendingMutation)))
        third.fail(.refused("HTTP 502: Bad Gateway"))
        XCTAssertEqual(third.stopReason?.kind, .user)
        XCTAssertTrue(third.stopReason?.message.hasSuffix(maybe) == true, third.stopReason?.message ?? "")
    }

    func testAConflictThatLeftTheTrainIsWhatTheQueueStopsOnAfterALandingWithALatePush() throws {
        let d = MQ.sha("d")
        var world = world()
        world.pullRequests[16] = MQ.pullRequest(16, head: c)
        var github = TrainGitHub(world: world)
        github.conflicts = [c]
        github.pushesAfterLanding = [14: d]
        var queue = MQ.Harness(entries: [], cadence: .train)
        queue.engine = MergeQueue.Engine(settings: MQ.settings(), entries: [MQ.entry(12, head: a), MQ.entry(14, head: b), MQ.entry(16, head: c)],
                                         cadence: .train)
        queue.start()
        queue.drive(&github)
        let reason = try XCTUnwrap(queue.stopReason)
        XCTAssertEqual(reason.message, "#16 conflicts with main or with #12, #14, merged before it in the train. It left the train. "
            + "Train #900 landed #12, #14.")
        let saved = MergeQueue.SavedQueue(engine: queue.engine, dryRun: false, savedAt: Date())
        XCTAssertEqual(MergeQueue.Conflict(saved: saved, repository: MQ.widgets, dryRun: false)?.number, 16)
        guard case .stopped(let moved) = queue.engine.entries[1].step else { return XCTFail("#14 isn't stopped") }
        XCTAssertEqual(moved.kind, .changed)
    }

    func testAStopWhileTheBranchIsCreatedDeletesItOrSaysItWasSent() throws {
        var sent = TrainGitHub(world: world())
        var first = queue()
        first.run(&sent) { if case .createBranch? = $0.pendingMutation { true } else { false } }
        first.mutated(sent.apply(try XCTUnwrap(first.pendingMutation)))
        first.send(.stop)
        XCTAssertEqual(first.phase, .stopping, "deleting the branch")
        first.mutated(sent.apply(try XCTUnwrap(first.pendingMutation)))
        XCTAssertEqual(first.stopReason?.message, "Stopped by the user. Nirux deleted the train’s branch \(branch).")
        XCTAssertNil(sent.world.branches[branch])

        var uncertain = TrainGitHub(world: world())
        var second = queue()
        second.run(&uncertain) { if case .createBranch? = $0.pendingMutation { true } else { false } }
        second.mutated(.uncertain("gh timed out"))
        second.send(.stop)
        XCTAssertEqual(second.stopReason?.message, "Stopped by the user. The creation of branch \(branch) at 0000000 was sent and "
            + "GitHub didn’t show its effect yet: check it on GitHub.")
    }

    func testAStopAfterGitHubRefusedToOpenTheTrainDeletesItsBranchAtOnce() throws {
        var github = TrainGitHub(world: world())
        var queue = queue()
        queue.run(&github) { if case .openPullRequest? = $0.pendingMutation { true } else { false } }
        queue.send(.stop)
        queue.mutated(.refused(status: 422, message: "Validation Failed"))
        XCTAssertEqual(queue.pendingMutation, .deleteBranch(name: branch), "no minute spent looking for a pull request")
        queue.mutated(github.apply(try XCTUnwrap(queue.pendingMutation)))
        let message = try XCTUnwrap(queue.stopReason?.message)
        XCTAssertTrue(message.hasSuffix("answered: HTTP 422: Validation Failed. Nirux deleted the train’s branch \(branch)."), message)
        XCTAssertFalse(message.contains("may be open"))
    }

    func testACallSentWhileTheBranchIsCreatedIsNamedOnAStopOrAQuit() throws {
        var github = TrainGitHub(world: world())
        var queue = queue()
        queue.run(&github) { if case .createBranch? = $0.pendingMutation { true } else { false } }
        let saved = MergeQueue.SavedQueue(engine: queue.engine, dryRun: false, savedAt: Date()).interrupted()
        XCTAssertTrue(saved.stopReason?.message.hasSuffix("Its creation of branch \(branch) at 0000000 was sent but not answered: check it "
            + "on GitHub.") == true, saved.stopReason?.message ?? "")
        queue.mutated(.uncertain("gh timed out"))
        queue.fail(.refused("HTTP 500"))
        XCTAssertTrue(queue.stopReason?.message.contains("The creation of branch \(branch) at 0000000 was sent and GitHub didn’t show its "
            + "effect yet: check it on GitHub.") == true, queue.stopReason?.message ?? "")
    }

    func testATrainLandsOnlyOnTheTipItWasTestedOnWithEveryHeadAsConfirmed() throws {
        var moved = TrainGitHub(world: world())
        moved.world.behind[TrainGitHub.commit(2)] = 1
        var first = queue()
        first.drive(&moved)
        XCTAssertEqual(first.stopReason?.kind, .train)
        XCTAssertTrue(first.stopReason?.message.hasSuffix(" Nirux closed train #900. Nirux deleted the train’s branch \(branch).") == true, first.stopReason?.message ?? "")
        XCTAssertEqual(first.mutations.suffix(2), [.closePullRequest(number: 900), .deleteBranch(name: branch)], "no merge of the train")

        var pushed = TrainGitHub(world: world())
        pushed.pushesAfterOpen = [14: c]
        // The train's run still going: the push stops it all the same.
        pushed.world.checks[TrainGitHub.commit(2)] = MQ.checks(MQ.checkRun(id: 9, status: "IN_PROGRESS", conclusion: nil))
        var second = queue()
        second.drive(&pushed)
        let reason = try XCTUnwrap(second.stopReason)
        XCTAssertEqual(reason.kind, .changed)
        XCTAssertTrue(reason.message.hasPrefix("#14 changed since you confirmed it"), reason.message)
        XCTAssertEqual(second.mutations.suffix(2), [.closePullRequest(number: 900), .deleteBranch(name: branch)], "no merge of the train")
        XCTAssertEqual(second.engine.entries.map(\.step), [.waiting, .stopped(reason)])
        XCTAssertFalse(second.notes.contains { $0.message.hasPrefix("Merging") }, "seen while the train's checks ran")
    }

    func testATrainWaitsAMomentForItsNewPullRequestToShow() {
        var github = TrainGitHub(world: world())
        github.hidesTrainOnce = true
        var queue = queue()
        queue.drive(&github)
        XCTAssertEqual(queue.phase, .finished)
        XCTAssertFalse(github.hidesTrainOnce, "the first read missed it")
    }

    func testAnotherWriterOnTheTrainsBranchStopsIt() throws {
        var foreign = TrainGitHub(world: world())
        foreign.committer = "someone"
        var first = queue()
        first.drive(&foreign)
        XCTAssertEqual(first.stopReason?.kind, .train)
        XCTAssertTrue(first.stopReason?.message.hasSuffix("someone else pushed to it. The train’s branch \(branch) stays on GitHub.") == true,
                      first.stopReason?.message ?? "")

        var pushed = TrainGitHub(world: world())
        pushed.pushToTrainAfterOpen = c
        var second = queue()
        second.drive(&pushed)
        XCTAssertEqual(second.stopReason?.kind, .changed)
        XCTAssertTrue(second.stopReason?.message.hasPrefix("Someone pushed to train #900") == true, second.stopReason?.message ?? "")
        XCTAssertEqual(second.mutations.last, .closePullRequest(number: 900), "no merge of the train, nor a deletion of a branch someone pushed to")
    }

    func testAStopWhileClosingTheTrainKeepsItsReasonAndATrainMergedOutsideIsLeftAlone() throws {
        var world = world()
        world.checks[TrainGitHub.commit(2)] = MQ.checks(MQ.checkRun(id: 9, conclusion: "FAILURE"))
        var red = TrainGitHub(world: world)
        var queue = queue()
        while queue.pendingMutation != .closePullRequest(number: 900) {
            if let mutation = queue.pendingMutation { queue.mutated(red.apply(mutation)) } else { queue.answer(red.world) }
        }
        XCTAssertTrue(queue.engine.statusText.hasPrefix("closing train #900: Required check Tests / test failed"),
                      queue.engine.statusText)
        let saved = MergeQueue.SavedQueue(engine: queue.engine, dryRun: false, savedAt: Date()).interrupted()
        XCTAssertTrue(saved.stopReason?.message.hasPrefix("Interrupted while closing train #900: Required check") == true)
        queue.send(.stop)
        queue.mutated(red.apply(.closePullRequest(number: 900)))
        queue.mutated(red.apply(try XCTUnwrap(queue.pendingMutation)))
        let reason = try XCTUnwrap(queue.stopReason)
        XCTAssertEqual(reason.kind, .checks)
        XCTAssertTrue(reason.message.hasSuffix("Nirux closed train #900. Nirux deleted the train’s branch \(branch)."), reason.message)

        var outside = TrainGitHub(world: self.world())
        var second = self.queue()
        while second.engine.request.map({ request in
            if case .read(let reads, _) = request.action { return !reads.contains(.checks(TrainGitHub.commit(2))) }
            return true
        }) == true {
            if let mutation = second.pendingMutation { second.mutated(outside.apply(mutation)) } else { second.answer(outside.world) }
        }
        outside.world.merge(900, as: TrainGitHub.commit(9))
        second.drive(&outside)
        XCTAssertEqual(second.stopReason?.message, "#900 is merged, no longer open. Nirux deleted the train’s branch \(branch).")
        XCTAssertFalse(second.mutations.contains(.closePullRequest(number: 900)))
    }

    func testEveryPullRequestThatLeftTheTrainIsNamed() throws {
        var world = world()
        world.pullRequests[16] = MQ.pullRequest(16, head: c)
        var github = TrainGitHub(world: world)
        github.conflicts = [b, c]
        var queue = MQ.Harness(entries: [MQ.entry(12, head: a), MQ.entry(14, head: b), MQ.entry(16, head: c)], cadence: .train)
        queue.start()
        queue.drive(&github)
        XCTAssertEqual(queue.stopReason?.message, "#14 conflicts with main or with #12, merged before it in the train. It left the "
            + "train. #16 left the train too. Train #900 landed #12.")
    }

    func testARedTrainTheTriageCallsFlakyIsRerunOnceAndOnlyThen() throws {
        let head = TrainGitHub.commit(2)
        var world = world()
        world.checks[head] = MQ.checks(MQ.checkRun(id: 9, conclusion: "FAILURE"))
        world.triage = .verdict(.flaky(reason: "a runner lost its connection"))
        var flaky = TrainGitHub(world: world)
        flaky.rerunsGreen = [head]
        flaky.rerunAnswer = .uncertain("gh timed out")
        var first = queue(triagesFlakes: true)
        first.drive(&flaky)
        XCTAssertEqual(first.phase, .finished)
        XCTAssertEqual(first.mutations.filter { if case .rerun = $0 { true } else { false } }, [.rerun(runID: 900)])
        XCTAssertTrue(first.noted("Required check is likely flaky (a runner lost its connection): rerunning the failed jobs of run 900, once"))
        XCTAssertTrue(first.noted("The rerun started despite the error"))

        var stillRed = TrainGitHub(world: world)
        var second = queue(triagesFlakes: true)
        second.drive(&stillRed)
        XCTAssertTrue(second.stopReason?.message.hasPrefix("Required check Tests / test failed on train #900 at 0000002 again after "
            + "its rerun.") == true, second.stopReason?.message ?? "")
        XCTAssertEqual(second.mutations.filter { if case .rerun = $0 { true } else { false } }.count, 1)

        world.triage = .verdict(.real)
        var real = TrainGitHub(world: world)
        var third = queue(triagesFlakes: true)
        third.drive(&real)
        XCTAssertEqual(third.stopReason?.kind, .checks)
        XCTAssertTrue(third.stopReason?.message.contains("The CI triage found a real failure.") == true)
        XCTAssertFalse(third.mutations.contains { if case .rerun = $0 { true } else { false } })

        // Triage off: no wait for the run's other jobs, no rerun.
        world.checks[head] = MQ.checks(MQ.checkRun(id: 9, conclusion: "FAILURE"),
                                       MQ.checkRun(id: 11, name: "lint", status: "IN_PROGRESS", conclusion: nil))
        var off = TrainGitHub(world: world)
        var fourth = queue()
        let start = fourth.now
        fourth.drive(&off)
        XCTAssertEqual(fourth.stopReason?.kind, .checks)
        XCTAssertLessThan(fourth.now - start, MergeQueue.Limits.pollInterval * 3, "it stopped at the first red look")
    }

    @MainActor
    func testTheDriverAsksTheAppsCITriageAboutARedTrain() {
        let head = TrainGitHub.commit(2)
        var world = world()
        world.checks[head] = MQ.checks(MQ.checkRun(id: 9, conclusion: "FAILURE"))
        var github = TrainGitHub(world: world)
        github.rerunsGreen = [head]
        let client = TrainClient(github)
        let asked = Asked()
        var local = MergeQueueLocalAccess(folders: { [] }, busyAgents: { _, _ in [] }, reviewTasks: { [] })
        local.triage = { run, pullRequest, checks in
            asked.add("\(run.repository) \(run.id) #\(pullRequest) \(checks.sorted())")
            return .verdict(.flaky(reason: "a runner went away"))
        }
        let driver = MergeQueueDriver(
            engine: MergeQueue.Engine(settings: MQ.settings(), entries: [MQ.entry(12, head: a), MQ.entry(14, head: b)], cadence: .train,
                                      triagesFlakes: true),
            client: client, local: local, clock: MergeQueueFlowTests.VirtualClock().queueClock
        )
        driver.start()
        waitUntil("the train ends") { !driver.engine.phase.isActive }
        XCTAssertEqual(driver.engine.phase, .finished)
        XCTAssertEqual(asked.all, ["github.com/acme/widgets 900 #900 [\"test\"]"])
        XCTAssertEqual(client.mutations.filter { if case .rerun = $0 { true } else { false } }, [.rerun(runID: 900)])
    }

    func testTheTriageSaysWhatItDidAndARedTrainDoesntWaitForever() throws {
        let head = TrainGitHub.commit(2)
        func stopped(_ answer: MergeQueue.TriageAnswer, checks: MergeQueue.CommitChecks? = nil) -> MQ.Harness {
            var world = self.world()
            world.checks[head] = checks ?? MQ.checks(MQ.checkRun(id: 9, conclusion: "FAILURE"))
            world.triage = answer
            var github = TrainGitHub(world: world)
            var queue = self.queue(triagesFlakes: true)
            queue.drive(&github)
            return queue
        }
        let unsure = stopped(.verdict(.unsure))
        XCTAssertTrue(unsure.stopReason?.message.contains("The CI triage read the run and couldn’t tell it from a flake.") == true)

        let unread = stopped(.unread("gh couldn’t read it"))
        XCTAssertTrue(unread.noted("The CI triage didn’t read run 900 (gh couldn’t read it): asking once more"))
        XCTAssertTrue(unread.stopReason?.message.contains("The CI triage didn’t read run 900 (gh couldn’t read it), so it wasn’t "
            + "rerun.") == true, unread.stopReason?.message ?? "")
        XCTAssertFalse(unread.mutations.contains { if case .rerun = $0 { true } else { false } })

        let off = stopped(.off)
        XCTAssertTrue(off.stopReason?.message.contains("The CI triage is off, so it wasn’t rerun.") == true)

        // A failure whose run's other jobs keep going: 10 minutes at most, not the checks' 30.
        let running = MQ.checks(MQ.checkRun(id: 9, conclusion: "FAILURE"), MQ.checkRun(id: 11, name: "lint", status: "IN_PROGRESS", conclusion: nil))
        var world = self.world()
        world.checks[head] = running
        world.triage = .verdict(.flaky(reason: "x"))
        var github = TrainGitHub(world: world)
        var queue = self.queue(triagesFlakes: true)
        let start = queue.now
        queue.drive(&github)
        XCTAssertTrue(queue.stopReason?.message.contains("Its run’s other jobs still ran 10 minutes later, so it wasn’t rerun.") == true,
                      queue.stopReason?.message ?? "")
        XCTAssertLessThan(queue.now - start, 20 * 60)
    }

    @MainActor
    func testATriageThatDoesntAnswerInTimeIsLate() async {
        let late = await MergeQueue.answer(within: 0.05, or: MergeQueue.TriageAnswer.unread("late")) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return .off
        }
        XCTAssertEqual(late, .unread("late"))
        let quick = await MergeQueue.answer(within: 5, or: MergeQueue.TriageAnswer.unread("late")) { .verdict(.real) }
        XCTAssertEqual(quick, .verdict(.real))
        XCTAssertEqual(MergeQueue.TriageAnswer(CITriageInvestigation.Outcome()), .unread("gh couldn’t read it"), "gh failed: not unsure")
        XCTAssertEqual(MergeQueue.TriageAnswer(CITriageInvestigation.Outcome(verdict: .real, wasRead: true)), .verdict(.real))
    }

    func testARefusedMergeOfTheTrainClosesIt() throws {
        var github = TrainGitHub(world: world())
        github.refusesMerge = true
        var queue = queue()
        queue.drive(&github)
        let reason = try XCTUnwrap(queue.stopReason)
        XCTAssertEqual(reason.kind, .merge)
        XCTAssertTrue(reason.message.hasSuffix("required. Nirux closed train #900. Nirux deleted the train’s branch \(branch)."), reason.message)
        XCTAssertEqual(github.world.pullRequests[900]?.state, .closed)
    }

    func testTheTrainsOwnChecksMustBeGreen() throws {
        let head = TrainGitHub.commit(2)
        let cases: [(MergeQueue.CommitChecks, String)] = [
            (MQ.checks(MQ.checkRun(id: 9, conclusion: "FAILURE")), "Required check Tests / test failed on train #900 at 0000002."),
            (MQ.checks(MQ.checkRun(id: 9, conclusion: "SKIPPED")), "Required check test (skipped) isn’t green on train #900"),
            (MQ.checks(MQ.checkRun(id: 9, status: "IN_PROGRESS", conclusion: nil)), "The checks of train #900 timed out after 30 minutes"),
            (MergeQueue.CommitChecks(), "The checks of train #900 timed out after 30 minutes: test (not started)"),
        ]
        for (checks, message) in cases {
            var world = world()
            world.checks[head] = checks
            var github = TrainGitHub(world: world)
            var queue = queue()
            queue.drive(&github)
            XCTAssertEqual(queue.stopReason?.kind, .checks, message)
            XCTAssertTrue(queue.stopReason?.message.hasPrefix(message) == true, queue.stopReason?.message ?? message)
            XCTAssertFalse(queue.mutations.contains { if case .merge = $0 { true } else { false } }, message)
        }

        // Green when waited for, running again at the merge's look: it waits again.
        var github = TrainGitHub(world: world())
        github.trainChecks = [MQ.checks(MQ.checkRun(id: 9)), MQ.checks(MQ.checkRun(id: 10, status: "IN_PROGRESS", conclusion: nil)),
                              MQ.checks(MQ.checkRun(id: 10))]
        var queue = queue()
        queue.drive(&github)
        XCTAssertEqual(queue.phase, .finished)
        XCTAssertTrue(queue.noted("A required check runs again: waiting for it"))
    }

    func testAMergeIntoTheTrainGitHubShowsLateIsWaitedFor() {
        var github = TrainGitHub(world: world())
        github.lagReads = 4
        var queue = queue()
        queue.drive(&github)
        XCTAssertEqual(queue.phase, .finished, String(describing: queue.stopReason))
    }

    func testOnceTheTrainLandedItsPullRequestsAreMergedWhateverStopsTheQueue() throws {
        var github = TrainGitHub(world: world())
        var queue = queue()
        while !(queue.pendingReads ?? []).contains(.pullRequest(12)) || github.world.pullRequests[900]?.state != .merged {
            if let mutation = queue.pendingMutation { queue.mutated(github.apply(mutation)) } else { queue.answer(github.world) }
        }
        let saved = MergeQueue.SavedQueue(engine: queue.engine, dryRun: false, savedAt: Date()).interrupted()
        XCTAssertEqual(saved.entries.map(\.step), [.done, .done])
        XCTAssertEqual(saved.entries.map(\.mergeCommit), [TrainGitHub.commit(1), TrainGitHub.commit(2)])
        queue.send(.stop)
        XCTAssertEqual(queue.stopReason?.kind, .user)
        XCTAssertEqual(queue.engine.entries.map(\.step), [.done, .done])
    }

    func testAStopWhileTheTrainOpensOrIsRefusedNamesItsPullRequest() throws {
        for refused in [false, true] {
            var github = TrainGitHub(world: world())
            github.refusesMerge = refused
            var queue = queue()
            while true {
                guard let mutation = queue.pendingMutation else { queue.answer(github.world); continue }
                if refused, case .merge = mutation { break }
                if !refused, case .openPullRequest = mutation { break }
                queue.mutated(github.apply(mutation))
            }
            queue.send(.stop)
            queue.mutated(github.apply(try XCTUnwrap(queue.pendingMutation)))
            if !refused { queue.answer(github.world) }
            XCTAssertTrue(queue.stopReason?.message.hasSuffix("Train #900 stays open on GitHub: close it rather than merge it.") == true,
                          queue.stopReason?.message ?? "")
            XCTAssertFalse(queue.mutations.contains(.deleteBranch(name: branch)), "a Stop leaves the train as it is")
        }
    }

    func testACancelledRequiredCheckOnTheTrainRunsAgainOnce() throws {
        let head = TrainGitHub.commit(2)
        var world = world()
        world.checks[head] = MQ.checks(MQ.checkRun(id: 9, conclusion: "CANCELLED"))
        var cancelled = TrainGitHub(world: world)
        cancelled.rerunsGreen = [head]
        // Another job of the run still going: the rerun waits for it.
        cancelled.trainChecks = [MQ.checks(MQ.checkRun(id: 9, conclusion: "CANCELLED"),
                                           MQ.checkRun(id: 11, name: "lint", status: "IN_PROGRESS", conclusion: nil))]
        var first = queue()
        first.drive(&cancelled)
        XCTAssertEqual(first.phase, .finished)
        XCTAssertEqual(first.mutations.filter { if case .rerun = $0 { true } else { false } }, [.rerun(runID: 900)])
        XCTAssertTrue(first.noted("Required check was cancelled: rerunning the failed jobs of run 900, once"))

        var again = TrainGitHub(world: world)
        var second = queue()
        second.drive(&again)
        XCTAssertTrue(second.stopReason?.message.hasPrefix("Required check Tests / test failed on train #900 at 0000002 again after "
            + "its rerun.") == true, second.stopReason?.message ?? "")
        XCTAssertEqual(second.mutations.filter { if case .rerun = $0 { true } else { false } }.count, 1)

        world.checks[head] = MQ.checks(MQ.checkRun(id: 9, conclusion: "FAILURE"))
        var failed = TrainGitHub(world: world)
        var third = queue()
        third.drive(&failed)
        XCTAssertEqual(third.stopReason?.kind, .checks)
        XCTAssertFalse(third.mutations.contains { if case .rerun = $0 { true } else { false } }, "a failure isn't rerun here")
    }

    func testADryRunStopsBeforeCreatingTheTrainsBranch() {
        var queue = queue()
        XCTAssertEqual(queue.run(world()), .createBranch(name: branch, commit: MQ.sha("0")))
        queue.mutated(.dryRun(command: "gh api", reason: "a test"))
        XCTAssertEqual(queue.stopReason?.kind, .dryRun)
    }

    func testAQueueInterruptedMidTrainNamesTheTrainAndStopsEachPullRequest() throws {
        var github = TrainGitHub(world: world())
        var queue = queue()
        while let request = queue.engine.request {
            guard case .mutate(let mutation) = request.action else {
                queue.answer(github.world)
                continue
            }
            if case .merge = mutation { break }
            queue.mutated(github.apply(mutation))
        }
        let saved = MergeQueue.SavedQueue(engine: queue.engine, dryRun: false, savedAt: Date()).interrupted()
        let message = try XCTUnwrap(saved.stopReason?.message)
        XCTAssertTrue(message.hasPrefix("Interrupted while merging train #900: Nirux quit."), message)
        XCTAssertTrue(message.hasSuffix("was sent but not answered: check train #900 on GitHub."), message)
        XCTAssertEqual(saved.entries.map(\.step), [.stopped(try XCTUnwrap(saved.stopReason)), .stopped(try XCTUnwrap(saved.stopReason))])

        var waiting = self.queue()
        var github2 = TrainGitHub(world: world())
        while case .read(let reads, _)? = waiting.engine.request?.action, !reads.contains(.checks(TrainGitHub.commit(2))) {
            waiting.answer(github2.world)
            if let mutation = waiting.pendingMutation { waiting.mutated(github2.apply(mutation)) }
        }
        let waitingSaved = MergeQueue.SavedQueue(engine: waiting.engine, dryRun: false, savedAt: Date()).interrupted()
        XCTAssertEqual(waitingSaved.stopReason?.message, "Interrupted while waiting for the checks of train #900: Nirux quit. "
            + "Train #900 stays open on GitHub: close it rather than merge it.")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("train-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        saved.save(to: url)
        XCTAssertEqual(MergeQueue.SavedQueue.load(from: url)?.train, saved.train)
    }

    func testATrainNeedsTheMergeMethodMerge() {
        let squash = MergeQueue.confirmation(MergeQueue.ConfirmationReading(settings: MQ.settings(mergeMethod: .squash), isDryRun: false))
        XCTAssertFalse(squash.offeredCadences.contains(.train))
        XCTAssertEqual(squash.refusal(for: .train), "A train needs the merge method “merge”: it lands each pull request’s own "
            + "commits, which a squash would replace.")
        XCTAssertEqual(squash.unavailableNotes.last, "Train unavailable. A train needs the merge method “merge”: it lands each "
            + "pull request’s own commits, which a squash would replace.")
        let merge = MergeQueue.confirmation(MergeQueue.ConfirmationReading(settings: MQ.settings(), isDryRun: false))
        XCTAssertNil(merge.refusal(for: .train))

        var red = MergeQueue.ConfirmationReading.Candidate(number: 14)
        red.checks = MQ.checks(MQ.checkRun(id: 2, conclusion: "FAILURE"))
        XCTAssertEqual(MergeQueue.trainCandidateRefusal(for: [red], settings: MQ.settings()),
                       "A train only takes pull requests whose checks are green: test isn’t green on #14.")
        red.checks = MQ.checks(MQ.checkRun(id: 2, status: "IN_PROGRESS", conclusion: nil))
        XCTAssertNil(MergeQueue.trainCandidateRefusal(for: [red], settings: MQ.settings()), "the train waits for running checks")
    }

    func testTheTrainsCallsAndReadsSpeakGitHubsAPI() {
        func arguments(_ mutation: MergeQueue.Mutation) -> [String] {
            GitHubCLIQueueClient.mutationArguments(mutation, repository: "acme/widgets")
        }
        let post = ["api", "--hostname", "github.com", "--method", "POST"]
        XCTAssertEqual(arguments(.createBranch(name: branch, commit: a)),
                       post + ["repos/acme/widgets/git/refs", "-f", "ref=refs/heads/\(branch)", "-f", "sha=\(a)"])
        XCTAssertEqual(arguments(.mergeIntoBranch(branch: branch, head: b, message: "Merge pull request #14 from acme/x")),
                       post + ["repos/acme/widgets/merges", "-f", "base=\(branch)", "-f", "head=\(b)",
                               "-f", "commit_message=Merge pull request #14 from acme/x"])
        XCTAssertEqual(arguments(.openPullRequest(base: "main", head: branch, title: "T", body: "@B")),
                       post + ["repos/acme/widgets/pulls", "-f", "base=main", "-f", "head=\(branch)", "-f", "title=T", "-f", "body=@B"])
        XCTAssertEqual(arguments(.closePullRequest(number: 900)),
                       ["api", "--hostname", "github.com", "--method", "PATCH", "repos/acme/widgets/pulls/900", "-f", "state=closed"])

        func data(_ json: String) -> Data { Data(json.utf8) }
        XCTAssertEqual(MergeQueue.parseBranchTip(data(#"{"data":{"repository":{"ref":null}}}"#)), .some(nil))
        XCTAssertEqual(MergeQueue.parseBranchTip(data(#"{"data":{"repository":{"ref":{"target":{"oid":"\#(a)"}}}}}"#)), .some(a))
        XCTAssertNil(MergeQueue.parseBranchTip(data(#"{"data":{"repository":{}}}"#)))

        let node = #"{"number":900,"state":"OPEN","isDraft":false,"url":"https://github.com/acme/widgets/pull/900","#
            + #""headRefName":"nirux-train/queue","headRefOid":"\#(c)","baseRefName":"main","#
            + #""headRepository":{"name":"widgets","owner":{"login":"acme"}},"mergeable":"MERGEABLE","isInMergeQueue":false,"#
            + #""autoMergeRequest":null,"mergeCommit":null}"#
        let found = MergeQueue.parsePullRequests(data(#"{"data":{"repository":{"pullRequests":{"nodes":["# + node + "]}}}}"))
        XCTAssertEqual(found?.map(\.number), [900])
        XCTAssertEqual(found?.first?.headOid, c)
        XCTAssertNil(MergeQueue.parsePullRequests(data(#"{"data":{"repository":{"pullRequests":{"nodes":[{"number":1}]}}}}"#)))
    }
}

/// GitHub's side of a train's calls: branches, merges made by `web-flow`,
/// the train's pull request (#900), and pull requests marked merged once
/// their heads land.
private struct TrainGitHub {
    var world: MQ.World
    /// Heads whose merge into the train conflicts (409).
    var conflicts: Set<String> = []
    var marksMerged = true
    /// Agents' pushes once the train's pull request is open.
    var pushesAfterOpen: [Int: String] = [:]
    var pushToTrainAfterOpen: String?
    /// Branch protection refuses the train's merge.
    var refusesMerge = false
    /// Heads whose rerun of failed jobs passes; any other's fails again.
    var rerunsGreen: Set<String> = []
    /// What gh answers a rerun it sent.
    var rerunAnswer = MergeQueue.MutationResult.sent
    var refusesClose = false
    /// Agents' pushes between the last check and the train's merge.
    var pushesAfterLanding: [Int: String] = [:]
    /// The first read of the train's pull request misses it.
    var hidesTrainOnce = false
    /// Reads of the train's branch that still show its tip before each merge.
    var lagReads = 0
    private(set) var staleTip: (tip: String, reads: Int)?
    /// The train head's checks at each read of them, then the world's.
    var trainChecks: [MergeQueue.CommitChecks] = []
    /// Who makes the merges into the train.
    var committer = "web-flow"
    /// Each head's merge commit in the train.
    private(set) var partCommits: [String: String] = [:]
    private var lastMerge: String?
    private var made = 0

    init(world: MQ.World) {
        self.world = world
    }

    /// The `n`th commit GitHub makes: "0000001eee…".
    static func commit(_ number: Int) -> String {
        String(format: "%07x", number) + String(repeating: "e", count: 33)
    }

    private mutating func newCommit() -> String {
        made += 1
        return Self.commit(made)
    }

    /// The world a read sees, with what GitHub shows late.
    mutating func world(for reads: [MergeQueue.Read]) -> MQ.World {
        var shown = world
        if hidesTrainOnce, reads.contains(where: { if case .pullRequests = $0 { true } else { false } }) {
            hidesTrainOnce = false
            shown.pullRequests[900] = nil
        }
        if let stale = staleTip, stale.reads > 0, reads.contains(.branch("nirux-train/queue")) {
            shown.branches["nirux-train/queue"] = stale.tip
            staleTip = (stale.tip, stale.reads - 1)
        }
        if let head = world.pullRequests[900]?.headOid, reads.contains(.checks(head)), !trainChecks.isEmpty {
            shown.checks[head] = trainChecks.removeFirst()
        }
        return shown
    }

    mutating func apply(_ mutation: MergeQueue.Mutation) -> MergeQueue.MutationResult {
        switch mutation {
        case .createBranch(let name, let commit):
            guard world.branches[name] == nil else { return .refused(status: 422, message: "Reference already exists") }
            world.branches[name] = commit
        case .mergeIntoBranch(let branch, let head, _):
            guard let tip = world.branches[branch] else { return .refused(status: 404, message: "Base does not exist") }
            if conflicts.contains(head) { return .refused(status: 409, message: "Merge conflict") }
            let commit = newCommit()
            world.commits[commit] = MergeQueue.CommitInfo(sha: commit, committerLogin: committer, parents: [tip, head])
            if lagReads > 0 { staleTip = (tip, lagReads) }
            world.branches[branch] = commit
            partCommits[head] = commit
            lastMerge = commit
        case .openPullRequest(_, let head, _, _):
            guard let tip = world.branches[head] else { return .refused(status: 422, message: "No commits between main and \(head)") }
            world.pullRequests[900] = MQ.pullRequest(900, head: pushToTrainAfterOpen ?? tip, branch: head)
            for (number, pushed) in pushesAfterOpen { world.pullRequests[number] = MQ.pullRequest(number, head: pushed) }
        case .merge(let number, _, _):
            if refusesMerge { return .refused(status: 405, message: "At least 1 approving review is required") }
            let base = world.mainTip
            let merged = newCommit()
            world.merge(number, as: merged)
            world.pushRuns[merged] = [MQ.run(77, head: merged)]
            for (number, pushed) in pushesAfterLanding { world.pullRequests[number] = MQ.pullRequest(number, head: pushed) }
            guard marksMerged else { break }
            for (part, pullRequest) in world.pullRequests where pullRequest.isOpen {
                guard let commit = partCommits[pullRequest.headOid] else { continue }
                world.pullRequests[part] = MQ.pullRequest(part, head: pullRequest.headOid, state: .merged, mergeCommit: commit,
                                                          parents: [base, pullRequest.headOid])
            }
        case .closePullRequest(let number):
            if refusesClose { return .refused(status: 403, message: "Resource not accessible") }
            guard let open = world.pullRequests[number] else { return .refused(status: 404, message: "Not Found") }
            world.pullRequests[number] = MQ.pullRequest(number, head: open.headOid, branch: open.headRefName, state: .closed)
        case .deleteBranch(let name):
            guard world.branches.removeValue(forKey: name) != nil else { return .refused(status: 422, message: "Reference does not exist") }
        case .rerun:
            guard let head = lastMerge else { return .refused(status: 404, message: "Not Found") }
            world.checks[head] = rerunsGreen.contains(head) ? MQ.checks(MQ.checkRun(id: 10))
                : MQ.checks(MQ.checkRun(id: 9, conclusion: "FAILURE"), MQ.checkRun(id: 10, conclusion: "FAILURE"))
            return rerunAnswer
        case .updateBranch:
            return .refused(status: 422, message: "not a train's call")
        }
        return .sent
    }
}

/// The same GitHub behind the driver, as the queue's client.
private final class TrainClient: MergeQueueGitHub, @unchecked Sendable {
    let isDryRun = false
    private let lock = NSLock()
    private var github: TrainGitHub
    private var made: [MergeQueue.Mutation] = []

    init(_ github: TrainGitHub) { self.github = github }

    var mutations: [MergeQueue.Mutation] { lock.withLock { made } }

    func read(_ read: MergeQueue.Read, settings: BoardConfig.QueueSettings) -> Result<MergeQueue.ReadResult, GitHub.CLI.Failure> {
        lock.withLock {
            if case .triage = read { return .failure(.unreadable("the CI triage isn’t a GitHub read")) }
            return github.world.answer(read).map { .success($0) } ?? .failure(.noAnswer("unscripted \(read)"))
        }
    }

    func mutate(_ mutation: MergeQueue.Mutation, settings: BoardConfig.QueueSettings) -> MergeQueue.MutationResult {
        lock.withLock {
            made.append(mutation)
            return github.apply(mutation)
        }
    }

    func commandLine(_ mutation: MergeQueue.Mutation, settings: BoardConfig.QueueSettings) -> String { "gh \(mutation)" }
}

private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    var all: [String] { lock.withLock { asked } }
    func add(_ question: String) { lock.withLock { asked.append(question) } }
}

extension MQ.Harness {
    /// Answers reads and makes calls on GitHub until `isDue`.
    fileprivate mutating func run(_ github: inout TrainGitHub, until isDue: (MQ.Harness) -> Bool) {
        for _ in 0..<500 {
            if isDue(self) { return }
            if let mutation = pendingMutation {
                mutated(github.apply(mutation))
            } else if let reads = pendingReads {
                answer(github.world(for: reads))
            } else {
                return XCTFail("the queue ended first")
            }
        }
        XCTFail("never got there")
    }

    /// Answers reads from GitHub's world and makes each call there, until
    /// the queue ends.
    fileprivate mutating func drive(_ github: inout TrainGitHub, limit: Int = 500) {
        for _ in 0..<limit {
            guard let request = engine.request else { return }
            switch request.action {
            case .read(let reads, _):
                answer(github.world(for: reads))
            case .mutate(let mutation): mutated(github.apply(mutation))
            }
        }
        XCTFail("the queue never ended")
    }
}
