import XCTest
@testable import Nirux

/// Each space's session history on disk (see AgentSessionLedger), on a
/// throwaway state directory: what is kept, what is closed, and what a
/// damaged file does. Synchronous setUp and tearDown, and `@MainActor` on
/// each test: CI's Swift 6.1 rejects a main-actor class overriding them.
final class AgentSessionLedgerTests: XCTestCase {
    // The caches directory keeps file permissions through renames; /tmp
    // doesn't (see ProjectStoreTests).
    private let stateDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("nirux-sessions-\(UUID().uuidString)", isDirectory: true)
    private let process = ProcessInstance(pid: 4242, startedAt: 1000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: stateDirectory)
        super.tearDown()
    }

    @MainActor
    private func makeLedger() -> AgentSessionLedger {
        let directory = stateDirectory
        return AgentSessionLedger(stateDirectory: { directory })
    }

    private func fileURL(_ spaceID: String = "space-1") throws -> URL {
        try XCTUnwrap(AgentSessionLedger.fileURL(spaceID: spaceID, stateDirectory: stateDirectory))
    }

    private func lines(_ spaceID: String = "space-1") throws -> [String] {
        try String(contentsOf: fileURL(spaceID), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func appendRaw(_ text: String, _ spaceID: String = "space-1") throws {
        let url = try fileURL(spaceID)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func observation(
        _ event: AgentHookEvent.Name,
        session: String = "s1",
        at timestamp: TimeInterval,
        source: String? = nil,
        column: String = "column-1",
        fromColumnAgent: Bool = true,
        checkout: AgentSessionRecord.Checkout? = nil,
        agent: AgentHookEvent.Kind = .claude
    ) -> AgentSessionObservation {
        AgentSessionObservation(
            agent: agent, sessionID: session, event: event, source: source, timestamp: timestamp,
            agentProcess: fromColumnAgent ? process : nil, name: nil, cwd: "/repo", transcriptPath: nil,
            checkout: checkout, pullRequest: nil, workspaceID: "ws-1", workspaceTitle: "feat/x",
            agentUUID: column, columnIndex: 0
        )
    }

    /// A prompted session, running in `column`.
    @MainActor
    private func startSession(
        _ session: String, in ledger: AgentSessionLedger, space: String = "space-1",
        at timestamp: TimeInterval, column: String = "column-1",
        checkout: AgentSessionRecord.Checkout? = nil
    ) {
        ledger.record(
            observation(.sessionStart, session: session, at: timestamp, source: "startup", column: column, checkout: checkout),
            spaceID: space
        )
        ledger.record(observation(.userPromptSubmit, session: session, at: timestamp + 1, column: column), spaceID: space)
    }

    // MARK: - Files

    @MainActor
    func testSessionsPersistPerSpaceInAPrivateFile() throws {
        // A file left 0644 by hand is made private again.
        try appendRaw("")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL().path)
        let ledger = makeLedger()
        startSession("s1", in: ledger, at: 10)
        startSession("s2", in: ledger, space: "space-2", at: 20, column: "column-2")

        let url = try fileURL()
        XCTAssertEqual(url.path, stateDirectory.appendingPathComponent("projects/space-1/sessions.jsonl").path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try lines().count, 2, "one line per change")

        let reloaded = makeLedger()
        XCTAssertEqual(reloaded.sessions(inSpace: "space-1").map(\.sessionID), ["s1"])
        XCTAssertEqual(reloaded.sessions(inSpace: "space-2").map(\.sessionID), ["s2"])
        XCTAssertEqual(reloaded.session(agent: .claude, sessionID: "s1")?.status, .working)
    }

    @MainActor
    func testAnInvalidSpaceIDRecordsNothing() {
        let ledger = makeLedger()
        startSession("s1", in: ledger, space: "../escape", at: 10)
        XCTAssertNil(ledger.session(agent: .claude, sessionID: "s1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent("escape").path))
    }

    @MainActor
    func testARunningSessionFollowsItsWorkspaceToAnotherSpace() throws {
        let ledger = makeLedger()
        startSession("ended", in: ledger, at: 5, column: "column-2")
        ledger.closeAllSessions(at: 8)
        startSession("s1", in: ledger, at: 10)
        // The workspace moved (Move to Project, or its space was deleted).
        ledger.record(observation(.stop, at: 12), spaceID: "space-2")
        // Another column's event, not the agent's: no move.
        ledger.record(observation(.sessionEnd, session: "ended", at: 13, column: "column-2", fromColumnAgent: false), spaceID: "space-2")

        XCTAssertEqual(ledger.sessions(inSpace: "space-1").map(\.sessionID), ["ended"])
        XCTAssertEqual(ledger.sessions(inSpace: "space-2").map(\.sessionID), ["s1"])
        // The stale line left in space-1's file loses at load.
        let reloaded = makeLedger()
        XCTAssertEqual(reloaded.sessions(inSpace: "space-1").map(\.sessionID), ["ended"])
        XCTAssertEqual(reloaded.sessions(inSpace: "space-2").first?.status, .idle)
    }

    // MARK: - Open and ended sessions

    @MainActor
    func testASessionLeftOpenIsClosedAtLoadAndReopenedByItsAgent() throws {
        let ledger = makeLedger()
        startSession("s1", in: ledger, at: 10)
        XCTAssertTrue(try XCTUnwrap(ledger.session(agent: .claude, sessionID: "s1")).isActive)

        // Nirux crashed: the agent went with it.
        let relaunched = makeLedger()
        let closed = try XCTUnwrap(relaunched.session(agent: .claude, sessionID: "s1"))
        XCTAssertEqual(closed.endedAt, 11, "closed at its last activity")

        relaunched.record(observation(.sessionStart, at: 100, source: "resume"), spaceID: "space-1")
        let resumed = try XCTUnwrap(relaunched.session(agent: .claude, sessionID: "s1"))
        XCTAssertTrue(resumed.isActive)
        XCTAssertEqual(resumed.startedAt, 10)
    }

    @MainActor
    func testANewSessionInAColumnEndsItsPreviousOne() throws {
        let ledger = makeLedger()
        startSession("s1", in: ledger, at: 10)
        startSession("other-column", in: ledger, at: 12, column: "column-2")
        // `/clear` in column-1.
        startSession("s2", in: ledger, at: 20)

        XCTAssertEqual(ledger.session(agent: .claude, sessionID: "s1")?.endedAt, 20)
        XCTAssertTrue(try XCTUnwrap(ledger.session(agent: .claude, sessionID: "s2")).isActive)
        XCTAssertTrue(try XCTUnwrap(ledger.session(agent: .claude, sessionID: "other-column")).isActive)
    }

    @MainActor
    func testASessionEndsWhenItsAgentNoLongerRunsInItsColumn() throws {
        let ledger = makeLedger()
        startSession("s1", in: ledger, at: 10)
        startSession("s2", in: ledger, at: 10, column: "column-2")
        startSession("s3", in: ledger, at: 10, column: "column-3")

        let replacement = ProcessInstance(pid: 4242, startedAt: 2000)
        // column-1 still runs it; column-2 runs another process now; column-3
        // is gone or back at its shell.
        ledger.closeSessions(notRunningIn: ["column-1": process, "column-2": replacement], at: 50)

        XCTAssertNil(ledger.session(agent: .claude, sessionID: "s1")?.endedAt)
        XCTAssertEqual(ledger.session(agent: .claude, sessionID: "s2")?.endedAt, 50)
        XCTAssertEqual(ledger.session(agent: .claude, sessionID: "s3")?.endedAt, 50)
    }

    @MainActor
    func testQuittingClosesEverySession() throws {
        let ledger = makeLedger()
        startSession("s1", in: ledger, at: 10)
        ledger.closeAllSessions(at: 60)
        XCTAssertEqual(makeLedger().session(agent: .claude, sessionID: "s1")?.endedAt, 60)
    }

    // MARK: - Damaged files

    @MainActor
    func testLinesThatArentSessionsAreDroppedAndTheFileRewritten() throws {
        let ledger = makeLedger()
        startSession("s1", in: ledger, at: 10)
        startSession("s2", in: ledger, at: 20, column: "column-2")
        // Garbage, a line without its session, and a line cut by a crash,
        // next to a rewrite the crash interrupted.
        try appendRaw("not json\n{\"v\":1,\"agent\":\"claude\"}\n{\"v\":1,\"agent\":\"cla")
        try Data("partial".utf8).write(to: fileURL().deletingLastPathComponent().appendingPathComponent(".sessions.jsonl.tmp-1"))

        let reloaded = makeLedger()
        XCTAssertEqual(Set(reloaded.sessions(inSpace: "space-1").map(\.sessionID)), ["s1", "s2"])
        XCTAssertEqual(try lines().count, 2)
        XCTAssertTrue(try String(contentsOf: fileURL(), encoding: .utf8).hasSuffix("\n"))
        let folder = try fileURL().deletingLastPathComponent().path
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder), ["sessions.jsonl"])
    }

    @MainActor
    func testAFileMostlyGarbageIsSetAsideBeforeTheRewrite() throws {
        let ledger = makeLedger()
        startSession("s1", in: ledger, at: 10)
        try appendRaw(String(repeating: "garbage\n", count: AgentSessionLedger.maxDroppedLines + 1))

        XCTAssertEqual(makeLedger().sessions(inSpace: "space-1").map(\.sessionID), ["s1"])
        XCTAssertEqual(try lines().count, 1)
        let folder = try fileURL().deletingLastPathComponent().path
        let copies = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasPrefix("sessions.corrupt.") }
        XCTAssertEqual(copies.count, 1)
    }

    @MainActor
    func testWhatThisBuildCantFullyReadIsKeptAsItIsAndNeverUpdated() throws {
        let ledger = makeLedger()
        startSession("s1", in: ledger, at: 10)
        // From a newer build: a newer format, an agent this one doesn't
        // know, a key it doesn't know.
        let foreign = [
            #"{"agent":"claude","sessionID":"newer","v":2}"#,
            #"{"agent":"gemini","hasConversation":true,"lastActivityAt":1,"lastStartAt":1,"sessionID":"g1","startedAt":1,"status":"idle","v":1}"#,
            #"{"agent":"claude","hasConversation":true,"lastActivityAt":1,"lastStartAt":1,"model":"opus","sessionID":"k1","startedAt":1,"status":"idle","v":1}"#
        ]
        try appendRaw(foreign.joined(separator: "\n") + "\n")

        let reloaded = makeLedger()
        XCTAssertEqual(reloaded.sessions(inSpace: "space-1").map(\.sessionID), ["s1"])
        reloaded.record(observation(.sessionStart, session: "k1", at: 30, source: "resume", column: "column-2"), spaceID: "space-1")
        XCTAssertNil(reloaded.session(agent: .claude, sessionID: "k1"), "never updated here")
        // Rewrites keep them.
        for turn in 0...AgentSessionLedger.minSupersededLines {
            reloaded.record(observation(.stop, at: TimeInterval(40 + turn)), spaceID: "space-1")
        }
        XCTAssertLessThan(try lines().count, 10, "rewritten")
        for line in foreign {
            XCTAssertTrue(try lines().contains(line), line)
        }
    }

    @MainActor
    func testATooLargeFileIsSetAsideAndANewOneStarts() throws {
        let url = try fileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: AgentSessionLedger.maxFileBytes + 1).write(to: url)

        let ledger = makeLedger()
        startSession("s1", in: ledger, at: 10)
        XCTAssertEqual(try lines().count, 2)
        let entries = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(entries.filter { $0.hasPrefix("sessions.corrupt.") && $0.hasSuffix(".jsonl") }.count, 1)
    }

    @MainActor
    func testALinkIsNeitherFollowedNorReplaced() throws {
        let url = try fileURL()
        let target = stateDirectory.appendingPathComponent("elsewhere.jsonl")
        try Data().write(to: target)
        let ledger = makeLedger()
        startSession("s1", in: ledger, at: 10)
        // Swapped in after the load.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        startSession("s2", in: ledger, at: 20, column: "column-2")
        XCTAssertEqual(try Data(contentsOf: target), Data())

        // Found at load.
        makeLedger().record(observation(.stop, at: 30), spaceID: "space-1")
        XCTAssertEqual(try Data(contentsOf: target), Data())
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), target.path)
    }

    // MARK: - Compaction

    @MainActor
    func testSupersededLinesAreCompactedToOneLinePerSession() throws {
        let ledger = makeLedger()
        startSession("s1", in: ledger, at: 10)
        for turn in 0..<AgentSessionLedger.minSupersededLines {
            let time = TimeInterval(20 + turn * 2)
            ledger.record(observation(.userPromptSubmit, at: time), spaceID: "space-1")
            ledger.record(observation(.stop, at: time + 1), spaceID: "space-1")
        }
        XCTAssertLessThan(try lines().count, AgentSessionLedger.minSupersededLines + 2)
        let last = TimeInterval(20 + (AgentSessionLedger.minSupersededLines - 1) * 2 + 1)
        XCTAssertEqual(makeLedger().session(agent: .claude, sessionID: "s1")?.lastActivityAt, last)
        let folder = try fileURL().deletingLastPathComponent().path
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder), ["sessions.jsonl"])
    }

    @MainActor
    func testASpacePastItsLimitKeepsItsMostRecentSessions() throws {
        let ledger = makeLedger()
        // One column: each new session ends the previous one.
        for index in 0...AgentSessionLedger.maxRecordsPerSpace {
            startSession("s\(index)", in: ledger, at: TimeInterval(index * 10))
        }
        // The rewrite, then the last session's prompt.
        XCTAssertEqual(try lines().count, AgentSessionLedger.compactedRecordsPerSpace + 1)
        let kept = makeLedger().sessions(inSpace: "space-1")
        XCTAssertEqual(kept.count, AgentSessionLedger.compactedRecordsPerSpace)
        XCTAssertEqual(kept.first?.sessionID, "s\(AgentSessionLedger.maxRecordsPerSpace)")
    }

    @MainActor
    func testAFileAnotherWriterAppendedToIsNotRewritten() throws {
        let ledger = makeLedger()
        startSession("s1", in: ledger, at: 10)
        // A second Nirux on the same state directory.
        let other = #"{"agent":"claude","hasConversation":true,"lastActivityAt":5,"lastStartAt":5,"sessionID":"other","startedAt":5,"status":"idle","v":1}"#
        try appendRaw(other + "\n")
        for turn in 0...AgentSessionLedger.minSupersededLines {
            ledger.record(observation(.stop, at: TimeInterval(20 + turn)), spaceID: "space-1")
        }
        XCTAssertTrue(try lines().contains(other))
        XCTAssertGreaterThan(try lines().count, AgentSessionLedger.minSupersededLines)
    }

    func testCompactionKeepsOpenSessionsAndTheMostRecentConversations() {
        func record(_ id: String, at time: TimeInterval, open: Bool = false, prompted: Bool = true) -> AgentSessionRecord {
            AgentSessionRecord(
                schemaVersion: 1, agent: .claude, sessionID: id, startedAt: time, lastStartAt: time,
                lastActivityAt: time, endedAt: open ? nil : time, status: .idle, hasConversation: prompted
            )
        }
        let records = [
            record("old", at: 1), record("open-old", at: 2, open: true), record("never-prompted", at: 9, prompted: false),
            record("open-unprompted", at: 3, open: true, prompted: false), record("recent", at: 8), record("middle", at: 5)
        ]
        XCTAssertEqual(
            AgentSessionLedger.compacted(records, limit: 4).map(\.sessionID),
            ["open-old", "open-unprompted", "middle", "recent"]
        )
    }

    // MARK: - Queries

    @MainActor
    func testQueriesFilterAndSortNewestFirst() throws {
        let ledger = makeLedger()
        startSession("ended", in: ledger, at: 10)
        startSession("active", in: ledger, at: 20, column: "column-2")
        startSession("newest", in: ledger, at: 30, column: "column-3")
        ledger.record(observation(.sessionStart, session: "unprompted", at: 40, source: "startup", column: "column-4"), spaceID: "space-1")
        ledger.closeSessions(notRunningIn: ["column-2": process, "column-3": process, "column-4": process], at: 50)
        ledger.record(observation(.turnComplete, session: "codex", at: 25, column: "column-5", agent: .codex), spaceID: "space-1")

        XCTAssertEqual(ledger.sessions(inSpace: "space-1").map(\.sessionID), ["newest", "codex", "active", "ended"])
        var query = AgentSessionLedger.Query()
        query.state = .active
        XCTAssertEqual(ledger.sessions(inSpace: "space-1", matching: query).map(\.sessionID), ["newest", "codex", "active"])
        query.includesUnprompted = true
        XCTAssertEqual(ledger.sessions(inSpace: "space-1", matching: query).first?.sessionID, "unprompted")
        query = AgentSessionLedger.Query(state: .ended)
        XCTAssertEqual(ledger.sessions(inSpace: "space-1", matching: query).map(\.sessionID), ["ended"])
        query = AgentSessionLedger.Query(agent: .codex)
        XCTAssertEqual(ledger.sessions(inSpace: "space-1", matching: query).map(\.sessionID), ["codex"])
        query = AgentSessionLedger.Query(limit: 2)
        XCTAssertEqual(ledger.sessions(inSpace: "space-1", matching: query).count, 2)
    }

    @MainActor
    func testAPullRequestReachesEverySessionOfItsCheckout() throws {
        let ledger = makeLedger()
        let checkout = AgentSessionRecord.Checkout(branch: "feat/x", worktreeRoot: "/wt", mainCheckout: "/repo", repository: nil)
        startSession("ended", in: ledger, at: 10, checkout: checkout)
        startSession("open", in: ledger, at: 20, column: "column-2", checkout: checkout)
        startSession("other-branch", in: ledger, at: 20, column: "column-3", checkout: AgentSessionRecord.Checkout(
            branch: "feat/y", worktreeRoot: "/wt", mainCheckout: "/repo", repository: nil
        ))
        ledger.closeSessions(notRunningIn: ["column-2": process, "column-3": process], at: 30)

        let pullRequest = AgentSessionRecord.PullRequest(number: 7, url: "https://github.com/o/r/pull/7", state: "OPEN")
        ledger.notePullRequest(pullRequest, branch: "feat/x", worktreeRoot: "/wt")
        XCTAssertEqual(ledger.session(agent: .claude, sessionID: "ended")?.pullRequest, pullRequest)
        XCTAssertEqual(ledger.session(agent: .claude, sessionID: "open")?.pullRequest, pullRequest)
        XCTAssertNil(ledger.session(agent: .claude, sessionID: "other-branch")?.pullRequest)

        var merged = pullRequest
        merged.state = "MERGED"
        ledger.notePullRequest(merged, branch: "feat/x", worktreeRoot: "/wt")
        // A branch reused for another pull request doesn't rewrite the old one.
        ledger.notePullRequest(AgentSessionRecord.PullRequest(number: 9, url: "u", state: "OPEN"), branch: "feat/x", worktreeRoot: "/wt")
        XCTAssertEqual(makeLedger().session(agent: .claude, sessionID: "ended")?.pullRequest, merged)

        var query = AgentSessionLedger.Query()
        query.pullRequest = .without
        XCTAssertEqual(ledger.sessions(inSpace: "space-1", matching: query).map(\.sessionID), ["other-branch"])
    }

    // MARK: - Context from the workspace

    @MainActor
    func testTheCheckoutIsTheWorkspacesOnlyWhenTheAgentWorksInIt() throws {
        let root = stateDirectory.appendingPathComponent("app.feat-x", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        let nested = root.appendingPathComponent(".claude/worktrees/feat", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("gitdir: /elsewhere\n".utf8).write(to: nested.appendingPathComponent(".git"))
        let context = GitContext(
            branch: "feat/x",
            identity: GitIdentity(repositoryRoot: root.path, head: "abc"),
            upstreamRepository: GitHubRepository(owner: "Xikimay", name: "Nirux")
        )

        let checkout = try XCTUnwrap(NiruxShellView.sessionCheckout(context: context, cwd: root.appendingPathComponent("Sources").path))
        XCTAssertEqual(checkout, AgentSessionRecord.Checkout(
            branch: "feat/x", worktreeRoot: root.path, mainCheckout: GitRepositoryLayout.canonicalPath(root.path),
            repository: "github.com/xikimay/nirux", head: "abc"
        ))
        XCTAssertNotNil(NiruxShellView.sessionCheckout(context: context, cwd: nil))
        // A sibling folder sharing the prefix, another repository, a
        // worktree nested inside.
        XCTAssertNil(NiruxShellView.sessionCheckout(context: context, cwd: root.path + "2"))
        XCTAssertNil(NiruxShellView.sessionCheckout(context: context, cwd: "/repos/other"))
        XCTAssertNil(NiruxShellView.sessionCheckout(context: context, cwd: nested.path))
        XCTAssertNil(NiruxShellView.sessionCheckout(context: nil, cwd: root.path))
    }
}
