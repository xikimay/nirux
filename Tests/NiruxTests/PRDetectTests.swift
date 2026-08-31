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

    func testGitHubRepositoryIdentityParsesCommonRemoteURLs() {
        let expected = GitHubRepository(owner: "xikimay", name: "nirux")

        XCTAssertEqual(
            GitHubRepository(remoteURL: "https://github.com/XikiMay/Nirux.git"),
            expected
        )
        XCTAssertEqual(
            GitHubRepository(remoteURL: "git@github.com:XikiMay/Nirux.git"),
            expected
        )
    }

    func testGitContextTracksUntrackedUnstagedAndStagedChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try runGit(["init", "-q"], at: directory)
        let trackedFile = directory.appendingPathComponent("tracked.txt")
        try "clean\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt"], at: directory)
        try runGit([
            "-c", "user.name=Nirux Tests",
            "-c", "user.email=nirux@example.test",
            "commit", "-qm", "initial"
        ], at: directory)

        XCTAssertFalse(try XCTUnwrap(GitDetect.context(at: directory.path)).identity.isDirty)

        let untrackedFile = directory.appendingPathComponent("untracked.txt")
        try "new\n".write(to: untrackedFile, atomically: true, encoding: .utf8)
        XCTAssertTrue(try XCTUnwrap(GitDetect.context(at: directory.path)).identity.isDirty)
        try FileManager.default.removeItem(at: untrackedFile)

        try "modified\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        XCTAssertTrue(try XCTUnwrap(GitDetect.context(at: directory.path)).identity.isDirty)
        try runGit(["restore", "tracked.txt"], at: directory)
        XCTAssertFalse(try XCTUnwrap(GitDetect.context(at: directory.path)).identity.isDirty)

        try "staged\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt"], at: directory)
        XCTAssertTrue(try XCTUnwrap(GitDetect.context(at: directory.path)).identity.isDirty)
    }

    func testOpenPullRequestIsPreferredOverNewerClosedPullRequest() throws {
        let result = try fetchUsingFakeGitHubCLI(
            openJSON: #"""
        [
          {"number":41,"state":"OPEN","headRefOid":"older-head","headRepositoryOwner":{"login":"XikiMay"},"headRepository":{"name":"Nirux"},"isDraft":false,"statusCheckRollup":[],"url":"https://example.test/pull/41"}
        ]
        """#,
            terminalJSON: #"""
        [
          {"number":52,"state":"CLOSED","headRefOid":"current-head","isDraft":false,"statusCheckRollup":[],"url":"https://example.test/pull/52"}
        ]
        """#
        )
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

    func testOpenPullRequestFromSameNamedForkBranchIsIgnored() throws {
        let result = try fetchUsingFakeGitHubCLI(openJSON: #"""
        [
          {"number":90,"state":"OPEN","headRefOid":"foreign-head","headRepositoryOwner":{"login":"alice"},"headRepository":{"name":"nirux"},"isDraft":false,"statusCheckRollup":[],"url":"https://example.test/pull/90"},
          {"number":80,"state":"OPEN","headRefOid":"current-head","headRepositoryOwner":{"login":"xikimay"},"headRepository":{"name":"nirux"},"isDraft":false,"statusCheckRollup":[],"url":"https://example.test/pull/80"}
        ]
        """#)

        guard case .success(_, let fetched) = result else {
            return XCTFail("Expected successful PR lookup")
        }
        XCTAssertEqual(try XCTUnwrap(fetched).number, 80)
    }

    func testAuthoritativeOpenPullRequestIsFoundBeyondFirstHundredForks() throws {
        let foreignCandidates: [[String: Any]] = (100 ... 199).map { number in
            [
                "number": number,
                "state": "OPEN",
                "headRefOid": "foreign-\(number)",
                "headRepositoryOwner": ["login": "fork-\(number)"],
                "headRepository": ["name": "nirux"],
                "isDraft": false,
                "statusCheckRollup": [],
                "url": "https://example.test/pull/\(number)"
            ]
        }
        let authoritativeCandidate: [String: Any] = [
            "number": 1,
            "state": "OPEN",
            "headRefOid": "current-head",
            "headRepositoryOwner": ["login": "xikimay"],
            "headRepository": ["name": "nirux"],
            "isDraft": false,
            "statusCheckRollup": [],
            "url": "https://example.test/pull/1"
        ]
        let cappedData = try JSONSerialization.data(withJSONObject: foreignCandidates)
        let exhaustiveData = try JSONSerialization.data(
            withJSONObject: foreignCandidates + [authoritativeCandidate]
        )
        let result = try fetchUsingFakeGitHubCLI(
            openJSON: try XCTUnwrap(String(data: exhaustiveData, encoding: .utf8)),
            cappedOpenJSON: try XCTUnwrap(String(data: cappedData, encoding: .utf8))
        )

        guard case .success(_, let fetched) = result else {
            return XCTFail("Expected exhaustive open PR lookup")
        }
        XCTAssertEqual(try XCTUnwrap(fetched).number, 1)
    }

    func testOpenPullRequestWithoutUpstreamIdentityPreservesCachedResult() throws {
        let result = try fetchUsingFakeGitHubCLI(
            openJSON: #"""
            [
              {"number":41,"state":"OPEN","headRefOid":"current-head","headRepositoryOwner":{"login":"xikimay"},"headRepository":{"name":"nirux"},"isDraft":false,"statusCheckRollup":[],"url":"https://example.test/pull/41"}
            ]
            """#,
            upstreamRepository: nil
        )

        guard case .failure = result else {
            return XCTFail("Expected an unclassifiable open PR lookup to fail")
        }
    }

    func testReopenedPullRequestIsNotHiddenByLongClosedHistory() throws {
        let terminalCandidates: [[String: Any]] = (100 ... 199).map { number in
            [
                "number": number,
                "state": "CLOSED",
                "headRefOid": "historical-\(number)",
                "isDraft": false,
                "url": "https://example.test/pull/\(number)"
            ]
        }
        let terminalData = try JSONSerialization.data(withJSONObject: terminalCandidates)
        let terminalJSON = try XCTUnwrap(String(data: terminalData, encoding: .utf8))
        let result = try fetchUsingFakeGitHubCLI(
            openJSON: #"""
            [
              {"number":1,"state":"OPEN","headRefOid":"reopened-head","headRepositoryOwner":{"login":"xikimay"},"headRepository":{"name":"nirux"},"isDraft":false,"statusCheckRollup":[],"url":"https://example.test/pull/1"}
            ]
            """#,
            terminalJSON: terminalJSON
        )

        guard case .success(_, let fetched) = result else {
            return XCTFail("Expected successful PR lookup")
        }
        XCTAssertEqual(try XCTUnwrap(fetched).number, 1)
    }

    func testNewestTerminalPullRequestIsSelectedWhenNoneAreOpen() throws {
        let result = try fetchUsingFakeGitHubCLI(terminalJSON: #"""
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

    func testDirtyWorktreeKeepsOpenPullRequestAndRejectsTerminalState() throws {
        let openResult = try fetchUsingFakeGitHubCLI(
            openJSON: #"""
            [
              {"number":41,"state":"OPEN","headRefOid":"current-head","headRepositoryOwner":{"login":"xikimay"},"headRepository":{"name":"nirux"},"isDraft":false,"statusCheckRollup":[],"url":"https://example.test/pull/41"}
            ]
            """#,
            isDirty: true
        )
        guard case .success(_, let openInfo) = openResult else {
            return XCTFail("Expected successful open PR lookup")
        }
        XCTAssertEqual(try XCTUnwrap(openInfo).state, "OPEN")

        let terminalResult = try fetchUsingFakeGitHubCLI(
            terminalJSON: #"""
            [
              {"number":42,"state":"MERGED","headRefOid":"current-head","isDraft":false,"statusCheckRollup":[],"url":"https://example.test/pull/42"}
            ]
            """#,
            isDirty: true
        )
        guard case .success(_, let terminalInfo) = terminalResult else {
            return XCTFail("Expected successful terminal PR lookup")
        }
        XCTAssertNil(terminalInfo)
    }

    func testTerminalPullRequestFromReusedBranchNameIsIgnored() throws {
        let result = try fetchUsingFakeGitHubCLI(terminalJSON: #"""
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
        let failure = try fetchUsingFakeGitHubCLI(failingState: "open")
        guard case .failure = failure else {
            return XCTFail("Expected failed PR lookup")
        }

        let empty = try fetchUsingFakeGitHubCLI()
        guard case .success(_, let pullRequest) = empty else {
            return XCTFail("Expected successful empty PR lookup")
        }
        XCTAssertNil(pullRequest)
    }

    func testLargeGitHubResponseIsDrainedWhileProcessRuns() throws {
        let padding = String(repeating: "x", count: 512 * 1024)
        let json = #"[{"number":41,"state":"OPEN","headRefOid":"current-head","headRepositoryOwner":{"login":"xikimay"},"headRepository":{"name":"nirux"},"isDraft":false,"statusCheckRollup":[{"conclusion":"SUCCESS","padding":"\#(padding)"}],"url":"https://example.test/pull/41"}]"#
        let result = try fetchUsingFakeGitHubCLI(
            openJSON: json,
            watchdogDelay: 2
        )
        guard case .success(_, let fetched) = result else {
            return XCTFail("Expected large PR lookup to complete")
        }
        XCTAssertEqual(try XCTUnwrap(fetched).ciStatus, "SUCCESS")
    }

    private func fetchUsingFakeGitHubCLI(
        openJSON: String = "[]",
        cappedOpenJSON: String? = nil,
        terminalJSON: String = "[]",
        currentHead: String = "current-head",
        isDirty: Bool = false,
        failingState: String? = nil,
        watchdogDelay: Int = 30,
        upstreamRepository: GitHubRepository? = GitHubRepository(owner: "xikimay", name: "nirux")
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
        search=""
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
                --search)
                    search="$2"
                    shift 2
                    ;;
                *)
                    shift
                    ;;
            esac
        done
        case "$state" in
            open)
                if [ "\#(cappedOpenJSON == nil ? "0" : "1")" = "1" ] && [ "$limit" = "100" ]; then
                    payload='\#(cappedOpenJSON ?? "")'
                else
                    payload='\#(openJSON)'
                fi
                ;;
            all)
                [ "$search" = "\#(currentHead)" ] || exit 69
                payload='\#(terminalJSON)'
                ;;
            *) exit 64 ;;
        esac
        [ -n "$limit" ] && [ "$limit" != "0" ] && [ "$limit" != "1" ] || exit 65
        case ",$json_fields," in
            *,headRefOid,*) ;;
            *) exit 66 ;;
        esac
        case ",$json_fields," in
            *,headRepositoryOwner,*) ;;
            *) exit 67 ;;
        esac
        case ",$json_fields," in
            *,headRepository,*) ;;
            *) exit 68 ;;
        esac
        [ "$state" != "\#(failingState ?? "")" ] || exit 1
        parent_pid=$$
        (sleep \#(watchdogDelay); kill -TERM "$parent_pid") >/dev/null 2>&1 &
        watchdog_pid=$!
        printf '%s\n' "$payload"
        kill "$watchdog_pid" 2>/dev/null || true
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
                    head: currentHead,
                    isDirty: isDirty
                )
            ),
            upstreamRepository: upstreamRepository
        )
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "PRDetectTests.Git", code: Int(process.terminationStatus))
        }
    }
}
