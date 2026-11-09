import Foundation
import Security
import CommonCrypto
import CryptoKit
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

    /// A browser profile with a cookie database, or one Nirux can't read:
    /// the import then fails with the reason instead of the profile
    /// vanishing from the list.
    struct Source: Equatable, Sendable {
        let browser: Browser
        /// The profile's folder: "Default", "Profile 2". Nil when Nirux
        /// can't see the browser's profiles at all.
        let profileFolder: String?
        /// The profile's name, as the browser shows it.
        let profileName: String?
        let cookiesPath: String
        /// Why it can't be read, found while listing it.
        var blocked: Failure? = nil

        /// "Chrome — Work", for the browser choice.
        var title: String { profileName.map { "\(browser.rawValue) — \($0)" } ?? browser.rawValue }

        /// "Chrome, profile “Work”", inside a sentence.
        var phrase: String { profileName.map { "\(browser.rawValue), profile “\($0)”" } ?? browser.rawValue }
    }

    struct ImportResult: Sendable {
        let imported: Int
        /// Cookies that didn't decrypt or that WebKit refused.
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

    /// What reading a profile found.
    struct Read: Equatable, Sendable {
        var cookies: [RawCookie]
        /// Encrypted cookies whose value didn't decrypt, left out.
        var undecryptable: Int
    }

    /// Import cookies from a browser profile into WKWebView's cookie store.
    @MainActor
    static func importCookies(from source: Source, into dataStore: WKWebsiteDataStore) async throws -> ImportResult {
        // Off the main thread: the read, and the Keychain prompt's wait.
        let read = try await Task.detached {
            try readCookies(from: source) { try keychainPassword(for: source.browser) }
        }.value

        var imported = 0
        var failed = read.undecryptable
        let cookieStore = dataStore.httpCookieStore

        for cookie in read.cookies {
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

    /// Reads and decrypts a profile's cookies, from a snapshot of the
    /// database (see `Snapshot`). A snapshot taken as the browser writes can
    /// still come out damaged: one more try before saying so. The Keychain
    /// is asked once, at the first encrypted cookie: no prompt for a
    /// database that can't be read, or that has nothing to decrypt.
    static func readCookies(from source: Source, password: () throws -> String) throws -> Read {
        var derived: Data?
        func key() throws -> Data {
            if let derived { return derived }
            let key = try pbkdf2(password: password())
            derived = key
            return key
        }
        do {
            if let blocked = source.blocked { throw blocked }
            do {
                return try readSnapshot(of: source.cookiesPath, key: key)
            } catch let failure as Failure where failure.isDamage {
                Thread.sleep(forTimeInterval: 0.2)
                return try readSnapshot(of: source.cookiesPath, key: key)
            }
        } catch let failure as Failure {
            throw ImportError(source: source, failure: failure)
        }
    }

    // MARK: - Profiles

    /// The browsers to offer the import for: those that ran here, a Local
    /// State, or at least left a Default cookie file. Only stat(2): the
    /// menu and the palette ask on every opening, and reading could raise
    /// a macOS privacy prompt before the user asked for anything. The click
    /// reads the profiles and says when it finds none.
    static func browsersToOffer(home: String = NSHomeDirectory()) -> [Browser] {
        Browser.allCases.filter { browser in
            let root = userDataRoot(of: browser, home: home)
            if case .missing = cookieFile(inProfile: root + "/Default") { return false }
            return true
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
        var profiles = LocalStateProfiles(data: nil)
        var localStateFailure: Failure?
        do {
            profiles = LocalStateProfiles(data: try readFile(at: root + "/Local State"))
        } catch let failure as Failure where !failure.isMissingFile {
            localStateFailure = failure
        } catch {}

        var folders = profiles.ranked
        var listingFailure: Failure?
        if folders.isEmpty {
            do {
                folders = try profileFolders(in: root)
            } catch let failure as Failure where !failure.isMissingFile {
                listingFailure = failure
            } catch {}
        }
        let found = folders.compactMap { folder -> Source? in
            let name = profiles.names[folder] ?? folder
            switch cookieFile(inProfile: root + "/" + folder) {
            case .found(let path):
                return Source(browser: browser, profileFolder: folder, profileName: name, cookiesPath: path)
            case .unreachable(let failure):
                return Source(
                    browser: browser, profileFolder: folder, profileName: name, cookiesPath: root + "/" + folder + "/Cookies",
                    blocked: failure
                )
            case .missing:
                return nil
            }
        }
        // Nothing found, and neither the profile list nor the folder could
        // be read: name the browser and why, not a profile it may not have.
        if found.isEmpty, let listingFailure {
            return [Source(
                browser: browser, profileFolder: nil, profileName: nil, cookiesPath: root, blocked: localStateFailure ?? listingFailure
            )]
        }
        return found
    }

    private enum CookieFile {
        case found(String)
        /// Its folder can't be looked into.
        case unreachable(Failure)
        case missing
    }

    /// Chromium moved the database into Network/ on some platforms; either
    /// file can stay behind, stale: the last written one.
    private static func cookieFile(inProfile folder: String) -> CookieFile {
        var newest: (path: String, modified: Double)?
        var unreachable: Failure?
        for path in [folder + "/Network/Cookies", folder + "/Cookies"] {
            var info = stat()
            guard stat(path, &info) == 0 else {
                if errno != ENOENT, errno != ENOTDIR { unreachable = .unreadable(path: path, errno: errno) }
                continue
            }
            let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            if modified > newest?.modified ?? -.infinity { newest = (path, modified) }
        }
        // One candidate Nirux can't look at may be the live file: say so
        // rather than import the other, maybe stale.
        if let unreachable { return .unreachable(unreachable) }
        return newest.map { .found($0.path) } ?? .missing
    }

    /// Without a profile list, the folders Chromium names for profiles.
    /// The URL listing: its errors carry the errno (the path one reports a
    /// missing folder as OSStatus -43). It doesn't follow a symlinked
    /// folder (ENOTDIR), as when the browser's data moved to another
    /// volume: resolve it first.
    private static func profileFolders(in root: String) throws -> [String] {
        let names: [String]
        do {
            let folder = URL(fileURLWithPath: root)
            names = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).map(\.lastPathComponent)
        } catch {
            throw Failure.unreadable(path: root, errno: posixCode(of: error))
        }
        let profiles = names.filter { $0.hasPrefix("Profile ") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return (names.contains("Default") ? ["Default"] : []) + profiles
    }

    /// The profile list in the browser's Local State file.
    struct LocalStateProfiles {
        /// Profile folder → name, told apart when two are alike.
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
            // tell them apart by account; one name and one account, by
            // folder.
            let bare = names
            for (folder, name) in bare where Self.count(name, in: bare) > 1 {
                names[folder] = "\(name) (\(accounts[folder] ?? folder))"
            }
            let byAccount = names
            for (folder, label) in byAccount where Self.count(label, in: byAccount) > 1 {
                names[folder] = "\(bare[folder] ?? folder) (\(folder))"
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

        private static func count(_ label: String, in names: [String: String]) -> Int {
            names.values.filter { $0 == label }.count
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

    private static func pbkdf2(password: String) throws -> Data {
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
        guard status == kCCSuccess else { throw Failure.keyDerivation(status) }
        return key
    }

    // MARK: - Decryption

    private static func isEncrypted(_ blob: Data) -> Bool {
        blob.count > 3 && (blob.prefix(3) == Data("v10".utf8) || blob.prefix(3) == Data("v11".utf8))
    }

    private enum Decrypted {
        case value(String)
        /// The key checked out (the domain hash matched) but the value
        /// isn't text: that cookie only.
        case notText
        /// The domain hash didn't match, or before version 24, no text.
        case wrongKey
    }

    /// The value of an encrypted ("v10"/"v11") blob. From database version
    /// 24, Chrome puts the SHA-256 of the cookie's domain (`domainHash`)
    /// before the value. It is the only check: CommonCrypto doesn't reject
    /// a wrong key, and its output, past the hash, can still read as UTF-8.
    private static func decryptValue(_ blob: Data, key: Data, domainHash: Data?) -> Decrypted {
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

        guard status == CCCryptorStatus(kCCSuccess) else { return .wrongKey }
        plain.count = outLen
        if let domainHash {
            guard plain.prefix(domainHash.count) == domainHash else { return .wrongKey }
            return String(data: plain.dropFirst(domainHash.count), encoding: .utf8).map { .value($0) } ?? .wrongKey
        }
        return String(data: plain, encoding: .utf8).map { .value($0) } ?? .wrongKey
    }

    // MARK: - SQLite

    /// A private copy of a browser's database, in a folder of Nirux's own:
    /// its WAL or rollback journal first, then the database, each an
    /// instant APFS clone. Recent commits still in the WAL come along, and
    /// a write caught halfway usually comes with the journal that undoes
    /// it; SQLite applies both when it opens the copy. A write that starts
    /// between the two clones can still slip through: SQLite then reports
    /// the damage (see `readCookies`), or the copy mixes old and new
    /// cookies, harmless for an import. The database is opened
    /// before anything else, so a file Nirux may not read fails as itself:
    /// it used to come out as the copy's folder, Foundation's "you don't
    /// have permission to access “T”".
    private struct Snapshot {
        let folder: String
        var database: String { folder + "/Cookies" }

        init(of path: String) throws {
            let source = open(path, O_RDONLY | O_CLOEXEC)
            guard source >= 0 else { throw Failure.unreadable(path: path, errno: errno) }
            defer { close(source) }
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-cookies-\(UUID().uuidString)").path
            guard mkdir(folder, 0o700) == 0 else { throw Failure.temporaryCopy(path: folder, errno: errno) }
            do {
                for suffix in ["-wal", "-journal"] {
                    let companion = open(path + suffix, O_RDONLY | O_CLOEXEC)
                    let code = errno
                    if companion < 0, code == ENOENT { continue }
                    guard companion >= 0 else { throw Failure.unreadable(path: path + suffix, errno: code) }
                    defer { close(companion) }
                    try Self.copy(companion, from: path + suffix, to: database + suffix)
                }
                try Self.copy(source, from: path, to: database)
            } catch {
                delete()
                throw error
            }
        }

        func delete() {
            try? FileManager.default.removeItem(atPath: folder)
        }

        /// An APFS clone or, when cloning fails for any reason, a byte copy
        /// that tells a source that won't read from a copy that won't
        /// write. Writable: SQLite rolls a journal back into the copy.
        private static func copy(_ source: Int32, from sourcePath: String, to destination: String) throws {
            if fclonefileat(source, AT_FDCWD, destination, 0) != 0 {
                let target = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                guard target >= 0 else { throw Failure.temporaryCopy(path: destination, errno: errno) }
                defer { close(target) }
                var buffer = [UInt8](repeating: 0, count: 1 << 16)
                var offset: off_t = 0
                while true {
                    let count = pread(source, &buffer, buffer.count, offset)
                    if count < 0, errno == EINTR { continue }
                    guard count >= 0 else { throw Failure.unreadable(path: sourcePath, errno: errno) }
                    if count == 0 { break }
                    var written = 0
                    while written < count {
                        let wrote = buffer.withUnsafeBytes { write(target, $0.baseAddress! + written, count - written) }
                        if wrote < 0, errno == EINTR { continue }
                        guard wrote >= 0 else { throw Failure.temporaryCopy(path: destination, errno: errno) }
                        written += wrote
                    }
                    offset += off_t(count)
                }
            }
            chmod(destination, 0o600)
        }
    }

    private static func readSnapshot(of path: String, key: () throws -> Data) throws -> Read {
        let snapshot = try Snapshot(of: path)
        defer { snapshot.delete() }
        var connection: OpaquePointer?
        // Read-write, on Nirux's own copy: SQLite rolls back an unfinished
        // write and applies the WAL.
        guard sqlite3_open_v2(snapshot.database, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = connection else {
            let failure = databaseFailure(connection)
            sqlite3_close(connection)
            throw failure
        }
        defer { sqlite3_close(db) }
        let statement = try prepareCookieQuery(db)
        defer { sqlite3_finalize(statement) }
        return try readRows(statement, of: db, hashesDomain: schemaVersion(of: db) >= 24, key: key)
    }

    /// The whole file, or the errno that stopped reading it.
    private static func readFile(at path: String) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unreadable(path: path, errno: errno) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            throw Failure.unreadable(path: path, errno: posixCode(of: error))
        }
    }

    private static func posixCode(of error: Error) -> Int32 {
        let cocoa = error as NSError
        let posix = cocoa.domain == NSPOSIXErrorDomain ? cocoa : cocoa.userInfo[NSUnderlyingErrorKey] as? NSError
        return posix.map { Int32($0.code) } ?? EIO
    }

    private static func databaseFailure(_ db: OpaquePointer?) -> Failure {
        .database(code: sqlite3_extended_errcode(db) & 0xFF, message: String(cString: sqlite3_errmsg(db)))
    }

    private static func prepareCookieQuery(_ db: OpaquePointer) throws -> OpaquePointer {
        let sql = "SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly FROM cookies"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let failure = databaseFailure(db)
            sqlite3_finalize(statement)
            throw failure
        }
        return statement
    }

    /// The cookie database's version, in its meta table; 0 without one. A
    /// meta table that doesn't read is a failure, not version 0: that
    /// would leave the domain hash on every value.
    private static func schemaVersion(of db: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version'", -1, &statement, nil) == SQLITE_OK else {
            if String(cString: sqlite3_errmsg(db)).hasPrefix("no such table") { return 0 }
            throw databaseFailure(db)
        }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return Int(sqlite3_column_int64(statement, 0))
        case SQLITE_DONE: return 0
        default: throw databaseFailure(db)
        }
    }

    private static func readRows(
        _ statement: OpaquePointer, of db: OpaquePointer, hashesDomain: Bool, key: () throws -> Data
    ) throws -> Read {
        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        var cookies: [RawCookie] = []
        var encrypted = 0
        var decrypted = 0
        var keyChecked = 0
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(statement) }
            var cookieValue = text(2)
            if cookieValue.isEmpty, let blobPtr = sqlite3_column_blob(statement, 3) {
                let blob = Data(bytes: blobPtr, count: Int(sqlite3_column_bytes(statement, 3)))
                if isEncrypted(blob) {
                    encrypted += 1
                    let domainHash = hashesDomain ? Data(SHA256.hash(data: Data(text(0).utf8))) : nil
                    switch try decryptValue(blob, key: key(), domainHash: domainHash) {
                    case .value(let value):
                        decrypted += 1
                        keyChecked += 1
                        cookieValue = value
                    case .notText:
                        keyChecked += 1
                    case .wrongKey:
                        break
                    }
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
        // A page that doesn't read: not a partial import passed off as the
        // whole.
        guard step == SQLITE_DONE else { throw databaseFailure(db) }
        // The Keychain's key isn't the one the browser encrypted them with:
        // from version 24, not one domain hash matched; before, nothing
        // checks a value and about 1% of a wrong key's output reads as
        // text, so most values failing says it.
        if encrypted > 0, keyChecked == 0 { throw Failure.undecryptable }
        return Read(cookies: cookies, undecryptable: encrypted - decrypted)
    }

    // MARK: - Errors

    /// What stopped an import, before it knows which profile it was.
    enum Failure: Error, Equatable, Sendable {
        /// open(2), stat(2), read(2) or a folder listing failed with this
        /// errno.
        case unreadable(path: String, errno: Int32)
        /// Nirux couldn't make its private copy of the database there.
        case temporaryCopy(path: String, errno: Int32)
        /// The Keychain refused the browser's key with this status.
        case keychain(OSStatus)
        /// CommonCrypto couldn't derive the key from the Keychain's
        /// password.
        case keyDerivation(Int32)
        /// SQLite couldn't read the database: its primary result code and
        /// message.
        case database(code: Int32, message: String)
        /// None of the encrypted cookies decrypts with the Keychain's key.
        case undecryptable

        /// A damaged copy, as when the browser wrote while it was taken.
        var isDamage: Bool {
            if case .database(let code, _) = self { return code == SQLITE_CORRUPT || code == SQLITE_NOTADB }
            return false
        }

        var isMissingFile: Bool {
            if case .unreadable(_, let code) = self { return code == ENOENT || code == ENOTDIR }
            return false
        }
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
                    return "macOS blocked Nirux from reading \(browser)’s files. In System Settings › Privacy & Security › "
                        + "Full Disk Access, add Nirux and turn it on, then quit and reopen Nirux and try again."
                case EACCES:
                    return "Nirux doesn’t have permission to read \(file).\(Self.ownerNote(path))"
                case ENOENT:
                    return "\(file) is gone. Open \(browser), then try again."
                default:
                    return "Reading \(file) failed: \(String(cString: strerror(code)))."
                }
            case .temporaryCopy(let path, let code):
                let place = (path as NSString).abbreviatingWithTildeInPath
                return "Nirux couldn’t make its working copy at \(place): \(String(cString: strerror(code)))."
            case .keychain(errSecItemNotFound):
                return "\(browser)’s key isn’t in your login Keychain. Open \(browser) once on this Mac account, then try again."
            case .keychain(errSecUserCanceled), .keychain(errSecAuthFailed):
                return "The Keychain didn’t give Nirux “\(source.browser.keychainService)”. Try again and click Allow when macOS asks."
            case .keychain(errSecInteractionNotAllowed):
                return "The Keychain is locked. Unlock it, then try again."
            case .keychain(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
                return "The Keychain refused “\(source.browser.keychainService)”: \(message)."
            case .keyDerivation(let status):
                return "Nirux couldn’t derive \(browser)’s decryption key from the Keychain’s password (CommonCrypto error \(status))."
            case .database(let code, let message) where failure.isDamage:
                return "\(browser)’s cookie file reads as damaged (\(message), code \(code)), as when \(browser) writes it at "
                    + "that moment. Try again in a moment."
            case .database(_, let message):
                return "\(browser)’s cookie file can’t be read as a database: \(message)."
            case .undecryptable:
                return "The key in your Keychain doesn’t decrypt \(browser)’s cookies."
            }
        }

        /// " It belongs to the user “x”." (or its folder does) when someone
        /// else owns it.
        private static func ownerNote(_ path: String) -> String {
            for (item, subject) in [(path, "It"), ((path as NSString).deletingLastPathComponent, "Its folder")] {
                var info = stat()
                guard stat(item, &info) == 0 else { continue }
                guard info.st_uid != getuid() else { return "" }
                let name = getpwuid(info.st_uid).flatMap { String(validatingCString: $0.pointee.pw_name) }
                return " \(subject) belongs to \(name.map { "the user “\($0)”" } ?? "another user")."
            }
            return ""
        }
    }
}
