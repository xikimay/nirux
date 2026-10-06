import XCTest
@testable import Nirux

/// How a Claude transcript becomes turns (docs/project-memory-tree.md,
/// section 2): which lines are messages, where turns end; and which secrets
/// are withheld from them.
final class ProjectHistoryTurnsTests: XCTestCase {
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

    // MARK: - Transcript fixtures

    private var clock = 0

    private func timestamp() -> String {
        clock += 1
        return String(format: "2026-10-05T20:%02d:%02d.000Z", clock / 60, clock % 60)
    }

    private func line(_ object: [String: Any]) throws -> String {
        var object = object
        if object["timestamp"] == nil { object["timestamp"] = timestamp() }
        if object["gitBranch"] == nil { object["gitBranch"] = "feat/x" }
        if object["sessionId"] == nil { object["sessionId"] = "s1" }
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func prompt(_ text: String, extra: [String: Any] = [:]) throws -> String {
        try line(["type": "user", "origin": ["kind": "human"], "message": ["role": "user", "content": text]]
            .merging(extra) { $1 })
    }

    /// Claude's text: its final answer, or (`final: false`) what it says
    /// before a tool call, as Claude Code writes their `stop_reason`.
    private func text(_ text: String, final: Bool = true, extra: [String: Any] = [:]) throws -> String {
        try line(["type": "assistant", "message": [
            "role": "assistant", "content": [["type": "text", "text": text]], "stop_reason": final ? "end_turn" : "tool_use"
        ]].merging(extra) { $1 })
    }

    private func toolUse() throws -> String {
        try line(["type": "assistant", "message": ["role": "assistant", "stop_reason": "tool_use", "content": [
            ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "ls"]]
        ]]])
    }

    private func toolResult(_ output: String = "file.swift") throws -> String {
        try line(["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "t1", "content": output]
        ]]])
    }

    private func peer(_ body: String, from name: String = "nirux-public-63") throws -> String {
        try line(["type": "user", "isMeta": true, "origin": [
            "kind": "peer", "body": body, "name": name, "from": "uds:/tmp/x.sock", "msg_id": "m1"
        ], "message": ["role": "user", "content": "Another Claude session sent a message: \(body)"]])
    }

    private func subagentReport(_ body: String) throws -> String {
        try line(["type": "user", "isMeta": true, "origin": [
            "kind": "peer", "body": body, "from": "agent", "handback": true, "senderTaskId": "a1"
        ], "message": ["role": "user", "content": body]])
    }

    private func taskNotification() throws -> String {
        try line(["type": "user", "origin": ["kind": "task-notification"],
                  "message": ["role": "user", "content": "<task-notification>done</task-notification>"]])
    }

    private func marker() throws -> String {
        try line(["type": "system", "subtype": "turn_duration", "durationMs": 1200])
    }

    private func stopHookMarker() throws -> String {
        try line(["type": "system", "subtype": "stop_hook_summary", "hookCount": 1])
    }

    /// A message from another session that arrived while Claude worked, as
    /// Claude Code writes it.
    private func queuedPeer(_ body: String, report: Bool = false) throws -> String {
        var origin: [String: Any] = ["kind": "peer", "body": body, "name": "nirux-public-63", "from": "uds:/tmp/x.sock"]
        if report { origin["senderTaskId"] = "a1"; origin["handback"] = true }
        return try line(["type": "attachment", "attachment": [
            "type": "queued_command", "commandMode": "prompt", "isMeta": true, "prompt": body, "origin": origin
        ]])
    }

    private func queued(_ text: String) throws -> String {
        try line(["type": "attachment", "attachment": [
            "type": "queued_command", "commandMode": "prompt", "prompt": text, "origin": ["kind": "human"]
        ]])
    }

    private func transcript(_ lines: [String], trailingNewline: Bool = true) throws -> String {
        let path = folder.appendingPathComponent("\(UUID().uuidString).jsonl").path
        try (lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func append(_ lines: [String], to path: String) throws {
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        handle.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
    }

    private func read(_ path: String, from offset: UInt64 = 0, ended: Bool = true, failed: Bool = false, session: String? = nil,
                      maxLineBytes: Int = ProjectHistory.TurnReader.maxLineBytes) throws -> ProjectHistory.TurnReader.Result {
        try XCTUnwrap(ProjectHistory.TurnReader.read(
            path: path, from: offset, lastTurnEnded: ended, endedWithError: failed, session: session,
            maxLineBytes: maxLineBytes, chunkSize: 64
        ))
    }

    private func summary(_ result: ProjectHistory.TurnReader.Result) -> [[String]] {
        result.turns.map { $0.messages.map { "\($0.kind.rawValue): \($0.text)" } }
    }

    // MARK: - Turns

    /// A turn is its prompt and the text after its last tool call: what
    /// Claude wrote before a tool call isn't the reply.
    func testATurnIsItsPromptAndTheTextAfterItsLastToolCall() throws {
        let path = try transcript([
            try prompt("Fix the rounding"),
            try text("Let me look first.", final: false),
            try toolUse(),
            try toolResult(),
            try text("Fixed in Billing.swift; tests pass."),
            try text("PR #12 is open.")
        ])
        let result = try read(path)
        XCTAssertEqual(summary(result), [["user: Fix the rounding", "talk: Fixed in Billing.swift; tests pass.\n\nPR #12 is open."]])
        XCTAssertEqual(result.turns.first?.messages.first?.branch, "feat/x")
        XCTAssertEqual(result.turns.first?.messages.first?.session, "s1")
    }

    /// The last turn is complete only when the caller knows it ended; a
    /// turn followed by another message is complete either way.
    func testTheOpenTurnWaitsAndTheNextReadStartsAtIt() throws {
        let first = try prompt("One")
        let path = try transcript([first, try text("Done one."), try prompt("Two"), try toolUse()])
        let open = try read(path, ended: false)
        XCTAssertEqual(summary(open), [["user: One", "talk: Done one."]])
        try append([try toolResult(), try text("Done two.")], to: path)
        let rest = try read(path, from: open.resumeOffset, ended: true)
        XCTAssertEqual(summary(rest), [["user: Two", "talk: Done two."]])
        XCTAssertEqual(open.turns.first?.end, open.resumeOffset)
    }

    /// A prompt queued while Claude worked, a message from another session
    /// between tool calls, and a prompt typed after Esc join the turn
    /// underway.
    func testMessagesDuringTheToolLoopJoinTheTurn() throws {
        let path = try transcript([
            try prompt("Refactor the parser"),
            try toolUse(),
            try toolResult(),
            try queued("also keep the old API"),
            try toolUse(),
            try toolResult("[Request interrupted by user for tool use]"),
            try prompt("[Request interrupted by user]"),
            try prompt("stop, use the lexer instead"),
            try peer("Rebase on main first."),
            try toolUse(),
            try toolResult(),
            try text("Done with the lexer.")
        ])
        XCTAssertEqual(summary(try read(path)), [[
            "user: Refactor the parser", "user: also keep the old API", "user: stop, use the lexer instead",
            "peer: Rebase on main first.", "talk: Done with the lexer."
        ]])
    }

    /// A subagent's report and a task notification aren't messages, but
    /// after a reply they start the next turn: Claude's answer to them is
    /// that turn's reply.
    func testReportsStartATurnWithoutAMessage() throws {
        let path = try transcript([
            try prompt("Review it"),
            try text("Two reviewers are running."),
            try subagentReport("Found 3 bugs: ..."),
            try text("Fixing the 3 bugs."),
            try taskNotification(),
            try text("CI is green.")
        ])
        XCTAssertEqual(summary(try read(path)), [
            ["user: Review it", "talk: Two reviewers are running."],
            ["talk: Fixing the 3 bugs."],
            ["talk: CI is green."]
        ])
    }

    /// Nirux's launch prompt and other sessions' messages are `peer`; a
    /// slash command keeps its arguments; harness text is left out.
    func testKindsAndHarnessText() throws {
        let launch = try XCTUnwrap(NiruxShellView.agentStartupPrompt(agent: .claude, deliveredHandover: true, isMission: false))
        let path = try transcript([
            try prompt(launch),
            try text("Read it."),
            try peer("PR #9 merged, rebase."),
            try text("Rebased."),
            try prompt("<command-name>/review</command-name><command-args>the parser</command-args>"),
            try prompt("<system-reminder>context</system-reminder>"),
            try prompt("caveat", extra: ["isMeta": true]),
            try prompt("Summary so far", extra: ["isCompactSummary": true]),
            try prompt("side work", extra: ["isSidechain": true]),
            try text("Reviewed.")
        ])
        XCTAssertEqual(summary(try read(path)), [
            ["peer: \(launch)", "talk: Read it."],
            ["peer: PR #9 merged, rebase.", "talk: Rebased."],
            ["user: the parser", "talk: Reviewed."]
        ])
    }

    /// Lines a fork copied from its parent are the parent's.
    func testForkedLinesAreSkipped() throws {
        let fork = ["forkedFrom": ["sessionId": "s0", "messageUuid": "u1"]]
        let path = try transcript([
            try prompt("Old question", extra: fork),
            try text("Old answer.", extra: fork),
            try prompt("New question"),
            try text("New answer.")
        ])
        XCTAssertEqual(summary(try read(path)), [["user: New question", "talk: New answer."]])
    }

    /// A turn that ended on an API error keeps its messages, no reply.
    func testATurnEndedByAnErrorHasNoReply() throws {
        let path = try transcript([try prompt("Go"), try text("Starting.")])
        XCTAssertEqual(summary(try read(path, failed: true)), [["user: Go"]])
    }

    /// Claude Code marks each turn's end: a marked turn is complete even
    /// when the next message follows at once, and an unmarked one waits.
    func testClaudeCodesTurnMarksCloseTurns() throws {
        let path = try transcript([
            try prompt("One"), try toolUse(), try toolResult(), try text("Done one."), try marker(),
            try prompt("Two")
        ])
        let result = try read(path, ended: false)
        XCTAssertEqual(summary(result), [["user: One", "talk: Done one."]])
        try append([try text("Done two.")], to: path)
        XCTAssertEqual(summary(try read(path, from: result.resumeOffset, ended: false)), [], "not marked yet")
        try append([try marker()], to: path)
        XCTAssertEqual(summary(try read(path, from: result.resumeOffset, ended: false)), [["user: Two", "talk: Done two."]])
    }

    /// A turn can end on a tool call (`ScheduleWakeup` in a /loop, a
    /// question the user dismissed): its mark ends it, without a reply.
    func testAMarkEndsATurnThatEndedOnAToolCall() throws {
        let path = try transcript([
            try prompt("Check CI every 10 minutes"), try text("Scheduling.", final: false), try toolUse(), try toolResult(),
            try stopHookMarker(), try marker(),
            try prompt("Status?"), try text("Green."), try stopHookMarker(), try marker()
        ])
        XCTAssertEqual(summary(try read(path, ended: false)), [["user: Check CI every 10 minutes"], ["user: Status?", "talk: Green."]])
    }

    /// A message after text Claude wrote before a tool call (Esc stopped it
    /// there) joins the turn: that text isn't a reply.
    func testAMessageAfterTextBeforeAToolCallJoinsTheTurn() throws {
        let path = try transcript([
            try prompt("Deploy"), try text("Checking the logs first.", final: false),
            try prompt("[Request interrupted by user]"), try prompt("use staging"),
            try toolUse(), try toolResult(), try text("Deployed to staging."), try marker()
        ])
        XCTAssertEqual(summary(try read(path, ended: false)), [["user: Deploy", "user: use staging", "talk: Deployed to staging."]])
    }

    /// A turn the session's end cut short keeps its messages; what Claude
    /// wrote before its next tool call isn't a reply. A final answer not
    /// marked yet is.
    func testATurnCutShortHasNoReply() throws {
        let cut = try transcript([try prompt("Deploy"), try toolUse(), try toolResult(), try text("Checking the logs.", final: false)])
        XCTAssertEqual(summary(try read(cut)), [["user: Deploy"]])
        let answered = try transcript([try prompt("Deploy"), try toolUse(), try toolResult(), try text("Deployed.")])
        XCTAssertEqual(summary(try read(answered)), [["user: Deploy", "talk: Deployed."]])
    }

    /// A detached checkout (`HEAD`) has no branch.
    func testADetachedCheckoutHasNoBranch() throws {
        let path = try transcript([
            try prompt("One"), try text("Done."), try marker(),
            try prompt("Two", extra: ["gitBranch": "HEAD"]), try text("Done.", extra: ["gitBranch": "HEAD"]), try marker()
        ])
        XCTAssertEqual(try read(path).turns.map { $0.messages.first?.branch }, ["feat/x", nil])
    }

    /// A message another session sent while Claude worked arrives as a
    /// queued attachment: it joins the turn; a queued report doesn't.
    func testQueuedMessagesFromOtherSessionsJoinTheTurn() throws {
        let path = try transcript([
            try prompt("Ship it"), try toolUse(), try toolResult(),
            try queuedPeer("Rebase first, #12 merged."), try queuedPeer("3 bugs found", report: true),
            try toolUse(), try toolResult(), try text("Rebased and shipped."), try marker()
        ])
        let turns = try read(path, ended: false).turns
        XCTAssertEqual(turns.map { $0.messages.map(\.kind) }, [[.user, .peer, .talk]])
        XCTAssertEqual(turns.first?.messages[1].from, "nirux-public-63")
        XCTAssertEqual(turns.first?.messages[1].text, "Rebase first, #12 merged.")
    }

    /// A turn a scheduled task or /loop starts ends the turn before it; an
    /// API error leaves a turn without reply; Claude Code's stand-in reply
    /// isn't Claude's.
    func testOtherTurnStartsErrorsAndStandIns() throws {
        let path = try transcript([
            try prompt("Watch CI"), try text("Watching."),
            try line(["type": "user", "isMeta": true, "turnOrigin": "scheduled", "message": ["role": "user", "content": "check CI"]]),
            try toolUse(), try toolResult(), try text("CI green."), try marker(),
            try prompt("Again"), try text("Partial"),
            try line(["type": "assistant", "isApiErrorMessage": true, "message": ["role": "assistant", "content": [
                ["type": "text", "text": "API Error: overloaded"]
            ]]]),
            try marker(),
            try prompt("Ok"),
            try line(["type": "assistant", "message": ["role": "assistant", "model": "<synthetic>", "content": [
                ["type": "text", "text": "No response requested."]
            ]]]),
            try marker()
        ])
        XCTAssertEqual(summary(try read(path, ended: false)), [
            ["user: Watch CI", "talk: Watching."], ["talk: CI green."], ["user: Again"], ["user: Ok"]
        ])
    }

    /// A line of another session (a path a hook named, wrongly) is skipped.
    func testLinesOfAnotherSessionAreSkipped() throws {
        let path = try transcript([
            try prompt("Mine"), try text("Yes."), try marker(),
            try prompt("Planted", extra: ["sessionId": "other"]), try text("No.", extra: ["sessionId": "other"]), try marker()
        ])
        XCTAssertEqual(summary(try read(path, ended: false, session: "s1")), [["user: Mine", "talk: Yes."]])
    }

    /// A line still being written (no newline yet) is not read; a line past
    /// the limit is skipped and said.
    func testCutAndLongLines() throws {
        let path = try transcript([try prompt("One"), try text("Done.")], trailingNewline: false)
        let result = try read(path)
        XCTAssertEqual(summary(result), [["user: One"]], "the reply's line has no newline yet")
        let long = try transcript([try prompt(String(repeating: "x", count: 500)), try prompt("Short"), try text("Ok.")])
        let skipped = try read(long, maxLineBytes: 300)
        XCTAssertTrue(skipped.skippedLongLine)
        XCTAssertEqual(summary(skipped), [["user: Short", "talk: Ok."]])
    }

    /// A file shorter than the offset, gone, or not a regular file reads as nil.
    func testUnreadableTranscripts() throws {
        let path = try transcript([try prompt("One")])
        XCTAssertNil(ProjectHistory.TurnReader.read(path: path, from: 1_000_000, lastTurnEnded: true))
        XCTAssertNil(ProjectHistory.TurnReader.read(path: folder.path + "/missing.jsonl", from: 0, lastTurnEnded: true))
        let link = folder.appendingPathComponent("link.jsonl").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        XCTAssertNil(ProjectHistory.TurnReader.read(path: link, from: 0, lastTurnEnded: true))
    }

    // MARK: - Secrets

    /// An AWS key id hides the rest of its line, where its secret is; a
    /// value given to a secret's name is hidden; a key inside a PEM block
    /// is one range with it.
    func testPairedSecretsAndAssignments() {
        XCTAssertEqual(
            ProjectHistory.withholdingSecrets("aws: AKIAABCDEFGHIJKLMNOP wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY\nnext"),
            "aws: [secret withheld]\nnext"
        )
        XCTAssertEqual(
            ProjectHistory.withholdingSecrets("DB_PASSWORD=hunter2hunter2 and api_key: \"abcd1234efgh\" ok"),
            "DB_PASSWORD=[secret withheld] and api_key: \"[secret withheld]\" ok"
        )
        let key = "sk-ant-api03-" + String(repeating: "Q", count: 40)
        XCTAssertEqual(ProjectHistory.withholdingSecrets("api_key=\(key) done"), "api_key=[secret withheld] done",
                       "the key's range and the assignment's overlap: one marker")
        XCTAssertEqual(
            ProjectHistory.withholdingSecrets("x -----BEGIN PRIVATE KEY-----\n\(key)\n-----END PRIVATE KEY-----\ny"),
            "x [secret withheld]\ny"
        )
    }

    /// Many keys, or many unclosed blocks, are read once: no part of the
    /// text is grown over twice.
    func testRedactionStaysLinear() {
        // Back to back: each key's growth would run to the end of the text.
        let keys = String(repeating: "sk-ant-api03-" + String(repeating: "k", count: 90), count: 1_000)
        let blocks = String(repeating: "-----BEGIN PRIVATE KEY-----\n", count: 2_000)
        let start = Date()
        XCTAssertFalse(ProjectHistory.withholdingSecrets(keys).contains("kkkk"))
        XCTAssertEqual(ProjectHistory.withholdingSecrets(blocks), ProjectHistory.withheldKey)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testKeysAreWithheldWhole() {
        let anthropic = "sk-ant-api03-" + String(repeating: "aB3_", count: 23) + "AA"
        let github = "github_pat_" + String(repeating: "Ab1", count: 27)
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEow\nAAAA\n-----END RSA PRIVATE KEY-----"
        let text = "use \(anthropic) here, then \(github).\n\(pem)\nthe end"
        let withheld = ProjectHistory.withholdingSecrets(text)
        XCTAssertEqual(withheld, "use [secret withheld] here, then [secret withheld]\n[secret withheld]\nthe end")
        XCTAssertFalse(withheld.contains("aB3_"))
        XCTAssertEqual(ProjectHistory.withholdingSecrets("no key here: sk-hynix-reports"), "no key here: sk-hynix-reports")
    }

    /// A long value given to a secret's name is withheld to its end, and so
    /// are the secrets history search looks for in chat.
    func testLongValuesAndChatSecretsAreWithheldWhole() {
        let token = String(repeating: "Ab9", count: 400)
        XCTAssertEqual(ProjectHistory.withholdingSecrets("access_token: \(token) next"), "access_token: [secret withheld] next")
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlLXNpZ25hdHVyZQ"
        XCTAssertEqual(ProjectHistory.withholdingSecrets("Bearer \(jwt) ok"), "Bearer [secret withheld] ok")
        XCTAssertEqual(
            ProjectHistory.withholdingSecrets("db: postgres://admin:s3cr3tpass@db.example.com/prod then"),
            "db: [secret withheld] then"
        )
    }

    /// An unclosed PEM block is withheld to the end of the text.
    func testAnUnclosedKeyBlockIsWithheldToTheEnd() {
        XCTAssertEqual(
            ProjectHistory.withholdingSecrets("key:\n-----BEGIN PRIVATE KEY-----\nMIIE..."),
            "key:\n[secret withheld]"
        )
    }

    // MARK: - Launch prompts

    func testNiruxLaunchPromptsAreRecognized() throws {
        let launch = try XCTUnwrap(NiruxShellView.agentStartupPrompt(agent: .codex, deliveredHandover: true, isMission: true))
        XCTAssertTrue(ProjectHistory.isLaunchPrompt(launch))
        XCTAssertTrue(ProjectHistory.isLaunchPrompt("  \(launch)\n"))
        XCTAssertFalse(ProjectHistory.isLaunchPrompt("Read .claude-handover.md please"))
    }
}
