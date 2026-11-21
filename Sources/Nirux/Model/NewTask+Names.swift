import Foundation

// MARK: - Names

/// A task's branch and title, when nobody gives them (start_task's `title`
/// and `branch`, the branch field of ⌘N), come from its description's first
/// line: a branch or a short name its writer put there, else its words.
extension NewTask {
    /// Longest slug a suggested branch gets after its type.
    static let maxSlugLength = 32
    static let maxTitleLength = 50

    /// The branch types a first line may give: `fix: …`, `docs(readme): …`,
    /// or a leading `docs/readme — …`.
    static let branchTypes: Set<String> = ["feat", "fix", "docs", "refactor", "chore", "test", "ci", "perf"]

    /// First words that make the branch a `fix/` one, left out of the slug:
    /// `fix/crash-on-launch`, not `fix/fix-crash-on-launch`.
    static let fixVerbs: Set<String> = ["fix", "fixes", "fixed", "bugfix", "hotfix", "corrige", "corriger"]
    /// First words that make it a `fix/` one too, but say what is broken:
    /// they stay in the slug (`fix/crash-on-launch`).
    static let bugWords: Set<String> = ["bug", "crash", "repair", "regression", "correction", "repare", "reparer", "flaky", "broken"]

    /// Words no slug keeps, in English and French: articles, pronouns,
    /// possessives, "is" and "and". Prepositions and negations stay ("crash
    /// on launch"); "can't" is one word by then (see `slugWords`).
    static let slugStopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "then", "than", "that", "this", "these", "those", "which", "who",
        "its", "it", "is", "are", "was", "were", "be", "been", "i", "me", "my", "we", "our", "you", "your", "he",
        "she", "they", "them", "their", "le", "la", "les", "l", "un", "une", "des", "de", "du", "d", "au", "aux",
        "et", "ou", "que", "qu", "qui", "ce", "ces", "cet", "cette", "c", "notre", "nos", "votre", "vos", "son",
        "sa", "ses", "leur", "leurs", "mon", "ma", "mes", "y", "je", "j", "tu", "il", "elle", "nous", "vous",
        "ils", "elles", "se", "s", "si", "est", "sont", "trucs", "truc"
    ]

    /// What a line may open with before it says the task: a request to the
    /// agent ("can you", "je veux que tu"), lowercase, straight apostrophes.
    static let requestPhrases = [
        "please", "can you", "could you", "would you", "i want you to", "i'd like you to", "i would like you to",
        "i need you to", "we need to", "we should", "let's", "lets", "je veux que tu", "je voudrais que tu",
        "j'aimerais que tu", "je veux qu'on", "j'aimerais qu'on", "tu peux", "tu pourrais", "peux-tu", "pourrais-tu",
        "est-ce que tu peux", "est-ce qu'on peut", "est-ce qu'on pourrait", "on peut", "il faudrait", "il faut",
        "merci de", "stp"
    ].map { $0.split(separator: " ").map(String.init) }

    /// The title and branch start_task gave; nil ones come from the
    /// description (the branch from the title, when there is one).
    struct Naming: Equatable, Sendable {
        var title: String?
        var branch: String?
    }

    /// A first line, read for the task's name.
    struct NameLine: Equatable {
        /// The branch the line asks for: a "(branch feat/x)" note, or a
        /// leading `feat/x — …` whose type is one of `branchTypes`.
        var branch: String?
        /// The type a leading `fix: …` or `fix/x — …` gives.
        var type: String?
        /// The writer's own short name, from a leading `area/name — …` of
        /// another kind (`daily-pass/forgotten — …`): the slug's words.
        var shortName: String?
        /// The title: what is left once the short name, the branch note, an
        /// opening request and links (their host stands in) are out.
        var text: String
    }

    static func nameLine(_ line: String) -> NameLine {
        var name = NameLine(text: line)
        let note = line.firstMatch(of: #/\s*\(\s*branch:?\s+`?([A-Za-z0-9._-]+/[A-Za-z0-9._/-]+)`?\s*\)/#.ignoresCase())
            ?? line.firstMatch(of: #/\s+[—–-]\s+branch:?\s+`?([A-Za-z0-9._-]+/[A-Za-z0-9._/-]+)`?\s*$/#.ignoresCase())
        if let note, BoardConfig.isValidBranchName(String(note.1)) {
            name.branch = String(note.1)
            name.text.removeSubrange(note.range)
        }
        if let lead = name.text.wholeMatch(of: #/([a-z0-9][a-z0-9._-]*)/([a-z0-9][a-z0-9._/-]*)(?:\s+[—–-]|\s*[—–:])\s+(\S.*)/#) {
            let area = String(lead.1), branch = "\(lead.1)/\(lead.2)"
            if branchTypes.contains(area) {
                name.type = area
                if name.branch == nil, BoardConfig.isValidBranchName(branch) { name.branch = branch }
            } else {
                name.shortName = branch
            }
            name.text = String(lead.3)
        } else if let typed = name.text.wholeMatch(of: #/(feat|fix|docs|refactor|chore|test|ci|perf)(?:\([^)]*\))?!?:\s+(\S.*)/#.ignoresCase()) {
            name.type = typed.1.lowercased()
            name.text = String(typed.2)
        }
        name.text = withoutRequest(withLinksAsHosts(name.text))
        return name
    }

    /// The branch a task gets from its description's first line: the one the
    /// line asks for (see `NameLine`), else `<type>/<slug>`. The slug is the
    /// line's words in ASCII lowercase, stop words and repeats left out,
    /// joined by `-`, cut at a word before `maxSlugLength`. The type is the
    /// line's, else `fix` for a template that speaks of a bug or a fix, else
    /// the first word's (see `firstWordType`), else `feat`. Empty when the
    /// line has no letter or digit to use. Always a valid branch name
    /// otherwise.
    static func suggestedBranch(description: String, templateName: String?) -> String {
        let line = nameLine(firstLine(of: description) ?? "")
        if let branch = line.branch { return branch }
        var words = slugWords(line.shortName ?? line.text)
        guard let first = words.first else { return "" }
        let template = templateName?.lowercased() ?? ""
        let firstType = firstWordType(first)
        let type = line.type ?? (template.contains("bug") || template.contains("fix") ? "fix" : nil) ?? firstType?.type ?? "feat"
        if words.count > 1, first == type || (firstType?.type == type && firstType?.isDropped == true) {
            words.removeFirst()
        }
        var seen = Set<String>()
        let kept = words.filter { !slugStopWords.contains($0) && seen.insert($0).inserted }
        let chosen = kept.isEmpty ? [words[0]] : kept
        var slug = ""
        for word in chosen {
            let candidate = slug.isEmpty ? word : slug + "-" + word
            guard candidate.count <= maxSlugLength else { break }
            slug = candidate
        }
        if slug.isEmpty { slug = String(chosen[0].prefix(maxSlugLength)) }
        return type + "/" + slug
    }

    /// The type a first word gives, and whether the slug leaves the word out
    /// (a verb its type says already) or keeps it (what is broken).
    static func firstWordType(_ word: String) -> (type: String, isDropped: Bool)? {
        if fixVerbs.contains(word) { return ("fix", true) }
        if bugWords.contains(word) { return ("fix", false) }
        if ["docs", "doc", "documentation"].contains(word) { return ("docs", true) }
        if word == "readme" { return ("docs", false) }
        if ["refactor", "refactoring"].contains(word) { return ("refactor", true) }
        return nil
    }

    /// The workspace's name: the description's first line as `NameLine`
    /// reads it, cut before `maxTitleLength`. Nil for a blank description.
    static func workspaceTitle(description: String) -> String? {
        firstLine(of: description).map { cut(titleText(of: $0), at: maxTitleLength) }
    }

    /// A line's title text (`NameLine.text`), or the line itself, its
    /// whitespace folded, when nothing else is left.
    static func titleText(of line: String) -> String {
        let text = nameLine(line).text
        return text.isEmpty ? line.split(whereSeparator: \.isWhitespace).joined(separator: " ") : text
    }

    /// A workspace opened on an existing branch: the branch's words, past a
    /// `feat/` that says nothing ("feat/dark-mode" → "Dark mode", "fix/x-y"
    /// → "Fix x y"). The branch itself when it has no type.
    static func branchTitle(_ branch: String) -> String {
        guard let slash = branch.firstIndex(of: "/"), branchTypes.contains(String(branch[..<slash])) else { return branch }
        let type = branch[..<slash]
        let words = branch[branch.index(after: slash)...].split { $0 == "-" || $0 == "/" }.joined(separator: " ")
        guard !words.isEmpty else { return branch }
        let title = type == "feat" ? words : type + " " + words
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    /// `text` up to `limit` characters, "…" ending a cut one, at a word
    /// when one ends past half the limit.
    static func cut(_ text: String, at limit: Int) -> String {
        guard text.count > limit else { return text }
        var head = String(text.prefix(limit - 1))
        let endsAWord = text[text.index(text.startIndex, offsetBy: limit - 1)] == " "
        if !endsAWord, let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > limit / 2 {
            head = String(head[..<space])
        }
        return head.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:—–-")) + "…"
    }

    /// A plain workspace's name: its folder's, `~` for the home folder. Not
    /// its branch, which would name every shell in a main checkout "main".
    static func folderTitle(_ path: String, home: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized != URL(fileURLWithPath: home).standardizedFileURL.path else { return "~" }
        let name = URL(fileURLWithPath: standardized).lastPathComponent
        return name.isEmpty ? standardized : name
    }

    /// The first line holding more than whitespace, trimmed.
    static func firstLine(of text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// Letters and digits in ASCII lowercase (accents dropped, other scripts
    /// transliterated), split at everything else; "can't" as "cant", "the
    /// Lead's" as "the lead".
    private static func slugWords(_ text: String) -> [String] {
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        let ascii = (latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin).lowercased()
            .replacing(#/n['’]t\b/#, with: "nt")
            .replacing(#/['’]s\b/#, with: "")
        return ascii.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
    }

    /// Links replaced by their host: "youtube.com", not the words of a URL.
    private static func withLinksAsHosts(_ text: String) -> String {
        text.replacing(#/https?://\S+/#.ignoresCase()) { link in
            let host = URL(string: String(link.output))?.host() ?? ""
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
    }

    /// Whitespace folded, and an opening request to the agent left out, the
    /// next word capitalized then. A line that is only a request keeps it.
    private static func withoutRequest(_ text: String) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var removedAny = false
        while let phrase = requestPhrases.first(where: { phrase in
            let plain = words.prefix(phrase.count).map {
                $0.lowercased().replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: CharacterSet(charactersIn: ",:;"))
            }
            return plain == phrase && words.dropFirst(phrase.count).contains { $0.contains { $0.isLetter || $0.isNumber } }
        }) {
            words.removeFirst(phrase.count)
            removedAny = true
        }
        if removedAny, let first = words.first { words[0] = first.prefix(1).uppercased() + first.dropFirst() }
        return words.joined(separator: " ")
    }
}
