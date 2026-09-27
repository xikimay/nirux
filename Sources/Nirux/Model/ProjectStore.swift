import Foundation

/// Persists spaces ("projects" in docs/projects.md, section 2) in their own
/// `projects.json`, so a space outlives its last workspace and keeps what is
/// keyed by its id (the space brief). `state.json` keeps writing
/// `workspaceProfiles` as a mirror, so older nightlies keep working.
///
/// The marker. `state.json` carries `projectsFileVersion` only when
/// `projects.json` held the same spaces at that save (`isFileCurrent`). Older
/// builds drop unknown keys when they save, and a build that can't write the
/// file leaves the marker out too. So:
/// - marker present: `projects.json` is authoritative and the mirror is
///   ignored, so a crash between the two writes or a `state.json` backup
///   can't bring a deleted space back;
/// - marker absent: the mirror may be newer, so it is merged in. Ids it
///   doesn't know are imported (unless deleted here) and names and colors
///   come from it, so a rename done in an older build survives.
@MainActor
final class ProjectStore {
    static let schemaVersion = 1

    enum Availability: Equatable {
        case writable
        /// Saved by a newer Nirux: reading isn't a lossless round trip, so
        /// this build never writes the file.
        case readOnlyNewerSchema(Int)
        /// Unreadable and not copied aside (or a directory): never replaced.
        case readOnlyUnreadable
    }

    let fileURL: URL
    private(set) var availability: Availability = .writable
    /// Ids of deleted spaces, so a mirror can't revive them.
    private(set) var deletedIDs: Set<String> = []
    /// `projects.json` holds what the last `save` was given. Only then may
    /// `state.json` carry the marker.
    private(set) var isFileCurrent = false
    private var hasLoaded = false
    private var lastWrittenData: Data?

    init(fileURL: URL = Persistence.stateDirectory.appendingPathComponent("projects.json")) {
        self.fileURL = fileURL
    }

    var backupURL: URL { fileURL.appendingPathExtension("bak") }

    /// The spaces to use at launch.
    /// - Parameters:
    ///   - mirror: `state.json`'s `workspaceProfiles`, if any.
    ///   - markerPresent: `state.json` carries `projectsFileVersion`.
    func load(mirror: [WorkspaceProfile]?, markerPresent: Bool) -> [WorkspaceProfile] {
        hasLoaded = true
        let mirror = Self.deduplicated(mirror ?? [])
        switch Self.read(fileURL) {
        case .ok(let file, let data):
            deletedIDs = Set(file.deletedIDs)
            if file.schemaVersion > Self.schemaVersion {
                availability = .readOnlyNewerSchema(file.schemaVersion)
                NiruxDebugLog.log("ProjectStore: projects.json is schema \(file.schemaVersion); read-only")
            } else {
                lastWrittenData = data
            }
            return markerPresent ? file.projects : Self.merged(file.projects, withMirror: mirror, deletedIDs: deletedIDs)
        case .newerSchemaUnreadable(let version):
            availability = .readOnlyNewerSchema(version)
            NiruxDebugLog.log("ProjectStore: projects.json is schema \(version) and unreadable here; read-only")
            return mirror
        case .directory:
            availability = .readOnlyUnreadable
            return mirror
        case .unreadable(let data):
            if !setAside(data) { availability = .readOnlyUnreadable }
            return recovered(mirror: mirror, markerPresent: markerPresent)
        case .missing:
            return recovered(mirror: mirror, markerPresent: markerPresent)
        }
    }

    func markDeleted(_ id: String) {
        deletedIDs.insert(id)
    }

    /// Writes `projects.json` when its content changed, keeping the previous
    /// readable version as `projects.json.bak`. Both are 0600. Call it before
    /// `state.json` is saved. Returns `isFileCurrent`.
    @discardableResult
    func save(_ profiles: [WorkspaceProfile]) -> Bool {
        guard hasLoaded, availability == .writable else {
            isFileCurrent = false
            return false
        }
        let file = ProjectsFile(schemaVersion: Self.schemaVersion, projects: profiles, deletedIDs: deletedIDs.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else {
            isFileCurrent = false
            return false
        }
        if data == lastWrittenData {
            isFileCurrent = true
            return true
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if let current = try? Data(contentsOf: fileURL), case .ok = Self.decode(current) {
                try current.write(to: backupURL, options: .atomic)
                Self.restrictPermissions(backupURL)
            }
            try data.write(to: fileURL, options: .atomic)
            Self.restrictPermissions(fileURL)
            lastWrittenData = data
            isFileCurrent = true
        } catch {
            NiruxDebugLog.log("ProjectStore: could not save projects.json: \(error)")
            isFileCurrent = false
        }
        return isFileCurrent
    }

    /// `projects.json` is missing or unreadable.
    private func recovered(mirror: [WorkspaceProfile], markerPresent: Bool) -> [WorkspaceProfile] {
        guard case .ok(let backup, _) = Self.read(backupURL) else {
            return mirror // the first launch after the update, or nothing else to go on
        }
        guard markerPresent else {
            deletedIDs = Set(backup.deletedIDs)
            return Self.merged(backup.projects, withMirror: mirror, deletedIDs: deletedIDs)
        }
        // The marker says projects.json held the mirror's spaces; the backup
        // is one change older. A space only the backup has was deleted since.
        let mirrorIDs = Set(mirror.map(\.id))
        deletedIDs = Set(backup.deletedIDs).union(backup.projects.map(\.id).filter { !mirrorIDs.contains($0) })
        return mirror
    }

    // MARK: - Reading

    struct ProjectsFile: Codable, Equatable {
        var schemaVersion: Int
        var projects: [WorkspaceProfile]
        var deletedIDs: [String]

        init(schemaVersion: Int, projects: [WorkspaceProfile], deletedIDs: [String]) {
            self.schemaVersion = schemaVersion
            self.projects = projects
            self.deletedIDs = deletedIDs
        }

        /// Lenient: a missing field gets a default, a project without an id
        /// (or with an id already seen) is skipped, and unknown keys are
        /// ignored.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            let stored = try container.decodeIfPresent([StoredProject].self, forKey: .projects) ?? []
            projects = ProjectStore.deduplicated(stored.enumerated().compactMap { index, project in
                guard let id = project.id, !id.isEmpty else { return nil }
                return WorkspaceProfile(
                    id: id,
                    name: project.name ?? "space",
                    colorHex: project.colorHex ?? WorkspaceProfile.colorHex(for: index)
                )
            })
            deletedIDs = try container.decodeIfPresent([String].self, forKey: .deletedIDs) ?? []
        }
    }

    private struct StoredProject: Decodable {
        let id: String?
        let name: String?
        let colorHex: String?
    }

    private struct SchemaVersionOnly: Decodable {
        let schemaVersion: Int?
    }

    enum ReadResult {
        case missing
        case directory
        case unreadable(Data)
        /// Written by a newer schema that this build can't even read.
        case newerSchemaUnreadable(Int)
        case ok(ProjectsFile, Data)
    }

    static func read(_ url: URL) -> ReadResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .missing }
        if isDirectory.boolValue { return .directory }
        guard let data = try? Data(contentsOf: url) else { return .unreadable(Data()) }
        return decode(data)
    }

    private static func decode(_ data: Data) -> ReadResult {
        if let file = try? JSONDecoder().decode(ProjectsFile.self, from: data) { return .ok(file, data) }
        if let version = (try? JSONDecoder().decode(SchemaVersionOnly.self, from: data))?.schemaVersion,
           version > schemaVersion {
            return .newerSchemaUnreadable(version)
        }
        return .unreadable(data)
    }

    /// The file's spaces with a newer mirror merged in: it may have renamed
    /// or recolored spaces, or created new ones.
    static func merged(
        _ projects: [WorkspaceProfile],
        withMirror mirror: [WorkspaceProfile],
        deletedIDs: Set<String>
    ) -> [WorkspaceProfile] {
        var result = projects
        for mirrored in mirror where !deletedIDs.contains(mirrored.id) {
            if let index = result.firstIndex(where: { $0.id == mirrored.id }) {
                result[index].name = mirrored.name
                result[index].colorHex = mirrored.colorHex
            } else {
                var added = mirrored
                // An older build may have recreated a space it had dropped.
                added.name = uniqueName(mirrored.name, among: result.map(\.name))
                result.append(added)
            }
        }
        return result
    }

    nonisolated static func deduplicated(_ profiles: [WorkspaceProfile]) -> [WorkspaceProfile] {
        var seen = Set<String>()
        return profiles.filter { seen.insert($0.id).inserted }
    }

    private static func uniqueName(_ name: String, among names: [String]) -> String {
        guard names.contains(name) else { return name }
        var index = 2
        while names.contains("\(name) \(index)") { index += 1 }
        return "\(name) \(index)"
    }

    /// Keeps an unreadable file's bytes next to it before it can be replaced.
    private func setAside(_ data: Data) -> Bool {
        let stamp = Int(Date().timeIntervalSince1970)
        let copy = fileURL.deletingLastPathComponent()
            .appendingPathComponent("projects.corrupt.\(stamp)-\(UUID().uuidString.prefix(8)).json")
        do {
            if data.isEmpty {
                try FileManager.default.copyItem(at: fileURL, to: copy)
            } else {
                try data.write(to: copy, options: .atomic)
            }
            Self.restrictPermissions(copy)
            return true
        } catch {
            NiruxDebugLog.log("ProjectStore: could not set aside unreadable projects.json: \(error)")
            return false
        }
    }

    private static func restrictPermissions(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
