import XCTest
@testable import Nirux

/// The review file of a branch (docs/branch-review.md, section 8): its name,
/// its format, its lock, which review a branch gets back, and who may write.
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

    private func store(_ branch: String = "feat/x", repository: String? = nil) throws -> Store {
        try XCTUnwrap(Store(repository: repository ?? self.repository, branch: branch, stateDirectory: state))
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

    /// git's answers, without git.
    private func history(own: Bool?, reflog: Bool?) -> BranchReview.History {
        BranchReview.History(isOwnCommit: { _ in own }, isInReflog: { _ in reflog })
    }

    /// A history that must not be asked.
    private var unasked: BranchReview.History {
        BranchReview.History(
            isOwnCommit: { _ in XCTFail("history asked"); return nil },
            isInReflog: { _ in XCTFail("reflog asked"); return nil }
        )
    }

    /// Opened at `head`, as a page would before writing.
    private func access(
        _ store: Store, head: String = "a1", pullRequest: BranchReview.PullRequestLookup = .notFound
    ) throws -> Store.Access {
        try XCTUnwrap(store.open(head: head, pullRequest: pullRequest, history: history(own: true, reflog: true)).access)
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
        XCTAssertEqual(plain.folder.path, root + "/state/reviews")
        let name = plain.fileURL.lastPathComponent
        XCTAssertTrue(name.hasPrefix("feat%2Fx-"), name)
        XCTAssertTrue(name.hasSuffix(".json"), name)
        XCTAssertEqual(plain.lockURL.lastPathComponent, name + ".lock")

        // APFS ignores case: the hash tells these apart.
        let upper = try store("Fix/A").fileURL.lastPathComponent
        let lower = try store("fix/a").fileURL.lastPathComponent
        XCTAssertNotEqual(upper.lowercased(), lower.lowercased())
        // Two repositories can both have the branch.
        XCTAssertNotEqual(try store("feat/x", repository: "/repos/gadgets/.git").fileURL, plain.fileURL)
        XCTAssertNil(Store(repository: repository, branch: "", stateDirectory: state))
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

        XCTAssertNoThrow(try long.update(try access(long)) { _ in }.get())
        XCTAssertEqual(long.load().record.branch, long.branch)
    }

    // MARK: - Format

    func testWriteKeepsWhatThisBuildDoesntKnow() throws {
        let store = try store()
        try place([
            "version": 1,
            "branch": "feat/x",
            "repository": repository,
            "lastHead": "a1",
            "reactions": [["id": "c1", "text": "Why?"]],
            "flags": [true, NSNull(), 1.5, 9_007_199_254_740_993],
            "reviewed": [
                "Sources/Old.swift": ["patchHash": "h0", "head": "a0", "reviewer": "kept"]
            ]
        ], in: store)

        let opened = store.open(head: "b2", pullRequest: pullRequest(57), history: history(own: true, reflog: nil))
        let written = try store.update(try XCTUnwrap(opened.access)) { record in
            record.markReviewed(self.file("Sources/New.swift", hash: "h1"), head: "b2", at: self.date)
        }.get()

        let object = try stored(store)
        XCTAssertEqual(object["reactions"] as? [[String: String]], [["id": "c1", "text": "Why?"]])
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: store.fileURL))
        XCTAssertEqual(fields["flags"], .array([.bool(true), .null, .double(1.5), .int(9_007_199_254_740_993)]))
        let marks = try XCTUnwrap(object["reviewed"] as? [String: [String: String]])
        XCTAssertEqual(marks["Sources/Old.swift"], ["patchHash": "h0", "head": "a0", "reviewer": "kept"])
        XCTAssertEqual(object["lastHead"] as? String, "b2")
        XCTAssertEqual(object["pullRequest"] as? Int, 57)
        XCTAssertEqual(object["version"] as? Int, Record.currentVersion)
        XCTAssertEqual(store.load().record, written.record)
        XCTAssertEqual(
            written.record.reviewedMarks["Sources/New.swift"],
            BranchReview.ReviewedMark(patchHash: "h1", head: "b2", date: date)
        )
    }

    func testReviewFilesArePrivate() throws {
        let store = try store()
        _ = try store.update(try access(store)) { _ in }.get()
        XCTAssertEqual(try permissions(store.fileURL), 0o600)
        XCTAssertEqual(try permissions(store.folder), 0o700)
    }

    func testFileFromANewerVersionIsShownButNeverWritten() throws {
        let store = try store()
        let earlier = try access(store)
        try place([
            "version": 2, "branch": "feat/x", "repository": repository, "lastHead": "a1", "pullRequest": 57,
            "reviewed": ["a.swift": ["patchHash": "h1"]]
        ], in: store)
        let before = try Data(contentsOf: store.fileURL)

        // Not set aside either, even under another pull request.
        let opened = store.open(head: "b2", pullRequest: pullRequest(60), history: history(own: false, reflog: false))
        XCTAssertEqual(opened.status, .readOnly(.newerVersion(2)))
        XCTAssertNil(opened.access)
        XCTAssertEqual(opened.record.reviewedMarks["a.swift"]?.patchHash, "h1")
        XCTAssertEqual(store.update(earlier) { $0.clearReviewed(path: "a.swift") }, .failure(.readOnly(.newerVersion(2))))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        XCTAssertEqual(archived(store), [])
    }

    func testFileThatIsntAReviewIsSetAsideByTheFirstWrite() throws {
        let store = try store()
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        for bytes in [Data("{ not json".utf8), Data(#"{"version": "two"}"#.utf8)] {
            try bytes.write(to: store.fileURL)
            let opened = store.open(head: "a1", pullRequest: .notFound, history: unasked)
            XCTAssertEqual(opened.status, .unreadable)
            XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes, "opening alone changes nothing")

            _ = try store.update(try XCTUnwrap(opened.access)) { _ in }.get()

            XCTAssertEqual(store.load().status, .loaded)
            let copies = archived(store).filter { $0.contains(".unreadable.") }
            XCTAssertTrue(try copies.contains { try Data(contentsOf: store.archiveFolder.appendingPathComponent($0)) == bytes })
        }
    }

    /// A change that leaves a review not created yet empty creates
    /// nothing, when the writer asks so (the column does): no file where
    /// there was none, and an unreadable one stays as it is.
    func testChangeThatLeavesNothingCreatesNothingWhenAsked() throws {
        let store = try store()
        let access = try access(store)
        _ = try store.update(access, createsEmpty: false) { $0.removeDraft(id: "d1") }.get()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))

        let bytes = Data("{ not json".utf8)
        try bytes.write(to: store.fileURL)
        let opened = store.open(head: "a1", pullRequest: .notFound, history: unasked)
        XCTAssertEqual(opened.status, .unreadable)
        _ = try store.update(try XCTUnwrap(opened.access), createsEmpty: false) { $0.removeDraft(id: "d1") }.get()
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
        XCTAssertEqual(archived(store), [])
        // A change that leaves something sets it aside, as always.
        _ = try store.update(try XCTUnwrap(opened.access), createsEmpty: false) {
            $0.markReviewed(self.file("a.swift", hash: "h1"), head: "a1", at: self.date)
        }.get()
        XCTAssertEqual(store.load().status, .loaded)
        XCTAssertEqual(archived(store).filter { $0.contains(".unreadable.") }.count, 1)
    }

    func testFileThatCantBeReadNowIsNeitherSetAsideNorReplaced() throws {
        let store = try store()
        let access = try access(store)
        _ = try store.update(access) { $0.markReviewed(self.file("a.swift", hash: "h1"), head: "a1", at: self.date) }.get()
        let before = try Data(contentsOf: store.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path) }

        XCTAssertEqual(store.open(head: "a1", pullRequest: .notFound, history: unasked).status, .readOnly(.couldNotRead))
        XCTAssertEqual(store.update(access) { _ in }, .failure(.readOnly(.couldNotRead)))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        XCTAssertEqual(archived(store), [])
    }

    func testLinkInPlaceOfTheFileIsNeitherFollowedNorReplaced() throws {
        let store = try store()
        let access = try access(store)
        let elsewhere = URL(fileURLWithPath: root + "/elsewhere.json")
        try Data(#"{"branch": "feat/x"}"#.utf8).write(to: elsewhere)
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: elsewhere)

        XCTAssertEqual(store.load().status, .readOnly(.notARegularFile))
        XCTAssertEqual(store.update(access) { _ in }, .failure(.readOnly(.notARegularFile)))
        XCTAssertEqual(try String(contentsOf: elsewhere, encoding: .utf8), #"{"branch": "feat/x"}"#)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: store.fileURL.path))
    }

    func testReviewTooLargeToReadBackIsNotWritten() throws {
        let store = try store()
        let access = try access(store)
        _ = try store.update(access) { $0.markReviewed(self.file("a.swift", hash: "h1"), head: "a1", at: self.date) }.get()
        let before = try Data(contentsOf: store.fileURL)
        let huge = String(repeating: "x", count: Store.maxFileBytes)

        XCTAssertEqual(
            store.update(access) { $0.markReviewed(self.file(huge, hash: "h2"), head: "a1", at: self.date) },
            .failure(.tooLarge)
        )
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    }

    // MARK: - Reviewed marks

    func testMarkIsNeverClearedForWantOfAHash() throws {
        let store = try store()
        _ = try store.update(try access(store)) { $0.markReviewed(self.file("a.swift", hash: "h1"), head: "a1", at: self.date) }.get()
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

    private func record(pullRequest: Int?, lastHead: String?) -> Record {
        var fields: [String: JSONValue] = ["branch": .string("feat/x"), "repository": .string(repository)]
        fields["pullRequest"] = pullRequest.map { .int(Int64($0)) }
        fields["lastHead"] = lastHead.map(JSONValue.string)
        return Record(fields: fields)
    }

    private func disposition(
        _ record: Record, pullRequest: BranchReview.PullRequestLookup, history: BranchReview.History
    ) -> BranchReview.Disposition {
        BranchReview.disposition(
            of: record, branch: "feat/x", repository: repository, head: "c3", pullRequest: pullRequest, history: history
        )
    }

    func testSameHeadOrOneOfItsOwnCommitsKeepsItWhateverThePullRequest() {
        // #57 closed and #60 opened for the same commits, or a second PR.
        XCTAssertEqual(disposition(record(pullRequest: 57, lastHead: "c3"), pullRequest: pullRequest(60), history: unasked), .keep)
        XCTAssertEqual(
            disposition(record(pullRequest: 57, lastHead: "a1"), pullRequest: pullRequest(60), history: history(own: true, reflog: false)),
            .keep
        )
    }

    func testStoredPullRequestDecidesOtherwise() {
        let rebased = record(pullRequest: 57, lastHead: "a1")
        let noReflog = BranchReview.History(isOwnCommit: { _ in false }, isInReflog: { _ in XCTFail("reflog asked"); return nil })
        XCTAssertEqual(disposition(rebased, pullRequest: pullRequest(57), history: noReflog), .keep)
        XCTAssertEqual(disposition(rebased, pullRequest: pullRequest(60), history: noReflog), .archive)
        // Unless git couldn't say whether the branch moved on from it.
        let unknown = BranchReview.History(isOwnCommit: { _ in nil }, isInReflog: { _ in XCTFail("reflog asked"); return nil })
        XCTAssertEqual(disposition(rebased, pullRequest: pullRequest(60), history: unknown), .unverified)
    }

    func testReflogDecidesWithoutAPullRequestToCompare() {
        // Merged or closed, gh missing, or none recorded yet.
        for (stored, lookup) in [
            (57, BranchReview.PullRequestLookup.notFound),
            (57, .unavailable("gh isn’t installed.")),
            (nil, pullRequest(57))
        ] as [(Int?, BranchReview.PullRequestLookup)] {
            let record = record(pullRequest: stored, lastHead: "a1")
            XCTAssertEqual(disposition(record, pullRequest: lookup, history: history(own: false, reflog: true)), .keep)
            XCTAssertEqual(disposition(record, pullRequest: lookup, history: history(own: false, reflog: false)), .archive)
            XCTAssertEqual(disposition(record, pullRequest: lookup, history: history(own: false, reflog: nil)), .unverified)
            // git couldn't say whether it is one of the branch's commits.
            XCTAssertEqual(disposition(record, pullRequest: lookup, history: history(own: nil, reflog: false)), .unverified)
        }
    }

    func testFileOfAnotherBranchOrRepositoryOrWithoutAHeadIsNotKept() {
        var other = Record()
        other.stamp(branch: "feat/y", repository: repository, head: "c3", pullRequest: 57)
        XCTAssertEqual(disposition(other, pullRequest: pullRequest(57), history: unasked), .archive)
        other.stamp(branch: "feat/x", repository: "/repos/gadgets/.git", head: "c3", pullRequest: 57)
        XCTAssertEqual(disposition(other, pullRequest: pullRequest(57), history: unasked), .archive)
        XCTAssertEqual(disposition(record(pullRequest: 57, lastHead: nil), pullRequest: pullRequest(57), history: unasked), .archive)
    }

    // MARK: - Opening

    func testOpeningKeepsTheBranchsReviewAndRecordsWhereItIs() throws {
        let store = try store()
        _ = try store.update(try access(store)) { $0.markReviewed(self.file("a.swift", hash: "h1"), head: "a1", at: self.date) }.get()

        let opened = store.open(head: "b2", pullRequest: pullRequest(57), history: history(own: true, reflog: nil))

        XCTAssertEqual(opened.status, .loaded)
        XCTAssertNil(opened.setAside)
        XCTAssertEqual(opened.access?.head, "b2")
        XCTAssertEqual(opened.record.reviewedMarks["a.swift"]?.patchHash, "h1")
        XCTAssertEqual(store.load().record.lastHead, "b2")
        XCTAssertEqual(store.load().record.pullRequest, 57)
    }

    func testOpeningSetsAsideAReusedNamesReview() throws {
        let store = try store()
        _ = try store.update(try access(store, pullRequest: pullRequest(57))) {
            $0.markReviewed(self.file("a.swift", hash: "h1"), head: "a1", at: self.date)
        }.get()
        let earlier = try Data(contentsOf: store.fileURL)

        let opened = store.open(head: "b2", pullRequest: pullRequest(60), history: history(own: false, reflog: true))

        XCTAssertEqual(opened.status, .missing)
        XCTAssertEqual(opened.record, Record())
        XCTAssertNotNil(opened.access)
        let setAside = try XCTUnwrap(opened.setAside)
        XCTAssertEqual(setAside.deletingLastPathComponent(), store.archiveFolder)
        XCTAssertTrue(setAside.lastPathComponent.contains(".reused."), setAside.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: setAside), earlier)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testOpeningWhenGitCantSayLeavesTheFileAndIsReadOnly() throws {
        let store = try store()
        _ = try store.update(try access(store)) { _ in }.get()
        let before = try Data(contentsOf: store.fileURL)

        let opened = store.open(head: "b2", pullRequest: .unavailable("gh isn’t installed."), history: history(own: false, reflog: nil))

        guard case .readOnly(.unverified) = opened.status else { return XCTFail("\(opened.status)") }
        XCTAssertNil(opened.access)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        XCTAssertEqual(archived(store), [])
    }

    func testOpeningDecidesAgainWhenTheFileChangesWhileGitAnswers() throws {
        let store = try store()
        _ = try store.update(try access(store, pullRequest: pullRequest(57))) { _ in }.get()
        var asked = 0
        let racing = BranchReview.History(
            isOwnCommit: { _ in
                asked += 1
                if asked == 1 {
                    // Another Nirux opens it at b2 meanwhile.
                    _ = store.open(head: "b2", pullRequest: self.pullRequest(57), history: self.history(own: true, reflog: true))
                }
                return false
            },
            isInReflog: { _ in false }
        )

        let opened = store.open(head: "b2", pullRequest: .notFound, history: racing)

        XCTAssertEqual(opened.status, .loaded)
        XCTAssertEqual(archived(store), [])
        XCTAssertEqual(store.load().record.lastHead, "b2")
    }

    func testOpeningABranchNeverReviewedLeavesNothingBehind() throws {
        let store = try store()
        XCTAssertEqual(store.open(head: "a1", pullRequest: pullRequest(57), history: unasked).status, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
    }

    func testOpeningASnapshotOfAnotherBranchChangesNothing() throws {
        let store = try store()
        _ = try store.update(try access(store)) { _ in }.get()
        let before = try Data(contentsOf: store.fileURL)
        let snapshot = BranchReview.Snapshot(
            root: root, branch: "feat/y", head: "b2", base: BranchReview.Base(name: "main", ref: "refs/heads/main", mergeBase: "m0"),
            pullRequest: pullRequest(60), fetchProblem: nil, upstream: nil, pullRequestHead: nil,
            hasUncommittedChanges: false, commits: [], files: [], testsAgainstCode: BranchReview.TestsAgainstCode()
        )

        let opened = store.open(for: snapshot)

        guard case .readOnly(.unverified) = opened.status else { return XCTFail("\(opened.status)") }
        XCTAssertEqual(opened.record, Record())
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        XCTAssertEqual(archived(store), [])
    }

    // MARK: - Who may write

    func testWriteNeverBringsBackADeletedReviewNorTakesOverAnotherHeads() throws {
        let store = try store()
        let first = try access(store)
        let afterWrite = try XCTUnwrap(try store.update(first) { _ in }.get().access)

        // Opened at another head since (another Nirux, a reload).
        _ = store.open(head: "b2", pullRequest: .notFound, history: history(own: true, reflog: true))
        XCTAssertEqual(store.update(afterWrite) { _ in }, .failure(.changedSinceOpened))
        XCTAssertEqual(store.load().record.lastHead, "b2")

        // Deleted since (Clean Up).
        let reopened = try XCTUnwrap(store.open(head: "b2", pullRequest: .notFound, history: unasked).access)
        XCTAssertTrue(store.delete())
        XCTAssertEqual(store.update(reopened) { _ in }, .failure(.changedSinceOpened))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.lockURL.path))

        // Another branch's access.
        XCTAssertEqual(try self.store("feat/y").update(first) { _ in }, .failure(.changedSinceOpened))
    }

    // MARK: - Lock

    func testWriteWaitsWhileAnotherProcessHoldsTheLock() throws {
        let lockf = "/usr/bin/lockf"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: lockf), "no lockf")
        let store = try store()
        let access = try access(store)
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        // Holds the lock until its standard input closes.
        let holder = Process()
        let input = Pipe()
        holder.executableURL = URL(fileURLWithPath: lockf)
        holder.arguments = ["-k", store.lockURL.path, "/bin/sh", "-c", "read line"]
        holder.standardInput = input
        try holder.run()
        defer {
            try? input.fileHandleForWriting.close()
            holder.waitUntilExit()
        }
        let deadline = Date().addingTimeInterval(10)
        while let probe = try? holdLock(store.lockURL) {
            close(probe)
            guard Date() < deadline else { return XCTFail("lockf never took the lock") }
            usleep(10_000)
        }

        let written = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = store.update(access) { _ in }
            written.signal()
        }
        XCTAssertEqual(written.wait(timeout: .now() + 0.5), .timedOut)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        try input.fileHandleForWriting.close()
        XCTAssertEqual(written.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(store.load().record.lastHead, "a1")
    }

    func testWriterWaitingOnADeletedLockFileLocksTheNewOne() throws {
        let store = try store()
        let access = try access(store)
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        let first = try holdLock(store.lockURL)
        let written = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = store.update(access) { _ in }
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

    func testWritingOrOpeningGivesUpOnALockHeldTooLong() throws {
        var store = try store()
        store.lockTimeout = 0.2
        let access = try access(store)
        _ = try store.update(access) { $0.markReviewed(self.file("a.swift", hash: "h1"), head: "a1", at: self.date) }.get()
        let before = try Data(contentsOf: store.fileURL)
        let held = try holdLock(store.lockURL)
        defer { close(held) }
        let impatient = store

        let gaveUp = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            if case .failure(.couldNotLock) = impatient.update(access, { _ in }) { gaveUp.signal() }
        }
        XCTAssertEqual(gaveUp.wait(timeout: .now() + 5), .success)

        // Opened at a new head, it is still shown, read-only; a reused
        // name's isn't.
        let kept = store.open(head: "b2", pullRequest: .notFound, history: history(own: true, reflog: nil))
        guard case .readOnly(.unverified) = kept.status else { return XCTFail("\(kept.status)") }
        XCTAssertEqual(kept.record.reviewedMarks["a.swift"]?.patchHash, "h1")
        let reused = store.open(head: "b2", pullRequest: .notFound, history: history(own: false, reflog: false))
        guard case .readOnly(.unverified) = reused.status else { return XCTFail("\(reused.status)") }
        XCTAssertEqual(reused.record, Record())
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    }

    func testConcurrentWritersKeepEachOthersChanges() throws {
        let store = try store()
        let access = try access(store)
        let date = date
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            _ = store.update(access) { record in
                record.markReviewed(
                    BranchReview.FileChange(path: "f\(index).swift", status: .modified, patchHash: "h"), head: "a1", at: date
                )
            }
        }
        XCTAssertEqual(store.load().record.reviewedMarks.count, 40)
    }

    // MARK: - Clean Up

    func testDeletingAReviewSparesTheOthers() throws {
        let deleted = try store("feat/x")
        let otherBranch = try store("feat/y")
        let otherRepository = try store("feat/x", repository: "/repos/gadgets/.git")
        for store in [deleted, otherBranch, otherRepository] {
            _ = try store.update(try access(store, pullRequest: pullRequest(57))) { _ in }.get()
        }
        let reused = deleted.open(head: "b2", pullRequest: pullRequest(60), history: history(own: false, reflog: true))
        _ = try deleted.update(try XCTUnwrap(reused.access)) { _ in }.get()
        let setAside = archived(deleted)
        XCTAssertEqual(setAside.count, 1)

        XCTAssertTrue(deleted.delete())

        XCTAssertFalse(FileManager.default.fileExists(atPath: deleted.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: deleted.lockURL.path))
        XCTAssertEqual(otherBranch.load().status, .loaded)
        XCTAssertEqual(otherRepository.load().status, .loaded)
        XCTAssertEqual(archived(deleted), setAside)
        XCTAssertFalse(deleted.delete())
    }
}

/// The review of a real branch: its repository, its history and reflog,
/// and a name reused after `git branch -D`.
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

    private func commit(_ message: String, file: String, at directory: String? = nil) throws {
        try "\(message)\n".write(toFile: (directory ?? repo) + "/" + file, atomically: true, encoding: .utf8)
        try git(["add", "-A"], at: directory)
        try git(["commit", "-q", "-m", message], at: directory)
    }

    private var options: BranchReview.Options {
        BranchReview.Options(gitHub: nil, environment: environment)
    }

    private func snapshot(at path: String? = nil) throws -> BranchReview.Snapshot {
        let outcome = BranchReview.snapshot(at: path ?? repo, options: options)
        guard case .snapshot(let snapshot) = outcome else {
            XCTFail("expected a snapshot, got \(outcome)")
            throw CancellationError()
        }
        return snapshot
    }

    /// The review of the branch `snapshot` reads, written once at its head.
    private func review(of snapshot: BranchReview.Snapshot) throws -> BranchReview.Store {
        let identity = try XCTUnwrap(BranchReview.repositoryIdentity(root: snapshot.root, options: options))
        let store = try XCTUnwrap(BranchReview.Store(
            repository: identity, branch: snapshot.branch, stateDirectory: URL(fileURLWithPath: root + "/state")
        ))
        let opened = store.open(for: snapshot, options: options)
        _ = try store.update(try XCTUnwrap(opened.access)) { _ in }.get()
        return store
    }

    private func isOwnCommit(_ commit: String, in snapshot: BranchReview.Snapshot) -> Bool? {
        BranchReview.isOwnCommit(commit, head: snapshot.head, mergeBase: snapshot.base.mergeBase, root: snapshot.root, options: options)
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
        let store = try review(of: first)

        // Rewritten: the reviewed head is no longer in the branch, but is
        // still in its reflog.
        try git(["commit", "-q", "--amend", "-m", "first, amended"])
        let rebased = try snapshot()
        XCTAssertEqual(isOwnCommit(first.head, in: rebased), false)
        XCTAssertEqual(BranchReview.reflog(of: "feat/x", contains: first.head, root: repo, options: options), true)
        XCTAssertEqual(store.open(for: rebased, options: options).status, .loaded)
        XCTAssertEqual(store.load().record.lastHead, rebased.head)

        try git(["checkout", "-q", "main"])
        try git(["branch", "-q", "-D", "feat/x"])
        try git(["checkout", "-q", "-b", "feat/x"])
        try commit("unrelated", file: "b.swift")
        let reused = try snapshot()
        let fresh = store.open(for: reused, options: options)
        XCTAssertEqual(fresh.status, .missing)
        XCTAssertNotNil(fresh.setAside)
        XCTAssertNil(BranchReview.reflog(of: "feat/gone", contains: reused.head, root: repo, options: options))
        // A head gc pruned is no commit of the branch's, which git can say.
        XCTAssertEqual(isOwnCommit(String(repeating: "0", count: 40), in: reused), false)
    }

    func testBranchThatMovedOnKeepsItsReviewWithoutItsReflog() throws {
        try commit("first", file: "a.swift")
        let first = try snapshot()
        let store = try review(of: first)
        // Moved on twice, the reflog emptied in between: no entry holds
        // the reviewed head, even as the head before the oldest one.
        try commit("second", file: "b.swift")
        try git(["reflog", "expire", "--expire=now", "--all"])
        try commit("third", file: "c.swift")
        let moved = try snapshot()

        XCTAssertEqual(BranchReview.reflog(of: "feat/x", contains: first.head, root: repo, options: options), false)
        XCTAssertEqual(isOwnCommit(first.head, in: moved), true)
        XCTAssertEqual(store.open(for: moved, options: options).status, .loaded)
        // Main's commits aren't the branch's own, and a name read from the
        // file isn't a commit: "HEAD" would always pass for one.
        XCTAssertEqual(isOwnCommit(moved.base.mergeBase, in: moved), false)
        XCTAssertEqual(isOwnCommit("HEAD", in: moved), false)
    }

    func testReflogThatGitStopsAnsweringIsUnknown() throws {
        try commit("first", file: "a.swift")
        try commit("second", file: "b.swift")
        // A git whose rev-parse hangs: the second question times out.
        let slowGit = root + "/slow-git"
        try """
        #!/bin/sh
        case "$1" in rev-parse) exec /bin/sleep 10 ;; *) exec /usr/bin/git "$@" ;; esac
        """.write(toFile: slowGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slowGit)
        var slow = options
        slow.gitPath = slowGit
        slow.timeout = 0.5

        XCTAssertNil(BranchReview.reflog(of: "feat/x", contains: String(repeating: "0", count: 40), root: repo, options: slow))
    }

    func testBareRepositorysWorktreeKeepsAReviewStartedBeforeItsFirstCommit() throws {
        let bare = root + "/bare.git"
        let worktree = root + "/bare.feat-z"
        try git(["clone", "-q", "--bare", repo, bare], at: root)
        // From the bare repository, the branch's creation isn't logged.
        try git(["worktree", "add", "-q", "-b", "feat/z", worktree, "main"], at: bare)
        let start = try snapshot(at: worktree)
        let store = try review(of: start)
        try commit("first", file: "a.swift", at: worktree)
        let moved = try snapshot(at: worktree)

        XCTAssertEqual(try git(["log", "-g", "--format=%H", "refs/heads/feat/z", "--"], at: worktree), moved.head)
        XCTAssertEqual(BranchReview.reflog(of: "feat/z", contains: start.head, root: worktree, options: options), true)
        XCTAssertEqual(store.open(for: moved, options: options).status, .loaded)
    }
}
