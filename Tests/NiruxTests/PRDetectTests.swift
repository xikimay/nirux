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

    func testMergedPullRequestIsFetchedAcrossAllStates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let gh = directory.appendingPathComponent("gh")
        let script = #"""
        #!/bin/sh
        state=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --state)
                    state="$2"
                    shift 2
                    ;;
                *)
                    shift
                    ;;
            esac
        done
        [ "$state" = "all" ] || exit 64
        printf '%s\n' '[{"number":42,"state":"MERGED","isDraft":false,"statusCheckRollup":[],"url":"https://example.test/pull/42"}]'
        """#
        try script.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)

        let pullRequest = try XCTUnwrap(
            PRDetect.fetch(branch: "feature/task", cwd: directory.path, ghPath: gh.path)
        )

        XCTAssertEqual(pullRequest.number, 42)
        XCTAssertEqual(pullRequest.state, "MERGED")
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
}
