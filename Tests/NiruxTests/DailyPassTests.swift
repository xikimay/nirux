import XCTest
@testable import Nirux

/// The daily pass (DailyPass): what GitHub, the CI triage, the Missions
/// ledger and the rules say of a space's day, the digest its Lead reads,
/// and where the next pass starts.
final class DailyPassTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let hour: TimeInterval = 3600
    /// 2027-01-15 08:00 UTC.
    private let now: TimeInterval = 1_800_000_000
    private var window: DailyPass.Window { DailyPass.Window(start: now - 24 * hour, end: now) }

    /// Merged pull requests with their rounds (the highest "round N" of
    /// their commits) and their Why; reruns are runs past their first
    /// attempt. Anything but a list reads as nothing.
    func testMergedPullRequestsAndReruns() throws {
        let merged = Data("""
            [{"number": 611, "title": "Floors", "headRefName": "feat/floors", "mergedAt": "2027-01-15T07:00:00Z",
              "body": "## Why\\nThe floors\\nmove.\\n\\n## How\\n- a bullet",
              "commits": [{"messageHeadline": "feat: floors"}, {"messageHeadline": "fix: the Lead's round 2"},
                          {"messageHeadline": "fix(floors): review round 1 of the floors"}]},
             {"number": 600, "title": "Old", "headRefName": "feat/old", "mergedAt": "2027-01-15T01:00:00Z", "body": "Plain text.\\n\\nMore."},
             {"title": "No number", "mergedAt": "2027-01-15T01:00:00Z"}]
            """.utf8)
        let pulls = try XCTUnwrap(DailyPass.mergedPullRequests(merged))
        XCTAssertEqual(pulls.map(\.number), [600, 611])
        XCTAssertEqual(pulls[1].rounds, 2)
        XCTAssertEqual(pulls[1].roundCommits, ["fix: the Lead's round 2", "fix(floors): review round 1 of the floors"])
        XCTAssertEqual(pulls[1].why, "The floors move.")
        XCTAssertEqual(pulls[0].why, "Plain text.")
        XCTAssertEqual(pulls[0].rounds, 0)
        XCTAssertNil(DailyPass.mergedPullRequests(Data("{}".utf8)))

        let runs = Data("""
            [{"databaseId": 1, "attempt": 1, "headBranch": "a", "conclusion": "success", "workflowName": "Tests"},
             {"databaseId": 2, "attempt": 3, "headBranch": "feat/floors", "conclusion": "", "workflowName": "Tests"}]
            """.utf8)
        XCTAssertEqual(DailyPass.reruns(runs), [DailyPass.Rerun(id: 2, attempt: 3, branch: "feat/floors", workflow: "Tests", conclusion: "running")])
    }

    private func event(
        _ kind: MissionEvent.Kind, _ message: String, at time: TimeInterval, inReplyTo: String? = nil, id: String = UUID().uuidString
    ) -> MissionEvent {
        MissionEvent(
            id: id, missionID: "m", childWorkspaceID: "task", childAgentUUID: "agent", kind: kind, message: message,
            inReplyTo: inReplyTo, timestamp: time
        )
    }

    private func mission(_ events: [MissionEvent]) -> Mission {
        Mission(
            id: "m", parentWorkspaceID: "lead", parentAgentUUID: "lead-agent", childWorkspaceID: "task", childAgentUUID: "agent",
            childAgentKind: "claude", branch: "feat/x", status: .active, createdAt: now - 48 * hour, updatedAt: now, events: events,
            reportsToLead: true
        )
    }

    /// Held (typed an hour or more late, or still waiting), given up,
    /// crossed (typed once the task had reported, or an answer typed after
    /// a newer question); what happened before the window stays out.
    func testHeldGivenUpAndCrossedMessages() {
        var lateTell = event(.instruction, "Fix the layer", at: now - 10 * hour)
        lateTell.childConsumedAt = now - 7 * hour
        var quickTell = event(.instruction, "Quick", at: now - 10 * hour)
        quickTell.childConsumedAt = now - 10 * hour + 60
        var lostTell = event(.instruction, "Lost", at: now - 30 * hour)
        lostTell.expiredAt = now - 6 * hour
        var oldTell = event(.instruction, "Before the window", at: now - 40 * hour)
        oldTell.childConsumedAt = now - 30 * hour
        var crossingTell = event(.instruction, "Also do Y", at: now - 5 * hour)
        crossingTell.childConsumedAt = now - 3 * hour
        var result = event(.completed, "Done", at: now - 4 * hour)
        result.parentTypedAt = now - 4 * hour + 30
        let waiting = event(.instruction, "Still waiting", at: now - 2 * hour)
        var lateQuestion = event(.question, "Which base?", at: now - 9 * hour, id: "q1")
        lateQuestion.parentTypedAt = now - 6 * hour
        let newer = event(.question, "And the tests?", at: now - 8 * hour, id: "q2")
        var answer = event(.response, "main", at: now - 7 * hour, inReplyTo: "q1")
        answer.childConsumedAt = now - 7 * hour

        let facts = DailyPass.missionFacts(
            [mission([lateTell, quickTell, lostTell, oldTell, crossingTell, result, waiting, lateQuestion, newer, answer])],
            window: window, timeZone: utc
        )
        let summary = facts.map { "\($0.kind.rawValue) \($0.message) \($0.excerpt): \($0.detail)" }
        XCTAssertEqual(summary, [
            "given up tell to feat/x Lost: given up untyped after 1 d",
            "held tell to feat/x Fix the layer: typed 3 h later",
            "held question from feat/x Which base?: typed into its parent 3 h later",
            "held question from feat/x And the tests?: not typed into its parent after 8 h",
            "crossed answer to feat/x main: typed at 01-15 01:00, after its newer question (01-15 00:00)",
            "crossed tell to feat/x Also do Y: typed at 01-15 05:00, after its result (01-15 04:00)",
            "held tell to feat/x Still waiting: still untyped after 2 h"
        ])
    }

    /// A question handed to the user, with their answer, and one they
    /// answered in Nirux without being asked: their words are corrections.
    func testTheUsersAnswers() {
        var handed = event(.question, "Ship it?", at: now - 5 * hour, id: "q1")
        handed.handedToUserBecause = "a product call"
        handed.parentTypedAt = now - 5 * hour
        var answer = event(.response, "Not yet:\nwait for the review.", at: now - 4 * hour, inReplyTo: "q1")
        answer.answeredByUser = true
        var own = event(.question, "Which name?", at: now - 3 * hour, id: "q2")
        own.parentTypedAt = now - 3 * hour
        var ownAnswer = event(.response, "Call it Floors", at: now - 2 * hour, inReplyTo: "q2")
        ownAnswer.answeredByUser = true
        var unanswered = event(.question, "Rename?", at: now - hour, id: "q3")
        unanswered.handedToUserBecause = "naming"

        let facts = DailyPass.missionFacts([mission([handed, answer, own, ownAnswer, unanswered])], window: window, timeZone: utc)
        XCTAssertEqual(facts.map(\.kind), [.handedToUser, .answeredByUser, .handedToUser])
        XCTAssertEqual(facts.map(\.answer), ["Not yet: wait for the review.", "Call it Floors", nil])
        XCTAssertEqual(facts.first?.detail, "why: a product call")
    }

    /// The runs of the space's repositories triaged in the window, with
    /// their pull request, and the tests learned flaky then.
    func testCIFactsKeepTheSpacesRepositoriesAndTheWindow() {
        var store = CITriageStore()
        store.repositories["github.com/xikimay/nirux"] = CITriageStore.Repository(
            runs: [
                "7": .init(
                    signature: "s", redChecks: ["test"], tests: ["A.testB"], verdict: .flaky(reason: "a timeout"), triagedAt: now - hour,
                    pullRequest: 611
                ),
                "6": .init(signature: "s", redChecks: ["test"], tests: ["A.testC"], verdict: .real, triagedAt: now - 30 * hour)
            ],
            flakyTests: ["A.testB": now - hour, "A.testOld": now - 40 * hour]
        )
        store.repositories["github.com/someone/else"] = CITriageStore.Repository(
            runs: ["9": .init(signature: "s", redChecks: [], tests: [], verdict: .real, triagedAt: now - hour)], flakyTests: ["X.y": now]
        )
        let facts = DailyPass.ciFacts(store, repositories: ["XIKIMAY/nirux"], window: window)
        XCTAssertEqual(facts.runs, [DailyPass.TriagedRun(
            id: "7", pullRequest: 611, verdict: "flaky", reason: "a timeout", tests: ["A.testB"], triagedAt: now - hour
        )])
        XCTAssertEqual(facts.flakyTests, ["A.testB"])
    }

    private func proposal(_ rule: String, dismissedAt: TimeInterval? = nil, addedAt: TimeInterval? = nil) -> RuleProposal {
        RuleProposal(
            id: UUID().uuidString, rule: rule, evidence: "#1, #2", proposedAt: now - 48 * hour, leadWorkspaceID: nil, leadAgentUUID: nil,
            dismissedAt: dismissedAt, addedAt: addedAt
        )
    }

    private func facts() -> DailyPass.Facts {
        let layer = ReviewFindings.Finding(kind: "backing-layer", text: "The layer was replaced")
        let report = DailyPass.RepositoryReport(
            name: "xikimay/nirux",
            merged: [DailyPass.MergedPullRequest(
                number: 611, title: "Floors", branch: "feat/floors", mergedAt: now - hour, why: "The floors move.",
                roundCommits: ["fix: review round 1"], rounds: 1
            )],
            reruns: [DailyPass.Rerun(id: 44, attempt: 2, branch: "feat/floors", workflow: "Tests", conclusion: "success")]
        )
        return DailyPass.Facts(
            spaceName: "Nirux", window: window,
            findings: [
                ReviewFindings.Entry(time: now - 10 * 24 * hour, task: "feat/depth", pullRequest: 594, round: 1, findings: [layer]),
                ReviewFindings.Entry(time: now - 20 * 24 * hour, task: "feat/old", pullRequest: 500, round: 1,
                                     findings: [ReviewFindings.Finding(kind: "only-old", text: "x")]),
                ReviewFindings.Entry(time: now - 2 * hour, task: "feat/floors", pullRequest: 611, round: 3, findings: [layer])
            ],
            repositories: [report], triagedRuns: [], flakyTests: [], missions: [],
            proposals: [proposal("Waiting rule."), proposal("Dismissed rule.", dismissedAt: now - 30 * 24 * hour)],
            briefRules: ["Tests wait on state. (learned 2026-11-11, #395)"]
        )
    }

    /// What to propose (the free slots under the pending limit), the kinds
    /// the window saw with where else they showed up, each pull request's
    /// rounds (its recorded reviews count), reruns, and the rules to avoid.
    func testTheDigestSaysWhatToProposeAndCitesItsFacts() {
        let digest = DailyPass.digest(facts(), timeZone: utc)
        XCTAssertTrue(digest.hasPrefix("# Daily pass · Nirux · since 01-14 08:00"), digest)
        XCTAssertTrue(digest.contains("propose at most 2 with propose_rule (1 of 3 already wait for the user)"), digest)
        let kind = "- backing-layer · 2 tasks: #594 round 1 “The layer was replaced”; #611 round 3 “The layer was replaced”"
        XCTAssertTrue(digest.contains(kind), digest)
        XCTAssertFalse(digest.contains("only-old"), digest)
        XCTAssertTrue(digest.contains("- #611 “Floors” · branch feat/floors · 3 review rounds · 1 rerun\n  Why: The floors move."), digest)
        XCTAssertTrue(digest.contains("- rerun: run 44 · Tests · branch feat/floors (#611) · attempt 2, success"), digest)
        XCTAssertTrue(digest.contains("## Rules waiting for the user\n- “Waiting rule.” (#1, #2)"), digest)
        XCTAssertTrue(digest.contains("## The brief's rules learned\n- Tests wait on state. (learned 2026-11-11, #395)"), digest)
        XCTAssertTrue(digest.contains("## Rules dismissed in the last 90 days\n- “Dismissed rule.”"), digest)

        var full = facts()
        full.proposals = (1...3).map { proposal("Rule \($0).") }
        XCTAssertTrue(DailyPass.digest(full, timeZone: utc).contains("Propose no rule now: 3 already wait for the user."))
    }

    /// A day with nothing to read says so; a huge one is cut.
    func testANothingDayAndAHugeOne() {
        var quiet = facts()
        quiet.findings = quiet.findings.filter { !window.contains($0.time) }
        quiet.repositories = []
        XCTAssertFalse(quiet.hasNews)
        XCTAssertTrue(DailyPass.digest(quiet, timeZone: utc).contains("Nothing happened since 01-14 08:00"))
        quiet.proposals.append(proposal("Added today.", addedAt: now - hour))
        XCTAssertTrue(quiet.hasNews, "a rule decided is news")

        var many = facts()
        many.briefRules = (1...200).map { "Rule \($0)." }
        XCTAssertTrue(DailyPass.digest(many, timeZone: utc).contains("- Rule 60.\n- … and 140 more"), "a section says what it leaves out")
        many.briefRules = (1...200).map { "Rule \($0) " + String(repeating: "x", count: 1_000) }
        let digest = DailyPass.digest(many, timeZone: utc)
        XCTAssertLessThan(digest.count, DailyPass.maxCharacters + 100)
        XCTAssertTrue(digest.hasSuffix("(cut: the digest passed \(DailyPass.maxCharacters) characters)"), String(digest.suffix(200)))
    }

    /// The first pass reads the last day; the next starts where it ended,
    /// unless it comes within two hours (the same window, longer); never
    /// more than a week. Saved 0600.
    func testTheWindowStartsWhereTheLastPassEnded() throws {
        XCTAssertEqual(DailyPassState().window(now: now), DailyPass.Window(start: now - 24 * hour, end: now))
        let last = DailyPassState(start: now - 30 * hour, end: now - 5 * hour)
        XCTAssertEqual(last.window(now: now), DailyPass.Window(start: now - 5 * hour, end: now))
        XCTAssertEqual(last.window(now: now - 4 * hour), DailyPass.Window(start: now - 30 * hour, end: now - 4 * hour))
        XCTAssertEqual(DailyPassState(start: 0, end: 1).window(now: now).start, now - 7 * 24 * hour)

        let state = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-pass-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        try last.save(spaceID: "S1", stateDirectory: state)
        XCTAssertEqual(DailyPassState.load(spaceID: "S1", stateDirectory: state), last)
        let url = try XCTUnwrap(DailyPassState.url(spaceID: "S1", stateDirectory: state))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }

    /// The brief's rules learned: that section's bullets as sessions read
    /// them, not the rest of the brief, comments or code.
    func testTheBriefsRulesLearned() {
        let brief = """
            # Space
            - Not a learned rule.

            ## Rules learned

            - Tests wait on state. (learned 2026-11-11, #395)
            <!-- - A hidden rule. -->
            - One owner per state,
              whatever the view.
            ```
            - In code.
            ```

            ## Next
            - After it.
            """
        XCTAssertEqual(LearnedRules.learnedRules(in: brief), [
            "Tests wait on state. (learned 2026-11-11, #395)", "One owner per state, whatever the view."
        ])
    }
}
