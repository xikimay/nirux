import Foundation

/// Persists spaces ("projects" in docs/projects.md, section 2) in their own
/// `projects.json`, so a space outlives its last workspace and carries what
/// is keyed by its id (the space brief). `state.json` keeps writing
/// `workspaceProfiles` as a mirror, so older nightlies keep working.
///
/// Rollback safety. New builds also write `projectsFileVersion` in
/// `state.json`; older builds drop unknown keys when they save, so a missing
/// marker means an older build saved last. Only then is the mirror merged
/// back: ids it doesn't know are imported (unless deleted here) and names and
/// colors come from it, so a rename done in the older build survives. With the
/// marker present the mirror is ignored, so a crash between the two writes or
/// a `state.json` backup can't bring a deleted space back.
@MainActor
final class ProjectStore {
    static let schemaVersion = 1

    enum Availability: Equatable {
        case writable
        /// Saved by a newer Nirux: reading isn't a lossless round trip, so
        /// this build never writes the file.
        case readOnlyNewerSchema(Int)
        /// The file is unreadable and couldn't be copied aside, so it must
        /// not be overwritten.
        case readOnlyUnreadable
    }

    let fileURL: URL
    private(set) var availability: Availability = .writable
    /// Ids of deleted spaces, so an older build's mirror can't revive them.
    private(set) var deletedIDs: Set<String> = []
    private var lastWrittenData: Data?

    init(fileURL: URL = Persistence.stateDirectory.appendingPathComponent("projects.json")) {
        self.fileURL = fileURL
    }

    var backupURL: URL { fileURL.appendingPathExtension("bak") }

    /// The spaces to use at launch.
    /// - Parameters:
    ///   - mirror: `state.json`'s `workspaceProfiles`, if any.
    ///   - markerPresent: `state.json` carries `projectsFileVersion`, i.e. a
    ///     build that knows this file saved it last.
    func load(mirror: [WorkspaceProfile]?, markerPresent: Bool) -> [WorkspaceProfile] {
        let mirror = mirror ?? []
        let file: ProjectsFile
        switch Self.read(fileURL) {
        case .ok(let decoded):
            file = decoded
        case .unreadable(let data):
            if !setAside(data) { availability = .readOnlyUnreadable }
            guard case .ok(let backup) = Self.read(backupURL) else { return migrated(from: mirror) }
            file = backup
        case .missing:
            // Also the first launch after the update. A missing file with the
            // marker present loses nothing today: the mirror holds every
            // field a space has (only deletions could come back, and only
            // from an older state.json backup).
            if markerPresent { NiruxDebugLog.log("ProjectStore: projects.json missing; rebuilt from state.json") }
            guard case .ok(let backup) = Self.read(backupURL) else { return migrated(from: mirror) }
            file = backup
        }

        deletedIDs = Set(file.deletedIDs)
        if file.schemaVersion > Self.schemaVersion {
            availability = .readOnlyNewerSchema(file.schemaVersion)
            NiruxDebugLog.log("ProjectStore: projects.json is schema \(file.schemaVersion); read-only")
            return file.projects
        }
        guard !markerPresent else { return file.projects }
        return Self.merged(file.projects, withOlderBuildMirror: mirror, deletedIDs: deletedIDs)
    }

    func markDeleted(_ id: String) {
        deletedIDs.insert(id)
    }

    /// Writes `projects.json` when its content changed. Call it before
    /// `state.json` is saved (see the type comment). The previous readable
    /// version is kept as `projects.json.bak`. Both files are 0600.
    func save(_ profiles: [WorkspaceProfile]) {
        guard availability == .writable else { return }
        let file = ProjectsFile(
            schemaVersion: Self.schemaVersion,
            projects: profiles,
            deletedIDs: deletedIDs.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file), data != lastWrittenData else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if let current = try? Data(contentsOf: fileURL), current != data,
               case .ok = Self.decode(current) {
                try current.write(to: backupURL, options: .atomic)
                Self.restrictPermissions(backupURL)
            }
            try data.write(to: fileURL, options: .atomic)
            Self.restrictPermissions(fileURL)
            lastWrittenData = data
        } catch {
            NiruxDebugLog.log("ProjectStore: could not save projects.json: \(error)")
        }
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
        /// is skipped, and unknown keys are ignored.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            let stored = try container.decodeIfPresent([StoredProject].self, forKey: .projects) ?? []
            projects = stored.enumerated().compactMap { index, project in
                guard let id = project.id, !id.isEmpty else { return nil }
                return WorkspaceProfile(
                    id: id,
                    name: project.name ?? "space",
                    colorHex: project.colorHex ?? WorkspaceProfile.colorHex(for: index)
                )
            }
            deletedIDs = try container.decodeIfPresent([String].self, forKey: .deletedIDs) ?? []
        }
    }

    private struct StoredProject: Decodable {
        let id: String?
        let name: String?
        let colorHex: String?
    }

    enum ReadResult {
        case missing
        case unreadable(Data)
        case ok(ProjectsFile)
    }

    static func read(_ url: URL) -> ReadResult {
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable(Data()) : .missing
        }
        return decode(data)
    }

    private static func decode(_ data: Data) -> ReadResult {
        guard let file = try? JSONDecoder().decode(ProjectsFile.self, from: data) else { return .unreadable(data) }
        return .ok(file)
    }

    /// The file's spaces, with an older build's mirror merged in: it may have
    /// renamed or recolored spaces, or created new ones.
    static func merged(
        _ projects: [WorkspaceProfile],
        withOlderBuildMirror mirror: [WorkspaceProfile],
        deletedIDs: Set<String>
    ) -> [WorkspaceProfile] {
        var result = projects
        for mirrored in mirror where !deletedIDs.contains(mirrored.id) {
            if let index = result.firstIndex(where: { $0.id == mirrored.id }) {
                result[index].name = mirrored.name
                result[index].colorHex = mirrored.colorHex
            } else {
                result.append(mirrored)
            }
        }
        return result
    }

    private func migrated(from mirror: [WorkspaceProfile]) -> [WorkspaceProfile] {
        mirror.filter { !deletedIDs.contains($0.id) }
    }

    /// Keeps an unreadable file's bytes next to it before it can be replaced.
    private func setAside(_ data: Data) -> Bool {
        let stamp = Int(Date().timeIntervalSince1970)
        let copy = fileURL.deletingLastPathComponent()
            .appendingPathComponent("projects.corrupt.\(stamp).json")
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
