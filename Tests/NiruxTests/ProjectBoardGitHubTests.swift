import XCTest
@testable import Nirux

/// The board's `gh` calls and what it reads from them. The fixtures are
/// real `gh` 2.100.0 output (2026-09-27), anonymized: owner, repository,
/// ids and URLs changed; PR 13's rerun and PR 14's fork added by hand.
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
             "number,state,headRefName,headRefOid,headRepositoryOwner,headRepository,baseRefName,isDraft,mergeable,"
                + "statusCheckRollup,url"]
        )
        XCTAssertEqual(
            Array(GitHubCLIBoardClient.pullRequestArguments(repository: "acme/widgets", state: .merged).prefix(8)),
            ["pr", "list", "--repo", "github.com/acme/widgets", "--state", "merged", "--limit", "30"]
        )
        XCTAssertEqual(
            GitHubCLIBoardClient.runArguments(repository: "acme/widgets", workflow: "nightly.yml", branch: "main"),
            ["run", "list", "--repo", "github.com/acme/widgets", "--workflow", "nightly.yml", "--branch", "main",
             "--event", "push", "--limit", "1", "--json", "status,conclusion,headSha,createdAt,updatedAt,url"]
        )
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
