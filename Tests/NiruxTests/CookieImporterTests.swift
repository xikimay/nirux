import CommonCrypto
import SQLite3
import XCTest
@testable import Nirux

final class CookieImporterTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cookie-importer-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    // MARK: - Profiles

    func testSourcesListEachProfileByItsNameLastUsedFirst() throws {
        let chrome = root + "/Library/Application Support/Google/Chrome"
        try write(#"""
            {"profile": {"last_used": "Profile 2", "profiles_order": ["Default", "Profile 2", "Profile 3"],
              "info_cache": {"Default": {"name": "Personal"}, "Profile 2": {"name": "Work"}, "Profile 3": {"name": "Empty"}}}}
            """#, to: chrome + "/Local State")
        try write("", to: chrome + "/Default/Cookies")
        try write("", to: chrome + "/Profile 2/Network/Cookies")
        try write("", to: chrome + "/Profile 2/Cookies")
        try FileManager.default.createDirectory(atPath: chrome + "/Profile 3", withIntermediateDirectories: true)
        // A deleted profile's folder Chrome no longer lists.
        try write("", to: chrome + "/Profile 9/Cookies")
        // No Local State: the folders Chromium names for profiles.
        let brave = root + "/Library/Application Support/BraveSoftware/Brave-Browser"
        for folder in ["Default", "Profile 10", "Profile 2", "System Profile"] {
            try write("", to: brave + "/\(folder)/Cookies")
        }

        XCTAssertEqual(CookieImporter.availableSources(home: root), [
            .init(browser: .chrome, profileFolder: "Profile 2", profileName: "Work", cookiesPath: chrome + "/Profile 2/Network/Cookies"),
            .init(browser: .chrome, profileFolder: "Default", profileName: "Personal", cookiesPath: chrome + "/Default/Cookies"),
            .init(browser: .brave, profileFolder: "Default", profileName: "Default", cookiesPath: brave + "/Default/Cookies"),
            .init(browser: .brave, profileFolder: "Profile 2", profileName: "Profile 2", cookiesPath: brave + "/Profile 2/Cookies"),
            .init(browser: .brave, profileFolder: "Profile 10", profileName: "Profile 10", cookiesPath: brave + "/Profile 10/Cookies"),
        ])
    }

    // MARK: - Reading

    /// The second account's failure: macOS wouldn't let Nirux read the
    /// cookie file, and the copy into the temporary folder reported it as
    /// "you don't have permission to access “T”".
    func testUnreadableCookieFileNamesTheProfileAndTheReason() throws {
        try XCTSkipIf(getuid() == 0, "root reads any file")
        let source = try makeSource(password: "peanuts", walMode: false)
        XCTAssertEqual(chmod(source.cookiesPath, 0), 0)
        defer { chmod(source.cookiesPath, 0o600) }

        var askedKeychain = false
        XCTAssertThrowsError(try CookieImporter.readCookies(from: source) { askedKeychain = true; return "peanuts" }) { error in
            XCTAssertEqual(error as? CookieImporter.ImportError, .init(source: source, failure: .unreadable(path: source.cookiesPath, errno: EACCES)))
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Chrome, profile “Work”") && message.contains("permission to read"), message)
        }
        XCTAssertFalse(askedKeychain, "no Keychain prompt for a file that can't be read")
    }

    /// Read from memory, so a database in WAL mode must still open.
    func testReadsAndDecryptsCookiesOfADatabaseInWALMode() throws {
        let source = try makeSource(password: "peanuts", walMode: true)
        XCTAssertEqual(try CookieImporter.readCookies(from: source) { "peanuts" }, [
            .init(domain: ".example.com", name: "plain", value: "1", path: "/", expiresUtc: 0, isSecure: false, isHttpOnly: false),
            .init(
                domain: ".example.org", name: "session", value: "s3cret", path: "/app",
                expiresUtc: 13_400_000_000_000_000, isSecure: true, isHttpOnly: true
            ),
        ])
    }

    /// A Keychain key that decrypts nothing used to import 0 cookies and
    /// call it a success.
    func testAKeychainKeyThatDecryptsNothingFails() throws {
        let source = try makeSource(password: "peanuts", walMode: false)
        XCTAssertThrowsError(try CookieImporter.readCookies(from: source) { "almonds" }) { error in
            XCTAssertEqual(error as? CookieImporter.ImportError, .init(source: source, failure: .undecryptable))
            XCTAssertTrue(error.localizedDescription.contains("doesn’t decrypt Chrome’s cookies"), error.localizedDescription)
        }
    }

    // MARK: - Fixtures

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    /// A Chrome cookie database: one plain cookie, one encrypted with the
    /// key Chrome derives from `password`.
    private func makeSource(password: String, walMode: Bool) throws -> CookieImporter.Source {
        let path = root + "/Cookies"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func exec(_ sql: String) {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        }
        if walMode { exec("PRAGMA journal_mode=WAL") }
        exec("""
            CREATE TABLE cookies (host_key TEXT NOT NULL, name TEXT NOT NULL, value TEXT NOT NULL,
            encrypted_value BLOB NOT NULL, path TEXT NOT NULL, expires_utc INTEGER NOT NULL,
            is_secure INTEGER NOT NULL, is_httponly INTEGER NOT NULL)
            """)
        exec("INSERT INTO cookies VALUES ('.example.com', 'plain', '1', x'', '/', 0, 0, 0)")
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(db, "INSERT INTO cookies VALUES ('.example.org', 'session', '', ?, '/app', 13400000000000000, 1, 1)", -1, &statement, nil),
            SQLITE_OK
        )
        defer { sqlite3_finalize(statement) }
        let blob = try encrypted("s3cret", password: password)
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        return CookieImporter.Source(browser: .chrome, profileFolder: "Profile 2", profileName: "Work", cookiesPath: path)
    }

    /// "v10" + AES-128-CBC, as Chrome encrypts cookie values on macOS.
    private func encrypted(_ value: String, password: String) throws -> Data {
        var key = Data(count: 16)
        let salt = Array("saltysalt".utf8)
        let derived = key.withUnsafeMutableBytes { keyBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, keyBytes.bindMemory(to: UInt8.self).baseAddress, 16
            )
        }
        XCTAssertEqual(derived, Int32(kCCSuccess))
        let plain = Array(value.utf8)
        var cipher = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
        var length = 0
        let iv = [UInt8](repeating: 0x20, count: 16)
        let status = key.withUnsafeBytes { keyBytes in
            CCCrypt(
                CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                keyBytes.baseAddress, 16, iv, plain, plain.count, &cipher, cipher.count, &length
            )
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        return Data("v10".utf8) + Data(cipher.prefix(length))
    }
}
