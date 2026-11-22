import Darwin
import Foundation

struct LocalCheckpoints: Sendable {
    struct Limits: Sendable {
        var maxCheckpointsPerWorkspace = 20
        var maxWorkspaceBytes = 50 << 20
        var maxSingleFileBytes = 2 << 20
        var maxFilesPerCapture = 2_000
        var captureTimeout: TimeInterval = 5
    }

    struct File: Codable, Equatable, Sendable {
        let path: String
        let status: String
        let size: Int
        /// Nil for a deletion. Payloads are named by their digest inside this checkpoint.
        let sha256: String?
    }

    struct Omission: Codable, Equatable, Sendable {
        let path: String
        let reason: String
    }

    struct Manifest: Codable, Equatable, Sendable {
        var schemaVersion = 1
        let id: UUID
        var createdAt = Date()
        var label: String?
        var branch: String?
        var head: String?
        var mergeBase: String?
        var files: [File] = []
        var omissions: [Omission] = []
        var timedOut = false
        var isIncomplete: Bool { timedOut || !omissions.isEmpty }
        var size: Int { files.reduce(0) { $0 + $1.size } }

        enum CodingKeys: String, CodingKey {
            case schemaVersion, id, createdAt, label, branch, head, mergeBase, files, omissions, timedOut, isIncomplete
        }

        init(id: UUID = UUID(), label: String?) {
            self.id = id
            self.label = label.flatMap { AgentText.clean($0, maxLength: 80) }
        }

        init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try keys.decode(Int.self, forKey: .schemaVersion)
            id = try keys.decode(UUID.self, forKey: .id)
            createdAt = try keys.decode(Date.self, forKey: .createdAt)
            label = try keys.decodeIfPresent(String.self, forKey: .label)
            branch = try keys.decodeIfPresent(String.self, forKey: .branch)
            head = try keys.decodeIfPresent(String.self, forKey: .head)
            mergeBase = try keys.decodeIfPresent(String.self, forKey: .mergeBase)
            files = try keys.decode([File].self, forKey: .files)
            var size = 0
            for file in files {
                guard file.size >= 0, file.size <= Int.max - size else { throw Problem("Invalid checkpoint file size.") }
                size += file.size
            }
            omissions = try keys.decodeIfPresent([Omission].self, forKey: .omissions) ?? []
            timedOut = try keys.decodeIfPresent(Bool.self, forKey: .timedOut) ?? false
            if try keys.decodeIfPresent(Bool.self, forKey: .isIncomplete) == true && !isIncomplete {
                omissions.append(Omission(path: "", reason: "Capture marked incomplete"))
            }
        }

        func encode(to encoder: Encoder) throws {
            var keys = encoder.container(keyedBy: CodingKeys.self)
            try keys.encode(schemaVersion, forKey: .schemaVersion)
            try keys.encode(id, forKey: .id)
            try keys.encode(createdAt, forKey: .createdAt)
            try keys.encodeIfPresent(label, forKey: .label)
            try keys.encodeIfPresent(branch, forKey: .branch)
            try keys.encodeIfPresent(head, forKey: .head)
            try keys.encodeIfPresent(mergeBase, forKey: .mergeBase)
            try keys.encode(files, forKey: .files)
            try keys.encode(omissions, forKey: .omissions)
            try keys.encode(timedOut, forKey: .timedOut)
            try keys.encode(isIncomplete, forKey: .isIncomplete)
        }
    }

    struct Entry: Identifiable, Sendable {
        let id: UUID
        let version: Int
        let manifest: Manifest?
        let storedBytes: Int
    }

    struct Problem: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    let folder: URL
    let limits: Limits

    init(stateDirectory: URL, workspaceID: String, limits: Limits = Limits()) throws {
        guard let resolved = stateDirectory.path.realPath else { throw Problem("The Nirux state directory is unavailable.") }
        let state = URL(fileURLWithPath: resolved)
        guard !workspaceID.isEmpty, workspaceID.first != ".", !workspaceID.contains("/"), !workspaceID.utf8.contains(0),
              !state.pathComponents.contains(where: { $0.lowercased() == ".git" })
        else { throw Problem("Unsafe checkpoint store location.") }
        folder = state.appendingPathComponent("checkpoints").appendingPathComponent(workspaceID)
        self.limits = limits
    }

    private func hasWorkspaceFolder() throws -> Bool {
        var info = stat()
        if lstat(folder.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw Self.fileError
    }

    private func locked<T>(create: Bool, _ body: () throws -> T) throws -> T {
        for directory in [folder.deletingLastPathComponent(), folder] {
            if create, mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw Self.fileError }
            var info = stat()
            guard lstat(directory.path, &info) == 0 else { throw Self.fileError }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
                throw Problem("The checkpoint folder must be a private directory.")
            }
        }
        return try BranchReview.Store.withExclusiveLock(at: folder.appendingPathComponent(".lock"), timeout: 5) {
            try finishSave()
            return try body()
        }
    }

    static var fileError: POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    func list() throws -> [Entry] {
        guard try hasWorkspaceFolder() else { return [] }
        return try locked(create: false) { try entries() }
    }

    /// Reads the saved working bytes by manifest path. A recorded deletion has no payload.
    func contents(of path: String, in id: UUID) throws -> Data? {
        try locked(create: false) {
            guard let manifest = try readEntry(id).manifest,
                  let file = manifest.files.first(where: { $0.path == path }) else {
                throw Problem("The file is unavailable in this checkpoint.")
            }
            guard let hash = file.sha256 else { return nil }
            guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw Problem("Invalid checkpoint digest.")
            }
            let directory = folder.appendingPathComponent(id.uuidString)
            let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard root >= 0 else { throw Self.fileError }
            defer { close(root) }
            let data = try BranchReview.ExplainCopy.readBytes(hash, from: root, maxFileBytes: Limits().maxWorkspaceBytes,
                                                              budget: file.size).get()
            guard data.count == file.size, Self.digest(data) == hash else { throw Problem("The stored file failed its checksum.") }
            return data
        }
    }

    func delete(_ id: UUID) throws {
        try locked(create: false) {
            let entry = try readEntry(id)
            guard entry.manifest != nil else { throw Problem("This checkpoint needs a newer Nirux.") }
            let fm = FileManager.default
            guard mkdir(staging.path, 0o700) == 0 else { throw Self.fileError }
            try fm.moveItem(at: folder.appendingPathComponent(id.uuidString), to: staging.appendingPathComponent(id.uuidString))
            try fm.removeItem(at: staging)
        }
    }

    private func entries() throws -> [Entry] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .compactMap(UUID.init(uuidString:)).map(readEntry)
            .sorted { ($0.manifest?.createdAt ?? .distantFuture, $0.id.uuidString) > ($1.manifest?.createdAt ?? .distantFuture, $1.id.uuidString) }
    }

    private func readEntry(_ id: UUID) throws -> Entry {
        struct Version: Decodable { let schemaVersion: Int }
        let directory = folder.appendingPathComponent(id.uuidString)
        let url = directory.appendingPathComponent("manifest.json")
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Self.fileError }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= Limits().maxWorkspaceBytes else { throw Problem("Unreadable checkpoint manifest.") }
        let data = try handle.readToEnd() ?? Data()
        let decoder = JSONDecoder()
        let version = try decoder.decode(Version.self, from: data).schemaVersion
        let manifest = version == 1 ? try decoder.decode(Manifest.self, from: data) : nil
        if let manifest, manifest.id != id { throw Problem("Checkpoint identifier mismatch.") }
        return Entry(id: id, version: version, manifest: manifest, storedBytes: try Self.diskBytes(in: directory))
    }

    private static func diskBytes(in directory: URL) throws -> Int {
        var size = 0
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            var info = stat()
            guard lstat(file.path, &info) == 0 else { throw fileError }
            size += info.st_mode & S_IFMT == S_IFDIR ? try diskBytes(in: file) : Int(info.st_size)
        }
        return size
    }

    private struct Eviction: Codable {
        let saved: UUID
        let victims: [UUID]
    }

    private var staging: URL { folder.appendingPathComponent(".saving") }

    /// Publishing the new directory commits the eviction plan. A later opener finishes
    /// interrupted evictions and discards staging from an unpublished capture.
    private func finishSave() throws {
        let fm = FileManager.default
        var info = stat()
        guard lstat(staging.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw Self.fileError
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw Problem("Invalid checkpoint staging directory.") }
        let journal = staging.appendingPathComponent("eviction.json")
        if fm.fileExists(atPath: journal.path) {
            let plan = try JSONDecoder().decode(Eviction.self, from: Data(contentsOf: journal))
            if fm.fileExists(atPath: folder.appendingPathComponent(plan.saved.uuidString).path) {
                for id in plan.victims {
                    let victim = folder.appendingPathComponent(id.uuidString)
                    if fm.fileExists(atPath: victim.path), try readEntry(id).manifest != nil {
                        try fm.moveItem(at: victim, to: staging.appendingPathComponent(id.uuidString))
                    }
                }
            }
        }
        try fm.removeItem(at: staging)
    }

    func persist(_ capture: Capture) throws -> Manifest {
        try locked(create: true) {
            let existing = try entries()
            let protected = existing.filter { $0.manifest == nil }
            guard protected.count < limits.maxCheckpointsPerWorkspace else { throw Problem("Newer checkpoints occupy the workspace quota.") }
            let available = limits.maxWorkspaceBytes - protected.reduce(0) { $0 + $1.storedBytes }
            let (manifest, json) = try capture.fitting(bytes: available)
            let fm = FileManager.default
            guard mkdir(staging.path, 0o700) == 0 else { throw Self.fileError }
            let pending = staging.appendingPathComponent(manifest.id.uuidString)
            guard mkdir(pending.path, 0o700) == 0 else { throw Self.fileError }
            var bytes = json.count
            for hash in Set(manifest.files.compactMap(\.sha256)) {
                guard let data = capture.payloads[hash] else { throw Problem("Missing captured file.") }
                try SpaceDefaultsStore.writePrivately(data, to: pending.appendingPathComponent(hash))
                bytes += data.count
            }
            try SpaceDefaultsStore.writePrivately(json, to: pending.appendingPathComponent("manifest.json"))
            let destination = folder.appendingPathComponent(manifest.id.uuidString)
            var victims: [UUID] = []
            var count = existing.count + 1
            bytes += existing.reduce(0) { $0 + $1.storedBytes }
            for oldest in existing.reversed() where oldest.manifest != nil {
                if count <= limits.maxCheckpointsPerWorkspace && bytes <= limits.maxWorkspaceBytes { break }
                victims.append(oldest.id)
                bytes -= oldest.storedBytes
                count -= 1
            }
            let journal = try JSONEncoder().encode(Eviction(saved: manifest.id, victims: victims))
            try SpaceDefaultsStore.writePrivately(journal, to: staging.appendingPathComponent("eviction.json"))
            try fm.moveItem(at: pending, to: destination)
            try finishSave()
            return manifest
        }
    }
}
