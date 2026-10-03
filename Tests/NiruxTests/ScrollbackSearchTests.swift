import XCTest
@testable import Nirux

/// Search Everywhere's matching must agree with Ghostty's search: a pick
/// selects its match by counting Ghostty's matches from the newest.
final class ScrollbackSearchTests: XCTestCase {
    private func search(_ needle: String, _ text: String, limit: Int = 50) -> ScrollbackSearch.Result {
        ScrollbackSearch.search(needle, in: text, limit: limit)
    }

    func testMatchesAreListedNewestFirstAndCountedFromTheBottom() {
        let result = search("error", "boot\nError: disk\nok\nan ERROR again\nerror")
        XCTAssertEqual(result.total, 3)
        XCTAssertEqual(result.matches.map(\.line), [5, 4, 2])
        XCTAssertEqual(result.matches.map(\.fromBottom), [0, 1, 2])
        XCTAssertEqual(result.matches.map(\.excerpt), ["error", "an ERROR again", "Error: disk"])
    }

    /// Ghostty folds ASCII letters only (std.ascii.indexOfIgnoreCase).
    func testOnlyASCIILettersMatchInEitherCase() {
        XCTAssertEqual(search("CAFÉ", "café\nCAFÉ\nCafÉ").matches.map(\.line), [3, 2])
    }

    func testTheLimitKeepsTheNewestMatchesAndTheTotalCountsThemAll() {
        let text = (1...10).map { "hit \($0)" }.joined(separator: "\n")
        let result = search("hit", text, limit: 3)
        XCTAssertEqual(result.total, 10)
        XCTAssertEqual(result.matches.map(\.line), [10, 9, 8])
        XCTAssertEqual(result.matches.map(\.fromBottom), [0, 1, 2])
    }

    /// Ghostty trims each row: a needle may cross a hard line break, but
    /// never through the spaces a row ends with.
    func testRowsAreTrimmedOfTrailingSpaces() {
        let text = "make   \nbuild ok    \n  indented"
        XCTAssertEqual(search("make\nbuild", text).matches.map(\.line), [1])
        XCTAssertEqual(search("ok ", text).total, 0)
        XCTAssertEqual(search("  indented", text).matches.map(\.line), [3])
    }

    /// Ghostty resumes one byte after a match's start: matches overlap.
    func testMatchesOverlapAsInGhostty() {
        XCTAssertEqual(search("aa", "aaaaa").total, 4)
        XCTAssertEqual(search("──", "─────").total, 4)
    }

    /// A pick finds its match again after output was printed below it and
    /// the scrollback limit dropped lines, with matches, above it.
    func testAPickFindsItsMatchAgainInTextThatChanged() throws {
        let before = (1...6).map { "error \($0)" }.joined(separator: "\n")
        let picked = try XCTUnwrap(search("error", before).matches.first { $0.excerpt == "error 3" })
        XCTAssertEqual(picked.fromBottom, 3)
        let after = (3...9).map { "error \($0)" }.joined(separator: "\n")
        let place = ScrollbackSearch.relocate(context: picked.context, fromBottom: picked.fromBottom, of: "error", in: after)
        XCTAssertEqual(place.fromBottom, 6)
        XCTAssertEqual(place.total, 7)

        // Identical lines: the one at its old place, matches only move up.
        let same = try XCTUnwrap(search("error", "error\nerror\nerror").matches.first { $0.fromBottom == 1 })
        XCTAssertEqual(ScrollbackSearch.relocate(context: same.context, fromBottom: 1, of: "error", in: "error\nerror\nerror").fromBottom, 1)
        // Gone: its old place.
        XCTAssertEqual(ScrollbackSearch.relocate(context: picked.context, fromBottom: 3, of: "error", in: "error 7\nerror 8").fromBottom, 1)
    }

    func testTheExcerptHighlightsTheMatchInALongLine() throws {
        // Longer than the excerpt, then longer than the bytes read for it.
        for (before, after) in [(100, 300), (100_000, 300_000)] {
            let line = "    👍 " + String(repeating: "x", count: before) + "needle" + String(repeating: "é", count: after)
            let match = try XCTUnwrap(search("NEEDLE", line).matches.first)
            XCTAssertTrue(match.excerpt.hasPrefix("…" + String(repeating: "x", count: ScrollbackSearch.excerptLead) + "needle"))
            XCTAssertTrue(match.excerpt.hasSuffix("éé…"))
            XCTAssertEqual(match.excerpt.count, ScrollbackSearch.excerptLength)
            XCTAssertEqual((match.excerpt as NSString).substring(with: match.highlight), "needle")
        }

        // A cut never splits a character, however many bytes it holds.
        let toned = "👍🏽"
        let line = String(repeating: toned, count: 1_000) + "needle" + String(repeating: toned, count: 1_000)
        let cut = try XCTUnwrap(search("needle", line).matches.first)
        XCTAssertTrue(cut.excerpt.hasPrefix("…" + toned))
        XCTAssertTrue(cut.excerpt.hasSuffix(toned + "…"))
        XCTAssertEqual(Set(cut.excerpt.replacingOccurrences(of: "needle", with: "")), ["…", Character(toned)])

        // UTF-16 offsets, leading spaces dropped.
        let short = try XCTUnwrap(search("go", "   👍 go").matches.first)
        XCTAssertEqual(short.excerpt, "👍 go")
        XCTAssertEqual(short.highlight, NSRange(location: 3, length: 2))
    }

    func testAMatchAcrossLinesHighlightsItsFirstLine() throws {
        let match = try XCTUnwrap(search("b\nc", "ab\ncd").matches.first)
        XCTAssertEqual(match.line, 1)
        XCTAssertEqual(match.excerpt, "ab")
        XCTAssertEqual((match.excerpt as NSString).substring(with: match.highlight), "b")
    }
}
