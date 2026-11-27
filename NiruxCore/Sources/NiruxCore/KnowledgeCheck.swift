import Foundation

/// What a check reads, at the base branch's tip for a repository, on disk
/// for a folder: the app gives git's answers, tests give their own.
public struct KnowledgeSource: Sendable {
    public enum Read: Equatable, Sendable {
        case missing
        case data(Data)
        /// Couldn't be read now (git failed, the network): nothing is decided.
        case unknown(String)
    }

    /// The commit checked; nil for a folder.
    public var tip: String?
    public var file: @Sendable (String) -> Read
    /// Whether the base branch holds the pull request's merge; nil: unknown.
    public var hasPullRequest: @Sendable (Int) -> Bool?
    public var hasCommit: @Sendable (String) -> Bool?
    /// Nil when pages aren't read this time: only the daily check reads them.
    public var page: (@Sendable (String) -> Read)?

    public init(
        tip: String?, file: @escaping @Sendable (String) -> Read, hasPullRequest: @escaping @Sendable (Int) -> Bool?,
        hasCommit: @escaping @Sendable (String) -> Bool?, page: (@Sendable (String) -> Read)?
    ) {
        self.tip = tip
        self.file = file
        self.hasPullRequest = hasPullRequest
        self.hasCommit = hasCommit
        self.page = page
    }
}

public enum ProofCheck: Equatable, Sendable {
    case holds
    case fails(String)
    case unknown(String)
    /// Not read this time (a page between daily checks).
    case skipped
}

extension Proof {
    public func check(in source: KnowledgeSource) -> ProofCheck {
        let base = source.tip.map { "the base branch at \($0.prefix(7))" } ?? "the folder"
        func reading(_ path: String, _ test: (String) -> ProofCheck) -> ProofCheck {
            switch source.file(path) {
            case .missing: return .fails("\(path) is gone from \(base).")
            case .unknown(let why): return .unknown(why)
            case .data(let data): return test(KnowledgeText.normalized(String(decoding: data, as: UTF8.self)))
            }
        }
        switch self {
        case .pullRequest(let number):
            switch source.hasPullRequest(number) {
            case true?: return .holds
            case false?: return .fails("\(base.prefix(1).uppercased() + base.dropFirst()) doesn’t hold PR #\(number).")
            case nil: return .unknown("Couldn’t read the history for PR #\(number).")
            }
        case .commit(let sha):
            switch source.hasCommit(sha) {
            case true?: return .holds
            case false?: return .fails("\(base.prefix(1).uppercased() + base.dropFirst()) doesn’t hold commit \(sha.prefix(7)).")
            case nil: return .unknown("Couldn’t read the history for commit \(sha.prefix(7)).")
            }
        case .file(let path):
            return reading(path) { _ in .holds }
        case .text(let path, let text):
            let words = KnowledgeText.normalized(text)
            return reading(path) { $0.contains(words) ? .holds : .fails("\(path) no longer says “\(Proof.clipped(text, 60))”.") }
        case .test(let path, let name):
            return reading(path) { content in
                ["func", "def", "fn", "function"].contains { content.contains("\($0) \(name)(") }
                    ? .holds : .fails("\(path) no longer has the test \(name).")
            }
        case .page(let url, let quote):
            guard let page = source.page else { return .skipped }
            switch page(url) {
            case .missing: return .fails("\(url) is gone.")
            case .unknown(let why): return .unknown(why)
            case .data(let data):
                let words = KnowledgeText.normalized(quote)
                return KnowledgeText.normalized(KnowledgeText.pageText(String(decoding: data, as: UTF8.self))).contains(words)
                    ? .holds : .fails("\(url) no longer says “\(Proof.clipped(quote, 60))”.")
            }
        case .said:
            return .holds
        }
    }
}

extension KnowledgeBrick {
    /// Its proofs' checks, in order; the first failure closes it.
    public func check(in source: KnowledgeSource) -> [ProofCheck] {
        proofs.map { $0.check(in: source) }
    }
}

extension KnowledgeStore.Loaded {
    /// Records the checks of `results` (brick id → its proofs' checks) at
    /// `tip`: a brick a proof fails for is failing, and closes, with why, if
    /// it was failing already; one whose checks all held is checked at
    /// `tip`, no longer failing. Returns the ids it closed.
    @discardableResult
    public mutating func record(_ results: [String: [ProofCheck]], tip: String?, now: TimeInterval) -> [String] {
        var closed: [String] = []
        for (id, checks) in results.sorted(by: { $0.key < $1.key }) where bricks[id] != nil {
            var brick = state(of: id)
            guard brick.closedAt == nil else { continue }
            if let failure = checks.lazy.compactMap({ check -> String? in
                if case .fails(let why) = check { return why }
                return nil
            }).first {
                if brick.failedAt == nil {
                    brick.failedAt = now
                    brick.failedBecause = failure
                } else {
                    brick.closedAt = now
                    brick.closedBecause = failure
                    closed.append(id)
                }
            } else if !checks.contains(where: { if case .unknown = $0 { return true } else { return false } }) {
                brick.checkedAt = now
                brick.checkedTip = tip
                brick.failedAt = nil
                brick.failedBecause = nil
            }
            state.bricks[id] = brick
        }
        return closed
    }
}

// MARK: - Text

public enum KnowledgeText {
    /// What a proof's words are compared on: each line without its indent
    /// and leading comment marks, the lines joined, every run of white
    /// space one space, typographic quotes plain.
    public static func normalized(_ text: String) -> String {
        let marks = ["///", "//", "/*", "*/", "*", "#", "--", ";", ">"]
        let lines = text.components(separatedBy: .newlines).map { line -> Substring in
            var rest = line.drop(while: \.isWhitespace)
            while let mark = marks.first(where: { rest.hasPrefix($0) }) {
                rest = rest.dropFirst(mark.count).drop(while: \.isWhitespace)
            }
            return rest
        }
        var result = ""
        var lastWasSpace = true
        for character in lines.joined(separator: " ") {
            let plain: Character = switch character {
            case "\u{2018}", "\u{2019}": "'"
            case "\u{201C}", "\u{201D}": "\""
            default: character
            }
            if plain.isWhitespace {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(plain)
                lastWasSpace = false
            }
        }
        return result.hasSuffix(" ") ? String(result.dropLast()) : result
    }

    /// A page's words: without its scripts, styles and tags, its common
    /// entities read.
    public static func pageText(_ html: String) -> String {
        var text = html
        for pattern in [#"(?is)<script\b.*?</script>"#, #"(?is)<style\b.*?</style>"#, #"(?s)<!--.*?-->"#, #"(?s)<[^>]*>"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // `&amp;` last: `&amp;lt;` means the text "&lt;".
        let entities = [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&rsquo;", "'"), ("&lsquo;", "'"),
                        ("&ldquo;", "\""), ("&rdquo;", "\""), ("&amp;", "&")]
        for (entity, plain) in entities { text = text.replacingOccurrences(of: entity, with: plain) }
        return text
    }
}
