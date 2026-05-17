import Foundation
import Security
import CommonCrypto
import WebKit
import SQLite3

/// Imports cookies from Chrome/Brave/Arc/Edge into a WKWebsiteDataStore
@MainActor
final class CookieImporter {

    enum Browser: String, CaseIterable {
        case chrome = "Chrome"
        case brave = "Brave"
        case arc = "Arc"
        case edge = "Edge"

        var keychainService: String {
            switch self {
            case .chrome: "Chrome Safe Storage"
            case .brave: "Brave Safe Storage"
            case .arc: "Arc Safe Storage"
            case .edge: "Microsoft Edge Safe Storage"
            }
        }

        var keychainAccount: String {
            switch self {
            case .chrome: "Chrome"
            case .brave: "Brave"
            case .arc: "Arc"
            case .edge: "Microsoft Edge"
            }
        }

        var cookiesPath: String {
            let home = NSHomeDirectory()
            switch self {
            case .chrome: return "\(home)/Library/Application Support/Google/Chrome/Default/Cookies"
            case .brave: return "\(home)/Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies"
            case .arc: return "\(home)/Library/Application Support/Arc/User Data/Default/Cookies"
            case .edge: return "\(home)/Library/Application Support/Microsoft Edge/Default/Cookies"
            }
        }

        var isInstalled: Bool {
            FileManager.default.fileExists(atPath: cookiesPath)
        }
    }

    struct ImportResult {
        let imported: Int
        let failed: Int
        let browser: Browser
    }

    /// Import cookies from browser into WKWebView's cookie store
    static func importCookies(from browser: Browser, into dataStore: WKWebsiteDataStore) async throws -> ImportResult {
        // 1. Get keychain password
        guard let password = getKeychainPassword(service: browser.keychainService, account: browser.keychainAccount) else {
            throw ImportError.keychainFailed
        }

        // 2. Derive AES key
        guard let key = pbkdf2(password: password) else {
            throw ImportError.keyDerivationFailed
        }

        // 3. Copy DB (Chrome locks it)
        let tempPath = NSTemporaryDirectory() + "cookies_\(UUID().uuidString)"
        try FileManager.default.copyItem(atPath: browser.cookiesPath, toPath: tempPath)
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        // 4. Read and decrypt cookies
        let cookies = try readAndDecrypt(dbPath: tempPath, key: key)

        // 5. Import into WKWebView
        var imported = 0
        var failed = 0
        let cookieStore = dataStore.httpCookieStore

        for cookie in cookies {
            var props: [HTTPCookiePropertyKey: Any] = [
                .domain: cookie.domain,
                .name: cookie.name,
                .value: cookie.value,
                .path: cookie.path
            ]
            if cookie.isSecure { props[.secure] = "TRUE" }
            if cookie.isHttpOnly { props[.init("HttpOnly")] = "TRUE" }
            if cookie.expiresUtc > 0 {
                // Chrome uses microseconds since 1601-01-01
                let chromeEpoch: Double = 11644473600
                let unixTime = Double(cookie.expiresUtc) / 1_000_000.0 - chromeEpoch
                props[.expires] = Date(timeIntervalSince1970: unixTime)
            }

            if let httpCookie = HTTPCookie(properties: props) {
                await cookieStore.setCookie(httpCookie)
                imported += 1
            } else {
                failed += 1
            }
        }

        return ImportResult(imported: imported, failed: failed, browser: browser)
    }

    /// Detect which browsers are installed
    static var availableBrowsers: [Browser] {
        Browser.allCases.filter(\.isInstalled)
    }

    // MARK: - Keychain

    private static func getKeychainPassword(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - PBKDF2

    private static func pbkdf2(password: String) -> Data? {
        let salt = Data("saltysalt".utf8)
        let keyLen = 16
        var key = Data(count: keyLen)
        let passData = Data(password.utf8)

        let status = key.withUnsafeMutableBytes { keyBuf in
            salt.withUnsafeBytes { saltBuf in
                passData.withUnsafeBytes { passBuf in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBuf.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passData.count,
                        saltBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLen
                    )
                }
            }
        }
        return status == kCCSuccess ? key : nil
    }

    // MARK: - Decryption

    private static func decryptValue(_ blob: Data, key: Data) -> String? {
        guard blob.count > 3,
              let prefix = String(data: blob[0..<3], encoding: .utf8),
              prefix == "v10" || prefix == "v11"
        else {
            return String(data: blob, encoding: .utf8)
        }

        let ciphertext = blob[3...]
        let iv = Data(repeating: 0x20, count: 16) // Chrome uses space bytes as IV
        let bufSize = ciphertext.count + kCCBlockSizeAES128
        var plain = Data(count: bufSize)
        var outLen: size_t = 0

        let status = plain.withUnsafeMutableBytes { pBuf in
            ciphertext.withUnsafeBytes { cBuf in
                key.withUnsafeBytes { kBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            kBuf.baseAddress, key.count,
                            ivBuf.baseAddress,
                            cBuf.baseAddress, ciphertext.count,
                            pBuf.baseAddress, bufSize,
                            &outLen
                        )
                    }
                }
            }
        }

        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        plain.count = outLen

        // Chrome DB version 24+ prefixes decrypted value with 32-byte SHA256 of host_key.
        // Strip it if present (detect by checking if first 32 bytes are non-printable).
        if plain.count > 32 {
            let prefix = plain[0..<32]
            let hasBinaryPrefix = prefix.contains(where: { $0 > 127 || ($0 < 32 && $0 != 9 && $0 != 10 && $0 != 13) })
            if hasBinaryPrefix {
                plain = plain[32...]
            }
        }

        return String(data: plain, encoding: .utf8)
    }

    // MARK: - SQLite

    private struct RawCookie {
        let domain: String
        let name: String
        let value: String
        let path: String
        let expiresUtc: Int64
        let isSecure: Bool
        let isHttpOnly: Bool
    }

    private static func readAndDecrypt(dbPath: String, key: Data) throws -> [RawCookie] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ImportError.databaseFailed
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly FROM cookies"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ImportError.databaseFailed
        }
        defer { sqlite3_finalize(stmt) }

        var cookies: [RawCookie] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let domain = String(cString: sqlite3_column_text(stmt, 0))
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let rawVal = String(cString: sqlite3_column_text(stmt, 2))
            let path = String(cString: sqlite3_column_text(stmt, 4))
            let expires = sqlite3_column_int64(stmt, 5)
            let secure = sqlite3_column_int(stmt, 6) != 0
            let httpOnly = sqlite3_column_int(stmt, 7) != 0

            var cookieValue = rawVal
            if rawVal.isEmpty, let blobPtr = sqlite3_column_blob(stmt, 3) {
                let blobLen = sqlite3_column_bytes(stmt, 3)
                let data = Data(bytes: blobPtr, count: Int(blobLen))
                cookieValue = decryptValue(data, key: key) ?? ""
            }

            guard !cookieValue.isEmpty else { continue }

            cookies.append(RawCookie(
                domain: domain, name: name, value: cookieValue,
                path: path, expiresUtc: expires,
                isSecure: secure, isHttpOnly: httpOnly
            ))
        }
        return cookies
    }

    enum ImportError: LocalizedError {
        case keychainFailed
        case keyDerivationFailed
        case databaseFailed

        var errorDescription: String? {
            switch self {
            case .keychainFailed: "Could not access browser Keychain. Allow access when prompted."
            case .keyDerivationFailed: "Key derivation failed."
            case .databaseFailed: "Could not read cookies database."
            }
        }
    }
}
