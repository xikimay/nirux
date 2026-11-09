import Foundation
import Security

/// Telegram Remote Access is gone (November 2026), and its bot token lived
/// in the Keychain, which no update clears. The installed app deletes it
/// at each launch: nothing once it is gone. Best effort — a failure is
/// logged and the next launch tries again. This can go once no install
/// predates the removal.
enum LegacyTelegramToken {
    /// The generic password the removed token store kept.
    static let service = "com.xikimay.nirux.telegram-remote-access"
    static let account = "bot-token"

    /// Deletes the token in the background; false when this Nirux leaves it
    /// alone. Only an app bundle on the real state deletes it: the Keychain
    /// is shared with every copy (NIRUX_STATE_DIR doesn't move it), and a
    /// development build, or a copy on a state of its own, must not take
    /// the token of an installed build that still has the feature.
    @discardableResult
    static func removeAtLaunch(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        delete: @escaping @Sendable () -> OSStatus = { LegacyTelegramToken.delete(service: service, account: account) }
    ) -> Bool {
        guard bundleURL.pathExtension == "app", Persistence.stateDirectoryOverride(in: environment) == nil else {
            return false
        }
        DispatchQueue.global(qos: .utility).async {
            let status = delete()
            guard status != errSecSuccess, status != errSecItemNotFound else { return }
            NSLog("[Nirux] Could not delete the Telegram bot token from the Keychain: OSStatus %d", status)
        }
        return true
    }

    /// Deletes that generic password: `errSecSuccess`, or
    /// `errSecItemNotFound` when there is none.
    static func delete(service: String, account: String) -> OSStatus {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }
}
