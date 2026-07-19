import XCTest
@testable import Nirux

final class AgentExcerptTests: XCTestCase {

    func testSingleLineRange() {
        XCTAssertEqual(
            AgentExcerpt.format(path: "a.swift", startLine: 5, endLine: 5, text: "let x = 1"),
            "a.swift:L5\n```\nlet x = 1\n```\n"
        )
    }

    func testMultiLineRange() {
        XCTAssertEqual(
            AgentExcerpt.format(path: "src/a.swift", startLine: 3, endLine: 4, text: "foo\nbar"),
            "src/a.swift:L3-L4\n```\nfoo\nbar\n```\n"
        )
    }

    func testTrailingNewlineDoesNotAddEmptyLine() {
        XCTAssertEqual(
            AgentExcerpt.format(path: "a.swift", startLine: 1, endLine: 2, text: "foo\nbar\n"),
            "a.swift:L1-L2\n```\nfoo\nbar\n```\n"
        )
    }

    func testFenceGrowsPastBackticksInBody() {
        let body = "```swift\ncode\n```"
        let out = AgentExcerpt.format(path: "doc.md", startLine: 1, endLine: 3, text: body)
        XCTAssertEqual(out, "doc.md:L1-L3\n````\n```swift\ncode\n```\n````\n")
    }

    func testTruncationKeepsFirstMaxLinesAndNotes() {
        let total = AgentExcerpt.maxLines + 50
        let text = (1...total).map { "line\($0)" }.joined(separator: "\n")
        let out = AgentExcerpt.format(path: "big.txt", startLine: 1, endLine: total, text: text)

        let lines = out.components(separatedBy: "\n")
        // header + fence + maxLines body lines + fence + note + trailing ""
        XCTAssertEqual(lines.count, AgentExcerpt.maxLines + 5)
        XCTAssertEqual(lines[1 + AgentExcerpt.maxLines], "line\(AgentExcerpt.maxLines)")
        XCTAssertTrue(out.hasSuffix("[excerpt truncated: first \(AgentExcerpt.maxLines) of \(total) lines]\n"))
        XCTAssertFalse(out.contains("line\(AgentExcerpt.maxLines + 1)\n"))
    }

    func testExactlyMaxLinesIsNotTruncated() {
        let text = (1...AgentExcerpt.maxLines).map { "line\($0)" }.joined(separator: "\n")
        let out = AgentExcerpt.format(path: "a.txt", startLine: 1, endLine: AgentExcerpt.maxLines, text: text)
        XCTAssertFalse(out.contains("truncated"))
        XCTAssertTrue(out.contains("line\(AgentExcerpt.maxLines)\n"))
    }
}
