import XCTest
@testable import Nirux

/// How one hook event changes a session's record (see
/// `AgentSessionRecord.applying`).
final class AgentSessionRecordTests: XCTestCase {
    private let agent = ProcessInstance(pid: 4242, startedAt: 1000)

    private func observation(
        _ event: AgentHookEvent.Name,
        at timestamp: TimeInterval,
        source: String? = nil,
        fromColumnAgent: Bool = true,
        agentUUID: String? = "column-1",
        name: String? = nil,
        transcriptPath: String? = nil,
        checkout: AgentSessionRecord.Checkout? = nil,
        pullRequest: AgentSessionRecord.PullRequest? = nil
    ) -> AgentSessionObservation {
        AgentSessionObservation(
            agent: .claude, sessionID: "s1", event: event, source: source, timestamp: timestamp,
            agentProcess: fromColumnAgent ? agent : nil, name: name, cwd: "/repo", transcriptPath: transcriptPath,
            checkout: checkout, pullRequest: pullRequest, workspaceID: "ws-1", workspaceTitle: "feat/x",
            agentUUID: agentUUID, columnIndex: 0
        )
    }

    private func apply(_ observations: [AgentSessionObservation], to record: AgentSessionRecord? = nil) -> AgentSessionRecord? {
        observations.reduce(record) { current, next in AgentSessionRecord.applying(next, to: current) ?? current }
    }

    func testOnlyTheColumnsAgentCreatesARecord() throws {
        XCTAssertNil(AgentSessionRecord.applying(observation(.sessionStart, at: 10, fromColumnAgent: false), to: nil))
        // A straggling end never creates one either.
        XCTAssertNil(AgentSessionRecord.applying(observation(.sessionEnd, at: 10), to: nil))

        let record = try XCTUnwrap(AgentSessionRecord.applying(
            observation(.sessionStart, at: 10, source: "startup", name: "feat/x · nirux"), to: nil
        ))
        XCTAssertEqual(record.key, "claude:s1")
        XCTAssertEqual(record.name, "feat/x · nirux")
        XCTAssertEqual(record.startedAt, 10)
        XCTAssertEqual(record.status, .started)
        XCTAssertFalse(record.hasConversation)
        XCTAssertTrue(record.isActive)
        XCTAssertEqual(record.agentUUID, "column-1")
    }

    func testTurnsDriveTheStatusAndTheConversation() throws {
        let started = try XCTUnwrap(apply([observation(.sessionStart, at: 10, source: "startup")]))
        let working = try XCTUnwrap(apply([observation(.userPromptSubmit, at: 11)], to: started))
        XCTAssertEqual(working.status, .working)
        XCTAssertTrue(working.hasConversation)
        let waiting = try XCTUnwrap(apply([observation(.permissionRequest, at: 12)], to: working))
        XCTAssertEqual(waiting.status, .waiting)
        XCTAssertEqual(apply([observation(.postToolUse, at: 13)], to: waiting)?.status, .working)
        XCTAssertEqual(apply([observation(.stop, at: 14)], to: working)?.status, .idle)
        XCTAssertEqual(apply([observation(.stopFailure, at: 14)], to: working)?.status, .failed)
        // Tool calls that asked nothing, and notifications, aren't recorded:
        // they would write a line each.
        XCTAssertNil(AgentSessionRecord.applying(observation(.postToolUse, at: 15), to: working))
        XCTAssertNil(AgentSessionRecord.applying(observation(.preToolUse, at: 15), to: working))
        XCTAssertNil(AgentSessionRecord.applying(observation(.notification, at: 15), to: working))
    }

    func testAStartBySourceSaysWhetherThereIsAConversation() throws {
        for (source, hasConversation, status) in [
            ("startup", false, AgentSessionRecord.Status.started),
            ("clear", false, .started),
            ("resume", true, .idle),
            ("compact", true, .started),
            ("fork", true, .started)
        ] {
            let record = try XCTUnwrap(apply([observation(.sessionStart, at: 10, source: source)]), source)
            XCTAssertEqual(record.hasConversation, hasConversation, source)
            XCTAssertEqual(record.status, status, source)
        }
    }

    func testAnOlderReplayDoesNotOverwriteTheStatus() throws {
        let idle = try XCTUnwrap(apply([
            observation(.sessionStart, at: 10, source: "startup"),
            observation(.userPromptSubmit, at: 11),
            observation(.stop, at: 20)
        ]))
        let replayed = try XCTUnwrap(apply([observation(.userPromptSubmit, at: 15)], to: idle))
        XCTAssertEqual(replayed.status, .idle)
        XCTAssertEqual(replayed.lastActivityAt, 20)
    }

    func testOtherEventsOnlyUpdateTheOpenRecordOfTheSameColumn() throws {
        let open = try XCTUnwrap(apply([
            observation(.sessionStart, at: 10, source: "startup"),
            observation(.userPromptSubmit, at: 11)
        ]))
        // Another column reporting the same id, or an event from before the
        // current run, is ignored.
        XCTAssertNil(AgentSessionRecord.applying(observation(.stop, at: 12, fromColumnAgent: false, agentUUID: "column-2"), to: open))
        XCTAssertNil(AgentSessionRecord.applying(observation(.stop, at: 12, fromColumnAgent: false, agentUUID: nil), to: open))
        XCTAssertNil(AgentSessionRecord.applying(observation(.stop, at: 9, fromColumnAgent: false), to: open))

        let ended = try XCTUnwrap(apply([observation(.sessionEnd, at: 30, fromColumnAgent: false)], to: open))
        XCTAssertEqual(ended.endedAt, 30)
        XCTAssertEqual(ended.status, .working, "an ended session keeps the status it ended with")
    }

    func testAnEndedRecordReopensOnlyForItsAgentsNewerEvents() throws {
        var ended = try XCTUnwrap(apply([
            observation(.sessionStart, at: 10, source: "startup"),
            observation(.userPromptSubmit, at: 11)
        ]))
        ended.endedAt = 20
        // A replay only corrects when it ended.
        XCTAssertNil(AgentSessionRecord.applying(observation(.stop, at: 40, fromColumnAgent: false), to: ended))
        XCTAssertEqual(apply([observation(.sessionEnd, at: 40, fromColumnAgent: false)], to: ended)?.endedAt, 40)
        // From before the end: not a resume. Unless it is a start: the
        // previous agent's exit may have been noticed before it was drained.
        XCTAssertNil(AgentSessionRecord.applying(observation(.stop, at: 15), to: ended))
        XCTAssertNil(apply([observation(.sessionStart, at: 15, source: "resume")], to: ended)?.endedAt)

        let resumed = try XCTUnwrap(apply([observation(.sessionStart, at: 50, source: "resume")], to: ended))
        XCTAssertNil(resumed.endedAt)
        XCTAssertEqual(resumed.startedAt, 10)
        XCTAssertEqual(resumed.lastStartAt, 50)
        XCTAssertEqual(resumed.status, .idle)
        // The end of the previous run, drained late, belongs to it, whoever
        // reports it.
        XCTAssertNil(AgentSessionRecord.applying(observation(.sessionEnd, at: 45, fromColumnAgent: false), to: resumed))
        XCTAssertNil(AgentSessionRecord.applying(observation(.sessionEnd, at: 45), to: resumed))
        // A compaction goes on with the same run.
        XCTAssertEqual(apply([observation(.sessionStart, at: 60, source: "compact")], to: resumed)?.lastStartAt, 50)
    }

    func testTheTranscriptComesFromTheTurnsNotFromAResumesStart() throws {
        let original = "/claude/projects/-repos-app-feat-x/s1.jsonl"
        let started = try XCTUnwrap(apply([observation(.sessionStart, at: 10, source: "startup", transcriptPath: original)]))
        XCTAssertEqual(started.transcriptPath, original)
        // Resumed from the main checkout: the start names a file that
        // doesn't exist.
        let elsewhere = "/claude/projects/-repos-app/s1.jsonl"
        let resumed = try XCTUnwrap(apply([observation(.sessionStart, at: 20, source: "resume", transcriptPath: elsewhere)], to: started))
        XCTAssertEqual(resumed.transcriptPath, original)
        let unknown = try XCTUnwrap(apply([observation(.sessionStart, at: 20, source: "resume", transcriptPath: elsewhere)]))
        XCTAssertNil(unknown.transcriptPath)
        XCTAssertEqual(apply([observation(.stop, at: 21, transcriptPath: original)], to: unknown)?.transcriptPath, original)
    }

    func testAnotherBranchForgetsThePreviousPullRequest() throws {
        let branchA = AgentSessionRecord.Checkout(branch: "a", worktreeRoot: "/wt", mainCheckout: "/repo", repository: nil, head: "1")
        var branchB = branchA
        branchB.branch = "b"
        let pullRequest = AgentSessionRecord.PullRequest(number: 1, url: "u", state: "OPEN")
        let onA = try XCTUnwrap(apply([observation(.sessionStart, at: 10, source: "startup", checkout: branchA, pullRequest: pullRequest)]))
        XCTAssertEqual(onA.pullRequest, pullRequest)
        var newCommit = branchA
        newCommit.head = "2"
        XCTAssertEqual(apply([observation(.stop, at: 11, checkout: newCommit)], to: onA)?.pullRequest, pullRequest)
        let onB = try XCTUnwrap(apply([observation(.stop, at: 12, checkout: branchB)], to: onA))
        XCTAssertNil(onB.pullRequest)
    }

    /// A Resume brings a cleaned-up session back detached, or in the main
    /// checkout: it keeps its branch, pull request and worktree.
    func testAResumedSessionKeepsItsBranchPullRequestAndWorktree() throws {
        let worktree = AgentSessionRecord.Checkout(branch: "feat/x", worktreeRoot: "/wt", mainCheckout: "/repo", head: "1")
        let pullRequest = AgentSessionRecord.PullRequest(number: 7, url: "u", state: "MERGED")
        let record = try XCTUnwrap(apply([observation(.stop, at: 10, checkout: worktree, pullRequest: pullRequest)], to: apply([
            observation(.sessionStart, at: 9, source: "startup")
        ])))

        var detached = worktree
        detached.branch = "HEAD"
        detached.head = "2"
        let back = try XCTUnwrap(apply([observation(.stop, at: 11, checkout: detached)], to: record))
        XCTAssertEqual(back.checkout?.branch, "feat/x")
        XCTAssertEqual(back.checkout?.head, "2")
        XCTAssertEqual(back.pullRequest, pullRequest)

        let main = AgentSessionRecord.Checkout(branch: "main", worktreeRoot: "/repo", mainCheckout: "/repo", head: "3")
        let inMain = try XCTUnwrap(apply([observation(.stop, at: 12, checkout: main)], to: record))
        XCTAssertEqual(inMain.checkout, worktree)
        XCTAssertEqual(inMain.pullRequest, pullRequest)

        // Another worktree is another checkout.
        let other = AgentSessionRecord.Checkout(branch: "HEAD", worktreeRoot: "/wt2", mainCheckout: "/repo", head: "4")
        XCTAssertEqual(apply([observation(.stop, at: 13, checkout: other)], to: record)?.checkout, other)
    }

    func testLaunchName() {
        XCTAssertEqual(AgentSessionObservation.launchName(arguments: ["claude", "--name=feat/x · nirux"]), "feat/x · nirux")
        XCTAssertEqual(AgentSessionObservation.launchName(arguments: ["claude", "--model", "opus", "--name", "a"]), "a")
        XCTAssertEqual(AgentSessionObservation.launchName(arguments: ["claude", "-n", "b", "prompt"]), "b")
        XCTAssertNil(AgentSessionObservation.launchName(arguments: ["claude", "--resume", "id"]))
        XCTAssertNil(AgentSessionObservation.launchName(arguments: ["claude", "--name"]))
        XCTAssertNil(AgentSessionObservation.launchName(arguments: ["claude", "--name=  "]))
        // After `--`, everything is the prompt.
        XCTAssertNil(AgentSessionObservation.launchName(arguments: ["claude", "--", "-n", "x"]))
    }

    func testCheckoutsOnDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-main-checkout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default
        // The files git writes, without running git.
        let main = root.appendingPathComponent("repo", isDirectory: true)
        try fileManager.createDirectory(at: main.appendingPathComponent(".git/worktrees/wt"), withIntermediateDirectories: true)
        try Data("../..\n".utf8).write(to: main.appendingPathComponent(".git/worktrees/wt/commondir"))
        let worktree = root.appendingPathComponent("wt", isDirectory: true)
        try fileManager.createDirectory(at: worktree.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try Data("gitdir: \(main.path)/.git/worktrees/wt\n".utf8).write(to: worktree.appendingPathComponent(".git"))
        let bare = root.appendingPathComponent("bare.git", isDirectory: true)
        try fileManager.createDirectory(at: bare.appendingPathComponent("worktrees/b"), withIntermediateDirectories: true)
        try Data("../..\n".utf8).write(to: bare.appendingPathComponent("worktrees/b/commondir"))
        let bareWorktree = root.appendingPathComponent("b", isDirectory: true)
        try fileManager.createDirectory(at: bareWorktree, withIntermediateDirectories: true)
        try Data("gitdir: \(bare.path)/worktrees/b\n".utf8).write(to: bareWorktree.appendingPathComponent(".git"))
        // A worktree nested in the main checkout (`claude --worktree`).
        let nested = main.appendingPathComponent(".claude/worktrees/feat", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("gitdir: \(main.path)/.git/worktrees/feat\n".utf8).write(to: nested.appendingPathComponent(".git"))

        let mainPath = GitRepositoryLayout.canonicalPath(main.path)
        XCTAssertEqual(AgentSessionRecord.mainCheckout(ofWorktreeAt: main.path), mainPath)
        XCTAssertEqual(AgentSessionRecord.mainCheckout(ofWorktreeAt: worktree.path), mainPath)
        XCTAssertNil(AgentSessionRecord.mainCheckout(ofWorktreeAt: bareWorktree.path))
        XCTAssertNil(AgentSessionRecord.mainCheckout(ofWorktreeAt: root.path))

        XCTAssertEqual(AgentSessionRecord.checkoutRoot(containing: worktree.appendingPathComponent("Sources").path), worktree.path)
        XCTAssertEqual(AgentSessionRecord.checkoutRoot(containing: nested.path), nested.path)
        XCTAssertEqual(AgentSessionRecord.checkoutRoot(containing: main.path), main.path)
    }
}
