import XCTest
@testable import Nirux

/// What Board Settings suggests from local checkouts (see
/// BoardConfigSuggestions). Real git repositories whose remotes are never
/// contacted.
final class BoardConfigSuggestionsTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-board-suggestions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // As git reports it (/private/var, not /var).
        root = try XCTUnwrap(base.path.realPath)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(atPath: root) }
        super.tearDown()
    }

    @discardableResult
    static func git(_ arguments: [String], at directory: String) throws -> String {
        let process = Process()
        // The git the code under test runs, so both read the same format.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false",
                             "-c", "user.name=Test", "-c", "user.email=test@example.com"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        // The developer's own config (a reftable or sha256 default) stays out.
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        ) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
        }
        return text
    }

    /// A repository whose `origin` is `remote`, with `origin/HEAD` on main
    /// unless told otherwise, and the given workflow files committed.
    static func makeRepository(
        at path: String, remote: String?, originHead: Bool = true, workflows: [String] = []
    ) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], at: path)
        let workflowsFolder = path + "/.github/workflows"
        try FileManager.default.createDirectory(atPath: workflowsFolder, withIntermediateDirectories: true)
        for file in workflows {
            try Data("on: push\n".utf8).write(to: URL(fileURLWithPath: workflowsFolder + "/" + file))
        }
        try git(["add", "-A"], at: path)
        try git(["commit", "-q", "--allow-empty", "-m", "init"], at: path)
        if let remote {
            try git(["remote", "add", "origin", remote], at: path)
            try git(["update-ref", "refs/remotes/origin/main", "HEAD"], at: path)
            if originHead {
                try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], at: path)
            }
        }
    }

    func testWorkspacesOfOneRepositorySuggestItsRemoteBranchAndWorkflows() throws {
        let repo = root + "/widgets"
        try Self.makeRepository(
            at: repo, remote: "git@github.com:Acme/Widgets.git",
            workflows: ["tests.yaml", "nightly.yml", "README.md", "-bad.yml"]
        )
        try FileManager.default.createDirectory(atPath: repo + "/.github/workflows/nested.yml", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: repo + "/.github/workflows/nested.yml/a.yml"))
        try Self.git(["add", "-A"], at: repo)
        try Self.git(["commit", "-q", "-m", "nested"], at: repo)
        try Self.git(["update-ref", "refs/remotes/origin/main", "HEAD"], at: repo)
        let worktree = root + "/widgets.feat"
        try Self.git(["worktree", "add", "-q", "-b", "feat/x", worktree], at: repo)
        let subfolder = repo + "/Sources"
        try FileManager.default.createDirectory(atPath: subfolder, withIntermediateDirectories: true)

        let suggestions = BoardConfigSuggestions.read(
            workspaceFolders: [worktree, repo, subfolder, root + "/gone", root], repository: nil
        )

        XCTAssertEqual(suggestions.repository, "Acme/Widgets", "spelled as the remote spells it")
        XCTAssertEqual(suggestions.source, .shared)
        XCTAssertEqual(suggestions.checkout, repo, "the main working tree, not the worktree")
        XCTAssertEqual(suggestions.baseBranch, "main")
        XCTAssertEqual(suggestions.workflowFiles, ["nightly.yml", "tests.yaml"])
        XCTAssertEqual(suggestions.workflowsRef, "origin/main")
    }

    func testWorkspacesInTwoRepositoriesSuggestNone() throws {
        try Self.makeRepository(at: root + "/one", remote: "https://github.com/acme/one.git", workflows: ["a.yml"])
        try Self.makeRepository(at: root + "/two", remote: "https://github.com/acme/two.git")

        let suggestions = BoardConfigSuggestions.read(workspaceFolders: [root + "/one", root + "/two"], repository: nil)

        XCTAssertNil(suggestions.repository)
        XCTAssertEqual(suggestions.source, .differing(["acme/one", "acme/two"]))
        XCTAssertNil(suggestions.checkout)
        XCTAssertNil(suggestions.baseBranch)
        XCTAssertNil(suggestions.workflowFiles)

        // With a saved repository, the checkout comes from a workspace
        // pushing to it.
        let saved = BoardConfigSuggestions.read(workspaceFolders: [root + "/one", root + "/two"], repository: "Acme/One")
        XCTAssertNil(saved.repository)
        XCTAssertEqual(saved.checkout, root + "/one")
        XCTAssertEqual(saved.workflowFiles, ["a.yml"])
    }

    func testARepositoryWithoutAGitHubRemoteBreaksTheAgreement() throws {
        try Self.makeRepository(at: root + "/github", remote: "https://github.com/acme/one.git")
        try Self.makeRepository(at: root + "/local", remote: nil)
        try Self.makeRepository(at: root + "/gitlab", remote: "git@gitlab.com:acme/one.git")

        let suggestions = BoardConfigSuggestions.read(
            workspaceFolders: [root + "/github", root + "/local", root + "/gitlab"], repository: nil
        )

        XCTAssertNil(suggestions.repository)
        XCTAssertEqual(suggestions.source, .differing(["acme/one", BoardConfigSuggestions.noGitHubRemote]))

        // The same repository, spelled differently, is one.
        try Self.makeRepository(at: root + "/upper", remote: "https://github.com/ACME/One")
        let shared = BoardConfigSuggestions.read(workspaceFolders: [root + "/github", root + "/upper"], repository: nil)
        XCTAssertEqual(shared.source, .shared)
        XCTAssertEqual(shared.repository, "acme/one")
    }

    func testNoWorkspaceInARepositorySuggestsNothing() throws {
        let plain = root + "/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)

        let suggestions = BoardConfigSuggestions.read(workspaceFolders: [plain, root + "/gone"], repository: nil)

        XCTAssertEqual(suggestions, BoardConfigSuggestions(repository: nil, source: .noRepository))
        XCTAssertEqual(BoardConfigSuggestions.read(workspaceFolders: [], repository: nil).source, .noRepository)
    }

    func testWithoutOriginHEADTheBaseBranchIsLeftToType() throws {
        let repo = root + "/repo"
        try Self.makeRepository(at: repo, remote: "https://github.com/acme/repo", originHead: false)

        let suggestions = BoardConfigSuggestions.read(workspaceFolders: [repo], repository: nil)

        XCTAssertEqual(suggestions.repository, "acme/repo")
        XCTAssertEqual(suggestions.checkout, repo)
        XCTAssertNil(suggestions.baseBranch)
        XCTAssertEqual(suggestions.workflowFiles, [])
    }

    /// A default branch that moved (master to main) leaves `origin/HEAD` on
    /// a branch that's gone: nothing is suggested.
    func testAnOriginHEADOnABranchThatsGoneIsNotSuggested() throws {
        let repo = root + "/repo"
        try Self.makeRepository(at: repo, remote: "https://github.com/acme/repo", originHead: false)
        try Self.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/master"], at: repo)

        XCTAssertNil(BoardConfigSuggestions.defaultBranch(of: "origin", at: repo))
    }

    /// `--short` would print `remotes/origin/main` here.
    func testALocalBranchNamedLikeTheRemoteOneDoesntChangeTheBaseBranch() throws {
        let repo = root + "/repo"
        try Self.makeRepository(at: repo, remote: "https://github.com/acme/repo")
        try Self.git(["branch", "origin/main"], at: repo)

        XCTAssertEqual(BoardConfigSuggestions.defaultBranch(of: "origin", at: repo), "main")
    }

    /// The main checkout may be on a branch that changed the workflows: the
    /// list comes from the base branch, as last fetched.
    func testWorkflowFilesComeFromTheBaseBranch() throws {
        let repo = root + "/repo"
        try Self.makeRepository(at: repo, remote: "https://github.com/acme/repo", workflows: ["nightly.yml"])
        try Self.git(["checkout", "-q", "-b", "feat/ci"], at: repo)
        try Data("on: push\n".utf8).write(to: URL(fileURLWithPath: repo + "/.github/workflows/new.yml"))

        let fromMain = BoardConfigSuggestions.read(workspaceFolders: [repo], repository: nil)
        XCTAssertEqual(fromMain.workflowFiles, ["nightly.yml"])
        XCTAssertEqual(fromMain.workflowsRef, "origin/main")

        // A saved base branch that the checkout never fetched: its own files.
        let unfetched = BoardConfigSuggestions.read(workspaceFolders: [repo], repository: nil, baseBranch: "release")
        XCTAssertEqual(unfetched.workflowFiles, ["new.yml", "nightly.yml"])
        XCTAssertNil(unfetched.workflowsRef)
    }

    func testAWorktreeOfABareRepositoryIsItsOwnCheckout() throws {
        let source = root + "/source"
        try Self.makeRepository(at: source, remote: nil)
        try Self.git(["clone", "-q", "--bare", source, root + "/bare.git"], at: root)
        try Self.git(["worktree", "add", "-q", root + "/wt", "main"], at: root + "/bare.git")

        let folder = try XCTUnwrap(BoardConfigSuggestions.folder(at: root + "/wt"))

        XCTAssertEqual(folder.checkout, root + "/wt")
    }

    func testRemoteURLsKeepTheirSpelling() {
        for (url, expected) in [
            ("git@github.com:Acme/Widgets.git", "Acme/Widgets"),
            ("https://github.com/Acme/Widgets", "Acme/Widgets"),
            ("ssh://git@ssh.github.com:443/Acme/Widgets.git", "Acme/Widgets"),
            ("https://github.com/Acme/Widgets/", "Acme/Widgets")
        ] {
            XCTAssertEqual(BoardConfigSuggestions.repositoryName(remoteURL: url), expected, url)
        }
        XCTAssertNil(BoardConfigSuggestions.repositoryName(remoteURL: "git@gitlab.com:acme/widgets.git"))
        XCTAssertNil(BoardConfigSuggestions.repositoryName(remoteURL: "/local/path"))
    }

    /// A branch pushed to another remote reads that remote, as PRDetect does.
    func testTheBranchsPushRemoteWins() throws {
        let repo = root + "/repo"
        try Self.makeRepository(at: repo, remote: "https://github.com/acme/repo.git")
        try Self.git(["remote", "add", "fork", "https://github.com/me/repo.git"], at: repo)
        try Self.git(["config", "branch.main.pushRemote", "fork"], at: repo)

        let folder = try XCTUnwrap(BoardConfigSuggestions.folder(at: repo))

        XCTAssertEqual(folder, BoardConfigSuggestions.Folder(repository: "me/repo", remote: "fork", checkout: repo))
    }

    func testABareMainRepositoryFallsBackToTheWorktree() {
        let listing = "worktree /r/repo.git\0bare\0\0worktree /r/feat\0HEAD abc\0branch refs/heads/feat\0\0"
        XCTAssertNil(BoardConfigSuggestions.mainWorkingTree(inListing: listing))
        XCTAssertEqual(
            BoardConfigSuggestions.mainWorkingTree(inListing: "worktree /r/repo\0HEAD abc\0branch refs/heads/main\0\0"),
            "/r/repo"
        )
    }
}
