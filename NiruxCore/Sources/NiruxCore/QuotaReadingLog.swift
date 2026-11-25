import Foundation

/// Claude's plan usage readings over the last days, as its status line
/// reported them: one line per reading in a file per UTC day,
/// `limits-<yyyy-MM-dd>.jsonl`, with the window's name, its percentage, its
/// reset and the time. Numbers only.
public enum QuotaReadingLog {
    public static let filePrefix = "limits-"
    /// Day files untouched for longer go when a new day's file starts.
    public static let keptDays = 8

    public static func fileName(at time: TimeInterval) -> String {
        filePrefix + Date(timeIntervalSince1970: time).formatted(.iso8601.year().month().day()) + ".jsonl"
    }

    /// One O_APPEND write per call; the caller's lock
    /// (`ClaudeUsageLimitsFile.record`) keeps concurrent writers apart.
    public static func append(_ readings: [String: QuotaReading], in folder: String) {
        guard let time = readings.values.map(\.time).max() else { return }
        var data = Data()
        for (window, reading) in readings.sorted(by: { $0.key < $1.key }) {
            let object: [String: Any] = ["window": window, "time": reading.time, "used": reading.usedPercent, "resets_at": reading.resetsAt]
            guard let line = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) else { return }
            data.append(line)
            data.append(0x0A)
        }
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
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// The readings since `since`, by window, oldest first.
    public static func read(in folder: String, since: TimeInterval) -> [String: [QuotaReading]] {
        var readings: [String: [QuotaReading]] = [:]
        for path in files(in: folder) where (FileStatus(path)?.modifiedAt ?? 0) >= since {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let window = object["window"] as? String,
                      let time = (object["time"] as? NSNumber)?.doubleValue, time >= since,
                      let used = (object["used"] as? NSNumber)?.doubleValue,
                      let resetsAt = (object["resets_at"] as? NSNumber)?.doubleValue else { continue }
                readings[window, default: []].append(QuotaReading(time: time, usedPercent: used, resetsAt: resetsAt))
            }
        }
        return readings.mapValues { $0.sorted { $0.time < $1.time } }
    }

    public static func removeAll(in folder: String) {
        for path in files(in: folder) { try? FileManager.default.removeItem(atPath: path) }
    }

    private static func files(in folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { $0.hasPrefix(filePrefix) && $0.hasSuffix(".jsonl") }
            .map { folder + "/" + $0 }
    }

    private static func prune(_ folder: String, before cutoff: TimeInterval) {
        for path in files(in: folder) {
            if let status = FileStatus(path), status.isFile, status.modifiedAt < cutoff {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }
}
