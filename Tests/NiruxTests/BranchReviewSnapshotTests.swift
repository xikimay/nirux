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
        // A folder named with "/" in the Finder holds a ":" on disk.
        repo = root + "/wid:gets"
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
        try Self.git(arguments, at: directory ?? repo, environment: environment)
    }

    /// Also for a fake gh, which runs off the test's actor.
    @discardableResult
    private static func git(_ arguments: [String], at directory: String, environment: [String: String]) throws -> String {
        let pinned = [
            "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "tag.gpgSign=false",
            "-c", "user.name=Nirux Tests", "-c", "user.email=nirux@example.test"
        ]
        guard let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: pinned + arguments,
            currentDirectoryURL: URL(fileURLWithPath: directory),
            environment: environment,
            timeout: 30,
            captureStandardError: true
        ) else { throw NSError(domain: "git", code: -1) }
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

    /// Commits on the branch, then makes it main's too, so the branch
    /// starts from it.
    private func commitToMain(_ message: String) throws {
        try commit(message)
        try git(["push", "-q", "origin", "HEAD:main"])
        try git(["fetch", "-q", "origin"])
    }

    private func head(at directory: String? = nil) throws -> String {
        try git(["rev-parse", "HEAD"], at: directory).trimmingCharacters(in: .newlines)
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
        try git(["config", "core.splitIndex", "true"])
        try git(["update-index", "--split-index"])
        let sharedIndexes = try FileManager.default.contentsOfDirectory(atPath: repo + "/.git").filter { $0.hasPrefix("sharedindex.") }
        try write(".git/hooks/post-index-change", "#!/bin/sh\ntouch \"$(dirname \"$0\")/hook-ran\"\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo + "/.git/hooks/post-index-change")
        let index = repo + "/.git/index"
        let before = try FileManager.default.attributesOfItem(atPath: index)
        // Same content, new timestamp: the index's stat data is stale.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: repo + "/README.md"
        )
        func assertIndexUntouched(_ message: String) throws {
            let after = try FileManager.default.attributesOfItem(atPath: index)
            XCTAssertEqual(after[.systemFileNumber] as? Int, before[.systemFileNumber] as? Int, "replaced \(message)")
            XCTAssertEqual(after[.modificationDate] as? Date, before[.modificationDate] as? Date, "written \(message)")
        }

        XCTAssertEqual(try snapshot().files.map(\.path), ["Sources/App.swift"])
        try assertIndexUntouched("by the diff")

        // An untracked file goes through a temporary index and object folder.
        try write("draft.txt", "untracked\n")
        XCTAssertEqual(try snapshot().files.map(\.path), ["Sources/App.swift", "draft.txt"])
        try assertIndexUntouched("for an untracked file")
        let objects = try FileManager.default.subpathsOfDirectory(atPath: repo + "/.git/objects")
        XCTAssertFalse(objects.contains { $0.hasPrefix("e6/") }, "the empty blob was written: \(objects)")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: repo + "/.git").filter { $0.hasPrefix("sharedindex.") },
            sharedIndexes
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/.git/hooks/hook-ran"), "a hook ran")
    }

    func testUserGitConfigChangesNeitherThePatchNorItsHash() throws {
        let long = (1...30).map { "let line\($0) = \($0)\n" }
        try write("Sources/Long.swift", long.joined())
        try write("frob.c", Self.frobnitz)
        try commitToMain("long files")
        var edited = long
        edited[9] = "let line10 = 100\n"
        edited[19] = "let line20 = 200\n\n"
        try write("Sources/Long.swift", edited.joined())
        // Myers and patience disagree on this one.
        try write("frob.c", Self.fibonacci)
        try write("Sources/App.swift", "let a = 1\nlet b = 20\nlet c = 3\n\nlet d = 4\n")
        try git(["mv", "README.md", "README-moved.md"])
        try write("we\tird.txt", "tab\n")
        try commit("work café")
        let plain = try snapshot()

        for setting in [
            "diff.noprefix=true", "diff.mnemonicPrefix=true", "diff.context=8", "diff.interHunkContext=10",
            "diff.algorithm=patience", "diff.renames=false", "color.diff=always", "color.ui=always",
            "diff.external=/usr/bin/false", "i18n.logOutputEncoding=ISO-8859-1"
        ] {
            let parts = setting.split(separator: "=", maxSplits: 1).map(String.init)
            try git(["config", parts[0], parts[1]])
        }
        var configured = options()
        configured.environment["GIT_DIFF_OPTS"] = "--unified=10"
        let withConfig = try snapshot(configured)

        XCTAssertEqual(withConfig.files, plain.files)
        XCTAssertEqual(withConfig.commits, plain.commits)
        XCTAssertEqual(try file("README-moved.md", in: plain).status, .renamed)
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

        let committed = try snapshot()

        XCTAssertFalse(try file("Sources/App.swift", in: committed).isUncommitted)
        XCTAssertFalse(committed.hasUncommittedChanges)
        try write("Sources/App.swift", "let a = 10\nlet b = 22\nlet c = 30\n")
        let edited = try snapshot()
        XCTAssertEqual(edited.files.map(\.path), ["Sources/App.swift", "Sources/Other.swift"])
        XCTAssertTrue(try file("Sources/App.swift", in: edited).isUncommitted)
        XCTAssertEqual(try file("Sources/App.swift", in: edited).additions, 3, "the whole patch from the merge base")
        XCTAssertFalse(try file("Sources/Other.swift", in: edited).isUncommitted)
        XCTAssertTrue(edited.hasUncommittedChanges)
    }

    func testUntrackedFilesKeepTheirHashOnceCommitted() throws {
        try write("Sources/Old.swift", (1...20).map { "let line\($0) = \($0)\n" }.joined())
        try commitToMain("old file")
        // Moved with mv, not git mv, and edited: a rename once committed.
        try FileManager.default.moveItem(atPath: repo + "/Sources/Old.swift", toPath: repo + "/Sources/New.swift")
        try write("Sources/New.swift", (1...20).map { "let line\($0) = \($0)\n" }.joined() + "let more = 0\n")
        try write(".gitattributes", "*.norm text=auto\n*.lock -diff\n")
        try write("crlf.norm", "one\r\ntwo\r\n")
        try write("crlf.txt", "one\r\ntwo\r\n")
        try write("deps.lock", "pinned\n")
        try write("notes.txt", "one\ntwo")
        try write("run.sh", "#!/bin/sh\necho hi\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo + "/run.sh")
        try FileManager.default.createSymbolicLink(atPath: repo + "/link", withDestinationPath: "notes.txt")
        try write("logo.bin", Data([0x89, 0x50, 0x00, 0x01, 0x02]))
        try write("empty.txt", "")
        try write("\u{301}accent.txt", "accent\n")
        // As a pathspec, this would add every untracked file but zzz.txt.
        try write(":(exclude)zzz.txt", "magic\n")
        try write(".gitignore", "*.log\n")
        try write("debug.log", "ignored\n")
        try write(".claude-handover.md", "handover\n")
        try write(".claude/settings.local.json", "{}\n")

        let untracked = try snapshot()

        XCTAssertEqual(untracked.files.map(\.path), [
            ".gitattributes", ".gitignore", ":(exclude)zzz.txt", "Sources/New.swift", "crlf.norm", "crlf.txt", "deps.lock",
            "empty.txt", "link", "logo.bin", "notes.txt", "run.sh", "\u{301}accent.txt"
        ])
        XCTAssertTrue(untracked.files.allSatisfy { $0.isUntracked && $0.isUncommitted })
        let moved = try file("Sources/New.swift", in: untracked)
        XCTAssertEqual(moved.status, .renamed)
        XCTAssertEqual(moved.oldPath, "Sources/Old.swift")
        XCTAssertEqual(try file("crlf.norm", in: untracked).hunks.first?.lines.map(\.text), ["one", "two"])
        XCTAssertEqual(try file("crlf.txt", in: untracked).hunks.first?.lines.map(\.text), ["one\r", "two\r"])
        XCTAssertTrue(try file("deps.lock", in: untracked).isBinary)
        XCTAssertEqual(try file("run.sh", in: untracked).newMode, "100755")
        try git(["add", "-A", "--", ".", ":!.claude-handover.md", ":!.claude"])
        try git(["commit", "-q", "-m", "add them"])
        let committed = try snapshot()
        XCTAssertEqual(committed.files.map(\.path), untracked.files.map(\.path))
        for (before, after) in zip(untracked.files, committed.files) {
            XCTAssertFalse(after.isUntracked, after.path)
            XCTAssertEqual(before.patchHash, after.patchHash, before.path)
            XCTAssertEqual(before.hunks, after.hunks, before.path)
        }
    }

    func testFileUntrackedWithRmCachedIsListedOnce() throws {
        try write("conf.json", (1...20).map { "\"key\($0)\": \($0),\n" }.joined())
        try commitToMain("config")
        try write("Sources/Added.swift", "let added = 1\n")
        try commit("added on the branch")
        try git(["rm", "-q", "--cached", "Sources/App.swift", "conf.json", "Sources/Added.swift"])
        // Close enough to pair with conf.json as a rename.
        try write("conf.local.json", (1...20).map { "\"key\($0)\": \($0),\n" }.joined() + "\"local\": true,\n")

        let snapshot = try snapshot()

        XCTAssertEqual(snapshot.files.map(\.path), ["Sources/Added.swift", "Sources/App.swift", "conf.local.json"])
        XCTAssertEqual(try file("Sources/App.swift", in: snapshot).status, .deleted)
        XCTAssertTrue(try file("Sources/App.swift", in: snapshot).isUncommitted)
        XCTAssertEqual(try file("conf.local.json", in: snapshot).oldPath, "conf.json")
        // Not in the base: read as an untracked addition.
        let added = try file("Sources/Added.swift", in: snapshot)
        XCTAssertEqual(added.status, .added)
        XCTAssertNil(added.omission)
    }

    func testUntrackedFileOutsideASparseCheckoutIsRead() throws {
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("work")
        try git(["sparse-checkout", "set", "--cone", "Sources"])
        try write("docs/notes.md", "outside the cone\n")

        let snapshot = try snapshot()

        XCTAssertEqual(snapshot.files.map(\.path), ["Sources/App.swift", "docs/notes.md"])
        XCTAssertNil(try file("docs/notes.md", in: snapshot).omission)
    }

    func testCommittedHandoverIsShownAndAnUntrackedOneIsNot() throws {
        try write(".codex-handover.md", "plan\n")
        try commit("with a handover")
        try write(".claude-handover.md", "another plan\n")

        let snapshot = try snapshot()

        XCTAssertEqual(snapshot.files.map(\.path), [".codex-handover.md"])
        XCTAssertFalse(snapshot.hasUncommittedChanges)
    }

    func testFileThatIsNotUTF8IsReadLossilyBesideTheOthers() throws {
        try write("latin.txt", Data([0x63, 0x61, 0x66, 0xE9, 0x0A]))
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("latin")

        let snapshot = try snapshot()

        XCTAssertEqual(snapshot.files.map(\.path), ["Sources/App.swift", "latin.txt"])
        XCTAssertEqual(try file("latin.txt", in: snapshot).hunks.first?.lines.map(\.text), ["caf\u{FFFD}"])
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
        _ = try? git(["remote", "set-head", "origin", "--delete"])
        try write("Sources/App.swift", "let a = 3\nlet b = 2\nlet c = 3\n")
        try commit("unpushed")

        let snapshot = try snapshot()

        XCTAssertEqual(snapshot.base.name, "main")
        XCTAssertEqual(snapshot.base.ref, "refs/remotes/origin/main")
        XCTAssertEqual(snapshot.files.map(\.path), ["Sources/App.swift"])
        XCTAssertEqual(
            snapshot.commits.map(\.subject), ["unpushed", "work", "Merge remote-tracking branch 'origin/main' into feat/x"]
        )
        XCTAssertEqual(snapshot.commits.map(\.isMergeFromBase), [false, false, true])
        XCTAssertEqual(snapshot.upstream, .counted(ahead: 1, behind: 0))
    }

    func testOriginHeadNamesTheDefaultBranch() throws {
        try git(["push", "-q", "origin", "main:develop"])
        try git(["fetch", "-q", "origin"])
        try git(["remote", "set-head", "origin", "develop"])
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("work")

        let snapshot = try snapshot()

        XCTAssertEqual(snapshot.base.name, "develop")
        XCTAssertNil(snapshot.upstream)
    }

    // MARK: - Pull request

    private func pushAndPointAtGitHub() throws {
        try git(["push", "-q", "-u", "origin", "feat/x"])
        // gh matches the head repository on the push URL; git never pushes again.
        try git(["remote", "set-url", "--push", "origin", "https://github.com/acme/widgets.git"])
    }

    private static let pullRequestURL = "https://github.com/acme/widgets/pull/7"

    private static func pullRequest(base: String = "main", head: String) -> BranchReview.PullRequest {
        BranchReview.PullRequest(
            number: 7, title: "Add x", body: "Why: because.", url: pullRequestURL,
            baseRefName: base, headRefOid: head, isDraft: false
        )
    }

    /// Answers `gh pr list` with one pull request and `gh pr view` with its
    /// commits, recording every call.
    private final class FakeGitHub: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        let list: Data
        let commits: [String]
        let onList: @Sendable () -> Void

        init(base: String = "main", head: String, commits: [String], onList: @escaping @Sendable () -> Void = {}) {
            let object: [[String: Any]] = [[
                "number": 7, "title": "Add x", "body": "Why: because.", "url": BranchReviewSnapshotTests.pullRequestURL,
                "baseRefName": base, "headRefOid": head, "isDraft": false,
                "headRepository": ["name": "widgets"], "headRepositoryOwner": ["login": "acme"]
            ]]
            list = try! JSONSerialization.data(withJSONObject: object)
            self.commits = commits
            self.onList = onList
        }

        var calls: [[String]] { lock.withLock { recorded } }

        var cli: BranchReview.GitHubCLI {
            BranchReview.GitHubCLI { arguments, _ in
                self.lock.withLock { self.recorded.append(arguments) }
                if arguments.starts(with: ["pr", "list"]) {
                    self.onList()
                    return .init(status: 0, standardOutput: self.list, standardError: "")
                }
                let json = try! JSONSerialization.data(withJSONObject: ["commits": self.commits.map { ["oid": $0] }])
                return .init(status: 0, standardOutput: json, standardError: "")
            }
        }
    }

    private func failingGitHub(status: Int32, error: String) -> BranchReview.GitHubCLI {
        BranchReview.GitHubCLI { _, _ in .init(status: status, standardOutput: Data(), standardError: error) }
    }

    func testOpenPullRequestPicksAndFetchesItsBaseBranch() throws {
        // The pull request targets develop, which moved on GitHub after
        // the branch last fetched it.
        try git(["push", "-q", "origin", "main:develop"])
        try git(["fetch", "-q", "origin"])
        try FileManager.default.removeItem(atPath: repo + "/.git/FETCH_HEAD")
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("work")
        let head = try head()
        try pushAndPointAtGitHub()
        let other = root + "/other"
        try git(["clone", "-q", "-b", "develop", remote, other], at: root)
        try write("Sources/Develop.swift", "let d = 1\n", at: other)
        try commit("develop moves", at: other)
        try git(["tag", "v1"], at: other)
        try git(["push", "-q", "origin", "develop", "v1"], at: other)
        let developTip = try self.head(at: other)
        try git(["config", "fetch.writeCommitGraph", "true"])
        let gitHub = FakeGitHub(base: "develop", head: head, commits: [head])

        let snapshot = try snapshot(options(gitHub: gitHub.cli, fetchBase: true))

        XCTAssertEqual(snapshot.pullRequest, .found(Self.pullRequest(base: "develop", head: head)))
        XCTAssertEqual(snapshot.base.name, "develop")
        XCTAssertTrue(snapshot.usesPullRequestBase)
        XCTAssertNil(snapshot.fetchProblem)
        XCTAssertEqual(snapshot.pullRequestHead, .counted(ahead: 0, behind: 0))
        XCTAssertEqual(try git(["rev-parse", "refs/remotes/origin/develop"]).trimmingCharacters(in: .newlines), developTip)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/.git/FETCH_HEAD"))
        XCTAssertEqual(try git(["tag", "--list"]), "")
        let objectInfo = try FileManager.default.contentsOfDirectory(atPath: repo + "/.git/objects/info")
        XCTAssertFalse(objectInfo.contains { $0.hasPrefix("commit-graph") }, "\(objectInfo)")
        // GitHub refuses a list with commits: 100 × 100 commits × 100
        // authors is over its 500,000-node limit. The reflog settled it.
        XCTAssertEqual(gitHub.calls.count, 1)
        XCTAssertFalse(gitHub.calls[0].joined(separator: " ").contains("commits"), "\(gitHub.calls)")
    }

    func testPullRequestOfAReusedBranchNameIsIgnored() throws {
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("work")
        let head = try head()
        try pushAndPointAtGitHub()
        let stranger = String(repeating: "a", count: 40)

        let reused = FakeGitHub(head: stranger, commits: [stranger])
        XCTAssertEqual(try snapshot(options(gitHub: reused.cli)).pullRequest, .notFound)
        XCTAssertEqual(reused.calls.last, ["pr", "view", Self.pullRequestURL, "--json", "commits"])
        // An old pull request whose commits reached main another way: they
        // are in HEAD's history, but in the base's too.
        let initial = try git(["rev-parse", "origin/main"]).trimmingCharacters(in: .newlines)
        XCTAssertEqual(try snapshot(options(gitHub: FakeGitHub(head: stranger, commits: [initial]).cli)).pullRequest, .notFound)
        // Its head isn't local (the merge queue updated it on GitHub), but
        // one of its commits is the branch's own.
        let updated = try snapshot(options(gitHub: FakeGitHub(head: stranger, commits: [head, stranger]).cli))
        XCTAssertEqual(updated.pullRequest.pullRequest?.number, 7)
        XCTAssertEqual(updated.pullRequestHead, .notLocal)
    }

    func testPullRequestRebasedLocallyIsFoundInTheReflog() throws {
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("work")
        let pushedHead = try head()
        try pushAndPointAtGitHub()
        // Rewritten locally and not pushed yet: none of the pull request's
        // commits is in HEAD's history, but its head is in the reflog.
        try git(["commit", "-q", "--amend", "-m", "work, reworded"])
        let gitHub = FakeGitHub(head: pushedHead, commits: [pushedHead])

        let rebased = try snapshot(options(gitHub: gitHub.cli))

        XCTAssertEqual(rebased.pullRequest.pullRequest?.headRefOid, pushedHead)
        XCTAssertEqual(rebased.pullRequestHead, .counted(ahead: 1, behind: 1))
        XCTAssertEqual(gitHub.calls.count, 1, "no gh pr view: \(gitHub.calls)")
    }

    func testKnownPullRequestIsUsedWithoutAskingGitHub() throws {
        try git(["push", "-q", "origin", "main:develop"])
        try git(["fetch", "-q", "origin"])
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("work")
        let other = root + "/other"
        try git(["clone", "-q", "-b", "develop", remote, other], at: root)
        try write("Sources/Develop.swift", "let d = 1\n", at: other)
        try commit("develop moves", at: other)
        try git(["push", "-q", "origin", "develop"], at: other)
        var known = options(gitHub: failingGitHub(status: 1, error: "gh must not run"))
        known.knownPullRequest = .init(branch: "feat/x", lookup: .found(Self.pullRequest(base: "develop", head: try head())))

        let snapshot = try snapshot(known)
        XCTAssertEqual(snapshot.base.name, "develop")
        XCTAssertEqual(snapshot.pullRequest.pullRequest?.number, 7)
        XCTAssertEqual(snapshot.knownPullRequest, known.knownPullRequest)

        // Another branch's pull request is never reused.
        var stale = known
        stale.knownPullRequest = .init(branch: "other", lookup: .found(Self.pullRequest(base: "develop", head: try head())))
        let looked = try self.snapshot(stale)
        XCTAssertNil(looked.pullRequest.pullRequest)
        XCTAssertEqual(looked.base.name, "main")

        // Refresh still fetches its base.
        known.fetchBase = true
        _ = try self.snapshot(known)
        XCTAssertEqual(try git(["rev-parse", "origin/develop"]), try git(["rev-parse", "HEAD"], at: other))
    }

    func testBaseBranchThatCantBeFetchedFallsBackAndSaysSo() throws {
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("work")
        let head = try head()
        try pushAndPointAtGitHub()
        let gitHub = FakeGitHub(base: "gone", head: head, commits: [head])

        let opened = try snapshot(options(gitHub: gitHub.cli))
        XCTAssertEqual(opened.pullRequest.pullRequest?.baseRefName, "gone")
        XCTAssertEqual(opened.base.name, "main")
        XCTAssertFalse(opened.usesPullRequestBase)
        XCTAssertNil(opened.fetchProblem)

        let refreshed = try snapshot(options(gitHub: gitHub.cli, fetchBase: true))
        XCTAssertEqual(refreshed.base.name, "main")
        XCTAssertEqual(refreshed.fetchProblem?.hasPrefix("git fetch of gone failed: "), true, refreshed.fetchProblem ?? "nil")
    }

    func testMissingOrFailingGitHubCLIIsSaidAndTheBaseStillFound() throws {
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("work")
        try pushAndPointAtGitHub()

        let missing = try snapshot(options(gitHub: nil))
        XCTAssertEqual(missing.pullRequest, .unavailable("The GitHub CLI (gh) isn't installed."))
        XCTAssertEqual(missing.base.name, "main")

        let loggedOut = try snapshot(options(
            gitHub: failingGitHub(status: 4, error: "To get started with GitHub CLI, please run:  gh auth login\n")
        ))
        XCTAssertEqual(
            loggedOut.pullRequest,
            .unavailable("gh couldn't list the pull requests: To get started with GitHub CLI, please run:  gh auth login")
        )
        XCTAssertEqual(loggedOut.files.map(\.path), ["Sources/App.swift"])
    }

    func testCommitLandingWhileGitHubAnswersIsReadOnce() throws {
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("work")
        try pushAndPointAtGitHub()
        try write("Sources/New.swift", "let n = 1\n")
        let (repo, environment) = (repo!, environment!)
        // The agent commits its new file while gh is listing pull requests.
        let gitHub = FakeGitHub(head: String(repeating: "a", count: 40), commits: []) {
            _ = try? Self.git(["add", "-A"], at: repo, environment: environment)
            _ = try? Self.git(["commit", "-q", "-m", "late"], at: repo, environment: environment)
        }

        let snapshot = try snapshot(options(gitHub: gitHub.cli))

        XCTAssertEqual(snapshot.head, snapshot.commits.first?.oid)
        XCTAssertEqual(snapshot.commits.first?.subject, "late")
        XCTAssertEqual(snapshot.files.map(\.path), ["Sources/App.swift", "Sources/New.swift"])
        XCTAssertFalse(try file("Sources/New.swift", in: snapshot).isUncommitted)
    }

    func testBranchSwitchOrMergeWhileGitHubAnswersStartsOver() throws {
        try git(["checkout", "-q", "-b", "other", "main"])
        try write("Sources/Other.swift", "let o = 1\n")
        try commit("work on other")
        try git(["checkout", "-q", "feat/x"])
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("work")
        try pushAndPointAtGitHub()
        let (repo, environment) = (repo!, environment!)
        let stranger = String(repeating: "a", count: 40)

        let switching = FakeGitHub(head: stranger, commits: []) {
            _ = try? Self.git(["checkout", "-q", "other"], at: repo, environment: environment)
        }
        let switched = try snapshot(options(gitHub: switching.cli))
        XCTAssertEqual(switched.branch, "other")
        XCTAssertEqual(switched.commits.map(\.subject), ["work on other"])
        XCTAssertEqual(switched.files.map(\.path), ["Sources/Other.swift"])

        try git(["checkout", "-q", "main"])
        try write("Sources/App.swift", "let a = 3\nlet b = 2\nlet c = 3\n")
        try commit("main edit")
        try git(["checkout", "-q", "feat/x"])
        // A merge stops on a conflict with HEAD still on the branch.
        let merging = FakeGitHub(head: stranger, commits: []) {
            _ = try? Self.git(["merge", "-q", "main"], at: repo, environment: environment)
        }
        XCTAssertEqual(BranchReview.snapshot(at: repo, options: options(gitHub: merging.cli)), .paused(.merge))
    }

    /// A git that misbehaves on cue: it fails a diff run with the
    /// temporary index, or every name-status listing, or switches the
    /// worktree to `other` when `git status` runs, as its environment says.
    private func misbehavingGit() throws -> String {
        let path = root + "/git"
        try """
        #!/bin/sh
        case " $* " in
          *" status "*)
            if [ -n "$PROBE_SWITCH" ] && [ -f "$PROBE_SWITCH" ]; then
              rm -f "$PROBE_SWITCH"; /usr/bin/git checkout -q other
            fi ;;
          *" --name-status "*)
            if [ -n "$PROBE_FAIL_NAME_STATUS" ]; then echo "fatal: probe failure" >&2; exit 128; fi
            if [ -n "$PROBE_FAIL_INDEXED_DIFF" ] && [ -n "$GIT_INDEX_FILE" ]; then echo "fatal: probe" >&2; exit 128; fi ;;
        esac
        exec /usr/bin/git "$@"

        """.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    func testDiffFailingWithTheTemporaryIndexIsReadWithoutIt() throws {
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try write("draft.txt", "draft\n")
        var probing = options()
        probing.gitPath = try misbehavingGit()
        probing.environment["PROBE_FAIL_INDEXED_DIFF"] = "1"

        let snapshot = try snapshot(probing)

        XCTAssertEqual(snapshot.files.map(\.path), ["Sources/App.swift", "draft.txt"])
        XCTAssertNotNil(try file("Sources/App.swift", in: snapshot).patchHash)
        XCTAssertEqual(try file("draft.txt", in: snapshot).omission, .notRead)
    }

    func testGitFailureSaysWhy() throws {
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        var probing = options()
        probing.gitPath = try misbehavingGit()
        probing.environment["PROBE_FAIL_NAME_STATUS"] = "1"

        XCTAssertEqual(
            BranchReview.snapshot(at: repo, options: probing),
            .unavailable("git couldn't list the changes in \(repo!): fatal: probe failure")
        )
    }

    func testBranchSwitchDuringTheReadStartsOver() throws {
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("work")
        // The same commit: only the branch name tells them apart.
        try git(["branch", "other"])
        let trigger = root + "/switch"
        FileManager.default.createFile(atPath: trigger, contents: nil)
        var probing = options()
        probing.gitPath = try misbehavingGit()
        probing.environment["PROBE_SWITCH"] = trigger

        let snapshot = try snapshot(probing)

        XCTAssertFalse(FileManager.default.fileExists(atPath: trigger), "the switch never happened")
        XCTAssertEqual(snapshot.branch, "other")
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

    // MARK: - States

    func testRebaseMergeOrConflictsPauseTheReview() throws {
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("work")
        try git(["checkout", "-q", "main"])
        try write("Sources/App.swift", "let a = 3\nlet b = 2\nlet c = 3\n")
        try commit("main edit")
        try git(["checkout", "-q", "feat/x"])
        XCTAssertThrowsError(try git(["merge", "-q", "main"]))
        XCTAssertEqual(BranchReview.snapshot(at: repo, options: options()), .paused(.merge))
        try git(["merge", "--abort"])

        XCTAssertThrowsError(try git(["rebase", "-q", "main"]))
        XCTAssertEqual(BranchReview.snapshot(at: repo, options: options()), .paused(.rebase))
        try git(["rebase", "--abort"])

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

    func testLargeFileGetsAPlaceholderWithoutSendingTheOthersOnDemand() throws {
        try write("Sources/Big.swift", String(repeating: "let big = 0\n", count: 100))
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("big")
        try write("draft.txt", "draft\n")
        var limited = options()
        limited.maxFileDiffBytes = 1_000
        limited.maxInlineDiffBytes = 1_000

        let placeholder = try snapshot(limited)
        let big = try file("Sources/Big.swift", in: placeholder)
        XCTAssertEqual(big.omission, .tooLarge)
        XCTAssertEqual(big.hunks, [])
        XCTAssertGreaterThan(big.patchBytes, 1_000)
        XCTAssertNotNil(big.patchHash)
        XCTAssertEqual(big.additions, 100)
        XCTAssertNil(try file("Sources/App.swift", in: placeholder).omission)
        XCTAssertNil(try file("draft.txt", in: placeholder).omission)

        limited.maxInlineDiffBytes = 100
        let onDemand = try snapshot(limited)
        let app = try file("Sources/App.swift", in: onDemand)
        XCTAssertEqual(app.omission, .onDemand)
        XCTAssertEqual(app.hunks, [])
        XCTAssertEqual(try file("draft.txt", in: onDemand).omission, .onDemand)
        let loaded = try XCTUnwrap(BranchReview.filePatch(app, in: onDemand, options: limited))
        XCTAssertNil(loaded.omission)
        XCTAssertEqual(loaded.patchHash, app.patchHash)
        XCTAssertEqual(loaded.hunks, try file("Sources/App.swift", in: placeholder).hunks)
        let draft = try XCTUnwrap(BranchReview.filePatch(try file("draft.txt", in: onDemand), in: onDemand, options: limited))
        XCTAssertEqual(draft.hunks.first?.lines.map(\.text), ["draft"])
        XCTAssertTrue(draft.isUntracked)
    }

    func testDiffOverTheReadLimitLeavesOutItsLargestFilesFirst() throws {
        try write("logo.bin", Data([0x89, 0x50, 0x00, 0x01]))
        try write("notes.md", "notes\n")
        try commitToMain("logo")
        try write("Sources/Big.swift", String(repeating: "let big = 0\n", count: 100))
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try write("logo.bin", Data([0x89, 0x50, 0x00, 0x02]))
        try commit("big")
        // Unchanged, but its timestamp is newer than the index says.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: repo + "/README.md"
        )
        try write("notes.md", "notes, not committed\n")
        var limited = options()
        limited.maxFileDiffBytes = 1_000
        limited.maxDiffBytes = 1_000

        let trimmed = try snapshot(limited)
        XCTAssertEqual(trimmed.files.map(\.path), ["Sources/App.swift", "Sources/Big.swift", "logo.bin", "notes.md"])
        let big = try file("Sources/Big.swift", in: trimmed)
        XCTAssertEqual(big.omission, .notRead)
        XCTAssertNil(big.patchHash)
        XCTAssertEqual(big.additions, 100)
        XCTAssertNil(try file("Sources/App.swift", in: trimmed).omission)
        XCTAssertNotNil(try file("Sources/App.swift", in: trimmed).patchHash)

        limited.maxDiffBytes = 100
        let listed = try snapshot(limited)
        XCTAssertEqual(listed.files.map(\.path), ["Sources/App.swift", "Sources/Big.swift", "logo.bin", "notes.md"])
        XCTAssertTrue(listed.files.allSatisfy { $0.omission == .notRead && $0.patchHash == nil })
        XCTAssertEqual(listed.files.map(\.isBinary), [false, false, true, false])
        // Too large to read alone too, and only in the worktree: still there.
        XCTAssertEqual(
            BranchReview.filePatch(try file("notes.md", in: listed), in: listed, options: limited)?.omission, .notRead
        )
        XCTAssertEqual(try file("Sources/App.swift", in: listed).additions, 1)
        XCTAssertEqual(
            BranchReview.filePatch(try file("Sources/App.swift", in: listed), in: listed, options: options())?.patchHash,
            try file("Sources/App.swift", in: try snapshot()).patchHash
        )
    }

    func testFilePatchTakesItsPathsLiterallyAndKeepsARename() throws {
        try write("x.txt", "plain\n")
        try write("Sources/Old.swift", (1...20).map { "let line\($0) = \($0)\n" }.joined())
        try commitToMain("more files")
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

    func testUntrackedFilesPastTheReadLimitAreListedByName() throws {
        for name in ["a", "b", "c"] { try write("Pods/\(name).js", "\(name)\n") }
        try write("Sources/New.swift", "let n = 1\n")
        var limited = options()
        limited.maxUntrackedFilesRead = 2

        let snapshot = try snapshot(limited)

        XCTAssertEqual(snapshot.files.map(\.path), ["Pods/a.js", "Pods/b.js", "Pods/c.js", "Sources/New.swift"])
        // The least crowded folder first: what the agent wrote, not what it installed.
        XCTAssertEqual(snapshot.files.map(\.omission), [nil, .notRead, .notRead, nil])
        XCTAssertTrue(snapshot.files.allSatisfy(\.isUntracked))
    }

    func testDiffOverTheReadLimitLeavesOutMoreFilesAtEachTry() throws {
        for index in 1...10 {
            try write("Sources/Part\(index).swift", (1...100).map { "let part\(index)Line\($0) = \($0)\n" }.joined())
        }
        try write("Sources/App.swift", "let a = 2\nlet b = 2\nlet c = 3\n")
        try commit("parts")
        var limited = options()
        limited.maxDiffBytes = 20_000

        let snapshot = try snapshot(limited)

        let leftOut = snapshot.files.filter { $0.omission == .notRead }
        XCTAssertTrue((1..<10).contains(leftOut.count), "\(leftOut.map(\.path))")
        XCTAssertNotNil(try file("Sources/App.swift", in: snapshot).patchHash)
    }

    // MARK: - Fixtures

    /// The classic case where Myers and patience diff disagree.
    private static let frobnitz = """
    #include <stdio.h>

    // Frobs foo heartily
    int frobnitz(int foo)
    {
        int i;
        for(i = 0; i < 10; i++)
        {
            printf("Your answer is: ");
            printf("%d\\n", foo);
        }
    }

    int fact(int n)
    {
        if(n > 1)
        {
            return fact(n-1) * n;
        }
        return 1;
    }

    int main(int argc, char **argv)
    {
        frobnitz(fact(10));
    }

    """

    private static let fibonacci = """
    #include <stdio.h>

    int fib(int n)
    {
        if(n > 2)
        {
            return fib(n-1) + fib(n-2);
        }
        return 1;
    }

    // Frobs foo heartily
    int frobnitz(int foo)
    {
        int i;
        for(i = 0; i < 10; i++)
        {
            printf("%d\\n", foo);
        }
    }

    int main(int argc, char **argv)
    {
        frobnitz(fib(10));
    }

    """
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?

    var value: Bool? { lock.withLock { stored } }

    func set(_ value: Bool) { lock.withLock { stored = value } }
}
