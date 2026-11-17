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

    /// Every text line of the last message, a tool call between them and a
    /// later tool call aside; a subagent's words and an API error aren't
    /// the agent's.
    func testTheLastMessageIsEveryTextOfItsLines() throws {
        var sidechain = assistant("s1", [text("A subagent's words.")])
        sidechain["isSidechain"] = true
        var failure = assistant("e1", [text("API Error: overloaded")])
        failure["isApiErrorMessage"] = true
        let lines = [
            assistant("m1", [text("An earlier answer.")]),
            ["type": "user", "message": ["role": "user", "content": "Go on."]],
            assistant("m2", [text("Part one.")]),
            assistant("m2", [toolCall]),
            assistant("m2", [text("Part two.")], at: "2026-11-17T10:06:00.000Z"),
            sidechain,
            ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "ok"]]]],
            failure,
            assistant("m3", [toolCall])
        ]
        let message = try XCTUnwrap(TranscriptLastMessage.last(in: Data(try lines.map(line).joined(separator: "\n").utf8)))
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
        XCTAssertEqual(TranscriptLastMessage.read(path: path, tailBytes: 2_000)?.text, "The end.")
        XCTAssertNil(TranscriptLastMessage.read(path: path, tailBytes: 20), "a window inside the last line holds no message")
    }

    func testNoTextFromTheAgentIsNoMessage() throws {
        let lines = [["type": "user", "message": ["role": "user", "content": "Hi."]], assistant("m1", [toolCall])]
        XCTAssertNil(TranscriptLastMessage.last(in: Data(try lines.map(line).joined(separator: "\n").utf8)))
    }
}
