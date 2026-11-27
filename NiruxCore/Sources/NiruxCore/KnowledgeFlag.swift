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

    public static func append(_ flag: KnowledgeFlag, in store: KnowledgeStore) throws {
        let url = store.folder.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        if stat(url.path, &info) == 0, info.st_size >= maxFileBytes { throw CocoaError(.fileWriteOutOfSpace) }
        var line = try JSONEncoder().encode(flag)
        line.append(UInt8(ascii: "\n"))
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard line.withUnsafeBytes({ write(descriptor, $0.baseAddress, $0.count) }) == line.count else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public static func load(in store: KnowledgeStore) -> [KnowledgeFlag] {
        guard let data = RegularFileRead.read(store.folder.appendingPathComponent(fileName), maxBytes: maxFileBytes + 65_536).contents
        else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(KnowledgeFlag.self, from: $0) }
    }

    /// Rewrites the file without the flags past `keptDays`, when it has some.
    public static func trim(in store: KnowledgeStore, now: TimeInterval) {
        let flags = load(in: store)
        let kept = flags.filter { now - $0.time < Double(keptDays) * 86_400 }
        guard kept.count < flags.count else { return }
        let lines = kept.compactMap { try? JSONEncoder().encode($0) }.map { $0 + Data("\n".utf8) }
        try? KnowledgeStore.writePrivately(lines.reduce(Data(), +), to: store.folder.appendingPathComponent(fileName))
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
            #"(?i)\b(password|passwd|secret|token|api[_-]?key)\s*[:=]\s*\S{6,}"#,
            #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, #"(?:\+|\b00)\d[\d .-]{8,}\d"#
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}
