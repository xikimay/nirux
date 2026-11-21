import XCTest
@testable import Nirux

final class TaskThreadReadingTests: XCTestCase {
    func testFoldedThreadKeepsOpenQuestionsAndWithholdsAccessAnswers() {
        let many = (0..<50).flatMap { index -> [TaskThread.Event] in
            let id = "q\(index)"
            return [.init(time: 2, kind: .question, text: String(repeating: "q", count: 300), ref: id),
                    .init(time: 3, kind: .answer, by: .lead, text: String(repeating: "a", count: 300), ref: id)]
        }
        let events: [TaskThread.Event] = [
            .init(time: 1, kind: .request, text: "Ship the reader"),
            .init(time: 4, kind: .question, text: "Which login?", detail: "access", ref: "access"),
            .init(time: 5, kind: .answer, by: .user, text: "private login detail", ref: "access"),
            .init(time: 6, kind: .question, text: "Which branch?", ref: "open", recipient: .lead),
            .init(time: 7, kind: .handedToUser, by: .lead, ref: "open"),
            .init(time: 8, kind: .nextStep, text: "Run the suite")
        ]
        let text = TaskThread.summary(TaskThread.ordered(events + many), title: "Reader", context: .init())
        XCTAssertLessThanOrEqual(text.count, 6_000)
        for wanted in ["Ship the reader", "Next · Run the suite", "Open (user) · Which branch?", "user: access answer withheld"] {
            XCTAssertTrue(text.contains(wanted), wanted)
        }
        XCTAssertFalse(text.contains("private login detail"))
    }

    func testEarlierThreadsNeedEvidenceOfLocalOriginBeforeShowingTheirText() {
        let request = TaskThread.Event(time: 1, kind: .request)
        let closed = TaskThread.Event(time: 2, kind: .closed)
        XCTAssertFalse(TaskThread.canReadArchive([closed]))
        XCTAssertTrue(TaskThread.canReadArchive([request, closed]))
        XCTAssertTrue(TaskThread.canReadArchive([.init(time: 2, kind: .closed, detail: "local")]))
        XCTAssertFalse(TaskThread.canReadArchive([request, .init(time: 2, kind: .closed, detail: "external")]))
    }

    func testDailyWaitsSplitAtHandoffAndCountConcurrentIntervalsOnce() throws {
        let events: [TaskThread.Event] = [
            .init(time: 0, kind: .request), .init(time: 2, kind: .question, ref: "q1", recipient: .lead, missionID: "one"),
            .init(time: 12, kind: .question, ref: "q2", recipient: .lead, missionID: "two"),
            .init(time: 14, kind: .checkRun, until: 19), .init(time: 15, kind: .checkRun, until: 31),
            .init(time: 17, kind: .handedToUser, by: .lead, ref: "q1"), .init(time: 18, kind: .result, missionID: "two"),
            .init(time: 19, kind: .pullRequest), .init(time: 22, kind: .answer, by: .user, ref: "q1"),
            .init(time: 23, kind: .followUp), .init(time: 24, kind: .findings)
        ]
        let waits = try XCTUnwrap(DailyPass.threadWaits(in: events, task: "reader", workspaceID: "w", window: .init(start: 10, end: 25)))
        XCTAssertEqual(waits.lead, 8)
        XCTAssertEqual(waits.user, 5)
        XCTAssertEqual(waits.ci, 11)
        XCTAssertEqual(waits.firstPR, 19)
        XCTAssertEqual(waits.questions, 1)
        XCTAssertEqual(waits.reviewRounds, 1)
        XCTAssertEqual(waits.followUps, 1)
        XCTAssertNil(DailyPass.threadWaits(in: events, task: "reader", workspaceID: "w", window: .init(start: 40, end: 50)))
    }

    func testLiveWaitsUseTheLedgerPRAndTheTimeItsChecksWereObserved() throws {
        let url = "https://github.com/o/r/pull/7"
        let pr = try XCTUnwrap(PRDetect.pullRequestInfo(from: [
            "state": "OPEN", "number": 7, "url": url, "createdAt": "2026-01-01T00:00:00Z",
            "statusCheckRollup": [
                ["name": "build", "status": "COMPLETED", "conclusion": "SUCCESS",
                 "startedAt": "2026-01-01T00:00:05Z", "completedAt": "2026-01-01T00:01:10Z"],
                ["name": "test", "status": "IN_PROGRESS", "startedAt": "2026-01-01T00:01:05Z"],
                ["name": "lint", "status": "QUEUED", "startedAt": "0001-01-01T00:00:00Z"]
            ]
        ]))
        let opened = try XCTUnwrap(TaskThread.time(pr.createdAt))
        var context = TaskThread.Context(pullRequest: pr, observedAt: opened + 80)
        XCTAssertTrue(context.pullRequestEvents.isEmpty)
        context.urls = [url]
        let events = TaskThread.ordered([.init(time: opened - 30, kind: .request)] + context.pullRequestEvents)
        let waits = try XCTUnwrap(DailyPass.threadWaits(in: events, task: "reader", workspaceID: "w",
                                                      window: .init(start: opened - 50, end: opened + 200)))
        XCTAssertEqual(waits.firstPR, 30)
        XCTAssertEqual(waits.ci, 75)
    }

    func testOnlyTheCurrentSpacesRetainedThreadsFeedThePass() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let events: [TaskThread.Event] = [.init(time: 2, kind: .request), .init(time: 6, kind: .question, ref: "q", recipient: .lead),
                                          .init(time: 8, kind: .closed)]
        for id in ["kept", "moved"] {
            TaskThread.Store.append(events, workspaceID: id, spaceID: "here", stateDirectory: directory)
        }
        TaskThread.Store.append(events, workspaceID: "foreign", spaceID: "elsewhere", stateDirectory: directory)
        let window = DailyPass.Window(start: 0, end: 20)
        let waits = DailyPass.readThreadWaits(spaceID: "here", live: [], excluding: ["moved"], missions: [], findings: [], window: window, directory: directory)
        XCTAssertEqual(waits.map(\.workspaceID), ["kept"])
        XCTAssertEqual(waits.first?.lead, 2)
        let facts = DailyPass.Facts(spaceName: "Here", window: window, findings: [], repositories: [], triagedRuns: [],
                                    flakyTests: [], threadWaits: waits, missions: [], proposals: [], briefRules: [])
        XCTAssertTrue(facts.hasNews)
        XCTAssertTrue(DailyPass.digest(facts).text.contains("Task waits in this window"))
    }
}
