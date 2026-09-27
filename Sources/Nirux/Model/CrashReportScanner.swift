import Foundation

/// One crash report found on disk, from its header alone.
struct CrashReportCandidate: Equatable, Sendable {
    let url: URL
    let header: CrashReportHeader
    /// The header's timestamp, or the file's modification date.
    let date: Date
    /// Orders reports written in the same instant: the later write is the
    /// later crash.
    let modified: Date?
    /// The incident ID, or the file name when the header has none.
    let key: String

    var fileName: String { url.lastPathComponent }

    /// Newest first. Reports of the same instant go by write order: the
    /// modification date, then the name's collision suffix (`-111448.ips`
    /// is written before `-111448.000.ips`, before `.001`).
    static func newerFirst(_ lhs: CrashReportCandidate, _ rhs: CrashReportCandidate) -> Bool {
        if lhs.date != rhs.date { return lhs.date > rhs.date }
        if let left = lhs.modified, let right = rhs.modified, left != right { return left > right }
        let left = collisionIndex(lhs.fileName), right = collisionIndex(rhs.fileName)
        if left != right { return left > right }
        return lhs.fileName > rhs.fileName
    }

    /// 0 for "….000.ips", -1 without a suffix.
    static func collisionIndex(_ name: String) -> Int {
        let parts = name.split(separator: ".")
        guard parts.count >= 3, parts.last == "ips", let suffix = parts.dropLast().last,
              suffix.allSatisfy({ $0.isASCII && $0.isNumber }), let index = Int(suffix)
        else { return -1 }
        return index
    }
}

/// The report files the crash notice has accounted for, with the incident
/// each one is about. A report is new when its incident was never seen,
/// whatever its date: reports don't reach the disk in the order they are
/// stamped. Files that are gone are forgotten, so the marker never
/// outgrows the reports folder.
struct CrashReportMarker: Codable, Equatable, Sendable {
    /// File name → incident key.
    var seen: [String: String] = [:]

    func isNew(_ candidate: CrashReportCandidate) -> Bool {
        !seen.values.contains(candidate.key)
    }

    /// The marker once `candidates` are accounted for, keeping only the
    /// files still in `listing`.
    func recording(_ candidates: [CrashReportCandidate], listing: Set<String>) -> CrashReportMarker {
        var next = CrashReportMarker(seen: seen.filter { listing.contains($0.key) })
        for candidate in candidates {
            next.seen[candidate.fileName] = candidate.key
        }
        return next
    }
}

/// What the notice shows for the crashes found since the last check.
struct CrashNotice: Equatable, Sendable {
    let report: CrashReport
    let reportURL: URL
    let date: Date
    /// App crashes found, this one included.
    let reportCount: Int

    var headline: String { CrashReportSummary.headline(for: report) }

    /// With the report's full path: an agent's file tools don't expand `~`.
    var summary: String {
        CrashReportSummary.text(for: report, reportPath: reportURL.path, otherReportCount: reportCount - 1)
    }

    /// The notice once a later check found `other` as well: the newest
    /// crash, counting both.
    func merged(with other: CrashNotice) -> CrashNotice {
        let newest = other.date >= date ? other : self
        return CrashNotice(
            report: newest.report, reportURL: newest.reportURL, date: newest.date,
            reportCount: reportCount + other.reportCount
        )
    }
}

/// Finds the crash reports macOS wrote for this app since the last check.
/// Only reads ~/Library/Logs/DiagnosticReports and the marker file: nothing
/// leaves the machine.
struct CrashReportScanner: Sendable {
    /// Reports of other builds (a `swift run` binary has no bundle ID, a dev
    /// bundle can have another) aren't this app's crashes.
    let bundleID: String
    /// Report files are named "<process>-<date>.ips".
    let processName: String
    let directory: URL
    let markerURL: URL

    /// A report whose body can't be read may still be being written: until
    /// it is this old, the next check looks at it again.
    static let writeGrace: TimeInterval = 120

    /// Written in the last `writeGrace` seconds. A date ahead of the clock
    /// isn't recent: waiting for it would wait for the clock.
    static func isRecent(_ candidate: CrashReportCandidate, now: Date) -> Bool {
        guard let modified = candidate.modified else { return false }
        let age = now.timeIntervalSince(modified)
        return age >= 0 && age < writeGrace
    }

    static var reportsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// The notice for the app's crashes reported since the last check, or
    /// nil. The first check only records where things stand: reports older
    /// than the feature are not news. A file recorded as seen is never
    /// opened again. A crash only shows once its report is recorded: when
    /// the marker can't be saved, nothing shows, rather than the same crash
    /// at every launch.
    func check(now: Date = Date()) -> CrashNotice? {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            // macOS creates the folder with the first report of the account.
            names = []
        } catch {
            // A folder that can't be read says nothing about what was seen.
            return nil
        }
        let listing = Set(names)
        guard let marker = loadMarker() else {
            _ = saveMarker(CrashReportMarker().recording(candidates(in: names), listing: listing))
            return nil
        }
        let unseenFiles = candidates(in: names, skipping: Set(marker.seen.keys))

        var deferred = Set<String>()
        var appCrashes: [(candidate: CrashReportCandidate, report: CrashReport)] = []
        for files in Self.byIncident(unseenFiles.filter(marker.isNew)) {
            autoreleasepool {
                guard let (candidate, report) = Self.bestReport(of: files) else { return }
                if !report.hasBody, files.contains(where: { Self.isRecent($0, now: now) }) {
                    deferred.insert(candidate.key)
                } else if !report.isCommandLineRun {
                    appCrashes.append((candidate, report))
                }
            }
        }
        let next = marker.recording(unseenFiles.filter { !deferred.contains($0.key) }, listing: listing)
        guard next == marker || saveMarker(next), let newest = appCrashes.first else { return nil }
        return CrashNotice(
            report: newest.report, reportURL: newest.candidate.url, date: newest.candidate.date,
            reportCount: appCrashes.count
        )
    }

    /// Crash reports of this app among `names`, newest first; files in
    /// `seenFiles` aren't opened again. One incident can have two files.
    func candidates(in names: [String], skipping seenFiles: Set<String> = []) -> [CrashReportCandidate] {
        names.filter { name in
            name.hasPrefix(processName + "-") && name.hasSuffix(".ips") && !seenFiles.contains(name)
        }.compactMap { name -> CrashReportCandidate? in
            let url = directory.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let header = Self.readHeader(at: url),
                  header.isCrash, header.bundleID == bundleID,
                  let date = header.timestamp ?? values.contentModificationDate
            else { return nil }
            return CrashReportCandidate(
                url: url, header: header, date: date,
                modified: values.contentModificationDate, key: header.incidentID ?? name
            )
        }.sorted(by: CrashReportCandidate.newerFirst)
    }

    /// The files of each incident, newest first; incidents in the order of
    /// their newest file.
    static func byIncident(_ candidates: [CrashReportCandidate]) -> [[CrashReportCandidate]] {
        var order: [String] = []
        var files: [String: [CrashReportCandidate]] = [:]
        for candidate in candidates {
            if files[candidate.key] == nil { order.append(candidate.key) }
            files[candidate.key, default: []].append(candidate)
        }
        return order.compactMap { files[$0] }
    }

    /// The newest of an incident's files that reads whole, or its newest
    /// file when none does.
    private static func bestReport(of files: [CrashReportCandidate]) -> (CrashReportCandidate, CrashReport)? {
        var newest: (CrashReportCandidate, CrashReport)?
        for file in files {
            let report = (try? Data(contentsOf: file.url)).flatMap(CrashReportParser.report(from:))
                ?? CrashReport(header: file.header)
            if report.hasBody { return (file, report) }
            if newest == nil { newest = (file, report) }
        }
        return newest
    }

    /// Headers fit in the first few kilobytes; a whole report is hundreds.
    private static func readHeader(at url: URL) -> CrashReportHeader? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 16 * 1024) else { return nil }
        return CrashReportParser.header(from: prefix)
    }

    /// Nil when there is no marker yet, or it can't be read: both mean
    /// start over from the reports on disk now.
    func loadMarker() -> CrashReportMarker? {
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? JSONDecoder().decode(CrashReportMarker.self, from: data)
    }

    private func saveMarker(_ marker: CrashReportMarker) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
            return true
        } catch {
            NSLog("[Nirux CrashReport] Failed to save marker: %@", error.localizedDescription)
            return false
        }
    }
}

extension CrashReportScanner {
    /// The scanner for this app's reports; nil for a binary without a
    /// bundle ID (`swift run`), whose reports can't be told apart.
    static func forRunningApp(bundle: Bundle = .main) -> CrashReportScanner? {
        guard let bundleID = bundle.bundleIdentifier else { return nil }
        return CrashReportScanner(
            bundleID: bundleID,
            processName: bundle.executableURL?.lastPathComponent ?? ProcessInfo.processInfo.processName,
            directory: reportsDirectory,
            markerURL: Persistence.stateDirectory.appendingPathComponent("crash-reports-seen.json")
        )
    }
}
