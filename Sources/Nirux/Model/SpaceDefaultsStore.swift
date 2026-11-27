import Foundation

/// Reads and writes a space's `defaults.json` (see SpaceDefaults), next to
/// its brief and board.json in `<state dir>/projects/<space id>/`. Its own
/// file rather than a key of projects.json: environment values may be
/// secrets, which must stay out of state.json's mirror and of what older
/// builds rewrite, and an older Nirux never reads or rewrites this file.
///
/// It follows BoardConfigStore's rules:
/// - decoding is lenient: a launch uses whatever decodes, whatever else the
///   file holds;
/// - a file this build can't write back as it found it (a newer
///   `schemaVersion`, keys or values it doesn't know) is read but never
///   written;
/// - an unreadable file is copied aside before a save replaces it;
/// - anything but a regular file, or a file over 1 MB, is neither read nor
///   replaced;
/// - it is created 0600 and replaced atomically, so a secret is never
///   readable by others, even for a moment.
struct SpaceDefaultsStore: Sendable {
    static let fileName = "defaults.json"
    static let schemaVersion = 1
    static let maxFileBytes = SpaceBrief.maxFileBytes

    let spaceID: String
    let fileURL: URL

    /// Nil for a space id that isn't a plain name (see `SpaceBrief.directory`).
    init?(spaceID: String, stateDirectory: URL = Persistence.stateDirectory) {
        guard let folder = SpaceBrief.directory(spaceID: spaceID, stateDirectory: stateDirectory) else { return nil }
        self.spaceID = spaceID
        fileURL = folder.appendingPathComponent(Self.fileName)
    }

    /// What a launch uses for the space: what the file holds, or nothing.
    static func defaults(forSpace spaceID: String, stateDirectory: URL = Persistence.stateDirectory) -> SpaceDefaults {
        SpaceDefaultsStore(spaceID: spaceID, stateDirectory: stateDirectory)?.load().defaults ?? SpaceDefaults()
    }

    /// A deleted space's defaults (copies set aside included) and setup
    /// scripts, which may hold secrets, go with it, and the rules its Lead
    /// proposed, its prompts' log, its review findings, its daily pass and its plan;
    /// its brief stays. Its Claude settings
    /// are emptied, not removed: its workspaces go on in General, and their
    /// columns' launch lines name the file.
    static func removeFiles(ofSpace spaceID: String, stateDirectory: URL = Persistence.stateDirectory) {
        do {
            try ClaudeSpaceSettings.empty(spaceID: spaceID, stateDirectory: stateDirectory)
        } catch {
            NiruxDebugLog.log("SpaceDefaultsStore: could not empty the Claude settings of a deleted space: \(error)")
        }
        guard let folder = SpaceBrief.directory(spaceID: spaceID, stateDirectory: stateDirectory),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return }
        for name in names where name == fileName || name.hasPrefix("defaults.corrupt.") || name == SpaceSetupScript.folderName
            || [RuleProposalStore.fileName, LoopLog.lines.fileName, ReviewFindings.lines.fileName, DailyPassState.fileName, Plan.Store.fileName]
                .contains(name) {
            do {
                try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            } catch {
                NiruxDebugLog.log("SpaceDefaultsStore: could not remove \(name) of a deleted space: \(error)")
            }
        }
    }

    // MARK: - Loading

    struct Loaded: Equatable, Sendable {
        enum Status: Equatable, Sendable {
            case missing
            case loaded
            /// Not JSON this build can read: a save copies it aside first.
            case unreadable
            /// This build never writes it.
            case readOnly(ReadOnlyReason)
        }

        var defaults: SpaceDefaults
        var status: Status
        /// The bytes read, so a save can tell whether the file changed since.
        var contents: Data?

        var isWritable: Bool {
            if case .readOnly = status { return false }
            return true
        }

        /// Why the file is used only in part, or not at all.
        var problem: String? {
            switch status {
            case .readOnly(let reason): return reason.message
            case .unreadable: return "defaults.json can’t be read: the next change keeps a copy of it (defaults.corrupt.….json) and replaces it."
            case .missing, .loaded: return nil
            }
        }
    }

    enum ReadOnlyReason: Equatable, Sendable {
        case newerSchema(Int)
        /// Keys, or values of known keys, this build doesn't know.
        case unknownSettings([String])
        case notARegularFile
        case tooLarge

        var message: String {
            switch self {
            case .newerSchema(let version):
                return "A newer Nirux saved these defaults (schema \(version)): this version uses what it can read "
                    + "and won’t change them."
            case .unknownSettings(let names):
                return "These defaults hold settings this version of Nirux doesn’t know (\(names.joined(separator: ", "))): "
                    + "it uses what it can read and won’t change them."
            case .notARegularFile:
                return "defaults.json isn’t a regular file (a folder or a link, say): Nirux won’t read or replace it."
            case .tooLarge:
                return "defaults.json is larger than 1 MB: Nirux won’t read or replace it."
            }
        }
    }

    /// What a file, or a switch, Nirux can't read holds is unknown: each
    /// switch takes its safe side (`SpaceDefaults.switches`), and a save
    /// replacing the file keeps it.
    static var unreadDefaults: SpaceDefaults {
        var defaults = SpaceDefaults()
        for item in SpaceDefaults.switches { defaults[keyPath: item.key] = item.safe }
        return defaults
    }

    func load() -> Loaded {
        switch BoardConfigStore.read(fileURL, maxBytes: Self.maxFileBytes) {
        case .missing: return Loaded(defaults: SpaceDefaults(), status: .missing)
        case .notARegularFile: return Loaded(defaults: Self.unreadDefaults, status: .readOnly(.notARegularFile))
        case .tooLarge: return Loaded(defaults: Self.unreadDefaults, status: .readOnly(.tooLarge))
        case .unreadableBytes: return Loaded(defaults: Self.unreadDefaults, status: .unreadable)
        case .data(let data): return Self.decode(data)
        }
    }

    static func decode(_ data: Data) -> Loaded {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var defaults = try? JSONDecoder().decode(SpaceDefaults.self, from: data)
        else { return Loaded(defaults: unreadDefaults, status: .unreadable, contents: data) }
        let unknown = unknownSettings(in: top, decoded: defaults)
        for item in SpaceDefaults.switches where defaults[keyPath: item.key] == nil
            && top[item.name.rawValue].map({ !($0 is NSNull) }) == true {
            defaults[keyPath: item.key] = item.safe
        }
        // An hour it can't read: off, as a switch it can't read.
        if top["leadDailyPassHour"].map({ !($0 is NSNull) }) == true, defaults.leadDailyPassHour == nil { defaults.leadDailyPass = false }
        let readOnly: ReadOnlyReason
        if let version = top["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
           version.doubleValue > Double(schemaVersion) {
            let newer = Int(exactly: version.doubleValue.rounded(.down)) ?? Int.max
            readOnly = .newerSchema(newer)
        } else if !unknown.isEmpty {
            readOnly = .unknownSettings(unknown)
        } else {
            return Loaded(defaults: defaults, status: .loaded, contents: data)
        }
        defaults.leadStartsMergeQueue = nil
        defaults.leadStartsMergeQueueWithoutLocalReview = nil
        return Loaded(defaults: defaults, status: .readOnly(readOnly), contents: data)
    }

    /// What a rewrite would drop: unknown keys, a mode or agent this build
    /// doesn't have, variables it can't read back as name and value.
    private static func unknownSettings(in top: [String: Any], decoded: SpaceDefaults) -> [String] {
        let known = Set(SpaceDefaults.CodingKeys.allCases.map(\.rawValue))
        var unknown = Set(top.keys).subtracting(known)
        if let value = top["schemaVersion"], !(value is NSNull) {
            let number = value as? NSNumber
            if number == nil || CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() || number?.doubleValue != Double(schemaVersion) {
                unknown.insert("schemaVersion")
            }
        }
        if top["agent"].map({ !($0 is NSNull) }) == true, decoded.agent == nil { unknown.insert("agent") }
        if top["leadAgent"].map({ !($0 is NSNull) }) == true, decoded.leadAgent == nil { unknown.insert("leadAgent") }
        if top["claudeLaunchMode"].map({ !($0 is NSNull) }) == true, decoded.claudeLaunchMode == nil {
            unknown.insert("claudeLaunchMode")
        }
        if top["codexLaunchMode"].map({ !($0 is NSNull) }) == true, decoded.codexLaunchMode == nil {
            unknown.insert("codexLaunchMode")
        }
        if top["agyLaunchMode"].map({ !($0 is NSNull) }) == true, decoded.agyLaunchMode == nil {
            unknown.insert("agyLaunchMode")
        }
        for item in SpaceDefaults.switches where decoded[keyPath: item.key] == nil
            && top[item.name.rawValue].map({ !($0 is NSNull) }) == true {
            unknown.insert(item.name.rawValue)
        }
        if top["leadDailyPassHour"].map({ !($0 is NSNull) }) == true, decoded.leadDailyPassHour == nil { unknown.insert("leadDailyPassHour") }
        if top["taskBudget"].map({ !($0 is NSNull) }) == true, decoded.taskBudget == nil { unknown.insert("taskBudget") }
        for key in [SpaceDefaults.CodingKeys.claudeAllow, .claudeEnvironment] {
            if let value = top[key.rawValue], !(value is NSNull), !(value is [String]) { unknown.insert(key.rawValue) }
        }
        if let variables = top["environment"], !(variables is NSNull) {
            let entries = variables as? [Any] ?? []
            let readable = entries.allSatisfy { entry in
                guard let object = entry as? [String: Any] else { return false }
                return object["name"] is String && object["value"] is String && Set(object.keys) == ["name", "value"]
            }
            if !(variables is [Any]) || !readable || entries.count != decoded.environment.count {
                unknown.insert("environment")
            }
        }
        return unknown.sorted()
    }

    // MARK: - Saving

    enum SaveError: Error, Equatable {
        /// The file isn't what was loaded: another Nirux saved it since.
        case changedSinceLoaded
        case readOnly(ReadOnlyReason)
        case couldNotSetAside(String)
        case couldNotWrite(String)

        var message: String {
            switch self {
            case .changedSinceLoaded:
                return "The space’s defaults changed since this window read them, perhaps in another Nirux. "
                    + "They now show what the file holds: make the change again."
            case .readOnly(let reason):
                return reason.message
            case .couldNotSetAside(let error):
                return "defaults.json can’t be read, and Nirux couldn’t keep a copy of it before replacing it: \(error)"
            case .couldNotWrite(let error):
                return "Nirux couldn’t save the space’s defaults: \(error)"
            }
        }
    }

    /// Writes `defaults`, after reading the file again: with `expected`,
    /// a file changed since is left alone; a read-only one always is; an
    /// unreadable one is copied aside first.
    func save(_ defaults: SpaceDefaults, replacing expected: Loaded? = nil) -> Result<Loaded, SaveError> {
        let current = BoardConfigStore.read(fileURL, maxBytes: Self.maxFileBytes)
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
            var data = try encoder.encode(defaults)
            data.append(0x0A)
            try Self.writePrivately(data, to: fileURL)
            return .success(Loaded(defaults: defaults, status: .loaded, contents: data))
        } catch {
            if let copy { try? FileManager.default.removeItem(at: copy) }
            NiruxDebugLog.log("SpaceDefaultsStore: could not save \(fileURL.path): \(error)")
            return .failure(.couldNotWrite(error.localizedDescription))
        }
    }

    private func setAside(_ data: Data?) -> Result<URL, SaveError> {
        let stamp = Int(Date().timeIntervalSince1970)
        let copy = fileURL.deletingLastPathComponent()
            .appendingPathComponent("defaults.corrupt.\(stamp)-\(UUID().uuidString.prefix(8)).json")
        do {
            if let data {
                try Self.writePrivately(data, to: copy)
            } else {
                try FileManager.default.copyItem(at: fileURL, to: copy)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
            }
            return .success(copy)
        } catch {
            return .failure(.couldNotSetAside(error.localizedDescription))
        }
    }

    static func writePrivately(_ data: Data, to url: URL) throws {
        try PrivateFileWrite.write(data, to: url)
    }
}
