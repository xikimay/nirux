import XCTest
@testable import Nirux

/// Folded noise, path groups and risk signals on handwritten patches and
/// file lists; `BranchReviewSnapshotTests` runs them on real repositories.
final class BranchReviewSignalsTests: XCTestCase {
    private typealias Patch = BranchReview.Patch
    private typealias FileChange = BranchReview.FileChange

    private func files(
        nameStatus: String, patch: String, reading: Patch.Reading = Patch.Reading()
    ) throws -> [FileChange] {
        let entries = try XCTUnwrap(Patch.nameStatus(Data(nameStatus.utf8)))
        let sections = try XCTUnwrap(Patch.sections(of: Data(patch.utf8), reading: { _ in reading }))
        return try XCTUnwrap(Patch.files(entries: entries, sections: sections))
    }

    private func modified(_ body: String, header: String, path: String = "a.swift", modes: String = "") -> String {
        """
        diff --git a/\(path) b/\(path)
        \(modes)index 1111111..2222222\(modes.isEmpty ? " 100644" : "")
        --- a/\(path)
        +++ b/\(path)
        \(header)
        \(body)

        """
    }

    private func fold(_ body: String, header: String = "@@ -1,3 +1,3 @@", modes: String = "") throws -> BranchReview.Fold? {
        try files(nameStatus: "M\0a.swift\0", patch: modified(body, header: header, modes: modes))[0].fold
    }

    // MARK: - Groups

    func testPathGroupsTryCodeLast() {
        let expected: [(String, BranchReview.PathGroup)] = [
            ("Tests/README.md", .tests),
            ("Packages/Core/Tests/Fixture.json", .tests),
            ("Sources/Nirux/WidgetTests.swift", .tests),
            ("web/app.test.ts", .tests),
            ("web/app.spec.js", .tests),
            ("cmd/main_test.go", .tests),
            ("Package.swift", .config),
            ("Resources/Info.plist", .config),
            ("Nirux.entitlements", .config),
            (".swiftlint.yml", .config),
            ("scripts/README.md", .config),
            (".github/workflows/README.md", .ci),
            (".github/actions/setup/action.yml", .ci),
            ("docs/diagram.png", .docs),
            ("CHANGELOG.MD", .docs),
            ("Sources/Nirux/App.swift", .code),
            (".github/dependabot.yml", .code),
            ("Sources/Contests.swift", .code)
        ]
        for (path, group) in expected {
            XCTAssertEqual(BranchReview.PathGroup(path: path), group, path)
        }
    }

    func testGroupsListUncommittedFirstThenAddedFilesThenLargerChanges() {
        func file(_ path: String, _ status: BranchReview.FileStatus = .modified, lines: Int = 1) -> FileChange {
            var file = FileChange(path: path, status: status)
            file.additions = lines
            return file
        }
        var lockfile = file("Package.resolved", lines: 40)
        lockfile.fold = .lockfile
        lockfile.isUncommitted = true
        var committedLockfile = file("web/yarn.lock")
        committedLockfile.fold = .lockfile
        var image = file("logo.png", lines: 0)
        image.fold = .binary
        let files = [
            file("Sources/Small.swift", lines: 2), file("Sources/Large.swift", lines: 90), file("Sources/New.swift", .added),
            file("Sources/Same.swift", lines: 2), file("README.md"), image, committedLockfile, lockfile,
            file("Tests/AppTests.swift", .added, lines: 300)
        ]

        let groups = BranchReview.groups(of: files)

        XCTAssertEqual(groups.map(\.kind), [
            .uncommitted, .path(.code), .path(.tests), .path(.docs), .folded(.lockfile), .folded(.binary)
        ])
        XCTAssertEqual(groups[0].paths, ["Package.resolved"])
        XCTAssertEqual(
            groups[1].paths, ["Sources/New.swift", "Sources/Large.swift", "Sources/Same.swift", "Sources/Small.swift"]
        )
        XCTAssertEqual(groups[4].paths, ["web/yarn.lock"])
    }

    // MARK: - Folds read from the patch

    func testWhitespaceOnlyChangesAreFoldedAndOtherChangesAreNot() throws {
        // Reindented, a blank line added, a CRLF ending dropped.
        XCTAssertEqual(try fold("-if a {\n-b()\r\n+if a {\n+\n+    b()\n }", header: "@@ -1,3 +1,4 @@"), .whitespaceOnly)
        // A line moved within one hunk: each run of changes differs.
        XCTAssertNil(try fold("-x\n y\n+x", header: "@@ -1,2 +1,2 @@"))
        // Whitespace that splits a word is still whitespace for git's -w,
        // but a changed character isn't.
        XCTAssertNil(try fold("-let a = 1\n+let a = 2\n c", header: "@@ -1,2 +1,2 @@"))
        // The last run of a hunk at the end of the file is compared too.
        XCTAssertNil(try fold(" a\n-b\n+c", header: "@@ -1,2 +1,2 @@"))
        // Each hunk on its own: a pure addition hunk doesn't make up for
        // the line the previous one removed.
        XCTAssertNil(try fold("-a\n-b\n+a\n@@ -9,0 +8 @@\n+b", header: "@@ -1,2 +1 @@"))
        // A mode change is never folded.
        XCTAssertNil(try fold("- a\n+a\n b\n c", modes: "old mode 100644\nnew mode 100755\n"))
        // Not checked: not folded.
        let unchecked = try files(
            nameStatus: "M\0a.swift\0", patch: modified("- a\n+a\n b\n c", header: "@@ -1,3 +1,3 @@"),
            reading: Patch.Reading(checksWhitespace: false)
        )
        XCTAssertNil(unchecked[0].fold)
    }

    func testPureRenameAndBinaryAreFoldedFromTheirPatch() throws {
        let patch = """
        diff --git a/Old.swift b/New.swift
        similarity index 100%
        rename from Old.swift
        rename to New.swift
        diff --git a/run.sh b/tools/run.sh
        old mode 100644
        new mode 100755
        similarity index 100%
        rename from run.sh
        rename to tools/run.sh
        diff --git a/Was.swift b/Is.swift
        similarity index 90%
        rename from Was.swift
        rename to Is.swift
        index 1111111..2222222 100644
        --- a/Was.swift
        +++ b/Is.swift
        @@ -1 +1 @@
        -a
        +b
        diff --git a/logo.png b/logo.png
        index 1111111111111111111111111111111111111111..2222222222222222222222222222222222222222 100644
        Binary files a/logo.png and b/logo.png differ

        """
        let folds = try files(
            nameStatus: "R100\0Old.swift\0New.swift\0R100\0run.sh\0tools/run.sh\0R090\0Was.swift\0Is.swift\0M\0logo.png\0",
            patch: patch
        ).map(\.fold)

        XCTAssertEqual(folds, [.pureRename, nil, nil, .binary])
    }

    // MARK: - Line rules

    private func labels(_ line: String) -> [String] {
        var found: [String] = []
        BranchReview.RiskRules.forEachLineRule(matching: Data(line.utf8)) {
            found.append(BranchReview.RiskRules.lineRules[$0].label)
        }
        return found
    }

    func testLineRulesMatchWholeIdentifiersOrTheirStart() {
        XCTAssertEqual(labels("struct Box: Codable, Sendable {"), ["Codable"])
        XCTAssertEqual(labels("struct MyCodableBox: CodableBase {"), [])
        XCTAssertEqual(labels("let status = SecItemAdd(query, nil)"), ["SecItem"])
        XCTAssertEqual(labels("Task { @MainActor in work() }"), ["@MainActor", "Task {"])
        XCTAssertEqual(labels("let task = MyTask { }; let t = Task(priority: .high) {}"), ["Task {"])
        XCTAssertEqual(labels("let dir = \"/tmpdir\""), [])
        XCTAssertEqual(labels("let dir = \"/private/tmp/x\""), ["/tmp"])
        XCTAssertEqual(labels("args == [\"--hooks\"]"), [])
        XCTAssertEqual(labels("args[1] == \"--hook\""), ["--hook"])
        XCTAssertEqual(labels("env[\"NIRUX_STATE_DIR\"] = nil"), ["NIRUX_*"])
        XCTAssertEqual(labels("let XNIRUX_A = 1"), [])
        XCTAssertEqual(labels("let p = Process(); p.arguments = args"), ["Process arguments", "process launch"])
        XCTAssertEqual(labels("let p = BoundedProcessed()"), [])
        XCTAssertEqual(labels("try FileManager.default.createDirectory(at: home.appendingPathComponent(\".claude\"))"), ["~/.claude"])
        XCTAssertEqual(labels("let ÜCodable = 1"), [], "a non-ASCII letter is part of an identifier")
    }

    func testSignalsPointAtTheirHunksAcrossATypeChangeEvenWithoutLines() throws {
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
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/same
        @@ -0,0 +1 @@
        +DispatchQueue.main.async {}
        diff --git a/a.swift b/a.swift
        index 1111111..2222222 100644
        --- a/a.swift
        +++ b/a.swift
        @@ -1,2 +1,2 @@
         DispatchQueue.main.async {}
        -a
        +b
        @@ -10 +10 @@
        -struct S: Codable {}
        +struct S: Codable, Sendable {}
        @@ -20 +20 @@
        -x
        +RunLoop.main.perform { work() }

        """
        for keepsLines in [true, false] {
            let read = try files(nameStatus: "M\0a.swift\0T\0same\0", patch: patch, reading: Patch.Reading(keepsLines: keepsLines))
            XCTAssertEqual(read[0].signals, [
                BranchReview.RiskSignal(kind: .persistence, reasons: ["Codable"], hunks: [1], byPath: false),
                BranchReview.RiskSignal(
                    kind: .concurrency, reasons: ["RunLoop.main.perform"], hunks: [2], byPath: false
                )
            ], "a context line raises nothing")
            XCTAssertEqual(read[1].signals, [
                BranchReview.RiskSignal(kind: .concurrency, reasons: ["DispatchQueue"], hunks: [1], byPath: false)
            ], "the second section's hunks come after the first's")
        }
        let unscanned = try files(nameStatus: "M\0a.swift\0T\0same\0", patch: patch, reading: Patch.Reading(findsRisks: false))
        XCTAssertEqual(unscanned.flatMap(\.signals), [])
    }

    func testPathRulesNameTheFileOrItsOldPathAndFoldedFilesKeepOnlyThem() {
        func settled(_ path: String, oldPath: String? = nil, fold: BranchReview.Fold? = nil) -> [BranchReview.RiskSignal] {
            var file = FileChange(path: path, status: oldPath == nil ? .modified : .renamed)
            file.oldPath = oldPath
            file.fold = fold
            file.signals = [BranchReview.RiskSignal(kind: .concurrency, reasons: ["@MainActor"], hunks: [0], byPath: false)]
            BranchReview.RiskRules.settle(&file)
            return file.signals
        }
        XCTAssertEqual(settled("Package.resolved", fold: .lockfile), [
            BranchReview.RiskSignal(kind: .dependencies, reasons: ["Package.resolved"], hunks: [], byPath: true)
        ])
        XCTAssertEqual(settled("Sources/Model/Workspace.swift", oldPath: "Sources/Model/WorkspaceStore.swift"), [
            BranchReview.RiskSignal(kind: .persistence, reasons: ["*Store.swift"], hunks: [], byPath: true),
            BranchReview.RiskSignal(kind: .concurrency, reasons: ["@MainActor"], hunks: [0], byPath: false)
        ])
        XCTAssertEqual(settled("Resources/Info.plist", fold: .whitespaceOnly).map(\.kind), [.launch])
        XCTAssertEqual(settled("Nirux.entitlements").map(\.kind), [.security, .concurrency])
        XCTAssertEqual(settled(".github/workflows/nightly.yml").map(\.kind), [.concurrency, .ci])
        XCTAssertEqual(settled("Sources/Model/Persistence+Recovery.swift").map(\.kind), [.persistence, .concurrency])
    }

    // MARK: - Generated files

    func testGeneratedMarkerIsReadInTheFirstFiveLines() {
        func marked(_ text: String) -> Bool { BranchReview.hasGeneratedMarker(Data(text.utf8)) }
        XCTAssertTrue(marked("// Code generated by protoc-gen-go. DO NOT EDIT.\npackage x\n"))
        XCTAssertTrue(marked("/**\n * This file is @generated by Relay.\n */\n"))
        XCTAssertTrue(marked("1\n2\n3\n4\n// @generated\n"))
        XCTAssertFalse(marked("1\n2\n3\n4\n5\n// @generated\n"))
        XCTAssertFalse(marked("// Mail me at me@generated.example\n"))
        XCTAssertFalse(marked("// @generatedBy is our own annotation\n"))
        XCTAssertFalse(marked("// Code generated once, then edited by hand.\n"))
        XCTAssertFalse(marked("// DO NOT EDIT: Code generated below\n"))
    }

    func testDeletedFileStartIsReadFromItsPatch() throws {
        let patch = """
        diff --git a/gen.go b/gen.go
        deleted file mode 100644
        index 1111111..0000000
        --- a/gen.go
        +++ /dev/null
        @@ -1,7 +0,0 @@
        -// Code generated by stringer. DO NOT EDIT.
        -package x
        -1
        -2
        -3
        -4
        -5

        """
        let start = try XCTUnwrap(Patch.deletedFileStart(Data(patch.utf8)))
        XCTAssertEqual(String(decoding: start, as: UTF8.self), "// Code generated by stringer. DO NOT EDIT.\npackage x\n1\n2\n3\n")
    }

    // MARK: - Workflows

    func testWorkflowPathsAreWholePathsFromTheTopLevel() {
        let workflow = """
        - run: ./scripts/bundle.sh "$VERSION"
        - run: bash $GITHUB_WORKSPACE/scripts/sign.sh
        - run: tools/my-scripts/prune.sh && cat ../outside.sh
        - run: swift build # see .github/actions/setup/action.yml.
        """

        let tokens = BranchReview.pathTokens(in: Data(workflow.utf8))

        XCTAssertTrue(tokens.isSuperset(of: [
            "scripts/bundle.sh", "scripts/sign.sh", "tools/my-scripts/prune.sh", ".github/actions/setup/action.yml"
        ]))
        XCTAssertFalse(tokens.contains("scripts/prune.sh"))
        XCTAssertFalse(tokens.contains("my-scripts/prune.sh"))
        XCTAssertFalse(tokens.contains("outside.sh"))
    }
}
