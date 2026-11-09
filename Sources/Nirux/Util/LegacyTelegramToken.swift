import Foundation
import Security

/// Telegram Remote Access is gone (November 2026), and its bot token lived
/// in the Keychain, which no update clears. The installed app deletes it
/// at each launch: nothing once it is gone. Best effort — a failure is
/// logged and the next launch tries again. This can go once no install
/// predates the removal.
enum LegacyTelegramToken {
    /// Deletes the token in the background; false when this Nirux leaves it
    /// alone. Only an app bundle on the real state deletes it: the Keychain
    /// is shared with every copy (NIRUX_STATE_DIR doesn't move it), and a
    /// build run from a checkout, or a copy on a state of its own, must not
    /// take the token of an installed build that still has the feature. (A
    /// bundle allowed onto the real state stands in for the installed app:
    /// its first save drops the feature's settings too.)
    @discardableResult
    static func removeAtLaunch(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        delete: @escaping @Sendable () -> OSStatus = { LegacyTelegramToken.delete() }
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

    /// Deletes the generic password the removed token store kept:
    /// `errSecSuccess`, or `errSecItemNotFound` when there is none.
    static func delete() -> OSStatus {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.xikimay.nirux.telegram-remote-access",
            kSecAttrAccount as String: "bot-token"
        ] as CFDictionary)
    }
}
