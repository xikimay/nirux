import XCTest
@testable import Nirux

final class TaskThreadTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("task-thread-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// An open task's thread: what Nirux recorded, then what the files say
    /// of it, with who said it, in time order.
    func testAnOpenTasksThreadJoinsTheFilesInTimeOrder() {
        var question = event(.question, "Pins per column or per workspace?", at: 30, id: "q1")
        question.questionKind = .decision
        question.recommendation = "Per column"
        question.handedToUserBecause = "Only the user knows"
        question.handedToUserAt = 35
        var answer = event(.response, "Per column", at: 40, inReplyTo: "q1")
        answer.answeredByUser = true
        answer.acceptedRecommendation = true
        var tell = event(.instruction, "/code-review", at: 50, id: "t1")
        tell.expiredAt = 80
        let url = "https://github.com/o/r/pull/731"
        let sources = TaskThread.Sources(
            missions: [mission([question, answer, tell, event(.completed, "PR #731 ready", at: 90, id: "r1")])],
            reviewRuns: [.adversarial: ReviewRun(head: "4c2e9a1", at: 55, branch: "feat/pins")],
            findings: [ReviewFindings.Entry(
                time: 60, workspace: "task", task: "feat/pins", round: 1,
                findings: [.init(kind: "persistence", text: "Saved too late"), .init(kind: "test-waits", text: "Waits on a delay")]
            )],
            followUps: [url: PRFollowUp.Entry(rounds: [PRFollowUp.Round(kind: .ci, head: "abc", typedAt: 70, items: ["x"])])],
            triage: [CITriageStore.RunRecord(
                signature: "s", redChecks: ["test"], tests: ["T.testA"], verdict: .flaky(reason: "a fixed wait"), triagedAt: 65, pullRequest: 731
            )],
            rules: [RuleProposal(
                id: "r", rule: "Wait on state", evidence: "#731", proposedAt: 95, leadWorkspaceID: nil, leadAgentUUID: nil, addedAt: 100
            )]
        )
        let recorded = [
            TaskThread.Event(time: 10, kind: .request, by: .lead, text: "Pinned commands"),
            TaskThread.Event(time: 45, kind: .status, by: .nirux, text: "Pin store in place")
        ]
        XCTAssertEqual(TaskThread.thread(recorded: recorded, joining: sources).map(line), [
            "10 request lead Pinned commands",
            "30 question agent decision Pins per column or per workspace? (Per column) q1",
            "35 handedToUser lead Only the user knows q1",
            "40 answer user accepted Per column q1",
            "45 status nirux Pin store in place",
            "50 tell lead expired /code-review t1",
            "55 review · adversarial 4c2e9a1",
            "60 findings lead persistence, test-waits Saved too late\nWaits on a delay #1",
            "65 ciFailure · flaky test (a fixed wait) #731",
            "70 followUp nirux ci #1 \(url)",
            "90 result agent PR #731 ready r1",
            "100 rule user Wait on state (#731)"
        ])
    }

    /// A closed task's thread is what was frozen, and the close names its
    /// pull requests. An event read twice counts once (a hook replayed, a
    /// task closed twice), and so does a status line repeating the one before.
    func testAClosedThreadIsItsFileAloneAndAnEventCountsOnce() {
        let sources = TaskThread.Sources(missions: [mission([event(.completed, "Done", at: 20, id: "r1")])])
        let turnEnd = TaskThread.Event(time: 10, kind: .turnEnd, detail: "claude")
        let frozen = [turnEnd] + TaskThread.frozen(sources, closedAt: 30, pullRequests: ["https://github.com/o/r/pull/2", "https://github.com/o/r/pull/1"])
        XCTAssertEqual(frozen.map(\.kind), [.turnEnd, .result, .closed])
        XCTAssertEqual(frozen.last?.text, "https://github.com/o/r/pull/1\nhttps://github.com/o/r/pull/2")
        XCTAssertEqual(TaskThread.thread(recorded: frozen, joining: nil), frozen)
        XCTAssertEqual(TaskThread.thread(recorded: [turnEnd, turnEnd] + frozen + frozen, joining: sources), frozen)
        let lines = [10.0, 20, 30, 40].map { time in
            TaskThread.Event(time: time, kind: .status, by: .nirux, text: time == 30 ? "Tests green" : "Pin store in place")
        }
        XCTAssertEqual(TaskThread.thread(recorded: lines, joining: nil).map(\.time), [10, 30, 40])
    }

    /// A rule cites a pull request by its URL, or by its number alone in a
    /// space of one repository.
    func testARulesEvidenceCitesPullRequests() {
        let urls: Set = ["https://github.com/o/r/pull/44"]
        func rule(_ evidence: String) -> RuleProposal {
            RuleProposal(id: "r", rule: "Wait on state", evidence: evidence, proposedAt: 0, leadWorkspaceID: nil, leadAgentUUID: nil)
        }
        XCTAssertTrue(TaskThread.cites(rule("#12, #44"), any: urls, isSingleRepository: true))
        XCTAssertFalse(TaskThread.cites(rule("#12, #44"), any: urls, isSingleRepository: false), "#44 may be another repository's")
        XCTAssertTrue(TaskThread.cites(rule("see https://github.com/o/r/pull/44"), any: urls, isSingleRepository: false))
        XCTAssertFalse(TaskThread.cites(rule("see https://github.com/o/r/pull/444"), any: urls, isSingleRepository: false))
        XCTAssertFalse(TaskThread.cites(rule("#4"), any: urls, isSingleRepository: true))
        XCTAssertEqual(TaskThread.citedPullRequests("#395, #417"), [395, 417])
        XCTAssertEqual(TaskThread.citedPullRequests("slider test (#589)"), [589])
        XCTAssertEqual(TaskThread.citedPullRequests("2 runs of #44"), [44])
        XCTAssertEqual(TaskThread.citedPullRequests("# no number, issue 12"), [])
    }

    /// What `gh pr view --json` says of a pull request: its opening, its
    /// commits, its reviews, the latest run of each check, its merge.
    func testAPullRequestsHistoryFromGitHub() throws {
        let merged = try XCTUnwrap(TaskThread.pullRequestHistory(Data("""
        {"number":731,"url":"https://github.com/o/r/pull/731","title":"Pinned commands","state":"MERGED",
         "createdAt":"2026-11-21T10:05:00Z","closedAt":"2026-11-21T14:02:00Z","mergedAt":"2026-11-21T14:02:00Z",
         "mergeCommit":{"oid":"A91F3C0"},
         "commits":[{"oid":"AAA","committedDate":"2026-11-21T09:58:00Z","messageHeadline":"feat: pin store"},
                    {"oid":"BBB","committedDate":"2026-11-21T10:48:00Z","messageHeadline":"feat: header pins"}],
         "reviews":[{"author":{"login":"someone"},"state":"APPROVED","submittedAt":"2026-11-21T13:00:00Z"}],
         "statusCheckRollup":[
          {"name":"test","workflowName":"Tests","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-11-21T11:25:00Z"},
          {"name":"test","workflowName":"Tests","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-11-21T11:41:00Z"},
          {"name":"build","workflowName":"Tests","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-11-21T11:30:00Z"}]}
        """.utf8)))
        let start = try Date("2026-11-21T00:00:00Z", strategy: .iso8601).timeIntervalSince1970
        XCTAssertEqual(merged.map { line($0, since: start) }, [
            "36300 pullRequest · Pinned commands #731 https://github.com/o/r/pull/731",
            "35880 commit · feat: pin store aaa",
            "38880 commit · feat: header pins bbb",
            "46800 prReview · approved someone",
            "42060 checks · passed 2 checks",
            "50520 merged · #731 a91f3c0"
        ])
        let closed = try XCTUnwrap(TaskThread.pullRequestHistory(Data("""
        {"number":9,"url":"https://github.com/o/r/pull/9","state":"CLOSED","closedAt":"2026-11-21T01:00:00Z",
         "statusCheckRollup":[{"name":"test","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-11-21T00:30:00Z"},
                              {"name":"lint","status":"IN_PROGRESS","startedAt":"2026-11-21T00:31:00Z"}]}
        """.utf8)))
        XCTAssertEqual(closed.map { line($0, since: start) }, ["1860 checks · failed 1 of 2 failed: test", "3600 prClosed · #9"])
        let queued = try XCTUnwrap(TaskThread.pullRequestHistory(Data("""
        {"number":3,"url":"https://github.com/o/r/pull/3","state":"OPEN",
         "statusCheckRollup":[{"name":"test","status":"QUEUED","startedAt":"0001-01-01T00:00:00Z"}]}
        """.utf8)))
        XCTAssertEqual(queued, [], "a queued run has no start")
        XCTAssertNil(TaskThread.pullRequestHistory(Data("not json".utf8)))
    }

    /// One file per task, private, only appended to; a line a crash cut is
    /// skipped and the next one starts on its own; the file follows its task
    /// into another space.
    func testAThreadIsPrivateAndFollowsItsTask() throws {
        let id = UUID().uuidString
        let first = [
            TaskThread.Event(time: 1, kind: .request, by: .user, text: "Pinned commands"),
            TaskThread.Event(time: 2, kind: .status, by: .nirux, text: "Pin store in place")
        ]
        XCTAssertEqual(TaskThread.Store.append(first, workspaceID: id, spaceID: "space-a", stateDirectory: directory), 2)
        let url = try XCTUnwrap(TaskThread.Store.fileURL(workspaceID: id, spaceID: "space-a", stateDirectory: directory))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"t\":2.5,\"ki".utf8))
        try handle.close()

        XCTAssertEqual(
            TaskThread.Store.append([TaskThread.Event(time: 3, kind: .turnEnd)], workspaceID: id, spaceID: "space-b", stateDirectory: directory), 1
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "moved, not copied")
        XCTAssertEqual(TaskThread.Store.load(workspaceID: id, stateDirectory: directory), first + [TaskThread.Event(time: 3, kind: .turnEnd)])
        XCTAssertNil(TaskThread.Store.fileURL(workspaceID: "../\(id)", spaceID: "space-a", stateDirectory: directory))
    }

    /// The request keeps 64 KB, anything else 8,000 characters, and a full
    /// file takes no more.
    func testLongTextsAreCutAndAFullFileTakesNoMore() {
        let id = UUID().uuidString
        let long = [
            TaskThread.Event(time: 1, kind: .request, text: String(repeating: "r", count: 70_000)),
            TaskThread.Event(time: 2, kind: .question, text: String(repeating: "q", count: 9_000), note: String(repeating: "n", count: 9_000))
        ]
        TaskThread.Store.append(long, workspaceID: id, spaceID: "s", stateDirectory: directory)
        let loaded = TaskThread.Store.load(workspaceID: id, stateDirectory: directory)
        XCTAssertEqual(loaded.map { $0.text?.count }, [TaskThread.Store.maxRequestLength, TaskThread.Store.maxTextLength])
        XCTAssertEqual(loaded.last?.note?.count, TaskThread.Store.maxTextLength)

        let line = TaskThread.Event(time: 3, kind: .status, text: String(repeating: "x", count: TaskThread.Store.maxTextLength))
        let many = TaskThread.Store.maxFileBytes / TaskThread.Store.maxTextLength + 10
        XCTAssertLessThan(TaskThread.Store.append(Array(repeating: line, count: many), workspaceID: id, spaceID: "s", stateDirectory: directory), many)
        XCTAssertEqual(TaskThread.Store.append([line], workspaceID: id, spaceID: "s", stateDirectory: directory), 0)
        let url = TaskThread.Store.fileURL(workspaceID: id, spaceID: "s", stateDirectory: directory)
        let size = url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int }
        XCTAssertLessThanOrEqual(size ?? .max, TaskThread.Store.maxFileBytes)
        let short = TaskThread.Event(time: 3, kind: .turnEnd)
        XCTAssertLessThan(TaskThread.Store.append(Array(repeating: short, count: 400), workspaceID: id, spaceID: "s", stateDirectory: directory), 400)
        let close = TaskThread.Event(time: 4, kind: .closed, text: "https://github.com/o/r/pull/1")
        XCTAssertEqual(TaskThread.Store.append([line, close], workspaceID: id, spaceID: "s", stateDirectory: directory), 1, "the close always")
        XCTAssertEqual(TaskThread.Store.load(workspaceID: id, stateDirectory: directory).last, close)
    }

    /// An open task's thread stays, and counts in no budget. Another goes
    /// six months after it was last written, the oldest first past the
    /// space's budget, in a deleted space's folder too.
    func testPruningKeepsOpenTasksAndRemovesOldOrOverBudgetThreads() throws {
        let now: TimeInterval = 2_000_000_000
        let day: TimeInterval = 86_400
        func thread(_ id: String, writtenDaysAgo days: TimeInterval, bytes: Int = 10, space: String = "s") throws -> URL {
            let url = try XCTUnwrap(TaskThread.Store.fileURL(workspaceID: id, spaceID: space, stateDirectory: directory))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: now - days * day)], ofItemAtPath: url.path)
            return url
        }
        let open = try thread("open", writtenDaysAgo: 400, bytes: 15_000_000)
        let old = try thread("old", writtenDaysAgo: 200)
        let recent = try thread("recent", writtenDaysAgo: 1, bytes: 6_000_000)
        let gone = try thread("gone", writtenDaysAgo: 200, space: "deleted-space")
        TaskThread.Store.pruneAll(keeping: ["open"], now: now, stateDirectory: directory)
        XCTAssertEqual([open, old, recent, gone].map { FileManager.default.fileExists(atPath: $0.path) }, [true, false, true, false])

        let older = try thread("older", writtenDaysAgo: 3, bytes: 11_000_000)
        let newer = try thread("newer", writtenDaysAgo: 2, bytes: 8_000_000)
        TaskThread.Store.pruneAll(keeping: ["open"], now: now, stateDirectory: directory)
        XCTAssertEqual([open, recent, older, newer].map { FileManager.default.fileExists(atPath: $0.path) }, [true, true, false, true])
    }

    /// The files are read by the task's workspace id (findings in every
    /// space), then by its pull requests' URLs (follow-ups, triage, rules).
    func testTheFilesAreReadByWorkspaceThenPullRequest() throws {
        let url = "https://github.com/o/r/pull/44"
        let finding = ReviewFindings.Entry(time: 5, workspace: "task", task: "feat/pins", round: 1, findings: [.init(kind: "k", text: "t")])
        ReviewFindings.lines.append(finding, spaceID: "old-space", stateDirectory: directory)
        ReviewFindings.lines.append(
            ReviewFindings.Entry(time: 6, workspace: "other", task: "feat/x", round: 1, findings: []), spaceID: "s", stateDirectory: directory
        )
        var followUps = PRFollowUpStore()
        followUps.pullRequests = [url: PRFollowUp.Entry(rounds: [PRFollowUp.Round(kind: .feedback, head: "h", typedAt: 7)])]
        followUps.pullRequests["https://github.com/o/r/pull/45"] = PRFollowUp.Entry(rounds: [PRFollowUp.Round(kind: .ci, head: "h", typedAt: 8)])
        followUps.save(to: directory.appendingPathComponent(PRFollowUpStore.fileName))
        var triage = CITriageStore()
        let record = CITriageStore.RunRecord(signature: "s", redChecks: ["test"], tests: [], verdict: .real, triagedAt: 9, pullRequest: 44)
        triage.keep(record, of: CIFailure.Run(repository: "github.com/o/r", id: 1))
        triage.keep(
            CITriageStore.RunRecord(signature: "s", redChecks: ["lint"], tests: [], verdict: .real, triagedAt: 10, pullRequest: 45),
            of: CIFailure.Run(repository: "github.com/o/r", id: 2)
        )
        triage.save(to: directory.appendingPathComponent(CITriageStore.fileName))
        let now = Date().timeIntervalSince1970
        let added = RuleProposal(id: "a", rule: "Wait on state", evidence: "#44", proposedAt: now, leadWorkspaceID: nil, leadAgentUUID: nil, addedAt: now)
        let dismissed = RuleProposal(id: "d", rule: "No", evidence: "#44", proposedAt: now, leadWorkspaceID: nil, leadAgentUUID: nil, dismissedAt: now)
        try XCTUnwrap(RuleProposalStore(spaceID: "s", stateDirectory: directory)).save([added, dismissed])

        let sources = TaskThread.Sources.load(
            workspaceID: "task", missions: [mission([]), Mission(
                id: "n", parentWorkspaceID: "lead", parentAgentUUID: "a", childWorkspaceID: "other", childAgentUUID: "b",
                childAgentKind: "claude", branch: "feat/x", status: .active, createdAt: 0, updatedAt: 0, events: []
            )],
            reviewRuns: [:], pullRequestURLs: [url], spaceID: "s", spaceIDs: ["s", "old-space"], isSingleRepository: true,
            stateDirectory: directory
        )
        XCTAssertEqual(sources.missions.map(\.id), ["m"])
        XCTAssertEqual(sources.findings, [finding])
        XCTAssertEqual(Array(sources.followUps.keys), [url])
        XCTAssertEqual(sources.triage, [record])
        XCTAssertEqual(sources.rules.map(\.id), ["a"])
    }

    // MARK: - Helpers

    private func line(_ event: TaskThread.Event) -> String {
        line(event, since: 0)
    }

    private func line(_ event: TaskThread.Event, since start: TimeInterval) -> String {
        [
            "\(Int(event.time - start))", event.kind.rawValue, event.by?.rawValue ?? "·", event.detail,
            event.text, event.note.map { "(\($0))" }, event.number.map { "#\($0)" }, event.ref
        ].compactMap { $0 }.joined(separator: " ")
    }

    private func event(
        _ kind: MissionEvent.Kind, _ message: String, at time: TimeInterval, inReplyTo: String? = nil, id: String = UUID().uuidString
    ) -> MissionEvent {
        MissionEvent(
            id: id, missionID: "m", childWorkspaceID: "task", childAgentUUID: "agent", kind: kind, message: message,
            inReplyTo: inReplyTo, timestamp: time
        )
    }

    private func mission(_ events: [MissionEvent]) -> Mission {
        Mission(
            id: "m", parentWorkspaceID: "lead", parentAgentUUID: "lead-agent", childWorkspaceID: "task", childAgentUUID: "agent",
            childAgentKind: "claude", branch: "feat/pins", status: .active, createdAt: 0, updatedAt: 0, events: events,
            reportsToLead: true
        )
    }
}
