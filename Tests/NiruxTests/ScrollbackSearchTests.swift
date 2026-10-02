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

    func testAMatchResumesTheSearchAfterItself() {
        XCTAssertEqual(search("aa", "aaaaa").total, 2)
    }

    func testTheExcerptHighlightsTheMatchInALongLine() throws {
        let lead = String(repeating: "x", count: 100)
        let line = "    👍 " + lead + "needle" + String(repeating: "y", count: 300)
        let match = try XCTUnwrap(search("NEEDLE", line).matches.first)
        XCTAssertTrue(match.excerpt.hasPrefix("…" + String(repeating: "x", count: ScrollbackSearch.excerptLead) + "needle"))
        XCTAssertTrue(match.excerpt.hasSuffix("y…"))
        XCTAssertEqual(match.excerpt.count, ScrollbackSearch.excerptLength)
        XCTAssertEqual((match.excerpt as NSString).substring(with: match.highlight), "needle")

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
