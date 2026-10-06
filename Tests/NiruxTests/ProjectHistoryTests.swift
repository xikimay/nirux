import XCTest
@testable import Nirux

/// The project history journal (docs/project-memory-tree.md, section 2):
/// how it writes, which transcripts it trusts, and what the center feeds it.
final class ProjectHistoryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: - Journal

    private func message(_ text: String, kind: ProjectHistory.Kind = .user) -> ProjectHistory.NewMessage {
        ProjectHistory.NewMessage(kind: kind, branch: "feat/x", text: text, date: Date(timeIntervalSince1970: 1_790_000_000), session: "s1")
    }

    func testTheJournalAppendsWithIdsAndReadsThemBack() throws {
        let memory = folder.appendingPathComponent("memory")
        var journal: ProjectHistoryJournal? = try XCTUnwrap(ProjectHistoryJournal.open(folder: memory))
        let written = try XCTUnwrap(journal).append(
            [message("Fix it"), message("Fixed.", kind: .talk)], from: "/t/a.jsonl", end: 120
        )
        XCTAssertEqual(written.map(\.i), [0, 1])
        XCTAssertEqual(written[0].size, "user [feat/x]: Fix it".utf8.count)
        XCTAssertEqual(journal?.offset(for: "/t/a.jsonl"), 120)
        journal = nil
        let reopened = try XCTUnwrap(ProjectHistoryJournal.open(folder: memory), "closing released the lock")
        XCTAssertEqual(reopened.count, 2)
        XCTAssertEqual(reopened.offset(for: "/t/a.jsonl"), 120, "offsets come back from the log")
        XCTAssertEqual(reopened.messages().map(\.text), ["Fix it", "Fixed."])
        XCTAssertEqual(reopened.append([message("Next")], from: nil, end: nil).map(\.i), [2])
        let attributes = try FileManager.default.attributesOfItem(atPath: memory.appendingPathComponent("log").path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: memory.appendingPathComponent("log").path).first)
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: memory.appendingPathComponent("log").appendingPathComponent(file).path
        )
        XCTAssertEqual(fileAttributes[.posixPermissions] as? Int, 0o600)
    }

    /// Where reading starts in transcripts that ran when history was
    /// turned on survives a relaunch.
    func testStartsAreKept() throws {
        let memory = folder.appendingPathComponent("memory")
        var journal: ProjectHistoryJournal? = try XCTUnwrap(ProjectHistoryJournal.open(folder: memory))
        XCTAssertTrue(try XCTUnwrap(journal).start("/t/b.jsonl", at: 4_096))
        journal = nil
        XCTAssertEqual(try XCTUnwrap(ProjectHistoryJournal.open(folder: memory)).offset(for: "/t/b.jsonl"), 4_096)
    }

    func testOneWriterAtATime() throws {
        let memory = folder.appendingPathComponent("memory")
        var first: ProjectHistoryJournal? = try XCTUnwrap(ProjectHistoryJournal.open(folder: memory))
        XCTAssertNil(ProjectHistoryJournal.open(folder: memory), "a second writer gets nothing")
        withExtendedLifetime(first) {}
        first = nil
        XCTAssertNotNil(ProjectHistoryJournal.open(folder: memory), "the lock goes with the first")
    }

    /// A turn is written at once; written again (read again after a crash
    /// cut it), its lines already there aren't repeated. Only its last line
    /// says where the turn ends.
    func testATurnIsWrittenOnceAndOnlyItsLastLineMovesTheOffset() throws {
        let memory = folder.appendingPathComponent("memory")
        let journal = try XCTUnwrap(ProjectHistoryJournal.open(folder: memory))
        var first = message("Fix it")
        first.uuid = "u1"
        var reply = message("Fixed.", kind: .talk)
        reply.uuid = "u2"
        XCTAssertEqual(journal.append([first], from: "/t/a.jsonl", end: 50).map(\.i), [0], "the turn cut short")
        XCTAssertEqual(journal.append([first, reply], from: "/t/a.jsonl", end: 90).map(\.i), [1], "read again")
        XCTAssertEqual(journal.messages().map(\.text), ["Fix it", "Fixed."])
        XCTAssertEqual(journal.messages().map { $0.source?.end }, [50, 90])
        XCTAssertEqual(journal.offset(for: "/t/a.jsonl"), 90)
    }

    /// A day file that isn't a regular file (a FIFO would block) is never
    /// written.
    func testAFIFODayFileIsNotWritten() throws {
        let memory = folder.appendingPathComponent("memory")
        let fixed = Date(timeIntervalSince1970: 1_791_239_400)
        let journal = try XCTUnwrap(ProjectHistoryJournal.open(folder: memory, now: { fixed }))
        let day = ProjectHistoryJournal.localGregorian.dateComponents([.year, .month, .day], from: fixed)
        let name = String(format: "%04d-%02d-%02d.jsonl", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        let fifo = memory.appendingPathComponent("log").appendingPathComponent(name).path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        // With a reader, opening it to write would succeed.
        let reader = open(fifo, O_RDONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(reader, 0)
        defer { close(reader) }
        XCTAssertEqual(journal.append([message("One")], from: nil, end: nil).count, 0)
    }

    /// A line cut by a crash is skipped, and the next starts on its own.
    func testACutLineIsSkippedAndTheNextStartsOnItsOwn() throws {
        let memory = folder.appendingPathComponent("memory")
        do {
            let journal = try XCTUnwrap(ProjectHistoryJournal.open(folder: memory))
            journal.append([message("One")], from: nil, end: nil)
        }
        let log = memory.appendingPathComponent("log")
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: log.path).first)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: log.appendingPathComponent(file).path))
        handle.seekToEndOfFile()
        handle.write(Data("{\"i\":1,\"kind\":\"us".utf8))
        try handle.close()
        let journal = try XCTUnwrap(ProjectHistoryJournal.open(folder: memory))
        XCTAssertEqual(journal.count, 1)
        XCTAssertEqual(journal.skippedLines, 1)
        journal.append([message("Two")], from: nil, end: nil)
        XCTAssertEqual(journal.messages().map(\.text), ["One", "Two"])
    }

    /// Lines go to the file of the local day they were written.
    func testLinesGoToTheFileOfTheirDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        var now = Date(timeIntervalSince1970: 1_791_239_400) // 2026-10-05 22:30 UTC = 10-06 00:30 Paris
        let memory = folder.appendingPathComponent("memory")
        let journal = try XCTUnwrap(ProjectHistoryJournal.open(folder: memory, now: { now }, calendar: calendar))
        journal.append([message("Late")], from: nil, end: nil)
        now = now.addingTimeInterval(86_400)
        journal.append([message("Next day")], from: nil, end: nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: memory.appendingPathComponent("log").path).sorted()
        XCTAssertEqual(names, ["2026-10-06.jsonl", "2026-10-07.jsonl"])
        XCTAssertEqual(journal.messages().map(\.i), [0, 1])
    }

    // MARK: - Transcript paths

    /// A hook can be run by anything in the agent's shell: the path it
    /// names must be the ledger's, and look like Claude's own.
    func testTheFeedOnlyTrustsClaudesTranscriptPath() {
        let folders = ["/Users/u/.claude/projects"]
        func feed(_ event: String?, _ record: String?, _ session: String = "s1") -> String? {
            ProjectHistory.feedPath(eventPath: event, recordPath: record, sessionID: session, projectsFolders: folders)
        }
        let real = "/Users/u/.claude/projects/-Users-u-proj/s1.jsonl"
        XCTAssertEqual(feed(real, real), real)
        XCTAssertEqual(feed(nil, real), real)
        XCTAssertEqual(feed(real, nil), real)
        XCTAssertNil(feed("/tmp/planted.jsonl", real), "the ledger's path wins")
        XCTAssertNil(feed("/tmp/projects/x/s1.jsonl", nil), "not Claude's projects folder")
        XCTAssertNil(feed("/Users/u/.claude/projects/x/../../../tmp/s1.jsonl", nil))
        XCTAssertNil(feed(real, nil, "s2"), "another session's file")
        let projects = folder.appendingPathComponent("projects")
        try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(atPath: projects.appendingPathComponent("linked").path, withDestinationPath: "/tmp")
        XCTAssertNil(ProjectHistory.feedPath(
            eventPath: projects.appendingPathComponent("linked/s1.jsonl").path, recordPath: nil, sessionID: "s1",
            projectsFolders: [projects.path]
        ), "a linked folder")
    }
}

final class ProjectHistoryCenterTests: XCTestCase {
    private var stateDirectory: URL!
    private var transcripts: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-history-center-\(UUID().uuidString)")
        stateDirectory = root.appendingPathComponent("state")
        transcripts = root.appendingPathComponent("transcripts")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: stateDirectory.deletingLastPathComponent())
        super.tearDown()
    }

    @MainActor
    private func center() -> ProjectHistoryCenter {
        let directory = stateDirectory!
        return ProjectHistoryCenter(
            stateDirectory: { directory },
            timing: ProjectHistoryCenter.Timing(quietInterval: 0, maxWait: 1, pollInterval: 0.01)
        )
    }

    /// History on since `since`, as the Turn On sheet records it.
    private func enable(_ spaceID: String, since: String = "2026-01-01T00:00:00.000Z") throws {
        let memory = try XCTUnwrap(ProjectHistory.folder(spaceID: spaceID, stateDirectory: stateDirectory))
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        try since.write(to: memory.appendingPathComponent("enabled"), atomically: true, encoding: .utf8)
    }

    private func transcript(_ turns: [(String, String)], at timestamp: String = "2026-10-05T20:00:00.000Z") throws -> String {
        let path = transcripts.appendingPathComponent("\(UUID().uuidString).jsonl").path
        try lines(turns, at: timestamp).write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Each turn: a prompt, a reply, and Claude Code's mark of its end
    /// (unless `marked` is false for the last one).
    private func lines(_ turns: [(String, String)], at timestamp: String = "2026-10-05T20:00:00.000Z",
                       marked: Bool = true) throws -> String {
        var lines: [String] = []
        for (index, (prompt, reply)) in turns.enumerated() {
            var objects: [[String: Any]] = [
                ["type": "user", "origin": ["kind": "human"], "message": ["role": "user", "content": prompt]],
                ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": reply]]]]
            ]
            if marked || index < turns.count - 1 { objects.append(["type": "system", "subtype": "turn_duration"]) }
            for var object in objects {
                object["timestamp"] = timestamp
                object["gitBranch"] = "feat/x"
                object["sessionId"] = "s1"
                lines.append(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func append(_ text: String, to path: String) throws {
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try handle.close()
    }

    /// One transcript line of session s1.
    private func line(_ object: [String: Any]) throws -> String {
        var object = object
        if object["timestamp"] == nil { object["timestamp"] = "2026-10-05T20:00:00.000Z" }
        object["gitBranch"] = "feat/x"
        object["sessionId"] = "s1"
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private var nowStamp: String { Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)) }

    @MainActor
    private func idle(_ center: ProjectHistoryCenter) {
        let done = expectation(description: "idle")
        center.whenIdle { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    private func texts(_ spaceID: String) -> [String] {
        ProjectHistoryCenter.messages(spaceID: spaceID, stateDirectory: stateDirectory).map(\.text)
    }

    @MainActor
    func testNothingIsReadForAProjectWhoseHistoryIsOff() throws {
        let center = center()
        let path = try transcript([("Hi", "Hello.")])
        center.turnEnded(spaceID: "p1", transcriptPath: path, sessionID: "s1")
        idle(center)
        XCTAssertNil(ProjectHistory.folder(spaceID: "p1", stateDirectory: stateDirectory).flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        })
    }

    /// Each turn's end journals the new turns, once, with keys withheld.
    @MainActor
    func testTurnsAreJournaledOnceWithKeysWithheld() throws {
        try enable("p1")
        let center = center()
        let key = "sk-ant-api03-" + String(repeating: "x1Y", count: 30)
        let path = try transcript([("Use \(key)", "Done.")])
        center.turnEnded(spaceID: "p1", transcriptPath: path, sessionID: "s1")
        idle(center)
        center.turnEnded(spaceID: "p1", transcriptPath: path, sessionID: "s1")
        idle(center)
        XCTAssertEqual(texts("p1"), ["Use [secret withheld]", "Done."])
        try append(try lines([("Next", "Ok.")]), to: path)
        center.sessionEnded(spaceID: "p1", transcriptPath: path, sessionID: "s1")
        idle(center)
        XCTAssertEqual(texts("p1"), ["Use [secret withheld]", "Done.", "Next", "Ok."])
    }

    /// A Stop reads the turns Claude Code marked as ended; one not marked
    /// yet waits for the next. Turns from before history was on aren't
    /// journaled by the live feed.
    @MainActor
    func testOnlyMarkedTurnsSinceHistoryWasOnAreJournaled() throws {
        try enable("p1", since: "2026-10-05T21:00:00.000Z")
        let center = center()
        let path = try transcript([("Before", "Old.")], at: "2026-10-05T20:00:00.000Z")
        try append(try lines([("After", "New."), ("Open", "Not yet.")], at: "2026-10-05T22:00:00.000Z", marked: false), to: path)
        center.turnEnded(spaceID: "p1", transcriptPath: path, sessionID: "s1")
        idle(center)
        XCTAssertEqual(texts("p1"), ["After", "New."])
        try append(try lines([], marked: true) + "{\"type\":\"system\",\"subtype\":\"turn_duration\",\"sessionId\":\"s1\"}\n", to: path)
        center.turnEnded(spaceID: "p1", transcriptPath: path, sessionID: "s1")
        idle(center)
        XCTAssertEqual(texts("p1"), ["After", "New.", "Open", "Not yet."])
    }

    /// Turned on while a session runs: its past isn't imported. A prompt
    /// typed before, answered after, gives its answer alone.
    @MainActor
    func testTurningOnStartsRunningTranscriptsAtTheirEnd() throws {
        let center = center()
        let path = try transcript([("Earlier", "Old.")])
        try append(try line(["type": "user", "origin": ["kind": "human"], "message": ["role": "user", "content": "Before"]]) + "\n", to: path)
        let turnedOn = expectation(description: "on")
        center.turnOn(spaceID: "p1", runningTranscripts: [path]) { done in
            XCTAssertTrue(done)
            turnedOn.fulfill()
        }
        wait(for: [turnedOn], timeout: 5)
        XCTAssertTrue(ProjectHistory.isEnabled(spaceID: "p1", stateDirectory: stateDirectory))
        let answer = try line(["type": "assistant", "timestamp": nowStamp, "message": [
            "role": "assistant", "content": [["type": "text", "text": "Answer."]], "stop_reason": "end_turn"
        ]])
        try append(answer + "\n" + (try line(["type": "system", "subtype": "turn_duration"])) + "\n", to: path)
        try append(try lines([("After", "New.")], at: nowStamp), to: path)
        center.turnEnded(spaceID: "p1", transcriptPath: path, sessionID: "s1")
        idle(center)
        XCTAssertEqual(texts("p1"), ["Answer.", "After", "New."])
    }

    private func date(_ text: String) throws -> Date {
        try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)
    }

    /// A workspace moved while a turn ran: the project it left journals
    /// the turns that ended before, the project it joined the turn underway,
    /// prompt included.
    @MainActor
    func testAMovedWorkspacesTurnsGoWhereTheyEnded() throws {
        try enable("p1")
        try enable("p2")
        let path = try transcript([("Before the move", "One.")], at: "2026-10-05T20:00:00.000Z")
        try append(try line(["type": "user", "origin": ["kind": "human"], "message": ["role": "user", "content": "During it"],
                             "timestamp": "2026-10-05T20:05:00.000Z"]) + "\n", to: path)
        // Its end, written before the queue gets to the move.
        try append(try line(["type": "assistant", "timestamp": "2026-10-05T20:15:00.000Z", "message": [
            "role": "assistant", "content": [["type": "text", "text": "Done."]], "stop_reason": "end_turn"
        ]]) + "\n" + (try line(["type": "system", "subtype": "turn_duration"])) + "\n", to: path)
        let center = center()
        center.sessionsJoined(
            spaceID: "p2", sessions: [.init(sessionID: "s1", transcriptPath: path)], at: try date("2026-10-05T20:10:00.000Z"),
            leaving: "p1"
        )
        center.turnEnded(spaceID: "p2", transcriptPath: path, sessionID: "s1")
        idle(center)
        XCTAssertEqual(texts("p1"), ["Before the move", "One."])
        XCTAssertEqual(texts("p2"), ["During it", "Done."])
    }

    /// Moved away and back: what the session said in between stays out,
    /// after a relaunch too.
    @MainActor
    func testASessionBackFromAnotherProjectSkipsWhatItSaidThere() throws {
        try enable("p1")
        let path = try transcript([("First", "One.")], at: "2026-10-05T20:00:00.000Z")
        var center = center()
        center.turnEnded(spaceID: "p1", transcriptPath: path, sessionID: "s1")
        idle(center)
        let joining = [ProjectHistoryCenter.Joining(sessionID: "s1", transcriptPath: path)]
        center.sessionsJoined(spaceID: "p3", sessions: joining, at: try date("2026-10-05T20:10:00.000Z"), leaving: "p1")
        try append(try lines([("In p3", "Said there.")], at: "2026-10-05T20:20:00.000Z"), to: path)
        center.sessionsJoined(spaceID: "p1", sessions: joining, at: try date("2026-10-05T20:30:00.000Z"), leaving: "p3")
        idle(center)
        // Relaunched before its next turn ended.
        center = self.center()
        try append(try lines([("Back", "Here.")], at: "2026-10-05T20:40:00.000Z"), to: path)
        center.catchUp([.init(spaceID: "p1", transcriptPath: path, sessionID: "s1", startedAt: 1_000, isRunning: false)])
        idle(center)
        XCTAssertEqual(texts("p1"), ["First", "One.", "Back", "Here."])
    }

    /// A session resumed here, its transcript unknown until its first turn
    /// ends: only the turns after the resume are the project's.
    @MainActor
    func testAResumedSessionJoinsWhenItResumes() throws {
        try enable("p1")
        let path = try transcript([("Long ago", "Elsewhere.")], at: "2026-10-05T20:00:00.000Z")
        let center = center()
        center.sessionsJoined(spaceID: "p1", sessions: [.init(sessionID: "s1", transcriptPath: nil)], at: try date("2026-10-05T20:10:00.000Z"))
        try append(try lines([("Resumed", "Yes.")], at: "2026-10-05T20:20:00.000Z"), to: path)
        center.turnEnded(spaceID: "p1", transcriptPath: path, sessionID: "s1")
        idle(center)
        XCTAssertEqual(texts("p1"), ["Resumed", "Yes."])
    }

    /// A new session's turns are all journaled, even when an earlier turn's
    /// Stop never came.
    @MainActor
    func testANewSessionsTurnsAreAllJournaled() throws {
        try enable("p1")
        let path = try transcript([("First", "One."), ("Second", "Two.")])
        let center = center()
        center.turnEnded(spaceID: "p1", transcriptPath: path, sessionID: "s1")
        idle(center)
        XCTAssertEqual(texts("p1"), ["First", "One.", "Second", "Two."])
    }

    /// The feed reads once the transcript has been quiet: a final answer
    /// Claude Code writes after the hook ran is in the turn. The session's
    /// end closes a turn without its mark, without the text Claude wrote
    /// before a tool call.
    @MainActor
    func testTheFeedWaitsForAQuietTranscript() throws {
        try enable("p1")
        let directory = stateDirectory!
        let center = ProjectHistoryCenter(
            stateDirectory: { directory },
            timing: ProjectHistoryCenter.Timing(quietInterval: 2, maxWait: 8, pollInterval: 0.05)
        )
        let path = try transcript([("One", "Done one.")])
        center.turnEnded(spaceID: "p1", transcriptPath: path, sessionID: "s1")
        idle(center)
        try append(try lines([("Two", "Done two.")]).components(separatedBy: "\n").prefix(1).joined() + "\n", to: path)
        center.turnEnded(spaceID: "p1", transcriptPath: path, sessionID: "s1")
        // Written after the hook, as Claude Code may: the feed is waiting.
        Thread.sleep(forTimeInterval: 0.3)
        try append(try lines([("Two", "Done two.")]).components(separatedBy: "\n").dropFirst().joined(separator: "\n"), to: path)
        idle(center)
        XCTAssertEqual(texts("p1"), ["One", "Done one.", "Two", "Done two."])

        try append(try lines([("Three", "Done three.")], marked: false), to: path)
        let narration = try line(["type": "assistant", "message": [
            "role": "assistant", "content": [["type": "text", "text": "Checking."]], "stop_reason": "tool_use"
        ]])
        try append(try lines([("Four", "x")]).components(separatedBy: "\n").prefix(1).joined() + "\n" + narration + "\n", to: path)
        center.sessionEnded(spaceID: "p1", transcriptPath: path, sessionID: "s1")
        idle(center)
        XCTAssertEqual(Array(texts("p1").suffix(3)), ["Three", "Done three.", "Four"])
    }

    /// A session whose workspace moved: the new project gets only the turns
    /// after the move.
    @MainActor
    func testAMovedSessionDoesNotJournalItsTurnsTwice() throws {
        try enable("p1")
        try enable("p2")
        let center = center()
        let path = try transcript([("First", "One.")])
        center.turnEnded(spaceID: "p1", transcriptPath: path, sessionID: "s1")
        idle(center)
        try append(try lines([("Second", "Two.")]), to: path)
        center.turnEnded(spaceID: "p2", transcriptPath: path, sessionID: "s1")
        idle(center)
        XCTAssertEqual(texts("p1"), ["First", "One."])
        XCTAssertEqual(texts("p2"), ["Second", "Two."])
    }

    /// At launch, only transcripts the journal already reads, and sessions
    /// started after history was turned on.
    @MainActor
    func testCatchUpReadsKnownAndNewSessionsOnly() throws {
        try enable("p1")
        let old = try transcript([("Old session", "Old.")])
        let newer = try transcript([("New session", "New.")])
        let known = try transcript([("Known", "Yes.")])
        let center = center()
        center.turnEnded(spaceID: "p1", transcriptPath: known, sessionID: "s1")
        idle(center)
        try append(try lines([("Later", "Also.")]), to: known)
        center.catchUp([
            .init(spaceID: "p1", transcriptPath: old, sessionID: "s1", startedAt: 1_000, isRunning: false),
            .init(spaceID: "p1", transcriptPath: newer, sessionID: "s1", startedAt: Date().timeIntervalSince1970 + 60, isRunning: false),
            .init(spaceID: "p1", transcriptPath: known, sessionID: "s1", startedAt: 1_000, isRunning: false)
        ])
        idle(center)
        XCTAssertEqual(Set(texts("p1")), ["Known", "Yes.", "New session", "New.", "Later", "Also."])
    }
}
