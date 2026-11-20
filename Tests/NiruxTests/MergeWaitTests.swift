import XCTest
@testable import Nirux

/// A merge wait's steps (docs/design/task-dependencies.md): what each read of
/// the awaited task's pull request, its closing, and GitHub's answers mean.
final class MergeWaitTests: XCTestCase {
    private func wait(branch: String? = "feat/login", repository: String? = "/repo", pullRequest: MergeWait.PullRequest? = nil) -> MergeWait {
        MergeWait(
            id: "w", awaited: MergeWait.Awaited(
                workspaceID: "a", title: "Fix login", branch: branch, repository: repository, pullRequest: pullRequest
            ),
            action: .tell(message: "merge origin/main"), createdAt: 0
        )
    }

    private func pullRequest(_ number: Int, _ state: String) -> PRInfo {
        PRInfo(
            number: number, state: state, isDraft: false, ciStatus: nil, checks: [], reviewDecision: nil, mergeable: nil,
            url: "https://github.com/o/r/pull/\(number)", additions: nil, deletions: nil, changedFiles: nil
        )
    }

    private let recorded = MergeWait.PullRequest(number: 41, url: "https://github.com/o/r/pull/41")

    func testAnOpenReadIsRecordedAndAMergedOneReleases() {
        var wait = wait()
        XCTAssertEqual(wait.step(after: .read(pullRequest(41, "OPEN"))), .keep)
        XCTAssertEqual(wait.awaited.pullRequest, recorded)
        XCTAssertEqual(wait.awaitedName, "#41")
        XCTAssertEqual(wait.step(after: .read(pullRequest(41, "MERGED"))), .release)
        var fresh = self.wait()
        XCTAssertEqual(fresh.step(after: .read(pullRequest(41, "MERGED"))), .release, "first seen merged, after a relaunch")
        XCTAssertEqual(fresh.awaitedName, "#41", "named by the pull request that merged")
    }

    func testAClosedReadFailsForTheRecordedPullRequestOnly() {
        var wait = wait(pullRequest: recorded)
        XCTAssertEqual(wait.step(after: .read(pullRequest(41, "CLOSED"))), .fail(.closedUnmerged(number: 41)))
        var older = self.wait(pullRequest: MergeWait.PullRequest(number: 42, url: "https://github.com/o/r/pull/42"))
        XCTAssertEqual(older.step(after: .read(pullRequest(41, "CLOSED"))), .lookUp, "#42 may still be open")
        var unrecorded = self.wait()
        XCTAssertEqual(unrecorded.step(after: .read(pullRequest(41, "CLOSED"))), .fail(.closedUnmerged(number: 41)))
    }

    func testAReadWithoutThePullRequestAsksGitHub() {
        var recordedWait = wait(pullRequest: recorded)
        XCTAssertEqual(recordedWait.step(after: .read(nil)), .lookUp)
        XCTAssertEqual(recordedWait.lookUpTarget, MergeWait.LookUpTarget(pullRequest: recorded.url, folder: "/repo"))
        var branchOnly = wait()
        XCTAssertEqual(branchOnly.step(after: .read(nil)), .lookUp)
        XCTAssertEqual(branchOnly.lookUpTarget, MergeWait.LookUpTarget(pullRequest: "feat/login", folder: "/repo"))
        var nowhere = wait(repository: nil)
        XCTAssertNil(nowhere.lookUpTarget, "a branch alone, with nowhere to ask")
        XCTAssertEqual(nowhere.step(after: .read(nil)), .keep)
    }

    func testTheTaskClosingAsksGitHubOrFails() {
        var recordedWait = wait(pullRequest: recorded)
        XCTAssertEqual(recordedWait.step(after: .gone), .lookUp)
        var nowhere = wait(branch: nil)
        XCTAssertEqual(nowhere.step(after: .gone), .fail(.closedFirst(number: nil)))
    }

    func testWhatGitHubSays() {
        func step(_ found: MergeWait.LookedUp?, gone: Bool) -> (MergeWait.Step, MergeWait.PullRequest?) {
            var wait = wait()
            return (wait.step(after: .lookedUp(found, awaitedGone: gone)), wait.awaited.pullRequest)
        }
        let open = MergeWait.LookedUp(number: 41, state: "OPEN", url: recorded.url)
        XCTAssertEqual(step(MergeWait.LookedUp(number: 41, state: "MERGED", url: recorded.url), gone: true).0, .release)
        XCTAssertEqual(step(MergeWait.LookedUp(number: 41, state: "CLOSED", url: recorded.url), gone: false).0, .fail(.closedUnmerged(number: 41)))
        XCTAssertEqual(step(open, gone: false).0, .keep)
        XCTAssertEqual(step(open, gone: false).1, recorded, "found open: recorded")
        XCTAssertEqual(step(open, gone: true).0, .fail(.closedFirst(number: 41)))
        XCTAssertEqual(step(nil, gone: false).0, .keep)
        XCTAssertEqual(step(nil, gone: true).0, .fail(.closedFirst(number: nil)))
        var unanswered = wait()
        XCTAssertEqual(unanswered.step(after: .unanswered("gh: offline", awaitedGone: false)), .keep)
        XCTAssertEqual(unanswered.step(after: .unanswered("gh: offline", awaitedGone: true)), .fail(.unanswered("gh: offline")))
    }

    func testWhyItWontHappen() {
        let wait = wait(pullRequest: recorded)
        XCTAssertEqual(wait.awaitedLongName, "#41 (“Fix login”)")
        XCTAssertEqual(wait.sentence(.closedUnmerged(number: 41)), "#41 (“Fix login”) closed without merging")
        XCTAssertEqual(wait.sentence(.closedFirst(number: 41)), "“Fix login” closed while #41 was still open")
        XCTAssertEqual(wait.sentence(.closedFirst(number: nil)), "“Fix login” closed without a merged pull request")
        XCTAssertEqual(self.wait().awaitedName, "“Fix login”", "no pull request yet")
    }

    /// Saved with its workspace; one this build can't read is dropped, the
    /// workspace and the other waits kept.
    func testWaitsAreSavedWithTheirWorkspace() throws {
        let saved = PersistedWorkspace(
            id: "b", title: "Add a filter", cwd: "/tmp", columns: [], focusedColumnIndex: 0, mergeWaits: [wait(pullRequest: recorded)]
        )
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var waits = try XCTUnwrap(json["mergeWaits"] as? [[String: Any]])
        XCTAssertEqual(waits.count, 1)
        var later = waits[0]
        later["action"] = ["start": ["description": "a later build's action"]]
        waits.append(later)
        json["mergeWaits"] = waits
        let restored = try JSONDecoder().decode(PersistedWorkspace.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.mergeWaits, [wait(pullRequest: recorded)])
        json["mergeWaits"] = "not a list"
        let unreadable = try JSONDecoder().decode(PersistedWorkspace.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(unreadable.mergeWaits)
        let none = PersistedWorkspace(id: "c", title: "c", cwd: "/tmp", columns: [], focusedColumnIndex: 0)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(none)) as? [String: Any])
        XCTAssertNil(written["mergeWaits"], "nothing written without waits")
    }

    func testTheRowSaysWhatItHolds() {
        XCTAssertNil(SidebarHeldMessages([]))
        let one = SidebarHeldMessages([wait(pullRequest: recorded)])
        XCTAssertEqual(one?.line, "After #41 merges · a message from the Lead")
        XCTAssertEqual(one?.tooltip, "Typed as the Lead's message once #41 (“Fix login”) merges: “merge origin/main”")
        var other = wait()
        other.awaited = MergeWait.Awaited(workspaceID: "c", title: "Add a filter")
        XCTAssertEqual(
            SidebarHeldMessages([wait(pullRequest: recorded), wait(pullRequest: recorded), other])?.line,
            "After #41, “Add a filter” merge · 3 messages from the Lead"
        )
    }
}
