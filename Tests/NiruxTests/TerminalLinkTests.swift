import XCTest
@testable import Nirux

final class TerminalLinkTests: XCTestCase {
    func testWebLinkRequiresAHost() {
        XCTAssertEqual(
            TerminalLinkTarget.parse("https://github.com/openai/codex"),
            .web(URL(string: "https://github.com/openai/codex")!)
        )
        XCTAssertNil(TerminalLinkTarget.parse("https://"))
    }

    func testFileAndExternalLinksAreClassified() {
        XCTAssertEqual(
            TerminalLinkTarget.parse("file:///tmp/a.swift#L12"),
            .file(URL(string: "file:///tmp/a.swift#L12")!)
        )
        XCTAssertEqual(
            TerminalLinkTarget.parse("mailto:hello@example.com"),
            .external(URL(string: "mailto:hello@example.com")!)
        )
    }

    func testUnsafeOrMalformedLinksAreRejected() {
        XCTAssertNil(TerminalLinkTarget.parse("javascript:alert(1)"))
        XCTAssertNil(TerminalLinkTarget.parse("data:text/plain,hello"))
        XCTAssertNil(TerminalLinkTarget.parse("https://example.com/\nnext"))
        XCTAssertNil(TerminalLinkTarget.parse("   "))
    }
}
