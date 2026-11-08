import Foundation

/// Reads and writes a project's `board.json` (see BoardConfig), next to its
/// brief in `<state dir>/projects/<space id>/`. Schema 1 holds one config,
/// the space's repository; schema 2 one per git anchor (see BoardSections),
/// written only once the file needs it, so an older Nirux keeps using a
/// space with one repository. It follows ProjectStore's rules:
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
    /// The newest schema this build reads and writes. It writes schema 1
    /// whenever the file holds one config an older build can place.
    static let schemaVersion = 2

    /// Where a repository's config sits in the file.
    enum Slot: Hashable, Sendable {
        /// Schema 1's one config: the space's repository, which
        /// `BoardSections` gives to one of its git anchors.
        case legacy
        /// A schema 2 entry: the git anchor with this common git dir.
        case anchor(commonDir: String)
    }

    /// One repository's config. Schema 2 writes it as the config's keys
    /// plus `commonDir` (none for `.legacy`), in a `repositories` list.
    struct Entry: Equatable, Sendable {
        static let listKey = "repositories"
        static let commonDirKey = "commonDir"
        /// Never remove one: a file that has it would turn read-only.
        static let knownKeys = Set(BoardConfig.CodingKeys.allCases.map(\.rawValue))
            .subtracting([BoardConfig.CodingKeys.schemaVersion.rawValue]).union([commonDirKey])

        var slot: Slot
        var config: BoardConfig
    }

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

        /// The config this is about: a schema 1 file's one config, or one
        /// repository's (`view(for:)`). Nil when there is none, or the file
        /// is unreadable or wasn't read at all (see `ReadOnlyReason`).
        var config: BoardConfig?
        var status: Status
        /// The bytes read, so `save(_:replacing:)` can tell whether the file
        /// changed since. Nil when it is missing or wasn't read.
        var contents: Data?
        /// Every config the file holds, in its order.
        var entries: [Entry] = []

        /// The same file, about the config in `slot` (none yet: nil).
        func view(for slot: Slot) -> Loaded {
            var view = self
            view.config = entries.first { $0.slot == slot }?.config
            return view
        }

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
        let schema = top.map(schema(of:)) ?? .invalid
        // A newer schema may have changed what a key holds: it is never
        // written, even when this build can't read it at all. What it reads
        // as this build's schemas is shown.
        if case .newer(let version) = schema {
            let config = try? JSONDecoder().decode(BoardConfig.self, from: data)
            var loaded = Loaded(config: config, status: .readOnly(.newerSchema(version)), contents: data)
            if let top, top[Entry.listKey] != nil {
                loaded.entries = (try? repositoryEntries(top).entries) ?? []
            } else {
                loaded.entries = config.map { [Entry(slot: .legacy, config: $0)] } ?? []
            }
            return loaded
        }
        guard let top, case .version(let version) = schema else {
            return Loaded(config: nil, status: .unreadable, contents: data)
        }
        if version == 1 {
            guard let config = try? JSONDecoder().decode(BoardConfig.self, from: data) else {
                return Loaded(config: nil, status: .unreadable, contents: data)
            }
            var loaded = Loaded(config: config, status: .loaded, contents: data, entries: [Entry(slot: .legacy, config: config)])
            let unknownKeys = Set(top.keys).subtracting(BoardConfig.CodingKeys.allCases.map(\.rawValue))
            if !unknownKeys.isEmpty {
                loaded.status = .readOnly(.unknownKeys(unknownKeys.sorted()))
            } else if let method = unsupportedMergeMethod(top) {
                loaded.status = .readOnly(.unsupportedMergeMethod(method))
            }
            return loaded
        }
        guard let read = try? repositoryEntries(top) else {
            return Loaded(config: nil, status: .unreadable, contents: data)
        }
        var loaded = Loaded(config: nil, status: .loaded, contents: data, entries: read.entries)
        let unknownKeys = Set(top.keys).subtracting(["schemaVersion", Entry.listKey]).union(read.unknownKeys)
        if !unknownKeys.isEmpty {
            loaded.status = .readOnly(.unknownKeys(unknownKeys.sorted()))
        } else if let method = read.unsupportedMergeMethod {
            loaded.status = .readOnly(.unsupportedMergeMethod(method))
        }
        return loaded
    }

    /// A merge method this build doesn't run: read as `merge`, which the
    /// queue must not use in its place. An empty one means not set, like
    /// the other keys.
    private static func unsupportedMergeMethod(_ object: [String: Any]) -> String? {
        guard let method = object["mergeMethod"] as? String, !method.isEmpty,
              BoardConfig.MergeMethod(rawValue: method) == nil
        else { return nil }
        return method
    }

    private struct RepositoryEntries {
        var entries: [Entry] = []
        var unknownKeys: Set<String> = []
        var unsupportedMergeMethod: String?
    }

    private struct NotAnEntryList: Error {}

    /// Schema 2's `repositories`: each an object with a `commonDir` (an
    /// absolute path), or none for the space's repository before it had
    /// anchors, at most once each. Anything else can't be written back as
    /// read: the file is unreadable.
    private static func repositoryEntries(_ top: [String: Any]) throws -> RepositoryEntries {
        var read = RepositoryEntries()
        let list = top[Entry.listKey]
        if list == nil || list is NSNull { return read }
        guard let objects = list as? [Any] else { throw NotAnEntryList() }
        var slots: Set<Slot> = []
        for value in objects {
            guard let object = value as? [String: Any] else { throw NotAnEntryList() }
            let slot: Slot
            switch object[Entry.commonDirKey] {
            case nil, is NSNull: slot = .legacy
            case let commonDir as String where commonDir.hasPrefix("/"): slot = .anchor(commonDir: commonDir)
            default: throw NotAnEntryList()
            }
            guard slots.insert(slot).inserted else { throw NotAnEntryList() }
            let data = try JSONSerialization.data(withJSONObject: object)
            let config = try JSONDecoder().decode(BoardConfig.self, from: data)
            read.entries.append(Entry(slot: slot, config: config))
            read.unknownKeys.formUnion(Set(object.keys).subtracting(Entry.knownKeys))
            if read.unsupportedMergeMethod == nil { read.unsupportedMergeMethod = unsupportedMergeMethod(object) }
        }
        return read
    }

    private enum Schema: Equatable {
        /// 1 (or none, or a lower whole number): one config at the top. 2:
        /// one per repository.
        case version(Int)
        case newer(Int)
        /// Neither absent nor a number: a string, a boolean, an object.
        case invalid
    }

    /// Missing or null is the first schema. Any number above the current
    /// one is newer, even one that isn't a whole number.
    private static func schema(of top: [String: Any]) -> Schema {
        guard let value = top["schemaVersion"], !(value is NSNull) else { return .version(1) }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return .invalid }
        let version = number.doubleValue
        if version > Double(Self.schemaVersion) {
            return .newer(Int(exactly: version.rounded(.down)) ?? Int.max)
        }
        guard version == version.rounded(.down) else { return .invalid }
        return .version(version < Double(Self.schemaVersion) ? 1 : Self.schemaVersion)
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

    /// Writes `config` as the file's one config, schema 1 (a space without
    /// repository anchors, or tests).
    func save(_ config: BoardConfig, replacing expected: Loaded? = nil) -> Result<URL?, SaveError> {
        save(entries: [Entry(slot: .legacy, config: config)], replacing: expected)
    }

    /// Writes `entries` atomically (`BoardSections.entries(saving:…)` makes
    /// them), unless `problems` refuses a config that `expected` doesn't
    /// hold as it is: configs kept as read stay as read. Schema 1 when
    /// `entries` is one `.legacy` config, else schema 2. Reads the file
    /// again first. With `expected` (what the caller loaded), a file
    /// changed since is left alone. A file that is read-only now is left
    /// alone too, and an unreadable one is copied aside before it is
    /// replaced. Returns that copy, if any.
    func save(entries: [Entry], replacing expected: Loaded? = nil) -> Result<URL?, SaveError> {
        let kept = expected?.entries.map(\.config) ?? []
        let problems = entries.filter { !kept.contains($0.config) }.flatMap(\.config.problems)
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
        do {
            var data = try Self.encode(entries)
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

    /// Schema 1 for a lone `.legacy` config, so an older Nirux keeps
    /// reading and writing it; schema 2 otherwise.
    static func encode(_ entries: [Entry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if entries.count == 1, let only = entries.first, only.slot == .legacy {
            return try encoder.encode(only.config)
        }
        encoder.userInfo[BoardConfig.omitsSchemaVersion] = true
        return try encoder.encode(EntryList(entries: entries))
    }

    private struct EntryList: Encodable {
        let entries: [Entry]

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(BoardConfigStore.schemaVersion, forKey: Key("schemaVersion"))
            try container.encode(entries, forKey: Key(Entry.listKey))
        }
    }

    fileprivate struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    // MARK: - Files

    /// What reading a small file found. The merge queue reads its saved
    /// state the same way.
    enum ReadResult {
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

    private func read() -> ReadResult {
        Self.read(fileURL, maxBytes: Self.maxFileBytes)
    }

    /// Opened without following a link and without blocking, then checked on
    /// the open file: a FIFO swapped in after a check would block the read.
    static func read(_ fileURL: URL, maxBytes: Int) -> ReadResult {
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
        guard info.st_size <= maxBytes else { return .tooLarge }
        let data: Data
        do {
            data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        } catch {
            return .unreadableBytes
        }
        return data.count <= maxBytes ? .data(data) : .tooLarge
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

extension BoardConfigStore.Entry: Encodable {
    /// The config's keys, then `commonDir` in the same object.
    func encode(to encoder: Encoder) throws {
        try config.encode(to: encoder)
        guard case .anchor(let commonDir) = slot else { return }
        var container = encoder.container(keyedBy: BoardConfigStore.Key.self)
        try container.encode(commonDir, forKey: BoardConfigStore.Key(Self.commonDirKey))
    }
}
