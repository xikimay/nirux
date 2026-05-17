import XCTest
@testable import Nirux

final class EditorSearchPanelTests: XCTestCase {
    func testParseRipgrepJSONMatchLine() throws {
        let line = #"{"type":"match","data":{"path":{"text":"./Sources/App.swift"},"lines":{"text":"let url = \"https://example.com\"\n"},"line_number":42,"absolute_offset":10,"submatches":[{"match":{"text":"url"},"start":4,"end":7}]}}"#

        let result = try XCTUnwrap(EditorSearchPanel.parseRipgrepJSONLine(line))

        XCTAssertEqual(result.relativePath, "Sources/App.swift")
        XCTAssertEqual(result.line, 42)
        XCTAssertEqual(result.column, 5)
        XCTAssertEqual(result.text, "let url = \"https://example.com\"\n")
    }

    func testParseRipgrepJSONIgnoresNonMatchMessages() {
        let line = #"{"type":"summary","data":{"elapsed_total":{"secs":0,"nanos":1},"stats":{"matches":0}}}"#

        XCTAssertNil(EditorSearchPanel.parseRipgrepJSONLine(line))
    }

    func testParseClassicLineStripsDotSlashAndKeepsColonInText() throws {
        let result = try XCTUnwrap(EditorSearchPanel.parseLine("./Sources/App.swift:7:12:http://example.com"))

        XCTAssertEqual(result.relativePath, "Sources/App.swift")
        XCTAssertEqual(result.line, 7)
        XCTAssertEqual(result.column, 12)
        XCTAssertEqual(result.text, "http://example.com")
    }
}
