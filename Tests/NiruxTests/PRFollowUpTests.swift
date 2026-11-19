import XCTest
@testable import Nirux

/// docs/design/pr-follow-up.md: when Nirux types a round into a task's idle
/// Claude, which one, and when it hands the pull request to the user.
final class PRFollowUpTests: XCTestCase {
    private let head = String(repeating: "a", count: 40)
    private let pushed = String(repeating: "b", count: 40)
    private let now: TimeInterval = 1_800_000_000

    private func pullRequest(
        mergeable: String = "MERGEABLE", rollup: [[String: Any]] = [], head: String? = nil, base: String = "main"
    ) -> PRInfo {
        PRDetect.pullRequestInfo(from: [
            "number": 52, "state": "OPEN", "url": "https://github.com/acme/widgets/pull/52", "statusCheckRollup": rollup,
            "mergeable": mergeable, "headRefOid": (head ?? self.head).uppercased(), "baseRefName": base
        ])
    }

    private func checkRun(_ name: String, conclusion: String = "FAILURE", status: String = "COMPLETED", run: Int = 7) -> [String: Any] {
        ["__typename": "CheckRun", "name": name, "workflowName": "Tests", "status": status, "conclusion": conclusion,
         "startedAt": "2026-11-19T10:00:00Z", "detailsUrl": "https://github.com/acme/widgets/actions/runs/\(run)/job/1"]
    }

    private var red: [[String: Any]] { [checkRun("test")] }

    private func item(_ name: String, age: TimeInterval, outdated: Bool = false) -> PRFeedback.Item {
        PRFeedback.Item(author: "reviewer", isBot: false, location: "Sources/A.swift:3", isOutdated: outdated, excerpt: "Fix",
                        url: "https://github.com/acme/widgets/pull/52#\(name)", createdAt: Date(timeIntervalSince1970: now - age))
    }

    /// A task ready for a round, its failure read and old enough.
    private func facts(_ pullRequest: PRInfo, feedback: [PRFeedback.Item] = []) -> PRFollowUp.Facts {
        PRFollowUp.Facts(
            pullRequest: pullRequest, feedback: PRFeedback(items: feedback), triage: .done(.real), redSince: now - 600,
            localHead: head, readAt: now, trackedSince: now - 3600, now: now
        )
    }

    private func typed(_ action: PRFollowUp.Action) -> (round: PRFollowUp.Round, prompt: String)? {
        guard case .type(let round, let prompt) = action else { return nil }
        return (round, prompt)
    }

    private func next(_ facts: PRFollowUp.Facts, _ entry: PRFollowUp.Entry = .init()) -> PRFollowUp.Action {
        var entry = entry
        return PRFollowUp.next(&entry, facts)
    }

    /// A settled round of `kind` typed on `head`.
    private func round(_ kind: PRFollowUp.Kind, on head: String, endedAgo: TimeInterval = 100, settled: Bool = false,
                       items: [String] = []) -> PRFollowUp.Round {
        PRFollowUp.Round(kind: kind, head: head, typedAt: now - endedAgo - 60, items: items, endedAt: now - endedAgo,
                         settledAt: settled ? now - endedAgo + 20 : nil)
    }

    // MARK: - Which round

    /// A conflicting pull request runs no pull_request workflow: the merge
    /// comes first, and never a rebase (a pushed branch only moves fast-forward).
    func testTheConflictComesFirstAndMergesTheBase() throws {
        let conflicting = facts(pullRequest(mergeable: "CONFLICTING", rollup: red), feedback: [item("c1", age: 600)])
        let conflict = try XCTUnwrap(typed(next(conflicting)))
        XCTAssertEqual(conflict.round, PRFollowUp.Round(kind: .conflict, head: head, typedAt: now))
        XCTAssertEqual(conflict.prompt, "PR #52 conflicts with main. Run `git fetch origin main`, merge origin/main into this "
            + "branch, resolve the conflicts, run the checks, commit and push. (Nirux follow-up, round 1 of 3.)")

        // A base name GitHub gives goes into no prompt unless plain.
        var oddBase = conflicting
        oddBase.pullRequest = pullRequest(mergeable: "CONFLICTING", rollup: red, base: "main`; rm -rf ~`")
        XCTAssertEqual(try XCTUnwrap(typed(next(oddBase))).round.kind, .ci)
    }

    func testAFailureWaitsForItsChecksTheTriageAndTheUser() throws {
        let failed = facts(pullRequest(rollup: red))
        XCTAssertEqual(try XCTUnwrap(typed(next(failed))).prompt, "CI failed on PR #52. Run "
            + "`gh run view 7 --repo github.com/acme/widgets --log-failed`, find why it failed, fix it, run the checks, "
            + "commit and push. If this branch didn't cause it, say so and push nothing. (Nirux follow-up, round 1 of 3.)")

        var running = failed
        running.pullRequest = pullRequest(rollup: red + [checkRun("lint", conclusion: "", status: "IN_PROGRESS", run: 8)])
        XCTAssertEqual(next(running), .wait("checks still run"))
        var reading = failed
        reading.triage = .pending
        XCTAssertEqual(next(reading), .wait("the triage reads the failure"))
        var fresh = failed
        fresh.redSince = now - 30
        XCTAssertEqual(next(fresh), .wait("the failure is new"))
        var off = failed
        off.triage = .off
        XCTAssertNotNil(typed(next(off)), "without the triage, a failure is unsure")

        // A likely flake's rerun stays the user's, so does a failure their
        // Why Failed took: feedback goes on.
        var flaky = facts(pullRequest(rollup: red), feedback: [item("c1", age: 600)])
        flaky.triage = .done(.flaky(reason: "runner lost"))
        XCTAssertEqual(try XCTUnwrap(typed(next(flaky))).round.kind, .feedback)
        let taken = PRFollowUp.Entry(userFailures: [CITriage.signature(of: CIFailure.redChecks(failed.pullRequest))])
        XCTAssertEqual(next(failed, taken), .none)

        // Nothing the agent could read.
        let status: [String: Any] = ["__typename": "StatusContext", "context": "ci/lint", "state": "FAILURE",
                                     "targetUrl": "https://ci.example.com/1", "startedAt": "2026-11-19T10:00:00Z"]
        XCTAssertEqual(next(facts(pullRequest(rollup: [status]))), .none)
    }

    func testNewFeedbackWaitsForTheBurstToEndAndIsHandedOnce() throws {
        var entry = PRFollowUp.Entry(handedFeedback: [item("old", age: 9000).url])
        let items = [item("new", age: 200), item("outdated", age: 900, outdated: true), item("old", age: 9000)]
        XCTAssertEqual(next(facts(pullRequest(), feedback: [item("burst", age: 60)] + items), entry),
                       .wait("feedback may still come"))
        let action = PRFollowUp.next(&entry, facts(pullRequest(), feedback: items))
        let round = try XCTUnwrap(typed(action))
        XCTAssertEqual(round.round.items, [item("new", age: 200).url])
        XCTAssertEqual(round.prompt, "/receiving-code-review Address this feedback on PR #52 "
            + "(https://github.com/acme/widgets/pull/52): \(item("new", age: 200).url) Commit and push the fixes. "
            + "(Nirux follow-up, round 1 of 3.)")
        entry.record(round.round)
        XCTAssertEqual(entry.handedFeedback, [item("old", age: 9000).url, item("new", age: 200).url])
    }

    func testNothingIsTypedUnlessTheTaskIsReady() {
        let ready = facts(pullRequest(rollup: red))
        var queued = ready
        queued.isInMergeQueue = true
        XCTAssertEqual(next(queued), .wait("the merge queue holds it"))
        var behind = ready
        behind.localHead = pushed
        XCTAssertEqual(next(behind), .wait("the checkout's HEAD isn't the pull request's"))
        var edited = ready
        edited.hasTrackedChanges = true
        XCTAssertEqual(next(edited), .wait("tracked files changed"))
        var busy = ready
        busy.agentRefusal = "working"
        XCTAssertEqual(next(busy), .wait("working"))
    }

    // MARK: - Rounds and stops

    func testARoundRunsUntilItsTurnEndsAndARead() {
        let inFlight = PRFollowUp.Round(kind: .ci, head: head, typedAt: now - 60)
        XCTAssertEqual(next(facts(pullRequest(rollup: red)), PRFollowUp.Entry(rounds: [inFlight])), .wait("its round runs"))
        var unread = facts(pullRequest(rollup: red))
        unread.readAt = now - 110
        XCTAssertEqual(next(unread, PRFollowUp.Entry(rounds: [round(.ci, on: head)])), .wait("no read since its round"))

        var ended = PRFollowUp.Entry(rounds: [inFlight])
        ended.endRound(at: inFlight.typedAt - 1)
        XCTAssertNil(ended.rounds[0].endedAt, "a turn that ended before the round was typed isn't its turn")
        ended.endRound(at: now - 30)
        XCTAssertEqual(PRFollowUp.next(&ended, facts(pullRequest(rollup: red))), .wait("stopped: nothingPushed"))

        // Typed by a Nirux that quit before its end: ended at this launch.
        var relaunched = facts(pullRequest(rollup: red))
        relaunched.trackedSince = inFlight.typedAt + 1
        relaunched.readAt = relaunched.trackedSince + PRFollowUp.readSettle
        var entry = PRFollowUp.Entry(rounds: [inFlight])
        XCTAssertEqual(PRFollowUp.next(&entry, relaunched), .wait("stopped: nothingPushed"))
    }

    /// The same signal back on the same head: what the round did moved
    /// nothing, and another round would do the same.
    func testARoundThatPushedNothingHandsThePullRequestOver() {
        let feedback = item("c1", age: 900)
        for (kind, stillThere) in [
            (PRFollowUp.Kind.conflict, facts(pullRequest(mergeable: "CONFLICTING"))),
            (.ci, facts(pullRequest(rollup: red))),
            (.feedback, facts(pullRequest(), feedback: [feedback]))
        ] {
            var entry = PRFollowUp.Entry(rounds: [round(kind, on: head, items: [feedback.url])])
            XCTAssertEqual(PRFollowUp.next(&entry, stillThere), .wait("stopped: nothingPushed"), "\(kind)")
            XCTAssertEqual(entry.stop, PRFollowUp.Stop(kind: kind, cause: .nothingPushed, head: head, at: now), "\(kind)")
            XCTAssertNotNil(entry.rounds.last?.settledAt, "\(kind)")
        }

        // Gone without a push (a question answered, a rerun that passed):
        // nothing to hand over.
        var answered = PRFollowUp.Entry(rounds: [round(.feedback, on: head, items: [feedback.url])])
        XCTAssertEqual(PRFollowUp.next(&answered, facts(pullRequest())), .none)
        XCTAssertNil(answered.stop)
        // Only its own items count: newer feedback is the next round's.
        var followed = PRFollowUp.Entry(rounds: [round(.feedback, on: head, items: [feedback.url])],
                                        handedFeedback: [feedback.url])
        XCTAssertEqual(typed(PRFollowUp.next(&followed, facts(pullRequest(), feedback: [item("c2", age: 600)])))?.round.kind,
                       .feedback)
    }

    func testAPushSettlesTheRoundAndTheNextOneMayFollow() throws {
        var entry = PRFollowUp.Entry(rounds: [round(.ci, on: head)])
        var failedAgain = facts(pullRequest(rollup: red, head: pushed))
        failedAgain.localHead = pushed
        let second = try XCTUnwrap(typed(PRFollowUp.next(&entry, failedAgain)))
        XCTAssertNotNil(entry.rounds[0].settledAt)
        XCTAssertNil(entry.stop)
        XCTAssertEqual(second.round.head, pushed)
        XCTAssertTrue(second.prompt.hasSuffix("(Nirux follow-up, round 2 of 3.)"))
    }

    func testCommitsLeftUnpushedStopThePullRequestUntilTheyArePushed() {
        var unpushed = facts(pullRequest(rollup: red))
        unpushed.localHead = pushed
        var entry = PRFollowUp.Entry(rounds: [round(.ci, on: head, endedAgo: 300)])
        XCTAssertEqual(PRFollowUp.next(&entry, unpushed), .wait("its round's commits aren't on the pull request yet"))
        entry = PRFollowUp.Entry(rounds: [round(.ci, on: head, endedAgo: PRFollowUp.unpushedLimit + 1)])
        XCTAssertEqual(PRFollowUp.next(&entry, unpushed), .wait("stopped: unpushed"))
        XCTAssertEqual(PRFollowUp.next(&entry, unpushed), .wait("stopped: unpushed"))

        var pushedNow = facts(pullRequest(head: pushed))
        pushedNow.localHead = pushed
        XCTAssertEqual(PRFollowUp.next(&entry, pushedNow), .none)
        XCTAssertNil(entry.stop)
    }

    func testAfterThreeRoundsEachNewSignalGoesToTheUser() {
        var entry = PRFollowUp.Entry(rounds: [
            round(.ci, on: "1", settled: true), round(.conflict, on: "2", settled: true), round(.ci, on: "3", settled: true)
        ])
        let failed = facts(pullRequest(rollup: red))
        XCTAssertEqual(PRFollowUp.next(&entry, failed), .wait("stopped: rounds"))
        XCTAssertEqual(entry.stop, PRFollowUp.Stop(kind: .ci, cause: .rounds, head: head, at: now))
        XCTAssertEqual(PRFollowUp.next(&entry, failed), .wait("stopped: rounds"))

        // Pushed and red again: still the user's, about the new head.
        var failedAgain = facts(pullRequest(rollup: red, head: pushed))
        failedAgain.localHead = pushed
        XCTAssertEqual(PRFollowUp.next(&entry, failedAgain), .wait("stopped: rounds"))
        XCTAssertEqual(entry.stop?.head, pushed)

        // Green: nothing waits on the user.
        var green = facts(pullRequest(rollup: [checkRun("test", conclusion: "SUCCESS")], head: pushed))
        green.localHead = pushed
        XCTAssertEqual(PRFollowUp.next(&entry, green), .none)
        XCTAssertNil(entry.stop)
    }

    /// GitHub reads `mergeable` UNKNOWN while it computes it again.
    func testAConflictStopHoldsWhileGitHubRecomputes() {
        var entry = PRFollowUp.Entry(stop: PRFollowUp.Stop(kind: .conflict, cause: .nothingPushed, head: head, at: now - 60))
        XCTAssertEqual(PRFollowUp.next(&entry, facts(pullRequest(mergeable: "UNKNOWN"))), .wait("stopped: nothingPushed"))
        XCTAssertEqual(PRFollowUp.next(&entry, facts(pullRequest())), .none)
        XCTAssertNil(entry.stop)
    }

    // MARK: - Store

    func testTheStoreIsPrivateAndForgetsWhatNothingTouchedForAMonth() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("pr-follow-up.json")
        var store = PRFollowUpStore()
        let old = "https://github.com/acme/widgets/pull/1"
        let current = "https://github.com/acme/widgets/pull/52"
        XCTAssertTrue(store.update(old, now: now - PRFollowUpStore.lifetime) { $0.handedFeedback = ["x"] })
        XCTAssertFalse(store.update(old, now: now) { _ in })
        XCTAssertTrue(store.update(current, now: now) { $0.record(self.round(.ci, on: self.head)) })
        XCTAssertEqual(Array(store.pullRequests.keys), [current])
        XCTAssertEqual(store.pullRequests[current]?.updatedAt, now)

        store.save(to: url)
        XCTAssertEqual(PRFollowUpStore.load(from: url), store)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertEqual(PRFollowUpStore.load(from: folder.appendingPathComponent("missing.json")), PRFollowUpStore())
    }
}
