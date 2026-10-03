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
            ("AppTests/Helpers/Mock.swift", .tests),
            ("App/AppUITests/Flow.swift", .tests),
            ("Package.swift", .config),
            ("Resources/Info.plist", .config),
            ("Nirux.entitlements", .config),
            (".swiftlint.yml", .config),
            ("Sources/.gitattributes", .config),
            (".github/dependabot.yml", .config),
            ("scripts/README.md", .config),
            (".github/workflows/README.md", .ci),
            (".github/actions/setup/action.yml", .ci),
            ("docs/diagram.png", .docs),
            ("CHANGELOG.MD", .docs),
            ("Sources/Nirux/App.swift", .code),
            ("Sources/Guide/docs/Page.swift", .code),
            ("Sources/Contests.swift", .code),
            ("Sources/Contests/Score.swift", .code)
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
        var edited = file("Sources/Zed.swift", lines: 90)
        edited.isUncommitted = true
        var draft = file("Sources/Draft.swift", .added)
        draft.isUncommitted = true
        var committedLockfile = file("web/yarn.lock")
        committedLockfile.fold = .lockfile
        var image = file("logo.png", lines: 0)
        image.fold = .binary
        let files = [
            file("Sources/Small.swift", lines: 2), file("Sources/Large.swift", lines: 90), file("Sources/New.swift", .added),
            file("Sources/Same.swift", lines: 2), file("README.md"), image, committedLockfile, lockfile,
            file("Tests/AppTests.swift", .added, lines: 300), edited, draft
        ]

        let groups = BranchReview.groups(of: files)

        XCTAssertEqual(groups.map(\.kind), [
            .uncommitted, .path(.code), .path(.tests), .path(.docs), .folded(.lockfile), .folded(.binary)
        ])
        // Refreshed while the agent works: by path, so rows stay put.
        XCTAssertEqual(groups[0].paths, ["Sources/Draft.swift", "Package.resolved", "Sources/Zed.swift"])
        XCTAssertEqual(
            groups[1].paths, ["Sources/New.swift", "Sources/Large.swift", "Sources/Same.swift", "Sources/Small.swift"]
        )
        XCTAssertEqual(groups[4].paths, ["web/yarn.lock"])
    }

    // MARK: - Folds read from the patch

    func testWhitespaceOnlyChangesAreFoldedAndOtherChangesAreNot() throws {
        // Reindented, a blank line added, a CRLF ending and trailing spaces dropped.
        XCTAssertEqual(try fold("-if a {\n-b()\r\n+if a {\n+\n+    b()  \n }", header: "@@ -1,3 +1,4 @@"), .whitespaceOnly)
        // git pairs an old closing brace with a new one as context: the
        // two sides of the hunk still read the same.
        XCTAssertEqual(
            try fold(" func a() {\n-if x {\n-y()\n+    if x {\n+        y()\n+    }\n }\n-}", header: "@@ -1,5 +1,5 @@"),
            .whitespaceOnly
        )
        // Whitespace inside a line changes what the code does.
        XCTAssertNil(try fold("-let s = \"a b\"\n+let s = \"ab\"\n c", header: "@@ -1,2 +1,2 @@"))
        XCTAssertNil(try fold("-x = a - -b\n+x = a --b\n c", header: "@@ -1,2 +1,2 @@"))
        // A line moved within one hunk.
        XCTAssertNil(try fold("-x\n y\n+x", header: "@@ -1,2 +1,2 @@"))
        // The last hunk is compared too.
        XCTAssertNil(try fold(" a\n-b\n+c", header: "@@ -1,2 +1,2 @@"))
        // Each hunk on its own: a pure addition hunk doesn't make up for
        // the line the previous one removed.
        XCTAssertNil(try fold("-a\n-b\n+a\n@@ -9,0 +8 @@\n+b", header: "@@ -1,2 +1 @@"))
        // A mode change is never folded.
        XCTAssertNil(try fold("- a\n+a\n b\n c", modes: "old mode 100644\nnew mode 100755\n"))
        // Where indentation carries meaning, only trailing whitespace goes.
        func indentationKept(_ body: String) throws -> BranchReview.Fold? {
            try files(
                nameStatus: "M\0a.swift\0", patch: modified(body, header: "@@ -1,2 +1,2 @@"),
                reading: Patch.Reading(whitespace: .keepingIndentation)
            )[0].fold
        }
        XCTAssertNil(try indentationKept(" steps:\n-  if: always()\n+if: always()"))
        XCTAssertEqual(try indentationKept(" steps:\n-  if: always()  \n+  if: always()"), .whitespaceOnly)
        // So do its blank lines: a YAML block, a Python string, a heredoc.
        XCTAssertNil(try files(
            nameStatus: "M\0a.swift\0", patch: modified(" text: |\n-\n   line", header: "@@ -1,3 +1,2 @@"),
            reading: Patch.Reading(whitespace: .keepingIndentation)
        )[0].fold)
        XCTAssertEqual(BranchReview.WhitespaceCheck.mode(for: "scripts/bundle.sh"), .keepingIndentation)
        XCTAssertEqual(BranchReview.WhitespaceCheck.mode(for: ".github/workflows/ci.yml"), .keepingIndentation)
        XCTAssertEqual(BranchReview.WhitespaceCheck.mode(for: "tools/Makefile"), .keepingIndentation)
        XCTAssertEqual(BranchReview.WhitespaceCheck.mode(for: "Sources/App.swift"), .ignoringIndentation)
        // Not checked: not folded.
        let unchecked = try files(
            nameStatus: "M\0a.swift\0", patch: modified("- a\n+a\n b\n c", header: "@@ -1,3 +1,3 @@"),
            reading: Patch.Reading(whitespace: nil)
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
        XCTAssertEqual(labels("let p = Process(); p.arguments = args"), ["Process arguments"])
        XCTAssertEqual(labels("task.arguments += [path]"), ["Process arguments"])
        XCTAssertEqual(labels("task.arguments.append(path)"), ["Process arguments"])
        XCTAssertEqual(labels("try workspace.openApplication(at: url, configuration: config)"), ["NSWorkspace"])
        XCTAssertEqual(labels("let mode = CommandLine.arguments[1]"), [], "reading argv launches nothing")
        XCTAssertEqual(labels("let p = BoundedProcessed()"), [])
        XCTAssertEqual(labels("try FileManager.default.createDirectory(at: home.appendingPathComponent(\".claude\"))"), ["~/.claude"])
        XCTAssertEqual(labels("let ÜCodable = 1"), [], "a non-ASCII letter is part of an identifier")
        XCTAssertEqual(labels("let config = home + \"/.codex/config.toml\""), ["~/.codex"])
        // A line that is only a comment raises nothing; a trailing comment does.
        XCTAssertEqual(labels("    /// Telegram prompts wait here."), [])
        XCTAssertEqual(labels("     * then DispatchQueue.main runs it"), [])
        XCTAssertEqual(labels("    /* DispatchQueue.main runs it */"), [])
        XCTAssertEqual(labels("    /* was: */ DispatchQueue.main.async {}"), ["DispatchQueue"])
        XCTAssertEqual(labels("     */ DispatchQueue.main.async {}"), ["DispatchQueue"])
        XCTAssertEqual(labels("     */"), [])
        XCTAssertEqual(labels("# Called by bundle.sh"), [])
        XCTAssertEqual(labels("#if canImport(Sparkle)"), ["Sparkle"])
        XCTAssertEqual(labels("let bot = Telegram() // Telegram"), ["Telegram"])
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
        XCTAssertEqual(settled("Sources/Views/Shell+Persistence.swift").map(\.kind), [.persistence, .concurrency])
        XCTAssertEqual(settled("Sources/Nirux/NiruxApp.swift").map(\.kind), [.concurrency, .launch])
        XCTAssertEqual(settled("Sources/Util/HandoverFile.swift").map(\.kind), [.security, .concurrency])
        XCTAssertEqual(settled("Sources/Util/AgentHookInstaller+StatusLine.swift").map(\.kind), [.concurrency, .sideEffects])
        // Merged in any order.
        let byPath = BranchReview.RiskSignal(kind: .launch, reasons: ["app delegate"], hunks: [], byPath: true)
        let byLine = BranchReview.RiskSignal(kind: .launch, reasons: ["--hook"], hunks: [3], byPath: false)
        XCTAssertEqual(
            BranchReview.merged([byPath, byLine]),
            [BranchReview.RiskSignal(kind: .launch, reasons: ["--hook", "app delegate"], hunks: [3], byPath: true)]
        )
    }

    func testTestsKeepOnlyConcurrency() {
        var file = FileChange(path: "Tests/NiruxTests/PersistenceTests.swift", status: .modified)
        file.signals = [
            BranchReview.RiskSignal(kind: .security, reasons: ["/tmp"], hunks: [0], byPath: false),
            BranchReview.RiskSignal(kind: .concurrency, reasons: ["@MainActor"], hunks: [1], byPath: false)
        ]

        BranchReview.RiskRules.settle(&file)

        XCTAssertEqual(file.signals, [BranchReview.RiskSignal(kind: .concurrency, reasons: ["@MainActor"], hunks: [1], byPath: false)])
    }

    // MARK: - Generated files

    func testGeneratedMarkerIsReadInTheFirstFiveLines() {
        func marked(_ text: String) -> Bool { BranchReview.hasGeneratedMarker(Data(text.utf8)) }
        XCTAssertTrue(marked("// Code generated by protoc-gen-go. DO NOT EDIT.\npackage x\n"))
        XCTAssertTrue(marked("/**\n * This file is @generated by Relay.\n */\n"))
        XCTAssertTrue(marked("# Code generated by sqlc; DO NOT EDIT.\n"))
        XCTAssertFalse(marked("# Prepends \"// @generated\" to each output file.\n"))
        XCTAssertFalse(marked("// Files that say Code generated … DO NOT EDIT are skipped.\n"))
        XCTAssertTrue(marked("1\n2\n3\n4\n// @generated\n"))
        XCTAssertFalse(marked("1\n2\n3\n4\n5\n// @generated\n"))
        XCTAssertFalse(marked("// Mail me at me@generated.example\n"))
        XCTAssertFalse(marked("// @generatedBy is our own annotation\n"))
        XCTAssertFalse(marked("// Code generated once, then edited by hand.\n"))
        XCTAssertFalse(marked("// DO NOT EDIT: Code generated below\n"))
        XCTAssertTrue(marked("// swiftlint:disable all\n// Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen\n"))
        XCTAssertTrue(marked("// Generated using Sourcery 2.1.7 — https://github.com/krzysztofzablocki/Sourcery\n"))
        XCTAssertTrue(marked("// DO NOT EDIT.\n// swift-format-ignore-file\n// swiftlint:disable all\n//\n// Generated by the Swift generator plugin for the protocol buffer compiler.\n"))
        XCTAssertFalse(marked("let note = \"Generated using SwiftGen\"\n"))
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
        let oneLine = patch.replacingOccurrences(of: "-package x", with: "-" + String(repeating: "x", count: 5_000))
        XCTAssertEqual(try XCTUnwrap(Patch.deletedFileStart(Data(oneLine.utf8))).count, 2_049, "a minified file's one line")
    }

    // MARK: - Workflows

    func testWorkflowPathsAreWholePathsFromTheTopLevel() {
        let workflow = """
        - run: ./scripts/bundle.sh "$VERSION"
        - run: bash $GITHUB_WORKSPACE/scripts/sign.sh
        - run: tools/my-scripts/prune.sh && cat ../outside.sh
        - run: swift build # see .github/actions/setup/action.yml.
        - run: swift test && cp out $RUNNER_TEMP/notes/README.md ${RUNNER_TEMP}/notes/CHANGES.md ~/bin/tool.sh
        - run: ${{ github.workspace }}/scripts/ws.sh && ./gradlew build # Update the Gemfile.
        """

        let tokens = BranchReview.pathTokens(in: Data(workflow.utf8))

        XCTAssertTrue(tokens.isSuperset(of: [
            "scripts/bundle.sh", "scripts/sign.sh", "tools/my-scripts/prune.sh", ".github/actions/setup/action.yml"
        ]))
        XCTAssertFalse(tokens.contains("scripts/prune.sh"))
        XCTAssertFalse(tokens.contains("my-scripts/prune.sh"))
        XCTAssertFalse(tokens.contains("outside.sh"))
        XCTAssertFalse(tokens.contains("test"), "a word, not a path")
        XCTAssertFalse(tokens.contains("notes/README.md"), "another variable's folder")
        XCTAssertFalse(tokens.contains("notes/CHANGES.md"), "another variable's folder")
        XCTAssertFalse(tokens.contains("bin/tool.sh"), "the home folder")
        XCTAssertTrue(tokens.isSuperset(of: ["scripts/ws.sh", "gradlew"]))
        XCTAssertFalse(tokens.contains("Gemfile"), "a sentence's last word")
    }
}
