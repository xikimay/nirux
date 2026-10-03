import XCTest
@testable import Nirux

/// The review file of a branch (docs/branch-review.md, section 8): its name,
/// its format, its lock, and which review a branch gets back.
final class BranchReviewStorageTests: XCTestCase {
    private typealias Store = BranchReview.Store
    private typealias Record = BranchReview.Record

    private var root: String!
    private var state: URL!
    private let repository = "/repos/widgets/.git"
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-review-storage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = try XCTUnwrap(base.path.realPath)
        state = URL(fileURLWithPath: root + "/state", isDirectory: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(atPath: root) }
    }

    // MARK: - Helpers

    private func store(_ branch: String = "feat/x", space: String = "default", repository: String? = nil) throws -> Store {
        try XCTUnwrap(Store(spaceID: space, repository: repository ?? self.repository, branch: branch, stateDirectory: state))
    }

    private func file(_ path: String, hash: String?) -> BranchReview.FileChange {
        BranchReview.FileChange(path: path, status: .modified, patchHash: hash)
    }

    private func pullRequest(_ number: Int) -> BranchReview.PullRequestLookup {
        .found(BranchReview.PullRequest(
            number: number, title: "", body: "", url: "https://github.com/acme/widgets/pull/\(number)",
            baseRefName: "main", headRefOid: "", isDraft: false
        ))
    }

    /// Writes `object` as the store's file, as another build would.
    private func place(_ object: [String: Any], in store: Store) throws {
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: store.fileURL)
    }

    private func stored(_ store: Store) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
    }

    private func archived(_ store: Store) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: store.archiveFolder.path))?.sorted() ?? []
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    /// An exclusive lock on `url` through a descriptor of its own, as
    /// another Nirux would hold it. Fails rather than wait.
    private func holdLock(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw NSError(domain: "BranchReviewStorageTests", code: Int(errno))
        }
        return descriptor
    }

    // MARK: - File names

    func testFileIsNamedAfterTheExactBranchAndItsRepository() throws {
        let plain = try store("feat/x")
        XCTAssertEqual(plain.fileURL.deletingLastPathComponent().path, root + "/state/reviews/default")
        let name = plain.fileURL.lastPathComponent
        XCTAssertTrue(name.hasPrefix("feat%2Fx-"), name)
        XCTAssertTrue(name.hasSuffix(".json"), name)
        XCTAssertEqual(plain.lockURL.lastPathComponent, name + ".lock")

        // APFS ignores case: the hash tells these apart.
        let upper = try store("Fix/A").fileURL.lastPathComponent
        let lower = try store("fix/a").fileURL.lastPathComponent
        XCTAssertNotEqual(upper.lowercased(), lower.lowercased())
        // Two repositories of a project can both have the branch.
        XCTAssertNotEqual(try store("feat/x", repository: "/repos/gadgets/.git").fileURL, plain.fileURL)

        // Anything but a plain space id could leave the folder.
        XCTAssertNil(Store(spaceID: "../x", repository: repository, branch: "feat/x", stateDirectory: state))
        XCTAssertNil(Store(spaceID: "", repository: repository, branch: "feat/x", stateDirectory: state))
    }

    func testLongOrNonASCIIBranchNameStillMakesAWritableFile() throws {
        XCTAssertEqual(Store.encodedBranch("fix/é 1"), "fix%2F%C3%A9%201")
        let long = try store("feat/" + String(repeating: "é", count: 300))
        let encoded = Store.encodedBranch(long.branch)
        XCTAssertLessThanOrEqual(encoded.utf8.count, Store.maxEncodedBranchBytes)
        XCTAssertNotNil(
            encoded.wholeMatch(of: /(?:[A-Za-z0-9._\-]|%[0-9A-F]{2})+/), "an escape is never split: \(encoded.suffix(6))"
        )
        XCTAssertLessThanOrEqual(long.lockURL.lastPathComponent.utf8.count, 255)

        XCTAssertNoThrow(try long.update(head: "a1", pullRequest: nil) { _ in }.get())
        XCTAssertEqual(long.load().record.branch, long.branch)
    }

    // MARK: - Format

    func testWriteKeepsWhatThisBuildDoesntKnowAndIsPrivate() throws {
        let store = try store()
        try place([
            "version": 1,
            "branch": "feat/x",
            "repository": repository,
            "lastHead": "a1",
            "comments": [["id": "c1", "text": "Why?"]],
            "flags": [true, NSNull(), 1.5, 9_007_199_254_740_993],
            "reviewed": [
                "Sources/Old.swift": ["patchHash": "h0", "head": "a0", "reviewer": "kept"]
            ]
        ], in: store)

        let written = try store.update(head: "b2", pullRequest: 57) { record in
            record.markReviewed(self.file("Sources/New.swift", hash: "h1"), head: "b2", at: self.date)
        }.get()

        let object = try stored(store)
        XCTAssertEqual(object["comments"] as? [[String: String]], [["id": "c1", "text": "Why?"]])
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: store.fileURL))
        XCTAssertEqual(fields["flags"], .array([.bool(true), .null, .double(1.5), .int(9_007_199_254_740_993)]))
        let marks = try XCTUnwrap(object["reviewed"] as? [String: [String: String]])
        XCTAssertEqual(marks["Sources/Old.swift"], ["patchHash": "h0", "head": "a0", "reviewer": "kept"])
        XCTAssertEqual(marks["Sources/New.swift"]?["patchHash"], "h1")
        XCTAssertEqual(object["lastHead"] as? String, "b2")
        XCTAssertEqual(object["pullRequest"] as? Int, 57)
        XCTAssertEqual(object["version"] as? Int, Record.currentVersion)
        XCTAssertEqual(store.load().record, written)
        XCTAssertEqual(written.reviewedMarks["Sources/New.swift"], BranchReview.ReviewedMark(patchHash: "h1", head: "b2", date: date))

    }

    func testFileFromANewerVersionIsShownButNeverWritten() throws {
        let store = try store()
        try place([
            "version": 2, "branch": "feat/x", "repository": repository, "lastHead": "a1", "pullRequest": 57,
            "reviewed": ["a.swift": ["patchHash": "h1"]]
        ], in: store)
        let before = try Data(contentsOf: store.fileURL)

        let loaded = store.load()
        XCTAssertEqual(loaded.status, .readOnly(.newerVersion(2)))
        XCTAssertEqual(loaded.record.reviewedMarks["a.swift"]?.patchHash, "h1")
        XCTAssertEqual(
            store.update(head: "b2", pullRequest: 57) { $0.clearReviewed(path: "a.swift") },
            .failure(.readOnly(.newerVersion(2)))
        )
        // Not set aside either, even under another pull request.
        XCTAssertEqual(store.open(head: "b2", pullRequest: pullRequest(60)) { _ in false }.status, .readOnly(.newerVersion(2)))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        XCTAssertEqual(archived(store), [])
    }

    func testUnreadableFileIsSetAsideBeforeTheFirstWrite() throws {
        let store = try store()
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        for bytes in [Data("{ not json".utf8), Data(#"{"version": "two"}"#.utf8)] {
            try bytes.write(to: store.fileURL)
            XCTAssertEqual(store.load().status, .unreadable)

            _ = try store.update(head: "a1", pullRequest: nil) { _ in }.get()

            XCTAssertEqual(store.load().status, .loaded)
            let copies = archived(store).filter { $0.contains(".unreadable.") }
            XCTAssertTrue(try copies.contains { try Data(contentsOf: store.archiveFolder.appendingPathComponent($0)) == bytes })
        }
    }

    func testLinkInPlaceOfTheFileIsNeitherFollowedNorReplaced() throws {
        let store = try store()
        let elsewhere = URL(fileURLWithPath: root + "/elsewhere.json")
        try Data(#"{"branch": "feat/x"}"#.utf8).write(to: elsewhere)
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: elsewhere)

        XCTAssertEqual(store.load().status, .readOnly(.notARegularFile))
        XCTAssertEqual(store.update(head: "a1", pullRequest: nil) { _ in }, .failure(.readOnly(.notARegularFile)))
        XCTAssertEqual(try String(contentsOf: elsewhere, encoding: .utf8), #"{"branch": "feat/x"}"#)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: store.fileURL.path))
    }

    func testReviewTooLargeToReadBackIsNotWritten() throws {
        let store = try store()
        _ = try store.update(head: "a1", pullRequest: nil) { $0.markReviewed(self.file("a.swift", hash: "h1"), head: "a1", at: self.date) }.get()
        let before = try Data(contentsOf: store.fileURL)
        let huge = String(repeating: "x", count: Store.maxFileBytes)

        XCTAssertEqual(
            store.update(head: "a1", pullRequest: nil) { $0.markReviewed(self.file(huge, hash: "h2"), head: "a1", at: self.date) },
            .failure(.tooLarge)
        )
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    }

    // MARK: - Reviewed marks

    func testMarkIsNeverClearedForWantOfAHash() throws {
        let store = try store()
        _ = try store.update(head: "a1", pullRequest: nil) { $0.markReviewed(self.file("a.swift", hash: "h1"), head: "a1", at: self.date) }.get()
        var record = store.load().record

        XCTAssertEqual(record.reviewedState(of: file("a.swift", hash: "h1")), .reviewed)
        XCTAssertEqual(record.reviewedState(of: file("a.swift", hash: "h2")), .changedSinceReviewed)
        XCTAssertEqual(record.reviewedState(of: file("a.swift", hash: nil)), .unverified)
        XCTAssertEqual(record.reviewedState(of: file("b.swift", hash: "h1")), .notReviewed)

        // A patch that wasn't read has nothing to mark, and the mark stays.
        XCTAssertFalse(record.markReviewed(file("a.swift", hash: nil), head: "b2", at: date))
        XCTAssertEqual(record.reviewedMarks["a.swift"]?.patchHash, "h1")

        record.clearReviewed(path: "a.swift")
        XCTAssertEqual(record.reviewedState(of: file("a.swift", hash: "h1")), .notReviewed)
    }

    // MARK: - Whose review

    func testStoredPullRequestDecidesWhenTheBranchHasOne() {
        let record = record(pullRequest: 57, lastHead: "a1")
        XCTAssertEqual(disposition(record, pullRequest: pullRequest(57), reflog: false), .keep)
        XCTAssertEqual(disposition(record, pullRequest: pullRequest(60), reflog: true), .archive)
    }

    func testReflogDecidesWithoutAPullRequestToCompare() {
        // Merged or closed, gh missing, or none recorded yet.
        for (stored, lookup) in [
            (57, BranchReview.PullRequestLookup.notFound),
            (57, .unavailable("gh isn’t installed.")),
            (nil, pullRequest(57))
        ] as [(Int?, BranchReview.PullRequestLookup)] {
            let record = record(pullRequest: stored, lastHead: "a1")
            XCTAssertEqual(disposition(record, pullRequest: lookup, reflog: true), .keep)
            XCTAssertEqual(disposition(record, pullRequest: lookup, reflog: false), .archive)
            XCTAssertEqual(disposition(record, pullRequest: lookup, reflog: nil), .unverified)
        }
        // The same head needs no reflog (a bare repository's may be off).
        XCTAssertEqual(
            BranchReview.disposition(
                of: record(pullRequest: nil, lastHead: "c3"), branch: "feat/x", repository: repository, head: "c3",
                pullRequest: .notFound
            ) { _ in XCTFail("reflog read"); return nil },
            .keep
        )
        XCTAssertEqual(disposition(record(pullRequest: nil, lastHead: nil), pullRequest: .notFound, reflog: true), .archive)
    }

    func testFileOfAnotherBranchOrRepositoryIsNotKept() {
        var other = Record()
        other.stamp(branch: "feat/y", repository: repository, head: "c3", pullRequest: 57)
        XCTAssertEqual(disposition(other, pullRequest: pullRequest(57), reflog: true), .archive)
        other.stamp(branch: "feat/x", repository: "/repos/gadgets/.git", head: "c3", pullRequest: 57)
        XCTAssertEqual(disposition(other, pullRequest: pullRequest(57), reflog: true), .archive)
    }

    private func record(pullRequest: Int?, lastHead: String?) -> Record {
        var fields: [String: JSONValue] = ["branch": .string("feat/x"), "repository": .string(repository)]
        fields["pullRequest"] = pullRequest.map { .int(Int64($0)) }
        fields["lastHead"] = lastHead.map(JSONValue.string)
        return Record(fields: fields)
    }

    private func disposition(
        _ record: Record, pullRequest: BranchReview.PullRequestLookup, reflog: Bool?
    ) -> BranchReview.Disposition {
        BranchReview.disposition(
            of: record, branch: "feat/x", repository: repository, head: "c3", pullRequest: pullRequest
        ) { commit in
            XCTAssertEqual(commit, record.lastHead)
            return reflog
        }
    }

    func testOpeningKeepsTheBranchsReviewAndRecordsWhereItIs() throws {
        let store = try store()
        _ = try store.update(head: "a1", pullRequest: nil) { $0.markReviewed(self.file("a.swift", hash: "h1"), head: "a1", at: self.date) }.get()

        let opened = store.open(head: "b2", pullRequest: pullRequest(57)) { $0 == "a1" }

        XCTAssertEqual(opened.status, .loaded)
        XCTAssertNil(opened.setAside)
        XCTAssertEqual(opened.record.reviewedMarks["a.swift"]?.patchHash, "h1")
        XCTAssertEqual(store.load().record.lastHead, "b2")
        XCTAssertEqual(store.load().record.pullRequest, 57)
        XCTAssertEqual(try permissions(store.fileURL), 0o600)
        XCTAssertEqual(try permissions(store.folder), 0o700)
        XCTAssertEqual(try permissions(store.folder.deletingLastPathComponent()), 0o700)
    }

    func testOpeningSetsAsideAReusedNamesReview() throws {
        let store = try store()
        _ = try store.update(head: "a1", pullRequest: 57) { $0.markReviewed(self.file("a.swift", hash: "h1"), head: "a1", at: self.date) }.get()
        let earlier = try Data(contentsOf: store.fileURL)

        let opened = store.open(head: "b2", pullRequest: pullRequest(60)) { _ in true }

        XCTAssertEqual(opened.status, .missing)
        XCTAssertEqual(opened.record, Record())
        let setAside = try XCTUnwrap(opened.setAside)
        XCTAssertEqual(setAside.deletingLastPathComponent(), store.archiveFolder)
        XCTAssertTrue(setAside.lastPathComponent.contains(".reused."), setAside.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: setAside), earlier)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testOpeningWhenGitCantSayLeavesTheFileAndIsReadOnly() throws {
        let store = try store()
        _ = try store.update(head: "a1", pullRequest: nil) { _ in }.get()
        let before = try Data(contentsOf: store.fileURL)

        let opened = store.open(head: "b2", pullRequest: .unavailable("gh isn’t installed.")) { _ in nil }

        guard case .readOnly(.unverified) = opened.status else { return XCTFail("\(opened.status)") }
        XCTAssertFalse(opened.isWritable)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        XCTAssertEqual(archived(store), [])
    }

    func testOpeningABranchNeverReviewedLeavesNothingBehind() throws {
        let store = try store()
        XCTAssertEqual(store.open(head: "a1", pullRequest: pullRequest(57)) { _ in true }.status, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
    }

    // MARK: - Lock

    func testWriteWaitsWhileAnotherProcessHoldsTheLock() throws {
        let lockf = "/usr/bin/lockf"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: lockf), "no lockf")
        let store = try store()
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: lockf)
        holder.arguments = ["-k", store.lockURL.path, "/bin/sleep", "2"]
        try holder.run()
        defer { holder.terminate() }
        let deadline = Date().addingTimeInterval(10)
        while let probe = try? holdLock(store.lockURL) {
            close(probe)
            guard Date() < deadline else { return XCTFail("lockf never took the lock") }
            usleep(10_000)
        }

        let written = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = store.update(head: "a1", pullRequest: nil) { _ in }
            written.signal()
        }
        XCTAssertEqual(written.wait(timeout: .now() + 0.5), .timedOut)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(written.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(store.load().record.lastHead, "a1")
    }

    func testWriterWaitingOnADeletedLockFileLocksTheNewOne() throws {
        let store = try store()
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        let first = try holdLock(store.lockURL)
        let written = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = store.update(head: "a1", pullRequest: nil) { _ in }
            written.signal()
        }
        XCTAssertEqual(written.wait(timeout: .now() + 0.3), .timedOut)

        // Deleted while the writer waits, and taken again at the same path.
        unlink(store.lockURL.path)
        let second = try holdLock(store.lockURL)
        close(first)
        XCTAssertEqual(written.wait(timeout: .now() + 0.5), .timedOut, "the writer locked the deleted file")
        close(second)
        XCTAssertEqual(written.wait(timeout: .now() + 10), .success)
    }

    func testConcurrentWritersKeepEachOthersChanges() throws {
        let store = try store()
        let date = date
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            _ = store.update(head: "a1", pullRequest: nil) { record in
                record.markReviewed(
                    BranchReview.FileChange(path: "f\(index).swift", status: .modified, patchHash: "h"), head: "a1", at: date
                )
            }
        }
        XCTAssertEqual(store.load().record.reviewedMarks.count, 40)
    }

    // MARK: - Clean Up

    func testDeletingABranchsReviewsSparesEverythingElse() throws {
        let inDefault = try store("feat/x", space: "default")
        let inOther = try store("feat/x", space: "space-b")
        let otherBranch = try store("feat/y", space: "default")
        let otherRepository = try store("feat/x", space: "default", repository: "/repos/gadgets/.git")
        for store in [inDefault, inOther, otherBranch, otherRepository] {
            _ = try store.update(head: "a1", pullRequest: 57) { _ in }.get()
        }
        _ = inOther.open(head: "b2", pullRequest: pullRequest(60)) { _ in true }
        _ = try inOther.update(head: "b2", pullRequest: 60) { _ in }.get()
        let setAside = archived(inOther)
        XCTAssertEqual(setAside.count, 1)

        let deleted = Store.deleteReviews(branch: "feat/x", repository: repository, stateDirectory: state)

        XCTAssertEqual(Set(deleted), [inDefault.fileURL, inOther.fileURL])
        for store in [inDefault, inOther] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.lockURL.path))
        }
        XCTAssertEqual(otherBranch.load().status, .loaded)
        XCTAssertEqual(otherRepository.load().status, .loaded)
        XCTAssertEqual(archived(inOther), setAside)
        XCTAssertEqual(Store.deleteReviews(branch: "feat/x", repository: repository, stateDirectory: state), [])
    }
}

/// The review of a real branch: its repository, its reflog, and a name
/// reused after `git branch -D`.
final class BranchReviewStorageGitTests: XCTestCase {
    private var root: String!
    private var repo: String!
    private var environment: [String: String]!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-review-storage-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = try XCTUnwrap(base.path.realPath)
        let home = root + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        environment = ["HOME": home, "XDG_CONFIG_HOME": home, "GIT_CONFIG_NOSYSTEM": "1"]
        repo = root + "/widgets"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "--template=", "-b", "main"])
        try commit("initial", file: "README.md")
        try git(["checkout", "-q", "-b", "feat/x"])
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(atPath: root) }
    }

    @discardableResult
    private func git(_ arguments: [String], at directory: String? = nil) throws -> String {
        let pinned = [
            "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
            "-c", "user.name=Nirux Tests", "-c", "user.email=nirux@example.test"
        ]
        let result = try XCTUnwrap(BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: pinned + arguments,
            currentDirectoryURL: URL(fileURLWithPath: directory ?? repo),
            environment: environment,
            timeout: 30,
            captureStandardError: true
        ))
        guard result.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(result.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")): "
                    + String(decoding: result.standardError, as: UTF8.self)
            ])
        }
        return String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    private func commit(_ message: String, file: String) throws {
        try "\(message)\n".write(toFile: repo + "/" + file, atomically: true, encoding: .utf8)
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", message])
    }

    private var options: BranchReview.Options {
        BranchReview.Options(gitHub: nil, environment: environment)
    }

    private func snapshot() throws -> BranchReview.Snapshot {
        let outcome = BranchReview.snapshot(at: repo, options: options)
        guard case .snapshot(let snapshot) = outcome else {
            XCTFail("expected a snapshot, got \(outcome)")
            throw CancellationError()
        }
        return snapshot
    }

    func testEveryWorktreeOfARepositoryHasItsIdentity() throws {
        let worktree = root + "/widgets.feat-y"
        try git(["worktree", "add", "-q", "-b", "feat/y", worktree])
        let identity = try XCTUnwrap(BranchReview.repositoryIdentity(root: repo, options: options))
        XCTAssertEqual(identity, repo + "/.git")
        XCTAssertEqual(BranchReview.repositoryIdentity(root: worktree, options: options), identity)
        XCTAssertNil(BranchReview.repositoryIdentity(root: root, options: options))
    }

    func testReviewOutlivesARebaseButNotABranchDeletedAndMadeAgain() throws {
        try commit("first", file: "a.swift")
        let first = try snapshot()
        let identity = try XCTUnwrap(BranchReview.repositoryIdentity(root: repo, options: options))
        let store = try XCTUnwrap(BranchReview.Store(
            spaceID: "default", repository: identity, branch: "feat/x",
            stateDirectory: URL(fileURLWithPath: root + "/state")
        ))
        let reviewed = try XCTUnwrap(first.files.first { $0.path == "a.swift" })
        _ = try store.update(head: first.head, pullRequest: nil) {
            $0.markReviewed(reviewed, head: first.head, at: Date())
        }.get()

        // Rewritten: the reviewed head is no longer in the branch, but is
        // still in its reflog.
        try git(["commit", "-q", "--amend", "-m", "first, amended"])
        let rebased = try snapshot()
        XCTAssertEqual(BranchReview.reflog(of: "feat/x", contains: first.head, root: repo, options: options), true)
        let kept = store.open(for: rebased, options: options)
        XCTAssertEqual(kept.status, .loaded)
        XCTAssertEqual(kept.record.reviewedState(of: reviewed), .reviewed)
        XCTAssertEqual(store.load().record.lastHead, rebased.head)

        try git(["checkout", "-q", "main"])
        try git(["branch", "-q", "-D", "feat/x"])
        try git(["checkout", "-q", "-b", "feat/x"])
        try commit("unrelated", file: "b.swift")
        let reused = try snapshot()
        XCTAssertEqual(BranchReview.reflog(of: "feat/x", contains: rebased.head, root: repo, options: options), false)
        let fresh = store.open(for: reused, options: options)
        XCTAssertEqual(fresh.status, .missing)
        XCTAssertNotNil(fresh.setAside)
        XCTAssertNil(BranchReview.reflog(of: "feat/gone", contains: reused.head, root: repo, options: options))
    }
}
