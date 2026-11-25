import XCTest

/// A closure literal handed to an Objective-C API that takes a sendable
/// block without arguments and runs it off the main thread (`Thread`,
/// `OperationQueue`, `RunLoop.current.perform`) can be typed `@MainActor`:
/// once WebKit's main-actor blocks (`WK_SWIFT_UI_ACTOR`) are imported
/// earlier in the same compilation, Swift imports that block type as
/// `@MainActor`. Which comes first depends on how the files are compiled:
/// today's release build is hit, a debug build only when its files fall so.
/// Such a closure traps as it starts (EXC_BREAKPOINT in
/// `swift_task_isCurrentExecutor`): BoundedProcess's stdin writer crashed
/// every release build this way, and TaskSpaceToolsFlowTests' MCP thread a
/// debug test build once StripSwipeShellTests, which uses WebKit, came
/// before it. This test fails on such a literal, in the app or its tests.
final class ThreadClosureGuardTests: XCTestCase {
    private static let advice = """
        type the closure before handing it over, so that it stays nonisolated in a release build: \
        `let body: @Sendable () -> Void = { … }; Thread(block: body).start()`
        """

    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testNoClosureLiteralIsHandedToAThread() throws {
        let literal = try NSRegularExpression(pattern: #"""
            (?<! -> \s) (?<! -> ) \b( Thread (\s*\.\s*(detachNewThread|init))? | addOperation | addExecutionBlock | addBarrierBlock
                | BlockOperation | RunLoop \s*\.\s* current \s*\.\s* perform )
            \s* ( \( \s* (block|withBlock|_)? \s* :? \s* )? \{
            """#, options: .allowCommentsAndWhitespace)
        var offenders: [String] = []
        for folder in ["Sources/Nirux", "Tests/NiruxTests"] {
            let sources = root.appendingPathComponent(folder)
            let paths = try FileManager.default.subpathsOfDirectory(atPath: sources.path)
                .filter { $0.hasSuffix(".swift") && $0 != URL(fileURLWithPath: #filePath).lastPathComponent }
            for path in paths {
                let text = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
                for match in literal.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let range = Range(match.range, in: text) else { continue }
                    offenders.append("\(folder)/\(path):\(text[..<range.lowerBound].components(separatedBy: "\n").count)")
                }
            }
            XCTAssertGreaterThan(paths.count, 100, "found too few sources under \(sources.path)")
        }
        XCTAssertEqual(offenders, [], Self.advice)
    }
}
