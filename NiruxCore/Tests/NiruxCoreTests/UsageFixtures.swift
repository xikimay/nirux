import Foundation

/// Transcript files shaped like the agents' own, holding only the fields
/// the readers use.
enum UsageFixture {
    static func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    static func claudeResponse(
        id: String,
        time: String,
        cacheWrite: Int = 0,
        cacheRead: Int = 0,
        output: Int = 10,
        model: String = "claude-opus-5-5",
        sidechain: Bool = false
    ) -> String {
        json([
            "type": "assistant", "isSidechain": sidechain, "requestId": "req_" + id, "timestamp": time,
            "message": [
                "id": id, "model": model, "content": [["type": "text", "text": "never kept"]],
                "usage": [
                    "input_tokens": 2, "cache_creation_input_tokens": cacheWrite,
                    "cache_read_input_tokens": cacheRead, "output_tokens": output
                ]
            ]
        ])
    }

    static func claudeUser(cwd: String) -> String {
        json(["type": "user", "cwd": cwd, "message": ["role": "user", "content": "never kept"]])
    }

    static func codexTokenCount(time: String, last: [String: Int], total: [String: Int]) -> String {
        json([
            "type": "event_msg", "timestamp": time,
            "payload": [
                "type": "token_count",
                "info": ["last_token_usage": last, "total_token_usage": total, "model_context_window": 258_000],
                "rate_limits": [
                    "primary": ["used_percent": 42.5, "window_minutes": 300, "resets_at": 1_795_300_000],
                    "secondary": NSNull()
                ]
            ]
        ])
    }

    static func agyResponse(time: String, input: Int, cacheRead: Int, output: Int) -> String {
        json([
            "type": "PLANNER_RESPONSE", "created_at": time, "model": "gemini-4-neon-high", "thinking": "never kept",
            "input_tokens": input, "cache_read_tokens": cacheRead, "output_tokens": output
        ])
    }

    static func write(_ lines: [String], to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url, options: .atomic)
    }

    static func temporaryFolder() -> String {
        (FileManager.default.temporaryDirectory.path as NSString).appendingPathComponent("usage-" + UUID().uuidString)
    }
}
