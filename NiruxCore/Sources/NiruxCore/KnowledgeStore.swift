import Foundation

/// A space's bricks on disk, in `<space dir>/knowledge/`: under `bricks/`
/// one file per brick named by its id, written once; `state.json`
/// (KnowledgeState); `served.json`, what the hook receiver hands agents
/// (ServedKnowledge); `sessions/`, what each agent session got. Folders
/// 0700, files 0600. Only the app writes the bricks and the state.
public struct KnowledgeStore: Sendable {
    public static let folderName = "knowledge"
    /// Bricks not closed, at most: the user validates each.
    public static let maxBricks = 20
    /// Proposals waiting for the user, at most.
    public static let maxPending = 3
    /// Decided proposals are kept this long, the newest `maxDecided`.
    public static let decidedLifetime: TimeInterval = 90 * 86_400
    public static let maxDecided = 100
    static let maxStateBytes = 512 * 1024
    static let maxBrickBytes = 16 * 1024
    static let maxBrickFiles = 500

    public let folder: URL

    public init(spaceFolder: URL) {
        folder = spaceFolder.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    var bricksFolder: URL { folder.appendingPathComponent("bricks", isDirectory: true) }
    var stateURL: URL { folder.appendingPathComponent("state.json") }
    public var servedURL: URL { folder.appendingPathComponent(ServedKnowledge.fileName) }
    public var sessionsFolder: URL { folder.appendingPathComponent("sessions", isDirectory: true) }

    /// The bricks and their state, as read.
    public struct Loaded: Equatable, Sendable {
        /// The validated bricks, by id.
        public var bricks: [String: KnowledgeBrick]
        public var state: KnowledgeState
        /// Why it can't be changed now, or nil.
        public var readOnlyReason: String?

        public init(bricks: [String: KnowledgeBrick] = [:], state: KnowledgeState = KnowledgeState(), readOnlyReason: String? = nil) {
            self.bricks = bricks
            self.state = state
            self.readOnlyReason = readOnlyReason
        }

        /// Validated bricks, oldest first.
        public var ordered: [(id: String, brick: KnowledgeBrick)] {
            bricks.map { ($0.key, $0.value) }.sorted { ($0.brick.validatedAt ?? 0, $0.id) < ($1.brick.validatedAt ?? 0, $1.id) }
        }

        public var pending: [BrickProposal] {
            state.proposals.filter(\.isPending).sorted { $0.proposedAt < $1.proposedAt }
        }

        public func state(of id: String) -> BrickState { state.bricks[id] ?? BrickState() }

        /// Bricks that aren't closed: they count against `maxBricks`.
        public var standing: Int { bricks.keys.filter { state(of: $0).closedAt == nil }.count }
    }

    public func load() -> Loaded {
        var loaded = Loaded()
        switch RegularFileRead.read(stateURL, maxBytes: Self.maxStateBytes) {
        case .missing:
            break
        case .unreadableBytes:
            loaded.readOnlyReason = "The space’s knowledge can’t be read just now: try again."
        case .tooLarge, .notARegularFile:
            loaded.readOnlyReason = "knowledge/state.json isn’t a small regular file: Nirux leaves it alone."
        case .data(let data):
            let version = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["schemaVersion"] as? Int
            if let state = try? JSONDecoder().decode(KnowledgeState.self, from: data) {
                loaded.state = state
            } else if version.map({ $0 <= KnowledgeState.currentSchemaVersion }) != false {
                // What it holds (closings, dismissals) must not be lost to an empty state.
                loaded.readOnlyReason = "knowledge/state.json can’t be read: Nirux leaves it alone."
            }
            if let version, version > KnowledgeState.currentSchemaVersion {
                loaded.readOnlyReason = "A newer Nirux keeps this space’s knowledge."
            }
        }
        loaded.bricks = readBricks()
        return loaded
    }

    /// Each `bricks/<id>.json` whose content is that id: a file changed by
    /// hand is no longer the brick it was named after.
    private func readBricks() -> [String: KnowledgeBrick] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: bricksFolder.path) else { return [:] }
        var bricks: [String: KnowledgeBrick] = [:]
        for name in names.sorted().prefix(Self.maxBrickFiles) where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            guard let data = RegularFileRead.read(bricksFolder.appendingPathComponent(name), maxBytes: Self.maxBrickBytes).contents,
                  let brick = try? JSONDecoder().decode(KnowledgeBrick.self, from: data),
                  brick.id == id, brick.validatedAt != nil
            else { continue }
            bricks[id] = brick
        }
        return bricks
    }

    /// Writes `state`, without decided proposals past their lifetime or past
    /// the newest `maxDecided`.
    public func save(_ state: KnowledgeState, now: TimeInterval) throws {
        var state = state
        let recent = state.proposals.filter { proposal in
            proposal.decidedAt.map { now - $0 < Self.decidedLifetime } ?? true
        }
        let dropped = Set(recent.filter { !$0.isPending }.sorted { ($0.decidedAt ?? 0) > ($1.decidedAt ?? 0) }
            .dropFirst(Self.maxDecided).map(\.id))
        state.proposals = recent.filter { !dropped.contains($0.id) }
        try Self.writePrivately(try Self.encoded(state), to: stateURL)
    }

    /// Writes `brick`'s file once; one already there with the same content
    /// is left as it is. Returns its id.
    @discardableResult
    public func add(_ brick: KnowledgeBrick) throws -> String {
        let id = brick.id
        let url = bricksFolder.appendingPathComponent(id + ".json")
        if let data = RegularFileRead.read(url, maxBytes: Self.maxBrickBytes).contents,
           (try? JSONDecoder().decode(KnowledgeBrick.self, from: data))?.id == id {
            return id
        }
        try Self.writePrivately(try Self.encoded(brick), to: url)
        return id
    }

    /// Writes what agents get, or removes it (nil): with nothing served, the
    /// receiver reads no further.
    public func writeServed(_ served: ServedKnowledge?) throws {
        guard let served, !served.bricks.isEmpty else {
            if unlink(servedURL.path) != 0, errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return
        }
        try Self.writePrivately(try Self.encoded(served), to: servedURL)
    }

    /// Session files untouched for `days` go: a session that old is over.
    public func removeSessions(olderThan days: Double, now: TimeInterval) {
        let folder = sessionsFolder
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasSuffix(".json") {
            let path = folder.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  now - TimeInterval(info.st_mtimespec.tv_sec) > days * 86_400 else { continue }
            unlink(path)
        }
    }

    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// Replaces `url` atomically with a 0600 file, its folders made 0700.
    public static func writePrivately(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            unlink(temporary.path)
            throw error
        }
    }
}

// MARK: - Changes

extension KnowledgeStore.Loaded {
    /// Why `brick` can't be proposed now, or nil.
    public enum Refusal: Equatable, Sendable {
        case invalid(String)
        case alreadyPending(since: TimeInterval)
        case dismissed(at: TimeInterval)
        /// The same brick exists, in this state.
        case exists(BrickStatus)
        case replacesUnknown(String)
        /// A brick it rests on that the space doesn't hold, or doesn't serve.
        case restsOnUnknown(String)
        case restsOnNotServed(String, BrickStatus)
        case tooManyPending
        case full
        case readOnly(String)
    }

    /// `validating`: the proposal itself waits; the checks a validation
    /// needs (the space's room, the brick it replaces) still apply.
    public func refusal(of brick: KnowledgeBrick, now: TimeInterval, macOS: Int, validating: Bool = false) -> Refusal? {
        if let reason = readOnlyReason { return .readOnly(reason) }
        if let problem = brick.problem { return .invalid(problem) }
        let id = brick.id
        if let status = status(of: id, now: now, macOS: macOS) { return .exists(status) }
        if !validating, let same = state.proposals.first(where: { $0.id == id }) {
            if let dismissed = same.dismissedAt { return .dismissed(at: dismissed) }
            if same.isPending { return .alreadyPending(since: same.proposedAt) }
        }
        if let replaced = brick.replaces, bricks[replaced] == nil { return .replacesUnknown(replaced) }
        for base in brick.restsOn ?? [] {
            guard let status = status(of: base, now: now, macOS: macOS) else { return .restsOnUnknown(base) }
            guard status.isServed else { return .restsOnNotServed(base, status) }
        }
        let others = pending.filter { $0.id != id }.count
        guard validating || others < KnowledgeStore.maxPending else { return .tooManyPending }
        // A replacement takes its brick's place; at validation, the others
        // waiting still count, so validating them all stays within room.
        let freed = brick.replaces.map { state(of: $0).closedAt == nil } == true ? 1 : 0
        guard standing - freed + others < KnowledgeStore.maxBricks else { return .full }
        return nil
    }

    /// Marks the proposal `id` validated and returns its brick, dated, to
    /// write before the state; nil when it no longer waits.
    public mutating func validate(_ id: String, now: TimeInterval) -> KnowledgeBrick? {
        guard let index = state.proposals.firstIndex(where: { $0.id == id && $0.isPending }) else { return nil }
        state.proposals[index].validatedAt = now
        var brick = state.proposals[index].brick
        brick.validatedAt = now
        bricks[id] = brick
        state.bricks[id] = state.bricks[id] ?? BrickState()
        if let replaced = brick.replaces, bricks[replaced] != nil {
            var old = state(of: replaced)
            if old.closedAt == nil {
                old.closedAt = now
                old.closedBecause = "Replaced by a brick you validated."
            }
            // A brick two proposals replaced keeps the first.
            if old.replacedBy == nil { old.replacedBy = id }
            state.bricks[replaced] = old
        }
        return brick
    }

    /// The user read an agent's flag: no longer listed.
    public mutating func dismissFlag(_ id: String) -> Bool {
        guard !(state.dismissedFlags ?? []).contains(id) else { return false }
        state.dismissedFlags = (state.dismissedFlags ?? []) + [id]
        return true
    }

    public mutating func dismiss(_ id: String, now: TimeInterval) -> Bool {
        guard let index = state.proposals.firstIndex(where: { $0.id == id && $0.isPending }) else { return false }
        state.proposals[index].dismissedAt = now
        return true
    }

    /// Served again: no longer suspect, its expiry and macOS version from now.
    public mutating func reconfirm(_ id: String, now: TimeInterval, macOS: Int) -> Bool {
        guard bricks[id] != nil, state(of: id).closedAt == nil else { return false }
        var brick = state(of: id)
        brick.reconfirmedAt = now
        // Only a brick macOS may change records where it was confirmed.
        if bricks[id]?.macOS != nil { brick.reconfirmedMacOS = macOS }
        brick.suspectAt = nil
        brick.suspectBecause = nil
        brick.failedAt = nil
        brick.failedBecause = nil
        state.bricks[id] = brick
        return true
    }

    public mutating func close(_ id: String, because reason: String, now: TimeInterval) -> Bool {
        guard bricks[id] != nil, state(of: id).closedAt == nil else { return false }
        var brick = state(of: id)
        brick.closedAt = now
        brick.closedBecause = reason
        state.bricks[id] = brick
        return true
    }

    /// Not served until reconfirmed; an earlier reason stays.
    public mutating func suspect(_ id: String, because reason: String, now: TimeInterval) -> Bool {
        guard bricks[id] != nil, state(of: id).closedAt == nil, state(of: id).suspectAt == nil else { return false }
        var brick = state(of: id)
        brick.suspectAt = now
        brick.suspectBecause = reason
        state.bricks[id] = brick
        return true
    }
}
