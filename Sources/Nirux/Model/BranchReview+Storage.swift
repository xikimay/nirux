import CryptoKit
import Darwin
import Foundation

// MARK: - Storage (section 8)

extension BranchReview {
    /// A file marked reviewed (section 6.3).
    struct ReviewedMark: Equatable, Sendable {
        /// The file's patch hash when it was marked.
        let patchHash: String
        /// The head the page showed then.
        var head: String?
        var date: Date?

        init(patchHash: String, head: String?, date: Date?) {
            self.patchHash = patchHash
            self.head = head
            self.date = date
        }

        init?(json: JSONValue) {
            guard let object = json.objectValue, let patchHash = object["patchHash"]?.stringValue else { return nil }
            self.patchHash = patchHash
            head = object["head"]?.stringValue
            date = object["date"]?.stringValue.flatMap { try? Date($0, strategy: .iso8601) }
        }

        var json: JSONValue {
            var object: [String: JSONValue] = ["patchHash": .string(patchHash)]
            object["head"] = head.map(JSONValue.string)
            object["date"] = date.map { .string($0.formatted(.iso8601)) }
            return .object(object)
        }
    }

    enum ReviewedState: Equatable, Sendable {
        case notReviewed
        case reviewed
        /// Its patch changed since it was marked: "changed since you
        /// reviewed".
        case changedSinceReviewed
        /// Marked, but its patch wasn't read (`Omission.notRead`), so there
        /// is no hash to check the mark against. The mark stays.
        case unverified
    }

    /// One branch's stored review: the file's top-level object, keys this
    /// build doesn't know included, read through typed accessors. R3 to R5
    /// add their own keys beside these (comments, drafts, what was sent,
    /// the explanation cache, usage). An older build keeps a top-level key
    /// it doesn't know, and every entry it doesn't change. A key added
    /// inside an entry (a mark, say) is lost when an older build rewrites
    /// that entry, and a key whose meaning changes needs a new `version`:
    /// older builds then open the file read-only.
    struct Record: Equatable, Sendable {
        static let currentVersion = 1

        private(set) var fields: [String: JSONValue]

        init(fields: [String: JSONValue] = [:]) {
            self.fields = fields
        }

        /// The branch and repository the file is named after.
        var branch: String? { fields["branch"]?.stringValue }
        var repository: String? { fields["repository"]?.stringValue }
        /// The branch's pull request when the review was last opened or
        /// written. Kept when the branch no longer has an open one.
        var pullRequest: Int? { fields["pullRequest"]?.intValue }
        /// The last head reviewed: the one the page showed when the review
        /// was last opened or written.
        var lastHead: String? { fields["lastHead"]?.stringValue }

        /// By path. Malformed entries are skipped, and kept in the file.
        var reviewedMarks: [String: ReviewedMark] {
            fields["reviewed"]?.objectValue?.compactMapValues(ReviewedMark.init(json:)) ?? [:]
        }

        func reviewedState(of file: FileChange) -> ReviewedState {
            guard let mark = fields["reviewed"]?.objectValue?[file.path].flatMap(ReviewedMark.init(json:)) else {
                return .notReviewed
            }
            guard let patchHash = file.patchHash else { return .unverified }
            return patchHash == mark.patchHash ? .reviewed : .changedSinceReviewed
        }

        /// Marks `file` reviewed at its current patch. Nothing changes, and
        /// it returns false, when its patch wasn't read: there is no hash.
        @discardableResult
        mutating func markReviewed(_ file: FileChange, head: String, at date: Date) -> Bool {
            guard let patchHash = file.patchHash else { return false }
            var marks = fields["reviewed"]?.objectValue ?? [:]
            marks[file.path] = ReviewedMark(patchHash: patchHash, head: head, date: date).json
            fields["reviewed"] = .object(marks)
            return true
        }

        /// The user unticked it. Nothing else clears a mark: a changed
        /// patch reads as `changedSinceReviewed`, an unread one as
        /// `unverified`.
        mutating func clearReviewed(path: String) {
            guard var marks = fields["reviewed"]?.objectValue, marks.removeValue(forKey: path) != nil else { return }
            fields["reviewed"] = .object(marks)
        }

        /// What every write records. A pull request is never erased: once
        /// merged or closed, the branch has none, and the number still
        /// tells a reused name from the same branch.
        mutating func stamp(branch: String, repository: String, head: String, pullRequest: Int?) {
            fields["version"] = .int(Int64(Self.currentVersion))
            fields["branch"] = .string(branch)
            fields["repository"] = .string(repository)
            fields["lastHead"] = .string(head)
            if let pullRequest { fields["pullRequest"] = .int(Int64(pullRequest)) }
        }

        enum Version: Equatable, Sendable {
            case current
            case newer(Int)
            /// Neither absent nor a number: a string, a boolean, an object.
            case invalid
        }

        /// Missing or null is the first version. Any number above the
        /// current one is newer, even one that isn't a whole number.
        var version: Version {
            switch fields["version"] {
            case nil, .null?:
                return .current
            case .int(let version)?:
                return version > Self.currentVersion ? .newer(Int(clamping: version)) : .current
            case .double(let version)?:
                if version > Double(Self.currentVersion) {
                    return .newer(Int(exactly: version.rounded(.down)) ?? Int.max)
                }
                return version == version.rounded(.down) ? .current : .invalid
            default:
                return .invalid
            }
        }
    }

    /// Whether a stored review belongs to the branch now under its name.
    enum Disposition: Equatable, Sendable {
        case keep
        /// A reused name's: set aside, and the review starts fresh.
        case archive
        /// git couldn't say: opened read-only until a later try can.
        case unverified
    }

    /// Kept only when its pull request is the branch's, or, when that
    /// can't settle it, when its last head is the branch's head or in the
    /// branch's reflog (`git branch -D` deletes the reflog, a rebase keeps
    /// it). With gh missing or failing, the reflog decides: a review is
    /// never archived for want of gh.
    static func disposition(
        of record: Record, branch: String, repository: String, head: String,
        pullRequest: PullRequestLookup, reflogContains: (String) -> Bool?
    ) -> Disposition {
        guard record.branch == branch, record.repository == repository else { return .archive }
        if let current = pullRequest.pullRequest?.number, let stored = record.pullRequest {
            return stored == current ? .keep : .archive
        }
        guard let lastHead = record.lastHead else { return .archive }
        if lastHead == head { return .keep }
        switch reflogContains(lastHead) {
        case true?: return .keep
        case false?: return .archive
        case nil: return .unverified
        }
    }

    /// Whether `commit` is in the reflog of `refs/heads/<branch>`. Nil when
    /// git couldn't read it.
    static func reflog(of branch: String, contains commit: String, root: String, options: Options) -> Bool? {
        guard let reflog = git(["log", "-g", "--format=%H", "refs/heads/\(branch)", "--"], in: root, options: options),
              reflog.status == 0
        else { return nil }
        return reflog.text.split(separator: "\n").contains { $0 == commit }
    }

    /// The repository a review belongs to: its common git folder
    /// (`--git-common-dir`), symlinks resolved. Every worktree of a
    /// repository shares it, so two repositories of a project can each
    /// have a `main` without sharing a review. Nil when git can't say.
    static func repositoryIdentity(root: String, options: Options = Options()) -> String? {
        guard let output = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: root, options: options),
              output.status == 0
        else { return nil }
        return output.text.trimmingCharacters(in: .newlines).realPath
    }

    /// The review file of one branch in one project:
    /// `<state dir>/reviews/<space id>/<branch>-<hash>.json`. `<branch>` is
    /// percent-encoded and `<hash>` is a hash of the repository
    /// (`repositoryIdentity`) and the exact branch name: APFS ignores case,
    /// so `Fix/A` and `fix/a` need it to differ.
    ///
    /// - Reading never locks: writes replace the file atomically.
    /// - Every write takes a blocking exclusive `flock` on `<file>.lock`,
    ///   held across reading, changing and writing the file, so two writers
    ///   (the installed app and a dev build sharing the state directory)
    ///   both keep their changes. A lock on the data file itself would be
    ///   lost when it is replaced. Writes block: call them off the main
    ///   thread.
    /// - A file from a newer `version`, anything but a regular file, or a
    ///   file over `maxFileBytes` is never written; an unreadable one is
    ///   set aside before the first write replaces it.
    /// - Set-aside files go to `archive/` beside it, and stay there.
    /// - Files are 0600, folders 0700.
    struct Store: Sendable {
        static let folderName = "reviews"
        static let archiveFolderName = "archive"
        /// Comments and the explanation cache are text, but a branch of a
        /// few hundred files can hold a lot of it.
        static let maxFileBytes = 8_000_000
        /// APFS caps a name at 255 bytes; the hash keeps a cut name unique.
        static let maxEncodedBranchBytes = 120

        let branch: String
        let repository: String
        let fileURL: URL

        var lockURL: URL { fileURL.appendingPathExtension("lock") }
        var folder: URL { fileURL.deletingLastPathComponent() }
        var archiveFolder: URL { folder.appendingPathComponent(Self.archiveFolderName, isDirectory: true) }

        /// Nil for a space id that isn't a plain name (see
        /// `SpaceBrief.isPlainSpaceID`), or an empty branch or repository.
        init?(spaceID: String, repository: String, branch: String, stateDirectory: URL = Persistence.stateDirectory) {
            guard SpaceBrief.isPlainSpaceID(spaceID), !repository.isEmpty, !branch.isEmpty else { return nil }
            let folder = stateDirectory.appendingPathComponent(Self.folderName, isDirectory: true)
                .appendingPathComponent(spaceID, isDirectory: true)
            self.init(folder: folder, repository: repository, branch: branch)
        }

        private init(folder: URL, repository: String, branch: String) {
            self.branch = branch
            self.repository = repository
            fileURL = folder.appendingPathComponent(Self.fileName(branch: branch, repository: repository))
        }

        static func fileName(branch: String, repository: String) -> String {
            "\(stem(branch: branch, repository: repository)).json"
        }

        private static func stem(branch: String, repository: String) -> String {
            let digest = SHA256.hash(data: Data("repository\0\(repository)\0branch\0\(branch)".utf8))
            return encodedBranch(branch) + "-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        }

        /// Byte by byte (UTF-8): ASCII letters, digits, "-", "_" and "."
        /// as they are, anything else as `%XX`, cut at
        /// `maxEncodedBranchBytes` without splitting an escape.
        static func encodedBranch(_ branch: String) -> String {
            var encoded = ""
            for byte in branch.utf8 {
                let piece: String
                switch byte {
                case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                     UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."):
                    piece = String(UnicodeScalar(byte))
                default:
                    piece = String(format: "%%%02X", byte)
                }
                guard encoded.utf8.count + piece.utf8.count <= maxEncodedBranchBytes else { break }
                encoded += piece
            }
            return encoded
        }

        // MARK: Loading

        struct Loaded: Equatable, Sendable {
            enum Status: Equatable, Sendable {
                /// No review yet: the first write creates it.
                case missing
                case loaded
                /// Not a review this build can read (bad JSON, a version
                /// that isn't a number): read as empty, and set aside by
                /// the first write.
                case unreadable
                /// This build never writes it.
                case readOnly(ReadOnlyReason)
            }

            /// Empty when there is nothing this branch's to show.
            var record: Record
            var status: Status
            /// Where `open` set aside a reused name's review.
            var setAside: URL?

            var isWritable: Bool {
                if case .readOnly = status { return false }
                return true
            }
        }

        enum ReadOnlyReason: Equatable, Sendable {
            case newerVersion(Int)
            case notARegularFile
            case tooLarge
            /// It couldn't be checked against the branch, or set aside
            /// once found to be a reused name's: why. The record is as
            /// read in the first case, empty in the second.
            case unverified(String)

            var message: String {
                switch self {
                case .newerVersion(let version):
                    return "This review was saved by a newer Nirux (version \(version)). "
                        + "This version shows it but won’t change it: update Nirux."
                case .notARegularFile:
                    return "The review file isn’t a regular file (a folder or a link, say). Nirux won’t read or replace it."
                case .tooLarge:
                    return "The review file is larger than \(Store.maxFileBytes / 1_000_000) MB. "
                        + "Nirux won’t read or replace it."
                case .unverified(let reason):
                    return reason
                }
            }
        }

        /// The file as it is now, without the lock and without checking
        /// whose it is: `open` checks.
        func load() -> Loaded {
            switch BoardConfigStore.read(fileURL, maxBytes: Self.maxFileBytes) {
            case .missing: return Loaded(record: Record(), status: .missing)
            case .notARegularFile: return Loaded(record: Record(), status: .readOnly(.notARegularFile))
            case .tooLarge: return Loaded(record: Record(), status: .readOnly(.tooLarge))
            case .unreadableBytes: return Loaded(record: Record(), status: .unreadable)
            case .data(let data): return Self.decode(data)
            }
        }

        static func decode(_ data: Data) -> Loaded {
            guard let fields = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
                return Loaded(record: Record(), status: .unreadable)
            }
            let record = Record(fields: fields)
            switch record.version {
            case .current: return Loaded(record: record, status: .loaded)
            case .newer(let version): return Loaded(record: record, status: .readOnly(.newerVersion(version)))
            case .invalid: return Loaded(record: Record(), status: .unreadable)
            }
        }

        // MARK: Opening

        /// The review to show for the branch at `head`: the file if it is
        /// this branch's (`disposition`), with `head` and the pull request
        /// recorded; otherwise set aside, and the review starts fresh. The
        /// lock is taken only when there is a file, so opening a branch
        /// never reviewed leaves nothing behind. `reflogContains` may run
        /// git: call this off the main thread.
        func open(head: String, pullRequest: PullRequestLookup, reflogContains: (String) -> Bool?) -> Loaded {
            guard Self.exists(fileURL) else { return load() }
            do {
                return try Self.withExclusiveLock(at: lockURL) {
                    let loaded = load()
                    guard case .loaded = loaded.status else { return loaded }
                    switch BranchReview.disposition(
                        of: loaded.record, branch: branch, repository: repository, head: head,
                        pullRequest: pullRequest, reflogContains: reflogContains
                    ) {
                    case .unverified:
                        return Loaded(record: loaded.record, status: .readOnly(.unverified(
                            "Nirux couldn’t read the history of \(branch) to check that this review is its own. "
                                + "Refresh to try again."
                        )))
                    case .archive:
                        do {
                            let setAside = try setAside(reason: "reused")
                            return Loaded(record: Record(), status: .missing, setAside: setAside)
                        } catch {
                            return Loaded(record: Record(), status: .readOnly(.unverified(
                                "The review stored for \(branch) belongs to an earlier branch of that name, "
                                    + "and Nirux couldn’t set it aside: \(error.localizedDescription)"
                            )))
                        }
                    case .keep:
                        var record = loaded.record
                        record.stamp(
                            branch: branch, repository: repository, head: head,
                            pullRequest: pullRequest.pullRequest?.number
                        )
                        // A failed stamp leaves the file as it was: the
                        // next write records it.
                        if record != loaded.record, case .failure(let error) = write(record) {
                            NiruxDebugLog.log("BranchReview.Store: could not record the head in \(fileURL.path): \(error)")
                        }
                        return Loaded(record: record, status: .loaded)
                    }
                }
            } catch {
                return Loaded(record: Record(), status: .readOnly(.unverified(
                    "Nirux couldn’t lock the review of \(branch): \(error.localizedDescription)"
                )))
            }
        }

        /// `open` for a snapshot: its head and pull request, and its
        /// branch's reflog.
        func open(for snapshot: Snapshot, options: Options = Options()) -> Loaded {
            open(head: snapshot.head, pullRequest: snapshot.pullRequest) { commit in
                BranchReview.reflog(of: snapshot.branch, contains: commit, root: snapshot.root, options: options)
            }
        }

        // MARK: Writing

        enum WriteError: Error, Equatable {
            /// What's on disk now is read-only for this build.
            case readOnly(ReadOnlyReason)
            /// The review would be larger than `maxFileBytes`, which this
            /// build wouldn't read back.
            case tooLarge
            case couldNotLock(String)
            case couldNotSetAside(String)
            case couldNotWrite(String)
        }

        /// Applies `change` to the review as it is on disk now, under the
        /// lock, records `head` and the pull request, and writes it back:
        /// a change another process wrote meanwhile is kept. Returns what
        /// was written. Call `open` first: this doesn't check whose review
        /// it is. Blocks while another write holds the lock: call it off
        /// the main thread.
        func update(head: String, pullRequest: Int?, _ change: (inout Record) -> Void) -> Result<Record, WriteError> {
            do {
                try Self.createPrivateFolder(folder)
            } catch {
                return .failure(.couldNotWrite(error.localizedDescription))
            }
            do {
                return try Self.withExclusiveLock(at: lockURL) {
                    let current = load()
                    var record: Record
                    switch current.status {
                    case .readOnly(let reason):
                        return .failure(.readOnly(reason))
                    case .unreadable:
                        do {
                            _ = try setAside(reason: "unreadable")
                        } catch {
                            return .failure(.couldNotSetAside(error.localizedDescription))
                        }
                        record = Record()
                    case .missing:
                        record = Record()
                    case .loaded:
                        record = current.record
                    }
                    change(&record)
                    record.stamp(branch: branch, repository: repository, head: head, pullRequest: pullRequest)
                    if case .loaded = current.status, record == current.record { return .success(record) }
                    return write(record).map { record }
                }
            } catch {
                return .failure(.couldNotLock(error.localizedDescription))
            }
        }

        /// Atomically, 0600. Under the lock.
        private func write(_ record: Record) -> Result<Void, WriteError> {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            guard var data = try? encoder.encode(record.fields) else {
                return .failure(.couldNotWrite("The review couldn’t be encoded."))
            }
            data.append(0x0A)
            guard data.count <= Self.maxFileBytes else { return .failure(.tooLarge) }
            do {
                try data.write(to: fileURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                return .success(())
            } catch {
                NiruxDebugLog.log("BranchReview.Store: could not write \(fileURL.path): \(error)")
                return .failure(.couldNotWrite(error.localizedDescription))
            }
        }

        /// Moves the file to `archive/<stem>.<reason>.<time>-<random>.json`.
        /// Under the lock.
        private func setAside(reason: String) throws -> URL {
            try Self.createPrivateFolder(archiveFolder)
            let stem = fileURL.deletingPathExtension().lastPathComponent
            let stamp = Int(Date().timeIntervalSince1970)
            let target = archiveFolder.appendingPathComponent(
                "\(stem).\(reason).\(stamp)-\(UUID().uuidString.prefix(8).lowercased()).json"
            )
            try FileManager.default.moveItem(at: fileURL, to: target)
            return target
        }

        // MARK: Deleting

        /// Deletes the review and its lock file, under the lock. True when
        /// there was a review.
        @discardableResult
        func delete() -> Bool {
            guard Self.exists(fileURL) || Self.exists(lockURL) else { return false }
            do {
                return try Self.withExclusiveLock(at: lockURL) {
                    let deleted = unlink(fileURL.path) == 0
                    // A writer waiting on this lock file sees it gone, and
                    // locks the one that replaces it.
                    unlink(lockURL.path)
                    return deleted
                }
            } catch {
                NiruxDebugLog.log("BranchReview.Store: could not delete \(fileURL.path): \(error)")
                return false
            }
        }

        /// Clean Up of a worktree: its branch is gone, so is its review, in
        /// every project. Clean Up doesn't know which project reviewed it
        /// (the Project Board cleans up a folder no workspace is open in).
        /// Set-aside reviews stay. Returns the files deleted.
        @discardableResult
        static func deleteReviews(branch: String, repository: String, stateDirectory: URL) -> [URL] {
            guard !branch.isEmpty, !repository.isEmpty else { return [] }
            let reviews = stateDirectory.appendingPathComponent(folderName, isDirectory: true)
            let spaces = (try? FileManager.default.contentsOfDirectory(atPath: reviews.path)) ?? []
            return spaces.sorted().filter(SpaceBrief.isPlainSpaceID).compactMap { spaceID in
                let store = Store(
                    folder: reviews.appendingPathComponent(spaceID, isDirectory: true),
                    repository: repository, branch: branch
                )
                return store.delete() ? store.fileURL : nil
            }
        }

        // MARK: Files

        struct LockError: LocalizedError {
            let errorDescription: String?
        }

        /// Runs `body` holding an exclusive `flock` on `url`, created if
        /// needed, waiting as long as another holder keeps it. The lock
        /// file may be deleted (`delete`) or replaced while this waits:
        /// once locked, the file locked must still be the one at `url`, or
        /// it starts over on the new one. Opened close-on-exec, so a
        /// process `body` starts doesn't keep the lock.
        static func withExclusiveLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
            for _ in 0..<100 {
                let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard descriptor >= 0 else { throw lockError("open", url) }
                defer { close(descriptor) }
                while flock(descriptor, LOCK_EX) != 0 {
                    guard errno == EINTR else { throw lockError("flock", url) }
                }
                var held = stat()
                var named = stat()
                guard fstat(descriptor, &held) == 0 else { throw lockError("fstat", url) }
                guard lstat(url.path, &named) == 0, named.st_dev == held.st_dev, named.st_ino == held.st_ino
                else { continue }
                return try body()
            }
            throw LockError(errorDescription: "\(url.lastPathComponent) kept being replaced.")
        }

        private static func lockError(_ call: String, _ url: URL) -> LockError {
            LockError(errorDescription: "\(call) \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }

        /// Whether anything is at `url`, a dangling link included.
        private static func exists(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path, &info) == 0
        }

        private static func createPrivateFolder(_ url: URL) throws {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
    }
}
