import Foundation

/// How a Mission message reaches its agent (docs/design/mission-delivery.md),
/// from the most to the least wanted.
public enum MissionTransport: Int, Comparable, CaseIterable, Sendable {
    /// The agent's own interface starts it, idle or mid-turn.
    case push
    /// A hook of the agent takes it from its `MissionMailbox`.
    case hook
    /// The agent's own queue starts it once its turn ends (`codex queue`).
    case queue
    /// Pasted into its prompt, then Enter.
    case typed

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum MissionDeliveryPolicy {
    /// What carries a message to an agent `carriers` reach now: the most
    /// wanted, typing only when none other does. nil: it waits.
    public static func transport(carriers: Set<MissionTransport>, typingRefused: Bool) -> MissionTransport? {
        if let best = carriers.subtracting([.typed]).min() { return best }
        return carriers.contains(.typed) && !typingRefused ? .typed : nil
    }
}

/// Mission messages for a conversation's hook (a Claude session, a Codex
/// thread, an agy conversation), one folder each:
///
///     <root>/<conversation>/ids/<id>                   the letter is here
///     <root>/<conversation>/waiting/<id>.json          for its hook
///     <root>/<conversation>/claimed/<ms>-<id>.json     its hook took it
///     <root>/<conversation>/owed/<id>.json             Nirux took it back to type it
///
/// A letter moves only by rename(2), so the hook that claims it and Nirux,
/// taking it back, can't both have it; its id's marker, created exclusively,
/// keeps it from being posted twice until Nirux is done with it.
public struct MissionMailbox: Sendable {
    public struct Letter: Codable, Hashable, Sendable {
        public var id: String
        public var text: String
        public var postedAt: TimeInterval

        public init(id: String, text: String, postedAt: TimeInterval) {
            self.id = id
            self.text = text
            self.postedAt = postedAt
        }
    }

    /// A letter a hook took, kept until Nirux records it (`forget`).
    public struct Claim: Hashable, Sendable {
        public let conversation: String
        public let letter: Letter
        public let claimedAt: TimeInterval
        let file: URL
    }

    /// A letter Nirux took back and owes to typing (`markTyped`).
    public struct Owed: Hashable, Sendable {
        public let conversation: String
        public let letter: Letter
    }

    /// What `retract` found.
    public enum Retraction: Equatable, Sendable {
        /// Taken back: owed to typing (`owed`) until `markTyped`.
        case retracted
        /// A hook has it.
        case claimed
        /// Nothing of that id: never posted, posted and failed, or done with.
        case unknown
    }

    /// Typed Missions give up after a day: so does the mailbox (`sweep`).
    public static let lifetime: TimeInterval = 86_400
    /// A draft or a marker with no letter this old is a crash's.
    public static let leftoverAge: TimeInterval = 60

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Leaves `letter` for `conversation`'s hook. False: a letter of that id
    /// is there already, waiting, claimed or owed. Throws with nothing left
    /// behind, for Nirux to type it.
    @discardableResult
    public func post(_ letter: Letter, to conversation: String, now: TimeInterval = Date().timeIntervalSince1970) throws -> Bool {
        try Self.requireName(letter.id)
        let marker = try folder(.ids, of: conversation).appendingPathComponent(letter.id)
        guard try Self.mark(marker) || (place(of: letter.id, in: conversation) == nil
            && Self.age(of: marker, now: now) >= Self.leftoverAge && (try? FileManager.default.removeItem(at: marker)) != nil
            && Self.mark(marker))
        else { return false }
        do {
            let manager = FileManager.default
            let waiting = try folder(.waiting, of: conversation)
            try manager.createDirectory(at: drafts, withIntermediateDirectories: true)
            try manager.createDirectory(at: waiting, withIntermediateDirectories: true)
            let draft = drafts.appendingPathComponent(UUID().uuidString)
            defer { try? manager.removeItem(at: draft) }
            try JSONEncoder().encode(letter).write(to: draft)
            let code = Self.move(draft, to: waiting.appendingPathComponent("\(letter.id).json"))
            guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            return true
        } catch {
            try? FileManager.default.removeItem(at: marker)
            throw error
        }
    }

    /// The letters waiting for `conversation`, oldest first, left in place.
    public func waiting(for conversation: String) -> [Letter] {
        guard let folder = try? folder(.waiting, of: conversation) else { return [] }
        return Self.oldestFirst(Self.names(in: folder).compactMap { Self.letter(at: folder.appendingPathComponent($0)) })
    }

    /// Takes the letters waiting for `conversation`, oldest first: each one
    /// only this call gets. One it can't read stays, for Nirux to type.
    public func claim(_ conversation: String, at time: TimeInterval) -> [Letter] {
        guard let waiting = try? folder(.waiting, of: conversation), let claimed = try? folder(.claimed, of: conversation) else { return [] }
        let names = Self.names(in: waiting)
        guard !names.isEmpty, (try? FileManager.default.createDirectory(at: claimed, withIntermediateDirectories: true)) != nil
        else { return [] }
        return Self.oldestFirst(names.compactMap { name in
            let source = waiting.appendingPathComponent(name)
            guard let letter = Self.letter(at: source),
                  Self.move(source, to: claimed.appendingPathComponent("\(Self.stamp(time))-\(name)")) == 0
            else { return nil }
            return letter
        })
    }

    /// Takes the letter `id` back from `conversation`, for Nirux to type
    /// it. A letter taken back earlier and not typed yet is still `.retracted`.
    /// Any other failure throws, so a disk error never reads as a hook's.
    public func retract(_ id: String, from conversation: String) throws -> Retraction {
        try Self.requireName(id)
        let waiting = try folder(.waiting, of: conversation).appendingPathComponent("\(id).json")
        let owed = try folder(.owed, of: conversation)
        if FileManager.default.fileExists(atPath: waiting.path) {
            try FileManager.default.createDirectory(at: owed, withIntermediateDirectories: true)
        }
        switch Self.move(waiting, to: owed.appendingPathComponent("\(id).json")) {
        case 0: return .retracted
        case ENOENT:
            switch place(of: id, in: conversation) {
            case .owed?: return .retracted
            case .claimed?: return .claimed
            case .waiting?, .ids?, nil: return .unknown
            }
        case let code: throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// The letters Nirux took back and hasn't typed yet, oldest first.
    public func owed() -> [Owed] {
        conversations().flatMap { conversation -> [Owed] in
            guard let folder = try? folder(.owed, of: conversation) else { return [] }
            return Self.oldestFirst(Self.names(in: folder).compactMap { Self.letter(at: folder.appendingPathComponent($0)) })
                .map { Owed(conversation: conversation, letter: $0) }
        }
        .sorted { ($0.letter.postedAt, $0.conversation, $0.letter.id) < ($1.letter.postedAt, $1.conversation, $1.letter.id) }
    }

    /// Nirux typed the letter `id` it took back: done with it.
    public func markTyped(_ id: String, in conversation: String) throws {
        try Self.requireName(id)
        try Self.remove(try folder(.owed, of: conversation).appendingPathComponent("\(id).json"))
        try Self.remove(try folder(.ids, of: conversation).appendingPathComponent(id))
    }

    /// The letters hooks took that Nirux hasn't recorded yet, oldest claim first.
    public func claims() -> [Claim] {
        conversations().compactMap { try? folder(.claimed, of: $0) }.flatMap { folder -> [Claim] in
            let conversation = folder.deletingLastPathComponent().lastPathComponent
            return Self.names(in: folder).compactMap { name in
                let file = folder.appendingPathComponent(name)
                guard let stamp = Self.claimedStamp(of: name), let letter = Self.letter(at: file) else { return nil }
                return Claim(conversation: conversation, letter: letter, claimedAt: stamp / 1000, file: file)
            }
        }
        .sorted {
            ($0.claimedAt, $0.letter.postedAt, $0.conversation, $0.letter.id) < ($1.claimedAt, $1.letter.postedAt, $1.conversation, $1.letter.id)
        }
    }

    /// Drops a claim Nirux recorded: done with it.
    public func forget(_ claim: Claim) throws {
        try Self.remove(claim.file)
        try Self.remove(try folder(.ids, of: claim.conversation).appendingPathComponent(claim.letter.id))
    }

    /// Drops what is `lifetime` old: letters waiting or owed, by when they
    /// were posted, and claims, by when they were taken. Then what a crash
    /// left `leftoverAge` ago (a draft, a marker with no letter), and the
    /// folders left empty.
    public func sweep(now: TimeInterval) {
        let manager = FileManager.default
        let expired = now - Self.lifetime
        for claim in claims() where claim.claimedAt < expired { try? forget(claim) }
        for conversation in conversations() {
            guard let waiting = try? folder(.waiting, of: conversation), let owed = try? folder(.owed, of: conversation),
                  let markers = try? folder(.ids, of: conversation) else { continue }
            for name in Self.names(in: waiting) where Self.postedAt(waiting.appendingPathComponent(name)) < expired {
                // Out of reach first: a hook may be claiming it.
                let taken = drafts.appendingPathComponent(UUID().uuidString)
                guard (try? manager.createDirectory(at: drafts, withIntermediateDirectories: true)) != nil,
                      Self.move(waiting.appendingPathComponent(name), to: taken) == 0 else { continue }
                try? manager.removeItem(at: taken)
                try? manager.removeItem(at: markers.appendingPathComponent(String(name.dropLast(5))))
            }
            for name in Self.names(in: owed) where Self.postedAt(owed.appendingPathComponent(name)) < expired {
                try? markTyped(String(name.dropLast(5)), in: conversation)
            }
            let leftover = (try? manager.contentsOfDirectory(atPath: markers.path)) ?? []
            for id in leftover where place(of: id, in: conversation) == nil
                && Self.age(of: markers.appendingPathComponent(id), now: now) >= Self.leftoverAge {
                try? manager.removeItem(at: markers.appendingPathComponent(id))
            }
            // rmdir(2) leaves a folder something just went into.
            for state in [State.waiting, .claimed, .owed, .ids] { rmdir((try? folder(state, of: conversation))?.path ?? "") }
            rmdir(root.appendingPathComponent(conversation, isDirectory: true).path)
        }
        for name in (try? manager.contentsOfDirectory(atPath: drafts.path)) ?? []
        where Self.age(of: drafts.appendingPathComponent(name), now: now) >= Self.leftoverAge {
            try? manager.removeItem(at: drafts.appendingPathComponent(name))
        }
    }

    /// A conversation or letter id that could leave its folder.
    public struct InvalidName: Error, Equatable {
        public let name: String
    }

    private enum State: String {
        case waiting, claimed, owed, ids
    }

    private var drafts: URL { root.appendingPathComponent(".drafts", isDirectory: true) }

    private func folder(_ state: State, of conversation: String) throws -> URL {
        try Self.requireName(conversation)
        return root.appendingPathComponent(conversation, isDirectory: true).appendingPathComponent(state.rawValue, isDirectory: true)
    }

    private func conversations() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter(Self.isName)
    }

    /// Where the letter `id` is in `conversation`, if anywhere.
    private func place(of id: String, in conversation: String) -> State? {
        let file = "\(id).json"
        if let waiting = try? folder(.waiting, of: conversation), Self.names(in: waiting).contains(file) { return .waiting }
        if let owed = try? folder(.owed, of: conversation), Self.names(in: owed).contains(file) { return .owed }
        if let claimed = try? folder(.claimed, of: conversation),
           Self.names(in: claimed).contains(where: { Self.claimedStamp(of: $0) != nil && $0.split(separator: "-", maxSplits: 1).last == file[...] }) {
            return .claimed
        }
        return nil
    }

    private static func requireName(_ text: String) throws {
        guard isName(text) else { throw InvalidName(name: text) }
    }

    /// A session, thread or conversation id, or a Mission event's: a file
    /// name that can't climb out of its folder.
    static func isName(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, first != ".", text.unicodeScalars.count <= 128 else { return false }
        return text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }
    }

    private static func oldestFirst(_ letters: [Letter]) -> [Letter] {
        letters.sorted { ($0.postedAt, $0.id) < ($1.postedAt, $1.id) }
    }

    /// Milliseconds.
    private static func stamp(_ time: TimeInterval) -> String {
        String(time.isFinite ? Int64(min(max(0, time * 1000), 1e15).rounded()) : 0)
    }

    /// The milliseconds a claimed letter's name starts with.
    private static func claimedStamp(of name: String) -> Double? {
        name.split(separator: "-", maxSplits: 1).first.flatMap { Double($0) }
    }

    /// Creates `marker` unless it exists: false then.
    private static func mark(_ marker: URL) throws -> Bool {
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(marker.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return false
        }
        close(descriptor)
        return true
    }

    /// rename(2) that leaves an existing `destination` alone: 0, or the errno.
    private static func move(_ source: URL, to destination: URL) -> Int32 {
        renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
    }

    /// Removes `file`; one already gone is fine.
    private static func remove(_ file: URL) throws {
        guard unlink(file.path) == 0 || errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func age(of file: URL, now: TimeInterval) -> TimeInterval {
        let modified = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)?.timeIntervalSince1970
        return now - (modified ?? now)
    }

    /// When a letter was posted; an unreadable one, when it was written.
    private static func postedAt(_ file: URL) -> TimeInterval {
        letter(at: file)?.postedAt ?? (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }

    private static func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }
    }

    private static func letter(at file: URL) -> Letter? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Letter.self, from: $0) }
    }
}
