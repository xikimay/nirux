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
        /// Listed after the rows that don't sink, whatever its score: an
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

    /// The rows each section lists for `query` and the order the sections
    /// show in. Rows: best match first, sinking ones after the others,
    /// equal scores in the order given. Sections: the one holding the best
    /// match first — typing a workspace's name puts it on top, where Return
    /// opens it — equal ones in the order given; a section with no match is
    /// left out. An empty query lists every row in the order given, sinking
    /// ones last, and every non-empty section in the order given.
    static func rank(query: String, sections: [[Candidate]]) -> [RankedSection] {
        let scored = sections.enumerated().map { index, candidates in
            let matches = candidates.enumerated().compactMap { row, candidate -> (row: Int, score: Int, sinks: Bool)? in
                if query.isEmpty { return (row, 0, candidate.sinks) }
                return score(query: query, candidate: candidate).map { (row, $0, candidate.sinks) }
            }
            let rows = matches.sorted { lhs, rhs in
                if lhs.sinks != rhs.sinks { return !lhs.sinks }
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.row < rhs.row
            }
            return (section: index, rows: rows.map(\.row), best: matches.map(\.score).max())
        }
        return scored
            .filter { !$0.rows.isEmpty }
            .sorted { lhs, rhs in
                lhs.best != rhs.best ? (lhs.best ?? 0) > (rhs.best ?? 0) : lhs.section < rhs.section
            }
            .map { RankedSection(section: $0.section, rows: $0.rows) }
    }
}
