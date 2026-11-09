import Foundation
import Security
import CommonCrypto
import WebKit
import SQLite3

/// Imports cookies from a Chrome, Brave, Arc or Edge profile into a
/// WKWebsiteDataStore.
enum CookieImporter {

    enum Browser: String, CaseIterable, Sendable {
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

        /// The browser's profiles folder, inside Application Support.
        var userDataFolder: String {
            switch self {
            case .chrome: "Google/Chrome"
            case .brave: "BraveSoftware/Brave-Browser"
            case .arc: "Arc/User Data"
            case .edge: "Microsoft Edge"
            }
        }
    }

    /// One browser profile that has a cookie database.
    struct Source: Equatable, Sendable {
        let browser: Browser
        /// The profile's folder: "Default", "Profile 2".
        let profileFolder: String
        /// The profile's name, as the browser shows it.
        let profileName: String
        let cookiesPath: String

        /// "Chrome — Work", for the browser choice.
        var title: String { "\(browser.rawValue) — \(profileName)" }

        /// "Chrome, profile “Work”", inside a sentence.
        var phrase: String { "\(browser.rawValue), profile “\(profileName)”" }
    }

    struct ImportResult: Sendable {
        let imported: Int
        let failed: Int
        let source: Source
    }

    /// A cookie as the browser stored it, its value decrypted.
    struct RawCookie: Equatable, Sendable {
        let domain: String
        let name: String
        let value: String
        let path: String
        let expiresUtc: Int64
        let isSecure: Bool
        let isHttpOnly: Bool
    }

    /// Import cookies from a browser profile into WKWebView's cookie store.
    @MainActor
    static func importCookies(from source: Source, into dataStore: WKWebsiteDataStore) async throws -> ImportResult {
        // Off the main thread: the read, and the Keychain prompt's wait.
        let cookies = try await Task.detached {
            try readCookies(from: source) { try keychainPassword(for: source.browser) }
        }.value

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

        return ImportResult(imported: imported, failed: failed, source: source)
    }

    /// Reads and decrypts a profile's cookies. The database is read into
    /// memory, never copied into the temporary folder, so a failure names
    /// the real cause: a cookie file macOS won't let Nirux read used to come
    /// out as Foundation's "you don't have permission to access “T”", the
    /// temporary folder. The Keychain is asked at the first encrypted
    /// cookie: no prompt for a database that can't be read, or that has
    /// nothing to decrypt.
    static func readCookies(from source: Source, password: () throws -> String) throws -> [RawCookie] {
        do {
            let db = try openInMemory(readFile(at: source.cookiesPath))
            defer { sqlite3_close(db) }
            let statement = try prepareCookieQuery(db)
            defer { sqlite3_finalize(statement) }
            return try readRows(statement, of: db, hashesDomain: true, password: password)
        } catch let failure as Failure {
            throw ImportError(source: source, failure: failure)
        }
    }

    // MARK: - Profiles

    /// The browsers to offer the import for. Only checks that files exist:
    /// reading them could raise a macOS privacy prompt as the menu or the
    /// palette opens, before the user asked for anything.
    static func installedBrowsers(home: String = NSHomeDirectory()) -> [Browser] {
        Browser.allCases.filter { browser in
            let root = userDataRoot(of: browser, home: home)
            return ["/Local State", "/Default/Cookies", "/Default/Network/Cookies"].contains {
                FileManager.default.fileExists(atPath: root + $0)
            }
        }
    }

    /// The profiles with a cookie database, browser by browser, each
    /// browser's last used profile first.
    static func availableSources(home: String = NSHomeDirectory()) -> [Source] {
        Browser.allCases.flatMap { sources(of: $0, home: home) }
    }

    private static func userDataRoot(of browser: Browser, home: String) -> String {
        home + "/Library/Application Support/" + browser.userDataFolder
    }

    private static func sources(of browser: Browser, home: String) -> [Source] {
        let root = userDataRoot(of: browser, home: home)
        let localState: Data?
        do {
            localState = try readFile(at: root + "/Local State")
        } catch Failure.unreadable(_, EPERM) {
            // macOS keeps Nirux out of the browser's folder, profile list
            // included: the import names the block instead of finding nothing.
            // Looking files up still works there.
            let cookies = cookiesPath(inProfile: root + "/Default") ?? root + "/Default/Cookies"
            return [Source(browser: browser, profileFolder: "Default", profileName: "Default", cookiesPath: cookies)]
        } catch {
            localState = nil
        }
        let profiles = LocalStateProfiles(data: localState)
        // Without a profile list, the folders Chromium names for profiles.
        let folders = profiles.ranked.isEmpty ? scannedProfileFolders(in: root) : profiles.ranked
        return folders.compactMap { folder in
            guard let cookies = cookiesPath(inProfile: root + "/" + folder) else { return nil }
            return Source(
                browser: browser, profileFolder: folder, profileName: profiles.names[folder] ?? folder, cookiesPath: cookies
            )
        }
    }

    /// Chromium moved the database into Network/ on some platforms; either
    /// file can stay behind, stale: the last written one.
    private static func cookiesPath(inProfile folder: String) -> String? {
        let files = ["/Network/Cookies", "/Cookies"].compactMap { name -> (path: String, modified: Date)? in
            let path = folder + name
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
            return (path, attributes[.modificationDate] as? Date ?? .distantPast)
        }
        return files.max { $0.modified < $1.modified }?.path
    }

    private static func scannedProfileFolders(in root: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        let profiles = names.filter { $0.hasPrefix("Profile ") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return ["Default"] + profiles
    }

    /// The profile list in the browser's Local State file.
    struct LocalStateProfiles {
        /// Profile folder → name.
        var names: [String: String] = [:]
        /// Profile folders, last used first, then in the browser's order.
        var ranked: [String] = []

        init(data: Data?) {
            guard let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let profile = root["profile"] as? [String: Any],
                  let cache = profile["info_cache"] as? [String: Any]
            else { return }
            var accounts: [String: String] = [:]
            for (folder, entry) in cache {
                let info = entry as? [String: Any] ?? [:]
                func text(_ key: String) -> String? { (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
                // A signed-in profile still named "Person 2": Chrome shows
                // the account's name.
                let accountName = info["is_using_default_name"] as? Bool == true ? text("gaia_given_name") ?? text("gaia_name") : nil
                names[folder] = accountName ?? text("name") ?? folder
                accounts[folder] = text("user_name")
            }
            // Two profiles with one name, say two accounts of one person:
            // tell them apart by account, else by folder.
            let counts = Dictionary(names.values.map { ($0, 1) }, uniquingKeysWith: +)
            for (folder, name) in names where counts[name, default: 0] > 1 {
                names[folder] = "\(name) (\(accounts[folder] ?? folder))"
            }
            let preferred = [profile["last_used"] as? String].compactMap { $0 }
                + (profile["last_active_profiles"] as? [String] ?? [])
                + (profile["profiles_order"] as? [String] ?? [])
                + names.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            // Only profiles the browser still lists: a deleted one's folder
            // can linger.
            for folder in preferred where names[folder] != nil && !ranked.contains(folder) {
                ranked.append(folder)
            }
        }
    }

    // MARK: - Keychain

    private static func keychainPassword(for browser: Browser) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: browser.keychainService,
            kSecAttrAccount as String: browser.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw Failure.keychain(errSecDecode)
        }
        return password
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

    private static func isEncrypted(_ blob: Data) -> Bool {
        blob.count > 3 && (blob.prefix(3) == Data("v10".utf8) || blob.prefix(3) == Data("v11".utf8))
    }

    /// The value of an encrypted ("v10"/"v11") blob. From database version
    /// 24, Chrome puts the SHA-256 of the cookie's domain (32 bytes) before
    /// the value.
    private static func decryptValue(_ blob: Data, key: Data, hashesDomain: Bool) -> String? {
        let ciphertext = blob.dropFirst(3)
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

        if hashesDomain {
            guard plain.count >= 32 else { return nil }
            plain = plain.dropFirst(32)
        }
        return String(data: plain, encoding: .utf8)
    }

    // MARK: - SQLite

    /// The whole file, or the errno that stopped reading it.
    private static func readFile(at path: String) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unreadable(path: path, errno: errno) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            let cocoa = error as NSError
            let posix = cocoa.domain == NSPOSIXErrorDomain ? cocoa : cocoa.userInfo[NSUnderlyingErrorKey] as? NSError
            throw Failure.unreadable(path: path, errno: posix.map { Int32($0.code) } ?? EIO)
        }
    }

    /// A read-only connection to a database held in memory. The browser
    /// keeps its file locked, hence the copy.
    private static func openInMemory(_ data: Data) throws -> OpaquePointer {
        guard !data.isEmpty else { throw Failure.database("the file is empty") }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = connection else {
            sqlite3_close(connection)
            throw Failure.database("SQLite can’t open a database in memory")
        }
        guard let buffer = sqlite3_malloc64(UInt64(data.count))?.assumingMemoryBound(to: UInt8.self) else {
            sqlite3_close(db)
            throw Failure.database("not enough memory to read it")
        }
        data.copyBytes(to: buffer, count: data.count)
        // A database in WAL mode can't be read from memory: mark it as a
        // rollback journal one (bytes 18 and 19 of the header).
        if data.count > 19, buffer[18] == 2 || buffer[19] == 2 {
            buffer[18] = 1
            buffer[19] = 1
        }
        let flags = UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_READONLY)
        guard sqlite3_deserialize(db, "main", buffer, Int64(data.count), Int64(data.count), flags) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw Failure.database(message)
        }
        return db
    }

    private static func prepareCookieQuery(_ db: OpaquePointer) throws -> OpaquePointer {
        let sql = "SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly FROM cookies"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(statement)
            throw Failure.database(message)
        }
        return statement
    }

    /// The cookie database's version, in its meta table; 0 without one.
    private static func schemaVersion(of db: OpaquePointer) -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version'", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW
        else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func readRows(
        _ statement: OpaquePointer, of db: OpaquePointer, hashesDomain: Bool, password: () throws -> String
    ) throws -> [RawCookie] {
        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        var derivedKey: Data?
        func key() throws -> Data {
            if let derivedKey { return derivedKey }
            guard let key = pbkdf2(password: try password()) else { throw Failure.undecryptable }
            derivedKey = key
            return key
        }
        var cookies: [RawCookie] = []
        var encrypted = 0
        var decrypted = 0
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(statement) }
            var cookieValue = text(2)
            if cookieValue.isEmpty, let blobPtr = sqlite3_column_blob(statement, 3) {
                let blob = Data(bytes: blobPtr, count: Int(sqlite3_column_bytes(statement, 3)))
                if isEncrypted(blob) {
                    encrypted += 1
                    let value = try decryptValue(blob, key: key(), hashesDomain: hashesDomain)
                    if value != nil { decrypted += 1 }
                    cookieValue = value ?? ""
                } else {
                    cookieValue = String(data: blob, encoding: .utf8) ?? ""
                }
            }

            guard !cookieValue.isEmpty else { continue }

            cookies.append(RawCookie(
                domain: text(0), name: text(1), value: cookieValue,
                path: text(4), expiresUtc: sqlite3_column_int64(statement, 5),
                isSecure: sqlite3_column_int(statement, 6) != 0, isHttpOnly: sqlite3_column_int(statement, 7) != 0
            ))
        }
        // A page that doesn't read, say one the browser was writing: not a
        // partial import passed off as the whole.
        guard step == SQLITE_DONE else { throw Failure.database(String(cString: sqlite3_errmsg(db))) }
        // Not a single one: the Keychain's key isn't the one the browser
        // encrypted them with.
        _ = (encrypted, decrypted)
        return cookies
    }

    // MARK: - Errors

    /// What stopped an import, before it knows which profile it was.
    enum Failure: Error, Equatable {
        /// open(2) or read(2) of the cookie file failed with this errno.
        case unreadable(path: String, errno: Int32)
        /// The Keychain refused the browser's key with this status.
        case keychain(OSStatus)
        /// SQLite couldn't read the database: its message.
        case database(String)
        /// None of the encrypted cookies decrypts with the Keychain's key.
        case undecryptable
    }

    struct ImportError: LocalizedError, Equatable {
        let source: Source
        let failure: Failure

        /// The System Settings pane that lifts the block.
        static let fullDiskAccessSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

        /// macOS privacy protection, not file permissions, kept Nirux out:
        /// Full Disk Access lifts it.
        var isBlockedByPrivacy: Bool {
            if case .unreadable(_, EPERM) = failure { return true }
            return false
        }

        var errorDescription: String? {
            "Nirux couldn’t import cookies from \(source.phrase). \(reason)"
        }

        private var reason: String {
            let browser = source.browser.rawValue
            switch failure {
            case .unreadable(let path, let code):
                let file = (path as NSString).abbreviatingWithTildeInPath
                switch code {
                case EPERM:
                    return "macOS blocked Nirux from reading \(browser)’s cookie file. In System Settings › Privacy & Security › "
                        + "Full Disk Access, add Nirux and turn it on, then quit and reopen Nirux and try again."
                case EACCES:
                    return "Nirux doesn’t have permission to read \(file).\(Self.ownerNote(path))"
                case ENOENT:
                    return "\(file) is gone. Open \(browser), then try again."
                default:
                    return "Reading \(file) failed: \(String(cString: strerror(code)))."
                }
            case .keychain(errSecItemNotFound):
                return "\(browser)’s key isn’t in your login Keychain. Open \(browser) once on this Mac account, then try again."
            case .keychain(errSecUserCanceled), .keychain(errSecAuthFailed):
                return "The Keychain didn’t give Nirux “\(source.browser.keychainService)”. Try again and click Allow when macOS asks."
            case .keychain(errSecInteractionNotAllowed):
                return "The Keychain is locked. Unlock it, then try again."
            case .keychain(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
                return "The Keychain refused “\(source.browser.keychainService)”: \(message)."
            case .database(let message):
                return "\(browser)’s cookie file can’t be read as a database: \(message)."
            case .undecryptable:
                return "The key in your Keychain doesn’t decrypt \(browser)’s cookies."
            }
        }

        /// " It belongs to the user “x”." when someone else owns the file.
        private static func ownerNote(_ path: String) -> String {
            var info = stat()
            guard stat(path, &info) == 0, info.st_uid != getuid() else { return "" }
            guard let entry = getpwuid(info.st_uid), let name = String(validatingCString: entry.pointee.pw_name) else {
                return " It belongs to another user."
            }
            return " It belongs to the user “\(name)”."
        }
    }
}
