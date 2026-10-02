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

    /// Whether `query` names `title` the way people type a name: it starts
    /// one of its words ("term", "new t" for "New Terminal", "quick" for
    /// "feat/quick-switcher") or spells initials of its words ("nt"). A
    /// looser match ("notes" scattered across "Clean Up Merged Worktrees")
    /// doesn't.
    static func namesTitle(query: String, title: String) -> Bool {
        let query = Array(query.lowercased())
        let title = Array(title.lowercased())
        guard !query.isEmpty else { return false }
        let wordStarts = title.indices.filter { $0 == 0 || wordSeparators.contains(title[$0 - 1]) }
        if wordStarts.contains(where: { title[$0...].starts(with: query) }) { return true }
        var next = query.startIndex
        for start in wordStarts where next < query.endIndex && title[start] == query[next] {
            next += 1
        }
        return next == query.endIndex
    }

    /// FuzzyMatch's word boundaries.
    private static let wordSeparators: Set<Character> = [" ", "-", "_", "/", ".", "("]

    /// The rows each section lists for `query`, and the order the sections
    /// show in.
    ///
    /// Rows: those whose title `query` names first (typing a workspace's
    /// name opens it, an inactive one too), then the rows that don't sink
    /// before those that do, then the best match; equal ones in the order
    /// given.
    ///
    /// Sections are judged by the row they show first. Those whose first
    /// row's title `query` names come first, in the order given: typing a
    /// command's name, or its initials, never puts a workspace above it.
    /// The others follow, best first row first. A section with no match is
    /// left out.
    ///
    /// An empty query lists every row in the order given, sinking ones
    /// last, and every non-empty section in the order given.
    static func rank(query: String, sections: [[Candidate]]) -> [RankedSection] {
        let ranked = sections.enumerated().compactMap { index, candidates -> (section: RankedSection, named: Bool, best: Int)? in
            let matches = candidates.enumerated().compactMap { row, candidate -> Match? in
                if query.isEmpty { return Match(row: row, score: 0, named: false, sinks: candidate.sinks) }
                return score(query: query, candidate: candidate).map {
                    Match(row: row, score: $0, named: namesTitle(query: query, title: candidate.title), sinks: candidate.sinks)
                }
            }
            let rows = matches.sorted(by: Match.precedes)
            guard let first = rows.first else { return nil }
            return (RankedSection(section: index, rows: rows.map(\.row)), first.named, first.score)
        }
        return ranked
            .sorted { lhs, rhs in
                if lhs.named != rhs.named { return lhs.named }
                if !lhs.named, lhs.best != rhs.best { return lhs.best > rhs.best }
                return lhs.section.section < rhs.section.section
            }
            .map(\.section)
    }

    private struct Match {
        let row: Int
        let score: Int
        let named: Bool
        let sinks: Bool

        static func precedes(_ lhs: Match, _ rhs: Match) -> Bool {
            if lhs.named != rhs.named { return lhs.named }
            if lhs.sinks != rhs.sinks { return !lhs.sinks }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.row < rhs.row
        }
    }
}
