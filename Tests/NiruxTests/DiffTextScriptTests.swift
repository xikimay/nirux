import JavaScriptCore
import XCTest

/// The editor's diff hunks (`EditorAssets/diff-text.js`) under
/// JavaScriptCore, as git writes them from two texts.
class DiffTextScriptTests: XCTestCase {
    /// DO NOT MERGE: the revert this class runs with (`globalThis.__zz`).
    class var mutant: String? { ProcessInfo.processInfo.environment["ZZ_MUTANT"] }
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Nirux/EditorAssets/diff-text.js")

    private var context: JSContext!

    override func setUpWithError() throws {
        context = try XCTUnwrap(JSContext())
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript("globalThis.__zz = " + (Self.mutant.map { "'\($0)'" } ?? "null"))
        context.evaluateScript(try String(contentsOf: Self.script, encoding: .utf8))
        XCTAssertNil(exception)
    }

    /// `DiffText.<function>(arguments)` as JSON.
    private func call(_ function: String, _ arguments: Any...) throws -> String {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: arguments, options: [.fragmentsAllowed]), as: UTF8.self)
        return try XCTUnwrap(context.evaluateScript("JSON.stringify(DiffText.\(function)(...\(json)))")?.toString())
    }

    /// Three unchanged lines around a change, as git keeps them; changes
    /// further apart make hunks of their own.
    func testHunksKeepThreeLinesOfContext() throws {
        XCTAssertEqual(try call("hunks", "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n", "a\nb\nc\nd\nE\nf\ng\nh\ni\nj\n"), #"[{"oldStart":2,"newStart":2,"lines":["#
            + #"{"kind":"context","text":"b"},{"kind":"context","text":"c"},{"kind":"context","text":"d"},"#
            + #"{"kind":"removed","text":"e"},{"kind":"added","text":"E"},"#
            + #"{"kind":"context","text":"f"},{"kind":"context","text":"g"},{"kind":"context","text":"h"}]}]"#)
        let starts = context.evaluateScript(#"JSON.stringify(DiffText.hunks("1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n", "1\nX\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\nY\n15\n").map((h) => [h.oldStart, h.newStart, h.lines.length]))"#)?.toString()
        XCTAssertEqual(starts, "[[1,1,6],[11,11,6]]")
    }

    /// A side with no lines starts before them, as git numbers it; a last
    /// line gaining its newline is a change with git's marker; equal texts
    /// have no hunk.
    func testHunksAtTheEdgesOfAFile() throws {
        XCTAssertEqual(try call("hunks", "", "x\n"), #"[{"oldStart":0,"newStart":1,"lines":[{"kind":"added","text":"x"}]}]"#)
        XCTAssertEqual(try call("hunks", "x\n", ""), #"[{"oldStart":1,"newStart":0,"lines":[{"kind":"removed","text":"x"}]}]"#)
        XCTAssertEqual(try call("hunks", "a\nb", "a\nb\n"), #"[{"oldStart":1,"newStart":1,"lines":["#
            + #"{"kind":"context","text":"a"},{"kind":"removed","text":"b"},{"kind":"noNewlineMarker"},{"kind":"added","text":"b"}]}]"#)
        XCTAssertEqual(try call("hunks", "same\n", "same\n"), "[]")
    }

    /// Each block of changes as its deletions, then its insertions.
    func testLineScriptPutsDeletionsBeforeInsertions() throws {
        XCTAssertEqual(try call("lineScript", ["a", "b", "c"], ["a", "x", "c", "d"]),
            #"[{"type":"equal","count":1},{"type":"delete","count":1},{"type":"insert","count":1},{"type":"equal","count":1},{"type":"insert","count":1}]"#)
    }

    /// The fewest changes, as git finds them: two edits far apart in a
    /// medium file stay two hunks. Past a bound (thousands of changes), a
    /// file's changed middle reads as replaced whole, in no more than a
    /// second.
    func testFewestChangesWithinABound() throws {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let counts = context.evaluateScript("""
            (function () {
              const changed = (count, at) => {
                const lines = Array.from({ length: count }, (_, i) => "line " + i);
                return [lines.join("\\n"), lines.map((line, i) => at(i) ? "changed " + i : line).join("\\n")];
              };
              return [
                changed(2000, (i) => i === 5 || i === 1994),
                changed(4000, (i) => i % 100 === 50),
                changed(30000, (i) => i % 10 === 5)
              ].map(([a, b]) => DiffText.hunks(a, b).length).join(",");
            })()
            """)?.toString()
        XCTAssertEqual(counts, "2,40,1")
        XCTAssertLessThan(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9, 1)
    }

    /// Lines end at CRLF, CR or LF, and which one doesn't count: the buffer
    /// keeps one per file, git's eol settings convert them.
    func testLinesEndAtAnyLineBreak() throws {
        XCTAssertEqual(try call("hunks", "a\rb\r", "a\rc\r"), #"[{"oldStart":1,"newStart":1,"lines":["#
            + #"{"kind":"context","text":"a"},{"kind":"removed","text":"b"},{"kind":"added","text":"c"}]}]"#)
        XCTAssertEqual(try call("hunks", "a\r\nb\r\n", "a\nc\n"), #"[{"oldStart":1,"newStart":1,"lines":["#
            + #"{"kind":"context","text":"a"},{"kind":"removed","text":"b"},{"kind":"added","text":"c"}]}]"#)
        XCTAssertEqual(try call("hunks", "a\r\nb\r\n", "a\nb\n"), "[]")
    }
}

final class ZZ_t1: DiffTextScriptTests { override class var mutant: String? { "t1" } }
final class ZZ_t2: DiffTextScriptTests { override class var mutant: String? { "t2" } }
final class ZZ_t3: DiffTextScriptTests { override class var mutant: String? { "t3" } }
final class ZZ_n1: DiffTextScriptTests { override class var mutant: String? { "n1" } }
final class ZZ_n2: DiffTextScriptTests { override class var mutant: String? { "n2" } }
final class ZZ_n3: DiffTextScriptTests { override class var mutant: String? { "n3" } }
final class ZZ_e1: DiffTextScriptTests { override class var mutant: String? { "e1" } }
