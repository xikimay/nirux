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

    func testSectionThatDisagreesWithItsStatusFails() throws {
        // Listed as added, read back as a rename: the worktree moved between
        // the two reads.
        let patch = """
        diff --git a/old.txt b/new.txt
        similarity index 100%
        rename from old.txt
        rename to new.txt

        """
        XCTAssertNil(try files(nameStatus: "A\0new.txt\0", patch: patch))
        XCTAssertNotNil(try files(nameStatus: "R100\0old.txt\0new.txt\0", patch: patch))
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

    /// A one-file modification patch.
    private func modified(
        _ body: String, path: String = "a.swift", header: String = "@@ -1,3 +1,3 @@", index: String = "1111111..2222222 100644",
        extraHeaders: String = ""
    ) -> String {
        """
        diff --git a/\(path) b/\(path)
        \(extraHeaders)index \(index)
        --- a/\(path)
        +++ b/\(path)
        \(header)
        \(body)

        """
    }

    private func hash(_ patch: String, nameStatus: String = "M\0a.swift\0", keepsLines: Bool = true) throws -> String {
        try hash(Data(patch.utf8), nameStatus: nameStatus, keepsLines: keepsLines)
    }

    private func hash(_ patch: Data, nameStatus: String = "M\0a.swift\0", keepsLines: Bool = true) throws -> String {
        let entries = try XCTUnwrap(Patch.nameStatus(Data(nameStatus.utf8)))
        let sections = try XCTUnwrap(Patch.sections(of: patch, keepsLines: { _ in keepsLines }))
        return try XCTUnwrap(Patch.files(entries: entries, sections: sections)?.first?.patchHash)
    }

    func testHashLeavesOutContextAndHunkPositions() throws {
        let reviewed = modified(" a\n-b\n+B\n c")
        // The base changed the file around the hunk: other context, another
        // place, another enclosing function, another index line.
        let moved = modified(" x\n-b\n+B\n y", header: "@@ -40,3 +41,3 @@ func other()", index: "3333333..4444444 100644")

        XCTAssertEqual(try hash(reviewed), try hash(moved))
    }

    func testHashChangesWithLinesPathsStatusModeAndObjectIDs() throws {
        let binary = """
        diff --git a/a.png b/a.png
        index 1111111..2222222 100644
        Binary files a/a.png and b/a.png differ

        """
        let hashes = [
            try hash(modified(" a\n-b\n+B\n c")),
            try hash(modified(" a\n-b\n+C\n c")),
            try hash(modified(" a\n+B\n-b\n c")),
            try hash(modified(" a\n-b\n+B\n c", path: "b.swift"), nameStatus: "M\0b.swift\0"),
            try hash(modified(" a\n-b\n+B\n c", extraHeaders: "old mode 100644\nnew mode 100755\n")),
            try hash(
                modified(" a\n-b\n+B\n c", extraHeaders: "similarity index 90%\nrename from old.swift\nrename to a.swift\n"),
                nameStatus: "R090\0old.swift\0a.swift\0"
            ),
            try hash(
                modified(" a\n-b\n+B\n c", extraHeaders: "similarity index 90%\nrename from older.swift\nrename to a.swift\n"),
                nameStatus: "R090\0older.swift\0a.swift\0"
            ),
            try hash(binary, nameStatus: "M\0a.png\0"),
            try hash(binary.replacingOccurrences(of: "2222222", with: "3333333"), nameStatus: "M\0a.png\0")
        ]

        XCTAssertEqual(Set(hashes).count, hashes.count)
    }

    func testNoNewlineMarkerCountsOnlyAfterAChangedLine() throws {
        let plain = modified("+x\n last", header: "@@ -1 +1,2 @@")
        let afterContext = modified("+x\n last\n\\ No newline at end of file", header: "@@ -1 +1,2 @@")
        let added = modified("-x\n+y", header: "@@ -1 +1 @@")
        let addedWithoutNewline = modified("-x\n+y\n\\ No newline at end of file", header: "@@ -1 +1 @@")

        XCTAssertEqual(try hash(plain), try hash(afterContext))
        XCTAssertNotEqual(try hash(added), try hash(addedWithoutNewline))
    }

    func testLinesThatAreNotUTF8AreHashedAsBytes() throws {
        func latin(_ byte: UInt8) -> Data {
            var patch = Data(modified("-cafe\n+caf", header: "@@ -1 +1 @@").utf8)
            patch.insert(byte, at: try! XCTUnwrap(patch.lastIndex(of: UInt8(ascii: "f"))) + 1)
            return patch
        }
        let acute = latin(0xE9)
        let grave = latin(0xE8)

        XCTAssertNotEqual(try hash(acute), try hash(grave))
        let line = try XCTUnwrap(Patch.sections(of: acute)?.first?.hunks.first?.lines.last)
        XCTAssertEqual(line.text, "caf\u{FFFD}")
        XCTAssertEqual(line.bytes, Data([0x63, 0x61, 0x66, 0xE9]))
    }

    func testSectionReadWithoutItsLinesKeepsItsCountsAndHash() throws {
        let patch = modified(" a\n-b\n+B\n+C\n c", header: "@@ -1,3 +1,4 @@")
        let entries = try XCTUnwrap(Patch.nameStatus(Data("M\0a.swift\0".utf8)))
        let full = try XCTUnwrap(Patch.files(entries: entries, sections: try XCTUnwrap(Patch.sections(of: Data(patch.utf8)))))
        let counted = try XCTUnwrap(Patch.files(
            entries: entries, sections: try XCTUnwrap(Patch.sections(of: Data(patch.utf8), keepsLines: { _ in false }))
        ))

        XCTAssertEqual(counted.first?.hunks, [])
        XCTAssertEqual(counted.first?.additions, 2)
        XCTAssertEqual(counted.first?.deletions, 1)
        XCTAssertEqual(counted.first?.patchHash, full.first?.patchHash)
    }
}
