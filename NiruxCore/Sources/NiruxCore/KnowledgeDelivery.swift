import CryptoKit
import Foundation

/// What the hook receiver hands agents, compiled by the app from the open
/// bricks each time their state changes: `<space dir>/knowledge/served.json`,
/// absent while nothing is served (the space's switch off, no open brick).
public struct ServedKnowledge: Codable, Equatable, Sendable {
    public static let fileName = "served.json"
    public static let maxBytes = 256 * 1024

    public var bricks: [Brick]

    public init(bricks: [Brick]) {
        self.bricks = bricks
    }

    public struct Brick: Codable, Equatable, Sendable {
        public var id: String
        public var sentence: String
        public var subject: String
        public var anchor: String
        public var name: String
        public var paths: [String]
        /// Its proofs, as its card names them.
        public var proof: String
        /// Not served from then on, unless the app compiles it again.
        public var servedUntil: TimeInterval?
        /// The macOS major version it holds on, when macOS may change it.
        public var macOS: Int?

        public init(
            id: String, sentence: String, subject: String, anchor: String, name: String, paths: [String], proof: String,
            servedUntil: TimeInterval? = nil, macOS: Int? = nil
        ) {
            self.id = id
            self.sentence = sentence
            self.subject = subject
            self.anchor = anchor
            self.name = name
            self.paths = paths
            self.proof = proof
            self.servedUntil = servedUntil
            self.macOS = macOS
        }

        public func isServed(now: TimeInterval, macOS current: Int) -> Bool {
            (servedUntil.map { now < $0 } ?? true) && (macOS.map { $0 == current } ?? true)
        }

        /// What an agent reads of it: one line.
        public var line: String { "- \(sentence) (proof: \(proof))" }
    }

    /// The open bricks of `loaded`, oldest first.
    public static func compile(_ loaded: KnowledgeStore.Loaded, now: TimeInterval, macOS: Int) -> ServedKnowledge {
        ServedKnowledge(bricks: loaded.ordered.compactMap { id, brick in
            let state = loaded.state(of: id)
            guard loaded.status(of: id, now: now, macOS: macOS)?.isServed == true else { return nil }
            let bounds = loaded.servedBounds(of: id, macOS: macOS)
            return Brick(
                id: id, sentence: brick.sentence, subject: brick.subject, anchor: brick.scope.anchor, name: brick.scope.name,
                paths: brick.scope.paths, proof: brick.proofs.map(\.label).joined(separator: " · "),
                // A brick resting on others stops with the first of them.
                servedUntil: bounds.until, macOS: bounds.macOS
            )
        })
    }

    public static func read(_ url: URL) -> ServedKnowledge? {
        RegularFileRead.read(url, maxBytes: maxBytes).contents.flatMap { try? JSONDecoder().decode(ServedKnowledge.self, from: $0) }
    }
}

// MARK: - Which bricks a file touch brings

public enum KnowledgeDelivery {
    /// What a session gets at most, in UTF-8 bytes: about 750 tokens.
    public static let budget = 3_000

    /// The served bricks about `path` (relative to `anchor`'s top) that
    /// `session` hasn't had, oldest first, while they fit what is left of
    /// the budget with the header.
    public static func pick(
        _ served: ServedKnowledge, anchor: String, path: String, session: KnowledgeSession, now: TimeInterval, macOS: Int
    ) -> [ServedKnowledge.Brick] {
        let name = served.bricks.first { $0.anchor == anchor }?.name ?? ""
        return pick(served, anchor: anchor, paths: [path], header: header(about: about(name, path: path)), session: session, now: now, macOS: macOS)
    }

    /// The served bricks about any of `paths`, for an agent that gets them
    /// at its start (Codex), within the whole budget.
    public static func pick(_ served: ServedKnowledge, anchor: String, paths: [String], now: TimeInterval, macOS: Int) -> [ServedKnowledge.Brick] {
        pick(served, anchor: anchor, paths: paths, header: header(about: branchFiles), session: KnowledgeSession(), now: now, macOS: macOS)
    }

    private static func pick(
        _ served: ServedKnowledge, anchor: String, paths: [String], header: String, session: KnowledgeSession, now: TimeInterval, macOS: Int
    ) -> [ServedKnowledge.Brick] {
        var room = budget - session.bytes - header.utf8.count
        var picked: [ServedKnowledge.Brick] = []
        for brick in served.bricks where brick.anchor == anchor && brick.isServed(now: now, macOS: macOS)
            && session.delivered[brick.id] == nil && !session.pending.contains(brick.id)
            && brick.paths.contains(where: { pattern in paths.contains { KnowledgePath.matches(pattern, $0) } }) {
            let cost = brick.line.utf8.count + 1
            guard cost <= room else { continue }
            room -= cost
            picked.append(brick)
        }
        return picked
    }

    /// What an agent reads, for bricks about `about`: a file
    /// (`about(_:path:)`), the files it just opened, its branch's.
    public static func text(_ bricks: [ServedKnowledge.Brick], about: String) -> String {
        ([header(about: about)] + bricks.map(\.line)).joined(separator: "\n")
    }

    public static let openedFiles = "the files you just opened"
    public static let branchFiles = "the files this branch changes"

    /// A file of a repository, as a header names it.
    public static func about(_ name: String, path: String) -> String { (name.isEmpty ? "" : name + "/") + path }

    static func header(about: String) -> String {
        "Nirux space knowledge about \(about): facts the user validated, their proofs rechecked by Nirux."
    }

    /// What `text` takes of a session's budget.
    public static func cost(_ text: String) -> Int { text.utf8.count }
}

// MARK: - Paths

/// A brick's paths against a file's, both relative to the same top.
public enum KnowledgePath {
    /// A pattern without wildcards names a file, or a folder and what it
    /// holds; `*` and `?` stay within a name, `**` spans folders.
    public static func matches(_ pattern: String, _ path: String) -> Bool {
        let pattern = pattern.hasPrefix("./") ? String(pattern.dropFirst(2)) : pattern
        guard pattern.contains(where: { "*?".contains($0) }) else {
            let folder = pattern.hasSuffix("/") ? String(pattern.dropLast()) : pattern
            return path == folder || path.hasPrefix(folder + "/")
        }
        guard let regex = try? NSRegularExpression(pattern: "^" + expression(pattern) + "$") else { return false }
        return regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    private static func expression(_ pattern: String) -> String {
        var result = ""
        var characters = Array(pattern)[...]
        while let character = characters.popFirst() {
            switch character {
            case "*" where characters.first == "*":
                characters.removeFirst()
                if characters.first == "/" {
                    characters.removeFirst()
                    result += "(?:.*/)?"
                } else {
                    result += ".*"
                }
            case "*": result += "[^/]*"
            case "?": result += "[^/]"
            default: result += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        // A folder pattern ("Views/**/") holds what is under it.
        return pattern.hasSuffix("/") ? result + ".*" : result
    }
}

// MARK: - Where a file is

public enum KnowledgeLocation {
    /// The anchor key of the repository `path` (absolute) is in, and its
    /// path from the checkout's top: read from `.git` up the folders, as git
    /// finds it, without running git. A linked worktree's `.git` file names
    /// its git dir, whose `commondir` names the repository's.
    public static func repository(of path: String) -> (anchor: String, path: String)? {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        var folder = resolved(file.deletingLastPathComponent().path)
        var rest = [file.lastPathComponent]
        for _ in 0..<64 {
            let dotGit = folder + "/.git"
            var info = stat()
            if lstat(dotGit, &info) == 0 {
                let common: String?
                switch info.st_mode & S_IFMT {
                case S_IFDIR: common = resolved(dotGit)
                case S_IFREG: common = commonDir(ofGitFile: dotGit, in: folder)
                default: common = nil
                }
                guard let common else { return nil }
                return ("git:" + common, rest.reversed().joined(separator: "/"))
            }
            guard folder != "/", !folder.isEmpty else { return nil }
            rest.append((folder as NSString).lastPathComponent)
            folder = (folder as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// `path` inside one of the served folder anchors, and its path there.
    public static func folder(of path: String, among anchors: [String]) -> (anchor: String, path: String)? {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let full = resolved(file.deletingLastPathComponent().path) + "/" + file.lastPathComponent
        for anchor in anchors where anchor.hasPrefix("folder:") {
            let root = String(anchor.dropFirst("folder:".count))
            if full.hasPrefix(root + "/") { return (anchor, String(full.dropFirst(root.count + 1))) }
        }
        return nil
    }

    private static func commonDir(ofGitFile url: String, in folder: String) -> String? {
        guard let data = RegularFileRead.read(URL(fileURLWithPath: url), maxBytes: 4096).contents,
              let text = String(data: data, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:")
        else { return nil }
        let named = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let gitDir = resolved(named.hasPrefix("/") ? named : folder + "/" + named)
        guard let common = RegularFileRead.read(URL(fileURLWithPath: gitDir + "/commondir"), maxBytes: 4096).contents
            .flatMap({ String(data: $0, encoding: .utf8) })?.trimmingCharacters(in: .whitespacesAndNewlines), !common.isEmpty
        else { return gitDir }
        return resolved(common.hasPrefix("/") ? common : gitDir + "/" + common)
    }

    /// With symlinks resolved, as anchors keep paths.
    static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(real) }
        return String(cString: real)
    }
}

// MARK: - What a session got

/// What one agent session got of the space's bricks:
/// `sessions/<key>.json`, which the hook receiver changes under a lock.
public struct KnowledgeSession: Codable, Equatable, Sendable {
    /// Brick ids, and when each reached the session.
    public var delivered: [String: TimeInterval] = [:]
    /// Bricks waiting for the agent's next model call (agy).
    public var pending: [String] = []
    /// Bricks a correction followed.
    public var corrected: [String] = []
    public var bytes = 0

    public init() {}

    /// The file of a session: one per agent conversation and subagent.
    public static func url(in folder: URL, agent: String, session: String, subagent: String?) -> URL {
        let key = [agent, session, subagent ?? ""].joined(separator: "\n")
        let name = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name + ".json")
    }

    /// Runs `change` on the session's record with the file locked, and
    /// writes what it leaves. Nil when the file can't be had within a
    /// second: a hook never waits long.
    public static func update<T>(_ url: URL, _ change: (inout KnowledgeSession) -> T) -> T? {
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var locked = false
        for _ in 0..<100 {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
            usleep(10_000)
        }
        guard locked else { return nil }
        defer { flock(descriptor, LOCK_UN) }
        // A session still at work keeps its record past the 7-day sweep.
        futimes(descriptor, nil)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 64 * 1024 else { return nil }
        var data = Data(count: Int(info.st_size))
        let read = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, Int(info.st_size), 0) }
        guard read == Int(info.st_size) else { return nil }
        var session = (try? JSONDecoder().decode(KnowledgeSession.self, from: data)) ?? KnowledgeSession()
        let before = session
        let result = change(&session)
        guard session != before, let encoded = try? JSONEncoder().encode(session) else { return result }
        let written = encoded.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, encoded.count, 0) }
        guard written == encoded.count, ftruncate(descriptor, off_t(encoded.count)) == 0 else { return nil }
        return result
    }
}

// MARK: - Corrections

public enum KnowledgeCorrection {
    /// Words that say a fact is wrong, folded; never a plain negation, which
    /// ordinary instructions hold ("the layer is not updating, fix it").
    static let cues: Set<String> = [
        "wrong", "incorrect", "mistaken", "mistake", "untrue", "faux", "fausse", "erreur", "errone", "erronee", "inexact", "inexacte"
    ]
    static let noes: Set<String> = ["no", "non", "nope", "nah"]

    /// The bricks whose subject `prompt` names, whole words, in any case and
    /// accent, in a sentence saying it is wrong: one holding a cue word,
    /// one opening on "No," or "Non,", or one right after a sentence that is
    /// only that. Conservative by design: a missed correction costs less
    /// than knowledge taken away by a misread instruction.
    public static func named(in prompt: String, among bricks: [ServedKnowledge.Brick]) -> [String] {
        var correcting: [String] = []
        var afterNo = false
        for sentence in prompt.components(separatedBy: CharacterSet(charactersIn: ".!?;\n")) {
            let trimmed = sentence.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let words = folded(trimmed)
            let tokens = words.split(separator: " ").map(String.init)
            let opensOnNo = trimmed.range(of: #"^(no|non|nope|nah)\s*[,:—–-]"#, options: [.regularExpression, .caseInsensitive]) != nil
            if afterNo || opensOnNo || tokens.contains(where: cues.contains) { correcting.append(words) }
            afterNo = tokens.count == 1 && noes.contains(tokens[0])
        }
        return bricks.filter { brick in
            let subject = folded(brick.subject).trimmingCharacters(in: .whitespaces)
            return subject.count > 2 && correcting.contains { $0.contains(" \(subject) ") }
        }.map(\.id)
    }

    /// Lowercased, without accents, every run of other characters than
    /// letters and digits one space, with a space at each end.
    static func folded(_ text: String) -> String {
        let plain = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let words = plain.unicodeScalars.split { !CharacterSet.alphanumerics.contains($0) }.map { String(String.UnicodeScalarView($0)) }
        return " " + words.joined(separator: " ") + " "
    }
}
