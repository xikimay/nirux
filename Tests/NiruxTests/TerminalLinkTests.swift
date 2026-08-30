import XCTest
import GhosttyTerminal
@testable import Nirux

final class TerminalLinkTests: XCTestCase {
    @MainActor
    func testGhosttyLinkRoutingIsDeferredUntilAfterItsMouseCallback() async {
        let column = ColumnState(url: "about:blank")
        let routed = expectation(description: "web link routed")
        var openedURL: String?
        column.onOpenURL = { url in
            openedURL = url
            routed.fulfill()
        }

        column.terminalDidRequestOpenURL(
            "https://github.com/openai/codex",
            kind: .text
        )

        XCTAssertNil(openedURL, "Routing must not mutate columns inside Ghostty's mouse callback")
        await fulfillment(of: [routed], timeout: 1)
        XCTAssertEqual(openedURL, "https://github.com/openai/codex")
    }

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
