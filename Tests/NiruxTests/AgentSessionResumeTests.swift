import XCTest
@testable import Nirux

/// Where a recorded session resumes once its worktree may be gone (see
/// AgentSessionResume).
final class AgentSessionResumeTests: XCTestCase {
    private let checkout = AgentSessionRecord.Checkout(
        branch: "feat/x", worktreeRoot: "/repos/app.feat-x", mainCheckout: "/repos/app", repository: nil,
        head: "0123456789abcdef0123"
    )

    private func record(
        agent: AgentHookEvent.Kind = .claude, cwd: String? = "/repos/app.feat-x",
        hasConversation: Bool = true, transcriptPath: String? = "/claude/projects/x/s1.jsonl"
    ) -> AgentSessionRecord {
        var record = AgentSessionRecord(
            schemaVersion: 1, agent: agent, sessionID: "s1", startedAt: 1, lastStartAt: 1,
            lastActivityAt: 2, endedAt: 2, status: .idle, hasConversation: hasConversation
        )
        record.cwd = cwd
        record.checkout = checkout
        record.transcriptPath = agent == .claude ? transcriptPath : nil
        return record
    }

    private func plan(
        _ record: AgentSessionRecord,
        existing: Set<String> = ["/claude/projects/x/s1.jsonl", "/repos/app"],
        branches: [String: String] = [:],
        worktrees: [GitWorktree.WorktreeEntry] = [],
        localBranches: Set<String> = [],
        commits: Set<String> = []
    ) -> Result<AgentSessionResume.Plan, AgentSessionResume.Unavailable> {
        AgentSessionResume.plan(for: record, probe: AgentSessionResume.Probe(
            directoryExists: { existing.contains($0) },
            fileExists: { existing.contains($0) },
            currentBranch: { branches[$0] },
            worktrees: { mainCheckout in
                XCTAssertEqual(mainCheckout, "/repos/app")
                return worktrees
            },
            hasBranch: { _, branch in localBranches.contains(branch) },
            hasCommit: { _, commit in commits.contains(commit) }
        ))
    }

    private let mainEntry = GitWorktree.WorktreeEntry(path: "/repos/app", branch: "main")

    func testASessionResumesAtTheTopOfItsCheckoutWhileItExists() throws {
        let existing: Set<String> = ["/claude/projects/x/s1.jsonl", "/repos/app.feat-x"]
        let original = try plan(record(), existing: existing, branches: ["/repos/app.feat-x": "feat/x"]).get()
        XCTAssertEqual(original, AgentSessionResume.Plan(place: .original, directory: "/repos/app.feat-x", warning: nil))

        // A subfolder it moved into is gone, the worktree isn't.
        XCTAssertEqual(try plan(record(cwd: "/repos/app.feat-x/gone"), existing: existing).get().directory, "/repos/app.feat-x")

        // The folder now has another branch checked out, seen from the top
        // even when the agent last worked in a subfolder.
        let inSubfolder = try plan(
            record(cwd: "/repos/app.feat-x/web"), existing: existing.union(["/repos/app.feat-x/web"]),
            branches: ["/repos/app.feat-x": "main"]
        ).get()
        XCTAssertEqual(inSubfolder, AgentSessionResume.Plan(
            place: .original, directory: "/repos/app.feat-x",
            warning: "The session ran on branch feat/x; /repos/app.feat-x now has main checked out."
        ))
    }

    func testAGoneWorktreeComesBackAtTheSamePathFromItsBranchOrItsLastCommit() throws {
        let head = try XCTUnwrap(checkout.head)
        let fromBranch = try plan(record(), worktrees: [mainEntry], localBranches: ["feat/x"], commits: [head]).get()
        XCTAssertEqual(fromBranch, AgentSessionResume.Plan(
            place: .recreatedWorktree(mainCheckout: "/repos/app", ref: "feat/x"), directory: "/repos/app.feat-x", warning: nil
        ))

        // The branch was deleted after its merge.
        let fromCommit = try plan(record(), commits: [head]).get()
        XCTAssertEqual(fromCommit.place, .recreatedWorktree(mainCheckout: "/repos/app", ref: head))
        XCTAssertEqual(fromCommit.directory, "/repos/app.feat-x")
        XCTAssertTrue(try XCTUnwrap(fromCommit.warning).hasPrefix("The branch feat/x no longer exists"))

        // It ran detached: it comes back as it was.
        var detached = record()
        detached.checkout?.branch = "HEAD"
        XCTAssertNil(try plan(detached, localBranches: ["HEAD"], commits: [head]).get().warning)
    }

    /// Nirux's clean-up leaves no entry behind: a folder git still lists
    /// was moved or is on a disk that isn't mounted.
    func testAFolderGitStillListsComesBackOnlyAfterAWarning() throws {
        let stale = GitWorktree.WorktreeEntry(path: "/repos/app.feat-x", branch: "feat/x")
        let vanished = try plan(record(), worktrees: [mainEntry, stale], localBranches: ["feat/x"]).get()
        XCTAssertEqual(vanished.place, .recreatedWorktree(mainCheckout: "/repos/app", ref: "feat/x"))
        XCTAssertTrue(try XCTUnwrap(vanished.warning).hasPrefix("Git still lists /repos/app.feat-x"))

        // Locked: git won't replace it.
        var locked = stale
        locked.isLocked = true
        let main = try plan(record(), worktrees: [mainEntry, locked], localBranches: ["feat/x"], commits: [checkout.head!]).get()
        XCTAssertEqual(main.place, .mainCheckout)
    }

    func testAMovedWorktreeIsWhereTheSessionResumes() throws {
        let moved = GitWorktree.WorktreeEntry(path: "/repos/elsewhere", branch: "feat/x")
        let there = try plan(
            record(), existing: ["/claude/projects/x/s1.jsonl", "/repos/app", "/repos/elsewhere"],
            worktrees: [mainEntry, moved], localBranches: ["feat/x"]
        ).get()
        XCTAssertEqual(there.place, .branchCheckout)
        XCTAssertEqual(there.directory, "/repos/elsewhere")
        XCTAssertTrue(try XCTUnwrap(there.warning).contains("/repos/app.feat-x"))

        // Moved in the Finder: git still gives the branch to a folder that
        // is gone, so the worktree comes back at its last commit.
        let head = try XCTUnwrap(checkout.head)
        let detached = try plan(record(), worktrees: [mainEntry, moved], localBranches: ["feat/x"], commits: [head]).get()
        XCTAssertEqual(detached.place, .recreatedWorktree(mainCheckout: "/repos/app", ref: head))
        XCTAssertTrue(try XCTUnwrap(detached.warning).contains("/repos/elsewhere"))
    }

    func testWithNeitherASessionResumesInTheMainCheckoutWithAWarning() throws {
        let main = try plan(record()).get()
        XCTAssertEqual(main.place, .mainCheckout)
        XCTAssertEqual(main.directory, "/repos/app")
        let warning = try XCTUnwrap(main.warning)
        XCTAssertTrue(warning.contains("/repos/app.feat-x"))
        XCTAssertTrue(warning.contains("feat/x"))
    }

    func testWhatCannotBeResumed() {
        XCTAssertEqual(plan(record(hasConversation: false)), .failure(.noConversation))
        XCTAssertEqual(plan(record(), existing: ["/repos/app"]), .failure(.transcriptGone))
        XCTAssertEqual(plan(record(), existing: ["/claude/projects/x/s1.jsonl"]), .failure(.noFolder))
        var noCheckout = record()
        noCheckout.checkout = nil
        XCTAssertEqual(plan(noCheckout), .failure(.noFolder))
        // A session of the main checkout itself has nowhere else to go.
        var inMain = record(cwd: "/repos/app")
        inMain.checkout?.worktreeRoot = "/repos/app"
        XCTAssertEqual(plan(inMain, existing: ["/claude/projects/x/s1.jsonl"]), .failure(.noFolder))
    }

    /// `-C` follows the thread id: restore proves a Codex column by the
    /// argument right after `resume`.
    @MainActor
    func testCodexResumesInTheChosenFolderAndRestoreStillProvesIt() {
        XCTAssertEqual(
            NiruxShellView.codexCommand(resume: .session("t1"), workingDirectory: "/repos/it's", mode: .default),
            "command codex resume 't1' -C '/repos/it'\\''s'"
        )
        var tracker = CodexSessionTracker()
        tracker.prepareResume(sessionID: "t1")
        let codex = ForegroundProcess(
            instance: ProcessInstance(pid: 10, startedAt: 1), name: "codex",
            arguments: ["codex", "resume", "t1", "-C", "/repos/app"]
        )
        XCTAssertEqual(tracker.sessionID(for: codex), "t1")
    }
}
