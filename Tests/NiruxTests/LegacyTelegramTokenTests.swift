import Security
import XCTest
@testable import Nirux

/// Telegram Remote Access left a bot token in the Keychain: the installed
/// app deletes it at launch, and no other copy touches it.
final class LegacyTelegramTokenTests: XCTestCase {
    private let installedApp = URL(fileURLWithPath: "/Applications/Nirux.app")
    private let devBuild = URL(fileURLWithPath: "/tmp/checkout/.build/debug")

    func testTheInstalledAppOnTheRealStateDeletesTheToken() {
        let deleted = expectation(description: "the token's item is deleted")
        XCTAssertTrue(LegacyTelegramToken.removeAtLaunch(environment: [:], bundleURL: installedApp) {
            deleted.fulfill()
            return errSecSuccess
        })
        wait(for: [deleted], timeout: 10)
    }

    /// The Keychain is shared with the installed app, which may still be a
    /// build that uses the token.
    func testADevelopmentBuildOrACopyOnItsOwnStateLeavesTheTokenAlone() {
        let touched = expectation(description: "the token's item is deleted")
        touched.isInverted = true
        // Each copy that got through would fulfill it, some after the test.
        touched.assertForOverFulfill = false
        let copies: [(environment: [String: String], bundle: URL)] = [
            ([:], devBuild),
            (["NIRUX_STATE_DIR": "/tmp/nirux-dev"], installedApp)
        ]
        for copy in copies {
            XCTAssertFalse(LegacyTelegramToken.removeAtLaunch(environment: copy.environment, bundleURL: copy.bundle) {
                touched.fulfill()
                return errSecSuccess
            })
        }
        wait(for: [touched], timeout: 0.3)
    }
}
