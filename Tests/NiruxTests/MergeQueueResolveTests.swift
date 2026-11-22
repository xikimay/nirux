import XCTest
@testable import Nirux

final class MergeQueueResolveTests: XCTestCase {
    private func conflict(_ saved: MergeQueue.SavedQueue) -> MergeQueue.Conflict? {
        MergeQueue.Conflict(saved: saved, repository: MQ.widgets, dryRun: false)
    }

    func testPromptUsesTheExactBaseOrRefusesIt() {
        var saved = MQ.stoppedConflict()
        for base in ["main", "release/v2.1-rc_2"] {
            saved.baseBranch = base
            XCTAssertEqual(conflict(saved)?.prompt, "PR #12 conflicts with `\(base)`. Run `git pull`, then `git merge origin/\(base)`, "
                + "resolve the conflicts, run the tests, commit and push. Don't rebase or force-push.")
        }
        for base in ["", " main", "HEAD", "-b", "refs/heads/main", "a..b", ".hide/x", "x.lock", "a//b",
                     "a;b", "a`b", "$(date)", "a'b", "a\nb", "x\u{1b}", "x\u{202E}main"] {
            saved.baseBranch = base
            XCTAssertNil(conflict(saved)?.prompt, base.debugDescription)
        }
    }

    func testOnlyTheCurrentStoppedConflictInThisRepositoryQualifies() {
        let stopped = MQ.stoppedConflict()
        XCTAssertNotNil(conflict(stopped))
        XCTAssertNil(MergeQueue.Conflict(saved: stopped, repository: MQ.widgets, dryRun: true))
        for status in [MergeQueue.SavedQueue.Status.running, .stopping, .finished] {
            var saved = stopped
            saved.status = status
            XCTAssertNil(conflict(saved))
        }
        for current in [nil, -1, 1] as [Int?] {
            var saved = stopped
            saved.current = current
            XCTAssertNil(conflict(saved))
        }
        XCTAssertNil(conflict(MQ.stoppedConflict(number: 0)))
        XCTAssertNil(conflict(MQ.stoppedConflict(branch: "")))
        var saved = stopped
        saved.entries[0].step = .done
        XCTAssertNil(conflict(saved))
        saved = stopped
        saved.stopReason = .init(kind: .checks, message: "conflict")
        XCTAssertNil(conflict(saved))
        saved = stopped
        saved.repository = "acme/other"
        XCTAssertNil(conflict(saved))
    }

    func testBranchMustBeCheckedOutInALiveWorktreeOfThisRepository() throws {
        let conflict = try XCTUnwrap(conflict(MQ.stoppedConflict()))
        let local = ProjectBoard.LocalSnapshot(repositories: [
            .init(worktrees: [.init(path: "/other", branch: conflict.branch)], remotes: [.init(owner: "other", name: "widgets")]),
            .init(worktrees: [.init(path: "/main", branch: "main"), .init(path: "/gone", branch: conflict.branch, isPrunable: true),
                              .init(path: "/login", branch: conflict.branch)], remotes: [MQ.widgets])
        ])
        XCTAssertEqual(conflict.worktrees(in: local, repository: MQ.widgets), ["/login"])
        XCTAssertEqual(conflict.worktrees(in: .init(), repository: MQ.widgets), [])
    }

    @MainActor
    func testOnlyForegroundEmptyIdlePromptsAreOfferedInColumnOrder() throws {
        let conflict = try XCTUnwrap(conflict(MQ.stoppedConflict()))
        typealias Column = NiruxShellView.ReviewSendColumn
        func column(_ refusal: ReviewSendRefusal? = nil, draft: Bool = false, foreground: Bool = true) -> Column {
            Column(workspaceID: "login", columnID: UUID(), label: "Agent", refusal: refusal, hasDraft: draft,
                   process: foreground ? .init(pid: 123, startedAt: 10) : nil)
        }
        let first = column(), second = column()
        for blocked in [column(.notInFront), column(.working), column(.dialog), column(draft: true), column(foreground: false)] {
            guard case .blocked(let why) = NiruxShellView.QueueResolution.offer(conflict, columns: [blocked]) else {
                return XCTFail("Offered a blocked column")
            }
            XCTAssertFalse(why.isEmpty)
            XCTAssertEqual(NiruxShellView.QueueResolution.offer(conflict, columns: [first, blocked, second]), .ready(conflict, [first, second]))
        }
        guard case .blocked = NiruxShellView.QueueResolution.offer(conflict, columns: []) else { return XCTFail("No agent") }
    }
}
