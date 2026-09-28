import Foundation

// MARK: - Files

extension MergeQueue {
    /// A project's queue files, next to its board.json: the journal and
    /// the saved state. A dry run writes its own, so it never touches a
    /// live queue's.
    struct Files: Equatable, Sendable {
        let journal: URL
        let state: URL

        /// Nil for a project id that isn't a plain name.
        init?(projectID: String, stateDirectory: URL, dryRun: Bool) {
            guard let folder = SpaceBrief.directory(spaceID: projectID, stateDirectory: stateDirectory) else { return nil }
            journal = folder.appendingPathComponent(dryRun ? "queue.dry-run.log" : "queue.log")
            state = folder.appendingPathComponent(dryRun ? "queue-state.dry-run.json" : "queue-state.json")
        }
    }
}

// MARK: - Saved state (section 3.5, restarts)

extension MergeQueue {
    /// The queue as saved after each step, so the board can say where a
    /// queue was when Nirux quit. A queue never resumes by itself: a saved
    /// running one reads as stopped, interrupted.
    struct SavedQueue: Codable, Equatable, Sendable {
        enum Status: String, Codable, Sendable {
            case running
            case stopping
            case stopped
            case finished
        }

        static let schemaVersion = 1
        static let maxFileBytes = 1_000_000

        var schemaVersion = SavedQueue.schemaVersion
        var repository: String
        var baseBranch: String
        var postMergeWorkflow: String?
        var dryRun: Bool
        var savedAt: Date
        var status: Status
        var stopReason: StopReason?
        var entries: [Entry]
        var current: Int?
        /// A mutating call sent whose effect GitHub hasn't shown yet: "merge
        /// of #52 at abc1234".
        var inFlight: String?

        init(engine: Engine, dryRun: Bool, savedAt: Date) {
            repository = engine.settings.repository
            baseBranch = engine.settings.baseBranch
            postMergeWorkflow = engine.settings.postMergeWorkflow
            self.dryRun = dryRun
            self.savedAt = savedAt
            entries = engine.entries
            current = engine.current
            inFlight = engine.unconfirmedMutation.map(Engine.describe)
            switch engine.phase {
            case .idle, .running, .paused: status = .running
            case .stopping: status = .stopping
            case .stopped(let reason):
                status = .stopped
                stopReason = reason
            case .finished: status = .finished
            }
        }

        var isRunning: Bool { status == .running || status == .stopping }

        /// The same queue, whenever it was saved: nothing to write again.
        func isSame(as other: SavedQueue?) -> Bool {
            guard let other else { return false }
            var copy = self
            copy.savedAt = other.savedAt
            return copy == other
        }

        /// "Interrupted while waiting for the nightly of #52": what a queue
        /// saved as running says after a restart.
        func interrupted() -> SavedQueue {
            guard isRunning else { return self }
            var saved = self
            let entry = current.flatMap { entries[safe: $0] }
            var message = "Interrupted while "
                + (entry?.stepDescription(workflow: postMergeWorkflow) ?? "starting") + ": Nirux quit."
            if let inFlight, let entry {
                message += " Its \(inFlight) was sent but not answered: check #\(entry.number) on GitHub."
            }
            let reason = StopReason(kind: .interrupted, message: message)
            saved.status = .stopped
            saved.stopReason = reason
            if let current, saved.entries.indices.contains(current), saved.entries[current].step.isActive {
                saved.entries[current].step = .stopped(reason)
            }
            return saved
        }

        static func load(from url: URL) -> SavedQueue? {
            guard let data = BoardConfigStore.read(url, maxBytes: maxFileBytes).contents,
                  let saved = try? decoder.decode(SavedQueue.self, from: data),
                  saved.schemaVersion <= schemaVersion
            else { return nil }
            return saved
        }

        func save(to url: URL) {
            guard var data = try? SavedQueue.encoder.encode(self) else { return }
            data.append(0x0A)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                NiruxDebugLog.log("MergeQueue: could not save \(url.path): \(error)")
            }
        }

        private static let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            return encoder
        }()

        private static let decoder: JSONDecoder = {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return decoder
        }()
    }

}

// MARK: - Journal (section 4)

extension MergeQueue {
    /// One JSON line per action in `queue.log`: time, pull request, step,
    /// the command a mutation ran, and what came of it. Capped at 1 MB,
    /// keeping one previous file. Never holds a token.
    struct Journal: Sendable {
        struct Line: Codable, Equatable, Sendable {
            let time: String
            let pr: Int?
            let step: String
            var command: String?
            let result: String
        }

        static let maxBytes = 1_000_000

        let url: URL
        var maxBytes = Journal.maxBytes

        var previousURL: URL { url.appendingPathExtension("1") }

        static func line(_ note: Note, at date: Date) -> Line {
            Line(time: timestamp(date), pr: note.number, step: note.step, command: nil, result: redacted(note.message))
        }

        static func line(
            number: Int?, step: String, command: String, result: String, at date: Date
        ) -> Line {
            Line(time: timestamp(date), pr: number, step: step, command: redacted(command), result: redacted(result))
        }

        static func timestamp(_ date: Date) -> String {
            ISO8601DateFormatter.string(from: date, timeZone: TimeZone(secondsFromGMT: 0)!, formatOptions: [.withInternetDateTime])
        }

        /// Tokens that an error message could echo are masked.
        static func redacted(_ text: String) -> String { MergeQueue.redacted(text) }

        /// Appends, moving the journal to its previous file first when the
        /// lines would take it past `maxBytes`. The files are 0600.
        func append(_ lines: [Line]) {
            guard !lines.isEmpty else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = Data()
            for line in lines {
                guard let encoded = try? encoder.encode(line) else { continue }
                data.append(encoded)
                data.append(0x0A)
            }
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                return NiruxDebugLog.log("MergeQueue: could not create \(url.deletingLastPathComponent().path): \(error)")
            }
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > 0, size + data.count > maxBytes {
                try? fileManager.removeItem(at: previousURL)
                try? fileManager.moveItem(at: url, to: previousURL)
            }
            let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else {
                return NiruxDebugLog.log("MergeQueue: could not open \(url.path): errno \(errno)")
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try? handle.write(contentsOf: data)
        }
    }
}

// MARK: - One queue per repository (section 3.4)

/// An exclusive `flock` on one file per repository, in a folder that
/// doesn't follow `NIRUX_STATE_DIR`: a live queue in any Nirux process
/// (the installed app, a bundle built by `scripts/bundle.sh`) holds it.
/// The kernel releases it when the process dies, so a reused pid can't
/// leave it stale. A lock is taken per open file, so two in one process
/// exclude each other too. Sendable so the controller can release it on
/// its file queue, after the last write; nothing else touches it then.
final class MergeQueueLock: @unchecked Sendable {
    let url: URL
    private var descriptor: Int32

    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nirux", isDirectory: true)
            .appendingPathComponent("locks", isDirectory: true)
    }

    /// `owner+name.lock`, lowercased: `+` is in neither.
    static func fileName(for repository: GitHubRepository) -> String {
        "\(repository.owner)+\(repository.name).lock"
    }

    private init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptor = descriptor
    }

    /// Nil when another queue holds it, or the file can't be opened.
    static func acquire(repository: GitHubRepository, folder: URL) -> MergeQueueLock? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName(for: repository))
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        // For whoever looks: which process holds it.
        ftruncate(descriptor, 0)
        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = pid.withCString { write(descriptor, $0, strlen($0)) }
        return MergeQueueLock(url: url, descriptor: descriptor)
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
