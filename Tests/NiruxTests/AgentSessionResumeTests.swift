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
        checkable: Set<String> = []
    ) -> Result<AgentSessionResume.Plan, AgentSessionResume.Unavailable> {
        AgentSessionResume.plan(for: record, probe: AgentSessionResume.Probe(
            directoryExists: { existing.contains($0) },
            fileExists: { existing.contains($0) },
            currentBranch: { branches[$0] },
            canCheckOut: { mainCheckout, ref in
                XCTAssertEqual(mainCheckout, "/repos/app")
                return checkable.contains(ref)
            }
        ))
    }

    func testASessionResumesInItsOwnFolderWhileItExists() throws {
        let existing: Set<String> = ["/claude/projects/x/s1.jsonl", "/repos/app.feat-x"]
        let original = try plan(record(), existing: existing, branches: ["/repos/app.feat-x": "feat/x"]).get()
        XCTAssertEqual(original, AgentSessionResume.Plan(place: .original, directory: "/repos/app.feat-x", warning: nil))

        // A subfolder it moved into is gone, the worktree isn't.
        XCTAssertEqual(try plan(record(cwd: "/repos/app.feat-x/gone"), existing: existing).get().directory, "/repos/app.feat-x")

        // The folder now has another branch checked out.
        let moved = try plan(record(), existing: existing, branches: ["/repos/app.feat-x": "main"]).get()
        XCTAssertEqual(moved.place, .original)
        XCTAssertEqual(moved.warning, "The session ran on branch feat/x; /repos/app.feat-x now has main checked out.")
    }

    func testAGoneWorktreeComesBackAtTheSamePathFromItsBranchOrItsLastCommit() throws {
        let fromBranch = try plan(record(), checkable: ["feat/x", checkout.head!]).get()
        XCTAssertEqual(fromBranch.place, .recreatedWorktree(mainCheckout: "/repos/app", ref: "feat/x"))
        XCTAssertEqual(fromBranch.directory, "/repos/app.feat-x")
        XCTAssertNil(fromBranch.warning)

        // The branch was deleted after its merge.
        let fromCommit = try plan(record(), checkable: [checkout.head!]).get()
        XCTAssertEqual(fromCommit.place, .recreatedWorktree(mainCheckout: "/repos/app", ref: "0123456789abcdef0123"))
        XCTAssertEqual(fromCommit.directory, "/repos/app.feat-x")
        XCTAssertTrue(try XCTUnwrap(fromCommit.warning).contains("0123456789ab"))
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
