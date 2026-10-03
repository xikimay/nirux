import XCTest
@testable import Nirux

/// docs/ci-failure-actions.md: which checks are red, when they are
/// reported, and what the two actions run.
final class CIFailureTests: XCTestCase {
    private func info(_ rollup: [[String: Any]], state: String = "OPEN") -> PRInfo {
        PRDetect.pullRequestInfo(from: [
            "number": 52, "state": state, "url": "https://github.com/acme/widgets/pull/52",
            "statusCheckRollup": rollup
        ])
    }

    private func checkRun(
        _ name: String, conclusion: String, status: String = "COMPLETED",
        startedAt: String = "2026-10-02T10:00:00Z", run: Int = 7, job: Int = 11,
        repository: String = "acme/widgets"
    ) -> [String: Any] {
        ["__typename": "CheckRun", "name": name, "workflowName": "Tests", "status": status,
         "conclusion": conclusion, "startedAt": startedAt,
         "detailsUrl": "https://github.com/\(repository)/actions/runs/\(run)/job/\(job)"]
    }

    private func status(_ context: String, state: String, targetUrl: String, startedAt: String) -> [String: Any] {
        ["__typename": "StatusContext", "context": context, "state": state, "targetUrl": targetUrl, "startedAt": startedAt]
    }

    // MARK: - Red rule (docs/project-board.md, section 3.2)

    func testEveryRedConclusionAndFailedStatusIsRed() {
        for conclusion in ["FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE"] {
            let pullRequest = info([checkRun("test", conclusion: conclusion)])
            XCTAssertEqual(pullRequest.ciStatus, "FAILURE", conclusion)
            XCTAssertEqual(CIFailure.redChecks(pullRequest).map(\.name), ["test"], conclusion)
            XCTAssertEqual(pullRequest.failedCheckUrl, "https://github.com/acme/widgets/actions/runs/7/job/11")
        }
        let failedStatus = info([status("ci/lint", state: "ERROR", targetUrl: "https://ci.example.com/lint/1",
                                        startedAt: "2026-10-02T10:00:00Z")])
        XCTAssertEqual(failedStatus.ciStatus, "FAILURE")
        XCTAssertEqual(CIFailure.redChecks(failedStatus).map(\.url), ["https://ci.example.com/lint/1"])
    }

    func testNeutralAndSkippedAreNotRed() {
        let pullRequest = info([checkRun("CodeQL", conclusion: "NEUTRAL"), checkRun("deploy", conclusion: "SKIPPED")])
        XCTAssertEqual(pullRequest.ciStatus, "SUCCESS")
        XCTAssertEqual(CIFailure.redChecks(pullRequest), [])
    }

    func testARerunReplacesTheFailureItReran() {
        let pullRequest = info([
            checkRun("test", conclusion: "FAILURE", startedAt: "2026-10-02T10:00:00Z", job: 11),
            checkRun("test", conclusion: "", status: "IN_PROGRESS", startedAt: "2026-10-02T10:05:00Z", job: 12)
        ])
        XCTAssertEqual(pullRequest.ciStatus, "PENDING")
        XCTAssertNil(pullRequest.failedCheckUrl)
    }

    /// gh writes a missing URL as "": the card's link falls back to the PR.
    func testAnEmptyURLIsNoURL() {
        let pullRequest = info([status("ci/lint", state: "FAILURE", targetUrl: "", startedAt: "2026-10-02T10:00:00Z")])
        XCTAssertNil(pullRequest.failedCheckUrl)
    }

    /// A run with a job still going can be neither rerun nor read: its
    /// failures wait for it to end. Other runs and statuses don't.
    func testAFailureWaitsForItsRunToEnd() {
        let rollup = [
            checkRun("lint", conclusion: "FAILURE", run: 7, job: 1),
            checkRun("test", conclusion: "", status: "IN_PROGRESS", run: 7, job: 2),
            checkRun("build", conclusion: "FAILURE", run: 8, job: 3)
        ]
        XCTAssertEqual(CIFailure.redChecks(info(rollup)).map(\.name), ["build"])
        XCTAssertEqual(CIFailure.runs(info(rollup)).map(\.id), [8])
    }

    func testOnlyAnOpenPullRequestIsActedOn() {
        for state in ["MERGED", "CLOSED"] {
            let pullRequest = info([checkRun("test", conclusion: "FAILURE")], state: state)
            XCTAssertEqual(pullRequest.ciStatus, "FAILURE")
            XCTAssertEqual(CIFailure.redChecks(pullRequest), [], state)
        }
    }

    // MARK: - Reported once

    @MainActor func testTheFirstReadOnlyRecordsThenEachNewRedRunIsReportedOnce() {
        let workspace = WorkspaceState(title: "ws", cwd: NSTemporaryDirectory())
        workspace.prInfo = info([checkRun("lint", conclusion: "FAILURE", job: 1)])
        XCTAssertEqual(workspace.takeNewRedChecks(), [], "already red at launch")

        workspace.prInfo = info([checkRun("lint", conclusion: "FAILURE", job: 1),
                                 checkRun("test", conclusion: "FAILURE", run: 8, job: 2)])
        XCTAssertEqual(workspace.takeNewRedChecks().map(\.name), ["test"])
        XCTAssertEqual(workspace.takeNewRedChecks(), [])

        workspace.prInfo = nil
        XCTAssertEqual(workspace.takeNewRedChecks(), [])
        workspace.prInfo = info([checkRun("test", conclusion: "FAILURE", run: 8, job: 2)])
        XCTAssertEqual(workspace.takeNewRedChecks(), [], "the same run, read again")

        workspace.prInfo = info([checkRun("test", conclusion: "FAILURE", startedAt: "2026-10-02T11:00:00Z", run: 8, job: 3)])
        XCTAssertEqual(workspace.takeNewRedChecks().map(\.name), ["test"], "a rerun that failed again")
    }

    @MainActor func testAWorkspaceWithoutAPullRequestAtLaunchReportsItsFirstRedRun() {
        let workspace = WorkspaceState(title: "ws", cwd: NSTemporaryDirectory())
        XCTAssertEqual(workspace.takeNewRedChecks(), [])
        workspace.prInfo = info([checkRun("test", conclusion: "FAILURE")])
        XCTAssertEqual(workspace.takeNewRedChecks().map(\.name), ["test"])
    }

    /// A status whose URL never changes (a coverage report): each new
    /// status is a new failure.
    @MainActor func testAStatusPostedAgainIsReportedAgain() {
        let workspace = WorkspaceState(title: "ws", cwd: NSTemporaryDirectory())
        XCTAssertEqual(workspace.takeNewRedChecks(), [])
        let url = "https://codecov.example/acme/widgets/pull/52"
        workspace.prInfo = info([status("codecov/patch", state: "FAILURE", targetUrl: url, startedAt: "2026-10-02T10:00:00Z")])
        XCTAssertEqual(workspace.takeNewRedChecks().count, 1)
        workspace.prInfo = info([status("codecov/patch", state: "FAILURE", targetUrl: url, startedAt: "2026-10-02T12:00:00Z")])
        XCTAssertEqual(workspace.takeNewRedChecks().count, 1)
    }

    /// A workspace switched to a pull request that was already red.
    @MainActor func testAnotherBranchStartsSilentAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "user.name=Nirux Tests", "-c", "user.email=nirux@example.test"] + arguments
            process.currentDirectoryURL = directory
            try process.run()
            process.waitUntilExit()
        }
        try git(["init", "-q", "-b", "one"])
        try git(["commit", "-q", "--allow-empty", "-m", "initial"])
        let workspace = WorkspaceState(title: "ws", cwd: directory.path)
        workspace.updateGitContext(GitDetect.context(at: directory.path))
        XCTAssertEqual(workspace.takeNewRedChecks(), [])

        try git(["checkout", "-q", "-b", "two"])
        workspace.updateGitContext(GitDetect.context(at: directory.path))
        workspace.prInfo = info([checkRun("test", conclusion: "FAILURE")])
        XCTAssertEqual(workspace.takeNewRedChecks(), [])
    }

    // MARK: - Actions

    func testOnlyGitHubActionsRunURLsAreRuns() {
        XCTAssertEqual(
            CIFailure.run(checkURL: "https://github.com/acme/widgets/actions/runs/123/job/456"),
            CIFailure.Run(repository: "github.com/acme/widgets", id: 123)
        )
        XCTAssertEqual(
            CIFailure.run(checkURL: "https://GHE.example.com/Acme/my.repo_1/actions/runs/9"),
            CIFailure.Run(repository: "ghe.example.com/Acme/my.repo_1", id: 9)
        )
        for url in [
            "https://github.com/acme/widgets/runs/13",
            "https://ci.example.com/lint/1",
            "http://github.com/acme/widgets/actions/runs/1",
            "https://github.com/acme/widgets/actions/runs/1x",
            "https://github.com/acme/wid`gets/actions/runs/1",
            "https://github.com/acme/widgets/actions/runs/1;rm -rf ~",
            "https://github.com/acme/widgets/actions/runs/",
            "https://github.com/../../actions/runs/1",
            "https://github.com/acme/widgets/actions/runs/99999999999999999999"
        ] {
            XCTAssertNil(CIFailure.run(checkURL: url), url)
        }
    }

    /// Anyone who can post a check on the pull request chooses its URL:
    /// only runs of its own repository are read or rerun.
    func testRunsAreThePullRequestRepositorysOnlyEachOnce() {
        let pullRequest = info([
            checkRun("test", conclusion: "FAILURE", run: 7, job: 1),
            checkRun("lint", conclusion: "FAILURE", run: 7, job: 2),
            checkRun("build", conclusion: "FAILURE", run: 8, job: 3),
            checkRun("deploy", conclusion: "FAILURE", run: 9, job: 4, repository: "acme/prod-deploy"),
            status("ci/lint", state: "FAILURE", targetUrl: "https://ci.example.com/lint/1", startedAt: "2026-10-02T10:00:00Z"),
            status("evil", state: "FAILURE", targetUrl: "https://evil.example/acme/widgets/actions/runs/10",
                   startedAt: "2026-10-02T10:00:00Z")
        ])
        XCTAssertEqual(CIFailure.runs(pullRequest).map(\.id), [7, 8])
    }

    func testThePromptOnlyCarriesParsedRuns() {
        let runs = [CIFailure.Run(repository: "github.com/acme/widgets", id: 7),
                    CIFailure.Run(repository: "github.com/acme/widgets", id: 8)]
        XCTAssertEqual(
            CIFailure.whyFailedPrompt(pullRequest: 52, runs: runs),
            "CI failed on PR #52. Run `gh run view 7 --repo github.com/acme/widgets --log-failed` and "
                + "`gh run view 8 --repo github.com/acme/widgets --log-failed`, then tell me why it failed."
        )
        XCTAssertEqual(
            CIFailure.rerunArguments(runs[0]),
            ["run", "rerun", "7", "--repo", "github.com/acme/widgets", "--failed"]
        )
    }
}
