import XCTest
@testable import Nirux

/// The decisions' memory files (docs/project-memory-tree.md, section 3.8):
/// their lines and marks, the user's changes read back, and rewrites that
/// touch only Nirux's own unchanged lines.
final class ProjectHistoryDecisionFilesTests: XCTestCase {
    private typealias Operation = ProjectHistory.DecisionOperation
    private let day = Date(timeIntervalSince1970: 1_790_000_000)

    private func decision(_ n: Int, id: Int, _ text: String, after: Int? = nil, edited: Bool = false) -> ProjectHistory.Decision {
        ProjectHistory.Decision(
            n: n, id: id, after: after, decisionClass: .design, topic: "Branch Review", text: text, date: day, isEditedByUser: edited
        )
    }

    private func list(_ decisions: [ProjectHistory.Decision]) -> ProjectHistory.DecisionList {
        ProjectHistory.DecisionList(decisions.map {
            Operation(op: .add, n: $0.n, id: $0.id, after: $0.after, decisionClass: $0.decisionClass, topic: $0.topic,
                      text: $0.text, date: $0.date, by: "model")
        })
    }

    private func record(_ decisions: [ProjectHistory.Decision]) -> ProjectHistory.DecisionFile {
        var file = ProjectHistory.DecisionFile(topic: "Branch Review")
        for decision in decisions { file.set(decision.n, ProjectHistory.decisionFileLine(decision)) }
        return file
    }

    /// `- <day>: <text> [d<n> · msg <id> after <id>]`, read back whatever
    /// the bullet, with or without its day.
    func testLinesAndMarks() {
        let line = ProjectHistory.decisionFileLine(decision(12, id: 4521, "Send comments at once.", after: 4520))
        XCTAssertEqual(line, "- \(ProjectHistory.localDay(day)): Send comments at once. [d12 · msg 4521 after 4520]")
        XCTAssertEqual(ProjectHistory.markedLine(line)?.n, 12)
        XCTAssertEqual(ProjectHistory.markedLine(line)?.text, "Send comments at once.")
        XCTAssertEqual(ProjectHistory.markedLine("* Reworded by hand [d3 · msg 9]  \r")?.text, "Reworded by hand")
        XCTAssertEqual(ProjectHistory.markedLine("- 2026-10-01:   [d3]")?.text, "")
        XCTAssertNil(ProjectHistory.markedLine("- A line of the user's."))
        XCTAssertNil(ProjectHistory.markedLine("- See [the doc](x.md)"))
        XCTAssertNil(ProjectHistory.markedLine("- A draft [d3x]"))
        XCTAssertNil(ProjectHistory.markedLine("- Something [done]"))
    }

    /// What the user did since Nirux wrote the file: any change to a line
    /// makes it the user's (an edit, even of its day alone); a line emptied
    /// is a removal; a line gone is one once confirmed (seen gone twice);
    /// the whole file gone drops its lines; a changed line whose decision
    /// is out becomes the user's.
    func testTheUsersChangesAreRead() {
        let decisions = [decision(1, id: 10, "One."), decision(2, id: 11, "Two."), decision(3, id: 12, "Three."),
                         decision(4, id: 13, "Four."), decision(5, id: 14, "Five.")]
        let file = record(decisions)
        var inForce = list(decisions)
        inForce.apply(Operation(op: .drop, replaces: [5], date: day, by: "model"))
        let lines = decisions.map { ProjectHistory.decisionFileLine($0) }
        let text = """
            The intro.

            \(lines[0].replacingOccurrences(of: "One.", with: "One, reworded."))
            \(lines[1].replacingOccurrences(of: ProjectHistory.localDay(day), with: "2020-01-01"))
            - [d3 · msg 12]
            \(lines[4].replacingOccurrences(of: "Five.", with: "Five, kept by the user."))
            A line of the user's.

            """
        let (operations, updated, missing) = ProjectHistory.userChanges(fileText: text, file: file, list: inForce, now: day)
        XCTAssertEqual(operations, [
            Operation(op: .edit, n: 1, text: "One, reworded.", date: day, by: "user"),
            Operation(op: .edit, n: 2, text: "Two.", date: day, by: "user"),
            Operation(op: .drop, replaces: [3], date: day, by: "user")
        ])
        XCTAssertEqual(missing, [4], "a line gone once may be a save under way")
        XCTAssertEqual(updated.numbers, [1, 2, 4], "the emptied and orphaned lines leave the record")
        XCTAssertEqual(updated.line(1), lines[0].replacingOccurrences(of: "One.", with: "One, reworded."))
        XCTAssertEqual(updated.line(2), lines[1].replacingOccurrences(of: ProjectHistory.localDay(day), with: "2020-01-01"))

        let (confirmed, _, none) = ProjectHistory.userChanges(fileText: text, file: file, list: inForce, confirmed: [4], now: day)
        XCTAssertEqual(confirmed.last, Operation(op: .drop, replaces: [4], date: day, by: "user"))
        XCTAssertEqual(none, [])

        let (gone, cleared, _) = ProjectHistory.userChanges(fileText: nil, file: file, list: inForce, now: day)
        XCTAssertEqual(gone.map(\.replaces), [[1], [2], [3], [4]], "every decision in force it held")
        XCTAssertEqual(cleared.numbers, [])
    }

    /// A rewrite adds the new decisions at the end and takes out Nirux's
    /// unchanged lines of decisions no longer wanted; an edited line, an
    /// unmarked one and the line breaks stay; `modified` moves on; a line
    /// written before a crash isn't written twice.
    func testARewriteTouchesOnlyNiruxsUnchangedLines() throws {
        let kept = decision(1, id: 10, "Kept.")
        let out = decision(2, id: 11, "Replaced.")
        let edited = decision(3, id: 12, "Edited by the user.", edited: true)
        let new = decision(4, id: 13, "New.")
        let crashed = decision(5, id: 14, "Written before a crash.")
        let file = record([kept, out, edited])
        let header = "---\r\nname: decisions-branch-review\r\nmetadata:\r\n  type: project\r\n  modified: 2020-01-01T00:00:00.000Z\r\n"
            + "  nirux: decisions\r\n---\r\n\r\nThe intro.\r\n\r\n"
        let text = header + [kept, out, edited].map { ProjectHistory.decisionFileLine($0) + "\r" }.joined(separator: "\n")
            + "\n- A line of the user's.\r\n" + ProjectHistory.decisionFileLine(crashed) + "\r\n"
        let (rewritten, updated) = ProjectHistory.rewrittenDecisionFile(
            text, file: file, wanted: [kept, new, crashed], editedByUser: [3], now: day
        )
        let result = try XCTUnwrap(rewritten)
        XCTAssertFalse(result.contains("Replaced."))
        XCTAssertTrue(result.contains("Edited by the user."), "never removed, though no longer wanted")
        XCTAssertTrue(result.contains("- A line of the user's.\r\n"))
        XCTAssertEqual(result.components(separatedBy: "Written before a crash.").count, 2, "taken back, not written twice")
        XCTAssertTrue(result.hasSuffix(ProjectHistory.decisionFileLine(new) + "\r\n"))
        XCTAssertTrue(result.contains("modified: \(ProjectMemory.modifiedText(day))\r\n"))
        XCTAssertEqual(updated.numbers, [1, 4, 5], "the edited line is the user's once its decision is out")

        let (unchanged, same) = ProjectHistory.rewrittenDecisionFile(
            result, file: updated, wanted: [kept, new, crashed], editedByUser: [3], now: day
        )
        XCTAssertNil(unchanged)
        XCTAssertEqual(same, updated)
    }

    /// A line changed meanwhile isn't taken out, and a line Nirux wrote
    /// that an agent removed meanwhile isn't written again.
    func testARewriteLeavesLinesChangedMeanwhile() {
        let out = decision(1, id: 10, "Replaced.")
        let removed = decision(2, id: 11, "Removed meanwhile.")
        let file = record([out, removed])
        let changed = ProjectHistory.decisionFileLine(out).replacingOccurrences(of: "Replaced.", with: "Reworded meanwhile.")
        let (rewritten, updated) = ProjectHistory.rewrittenDecisionFile(
            changed + "\n", file: file, wanted: [removed], editedByUser: [], now: day
        )
        XCTAssertNil(rewritten)
        XCTAssertEqual(updated.numbers, [2])
    }

    /// A new file is marked as Nirux's in its frontmatter; other memories
    /// aren't.
    func testANewFileIsMarkedAsNiruxs() {
        let text = ProjectHistory.newDecisionFile(
            name: "decisions-branch-review", topic: "Branch Review", decisions: [decision(2, id: 11, "B."), decision(1, id: 10, "A.")],
            now: day
        )
        XCTAssertTrue(ProjectHistory.isDecisionFile(text))
        XCTAssertEqual(ProjectHistory.decisionFileTopic(text), "Branch Review")
        XCTAssertTrue(text.hasPrefix("---\nname: decisions-branch-review\ndescription: \"The user's decisions on Branch Review"))
        XCTAssertTrue(text.contains("  nirux: decisions\n  topic: \"Branch Review\"\n---\n\nThe user's decisions on Branch Review, as Nirux"))
        XCTAssertTrue(text.contains("records of what the user chose, not tasks"))
        XCTAssertTrue(text.contains("Agents: don't edit or delete these lines unless the user asks"))
        let a = ProjectHistory.decisionFileLine(decision(1, id: 10, "A.")), b = ProjectHistory.decisionFileLine(decision(2, id: 11, "B."))
        XCTAssertTrue(text.hasSuffix("\(a)\n\(b)\n"), "oldest message first")
        XCTAssertEqual(ProjectMemory.frontmatter(of: text).fields["description"],
                       "The user's decisions on Branch Review, dated, each with its source")
        XCTAssertFalse(ProjectHistory.isDecisionFile("---\nname: x\n---\n\nnirux: decisions\n"))
        XCTAssertFalse(ProjectHistory.isDecisionFile("nirux: decisions"))
    }

    /// A topic's index line goes at the end, as the panel adds a memory's,
    /// once; the index takes none past 180 lines or 23,000 bytes.
    func testTheIndexLine() {
        let line = ProjectMemory.indexLine(
            title: ProjectHistory.decisionTitle("Branch Review"), fileName: "decisions-branch-review.md",
            hook: ProjectHistory.decisionHook("Branch Review")
        )
        XCTAssertEqual(line, "- [Decisions — Branch Review](decisions-branch-review.md) — the user's decisions on Branch Review, "
            + "dated, each with its source")
        let index = "# Memory index\n\n- [Old](old.md) — a memory\n"
        XCTAssertEqual(ProjectHistory.indexAdding(line, for: "decisions-branch-review.md", to: index),
                       "# Memory index\n\n- [Old](old.md) — a memory\n\(line)\n")
        XCTAssertNil(ProjectHistory.indexAdding(line, for: "Decisions-Branch-Review.md", to: "\(line)\n"), "already listed")
        XCTAssertEqual(ProjectHistory.indexAdding(line, for: "decisions-branch-review.md", to: ""), "\(line)\n")
        XCTAssertEqual(ProjectHistory.indexAdding(line, for: "decisions-branch-review.md", to: "# Index\r\n"), "# Index\r\n\(line)\r\n")

        let full = String(repeating: "- [M](m.md) — x\n", count: 179)
        XCTAssertTrue(ProjectHistory.indexHasRoom(String(repeating: "- [M](m.md) — x\n", count: 178), for: line))
        XCTAssertFalse(ProjectHistory.indexHasRoom(full + "- [M](m.md) — x\n", for: line))
        XCTAssertFalse(ProjectHistory.indexHasRoom(String(repeating: "x", count: 22_950), for: line))
    }

    /// The record of the files and the operation log, written and read
    /// back: a cut last line is skipped and the next write starts a line of
    /// its own; a log that can't be read is nil, not empty.
    func testTheRecordAndTheLogRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-decision-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = try XCTUnwrap(ProjectHistoryJournal.open(folder: folder))
        XCTAssertEqual(journal.decisionOperations(), [], "no log: no operation")

        var files = ProjectHistory.DecisionFiles(directory: "/memory")
        files.files["decisions-a.md"] = record([decision(1, id: 10, "A.")])
        files.retired = ["B"]
        XCTAssertTrue(ProjectHistory.writeDecisionFiles(files, in: folder))
        XCTAssertEqual(ProjectHistory.decisionFiles(in: folder), files)

        let first = Operation(op: .add, n: 1, id: 10, decisionClass: .design, topic: "A", text: "A.", date: day, by: "model")
        XCTAssertTrue(journal.appendDecisionOperations([first]))
        let log = folder.appendingPathComponent(ProjectHistory.decisionsFileName)
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"op":"add","n":2,"#.utf8))
        try handle.close()
        let second = Operation(op: .drop, replaces: [1], date: day, by: "user")
        XCTAssertTrue(journal.appendDecisionOperations([second]))
        XCTAssertEqual(journal.decisionOperations(), [first, second], "the cut line is skipped, not the next")

        try FileManager.default.removeItem(at: log)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        XCTAssertNil(journal.decisionOperations(), "there but unreadable: nil, never an empty list")
    }
}
