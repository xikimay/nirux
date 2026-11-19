import XCTest
@testable import Nirux

/// Claude Code's session record (`ClaudeSessionRecord`): its REPL's word
/// that it sits idle at its prompt, which lets Nirux type into a `claude`
/// that took no prompt since it started.
final class ClaudeSessionRecordTests: XCTestCase {
    private let process = ProcessInstance(pid: 4242, startedAt: 1_000)

    private func record(
        _ status: String?, waitingFor: String? = nil, changedAt: TimeInterval? = 1_010, startedAt: TimeInterval = 1_000.2,
        pid: pid_t = 4242
    ) -> ClaudeSessionRecord {
        ClaudeSessionRecord(pid: pid, startedAt: startedAt, status: status, waitingFor: waitingFor, statusUpdatedAt: changedAt)
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-claude-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The file as Claude Code 2.1.328 writes it, times in milliseconds. It
    /// shows the REPL idle at its prompt only when it is that process's,
    /// says idle with nothing waiting, and held for the settle time.
    func testRecordShowsTheIdlePromptOnlyWhenItsREPLSaysSo() throws {
        let json = #"{"pid":4242,"sessionId":"s","cwd":"/r","startedAt":1000200,"procStart":"p","version":"2.1.328","#
            + #""kind":"interactive","entrypoint":"cli","status":"idle","updatedAt":1010000,"statusUpdatedAt":1010000}"#
        let parsed = try XCTUnwrap(ClaudeSessionRecord(json: Data(json.utf8)))
        XCTAssertEqual(parsed, record("idle"))
        XCTAssertTrue(parsed.showsIdlePrompt(of: process, now: 1_013))
        XCTAssertFalse(parsed.showsIdlePrompt(of: process, now: 1_012.9), "a resume's dialog may still open")
        XCTAssertFalse(record("waiting", waitingFor: "dialog open").showsIdlePrompt(of: process, now: 2_000))
        XCTAssertFalse(record("idle", waitingFor: "permission prompt").showsIdlePrompt(of: process, now: 2_000), "a wait it names")
        XCTAssertFalse(record("busy").showsIdlePrompt(of: process, now: 2_000))
        XCTAssertFalse(record(nil, changedAt: nil).showsIdlePrompt(of: process, now: 2_000), "no REPL yet")
        XCTAssertFalse(record("idle", changedAt: nil).showsIdlePrompt(of: process, now: 2_000))
        XCTAssertFalse(record("idle", startedAt: 990).showsIdlePrompt(of: process, now: 2_000), "an earlier process's, same pid")
        XCTAssertFalse(record("idle", pid: 7).showsIdlePrompt(of: process, now: 2_000))
        XCTAssertNil(ClaudeSessionRecord(json: Data(#"{"pid":4242,"startedAt":1000200,"status":3}"#.utf8)), "a field of another kind")
    }

    /// Found in the config folder Claude Code uses, `.claude` in its home
    /// unless `CLAUDE_CONFIG_DIR` names one; missing and unreadable are told
    /// apart for the log.
    func testRecordIsReadFromTheConfigFolder() throws {
        XCTAssertEqual(ClaudeSessionRecord.url(pid: 42, environment: ["HOME": "/Users/a"]).path, "/Users/a/.claude/sessions/42.json")
        let config = try folder()
        let url = ClaudeSessionRecord.url(pid: 42, environment: ["HOME": "/Users/a", "CLAUDE_CONFIG_DIR": config.path])
        XCTAssertEqual(url.path, config.appendingPathComponent("sessions/42.json").path)
        XCTAssertEqual(ClaudeSessionRecord.read(at: url), .missing)
        XCTAssertEqual(ClaudeSessionRecord.Reading.missing.facts(of: process, now: 0), "missing")
        try Data(#"{"pid":42,"#.utf8).write(to: url)
        XCTAssertEqual(ClaudeSessionRecord.read(at: url), .unreadable)
        try Data(#"{"pid":42,"startedAt":5000}"#.utf8).write(to: url)
        XCTAssertEqual(ClaudeSessionRecord.read(at: url), .found(ClaudeSessionRecord(
            pid: 42, startedAt: 5, status: nil, waitingFor: nil, statusUpdatedAt: nil
        )))
        let waiting = ClaudeSessionRecord.Reading.found(record("waiting", waitingFor: "dialog open"))
        XCTAssertEqual(waiting.facts(of: process, now: 1_013), "waiting(dialog_open)/3s")
        XCTAssertEqual(ClaudeSessionRecord.Reading.found(record("idle", pid: 7)).facts(of: process, now: 1_013), "stale")
    }

    /// The environment a process started with, as KERN_PROCARGS2 lays it
    /// out: past all of its arguments, empty ones too, up to the strings
    /// macOS adds after it.
    func testEnvironmentIsReadPastAllTheArguments() {
        let area = ["/bin/sh", "-c", "sleep 30", "", "CLAUDE_CONFIG_DIR=/tmp/c", "HOME=/tmp/a=b", "NOVALUE", "", "executable_path=/bin/sh"]
            .joined(separator: "\0") + "\0"
        let environment = ProcessSnapshot.environment(argc: 4, strings: ArraySlice(Array(area.utf8)))
        XCTAssertEqual(environment, ["CLAUDE_CONFIG_DIR": "/tmp/c", "HOME": "/tmp/a=b"])
        XCTAssertNotNil(ProcessSnapshot.environment(of: getpid())["PATH"], "this process's, from the kernel")
        XCTAssertEqual(ProcessSnapshot.environment(of: -1), [:])
    }

    /// End to end: the `claude` in a terminal, with no prompt since it
    /// started, takes a message once the record in its own config folder
    /// says its REPL sits idle at its prompt.
    @MainActor func testAClaudeWithNoPromptTakesAMessageOnceItsRecordSaysSo() async throws {
        let config = try folder()
        // Nirux's, which the terminal inherits: macOS hides a system binary's
        // own, as the stand-in's `cat`.
        let inherited = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        setenv("CLAUDE_CONFIG_DIR", config.path, 1)
        defer {
            if let inherited { setenv("CLAUDE_CONFIG_DIR", inherited, 1) } else { unsetenv("CLAUDE_CONFIG_DIR") }
        }
        let agent = AgentStandIn()
        defer { agent.remove() }
        let pty = PtySession()
        pty.start(shell: "/bin/zsh", args: ["-f", "-c", agent.command()], cwd: config.path)
        try await waitUntil("claude in front", timeout: 3) { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
        let claude = try XCTUnwrap(pty.foregroundProcess(snapshot: ProcessSnapshot())).instance
        func refusal() -> AgentPromptRefusal? {
            pty.missionPromptRefusal(runningSince: Date().timeIntervalSince1970, snapshot: ProcessSnapshot())
        }
        func write(_ status: String, waitingFor: String? = nil) throws {
            let changed = (Date().timeIntervalSince1970 - ClaudeSessionRecord.settleTime - 1) * 1000
            var fields = #""pid":\#(claude.pid),"startedAt":\#((claude.startedAt + 0.1) * 1000),"#
                + #""status":"\#(status)","statusUpdatedAt":\#(changed)"#
            if let waitingFor { fields += #","waitingFor":"\#(waitingFor)""# }
            try Data("{\(fields)}".utf8).write(to: config.appendingPathComponent("sessions/\(claude.pid).json"))
        }
        XCTAssertEqual(refusal(), .noPromptYet, "no record")
        try write("waiting", waitingFor: "dialog open")
        XCTAssertEqual(refusal(), .noPromptYet, "a resume's dialog")
        try write("idle")
        XCTAssertNil(refusal())
        XCTAssertTrue(pty.missionPromptFacts(now: Date().timeIntervalSince1970, snapshot: ProcessSnapshot()).contains(" record=idle/"))
    }
}
