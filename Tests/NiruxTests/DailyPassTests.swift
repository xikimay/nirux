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
        // A review round, not any "round N".
        XCTAssertEqual(DailyPass.roundNumber("fix(lead): PR 3 review round 2"), 2)
        XCTAssertEqual(DailyPass.roundNumber("fix(columns): round 1 of the lift"), 1)
        XCTAssertNil(DailyPass.roundNumber("fix(time): round 60 seconds up"))
        XCTAssertNil(DailyPass.roundNumber("fix(lead): round 3 timeout"))
        XCTAssertNil(DailyPass.roundNumber("review round 40 of the cache"), "past \(DailyPass.maxRound)")
        XCTAssertEqual(DailyPass.roundNumber("fix: round 2 review of the cache"), 2)
        XCTAssertEqual(DailyPass.roundNumber("fix(lead): the Lead's review of #586, round 1"), 1)
        XCTAssertNil(DailyPass.roundNumber("fix: review the timeout, round 3 seconds"), "\"review\" right before \"round\", or the forms above")

        let runs = Data("""
            [{"databaseId": 1, "attempt": 1, "headBranch": "a", "conclusion": "success", "workflowName": "Tests", "startedAt": "2027-01-15T07:00:00Z",
              "status": "completed", "event": "push", "headSha": "\(String(repeating: "a", count: 40))"},
             {"databaseId": 2, "attempt": 3, "headBranch": "feat/floors", "conclusion": "", "workflowName": "Tests", "startedAt": "2027-01-15T07:00:00Z",
              "status": "in_progress", "event": "pull_request", "headSha": "\(String(repeating: "b", count: 40))"}]
            """.utf8)
        XCTAssertEqual(DailyPass.reruns(runs), [
            DailyPass.Rerun(id: 2, attempt: 3, branch: "feat/floors", workflow: "Tests", conclusion: "running", startedAt: now - hour)
        ])
    }

    /// Each repository read with its own calls, in the order given; what
    /// merged or was rerun outside the window stays out (a run counts by
    /// its last attempt's start); what gh couldn't answer is said, and read
    /// again only when gh didn't answer in time; a list at gh's limit says
    /// so.
    func testEachRepositoryIsReadAndItsProblemsSaid() {
        let pulls = Data("""
            [{"number": 3, "title": "After", "headRefName": "c", "mergedAt": "2027-01-15T09:00:00Z"},
             {"number": 2, "title": "In", "headRefName": "b", "mergedAt": "2027-01-15T07:00:00Z"},
             {"number": 1, "title": "Before", "headRefName": "a", "mergedAt": "2027-01-13T07:00:00Z"}]
            """.utf8)
        let runs = Data("""
            [{"databaseId": 7, "attempt": 2, "headBranch": "b", "conclusion": "success", "workflowName": "Tests", "startedAt": "2027-01-15T07:00:00Z",
              "status": "completed", "event": "push", "headSha": "\(String(repeating: "7", count: 40))"},
             {"databaseId": 6, "attempt": 2, "headBranch": "a", "conclusion": "success", "workflowName": "Tests", "startedAt": "2027-01-14T07:00:00Z",
              "status": "completed", "event": "push", "headSha": "\(String(repeating: "6", count: 40))"}]
            """.utf8)
        let many = Data(("[" + (1...DailyPass.mergedLimit).map { "{\"number\": \($0), \"title\": \"t\", \"mergedAt\": \"2027-01-15T07:00:00Z\"}" }
            .joined(separator: ",") + "]").utf8)
        let repositories = ["acme/one", "acme/two", "acme/three", "acme/busy", "acme/limited", "acme/odd", "acme/wordy"]
        let answer: @Sendable (Data) -> Result<GitHub.CLI.Output, GitHub.CLI.Failure> = { .success(.init(status: 0, standardOutput: $0, standardError: Data())) }
        let reports = DailyPass.readGitHub(repositories, window: window) { call in
            let arguments = call.arguments
            if arguments.contains("github.com/acme/two") { return .failure(.noAnswer("gh didn’t answer")) }
            if arguments.contains("github.com/acme/three") { return .failure(.notSignedIn("not signed in")) }
            if arguments.contains("github.com/acme/busy") { return answer(arguments.first == "pr" ? many : Data("[]".utf8)) }
            if arguments.contains("github.com/acme/limited") { return .failure(.rateLimited(resetAt: nil)) }
            if arguments.contains("github.com/acme/odd") { return answer(Data("<html>".utf8)) }
            if arguments.contains("github.com/acme/wordy") { return .failure(.refused(status: nil, message: "Bad\n" + String(repeating: "word ", count: 100))) }
            return answer(arguments.first == "pr" ? pulls : runs)
        }
        XCTAssertEqual(reports.map(\.name), repositories)
        XCTAssertEqual(reports[0].merged.map(\.number), [2])
        XCTAssertEqual(reports[0].reruns.map(\.id), [7])
        XCTAssertEqual(reports[0].problems, [])
        XCTAssertEqual(reports[1].problems, ["merged pull requests: gh didn’t answer", "workflow runs: gh didn’t answer"])
        XCTAssertEqual(reports.map(\.readsAgain), [false, true, false, false, true, false, false], "a rate limit passes by itself too")
        XCTAssertEqual(reports[3].problems, ["only the \(DailyPass.mergedLimit) most recently updated merged pull requests were read"])
        XCTAssertEqual(reports[5].problems, [
            "merged pull requests: gh answered with something Nirux can’t read: <html>",
            "workflow runs: gh answered with something Nirux can’t read: <html>"
        ])
        XCTAssertEqual(reports[6].problems.count, 2)
        XCTAssertTrue(reports[6].problems.allSatisfy { !$0.contains("\n") && $0.count < 330 }, "gh's words are cleaned before the Lead reads them")
    }

    /// No answer (no network, a timeout, a 5xx, what gh never said) and
    /// rate limits read the window again; anything GitHub or gh said
    /// (signed out, refused) holds.
    func testAGitHubErrorReadsAgainUnlessItHolds() {
        func retries(_ standardError: String, status: Int32 = 1) -> Bool {
            DailyPass.mayPassLater(GitHub.CLI.classify(GitHub.CLI.Output(status: status, standardOutput: Data(), standardError: Data(standardError.utf8))))
        }
        XCTAssertTrue(retries("error connecting to api.github.com\ncheck your internet connection or https://githubstatus.com"))
        XCTAssertTrue(retries("HTTP 502: Bad Gateway (https://api.github.com/graphql)"))
        XCTAssertTrue(retries("GraphQL: API rate limit exceeded for user ID 1."))
        XCTAssertTrue(retries("gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (HTTP 403)"))
        XCTAssertTrue(retries("something gh never said before"))
        XCTAssertFalse(retries("To get started with GitHub CLI, please run:  gh auth login", status: 4))
        XCTAssertFalse(retries("GraphQL: Could not resolve to a Repository with the name 'acme/gone'. (repository)"))
        XCTAssertFalse(retries("HTTP 404: Not Found (https://api.github.com/repos/acme/gone)"))
        XCTAssertFalse(retries("HTTP 422: Validation Failed (https://api.github.com/search/issues)"))
        XCTAssertFalse(retries("GraphQL: Resource protected by organization SAML enforcement. (repository)"))
        XCTAssertFalse(DailyPass.mayPassLater(.ghMissing))
        XCTAssertFalse(DailyPass.mayPassLater(.unreadable("<html>")))
    }

    /// Three reads in a row that GitHub may answer next time at most: the
    /// third marks the window read all the same; a full read starts over.
    func testRereadsStopAfterThree() {
        var rereads = DailyPass.Rereads()
        XCTAssertEqual([true, true, true].map { rereads.readsAgain($0) }, [true, true, false])
        XCTAssertFalse(rereads.readsAgain(false))
        XCTAssertTrue(rereads.readsAgain(true), "counted again from a full read")
    }

    /// Folders whose base remote names the same repository read it once;
    /// one whose remote couldn't be read says so and reads the window
    /// again; one without a GitHub remote is left alone.
    func testAnUnreadRemoteIsNoSilentSkip() {
        let remotes = DailyPass.repositories(from: [
            ("/w/app", .gitHub(repository: "acme/app", remote: "origin")), ("/w/slow", .unread),
            ("/w/app-2", .gitHub(repository: "ACME/app", remote: "upstream")), ("/w/local", .noRemote)
        ])
        XCTAssertEqual(remotes.gitHub.map(\.name), ["acme/app"])
        XCTAssertEqual(remotes.gitHub.first?.folders, ["/w/app", "/w/app-2"])
        XCTAssertEqual(remotes.unread.map(\.name), ["slow"])
        XCTAssertEqual(remotes.unread.map(\.readsAgain), [true])
        XCTAssertEqual(remotes.unread.first?.problems, ["its remote couldn’t be read (git or ssh didn’t answer)"])
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
        // Answered by its parent long after: Nirux types one for an hour only.
        let late = event(.question, "Late?", at: now - 6 * hour, id: "q3")
        let lateAnswer = event(.response, "Yes", at: now - 3 * hour, inReplyTo: "q3")
        var lateQuestion = event(.question, "Which base?", at: now - 9 * hour, id: "q1")
        lateQuestion.parentTypedAt = now - 6 * hour
        let newer = event(.question, "And the tests?", at: now - 8 * hour, id: "q2")
        var answer = event(.response, "main", at: now - 7 * hour, inReplyTo: "q1")
        answer.childConsumedAt = now - 7 * hour

        // A sub-task's parent may have read it with `receive`: nothing typed proves nothing.
        var subtask = mission([event(.question, "Read?", at: now - 6 * hour, id: "s1"), event(.response, "Yes", at: now - 3 * hour, inReplyTo: "s1")])
        subtask.reportsToLead = nil
        subtask.reportsToTask = true
        let facts = DailyPass.missionFacts(
            [mission([lateTell, quickTell, lostTell, oldTell, crossingTell, result, waiting, lateQuestion, newer, answer, late, lateAnswer]), subtask],
            window: window, timeZone: utc
        )
        let summary = facts.map { "\($0.kind.rawValue) \($0.message) \($0.excerpt): \($0.detail)" }
        XCTAssertEqual(summary, [
            "given up tell to feat/x Lost: given up after 1 d",
            "held tell to feat/x Fix the layer: typed 3 h later",
            "held question from feat/x Which base?: typed into its parent 3 h later",
            "held question from feat/x And the tests?: not typed into its parent after 8 h",
            "crossed answer to feat/x main: typed at 01-15 01:00, after its newer question (01-15 00:00)",
            "held question from feat/x Late?: answered 3 h later, never typed into its parent",
            "crossed tell to feat/x Also do Y: typed at 01-15 05:00, after its result (01-15 04:00)",
            "held tell to feat/x Still waiting: still untyped after 2 h"
        ])
    }

    /// A question handed to the user, with their answer (or the Lead's,
    /// once it heard it), and one they answered in Nirux without being
    /// asked: their words are corrections. A line that looks like a secret
    /// is withheld.
    func testTheUsersAnswers() {
        var handed = event(.question, "Ship it?", at: now - 5 * hour, id: "q1")
        handed.handedToUserBecause = "a product call"
        handed.parentTypedAt = now - 5 * hour
        var answer = event(.response, "Not yet:\nwait for the review.\nAPI_TOKEN=abcd1234efgh5678", at: now - 4 * hour, inReplyTo: "q1")
        answer.answeredByUser = true
        var own = event(.question, "Which name?", at: now - 3 * hour, id: "q2")
        own.parentTypedAt = now - 3 * hour
        var ownAnswer = event(.response, "Call it Floors", at: now - 2 * hour, inReplyTo: "q2")
        ownAnswer.answeredByUser = true
        var relayed = event(.question, "Which port?", at: now - 2 * hour, id: "q4")
        relayed.handedToUserBecause = "a setting"
        relayed.parentTypedAt = now - 2 * hour
        let relayedAnswer = event(.response, "8080", at: now - 90 * 60, inReplyTo: "q4")
        var unanswered = event(.question, "Rename?", at: now - hour, id: "q3")
        unanswered.handedToUserBecause = "naming"
        // Asked before the window, handed over in it.
        var older = event(.question, "Which repo?", at: now - 30 * hour, id: "q5")
        older.handedToUserBecause = "a choice"
        older.handedToUserAt = now - 2 * hour

        let facts = DailyPass.missionFacts(
            [mission([handed, answer, own, ownAnswer, relayed, relayedAnswer, unanswered, older])], window: window, timeZone: utc
        )
        XCTAssertEqual(facts.map(\.kind), [.handedToUser, .handedToUser, .answeredByUser, .handedToUser, .handedToUser])
        XCTAssertEqual(facts.map(\.answer), [
            nil, "Not yet: wait for the review. [withheld: it looks like a secret]", "Call it Floors", "8080", nil
        ])
        XCTAssertEqual(facts.map(\.answeredByUser), [false, true, true, false, false])
        XCTAssertEqual(facts.first?.at, now - 2 * hour)
        XCTAssertEqual(facts[1].detail, "why: a product call")
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
            name: "xikimay/nirux", folders: ["/w/nirux"],
            merged: [DailyPass.MergedPullRequest(
                number: 611, title: "Floors", branch: "feat/floors", mergedAt: now - hour, why: "The floors move.",
                roundCommits: ["fix: review round 1"], rounds: 1
            )],
            reruns: [DailyPass.Rerun(id: 44, attempt: 2, branch: "feat/floors", workflow: "Tests", conclusion: "success", startedAt: now - hour)]
        )
        return DailyPass.Facts(
            spaceName: "Nirux", window: window,
            findings: [
                ReviewFindings.Entry(time: now - 10 * 24 * hour, workspace: "W1", task: "feat/depth", pullRequest: 594, round: 1, findings: [layer]),
                ReviewFindings.Entry(time: now - 20 * 24 * hour, workspace: "W2", task: "feat/old", pullRequest: 500, round: 1,
                                     findings: [ReviewFindings.Finding(kind: "only-old", text: "x")]),
                // Recorded before its pull request opened: it counts all the same.
                ReviewFindings.Entry(
                    time: now - 2 * hour, workspace: "W3", task: "feat/floors", pullRequest: nil, repository: "/w/nirux", round: 3, findings: [layer]
                ),
                // The same branch name in another repository doesn't.
                ReviewFindings.Entry(time: now - 3 * hour, workspace: "W4", task: "feat/floors", repository: "/w/other", round: 5, findings: []),
                // One recorded before reviews kept their repository counts.
                ReviewFindings.Entry(time: now - 4 * hour, workspace: "W5", task: "feat/floors", round: 4, findings: [])
            ],
            repositories: [report], triagedRuns: [], flakyTests: [], missions: [],
            proposals: [
                proposal("Waiting rule."), proposal("Dismissed rule.", dismissedAt: now - 30 * 24 * hour),
                proposal("Dismissed long ago.", dismissedAt: now - 100 * 24 * hour)
            ],
            briefRules: ["Tests wait on state. (learned 2026-11-11, #395)"]
        )
    }

    /// The morning line: what landed, then what waits and on whom, first in
    /// the digest, quiet or not.
    func testTheDigestOpensWithTheMorningLine() {
        var facts = facts()
        XCTAssertEqual(DailyPass.morningLine(facts), "Overnight: landed #611, nothing waits.")
        var red = PRInfo(number: 812, state: .open, isDraft: false, ciStatus: "FAILURE", checks: [], reviewDecision: nil,
                         mergeable: nil, url: "u", additions: nil, deletions: nil, changedFiles: nil)
        red.headRefOid = "a"
        facts.tasks = [
            DailyPass.TaskActivity(id: "1", title: "Login", waitsOnUser: "a login"),
            DailyPass.TaskActivity(id: "2", title: "Canary", question: .init(id: "q")),
            DailyPass.TaskActivity(id: "3", title: "Picker", question: .init(id: "q2", handedToUser: true)),
            DailyPass.TaskActivity(id: "4", title: "Awake", pullRequest: red),
            DailyPass.TaskActivity(id: "5", title: "Landed", question: .init(id: "q3"), mergedLately: true)
        ]
        let line = "Overnight: landed #611; waiting on you: Login, Picker; on the Lead: Canary; red CI, on the task: Awake (#812)."
        XCTAssertEqual(DailyPass.morningLine(facts), line)
        XCTAssertTrue(DailyPass.digest(facts, timeZone: utc).text.contains("## Morning line\nOpen your answer to the user with this line, as it is:\n" + line))
        facts.repositories = []
        facts.findings = []
        XCTAssertTrue(DailyPass.digest(facts, timeZone: utc).text.contains("Overnight: landed nothing; waiting on you"), "quiet too")
    }

    /// What to propose (the free slots under the pending limit), the kinds
    /// the window saw with where else they showed up, each pull request's
    /// rounds (its recorded reviews count), reruns, and the rules to avoid.
    func testTheDigestSaysWhatToProposeAndCitesItsFacts() throws {
        let read = DailyPass.digest(facts(), timeZone: utc)
        XCTAssertEqual(read.readUntil, now, "all of it shown")
        let digest = read.text
        XCTAssertTrue(digest.hasPrefix("# Daily pass · Nirux · since 01-14 08:00"), digest)
        XCTAssertTrue(digest.contains("propose at most 2 with propose_rule (1 of 3 already wait for the user)"), digest)
        let kind = "- backing-layer · 2 tasks: #594 round 1 “The layer was replaced”; feat/floors round 3 “The layer was replaced”"
        XCTAssertTrue(digest.contains(kind), digest)
        XCTAssertFalse(digest.contains("only-old"), digest)
        XCTAssertTrue(digest.contains("- #611 “Floors” · branch feat/floors · 4 review rounds · 1 run rerun\n  Why: The floors move."), digest)
        XCTAssertTrue(digest.contains("- rerun: run 44 · Tests · branch feat/floors (#611) · attempt 2, success"), digest)
        XCTAssertTrue(digest.contains("## Rules waiting for the user\n- “Waiting rule.” (#1, #2)"), digest)
        XCTAssertTrue(digest.contains("## The brief's rules learned\n- Tests wait on state. (learned 2026-11-11, #395)"), digest)
        XCTAssertTrue(digest.contains("## Rules dismissed in the last 90 days\n- “Dismissed rule.”"), digest)
        XCTAssertFalse(digest.contains("Dismissed long ago."), digest)
        let rules = digest.range(of: "## The brief's rules learned")?.lowerBound
        let pulls = digest.range(of: "## Pull requests merged")?.lowerBound
        XCTAssertLessThan(try XCTUnwrap(rules), try XCTUnwrap(pulls), "a cut takes the end: the rules come first")
        XCTAssertFalse(digest.contains("What GitHub didn’t say"), digest)

        var full = facts()
        full.proposals = (1...3).map { proposal("Rule \($0).") }
        XCTAssertTrue(DailyPass.digest(full, timeZone: utc).text.contains("Propose no rule now: 3 already wait for the user."))
    }

    /// A day with nothing to read says so, and what GitHub didn't say
    /// (which is no news: a signed-out gh would make every day one). A
    /// huge day lists less, and one that leaves facts out is read up to
    /// the first of them only, and says so.
    func testANothingDayAndAHugeOne() {
        var quiet = facts()
        quiet.findings = quiet.findings.filter { !window.contains($0.time) }
        quiet.repositories = []
        XCTAssertFalse(quiet.hasNews)
        XCTAssertTrue(DailyPass.digest(quiet, timeZone: utc).text.contains("Nothing happened since 01-14 08:00"))
        var unread = quiet
        unread.repositories = [DailyPass.RepositoryReport(name: "acme/one", problems: ["merged pull requests: timed out"], readsAgain: true)]
        XCTAssertFalse(unread.hasNews)
        XCTAssertTrue(unread.readsAgain)
        let said = DailyPass.digest(unread, timeZone: utc).text
        XCTAssertTrue(said.contains("Nothing happened since 01-14 08:00: no review recorded, no CI failure,"), said)
        XCTAssertTrue(said.contains("## What GitHub didn’t say\n- acme/one: merged pull requests: timed out\nThe next pass reads this window again."), said)
        quiet.proposals.append(proposal("Added today.", addedAt: now - hour))
        XCTAssertTrue(quiet.hasNews, "a rule decided is news")

        var many = facts()
        many.briefRules = (1...200).map { "Rule \($0)." }
        XCTAssertTrue(DailyPass.digest(many, timeZone: utc).text.contains("- Rule 60.\n- … and 140 more"), "a section says what it leaves out")
        many.briefRules = (1...200).map { "Rule \($0) " + String(repeating: "x", count: 1_000) }
        let long = DailyPass.digest(many, timeZone: utc)
        XCTAssertLessThanOrEqual(long.text.count, DailyPass.maxCharacters)
        XCTAssertTrue(long.text.contains("- … and 170 more"), "shorter lists, not a cut")
        XCTAssertEqual(long.readUntil, now, "the brief's rules are no facts of the day")

        var busy = facts()
        // Sent in the other order than what put them in the window: cut by the latter.
        busy.missions = (0...DailyPass.maxItems).reversed().map { index in
            let time = now - 20 * hour + Double(index) * 60
            return DailyPass.MissionFact(
                kind: .held, message: "tell \(index)", sentAt: now - 30 * hour - Double(index) * 60, at: time, detail: "typed late", excerpt: ""
            )
        }
        let cut = DailyPass.digest(busy, timeZone: utc)
        XCTAssertEqual(cut.readUntil, now - 20 * hour + Double(DailyPass.maxItems) * 60)
        XCTAssertTrue(cut.text.contains("Left out: what came after 01-14 12:30. The window is read up to there only"), cut.text)
        XCTAssertTrue(cut.text.contains("tell 0,") && !cut.text.contains("tell \(DailyPass.maxItems),"), "the earliest shown")
    }

    /// Each read ends later than it started, whatever it leaves out: a
    /// kind's older sightings are context, kinds and facts are cut in time
    /// order, learned flaky tests are all shown, and sections too long at
    /// the smallest lists go whole, read again next time.
    func testTheWindowAlwaysMovesOn() {
        var day = facts()
        day.repositories = []
        day.findings = (0..<10).map { index in
            ReviewFindings.Entry(time: now - Double(10 - index) * hour, workspace: "W\(index)", task: "t\(index)", round: 1,
                                 findings: [ReviewFindings.Finding(kind: "busy", text: "x")])
        }
        XCTAssertEqual(DailyPass.digest(day, timeZone: utc).readUntil, now, "older sightings are context")

        day.findings = (0..<40).map { index in
            ReviewFindings.Entry(time: now - 20 * hour + Double(index) * 60, workspace: "W\(index)", task: "t\(index)", round: 1,
                                 findings: [ReviewFindings.Finding(kind: "kind-\(index)", text: "x")])
        }
        day.flakyTests = (0..<50).map { "Suite.test\($0)" }
        let first = DailyPass.digest(day, timeZone: utc)
        XCTAssertEqual(first.readUntil, now - 20 * hour + Double(DailyPass.maxItems) * 60)
        XCTAssertTrue(first.text.contains("Suite.test0, ") && first.text.contains("Suite.test49"), "every flaky test")
        XCTAssertTrue(first.text.contains("- kind-0 ·") && !first.text.contains("- kind-39 ·"), "the earliest kinds are shown")
        var rest = day
        rest.window.start = first.readUntil
        XCTAssertEqual(DailyPass.digest(rest, timeZone: utc).readUntil, now, "the next read takes the rest")

        var huge = facts()
        huge.repositories = (0..<80).map { repository in
            DailyPass.RepositoryReport(name: "acme/r\(repository)", merged: (0..<4).map { index in
                DailyPass.MergedPullRequest(
                    number: index, title: String(repeating: "t", count: 200), branch: "b\(index)",
                    mergedAt: now - 10 * hour + Double(repository * 4 + index) * 60, why: String(repeating: "w", count: 300),
                    roundCommits: [], rounds: 0
                )
            })
        }
        // Facts left out at the window's very start: it moves on all the same.
        var tied = facts()
        tied.missions = (0...DailyPass.maxItems).map { index in
            DailyPass.MissionFact(kind: .held, message: "tell \(index)", sentAt: tied.window.start, at: tied.window.start, detail: "", excerpt: "")
        }
        XCTAssertGreaterThan(DailyPass.digest(tied, timeZone: utc).readUntil, tied.window.start)

        let cut = DailyPass.digest(huge, timeZone: utc)
        XCTAssertLessThanOrEqual(cut.text.count, DailyPass.maxCharacters + 200)
        XCTAssertGreaterThan(cut.readUntil, huge.window.start, "a section that went whole is read again, later")
        XCTAssertTrue(cut.text.contains("Left out: what came after"), String(cut.text.suffix(300)))
    }

    /// The first pass reads the last day; the next starts where it ended,
    /// unless it comes within two hours: the same window, longer, saved
    /// as it was, so calls in a row don't stretch it. Never more than a
    /// week. Saved 0600.
    func testTheWindowStartsWhereTheLastPassEnded() throws {
        let first = DailyPassState().reading(now: now)
        XCTAssertEqual(first.window, DailyPass.Window(start: now - 24 * hour, end: now))
        XCTAssertEqual(first.next, DailyPassState(start: now - 24 * hour, end: now))
        let fullRead = DailyPass.Note(at: now - 5 * hour, pullRequests: 0, flakyTests: 0, messages: 0)
        let last = DailyPassState(start: now - 30 * hour, end: now - 5 * hour, note: fullRead)
        XCTAssertEqual(last.reading(now: now).window, DailyPass.Window(start: now - 5 * hour, end: now))
        let again = last.reading(now: now - 4 * hour)
        XCTAssertEqual(again.window, DailyPass.Window(start: now - 30 * hour, end: now - 4 * hour))
        XCTAssertNil(again.next)
        XCTAssertEqual(last.reading(now: now - 4 * hour, extending: false).window.start, now - 5 * hour, "the daily check's news")
        let typed = DailyPassState(start: now - 30 * hour, end: now - 5 * hour, typedAt: now - 4.5 * hour, note: fullRead)
        XCTAssertEqual(typed.reading(now: now - 4 * hour).window.start, now - 5 * hour, "a typed line makes the next call a new pass")
        XCTAssertNotNil(typed.reading(now: now - 4 * hour).next)
        let checked = DailyPassState(start: now - 30 * hour, end: now - 5 * hour, checkedAt: now - 5 * hour, note: fullRead)
        XCTAssertNotNil(checked.reading(now: now - 4 * hour).next, "a window a quiet check read isn't read again")
        let partial = DailyPassState(start: now - 30 * hour, end: now - 5.5 * hour, note: fullRead)
        XCTAssertEqual(partial.reading(now: now - 4 * hour).window.start, now - 5.5 * hour, "after a read cut short, the rest")
        XCTAssertEqual(DailyPassState(start: 0, end: 1).reading(now: now).window.start, now - 7 * 24 * hour)

        // Once read: marked read, unless GitHub may answer next time; a
        // second read keeps its pass's time.
        let note = DailyPass.Note(at: now, pullRequests: 2, flakyTests: 0, messages: 0)
        let read = last.afterReading(last.reading(now: now).next, readsAgain: false, note: note, readUntil: now)
        XCTAssertEqual(read.end, now)
        XCTAssertEqual(read.readAt, now)
        XCTAssertEqual(read.note, note)
        XCTAssertEqual(last.afterReading(last.reading(now: now).next, readsAgain: true, note: note, readUntil: now).end, now - 5 * hour)
        XCTAssertEqual(last.afterReading(last.reading(now: now).next, readsAgain: false, note: note, readUntil: now - 2 * hour).end,
                       now - 2 * hour, "read up to the first fact left out")
        let reread = read.afterReading(
            nil, readsAgain: false, note: DailyPass.Note(at: now + hour, pullRequests: 3, flakyTests: 0, messages: 0), readUntil: now + hour
        )
        XCTAssertEqual(reread.note, DailyPass.Note(at: now, pullRequests: 3, flakyTests: 0, messages: 0))

        let state = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-pass-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        try last.save(spaceID: "S1", stateDirectory: state)
        XCTAssertEqual(DailyPassState.load(spaceID: "S1", stateDirectory: state), last)
        let url = try XCTUnwrap(DailyPassState.url(spaceID: "S1", stateDirectory: state))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }

    /// Due once the hour struck since the last pass read, was typed, or
    /// found nothing: the user's own pass after it counts.
    func testThePassIsDueOnceItsHourStruck() {
        // 08:00 UTC: today's 06:00 struck; 09:00 hasn't, so yesterday's.
        XCTAssertEqual(DailyPass.lastStroke(of: 6, before: now, timeZone: utc), now - 2 * hour)
        XCTAssertEqual(DailyPass.lastStroke(of: 9, before: now, timeZone: utc), now - 23 * hour)
        XCTAssertTrue(DailyPass.isDue(DailyPassState(), hour: 6, now: now, timeZone: utc))
        XCTAssertTrue(DailyPass.isDue(DailyPassState(end: now - 13 * hour, typedAt: now - 13 * hour), hour: 6, now: now, timeZone: utc))
        XCTAssertFalse(DailyPass.isDue(DailyPassState(typedAt: now - hour), hour: 6, now: now, timeZone: utc))
        XCTAssertFalse(DailyPass.isDue(DailyPassState(checkedAt: now - hour), hour: 6, now: now, timeZone: utc))
        XCTAssertFalse(DailyPass.isDue(DailyPassState(end: now - hour), hour: 6, now: now, timeZone: utc), "the user asked for one")
        XCTAssertFalse(DailyPass.isDue(DailyPassState(end: now - 3 * hour), hour: 6, now: now, timeZone: utc), "one just before the hour")
        let cutShort = DailyPassState(end: now - 30 * hour, readAt: now - 3 * hour)
        XCTAssertFalse(DailyPass.isDue(cutShort, hour: 6, now: now, timeZone: utc), "when it read, not up to where")
        // The night Paris skips 02:00: yesterday's stroke is yesterday's 02:00.
        let paris = TimeZone(identifier: "Europe/Paris")!
        let iso = ISO8601DateFormatter()
        let skipped = iso.date(from: "2027-03-28T00:30:00Z")!.timeIntervalSince1970
        XCTAssertEqual(DailyPass.lastStroke(of: 2, before: skipped, timeZone: paris), iso.date(from: "2027-03-27T01:00:00Z")!.timeIntervalSince1970)
    }

    /// Never while the Lead works, a message waits for it, or the user is
    /// around.
    func testQuietMeansNobodyIsBusy() {
        let idle = now - DailyPass.leadIdle
        let away = now - DailyPass.userAway
        XCTAssertTrue(DailyPass.isQuiet(promptFree: true, lastHookAt: idle, messageWaiting: false, awaySince: away, now: now))
        XCTAssertFalse(DailyPass.isQuiet(promptFree: false, lastHookAt: idle, messageWaiting: false, awaySince: away, now: now))
        XCTAssertFalse(DailyPass.isQuiet(promptFree: true, lastHookAt: idle + 1, messageWaiting: false, awaySince: away, now: now))
        XCTAssertFalse(DailyPass.isQuiet(promptFree: true, lastHookAt: idle, messageWaiting: true, awaySince: away, now: now))
        XCTAssertFalse(DailyPass.isQuiet(promptFree: true, lastHookAt: idle, messageWaiting: false, awaySince: away + 1, now: now))
        XCTAssertFalse(DailyPass.isQuiet(promptFree: true, lastHookAt: idle, messageWaiting: false, awaySince: nil, now: now))
    }

    /// The Lead row's counts: pull requests merged, flaky tests (learned or
    /// called so), messages held or given up, and the rules proposed since.
    func testTheNoteCountsTheDay() {
        var day = facts()
        day.flakyTests = ["A.testB"]
        day.triagedRuns = [
            DailyPass.TriagedRun(id: "1", pullRequest: nil, verdict: "flaky", reason: nil, tests: ["A.testB", "A.testC"], triagedAt: now),
            DailyPass.TriagedRun(id: "2", pullRequest: nil, verdict: "real", reason: nil, tests: ["A.testD"], triagedAt: now)
        ]
        day.missions = [.held, .crossed, .handedToUser].map {
            DailyPass.MissionFact(kind: $0, message: "tell to x", sentAt: now, at: now, detail: "", excerpt: "")
        }
        let note = day.note(at: now)
        XCTAssertEqual(note, DailyPass.Note(at: now, pullRequests: 1, flakyTests: 2, messages: 1))
        XCTAssertEqual(DailyPass.noteCounts(note, rulesProposed: 1), "1 PR, 2 flaky tests, 1 message held or lost, 1 rule proposed")
        XCTAssertEqual(DailyPass.noteCounts(DailyPass.Note(at: now, pullRequests: 3, flakyTests: 0, messages: 0), rulesProposed: 0),
                       "3 PRs, no rule proposed")
        // The rules of that pass's turn, not of the day after.
        let proposals = [now - 60, now + 600, now + 2 * hour].map { time in
            RuleProposal(id: UUID().uuidString, rule: "r", evidence: "e", proposedAt: time, leadWorkspaceID: nil, leadAgentUUID: nil)
        }
        XCTAssertEqual(DailyPass.rulesProposed(proposals, in: note), 1)
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

    // MARK: Forgotten tasks

    private let day: TimeInterval = 86_400

    private func pullRequest(
        _ state: GitHub.PullRequestState = .open, checks: String? = "SUCCESS", mergeable: String? = "MERGEABLE", draft: Bool = false,
        base: String? = "main", checkStartedAt: TimeInterval? = nil
    ) -> PRInfo {
        let check = checkStartedAt.map {
            GitHub.Check(name: "test", workflowName: "Tests", result: .success, startedAt: DailyPass.isoTime($0), url: nil)
        }
        return PRInfo(
            number: 640, state: state, isDraft: draft, ciStatus: checks, checks: check.map { [$0] } ?? [], reviewDecision: nil,
            mergeable: mergeable, url: "https://github.com/acme/app/pull/640", additions: nil, deletions: nil, changedFiles: nil,
            baseRefName: base
        )
    }

    /// The Lead's task, its pull request read an hour ago.
    private func task(_ title: String, lastTurn: TimeInterval?, pullRequest: PRInfo? = nil) -> DailyPass.TaskActivity {
        DailyPass.TaskActivity(
            id: title, title: title, branch: "feat/\(title.lowercased())", pullRequest: pullRequest, pullRequestReadAt: now - hour,
            repositoryBase: "main", lastTurnAt: lastTurn
        )
    }

    private func forgotten(_ tasks: [DailyPass.TaskActivity]) -> [String] {
        DailyPass.forgottenTasks(tasks, now: now, timeZone: utc).map(\.line)
    }

    /// A merged pull request at once (the window's merged list too, newer
    /// than the sidebar's), a closed one for the user to confirm; a result
    /// with nothing after it a day on, once its turn is over and a pull
    /// request was read as missing. Closable first, oldest first.
    func testAMergedPullRequestOrAnUnattendedResultIsClosable() {
        var merged = task("Glass", lastTurn: now - 2 * hour, pullRequest: pullRequest(.merged))
        merged.notYours = "not yours (started by the user)"
        var mergedOvernight = task("Overnight", lastTurn: now - 3 * hour, pullRequest: pullRequest())
        mergedOvernight.mergedLately = true
        let closed = task("Dropped", lastTurn: nil, pullRequest: pullRequest(.closed))
        var finished = task("Report", lastTurn: now - day - 10 * 60)
        finished.resultAt = now - day - 20 * 60
        var fresh = task("Fresh", lastTurn: now - day + 5 * 60)
        fresh.resultAt = now - day
        // Without hooks: its result counts from when it came.
        var hookless = task("Hookless", lastTurn: nil)
        (hookless.lastCommitAt, hookless.resultAt) = (now - 2 * day, now - hour)
        var reworked = task("Reworked", lastTurn: now - 4 * day)
        reworked.resultAt = now - 4 * day - DailyPass.resultTurn - 60
        var unread = task("Unread", lastTurn: now - 3 * day)
        (unread.resultAt, unread.pullRequestReadAt) = (now - 3 * day, nil)
        XCTAssertEqual(forgotten([merged, mergedOvernight, fresh, hookless, reworked, unread, finished, closed]), [
            "- “Dropped” · branch feat/dropped · PR #640 closed unmerged · no activity recorded → ask the user whether it was dropped, "
                + "then close_task",
            "- “Report” · branch feat/report · result sent 01-14 07:40, nothing since, no pull request · "
                + "last activity 01-14 07:50 (a turn), 1 d ago → close_task",
            "- “Overnight” · branch feat/overnight · PR #640 merged · last activity 01-15 05:00 (a turn), 3 h ago → close_task",
            "- “Glass” · branch feat/glass · not yours (started by the user) · PR #640 merged · last activity 01-15 06:00 (a turn), 2 h ago "
                + "→ close_task",
            "- “Reworked” · branch feat/reworked · no pull request · quiet: last activity 01-11 08:00 (a turn), 4 d ago "
                + "→ tell it what comes next, or close_task if it was dropped",
            "- “Unread” · branch feat/unread · its pull request not read yet · quiet: last activity 01-12 08:00 (a turn), 3 d ago "
                + "→ tell it what comes next, or close_task if it was dropped"
        ])
        var folder = finished
        folder.isFolderTask = true
        folder.pullRequestReadAt = nil
        XCTAssertTrue(forgotten([folder])[0].hasSuffix("→ close_task once the user has its result (its folder goes to the Trash)"))
        var subtask = finished
        (subtask.notYours, subtask.parentTitle) = ("not yours (another agent started it)", "Parent")
        XCTAssertTrue(forgotten([subtask])[0].hasSuffix("→ tell “Parent”, the task that started it"))
    }

    /// Open, green (or no check at all), mergeable, no draft, no change
    /// asked, not merging by itself, on its repository's base branch (or a
    /// base nobody named), a day without activity: waiting. Anything short
    /// of that is an open task, quiet after three days.
    func testAGreenMergeablePullRequestNobodyMergesIsWaiting() {
        var unnamed = task("Unnamed", lastTurn: now - day - 2 * hour, pullRequest: pullRequest(base: "feat/parent"))
        unnamed.repositoryBase = nil
        let pull = { (review: String?, autoMerges: Bool) in
            PRInfo(
                number: 640, state: .open, isDraft: false, ciStatus: "SUCCESS", checks: [], reviewDecision: review, mergeable: "MERGEABLE",
                url: "https://github.com/acme/app/pull/640", additions: nil, deletions: nil, changedFiles: nil, autoMerges: autoMerges
            )
        }
        let tasks = [
            task("Green", lastTurn: now - day - hour, pullRequest: pullRequest()), unnamed,
            task("Unchecked", lastTurn: now - day - 3 * hour, pullRequest: pullRequest(checks: nil)),
            task("Early", lastTurn: now - day + hour, pullRequest: pullRequest()),
            task("Red", lastTurn: now - 2 * day, pullRequest: pullRequest(checks: "FAILURE")),
            task("Failing", lastTurn: now - 3 * day, pullRequest: pullRequest(checks: "FAILURE")),
            task("Draft", lastTurn: now - 3 * day - 60, pullRequest: pullRequest(draft: true)),
            task("Conflict", lastTurn: now - 3 * day - 120, pullRequest: pullRequest(mergeable: "CONFLICTING")),
            task("Stacked", lastTurn: now - 3 * day - 180, pullRequest: pullRequest(base: "feat/parent")),
            task("Changes", lastTurn: now - 3 * day - 240, pullRequest: pull("CHANGES_REQUESTED", false)),
            task("Auto", lastTurn: now - 3 * day - 300, pullRequest: pull(nil, true))
        ]
        let move = "→ tell it what comes next, or close_task if it was dropped"
        let waiting = "green and mergeable, unmerged"
        XCTAssertEqual(forgotten(tasks), [
            "- “Unchecked” · branch feat/unchecked · PR #640 \(waiting) · last activity 01-14 05:00 (a turn), 1 d 3 h ago "
                + "→ ask the user to merge it",
            "- “Unnamed” · branch feat/unnamed · PR #640 \(waiting) · last activity 01-14 06:00 (a turn), 1 d 2 h ago → ask the user to merge it",
            "- “Green” · branch feat/green · PR #640 \(waiting) · last activity 01-14 07:00 (a turn), 1 d 1 h ago → ask the user to merge it",
            "- “Auto” · branch feat/auto · PR #640 open, checks green, set to merge by itself · quiet: last activity 01-12 07:55 (a turn), "
                + "3 d ago \(move)",
            "- “Changes” · branch feat/changes · PR #640 open, checks green, changes requested · quiet: last activity 01-12 07:56 (a turn), "
                + "3 d ago \(move)",
            "- “Stacked” · branch feat/stacked · PR #640 open, checks green, on feat/parent · quiet: last activity 01-12 07:57 (a turn), "
                + "3 d ago \(move)",
            "- “Conflict” · branch feat/conflict · PR #640 open, checks green, conflicting · quiet: last activity 01-12 07:58 (a turn), "
                + "3 d ago \(move)",
            "- “Draft” · branch feat/draft · PR #640 draft, checks green · quiet: last activity 01-12 07:59 (a turn), 3 d ago \(move)",
            "- “Failing” · branch feat/failing · PR #640 open, checks failing · quiet: last activity 01-12 08:00 (a turn), 3 d ago \(move)"
        ])
    }

    /// The latest of its last turn, commit and check run (its checks'
    /// newest start) dates a task: each alone keeps it off the list, and
    /// the line names it. Nothing to date it by: never listed.
    func testEachSourceOfActivityCounts() {
        var committed = task("Committed", lastTurn: now - 5 * day)
        committed.lastCommitAt = now - 2 * day
        let checked = task("Checked", lastTurn: now - 5 * day, pullRequest: pullRequest(checks: "FAILURE", checkStartedAt: now - 2 * day))
        XCTAssertEqual(forgotten([committed, checked, task("Unknown", lastTurn: nil)]), [])
        committed.lastCommitAt = now - 4 * day
        let checkedEarlier = task("Checked", lastTurn: now - 5 * day, pullRequest: pullRequest(checks: "FAILURE", checkStartedAt: now - 3 * day))
        let lines = forgotten([committed, checkedEarlier])
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("quiet: last activity 01-11 08:00 (a commit), 4 d ago"), lines[0])
        XCTAssertTrue(lines[1].contains("quiet: last activity 01-12 08:00 (a check run), 3 d ago"), lines[1])
    }

    /// A quiet task's move follows what it waits on: the user's answer to
    /// a question handed to them, the Lead's reply, the user in its
    /// terminal; else whose it is: the Lead's is told, a sub-task goes to
    /// the task that started it, the user's to the user.
    func testTheMoveFollowsWhatItWaitsOnAndWhoseItIs() {
        let quiet = now - 3 * day
        var handed = task("Handed", lastTurn: quiet - 50)
        handed.question = .init(id: "q2", handedToUser: true)
        var asking = task("Asking", lastTurn: quiet - 40)
        asking.question = .init(id: "q1")
        var stuck = task("Stuck", lastTurn: quiet - 30)
        stuck.waitsOnUser = "a permission for Bash"
        var subtask = task("Sub", lastTurn: quiet - 20)
        (subtask.notYours, subtask.parentTitle) = ("not yours (another agent started it)", "Parent")
        var theirs = task("Theirs", lastTurn: quiet - 10)
        theirs.notYours = "not yours (started by the user)"
        let lines = forgotten([theirs, subtask, stuck, asking, handed, task("Mine", lastTurn: quiet)])
        let moves = lines.map { String($0[$0.range(of: " → ")!.upperBound...]) }
        XCTAssertEqual(moves, [
            "ask the user: it waits on their answer to question q2", "reply to its question q1",
            "ask the user: it waits on them (a permission for Bash)", "tell “Parent”, the task that started it", "ask the user",
            "tell it what comes next, or close_task if it was dropped"
        ])
        XCTAssertTrue(lines[3].hasPrefix("- “Sub” · sub-task of “Parent” · branch feat/sub · not yours (another agent started it) · "), lines[3])
    }

    /// A result is a task's last word when no question followed, nor a
    /// tell typed after it (one held, sent before) or on its way (a Lead's
    /// one-way tell too); an answer typed late or a tell given up untyped
    /// leave it.
    func testTheResultIsTheTasksLastWord() {
        let result = event(.completed, "Done", at: now - 5 * hour)
        let question = event(.question, "Base?", at: now - 9 * hour, id: "q1")
        var lost = event(.instruction, "Also Y", at: now - 4 * hour)
        lost.expiredAt = now - 2 * hour
        let lateAnswer = event(.response, "main", at: now - 3 * hour, inReplyTo: "q1")
        XCTAssertEqual(DailyPass.resultAt([mission([question, result, lost, lateAnswer])]), now - 5 * hour)
        XCTAssertNil(DailyPass.resultAt([mission([result, event(.question, "And the tests?", at: now - 4 * hour)])]))
        var held = event(.instruction, "Also Y", at: now - 6 * hour)
        held.childConsumedAt = now - 4 * hour
        XCTAssertNil(DailyPass.resultAt([mission([held, result])]), "typed after the result")
        var oneWay = mission([event(.instruction, "Also Z", at: now - 6 * hour)])
        oneWay.oneWay = true
        XCTAssertNil(DailyPass.resultAt([mission([result]), oneWay]), "a tell on its way")
        XCTAssertNil(DailyPass.resultAt([mission([question])]))
    }

    /// A forgotten task is news until a read lists it, and again once its
    /// kind or last activity changes. Every digest lists them all, the
    /// nothing day's too, those listed last time after the others, after
    /// the rules and with no fact of the window.
    func testAForgottenTaskIsNewsUntilListed() throws {
        var quiet = facts()
        quiet.findings = quiet.findings.filter { !window.contains($0.time) }
        quiet.repositories = []
        quiet.tasks = [task("Old", lastTurn: now - 5 * day), task("Merged", lastTurn: now - hour, pullRequest: pullRequest(.merged))]
        XCTAssertTrue(quiet.hasNews)
        let first = DailyPass.digest(quiet, timeZone: utc)
        XCTAssertEqual(first.listed.count, 2)
        quiet.reported = Set(first.listed)
        XCTAssertFalse(quiet.hasNews, "listed last time")
        let said = DailyPass.digest(quiet, timeZone: utc).text
        XCTAssertTrue(said.contains("Nothing happened since 01-14 08:00: no review recorded, no pull request merged, no CI failure, "
            + "no Mission message held, no rule decided. Nothing to propose.\n"), said)
        XCTAssertTrue(said.contains("""
            ## Tasks you may have forgotten
            Nirux only lists them: nothing was closed or told. Make each move, or tell the user why not.
            Listed last time too, nothing changed since:
            - “Merged” ·
            """), said)
        quiet.tasks[0].lastCommitAt = now - 4 * day
        XCTAssertTrue(quiet.hasNews, "its last activity moved")
        let again = DailyPass.digest(quiet, timeZone: utc).text
        XCTAssertTrue(again.contains("why not.\n- “Old” ·"), again)

        var busy = facts()
        busy.tasks = (0...DailyPass.maxItems).map { task("T\($0)", lastTurn: now - 4 * day + Double($0) * 60) }
        let read = DailyPass.digest(busy, timeZone: utc)
        XCTAssertEqual(read.readUntil, now, "no fact of the window")
        XCTAssertEqual(read.listed.count, DailyPass.maxItems)
        busy.reported = Set(DailyPass.forgottenTasks(busy.tasks, now: now).map(\.key))
        XCTAssertEqual(DailyPass.digest(busy, timeZone: utc).listed.count, DailyPass.maxItems + 1, "left out for room, still known")
        let start = try XCTUnwrap(read.text.range(of: "## Tasks you may have forgotten"))
        let section = String(read.text[start.lowerBound...]).components(separatedBy: "\n\n")[0]
        XCTAssertTrue(section.contains("- “T0” ·") && !section.contains("“T\(DailyPass.maxItems)”"), section)
        XCTAssertTrue(section.hasSuffix("- … and 1 more"), section)
        let rules = try XCTUnwrap(read.text.range(of: "## The brief's rules learned"))
        XCTAssertLessThan(rules.lowerBound, start.lowerBound)
    }

    /// What is read off the main thread reaches its task: its last commit,
    /// by order, its repository's base branch, and whether GitHub's merged
    /// list of its repository has its pull request.
    func testWhatIsReadOffTheMainThreadReachesItsTask() {
        var report = DailyPass.RepositoryReport(name: "Acme/App")
        report.mergedLately = [640]
        var other = DailyPass.RepositoryReport(name: "acme/other")
        other.mergedLately = [640]
        let reads = DailyPass.Reads(
            repositories: [other, report], findings: [], commits: [now - day, nil],
            bases: ["/w/app": DailyPass.Base(remote: "origin", branch: "trunk")]
        )
        let elsewhere = PRInfo(
            number: 640, state: .open, isDraft: false, ciStatus: nil, checks: [], reviewDecision: nil, mergeable: nil,
            url: "https://github.com/acme/third/pull/640", additions: nil, deletions: nil, changedFiles: nil
        )
        let read = DailyPass.tasks([
            (DailyPass.TaskActivity(id: "A", title: "A", pullRequest: pullRequest()), "/w/app"),
            (DailyPass.TaskActivity(id: "B", title: "B", pullRequest: elsewhere), nil)
        ], with: reads)
        XCTAssertEqual(read.map(\.id), ["A", "B"])
        XCTAssertEqual(read.map(\.lastCommitAt), [now - day, nil])
        XCTAssertEqual(read.map(\.repositoryBase), ["trunk", nil])
        XCTAssertEqual(read.map(\.mergedLately), [true, false])
    }

    /// GitHub's merged list reaches back to the oldest read of a task's open
    /// pull request when that came before the window (a week at most), by
    /// numbers alone; the merged section keeps the window's.
    func testTheMergedListReachesTheOldestReadOfAnOpenPullRequest() {
        var open = task("Open", lastTurn: nil, pullRequest: pullRequest())
        open.pullRequestReadAt = now - 3 * day
        var merged = task("Merged", lastTurn: nil, pullRequest: pullRequest(.merged))
        merged.pullRequestReadAt = now - 6 * day
        XCTAssertEqual(DailyPass.mergedSince([open, merged], window: window), now - 3 * day)
        open.pullRequestReadAt = now - 30 * day
        XCTAssertEqual(DailyPass.mergedSince([open], window: window), now - 7 * day)
        open.pullRequestReadAt = now - hour
        XCTAssertNil(DailyPass.mergedSince([open], window: window), "the window covers it")

        let pulls = Data("""
            [{"number": 2, "title": "In", "headRefName": "b", "mergedAt": "2027-01-15T07:00:00Z"}]
            """.utf8)
        final class Calls: @unchecked Sendable { var numbers: [[String]] = [] }
        let calls = Calls()
        let read: GitHub.CLI.Runner = { call in
            let arguments = call.arguments
            let data: Data
            if arguments.contains("number") {
                calls.numbers.append(arguments)
                data = Data(#"[{"number": 7}, {"number": 2}]"#.utf8)
            } else {
                data = arguments.first == "pr" ? pulls : Data("[]".utf8)
            }
            return .success(.init(status: 0, standardOutput: data, standardError: Data()))
        }
        let reached = DailyPass.readGitHub(["acme/app"], window: window, mergedSince: now - 3 * day, gh: read)
        XCTAssertEqual(reached.first?.merged.map(\.number), [2])
        XCTAssertEqual(reached.first?.mergedLately, [2, 7])
        XCTAssertEqual(calls.numbers.first?.contains("merged:>=\(DailyPass.isoTime(now - 3 * day)) sort:updated-desc"), true)
        XCTAssertEqual(DailyPass.readGitHub(["acme/app"], window: window, gh: read).first?.mergedLately, [2])
        XCTAssertEqual(calls.numbers.count, 1, "no reach without a stale read")
        XCTAssertEqual(calls.numbers.first?.contains("github.com/acme/app"), true)
        let partial = DailyPass.readGitHub(["acme/app"], window: window, mergedSince: now - 3 * day) { call in
            call.arguments.contains("number") ? .failure(.noAnswer("timeout")) : read(call)
        }
        XCTAssertEqual(partial.first?.mergedLately, [2])
        XCTAssertEqual(partial.first?.problems, ["pull requests merged before the window: timeout"])
        XCTAssertEqual(partial.first?.readsAgain, false, "the window itself was read")
    }

    /// A folder's newest commit off its base branch by its committer date
    /// (of HEAD without one; none outside git, or with no commit of its
    /// own), and its base branch as `<remote>/HEAD` names it (none for a
    /// folder without a GitHub remote).
    @MainActor
    func testCommitTimesAndBaseBranchesComeFromGit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        @MainActor func commit(at time: TimeInterval) throws {
            try UIFlowHarness.git(
                ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "--allow-empty", "-m", "c", "--date=@1700000000"],
                at: folder, environment: ["GIT_COMMITTER_DATE": "@\(Int(time))"]
            )
        }
        try UIFlowHarness.git(["init", "-q", "-b", "trunk"], at: folder)
        try commit(at: now - 2 * day)
        try UIFlowHarness.git(["update-ref", "refs/remotes/origin/trunk", "HEAD"], at: folder)
        try UIFlowHarness.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk"], at: folder)
        let bases = DailyPass.baseBranches([(folder, .gitHub(repository: "acme/app", remote: "origin")), (folder + "/missing", .noRemote)])
        XCTAssertEqual(bases, [folder: DailyPass.Base(remote: "origin", branch: "trunk")])
        let base = bases[folder]?.ref
        XCTAssertEqual(DailyPass.commitTimes([(folder, base), (folder, nil), (folder + "/missing", nil)]), [nil, now - 2 * day, nil])
        try commit(at: now - day)
        XCTAssertEqual(DailyPass.commitTimes([(folder, base)]), [now - day])
    }
}
