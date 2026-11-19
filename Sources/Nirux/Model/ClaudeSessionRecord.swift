import Foundation

/// What Claude Code's REPL says of itself in its session record,
/// `<config folder>/sessions/<pid>.json`: `idle`, `busy`, or `waiting`
/// on a dialog or screen of its own (`waitingFor`; a dialog kind it
/// doesn't name reads "permission prompt"). Claude Code 2.1 writes it on
/// each change once its REPL is mounted, never before: the trust and other
/// setup screens leave none. Not a documented API (`claude agents --json`
/// shows it), so a record missing or unreadable holds what waits on it.
struct ClaudeSessionRecord: Equatable, Sendable {
    let pid: pid_t
    /// When Claude Code wrote it first.
    let startedAt: TimeInterval
    let status: String?
    let waitingFor: String?
    let statusUpdatedAt: TimeInterval?

    /// How long its status must have held: the dialogs that follow a
    /// resume open while the REPL mounts.
    static let settleTime: TimeInterval = 3

    enum Reading: Equatable, Sendable {
        case found(ClaudeSessionRecord)
        case missing
        case unreadable
    }

    init(pid: pid_t, startedAt: TimeInterval, status: String?, waitingFor: String?, statusUpdatedAt: TimeInterval?) {
        self.pid = pid
        self.startedAt = startedAt
        self.status = status
        self.waitingFor = waitingFor
        self.statusUpdatedAt = statusUpdatedAt
    }

    /// From the file's JSON, whose times are in milliseconds.
    init?(json: Data) {
        struct File: Decodable {
            let pid: pid_t
            let startedAt: Double
            let status: String?
            let waitingFor: String?
            let statusUpdatedAt: Double?
        }
        guard let file = try? JSONDecoder().decode(File.self, from: json) else { return nil }
        self.init(
            pid: file.pid, startedAt: file.startedAt / 1000, status: file.status, waitingFor: file.waitingFor,
            statusUpdatedAt: file.statusUpdatedAt.map { $0 / 1000 }
        )
    }

    /// The record of `pid` under the config folder of `environment`, that
    /// `claude`'s own, as Claude Code finds it: `CLAUDE_CONFIG_DIR`, else
    /// `.claude` in its home.
    static func url(pid: pid_t, environment: [String: String]) -> URL {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return URL(fileURLWithPath: ProjectMemory.configDirectory(home: home, environment: environment), isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(pid).json")
    }

    static func read(at url: URL) -> Reading {
        do {
            return ClaudeSessionRecord(json: try Data(contentsOf: url)).map(Reading.found) ?? .unreadable
        } catch CocoaError.fileReadNoSuchFile {
            return .missing
        } catch {
            return .unreadable
        }
    }

    /// Written by `process`, not by an earlier one under the same pid (a
    /// second's slack for the clocks).
    func belongs(to process: ProcessInstance) -> Bool {
        pid == process.pid && startedAt >= process.startedAt - 1
    }

    /// Whether it shows the REPL of `process` idle at its prompt, nothing
    /// waiting, its status unchanged for `settleTime` at `now`.
    func showsIdlePrompt(of process: ProcessInstance, now: TimeInterval) -> Bool {
        guard belongs(to: process), status == "idle", waitingFor == nil, let statusUpdatedAt else { return false }
        return now - statusUpdatedAt >= Self.settleTime
    }
}

extension ClaudeSessionRecord.Reading {
    func showsIdlePrompt(of process: ProcessInstance, now: TimeInterval) -> Bool {
        guard case .found(let record) = self else { return false }
        return record.showsIdlePrompt(of: process, now: now)
    }

    /// For the missions log, one word: `idle/12s`, `waiting(dialog_open)/3s`,
    /// `stale` (an earlier process's), `missing`, `unreadable`.
    func facts(of process: ProcessInstance, now: TimeInterval) -> String {
        switch self {
        case .missing: return "missing"
        case .unreadable: return "unreadable"
        case .found(let record) where !record.belongs(to: process): return "stale"
        case .found(let record):
            let waiting = record.waitingFor.map { "(\($0.replacingOccurrences(of: " ", with: "_")))" } ?? ""
            let age = record.statusUpdatedAt.map { String(Int(min(max(now - $0, 0), 1e7))) + "s" } ?? "-"
            return "\(record.status ?? "-")\(waiting)/\(age)"
        }
    }
}
