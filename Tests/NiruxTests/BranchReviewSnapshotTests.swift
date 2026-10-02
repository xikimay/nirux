import XCTest
@testable import Nirux

/// `BranchReview.snapshot` on real, temporary git repositories, with a
/// fake gh. Git runs pinned against the developer's global and system
/// config (hooks, signing, excludes, templates).
final class BranchReviewSnapshotTests: XCTestCase {
    private var root: String!
    private var remote: String!
    private var repo: String!
    private var environment: [String: String]!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-review-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = try XCTUnwrap(base.path.realPath)
        let home = root + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        environment = ["HOME": home, "XDG_CONFIG_HOME": home, "GIT_CONFIG_NOSYSTEM": "1"]

        remote = root + "/remote.git"
        repo = root + "/widgets"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "--bare", "--template=", "-b", "main", remote], at: root)
        try git(["init", "-q", "--template=", "-b", "main"], at: repo)
        try write("README.md", "widgets\n")
        try write("Sources/App.swift", "let a = 1\nlet b = 2\nlet c = 3\n")
        try commit("initial")
        try git(["remote", "add", "origin", remote], at: repo)
        try git(["push", "-q", "-u", "origin", "main"], at: repo)
        try git(["checkout", "-q", "-b", "feat/x"], at: repo)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(atPath: root) }
    }

    // MARK: - Helpers

    @discardableResult
    private func git(_ arguments: [String], at directory: String? = nil) throws -> String {
        let pinned = [
            "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "tag.gpgSign=false",
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
        let stderr = String(data: result.standardError, encoding: .utf8) ?? ""
        guard result.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(result.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")): \(stderr)"
            ])
        }
        return String(decoding: result.standardOutput, as: UTF8.self)
    }

    private func write(_ path: String, _ text: String, at directory: String? = nil) throws {
        try write(path, Data(text.utf8), at: directory)
    }

    private func write(_ path: String, _ data: Data, at directory: String? = nil) throws {
        let url = URL(fileURLWithPath: (directory ?? repo) + "/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func commit(_ message: String, at directory: String? = nil) throws {
        try git(["add", "-A"], at: directory)
        try git(["commit", "-q", "--allow-empty", "-m", message], at: directory)
    }

    private func options(gitHub: BranchReview.GitHubCLI? = nil, fetchBase: Bool = false) -> BranchReview.Options {
        BranchReview.Options(gitHub: gitHub, fetchBase: fetchBase, environment: environment)
    }

    private func snapshot(_ options: BranchReview.Options? = nil, at path: String? = nil) throws -> BranchReview.Snapshot {
        let outcome = BranchReview.snapshot(at: path ?? repo, options: options ?? self.options())
        guard case .snapshot(let snapshot) = outcome else {
            XCTFail("expected a snapshot, got \(outcome)")
            throw CancellationError()
        }
        return snapshot
    }

    private func file(_ path: String, in snapshot: BranchReview.Snapshot) throws -> BranchReview.FileChange {
        try XCTUnwrap(snapshot.files.first { $0.path == path }, "\(path) not in \(snapshot.files.map(\.path))")
    }

    // MARK: - Reading the diff

    func testDiffLeavesTheIndexUntouchedAndSkipsTouchedFiles() throws {
        try write("Sources/App.swift", "let a = 1\nlet b = 20\nlet c = 3\n")
        let index = repo + "/.git/index"
        let before = try FileManager.default.attributesOfItem(atPath: index)
        // Same content, new timestamp: the index's stat data is stale.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: repo + "/README.md"
        )

        let snapshot = try snapshot()

        XCTAssertEqual(snapshot.files.map(\.path), ["Sources/App.swift"])
        let after = try FileManager.default.attributesOfItem(atPath: index)
        XCTAssertEqual(after[.systemFileNumber] as? Int, before[.systemFileNumber] as? Int, "the index was replaced")
        XCTAssertEqual(after[.modificationDate] as? Date, before[.modificationDate] as? Date, "the index was written")
    }

    func testUserGitConfigChangesNeitherThePatchNorItsHash() throws {
        let long = (1...30).map { "let line\($0) = \($0)\n" }
        try write("Sources/Long.swift", long.joined())
        try commit("long file")
        try git(["push", "-q", "origin", "HEAD:main"])
        try git(["fetch", "-q", "origin"])
        var edited = long
        edited[9] = "let line10 = 100\n"
        edited[19] = "let line20 = 200\n\n"
        try write("Sources/Long.swift", edited.joined())
        try write("Sources/App.swift", "let a = 1\nlet b = 20\nlet c = 3\n\nlet d = 4\n")
        try git(["mv", "README.md", "README-moved.md"])
        try write("we\tird.txt", "tab\n")
        try write("sp ace.txt", "space\n")
        try commit("work café")
        let plain = try snapshot()

        for setting in [
            "diff.noprefix=true", "diff.mnemonicPrefix=true", "diff.context=8", "diff.interHunkContext=10",
            "diff.algorithm=patience", "diff.indentHeuristic=false", "diff.renames=false", "color.diff=always",
            "color.ui=always", "core.quotePath=true", "diff.suppressBlankEmpty=true", "diff.external=/usr/bin/false",
            "i18n.logOutputEncoding=ISO-8859-1"
        ] {
            let parts = setting.split(separator: "=", maxSplits: 1).map(String.init)
            try git(["config", parts[0], parts[1]])
        }
        let configured = try snapshot()

        XCTAssertEqual(configured.files, plain.files)
        XCTAssertEqual(configured.commits, plain.commits)
        XCTAssertEqual(try file("README-moved.md", in: plain).status, .renamed)
        XCTAssertEqual(try file("Sources/App.swift", in: plain).hunks.first?.lines.first, BranchReview.Line(kind: .context, text: "let a = 1"))
        let hunks = try file("Sources/Long.swift", in: plain).hunks
        XCTAssertEqual(hunks.map(\.oldStart), [7, 17])
        XCTAssertEqual(hunks.map(\.oldCount), [7, 7])
    }

    func testFileEditedInCommitsAndInTheWorktreeIsListedOnce() throws {
        try write("Sources/App.swift", "let a = 10\nlet b = 2\nlet c = 3\n")
        try commit("committed edit")
        try write("Sources/App.swift", "let a = 10\nlet b = 2\nlet c = 30\n")
        try write("Sources/Other.swift", "let z = 0\n")
        try commit("other")

        let snapshot = try snapshot()

        let app = try file("Sources/App.swift", in: snapshot)
        XCTAssertEqual(snapshot.files.filter { $0.path == "Sources/App.swift" }.count, 1)
        XCTAssertFalse(app.isUncommitted)
        try write("Sources/App.swift", "let a = 10\nlet b = 22\nlet c = 30\n")
        let edited = try file("Sources/App.swift", in: try self.snapshot())
        XCTAssertTrue(edited.isUncommitted)
        XCTAssertEqual(edited.additions, 3, "the whole patch from the merge base")
        XCTAssertFalse(try file("Sources/Other.swift", in: try self.snapshot()).isUncommitted)
    }

    func testUntrackedFilesKeepTheirHashOnceCommitted() throws {
        try write("notes.txt", "one\ntwo")
        try write("crlf.txt", "one\r\ntwo\r\n")
        try write("run.sh", "#!/bin/sh\necho hi\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo + "/run.sh")
        try FileManager.default.createSymbolicLink(atPath: repo + "/link", withDestinationPath: "notes.txt")
        try write("logo.bin", Data([0x89, 0x50, 0x00, 0x01, 0x02]))
        try write("empty.txt", "")
        try write(".gitignore", "*.log\n")
        try write("debug.log", "ignored\n")
        try write(".claude-handover.md", "handover\n")
        try write(".claude/settings.local.json", "{}\n")

        let untracked = try snapshot()

        XCTAssertEqual(
            untracked.files.map(\.path), [".gitignore", "crlf.txt", "empty.txt", "link", "logo.bin", "notes.txt", "run.sh"]
        )
        XCTAssertEqual(try file("crlf.txt", in: untracked).hunks.first?.lines.map(\.text), ["one\r", "two\r"])
        XCTAssertTrue(untracked.files.allSatisfy { $0.isUntracked && $0.isUncommitted && $0.status == .added })
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", "add them"])
        let committed = try snapshot()
        XCTAssertEqual(committed.files.map(\.path), untracked.files.map(\.path))
        for (before, after) in zip(untracked.files, committed.files) {
            XCTAssertFalse(after.isUntracked)
            XCTAssertEqual(before.patchHash, after.patchHash, before.path)
            XCTAssertEqual(before.hunks, after.hunks, before.path)
            XCTAssertEqual(before.newMode, after.newMode, before.path)
            XCTAssertEqual(before.newObjectID, after.newObjectID, before.path)
        }
    }

    func testCommittedHandoverIsLeftOut() throws {
        try write(".codex-handover.md", "plan\n")
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("with a handover")

        XCTAssertEqual(try snapshot().files.map(\.path), ["Sources/App.swift"])
    }

    func testFileThatIsNotUTF8IsReadLossilyBesideTheOthers() throws {
        try write("latin.txt", Data([0x63, 0x61, 0x66, 0xE9, 0x0A]))
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("latin")

        let snapshot = try snapshot()

        XCTAssertEqual(snapshot.files.map(\.path), ["Sources/App.swift", "latin.txt"])
        XCTAssertEqual(try file("latin.txt", in: snapshot).hunks.first?.lines, [.init(kind: .added, text: "caf\u{FFFD}")])
    }

    // MARK: - Base

    func testBaseIsTheRemoteDefaultBranchNeverTheUpstream() throws {
        // main moved on GitHub; the local main is behind; the branch has
        // an upstream of its own and no origin/HEAD.
        let other = root + "/other"
        try git(["clone", "-q", remote, other], at: root)
        try write("Sources/Main.swift", "let m = 1\n", at: other)
        try commit("main moves", at: other)
        try git(["push", "-q", "origin", "main"], at: other)
        try git(["fetch", "-q", "origin"])
        try git(["merge", "-q", "--no-ff", "--no-edit", "origin/main"])
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("work")
        try git(["push", "-q", "-u", "origin", "feat/x"])
        // git 2.48+ creates origin/HEAD when it fetches.
        try? git(["remote", "set-head", "origin", "--delete"])

        let snapshot = try snapshot()

        XCTAssertEqual(snapshot.base.name, "main")
        XCTAssertEqual(snapshot.base.ref, "refs/remotes/origin/main")
        XCTAssertEqual(snapshot.files.map(\.path), ["Sources/App.swift"])
        XCTAssertEqual(snapshot.commits.map(\.subject), ["work", "Merge remote-tracking branch 'origin/main' into feat/x"])
        XCTAssertEqual(snapshot.commits.map(\.isMergeFromBase), [false, true])
    }

    // MARK: - Pull request

    private func pushAndPointAtGitHub() throws {
        try git(["push", "-q", "-u", "origin", "feat/x"])
        // gh matches the head repository on the push URL; git never pushes again.
        try git(["remote", "set-url", "--push", "origin", "https://github.com/acme/widgets.git"])
    }

    private func pullRequestJSON(number: Int = 7, base: String = "main", head: String, commits: [String]) -> Data {
        let object: [[String: Any]] = [[
            "number": number, "title": "Add x", "body": "Why: because.", "url": "https://github.com/acme/widgets/pull/\(number)",
            "baseRefName": base, "headRefOid": head, "isDraft": false,
            "headRepository": ["name": "widgets"], "headRepositoryOwner": ["login": "acme"],
            "commits": commits.map { ["oid": $0] }
        ]]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func fakeGitHub(_ answer: Data, status: Int32 = 0, error: String = "") -> BranchReview.GitHubCLI {
        BranchReview.GitHubCLI { _, _ in .init(status: status, standardOutput: answer, standardError: error) }
    }

    func testOpenPullRequestPicksAndFetchesItsBaseBranch() throws {
        // The pull request targets develop, which moved on GitHub after
        // the branch last fetched it.
        try git(["push", "-q", "origin", "main:develop"])
        try git(["fetch", "-q", "origin"])
        try FileManager.default.removeItem(atPath: repo + "/.git/FETCH_HEAD")
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("work")
        let head = try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
        try pushAndPointAtGitHub()
        let other = root + "/other"
        try git(["clone", "-q", "-b", "develop", remote, other], at: root)
        try write("Sources/Develop.swift", "let d = 1\n", at: other)
        try commit("develop moves", at: other)
        try git(["tag", "v1"], at: other)
        try git(["push", "-q", "origin", "develop", "v1"], at: other)
        let developTip = try git(["rev-parse", "HEAD"], at: other)
        try git(["config", "fetch.writeCommitGraph", "true"])
        let gitHub = fakeGitHub(pullRequestJSON(base: "develop", head: head, commits: [head]))

        let snapshot = try snapshot(options(gitHub: gitHub, fetchBase: true))

        XCTAssertEqual(snapshot.pullRequest.pullRequest?.number, 7)
        XCTAssertEqual(snapshot.pullRequest.pullRequest?.body, "Why: because.")
        XCTAssertEqual(snapshot.base.name, "develop")
        XCTAssertNil(snapshot.fetchProblem)
        XCTAssertEqual(try git(["rev-parse", "refs/remotes/origin/develop"]), developTip)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/.git/FETCH_HEAD"))
        XCTAssertEqual(try git(["tag", "--list"]), "")
        let objectInfo = try FileManager.default.contentsOfDirectory(atPath: repo + "/.git/objects/info")
        XCTAssertFalse(objectInfo.contains { $0.hasPrefix("commit-graph") }, "\(objectInfo)")
    }

    func testPullRequestOfAReusedBranchNameIsIgnoredUnlessItsHeadIsInTheReflog() throws {
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("work")
        let pushedHead = try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
        try pushAndPointAtGitHub()
        let stranger = String(repeating: "a", count: 40)

        let reused = try snapshot(options(gitHub: fakeGitHub(pullRequestJSON(head: stranger, commits: [stranger]))))
        XCTAssertEqual(reused.pullRequest, .notFound)
        // An old pull request whose commits reached main another way: they
        // are in HEAD's history, but in the base's too.
        let initial = try git(["rev-parse", "origin/main"]).trimmingCharacters(in: .newlines)
        let landed = try snapshot(options(gitHub: fakeGitHub(pullRequestJSON(head: stranger, commits: [initial]))))
        XCTAssertEqual(landed.pullRequest, .notFound)

        // Rewritten locally and not pushed yet: none of the pull request's
        // commits is in HEAD's history, but its head is in the reflog.
        try git(["commit", "-q", "--amend", "-m", "work, reworded"])
        let rebased = try snapshot(options(gitHub: fakeGitHub(pullRequestJSON(head: pushedHead, commits: [pushedHead]))))
        XCTAssertEqual(rebased.pullRequest.pullRequest?.headRefOid, pushedHead)
    }

    func testMissingOrFailingGitHubCLIIsSaidAndTheBaseStillFound() throws {
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("work")
        try pushAndPointAtGitHub()

        let missing = try snapshot(options(gitHub: nil))
        XCTAssertEqual(missing.pullRequest, .unavailable("The GitHub CLI (gh) isn't installed."))
        XCTAssertEqual(missing.base.name, "main")

        let loggedOut = try snapshot(options(gitHub: fakeGitHub(Data(), status: 4, error: "To get started with GitHub CLI, please run:  gh auth login\n")))
        XCTAssertEqual(loggedOut.pullRequest, .unavailable("gh couldn't list the pull requests: To get started with GitHub CLI, please run:  gh auth login"))
        XCTAssertEqual(loggedOut.files.map(\.path), ["Sources/App.swift"])
    }

    @MainActor
    func testLoadSnapshotRunsOffTheMainThreadAndCompletesOnIt() throws {
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("work")
        try pushAndPointAtGitHub()
        let calledOnMain = LockedFlag()
        let gitHub = BranchReview.GitHubCLI { _, _ in
            calledOnMain.set(Thread.isMainThread)
            return .init(status: 0, standardOutput: Data("[]".utf8), standardError: "")
        }
        let finished = expectation(description: "snapshot")
        BranchReview.loadSnapshot(at: repo, options: options(gitHub: gitHub)) { outcome in
            MainActor.assertIsolated()
            if case .snapshot(let snapshot) = outcome {
                XCTAssertEqual(snapshot.pullRequest, .notFound)
            } else {
                XCTFail("\(outcome)")
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)

        XCTAssertEqual(calledOnMain.value, false)
    }

    func testFilePatchTakesItsPathsLiterallyAndKeepsARename() throws {
        try write("x.txt", "plain\n")
        try write("Sources/Old.swift", (1...20).map { "let line\($0) = \($0)\n" }.joined())
        try commit("more files")
        try git(["push", "-q", "origin", "HEAD:main"])
        try git(["fetch", "-q", "origin"])
        try write("x.txt", "plain, edited\n")
        // As a pathspec, ":(top)x.txt" would name x.txt.
        try write(":(top)x.txt", "magic\n")
        try git(["add", "-A"])
        try git(["mv", "Sources/Old.swift", "Sources/New.swift"])
        try write("Sources/New.swift", (1...20).map { "let line\($0) = \($0)\n" }.joined() + "let more = 0\n")
        var onDemand = options()
        onDemand.maxInlineDiffBytes = 0
        let snapshot = try snapshot(onDemand)

        let magic = try XCTUnwrap(BranchReview.filePatch(try file(":(top)x.txt", in: snapshot), in: snapshot, options: onDemand))
        XCTAssertEqual(magic.hunks.first?.lines.map(\.text), ["magic"])
        let renamed = try file("Sources/New.swift", in: snapshot)
        XCTAssertEqual(renamed.status, .renamed)
        let loaded = try XCTUnwrap(BranchReview.filePatch(renamed, in: snapshot, options: onDemand))
        XCTAssertEqual(loaded.status, .renamed)
        XCTAssertEqual(loaded.oldPath, "Sources/Old.swift")
        XCTAssertEqual(loaded.patchHash, renamed.patchHash)
    }

    // MARK: - States

    func testMergeInProgressOrConflictsPauseTheReview() throws {
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("work")
        try git(["checkout", "-q", "main"])
        try write("Sources/App.swift", "let a = 3\nlet b = 2\nlet c = 3\n")
        try commit("main edit")
        try git(["checkout", "-q", "feat/x"])
        XCTAssertThrowsError(try git(["merge", "-q", "main"]))
        XCTAssertEqual(BranchReview.snapshot(at: repo, options: options()), .paused(.merge))

        try git(["merge", "--abort"])
        try write("Sources/App.swift", "let a = 4\nlet b = 2\nlet c = 3\n")
        try git(["stash", "-q"])
        try git(["merge", "-q", "main", "-X", "theirs", "-m", "take main"])
        XCTAssertThrowsError(try git(["stash", "pop", "-q"]))
        XCTAssertEqual(BranchReview.snapshot(at: repo, options: options()), .paused(.conflicts))
    }

    func testDetachedHeadIsNotReviewed() throws {
        try git(["checkout", "-q", "--detach"])

        XCTAssertEqual(
            BranchReview.snapshot(at: repo, options: options()),
            .unavailable("HEAD is detached: there is no branch to review.")
        )
    }

    // MARK: - Sizes

    func testLargeFilesGetPlaceholdersAndLargeDiffsLoadOnDemand() throws {
        try write("Sources/Big.swift", String(repeating: "let big = 0\n", count: 100))
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("big")
        try write("draft.txt", "draft\n")
        var limited = options()
        limited.maxFileDiffBytes = 1_000

        let placeholder = try snapshot(limited)
        let big = try file("Sources/Big.swift", in: placeholder)
        XCTAssertEqual(big.hunks, [])
        guard case .tooLarge(let bytes) = big.omission else { return XCTFail("\(String(describing: big.omission))") }
        XCTAssertGreaterThan(bytes, 1_000)
        XCTAssertNotNil(big.patchHash)
        XCTAssertEqual(big.additions, 100)
        XCTAssertNil(try file("Sources/App.swift", in: placeholder).omission)

        limited.maxInlineDiffBytes = 1_000
        let onDemand = try snapshot(limited)
        let app = try file("Sources/App.swift", in: onDemand)
        XCTAssertEqual(app.omission, .onDemand)
        XCTAssertEqual(app.hunks, [])
        XCTAssertEqual(try file("draft.txt", in: onDemand).omission, .onDemand)
        let loaded = try XCTUnwrap(BranchReview.filePatch(app, in: onDemand, options: limited))
        XCTAssertNil(loaded.omission)
        XCTAssertEqual(loaded.patchHash, app.patchHash)
        XCTAssertEqual(loaded.hunks, try file("Sources/App.swift", in: placeholder).hunks)

        limited.maxDiffBytes = 500
        let listed = try snapshot(limited)
        XCTAssertEqual(listed.files.map(\.path), ["Sources/App.swift", "Sources/Big.swift", "draft.txt"])
        XCTAssertTrue(listed.files.allSatisfy { $0.omission == .notRead && $0.patchHash == nil })
        XCTAssertEqual(try file("Sources/Big.swift", in: listed).additions, 100)
        XCTAssertNil(listed.diffBytes)
        XCTAssertEqual(
            BranchReview.filePatch(try file("Sources/App.swift", in: listed), in: listed, options: options())?.patchHash,
            app.patchHash
        )
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?

    var value: Bool? { lock.withLock { stored } }

    func set(_ value: Bool) { lock.withLock { stored = value } }
}
