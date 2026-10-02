import XCTest
@testable import Nirux

/// docs/ci-failure-actions.md: which checks are red, when they are
/// reported, and what the two actions run.
final class CIFailureTests: XCTestCase {
    private func info(_ rollup: [[String: Any]]) -> PRInfo {
        PRDetect.pullRequestInfo(from: [
            "number": 52, "state": "OPEN", "url": "https://github.com/acme/widgets/pull/52",
            "statusCheckRollup": rollup
        ])
    }

    private func checkRun(
        _ name: String, conclusion: String, status: String = "COMPLETED",
        startedAt: String = "2026-10-02T10:00:00Z", job: Int = 11
    ) -> [String: Any] {
        ["__typename": "CheckRun", "name": name, "workflowName": "Tests", "status": status,
         "conclusion": conclusion, "startedAt": startedAt,
         "detailsUrl": "https://github.com/acme/widgets/actions/runs/7/job/\(job)"]
    }

    // MARK: - Red rule (docs/project-board.md, section 3.2)

    func testEveryRedConclusionAndFailedStatusIsRed() {
        for conclusion in ["FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE"] {
            let pullRequest = info([checkRun("test", conclusion: conclusion)])
            XCTAssertEqual(pullRequest.ciStatus, "FAILURE", conclusion)
            XCTAssertEqual(pullRequest.redChecks.map(\.name), ["test"], conclusion)
            XCTAssertEqual(pullRequest.failedCheckUrl, "https://github.com/acme/widgets/actions/runs/7/job/11")
        }
        let status = info([["__typename": "StatusContext", "context": "ci/lint", "state": "ERROR",
                            "targetUrl": "https://ci.example.com/lint/1"]])
        XCTAssertEqual(status.ciStatus, "FAILURE")
        XCTAssertEqual(status.redChecks, [PRInfo.RedCheck(name: "ci/lint", url: "https://ci.example.com/lint/1")])
    }

    func testNeutralAndSkippedAreNotRed() {
        let pullRequest = info([checkRun("CodeQL", conclusion: "NEUTRAL"), checkRun("deploy", conclusion: "SKIPPED")])
        XCTAssertEqual(pullRequest.ciStatus, "SUCCESS")
        XCTAssertEqual(pullRequest.redChecks, [])
    }

    func testARerunReplacesTheFailureItReran() {
        let pullRequest = info([
            checkRun("test", conclusion: "FAILURE", startedAt: "2026-10-02T10:00:00Z", job: 11),
            checkRun("test", conclusion: "", status: "IN_PROGRESS", startedAt: "2026-10-02T10:05:00Z", job: 12)
        ])
        XCTAssertEqual(pullRequest.ciStatus, "PENDING")
        XCTAssertEqual(pullRequest.redChecks, [])
        XCTAssertNil(pullRequest.failedCheckUrl)
    }

    // MARK: - Reported once

    @MainActor func testTheFirstReadOnlyRecordsThenEachNewRedRunIsReportedOnce() {
        let workspace = WorkspaceState(title: "ws", cwd: NSTemporaryDirectory())
        workspace.prInfo = info([checkRun("lint", conclusion: "FAILURE", job: 1)])
        XCTAssertEqual(workspace.takeNewRedChecks(), [], "already red at launch")

        workspace.prInfo = info([checkRun("lint", conclusion: "FAILURE", job: 1),
                                 checkRun("test", conclusion: "FAILURE", job: 2)])
        XCTAssertEqual(workspace.takeNewRedChecks().map(\.name), ["test"])
        XCTAssertEqual(workspace.takeNewRedChecks(), [])

        workspace.prInfo = nil
        XCTAssertEqual(workspace.takeNewRedChecks(), [])
        workspace.prInfo = info([checkRun("test", conclusion: "FAILURE", job: 2)])
        XCTAssertEqual(workspace.takeNewRedChecks(), [], "the same run, read again")

        workspace.prInfo = info([checkRun("test", conclusion: "FAILURE", startedAt: "2026-10-02T11:00:00Z", job: 3)])
        XCTAssertEqual(workspace.takeNewRedChecks().map(\.name), ["test"], "a rerun that failed again")
    }

    @MainActor func testAWorkspaceWithoutAPullRequestAtLaunchReportsItsFirstRedRun() {
        let workspace = WorkspaceState(title: "ws", cwd: NSTemporaryDirectory())
        XCTAssertEqual(workspace.takeNewRedChecks(), [])
        workspace.prInfo = info([checkRun("test", conclusion: "FAILURE")])
        XCTAssertEqual(workspace.takeNewRedChecks().map(\.name), ["test"])
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
            "https://github.com/acme/widgets/actions/runs/"
        ] {
            XCTAssertNil(CIFailure.run(checkURL: url), url)
        }
    }

    func testRunsAreListedOnceEach() {
        let red = [
            PRInfo.RedCheck(name: "test", url: "https://github.com/acme/widgets/actions/runs/7/job/1"),
            PRInfo.RedCheck(name: "lint", url: "https://github.com/acme/widgets/actions/runs/7/job/2"),
            PRInfo.RedCheck(name: "ci/lint", url: "https://ci.example.com/lint/1"),
            PRInfo.RedCheck(name: "build", url: "https://github.com/acme/widgets/actions/runs/8/job/3"),
            PRInfo.RedCheck(name: "status", url: nil)
        ]
        XCTAssertEqual(CIFailure.runs(red).map(\.id), [7, 8])
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
