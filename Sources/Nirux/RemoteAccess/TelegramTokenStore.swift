import Foundation
import Security

enum TelegramTokenStore {
    private static let service = "com.xikimay.nirux.telegram-remote-access"
    private static let account = "bot-token"

    enum StoreError: LocalizedError {
        case keychain(OSStatus)
        case invalidEncoding

        var errorDescription: String? {
            switch self {
            case let .keychain(status):
                return SecCopyErrorMessageString(status, nil) as String?
                    ?? "Keychain error \(status)"
            case .invalidEncoding:
                return "The stored Telegram token is not valid UTF-8."
            }
        }
    }

    static func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else { throw StoreError.invalidEncoding }
        return token
    }

    static func save(_ token: String) throws {
        let data = Data(token.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw StoreError.keychain(updateStatus) }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw StoreError.keychain(addStatus) }
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum TelegramPairingCode {
    static func generate() -> String {
        let modulus: UInt32 = 100_000_000
        let acceptedUpperBound = UInt32.max - (UInt32.max % modulus)
        var random: UInt32 = 0
        repeat {
            let status = withUnsafeMutableBytes(of: &random) { buffer in
                SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
            }
            if status != errSecSuccess {
                random = UInt32.random(in: 0..<modulus)
                break
            }
        } while random >= acceptedUpperBound
        return String(format: "%08u", random % modulus)
    }
}
