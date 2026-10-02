import AppKit
import XCTest
@testable import Nirux

final class AWSSSOStatusTests: XCTestCase {
    private let config = """
    [default]
    region = eu-west-1

    [profile dev]
    sso_session = example
    sso_account_id = 123456789012

    [profile prod]
    sso_session=example

    [sso-session example]
    sso_start_url = https://example.awsapps.com/start
    sso_region = eu-west-1

    [sso-session unused]
    sso_start_url = https://other.awsapps.com/start
    """

    func testSessionsPairEachSSOSessionWithItsFirstProfile() {
        XCTAssertEqual(
            AWSSSOStatus.sessions(config: config),
            [AWSSSOStatus.Session(name: "example", profile: "dev")]
        )
    }

    func testDefaultProfileCanUseASession() {
        let config = "[default]\nsso_session = example\n[sso-session example]\n"
        XCTAssertEqual(AWSSSOStatus.sessions(config: config), [AWSSSOStatus.Session(name: "example", profile: "default")])
    }

    /// The AWS CLI names a session's cache file after the SHA-1 of its name.
    func testCacheURLIsTheSHA1OfTheSessionName() {
        XCTAssertEqual(
            AWSSSOStatus.cacheURL(session: "example", home: "/Users/me").path,
            "/Users/me/.aws/sso/cache/c3499c2729730a7f807efb8676a92dcb6f8a3f8f.json"
        )
    }

    func testExpiresAtIsTheOnlyFieldRead() {
        let cache = Data("""
        {"startUrl": "https://example.awsapps.com/start", "accessToken": "secret", "refreshToken": "secret",
         "expiresAt": "2026-10-02T12:00:00Z"}
        """.utf8)
        XCTAssertEqual(AWSSSOStatus.expiresAt(cache: cache), ISO8601DateFormatter().date(from: "2026-10-02T12:00:00Z"))
        XCTAssertNil(AWSSSOStatus.expiresAt(cache: Data("{}".utf8)))
    }

    /// The JavaScript SDK (CDK, Node tools) refreshes the same file with
    /// `Date.toISOString()`, milliseconds included.
    func testExpiresAtReadsFractionalSeconds() {
        XCTAssertEqual(
            AWSSSOStatus.expiresAt(cache: Data(#"{"expiresAt": "2026-10-02T12:00:00.000Z"}"#.utf8)),
            ISO8601DateFormatter().date(from: "2026-10-02T12:00:00Z")
        )
    }

    func testAFreshTokenIsNotProbed() {
        let now = Date()
        let result = expired(expiresAt: now.addingTimeInterval(AWSSSOStatus.refreshWindow + 60), now: now) { _ in
            XCTFail("probed a fresh token")
            return true
        }
        XCTAssertEqual(result, [:])
    }

    /// The CLI refreshes an expired access token by itself while the
    /// session lasts: only the probe can tell.
    func testATokenInsideTheRefreshWindowIsExpiredOnlyIfTheProbeSaysSo() {
        let now = Date()
        let expiry = now.addingTimeInterval(-60)
        XCTAssertEqual(expired(expiresAt: expiry, now: now) { _ in false }, [:])
        XCTAssertEqual(expired(expiresAt: expiry, now: now) { _ in true }, ["example": expiry])
        let stillValid = now.addingTimeInterval(AWSSSOStatus.refreshWindow - 60)
        XCTAssertEqual(expired(expiresAt: stillValid, now: now) { _ in true }, ["example": stillValid])
    }

    func testAnExpiredSessionStaysExpiredUntilALoginRewritesItsFile() {
        let now = Date()
        let expiry = now.addingTimeInterval(-60)
        let unchanged = expired(expiresAt: expiry, known: ["example": expiry], now: now) { _ in
            XCTFail("probed again an unchanged file")
            return false
        }
        XCTAssertEqual(unchanged, ["example": expiry])
        let loggedIn = expired(expiresAt: now.addingTimeInterval(3600), known: ["example": expiry], now: now) { _ in true }
        XCTAssertEqual(loggedIn, [:])
    }

    func testASessionWithoutCacheFileIsLeftAlone() {
        XCTAssertEqual(expired(expiresAt: nil, now: Date()) { _ in true }, [:])
    }

    func testOnlyAnExpiredErrorAsksForALogin() {
        XCTAssertTrue(AWSSSOStatus.saysExpired(standardError: Data(
            "Error when retrieving token from sso: Token has expired and refresh failed".utf8
        )))
        XCTAssertTrue(AWSSSOStatus.saysExpired(standardError: Data(
            "The SSO session associated with this profile has expired or is otherwise invalid.".utf8
        )))
        XCTAssertFalse(AWSSSOStatus.saysExpired(standardError: Data(
            "Could not connect to the endpoint URL: \"https://sts.amazonaws.com/\"".utf8
        )))
        // Clock skew after a wake: a login wouldn't fix it.
        XCTAssertFalse(AWSSSOStatus.saysExpired(standardError: Data(
            "An error occurred (SignatureDoesNotMatch) when calling the GetCallerIdentity operation: Signature expired".utf8
        )))
    }

    func testLoginCommandQuotesASessionNameThatIsNotAPlainWord() {
        XCTAssertEqual(AWSSSOStatus.loginCommand(session: "example"), "! aws sso login --sso-session example")
        XCTAssertEqual(AWSSSOStatus.loginCommand(session: "$(id)"), "! aws sso login --sso-session '$(id)'")
        XCTAssertEqual(AWSSSOStatus.loginCommand(session: "x;id"), "! aws sso login --sso-session 'x;id'")
    }

    @MainActor
    func testIndicatorShowsTheLoginCommandOfEachExpiredSession() {
        let indicator = AWSSSOIndicator()
        XCTAssertTrue(indicator.isHidden)

        indicator.update(expiredSessions: ["example"])

        XCTAssertFalse(indicator.isHidden)
        let menu = indicator.menu()
        menu.update()
        let items = menu.items
        XCTAssertEqual(items.map(\.title), ["! aws sso login --sso-session example", "Copy Command"])
        XCTAssertEqual(items.map(\.isEnabled), [false, true])

        indicator.update(expiredSessions: [])
        XCTAssertTrue(indicator.isHidden)
    }

    private func expired(
        expiresAt: Date?,
        known: [String: Date] = [:],
        now: Date,
        probe: (AWSSSOStatus.Session) -> Bool
    ) -> [String: Date] {
        AWSSSOStatus.expiredSessions(
            AWSSSOStatus.sessions(config: config),
            known: known,
            now: now,
            expiresAt: { _ in expiresAt },
            probeSaysExpired: probe
        )
    }
}
