import JavaScriptCore
import XCTest

/// The editor's diff hunks (`EditorAssets/diff-text.js`) under
/// JavaScriptCore, as git writes them from two texts.
final class DiffTextScriptTests: XCTestCase {
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Nirux/EditorAssets/diff-text.js")

    private var context: JSContext!

    override func setUpWithError() throws {
        context = try XCTUnwrap(JSContext())
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
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

    /// Lines end at LF, as git and a checkpoint split them: a CR is part of
    /// its line.
    func testLinesEndAtLF() throws {
        XCTAssertEqual(try call("hunks", "a\rb\r", "a\rc\r"), #"[{"oldStart":1,"newStart":1,"lines":["#
            + #"{"kind":"removed","text":"a\rb\r"},{"kind":"noNewlineMarker"},{"kind":"added","text":"a\rc\r"},{"kind":"noNewlineMarker"}]}]"#)
        XCTAssertEqual(try call("hunks", "a\r\nb\n", "a\nb\n"), #"[{"oldStart":1,"newStart":1,"lines":["#
            + #"{"kind":"removed","text":"a\r"},{"kind":"added","text":"a"},{"kind":"context","text":"b"}]}]"#)
    }

    /// The Monaco diff's marks, redone at each keystroke, give up past 2M
    /// steps (about 50 changes in a 20,000-line file): 100 scattered changes
    /// read as replaced between the first and last, at once.
    func testMarksAtEachKeystrokeStayWithinTheirBound() throws {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let runs = context.evaluateScript("""
            (function () {
              const a = Array.from({ length: 20000 }, (_, i) => "line " + i);
              const b = a.map((line, i) => (i % 200 === 100 ? "changed " + i : line));
              return DiffText.lineScript(a, b, DiffText.work.typing).map((run) => run.type + ":" + run.count).join(",");
            })()
            """)?.toString()
        let seconds = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9
        XCTAssertEqual(runs, "equal:100,delete:19801,insert:19801,equal:99")
        XCTAssertLessThan(seconds, 0.25)
    }
}
