import XCTest
@testable import Nirux

/// docs/design/pr-follow-up.md: when Nirux types a round into a task's idle
/// Claude, which one, and when it hands the pull request to the user.
final class PRFollowUpTests: XCTestCase {
    private let head = String(repeating: "a", count: 40)
    private let pushed = String(repeating: "b", count: 40)
    private let now: TimeInterval = 1_800_000_000

    private func pullRequest(
        mergeable: String = "MERGEABLE", rollup: [[String: Any]] = [], head: String? = nil, base: String = "main",
        autoMerge: Bool = false
    ) -> PRInfo {
        var candidate: [String: Any] = [
            "number": 52, "state": "OPEN", "url": "https://github.com/acme/widgets/pull/52", "statusCheckRollup": rollup,
            "mergeable": mergeable, "headRefOid": (head ?? self.head).uppercased(), "baseRefName": base
        ]
        if autoMerge { candidate["autoMergeRequest"] = ["mergeMethod": "MERGE"] }
        return PRDetect.pullRequestInfo(from: candidate)
    }

    private func checkRun(_ name: String, conclusion: String = "FAILURE", status: String = "COMPLETED", run: Int = 7) -> [String: Any] {
        ["__typename": "CheckRun", "name": name, "workflowName": "Tests", "status": status, "conclusion": conclusion,
         "startedAt": "2026-11-19T10:00:00Z", "detailsUrl": "https://github.com/acme/widgets/actions/runs/\(run)/job/1"]
    }

    private var red: [[String: Any]] { [checkRun("test")] }

    private func item(_ name: String, age: TimeInterval, outdated: Bool = false, location: String = "Sources/A.swift:3",
                      bot: Bool = false, approval: Bool = false, answered: Bool = false) -> PRFeedback.Item {
        PRFeedback.Item(author: "reviewer", isBot: bot, location: location, isOutdated: outdated, excerpt: "Fix",
                        url: "https://github.com/acme/widgets/pull/52#\(name)", createdAt: Date(timeIntervalSince1970: now - age),
                        isApproval: approval, isAnswered: answered)
    }

    /// A task ready for a round, its failure read and old enough.
    private func facts(_ pullRequest: PRInfo, feedback: [PRFeedback.Item] = []) -> PRFollowUp.Facts {
        PRFollowUp.Facts(
            pullRequest: pullRequest, feedback: PRFeedback(items: feedback), feedbackReadAt: now, triage: .done(.real),
            redSince: now - 600, localHead: head, baseRemote: "upstream", hasTrackedChanges: false, readAt: now,
            agent: "agent-1", trackedSince: now - 3600, now: now
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

    /// A round of `kind` typed on `head`, its turn over.
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
        XCTAssertEqual(conflict.round, PRFollowUp.Round(kind: .conflict, head: head, typedAt: now, agent: "agent-1"))
        XCTAssertEqual(conflict.prompt, "PR #52 conflicts with main. Run `git fetch upstream main`, merge upstream/main into "
            + "this branch, resolve the conflicts, run the checks, commit and push. (Nirux follow-up, round 1 of 3.)")

        // Names go into no prompt unless plain; no remote for the base, no
        // merge, and no other round: its checks wouldn't run.
        var oddBase = conflicting
        oddBase.pullRequest = pullRequest(mergeable: "CONFLICTING", rollup: red, base: "main`; rm -rf ~`")
        XCTAssertEqual(next(oddBase), .wait("no plain remote and base to merge"))
        var noRemote = conflicting
        noRemote.baseRemote = nil
        XCTAssertEqual(next(noRemote), .wait("no plain remote and base to merge"))
    }

    func testAFailureWaitsForItsRunsTheTriageAndTheUser() throws {
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
        // Why Failed took; a job cancelled isn't the branch's doing.
        var flaky = failed
        flaky.triage = .done(.flaky(reason: "runner lost"))
        XCTAssertEqual(next(flaky), .none)
        let taken = PRFollowUp.Entry(userFailures: [PRFollowUp.failureSignature(failed.pullRequest)])
        XCTAssertEqual(next(failed, taken), .none)
        let cancelled = checkRun("Analyze (swift)", conclusion: "CANCELLED", run: 9)
        XCTAssertEqual(next(facts(pullRequest(rollup: [cancelled]))), .none)
        XCTAssertEqual(next(facts(pullRequest(rollup: red + [cancelled])), taken), .none, "still the failure the user took")
        XCTAssertEqual(try XCTUnwrap(typed(next(facts(pullRequest(rollup: red + [cancelled]))))).prompt,
                       try XCTUnwrap(typed(next(failed))).prompt, "the cancelled run isn't the agent's to read")
        XCTAssertNotNil(typed(next(facts(pullRequest(rollup: [checkRun("test", conclusion: "TIMED_OUT")])))))

        // Nothing the agent could read.
        var foreign = checkRun("test")
        foreign["detailsUrl"] = "https://github.com/someone/else/actions/runs/9/job/1"
        XCTAssertEqual(next(facts(pullRequest(rollup: [foreign]))), .none)
        let status: [String: Any] = ["__typename": "StatusContext", "context": "ci/lint", "state": "FAILURE",
                                     "targetUrl": "https://ci.example.com/1", "startedAt": "2026-11-19T10:00:00Z"]
        XCTAssertEqual(next(facts(pullRequest(rollup: [status]))), .none)
    }

    /// A check that waits on someone (a deployment's approval) must not hold
    /// the feedback behind it.
    func testAWaitingKindLetsTheNextOneGo() throws {
        var reading = facts(pullRequest(rollup: red), feedback: [item("c1", age: 600)])
        reading.triage = .pending
        XCTAssertEqual(try XCTUnwrap(typed(next(reading))).round.kind, .feedback)
    }

    func testNewFeedbackWaitsForTheBurstToEndAndIsHandedOnce() throws {
        let fresh = item("new", age: 200)
        let items = [
            fresh, item("outdated", age: 900, outdated: true), item("old", age: 9000),
            item("before", age: 4000), item("lgtm", age: 900, location: "comment", approval: true),
            item("overview", age: 900, location: "comment", bot: true), item("bot-thread", age: 400, bot: true),
            item("replied", age: 500, answered: true)
        ]
        var entry = PRFollowUp.Entry(since: now - 3600, handedFeedback: [item("old", age: 9000).url])
        XCTAssertEqual(PRFollowUp.next(&entry, facts(pullRequest(), feedback: [item("burst", age: 60)] + items)),
                       .wait("feedback may still come"))
        // Turned off and on again since the entry began: what came between is the user's.
        var turnedOn = facts(pullRequest(), feedback: items)
        turnedOn.followedSince = now - 300
        XCTAssertEqual(typed(next(turnedOn, entry))?.round.items, [fresh.url], "only what came since it was turned on")
        let action = PRFollowUp.next(&entry, facts(pullRequest(), feedback: items + [item("ask", age: 300, location: "comment")]))
        let round = try XCTUnwrap(typed(action))
        let handed = [fresh.url, item("bot-thread", age: 400).url, item("ask", age: 300).url]
        XCTAssertEqual(round.round.items, handed)
        XCTAssertEqual(round.prompt, "/receiving-code-review Address this feedback on PR #52 "
            + "(https://github.com/acme/widgets/pull/52): \(handed.joined(separator: " ")) Commit and push the fixes. "
            + "(Nirux follow-up, round 1 of 3.)")
        XCTAssertEqual(entry.rounds, [round.round], "recorded at once: no second read types it again")
        XCTAssertEqual(entry.handedFeedback, [item("old", age: 9000).url] + handed)

        // Pushed, the threads still listed: handed once.
        var afterPush = entry
        afterPush.endRound(at: now)
        var later = facts(pullRequest(head: pushed), feedback: items + [item("ask", age: 300, location: "comment")])
        later.localHead = pushed
        later.now = now + 60
        later.readAt = now + 30
        XCTAssertEqual(PRFollowUp.next(&afterPush, later), .none)

        // Typing failed: as if never typed, even once a pass ended it (its
        // column closed meanwhile).
        entry.endRound(at: now + 1)
        entry.cancelRound()
        XCTAssertEqual(entry, PRFollowUp.Entry(since: now - 3600, handedFeedback: [item("old", age: 9000).url]))
    }

    func testNothingIsTypedUnlessTheTaskIsReady() {
        let ready = facts(pullRequest(rollup: red))
        var queued = ready
        queued.isInMergeQueue = true
        XCTAssertEqual(next(queued), .wait("the merge queue holds it"))
        XCTAssertEqual(next(facts(pullRequest(rollup: red, autoMerge: true))), .wait("auto-merge is on"))
        var behind = ready
        behind.localHead = pushed
        XCTAssertEqual(next(behind), .wait("the checkout's HEAD isn't the pull request's"))
        var unknown = ready
        unknown.localHead = nil
        XCTAssertEqual(next(unknown), .wait("the checkout's HEAD isn't the pull request's"))
        var edited = ready
        edited.hasTrackedChanges = true
        XCTAssertEqual(next(edited), .wait("tracked files changed, or unknown"))
        edited.hasTrackedChanges = nil
        XCTAssertEqual(next(edited), .wait("tracked files changed, or unknown"))
        var busy = ready
        busy.agentRefusal = "working"
        XCTAssertEqual(next(busy), .wait("working"))
    }

    // MARK: - Rounds and stops

    func testARoundIsJudgedOnceItsTurnEndedTheAgentRestsAndReadsCame() {
        let inFlight = PRFollowUp.Round(kind: .ci, head: head, typedAt: now - 60)
        let failed = facts(pullRequest(rollup: red))
        XCTAssertEqual(next(failed, PRFollowUp.Entry(rounds: [inFlight])), .wait("its round runs"))
        var busy = failed
        busy.agentIsBusy = true
        XCTAssertEqual(next(busy, PRFollowUp.Entry(rounds: [round(.ci, on: head)])), .wait("its agent is busy"))
        var unread = failed
        unread.readAt = now - 110
        XCTAssertEqual(next(unread, PRFollowUp.Entry(rounds: [round(.ci, on: head)])), .wait("no read since its round"))
        var oldFeedback = facts(pullRequest(), feedback: [item("c1", age: 900)])
        oldFeedback.feedbackReadAt = now - 110
        XCTAssertEqual(next(oldFeedback, PRFollowUp.Entry(rounds: [round(.feedback, on: head, items: [item("c1", age: 900).url])])),
                       .wait("no feedback read since its round"))

        var ended = PRFollowUp.Entry(rounds: [inFlight])
        ended.endRound(at: inFlight.typedAt - 1)
        XCTAssertNil(ended.rounds[0].endedAt, "a turn that ended before the round was typed isn't its turn")
        ended.endRound(at: now - 30)
        XCTAssertEqual(PRFollowUp.next(&ended, failed), .wait("stopped: nothingPushed"))

        // Typed by a Nirux that quit before its end: ended at this launch.
        var relaunched = failed
        relaunched.trackedSince = inFlight.typedAt + 1
        relaunched.readAt = relaunched.trackedSince + PRFollowUp.readSettle
        var entry = PRFollowUp.Entry(rounds: [inFlight])
        XCTAssertEqual(PRFollowUp.next(&entry, relaunched), .wait("stopped: nothingPushed"))

        // No turn end ever came (Esc, a stalled turn): given up after a while.
        var longRunning = failed
        longRunning.trackedSince = now - 2 * PRFollowUp.roundLimit
        let stalledRound = PRFollowUp.Round(kind: .ci, head: head, typedAt: now - PRFollowUp.roundLimit + 60)
        XCTAssertEqual(next(longRunning, PRFollowUp.Entry(rounds: [stalledRound])), .wait("its round runs"))
        var stalled = PRFollowUp.Entry(rounds: [PRFollowUp.Round(kind: .ci, head: head, typedAt: now - PRFollowUp.roundLimit - 60)])
        XCTAssertEqual(PRFollowUp.next(&stalled, longRunning), .wait("stopped: nothingPushed"))
    }

    /// The same signal back on the same head: what the round did moved
    /// nothing, and another round would do the same.
    func testARoundThatPushedNothingHandsThePullRequestOver() throws {
        let feedback = item("c1", age: 900)
        for (kind, stillThere) in [
            (PRFollowUp.Kind.conflict, facts(pullRequest(mergeable: "CONFLICTING"))),
            (.ci, facts(pullRequest(rollup: red))),
            (.feedback, facts(pullRequest(), feedback: [feedback]))
        ] {
            var entry = PRFollowUp.Entry(rounds: [round(kind, on: head, items: [feedback.url])], handedFeedback: [feedback.url])
            XCTAssertEqual(PRFollowUp.next(&entry, stillThere), .wait("stopped: nothingPushed"), "\(kind)")
            XCTAssertEqual(entry.stop?.cause, .nothingPushed, "\(kind)")
            XCTAssertNotNil(entry.rounds.last?.settledAt, "\(kind)")
        }

        // GitHub still computing, a rerun going: nothing is known yet.
        let unknown = [
            (PRFollowUp.Kind.conflict, facts(pullRequest(mergeable: "UNKNOWN"))),
            (.ci, facts(pullRequest(rollup: [checkRun("test", conclusion: "", status: "IN_PROGRESS")])))
        ]
        for (kind, computing) in unknown {
            XCTAssertEqual(next(computing, PRFollowUp.Entry(rounds: [round(kind, on: head)])), .wait("GitHub is still computing"))
            // Pending for good (a job waiting on an approval): settled, no stop.
            var late = PRFollowUp.Entry(rounds: [round(kind, on: head, endedAgo: PRFollowUp.settleLimit + 1)])
            XCTAssertEqual(PRFollowUp.next(&late, computing), .none, "\(kind)")
            XCTAssertNil(late.stop)
        }

        // Gone without a push (a question answered, a rerun that passed):
        // nothing to hand over; newer feedback is the next round's.
        var answered = PRFollowUp.Entry(rounds: [round(.feedback, on: head, items: [feedback.url])], handedFeedback: [feedback.url])
        XCTAssertEqual(typed(PRFollowUp.next(&answered, facts(pullRequest(), feedback: [item("c2", age: 600)])))?.round.kind,
                       .feedback)
        XCTAssertNil(answered.stop)
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

    func testACheckoutApartFromThePullRequestStopsItUntilTheyMeet() {
        var apart = facts(pullRequest(rollup: red))
        apart.localHead = pushed
        var entry = PRFollowUp.Entry(rounds: [round(.ci, on: head, endedAgo: 300)])
        XCTAssertEqual(PRFollowUp.next(&entry, apart), .wait("the checkout isn't at the pull request's head"))
        entry = PRFollowUp.Entry(rounds: [round(.ci, on: head, endedAgo: PRFollowUp.settleLimit + 1)])
        XCTAssertEqual(PRFollowUp.next(&entry, apart), .wait("stopped: checkoutDiffers"))
        XCTAssertEqual(PRFollowUp.next(&entry, apart), .wait("stopped: checkoutDiffers"))

        var met = entry
        XCTAssertEqual(PRFollowUp.next(&met, facts(pullRequest())), .none, "the checkout moved to the pull request's head")
        XCTAssertNil(met.stop)
        var pulled = facts(pullRequest(head: pushed))
        pulled.localHead = pushed
        XCTAssertEqual(PRFollowUp.next(&entry, pulled), .none)
        XCTAssertNil(entry.stop)
    }

    func testAfterThreeRoundsEachNewSignalGoesToTheUser() {
        var entry = PRFollowUp.Entry(rounds: [
            round(.ci, on: "1", settled: true), round(.conflict, on: "2", settled: true), round(.ci, on: "3", settled: true)
        ])
        let failed = facts(pullRequest(rollup: red))
        var busy = failed
        busy.agentRefusal = "working"
        XCTAssertEqual(PRFollowUp.next(&entry, busy), .wait("working"), "it may be fixing it with the user")
        XCTAssertNil(entry.stop)
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

    /// A stop is about what stopped it; while that isn't known, it holds.
    func testAStopHoldsWhileItsCauseIsThereOrUnknown() {
        let conflictStop = PRFollowUp.Stop(kind: .conflict, cause: .nothingPushed, head: head, at: now - 60)
        var entry = PRFollowUp.Entry(stop: conflictStop)
        XCTAssertEqual(PRFollowUp.next(&entry, facts(pullRequest(mergeable: "UNKNOWN"))), .wait("stopped: nothingPushed"))
        XCTAssertEqual(PRFollowUp.next(&entry, facts(pullRequest())), .none)
        XCTAssertNil(entry.stop)

        let c1 = item("c1", age: 900)
        let feedbackStop = PRFollowUp.Stop(kind: .feedback, cause: .nothingPushed, head: head, at: now - 60, items: [c1.url])
        var unread = facts(pullRequest())
        unread.feedback = nil
        XCTAssertEqual(next(unread, PRFollowUp.Entry(stop: feedbackStop)), .wait("stopped: nothingPushed"))
        // Resolved: an older thread still listed doesn't keep it.
        var resolved = PRFollowUp.Entry(since: now - 1800, handedFeedback: [c1.url], stop: feedbackStop)
        XCTAssertEqual(PRFollowUp.next(&resolved, facts(pullRequest(), feedback: [item("older", age: 3000)])), .none)
        XCTAssertNil(resolved.stop)
        // Answered, its reviewer's turn: neither.
        var answered = PRFollowUp.Entry(since: now - 1800, handedFeedback: [c1.url], stop: feedbackStop)
        XCTAssertEqual(PRFollowUp.next(&answered, facts(pullRequest(), feedback: [item("c1", age: 900, answered: true)])), .none)
        XCTAssertNil(answered.stop)
    }

    // MARK: - Store

    func testTheStoreIsPrivateAndKeepsStopsPastAMonth() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("pr-follow-up.json")
        var store = PRFollowUpStore()
        let old = "https://github.com/acme/widgets/pull/1"
        let stopped = "https://github.com/acme/widgets/pull/2"
        let current = "https://github.com/acme/widgets/pull/52"
        let monthAgo = now - PRFollowUpStore.lifetime
        XCTAssertTrue(store.update(old, now: monthAgo) { _ in }, "a new entry is saved: it says since when")
        XCTAssertEqual(store.pullRequests[old]?.since, monthAgo)
        XCTAssertFalse(store.update(old, now: monthAgo) { _ in })
        store.update(stopped, now: monthAgo) { $0.stop = PRFollowUp.Stop(kind: .ci, cause: .rounds, head: self.head, at: monthAgo) }
        XCTAssertTrue(store.update(current, now: now, since: now - 600) { $0.rounds = [self.round(.ci, on: self.head)] })
        XCTAssertEqual(store.pullRequests[current]?.since, now - 600, "from when its space's follow-up turned on")
        store.spacesOnSince["space"] = now - 600
        XCTAssertEqual(Set(store.pullRequests.keys), [stopped, current])
        XCTAssertEqual(store.pullRequests[current]?.updatedAt, now)

        store.save(to: url)
        XCTAssertEqual(PRFollowUpStore.load(from: url), store)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertEqual(PRFollowUpStore.load(from: folder.appendingPathComponent("missing.json")), PRFollowUpStore())
    }

    /// Another build's file is read on the side of typing less: an
    /// unknown round still counts, a missing start is the last change.
    func testTheStoreReadsWhatItCan() throws {
        let json = """
        {"pullRequests": {
          "a": {"updatedAt": 9, "rounds": [{"kind": "ci", "head": "h", "typedAt": 6},
                                            {"kind": "deploy", "head": "h", "typedAt": 7, "items": []}],
                "stop": {"kind": "ci", "cause": "someday", "head": "h", "at": 8}, "extra": 1},
          "b": "garbage"
        }}
        """
        let store = try JSONDecoder().decode(PRFollowUpStore.self, from: Data(json.utf8))
        XCTAssertEqual(store.pullRequests, ["a": PRFollowUp.Entry(
            since: 9, rounds: [PRFollowUp.Round(kind: .ci, head: "h", typedAt: 6), .unreadable], updatedAt: 9
        )])
    }

    // MARK: - What the shell reads

    func testTheAgentGateWaitsForAFreePromptAndSaysWhenItsTurnMayGoOn() {
        let free = PRFollowUp.AgentState(lastTurnEndedAt: now - 60)
        func gate(_ change: (inout PRFollowUp.AgentState) -> Void) -> [String] {
            var agent = free
            change(&agent)
            let gate = PRFollowUp.gate(agent, now: now)
            return [gate.refusal ?? "free", gate.isBusy ? "busy" : "idle"]
        }
        XCTAssertEqual(gate { _ in }, ["free", "idle"])
        XCTAssertEqual(gate { $0.refusal = .working }, ["working", "busy"])
        XCTAssertEqual(gate { $0.refusal = .failedTurn }, ["failedTurn", "busy"], "a usage limit: what the round did is unknown")
        XCTAssertEqual(gate { $0.refusal = .noPromptYet }, ["noPromptYet", "idle"], "resumed: it takes nothing until the user types")
        XCTAssertEqual(gate { $0.waitsOnUser = true }, ["it waits on the user", "busy"])
        XCTAssertEqual(gate { $0.missionWaits = true }, ["a Mission message waits", "busy"])
        XCTAssertEqual(gate { $0.lastTurnEndedAt = now - 10 }, ["its turn just ended", "idle"])
        XCTAssertEqual(gate { $0.isWatched = true }, ["the user is on its terminal", "idle"])
    }

    func testTheRowSaysTheRoundAndWhyThePullRequestIsTheUsers() {
        XCTAssertEqual(PRFollowUp.roundText(.ci, number: 2), "Auto follow-up 2/3 · failed checks")
        let pullRequest = pullRequest(base: "develop")
        let cases: [(PRFollowUp.Kind, PRFollowUp.Stop.Cause, String)] = [
            (.conflict, .rounds, "#52 conflicts with develop after 3 automatic rounds"),
            (.ci, .nothingPushed, "#52 still fails its checks: the automatic round pushed nothing"),
            (.feedback, .nothingPushed, "#52 still has review feedback open: the automatic round pushed nothing"),
            (.feedback, .checkoutDiffers, "#52: the checkout isn’t at the pull request’s head after the automatic round")
        ]
        for (kind, cause, text) in cases {
            XCTAssertEqual(PRFollowUp.stopText(PRFollowUp.Stop(kind: kind, cause: cause, head: head, at: now), pullRequest: pullRequest), text)
        }
        XCTAssertEqual(NiruxShellView.pullRequestRepository("https://github.com/Acme/Widgets/pull/52"),
                       GitHubRepository(owner: "acme", name: "widgets"))
        XCTAssertNil(NiruxShellView.pullRequestRepository("https://github.com/acme/widgets/issues/52"))
    }

    /// Another Nirux on the same state directory writes the file too.
    @MainActor
    func testAFileWrittenElsewhereIsReadAgain() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("pr-follow-up.json")
        let file = FileBackedValue(url: url, read: { PRFollowUpStore.load(from: $0) }, write: { $0.save(to: $1) })
        XCTAssertEqual(file.value, PRFollowUpStore())
        file.update { $0.update("a", now: self.now) { _ in } }
        // Two writes within the date's precision: the file is another one.
        let sameDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: sameDate], ofItemAtPath: url.path)
        XCTAssertEqual(Set(file.value.pullRequests.keys), ["a"])
        var other = PRFollowUpStore.load(from: url)
        other.update("b", now: now) { _ in }
        other.save(to: url)
        try FileManager.default.setAttributes([.modificationDate: sameDate], ofItemAtPath: url.path)
        XCTAssertEqual(Set(file.value.pullRequests.keys), ["a", "b"], "written right after, read again")
    }
}
