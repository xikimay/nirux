import Foundation

/// The token usage of Nirux's own one-shot Claude runs (`claude -p`), which
/// leave no transcript (`--no-session-persistence`): one line per run in a
/// file per UTC day, `one-shots-<yyyy-MM-dd>.jsonl`. Counts, the model, the
/// client and the time; never text.
public enum NiruxOneShotLog {
    public static let filePrefix = "one-shots-"
    /// Day files untouched for longer go when a new day's file starts.
    public static let keptDays = 31

    public static func fileName(at time: TimeInterval) -> String {
        filePrefix + Date(timeIntervalSince1970: time).formatted(.iso8601.year().month().day()) + ".jsonl"
    }

    /// One write of a line under PIPE_BUF with O_APPEND: concurrent runs
    /// never interleave.
    public static func append(client: String, model: String?, counts: TokenCounts, at time: TimeInterval, in folder: String) {
        var object: [String: Any] = [
            "timestamp": time, "client": client,
            "usage": [
                "input_tokens": counts.input, "output_tokens": counts.output,
                "cache_creation_input_tokens": counts.cacheWrite, "cache_read_input_tokens": counts.cacheRead,
                "cache_creation": ["ephemeral_1h_input_tokens": counts.hourCacheWrite]
            ]
        ]
        if let model { object["model"] = model }
        guard var line = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = folder + "/" + fileName(at: time)
        var fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd >= 0 {
            prune(folder, before: time - Double(keptDays) * 86_400)
        } else {
            fd = open(path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    private static func prune(_ folder: String, before cutoff: TimeInterval) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        where name.hasPrefix(filePrefix) && name.hasSuffix(".jsonl") {
            let path = folder + "/" + name
            if let status = FileStatus(path), status.isFile, status.modifiedAt < cutoff {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }
}

/// Reads `NiruxOneShotLog`'s lines.
public struct NiruxOneShotUsageParser: TranscriptLineParser, Sendable {
    public private(set) var events: [UsageEvent] = []

    public init() {}

    public mutating func consume(line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let usage = object["usage"] as? [String: Any],
              let counts = TokenCounts(claudeUsage: usage), counts.context > 0 else { return }
        events.append(UsageEvent(
            timestamp: (object["timestamp"] as? NSNumber)?.doubleValue ?? 0,
            model: object["model"] as? String,
            counts: counts
        ))
    }
}
