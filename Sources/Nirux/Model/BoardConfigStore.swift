import Foundation

/// Reads and writes a project's `board.json` (see BoardConfig), next to its
/// brief in `<state dir>/projects/<space id>/`. It follows ProjectStore's
/// rules:
/// - decoding is lenient (see `BoardConfig.init(from:)`);
/// - a file this build can't write back as it found it is read but never
///   written: a newer `schemaVersion`, keys it doesn't know, a merge method
///   it doesn't support. The merge queue won't start with it either
///   (`Loaded.canStartQueue`), since the settings it doesn't know would be
///   ignored;
/// - an unreadable file is copied aside (`board.corrupt.<time>-<random>.json`)
///   before Save replaces it, and never replaced if the copy fails. The copy
///   is made at Save rather than at load, so opening the form again and
///   again doesn't pile up copies;
/// - anything but a regular file (a folder, a link, a FIFO), or a file over
///   `SpaceBrief.maxFileBytes`, is neither read nor replaced;
/// - writes are atomic, and the file is 0600.
///
/// Deleting the space leaves the file behind, like the brief. Nothing here
/// is bound to the main actor, so the merge queue can read it anywhere.
struct BoardConfigStore: Sendable {
    static let fileName = "board.json"
    static let maxFileBytes = SpaceBrief.maxFileBytes

    /// Posted after each save, on the thread that saved, with the space's id
    /// as `userInfo["spaceID"]`.
    static let didSaveNotification = Notification.Name("NiruxBoardConfigDidSave")

    let spaceID: String
    let fileURL: URL

    /// Nil for a space id that isn't a plain name (see `SpaceBrief.directory`).
    init?(spaceID: String, stateDirectory: URL = Persistence.stateDirectory) {
        guard let folder = SpaceBrief.directory(spaceID: spaceID, stateDirectory: stateDirectory) else { return nil }
        self.spaceID = spaceID
        fileURL = folder.appendingPathComponent(Self.fileName)
    }

    // MARK: - Loading

    struct Loaded: Equatable, Sendable {
        enum Status: Equatable, Sendable {
            /// No file yet: the board isn't configured.
            case missing
            case loaded
            /// Not a config this build can read (bad JSON, a value of the
            /// wrong type). Save copies it aside first.
            case unreadable
            /// This build never writes it.
            case readOnly(ReadOnlyReason)
        }

        /// What the file holds. Nil when it is missing, unreadable, or not
        /// read at all (see `ReadOnlyReason`).
        var config: BoardConfig?
        var status: Status
        /// The bytes read, so `save(_:replacing:)` can tell whether the file
        /// changed since. Nil when it is missing or wasn't read.
        var contents: Data?

        var isWritable: Bool {
            if case .readOnly = status { return false }
            return true
        }

        /// Why the merge queue can't start with this file. Empty when it can:
        /// the file is writable, its values are valid (`BoardConfig.problems`)
        /// and its post-merge workflow is chosen.
        var queueStartProblems: [String] {
            switch status {
            case .missing:
                return ["The board isn’t configured yet: open Board Settings…"]
            case .unreadable:
                return ["board.json can’t be read: open Board Settings… to replace it."]
            case .readOnly(let reason):
                return [reason.message]
            case .loaded:
                guard let config else { return ["The board isn’t configured yet: open Board Settings…"] }
                var problems = config.problems
                if config.postMergeWorkflow == .unset {
                    problems.append("Choose the post-merge workflow in Board Settings…, or None.")
                }
                return problems
            }
        }

        var canStartQueue: Bool { queueStartProblems.isEmpty }

        /// What the merge queue (B2, B3) runs with, read at Start. Nil unless
        /// `canStartQueue`.
        var queueSettings: BoardConfig.QueueSettings? {
            guard canStartQueue, let config, let repository = config.repository,
                  let gitHubRepository = config.gitHubRepository, let baseBranch = config.baseBranch
            else { return nil }
            let postMergeWorkflow: String?
            switch config.postMergeWorkflow {
            case .unset: return nil
            case .noWorkflow: postMergeWorkflow = nil
            case .workflow(let file): postMergeWorkflow = file
            }
            return BoardConfig.QueueSettings(
                repository: repository,
                gitHubRepository: gitHubRepository,
                baseBranch: baseBranch,
                requiredChecks: config.requiredChecks,
                postMergeWorkflow: postMergeWorkflow,
                mergeMethod: config.mergeMethod,
                checksTimeoutMinutes: config.checksTimeoutMinutes,
                postMergeTimeoutMinutes: config.postMergeTimeoutMinutes
            )
        }
    }

    enum ReadOnlyReason: Equatable, Sendable {
        case newerSchema(Int)
        case unknownKeys([String])
        case unsupportedMergeMethod(String)
        case notARegularFile
        case tooLarge

        var message: String {
            switch self {
            case .newerSchema(let version):
                return "board.json was saved by a newer Nirux (schema \(version)). This version won’t change it, "
                    + "and its merge queue won’t start with it: update Nirux, or delete the file to start over."
            case .unknownKeys(let keys):
                return "board.json has settings this version of Nirux doesn’t know (\(keys.joined(separator: ", "))). "
                    + "It won’t change the file, and its merge queue won’t start with it: "
                    + "update Nirux, or remove them from the file."
            case .unsupportedMergeMethod(let method):
                return "board.json sets the merge method “\(method)”. Nirux only merges with merge or squash, "
                    + "so it won’t change the file and its merge queue won’t start: edit mergeMethod in the file."
            case .notARegularFile:
                return "board.json isn’t a regular file (a folder or a link, say). Nirux won’t read or replace it."
            case .tooLarge:
                return "board.json is larger than \(BoardConfigStore.maxFileBytes / 1_000_000) MB. "
                    + "Nirux won’t read or replace it."
            }
        }
    }

    func load() -> Loaded {
        switch read() {
        case .missing: return Loaded(config: nil, status: .missing)
        case .notARegularFile: return Loaded(config: nil, status: .readOnly(.notARegularFile))
        case .tooLarge: return Loaded(config: nil, status: .readOnly(.tooLarge))
        case .unreadableBytes: return Loaded(config: nil, status: .unreadable)
        case .data(let data): return Self.decode(data)
        }
    }

    static func decode(_ data: Data) -> Loaded {
        let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let config = try? JSONDecoder().decode(BoardConfig.self, from: data)
        let schema = top.map(schema(of:)) ?? .invalid
        // A newer schema may have changed what a key holds: it is never
        // written, even when this build can't read it at all.
        if case .newer(let version) = schema {
            return Loaded(config: config, status: .readOnly(.newerSchema(version)), contents: data)
        }
        guard let top, let config, schema == .current else {
            return Loaded(config: nil, status: .unreadable, contents: data)
        }
        let unknownKeys = Set(top.keys).subtracting(BoardConfig.CodingKeys.allCases.map(\.rawValue))
        if !unknownKeys.isEmpty {
            return Loaded(config: config, status: .readOnly(.unknownKeys(unknownKeys.sorted())), contents: data)
        }
        // Read as `merge`, which the queue must not use in its place. An
        // empty one means not set, like the other keys.
        if let method = top["mergeMethod"] as? String, !method.isEmpty, BoardConfig.MergeMethod(rawValue: method) == nil {
            return Loaded(config: config, status: .readOnly(.unsupportedMergeMethod(method)), contents: data)
        }
        return Loaded(config: config, status: .loaded, contents: data)
    }

    private enum Schema: Equatable {
        case current
        case newer(Int)
        /// Neither absent nor a number: a string, a boolean, an object.
        case invalid
    }

    /// Missing or null is the first schema. Any number above the current
    /// one is newer, even one that isn't a whole number.
    private static func schema(of top: [String: Any]) -> Schema {
        guard let value = top["schemaVersion"], !(value is NSNull) else { return .current }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return .invalid }
        let version = number.doubleValue
        if version > Double(BoardConfig.schemaVersion) {
            return .newer(Int(exactly: version.rounded(.down)) ?? Int.max)
        }
        return version == version.rounded(.down) ? .current : .invalid
    }

    // MARK: - Saving

    enum SaveError: Error, Equatable {
        /// Values `BoardConfig.problems` refuses.
        case invalid([String])
        /// The file isn't what `replacing` read: another Nirux saved it since.
        case changedSinceLoaded
        /// What's on disk now is read-only for this build.
        case readOnly(ReadOnlyReason)
        case couldNotSetAside(String)
        case couldNotWrite(String)

        var message: String {
            switch self {
            case .invalid(let problems):
                return problems.joined(separator: "\n")
            case .changedSinceLoaded:
                return "board.json changed since this form opened, perhaps saved by another Nirux. "
                    + "Close the form and open it again to see what it holds now."
            case .readOnly(let reason):
                return reason.message
            case .couldNotSetAside(let error):
                return "board.json can’t be read, and Nirux couldn’t keep a copy of it before replacing it: \(error)"
            case .couldNotWrite(let error):
                return "Nirux couldn’t save board.json: \(error)"
            }
        }
    }

    /// Writes `config` atomically, unless `problems` refuses it. Reads the
    /// file again first. With `expected` (what the caller loaded), a file
    /// changed since is left alone. A file that is read-only now is left
    /// alone too, and an unreadable one is copied aside before it is
    /// replaced. Returns that copy, if any.
    func save(_ config: BoardConfig, replacing expected: Loaded? = nil) -> Result<URL?, SaveError> {
        let problems = config.problems
        guard problems.isEmpty else { return .failure(.invalid(problems)) }
        let current = read()
        if let expected, current.contents != expected.contents {
            return .failure(.changedSinceLoaded)
        }
        var copy: URL?
        switch current {
        case .missing:
            break
        case .notARegularFile:
            return .failure(.readOnly(.notARegularFile))
        case .tooLarge:
            return .failure(.readOnly(.tooLarge))
        case .unreadableBytes:
            switch setAside(nil) {
            case .success(let url): copy = url
            case .failure(let error): return .failure(error)
            }
        case .data(let data):
            switch Self.decode(data).status {
            case .readOnly(let reason):
                return .failure(.readOnly(reason))
            case .unreadable:
                switch setAside(data) {
                case .success(let url): copy = url
                case .failure(let error): return .failure(error)
                }
            case .missing, .loaded:
                break
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            var data = try encoder.encode(config)
            data.append(0x0A)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            Self.restrictPermissions(fileURL)
            NotificationCenter.default.post(name: Self.didSaveNotification, object: nil, userInfo: ["spaceID": spaceID])
            return .success(copy)
        } catch {
            // The file is as it was: a retry mustn't leave another copy.
            if let copy { try? FileManager.default.removeItem(at: copy) }
            NiruxDebugLog.log("BoardConfigStore: could not save \(fileURL.path): \(error)")
            return .failure(.couldNotWrite(error.localizedDescription))
        }
    }

    // MARK: - Files

    private enum ReadResult {
        case missing
        case notARegularFile
        case tooLarge
        /// A regular file whose bytes can't be read (permissions, say).
        case unreadableBytes
        case data(Data)

        var contents: Data? {
            if case .data(let data) = self { return data }
            return nil
        }
    }

    /// Opened without following a link and without blocking, then checked on
    /// the open file: a FIFO swapped in after a check would block the read.
    private func read() -> ReadResult {
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .missing
            case ELOOP: return .notARegularFile
            default: return .unreadableBytes
            }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .unreadableBytes }
        guard info.st_mode & S_IFMT == S_IFREG else { return .notARegularFile }
        guard info.st_size <= Self.maxFileBytes else { return .tooLarge }
        let data: Data
        do {
            data = try handle.read(upToCount: Self.maxFileBytes + 1) ?? Data()
        } catch {
            return .unreadableBytes
        }
        return data.count <= Self.maxFileBytes ? .data(data) : .tooLarge
    }

    /// Keeps an unreadable file's bytes next to it before Save replaces it.
    private func setAside(_ data: Data?) -> Result<URL, SaveError> {
        let stamp = Int(Date().timeIntervalSince1970)
        let copy = fileURL.deletingLastPathComponent()
            .appendingPathComponent("board.corrupt.\(stamp)-\(UUID().uuidString.prefix(8)).json")
        do {
            if let data {
                try data.write(to: copy, options: .atomic)
            } else {
                try FileManager.default.copyItem(at: fileURL, to: copy)
            }
            Self.restrictPermissions(copy)
            return .success(copy)
        } catch {
            NiruxDebugLog.log("BoardConfigStore: could not set aside \(fileURL.path): \(error)")
            return .failure(.couldNotSetAside(error.localizedDescription))
        }
    }

    private static func restrictPermissions(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
