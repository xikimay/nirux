import CryptoKit
import Foundation

/// What an agent signals about the space's knowledge, with no right to
/// change it (`flag_knowledge`): a fact it lacked (gap), a brick proven
/// wrong (error), two that disagree or a brick the code contradicts
/// (contradiction). One line of `knowledge/flags.jsonl`, kept 90 days. The
/// user sees them in Space Memory; an error or contradiction on a brick in
/// two tasks makes it suspect, as corrections do.
public struct KnowledgeFlag: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case gap, error, contradiction }

    public var id: String
    public var time: TimeInterval
    public var kind: Kind
    /// The brick it is about, when one is.
    public var brick: String?
    /// What it is about, in a few words.
    public var about: String
    public var text: String
    /// Where it showed (a test, a PR, a file and line).
    public var evidence: String?
    /// The workspace of the agent that flagged it: its task.
    public var task: String?

    public init(time: TimeInterval, kind: Kind, brick: String?, about: String, text: String, evidence: String?, task: String?) {
        self.time = time
        self.kind = kind
        self.brick = brick
        self.about = about
        self.text = text
        self.evidence = evidence
        self.task = task
        let key = [String(time), kind.rawValue, brick ?? "", about, text, task ?? ""].joined(separator: "\n")
        id = "f-" + SHA256.hash(data: Data(key.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    enum CodingKeys: String, CodingKey { case id, time = "t", kind, brick, about, text, evidence, task }

    public static let fileName = "flags.jsonl"
    public static let keptDays = 90
    public static let maxAbout = 80
    public static let maxText = 300
    public static let maxEvidence = 200
    /// Flags a task may write in a day, and kept at most by a trim.
    public static let maxPerTaskPerDay = 5
    static let maxKept = 1_000
    static let maxFileBytes = 1_000_000

    /// Why it can't be recorded, or nil: short single lines, nothing that
    /// looks like a secret or someone's contact details.
    public static func problem(about: String, text: String, evidence: String?) -> String? {
        for (field, value, limit) in [("about", about, maxAbout), ("text", text, maxText), ("evidence", evidence ?? "x", maxEvidence)] {
            guard (1...limit).contains(value.count), !value.contains(where: \.isNewline) else {
                return "\(field) must be one line of at most \(limit) characters."
            }
        }
        if [about, text, evidence ?? ""].contains(where: KnowledgeText.looksPrivate) {
            return "It looks like it holds a secret or personal details: say it without them."
        }
        return nil
    }

    static let lockName = "flags.lock"

    /// Appends `flag` under the lock a trim takes.
    public static func append(_ flag: KnowledgeFlag, in store: KnowledgeStore) throws {
        let url = store.folder.appendingPathComponent(fileName)
        var line = try JSONEncoder().encode(flag)
        line.append(UInt8(ascii: "\n"))
        var failure: Error?
        let ran = store.locked(lockName, attempts: 100) {
            var info = stat()
            if stat(url.path, &info) == 0, info.st_size >= maxFileBytes { return failure = CocoaError(.fileWriteOutOfSpace) }
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(descriptor) }
            if line.withUnsafeBytes({ write(descriptor, $0.baseAddress, $0.count) }) != line.count {
                failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        if !ran { throw POSIXError(.EBUSY) }
        if let failure { throw failure }
    }

    public static func load(in store: KnowledgeStore) -> [KnowledgeFlag] {
        loadIfReadable(in: store) ?? []
    }

    /// Nil when the file is there but couldn't be read.
    public static func loadIfReadable(in store: KnowledgeStore) -> [KnowledgeFlag]? {
        let data: Data
        switch RegularFileRead.read(store.folder.appendingPathComponent(fileName), maxBytes: maxFileBytes + 65_536) {
        case .missing: return []
        case .data(let read): data = read
        case .notARegularFile, .tooLarge, .unreadableBytes: return nil
        }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(KnowledgeFlag.self, from: $0) }
    }

    /// Rewrites the file without the flags past `keptDays`, when it has some.
    public static func trim(in store: KnowledgeStore, now: TimeInterval) {
        store.locked(lockName, attempts: 300) {
            let flags = load(in: store)
            let kept = flags.filter { now - $0.time < Double(keptDays) * 86_400 }.suffix(maxKept)
            guard kept.count < flags.count else { return }
            let lines = kept.compactMap { try? JSONEncoder().encode($0) }.map { $0 + Data("\n".utf8) }
            try? KnowledgeStore.writePrivately(lines.reduce(Data(), +), to: store.folder.appendingPathComponent(fileName))
        }
    }

    /// Says a brick is wrong: it counts toward suspicion.
    public var faultsItsBrick: Bool { brick != nil && kind != .gap }
}

extension KnowledgeText {
    /// A secret (a key, a token, a private key block, "password = …") or
    /// personal details (an email address, a phone number).
    public static func looksPrivate(_ text: String) -> Bool {
        let patterns = [
            #"-----BEGIN [A-Z ]*PRIVATE KEY"#, #"\bgh[pousr]_[A-Za-z0-9]{20,}"#, #"\bgithub_pat_[A-Za-z0-9_]{20,}"#,
            #"\bsk-[A-Za-z0-9_-]{20,}"#, #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, #"\bAKIA[0-9A-Z]{16}\b"#, #"\bAIza[0-9A-Za-z_-]{30,}"#,
            // A value given, quoted or with a digit: not "token = makeToken()".
            #"(?i)\b(password|passwd|secret|token|api[_-]?key)\s*[:=]\s*(["'][^"'\s]{6,}["']|(?=[A-Za-z_./+-]*\d)[A-Za-z0-9_./+-]{8,}(?![\w(]))"#,
            #"\bBearer\s+[A-Za-z0-9._~+/-]{20,}"#, #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#,
            // An address: a domain of words, not "icon@2x.png".
            // (not a git remote, not a noreply address)
            #"(?<![\w.%+-])(?!git@)(?![\w.+-]*no-?reply@)[A-Za-z0-9._%+-]+@[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)*\.(?!(png|jpe?g|gif|svg|pdf|swift|json|md|txt|html?|js|css)\b)[A-Za-z]{2,}\b"#,
            // An international number: "+33 6 12 34 56 78", not "+0000 2026-11-27".
            #"\+\d{1,3}[ .]?\d(?:[ .]?\d){7,12}\b"#, #"\b0[1-9](?:[ .]\d{2}){4}\b"#
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}
