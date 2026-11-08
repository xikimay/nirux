import XCTest
@testable import Nirux

/// Tests for URLHistory.normalize — the pure string-handling path that
/// decides whether a user's typed entry is a URL (and how to normalize it)
/// or a search query (and should be ignored). The file-backed `add`/`load`/
/// `save` pipeline is deliberately not exercised here because it writes to
/// ~/Library/Application Support/nirux.
final class URLHistoryTests: XCTestCase {

    // MARK: - URLs with an explicit scheme are preserved verbatim

    func testHttpsURLPassesThrough() {
        XCTAssertEqual(URLHistory.normalize("https://example.com"), "https://example.com")
    }

    // MARK: - Bare hosts get https:// prepended

    func testBareDomainGetsHttps() {
        XCTAssertEqual(URLHistory.normalize("example.com"), "https://example.com")
    }

    // MARK: - localhost is a special case (no dot but still a host)

    func testLocalhostGetsHttps() {
        XCTAssertEqual(URLHistory.normalize("localhost"), "https://localhost")
        XCTAssertEqual(URLHistory.normalize("localhost:8080"), "https://localhost:8080")
    }

    // MARK: - Search queries return nil

    func testBareWordReturnsNil() {
        XCTAssertNil(URLHistory.normalize("swift"))
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(URLHistory.normalize(""))
    }

    // MARK: - Edge cases

    func testStringContainingDotIsTreatedAsHost() {
        // The heuristic is blunt: any dot means "looks like a domain".
        // Callers are expected to preflight with their own validation
        // before surfacing the entry to the user.
        XCTAssertEqual(URLHistory.normalize("version 1.0"), "https://version 1.0")
    }
}
