import Foundation

/// Recovery copies that outlive the rotating backups: daily snapshots, and
/// state files this build couldn't use, set aside before being replaced.
extension Persistence {
    private static let maxDailySnapshots = 7
    private static let maxCorruptCopies = 10

    /// The first save of each day survives for a week of active days.
    static func writeDailySnapshotIfNeeded(_ data: Data, in dir: URL, now: Date) {
        let fm = FileManager.default
        let url = dir.appendingPathComponent(dailySnapshotName(now))
        guard !fm.fileExists(atPath: url.path) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[Nirux Persistence] Failed to write %@: %@", url.lastPathComponent, error.localizedDescription)
            return
        }
        for stale in dailySnapshotURLs(in: dir, now: now).dropFirst(maxDailySnapshots) where stale != url {
            try? fm.removeItem(at: stale)
        }
        // Once a day, sweep staging files a crash left behind. Real time, not
        // `now`: it's compared with modification dates.
        let hourAgo = Date().addingTimeInterval(-3_600)
        for name in fileNames(in: dir) where name.hasPrefix(stagingPrefix) {
            let staged = dir.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: staged.path))?[.modificationDate] as? Date
            if let modified, modified < hourAgo { try? fm.removeItem(at: staged) }
        }
    }

    /// Keeps a state.json this build can't use before a save replaces it.
    /// Undecodable bytes are copied, unless an identical copy is already
    /// kept; a file that can't even be read is hard-linked, unless a copy
    /// already links it (a retry). False when that failed.
    static func setAsideUnusable(_ url: URL, contents: Data?, now: Date) -> Bool {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let copies = corruptCopyURLs(in: dir)
        if let contents {
            if copies.contains(where: { (try? Data(contentsOf: $0)) == contents }) { return true }
        } else if let inode = fileNumber(url), copies.contains(where: { fileNumber($0) == inode }) {
            return true
        }
        let timestamp = stamp(now, withTime: true)
        var copy = dir.appendingPathComponent("state.corrupt.\(timestamp).json")
        var suffix = 2
        while fm.fileExists(atPath: copy.path) {
            copy = dir.appendingPathComponent("state.corrupt.\(timestamp)-\(suffix).json")
            suffix += 1
        }
        do {
            if let contents {
                try contents.write(to: copy, options: .atomic)
            } else if link(url.path, copy.path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            NSLog(
                "[Nirux Persistence] Keeping unusable state.json — failed to set it aside: %@",
                error.localizedDescription
            )
            return false
        }
        NSLog("[Nirux Persistence] state.json unusable — set aside as %@", copy.lastPathComponent)
        for stale in corruptCopyURLs(in: dir).dropFirst(maxCorruptCopies) where stale != copy {
            try? fm.removeItem(at: stale)
        }
        return true
    }

    private static func fileNumber(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? Int
    }

    private static func dailySnapshotName(_ date: Date) -> String {
        "state.daily.\(stamp(date, withTime: false)).json"
    }

    /// Newest first: zero-padded Gregorian dates sort chronologically by
    /// name. Names dated after `now` (the clock went back) rank as oldest,
    /// so they are pruned first and tried last.
    static func dailySnapshotURLs(in dir: URL, now: Date) -> [URL] {
        let today = dailySnapshotName(now)
        let names = fileNames(in: dir)
            .filter { $0.wholeMatch(of: /state\.daily\.[0-9]{4}-[0-9]{2}-[0-9]{2}\.json/) != nil }
            .sorted(by: >)
        return (names.filter { $0 <= today } + names.filter { $0 > today }).map { dir.appendingPathComponent($0) }
    }

    /// Newest first, by timestamp then by collision suffix (-2 … -10).
    private static func corruptCopyURLs(in dir: URL) -> [URL] {
        let copies = fileNames(in: dir).compactMap { name -> (name: String, stamp: String, suffix: Int)? in
            guard let match = name.wholeMatch(
                of: /state\.corrupt\.([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6})(?:-([0-9]+))?\.json/
            ) else { return nil }
            return (name, String(match.1), match.2.flatMap { Int($0) } ?? 1)
        }
        return copies
            .sorted { ($0.stamp, $0.suffix) > ($1.stamp, $1.suffix) }
            .map { dir.appendingPathComponent($0.name) }
    }

    private static func fileNames(in dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    /// `2026-09-26`, or `2026-09-26-143005` with the time, in local time.
    /// Always Gregorian: the user's calendar (Japanese, Buddhist…) would
    /// yield years that don't sort against names written before a switch.
    private static func stamp(_ date: Date, withTime: Bool) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        guard withTime else { return day }
        return day + String(format: "-%02d%02d%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }
}
