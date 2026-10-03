import Foundation

/// How ⌘P orders what it lists: the commands, then the other sections
/// (workspaces; past sessions can join), each row searched with
/// `FuzzyMatch`.
enum PaletteRanking {
    /// What a row is searched on.
    struct Candidate: Equatable {
        let title: String
        /// Searched with less weight than the title: a command's subtitle;
        /// a workspace's branch, space and folder.
        let keys: [String]
        /// Listed after the rows that don't sink and match as well: an
        /// inactive workspace.
        var sinks = false
    }

    /// A section as the palette lists it: its index in the sections given,
    /// and the indices of its rows, in display order.
    struct RankedSection: Equatable {
        let section: Int
        let rows: [Int]
    }

    /// What a title match gets over a match on another key.
    static let titleBonus = 25

    /// How well `candidate` matches `query`: its best key, nil when none
    /// matches.
    static func score(query: String, candidate: Candidate) -> Int? {
        let title = FuzzyMatch.score(query: query, candidate: candidate.title).map { $0 + titleBonus }
        let keys = candidate.keys.map { FuzzyMatch.score(query: query, candidate: $0) }
        return ([title] + keys).compactMap { $0 }.max()
    }

    /// How `query` names a title, the way people type a name.
    enum Naming {
        case none
        /// It spells the initials of consecutive words ("nt" for "New
        /// Terminal", "cw" for "Cycle Width").
        case initials
        /// It starts one of the title's words ("term", "new t" for "New
        /// Terminal"; "quick" for "feat/quick-switcher").
        case wordStart
        /// It is the title.
        case exact
    }

    static func naming(query: String, title: String) -> Naming {
        let query = Array(query.lowercased())
        let title = Array(title.lowercased())
        guard !query.isEmpty else { return .none }
        if title == query { return .exact }
        let wordStarts = title.indices.filter { $0 == 0 || FuzzyMatch.wordSeparators.contains(title[$0 - 1]) }
        if wordStarts.contains(where: { title[$0...].starts(with: query) }) { return .wordStart }
        let initials = wordStarts.map { title[$0] }
        guard query.count <= initials.count else { return .none }
        let spelled = (0...(initials.count - query.count)).contains { Array(initials[$0..<$0 + query.count]) == query }
        return spelled ? .initials : .none
    }

    /// The rows each section lists for `query`, and the order the sections
    /// show in.
    ///
    /// Rows: a title the query is first, then those it starts a word of
    /// (typing a workspace's name opens it, an inactive one too); then the
    /// rows that don't sink before those that do; then the best match.
    /// Equal ones keep the order given.
    ///
    /// Sections are judged by the row they show first, where Return goes.
    /// One whose first row's title the query is leads; then those whose
    /// first row's title it names (a word start or initials), in the order
    /// given: typing a command's name or initials ("editor", "nt") never
    /// puts a workspace above it, unless that workspace bears that very
    /// name. The others follow, best first row first. A section with no
    /// match is left out.
    ///
    /// An empty query lists every row in the order given, sinking ones
    /// last, and every non-empty section in the order given.
    static func rank(query: String, sections: [[Candidate]]) -> [RankedSection] {
        let ranked = sections.enumerated().compactMap { index, candidates -> (section: RankedSection, first: Match)? in
            let matches = candidates.enumerated().compactMap { row, candidate -> Match? in
                if query.isEmpty { return Match(row: row, score: 0, naming: .none, sinks: candidate.sinks) }
                return score(query: query, candidate: candidate).map {
                    Match(row: row, score: $0, naming: naming(query: query, title: candidate.title), sinks: candidate.sinks)
                }
            }
            let rows = matches.sorted(by: Match.precedes)
            guard let first = rows.first else { return nil }
            return (RankedSection(section: index, rows: rows.map(\.row)), first)
        }
        return ranked
            .sorted { lhs, rhs in
                if lhs.first.sectionRank != rhs.first.sectionRank { return lhs.first.sectionRank > rhs.first.sectionRank }
                if lhs.first.sectionRank == 0, lhs.first.score != rhs.first.score { return lhs.first.score > rhs.first.score }
                return lhs.section.section < rhs.section.section
            }
            .map(\.section)
    }

    private struct Match {
        let row: Int
        let score: Int
        let naming: Naming
        let sinks: Bool

        /// Within a section: the title typed, then a word of it, outrank
        /// sinking. Initials don't: "api" spelled by an inactive
        /// "feat/add-payment-integration" is a guess.
        var rowRank: Int {
            switch naming {
            case .exact: return 2
            case .wordStart: return 1
            case .initials, .none: return 0
            }
        }

        /// Between sections, judged by the first row: initials count as a
        /// name there, so "nt" keeps New Terminal on top.
        var sectionRank: Int {
            switch naming {
            case .exact: return 2
            case .wordStart, .initials: return 1
            case .none: return 0
            }
        }

        static func precedes(_ lhs: Match, _ rhs: Match) -> Bool {
            if lhs.rowRank != rhs.rowRank { return lhs.rowRank > rhs.rowRank }
            if lhs.sinks != rhs.sinks { return !lhs.sinks }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.row < rhs.row
        }
    }
}
