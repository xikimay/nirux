import XCTest
@testable import Nirux

/// The board's `gh` calls and what it reads from them. The open list and
/// the runs are real `gh` 2.100.0 output (2026-09-27), anonymized: owner,
/// repository, ids and URLs changed; PR 13's rerun and PR 14's fork added
/// by hand. The merged answer is written by hand in the shape the query's
/// answer has (checked against GitHub on 2026-11-12).
final class ProjectBoardGitHubTests: XCTestCase {
    private let widgets = GitHubRepository(owner: "acme", name: "widgets")

    static let openPullRequests = """
    [
      {
        "baseRefName": "main",
        "headRefName": "feat/login",
        "headRefOid": "9B57F5AB537BF3B5C0B22EA831B8D8C647EE2984",
        "headRepository": {"id": "R_kgDOAAAAAA", "name": "widgets", "nameWithOwner": "acme/widgets"},
        "headRepositoryOwner": {"id": "MDQ6VXNlcjAwMDAwMDA=", "name": "Acme", "login": "acme"},
        "isDraft": false,
        "mergeable": "MERGEABLE",
        "number": 12,
        "state": "OPEN",
        "title": "Sign in with a password",
        "statusCheckRollup": [
          {"__typename": "CheckRun", "completedAt": "2026-09-27T23:05:43Z", "conclusion": "SUCCESS",
           "detailsUrl": "https://github.com/acme/widgets/actions/runs/1/job/11", "name": "Analyze (actions)",
           "startedAt": "2026-09-27T23:04:58Z", "status": "COMPLETED", "workflowName": "CodeQL"},
          {"__typename": "CheckRun", "completedAt": "0001-01-01T00:00:00Z", "conclusion": "",
           "detailsUrl": "https://github.com/acme/widgets/actions/runs/2/job/21", "name": "test",
           "startedAt": "2026-09-27T23:05:04Z", "status": "IN_PROGRESS", "workflowName": "Tests"},
          {"__typename": "CheckRun", "completedAt": "0001-01-01T00:00:00Z", "conclusion": "",
           "detailsUrl": "https://github.com/acme/widgets/actions/runs/1/job/12", "name": "Analyze (swift)",
           "startedAt": "2026-09-27T23:05:04Z", "status": "IN_PROGRESS", "workflowName": "CodeQL"},
          {"__typename": "CheckRun", "completedAt": "2026-09-27T23:05:38Z", "conclusion": "NEUTRAL",
           "detailsUrl": "https://github.com/acme/widgets/runs/13", "name": "CodeQL",
           "startedAt": "2026-09-27T23:05:34Z", "status": "COMPLETED", "workflowName": ""},
          {"__typename": "StatusContext", "context": "ci/lint", "startedAt": "2026-09-27T23:05:00Z",
           "state": "SUCCESS", "targetUrl": "https://ci.example.com/lint/1"}
        ],
        "url": "https://github.com/acme/widgets/pull/12"
      },
      {
        "baseRefName": "release",
        "headRefName": "fix/crash",
        "headRefOid": "a1b58d96ada210a3592b1d1c13e07130b7c425f0",
        "headRepository": {"id": "R_kgDOAAAAAA", "name": "widgets", "nameWithOwner": "acme/widgets"},
        "headRepositoryOwner": {"id": "MDQ6VXNlcjAwMDAwMDA=", "name": "Acme", "login": "acme"},
        "isDraft": true,
        "mergeable": "CONFLICTING",
        "number": 13,
        "state": "OPEN",
        "statusCheckRollup": [
          {"__typename": "CheckRun", "completedAt": "2026-09-27T22:46:39Z", "conclusion": "SUCCESS",
           "detailsUrl": "https://github.com/acme/widgets/actions/runs/3/job/31", "name": "test",
           "startedAt": "2026-09-27T22:44:23Z", "status": "COMPLETED", "workflowName": "Tests"},
          {"__typename": "CheckRun", "completedAt": "2026-09-27T22:58:10Z", "conclusion": "FAILURE",
           "detailsUrl": "https://github.com/acme/widgets/actions/runs/3/job/32", "name": "test",
           "startedAt": "2026-09-27T22:55:02Z", "status": "COMPLETED", "workflowName": "Tests"},
          {"__typename": "CheckRun", "completedAt": "2026-09-27T22:45:06Z", "conclusion": "CANCELLED",
           "detailsUrl": "https://github.com/acme/widgets/actions/runs/4/job/41", "name": "Analyze (actions)",
           "startedAt": "2026-09-27T22:44:20Z", "status": "COMPLETED", "workflowName": "CodeQL"}
        ],
        "url": "https://github.com/acme/widgets/pull/13"
      },
      {
        "baseRefName": "main",
        "headRefName": "patch-1",
        "headRefOid": "0123456789abcdef0123456789abcdef01234567",
        "headRepository": {"id": "R_kgDOBBBBBB", "name": "widgets", "nameWithOwner": "someone/widgets"},
        "headRepositoryOwner": {"id": "MDQ6VXNlcjExMTExMTE=", "login": "someone"},
        "isDraft": false,
        "mergeable": "UNKNOWN",
        "number": 14,
        "state": "OPEN",
        "statusCheckRollup": [],
        "url": "https://github.com/acme/widgets/pull/14"
      },
      {"number": 15, "state": "OPEN", "headRefName": "no-oid", "url": "https://github.com/acme/widgets/pull/15"}
    ]
    """

    static let postMergeRuns = """
    [{"conclusion":"success","createdAt":"2026-09-27T23:08:47Z","headSha":"43a9503a372d2413047f5c5539b2ccbef539b17f",\
    "status":"completed","updatedAt":"2026-09-27T23:14:16Z","url":"https://github.com/acme/widgets/actions/runs/5"}]
    """

    // MARK: - Pull requests

    func testOpenPullRequestsAreReadWithTheirChecksAndHeadRepository() throws {
        let pullRequests = try XCTUnwrap(ProjectBoard.parsePullRequests(Data(Self.openPullRequests.utf8), repository: widgets))
        XCTAssertEqual(pullRequests.map(\.number), [12, 13, 14], "an entry missing its head commit is left out")

        let login = pullRequests[0]
        XCTAssertEqual(login.headRefName, "feat/login")
        XCTAssertEqual(pullRequests.map(\.title), ["Sign in with a password", "", ""])
        XCTAssertEqual(login.headOid, "9b57f5ab537bf3b5c0b22ea831b8d8c647ee2984")
        XCTAssertTrue(login.isOpen)
        XCTAssertFalse(login.isDraft)
        XCTAssertTrue(login.isFromConfiguredRepository)
        XCTAssertEqual(login.checks.map(\.name), ["Analyze (actions)", "test", "Analyze (swift)", "CodeQL", "ci/lint"])
        XCTAssertEqual(login.checks.map(\.result), [.success, .pending, .pending, .neutral, .success])
        XCTAssertEqual(login.checks[1].qualifiedName, "Tests / test")
        XCTAssertNil(login.checks[3].qualifiedName, "CodeQL's summary check has no workflow")
        XCTAssertNil(login.checks[4].workflowName)

        XCTAssertTrue(pullRequests[1].isDraft)
        XCTAssertTrue(pullRequests[1].isConflicting)
        XCTAssertFalse(pullRequests[2].isFromConfiguredRepository, "a fork's")
    }

    func testTheMergedPullRequestsAreReadFromTheQuerysTwoLists() throws {
        // The query's answer: #52 is in both lists; #49 is an earlier merge of the same branch at the
        // same commit; #51 came from a fork deleted since; #50 says less than was asked; and one
        // node is no pull request.
        let login = """
        "baseRefName": "main", "headRefName": "feat/login", "headRefOid": "9b57f5ab537bf3b5c0b22ea831b8d8c647ee2984",
        "headRepository": {"name": "widgets"}, "headRepositoryOwner": {"login": "acme"}, "state": "MERGED"
        """
        let answer = """
        {"data": {"repository": {
          "opened": {"nodes": [
            {\(login), "mergedAt": "2026-11-11T13:02:11Z", "number": 52, "title": "Sign in with a passkey",
             "url": "https://github.com/acme/widgets/pull/52"},
            null,
            {"baseRefName": "main", "headRefName": "patch-1", "headRefOid": "0123456789abcdef0123456789abcdef01234567",
             "headRepository": null, "headRepositoryOwner": {"login": "someone"},
             "mergedAt": "2026-11-10T08:00:00Z", "number": 51, "state": "MERGED", "title": "A typo",
             "url": "https://github.com/acme/widgets/pull/51"},
            {"number": 50, "state": "MERGED", "headRefName": "fix/crash", "headRefOid": "a1b58d96ada210a3592b1d1c13e07130b7c425f0",
             "url": "https://github.com/acme/widgets/pull/50", "mergedAt": null}
          ]},
          "updated": {"nodes": [
            {\(login), "mergedAt": "2026-11-09T09:00:00Z", "number": 49, "title": "Sign in, first part",
             "url": "https://github.com/acme/widgets/pull/49"},
            {\(login), "mergedAt": "2026-11-11T13:02:11Z", "number": 52, "title": "Sign in with a passkey, renamed since",
             "url": "https://github.com/acme/widgets/pull/52"}
          ]}
        }}}
        """
        let list = try XCTUnwrap(GitHubCLIBoardClient.mergedList(Data(answer.utf8)))
        let pullRequests = try XCTUnwrap(ProjectBoard.parsePullRequests(list, repository: widgets))
        XCTAssertEqual(pullRequests.map(\.number), [52, 51, 50, 49],
                       "those opened last, then those updated last; each once, by its number; a node that isn't one is left out")
        XCTAssertEqual(pullRequests.map(\.isFromConfiguredRepository), [true, false, false, true], "by its head repository's owner and name")
        XCTAssertEqual(pullRequests.map(\.title), ["Sign in with a passkey", "A typo", "", "Sign in, first part"],
                       "the first list's copy is kept; one read without its title has none")
        XCTAssertEqual(pullRequests.map { $0.mergedAt?.timeIntervalSince1970 }, [1_794_402_131, 1_794_297_600, nil, 1_794_214_800],
                       "no date, as gh writes one that hasn't merged")

        // A repository without a merged pull request is an empty list; an answer without one of the
        // lists is no list at all, so the one read before isn't replaced by nothing.
        let none = #"{"data": {"repository": {"opened": {"nodes": []}, "updated": {"nodes": []}}}}"#
        XCTAssertEqual(GitHubCLIBoardClient.mergedList(Data(none.utf8)).map { String(decoding: $0, as: UTF8.self) }, "[]")
        for incomplete in [
            #"{"data": {"repository": null}}"#,
            #"{"data": {"repository": {"opened": {"nodes": []}}}}"#,
            #"{"data": {"repository": {"updated": {"nodes": []}}}}"#,
            #"{"data": {"repository": {"opened": {"nodes": []}, "updated": {"nodes": null}}}}"#,
            "[]"
        ] {
            XCTAssertNil(GitHubCLIBoardClient.mergedList(Data(incomplete.utf8)), incomplete)
        }
    }

    func testNotAListReadsAsNothing() {
        XCTAssertNil(ProjectBoard.parsePullRequests(Data("{\"message\": \"Bad credentials\"}".utf8), repository: widgets))
        XCTAssertNil(ProjectBoard.parseRuns(Data("not json".utf8)))
        XCTAssertEqual(ProjectBoard.parsePullRequests(Data("[]".utf8), repository: widgets), [])
    }

    // MARK: - Checks

    func testRequiredChecksShowByNameAndTheOthersFold() throws {
        let pullRequests = try XCTUnwrap(ProjectBoard.parsePullRequests(Data(Self.openPullRequests.utf8), repository: widgets))
        let login = ProjectBoard.checkSummary(pullRequests[0].checks, required: ["test", "build"])
        XCTAssertEqual(login.required, [.init(name: "test", result: .pending), .init(name: "build", result: nil)])
        XCTAssertEqual(login.others, [.success, .pending, .neutral, .success])
        XCTAssertEqual(login.text, "test ● · build missing · others: 1 ●")
        XCTAssertTrue(login.hasPending)

        // The rerun replaced the success; the cancelled run counts as red.
        let crash = ProjectBoard.checkSummary(pullRequests[1].checks, required: ["Tests / test"])
        XCTAssertEqual(crash.required, [.init(name: "Tests / test", result: .failure)])
        XCTAssertEqual(crash.text, "Tests / test ✗ · others: 1 ✗")
        XCTAssertEqual(crash.worst, .failure)
        XCTAssertFalse(crash.hasPending)

        let green = ProjectBoard.checkSummary(
            [ProjectBoard.Check(name: "test", workflowName: "Tests", result: .success, startedAt: nil, url: nil),
             ProjectBoard.Check(name: "lint", workflowName: "Tests", result: .skipped, startedAt: nil, url: nil)],
            required: ["test"]
        )
        XCTAssertEqual(green.text, "test ✓ · others ✓")
        XCTAssertEqual(green.worst, .success, "a skipped job doesn't grey out a green board")

        // A rerun waiting for a runner has gh's zero time: it is the latest.
        let rerun = ProjectBoard.checkSummary([
            ProjectBoard.Check(name: "test", workflowName: "Tests", result: .failure, startedAt: "2026-09-27T22:55:02Z", url: nil),
            ProjectBoard.Check(name: "test", workflowName: "Tests", result: .pending, startedAt: "0001-01-01T00:00:00Z", url: nil)
        ], required: ["test"])
        XCTAssertEqual(rerun.required, [.init(name: "test", result: .pending)])
        let twoJobs = ProjectBoard.checkSummary([
            ProjectBoard.Check(name: "test", workflowName: "Tests", result: .success, startedAt: nil, url: nil),
            ProjectBoard.Check(name: "test", workflowName: "Lint", result: .skipped, startedAt: nil, url: nil)
        ], required: ["test"])
        XCTAssertEqual(twoJobs.text, "test ✓")
    }

    func testThePullRequestColumnSaysStateDraftConflictAndAnotherBase() throws {
        let pullRequests = try XCTUnwrap(ProjectBoard.parsePullRequests(Data(Self.openPullRequests.utf8), repository: widgets))
        XCTAssertEqual(ProjectBoard.pullRequestText(pullRequests[0], baseBranch: "main"), "#12 open")
        XCTAssertEqual(ProjectBoard.pullRequestText(pullRequests[1], baseBranch: "main"), "#13 draft · conflict → release")
        let merged = ProjectBoard.PullRequest(
            number: 9, state: "MERGED", headRefName: "x", headOid: "", baseRefName: "dev", isDraft: false,
            mergeable: nil, checks: [], url: "", isFromConfiguredRepository: true
        )
        XCTAssertEqual(ProjectBoard.pullRequestText(merged, baseBranch: "main"), "#9 merged")
    }

    // MARK: - Post-merge run

    func testTheLastPostMergeRunReadsAsInTheHeader() throws {
        let runs = try XCTUnwrap(ProjectBoard.parseRuns(Data(Self.postMergeRuns.utf8)))
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].status, "completed")
        XCTAssertEqual(runs[0].conclusion, "success")
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let sameDay = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-27T23:30:00Z"))
        XCTAssertEqual(
            ProjectBoard.runSummary(runs[0], workflow: "nightly.yml", now: sameDay, timeZone: utc),
            "nightly: success 23:14, 43a9503"
        )
        let nextDay = sameDay.addingTimeInterval(86_400)
        XCTAssertEqual(
            ProjectBoard.runSummary(runs[0], workflow: "nightly.yml", now: nextDay, timeZone: utc),
            "nightly: success 27 Sep 23:14, 43a9503"
        )
        let running = ProjectBoard.WorkflowRun(
            status: "in_progress", conclusion: nil, headSha: "60e0ff2aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            createdAt: sameDay.addingTimeInterval(-60), updatedAt: sameDay, url: nil
        )
        XCTAssertEqual(
            ProjectBoard.runSummary(running, workflow: "release.yaml", now: sameDay, timeZone: utc),
            "release: in progress 23:29, 60e0ff2"
        )
        XCTAssertEqual(ProjectBoard.runSummary(nil, workflow: "nightly.yml", now: sameDay), "nightly: no run yet")
        XCTAssertEqual(ProjectBoard.parseRuns(Data("[]".utf8)), [])
    }

    // MARK: - gh

    func testGhIsAskedForTheConfiguredRepositoryOnGitHubCom() {
        XCTAssertEqual(
            GitHubCLIBoardClient.pullRequestArguments(repository: "acme/widgets", state: .open),
            ["pr", "list", "--repo", "github.com/acme/widgets", "--state", "open", "--limit", "100", "--json",
             "number,state,headRefName,headRefOid,headRepositoryOwner,headRepository,baseRefName,baseRefOid,isDraft,"
                + "mergeable,statusCheckRollup,url,title"]
        )
        // The merged ones in one GraphQL query: those opened last, as `gh pr list` lists them, and
        // those updated last, which it can't ask for; the fields under the names it gives them.
        XCTAssertEqual(
            GitHubCLIBoardClient.pullRequestArguments(repository: "acme/widgets", state: .merged),
            ["api", "graphql", "--hostname", "github.com", "-f",
             "query=query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { "
                + "opened: pullRequests(states: MERGED, first: 100, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { ...merged } } "
                + "updated: pullRequests(states: MERGED, first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { ...merged } } } } "
                + "fragment merged on PullRequest { number state headRefName headRefOid headRepositoryOwner { login } "
                + "headRepository { name } baseRefName url title mergedAt }",
             "-f", "owner=acme", "-f", "name=widgets"]
        )
        // What it falls back to: the call the Board made before.
        XCTAssertEqual(
            GitHubCLIBoardClient.openedLastArguments(repository: "acme/widgets"),
            ["pr", "list", "--repo", "github.com/acme/widgets", "--state", "merged", "--limit", "100", "--json",
             "number,state,headRefName,headRefOid,headRepositoryOwner,headRepository,baseRefName,url,title,mergedAt"]
        )
        XCTAssertEqual(
            GitHubCLIBoardClient.runArguments(repository: "acme/widgets", workflow: "nightly.yml", branch: "main"),
            ["run", "list", "--repo", "github.com/acme/widgets", "--workflow", "nightly.yml", "--branch", "main",
             "--event", "push", "--limit", "1", "--json", "status,conclusion,headSha,createdAt,updatedAt,url"]
        )
        // REST, as the queue's mutations.
        XCTAssertEqual(
            GitHubCLIBoardClient.retargetArguments(repository: "acme/widgets", number: 53, base: "main"),
            ["api", "--hostname", "github.com", "--method", "PATCH", "repos/acme/widgets/pulls/53",
             "-f", "base=main", "--jq", ".base.ref"]
        )
    }

    /// What a fake gh answers to one kind of call.
    private struct Answer {
        var output = ""
        var error = ""
        var status = 0
    }

    /// A gh in a folder of its own that answers the merged query (`gh api
    /// graphql`), `gh pr list --state merged` and the other calls apart,
    /// and writes down which it was asked. The folder goes with the test.
    private func fakeGH(query: Answer = Answer(), openedLast: Answer = Answer(), others: Answer = Answer()) throws
        -> (client: GitHubCLIBoardClient, calls: () -> [String]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-fake-gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("gh").path
        for (kind, answer) in [("query", query), ("openedLast", openedLast), ("others", others)] {
            try Data(answer.output.utf8).write(to: URL(fileURLWithPath: "\(path).\(kind).out"))
            try Data("\(answer.error)\n\(answer.status)".utf8).write(to: URL(fileURLWithPath: "\(path).\(kind).err"))
        }
        // The last line of ".err" is the status to exit with.
        let script = """
        #!/bin/sh
        case "$*" in
          "api graphql"*) kind=query ;;
          *"--state merged"*) kind=openedLast ;;
          *) kind=others ;;
        esac
        echo "$kind" >> "$0.calls"
        cat "$0.$kind.out"
        sed '$d' "$0.$kind.err" >&2
        exit "$(tail -n 1 "$0.$kind.err")"

        """
        try Data(script.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        let calls = { (try? String(contentsOfFile: "\(path).calls", encoding: .utf8))?.split(separator: "\n").map(String.init) ?? [] }
        return (GitHubCLIBoardClient(findGH: { path }), calls)
    }

    /// gh signed out (its status 4), or with a token GitHub refuses, is
    /// said in plain words, once.
    func testGhSignedOutSaysSoOnce() throws {
        let toSignIn = Answer(error: "To get started with GitHub CLI, please run:  gh auth login", status: 4)
        let signedOut = try fakeGH(query: toSignIn, openedLast: toSignIn, others: toSignIn)
        XCTAssertEqual(signedOut.client.pullRequests(repository: "acme/widgets", state: .open), .failure(.notSignedIn(nil)))
        XCTAssertEqual(signedOut.client.pullRequests(repository: "acme/widgets", state: .merged), .failure(.notSignedIn(nil)))
        XCTAssertEqual(signedOut.calls(), ["others", "query"], "signed out fails every call: the list opened last isn't asked for")

        // A revoked token, as each call words it.
        let refusal = "HTTP 401: Bad credentials (https://api.github.com/graphql)"
        let revoked = try fakeGH(
            query: Answer(output: #"{"message": "Bad credentials", "status": "401"}"#, error: "gh: Bad credentials (HTTP 401)", status: 1),
            openedLast: Answer(output: "[]"), others: Answer(error: refusal, status: 1)
        )
        XCTAssertEqual(revoked.client.pullRequests(repository: "acme/widgets", state: .open), .failure(.notSignedIn(refusal)))
        XCTAssertEqual(revoked.client.pullRequests(repository: "acme/widgets", state: .merged), .failure(.notSignedIn("Bad credentials")))
        XCTAssertEqual(revoked.calls(), ["others", "query"])
        let signIn = "gh isn’t signed in to GitHub: run gh auth login in a terminal, then Refresh."
        XCTAssertEqual(ProjectBoard.FetchError.notSignedIn(nil).message, signIn)
        XCTAssertEqual(ProjectBoard.FetchError.notSignedIn(refusal).message, "\(signIn) (gh: \(refusal))")

        // The header says it once, as the first read does, beside what else went wrong.
        XCTAssertEqual(
            ProjectBoard.messages(of: [
                .mergedPullRequests: .notSignedIn("Bad credentials"), .openPullRequests: .notSignedIn(refusal),
                .postMergeRun: .failed("HTTP 502: Bad Gateway")
            ]),
            ["\(signIn) (gh: \(refusal))", "gh: HTTP 502: Bad Gateway"]
        )
        XCTAssertEqual(ProjectBoard.messages(of: [.mergedPullRequests: .notSignedIn("Bad credentials")]), ["\(signIn) (gh: Bad credentials)"])
        XCTAssertEqual(
            ProjectBoard.messages(of: [.openPullRequests: .failed("timeout"), .mergedPullRequests: .failed("timeout"), .postMergeRun: .unreadable]),
            ["gh answered with something Nirux can’t read.", "gh: timeout"], "two reads that fail alike say it once"
        )
        XCTAssertEqual(ProjectBoard.messages(of: [:]), [])
    }

    /// The merged read is never less than the list opened last: when the
    /// query for both lists fails, the Board asks for that one as before.
    func testAFailedQueryFallsBackToTheListOpenedLast() throws {
        let merged = { (client: GitHubCLIBoardClient) in
            client.pullRequests(repository: "acme/widgets", state: .merged).map { String(decoding: $0, as: UTF8.self) }
        }
        let openedLast = Answer(output: #"[{"number": 7}]"#)
        let both = #"{"data": {"repository": {"opened": {"nodes": [{"number": 7}]}, "updated": {"nodes": [{"number": 3}]}}}}"#

        let answered = try fakeGH(query: Answer(output: both), openedLast: openedLast)
        XCTAssertEqual(merged(answered.client), .success(#"[{"number":7},{"number":3}]"#))
        XCTAssertEqual(answered.calls(), ["query"], "one call while the query answers")

        // A failed `gh api` prints the answer it got: a pull request's title in it isn't the reason.
        let partial = #"{"data": {"repository": {"opened": {"nodes": [{"number": 7, "title": "How to run gh auth login"}]}}}, "#
            + #""errors": [{"message": "Timeout"}]}"#
        let timedOut = try fakeGH(query: Answer(output: partial, error: "gh: Timeout", status: 1), openedLast: openedLast)
        XCTAssertEqual(merged(timedOut.client), .success(#"[{"number": 7}]"#))
        XCTAssertEqual(timedOut.calls(), ["query", "openedLast"])

        let withoutAList = try fakeGH(query: Answer(output: #"{"data": {"repository": {"opened": {"nodes": []}}}}"#), openedLast: openedLast)
        XCTAssertEqual(merged(withoutAList.client), .success(#"[{"number": 7}]"#), "an answer without one of its lists is a failed read")
        XCTAssertEqual(withoutAList.calls(), ["query", "openedLast"])

        // Both fail: the list's failure stands, worded as the open pull requests' is.
        let unresolved = "GraphQL: Could not resolve to a Repository with the name acme/widgets. (repository)"
        let missing = try fakeGH(
            query: Answer(error: "gh: Could not resolve to a Repository with the name acme/widgets.", status: 1),
            openedLast: Answer(error: unresolved, status: 1), others: Answer(error: unresolved, status: 1)
        )
        XCTAssertEqual(merged(missing.client), .failure(.failed(unresolved)))
        XCTAssertEqual(missing.client.pullRequests(repository: "acme/widgets", state: .open), .failure(.failed(unresolved)))
        XCTAssertEqual(missing.calls(), ["query", "openedLast", "others"], "the open pull requests are asked for once, whatever the answer")
        XCTAssertEqual(ProjectBoard.FetchError.failed(unresolved).message, "gh: \(unresolved)")
    }

    func testWithoutGhNothingRuns() {
        let client = GitHubCLIBoardClient(findGH: { nil })
        XCTAssertEqual(client.pullRequests(repository: "acme/widgets", state: .open), .failure(.ghMissing))
        XCTAssertEqual(client.postMergeRuns(repository: "acme/widgets", workflow: "n.yml", branch: "main"), .failure(.ghMissing))
    }

    // MARK: - Worktree listing

    func testTheWorktreeListingKeepsBranchHeadBareAndPrunable() {
        let output = [
            "worktree /p/widgets.git", "bare", "",
            "worktree /p/widgets", "HEAD 1111111111111111111111111111111111111111", "branch refs/heads/main", "",
            "worktree /p/widgets.merge", "HEAD 2222222222222222222222222222222222222222", "detached", "",
            "worktree /p/widgets.gone", "HEAD 3333333333333333333333333333333333333333", "branch refs/heads/gone",
            "prunable gitdir file points to non-existent location", "",
            "worktree /p/widgets.new", "HEAD 0000000000000000000000000000000000000000", "branch refs/heads/new",
            "locked reason", ""
        ].joined(separator: "\0")
        XCTAssertEqual(WorktreeCleanup.parseWorktreeListing(output), [
            .init(path: "/p/widgets.git", isBare: true),
            .init(path: "/p/widgets", head: "1111111111111111111111111111111111111111", branch: "main"),
            .init(path: "/p/widgets.merge", head: "2222222222222222222222222222222222222222"),
            .init(path: "/p/widgets.gone", head: "3333333333333333333333333333333333333333", branch: "gone", isPrunable: true),
            .init(path: "/p/widgets.new", isLocked: true, branch: "new")
        ])
    }
}
