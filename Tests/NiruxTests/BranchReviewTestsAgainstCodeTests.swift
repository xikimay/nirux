import XCTest
@testable import Nirux

/// "Tests against code" on real, temporary git repositories:
/// `BranchReviewSymbolsTests` covers the scanner on handwritten sources.
final class BranchReviewTestsAgainstCodeTests: BranchReviewRepositoryTestCase {
    private typealias Symbol = BranchReview.Symbol

    private func symbol(_ name: String, _ line: Int, _ kind: Symbol.Kind = .variable, in container: String? = nil) -> Symbol {
        Symbol(name: name, line: line, kind: kind, container: container)
    }

    func testTestsAgainstCodeListsTheSymbolsNoTestMentions() throws {
        try write("Sources/Widget.swift", "struct Widget {\n    var name = \"\"\n}\n")
        try commitToMain("widget")
        try write("Sources/Widget.swift", """
        struct Widget {
            var name = "widget"
            var title = ""
            func render() -> String {
                let local = name
                return local
            }
            private func cache() {}
        }

        """)
        try write("Sources/Gauge.swift", "public final class Gauge {\n    public static let shared = Gauge()\n    func measureAll() {}\n}\n")
        try write("Sources/Generated.swift", "// @generated\nstruct Generated {}\n")
        try write("Sources/Strings.swift", "// Generated using SwiftGen\nenum L10n {}\n")
        try write("Sources/Model.pb.swift", "struct Model {}\n")
        try write("scripts/tool.sh", "#!/bin/sh\necho tool\n")
        try write("Tests/WidgetTests.swift", "func testRender() { _ = Widget().render() }\n// measureAll\nlet label = \"title\"\n")
        try write("Sources/App.swift", "let a = 1\nlet b = 2\n")
        try commit("work")
        try write("Tests/Draft/GaugeTests.swift", "let gauge = \"\\(Gauge.shared)\"\n")
        try write("AppTests/Helpers/Mock.swift", "let mock = 1\n")
        try write("Sources/Use.swift", "let used = Widget().title\n")

        let snapshot = try snapshot()
        let tests = snapshot.testsAgainstCode

        XCTAssertEqual(tests.testLines, 5)
        XCTAssertEqual(tests.codeLines, 14, "the script counts, the generated files don't")
        // `name` only changed its value.
        XCTAssertEqual(try file("Sources/Widget.swift", in: snapshot).symbols, .read([
            symbol("title", 3, in: "Widget"), symbol("render", 4, .function, in: "Widget")
        ]))
        XCTAssertEqual(tests.declared, 6)
        // `measureAll` is only in a comment, `title` only in a string or
        // outside the tests.
        XCTAssertEqual(tests.unmentioned, [
            .init(path: "Sources/Gauge.swift", symbol: symbol("measureAll", 3, .function, in: "Gauge")),
            .init(path: "Sources/Use.swift", symbol: symbol("used", 1)),
            .init(path: "Sources/Widget.swift", symbol: symbol("title", 3, in: "Widget"))
        ])
        XCTAssertEqual(tests.unscannedFiles, [])
        XCTAssertEqual(tests.unreadTestFiles, 0)
        XCTAssertFalse(tests.testFilesUnlisted)
        XCTAssertNil(try file("Sources/App.swift", in: snapshot).symbols, "it adds no line")
        XCTAssertNil(try file("Sources/Generated.swift", in: snapshot).symbols, "it is folded")

        var limited = options()
        limited.maxTestFilesRead = 0
        let unread = try self.snapshot(limited).testsAgainstCode
        XCTAssertEqual(unread.unreadTestFiles, 3)
        XCTAssertEqual(unread.unmentioned.count, 6)
    }

    func testTypeIsMentionedThroughItsMembers() throws {
        try write("Sources/Phase.swift", """
        enum Phase {
            case idle, busy
        }
        struct Outer {
            enum Inner { case deep }
        }
        struct Lonely {
            static let alone = 1
        }
        extension Phase {
            static let initial = Phase.idle
        }

        """)
        // An extension in another file declares a member too.
        try write("Sources/PhaseExtras.swift", "extension Lonely {\n    static let together = 1\n}\n")
        // A requirement's name says nothing of the real type: tests call it
        // on a fake.
        try write("Sources/Making.swift", "protocol Maker {\n    func make()\n}\nstruct RealMaker: Maker {\n    func make() {}\n}\n")
        try write("Tests/FakeMaker.swift", "struct FakeMaker: Maker { func make() {} }\n")
        // `Kind` is nested in two types: each counts by its own members.
        try write("Sources/Shapes.swift", "enum Circle {\n    enum Kind { case round }\n}\nenum Square {\n    enum Kind { case sharp }\n}\n")
        try write(
            "Tests/PhaseTests.swift",
            "assert(phase == .busy)\nassert(depth == .deep)\nassert(kind == .sharp)\nassert(value == .together)\n"
        )

        let tests = try snapshot().testsAgainstCode

        XCTAssertEqual(
            tests.unmentioned.map { "\(BranchReview.fileName($0.path)):\($0.symbol.name)" },
            ["Making.swift:RealMaker", "Phase.swift:idle", "Phase.swift:alone", "Phase.swift:initial",
             "Shapes.swift:Circle", "Shapes.swift:Kind", "Shapes.swift:round"]
        )
    }

    func testTestFilesThatCantBeReadCountAsUnreadButDeletedOnesDont() throws {
        try write("Tests/GoneTests.swift", "gauge\n")
        try commitToMain("tests")
        try FileManager.default.removeItem(atPath: repo + "/Tests/GoneTests.swift")
        try FileManager.default.createSymbolicLink(atPath: repo + "/Tests/LinkTests.swift", withDestinationPath: "../README.md")
        // Not a test's text: a snapshot image (the one file read), a nested
        // repository (none).
        try write("Tests/__Snapshots__/shot.png", Data([0x89, 0x50, 0x4E, 0x47, 0x00]) + Data(" gauge ".utf8))
        try git(["init", "-q", "--template=", "Tests/Nested"])
        try write("Tests/zz.txt", "nothing\n")
        try write("Sources/Gauge.swift", "let gauge = 1\n")
        // A link declares nothing.
        try FileManager.default.createSymbolicLink(atPath: repo + "/Sources/Alias.swift", withDestinationPath: "Gauge.swift")

        var oneFile = options()
        oneFile.maxTestFilesRead = 1
        let snapshot = try snapshot(oneFile)

        XCTAssertEqual(snapshot.testsAgainstCode.unreadTestFiles, 2, "the link, and the text past the one file read")
        XCTAssertEqual(snapshot.testsAgainstCode.unmentioned.map(\.symbol.name), ["gauge"], "an image says nothing")
        XCTAssertNil(try file("Sources/Alias.swift", in: snapshot).symbols)
        XCTAssertEqual(snapshot.testsAgainstCode.unscannedFiles, [])
    }

    func testSymbolsOfAFileCheckedOutWithCRLFAreRead() throws {
        try write(".gitattributes", "*.swift text eol=crlf\n")
        try commitToMain("attributes")
        try write("Sources/Gauge.swift", "struct Gauge {\r\n    var level = 0\r\n}\r\n")

        let gauge = try file("Sources/Gauge.swift", in: try snapshot())

        XCTAssertEqual(gauge.hunks.first?.lines.map(\.text), ["struct Gauge {", "    var level = 0", "}"])
        XCTAssertEqual(gauge.symbols, .read([symbol("Gauge", 1, .type), symbol("level", 2, in: "Gauge")]))
    }

    func testSymbolsOfFilesListedWithoutTheirPatchAreUnknown() throws {
        try write("Sources/Old.swift", (1...20).map { "let line\($0) = \($0)\n" }.joined())
        try commitToMain("base")
        try write("Sources/Old.swift", (1...20).map { "let line\($0) = \($0)\n" }.joined() + "let more = 1\n")
        try write("Sources/App.swift", "let a = 1\nlet b = 2\n")
        try commit("more")
        try write("Sources/Draft.swift", "let draft = 1\n")
        var limited = options()
        limited.maxDiffBytes = 60
        limited.maxUntrackedFilesRead = 0

        let snapshot = try snapshot(limited)

        XCTAssertTrue(snapshot.files.allSatisfy { $0.omission == .notRead })
        XCTAssertEqual(snapshot.testsAgainstCode.unscannedFiles, ["Sources/Draft.swift", "Sources/Old.swift"])
        XCTAssertEqual(try file("Sources/Old.swift", in: snapshot).symbols, .unread(.patchNotRead))
        XCTAssertNil(try file("Sources/App.swift", in: snapshot).symbols, "it adds no line")
    }

    func testSymbolsAreUnknownPastTheLimitsOnceTheFileChangedOrWhenItDoesntBalance() throws {
        try write("Sources/Gauge.swift", "struct Gauge {\n    var level = 0\n}\n")
        try write("Sources/Lever.swift", "struct Lever {\n    var level = 0\n}\n")
        try commitToMain("gauges")
        let gauge = "struct Gauge {\n    var level = 0\n    var limit = 0\n}\n"
        try write("Sources/Gauge.swift", gauge)
        try write("Sources/Lever.swift", "struct Lever {\n    var level = 0\n    var limit = 0\n}\n")
        // A bare regex reads as code: its brace never closes.
        try write("Sources/Pattern.swift", "struct Pattern {\n    let opening = /\\{/\n}\n")
        let snapshot = try snapshot()
        let read = try file("Sources/Gauge.swift", in: snapshot).symbols
        XCTAssertEqual(read, .read([symbol("limit", 3, in: "Gauge")]))
        XCTAssertEqual(try file("Sources/Pattern.swift", in: snapshot).symbols, .unread(.unbalanced))

        let section = Data(try git(["diff", "--no-color", "-U3", "HEAD", "--", "Sources/Gauge.swift"]).utf8)
        XCTAssertEqual(try BranchReview.readSwift(section, head: Data(gauge.utf8)).get().symbols, [symbol("limit", 3, in: "Gauge")])
        let edited = Data("struct Gauge {\n    var lever = 0\n    var limit = 0\n}\n".utf8)
        guard case .failure(.changedSincePatch) = BranchReview.readSwift(section, head: edited) else {
            return XCTFail("a file edited since its patch")
        }

        var limited = options()
        limited.maxScannedBytes = 70
        let budgeted = try self.snapshot(limited)
        XCTAssertEqual(try file("Sources/Gauge.swift", in: budgeted).symbols, read)
        XCTAssertEqual(try file("Sources/Lever.swift", in: budgeted).symbols, .unread(.tooLarge), "past the files' budget")
        limited.maxScannedFileBytes = 20
        let small = try self.snapshot(limited)
        XCTAssertEqual(try file("Sources/Gauge.swift", in: small).symbols, .unread(.tooLarge))
        XCTAssertEqual(try file("Sources/Pattern.swift", in: small).symbols, .unread(.tooLarge), "its patch is past the limit")
    }

    func testMentionsAreLookedForInTheTestGroupsFilesOnly() throws {
        let tests = [
            "Tests/README.md", "Packages/Core/Tests/Fixture.json", "Sources/Nirux/WidgetTests.swift", "web/app.test.ts",
            "web/app.spec.js", "cmd/main_test.go", "AppTests/Helpers/Mock.swift", "App/AppUITests/Flow.swift"
        ]
        let others = ["Sources/Contests/Score.swift", "Sources/Contests.swift", "scripts/README.md", "docs/Tests.md"]
        for (index, path) in (tests + others).enumerated() { try write(path, "word\(index)\n") }

        let found = BranchReview.mentions(of: Set((tests + others).indices.map { "word\($0)" }), root: repo, options: options())

        XCTAssertEqual(found?.found, Set(tests.indices.map { "word\($0)" }))
        XCTAssertTrue(tests.allSatisfy { BranchReview.PathGroup(path: $0) == .tests })
        XCTAssertTrue(others.allSatisfy { BranchReview.PathGroup(path: $0) != .tests })
    }

    func testMentionsReadSwiftTestsFirstWithinTheLimits() throws {
        try write("Tests/A.json", "render, more\n")
        try write("Tests/BTests.swift", "measure\n")
        try write("Tests/CTests.swift", "1; gaugeX\n")
        try write("Sources/Other.swift", "gauge\n")
        let names: Set<String> = ["measure", "render", "gauge"]
        func mentions(
            maxFiles: Int = 100, maxFileBytes: Int = 100, maxBytes: Int = 1_000, of names: Set<String> = names
        ) -> BranchReview.Mentions? {
            var limited = options()
            limited.maxTestFilesRead = maxFiles
            limited.maxTestFileBytes = maxFileBytes
            limited.maxTestBytesRead = maxBytes
            return BranchReview.mentions(of: names, root: repo, options: limited)
        }

        XCTAssertEqual(mentions()?.found, ["measure", "render"])
        XCTAssertEqual(mentions()?.unread, 0)
        var literal = options()
        literal.environment["GIT_LITERAL_PATHSPECS"] = "1"
        XCTAssertEqual(BranchReview.mentions(of: names, root: repo, options: literal)?.found, ["measure", "render"])
        XCTAssertEqual(mentions(maxFiles: 1)?.found, ["measure"])
        XCTAssertEqual(mentions(maxFiles: 1)?.unread, 2)
        XCTAssertEqual(mentions(maxBytes: 8)?.found, ["measure"])
        XCTAssertEqual(mentions(maxBytes: 8)?.unread, 2)
        // "gaugeX" cut after "gauge" doesn't mention it.
        XCTAssertEqual(mentions(maxFileBytes: 8)?.found, ["measure", "render"])
        XCTAssertEqual(mentions(maxFileBytes: 8)?.unread, 2)
        XCTAssertEqual(mentions(maxFiles: 1, of: ["measure"])?.unread, 0, "nothing left to look for")
        XCTAssertNil(BranchReview.mentions(of: names, root: root, options: options()), "not a repository")
    }

    func testEverySymbolReadsUnmentionedWhenTheTestsCantBeListed() {
        var file = BranchReview.FileChange(path: "Sources/Gauge.swift", status: .added)
        file.additions = 1
        file.symbols = .read([symbol("Gauge", 1, .type)])

        let tests = BranchReview.testsAgainstCode(of: [file], root: root, deleted: [], options: options())

        XCTAssertTrue(tests.testFilesUnlisted)
        XCTAssertEqual(tests.unmentioned, [.init(path: "Sources/Gauge.swift", symbol: symbol("Gauge", 1, .type))])
    }

    /// #57 as merged, when the clone has its commits (a shallow one hasn't;
    /// CI's checkouts fetch the whole history).
    func testPullRequest57ListsTheSymbolsItsTestsDontMention() throws {
        let tests = try snapshotOfMergedPullRequest("fa74b4c", branch: "feat/keep-awake").testsAgainstCode

        XCTAssertEqual(tests.testLines, 578)
        XCTAssertEqual(tests.codeLines, 458)
        XCTAssertEqual(tests.declared, 44)
        // The launch wiring, the real IOKit calls (the tests inject a fake)
        // and the main queue's schedule among them.
        XCTAssertEqual(tests.unmentioned.map { "\(BranchReview.fileName($0.path)):\($0.symbol.name)" }, [
            "PtySession.swift:lastSeenRunningAgent", "NiruxApp+KeepAwake.swift:setUpKeepAwake",
            "NiruxApp+Settings.swift:generalSectionHeight", "NiruxApp.swift:keepAwakeIndicator",
            "KeepAwakeController.swift:IOKitSleepAssertions", "KeepAwakeController.swift:assertionName",
            "MainActorSchedule.swift:MainActorSchedule", "MainActorSchedule.swift:mainQueueSchedule",
            "KeepAwakeIndicator.swift:symbolName", "NiruxShellView+KeepAwake.swift:currentKeepMacAwakeEnabled"
        ])
        XCTAssertEqual(tests.unscannedFiles, [])
        XCTAssertEqual(tests.unreadTestFiles, 0)
    }
}
