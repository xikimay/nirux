import XCTest
@testable import Nirux

/// The Swift scanner and the mentions of "Tests against code" on
/// handwritten sources; `BranchReviewTestsAgainstCodeTests` and
/// `BranchReviewSwiftReadingTests` run them on real repositories.
final class BranchReviewSymbolsTests: XCTestCase {
    private func scanned(_ source: String, added: Set<Int>? = nil, words: Set<String>? = nil) -> BranchReview.SwiftScanner {
        var scanner = BranchReview.SwiftScanner()
        scanner.words = words.map(BranchReview.WordSet.init)
        for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            Array(line.utf8).withUnsafeBytes { scanner.feed($0, collecting: added?.contains(index + 1) ?? true) }
        }
        return scanner
    }

    /// The names `source` declares on `added` lines (all by default).
    private func declared(_ source: String, added: Set<Int>? = nil) -> [String] {
        scanned(source, added: added).symbols.map(\.name)
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
            override func layout() {}
            private(set) var count = 0
            public private(set) var total = 0
            @MainActor private static func reset() {}
            private
            func split() {}
            private struct Secret { var key = 0 }
            nonisolated(unsafe) static var shared = 0
        }
        private extension Widget {
            func hidden() {}
            struct Hidden { let deep = 0 }
        }
        fileprivate enum Keys { case first }
        extension Widget {
            func shown() {}
            @objc func handle() {}
            @IBAction func tap(_ sender: Any) {}
            @objc dynamic var level = 0
        }
        extension Secret {
            func leak() {}
        }
        extension Secret.Inner {
            func deeperLeak() {}
        }
        fileprivate struct Secret { struct Inner {} }
        struct Holder { private struct Kept {} }
        extension Holder.Kept {
            func keptLeak() {}
        }
        private extension Holder { struct Nested {} }
        extension Holder.Nested {
            func nestedLeak() {}
        }
        """
        XCTAssertEqual(declared(source), ["Widget", "count", "total", "shared", "shown", "level", "Holder"])
    }

    func testEachNameOfADeclaration() {
        let source = """
        @MainActor final class Box<T>: NSObject where T: Equatable {
            class func make() -> Box { Box() }
            class override var kind: String { "box" }
            static func == (lhs: Box, rhs: Box) -> Bool { true }
            @available(*, deprecated) @Argument(help: .init("size")) var size = 0
            let (width, (height, depth)): (Int, (Int, Int)) = (1, (2, 3))
            let first = 1, second = 2
            var map: Dictionary<String, Int> = [:], third, fourth: Int
            let pair = f(a, b: 1)
            let handler = make({ $0 }, label: "x")
            let made = { 1 }(), after = 2
            let wrapped = f(
                1
            ), alsoWrapped = 2
            @SwiftUI.State var count = 0
            @Clamped<Array<Int>> var limit = 0
            @Mapped<(Int) -> Int> var mapping = 0
            func `does something`() {}
            typealias ID = String
            func `default`() {}
        }
        enum Style: Int {
            case plain = 0, bold
            indirect case nested(Style, depth: Int), `default`
            case withHandler(run: () -> Void = {}), last
        }
        actor Worker {}
        actor `open` {}
        protocol Drawing: AnyObject { func draw() }
        """
        XCTAssertEqual(declared(source), [
            "Box", "make", "size", "width", "height", "depth", "first", "second", "map", "third", "fourth", "pair",
            "handler", "made", "after", "wrapped", "alsoWrapped", "count", "limit", "mapping", "ID", "default", "Style",
            "plain", "bold", "nested", "default", "withHandler", "last", "Worker", "open", "Drawing", "draw"
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
            let rawBrace = #" "x{ "#
            let rawTemplate = #"""
                } \#(count("}")) func alsoFake() {
                \a( {
                """#
            let label = "\(items.map { "\($0) {" }.joined())"
            let nested = "\(f(g(1), "{"))"
            let joined = "\(join(1, with: 2))"
            /* func commented() /* nested */ { */
            // func lineComment() {
            let regex = #/[{]/#
            let escaped = #/\/#{/#
            let unterminated = "{
            func real() {}
        }
        let after = 1
        """##
        XCTAssertEqual(
            declared(source), [
                "Parser", "open", "template", "raw", "rawBrace", "rawTemplate", "label", "nested", "joined", "regex", "escaped",
                "unterminated", "real", "after"
            ]
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
        guard
            let directory = environment["PWD"]
        else { fatalError() }
        var counter = 0
        let _ = load()
        var x$y = 1
        `extension`.run()
        if ready { let inner = 1 }
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

    func testSymbolsSayWhatTheyAreAndWhereTheyAre() {
        let source = """
        struct Outer {
            enum Inner { case deep }
            typealias ID = Int
        }
        extension Outer.Inner {
            func describe() {}
        }
        let top = 1
        """
        let symbols = scanned(source).symbols
        XCTAssertEqual(symbols, [
            .init(name: "Outer", line: 1, kind: .type, container: nil),
            .init(name: "Inner", line: 2, kind: .type, container: "Outer"),
            .init(name: "deep", line: 2, kind: .enumCase, container: "Outer.Inner"),
            .init(name: "ID", line: 3, kind: .typeAlias, container: "Outer"),
            .init(name: "describe", line: 6, kind: .function, container: "Outer.Inner"),
            .init(name: "top", line: 8, kind: .variable, container: nil)
        ])
    }

    func testEachLineSaysWhereItStartsAndWhatItsCodeIs() {
        let source = """
        @main
        struct App {
            static func main() {
                let help = \"\"\"
                    usage: app // not a comment
                    \"\"\"
                run() // Telegram
                /* block
                   Telegram */ go()
            }
            func handle(done: () -> Void = { }) {
                done()
            }
        }
        """
        var scanner = BranchReview.SwiftScanner()
        var lines: [(inString: Bool, functions: [String], code: String)] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let inString = scanner.stringText != nil
            let functions = scanner.enclosingFunctions.map { $0.name + ($0.isEntryPoint ? " (entry point)" : "") }
            Array(line.utf8).withUnsafeBytes { scanner.feed($0, collecting: false, capturingCode: true) }
            lines.append((inString, functions, String(decoding: scanner.code, as: UTF8.self)))
        }

        let main = "main (entry point)"
        XCTAssertEqual(lines.map(\.inString), [false, false, false, false, true, true, false, false, false, false, false, false, false, false])
        XCTAssertEqual(lines.map(\.functions), [
            [], [], [], [main], [main], [main], [main], [main], [main], [main], [], ["handle"], ["handle"], []
        ])
        XCTAssertEqual(lines[4].code, "            usage: app // not a comment")
        XCTAssertEqual(lines[6].code, "        run() " + String(repeating: " ", count: "// Telegram".count))
        XCTAssertEqual(lines[7].code, "        " + String(repeating: " ", count: 8))
        XCTAssertEqual(lines[8].code, String(repeating: " ", count: 22) + " go()")
        XCTAssertEqual(scanner.stringIndents, [1: Data(String(repeating: " ", count: 12).utf8)], "the closing delimiter's")
    }

    func testMainOfAnAtMainTypeIsTheEntryPointWhereverItIsDeclared() {
        func functions(at line: Int, of source: [String]) -> [BranchReview.SwiftScanner.Function] {
            var scanner = BranchReview.SwiftScanner()
            for text in source.prefix(line) { Array(text.utf8).withUnsafeBytes { scanner.feed($0, collecting: false) } }
            return scanner.enclosingFunctions
        }
        let main = [BranchReview.SwiftScanner.Function(name: "main", isEntryPoint: true)]
        XCTAssertEqual(functions(at: 3, of: ["@main", "final class App {", "    class func main() {", "        go()"]), main)
        XCTAssertEqual(functions(at: 4, of: ["@main", "struct App {}", "extension App {", "    static func main() {", "        go()"]), main)
        // Its generic parameters wrap.
        XCTAssertEqual(
            functions(at: 2, of: ["func applicationShouldTerminate<", "    T>(_ sender: T) -> Bool {", "    go()"]),
            [BranchReview.SwiftScanner.Function(name: "applicationShouldTerminate", isEntryPoint: false)]
        )
    }

    func testAStringTheLineEndCutsLeavesNoCommentOpen() {
        var scanner = BranchReview.SwiftScanner()
        for line in ["let s = \"\\( /* x", "let queue = DispatchQueue.main"] {
            Array(line.utf8).withUnsafeBytes { scanner.feed($0, collecting: false, capturingCode: true) }
        }
        XCTAssertEqual(String(decoding: scanner.code, as: UTF8.self), "let queue = DispatchQueue.main")
    }

    func testByteOrderMarkIsNotAnIdentifier() {
        XCTAssertEqual(declared("\u{FEFF}struct Marked {\n    var level = 0\n}"), ["Marked", "level"])
    }

    func testSourceThatLeavesABraceStringOrCommentOpenIsUnbalanced() {
        XCTAssertTrue(scanned("struct A {\n    let s = \"{\"\n}").isBalanced)
        XCTAssertFalse(scanned("struct A {\n}\n}").isBalanced, "a brace closed with none open")
        XCTAssertFalse(scanned("struct A {\n    let s = 1").isBalanced)
        XCTAssertFalse(scanned("let s = \"\"\"\n    text").isBalanced)
        XCTAssertFalse(scanned("/* open\nlet s = 1").isBalanced)
    }

    func testWordsAreFoundInCodeAndInterpolationsOnly() {
        let source = "// alpha\nlet text = \"beta \\(gamma) `delta`\"\n/* epsilon */ zeta(`eta`, model.$theta, kappa$lambda)"
        let names: Set<String> = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "kappa", "lambda"]
        XCTAssertEqual(scanned(source, words: names).words?.names, ["alpha", "beta", "delta", "epsilon", "kappa", "lambda"])
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
