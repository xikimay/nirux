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
    /// build doesn't know included, read through typed accessors. Later
    /// parts (comments, drafts, what was sent, the explanation cache,
    /// usage) add their own keys and accessors beside these. An older
    /// build keeps a top-level key it doesn't know, and every entry it
    /// doesn't change. A key added inside an entry (a mark, say) is lost
    /// when an older build rewrites that entry, and a key whose meaning
    /// changes needs a new `version`: older builds then open the file
    /// read-only.
    struct Record: Equatable, Sendable {
        static let currentVersion = 1

        var fields: [String: JSONValue]

        init(fields: [String: JSONValue] = [:]) {
            self.fields = fields
        }

        /// The branch and repository the file is named after.
        var branch: String? { fields["branch"]?.stringValue }
        var repository: String? { fields["repository"]?.stringValue }
        /// The branch's pull request when the review was last opened or
        /// written. Kept when the branch no longer has an open one.
        var pullRequest: Int? { fields["pullRequest"]?.intValue }
        /// The head the page showed when the review was last opened or
        /// written.
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
            markReviewed([file], head: head, at: date) == 1
        }

        /// Marks each of `files` whose patch was read; returns how many.
        /// The marks are changed in place: a group of thousands of files
        /// isn't copied once per file.
        @discardableResult
        mutating func markReviewed(_ files: [FileChange], head: String, at date: Date) -> Int {
            // Out of `fields` while it changes: changed in place.
            var marks = fields.removeValue(forKey: "reviewed")?.objectValue ?? [:]
            var marked = 0
            for file in files {
                guard let patchHash = file.patchHash else { continue }
                marks[file.path] = ReviewedMark(patchHash: patchHash, head: head, date: date).json
                marked += 1
            }
            if !marks.isEmpty { fields["reviewed"] = .object(marks) }
            return marked
        }

        /// The user unticked it. Nothing else clears a mark: a changed
        /// patch reads as `changedSinceReviewed`, an unread one as
        /// `unverified`.
        mutating func clearReviewed(path: String) {
            clearReviewed(paths: [path])
        }

        mutating func clearReviewed(paths: [String]) {
            guard var marks = fields["reviewed"]?.objectValue else { return }
            // Out of `fields` while it changes: changed in place.
            fields["reviewed"] = nil
            for path in paths { marks.removeValue(forKey: path) }
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

    /// What the branch's history says about a commit, for `disposition`.
    /// Each answer is nil when git couldn't say.
    struct History {
        /// In the head's history and not in the base's: one of the
        /// branch's own commits.
        var isOwnCommit: (String) -> Bool?
        /// In the branch's reflog.
        var isInReflog: (String) -> Bool?
    }

    /// Kept when its last head is the branch's head or one of its own
    /// commits (the branch moved on from what was reviewed). Else, when
    /// both have a pull request, kept only if it is the same one; else
    /// kept when its last head is in the branch's reflog (`git branch -D`
    /// deletes the reflog, a rebase keeps it). A new pull request for the
    /// same commits doesn't archive it, a review is never archived for want
    /// of gh, and never when git couldn't answer.
    static func disposition(
        of record: Record, branch: String, repository: String, head: String,
        pullRequest: PullRequestLookup, history: History
    ) -> Disposition {
        guard record.branch == branch, record.repository == repository, let lastHead = record.lastHead
        else { return .archive }
        if lastHead == head { return .keep }
        let isOwnCommit = history.isOwnCommit(lastHead)
        if isOwnCommit == true { return .keep }
        if let current = pullRequest.pullRequest?.number, let stored = record.pullRequest {
            guard stored != current else { return .keep }
            return isOwnCommit == nil ? .unverified : .archive
        }
        switch history.isInReflog(lastHead) {
        case true?: return .keep
        case false?: return isOwnCommit == nil ? .unverified : .archive
        case nil: return .unverified
        }
    }

    /// What `disposition` asks, answered by git for `snapshot`'s branch.
    static func history(of snapshot: Snapshot, options: Options) -> History {
        History(
            isOwnCommit: { commit in
                isOwnCommit(commit, head: snapshot.head, mergeBase: snapshot.base.mergeBase, root: snapshot.root, options: options)
            },
            isInReflog: { commit in
                reflog(of: snapshot.branch, contains: commit, root: snapshot.root, options: options)
            }
        )
    }

    /// A full object id. Anything else read from a review file never
    /// reaches git, where it could pass for an option.
    static func isCommitID(_ text: String) -> Bool {
        (text.utf8.count == 40 || text.utf8.count == 64)
            && text.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }
    }

    /// Whether `commit` is in `head`'s history and not in `mergeBase`'s.
    /// False for a commit that is gone (a rebase left it, and gc pruned
    /// it). Nil when git couldn't say.
    static func isOwnCommit(_ commit: String, head: String, mergeBase: String, root: String, options: Options) -> Bool? {
        guard isCommitID(commit) else { return false }
        guard let exists = git(["rev-parse", "-q", "--verify", "\(commit)^{commit}"], in: root, options: options)
        else { return nil }
        switch exists.status {
        case 0: break
        case 1: return false
        default: return nil
        }
        func isAncestor(of other: String) -> Bool? {
            switch git(["merge-base", "--is-ancestor", commit, other], in: root, options: options)?.status {
            case 0?: return true
            case 1?: return false
            default: return nil
            }
        }
        guard let inHead = isAncestor(of: head) else { return nil }
        guard inHead else { return false }
        return isAncestor(of: mergeBase).map { !$0 }
    }

    /// Whether `commit` is in the reflog of `refs/heads/<branch>`, the
    /// head before its oldest entry included: the one the branch was
    /// created at when that wasn't logged (from a bare repository), or
    /// left at when older entries expired. Nil when git couldn't read it.
    static func reflog(of branch: String, contains commit: String, root: String, options: Options) -> Bool? {
        guard isCommitID(commit) else { return false }
        guard let reflog = git(["log", "-g", "--format=%H", "refs/heads/\(branch)", "--"], in: root, options: options),
              reflog.status == 0
        else { return nil }
        let entries = reflog.text.split(separator: "\n")
        if entries.contains(where: { $0 == commit }) { return true }
        guard !entries.isEmpty else { return false }
        guard let before = git(["rev-parse", "-q", "--verify", "refs/heads/\(branch)@{\(entries.count)}"], in: root, options: options)
        else { return nil }
        // Fails when the oldest entry is the branch's creation.
        return before.status == 0 && before.text.trimmingCharacters(in: .whitespacesAndNewlines) == commit
    }

    /// The repository a review belongs to: its common git folder
    /// (`--git-common-dir`), symlinks resolved. Every worktree of a
    /// repository shares it, so two repositories can each have a `main`
    /// without sharing a review. Nil when git can't say.
    static func repositoryIdentity(root: String, options: Options = Options()) -> String? {
        guard let output = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: root, options: options),
              output.status == 0
        else { return nil }
        return output.text.trimmingCharacters(in: .newlines).realPath
    }

    /// The review file of one branch: `<state dir>/reviews/<branch>-<hash>.json`.
    /// `<branch>` is percent-encoded and `<hash>` is a hash of the
    /// repository (`repositoryIdentity`) and the exact branch name: APFS
    /// ignores case, so `Fix/A` and `fix/a` need it to differ. Not per
    /// project: a workspace moved to another project keeps its review.
    ///
    /// - Reading never locks: writes replace the file atomically.
    /// - Every write takes an exclusive `flock` on `<file>.lock`, held
    ///   across reading, changing and writing the file, so two writers
    ///   (the installed app and a dev build sharing the state directory)
    ///   both keep their changes. A lock on the data file itself would be
    ///   lost when it is replaced. A write waits up to `lockTimeout` for
    ///   it, and git never runs while it is held. Taking it again inside a
    ///   write's change blocks until the timeout. Call writes, and `open`,
    ///   off the main thread.
    /// - Only what `open` returns can write (`Access`): a write never takes
    ///   over a reused name's review, and never brings back a review
    ///   deleted since it was opened. A page that opened a branch never
    ///   reviewed must stop writing once its branch is gone: its first
    ///   write would create the review again.
    /// - A file from a newer `version`, anything but a regular file, or a
    ///   file over `maxFileBytes` is never written; one that can't be read
    ///   right now is read-only. One that isn't a review (not JSON, a
    ///   `version` that isn't a number) is set aside before the first write
    ///   replaces it.
    /// - Set-aside files go to `reviews/archive/`, and stay there.
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
        /// A lock held longer than this is another Nirux stopped (in a
        /// debugger, say): the write fails rather than wait forever.
        var lockTimeout: TimeInterval = 10

        var lockURL: URL { fileURL.appendingPathExtension("lock") }
        var folder: URL { fileURL.deletingLastPathComponent() }
        var archiveFolder: URL { folder.appendingPathComponent(Self.archiveFolderName, isDirectory: true) }

        /// Nil for an empty branch or repository.
        init?(repository: String, branch: String, stateDirectory: URL = Persistence.stateDirectory) {
            guard !repository.isEmpty, !branch.isEmpty else { return nil }
            self.branch = branch
            self.repository = repository
            fileURL = stateDirectory.appendingPathComponent(Self.folderName, isDirectory: true)
                .appendingPathComponent(Self.fileName(branch: branch, repository: repository))
        }

        static func fileName(branch: String, repository: String) -> String {
            let digest = SHA256.hash(data: Data("repository\0\(repository)\0branch\0\(branch)".utf8))
            return encodedBranch(branch) + "-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined() + ".json"
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

        /// What `open` checked, which a write needs: the review is this
        /// branch's, opened at `head`.
        struct Access: Equatable, Sendable {
            let branch: String
            let repository: String
            /// What writes record as the last head.
            let head: String
            let pullRequest: Int?
            /// The last heads the file may hold for a write to go ahead:
            /// another means it was archived and started again, or opened
            /// at another head, since.
            fileprivate let lastHeads: Set<String>
            /// The review was on disk: a write never recreates it once
            /// deleted (Clean Up). Without one, the first write creates it.
            fileprivate let existed: Bool

            /// The next write creates the review: the branch must still
            /// exist, or it would come back after Clean Up deleted both.
            var createsReview: Bool { !existed }
        }

        struct Loaded: Equatable, Sendable {
            enum Status: Equatable, Sendable {
                /// No review yet: the first write creates it.
                case missing
                case loaded
                /// Not a review this build can read (bad JSON, a version
                /// that isn't a number): read as empty, and set aside by
                /// the first write.
                case unreadable
                /// This build doesn't write it.
                case readOnly(ReadOnlyReason)
            }

            /// Empty when there is nothing this branch's to show.
            var record: Record
            var status: Status
            /// Where `open` set aside a reused name's review.
            var setAside: URL?
            /// Nil when it can't be written: read-only, or not opened.
            var access: Access?
        }

        enum ReadOnlyReason: Equatable, Sendable {
            case newerVersion(Int)
            case notARegularFile
            case tooLarge
            /// A regular file whose bytes can't be read now (permissions,
            /// too many open files): nothing is set aside for it.
            case couldNotRead
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
                case .couldNotRead:
                    return "Nirux couldn’t read the review file. Refresh to try again."
                case .unverified(let reason):
                    return reason
                }
            }
        }

        /// The file as it is now, without the lock and without checking
        /// whose it is: `open` checks. It can't be written.
        func load() -> Loaded {
            read().loaded
        }

        /// The bytes too, for `open` to tell whether the file changed
        /// while git answered.
        private func read() -> (loaded: Loaded, bytes: Data?) {
            switch BoardConfigStore.read(fileURL, maxBytes: Self.maxFileBytes) {
            case .missing: return (Loaded(record: Record(), status: .missing), nil)
            case .notARegularFile: return (Loaded(record: Record(), status: .readOnly(.notARegularFile)), nil)
            case .tooLarge: return (Loaded(record: Record(), status: .readOnly(.tooLarge)), nil)
            case .unreadableBytes: return (Loaded(record: Record(), status: .readOnly(.couldNotRead)), nil)
            case .data(let data): return (Self.decode(data), data)
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

        /// The review to show for the branch at `head`, with the access to
        /// write it: the file if it is this branch's (`disposition`), with
        /// `head` and the pull request recorded; otherwise set aside, and
        /// the review starts fresh. git runs before the lock is taken; if
        /// the file changed meanwhile, it decides again. Opening a branch
        /// never reviewed leaves nothing behind. Call it off the main
        /// thread.
        func open(head: String, pullRequest: PullRequestLookup, history: History) -> Loaded {
            let number = pullRequest.pullRequest?.number
            func access(lastHeads: Set<String>, existed: Bool) -> Access {
                Access(
                    branch: branch, repository: repository, head: head, pullRequest: number,
                    lastHeads: lastHeads, existed: existed
                )
            }
            for _ in 0..<3 {
                let (loaded, bytes) = read()
                var found = loaded
                switch found.status {
                case .missing, .unreadable:
                    found.access = access(lastHeads: [head], existed: false)
                    return found
                case .readOnly:
                    return found
                case .loaded:
                    break
                }
                let disposition = BranchReview.disposition(
                    of: found.record, branch: branch, repository: repository, head: head,
                    pullRequest: pullRequest, history: history
                )
                var stamped = found.record
                stamped.stamp(branch: branch, repository: repository, head: head, pullRequest: number)
                switch disposition {
                case .unverified:
                    return Loaded(record: found.record, status: .readOnly(.unverified(
                        "Nirux couldn’t read the history of \(branch) to check that this review is its own. "
                            + "Refresh to try again."
                    )))
                case .keep where stamped == found.record:
                    return Loaded(record: found.record, status: .loaded, access: access(lastHeads: [head], existed: true))
                case .keep, .archive:
                    break
                }
                let acted: Loaded?
                do {
                    acted = try Self.withExclusiveLock(at: lockURL, timeout: lockTimeout) { () -> Loaded? in
                        guard read().bytes == bytes else { return nil }
                        if disposition == .archive {
                            do {
                                let setAside = try setAside(reason: "reused")
                                return Loaded(
                                    record: Record(), status: .missing, setAside: setAside,
                                    access: access(lastHeads: [head], existed: false)
                                )
                            } catch {
                                return Loaded(record: Record(), status: .readOnly(.unverified(
                                    "The review stored for \(branch) belongs to an earlier branch of that name, "
                                        + "and Nirux couldn’t set it aside: \(error.localizedDescription)"
                                )))
                            }
                        }
                        // A failed write leaves the file as it was: the
                        // next one records the head.
                        if case .failure(let error) = write(stamped) {
                            NiruxDebugLog.log("BranchReview.Store: could not record the head in \(fileURL.path): \(error)")
                        }
                        let lastHeads = Set([head] + [found.record.lastHead].compactMap { $0 })
                        return Loaded(record: stamped, status: .loaded, access: access(lastHeads: lastHeads, existed: true))
                    }
                } catch {
                    // A reused name's review is never shown.
                    return Loaded(record: disposition == .keep ? found.record : Record(), status: .readOnly(.unverified(
                        "Nirux couldn’t lock the review of \(branch): \(error.localizedDescription)"
                    )))
                }
                if let acted { return acted }
            }
            return Loaded(record: Record(), status: .readOnly(.unverified(
                "The review of \(branch) kept changing while Nirux opened it. Refresh to try again."
            )))
        }

        /// `open` for a snapshot of this store's branch: its head, its pull
        /// request, and git's answers about its history.
        func open(for snapshot: Snapshot, options: Options = Options()) -> Loaded {
            guard snapshot.branch == branch else {
                return Loaded(record: Record(), status: .readOnly(.unverified(
                    "The worktree is on \(snapshot.branch) now, not \(branch)."
                )))
            }
            return open(head: snapshot.head, pullRequest: snapshot.pullRequest, history: BranchReview.history(of: snapshot, options: options))
        }

        // MARK: Writing

        enum WriteError: Error, Equatable {
            /// What's on disk now is read-only for this build.
            case readOnly(ReadOnlyReason)
            /// Deleted, archived, or opened at another head since `open`:
            /// open it again.
            case changedSinceOpened
            /// The review would be larger than `maxFileBytes`, which this
            /// build wouldn't read back.
            case tooLarge
            case couldNotLock(String)
            case couldNotSetAside(String)
            case couldNotWrite(String)
        }

        /// Applies `change` to the review as it is on disk now, under the
        /// lock, records the access's head and pull request, and writes it
        /// back: a change another process wrote meanwhile is kept. Returns
        /// what was written, with the access for the next write. Call it
        /// off the main thread.
        func update(_ access: Access, _ change: (inout Record) -> Void) -> Result<Loaded, WriteError> {
            guard access.branch == branch, access.repository == repository else { return .failure(.changedSinceOpened) }
            do {
                try Self.createPrivateFolder(folder)
            } catch {
                return .failure(.couldNotWrite(error.localizedDescription))
            }
            do {
                return try Self.withExclusiveLock(at: lockURL, timeout: lockTimeout) {
                    let current = read().loaded
                    var record: Record
                    switch current.status {
                    case .readOnly(let reason):
                        return .failure(.readOnly(reason))
                    case .missing:
                        guard !access.existed else {
                            // Deleted since (Clean Up): nor its lock file.
                            unlink(lockURL.path)
                            return .failure(.changedSinceOpened)
                        }
                        record = Record()
                    case .unreadable:
                        do {
                            _ = try setAside(reason: "unreadable")
                        } catch {
                            return .failure(.couldNotSetAside(error.localizedDescription))
                        }
                        record = Record()
                    case .loaded:
                        guard current.record.branch == branch, current.record.repository == repository,
                              let lastHead = current.record.lastHead, access.lastHeads.contains(lastHead)
                        else { return .failure(.changedSinceOpened) }
                        record = current.record
                    }
                    change(&record)
                    record.stamp(branch: branch, repository: repository, head: access.head, pullRequest: access.pullRequest)
                    let next = Access(
                        branch: branch, repository: repository, head: access.head, pullRequest: access.pullRequest,
                        lastHeads: [access.head], existed: true
                    )
                    let written = Loaded(record: record, status: .loaded, access: next)
                    if case .loaded = current.status, record == current.record { return .success(written) }
                    return write(record).map { written }
                }
            } catch {
                return .failure(.couldNotLock(error.localizedDescription))
            }
        }

        /// `change` applied to the review as it is on disk, without
        /// recording a head: for a writer whose snapshot is older than the
        /// head the review was opened at since (Explain's cache, whose
        /// entries hold at that head too). Only while the file is this
        /// branch's, at `lastHead`: a review deleted (Clean Up), archived or
        /// moved on again fails with `changedSinceOpened`, and is never
        /// created. Call it off the main thread.
        func update(keepingHead lastHead: String, _ change: (inout Record) -> Void) -> Result<Loaded, WriteError> {
            do {
                return try Self.withExclusiveLock(at: lockURL, timeout: lockTimeout) {
                    let current = read().loaded
                    if case .readOnly(let reason) = current.status { return .failure(.readOnly(reason)) }
                    if case .missing = current.status {
                        // Deleted (Clean Up): nor its lock file.
                        unlink(lockURL.path)
                        return .failure(.changedSinceOpened)
                    }
                    guard case .loaded = current.status, current.record.branch == branch,
                          current.record.repository == repository, current.record.lastHead == lastHead
                    else { return .failure(.changedSinceOpened) }
                    var record = current.record
                    change(&record)
                    let written = Loaded(record: record, status: .loaded)
                    if record == current.record { return .success(written) }
                    return write(record).map { written }
                }
            } catch {
                return .failure(.couldNotLock(error.localizedDescription))
            }
        }

        /// Atomically, 0600. Under the lock.
        private func write(_ record: Record) -> Result<Void, WriteError> {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard var data = try? encoder.encode(record.fields) else {
                return .failure(.couldNotWrite("The review couldn’t be encoded."))
            }
            data.append(0x0A)
            guard data.count <= Self.maxFileBytes else { return .failure(.tooLarge) }
            do {
                try data.write(to: fileURL, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                return .success(())
            } catch {
                NiruxDebugLog.log("BranchReview.Store: could not write \(fileURL.path): \(error)")
                return .failure(.couldNotWrite(error.localizedDescription))
            }
        }

        /// Moves the file to `archive/<name>.<reason>.<time>-<random>.json`.
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

        /// Clean Up of a worktree: its branch is gone, so is its review and
        /// its lock file. Set-aside reviews stay. True when there was a
        /// review.
        @discardableResult
        func delete() -> Bool {
            guard Self.exists(fileURL) || Self.exists(lockURL) else { return false }
            do {
                return try Self.withExclusiveLock(at: lockURL, timeout: lockTimeout) {
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

        // MARK: Files

        struct LockError: LocalizedError {
            let errorDescription: String?
        }

        /// Runs `body` holding an exclusive `flock` on `url`, created if
        /// needed, waiting up to `timeout` for another holder to let go.
        /// The lock file may be deleted (`delete`) or replaced meanwhile:
        /// once locked, the file locked must still be the one at `url`, or
        /// it starts over on the new one. Opened close-on-exec, so a
        /// process started meanwhile doesn't keep the lock.
        static func withExclusiveLock<T>(at url: URL, timeout: TimeInterval, _ body: () throws -> T) throws -> T {
            let deadline = Date().addingTimeInterval(timeout)
            var pause: useconds_t = 1_000
            while true {
                do {
                    let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard descriptor >= 0 else { throw lockError("open", url) }
                    defer { close(descriptor) }
                    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                        var held = stat()
                        var named = stat()
                        guard fstat(descriptor, &held) == 0 else { throw lockError("fstat", url) }
                        if lstat(url.path, &named) == 0, named.st_dev == held.st_dev, named.st_ino == held.st_ino {
                            return try body()
                        }
                    } else if errno != EWOULDBLOCK, errno != EINTR {
                        throw lockError("flock", url)
                    }
                }
                guard Date() < deadline else {
                    throw LockError(errorDescription: "Another Nirux has held \(url.lastPathComponent) for over \(Int(timeout)) s.")
                }
                usleep(pause)
                pause = min(pause * 2, 50_000)
            }
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
