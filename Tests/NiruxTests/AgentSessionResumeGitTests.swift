import XCTest
@testable import Nirux

/// What a Resume asks of git, on a real repository: which branch or commit
/// can bring a removed worktree back, and bringing it back.
final class AgentSessionResumeGitTests: XCTestCase {
    private var root = ""
    private var repo: String { root + "/app" }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.path.realPath ?? base.path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        // Worktrees made by the code under test run no hook of the developer's.
        try git(["config", "core.hooksPath", "/dev/null"])
        try git(["commit", "-q", "--allow-empty", "-m", "init"])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    @discardableResult
    private func git(_ arguments: [String], at directory: String? = nil) throws -> String {
        let pinned = ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"]
        let result = GitWorktree.gitRunFull(pinned + arguments, cwd: directory ?? repo, timeout: 30)
        guard result.status == 0 else {
            throw NSError(domain: "git", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.stderr])
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testTheProbeReadsBranchesCommitsAndLocks() throws {
        let worktree = root + "/app.feat-x"
        try git(["worktree", "add", "-q", "-b", "feat/x", worktree])
        try git(["worktree", "lock", worktree])
        let head = try git(["rev-parse", "HEAD"])
        let probe = AgentSessionResume.Probe.onDisk()

        XCTAssertTrue(probe.hasBranch(repo, "feat/x"))
        XCTAssertFalse(probe.hasBranch(repo, "feat/none"))
        XCTAssertFalse(probe.hasBranch(repo, "-b"))
        XCTAssertTrue(probe.hasCommit(repo, head))
        XCTAssertFalse(probe.hasCommit(repo, String(repeating: "0", count: 40)))
        XCTAssertFalse(probe.hasCommit(repo, "HEAD~1"), "not a commit id")
        let entry = try XCTUnwrap(probe.worktrees(repo).first { $0.branch == "feat/x" })
        XCTAssertTrue(entry.isLocked)
        XCTAssertFalse(try XCTUnwrap(probe.worktrees(repo).first).isLocked)
    }

    /// Never a repository-wide prune: a worktree moved in the Finder, or on
    /// a disk that isn't mounted, would lose its entry and break.
    func testBringingAWorktreeBackLeavesTheOtherMissingOnesAlone() throws {
        let worktree = root + "/app.feat-x"
        let deleted = root + "/app.feat-d"
        let moved = root + "/app.feat-m"
        for (branch, path) in [("feat/x", worktree), ("feat/d", deleted), ("feat/m", moved)] {
            try git(["worktree", "add", "-q", "-b", branch, path])
        }
        try FileManager.default.removeItem(atPath: worktree)
        try FileManager.default.removeItem(atPath: deleted)
        try FileManager.default.moveItem(atPath: moved, toPath: root + "/elsewhere")

        XCTAssertEqual(AgentSessionResume.recreateWorktree(at: worktree, ref: "feat/x", mainCheckout: repo), .done)
        XCTAssertEqual(GitWorktree.currentBranch(at: worktree), "feat/x")
        // Back already: another Resume of the same worktree.
        XCTAssertEqual(AgentSessionResume.recreateWorktree(at: worktree, ref: "feat/x", mainCheckout: repo), .alreadyBack)
        let listed = GitWorktree.list(repoRoot: repo).map(\.path)
        XCTAssertTrue(listed.contains { AgentSessionResume.isSamePath($0, deleted) }, "\(listed)")
        XCTAssertTrue(listed.contains { AgentSessionResume.isSamePath($0, moved) }, "\(listed)")
        XCTAssertEqual(try git(["rev-parse", "--abbrev-ref", "HEAD"], at: root + "/elsewhere"), "feat/m")
    }

    func testACommitComesBackDetachedOnceItsBranchIsGone() throws {
        let worktree = root + "/app.feat-y"
        try git(["worktree", "add", "-q", "-b", "feat/y", worktree])
        try git(["commit", "-q", "--allow-empty", "-m", "work"], at: worktree)
        let head = try git(["rev-parse", "HEAD"], at: worktree)
        try git(["worktree", "remove", "--force", worktree])
        try git(["branch", "-q", "-D", "feat/y"])

        XCTAssertEqual(AgentSessionResume.recreateWorktree(at: worktree, ref: head, mainCheckout: repo), .done)
        XCTAssertNil(GitWorktree.currentBranch(at: worktree))
        XCTAssertEqual(try git(["rev-parse", "HEAD"], at: worktree), head)
    }

    func testARecreationRefusesALockedEntryOrABranchCheckedOutElsewhere() throws {
        let locked = root + "/app.feat-l"
        try git(["worktree", "add", "-q", "-b", "feat/l", locked])
        try git(["worktree", "lock", locked])
        try FileManager.default.removeItem(atPath: locked)
        XCTAssertEqual(
            AgentSessionResume.recreateWorktree(at: locked, ref: "feat/l", mainCheckout: repo),
            .failed("git keeps \(locked) locked (git worktree unlock)")
        )

        let busy = root + "/app.feat-b"
        try git(["worktree", "add", "-q", "-b", "feat/b", busy])
        XCTAssertEqual(
            AgentSessionResume.recreateWorktree(at: root + "/app.feat-b2", ref: "feat/b", mainCheckout: repo),
            .failed("feat/b is checked out in \(busy)")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/app.feat-b2"))
    }

    func testAFailedRecreationSaysWhy() {
        let worktree = root + "/app.feat-none"
        guard case .failed(let error) = AgentSessionResume.recreateWorktree(at: worktree, ref: "feat/none", mainCheckout: repo)
        else { return XCTFail("feat/none came back") }
        XCTAssertTrue(error.contains("feat/none"), error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
    }

    /// Written to after Nirux last saw the session, lately: it may run
    /// somewhere else.
    func testATranscriptChangedElsewhereIsReported() throws {
        let transcript = root + "/s1.jsonl"
        FileManager.default.createFile(atPath: transcript, contents: Data())
        let now = Date().timeIntervalSince1970
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: now - 120)], ofItemAtPath: transcript)
        var record = AgentSessionRecord(
            schemaVersion: 1, agent: .claude, sessionID: "s1", startedAt: 0, lastStartAt: 0,
            lastActivityAt: now - 600, endedAt: now - 600, status: .idle, hasConversation: true
        )
        record.transcriptPath = transcript
        XCTAssertTrue(AgentSessionResume.transcriptChangedElsewhere(record, now: now)?.hasPrefix("Its transcript changed 2 min ago") == true)
        // Claude's last lines after the turn Nirux saw end.
        record.lastActivityAt = now - 150
        XCTAssertNil(AgentSessionResume.transcriptChangedElsewhere(record, now: now))
        // Nirux ended it mid-turn (its column closed): the turn's writes
        // came before.
        record.lastActivityAt = now - 600
        record.endedAt = now - 100
        XCTAssertNil(AgentSessionResume.transcriptChangedElsewhere(record, now: now))
        // Long ago.
        record.endedAt = nil
        record.lastActivityAt = now - 3600
        XCTAssertNil(AgentSessionResume.transcriptChangedElsewhere(record, now: now + 600))
    }

    /// The probe `resumeSession` plans with, on the disk and git.
    func testThePlanOnDisk() throws {
        let worktree = root + "/app.feat-z"
        try git(["worktree", "add", "-q", "-b", "feat/z", worktree])
        try FileManager.default.createDirectory(atPath: worktree + "/web", withIntermediateDirectories: true)
        let transcript = root + "/s1.jsonl"
        FileManager.default.createFile(atPath: transcript, contents: Data())
        var record = AgentSessionRecord(
            schemaVersion: 1, agent: .claude, sessionID: "s1", startedAt: 0, lastStartAt: 0,
            lastActivityAt: 1, endedAt: 1, status: .idle, hasConversation: true
        )
        record.cwd = worktree + "/web"
        record.transcriptPath = transcript
        record.checkout = AgentSessionRecord.Checkout(branch: "feat/z", worktreeRoot: worktree, mainCheckout: repo)

        // Its folder, from a subfolder, now on another branch.
        try git(["checkout", "-q", "-b", "other"], at: worktree)
        let moved = try AgentSessionResume.plan(for: record, probe: .onDisk()).get()
        XCTAssertEqual(moved.place, .original)
        XCTAssertEqual(moved.directory, worktree)
        XCTAssertEqual(moved.warning, "The session ran on branch feat/z; \(worktree) now has other checked out.")

        // Deleted without git: it comes back, after a warning.
        try FileManager.default.removeItem(atPath: worktree)
        let vanished = try AgentSessionResume.plan(for: record, probe: .onDisk()).get()
        XCTAssertEqual(vanished.place, .recreatedWorktree(mainCheckout: repo, ref: "feat/z"))
        XCTAssertNotNil(vanished.warning)

        // Removed by git, as Nirux's clean-up does: it comes back unasked.
        try git(["worktree", "prune"])
        XCTAssertEqual(
            try AgentSessionResume.plan(for: record, probe: .onDisk()).get(),
            AgentSessionResume.Plan(place: .recreatedWorktree(mainCheckout: repo, ref: "feat/z"), directory: worktree, warning: nil)
        )
    }
}
