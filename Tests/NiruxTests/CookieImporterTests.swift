import CommonCrypto
import SQLite3
import XCTest
@testable import Nirux

final class CookieImporterTests: XCTestCase {
    private var root = ""
    /// Folders a test locks; given back before tearDown removes them.
    private var lockedFolders: [String] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cookie-importer-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for folder in lockedFolders { chmod(folder, 0o700) }
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
                "Profile 4": {"name": "No folder"},
                "Profile 5": {"name": "Shop", "user_name": "shop@example"}, "Profile 6": {"name": "Shop", "user_name": "shop@example"}}}}
            """#, to: chrome + "/Local State")
        // The last written of Cookies and Network/Cookies.
        try write("", to: chrome + "/Default/Network/Cookies", modified: -86_400)
        try write("", to: chrome + "/Default/Cookies")
        try write("", to: chrome + "/Profile 2/Network/Cookies")
        try write("", to: chrome + "/Profile 2/Cookies", modified: -86_400)
        try write("", to: chrome + "/Profile 3/Cookies")
        try write("", to: chrome + "/Profile 5/Cookies")
        try write("", to: chrome + "/Profile 6/Cookies")
        // A deleted profile's folder Chrome no longer lists.
        try write("", to: chrome + "/Profile 9/Cookies")
        // No Local State: the folders Chromium names for profiles.
        let brave = root + "/Library/Application Support/BraveSoftware/Brave-Browser"
        for folder in ["Default", "Profile 10", "Profile 2", "System Profile"] {
            try write("", to: brave + "/\(folder)/Cookies")
        }
        // Moved to another volume, a symlink left behind.
        let edge = root + "/Library/Application Support/Microsoft Edge"
        try write("", to: root + "/Elsewhere/Edge/Default/Cookies")
        try FileManager.default.createSymbolicLink(atPath: edge, withDestinationPath: root + "/Elsewhere/Edge")

        XCTAssertEqual(CookieImporter.availableSources(home: root), [
            .init(browser: .chrome, profileFolder: "Profile 2", profileName: "Alex (alex@work.example)",
                  cookiesPath: chrome + "/Profile 2/Network/Cookies"),
            .init(browser: .chrome, profileFolder: "Default", profileName: "Personal", cookiesPath: chrome + "/Default/Cookies"),
            .init(browser: .chrome, profileFolder: "Profile 3", profileName: "Alex (alex@home.example)", cookiesPath: chrome + "/Profile 3/Cookies"),
            // One name and one account: told apart by folder.
            .init(browser: .chrome, profileFolder: "Profile 5", profileName: "Shop (Profile 5)", cookiesPath: chrome + "/Profile 5/Cookies"),
            .init(browser: .chrome, profileFolder: "Profile 6", profileName: "Shop (Profile 6)", cookiesPath: chrome + "/Profile 6/Cookies"),
            .init(browser: .brave, profileFolder: "Default", profileName: "Default", cookiesPath: brave + "/Default/Cookies"),
            .init(browser: .brave, profileFolder: "Profile 2", profileName: "Profile 2", cookiesPath: brave + "/Profile 2/Cookies"),
            .init(browser: .brave, profileFolder: "Profile 10", profileName: "Profile 10", cookiesPath: brave + "/Profile 10/Cookies"),
            .init(browser: .edge, profileFolder: "Default", profileName: "Default", cookiesPath: edge + "/Default/Cookies"),
        ])
    }

    /// A profile folder another account owns, mode 700: the profile used to
    /// vanish, leaving "no profile with cookies". And one whose Network
    /// folder Nirux can't enter: its old Cookies file may be stale, so the
    /// block is reported rather than that file imported.
    func testAProfileNiruxCannotEnterFailsWithItsNameAndTheReason() throws {
        try XCTSkipIf(getuid() == 0, "root enters any folder")
        let chrome = root + "/Library/Application Support/Google/Chrome"
        try write(#"{"profile": {"last_used": "Profile 2", "info_cache": {"Profile 2": {"name": "Work"}, "Profile 3": {"name": "Home"}}}}"#,
                  to: chrome + "/Local State")
        try write("", to: chrome + "/Profile 2/Cookies")
        try lock(chrome + "/Profile 2", mode: 0)
        try write("", to: chrome + "/Profile 3/Network/Cookies")
        try write("", to: chrome + "/Profile 3/Cookies")
        try lock(chrome + "/Profile 3/Network", mode: 0)

        let sources = CookieImporter.availableSources(home: root)
        XCTAssertEqual(sources.map(\.profileName), ["Work", "Home"])
        XCTAssertEqual(sources.map(\.blocked), [
            .unreadable(path: chrome + "/Profile 2/Cookies", errno: EACCES), .unreadable(path: chrome + "/Profile 3/Network/Cookies", errno: EACCES),
        ])
        XCTAssertThrowsError(try CookieImporter.readCookies(from: try XCTUnwrap(sources.first)) { "peanuts" }) { error in
            XCTAssertEqual(
                (error as? CookieImporter.ImportError)?.failure, .unreadable(path: chrome + "/Profile 2/Cookies", errno: EACCES)
            )
            XCTAssertTrue(error.localizedDescription.contains("Chrome, profile “Work”"), error.localizedDescription)
        }
    }

    /// Neither the profile list nor the folder can be read, as when macOS
    /// blocks the browser's folder: the browser is named, not a profile it
    /// may not have.
    /// Unless Default's cookie file answers a stat: then that profile.
    func testABrowserWhoseProfilesNiruxCannotSeeFailsWithoutAProfile() throws {
        try XCTSkipIf(getuid() == 0, "root reads any folder")
        let arc = try makeUnlistableBrowser()
        let brave = try makeUnlistableBrowser(at: "BraveSoftware/Brave-Browser", withDefaultCookies: true)

        let sources = CookieImporter.availableSources(home: root)
        XCTAssertEqual(sources.map(\.browser), [.brave, .arc])
        XCTAssertEqual(sources.first, .init(browser: .brave, profileFolder: "Default", profileName: "Default", cookiesPath: brave + "/Default/Cookies"))
        XCTAssertNil(sources.last?.profileName)
        XCTAssertThrowsError(try CookieImporter.readCookies(from: try XCTUnwrap(sources.last)) { "peanuts" }) { error in
            XCTAssertEqual((error as? CookieImporter.ImportError)?.failure, .unreadable(path: arc + "/Local State", errno: EACCES))
            XCTAssertTrue(error.localizedDescription.hasPrefix("Nirux couldn’t import cookies from Arc. "), error.localizedDescription)
        }
    }

    /// The menu and the palette offer a browser that ran here, on stat(2)
    /// alone: a Local State, or a Default cookie file. Only a click reads
    /// the profiles, those Local State lists: a lingering Default isn't
    /// one, and a browser whose profiles are all "Profile N" is offered.
    func testOffersBrowsersThatRanHereAndListsTheirProfiles() throws {
        let support = root + "/Library/Application Support"
        let chrome = support + "/Google/Chrome"
        try write(#"{"profile": {"info_cache": {"Profile 2": {"name": "Work"}}}}"#, to: chrome + "/Local State")
        try write("", to: chrome + "/Profile 2/Cookies")
        try write("", to: chrome + "/Default/Cookies")
        let brave = support + "/BraveSoftware/Brave-Browser"
        try write(#"{"profile": {"info_cache": {"Profile 1": {"name": "Home"}}}}"#, to: brave + "/Local State")
        try write("", to: brave + "/Profile 1/Cookies")
        // Ran, no cookie file yet: offered, and the click says so.
        try write(#"{"profile": {"info_cache": {"Default": {"name": "Person 1"}}}}"#, to: support + "/Microsoft Edge/Local State")
        // No Local State, a Default cookie file: offered on it.
        let arc = support + "/Arc/User Data"
        try write("", to: arc + "/Default/Cookies")

        XCTAssertEqual(CookieImporter.browsersToOffer(home: root), [.chrome, .brave, .arc, .edge])
        XCTAssertEqual(CookieImporter.availableSources(home: root), [
            .init(browser: .chrome, profileFolder: "Profile 2", profileName: "Work", cookiesPath: chrome + "/Profile 2/Cookies"),
            .init(browser: .brave, profileFolder: "Profile 1", profileName: "Home", cookiesPath: brave + "/Profile 1/Cookies"),
            .init(browser: .arc, profileFolder: "Default", profileName: "Default", cookiesPath: arc + "/Default/Cookies"),
        ])

        // Never ran: an extension's helper folder only.
        let other = root + "/other"
        try FileManager.default.createDirectory(
            atPath: other + "/Library/Application Support/Arc/User Data/NativeMessagingHosts", withIntermediateDirectories: true
        )
        XCTAssertEqual(CookieImporter.browsersToOffer(home: other), [])
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

    /// Before and from version 24, which puts the domain's hash before the
    /// value.
    func testReadsAndDecryptsCookiesOfBothDatabaseVersions() throws {
        for version in [23, 24] {
            let source = try makeSource(Self.standardRows, version: version)
            XCTAssertEqual(try CookieImporter.readCookies(from: source) { "peanuts" }, .init(cookies: Self.decryptedRows, undecryptable: 0))
        }
    }

    /// The browser running in WAL mode: recent commits, here everything,
    /// are still in Cookies-wal.
    func testReadsCookiesStillInTheWriteAheadLog() throws {
        let path = root + "/Cookies"
        let writer = try openDatabase(at: path)
        defer { sqlite3_close(writer) }
        exec(writer, "PRAGMA journal_mode=WAL")
        exec(writer, "PRAGMA wal_autocheckpoint=0")
        try fill(writer, with: [Self.standardRows[0]])
        let source = CookieImporter.Source(browser: .chrome, profileFolder: "Default", profileName: "Work", cookiesPath: path)

        XCTAssertEqual(try CookieImporter.readCookies(from: source) { "peanuts" }.cookies, [Self.plainCookie])
    }

    /// The browser in the middle of a write: pages already changed in the
    /// file, the originals in its hot journal. The import reads the
    /// database as it was, not half of the write.
    func testReadsTheDatabaseAsItWasBeforeAnUnfinishedWrite() throws {
        let path = root + "/Cookies"
        let writer = try openDatabase(at: path)
        defer { sqlite3_close(writer) }
        exec(writer, "PRAGMA journal_mode=TRUNCATE")
        let before = String(repeating: "o", count: 200)
        try fill(writer, with: (0..<3000).map { Row(host: ".example\($0).com", name: "c", plain: before) })
        // A cache too small for the write: changed pages go to the file.
        exec(writer, "PRAGMA cache_size=10")
        exec(writer, "PRAGMA cache_spill=1")
        exec(writer, "BEGIN")
        exec(writer, "UPDATE cookies SET value = '\(String(repeating: "N", count: 200))'")
        defer { exec(writer, "ROLLBACK") }
        let changed = Data(String(repeating: "N", count: 200).utf8)
        XCTAssertNotNil(try Data(contentsOf: URL(fileURLWithPath: path)).range(of: changed), "the write reached the file")
        let source = CookieImporter.Source(browser: .chrome, profileFolder: "Default", profileName: "Work", cookiesPath: path)

        let values = try CookieImporter.readCookies(from: source) { "peanuts" }.cookies.map(\.value)
        XCTAssertEqual(values.count, 3000)
        XCTAssertEqual(Set(values), [before])
    }

    /// A Keychain key that decrypts nothing used to import 0 cookies and
    /// call it a success. CommonCrypto takes any key, and a few short
    /// values out of hundreds read as UTF-8 past the domain hash: only the
    /// hash tells.
    func testAKeychainKeyThatDecryptsNothingFails() throws {
        let short = (0..<300).map { Row(host: ".example\($0).com", name: "s", secret: "v\($0)") }
        let source = try makeSource(Self.standardRows + short)
        XCTAssertThrowsError(try CookieImporter.readCookies(from: source) { "almonds" }) { error in
            XCTAssertEqual(error as? CookieImporter.ImportError, .init(source: source, failure: .undecryptable))
            XCTAssertTrue(error.localizedDescription.contains("doesn’t decrypt Chrome’s cookies"), error.localizedDescription)
        }
    }

    /// Some cookies don't decrypt: counted, so the result says some are
    /// missing.
    func testCookiesThatDoNotDecryptAreCounted() throws {
        let source = try makeSource(Self.standardRows + [Row(host: ".example.net", name: "other", secret: "x", password: "almonds")])
        XCTAssertEqual(try CookieImporter.readCookies(from: source) { "peanuts" }, .init(cookies: Self.decryptedRows, undecryptable: 1))
    }

    /// Before version 24 nothing checks a value: about 1% of a wrong key's
    /// output still reads as UTF-8. Most values failing means the key is
    /// wrong, not that a few cookies are.
    func testAWrongKeyFailsBeforeVersion24Too() throws {
        let short = (0..<1000).map { Row(host: ".example\($0).com", name: "s", secret: "v\($0)") }
        let source = try makeSource(Self.standardRows + short, version: 23)
        XCTAssertThrowsError(try CookieImporter.readCookies(from: source) { "almonds" }) { error in
            XCTAssertEqual((error as? CookieImporter.ImportError)?.failure, .undecryptable)
        }
    }

    /// Before version 24, a wrong key's output that is empty proves
    /// nothing: "v193" decrypts to "" with the wrong key.
    func testAnEmptyValueDoesNotVouchForTheKeyBeforeVersion24() throws {
        let source = try makeSource([Row(host: ".example.com", name: "s", secret: "v193")], version: 23)
        XCTAssertThrowsError(try CookieImporter.readCookies(from: source) { "almonds" }) { error in
            XCTAssertEqual((error as? CookieImporter.ImportError)?.failure, .undecryptable)
        }
    }

    /// Leftovers of an older Keychain key beside the current one, before
    /// version 24: the cookies the current key reads still import.
    func testOlderKeyLeftoversDoNotBlockTheRestBeforeVersion24() throws {
        let good = (0..<20).map { Row(host: ".good\($0).com", name: "good", secret: "g\($0)") }
        let old = (0..<60).map { Row(host: ".old\($0).com", name: "old", secret: "o\($0)", password: "almonds") }
        let read = try CookieImporter.readCookies(from: makeSource(good + old, version: 23)) { "peanuts" }
        XCTAssertEqual(read.cookies.filter { $0.name == "good" }.map(\.value), (0..<20).map { "g\($0)" })
        XCTAssertGreaterThanOrEqual(read.undecryptable, 55)
    }

    /// A value whose hash checks out but isn't text: that cookie is left
    /// out, the key isn't blamed and the others still import.
    func testAValueThatIsNotTextIsNotAWrongKey() throws {
        let source = try makeSource([Self.standardRows[0], Row(host: ".example.org", name: "bytes", secretBytes: [0xFF, 0xFE, 0x80])])
        XCTAssertEqual(try CookieImporter.readCookies(from: source) { "peanuts" }, .init(cookies: [Self.plainCookie], undecryptable: 1))
    }

    /// A value whose domain hash isn't its cookie's: not imported, counted.
    func testAValueWhoseDomainHashDoesNotMatchIsNotImported() throws {
        let source = try makeSource(Self.standardRows + [Row(host: ".example.net", name: "moved", secret: "x", hashHost: ".example.org")])
        XCTAssertEqual(try CookieImporter.readCookies(from: source) { "peanuts" }, .init(cookies: Self.decryptedRows, undecryptable: 1))
    }

    /// Version 24 puts the domain's hash before the value: an empty value
    /// decrypts to just the hash, not to a wrong key.
    func testAnEmptyEncryptedValueIsNotAWrongKey() throws {
        let source = try makeSource([Self.standardRows[0], Row(host: ".example.org", name: "empty", secret: "")])
        XCTAssertEqual(try CookieImporter.readCookies(from: source) { "peanuts" }.cookies, [Self.plainCookie])
    }

    func testAProfileWithoutEncryptedCookiesNeverAsksTheKeychain() throws {
        let source = try makeSource([Self.standardRows[0]])
        var askedKeychain = false
        XCTAssertEqual(try CookieImporter.readCookies(from: source) { askedKeychain = true; return "peanuts" }.cookies, [Self.plainCookie])
        XCTAssertFalse(askedKeychain)
    }

    /// A page that doesn't read: not a partial import.
    func testADamagedDatabaseFailsTheImport() throws {
        let rows = (0..<300).map { Row(host: ".example\($0).com", name: "c", plain: String(repeating: "v", count: 200)) }
        let source = try makeSource(rows)
        let file = try FileHandle(forUpdating: URL(fileURLWithPath: source.cookiesPath))
        let size = try file.seekToEnd()
        try file.seek(toOffset: size - 4096)
        try file.write(contentsOf: Data(repeating: 0xFF, count: 4096))
        try file.close()

        XCTAssertThrowsError(try CookieImporter.readCookies(from: source) { "peanuts" }) { error in
            let failure = (error as? CookieImporter.ImportError)?.failure
            XCTAssertTrue(failure?.isDamage == true, "\(error)")
        }
    }

    /// A meta table that doesn't read used to mean version 0: every value
    /// kept its domain hash and the Keychain's key took the blame.
    func testAMetaTableThatDoesNotReadFailsTheImport() throws {
        let source = try makeSource(Self.standardRows)
        // Page 2 holds the meta table, created first.
        let file = try FileHandle(forUpdating: URL(fileURLWithPath: source.cookiesPath))
        try file.seek(toOffset: 4096)
        try file.write(contentsOf: Data(repeating: 0xFF, count: 4096))
        try file.close()

        XCTAssertThrowsError(try CookieImporter.readCookies(from: source) { "peanuts" }) { error in
            let failure = (error as? CookieImporter.ImportError)?.failure
            XCTAssertTrue(failure?.isDamage == true, "\(error)")
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
        /// Encrypts `secret` with another key than the database's.
        var password: String?
        /// Puts another domain's hash before `secret`.
        var hashHost: String?
        /// Stored encrypted when set, raw bytes rather than text.
        var secretBytes: [UInt8]?
    }

    private static let plainCookie = CookieImporter.RawCookie(
        domain: ".example.com", name: "plain", value: "1", path: "/", expiresUtc: 0, isSecure: false, isHttpOnly: false
    )

    private static let standardRows = [
        Row(host: ".example.com", name: "plain", plain: "1"),
        Row(host: ".example.org", name: "session", secret: "s3cret", path: "/app", expires: 13_400_000_000_000_000, secure: true, httpOnly: true),
    ]

    private static let decryptedRows: [CookieImporter.RawCookie] = [
        plainCookie,
        .init(
            domain: ".example.org", name: "session", value: "s3cret", path: "/app",
            expiresUtc: 13_400_000_000_000_000, isSecure: true, isHttpOnly: true
        ),
    ]

    private func write(_ text: String, to path: String, modified offset: TimeInterval = 0) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: offset)], ofItemAtPath: path)
    }

    private func lock(_ folder: String, mode: mode_t) throws {
        XCTAssertEqual(chmod(folder, mode), 0)
        lockedFolders.append(folder)
    }

    /// Arc with a Local State Nirux can't read, in a folder it can enter but
    /// not list: what a macOS block looks like, with EACCES for EPERM.
    private func makeUnlistableBrowser(at folder: String = "Arc/User Data", withDefaultCookies: Bool = false) throws -> String {
        let browser = root + "/Library/Application Support/" + folder
        if withDefaultCookies { try write("", to: browser + "/Default/Cookies") }
        try write("{}", to: browser + "/Local State")
        XCTAssertEqual(chmod(browser + "/Local State", 0), 0)
        try lock(browser, mode: 0o300)
        return browser
    }

    private func openDatabase(at path: String) throws -> OpaquePointer {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        return try XCTUnwrap(db)
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }

    /// A Chrome cookie database of `version` at Cookies-v<version>, its
    /// secrets encrypted with the key Chrome derives from `password`.
    private func makeSource(_ rows: [Row], password: String = "peanuts", version: Int = 24) throws -> CookieImporter.Source {
        let path = root + "/Cookies-v\(version)"
        let db = try openDatabase(at: path)
        defer { sqlite3_close(db) }
        try fill(db, with: rows, password: password, version: version)
        return CookieImporter.Source(browser: .chrome, profileFolder: "Profile 2", profileName: "Work", cookiesPath: path)
    }

    private func fill(_ db: OpaquePointer, with rows: [Row], password: String = "peanuts", version: Int = 24) throws {
        exec(db, "CREATE TABLE meta (key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR)")
        exec(db, "INSERT INTO meta VALUES ('version', '\(version)')")
        exec(db, """
            CREATE TABLE cookies (host_key TEXT NOT NULL, name TEXT NOT NULL, value TEXT NOT NULL,
            encrypted_value BLOB NOT NULL, path TEXT NOT NULL, expires_utc INTEGER NOT NULL,
            is_secure INTEGER NOT NULL, is_httponly INTEGER NOT NULL)
            """)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO cookies VALUES (?, ?, ?, ?, ?, ?, ?, ?)", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        exec(db, "BEGIN")
        for row in rows {
            let blob = try (row.secretBytes ?? row.secret.map { Array($0.utf8) }).map {
                try encrypted($0, host: row.hashHost ?? row.host, password: row.password ?? password, version: version)
            } ?? Data()
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
        exec(db, "COMMIT")
    }

    /// "v10" + AES-128-CBC, as Chrome encrypts cookie values on macOS; from
    /// version 24 the SHA-256 of the domain comes before the value.
    private func encrypted(_ value: [UInt8], host: String, password: String, version: Int) throws -> Data {
        var key = Data(count: 16)
        let salt = Array("saltysalt".utf8)
        let derived = key.withUnsafeMutableBytes { keyBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, keyBytes.bindMemory(to: UInt8.self).baseAddress, 16
            )
        }
        XCTAssertEqual(derived, Int32(kCCSuccess))
        var plain = value
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
