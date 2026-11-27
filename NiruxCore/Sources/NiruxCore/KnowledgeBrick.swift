import CryptoKit
import Foundation

/// A fact of a space in one sentence, attached to proofs that a machine
/// checks again without a model (docs/design/knowledge-bricks.md). Never
/// edited: when a proof stops holding, the brick closes and a new one
/// replaces it. Its file keeps only what never changes; what does (checks,
/// closing, suspicion, use) lives in `KnowledgeState`.
public struct KnowledgeBrick: Codable, Equatable, Sendable {
    public var sentence: String
    /// A few words naming what it is about ("backing layer"): what a brick
    /// replacing it shares, and what a user's correction would name.
    public var subject: String
    public var scope: Scope
    public var proofs: [Proof]
    /// The macOS major version it was validated on, for a fact macOS may
    /// change: on another major it expires until someone reconfirms it.
    public var macOS: Int?
    /// The brick it replaces.
    public var replaces: String?
    /// Who proposed it, as shown ("the Lead").
    public var proposedBy: String?
    /// When the user validated it; nil while it is only proposed.
    public var validatedAt: TimeInterval?

    public init(
        sentence: String, subject: String, scope: Scope, proofs: [Proof], macOS: Int? = nil, replaces: String? = nil,
        proposedBy: String? = nil, validatedAt: TimeInterval? = nil
    ) {
        self.sentence = sentence
        self.subject = subject
        self.scope = scope
        self.proofs = proofs
        self.macOS = macOS
        self.replaces = replaces
        self.proposedBy = proposedBy
        self.validatedAt = validatedAt
    }

    /// What the files of a repository or folder it concerns.
    public struct Scope: Codable, Equatable, Sendable {
        /// The space anchor's key: `git:<common git dir>` or `folder:<path>`.
        public var anchor: String
        /// The repository's or folder's name, as shown.
        public var name: String
        /// Relative to the checkout's top or the folder: a file, a folder
        /// (its files), or a pattern with `*`, `**` and `?`.
        public var paths: [String]

        public init(anchor: String, name: String, paths: [String]) {
            self.anchor = anchor
            self.name = name
            self.paths = paths
        }
    }

    /// The content a brick is known by: the same fact on the same proofs is
    /// the same brick, whoever proposed it and whenever.
    public var id: String {
        struct Content: Encodable {
            let sentence: String, subject: String, scope: Scope, proofs: [Proof], macOS: Int?, replaces: String?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(Content(
            sentence: sentence, subject: subject, scope: scope, proofs: proofs, macOS: macOS, replaces: replaces
        ))) ?? Data()
        return "b-" + SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether some proof is checked again: without one, the brick expires.
    public var isRechecked: Bool { proofs.contains(where: \.isRechecked) }
}

// MARK: - Proofs

/// Something outside the base that shows the fact, and how a machine sees
/// it still holds. Only declarative checks: nothing a brick carries runs.
public enum Proof: Equatable, Sendable {
    /// A pull request merged into the base branch.
    case pullRequest(Int)
    /// A commit on the base branch.
    case commit(String)
    /// A file at the base branch's tip.
    case file(path: String)
    /// Words a file holds at the base branch's tip, line breaks and comment
    /// marks aside.
    case text(path: String, text: String)
    /// A committed test, by its function's name.
    case test(path: String, name: String)
    /// Words a web page shows.
    case page(url: String, quote: String)
    /// What the user said, on a day (YYYY-MM-DD).
    case said(quote: String, day: String)

    /// Checked again at each merge, or each day for a page. The others prove
    /// the fact was true, not that it still is.
    public var isRechecked: Bool {
        switch self {
        case .file, .text, .test, .page: return true
        case .pullRequest, .commit, .said: return false
        }
    }

    /// As a brick's card names it.
    public var label: String {
        switch self {
        case .pullRequest(let number): return "PR #\(number)"
        case .commit(let sha): return "commit \(sha.prefix(7))"
        case .file(let path): return path
        case .text(let path, let text): return "“\(Self.clipped(text, 40))” in \((path as NSString).lastPathComponent)"
        case .test(let path, let name): return "test \(name) in \((path as NSString).lastPathComponent)"
        case .page(let url, _): return "page " + (URL(string: url)?.host ?? url)
        case .said(_, let day): return "you, \(day)"
        }
    }

    static func clipped(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}

extension Proof: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, number, sha, path, text, name, url, quote, day
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) throws -> String { try container.decode(String.self, forKey: key) }
        switch try string(.kind) {
        case "pullRequest": self = .pullRequest(try container.decode(Int.self, forKey: .number))
        case "commit": self = .commit(try string(.sha))
        case "file": self = .file(path: try string(.path))
        case "text": self = .text(path: try string(.path), text: try string(.text))
        case "test": self = .test(path: try string(.path), name: try string(.name))
        case "page": self = .page(url: try string(.url), quote: try string(.quote))
        case "said": self = .said(quote: try string(.quote), day: try string(.day))
        case let kind: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown proof \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pullRequest(let number):
            try container.encode("pullRequest", forKey: .kind)
            try container.encode(number, forKey: .number)
        case .commit(let sha):
            try container.encode("commit", forKey: .kind)
            try container.encode(sha, forKey: .sha)
        case .file(let path):
            try container.encode("file", forKey: .kind)
            try container.encode(path, forKey: .path)
        case .text(let path, let text):
            try container.encode("text", forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(text, forKey: .text)
        case .test(let path, let name):
            try container.encode("test", forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(name, forKey: .name)
        case .page(let url, let quote):
            try container.encode("page", forKey: .kind)
            try container.encode(url, forKey: .url)
            try container.encode(quote, forKey: .quote)
        case .said(let quote, let day):
            try container.encode("said", forKey: .kind)
            try container.encode(quote, forKey: .quote)
            try container.encode(day, forKey: .day)
        }
    }
}

// MARK: - What a brick may hold

extension KnowledgeBrick {
    public static let maxSentenceLength = 300
    public static let maxSubjectLength = 60
    public static let maxPaths = 10
    public static let maxProofs = 6
    public static let maxQuoteLength = 300

    /// Why it can't be a brick, or nil: one sentence, a subject, the files
    /// it concerns, at least one proof, each well formed.
    public var problem: String? {
        if let problem = Self.lineProblem(sentence, name: "sentence", range: 10...Self.maxSentenceLength) { return problem }
        if sentence.range(of: #"[.!?;]\s+\p{Lu}"#, options: .regularExpression) != nil {
            return "sentence must be one sentence: put another fact in a brick of its own."
        }
        if let problem = Self.lineProblem(subject, name: "subject", range: 2...Self.maxSubjectLength) { return problem }
        guard (1...Self.maxPaths).contains(scope.paths.count) else { return "paths must name 1 to \(Self.maxPaths) files or folders." }
        if let path = scope.paths.first(where: { !Self.isRelativePath($0) }) {
            return "“\(path)” must be a path relative to the repository’s top, without “..”."
        }
        guard (1...Self.maxProofs).contains(proofs.count) else { return "A brick needs 1 to \(Self.maxProofs) proofs." }
        for proof in proofs {
            if let problem = Self.problem(of: proof) { return problem }
        }
        return nil
    }

    static func problem(of proof: Proof) -> String? {
        switch proof {
        case .pullRequest(let number):
            return number > 0 ? nil : "A pull request proof needs its number."
        case .commit(let sha):
            return sha.range(of: "^[0-9a-f]{7,40}$", options: .regularExpression) != nil ? nil : "A commit proof needs a hex SHA."
        case .file(let path):
            return isRelativePath(path) ? nil : "“\(path)” must be a path relative to the repository’s top."
        case .text(let path, let text):
            return isRelativePath(path) ? lineProblem(text, name: "A file proof’s text", range: 3...maxQuoteLength)
                : "“\(path)” must be a path relative to the repository’s top."
        case .test(let path, let name):
            guard isRelativePath(path) else { return "“\(path)” must be a path relative to the repository’s top." }
            return name.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,120}$"#, options: .regularExpression) != nil
                ? nil : "A test proof needs the test function’s name."
        case .page(let url, let quote):
            guard let parsed = URL(string: url), parsed.scheme == "https", parsed.host?.isEmpty == false else {
                return "A page proof needs an https URL."
            }
            return lineProblem(quote, name: "A page proof’s quote", range: 10...maxQuoteLength)
        case .said(let quote, let day):
            guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
                return "A said proof needs its day as YYYY-MM-DD."
            }
            return lineProblem(quote, name: "A said proof’s quote", range: 3...maxQuoteLength)
        }
    }

    private static func lineProblem(_ text: String, name: String, range: ClosedRange<Int>) -> String? {
        guard range.contains(text.count), !text.contains(where: \.isNewline),
              text.trimmingCharacters(in: .whitespaces) == text
        else { return "\(name) must be one line of \(range.lowerBound) to \(range.upperBound) characters." }
        return nil
    }

    static func isRelativePath(_ path: String) -> Bool {
        !path.isEmpty && path.count <= 200 && !path.hasPrefix("/") && !path.contains("\0")
            && !path.split(separator: "/").contains("..") && !path.contains(where: \.isNewline)
    }
}
