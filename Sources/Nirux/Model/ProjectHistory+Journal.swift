import Foundation

/// A project's journal (`ProjectHistory`), open for writing. One app writes
/// a project's journal: `open` takes the folder's `lock` with
/// `flock(LOCK_EX | LOCK_NB)` and keeps it until the journal is closed, so a
/// second app on the same state directory gets nil and writes nothing.
///
/// Rules (docs/project-memory-tree.md, section 2.4):
/// - append-only: a line is never edited or deleted;
/// - each line is one `write` of a whole line, then `fsync`, before
///   `append` returns: a crash loses nothing written;
/// - at load, a line that isn't a message (cut by a crash) is skipped, and
///   a file not ending in a newline gets one, so the next line starts on
///   its own;
/// - a line goes to the file of the local day it was written; ids run
///   across files;
/// - files 0600, folders 0700. Anything but a regular file is neither read
///   nor written.
///
/// Used from one queue at a time; not thread-safe.
final class ProjectHistoryJournal: @unchecked Sendable {
    static let logFolderName = "log"
    static let stateFileName = "state.json"
    static let lockFileName = "lock"

    let folder: URL
    /// The next message's id: one past the last message read or written.
    private(set) var count = 0
    /// Lines skipped at load: not a message.
    private(set) var skippedLines = 0
    /// Per transcript path, where reading starts next: past the last turn
    /// journaled, or where history was turned on.
    private var offsets: [String: UInt64] = [:]
    /// When sessions joined the project (`join`).
    private var joins: [String: Date] = [:]
    /// Transcript lines already journaled, by their `uuid`.
    private var writtenLines: Set<String> = []
    private let lockDescriptor: Int32
    private let now: () -> Date
    private let calendar: Calendar

    private init(folder: URL, lockDescriptor: Int32, now: @escaping () -> Date, calendar: Calendar) {
        self.folder = folder
        self.lockDescriptor = lockDescriptor
        self.now = now
        self.calendar = calendar
    }

    deinit {
        close(lockDescriptor)
    }

    /// Creates the folders, takes the lock and reads what was written. Nil
    /// when another process holds the lock or the folder can't be used.
    static func open(
        folder: URL, now: @escaping () -> Date = Date.init, calendar: Calendar = localGregorian
    ) -> ProjectHistoryJournal? {
        let log = folder.appendingPathComponent(logFolderName, isDirectory: true)
        guard makeFolder(folder), makeFolder(log) else { return nil }
        let descriptor = Darwin.open(
            folder.appendingPathComponent(lockFileName).path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600
        )
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        let journal = ProjectHistoryJournal(folder: folder, lockDescriptor: descriptor, now: now, calendar: calendar)
        journal.load()
        return journal
    }

    // MARK: - Offsets

    /// Where reading `path` starts next.
    func offset(for path: String) -> UInt64 {
        offsets[path] ?? 0
    }

    /// Reading went on to `offset` without journaling anything (a turn
    /// with no message): not written, so it is read again after a relaunch.
    func advance(_ path: String, to offset: UInt64) {
        offsets[path] = max(offsets[path] ?? 0, offset)
    }

    /// Reading `path` starts at `offset`, its end when history was turned
    /// on while it ran: written to `state.json`.
    @discardableResult
    func start(_ path: String, at offset: UInt64) -> Bool {
        var state = Self.readState(in: folder)
        state.starts[path] = offset
        guard Self.writeState(state, in: folder) else { return false }
        advance(path, to: offset)
        return true
    }

    /// A transcript line (or memory file version) already journaled.
    func hasWritten(_ uuid: String) -> Bool {
        writtenLines.contains(uuid)
    }

    /// When Claude session `session` joined the project (a workspace moved
    /// here, a session resumed here): its turns that ended before are
    /// another project's, or from before.
    func joined(_ session: String) -> Date? {
        joins[session]
    }

    /// History turned on again: joins recorded while it was on before
    /// don't apply to what was said since.
    @discardableResult
    func clearJoins() -> Bool {
        var state = Self.readState(in: folder)
        guard state.joins?.isEmpty == false else { return true }
        state.joins = nil
        guard Self.writeState(state, in: folder) else { return false }
        joins = [:]
        return true
    }

    /// Records, in `state.json`, that `session` joined the project at
    /// `date`.
    @discardableResult
    func join(_ session: String, at date: Date) -> Bool {
        var state = Self.readState(in: folder)
        let time = max(date.timeIntervalSince1970, state.joins?[session] ?? 0)
        state.joins = (state.joins ?? [:]).merging([session: time]) { _, new in new }
        guard Self.writeState(state, in: folder) else { return false }
        joins[session] = Date(timeIntervalSince1970: time)
        return true
    }

    // MARK: - Appending

    /// Appends a turn's messages, in order, read from `path` up to `end`,
    /// in one write. Only the last message carries `end`: a turn cut short
    /// by a crash is read again, and its messages already written (the same
    /// transcript line) aren't written twice. Returns the messages written.
    @discardableResult
    func append(_ messages: [ProjectHistory.NewMessage], from path: String?, end: UInt64?) -> [ProjectHistory.Message] {
        var entries: [ProjectHistory.Message] = []
        var lines: [Data] = []
        for (index, message) in messages.enumerated() {
            if path != nil, let uuid = message.uuid, writtenLines.contains(uuid) { continue }
            let rendered = ProjectHistory.Message.render(
                kind: message.kind, branch: message.branch, from: message.from, text: message.text
            )
            let source = path.map {
                ProjectHistory.Message.Source(path: $0, uuid: message.uuid, end: index == messages.count - 1 ? end : nil)
            }
            let entry = ProjectHistory.Message(
                i: count + entries.count, kind: message.kind, branch: message.branch, from: message.from,
                text: message.text, size: rendered.utf8.count, date: message.date, session: message.session, source: source
            )
            guard let data = try? Self.encoder.encode(entry) else { break }
            entries.append(entry)
            lines.append(data)
        }
        let whole = appendLines(lines, in: Self.logFolderName)
        let written = Array(entries.prefix(whole))
        count += written.count
        for entry in written {
            if let uuid = entry.source?.uuid { writtenLines.insert(uuid) }
        }
        if let path, let end, written.count == entries.count { advance(path, to: end) }
        return written
    }

    /// Writes the lines in one `write`, then `fsync`s, and returns how many
    /// were written whole. A cut line is ended, so the next starts on its
    /// own; loading skips it. A file that doesn't end with a newline (cut
    /// earlier) gets one first.
    private func appendLines(_ lines: [Data], in subfolder: String) -> Int {
        guard !lines.isEmpty else { return 0 }
        let url = currentFile(in: subfolder)
        let descriptor = Darwin.open(
            url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600
        )
        guard descriptor >= 0 else { return 0 }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return 0 }
        var data = Data()
        if info.st_size > 0 {
            var last: UInt8 = 0
            let reader = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if reader >= 0 {
                if pread(reader, &last, 1, info.st_size - 1) == 1, last != 0x0A { data.append(0x0A) }
                close(reader)
            }
        }
        let prefix = data.count
        var ends: [Int] = []
        for line in lines {
            data.append(line)
            data.append(0x0A)
            ends.append(data.count)
        }
        let written = data.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var result: Int
            repeat { result = write(descriptor, base, buffer.count) } while result < 0 && errno == EINTR
            return result
        }
        guard written > prefix else { return 0 }
        if written < data.count {
            _ = "\n".withCString { write(descriptor, $0, 1) }
        }
        if fsync(descriptor) != 0 {
            NiruxDebugLog.log("ProjectHistoryJournal: fsync failed for \(url.path), errno \(errno)")
        }
        return ends.filter { $0 <= written }.count
    }

    private func currentFile(in subfolder: String) -> URL {
        let parts = calendar.dateComponents([.year, .month, .day], from: now())
        let name = String(format: "%04d-%02d-%02d.jsonl", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return folder.appendingPathComponent(subfolder, isDirectory: true).appendingPathComponent(name)
    }

    /// Day files are named in the Gregorian calendar, in local time.
    static var localGregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    // MARK: - Loading

    private func load() {
        let log = folder.appendingPathComponent(Self.logFolderName, isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: log.path)) ?? [])
            .filter { $0.hasSuffix(".jsonl") && !$0.hasPrefix(".") }.sorted()
        for name in names {
            let url = log.appendingPathComponent(name)
            guard Self.isRegularFile(url), var data = try? Data(contentsOf: url) else { continue }
            if let last = data.last, last != 0x0A {
                Self.endWithNewline(url)
                data.append(0x0A)
            }
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard let message = try? Self.decoder.decode(ProjectHistory.Message.self, from: Data(line)) else {
                    skippedLines += 1
                    continue
                }
                count = max(count, message.i + 1)
                if let source = message.source {
                    if let uuid = source.uuid { writtenLines.insert(uuid) }
                    if let end = source.end { advance(source.path, to: end) }
                }
            }
        }
        if skippedLines > 0 {
            NiruxDebugLog.log("ProjectHistoryJournal: skipped \(skippedLines) lines in \(log.path)")
        }
        let state = Self.readState(in: folder)
        for (path, offset) in state.starts { advance(path, to: offset) }
        joins = (state.joins ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// Every message, oldest first: for tests and the passes that read the
    /// journal whole.
    func messages() -> [ProjectHistory.Message] {
        Self.messages(in: folder)
    }

    /// Every message of the journal in `folder`, oldest first, read without
    /// the writer's lock: readers never write.
    static func messages(in folder: URL) -> [ProjectHistory.Message] {
        let log = folder.appendingPathComponent(logFolderName, isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: log.path)) ?? [])
            .filter { $0.hasSuffix(".jsonl") && !$0.hasPrefix(".") }.sorted()
        var all: [ProjectHistory.Message] = []
        for name in names {
            let url = log.appendingPathComponent(name)
            guard isRegularFile(url), let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                if let message = try? decoder.decode(ProjectHistory.Message.self, from: Data(line)) {
                    all.append(message)
                }
            }
        }
        return all.sorted { $0.i < $1.i }
    }

    // MARK: - Files

    private static func makeFolder(_ url: URL) -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info.st_mode & S_IFMT == S_IFDIR }
        return (try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )) != nil
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    private static func endWithNewline(_ url: URL) {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        _ = "\n".withCString { write(descriptor, $0, 1) }
        fsync(descriptor)
        close(descriptor)
    }

    private struct State: Codable {
        var v = 1
        var starts: [String: UInt64] = [:]
        /// Seconds since 1970, by Claude session id.
        var joins: [String: Double]?
    }

    private static func readState(in folder: URL) -> State {
        let url = folder.appendingPathComponent(stateFileName)
        guard isRegularFile(url), let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    /// Complete before it replaces the file.
    private static func writeState(_ state: State, in folder: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        let url = folder.appendingPathComponent(stateFileName)
        let temporary = folder.appendingPathComponent(".\(stateFileName).tmp-\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) } == data.count
            && fsync(descriptor) == 0
        close(descriptor)
        guard written, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        return true
    }

    // MARK: - JSON

    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(dateStyle))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? dateStyle.parse(text) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "date"))
        }
        return decoder
    }()
}
