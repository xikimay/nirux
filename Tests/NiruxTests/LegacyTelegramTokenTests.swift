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

    /// The real call, on a throwaway item kept the way the token was.
    func testDeleteRemovesTheItemAndSaysWhenThereIsNone() throws {
        let service = "com.xikimay.nirux.tests.legacy-token-\(UUID().uuidString)"
        let account = LegacyTelegramToken.account
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data("123456789:throwaway".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let added = SecItemAdd(item as CFDictionary, nil)
        // Without a login keychain to write to, there is nothing to prove.
        try XCTSkipIf(
            [errSecInteractionNotAllowed, errSecNotAvailable, errSecNoDefaultKeychain].contains(added),
            "no usable keychain (OSStatus \(added))"
        )
        XCTAssertEqual(added, errSecSuccess)
        defer { _ = LegacyTelegramToken.delete(service: service, account: account) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecSuccess)

        XCTAssertEqual(LegacyTelegramToken.delete(service: service, account: account), errSecSuccess)

        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecItemNotFound)
        XCTAssertEqual(LegacyTelegramToken.delete(service: service, account: account), errSecItemNotFound)
    }
}
