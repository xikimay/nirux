import XCTest
@testable import Nirux

/// "Tests against code" on real, temporary git repositories:
/// `BranchReviewSymbolsTests` covers the scanner on handwritten sources.
final class BranchReviewTestsAgainstCodeTests: BranchReviewRepositoryTestCase {
    func testTestsAgainstCodeListsTheSymbolsNoTestMentions() throws {
        try write("Sources/Widget.swift", "struct Widget {\n    var name = \"\"\n}\n")
        try commitToMain("widget")
        try write("Sources/Widget.swift", """
        struct Widget {
            var name = ""
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
        try write("Tests/WidgetTests.swift", "func testRender() { _ = Widget().render() }\n// measureAll\n")
        try commit("work")
        try write("Tests/Draft/GaugeTests.swift", "let gauge = Gauge.shared\n")
        try write("Sources/Use.swift", "let used = Widget().title\n")

        let tests = try snapshot().testsAgainstCode

        XCTAssertEqual(tests.testLines, 3)
        XCTAssertEqual(tests.codeLines, 11, "the generated file is folded")
        XCTAssertEqual(tests.declared, 6)
        XCTAssertEqual(tests.unmentioned, [
            .init(path: "Sources/Use.swift", symbol: .init(name: "used", line: 1)),
            .init(path: "Sources/Widget.swift", symbol: .init(name: "title", line: 3))
        ])
        XCTAssertEqual(tests.unscannedFiles, [])
        XCTAssertEqual(tests.unreadTestFiles, 0)
        XCTAssertFalse(tests.testFilesUnlisted)
    }

    func testSymbolsOfAFileCheckedOutWithCRLFAreRead() throws {
        try write(".gitattributes", "*.swift text eol=crlf\n")
        try commitToMain("attributes")
        try write("Sources/Gauge.swift", "struct Gauge {\r\n    var level = 0\r\n}\r\n")

        let gauge = try file("Sources/Gauge.swift", in: try snapshot())

        XCTAssertEqual(gauge.hunks.first?.lines.map(\.text), ["struct Gauge {", "    var level = 0", "}"])
        XCTAssertEqual(gauge.symbols, .read([.init(name: "Gauge", line: 1), .init(name: "level", line: 2)]))
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
        XCTAssertNil(try file("Sources/App.swift", in: snapshot).symbols, "it adds no line")
    }

    func testMentionsReadSwiftTestsFirstWithinTheLimits() throws {
        try write("Tests/a.json", "render, more\n")
        try write("Tests/BTests.swift", "measure\n")
        try write("Tests/CTests.swift", "// gaugeMeter\n")
        try write("Sources/Other.swift", "gauge\n")
        let names: Set<String> = ["measure", "render", "gauge"]
        func mentions(maxFiles: Int = 100, maxFileBytes: Int = 100, maxBytes: Int = 1_000, of names: Set<String> = names)
            -> (found: Set<String>, unread: Int)? {
            BranchReview.mentions(
                of: names, root: repo, options: options(), maxFiles: maxFiles, maxFileBytes: maxFileBytes, maxBytes: maxBytes
            )
        }

        XCTAssertEqual(mentions()?.found, ["measure", "render"])
        XCTAssertEqual(mentions()?.unread, 0)
        XCTAssertEqual(mentions(maxFiles: 1)?.found, ["measure"])
        XCTAssertEqual(mentions(maxFiles: 1)?.unread, 2)
        XCTAssertEqual(mentions(maxBytes: 8)?.found, ["measure"])
        XCTAssertEqual(mentions(maxBytes: 8)?.unread, 2)
        // "// gaugeMeter" cut after "gauge" doesn't mention it.
        XCTAssertEqual(mentions(maxFileBytes: 8)?.found, ["measure", "render"])
        XCTAssertEqual(mentions(maxFileBytes: 8)?.unread, 2)
        XCTAssertEqual(mentions(maxFiles: 1, of: ["measure"])?.unread, 0, "nothing left to look for")
        XCTAssertNil(BranchReview.mentions(of: names, root: root, options: options()), "not a repository")
    }

    func testEverySymbolReadsUnmentionedWhenTheTestsCantBeListed() {
        var file = BranchReview.FileChange(path: "Sources/Gauge.swift", status: .added)
        file.additions = 1
        file.symbols = .read([.init(name: "Gauge", line: 1)])

        let tests = BranchReview.testsAgainstCode(of: [file], root: root, options: options())

        XCTAssertTrue(tests.testFilesUnlisted)
        XCTAssertEqual(tests.unmentioned, [.init(path: "Sources/Gauge.swift", symbol: .init(name: "Gauge", line: 1))])
    }

    /// #57 as merged, when the clone has its commits (CI's has depth 1).
    func testPullRequest57ListsTheSymbolsItsTestsDontMention() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().path
        guard (try? git(["cat-file", "-e", "fa74b4c^2^{commit}"], at: source)) != nil else {
            throw XCTSkip("#57's commits aren't in this clone.")
        }
        let clone = root + "/c57"
        try git(["clone", "-q", "--shared", "--no-checkout", source, clone], at: root)
        try git(["checkout", "-q", "-b", "feat/keep-awake", "fa74b4c^2"], at: clone)
        try git(["update-ref", "refs/remotes/origin/main", "fa74b4c^1"], at: clone)
        _ = try? git(["symbolic-ref", "-d", "refs/remotes/origin/HEAD"], at: clone)

        let tests = try snapshot(at: clone).testsAgainstCode

        XCTAssertEqual(tests.testLines, 578)
        XCTAssertEqual(tests.codeLines, 458)
        XCTAssertEqual(tests.declared, 45)
        // The launch wiring, the real IOKit calls (the tests inject a fake)
        // and the main queue's schedule among them.
        XCTAssertEqual(tests.unmentioned.map { "\(BranchReview.fileName($0.path)):\($0.symbol.name)" }, [
            "PtySession.swift:lastSeenRunningAgent", "AgentStatusMachine.swift:lastEventAt",
            "AgentStatusMachine.swift:lastReadAt", "NiruxApp+KeepAwake.swift:setUpKeepAwake",
            "NiruxApp+Settings.swift:generalSectionHeight", "NiruxApp.swift:keepAwakeIndicator",
            "KeepAwakeController.swift:IOKitSleepAssertions", "KeepAwakeController.swift:assertionName",
            "MainActorSchedule.swift:MainActorSchedule", "MainActorSchedule.swift:mainQueueSchedule",
            "KeepAwakeIndicator.swift:symbolName", "NiruxShellView+KeepAwake.swift:currentKeepMacAwakeEnabled"
        ])
        XCTAssertEqual(tests.unscannedFiles, [])
        XCTAssertEqual(tests.unreadTestFiles, 0)
    }
}
