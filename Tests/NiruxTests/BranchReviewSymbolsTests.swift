import XCTest
@testable import Nirux

/// The Swift scanner, the added lines and the mentions of "Tests against
/// code" on handwritten sources; `BranchReviewSnapshotTests` runs them on
/// real repositories.
final class BranchReviewSymbolsTests: XCTestCase {
    /// The names `source` declares on `added` lines (all by default).
    private func declared(_ source: String, added: Set<Int>? = nil) -> [String] {
        var scanner = BranchReview.SwiftScanner()
        for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            Array(line.utf8).withUnsafeBytes { scanner.feed($0, collecting: added?.contains(index + 1) ?? true) }
        }
        return scanner.symbols.map(\.name)
    }

    // MARK: - Scanner

    func testDeclarationsInFunctionBodiesAreLeftOut() {
        let source = """
        struct Widget {
            var name: String
            var title: String { name.uppercased() }
            var size = 0 {
                didSet { let old = size }
            }
            func render() -> String {
                let local = 1
                func nested() {}
                struct Inner { let field = 1 }
                return "\\(local)"
            }
            init() { let value = 2 }
            static let make = { () -> Widget in let built = Widget(); return built }
            let sorted = [1].sorted(by: { let a = $0; return a < $1 })
            enum Style { case plain }
        }
        func free() { var counter = 0 }
        let after = 1
        """
        XCTAssertEqual(declared(source), ["Widget", "name", "title", "size", "render", "make", "sorted", "Style", "plain", "free", "after"])
    }

    func testPrivateOrOverridingDeclarationsAndThoseOfPrivateTypesAreLeftOut() {
        let source = """
        public struct Widget {
            private var cache = 0
            fileprivate func helper() {}
            private(set) var count = 0
            public private(set) var total = 0
            @MainActor private static func reset() {}
            private
            func split() {}
            private struct Secret { var key = 0 }
            override func layout() {}
        }
        private extension Widget {
            func hidden() {}
        }
        fileprivate enum Keys { case first }
        extension Widget {
            func shown() {}
        }
        """
        XCTAssertEqual(declared(source), ["Widget", "count", "total", "shown"])
    }

    func testEachNameOfADeclaration() {
        let source = """
        final class Box<T>: NSObject where T: Equatable {
            class func make() -> Box { Box() }
            class override var kind: String { "box" }
            static func == (lhs: Box, rhs: Box) -> Bool { true }
            let (width, (height, depth)): (Int, (Int, Int)) = (1, (2, 3))
            let first = 1, second: Int = 2
            var map: Dictionary<String, Int> = [:], third, fourth: Int
            let pair = f(a, b: 1)
            typealias ID = String
            func `default`() {}
        }
        enum Style: Int {
            case plain = 0, bold
            indirect case nested(Style, depth: Int), `default`
        }
        actor Worker {}
        protocol Drawing: AnyObject { func draw() }
        """
        XCTAssertEqual(declared(source), [
            "Box", "make", "width", "height", "depth", "first", "second", "map", "third", "fourth", "pair",
            "ID", "default", "Style", "plain", "bold", "nested", "default", "Worker", "Drawing", "draw"
        ])
    }

    func testStringsAndCommentsHoldNoBraceNorDeclaration() {
        let source = ##"""
        struct Parser {
            let open = "{ func quoted() {"
            let template = """
                func fake() {
                \(value) } "" \"""
                """
            let raw = #"\(not) "{" "#
            let rawTemplate = #"""
                } \#(count("}")) func alsoFake() {
                """#
            let label = "\(items.map { "\($0) {" }.joined())"
            /* func commented() { /* nested } */ } */
            // func lineComment() {
            let regex = #/[{]/#
            let unterminated = "{
            func real() {}
        }
        let after = 1
        """##
        XCTAssertEqual(
            declared(source), ["Parser", "open", "template", "raw", "rawTemplate", "label", "regex", "unterminated", "real", "after"]
        )
    }

    func testFileLevelStatementsDeclareOnlyWhatStartsAStatement() {
        let source = """
        import struct Foundation.URL
        let config = load()
        if let path = config.path { print(path) }
        guard let home = environment["HOME"],
              let user = environment["USER"] else { fatalError() }
        for case let item? in items {}
        var counter = 0
        actor.run()
        @available(macOS 13, *)
        func modern() {}
        """
        XCTAssertEqual(declared(source), ["config", "counter", "modern"])
    }

    func testOnlyNamesOnCollectedLinesAreListed() {
        let source = """
        struct Widget {
            var name: String
            let (width,
                 height) = (1, 2)
            let first = 1,
                second = 2
        }
        """
        XCTAssertEqual(declared(source, added: [2, 4, 5]), ["name", "height", "first"])
    }

    // MARK: - Added lines

    func testAddedLinesAreCollectedAsRangesOfTheNewSide() throws {
        let patch = """
        diff --git a/a.swift b/a.swift
        index 1111111..2222222 100644
        --- a/a.swift
        +++ b/a.swift
        @@ -1 +1,3 @@
         let a = 1
        +let b = 2\r
        +let c = 3
        @@ -10,3 +11,3 @@
         x
        -y
        +z
         w

        """
        let reading = BranchReview.Patch.Reading(collectsAddedLines: true)
        let section = try XCTUnwrap(BranchReview.Patch.section(Data(patch.utf8), reading: reading))

        var digest = BranchReview.LineDigest()
        for line in ["let b = 2", "let c = 3", "z"] { Array(line.utf8).withUnsafeBytes { digest.add($0) } }
        XCTAssertEqual(section.addedLines, BranchReview.AddedLines(ranges: [2..<4, 12..<13], digest: digest.finalize()))
        XCTAssertNil(try XCTUnwrap(BranchReview.Patch.section(Data(patch.utf8))).addedLines)

        var collector = BranchReview.AddedLineCollector(maxRanges: 1)
        collector.add(1, Data("a".utf8))
        collector.add(2, Data("b".utf8))
        XCTAssertNotNil(collector.finalize())
        collector.add(4, Data("c".utf8))
        XCTAssertNil(collector.finalize(), "a second run of lines is past the limit")
    }

    // MARK: - Mentions

    func testWordSetFindsWholeWordsOnly() {
        var words = BranchReview.WordSet(["render", "Box", "état"])
        words.removeWords(in: Data("renderAll(MyBox) // état".utf8))
        XCTAssertEqual(words.names, ["render", "Box"])
        words.removeWords(in: Data("$render; let box = Box()".utf8))
        XCTAssertEqual(words.names, [])
        XCTAssertTrue(words.isEmpty)
    }
}
