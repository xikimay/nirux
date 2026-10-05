import XCTest
@testable import Nirux

/// Search Everywhere streams each terminal's matches as it is read, and a
/// newer search silences the one it replaced.
@MainActor
final class GlobalTerminalSearchTests: XCTestCase {
    /// What the callbacks saw: a main-actor object, not captured vars,
    /// which Swift 6.1 won't let `@Sendable` closures mutate.
    private final class Calls {
        var matches: [(Int, [String])] = []
        var done = 0
        var events: [String] = []
        var summary: GlobalTerminalSearch.TranscriptSummary?
    }

    /// The transcripts come after every terminal; a file that is gone is
    /// skipped without counting.
    func testTranscriptsAreReadAfterTheTerminals() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-engine-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let transcript = folder + "/s.jsonl"
        try #"{"type":"user","message":{"role":"user","content":"a needle"}}"#.write(toFile: transcript, atomically: true, encoding: .utf8)

        let search = GlobalTerminalSearch()
        let calls = Calls()
        let done = expectation(description: "done")
        search.start(
            needle: "needle",
            readers: [{ "needle" }],
            transcripts: [folder + "/gone.jsonl", transcript],
            onMatches: { index, _ in calls.events.append("terminal \(index)") },
            onTerminalsDone: { calls.events.append("terminals done") },
            onTranscriptMatches: { index, result in calls.events.append("transcript \(index): \(result.total)") },
            onDone: { summary in
                calls.summary = summary
                done.fulfill()
            }
        )
        wait(for: [done], timeout: 5)
        XCTAssertEqual(calls.events, ["terminal 0", "terminals done", "transcript 1: 1"])
        XCTAssertEqual(calls.summary, GlobalTerminalSearch.TranscriptSummary(searched: 1, isCut: false, partial: 0))
    }

    func testMatchesArriveTerminalByTerminalThenTheSearchEnds() {
        let search = GlobalTerminalSearch()
        let calls = Calls()
        let done = expectation(description: "done")
        search.start(
            needle: "needle",
            readers: [{ "a needle" }, { nil }, { "nothing" }, { "needle\nneedle 2" }],
            onMatches: { index, result in calls.matches.append((index, result.matches.map(\.excerpt))) },
            onDone: { _ in done.fulfill() }
        )
        XCTAssertTrue(search.isRunning)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(calls.matches.map(\.0), [0, 3])
        XCTAssertEqual(calls.matches.map(\.1), [["a needle"], ["needle 2", "needle"]])
        XCTAssertFalse(search.isRunning)
    }

    func testASupersededOrCancelledSearchStaysSilent() {
        let search = GlobalTerminalSearch()
        let stale = Calls()
        // Its second terminal is read once the first one's match is on its
        // way to the main queue, ahead of anything sent after.
        func startStaleSearch() {
            let firstDelivered = DispatchSemaphore(value: 0)
            search.start(
                needle: "old",
                readers: [{ "old" }, { firstDelivered.signal(); return nil }],
                onMatches: { index, _ in stale.matches.append((index, [])) },
                onDone: { _ in stale.done += 1 }
            )
            firstDelivered.wait()
        }

        startStaleSearch()
        let fresh = Calls()
        let done = expectation(description: "done")
        search.start(
            needle: "new",
            readers: [{ "new" }],
            onMatches: { index, _ in fresh.matches.append((index, [])) },
            onDone: { _ in done.fulfill() }
        )
        wait(for: [done], timeout: 5)
        XCTAssertEqual(fresh.matches.count, 1)

        startStaleSearch()
        search.cancel()
        XCTAssertFalse(search.isRunning)
        // The search queue is serial: this answers after the cancelled
        // scan's last word.
        let drained = expectation(description: "drained")
        let anyMatch = ScrollbackSearch.Match(line: 1, excerpt: "", highlight: NSRange(), fromBottom: 0, context: 0)
        GlobalTerminalSearch.relocate(anyMatch, of: "old", read: { nil }) { _ in drained.fulfill() }
        wait(for: [drained], timeout: 5)
        XCTAssertTrue(stale.matches.isEmpty)
        XCTAssertEqual(stale.done, 0)
    }

    /// Terminals full of a common word fill their rows, not the sessions'.
    func testTerminalsLeaveTheSessionsTheirRows() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-rows-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let transcript = folder + "/s.jsonl"
        try #"{"type":"user","message":{"role":"user","content":"a needle"}}"#.write(toFile: transcript, atomically: true, encoding: .utf8)
        let record = AgentSessionRecord(
            schemaVersion: 1, agent: .claude, sessionID: "s1", startedAt: 0, lastStartAt: 0,
            lastActivityAt: 0, status: .idle, hasConversation: true
        )
        let text = (1...60).map { "needle \($0)" }.joined(separator: "\n")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let panel = GlobalSearchPanel()
        panel.show(
            relativeTo: window,
            targets: { (1...12).map { GlobalSearchPanel.Target(column: nil, place: "t\($0)", read: { text }) } },
            sessions: { [GlobalSearchPanel.Session(record: record, spaceID: "default", title: "s", transcriptPath: transcript)] },
            onPick: { _ in }
        )
        defer { panel.dismiss() }
        let field = try XCTUnwrap(panel.searchField)
        field.stringValue = "needle"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        let deadline = Date().addingTimeInterval(10)
        while panel.isSearching || panel.rows.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(panel.rows.filter { $0.session == nil }.count, GlobalSearchPanel.maxRows)
        XCTAssertEqual(panel.rows.filter { $0.session != nil }.map(\.excerpt), ["a needle"])
        XCTAssertEqual(panel.statusLabel?.stringValue, "720 matches in 12 of 12 terminals · 500 shown · 1 match in 1 of 1 session")
    }

    func testTheStatusLineCountsTranscriptsApart() {
        let status = GlobalSearchPanel.sessionStatus
        XCTAssertEqual(status(0, 0, 0, nil), "Searching Claude sessions…")
        XCTAssertEqual(status(2, 1, 2, nil), "Searching Claude sessions… 2 matches so far")
        XCTAssertEqual(status(0, 0, 0, .init(searched: 0)), "No Claude session to search")
        XCTAssertEqual(status(0, 0, 0, .init(searched: 40)), "No matches in 40 sessions")
        XCTAssertEqual(status(250, 60, 200, .init(searched: 90)), "250 matches in 60 of 90 sessions · 200 shown")
        XCTAssertEqual(
            status(3, 1, 3, .init(searched: 47, isCut: true, partial: 2)),
            "3 matches in 1 of 47 sessions (older sessions not searched; 2 long transcripts read from the end)"
        )
    }

    /// The session's name, then the title it was given unless that is the
    /// name (Nirux's `--name`), else Claude's own.
    func testASessionRowNamesItOnce() {
        let record = AgentSessionRecord(
            schemaVersion: 1, agent: .claude, sessionID: "s1", startedAt: 0, lastStartAt: 0,
            lastActivityAt: 0, status: .idle, hasConversation: true
        )
        let session = GlobalSearchPanel.Session(record: record, spaceID: "default", title: "feat/x · web", transcriptPath: "/t")
        let place = GlobalSearchPanel.place
        XCTAssertEqual(place(session, "feat/x · web", "Fix billing"), "feat/x · web · Fix billing")
        XCTAssertEqual(place(session, "Billing v2", "Fix billing"), "feat/x · web · Billing v2")
        XCTAssertEqual(place(session, "feat/x · web", nil), "feat/x · web")
        XCTAssertEqual(place(session, nil, nil), "feat/x · web")
    }

    func testTheStatusLineCountsMatchesAndTerminals() {
        let status = GlobalSearchPanel.status
        XCTAssertEqual(status(0, 0, 0, 0, false), "No terminal to search")
        XCTAssertEqual(status(3, 0, 0, 0, true), "Searching 3 terminals…")
        XCTAssertEqual(status(3, 1, 1, 1, true), "Searching 3 terminals… 1 match so far")
        XCTAssertEqual(status(1, 0, 0, 0, false), "No matches in 1 terminal")
        XCTAssertEqual(status(3, 2, 7, 7, false), "7 matches in 2 of 3 terminals")
        XCTAssertEqual(status(3, 2, 900, 500, false), "900 matches in 2 of 3 terminals · 500 shown")
    }
}
