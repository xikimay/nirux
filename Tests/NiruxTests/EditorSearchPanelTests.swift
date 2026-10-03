import XCTest
@testable import Nirux

final class EditorSearchPanelTests: XCTestCase {
    func testParseRipgrepJSONMatchLine() throws {
        let line = #"{"type":"match","data":{"path":{"text":"./Sources/App.swift"},"lines":{"text":"let url = \"https://example.com\"\n"},"line_number":42,"absolute_offset":10,"# +
            #""submatches":[{"match":{"text":"url"},"start":4,"end":7}]}}"#

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

    /// The search reads until its output closes, not until it exits: here
    /// the exit comes first every time, as it sometimes did on CI, where
    /// stopping then left `PaletteCommandFlowTests.testEditorCommands`
    /// without a single result.
    func testLinesPrintedAfterTheProcessExitsStillArrive() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The subshell prints once `sh` has exited.
        process.arguments = ["-c", "(sleep 0.3; echo late) & echo early"]
        let late = expectation(description: "the line printed after the exit")
        try EditorSearchPanel.run(process) { line in
            if line == "late" { late.fulfill() }
        }
        process.waitUntilExit()
        wait(for: [late], timeout: 10)
    }
}
