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
            {"profile": {"last_used": "Profile 2", "profiles_order": ["Default", "Profile 2", "Profile 3", "Profile 4"],
              "info_cache": {"Default": {"name": "Personal"},
                "Profile 2": {"name": "Alex", "user_name": "alex@work.example"},
                "Profile 3": {"name": "Person 3", "is_using_default_name": true, "gaia_given_name": "Alex", "user_name": "alex@home.example"},
                "Profile 4": {"name": "No folder"}}}}
            """#, to: chrome + "/Local State")
        // The last written of Cookies and Network/Cookies.
        try write("", to: chrome + "/Default/Network/Cookies", modified: -86_400)
        try write("", to: chrome + "/Default/Cookies")
        try write("", to: chrome + "/Profile 2/Network/Cookies")
        try write("", to: chrome + "/Profile 2/Cookies", modified: -86_400)
        try write("", to: chrome + "/Profile 3/Cookies")
        // A deleted profile's folder Chrome no longer lists.
        try write("", to: chrome + "/Profile 9/Cookies")
        // No Local State: the folders Chromium names for profiles.
        let brave = root + "/Library/Application Support/BraveSoftware/Brave-Browser"
        for folder in ["Default", "Profile 10", "Profile 2", "System Profile"] {
            try write("", to: brave + "/\(folder)/Cookies")
        }

        XCTAssertEqual(CookieImporter.availableSources(home: root), [
            .init(browser: .chrome, profileFolder: "Profile 2", profileName: "Alex (alex@work.example)",
                  cookiesPath: chrome + "/Profile 2/Network/Cookies"),
            .init(browser: .chrome, profileFolder: "Default", profileName: "Personal", cookiesPath: chrome + "/Default/Cookies"),
            .init(browser: .chrome, profileFolder: "Profile 3", profileName: "Alex (alex@home.example)", cookiesPath: chrome + "/Profile 3/Cookies"),
            .init(browser: .brave, profileFolder: "Default", profileName: "Default", cookiesPath: brave + "/Default/Cookies"),
            .init(browser: .brave, profileFolder: "Profile 2", profileName: "Profile 2", cookiesPath: brave + "/Profile 2/Cookies"),
            .init(browser: .brave, profileFolder: "Profile 10", profileName: "Profile 10", cookiesPath: brave + "/Profile 10/Cookies"),
        ])
    }

    // MARK: - Reading

    /// A cookie file Nirux may not read used to fail as the copy into the
    /// temporary folder: "you don't have permission to access “T”". CI can
    /// only deny it with file permissions (EACCES); macOS privacy
    /// protection gives EPERM the same way.
    func testUnreadableCookieFileNamesTheProfileAndTheReason() throws {
        try XCTSkipIf(getuid() == 0, "root reads any file")
        let source = try makeSource(Self.standardRows)
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
        let source = try makeSource(Self.standardRows, walMode: true)
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
        let source = try makeSource(Self.standardRows)
        XCTAssertThrowsError(try CookieImporter.readCookies(from: source) { "almonds" }) { error in
            XCTAssertEqual(error as? CookieImporter.ImportError, .init(source: source, failure: .undecryptable))
            XCTAssertTrue(error.localizedDescription.contains("doesn’t decrypt Chrome’s cookies"), error.localizedDescription)
        }
    }

    /// Version 24 puts the domain's hash before the value: an empty value
    /// decrypts to just the hash, not to a wrong key.
    func testAnEmptyEncryptedValueIsNotAWrongKey() throws {
        let source = try makeSource([Self.standardRows[0], Row(host: ".example.org", name: "empty", secret: "")])
        XCTAssertEqual(try CookieImporter.readCookies(from: source) { "peanuts" }, [Self.plainCookie])
    }

    func testAProfileWithoutEncryptedCookiesNeverAsksTheKeychain() throws {
        let source = try makeSource([Self.standardRows[0]])
        var askedKeychain = false
        XCTAssertEqual(try CookieImporter.readCookies(from: source) { askedKeychain = true; return "peanuts" }, [Self.plainCookie])
        XCTAssertFalse(askedKeychain)
    }

    /// A page that doesn't read, as when the browser was writing it.
    func testAPageThatDoesNotReadFailsTheImport() throws {
        let rows = (0..<300).map { Row(host: ".example\($0).com", name: "c", plain: String(repeating: "v", count: 200)) }
        let source = try makeSource(rows)
        let file = try FileHandle(forUpdating: URL(fileURLWithPath: source.cookiesPath))
        let size = try file.seekToEnd()
        try file.seek(toOffset: size - 4096)
        try file.write(contentsOf: Data(repeating: 0xFF, count: 4096))
        try file.close()

        XCTAssertThrowsError(try CookieImporter.readCookies(from: source) { "peanuts" }) { error in
            let failure = (error as? CookieImporter.ImportError)?.failure
            guard case .database = failure else { return XCTFail("\(error)") }
        }
    }

    // MARK: - Fixtures

    private struct Row {
        var host: String
        var name: String
        var plain = ""
        /// Stored encrypted when set.
        var secret: String?
        var path = "/"
        var expires: Int64 = 0
        var secure = false
        var httpOnly = false
    }

    private static let plainCookie = CookieImporter.RawCookie(
        domain: ".example.com", name: "plain", value: "1", path: "/", expiresUtc: 0, isSecure: false, isHttpOnly: false
    )

    private static let standardRows = [
        Row(host: ".example.com", name: "plain", plain: "1"),
        Row(host: ".example.org", name: "session", secret: "s3cret", path: "/app", expires: 13_400_000_000_000_000, secure: true, httpOnly: true),
    ]

    private func write(_ text: String, to path: String, modified offset: TimeInterval = 0) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: offset)], ofItemAtPath: path)
    }

    /// A Chrome cookie database of `version`, its secrets encrypted with
    /// the key Chrome derives from `password`.
    private func makeSource(
        _ rows: [Row], password: String = "peanuts", version: Int = 24, walMode: Bool = false
    ) throws -> CookieImporter.Source {
        let path = root + "/Cookies"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func exec(_ sql: String) {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        }
        if walMode { exec("PRAGMA journal_mode=WAL") }
        exec("CREATE TABLE meta (key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR)")
        exec("INSERT INTO meta VALUES ('version', '\(version)')")
        exec("""
            CREATE TABLE cookies (host_key TEXT NOT NULL, name TEXT NOT NULL, value TEXT NOT NULL,
            encrypted_value BLOB NOT NULL, path TEXT NOT NULL, expires_utc INTEGER NOT NULL,
            is_secure INTEGER NOT NULL, is_httponly INTEGER NOT NULL)
            """)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO cookies VALUES (?, ?, ?, ?, ?, ?, ?, ?)", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        exec("BEGIN")
        for row in rows {
            let blob = try row.secret.map { try encrypted($0, host: row.host, password: password, version: version) } ?? Data()
            sqlite3_bind_text(statement, 1, row.host, -1, transient)
            sqlite3_bind_text(statement, 2, row.name, -1, transient)
            sqlite3_bind_text(statement, 3, row.plain, -1, transient)
            if blob.isEmpty {
                sqlite3_bind_zeroblob(statement, 4, 0)
            } else {
                _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(blob.count), transient) }
            }
            sqlite3_bind_text(statement, 5, row.path, -1, transient)
            sqlite3_bind_int64(statement, 6, row.expires)
            sqlite3_bind_int(statement, 7, row.secure ? 1 : 0)
            sqlite3_bind_int(statement, 8, row.httpOnly ? 1 : 0)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_reset(statement)
        }
        exec("COMMIT")
        return CookieImporter.Source(browser: .chrome, profileFolder: "Profile 2", profileName: "Work", cookiesPath: path)
    }

    /// "v10" + AES-128-CBC, as Chrome encrypts cookie values on macOS; from
    /// version 24 the SHA-256 of the domain comes before the value.
    private func encrypted(_ value: String, host: String, password: String, version: Int) throws -> Data {
        var key = Data(count: 16)
        let salt = Array("saltysalt".utf8)
        let derived = key.withUnsafeMutableBytes { keyBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, keyBytes.bindMemory(to: UInt8.self).baseAddress, 16
            )
        }
        XCTAssertEqual(derived, Int32(kCCSuccess))
        var plain = Array(value.utf8)
        if version >= 24 {
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            let hostBytes = Array(host.utf8)
            _ = CC_SHA256(hostBytes, CC_LONG(hostBytes.count), &hash)
            plain = hash + plain
        }
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
