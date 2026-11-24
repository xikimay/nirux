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

    /// The next step for a message to an agent whose hook may wait on its
    /// conversation, from where its letter is (`MissionMailbox.places`).
    /// `recipient`: the conversation the agent runs now, if known;
    /// `ended`: the conversation of its claim runs nowhere any more;
    /// `sentTo`: the one a `tell` was sent to, posted nowhere else.
    public static func hookStep(
        place: MissionLetterPlace?, recipient: String?, ended: Bool, sentTo: String? = nil, isArmed: (String) -> Bool
    ) -> MissionHookStep {
        switch place {
        case .claimed?:
            return ended ? .release : .leave
        case .waiting(let conversation)?:
            return conversation == recipient && isArmed(conversation) ? .leave : .retract(conversation)
        case nil:
            guard let recipient, sentTo == nil || sentTo == recipient, isArmed(recipient) else { return .type }
            return .post(recipient)
        }
    }
}

/// Where a Mission message's letter is.
public enum MissionLetterPlace: Equatable, Sendable {
    case waiting(conversation: String)
    case claimed(conversation: String)
}

/// See `MissionDeliveryPolicy.hookStep`.
public enum MissionHookStep: Equatable, Sendable {
    /// Its hook has it, or is about to.
    case leave
    /// Its claim's session ended before the turn that took it: drop the
    /// claim, then take the next step.
    case release
    /// Its waiter left that conversation: take it back, then take the next step.
    case retract(String)
    /// A waiter waits on that conversation.
    case post(String)
    /// No hook takes it: typing does.
    case type
}

/// Mission messages waiting for a conversation's hook, one folder each:
/// `<root>/<conversation>/waiting/<id>.json`. A letter leaves
/// `waiting` only by rename(2), so the hook that claims it and Nirux, taking
/// it back to type it, can't both have it.
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

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Leaves `letter` for `conversation`'s hook. False: it waits there
    /// already, or a hook claimed it and Nirux hasn't forgotten the claim.
    @discardableResult
    public func post(_ letter: Letter, to conversation: String) throws -> Bool {
        let waiting = try folder(.waiting, of: conversation), claimed = try folder(.claimed, of: conversation)
        try Self.requireName(letter.id)
        guard !Self.names(in: claimed).contains(where: { $0.hasSuffix("-\(letter.id).json") }) else { return false }
        let manager = FileManager.default
        try manager.createDirectory(at: drafts, withIntermediateDirectories: true)
        try manager.createDirectory(at: waiting, withIntermediateDirectories: true)
        let draft = drafts.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: draft) }
        try JSONEncoder().encode(letter).write(to: draft)
        switch Self.move(draft, to: waiting.appendingPathComponent("\(letter.id).json")) {
        case 0: return true
        case EEXIST: return false
        case let code: throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
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
        guard let waiting = try? folder(.waiting, of: conversation), let claimed = try? folder(.claimed, of: conversation),
              (try? FileManager.default.createDirectory(at: claimed, withIntermediateDirectories: true)) != nil
        else { return [] }
        return Self.oldestFirst(Self.names(in: waiting).compactMap { name in
            let source = waiting.appendingPathComponent(name)
            guard let letter = Self.letter(at: source),
                  Self.move(source, to: claimed.appendingPathComponent("\(Self.stamp(time))-\(name)")) == 0
            else { return nil }
            return letter
        })
    }

    /// Takes the letter `id` back from `conversation`'s folder. False: a
    /// hook claimed it, or it never was there.
    public func retract(_ id: String, from conversation: String) throws -> Bool {
        let waiting = try folder(.waiting, of: conversation)
        try Self.requireName(id)
        try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
        let taken = drafts.appendingPathComponent(UUID().uuidString)
        switch Self.move(waiting.appendingPathComponent("\(id).json"), to: taken) {
        case 0:
            try? FileManager.default.removeItem(at: taken)
            return true
        case ENOENT: return false
        case let code: throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// The letters hooks took that Nirux hasn't recorded yet, oldest claim first.
    public func claims() -> [Claim] {
        conversations().compactMap { try? folder(.claimed, of: $0) }.flatMap { folder -> [Claim] in
            let conversation = folder.deletingLastPathComponent().lastPathComponent
            return Self.names(in: folder).compactMap { name in
                let file = folder.appendingPathComponent(name)
                guard let stamp = name.split(separator: "-").first.flatMap({ Double($0) }), let letter = Self.letter(at: file)
                else { return nil }
                return Claim(conversation: conversation, letter: letter, claimedAt: stamp / 1000, file: file)
            }
        }
        .sorted {
            ($0.claimedAt, $0.letter.postedAt, $0.conversation, $0.letter.id) < ($1.claimedAt, $1.letter.postedAt, $1.conversation, $1.letter.id)
        }
    }

    /// Drops a claim Nirux recorded.
    public func forget(_ claim: Claim) throws {
        try FileManager.default.removeItem(at: claim.file)
    }

    /// Where each letter waits or was claimed, by its id.
    public func places() -> [String: MissionLetterPlace] {
        var places: [String: MissionLetterPlace] = [:]
        for conversation in conversations() {
            for name in (try? folder(.waiting, of: conversation)).map(Self.names) ?? [] {
                places[String(name.dropLast(5))] = .waiting(conversation: conversation)
            }
        }
        for claim in claims() { places[claim.letter.id] = .claimed(conversation: claim.conversation) }
        return places
    }

    /// A hook waiting on a conversation's letters: one at a time per
    /// conversation, holding its lock while it lives (`isArmed`).
    public final class Waiter: Sendable {
        let descriptor: Int32

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        deinit {
            close(descriptor)
        }
    }

    /// `conversation`'s waiter, or nil while another one waits there.
    /// `isArmed` takes the lock for an instant: a few tries ride it out.
    public func arm(_ conversation: String) throws -> Waiter? {
        let lock = try lockFile(of: conversation)
        try FileManager.default.createDirectory(at: try folder(.waiting, of: conversation), withIntermediateDirectories: true)
        let descriptor = open(lock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for attempt in 1...5 {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return Waiter(descriptor: descriptor) }
            guard errno == EWOULDBLOCK, attempt < 5 else { break }
            usleep(20_000)
        }
        close(descriptor)
        return nil
    }

    /// Whether a waiter waits on `conversation` now.
    public func isArmed(_ conversation: String) -> Bool {
        guard let lock = try? lockFile(of: conversation) else { return false }
        let descriptor = open(lock.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return flock(descriptor, LOCK_SH | LOCK_NB) != 0 && errno == EWOULDBLOCK
    }

    /// Claims `conversation`'s letters once there are any, waiting while
    /// `parent` runs, until `deadline`; empty when it stopped first.
    public func letters(for conversation: String, whileRunning parent: pid_t, until deadline: Date) -> [Letter] {
        guard let waiting = try? folder(.waiting, of: conversation),
              (try? FileManager.default.createDirectory(at: waiting, withIntermediateDirectories: true)) != nil
        else { return [] }
        let queue = kqueue()
        guard queue >= 0 else { return [] }
        defer { close(queue) }
        let watched = open(waiting.path, O_EVTONLY | O_CLOEXEC)
        guard watched >= 0 else { return [] }
        defer { close(watched) }
        var changes = [
            kevent(ident: UInt(watched), filter: Int16(EVFILT_VNODE), flags: UInt16(EV_ADD | EV_CLEAR), fflags: UInt32(NOTE_WRITE), data: 0, udata: nil),
            kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT), fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        ]
        // ESRCH: the parent is gone already.
        guard kevent(queue, &changes, Int32(changes.count), nil, 0, nil) == 0 else { return [] }
        while true {
            let letters = claim(conversation, at: Date().timeIntervalSince1970)
            let left = deadline.timeIntervalSinceNow
            guard letters.isEmpty, left > 0 else { return letters }
            let wait = min(left, 60)
            var timeout = timespec(tv_sec: Int(wait), tv_nsec: Int((wait - wait.rounded(.down)) * 1e9))
            var event = kevent()
            let count = kevent(queue, nil, 0, &event, 1, &timeout)
            if count < 0, errno != EINTR { return [] }
            if count > 0, event.filter == Int16(EVFILT_PROC) { return [] }
        }
    }

    /// Removes the folders of conversations with no letter, claim or waiter.
    public func prune() {
        for conversation in conversations() where !isArmed(conversation) {
            let states = [State.waiting, .claimed].compactMap { try? folder($0, of: conversation) }
            guard states.allSatisfy({ Self.names(in: $0).isEmpty }) else { continue }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(conversation, isDirectory: true))
        }
    }

    /// A conversation or letter id that could leave its folder.
    public struct InvalidName: Error, Equatable {
        public let name: String
    }

    private enum State: String {
        case waiting, claimed
    }

    private var drafts: URL { root.appendingPathComponent(".drafts", isDirectory: true) }

    private func conversations() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter(Self.isName)
    }

    private func lockFile(of conversation: String) throws -> URL {
        try Self.requireName(conversation)
        return root.appendingPathComponent(conversation, isDirectory: true).appendingPathComponent("waiter.lock")
    }

    private func folder(_ state: State, of conversation: String) throws -> URL {
        try Self.requireName(conversation)
        return root.appendingPathComponent(conversation, isDirectory: true).appendingPathComponent(state.rawValue, isDirectory: true)
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

    /// rename(2) that leaves an existing `destination` alone: 0, or the errno.
    private static func move(_ source: URL, to destination: URL) -> Int32 {
        renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
    }

    private static func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }
    }

    private static func letter(at file: URL) -> Letter? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Letter.self, from: $0) }
    }
}
