import Foundation

/// Feeds each project's journal from its sessions' turns
/// (docs/project-memory-tree.md, section 2.2): on a turn's end (`Stop`,
/// `StopFailure`) and a session's end (`SessionEnd`), the session's
/// transcript is read from where the journal left it, once the file has
/// been quiet for `quietInterval` (at most `maxWait`): Claude Code writes it
/// asynchronously, after the hook may already have run. Reads and writes
/// run on one serial queue, never on the main thread.
@MainActor
final class ProjectHistoryCenter {
    struct Timing: Sendable {
        var quietInterval: TimeInterval = 0.5
        var maxWait: TimeInterval = 5
        var pollInterval: TimeInterval = 0.25
    }

    private let worker: Worker

    init(stateDirectory: @escaping @Sendable () -> URL = { Persistence.stateDirectory }, timing: Timing = Timing()) {
        worker = Worker(stateDirectory: stateDirectory, timing: timing)
    }

    /// A turn of the session ended (Stop, StopFailure). Claude Code marks
    /// each turn's end in the transcript; the read takes the turns marked.
    func turnEnded(spaceID: String, transcriptPath: String, sessionID: String?) {
        Self.enqueue(worker) { $0.request(spaceID: spaceID, path: transcriptPath, session: sessionID, sessionEnded: false) }
    }

    /// The session ended: its last turn is over, whatever it was doing.
    func sessionEnded(spaceID: String, transcriptPath: String, sessionID: String?) {
        Self.enqueue(worker) { $0.request(spaceID: spaceID, path: transcriptPath, session: sessionID, sessionEnded: true) }
    }

    /// At launch: turns written while Nirux was closed. Only transcripts
    /// the journal already reads, or sessions started after history was
    /// turned on, so nothing from before is imported.
    func catchUp(_ sessions: [CatchUp]) {
        Self.enqueue(worker) { worker in
            for session in sessions {
                worker.catchUp(session)
            }
        }
    }

    /// A Claude session now writing for a project, its transcript when
    /// known.
    struct Joining: Equatable, Sendable {
        let sessionID: String
        let transcriptPath: String?
    }

    /// Sessions now writing for the project: a workspace moved here from
    /// `oldSpaceID`, or a session resumed here. Their turns that end after
    /// `date` are the project's; the project they left first journals those
    /// that ended before.
    func sessionsJoined(spaceID: String, sessions: [Joining], at date: Date, leaving oldSpaceID: String? = nil) {
        Self.enqueue(worker) { $0.join(spaceID: spaceID, sessions: sessions, at: date, leaving: oldSpaceID) }
    }

    /// A session the launch catch-up reads.
    struct CatchUp: Equatable, Sendable {
        let spaceID: String
        let transcriptPath: String
        let sessionID: String
        let startedAt: TimeInterval
        let isRunning: Bool
    }

    /// Turns history on for a project: transcripts of sessions running now
    /// are read from their current end, so their past isn't imported.
    func turnOn(spaceID: String, runningTranscripts: [String], completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        Self.enqueue(worker) { worker in
            let done = worker.turnOn(spaceID: spaceID, runningTranscripts: runningTranscripts)
            DispatchQueue.main.async { completion(done) }
        }
    }

    /// Runs `completion` on the main thread once every request made so far,
    /// and every wait for a quiet file, is done. Tests.
    func whenIdle(_ completion: @escaping @MainActor @Sendable () -> Void) {
        Self.enqueue(worker) { $0.whenIdle { DispatchQueue.main.async { completion() } } }
    }

    /// The journal's messages, read from disk. Tests.
    nonisolated static func messages(spaceID: String, stateDirectory: URL) -> [ProjectHistory.Message] {
        guard let folder = ProjectHistory.folder(spaceID: spaceID, stateDirectory: stateDirectory) else { return [] }
        return ProjectHistoryJournal.messages(in: folder)
    }

    /// Not from a closure formed in this main-actor class: Swift 6.1 would
    /// isolate it to the main actor and trap on the worker's queue.
    private nonisolated static func enqueue(_ worker: Worker, _ work: @escaping @Sendable (Worker) -> Void) {
        worker.queue.async { work(worker) }
    }

    /// The center's state, used only on its queue.
    final class Worker: @unchecked Sendable {
        let queue = DispatchQueue(label: "nirux.project-history", qos: .utility)
        /// Read once: a test's `NIRUX_STATE_DIR` restored later never
        /// sends a delayed read to the real state.
        private let directory: URL
        func stateDirectory() -> URL { directory }
        private let timing: Timing
        /// Open journals, by space id.
        private var journals: [String: ProjectHistoryJournal] = [:]
        /// Transcripts waiting for their file to be quiet, by path.
        private var waits: [String: Wait] = [:]
        private var idleCallbacks: [@Sendable () -> Void] = []

        private struct Wait {
            var spaceID: String
            let session: String?
            var sessionEnded: Bool
            let started: TimeInterval
            var stamp: FileStamp?
            var quietSince: TimeInterval
        }

        private struct FileStamp: Equatable {
            let size: Int64
            let modified: timespec

            static func == (lhs: FileStamp, rhs: FileStamp) -> Bool {
                lhs.size == rhs.size && lhs.modified.tv_sec == rhs.modified.tv_sec
                    && lhs.modified.tv_nsec == rhs.modified.tv_nsec
            }

            init?(path: String) {
                var info = stat()
                guard lstat(path, &info) == 0 else { return nil }
                size = Int64(info.st_size)
                modified = info.st_mtimespec
            }
        }

        init(stateDirectory: @escaping @Sendable () -> URL, timing: Timing) {
            directory = stateDirectory()
            self.timing = timing
        }

        private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

        func request(spaceID: String, path: String, session: String?, sessionEnded: Bool) {
            guard ProjectHistory.isEnabled(spaceID: spaceID, stateDirectory: stateDirectory()) else { return }
            if var wait = waits[path] {
                wait.spaceID = spaceID
                wait.sessionEnded = wait.sessionEnded || sessionEnded
                waits[path] = wait
                return
            }
            let start = now()
            waits[path] = Wait(
                spaceID: spaceID, session: session, sessionEnded: sessionEnded, started: start,
                stamp: FileStamp(path: path), quietSince: start
            )
            poll(path)
        }

        private func poll(_ path: String) {
            guard var wait = waits[path] else { return }
            let time = now()
            let stamp = FileStamp(path: path)
            if stamp != wait.stamp {
                wait.stamp = stamp
                wait.quietSince = time
                waits[path] = wait
            }
            let quiet = time - wait.quietSince >= timing.quietInterval
            if quiet || time - wait.started >= timing.maxWait {
                waits[path] = nil
                // A Stop's turn is closed by Claude Code's mark; only the
                // session's end closes a turn without one.
                read(spaceID: wait.spaceID, path: path, session: wait.session, lastTurnEnded: wait.sessionEnded && quiet)
                runIdleCallbacksIfIdle()
                return
            }
            queue.asyncAfter(deadline: .now() + timing.pollInterval) { [weak self] in self?.poll(path) }
        }

        func catchUp(_ session: CatchUp) {
            let spaceID = session.spaceID, path = session.transcriptPath, startedAt = session.startedAt
            let directory = stateDirectory()
            guard ProjectHistory.isEnabled(spaceID: spaceID, stateDirectory: directory),
                  journal(for: spaceID) != nil else { return }
            let known = offset(for: path) > 0
            let enabledAt = ProjectHistory.enabledDate(spaceID: spaceID, stateDirectory: directory)?.timeIntervalSince1970
            guard known || (enabledAt.map { startedAt >= $0 } ?? false) else { return }
            read(spaceID: spaceID, path: path, session: session.sessionID, lastTurnEnded: !session.isRunning)
        }

        func join(spaceID: String, sessions: [ProjectHistoryCenter.Joining], at date: Date, leaving oldSpaceID: String?) {
            if let oldSpaceID, oldSpaceID != spaceID {
                for session in sessions {
                    guard let path = session.transcriptPath else { continue }
                    read(spaceID: oldSpaceID, path: path, session: session.sessionID, lastTurnEnded: false, until: date)
                }
            }
            guard ProjectHistory.isEnabled(spaceID: spaceID, stateDirectory: stateDirectory()),
                  let journal = journal(for: spaceID) else { return }
            for session in sessions { journal.join(session.sessionID, at: date) }
        }

        func turnOn(spaceID: String, runningTranscripts: [String]) -> Bool {
            let directory = stateDirectory()
            guard let folder = ProjectHistory.folder(spaceID: spaceID, stateDirectory: directory),
                  let journal = journal(for: spaceID, creating: true) else { return false }
            for path in runningTranscripts {
                var info = stat()
                guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
                guard journal.start(path, at: UInt64(info.st_size)) else { return false }
            }
            let stamp = Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            return ProjectHistory.writeAtomically(stamp, to: folder.appendingPathComponent(ProjectHistory.enabledFileName))
        }

        func whenIdle(_ callback: @escaping @Sendable () -> Void) {
            idleCallbacks.append(callback)
            runIdleCallbacksIfIdle()
        }

        private func runIdleCallbacksIfIdle() {
            guard waits.isEmpty else { return }
            let callbacks = idleCallbacks
            idleCallbacks = []
            callbacks.forEach { $0() }
        }

        private func journal(for spaceID: String, creating: Bool = false) -> ProjectHistoryJournal? {
            if let journal = journals[spaceID] { return journal }
            guard let folder = ProjectHistory.folder(spaceID: spaceID, stateDirectory: stateDirectory()) else { return nil }
            var info = stat()
            guard creating || lstat(folder.path, &info) == 0 else { return nil }
            guard let journal = ProjectHistoryJournal.open(folder: folder) else { return nil }
            journals[spaceID] = journal
            return journal
        }

        /// - Parameter until: turns that ended later are another project's
        ///   (the session moved there): left for it, not read past.
        private func read(spaceID: String, path: String, session: String?, lastTurnEnded: Bool, until: Date? = nil) {
            guard ProjectHistory.isEnabled(spaceID: spaceID, stateDirectory: stateDirectory()),
                  let journal = journal(for: spaceID) else {
                journals[spaceID] = nil
                return
            }
            let offset = offset(for: path)
            guard let result = ProjectHistory.TurnReader.read(
                path: path, from: offset, lastTurnEnded: lastTurnEnded, session: session
            ) else {
                NiruxDebugLog.log("ProjectHistory: \(path) can't be read from \(offset) (gone, replaced or shorter)")
                return
            }
            if result.skippedLongLine { NiruxDebugLog.log("ProjectHistory: skipped a line too long in \(path)") }
            // Only what was said since history was turned on (the import
            // brings the past), and since the session joined the project.
            let sessionID = session ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let since = max(
                ProjectHistory.enabledDate(spaceID: spaceID, stateDirectory: stateDirectory()) ?? .distantPast,
                journal.joined(sessionID) ?? .distantPast
            )
            for turn in result.turns {
                let ended = turn.messages.last?.date ?? .distantPast
                if let until, ended > until { return }
                guard ended >= since else {
                    journal.advance(path, to: turn.end)
                    continue
                }
                let messages = turn.messages.map { $0.withText(ProjectHistory.withholdingSecrets($0.text)) }
                journal.append(messages, from: path, end: turn.end)
                // A turn written before a crash isn't written again: what
                // counts is that the journal now reads past it.
                guard journal.offset(for: path) >= turn.end else {
                    NiruxDebugLog.log("ProjectHistory: could not append to \(journal.folder.path)")
                    return
                }
            }
            journal.advance(path, to: result.resumeOffset)
        }

        /// Where reading `path` starts: the furthest any project's journal
        /// reached, so a session whose workspace moved to another project
        /// doesn't give the new one the turns the old one has.
        private func offset(for path: String) -> UInt64 {
            openEnabledJournals()
            return journals.values.map { $0.offset(for: path) }.max() ?? 0
        }

        private var openedEnabled = false

        /// Every project whose history is on, once.
        private func openEnabledJournals() {
            guard !openedEnabled else { return }
            openedEnabled = true
            let projects = stateDirectory().appendingPathComponent("projects", isDirectory: true)
            for spaceID in (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
            where ProjectHistory.isEnabled(spaceID: spaceID, stateDirectory: stateDirectory()) {
                _ = journal(for: spaceID)
            }
        }

        private static func modificationDate(of url: URL) -> TimeInterval? {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            return TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        }
    }
}
