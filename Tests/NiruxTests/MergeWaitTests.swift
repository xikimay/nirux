import XCTest
@testable import Nirux

/// A merge wait's steps (docs/design/task-dependencies.md): what each read of
/// the awaited task's pull request, its closing, and GitHub's answers mean.
final class MergeWaitTests: XCTestCase {
    private func wait(pullRequest: MergeWait.PullRequest? = nil, mergedAt: TimeInterval? = nil) -> MergeWait {
        MergeWait(
            id: "w", awaited: MergeWait.Awaited(workspaceID: "a", title: "Fix login", pullRequest: pullRequest),
            action: .tell(message: "merge origin/main"), createdAt: 0, mergedAt: mergedAt
        )
    }

    private func pullRequest(_ number: Int, _ state: String) -> PRInfo {
        PRInfo(
            number: number, state: state, isDraft: false, ciStatus: nil, checks: [], reviewDecision: nil, mergeable: nil,
            url: "https://github.com/o/r/pull/\(number)", additions: nil, deletions: nil, changedFiles: nil
        )
    }

    private func found(_ number: Int, _ state: String) -> MergeWait.LookedUp {
        MergeWait.LookedUp(number: number, state: state, url: "https://github.com/o/r/pull/\(number)")
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

    func testOnlyTheRecordedPullRequestCounts() {
        var wait = wait(pullRequest: recorded)
        XCTAssertEqual(wait.step(after: .read(pullRequest(41, "CLOSED"))), .fail(.closedUnmerged(number: 41)))
        for state in ["OPEN", "MERGED", "CLOSED"] {
            var other = self.wait(pullRequest: recorded)
            XCTAssertEqual(other.step(after: .read(pullRequest(42, state))), .lookUp, "#42 \(state): #41 is asked about")
            XCTAssertEqual(other.awaited.pullRequest, recorded)
            XCTAssertEqual(other.step(after: .lookedUp(found(42, state), awaitedGone: true)), .lookUp, "close_task's word on another one")
        }
        var unrecorded = self.wait()
        XCTAssertEqual(unrecorded.step(after: .read(pullRequest(41, "CLOSED"))), .fail(.closedUnmerged(number: 41)))
    }

    func testAReadWithoutThePullRequestAsksGitHubAboutTheRecordedOne() {
        var recordedWait = wait(pullRequest: recorded)
        XCTAssertEqual(recordedWait.step(after: .read(nil)), .lookUp)
        var unrecorded = wait()
        XCTAssertEqual(unrecorded.step(after: .read(nil)), .keep, "no branch look-up: a reused branch name has old pull requests")
    }

    func testTheTaskClosingAsksGitHubOrFails() {
        var recordedWait = wait(pullRequest: recorded)
        XCTAssertEqual(recordedWait.step(after: .gone), .lookUp)
        var unrecorded = wait()
        XCTAssertEqual(unrecorded.step(after: .gone), .fail(.closedFirst(number: nil)))
    }

    func testWhatGitHubSays() {
        func step(_ answer: MergeWait.LookedUp?, gone: Bool) -> (MergeWait.Step, MergeWait.PullRequest?) {
            var wait = wait()
            return (wait.step(after: .lookedUp(answer, awaitedGone: gone)), wait.awaited.pullRequest)
        }
        XCTAssertEqual(step(found(41, "MERGED"), gone: true).0, .release)
        XCTAssertEqual(step(found(41, "CLOSED"), gone: false).0, .fail(.closedUnmerged(number: 41)))
        XCTAssertEqual(step(found(41, "OPEN"), gone: false).0, .keep)
        XCTAssertEqual(step(found(41, "OPEN"), gone: false).1, recorded, "found open: recorded")
        XCTAssertEqual(step(found(41, "OPEN"), gone: true).0, .fail(.closedFirst(number: 41)))
        XCTAssertEqual(step(nil, gone: false).0, .keep)
        XCTAssertEqual(step(nil, gone: true).0, .fail(.closedFirst(number: nil)))
    }

    /// GitHub not answering ends a wait only once its task is gone, and
    /// after a few tries.
    func testGitHubNotAnswering() {
        var wait = wait(pullRequest: recorded)
        let last = MergeWait.maxUnansweredLookUps
        XCTAssertEqual(wait.step(after: .unanswered("gh: offline", awaitedGone: false, attempt: last)), .keep)
        XCTAssertEqual(wait.step(after: .unanswered("gh: offline", awaitedGone: true, attempt: last - 1)), .keep)
        XCTAssertEqual(wait.step(after: .unanswered("gh: offline", awaitedGone: true, attempt: last)), .fail(.unanswered("gh: offline")))
    }

    /// Merged, the wait is over: what reads say no longer counts, and it is
    /// tried for a day.
    func testAMergedWaitTakesNoMoreReadings() {
        var merged = wait(pullRequest: recorded, mergedAt: 100)
        XCTAssertEqual(merged.step(after: .read(pullRequest(41, "CLOSED"))), .keep)
        XCTAssertEqual(merged.step(after: .gone), .keep)
        XCTAssertFalse(merged.isPastDelivery(at: 100 + MergeWait.deliveryLifetime - 1))
        XCTAssertTrue(merged.isPastDelivery(at: 100 + MergeWait.deliveryLifetime))
        XCTAssertFalse(wait().isPastDelivery(at: .greatestFiniteMagnitude))
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
        let waits = [wait(pullRequest: recorded), wait(pullRequest: recorded, mergedAt: 100)]
        let saved = PersistedWorkspace(id: "b", title: "Add a filter", cwd: "/tmp", columns: [], focusedColumnIndex: 0, mergeWaits: waits)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var written = try XCTUnwrap(json["mergeWaits"] as? [[String: Any]])
        XCTAssertEqual(written.count, 2)
        var later = written[0]
        later["action"] = ["start": ["description": "a later build's action"]]
        written.append(later)
        json["mergeWaits"] = written
        let restored = try JSONDecoder().decode(PersistedWorkspace.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.mergeWaits, waits)
        json["mergeWaits"] = "not a list"
        let unreadable = try JSONDecoder().decode(PersistedWorkspace.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(unreadable.mergeWaits)
        let none = PersistedWorkspace(id: "c", title: "c", cwd: "/tmp", columns: [], focusedColumnIndex: 0)
        let empty = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(none)) as? [String: Any])
        XCTAssertNil(empty["mergeWaits"], "nothing written without waits")
    }

    func testTheRowSaysWhatItHolds() {
        XCTAssertNil(SidebarHeldMessages([]))
        let one = SidebarHeldMessages([wait(pullRequest: recorded)])
        XCTAssertEqual(one?.line, "After #41 merges · a message from the Lead")
        XCTAssertEqual(one?.tooltip, "Typed as the Lead's message once #41 (“Fix login”) merges: “merge origin/main”")
        var other = wait()
        other.awaited = MergeWait.Awaited(workspaceID: "c", title: "Add a filter")
        let merged = wait(pullRequest: recorded, mergedAt: 100)
        XCTAssertEqual(
            SidebarHeldMessages([wait(pullRequest: recorded), wait(pullRequest: recorded), other, merged])?.line,
            "After #41, “Add a filter” merge · 3 messages from the Lead",
            "those still waiting first"
        )
        XCTAssertEqual(SidebarHeldMessages([merged])?.line, "#41 merged · a message from the Lead waits to go")
    }

    /// A sub-task's row keeps its indent over the line: it asks nothing.
    @MainActor
    func testANestedRowKeepsItsIndentOverItsHeldLine() throws {
        var info = WorkspaceInfo(
            id: "b", index: 1, title: "Add a filter", profileID: "space", isInactive: false, columnCount: 0, focusedColumn: 0,
            gitBranch: nil, notification: nil, isActive: false, columns: [], prInfo: nil, diffStats: nil, purpose: nil,
            nextStep: nil, blocker: nil, phase: .active, lastSummary: nil, lastActivityAt: nil
        )
        info.parentTitle = "Fix login"
        let held = try XCTUnwrap(SidebarHeldMessages([wait(pullRequest: recorded)]))
        info.heldMessages = held
        XCTAssertEqual(info.cardActions, [.heldMessages(held)])
        XCTAssertEqual(
            SidebarCardLayout(workspace: info, sidebarWidth: 260).cardX,
            SidebarExpandedMetrics.workspaceInsetX + SidebarExpandedMetrics.nestIndent
        )
    }
}
