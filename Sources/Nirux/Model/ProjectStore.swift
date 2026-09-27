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
///
/// Changing the format: bump `schemaVersion`. A file with keys this build
/// doesn't know is read but never written, so a rollback can't strip them.
@MainActor
final class ProjectStore {
    static let schemaVersion = 1
    private static let fileKeys: Set<String> = ["schemaVersion", "projects", "deletedIDs"]
    private static let projectKeys: Set<String> = ["id", "name", "colorHex"]

    enum Availability: Equatable {
        case writable
        /// Saved by a newer Nirux (a higher schema, or fields this build
        /// doesn't know): reading isn't a lossless round trip, so this build
        /// never writes the file.
        case readOnlyNewerSchema(Int)
        /// Unreadable and not copied aside (or a directory): never replaced.
        case readOnlyUnreadable
    }

    let fileURL: URL
    private(set) var availability: Availability = .writable
    /// Ids of deleted spaces, so a mirror or an orphaned brief can't revive
    /// them.
    private(set) var deletedIDs: Set<String> = []
    /// `projects.json` holds what the last `save` was given. Only then may
    /// `state.json` carry the marker.
    private(set) var isFileCurrent = false
    private var hasLoaded = false
    /// Spaces only the backup had, left out because the mirror dropped them:
    /// their briefs mustn't bring them back (see `orphanedBriefSpaces`).
    private var droppedSinceBackup: Set<String> = []

    init(fileURL: URL = Persistence.stateDirectory.appendingPathComponent("projects.json")) {
        self.fileURL = fileURL
    }

    var backupURL: URL { fileURL.appendingPathExtension("bak") }
    /// Where space briefs live (see SpaceBrief).
    private var briefsFolder: URL { fileURL.deletingLastPathComponent().appendingPathComponent("projects") }

    /// The spaces to use at launch.
    /// - Parameters:
    ///   - mirror: `state.json`'s `workspaceProfiles`, if any.
    ///   - markerPresent: `state.json` carries `projectsFileVersion`.
    func load(mirror: [WorkspaceProfile]?, markerPresent: Bool) -> [WorkspaceProfile] {
        hasLoaded = true
        let mirror = mirror.map(Self.deduplicated)
        let spaces = loadedSpaces(mirror: mirror, markerPresent: markerPresent)
        return spaces + orphanedBriefSpaces(known: spaces)
    }

    private func loadedSpaces(mirror: [WorkspaceProfile]?, markerPresent: Bool) -> [WorkspaceProfile] {
        switch Self.read(fileURL) {
        case .ok(let file, let data):
            deletedIDs = Set(file.deletedIDs)
            if file.schemaVersion > Self.schemaVersion || Self.hasUnknownKeys(data) {
                availability = .readOnlyNewerSchema(file.schemaVersion)
                NiruxDebugLog.log("ProjectStore: projects.json is from a newer Nirux; read-only")
            }
            guard !markerPresent, let mirror else { return file.projects }
            return Self.merged(file.projects, withMirror: mirror, deletedIDs: deletedIDs)
        case .newerSchemaUnreadable(let version):
            availability = .readOnlyNewerSchema(version)
            NiruxDebugLog.log("ProjectStore: projects.json is schema \(version) and unreadable here; read-only")
            return mirror ?? []
        case .directory:
            availability = .readOnlyUnreadable
            return mirror ?? []
        case .unreadable(let data):
            if !setAside(data) { availability = .readOnlyUnreadable }
            return recovered(mirror: mirror, markerPresent: markerPresent)
        case .missing:
            return recovered(mirror: mirror, markerPresent: markerPresent)
        }
    }

    /// `projects.json` is missing or unreadable.
    private func recovered(mirror: [WorkspaceProfile]?, markerPresent: Bool) -> [WorkspaceProfile] {
        let backup: ProjectsFile
        switch Self.read(backupURL) {
        case .ok(let file, let data):
            if file.schemaVersion > Self.schemaVersion || Self.hasUnknownKeys(data) {
                availability = .readOnlyNewerSchema(file.schemaVersion)
            }
            backup = file
        case .newerSchemaUnreadable(let version):
            availability = .readOnlyNewerSchema(version)
            return mirror ?? []
        default:
            return mirror ?? [] // the first launch after the update, or nothing else to go on
        }
        deletedIDs = Set(backup.deletedIDs)
        guard let mirror else { return backup.projects }
        guard markerPresent else {
            return Self.merged(backup.projects, withMirror: mirror, deletedIDs: deletedIDs)
        }
        // The marker says projects.json held the mirror's spaces; the backup
        // is one change older. Keep the backup's copy of each (it may hold
        // more than the mirror) and nothing the mirror has dropped.
        let mirrorIDs = Set(mirror.map(\.id))
        let kept = backup.projects.filter { mirrorIDs.contains($0.id) }
        droppedSinceBackup = Set(backup.projects.map(\.id)).subtracting(mirrorIDs)
        return Self.merged(kept, withMirror: mirror, deletedIDs: deletedIDs)
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
        // Compare with the disk, not with this process's last write: another
        // Nirux (a second copy, a debug build without NIRUX_STATE_DIR) may
        // have written since. Keep the deletions it recorded.
        let current = try? Data(contentsOf: fileURL)
        if let current {
            switch Self.decode(current) {
            case .ok(let onDisk, _) where onDisk.schemaVersion > Self.schemaVersion || Self.hasUnknownKeys(current):
                availability = .readOnlyNewerSchema(onDisk.schemaVersion)
            case .newerSchemaUnreadable(let version):
                availability = .readOnlyNewerSchema(version)
            case .ok(let onDisk, _):
                deletedIDs.formUnion(onDisk.deletedIDs)
            default:
                break
            }
            guard availability == .writable else {
                NiruxDebugLog.log("ProjectStore: a newer Nirux wrote projects.json; read-only")
                isFileCurrent = false
                return false
            }
        }
        // A space this instance still lists isn't deleted, whatever another
        // instance recorded.
        deletedIDs.subtract(profiles.map(\.id))
        let file = ProjectsFile(schemaVersion: Self.schemaVersion, projects: profiles, deletedIDs: deletedIDs.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else {
            isFileCurrent = false
            return false
        }
        if data == current {
            isFileCurrent = true
            return true
        }
        if let current, case .ok = Self.decode(current) {
            // Best effort: a failed backup must not block the save itself.
            try? current.write(to: backupURL, options: .atomic)
            Self.restrictPermissions(backupURL)
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            Self.restrictPermissions(fileURL)
            isFileCurrent = true
        } catch {
            NiruxDebugLog.log("ProjectStore: could not save projects.json: \(error)")
            isFileCurrent = false
        }
        return isFileCurrent
    }

    // MARK: - Orphaned briefs

    /// Spaces that disappeared while their brief has content: an older build
    /// dropped a space once it had no workspace, which left its brief behind.
    /// Each comes back under the name its brief's template recorded.
    private func orphanedBriefSpaces(known: [WorkspaceProfile]) -> [WorkspaceProfile] {
        let knownIDs = Set(known.map(\.id)).union(deletedIDs).union(droppedSinceBackup)
            .union([WorkspaceProfile.defaultID])
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: briefsFolder.path) else { return [] }
        var names = known.map(\.name)
        var used = Set(known.map { $0.colorHex.uppercased() })
        var adopted: [WorkspaceProfile] = []
        for id in folders.sorted() where !knownIDs.contains(id) {
            guard let briefURL = SpaceBrief.briefURL(spaceID: id, stateDirectory: fileURL.deletingLastPathComponent()),
                  let text = SpaceBrief.readBrief(at: briefURL),
                  SpaceBrief.body(of: text) != nil
            else { continue }
            let name = Self.uniqueName(Self.templateSpaceName(in: text) ?? "space", among: names)
            let color = WorkspaceProfile.palette.first { !used.contains($0.hex.uppercased()) }?.hex
                ?? WorkspaceProfile.colorHex(for: known.count + adopted.count)
            adopted.append(WorkspaceProfile(id: id, name: name, colorHex: color))
            names.append(name)
            used.insert(color.uppercased())
        }
        return adopted
    }

    /// The space name in a brief's template comment (`Brief for the space "…"`).
    private static func templateSpaceName(in text: String) -> String? {
        let prefix = "Brief for the space \""
        guard let start = text.range(of: prefix),
              let end = text[start.upperBound...].range(of: "\":")
        else { return nil }
        let name = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
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
        /// ignored here (see `hasUnknownKeys`).
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

    /// Keys this build would drop on rewrite: the file came from a newer build
    /// even if its schemaVersion wasn't bumped.
    private static func hasUnknownKeys(_ data: Data) -> Bool {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        if !Set(top.keys).isSubset(of: fileKeys) { return true }
        let projects = top["projects"] as? [[String: Any]] ?? []
        return projects.contains { !Set($0.keys).isSubset(of: projectKeys) }
    }

    /// `projects` with a newer mirror merged in: it may have renamed or
    /// recolored spaces, or created new ones.
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
