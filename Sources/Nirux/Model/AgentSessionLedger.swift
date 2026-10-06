import Foundation

/// The agent sessions of each space, kept after their worktree is gone:
/// Claude files its transcripts by folder (`~/.claude/projects/<cwd>/`),
/// so once a worktree is cleaned up nothing else ties its sessions to the
/// project. See "History" in docs/projects.md.
///
/// Built from the hook events Nirux already routes (see
/// `AgentSessionRecord.applying`). Only the column's own agent creates a
/// record, so a `claude -p` run by a tool or a review pipeline never shows
/// up. A column runs one session at a time: a new one ends the previous,
/// and so does its agent exiting (`closeSessions(notRunningIn:at:)`). A
/// running session follows its workspace into another space; an ended one
/// stays where it was.
///
/// Files: `<state dir>/projects/<space id>/sessions.jsonl`, next to the
/// space's brief. One JSON line per change, holding the whole record; a
/// session's last line wins. Rules:
/// - lines are appended; once superseded lines outnumber the records (and
///   `minSupersededLines`), or a space holds more than `maxRecordsPerSpace`
///   sessions, the file is rewritten atomically with one line per session
///   (`compacted`): open sessions, then the most recently active ended ones
///   that were prompted;
/// - a line this build can't fully read (a newer `v`, a key or a value it
///   doesn't know) is kept as it is through rewrites, and its session is
///   never updated here, so a rollback strips nothing;
/// - a line that isn't a session (cut by a crash, garbage) is dropped at
///   load; past `maxDroppedLines` the file is set aside first
///   (`sessions.corrupt.<time>-<random>.jsonl`), as is a file over
///   `maxFileBytes`. Anything but a regular file is neither read nor
///   written;
/// - a file another writer appended to since it was read (a second Nirux on
///   the same state directory) is no longer rewritten by this one;
/// - files are 0600.
///
/// Files load together, on the first event or query: a session found open
/// in a file was cut off by a quit or a crash, and is closed at its last
/// activity. A restored column's agent reopens it. Nothing here throws:
/// the history must never stop Nirux from launching.
@MainActor
final class AgentSessionLedger {
    nonisolated static let schemaVersion = 1
    nonisolated static let fileName = "sessions.jsonl"
    nonisolated static let maxRecordsPerSpace = 500
    /// What a rewrite past `maxRecordsPerSpace` keeps, so the next one is
    /// dozens of sessions away.
    nonisolated static let compactedRecordsPerSpace = 450
    /// Superseded lines a file may hold beyond one per record before it is
    /// rewritten.
    nonisolated static let minSupersededLines = 256
    nonisolated static let maxFileBytes = 4_000_000
    nonisolated static let maxDroppedLines = 10

    /// What `sessions(inSpace:matching:)` returns, newest activity first.
    struct Query: Equatable, Sendable {
        enum State: Sendable { case any, active, ended }
        enum PullRequestFilter: Sendable { case any, with, without }

        var state = State.any
        var pullRequest = PullRequestFilter.any
        var agent: AgentHookEvent.Kind?
        /// Sessions never prompted have nothing to read or resume.
        var includesUnprompted = false
        var limit: Int?
    }

    private struct SpaceFile {
        let url: URL
        var records: [String: AgentSessionRecord] = [:]
        /// Lines this build can't fully read, by session: written back as
        /// they are.
        var foreignLines: [String: Data] = [:]
        /// Lines in the file, superseded ones included.
        var lineCount = 0
        /// What the file should weigh: anything else means another writer.
        var expectedSize = 0
        var endsWithNewline = true
        var isWritable = true
        /// Off after a failed rewrite or another writer's lines.
        var mayCompact = true
    }

    private struct OpenSession {
        let spaceID: String
        let process: ProcessInstance
    }

    private let stateDirectory: () -> URL
    private var loadedDirectory: URL?
    private var spaces: [String: SpaceFile] = [:]
    /// Every open session, with the agent process that proved it. Memory
    /// only: no agent outlives Nirux.
    private var openSessions: [String: OpenSession] = [:]

    init(stateDirectory: @escaping () -> URL = { Persistence.stateDirectory }) {
        self.stateDirectory = stateDirectory
    }

    // MARK: - Recording

    /// Apply one event of a session in a column whose workspace is in
    /// `spaceID`.
    func record(_ observation: AgentSessionObservation, spaceID: String) {
        loadIfNeeded()
        let key = observation.key
        guard !spaces.values.contains(where: { $0.foreignLines[key] != nil }) else { return }
        let existing = locate(key)
        guard let updated = AgentSessionRecord.applying(observation, to: existing?.record) else { return }
        var target = observation.isFromColumnAgent ? spaceID : existing?.spaceID ?? spaceID
        if !prepareSpace(target) {
            guard let existing else { return }
            target = existing.spaceID
        }
        if let existing, existing.spaceID != target {
            // The stale line left behind loses to this one at load.
            spaces[existing.spaceID]?.records[key] = nil
        }
        if updated.isActive, let process = observation.agentProcess {
            // One session per column: /clear, /resume or a new agent left
            // the previous one.
            if let agentUUID = updated.agentUUID {
                closeOpenSessions(at: observation.timestamp) { $0.key != key && $0.agentUUID == agentUUID }
            }
            openSessions[key] = OpenSession(spaceID: target, process: process)
        }
        store(updated, in: target)
    }

    /// End every open session whose agent no longer runs in its column.
    /// `live` maps each column's `NIRUX_AGENT_UUID` to the agent process in
    /// its foreground.
    func closeSessions(notRunningIn live: [String: ProcessInstance], at time: TimeInterval) {
        closeOpenSessions(at: time) { [openSessions] record in
            guard let agentUUID = record.agentUUID, let open = openSessions[record.key] else { return true }
            return live[agentUUID] != open.process
        }
    }

    /// Nirux quits: every agent goes with its terminal.
    func closeAllSessions(at time: TimeInterval) {
        closeOpenSessions(at: time) { _ in true }
    }

    /// A pull request found for `branch` in the checkout at `worktreeRoot`:
    /// every session that ran there learns it, ended ones included (the
    /// pull request often comes after the session). One that already knows
    /// another pull request keeps it. Only loaded files are touched.
    func notePullRequest(_ pullRequest: AgentSessionRecord.PullRequest, branch: String, worktreeRoot: String) {
        for (spaceID, space) in spaces {
            for var record in space.records.values {
                guard let checkout = record.checkout, checkout.branch == branch,
                      checkout.worktreeRoot == worktreeRoot,
                      record.pullRequest == nil || record.pullRequest?.number == pullRequest.number,
                      record.pullRequest != pullRequest
                else { continue }
                record.pullRequest = pullRequest
                store(record, in: spaceID)
            }
        }
    }

    // MARK: - Reading

    func sessions(inSpace spaceID: String, matching query: Query = Query()) -> [AgentSessionRecord] {
        loadIfNeeded()
        return Self.matching(spaces[spaceID].map { Array($0.records.values) } ?? [], query)
    }

    func session(agent: AgentHookEvent.Kind, sessionID: String) -> AgentSessionRecord? {
        loadIfNeeded()
        return locate(AgentSessionRecord.key(agent: agent.rawValue, sessionID: sessionID))?.record
    }

    nonisolated static func matching(_ records: [AgentSessionRecord], _ query: Query) -> [AgentSessionRecord] {
        var result = records.filter { record in
            switch query.state {
            case .any: break
            case .active: guard record.isActive else { return false }
            case .ended: guard !record.isActive else { return false }
            }
            switch query.pullRequest {
            case .any: break
            case .with: guard record.pullRequest != nil else { return false }
            case .without: guard record.pullRequest == nil else { return false }
            }
            if let agent = query.agent, record.agent != agent { return false }
            return query.includesUnprompted || record.hasConversation
        }
        result.sort(by: isMoreRecent)
        if let limit = query.limit { result = Array(result.prefix(max(0, limit))) }
        return result
    }

    /// Each Claude session's space, by session id: the space of its most
    /// recent record across the state folder's files (a moved workspace
    /// leaves a stale line in its former space's file), and whether that
    /// record is open. Read from disk, off the main thread.
    nonisolated static func claudeSessions(stateDirectory: URL) -> [String: (spaceID: String, isActive: Bool)] {
        let projects = stateDirectory.appendingPathComponent("projects", isDirectory: true)
        var latest: [String: (spaceID: String, record: AgentSessionRecord)] = [:]
        for spaceID in ((try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []).sorted() {
            guard let url = fileURL(spaceID: spaceID, stateDirectory: stateDirectory),
                  let data = HistorySearch.readRegularFile(url.path, maxBytes: maxFileBytes) else { continue }
            for record in parse(data).records.values where record.agent == .claude {
                if let kept = latest[record.sessionID], !isMoreRecent(record, kept.record) { continue }
                latest[record.sessionID] = (spaceID, record)
            }
        }
        return latest.mapValues { ($0.spaceID, $0.record.isActive) }
    }

    nonisolated private static func isMoreRecent(_ lhs: AgentSessionRecord, _ rhs: AgentSessionRecord) -> Bool {
        if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
        return lhs.key < rhs.key
    }

    // MARK: - Records in memory

    private func locate(_ key: String) -> (spaceID: String, record: AgentSessionRecord)? {
        for (spaceID, space) in spaces {
            if let record = space.records[key] { return (spaceID, record) }
        }
        return nil
    }

    private func closeOpenSessions(at time: TimeInterval, where shouldClose: (AgentSessionRecord) -> Bool) {
        for (key, open) in openSessions {
            guard var record = spaces[open.spaceID]?.records[key], record.isActive else {
                openSessions[key] = nil
                continue
            }
            guard shouldClose(record) else { continue }
            record.endedAt = max(time, record.lastActivityAt)
            store(record, in: open.spaceID)
        }
    }

    private func store(_ record: AgentSessionRecord, in spaceID: String) {
        guard spaces[spaceID] != nil else { return }
        spaces[spaceID]?.records[record.key] = record
        if !record.isActive { openSessions[record.key] = nil }
        append(record, in: spaceID)
    }

    // MARK: - Loading

    nonisolated static func fileURL(spaceID: String, stateDirectory: URL) -> URL? {
        SpaceBrief.directory(spaceID: spaceID, stateDirectory: stateDirectory)?.appendingPathComponent(fileName)
    }

    /// Load every space's file the first time, and again if the state
    /// directory changed (tests).
    private func loadIfNeeded() {
        let directory = stateDirectory().standardizedFileURL
        guard loadedDirectory != directory else { return }
        loadedDirectory = directory
        spaces = [:]
        openSessions = [:]
        let projects = directory.appendingPathComponent("projects", isDirectory: true)
        for spaceID in ((try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []).sorted() {
            guard let url = Self.fileURL(spaceID: spaceID, stateDirectory: directory) else { continue }
            Self.sweepTemporaryFiles(in: url.deletingLastPathComponent())
            if let space = Self.load(url) { spaces[spaceID] = space }
        }
        dropMovedCopies()
    }

    /// A session that moved with its workspace left a stale line in its
    /// former space's file: the most recent copy wins.
    private func dropMovedCopies() {
        var seen: [String: String] = [:]
        for spaceID in spaces.keys.sorted() {
            for (key, record) in spaces[spaceID]?.records ?? [:] {
                guard let other = seen[key], let kept = spaces[other]?.records[key] else {
                    seen[key] = spaceID
                    continue
                }
                if Self.isMoreRecent(record, kept) {
                    spaces[other]?.records[key] = nil
                    seen[key] = spaceID
                } else {
                    spaces[spaceID]?.records[key] = nil
                }
            }
        }
    }

    /// A space without a file yet gets one on its first record.
    private func prepareSpace(_ spaceID: String) -> Bool {
        if spaces[spaceID] != nil { return true }
        guard let directory = loadedDirectory,
              let url = Self.fileURL(spaceID: spaceID, stateDirectory: directory) else { return false }
        spaces[spaceID] = SpaceFile(url: url)
        return true
    }

    /// Nil when there is no file.
    private static func load(_ url: URL) -> SpaceFile? {
        switch BoardConfigStore.read(url, maxBytes: maxFileBytes) {
        case .missing:
            return nil
        case .notARegularFile, .unreadableBytes:
            NiruxDebugLog.log("AgentSessionLedger: \(url.path) can't be read; left alone")
            return SpaceFile(url: url, isWritable: false)
        case .tooLarge:
            return SpaceFile(url: url, isWritable: setAside(url))
        case .data(let data):
            let parsed = parse(data)
            var space = SpaceFile(
                url: url, records: parsed.records, foreignLines: parsed.foreignLines,
                lineCount: parsed.lineCount, expectedSize: data.count, endsWithNewline: parsed.endsWithNewline
            )
            for (key, record) in space.records where record.isActive {
                space.records[key]?.endedAt = record.lastActivityAt
            }
            if parsed.unreadableLines > maxDroppedLines {
                guard setAside(url) else { return SpaceFile(url: url, isWritable: false) }
                space.expectedSize = 0
            }
            if parsed.unreadableLines > 0 || !parsed.endsWithNewline || needsCompaction(space) {
                compact(&space)
            }
            return space
        }
    }

    struct Parsed: Equatable {
        var records: [String: AgentSessionRecord] = [:]
        var foreignLines: [String: Data] = [:]
        var lineCount = 0
        var unreadableLines = 0
        var endsWithNewline = true
    }

    nonisolated static func parse(_ data: Data) -> Parsed {
        var parsed = Parsed()
        parsed.endsWithNewline = data.isEmpty || data.last == 0x0A
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A) {
            parsed.lineCount += 1
            let lineData = Data(line)
            guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let agent = object["agent"] as? String, let sessionID = object["sessionID"] as? String,
                  !agent.isEmpty, !sessionID.isEmpty,
                  let version = object["v"] as? Int, version > 0
            else {
                parsed.unreadableLines += 1
                continue
            }
            let key = AgentSessionRecord.key(agent: agent, sessionID: sessionID)
            if version <= schemaVersion, hasOnlyKnownKeys(object),
               let record = try? decoder.decode(AgentSessionRecord.self, from: lineData) {
                parsed.records[key] = record
                parsed.foreignLines[key] = nil
            } else {
                parsed.foreignLines[key] = lineData
                parsed.records[key] = nil
            }
        }
        return parsed
    }

    /// Keys a newer build added without a new `v` would be lost in a
    /// rewrite: such a line stays foreign.
    nonisolated private static func hasOnlyKnownKeys(_ object: [String: Any]) -> Bool {
        let recordKeys = Set(AgentSessionRecord.CodingKeys.allCases.map(\.rawValue))
        let checkoutKeys = Set(AgentSessionRecord.Checkout.CodingKeys.allCases.map(\.rawValue))
        let pullRequestKeys = Set(AgentSessionRecord.PullRequest.CodingKeys.allCases.map(\.rawValue))
        guard Set(object.keys).isSubset(of: recordKeys) else { return false }
        if let checkout = object["checkout"] as? [String: Any], !Set(checkout.keys).isSubset(of: checkoutKeys) {
            return false
        }
        if let pullRequest = object["pullRequest"] as? [String: Any],
           !Set(pullRequest.keys).isSubset(of: pullRequestKeys) {
            return false
        }
        return true
    }

    // MARK: - Writing

    private static func needsCompaction(_ space: SpaceFile) -> Bool {
        let lines = space.records.count + space.foreignLines.count
        return space.lineCount - lines > max(minSupersededLines, lines)
            || space.records.count > maxRecordsPerSpace
    }

    /// What a rewrite keeps, oldest activity first: open sessions, then the
    /// most recently active ended ones that have a conversation.
    nonisolated static func compacted(_ records: [AgentSessionRecord], limit: Int) -> [AgentSessionRecord] {
        let open = records.filter(\.isActive)
        let ended = records.filter { !$0.isActive && $0.hasConversation }.sorted(by: isMoreRecent)
        let kept = open + ended.prefix(max(0, limit - open.count))
        return kept.sorted { isMoreRecent($1, $0) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func line(_ record: AgentSessionRecord) -> Data? {
        guard var data = try? encoder.encode(record) else { return nil }
        data.append(0x0A)
        return data
    }

    private static func compact(_ space: inout SpaceFile) {
        guard space.isWritable, space.mayCompact else { return }
        guard fileSize(space.url) == space.expectedSize else {
            NiruxDebugLog.log("AgentSessionLedger: another writer changed \(space.url.path); no rewrite")
            space.mayCompact = false
            return
        }
        let limit = space.records.count > maxRecordsPerSpace ? compactedRecordsPerSpace : maxRecordsPerSpace
        let kept = compacted(Array(space.records.values), limit: limit)
        var data = Data()
        for record in kept {
            if let line = line(record) { data.append(line) }
        }
        for (_, line) in space.foreignLines.sorted(by: { $0.key < $1.key }) {
            data.append(line)
            data.append(0x0A)
        }
        guard createFolder(of: space.url), writeAtomically(data, to: space.url) else {
            NiruxDebugLog.log("AgentSessionLedger: could not rewrite \(space.url.path)")
            space.mayCompact = false
            return
        }
        space.records = Dictionary(kept.map { ($0.key, $0) }, uniquingKeysWith: { $1 })
        space.lineCount = kept.count + space.foreignLines.count
        space.expectedSize = data.count
        space.endsWithNewline = true
    }

    private func append(_ record: AgentSessionRecord, in spaceID: String) {
        guard var space = spaces[spaceID], space.isWritable, var line = Self.line(record) else { return }
        defer { spaces[spaceID] = space }
        // A line cut by a crash that a rewrite couldn't drop.
        if !space.endsWithNewline { line.insert(0x0A, at: 0) }
        guard Self.createFolder(of: space.url) else { return }
        let descriptor = open(space.url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            let error = errno
            NiruxDebugLog.log("AgentSessionLedger: could not open \(space.url.path): errno \(error)")
            if error == ELOOP || error == ENXIO || error == EISDIR { space.isWritable = false }
            return
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            space.isWritable = false
            return
        }
        fchmod(descriptor, 0o600)
        guard Self.writeAll(line, to: descriptor) else {
            let error = errno
            NiruxDebugLog.log("AgentSessionLedger: could not append to \(space.url.path): errno \(error)")
            // Part of the line may have been written: the next one starts
            // on its own line.
            space.endsWithNewline = false
            return
        }
        space.lineCount += 1
        space.expectedSize += line.count
        space.endsWithNewline = true
        if Self.needsCompaction(space) { Self.compact(&space) }
    }

    private static func fileSize(_ url: URL) -> Int {
        var info = stat()
        return lstat(url.path, &info) == 0 ? Int(info.st_size) : 0
    }

    private static func createFolder(of url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return true
        } catch {
            NiruxDebugLog.log("AgentSessionLedger: could not create \(url.deletingLastPathComponent().path): \(error)")
            return false
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(descriptor, pointer, remaining)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                pointer += written
                remaining -= written
            }
            return true
        }
    }

    private static let temporaryPrefix = ".\(fileName).tmp-"

    /// Owner-only, complete before it replaces the file.
    private static func writeAtomically(_ data: Data, to url: URL) -> Bool {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(temporaryPrefix + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        let written = writeAll(data, to: descriptor) && fsync(descriptor) == 0
        close(descriptor)
        guard written, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        return true
    }

    /// Rewrites cut short by a crash.
    private static func sweepTemporaryFiles(in folder: URL) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix(temporaryPrefix) {
            unlink(folder.appendingPathComponent(name).path)
        }
    }

    /// Moves a file out of the way, for manual recovery.
    private static func setAside(_ url: URL) -> Bool {
        let copy = url.deletingLastPathComponent().appendingPathComponent(
            "sessions.corrupt.\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).jsonl"
        )
        guard rename(url.path, copy.path) == 0 else {
            let error = errno
            NiruxDebugLog.log("AgentSessionLedger: could not set aside \(url.path): errno \(error)")
            return false
        }
        chmod(copy.path, 0o600)
        NiruxDebugLog.log("AgentSessionLedger: set \(url.path) aside as \(copy.lastPathComponent)")
        return true
    }
}
