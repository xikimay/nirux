import XCTest
@testable import Nirux

final class AgentExcerptTests: XCTestCase {

    func testSingleLineRange() {
        XCTAssertEqual(
            AgentExcerpt.format(path: "a.swift", startLine: 5, endLine: 5, text: "let x = 1"),
            "a.swift:L5\n```\nlet x = 1\n```"
        )
    }

    func testMultiLineRange() {
        XCTAssertEqual(
            AgentExcerpt.format(path: "src/a.swift", startLine: 3, endLine: 4, text: "foo\nbar"),
            "src/a.swift:L3-L4\n```\nfoo\nbar\n```"
        )
    }

    func testTrailingNewlineDoesNotAddEmptyLine() {
        XCTAssertEqual(
            AgentExcerpt.format(path: "a.swift", startLine: 1, endLine: 2, text: "foo\nbar\n"),
            "a.swift:L1-L2\n```\nfoo\nbar\n```"
        )
    }

    func testCRLFNormalizedAndTrailingNewlineStripped() {
        XCTAssertEqual(
            AgentExcerpt.format(path: "a.swift", startLine: 1, endLine: 2, text: "foo\r\nbar\r\n"),
            "a.swift:L1-L2\n```\nfoo\nbar\n```"
        )
    }

    func testEscapeBytesAreStripped() {
        // An embedded ESC[201~ would end the bracketed paste early and turn
        // the rest of the excerpt into live keystrokes.
        let out = AgentExcerpt.format(
            path: "evil.txt", startLine: 1, endLine: 2,
            text: "safe\n\u{1B}[201~rm -rf /"
        )
        XCTAssertFalse(out.contains("\u{1B}"))
        XCTAssertTrue(out.contains("[201~rm -rf /"))
    }

    func testFenceGrowsPastBackticksInBody() {
        let body = "```swift\ncode\n```"
        let out = AgentExcerpt.format(path: "doc.md", startLine: 1, endLine: 3, text: body)
        XCTAssertEqual(out, "doc.md:L1-L3\n````\n```swift\ncode\n```\n````")
    }

    func testTruncationKeepsFirstMaxLinesAndNotes() {
        let total = AgentExcerpt.maxLines + 50
        let text = (1...total).map { "line\($0)" }.joined(separator: "\n")
        let out = AgentExcerpt.format(path: "big.txt", startLine: 1, endLine: total, text: text)

        let lines = out.components(separatedBy: "\n")
        // header + fence + maxLines body lines + fence + note
        XCTAssertEqual(lines.count, AgentExcerpt.maxLines + 4)
        XCTAssertEqual(lines[1 + AgentExcerpt.maxLines], "line\(AgentExcerpt.maxLines)")
        XCTAssertTrue(out.hasSuffix("[excerpt truncated: first \(AgentExcerpt.maxLines) of \(total) lines]"))
        XCTAssertFalse(out.contains("line\(AgentExcerpt.maxLines + 1)\n"))
    }

    func testExactlyMaxLinesIsNotTruncated() {
        let text = (1...AgentExcerpt.maxLines).map { "line\($0)" }.joined(separator: "\n")
        let out = AgentExcerpt.format(path: "a.txt", startLine: 1, endLine: AgentExcerpt.maxLines, text: text)
        XCTAssertFalse(out.contains("truncated"))
        XCTAssertTrue(out.contains("line\(AgentExcerpt.maxLines)\n"))
    }

    func testCharacterCapCatchesGiantSingleLine() {
        let text = String(repeating: "x", count: AgentExcerpt.maxCharacters + 100)
        let out = AgentExcerpt.format(path: "min.js", startLine: 1, endLine: 1, text: text)
        XCTAssertLessThan(out.count, AgentExcerpt.maxCharacters + 200)
        XCTAssertTrue(out.hasSuffix("[excerpt truncated at \(AgentExcerpt.maxCharacters) characters]"))
    }
}
