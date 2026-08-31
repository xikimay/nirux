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
        let pullRequest = try fetchUsingFakeGitHubCLI(json: #"""
        [
          {"number":52,"state":"CLOSED","isDraft":false,"statusCheckRollup":[],"url":"https://example.test/pull/52"},
          {"number":41,"state":"OPEN","isDraft":false,"statusCheckRollup":[],"url":"https://example.test/pull/41"}
        ]
        """#)

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
        let pullRequest = try fetchUsingFakeGitHubCLI(json: #"""
        [
          {"number":42,"state":"MERGED","isDraft":false,"statusCheckRollup":[],"url":"https://example.test/pull/42"},
          {"number":57,"state":"CLOSED","isDraft":false,"statusCheckRollup":[],"url":"https://example.test/pull/57"}
        ]
        """#)

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

    private func fetchUsingFakeGitHubCLI(json: String) throws -> PRInfo {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let gh = directory.appendingPathComponent("gh")
        let script = #"""
        #!/bin/sh
        state=""
        limit=0
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
                *)
                    shift
                    ;;
            esac
        done
        [ "$state" = "all" ] || exit 64
        [ "$limit" -ge 2 ] || exit 65
        printf '%s\n' '\#(json)'
        """#
        try script.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)

        return try XCTUnwrap(
            PRDetect.fetch(branch: "feature/task", cwd: directory.path, ghPath: gh.path)
        )
    }
}
