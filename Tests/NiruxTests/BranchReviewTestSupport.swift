import XCTest
@testable import Nirux

/// A temporary repository for `BranchReview` tests: a bare remote, and a
/// clone on `feat/x` branched from `main`, which holds a README and
/// `Sources/App.swift`. Git runs pinned against the developer's global and
/// system config (hooks, signing, excludes, templates).
class BranchReviewRepositoryTestCase: XCTestCase {
    var root: String!
    var remote: String!
    var repo: String!
    var environment: [String: String]!

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
    func git(_ arguments: [String], at directory: String? = nil) throws -> String {
        try Self.git(arguments, at: directory ?? repo, environment: environment)
    }

    /// Also for a fake gh, which runs off the test's actor.
    @discardableResult
    static func git(_ arguments: [String], at directory: String, environment: [String: String]) throws -> String {
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

    func write(_ path: String, _ text: String, at directory: String? = nil) throws {
        try write(path, Data(text.utf8), at: directory)
    }

    @nonobjc func write(_ path: String, _ data: Data, at directory: String? = nil) throws {
        let url = URL(fileURLWithPath: (directory ?? repo) + "/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func commit(_ message: String, at directory: String? = nil) throws {
        try git(["add", "-A"], at: directory)
        try git(["commit", "-q", "--allow-empty", "-m", message], at: directory)
    }

    /// Commits on the branch, then makes it main's too, so the branch
    /// starts from it.
    func commitToMain(_ message: String) throws {
        try commit(message)
        try git(["push", "-q", "origin", "HEAD:main"])
        try git(["fetch", "-q", "origin"])
    }

    func head(at directory: String? = nil) throws -> String {
        try git(["rev-parse", "HEAD"], at: directory).trimmingCharacters(in: .newlines)
    }

    func options(gitHub: BranchReview.GitHubCLI? = nil, fetchBase: Bool = false) -> BranchReview.Options {
        BranchReview.Options(gitHub: gitHub, fetchBase: fetchBase, environment: environment)
    }

    func snapshot(_ options: BranchReview.Options? = nil, at path: String? = nil) throws -> BranchReview.Snapshot {
        let outcome = BranchReview.snapshot(at: path ?? repo, options: options ?? self.options())
        guard case .snapshot(let snapshot) = outcome else {
            XCTFail("expected a snapshot, got \(outcome)")
            throw CancellationError()
        }
        return snapshot
    }

    func file(_ path: String, in snapshot: BranchReview.Snapshot) throws -> BranchReview.FileChange {
        try XCTUnwrap(snapshot.files.first { $0.path == path }, "\(path) not in \(snapshot.files.map(\.path))")
    }

    /// The snapshot of a pull request this repository merged as `merge`:
    /// its branch at the merge's second parent, main at its first. Skips
    /// when the clone lacks the commits (a shallow one does).
    func snapshotOfMergedPullRequest(_ merge: String, branch: String) throws -> BranchReview.Snapshot {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().path
        guard (try? git(["cat-file", "-e", "\(merge)^2^{commit}"], at: source)) != nil else {
            throw XCTSkip("\(merge)'s commits aren't in this clone.")
        }
        let clone = root + "/" + merge
        try git(["clone", "-q", "--shared", "--no-checkout", source, clone], at: root)
        try git(["checkout", "-q", "-b", branch, "\(merge)^2"], at: clone)
        try git(["update-ref", "refs/remotes/origin/main", "\(merge)^1"], at: clone)
        _ = try? git(["symbolic-ref", "-d", "refs/remotes/origin/HEAD"], at: clone)
        return try snapshot(at: clone)
    }
}
