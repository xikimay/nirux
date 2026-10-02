import XCTest
@testable import Nirux

/// The patch parser and the patch hash on handwritten git output.
final class BranchReviewPatchTests: XCTestCase {
    private typealias Patch = BranchReview.Patch

    private func files(nameStatus: String, patch: String) throws -> [BranchReview.FileChange]? {
        let entries = try XCTUnwrap(Patch.nameStatus(Data(nameStatus.utf8)))
        let sections = try XCTUnwrap(Patch.sections(of: Data(patch.utf8)))
        return Patch.files(entries: entries, sections: sections)
    }

    // MARK: - Paths

    func testQuotedAndTabEndedPathsMatchTheirNameStatusEntries() throws {
        // A tab or a quote forces C-quoting even with core.quotePath=false;
        // a space adds a tab after the ---/+++ names.
        let patch = """
        diff --git "a/we\\tird" "b/we\\tird"
        index 1111111..2222222 100644
        --- "a/we\\tird"
        +++ "b/we\\tird"
        @@ -1 +1,2 @@
         tab
        +tab2
        diff --git a/sp ace.txt b/sp ace.txt
        index 1111111..2222222 100644
        --- a/sp ace.txt\t
        +++ b/sp ace.txt\t
        @@ -1 +1,2 @@
         x
        +y
        diff --git "a/\\303\\251\\"q.txt" "b/\\303\\251\\"q.txt"
        new file mode 100644
        index 0000000..2222222
        --- /dev/null
        +++ "b/\\303\\251\\"q.txt"
        @@ -0,0 +1 @@
        +e

        """
        let files = try XCTUnwrap(try files(
            nameStatus: "M\0we\tird\0M\0sp ace.txt\0A\0é\"q.txt\0", patch: patch
        ))

        XCTAssertEqual(files.map(\.path), ["we\tird", "sp ace.txt", "é\"q.txt"])
        XCTAssertEqual(files.map(\.additions), [1, 1, 1])
        XCTAssertEqual(files[2].status, .added)
        XCTAssertEqual(files[2].newMode, "100644")
    }

    func testSectionsWithoutHunksTakeTheirPathsFromTheirHeaders() throws {
        let patch = """
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755
        diff --git a/logo.png b/logo.png
        index 1111111111111111111111111111111111111111..2222222222222222222222222222222222222222 100644
        Binary files a/logo.png and b/logo.png differ
        diff --git a/empty b/empty
        new file mode 100644
        index 0000000000000000000000000000000000000000..e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
        diff --git a/old name.swift b/new name.swift
        similarity index 100%
        rename from old name.swift
        rename to new name.swift

        """
        let files = try XCTUnwrap(try files(
            nameStatus: "M\0run.sh\0M\0logo.png\0A\0empty\0R100\0old name.swift\0new name.swift\0", patch: patch
        ))

        XCTAssertEqual(files.map(\.path), ["run.sh", "logo.png", "empty", "new name.swift"])
        XCTAssertEqual(files[0].oldMode, "100644")
        XCTAssertEqual(files[0].newMode, "100755")
        XCTAssertTrue(files[1].isBinary)
        XCTAssertEqual(files[1].oldObjectID, String(repeating: "1", count: 40))
        XCTAssertEqual(files[1].newObjectID, String(repeating: "2", count: 40))
        XCTAssertEqual(files[2].status, .added)
        XCTAssertNil(files[2].oldObjectID, "only binary files keep their object ids")
        XCTAssertEqual(files[3].status, .renamed)
        XCTAssertEqual(files[3].oldPath, "old name.swift")
        XCTAssertEqual(files[3].similarity, 100)
    }

    func testListedFileWithoutASectionIsDroppedAndASectionWithoutEntryFails() throws {
        // Under diff.autoRefreshIndex=false a touched, unchanged file is in
        // --name-status but not in the patch.
        let patch = """
        diff --git a/a.txt b/a.txt
        index 1111111..2222222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -a
        +b

        """
        let kept = try XCTUnwrap(try files(nameStatus: "M\0a.txt\0M\0touched.txt\0", patch: patch))
        XCTAssertEqual(kept.map(\.path), ["a.txt"])

        // The patch has a file the list doesn't: the worktree moved between the reads.
        XCTAssertNil(try files(nameStatus: "M\0touched.txt\0", patch: patch))
    }

    func testTypeChangeSectionsMergeIntoOneFile() throws {
        let patch = """
        diff --git a/same b/same
        deleted file mode 100644
        index 1111111..0000000
        --- a/same
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -a
        -b
        diff --git a/same b/same
        new file mode 120000
        index 0000000..3333333
        --- /dev/null
        +++ b/same
        @@ -0,0 +1 @@
        +target
        \\ No newline at end of file

        """
        let files = try XCTUnwrap(try files(nameStatus: "T\0same\0", patch: patch))

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].status, .typeChanged)
        XCTAssertEqual(files[0].oldMode, "100644")
        XCTAssertEqual(files[0].newMode, "120000")
        XCTAssertEqual(files[0].deletions, 2)
        XCTAssertEqual(files[0].additions, 1)
    }

    func testHunkCountsDecideWhereAHunkEnds() throws {
        // Changed lines that read like headers, and a removed "-- x" line.
        let patch = """
        diff --git a/notes.md b/notes.md
        index 1111111..2222222 100644
        --- a/notes.md
        +++ b/notes.md
        @@ -1,3 +1,4 @@ title
         keep
        --- x
        +++ b/x
        +@@ -1 +1 @@
         end
        @@ -10 +11 @@
        -old
        +new

        """
        let file = try XCTUnwrap(try files(nameStatus: "M\0notes.md\0", patch: patch)?.first)

        XCTAssertEqual(file.hunks.count, 2)
        XCTAssertEqual(file.hunks[0].section, "title")
        XCTAssertEqual(file.hunks[0].lines.map(\.kind), [.context, .removed, .added, .added, .context])
        XCTAssertEqual(file.hunks[0].lines.map(\.text), ["keep", "-- x", "++ b/x", "@@ -1 +1 @@", "end"])
        XCTAssertEqual(file.hunks[1].lines.map(\.text), ["old", "new"])
        XCTAssertEqual(file.additions, 3)
        XCTAssertEqual(file.deletions, 2)
    }

    func testLinesAndPathsStartingWithACombiningAccentKeepIt() throws {
        // The tab makes git quote the path everywhere.
        let patch = """
        diff --git "a/\u{301}x\\ty.txt" "b/\u{301}x\\ty.txt"
        index 1111111..2222222 100644
        --- "a/\u{301}x\\ty.txt"
        +++ "b/\u{301}x\\ty.txt"
        @@ -1 +1 @@
        -\u{301}old
        +\u{301}new

        """
        let file = try XCTUnwrap(try files(nameStatus: "M\0\u{301}x\ty.txt\0", patch: patch)?.first)

        XCTAssertEqual(file.path, "\u{301}x\ty.txt")
        XCTAssertEqual(file.hunks.first?.lines, [.init(kind: .removed, text: "\u{301}old"), .init(kind: .added, text: "\u{301}new")])
    }

    func testFileThatIsNotUTF8DoesNotEmptyTheOthers() throws {
        var patch = Data("""
        diff --git a/latin.txt b/latin.txt
        index 1111111..2222222 100644
        --- a/latin.txt
        +++ b/latin.txt
        @@ -1 +1,2 @@
         e
        +
        """.utf8)
        patch.append(contentsOf: [0xE9, 0x74, 0xE9, 0x0A])
        patch.append(Data("""
        diff --git a/b.txt b/b.txt
        index 1111111..2222222 100644
        --- a/b.txt
        +++ b/b.txt
        @@ -1 +1 @@
        -x
        +y

        """.utf8))
        let entries = try XCTUnwrap(Patch.nameStatus(Data("M\0b.txt\0M\0latin.txt\0".utf8)))
        let files = try XCTUnwrap(Patch.files(entries: entries, sections: try XCTUnwrap(Patch.sections(of: patch))))

        XCTAssertEqual(files.map(\.path), ["b.txt", "latin.txt"])
        XCTAssertEqual(files[1].hunks.first?.lines.last?.text, "\u{FFFD}t\u{FFFD}")
    }

    // MARK: - Hash

    private func modified(_ lines: [BranchReview.Line], path: String = "a.swift", start: Int = 1, section: String = "")
        -> BranchReview.FileChange {
        var file = BranchReview.FileChange(path: path, status: .modified)
        file.hunks = [BranchReview.Hunk(
            oldStart: start, oldCount: 0, newStart: start, newCount: 0, section: section, lines: lines
        )]
        return file
    }

    private func line(_ kind: BranchReview.Line.Kind, _ text: String = "") -> BranchReview.Line {
        BranchReview.Line(kind: kind, text: text)
    }

    func testHashLeavesOutContextAndHunkPositions() {
        let reviewed = modified([line(.context, "a"), line(.removed, "b"), line(.added, "B"), line(.context, "c")])
        // The base changed the file around the hunk: other context, another
        // place, another enclosing function, another index line.
        var moved = modified(
            [line(.context, "x"), line(.removed, "b"), line(.added, "B")], start: 40, section: "func other()"
        )
        moved.oldObjectID = "1111111"

        XCTAssertEqual(BranchReview.patchHash(of: reviewed), BranchReview.patchHash(of: moved))
    }

    func testHashChangesWithLinesPathsStatusModeAndObjectIDs() {
        let original = modified([line(.removed, "b"), line(.added, "B")])
        var variants: [BranchReview.FileChange] = [
            modified([line(.removed, "b"), line(.added, "C")]),
            modified([line(.added, "B"), line(.removed, "b")]),
            modified([line(.removed, "b"), line(.added, "B")], path: "b.swift")
        ]
        var renamed = original
        renamed.status = .renamed
        renamed.oldPath = "old.swift"
        var renamedElsewhere = renamed
        renamedElsewhere.oldPath = "older.swift"
        var executable = original
        executable.oldMode = "100644"
        executable.newMode = "100755"
        var binary = BranchReview.FileChange(path: "a.png", status: .modified, isBinary: true)
        binary.oldObjectID = "1111111"
        binary.newObjectID = "2222222"
        var otherBinary = binary
        otherBinary.newObjectID = "3333333"
        variants += [renamed, renamedElsewhere, executable, binary, otherBinary]

        let hashes = ([original] + variants).map(BranchReview.patchHash(of:))
        XCTAssertEqual(Set(hashes).count, hashes.count)
    }

    func testNoNewlineMarkerCountsOnlyAfterAChangedLine() {
        let plain = modified([line(.added, "x"), line(.context, "last")])
        let afterContext = modified([line(.added, "x"), line(.context, "last"), line(.noNewlineMarker)])
        let added = modified([line(.added, "x")])
        let addedWithoutNewline = modified([line(.added, "x"), line(.noNewlineMarker)])

        XCTAssertEqual(BranchReview.patchHash(of: plain), BranchReview.patchHash(of: afterContext))
        XCTAssertNotEqual(BranchReview.patchHash(of: added), BranchReview.patchHash(of: addedWithoutNewline))
    }
}
