import XCTest
@testable import Nirux

/// Claude Code's session record (`ClaudeSessionRecord`): its REPL's word
/// that it sits idle at its prompt, which lets Nirux type into a `claude`
/// that took no prompt since it started.
final class ClaudeSessionRecordTests: XCTestCase {
    private let process = ProcessInstance(pid: 4242, startedAt: 1_000)

    private func record(
        _ status: String?, waitingFor: String? = nil, changedAt: TimeInterval? = 1_010, writtenAt: TimeInterval = 1_010.1
    ) -> ClaudeSessionRecord {
        ClaudeSessionRecord(status: status, waitingFor: waitingFor, statusUpdatedAt: changedAt, writtenAt: writtenAt)
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-claude-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Writes the record of `pid` under `config`, its status set and the
    /// file written at `changedAt`.
    private func writeRecord(pid: pid_t, in config: URL, _ status: String, waitingFor: String? = nil, changedAt: TimeInterval) throws {
        let settled = Date(timeIntervalSince1970: changedAt)
        var fields = #""pid":\#(pid),"status":"\#(status)","statusUpdatedAt":\#(changedAt * 1000)"#
        if let waitingFor { fields += #","waitingFor":"\#(waitingFor)""# }
        let url = config.appendingPathComponent("sessions/\(pid).json")
        try Data("{\(fields)}".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: settled], ofItemAtPath: url.path)
    }

    /// The file as Claude Code 2.1.328 writes it, times in milliseconds. It
    /// shows the REPL idle at its prompt only when this process set its
    /// status idle, nothing waits, and neither status nor file changed for
    /// the settle time.
    func testRecordShowsTheIdlePromptOnlyWhenItsREPLSaysSo() throws {
        let json = #"{"pid":4242,"sessionId":"s","cwd":"/r","startedAt":1000200,"procStart":"p","version":"2.1.328","#
            + #""kind":"interactive","entrypoint":"cli","status":"idle","updatedAt":1010000,"statusUpdatedAt":1010000}"#
        let parsed = try XCTUnwrap(ClaudeSessionRecord(json: Data(json.utf8), writtenAt: 1_010.1))
        XCTAssertEqual(parsed, record("idle"))
        XCTAssertTrue(parsed.showsIdlePrompt(of: process, now: 1_013.1))
        XCTAssertFalse(parsed.showsIdlePrompt(of: process, now: 1_013), "a resume's dialog may still open")
        XCTAssertFalse(record("idle", writtenAt: 1_012).showsIdlePrompt(of: process, now: 1_014), "a write queued behind it may land")
        XCTAssertTrue(record("idle", changedAt: 1_000, writtenAt: 1_000).showsIdlePrompt(of: process, now: 1_003),
                      "its start is known to the second")
        XCTAssertFalse(record("idle", changedAt: 999.9).showsIdlePrompt(of: process, now: 2_000), "an earlier process's, same pid")
        XCTAssertFalse(record("waiting", waitingFor: "dialog open").showsIdlePrompt(of: process, now: 2_000))
        XCTAssertFalse(record("idle", waitingFor: "permission prompt").showsIdlePrompt(of: process, now: 2_000), "a wait it names")
        XCTAssertFalse(record("busy").showsIdlePrompt(of: process, now: 2_000))
        XCTAssertFalse(record(nil, changedAt: nil).showsIdlePrompt(of: process, now: 2_000), "no REPL yet")
        XCTAssertTrue(record("waiting", waitingFor: "dialog open").showsWait(of: process))
        XCTAssertFalse(record("idle").showsWait(of: process))
        XCTAssertFalse(record("waiting", changedAt: 999).showsWait(of: process), "an earlier process's")
        XCTAssertNil(ClaudeSessionRecord(json: Data(#"{"status":3}"#.utf8), writtenAt: 0), "a field of another kind")
    }

    /// Found in the config folder Claude Code uses, `.claude` in its home
    /// unless `CLAUDE_CONFIG_DIR` names one, read without waiting and only
    /// up to Claude Code's size; missing and unreadable are told apart for
    /// the log.
    func testRecordIsReadFromTheConfigFolder() throws {
        XCTAssertEqual(ClaudeSessionRecord.url(pid: 42, environment: ["HOME": "/Users/a"]).path, "/Users/a/.claude/sessions/42.json")
        let config = try folder()
        let url = ClaudeSessionRecord.url(pid: 42, environment: ["HOME": "/Users/a", "CLAUDE_CONFIG_DIR": config.path])
        XCTAssertEqual(url.path, config.appendingPathComponent("sessions/42.json").path)
        XCTAssertEqual(ClaudeSessionRecord.url(pid: 42, environment: ["CLAUDE_CONFIG_DIR": "work/.claude"]) { "/repo" }.path,
                       "/repo/work/.claude/sessions/42.json", "a relative one, against the process's working directory")
        XCTAssertEqual(ClaudeSessionRecord.read(at: url), .missing)
        XCTAssertEqual(ClaudeSessionRecord.Reading.missing.facts(of: process, now: 0), "missing")
        try Data(#"{"pid":42,"#.utf8).write(to: url)
        XCTAssertEqual(ClaudeSessionRecord.read(at: url), .unreadable)
        try Data(#"{"pid":42,"status":"idle"}"#.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 5)], ofItemAtPath: url.path)
        XCTAssertEqual(ClaudeSessionRecord.read(at: url), .found(record("idle", changedAt: nil, writtenAt: 5)))
        let padding = String(repeating: " ", count: ClaudeSessionRecord.maxBytes)
        try Data(#"{"status":"idle","pad":"\#(padding)"}"#.utf8).write(to: url)
        XCTAssertEqual(ClaudeSessionRecord.read(at: url), .unreadable, "past Claude Code's size")
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        XCTAssertEqual(ClaudeSessionRecord.read(at: url), .unreadable, "a FIFO, read without waiting for a writer")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "/dev/zero")
        XCTAssertEqual(ClaudeSessionRecord.read(at: url), .unreadable, "a device that never ends")

        let waiting = ClaudeSessionRecord.Reading.found(record("waiting", waitingFor: "dialog open"))
        XCTAssertEqual(waiting.facts(of: process, now: 1_013), "waiting(dialog_open)/3s")
        // What the log says: missing, unreadable twice in a row, no status of its own.
        XCTAssertTrue(ClaudeSessionRecord.Reading.missing.isIssue(for: process, unreadableBefore: false))
        XCTAssertFalse(ClaudeSessionRecord.Reading.unreadable.isIssue(for: process, unreadableBefore: false), "it may land mid-write")
        XCTAssertTrue(ClaudeSessionRecord.Reading.unreadable.isIssue(for: process, unreadableBefore: true))
        XCTAssertTrue(ClaudeSessionRecord.Reading.found(record(nil, changedAt: nil)).isIssue(for: process, unreadableBefore: false))
        XCTAssertFalse(waiting.isIssue(for: process, unreadableBefore: false))
        XCTAssertEqual(ClaudeSessionRecord.Reading.found(record("idle", changedAt: 990)).facts(of: process, now: 1_013), "stale")
    }

    /// The environment a process started with, as KERN_PROCARGS2 lays it
    /// out: past all of its arguments, empty ones too, up to the strings
    /// macOS adds after it.
    func testEnvironmentIsReadPastAllTheArguments() {
        let area = ["/bin/sh", "-c", "sleep 30", "", "CLAUDE_CONFIG_DIR=/tmp/c", "HOME=/tmp/a=b", "NOVALUE", "", "executable_path=/bin/sh"]
            .joined(separator: "\0") + "\0"
        let environment = ProcessSnapshot.environment(argc: 4, strings: ArraySlice(Array(area.utf8)))
        XCTAssertEqual(environment, ["CLAUDE_CONFIG_DIR": "/tmp/c", "HOME": "/tmp/a=b"])
        // Its argv overwritten in place (Node's process.title): a title, then NULs.
        let retitled = (["claude"] + Array(repeating: "", count: 12) + ["HOME=/tmp/h", ""]).joined(separator: "\0") + "\0"
        XCTAssertEqual(ProcessSnapshot.environment(argc: 4, strings: ArraySlice(Array(retitled.utf8))), ["HOME": "/tmp/h"])
        XCTAssertNotNil(ProcessSnapshot.environment(of: getpid())["PATH"], "this process's, from the kernel")
        XCTAssertEqual(ProcessSnapshot.environment(of: -1), [:])
    }

    /// End to end: the `claude` in a terminal, with no prompt since it
    /// started, takes a message once the record in its config folder says
    /// its REPL sits idle at its prompt, and no Enter follows a paste while
    /// it says it waits on a screen. Nirux's environment names the folder
    /// when macOS hides the process's own, as for its own binaries (the
    /// stand-in's `cat`); a process's own wins when it can be read.
    @MainActor func testAClaudeWithNoPromptTakesAMessageOnceItsRecordSaysSo() async throws {
        let config = try folder()
        let previous = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        setenv("CLAUDE_CONFIG_DIR", config.path, 1)
        defer {
            if let previous { setenv("CLAUDE_CONFIG_DIR", previous, 1) } else { unsetenv("CLAUDE_CONFIG_DIR") }
        }
        let me = ProcessInstance(pid: getpid(), startedAt: 0)
        try writeRecord(pid: me.pid, in: config, "idle", changedAt: Date().timeIntervalSince1970)
        XCTAssertNotEqual(PtySession.sessionRecord(of: me), ClaudeSessionRecord.read(at: config.appendingPathComponent("sessions/\(me.pid).json")),
                          "this process's own environment, which never named that folder")

        let agent = AgentStandIn()
        defer { agent.remove() }
        let pty = PtySession()
        pty.start(shell: "/bin/zsh", args: ["-f", "-c", agent.command()], cwd: config.path)
        try await waitUntil("claude in front", timeout: 3) { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
        let claude = try XCTUnwrap(pty.foregroundProcess(snapshot: ProcessSnapshot())).instance
        func refusal(at now: TimeInterval = Date().timeIntervalSince1970) -> AgentPromptRefusal? {
            pty.missionPromptRefusal(runningSince: now, snapshot: ProcessSnapshot(), now: now)
        }
        XCTAssertEqual(refusal(), .noPromptYet, "no record")
        // As its REPL writes it: once it started.
        try writeRecord(pid: claude.pid, in: config, "idle", changedAt: claude.startedAt)
        let settled = claude.startedAt + ClaudeSessionRecord.settleTime
        XCTAssertEqual(refusal(at: settled), .noPromptYet, "without Nirux's hooks from it")
        _ = pty.applyAgentHook(AgentHookEvent(
            kind: .claude, name: .sessionStart, sessionID: "s", emitterProcess: claude, source: "resume", timestamp: claude.startedAt
        ), isUserFocused: false)
        try writeRecord(pid: claude.pid, in: config, "waiting", waitingFor: "dialog open", changedAt: claude.startedAt)
        XCTAssertEqual(refusal(at: settled), .noPromptYet, "a resume's dialog")
        try writeRecord(pid: claude.pid, in: config, "idle", changedAt: claude.startedAt)
        XCTAssertEqual(refusal(at: settled - 0.1), .noPromptYet, "not settled at that time")
        XCTAssertNil(refusal(at: settled))
        XCTAssertTrue(pty.missionPromptFacts(now: settled, snapshot: ProcessSnapshot()).contains(" record=idle/"))
    }
}
