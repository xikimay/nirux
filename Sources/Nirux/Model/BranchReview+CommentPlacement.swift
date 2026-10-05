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
            // The same place: the same rows, wherever it was looked for from.
            guard made.anchor.rows != moved.anchor.rows else { return .placed(made.anchor) }
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

    typealias Run = (hunk: Int, range: ClosedRange<Int>)

    /// The run that reads as `anchor`'s rows and is the same place. A
    /// comment under the wrong line is worse than an outdated one, so a
    /// run counts only with evidence, and when no other is as likely:
    /// - copied code (`copy`) is found, among the runs nothing around
    ///   contradicts, by the nearest row above that told it from its
    ///   copies (`landmark`); or else by its rank while their number is
    ///   the same, the run at that rank where the rows were, or at their
    ///   line of the base with no other copy where they were;
    /// - a context row is evidence only when it holds a letter or a digit
    ///   (`}` and blank lines are everywhere): each one of the anchor's
    ///   found among the run's three nearest rows on its side is a hit,
    ///   each missing where the rows reach that far a miss, and the score
    ///   is hits less misses;
    /// - where its nearest distinctive context rows still stand around
    ///   other rows (a frame), the rows were rewritten or deleted there:
    ///   a frame where the rows were leaves it outdated; frames elsewhere,
    ///   when there are more than when it was made, bar any run that
    ///   doesn't score above them;
    /// - a run needs a score above 0, and above the best another run had
    ///   when the comment was made or last found (`rival`: a near copy);
    ///   or to be where the rows were (at the line the page showed), with
    ///   neither hit nor miss, the only run that reads as its rows, and no
    ///   frame;
    /// - of the runs with the best score, the only one; or, when the one
    ///   where the rows were is among them and something around it
    ///   changed, that one (an unchanged twin is a copy made since). Two
    ///   leave it outdated, and so does another run where the rows were
    ///   that nothing contradicts.
    /// The anchor found is made again where it is: its near copies and
    /// frames counted there.
    fileprivate static func search(
        _ anchor: CommentAnchor, in hunks: [[DiffRow]], path: String
    ) -> (anchor: CommentAnchor, score: Int)? {
        guard let first = anchor.rows.first else { return (.file(path), 0) }
        let runs = runs(of: anchor, in: hunks)
        guard !runs.isEmpty else { return nil }
        let isWhereItWas = { (run: Run) in hunks[run.hunk][run.range.lowerBound].line == first.line }
        let evidences = runs.map { evidence(of: anchor, around: $0.range, in: hunks[$0.hunk]) }
        if let copy = anchor.copy {
            let clean = runs.indices.filter { evidences[$0].misses == 0 }.map { runs[$0] }
            let run: Run
            if let landmark = copy.landmark {
                let marked = clean.filter { landmark.marks($0, in: hunks) }
                guard marked.count == 1 else { return nil }
                run = marked[0]
            } else {
                // By rank, at the line it was or at its line of the base
                // (lines added above it). Within added code, every copy has
                // the same line of the base: its own rewritten while one is
                // added after it passes for it.
                guard clean.count == copy.count else { return nil }
                run = clean[copy.index]
                let isAtItsBaseLine = hunks[run.hunk][run.range.lowerBound].old == first.old
                guard isWhereItWas(run) || (isAtItsBaseLine && !clean.contains(where: isWhereItWas)) else { return nil }
            }
            let found = CommentAnchor.anchor(path: path, rows: hunks[run.hunk], range: run.range, copy: copy)
            return (found, evidence(of: anchor, around: run.range, in: hunks[run.hunk]).score)
        }
        struct Candidate {
            let run: Run
            let evidence: ContextEvidence
            /// At the line the page showed.
            let isWhereItWas: Bool
        }
        let candidates = runs.indices.map { Candidate(run: runs[$0], evidence: evidences[$0], isWhereItWas: isWhereItWas(runs[$0])) }
        let frames = frames(of: anchor, in: hunks, runs: runs)
        guard !frames.contains(where: \.isWhereItWas) else { return nil }
        let frameBar = frames.count > anchor.frames ? frames.map(\.score).max() ?? 0 : 0
        let bar = max(0, anchor.rival ?? 0, frameBar)
        let trusted = candidates.filter { candidate in
            candidate.evidence.score > bar
                || (candidate.isWhereItWas && candidate.evidence == ContextEvidence() && candidates.count == 1 && frames.isEmpty)
        }
        guard let best = trusted.map(\.evidence.score).max() else { return nil }
        let winners = trusted.filter { $0.evidence.score == best }
        let inPlace = winners.filter(\.isWhereItWas)
        let changedInPlace = inPlace.count == 1 && inPlace[0].evidence.misses > 0 ? inPlace.first : nil
        guard let winner = winners.count == 1 ? winners.first : changedInPlace,
              !candidates.contains(where: { other in
                  other.isWhereItWas && (other.run.hunk, other.run.range) != (winner.run.hunk, winner.run.range)
                      && (other.evidence.score >= 0 || winner.evidence.misses > 0)
              })
        else { return nil }
        let found = CommentAnchor.made(path: path, hunks: hunks, run: winner.run, runs: runs)
        return (found, winner.evidence.score)
    }

    /// Where the nearest context rows of `anchor` that hold a letter or a
    /// digit, one above and one below, still stand about as far apart
    /// around rows none of `runs` is: the rows were rewritten, or deleted,
    /// there. Each scored as a run there would be, so that the same frame
    /// around other code (another test's) only counts as far as its
    /// context bears out. Not the rows themselves, unchanged where they
    /// were, standing as a frame row (two lines alike, one under the
    /// other).
    static func frames(of anchor: CommentAnchor, in hunks: [[DiffRow]], runs: [Run]) -> [Frame] {
        guard let first = anchor.rows.first, let above = anchor.before.lastIndex(where: isDistinctive),
              let below = anchor.after.firstIndex(where: isDistinctive)
        else { return [] }
        // The rows between them when the comment was made, and some slack.
        let reach = (anchor.before.count - 1 - above) + anchor.rows.count + below + 3
        let count = anchor.rows.count
        // Each hunk's run starts, in order (`runs` makes them so): a frame
        // asks only for those near it, not every run of a long diff.
        var starts = [[Int]](repeating: [], count: hunks.count)
        for run in runs { starts[run.hunk].append(run.range.lowerBound) }
        func startsOf(_ hunk: Int, from lower: Int, through upper: Int) -> ArraySlice<Int> {
            let sorted = starts[hunk]
            guard lower <= upper else { return [] }
            return sorted[firstIndex(in: sorted, notBelow: lower)..<firstIndex(in: sorted, notBelow: upper + 1)]
        }
        var frames: [Frame] = []
        for (index, rows) in hunks.enumerated() {
            for top in rows.indices where rows[top].text == anchor.before[above] {
                let bottom = rows[(top + 1)..<min(rows.count, top + 1 + reach)].firstIndex { $0.text == anchor.after[below] }
                guard let bottom, startsOf(index, from: top + 1, through: bottom - count).isEmpty,
                      !(startsOf(index, from: top - count + 1, through: top) + startsOf(index, from: bottom - count + 1, through: bottom))
                          .contains(where: { start in
                              rows[start].line == first.line
                                  && evidence(of: anchor, around: start...(start + count - 1), in: rows).misses == 0
                          })
                else { continue }
                frames.append(Frame(
                    score: evidence(of: anchor, aboveEnd: top + 1, belowStart: bottom, in: rows).score,
                    isWhereItWas: rows[top + 1].position == first.position
                ))
            }
        }
        return frames
    }

    /// The index of the first of `sorted` at or above `value`.
    private static func firstIndex(in sorted: [Int], notBelow value: Int) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// A place where a comment's frame stands around other rows.
    struct Frame: Equatable {
        let score: Int
        /// Where the rows were: they were rewritten, or deleted, there.
        let isWhereItWas: Bool
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
        evidence(of: anchor, aboveEnd: range.lowerBound, belowStart: range.upperBound + 1, in: rows)
    }

    /// The same, for rows that would end above at `aboveEnd` and start
    /// below at `belowStart`.
    static func evidence(of anchor: CommentAnchor, aboveEnd: Int, belowStart: Int, in rows: [DiffRow]) -> ContextEvidence {
        let window = CommentAnchor.contextRows + 1
        let above = rows[max(0, aboveEnd - window)..<aboveEnd].reversed().map(\.text)
        let below = rows[belowStart..<min(rows.count, belowStart + window)].map(\.text)
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
