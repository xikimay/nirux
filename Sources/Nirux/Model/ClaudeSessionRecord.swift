import Foundation

/// What Claude Code's REPL says of itself in its session record,
/// `<config folder>/sessions/<pid>.json`: `idle`, `busy`, or `waiting`
/// on a dialog or screen of its own (`waitingFor`; a dialog kind it
/// doesn't name reads "permission prompt"). Claude Code 2.1 writes it on
/// each change once its REPL is mounted, never before: the trust and other
/// setup screens leave none. Not a documented API (`claude agents --json`
/// shows it), so a record missing or unreadable holds what waits on it.
struct ClaudeSessionRecord: Equatable, Sendable {
    let status: String?
    let waitingFor: String?
    /// When the REPL set its status, which Claude Code writes later, after
    /// the writes queued before it.
    let statusUpdatedAt: TimeInterval?
    /// When the file was last written.
    let writtenAt: TimeInterval

    /// How long its status must have held, and the file stayed unwritten:
    /// the dialogs that follow a resume open while the REPL mounts.
    static let settleTime: TimeInterval = 3
    /// Claude Code reads no larger one.
    static let maxBytes = 262_144

    enum Reading: Equatable, Sendable {
        case found(ClaudeSessionRecord)
        case missing
        case unreadable
    }

    init(status: String?, waitingFor: String?, statusUpdatedAt: TimeInterval?, writtenAt: TimeInterval) {
        self.status = status
        self.waitingFor = waitingFor
        self.statusUpdatedAt = statusUpdatedAt
        self.writtenAt = writtenAt
    }

    /// From the file's JSON, whose times are in milliseconds.
    init?(json: Data, writtenAt: TimeInterval) {
        struct File: Decodable {
            let status: String?
            let waitingFor: String?
            let statusUpdatedAt: Double?
        }
        guard let file = try? JSONDecoder().decode(File.self, from: json) else { return nil }
        self.init(
            status: file.status, waitingFor: file.waitingFor, statusUpdatedAt: file.statusUpdatedAt.map { $0 / 1000 },
            writtenAt: writtenAt
        )
    }

    /// The record of `pid` under the config folder of `environment`, that
    /// `claude`'s own, as Claude Code finds it: `CLAUDE_CONFIG_DIR`, else
    /// `.claude` in its home; a relative one against its working directory
    /// (`cwd`, read only then).
    static func url(pid: pid_t, environment: [String: String], cwd: () -> String? = { nil }) -> URL {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        var folder = ProjectMemory.configDirectory(home: home, environment: environment)
        if !folder.hasPrefix("/"), let cwd = cwd() { folder = (cwd as NSString).appendingPathComponent(folder) }
        return URL(fileURLWithPath: folder, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(pid).json")
    }

    /// Reads Claude Code's size at most, and opens without waiting (a FIFO
    /// would wait for a writer, a device never end): the main thread reads
    /// it, from a folder the agent names.
    static func read(at url: URL) -> Reading {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else { return errno == ENOENT ? .missing : .unreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, let data = try? handle.read(upToCount: maxBytes + 1), data.count <= maxBytes
        else { return .unreadable }
        let writtenAt = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        return ClaudeSessionRecord(json: data, writtenAt: writtenAt).map(Reading.found) ?? .unreadable
    }

    /// Written by `process`, whose start is known to the second, not by an
    /// earlier one under the same pid.
    func belongs(to process: ProcessInstance) -> Bool {
        statusUpdatedAt.map { $0 >= process.startedAt } ?? false
    }

    /// Whether it shows the REPL of `process` idle at its prompt, nothing
    /// waiting, settled for `settleTime` at `now`.
    func showsIdlePrompt(of process: ProcessInstance, now: TimeInterval) -> Bool {
        guard belongs(to: process), status == "idle", waitingFor == nil, let statusUpdatedAt else { return false }
        return now - max(statusUpdatedAt, writtenAt) >= Self.settleTime
    }

    /// Whether it shows the REPL of `process` waiting on a dialog or screen.
    func showsWait(of process: ProcessInstance) -> Bool {
        belongs(to: process) && (status == "waiting" || waitingFor != nil)
    }
}

extension ClaudeSessionRecord.Reading {
    func showsIdlePrompt(of process: ProcessInstance, now: TimeInterval) -> Bool {
        guard case .found(let record) = self else { return false }
        return record.showsIdlePrompt(of: process, now: now)
    }

    /// Whether the user's word that `process` sits at its prompt may stand:
    /// in place of a record only where there is none (another Claude Code),
    /// once it ran for `settleTime`; a record that exists must show its idle
    /// prompt.
    func allowsTypingOnSight(of process: ProcessInstance, now: TimeInterval) -> Bool {
        switch self {
        case .missing: return now - process.startedAt >= ClaudeSessionRecord.settleTime
        case .unreadable: return false
        case .found(let record): return record.showsIdlePrompt(of: process, now: now)
        }
    }

    func showsWait(of process: ProcessInstance) -> Bool {
        guard case .found(let record) = self else { return false }
        return record.showsWait(of: process)
    }

    /// Whether the log should say so: missing, unreadable at a second read
    /// in a row (`unreadableBefore`), or without a status of `process`'s own.
    func isIssue(for process: ProcessInstance, unreadableBefore: Bool) -> Bool {
        switch self {
        case .missing: return true
        case .unreadable: return unreadableBefore
        case .found(let record): return !record.belongs(to: process)
        }
    }

    /// For the missions log, one word: `idle/12s`, `waiting(dialog_open)/3s`,
    /// `stale` (an earlier process's, or one with no status yet), `missing`,
    /// `unreadable`.
    func facts(of process: ProcessInstance, now: TimeInterval) -> String {
        switch self {
        case .missing: return "missing"
        case .unreadable: return "unreadable"
        case .found(let record):
            guard record.belongs(to: process), let changedAt = record.statusUpdatedAt else { return "stale" }
            let waiting = record.waitingFor.map { "(\($0.replacingOccurrences(of: " ", with: "_")))" } ?? ""
            return "\(record.status ?? "-")\(waiting)/\(Int(min(max(now - changedAt, 0), 1e7)))s"
        }
    }
}
