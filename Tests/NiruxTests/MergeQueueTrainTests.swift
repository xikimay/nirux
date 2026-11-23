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

    private func queue() -> MQ.Harness {
        var queue = MQ.Harness(entries: [MQ.entry(12, head: a), MQ.entry(14, head: b)], cadence: .train)
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
        ])
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
        XCTAssertEqual(none.stopReason?.message, "#12 conflicts with main. It left the train.")
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
        XCTAssertTrue(reason.message.hasSuffix("failed on train #900 at 0000002. Nirux closed train #900."), reason.message)
        XCTAssertEqual(first.mutations.last, .closePullRequest(number: 900))
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

    func testABusyAgentHoldsTheWholeTrainForTenMinutesAtMost() throws {
        var world = world()
        world.locals["feat/14"] = MergeQueue.LocalState(busyAgents: ["claude working in “api”"])
        var github = TrainGitHub(world: world)
        var queue = queue()
        let start = queue.now
        queue.drive(&github)

        let reason = try XCTUnwrap(queue.stopReason)
        XCTAssertEqual(reason.kind, .agentBusy)
        XCTAssertEqual(reason.message, "An agent of #14 is still busy after 10 minutes: claude working in “api”.")
        XCTAssertGreaterThanOrEqual(queue.now - start, MergeQueue.Limits.agentWait)
        XCTAssertEqual(queue.notes.filter { $0.message.hasPrefix("Waiting up to 10 minutes") }.count, 1)
        XCTAssertEqual(queue.mutations, [])
    }

    func testAPushAfterTheLastCheckStopsOnThatPullRequestOnceTheTrainLands() throws {
        var github = TrainGitHub(world: world())
        github.pushesAfterLanding = [14: c]
        var queue = queue()
        queue.drive(&github)

        let reason = try XCTUnwrap(queue.stopReason)
        XCTAssertEqual(reason.kind, .changed)
        XCTAssertEqual(reason.message, "#14 moved to ccccccc after train #900’s last check: the train landed bbbbbbb, and #14 stays "
            + "open with the commits after it. Train #900 landed #12.")
        XCTAssertEqual(queue.engine.entries.map(\.step), [.done, .stopped(reason)])
        XCTAssertTrue(queue.notes.contains { $0.message == "#12 read merged" })
        XCTAssertTrue(queue.notes.contains { $0.message == "The nightly of train #900 succeeded" }, "the landed train's run is still read")
    }

    func testStopWhileComposingStopsTheWholeTrain() throws {
        var github = TrainGitHub(world: world())
        var queue = queue()
        while let request = queue.engine.request {
            guard case .mutate(let mutation) = request.action else {
                queue.answer(github.world)
                continue
            }
            if case .mergeIntoBranch(_, let head, _) = mutation, head == b { break }
            queue.mutated(github.apply(mutation))
        }
        queue.send(.stop)
        queue.mutated(github.apply(try XCTUnwrap(queue.pendingMutation)))
        let reason = try XCTUnwrap(queue.stopReason)
        XCTAssertEqual(reason.kind, .user)
        XCTAssertEqual(queue.engine.entries.map(\.step), [.stopped(reason), .stopped(reason)])
    }

    func testATrainLandsOnlyOnTheTipItWasTestedOnWithEveryHeadAsConfirmed() throws {
        var moved = TrainGitHub(world: world())
        moved.world.behind[TrainGitHub.commit(2)] = 1
        var first = queue()
        first.drive(&moved)
        XCTAssertEqual(first.stopReason?.kind, .train)
        XCTAssertTrue(first.stopReason?.message.hasSuffix(" Nirux closed train #900.") == true, first.stopReason?.message ?? "")
        XCTAssertEqual(first.mutations.count, 5, "no merge of the train")
        XCTAssertEqual(first.mutations.last, .closePullRequest(number: 900))

        var pushed = TrainGitHub(world: world())
        pushed.pushesAfterOpen = [14: c]
        // The train's run still going: the push stops it all the same.
        pushed.world.checks[TrainGitHub.commit(2)] = MQ.checks(MQ.checkRun(id: 9, status: "IN_PROGRESS", conclusion: nil))
        var second = queue()
        second.drive(&pushed)
        let reason = try XCTUnwrap(second.stopReason)
        XCTAssertEqual(reason.kind, .changed)
        XCTAssertTrue(reason.message.hasPrefix("#14 changed since you confirmed it"), reason.message)
        XCTAssertEqual(second.mutations.last, .closePullRequest(number: 900), "no merge of the train")
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
        XCTAssertTrue(first.stopReason?.message.hasSuffix("someone else pushed to it.") == true, first.stopReason?.message ?? "")

        var pushed = TrainGitHub(world: world())
        pushed.pushToTrainAfterOpen = c
        var second = queue()
        second.drive(&pushed)
        XCTAssertEqual(second.stopReason?.kind, .changed)
        XCTAssertTrue(second.stopReason?.message.hasPrefix("Someone pushed to train #900") == true, second.stopReason?.message ?? "")
        XCTAssertEqual(second.mutations.last, .closePullRequest(number: 900), "no merge of the train")
    }

    func testARefusedMergeOfTheTrainClosesIt() throws {
        var github = TrainGitHub(world: world())
        github.refusesMerge = true
        var queue = queue()
        queue.drive(&github)
        let reason = try XCTUnwrap(queue.stopReason)
        XCTAssertEqual(reason.kind, .merge)
        XCTAssertTrue(reason.message.hasSuffix("required. Nirux closed train #900."), reason.message)
        XCTAssertEqual(github.world.pullRequests[900]?.state, .closed)
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
    var refusesClose = false
    /// Agents' pushes between the last check and the train's merge.
    var pushesAfterLanding: [Int: String] = [:]
    /// The first read of the train's pull request misses it.
    var hidesTrainOnce = false
    /// Who makes the merges into the train.
    var committer = "web-flow"
    /// Each head's merge commit in the train.
    private(set) var partCommits: [String: String] = [:]
    private var made = 0

    /// The `n`th commit GitHub makes: "0000001eee…".
    static func commit(_ number: Int) -> String {
        String(format: "%07x", number) + String(repeating: "e", count: 33)
    }

    private mutating func newCommit() -> String {
        made += 1
        return Self.commit(made)
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
            world.branches[branch] = commit
            partCommits[head] = commit
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
        case .updateBranch, .rerun:
            return .refused(status: 422, message: "not a train's call")
        }
        return .sent
    }
}

extension MQ.Harness {
    /// Answers reads from GitHub's world and makes each call there, until
    /// the queue ends.
    fileprivate mutating func drive(_ github: inout TrainGitHub, limit: Int = 500) {
        for _ in 0..<limit {
            guard let request = engine.request else { return }
            switch request.action {
            case .read(let reads, _):
                var world = github.world
                if github.hidesTrainOnce, reads.contains(where: { if case .pullRequests = $0 { true } else { false } }) {
                    github.hidesTrainOnce = false
                    world.pullRequests[900] = nil
                }
                answer(world)
            case .mutate(let mutation): mutated(github.apply(mutation))
            }
        }
        XCTFail("the queue never ended")
    }
}
