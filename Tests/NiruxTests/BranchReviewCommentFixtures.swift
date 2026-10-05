import XCTest
@testable import Nirux

/// Hunks, files and comments' anchors for the comments' tests, written as
/// in a patch.
protocol CommentFixtures {}

extension CommentFixtures {
    typealias Anchor = BranchReview.CommentAnchor

    /// A hunk from lines written as in a patch: " ", "+", "-" or "\".
    func hunk(old: Int, new: Int, _ lines: [String]) -> BranchReview.Hunk {
        BranchReview.Hunk(oldStart: old, oldCount: 0, newStart: new, newCount: 0, section: "", lines: lines.map { line in
            let kind: BranchReview.Line.Kind
            switch line.first {
            case "+": kind = .added
            case "-": kind = .removed
            case "\\": kind = .noNewlineMarker
            default: kind = .context
            }
            return BranchReview.Line(kind: kind, text: String(line.dropFirst()))
        })
    }

    func file(
        _ hunks: [BranchReview.Hunk], path: String = "a.swift", oldPath: String? = nil, omission: BranchReview.Omission? = nil
    ) -> BranchReview.FileChange {
        BranchReview.FileChange(
            path: path, oldPath: oldPath, status: oldPath == nil ? .modified : .renamed, patchHash: "h", hunks: hunks,
            omission: omission
        )
    }

    func at(_ side: BranchReview.DiffSide, _ line: Int) -> BranchReview.DiffPosition {
        BranchReview.DiffPosition(side: side, line: line)
    }

    func row(_ kind: BranchReview.DiffRow.Kind, _ old: Int, _ new: Int, _ text: String) -> BranchReview.DiffRow {
        BranchReview.DiffRow(kind: kind, old: old, new: new, text: text)
    }

    /// The comment on the rows from `start` to `end` of `hunks`, which
    /// finds itself in the diff it was made in: a comment is never
    /// outdated as soon as it is made.
    func anchor(
        _ hunks: [BranchReview.Hunk], _ start: BranchReview.DiffPosition, _ end: BranchReview.DiffPosition? = nil,
        file path: StaticString = #filePath, line: UInt = #line
    ) throws -> Anchor {
        let made = try XCTUnwrap(Anchor(file: file(hunks), from: start, to: end ?? start), file: path, line: line)
        guard case .placed(let found) = BranchReview.place(made, in: file(hunks)), found.rows == made.rows else {
            XCTFail("not placed where it was made", file: path, line: line)
            return made
        }
        return made
    }

    /// The lines, as the page numbers them, of the rows `anchor` is placed
    /// at in `hunks`; nil when it isn't.
    func placed(_ anchor: Anchor, _ hunks: [BranchReview.Hunk], moved: Anchor? = nil) -> [Int]? {
        guard case .placed(let found) = BranchReview.place(anchor, moved: moved, in: file(hunks)) else { return nil }
        return found.rows.map(\.line)
    }

    func lineAnchor(_ text: String = "let b = 2") throws -> Anchor {
        try anchor([hunk(old: 1, new: 1, [" let a = 1", "+" + text, " let c = 3"])], at(.additions, 2))
    }
}
