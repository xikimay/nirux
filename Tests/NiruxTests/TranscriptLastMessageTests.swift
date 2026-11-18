import XCTest
@testable import Nirux

/// The last message of a Claude Code transcript, from invented lines in its
/// format (never a real transcript).
final class TranscriptLastMessageTests: XCTestCase {
    private func line(_ object: [String: Any]) throws -> String {
        try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))
    }

    private func assistant(_ id: String, _ parts: [[String: Any]], at time: String = "2026-11-17T10:00:00.000Z") -> [String: Any] {
        ["type": "assistant", "timestamp": time, "message": ["id": id, "role": "assistant", "content": parts]]
    }

    private func text(_ text: String) -> [String: Any] { ["type": "text", "text": text] }

    private let toolCall: [String: Any] = ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "ls"]]

    private func reading(_ lines: [[String: Any]]) throws -> TranscriptLastMessage.Reading? {
        TranscriptLastMessage.last(in: Data(try lines.map(line).joined(separator: "\n").utf8))
    }

    private func message(_ reading: TranscriptLastMessage.Reading?) -> TranscriptSearch.Message? {
        if case .message(let message)? = reading { return message }
        return nil
    }

    /// Every text line of the last message, a tool call between them and a
    /// later tool call aside; a subagent's words and an API error aren't
    /// the agent's.
    func testTheLastMessageIsEveryTextOfItsLines() throws {
        var sidechain = assistant("s1", [text("A subagent's words.")])
        sidechain["isSidechain"] = true
        var failure = assistant("e1", [text("API Error: overloaded")])
        failure["isApiErrorMessage"] = true
        // Claude Code's own placeholder, after a prompt queued meanwhile.
        let placeholder: [String: Any] = [
            "type": "assistant", "message": ["id": "p1", "model": "<synthetic>", "role": "assistant", "content": [text("No response requested.")]]
        ]
        let lines = [
            assistant("m1", [text("An earlier answer.")]),
            ["type": "user", "message": ["role": "user", "content": "Go on."]],
            assistant("m2", [text("Part one.")]),
            assistant("m2", [toolCall]),
            assistant("m2", [text("Part two.")], at: "2026-11-17T10:06:00.000Z"),
            sidechain,
            ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "ok"]]]],
            failure,
            assistant("m3", [toolCall]),
            placeholder
        ]
        let message = try XCTUnwrap(message(try reading(lines)))
        XCTAssertEqual(message.text, "Part one.\n\nPart two.")
        XCTAssertEqual(message.timestamp, ISO8601DateFormatter().date(from: "2026-11-17T10:06:00Z"))
    }

    /// Only the end of the file is read, its first line cut short.
    func testOnlyTheEndIsRead() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-transcript-\(UUID().uuidString).jsonl").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let early = try line(assistant("m1", [text(String(repeating: "x", count: 10_000))]))
        let last = try line(assistant("m2", [text("The end.")]))
        try (early + "\n" + last + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(message(TranscriptLastMessage.read(path: path, tailBytes: 2_000))?.text, "The end.")
        XCTAssertEqual(message(TranscriptLastMessage.read(path: path, tailBytes: last.utf8.count + 1))?.text, "The end.", "a window starting a line keeps it")
        XCTAssertEqual(TranscriptLastMessage.read(path: path, tailBytes: 20), .noText, "a window inside the last line holds no message")
    }

    /// Never an answer to an earlier prompt as the latest: a turn that only
    /// ran tools since its prompt gives that prompt; a window of tool output
    /// says so; a conversation with neither gives nothing.
    func testTheNewestPromptBoundsTheMessage() throws {
        let toolOutput: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "ok"]]]]
        let prompt: [String: Any] = ["type": "user", "timestamp": "2026-11-17T11:00:00.000Z", "message": ["role": "user", "content": "Check the tests.\nThen push."]]
        let ranTools = try reading([assistant("m1", [text("An earlier answer.")]), prompt, assistant("m2", [toolCall]), toolOutput])
        guard case .unanswered(let asked)? = ranTools else { return XCTFail("\(String(describing: ranTools))") }
        XCTAssertEqual(asked.text, "Check the tests.\nThen push.")
        XCTAssertEqual(asked.timestamp, ISO8601DateFormatter().date(from: "2026-11-17T11:00:00Z"))
        XCTAssertEqual(message(try reading([prompt, assistant("m2", [text("Done.")]), assistant("m2", [toolCall])]))?.text, "Done.")
        let filler = try line(toolOutput)
        XCTAssertEqual(TranscriptLastMessage.last(in: Data((filler + "\n" + filler).utf8), startsMidLine: true), .noText)
        XCTAssertNil(try reading([assistant("m1", [toolCall]), toolOutput]), "a conversation not started")
    }

    /// A line holding a secret is withheld, a private key's block whole.
    func testSecretsAreWithheldByTheLine() {
        let text = ["Done.", "API_TOKEN=abcd1234efgh5678", "-----BEGIN RSA PRIVATE KEY-----", "MIIEowIBAAKCAQEA", "-----END RSA PRIVATE KEY-----", "Bye."]
            .joined(separator: "\n")
        let (shown, withheld) = TranscriptLastMessage.withholdingSecrets(text)
        XCTAssertEqual(withheld, 4)
        XCTAssertEqual(shown.components(separatedBy: "\n").first, "Done.")
        XCTAssertEqual(shown.components(separatedBy: "\n").last, "Bye.")
        XCTAssertFalse(shown.contains("MIIE") || shown.contains("abcd1234"), shown)
        XCTAssertEqual(TranscriptLastMessage.withholdingSecrets("Plain.").withheld, 0)
    }

    /// The interrupt is read only from what was written after the Esc.
    func testTheInterruptIsReadPastTheEsc() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-interrupt-\(UUID().uuidString).jsonl").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sentAt = Date()
        let later = Date(timeInterval: 1, since: sentAt).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let marker = #"{"type":"user","timestamp":"\#(later)","message":{"role":"user","content":"[Request interrupted by user]"}}"#
        // Stamped after the Esc, yet written before it: not this Esc's.
        try (marker + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let offset = TranscriptLastMessage.size(of: path)
        XCTAssertFalse(TranscriptLastMessage.showsInterrupt(path: path, since: sentAt, after: offset))
        XCTAssertTrue(TranscriptLastMessage.showsInterrupt(path: path, since: sentAt, after: 0))
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        handle.write(Data((marker + "\n").utf8))
        try handle.close()
        XCTAssertTrue(TranscriptLastMessage.showsInterrupt(path: path, since: sentAt, after: offset))
    }
}
