import Foundation

// MARK: - Where a comment is (section 6.1)

extension BranchReview {
    enum CommentPlacement: Equatable, Sendable {
        /// Its file is in the diff, and so are its rows: where they were,
        /// or where they moved to (`anchor` is where they are now).
        case placed(CommentAnchor)
        /// Its file is in the diff, its rows aren't, or not so that Nirux
        /// can tell where: it keeps its excerpt.
        case outdated
        /// Its file no longer differs from the base.
        case fileGone
        /// Its file's hunks aren't read yet (`FileChange.omission`): it is
        /// placed once they are, when the file's row opens.
        case unread
        /// Its file's diff is too large to show: its rows can't be.
        case tooLarge
    }

    /// The file a comment made at `anchor`, and last found at `moved`, is
    /// about in `files`: by the path it was last found at, then by the one
    /// it was made at, each as a path or as a renamed file's old path.
    static func file(for anchor: CommentAnchor, moved: CommentAnchor?, in files: [FileChange]) -> FileChange? {
        for path in [(moved ?? anchor).path, anchor.path] {
            if let file = files.first(where: { $0.path == path }) ?? files.first(where: { $0.oldPath == path }) { return file }
        }
        return nil
    }

    /// Where a comment made at `anchor`, and last found at `moved`, is in
    /// `file`'s diff (nil when the file no longer differs from the base;
    /// see `file(for:moved:in:)`). Looked for from both: when they find
    /// different places, the better evidence wins, and as good leaves it
    /// outdated. A comment on a file stays as long as its file. `rows`
    /// are the file's `diffRows`, when made before.
    static func place(
        _ anchor: CommentAnchor, moved: CommentAnchor? = nil, in file: FileChange?, rows: [[DiffRow]]? = nil
    ) -> CommentPlacement {
        guard let file else { return .fileGone }
        if anchor.isFile { return .placed(.file(file.path)) }
        switch file.omission {
        case .tooLarge?: return .tooLarge
        case .onDemand?, .notRead?: return .unread
        case nil: break
        }
        let rows = rows ?? diffRows(of: file.hunks)
        let fromMade = search(anchor, in: rows, path: file.path)
        let fromMoved = moved.flatMap { search($0, in: rows, path: file.path) }
        switch (fromMade, fromMoved) {
        case let (made?, moved?):
            guard made.anchor != moved.anchor else { return .placed(made.anchor) }
            guard made.score != moved.score else { return .outdated }
            return .placed(made.score > moved.score ? made.anchor : moved.anchor)
        case let (found?, nil), let (nil, found?):
            return .placed(found.anchor)
        case (nil, nil):
            return .outdated
        }
    }

    /// Where `anchor`'s rows are in `hunks` (rows as `diffRows` makes
    /// them); nil when they aren't, or not so that it can tell.
    static func place(_ anchor: CommentAnchor, inRows hunks: [[DiffRow]], path: String) -> CommentAnchor? {
        search(anchor, in: hunks, path: path)?.anchor
    }

    /// Each run of rows that reads as `anchor`'s, within one hunk.
    static func runs(of anchor: CommentAnchor, in hunks: [[DiffRow]]) -> [(hunk: Int, range: ClosedRange<Int>)] {
        guard let first = anchor.rows.first else { return [] }
        let count = anchor.rows.count
        var runs: [(hunk: Int, range: ClosedRange<Int>)] = []
        for (index, rows) in hunks.enumerated() where rows.count >= count {
            for start in 0...(rows.count - count) where rows[start].reads(as: first) {
                let range = start...(start + count - 1)
                if anchor.rows.elementsEqual(rows[range], by: { $0.reads(as: $1) }) { runs.append((index, range)) }
            }
        }
        return runs
    }

    /// The run that reads as `anchor`'s rows and is the same place. A
    /// comment under the wrong line is worse than an outdated one, so a
    /// run counts only with evidence, and when no other is as likely:
    /// - copied code (`copy`) is found by its rank among the runs that
    ///   read as its rows, as long as their number is the same;
    /// - rows rewritten where they were (the nearest context rows that
    ///   hold a letter or a digit, above and below, still stand around
    ///   rows that don't read as them) are outdated;
    /// - a context row is evidence only when it holds a letter or a digit
    ///   (`}` and blank lines are everywhere): each one of the anchor's
    ///   found among the run's three nearest rows on its side is a hit,
    ///   each missing where the rows reach that far a miss, and the score
    ///   is hits less misses;
    /// - a run needs a score above 0, or to be where the rows were (at the
    ///   line the page showed), with neither hit nor miss, and the only
    ///   run that reads as its rows;
    /// - of the runs with the best score, the one where the rows were if
    ///   there is one, else the only one; two leave it outdated, and so
    ///   does another run where the rows were that nothing contradicts.
    fileprivate static func search(
        _ anchor: CommentAnchor, in hunks: [[DiffRow]], path: String
    ) -> (anchor: CommentAnchor, score: Int)? {
        guard let first = anchor.rows.first else { return (.file(path), 0) }
        let runs = runs(of: anchor, in: hunks)
        if let copy = anchor.copy {
            guard runs.count == copy.count else { return nil }
            let run = runs[copy.index]
            let found = CommentAnchor.anchor(path: path, rows: hunks[run.hunk], range: run.range, copy: copy)
            return (found, evidence(of: anchor, around: run.range, in: hunks[run.hunk]).score)
        }
        guard !isRewrittenInPlace(anchor, in: hunks, runs: runs) else { return nil }
        struct Candidate {
            let hunk: Int
            let range: ClosedRange<Int>
            let evidence: ContextEvidence
            /// At the line the page showed.
            let isWhereItWas: Bool
        }
        let candidates = runs.map { run in
            Candidate(
                hunk: run.hunk, range: run.range, evidence: evidence(of: anchor, around: run.range, in: hunks[run.hunk]),
                isWhereItWas: hunks[run.hunk][run.range.lowerBound].line == first.line
            )
        }
        let trusted = candidates.filter { candidate in
            candidate.evidence.score > 0
                || (candidate.isWhereItWas && candidate.evidence == ContextEvidence() && candidates.count == 1)
        }
        guard let best = trusted.map(\.evidence.score).max() else { return nil }
        let winners = trusted.filter { $0.evidence.score == best }
        let inPlace = winners.filter(\.isWhereItWas)
        guard let winner = winners.count == 1 ? winners.first : (inPlace.count == 1 ? inPlace.first : nil),
              !candidates.contains(where: { other in
                  other.isWhereItWas && (other.hunk, other.range) != (winner.hunk, winner.range)
                      && (other.evidence.score >= 0 || winner.evidence.misses > 0)
              })
        else { return nil }
        return (CommentAnchor.anchor(path: path, rows: hunks[winner.hunk], range: winner.range), winner.evidence.score)
    }

    /// Whether the nearest context rows of `anchor` that hold a letter or
    /// a digit, one above and one below, still stand about as far apart
    /// somewhere, around rows none of `runs` is: the rows were rewritten,
    /// or deleted, there.
    private static func isRewrittenInPlace(
        _ anchor: CommentAnchor, in hunks: [[DiffRow]], runs: [(hunk: Int, range: ClosedRange<Int>)]
    ) -> Bool {
        guard let above = anchor.before.lastIndex(where: isDistinctive),
              let below = anchor.after.firstIndex(where: isDistinctive)
        else { return false }
        // The rows between them when the comment was made, and some slack.
        let reach = (anchor.before.count - 1 - above) + anchor.rows.count + below + 3
        for (index, rows) in hunks.enumerated() {
            for top in rows.indices where rows[top].text == anchor.before[above] {
                let bottom = rows[(top + 1)..<min(rows.count, top + 1 + reach)].firstIndex { $0.text == anchor.after[below] }
                guard let bottom else { continue }
                if !runs.contains(where: { $0.hunk == index && $0.range.lowerBound > top && $0.range.upperBound < bottom }) {
                    return true
                }
            }
        }
        return false
    }

    /// What the rows around a run say of an anchor's context.
    struct ContextEvidence: Equatable {
        var hits = 0
        var misses = 0
        var score: Int { hits - misses }
    }

    /// How the rows around `range` of a hunk's `rows` bear out `anchor`'s
    /// context: each of its rows that holds a letter or a digit is a hit
    /// when found among the three nearest on its side (each found row
    /// counting once), and a miss when not though the rows reach as far
    /// as it was.
    static func evidence(of anchor: CommentAnchor, around range: ClosedRange<Int>, in rows: [DiffRow]) -> ContextEvidence {
        let window = CommentAnchor.contextRows + 1
        let above = rows[max(0, range.lowerBound - window)..<range.lowerBound].reversed().map(\.text)
        let below = rows[(range.upperBound + 1)..<min(rows.count, range.upperBound + 1 + window)].map(\.text)
        var evidence = ContextEvidence()
        for (kept, found) in [(Array(anchor.before.reversed()), above), (anchor.after, below)] {
            var unused = found
            for (distance, text) in kept.enumerated() where isDistinctive(text) {
                if let index = unused.firstIndex(of: text) {
                    unused.remove(at: index)
                    evidence.hits += 1
                } else if found.count > distance {
                    evidence.misses += 1
                }
            }
        }
        return evidence
    }

    /// A row that says where it is: one with a letter or a digit.
    private static func isDistinctive(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
