import Foundation

/// Reads and writes a project's `board.json` (see BoardConfig), next to its
/// brief in `<state dir>/projects/<space id>/`. It follows ProjectStore's
/// rules:
/// - decoding is lenient (see `BoardConfig.init(from:)`);
/// - a file this build can't write back as it found it is read but never
///   written: a newer `schemaVersion`, keys it doesn't know, a merge method
///   it doesn't support. The merge queue won't start with it either
///   (`Loaded.queueStartProblems`), since the newer settings would be
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

    let fileURL: URL

    /// Nil for a space id that isn't a plain name (see `SpaceBrief.directory`).
    init?(spaceID: String, stateDirectory: URL = Persistence.stateDirectory) {
        guard let folder = SpaceBrief.directory(spaceID: spaceID, stateDirectory: stateDirectory) else { return nil }
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

        var isWritable: Bool {
            if case .readOnly = status { return false }
            return true
        }

        /// Why the merge queue can't start with this file. Empty when it can.
        var queueStartProblems: [String] {
            switch status {
            case .missing:
                return ["The board isn’t configured yet: open Board Settings…"]
            case .unreadable:
                return ["board.json can’t be read: open Board Settings… to replace it."]
            case .readOnly(let reason):
                return [reason.message]
            case .loaded:
                return config?.queueStartProblems ?? ["The board isn’t configured yet: open Board Settings…"]
            }
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
                    + "and its merge queue won’t start with it."
            case .unknownKeys(let keys):
                return "board.json has settings this version of Nirux doesn’t know (\(keys.joined(separator: ", "))). "
                    + "It won’t change the file, and its merge queue won’t start with it."
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
        // A newer schema may have changed what a key holds: it is never
        // written, even when this build can't read it at all.
        if let version = top?["schemaVersion"] as? Int, version > BoardConfig.schemaVersion {
            return Loaded(config: config, status: .readOnly(.newerSchema(version)))
        }
        guard let top, let config else { return Loaded(config: nil, status: .unreadable) }
        let unknownKeys = Set(top.keys).subtracting(BoardConfig.CodingKeys.allCases.map(\.rawValue))
        if !unknownKeys.isEmpty {
            return Loaded(config: config, status: .readOnly(.unknownKeys(unknownKeys.sorted())))
        }
        // Read as `merge`, which the queue must not use in its place.
        if let method = top["mergeMethod"] as? String, BoardConfig.MergeMethod(rawValue: method) == nil {
            return Loaded(config: config, status: .readOnly(.unsupportedMergeMethod(method)))
        }
        return Loaded(config: config, status: .loaded)
    }

    // MARK: - Saving

    enum SaveError: Error, Equatable {
        /// What's on disk now is read-only for this build, perhaps written by
        /// another Nirux since the form opened.
        case readOnly(ReadOnlyReason)
        case couldNotSetAside(String)
        case couldNotWrite(String)

        var message: String {
            switch self {
            case .readOnly(let reason):
                return reason.message
            case .couldNotSetAside(let error):
                return "board.json can’t be read, and Nirux couldn’t keep a copy of it before replacing it: \(error)"
            case .couldNotWrite(let error):
                return "Nirux couldn’t save board.json: \(error)"
            }
        }
    }

    /// Writes `config` atomically. Reads the file again first: one that
    /// became read-only since it was loaded is left alone, and an unreadable
    /// one is copied aside before it is replaced. Returns that copy, if any.
    func save(_ config: BoardConfig) -> Result<URL?, SaveError> {
        var copy: URL?
        switch read() {
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
            return .success(copy)
        } catch {
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
    }

    private func read() -> ReadResult {
        let attributes: [FileAttributeKey: Any]
        do {
            // Doesn't follow a link, which counts as not a regular file.
            attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return .missing
        } catch {
            return .unreadableBytes
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return .notARegularFile }
        guard let size = attributes[.size] as? Int, size <= Self.maxFileBytes else { return .tooLarge }
        guard let data = try? Data(contentsOf: fileURL) else { return .unreadableBytes }
        return .data(data)
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
