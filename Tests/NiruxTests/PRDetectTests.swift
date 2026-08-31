import XCTest
@testable import Nirux

final class PRDetectTests: XCTestCase {
    func testInactiveWorkspaceNeverRefreshesGitHub() {
        XCTAssertFalse(PRDetect.shouldRefresh(isInactive: true, branch: "feature/task"))
    }

    func testActiveWorkspaceWithBranchRefreshesGitHub() {
        XCTAssertTrue(PRDetect.shouldRefresh(isInactive: false, branch: "feature/task"))
    }

    func testWorkspaceWithoutBranchDoesNotRefreshGitHub() {
        XCTAssertFalse(PRDetect.shouldRefresh(isInactive: false, branch: nil))
        XCTAssertFalse(PRDetect.shouldRefresh(isInactive: false, branch: "   "))
    }

    func testOpenPullRequestIsPreferredOverNewerClosedPullRequest() throws {
        let result = try fetchUsingFakeGitHubCLI(json: #"""
        [
          {"number":52,"state":"CLOSED","headRefOid":"current-head","isDraft":false,"statusCheckRollup":[],"url":"https://example.test/pull/52"},
          {"number":41,"state":"OPEN","headRefOid":"older-head","isDraft":false,"statusCheckRollup":[],"url":"https://example.test/pull/41"}
        ]
        """#)
        guard case .success(let context, let fetched) = result else {
            return XCTFail("Expected successful PR lookup")
        }
        let pullRequest = try XCTUnwrap(fetched)

        XCTAssertEqual(context.identity.head, "current-head")
        XCTAssertEqual(context.branch, "feature/task")
        XCTAssertEqual(pullRequest.number, 41)
        XCTAssertEqual(pullRequest.state, "OPEN")
        XCTAssertEqual(
            WorkspacePhase.derived(
                isInactive: false,
                hasBlocker: false,
                agentStatuses: [],
                pullRequestState: pullRequest.state
            ),
            .review
        )
    }

    func testNewestTerminalPullRequestIsSelectedWhenNoneAreOpen() throws {
        let result = try fetchUsingFakeGitHubCLI(json: #"""
        [
          {"number":42,"state":"MERGED","headRefOid":"current-head","isDraft":false,"statusCheckRollup":[],"url":"https://example.test/pull/42"},
          {"number":57,"state":"CLOSED","headRefOid":"current-head","isDraft":false,"statusCheckRollup":[],"url":"https://example.test/pull/57"}
        ]
        """#)
        guard case .success(_, let fetched) = result else {
            return XCTFail("Expected successful PR lookup")
        }
        let pullRequest = try XCTUnwrap(fetched)

        XCTAssertEqual(pullRequest.number, 57)
        XCTAssertEqual(pullRequest.state, "CLOSED")
        XCTAssertEqual(
            WorkspacePhase.derived(
                isInactive: false,
                hasBlocker: false,
                agentStatuses: [],
                pullRequestState: pullRequest.state
            ),
            .done
        )
    }

    func testTerminalPullRequestFromReusedBranchNameIsIgnored() throws {
        let result = try fetchUsingFakeGitHubCLI(json: #"""
        [
          {"number":42,"state":"MERGED","headRefOid":"historical-head","isDraft":false,"statusCheckRollup":[],"url":"https://example.test/pull/42"}
        ]
        """#, currentHead: "recreated-head")

        guard case .success(_, let pullRequest) = result else {
            return XCTFail("Expected successful PR lookup")
        }
        XCTAssertNil(pullRequest)
    }

    func testLookupFailureDiffersFromSuccessfulEmptyResult() throws {
        let failure = try fetchUsingFakeGitHubCLI(json: "[]", exitStatus: 1)
        guard case .failure = failure else {
            return XCTFail("Expected failed PR lookup")
        }

        let empty = try fetchUsingFakeGitHubCLI(json: "[]")
        guard case .success(_, let pullRequest) = empty else {
            return XCTFail("Expected successful empty PR lookup")
        }
        XCTAssertNil(pullRequest)
    }

    func testLargeGitHubResponseIsDrainedWhileProcessRuns() throws {
        let padding = String(repeating: "x", count: 512 * 1024)
        let json = #"[{"number":41,"state":"OPEN","headRefOid":"current-head","isDraft":false,"statusCheckRollup":[{"conclusion":"SUCCESS","padding":"\#(padding)"}],"url":"https://example.test/pull/41"}]"#
        let result = try fetchUsingFakeGitHubCLI(
            json: json,
            watchdogDelay: 2
        )
        guard case .success(_, let fetched) = result else {
            return XCTFail("Expected large PR lookup to complete")
        }
        XCTAssertEqual(try XCTUnwrap(fetched).ciStatus, "SUCCESS")
    }

    private func fetchUsingFakeGitHubCLI(
        json: String,
        currentHead: String = "current-head",
        exitStatus: Int = 0,
        watchdogDelay: Int = 30
    ) throws -> PRDetect.FetchResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let gh = directory.appendingPathComponent("gh")
        let script = #"""
        #!/bin/sh
        state=""
        limit=0
        json_fields=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --state)
                    state="$2"
                    shift 2
                    ;;
                --limit)
                    limit="$2"
                    shift 2
                    ;;
                --json)
                    json_fields="$2"
                    shift 2
                    ;;
                *)
                    shift
                    ;;
            esac
        done
        [ "$state" = "all" ] || exit 64
        [ "$limit" -ge 2 ] || exit 65
        case ",$json_fields," in
            *,headRefOid,*) ;;
            *) exit 66 ;;
        esac
        parent_pid=$$
        (sleep \#(watchdogDelay); kill -TERM "$parent_pid") >/dev/null 2>&1 &
        watchdog_pid=$!
        printf '%s\n' '\#(json)'
        kill "$watchdog_pid" 2>/dev/null || true
        exit \#(exitStatus)
        """#
        try script.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)

        return PRDetect.fetch(
            branch: "feature/task",
            ghPath: gh.path,
            context: GitContext(
                branch: "feature/task",
                identity: GitIdentity(
                    repositoryRoot: directory.path,
                    head: currentHead
                )
            )
        )
    }
}
