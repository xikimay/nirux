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

    func testHttpURLPassesThrough() {
        XCTAssertEqual(URLHistory.normalize("http://example.com/path"), "http://example.com/path")
    }

    func testFileURLPassesThrough() {
        XCTAssertEqual(URLHistory.normalize("file:///tmp/foo.html"), "file:///tmp/foo.html")
    }

    func testCustomSchemePassesThrough() {
        XCTAssertEqual(URLHistory.normalize("nirux://new-worktree?branch=feat"),
                       "nirux://new-worktree?branch=feat")
    }

    // MARK: - Bare hosts get https:// prepended

    func testBareDomainGetsHttps() {
        XCTAssertEqual(URLHistory.normalize("example.com"), "https://example.com")
    }

    func testBareDomainWithPathGetsHttps() {
        XCTAssertEqual(URLHistory.normalize("example.com/about"),
                       "https://example.com/about")
    }

    func testSubdomainDotBoundaryStillMatches() {
        XCTAssertEqual(URLHistory.normalize("api.github.com"),
                       "https://api.github.com")
    }

    // MARK: - localhost is a special case (no dot but still a host)

    func testLocalhostBareGetsHttps() {
        XCTAssertEqual(URLHistory.normalize("localhost"), "https://localhost")
    }

    func testLocalhostWithPortGetsHttps() {
        XCTAssertEqual(URLHistory.normalize("localhost:8080"),
                       "https://localhost:8080")
    }

    func testLocalhostWithPathGetsHttps() {
        XCTAssertEqual(URLHistory.normalize("localhost:3000/health"),
                       "https://localhost:3000/health")
    }

    // MARK: - Search queries return nil

    func testBareWordReturnsNil() {
        XCTAssertNil(URLHistory.normalize("swift"))
    }

    func testMultiWordSearchReturnsNil() {
        XCTAssertNil(URLHistory.normalize("how to use forkpty"))
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

    func testIPAddressGetsHttps() {
        XCTAssertEqual(URLHistory.normalize("127.0.0.1:8080"),
                       "https://127.0.0.1:8080")
    }
}
