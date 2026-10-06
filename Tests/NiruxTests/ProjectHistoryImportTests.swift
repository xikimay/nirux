import XCTest
@testable import Nirux

/// Importing a project's past sessions and Claude Code memories into its
/// history, and the estimate shown before (docs/project-memory-tree.md,
/// section 2.6).
final class ProjectHistoryImportTests: XCTestCase {
    private var root: URL!
    private var stateDirectory: URL { root.appendingPathComponent("state") }
    private var claudeProjects: URL { root.appendingPathComponent("claude-projects") }
    private var repository: String { root.appendingPathComponent("proj").path }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let created = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-history-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        // As Claude and git write it: /var is /private/var.
        root = URL(fileURLWithPath: try XCTUnwrap(realpath(created.path, nil).map { String(cString: $0) }))
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeProjects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], at: repository)
        try git(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "init"],
                at: repository)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Estimate

    /// Messages that fit in a node cost nothing; a long one is a summary,
    /// and so is a merge whose two lines don't fit together.
    func testTheEstimateCountsModelCalls() {
        XCTAssertEqual(ProjectHistory.Estimate.of(sizes: [100, 100]).summaries, 0)
        XCTAssertEqual(ProjectHistory.Estimate.of(sizes: [600, 100]).summaries, 1, "400 + 1 + 100 fits")
        XCTAssertEqual(ProjectHistory.Estimate.of(sizes: [600, 600]).summaries, 3)
        let estimate = ProjectHistory.Estimate.of(sizes: [600, 600, 600, 600])
        XCTAssertEqual(estimate.summaries, 7)
        XCTAssertEqual(estimate.freeMessages, 0)
        XCTAssertEqual(estimate.messages, 4)
        XCTAssertEqual(estimate.dollars(.sonnet), 7 * 0.048, accuracy: 1e-9)
        XCTAssertEqual(estimate.seconds, 7 * ProjectHistory.Estimate.secondsPerSummary)
    }

    /// Only merges that reach a new message are new, at every level.
    func testTheEstimateCountsOnlyWhatTheNewMessagesAdd() {
        XCTAssertEqual(ProjectHistory.Estimate.of(sizes: [600], after: [600]).summaries, 2)
        XCTAssertEqual(ProjectHistory.Estimate.of(sizes: [100], after: [600, 600]).summaries, 0)
        XCTAssertEqual(ProjectHistory.Estimate.of(sizes: [600], after: [600, 600, 600]).summaries, 3)
    }

    // MARK: - Fixtures

    private func git(_ arguments: [String], at directory: String) throws {
        _ = try HistorySearchTests.git(arguments, at: directory)
    }

    /// A transcript Claude filed for `cwd`, one turn per pair, each marked
    /// as Claude Code ends it unless `marked` is false for the last;
    /// written `age` seconds ago.
    @discardableResult
    private func transcript(
        cwd: String, session: String = UUID().uuidString, branch: String = "main",
        _ turns: [(prompt: String, reply: String, at: String)], marked: Bool = true, age: TimeInterval = 3_600
    ) throws -> String {
        let folder = claudeProjects.appendingPathComponent(HistorySearch.claudeFolderName(cwd))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var lines: [String] = []
        for (index, turn) in turns.enumerated() {
            var objects: [[String: Any]] = [
                ["type": "user", "origin": ["kind": "human"], "message": ["role": "user", "content": turn.prompt]],
                ["type": "assistant", "message": [
                    "role": "assistant", "content": [["type": "text", "text": turn.reply]], "stop_reason": "end_turn"
                ]]
            ]
            if marked || index < turns.count - 1 { objects.append(["type": "system", "subtype": "stop_hook_summary"]) }
            for (number, var object) in objects.enumerated() {
                object["timestamp"] = turn.at
                object["cwd"] = cwd
                object["gitBranch"] = branch
                object["sessionId"] = session
                object["uuid"] = "\(session)-\(index)-\(number)"
                lines.append(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
            }
        }
        let path = folder.appendingPathComponent("\(session).jsonl").path
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
        return path
    }

    /// A session ledger line of `space`, for `session`.
    private func record(
        _ session: String, in space: String, transcriptPath: String?, lastActivityAt: TimeInterval, isActive: Bool = false
    ) throws {
        let record = AgentSessionRecord(
            schemaVersion: 1, agent: .claude, sessionID: session, name: nil, cwd: repository, transcriptPath: transcriptPath,
            checkout: nil, pullRequest: nil, startedAt: 0, lastStartAt: 0, lastActivityAt: lastActivityAt,
            endedAt: isActive ? nil : lastActivityAt,
            status: .idle, hasConversation: true, workspaceID: nil, workspaceTitle: nil, agentUUID: nil, columnIndex: nil
        )
        let ledger = try XCTUnwrap(AgentSessionLedger.fileURL(spaceID: space, stateDirectory: stateDirectory))
        try FileManager.default.createDirectory(at: ledger.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? Data(contentsOf: ledger)) ?? Data()
        try (existing + JSONEncoder().encode(record) + Data("\n".utf8)).write(to: ledger)
    }

    private var scope: ProjectHistory.ImportScope {
        ProjectHistory.ImportScope(repositories: [repository], claudeProjects: claudeProjects.path)
    }

    @MainActor
    private func center() -> ProjectHistoryCenter {
        let directory = stateDirectory
        return ProjectHistoryCenter(stateDirectory: { directory })
    }

    @MainActor
    private func plan(_ center: ProjectHistoryCenter, running: Set<String> = []) -> ProjectHistory.ImportPlan? {
        let done = expectation(description: "plan")
        var result: ProjectHistory.ImportPlan?
        center.planImport(spaceID: "p1", scope: scope, runningSessions: running) { plan in
            result = plan
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return result
    }

    @MainActor
    @discardableResult
    private func turnOn(_ center: ProjectHistoryCenter, running: Set<String> = []) -> Int? {
        let done = expectation(description: "import")
        var written: Int?
        center.turnOnImporting(spaceID: "p1", scope: scope, runningSessions: running) { count in
            written = count
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return written
    }

    @MainActor
    private func idle(_ center: ProjectHistoryCenter) {
        let done = expectation(description: "idle")
        center.whenIdle { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    private var messages: [ProjectHistory.Message] {
        ProjectHistoryCenter.messages(spaceID: "p1", stateDirectory: stateDirectory)
    }

    // MARK: - Import

    /// The project's transcripts, in the order their turns ended across
    /// files, once: those of a removed worktree Nirux named for the
    /// session's branch included, a sibling folder's left out.
    @MainActor
    func testImportReadsTheProjectsTranscriptsInTurnOrderOnce() throws {
        try transcript(cwd: repository, [("First", "One.", "2026-10-01T10:00:00.000Z"), ("Fourth", "Four.", "2026-10-01T13:00:00.000Z")])
        try transcript(cwd: repository + "/Sources", [("Second", "Two.", "2026-10-01T11:00:00.000Z")])
        try transcript(cwd: repository + ".feat-y", branch: "feat/y", [("Third", "Three.", "2026-10-01T12:00:00.000Z")])
        try transcript(cwd: repository + "-x", [("Sibling", "No.", "2026-10-01T10:30:00.000Z")])
        try transcript(cwd: repository + ".feat-z", branch: "main", [("Not its branch", "No.", "2026-10-01T10:40:00.000Z")])
        let center = center()

        let first = try XCTUnwrap(plan(center))
        XCTAssertEqual(first.transcripts, 3)
        XCTAssertEqual(first.estimate.messages, 8)
        XCTAssertEqual(first.estimate.freeMessages, 8)
        XCTAssertFalse(ProjectHistory.isEnabled(spaceID: "p1", stateDirectory: stateDirectory), "a plan changes nothing")
        XCTAssertEqual(turnOn(center), 8)
        XCTAssertTrue(ProjectHistory.isEnabled(spaceID: "p1", stateDirectory: stateDirectory))
        let enabledAt = ProjectHistory.enabledDate(spaceID: "p1", stateDirectory: stateDirectory)
        XCTAssertEqual(messages.map(\.text), ["First", "One.", "Second", "Two.", "Third", "Three.", "Fourth", "Four."])
        XCTAssertEqual(plan(center)?.transcripts, 0, "nothing left to import")
        XCTAssertEqual(turnOn(center), 0)
        XCTAssertEqual(ProjectHistory.enabledDate(spaceID: "p1", stateDirectory: stateDirectory), enabledAt, "on since then")
    }

    /// An import a failed write cut short keeps its record, so the next
    /// launch goes on with it.
    @MainActor
    func testAnImportCutShortGoesOnAtTheNextLaunch() throws {
        try transcript(cwd: repository, [("First", "One.", "2026-10-01T10:00:00.000Z")])
        let folder = try XCTUnwrap(ProjectHistory.folder(spaceID: "p1", stateDirectory: stateDirectory))
        let log = folder.appendingPathComponent("log")
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: log.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: log.path) }
        XCTAssertEqual(turnOn(center()), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(ProjectHistory.importFileName).path))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: log.path)
        let relaunched = center()
        relaunched.catchUp([])
        idle(relaunched)
        XCTAssertEqual(messages.map(\.text), ["First", "One."])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(ProjectHistory.importFileName).path))
    }

    /// The live feed doesn't pass over what a cut-short import owes: it
    /// goes on with the import first, in the same launch.
    @MainActor
    func testTheLiveFeedGoesOnWithACutShortImportFirst() throws {
        let session = UUID().uuidString
        let path = try transcript(cwd: repository, session: session, [("Imported", "Yes.", "2026-10-01T10:00:00.000Z")])
        let folder = try XCTUnwrap(ProjectHistory.folder(spaceID: "p1", stateDirectory: stateDirectory))
        let log = folder.appendingPathComponent("log")
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: log.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: log.path) }
        let center = center()
        XCTAssertEqual(turnOn(center), 0)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: log.path)
        // Tried again at most every 5 minutes: the first Stop waits.
        center.turnEnded(spaceID: "p1", transcriptPath: path, sessionID: session)
        idle(center)
        XCTAssertTrue(messages.isEmpty)
        let worker = center.worker
        worker.queue.sync { worker.importAttempts["p1"] = .distantPast }
        let line = "{\"type\":\"user\",\"origin\":{\"kind\":\"human\"},\"message\":{\"role\":\"user\",\"content\":\"Now\"},"
            + "\"timestamp\":\"\(Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))\",\"sessionId\":\"\(session)\"}\n"
            + "{\"type\":\"system\",\"subtype\":\"turn_duration\",\"sessionId\":\"\(session)\"}\n"
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try handle.close()
        center.turnEnded(spaceID: "p1", transcriptPath: path, sessionID: session)
        idle(center)
        XCTAssertEqual(messages.map(\.text), ["Imported", "Yes.", "Now"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(ProjectHistory.importFileName).path))
    }

    /// A session the ledger says runs keeps its open turn for the live
    /// feed, even without the running list; a turn that ended just before
    /// history was on is the live feed's, not passed over.
    @MainActor
    func testRunningSessionsOpenTurnsGoToTheLiveFeed() throws {
        let fromLedger = UUID().uuidString
        let ledgerPath = try transcript(cwd: repository, session: fromLedger, [("Open", "Not yet", "2026-10-01T10:00:00.000Z")],
                                        marked: false)
        try record(fromLedger, in: "p1", transcriptPath: ledgerPath, lastActivityAt: 100, isActive: true)
        let running = UUID().uuidString
        let stamp = Date().addingTimeInterval(-60).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let path = try transcript(cwd: repository, session: running, [("Just before", "Answered.", stamp)], marked: false, age: 30)
        let center = center()
        XCTAssertEqual(turnOn(center, running: [running]), 0)

        let mark = "{\"type\":\"system\",\"subtype\":\"stop_hook_summary\",\"sessionId\":\"\(running)\"}\n"
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        handle.write(Data(mark.utf8))
        try handle.close()
        center.turnEnded(spaceID: "p1", transcriptPath: path, sessionID: running)
        idle(center)
        XCTAssertEqual(messages.map(\.text), ["Just before", "Answered."])
    }

    /// A memory note that can't be written leaves the import to go on.
    @MainActor
    func testANoteThatCantBeWrittenLeavesTheImportOpen() throws {
        let memory = claudeProjects.appendingPathComponent(HistorySearch.claudeFolderName(repository)).appendingPathComponent("memory")
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        try "---\nname: Rule\n---\nBody".write(to: memory.appendingPathComponent("rule.md"), atomically: true, encoding: .utf8)
        let folder = try XCTUnwrap(ProjectHistory.folder(spaceID: "p1", stateDirectory: stateDirectory))
        let log = folder.appendingPathComponent("log")
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: log.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: log.path) }
        XCTAssertEqual(turnOn(center()), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(ProjectHistory.importFileName).path))
    }

    /// Turned on without the import, an import cut short earlier is
    /// dropped; importing later, while on, leaves the joins alone.
    @MainActor
    func testTurningOnWithoutTheImportDropsAnOldOneAndRunningTurnsWait() throws {
        let folder = try XCTUnwrap(ProjectHistory.folder(spaceID: "p1", stateDirectory: stateDirectory))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(scope).write(to: folder.appendingPathComponent(ProjectHistory.importFileName))
        do {
            // A join from when history was on before.
            let journal = try XCTUnwrap(ProjectHistoryJournal.open(folder: folder))
            XCTAssertTrue(journal.join("s-old", at: Date(timeIntervalSince1970: 0)))
        }
        let center = center()
        let done = expectation(description: "on")
        center.turnOn(spaceID: "p1", runningTranscripts: []) { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(ProjectHistory.importFileName).path))
        let joins = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("state.json"))) as? [String: Any]
        XCTAssertNil((joins?["joins"] as? [String: Double])?["s-old"], "joins from before don't apply")

        // Already on: importing changes neither the date it was turned on
        // nor the running sessions' joins.
        let enabledAt = ProjectHistory.enabledDate(spaceID: "p1", stateDirectory: stateDirectory)
        XCTAssertEqual(turnOn(center, running: ["s-running"]), 0)
        XCTAssertEqual(ProjectHistory.enabledDate(spaceID: "p1", stateDirectory: stateDirectory), enabledAt)
        let stateData = try? Data(contentsOf: folder.appendingPathComponent("state.json"))
        let state = stateData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertNil((state?["joins"] as? [String: Double])?["s-running"])
    }

    /// The project's Claude Code memories come first, as notes: name and
    /// description, then the body, keys withheld; not the index, not a link,
    /// and not twice.
    @MainActor
    func testMemoriesAreImportedFirstAsNotes() throws {
        let memory = claudeProjects.appendingPathComponent(HistorySearch.claudeFolderName(repository)).appendingPathComponent("memory")
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        let key = "sk-ant-api03-" + String(repeating: "m4Q", count: 30)
        try "---\nname: Telegram frozen\ndescription: \"No new work\"\nmetadata:\n  type: project\n---\n\nKeep alerts. Key \(key) here.\n"
            .write(to: memory.appendingPathComponent("telegram.md"), atomically: true, encoding: .utf8)
        try "- [Telegram frozen](telegram.md)".write(to: memory.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        let outside = root.appendingPathComponent("outside.md")
        try "private".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: memory.appendingPathComponent("link.md"), withDestinationURL: outside)
        try transcript(cwd: repository, [("Hello", "Hi.", "2020-01-01T10:00:00.000Z")])
        let center = center()

        XCTAssertEqual(plan(center)?.notes, 1)
        XCTAssertEqual(turnOn(center), 3)
        XCTAssertEqual(plan(center)?.notes, 0, "imported already")
        XCTAssertEqual(messages.map(\.kind), [.note, .user, .talk])
        XCTAssertEqual(messages.first?.text, "Telegram frozen: No new work\n\nKeep alerts. Key [secret withheld] here.")
        XCTAssertEqual(messages.first?.rendered.hasPrefix("note: Telegram frozen"), true)
        XCTAssertEqual(turnOn(center), 0, "imported once")
    }

    /// A session counts for the project its latest ledger record is in, and
    /// a transcript path the ledger names must be Claude's.
    @MainActor
    func testOtherProjectsSessionsAndForgedPathsAreLeftOut() throws {
        let moved = UUID().uuidString
        let movedPath = try transcript(cwd: repository, session: moved, [("Said in p2", "Yes.", "2026-10-01T10:00:00.000Z")])
        try record(moved, in: "p1", transcriptPath: movedPath, lastActivityAt: 100)
        try record(moved, in: "p2", transcriptPath: movedPath, lastActivityAt: 200)
        let forged = UUID().uuidString
        let forgedPath = root.appendingPathComponent("elsewhere/\(forged).jsonl").path
        try FileManager.default.createDirectory(atPath: (forgedPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: try transcript(cwd: root.appendingPathComponent("elsewhere").path, session: forged, [
            ("Not Claude's file", "No.", "2026-10-01T11:00:00.000Z")
        ]), toPath: forgedPath)
        try record(forged, in: "p1", transcriptPath: forgedPath, lastActivityAt: 300)
        let mine = UUID().uuidString
        let minePath = try transcript(cwd: repository, session: mine, [("Mine", "Ok.", "2026-10-01T12:00:00.000Z")])
        try record(mine, in: "p1", transcriptPath: minePath, lastActivityAt: 400)

        XCTAssertEqual(turnOn(center()), 2)
        XCTAssertEqual(messages.map(\.text), ["Mine", "Ok."])
    }

    /// Imported turns have their keys withheld, and a line of another
    /// session in the file is left out.
    @MainActor
    func testImportedTurnsWithholdKeysAndKeepToTheirSession() throws {
        let key = "sk-ant-api03-" + String(repeating: "t2K", count: 30)
        let path = try transcript(cwd: repository, [("Use \(key) now", "Done.", "2026-10-01T10:00:00.000Z")])
        let planted = try transcript(cwd: repository + "/x", session: "other", [("Planted", "No.", "2026-10-01T11:00:00.000Z")])
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        handle.write(try Data(contentsOf: URL(fileURLWithPath: planted)))
        try handle.close()
        try FileManager.default.removeItem(atPath: planted)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: path)

        XCTAssertEqual(turnOn(center()), 2)
        XCTAssertEqual(messages.map(\.text), ["Use [secret withheld] now", "Done."])
    }

    /// A running session's last turn, if Claude Code hasn't marked it,
    /// waits: in Nirux, the session is running; outside, its transcript
    /// was written in the last minutes.
    @MainActor
    func testARunningSessionsOpenTurnWaits() throws {
        let running = UUID().uuidString
        try transcript(cwd: repository, session: running, [
            ("Done", "Yes.", "2026-10-01T10:00:00.000Z"), ("Open", "Still working", "2026-10-01T10:05:00.000Z")
        ], marked: false)
        try transcript(cwd: repository, [("Outside", "Yes.", "2026-10-01T11:00:00.000Z"), ("Recent", "Mid", "2026-10-01T11:05:00.000Z")],
                       marked: false, age: 30)
        try transcript(cwd: repository, [("Old", "Done.", "2026-10-01T12:00:00.000Z")], marked: false)

        XCTAssertEqual(turnOn(center(), running: [running]), 6)
        XCTAssertEqual(messages.map(\.text), ["Done", "Yes.", "Outside", "Yes.", "Old", "Done."])
    }

    /// Without history on, nothing is imported; an import a crash cut short
    /// goes on at the next launch, before the feed reads anything.
    @MainActor
    func testTheImportNeedsHistoryOnAndGoesOnAfterACrash() throws {
        try transcript(cwd: repository, [("First", "One.", "2026-10-01T10:00:00.000Z")])
        let center = center()
        let worker = center.worker
        let folder = try XCTUnwrap(ProjectHistory.folder(spaceID: "p1", stateDirectory: stateDirectory))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scope = self.scope
        XCTAssertEqual(worker.queue.sync { worker.runImport(spaceID: "p1", scope: scope, runningSessions: []).written }, 0)
        XCTAssertTrue(messages.isEmpty)

        // As `turnOnImporting` leaves them when the app quits mid-import.
        try JSONEncoder().encode(scope).write(to: folder.appendingPathComponent(ProjectHistory.importFileName))
        try "2026-10-02T00:00:00.000Z".write(to: folder.appendingPathComponent("enabled"), atomically: true, encoding: .utf8)
        let relaunched = self.center()
        relaunched.catchUp([])
        idle(relaunched)
        XCTAssertEqual(messages.map(\.text), ["First", "One."])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(ProjectHistory.importFileName).path))
    }

    /// A turn partly written before a crash: the rest is written, and the
    /// import goes on.
    @MainActor
    func testAPartlyWrittenTurnDoesNotStopTheImport() throws {
        let session = UUID().uuidString
        let path = try transcript(cwd: repository, session: session, [
            ("First", "One.", "2026-10-01T10:00:00.000Z"), ("Second", "Two.", "2026-10-01T11:00:00.000Z")
        ])
        let center = center()
        let worker = center.worker
        let folder = try XCTUnwrap(ProjectHistory.folder(spaceID: "p1", stateDirectory: stateDirectory))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        worker.queue.sync {
            _ = worker.journal(for: "p1", creating: true)?.append([ProjectHistory.NewMessage(
                kind: .user, branch: "main", text: "First", date: Date(), session: session, uuid: "\(session)-0-0"
            )], from: path, end: nil)
        }
        XCTAssertEqual(turnOn(center), 3)
        XCTAssertEqual(messages.map(\.text), ["First", "One.", "Second", "Two."])
    }

    /// The handover Nirux delivered is journaled as Nirux's message, as
    /// delivered and keys withheld, only when the project's history is on.
    @MainActor
    func testADeliveredHandoverIsJournaledWhenHistoryIsOn() throws {
        let center = center()
        let key = "sk-ant-api03-" + String(repeating: "h7W", count: 30)
        let text = "# Goal\nShip the journal with \(key) today."
        center.handoverDelivered(spaceID: "p1", name: ".claude-handover.md", text: text, branch: "feat/journal")
        idle(center)
        XCTAssertTrue(messages.isEmpty)

        let memory = try XCTUnwrap(ProjectHistory.folder(spaceID: "p1", stateDirectory: stateDirectory))
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: memory.appendingPathComponent("enabled").path, contents: Data())
        center.handoverDelivered(spaceID: "p1", name: ".claude-handover.md", text: text, branch: "feat/journal")
        idle(center)
        XCTAssertEqual(messages.map(\.kind), [.peer])
        XCTAssertEqual(messages.first?.from, "Nirux")
        XCTAssertEqual(messages.first?.text, "Handover .claude-handover.md:\n\n# Goal\nShip the journal with [secret withheld] today.")
        XCTAssertEqual(messages.first?.rendered.hasPrefix("peer [feat/journal] from Nirux: Handover"), true)
    }
}
