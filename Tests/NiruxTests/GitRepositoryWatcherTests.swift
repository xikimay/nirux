import CoreServices
import XCTest
@testable import Nirux

/// Repository layout resolution, FSEvents path classification, the live
/// watcher, and the read-only guarantee of the background git reads.
@MainActor
final class GitRepositoryWatcherTests: XCTestCase {
    // MARK: - GitRepositoryLayout

    func testLayoutResolvesPlainCheckoutAndLinkedWorktree() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main", isDirectory: true)
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try initializeRepository(at: main)
        try git(["worktree", "add", "-q", "-b", "feature/x", linked.path], at: main)

        let mainPath = GitRepositoryLayout.canonicalPath(main.path)
        let mainLayout = GitRepositoryLayout.resolve(worktreeRoot: main.path)
        XCTAssertEqual(mainLayout.worktreeRoot, mainPath)
        XCTAssertEqual(mainLayout.gitDirectory, mainPath + "/.git")
        XCTAssertEqual(mainLayout.commonDirectory, mainPath + "/.git")
        XCTAssertEqual(mainLayout.watchedPaths, [mainPath])

        let linkedLayout = GitRepositoryLayout.resolve(worktreeRoot: linked.path)
        XCTAssertEqual(linkedLayout.worktreeRoot, GitRepositoryLayout.canonicalPath(linked.path))
        XCTAssertEqual(linkedLayout.gitDirectory, mainPath + "/.git/worktrees/linked")
        XCTAssertEqual(linkedLayout.commonDirectory, mainPath + "/.git")
        // The private git dir lives inside the common one: one watch covers both.
        XCTAssertEqual(linkedLayout.watchedPaths, [linkedLayout.worktreeRoot, mainPath + "/.git"])

        let plain = GitRepositoryLayout.resolve(worktreeRoot: root.path)
        XCTAssertNil(plain.gitDirectory)
        XCTAssertNil(plain.commonDirectory)
    }

    func testCanonicalPathKeepsPrivatePrefixReportedByFSEvents() {
        XCTAssertEqual(GitRepositoryLayout.canonicalPath("/tmp"), "/private/tmp")
    }

    func testPlainCheckoutClassification() {
        let layout = GitRepositoryLayout(
            worktreeRoot: "/repo",
            gitDirectory: "/repo/.git",
            commonDirectory: "/repo/.git"
        )
        func classify(_ path: String, branch: String? = "main") -> GitRepositoryChange? {
            layout.classify(path, branch: branch)
        }
        XCTAssertEqual(classify("/repo/Sources/app.swift"), .worktree)
        XCTAssertEqual(classify("/repo/.git/HEAD"), .metadata)
        XCTAssertEqual(classify("/repo/.git/index"), .metadata)
        XCTAssertEqual(classify("/repo/.git/refs/heads/main"), .metadata)
        XCTAssertEqual(classify("/repo/.git/packed-refs"), .metadata)
        XCTAssertEqual(classify("/repo/.git/config"), .metadata)
        XCTAssertNil(classify("/repo/.git/refs/heads/other"))
        XCTAssertEqual(classify("/repo/.git/refs/remotes/origin/main"), .remoteBranch)
        XCTAssertNil(classify("/repo/.git/refs/tags/v1"))
        XCTAssertNil(classify("/repo/.git/objects/ab/cdef"))
        XCTAssertNil(classify("/repo/.git/logs/HEAD"))
        XCTAssertNil(classify("/repo/.git/index.lock"))
        XCTAssertNil(classify("/repo/.git/FETCH_HEAD"))
        XCTAssertNil(classify("/repo/.git/worktrees/other/HEAD"))
        XCTAssertEqual(classify("/repo/.git/refs/heads/feature/x", branch: "feature/x"), .metadata)
        XCTAssertEqual(classify("/repo/.git/refs/heads/anything", branch: nil), .metadata)
        XCTAssertEqual(classify("/repository-sibling/file"), .worktree)
    }

    func testLinkedWorktreeIgnoresTheMainCheckoutsHeadAndIndex() {
        let layout = GitRepositoryLayout(
            worktreeRoot: "/wt",
            gitDirectory: "/repo/.git/worktrees/wt",
            commonDirectory: "/repo/.git"
        )
        func classify(_ path: String) -> GitRepositoryChange? {
            layout.classify(path, branch: "feature/x")
        }
        XCTAssertEqual(classify("/wt/README.md"), .worktree)
        XCTAssertEqual(classify("/repo/.git/worktrees/wt/HEAD"), .metadata)
        XCTAssertEqual(classify("/repo/.git/worktrees/wt/index"), .metadata)
        XCTAssertEqual(classify("/repo/.git/refs/heads/feature/x"), .metadata)
        XCTAssertEqual(classify("/repo/.git/config"), .metadata)
        XCTAssertNil(classify("/repo/.git/HEAD"))
        XCTAssertNil(classify("/repo/.git/index"))
        XCTAssertNil(classify("/repo/.git/worktrees/other/index"))
        XCTAssertNil(classify("/repo/.git/refs/heads/main"))
    }

    func testReadCookiesAndRemoteBranchClassification() {
        let layout = GitRepositoryLayout(
            worktreeRoot: "/repo",
            gitDirectory: "/repo/.git",
            commonDirectory: "/repo/.git"
        )
        // Written by git's own reads when fsmonitor/watchman is enabled:
        // following them would make every read schedule the next one.
        XCTAssertNil(layout.classify("/repo/.git/fsmonitor--daemon/cookies/123-1", branch: "main"))
        XCTAssertNil(layout.classify("/repo/.git/fsmonitor--daemon.ipc", branch: "main"))
        XCTAssertNil(layout.classify("/repo/.watchman-cookie-host-1-2", branch: "main"))
        XCTAssertNil(layout.classify("/repo/.git/.watchman-cookie-host-1-2", branch: "main"))

        XCTAssertEqual(layout.classify("/repo/.git/refs/remotes/origin/feature/x", branch: "feature/x"), .remoteBranch)
        XCTAssertNil(layout.classify("/repo/.git/refs/remotes/origin/other", branch: "feature/x"))
        XCTAssertNil(layout.classify("/repo/.git/refs/remotes/origin/HEAD", branch: nil))
        // `symbolic-ref --short` disambiguates a branch shadowed by a tag.
        XCTAssertEqual(layout.classify("/repo/.git/refs/heads/main", branch: "heads/main"), .metadata)
        XCTAssertEqual(layout.classify("/repo/.git/refs/heads/heads/x", branch: "heads/x"), .metadata)
        XCTAssertNil(GitRepositoryWatcher.change(
            for: "",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone),
            layout: layout,
            branch: nil
        ))
    }

    func testDroppedOrRescannedEventsCountAsMetadata() {
        let layout = GitRepositoryLayout(worktreeRoot: "/repo", gitDirectory: nil, commonDirectory: nil)
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        XCTAssertEqual(
            GitRepositoryWatcher.change(for: "/repo/.git/objects/x", flags: rescan, layout: layout, branch: nil),
            .metadata
        )
    }

    func testLayoutFollowsSymlinkedGitDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = root.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try initializeRepository(at: checkout)
        let moved = root.appendingPathComponent("moved.git", isDirectory: true)
        try FileManager.default.moveItem(at: checkout.appendingPathComponent(".git"), to: moved)
        try FileManager.default.createSymbolicLink(
            at: checkout.appendingPathComponent(".git"),
            withDestinationURL: moved
        )

        let layout = GitRepositoryLayout.resolve(worktreeRoot: checkout.path)
        let movedPath = GitRepositoryLayout.canonicalPath(moved.path)
        XCTAssertEqual(layout.gitDirectory, movedPath)
        XCTAssertEqual(layout.watchedPaths, [GitRepositoryLayout.canonicalPath(checkout.path), movedPath])
    }

    // MARK: - GitRepositoryWatcher

    func testWatcherReportsWorktreeAndMetadataChanges() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try initializeRepository(at: root)
        let layout = GitRepositoryLayout.resolve(worktreeRoot: root.path)
        var changes: [GitRepositoryChange] = []
        let watcher = try XCTUnwrap(GitRepositoryWatcher(layout: layout, branch: nil, latency: 0.05) {
            changes.append($0)
        })
        defer { watcher.stop() }
        // Let the stream settle so setup writes are not reported.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        changes.removeAll()

        try "edited\n".write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil { changes.contains(.worktree) }, "no worktree event: \(changes)")

        try git(["add", "tracked.txt"], at: root)
        XCTAssertTrue(waitUntil { changes.contains(.metadata) }, "no metadata event: \(changes)")
    }

    // MARK: - Read-only git reads

    func testObservationDoesNotRewriteTheIndex() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try initializeRepository(at: root)
        let index = root.appendingPathComponent(".git/index").path
        // Stale stat data: plain `git status` would refresh and rewrite the index.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: root.appendingPathComponent("tracked.txt").path
        )
        let before = try inode(of: index)

        guard case .observed(let context) = GitDetect.observe(at: root.path) else {
            return XCTFail("expected an observed repository")
        }
        XCTAssertFalse(context.identity.isDirty)
        XCTAssertEqual(try inode(of: index), before, "GitDetect rewrote .git/index")
        XCTAssertEqual(PRDetect.diffStats(cwd: root.path), .observed(context: context, stats: nil))
        XCTAssertEqual(try inode(of: index), before, "git diff --shortstat rewrote .git/index")

        try git(["status", "--porcelain"], at: root)
        XCTAssertNotEqual(try inode(of: index), before, "precondition: plain git status refreshes the index")
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func initializeRepository(at directory: URL) throws {
        try git(["init", "-q"], at: directory)
        try "context\n".write(
            to: directory.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "tracked.txt"], at: directory)
        try git([
            "-c", "user.name=Nirux Tests",
            "-c", "user.email=nirux@example.test",
            "commit", "-qm", "initial"
        ], at: directory)
    }

    private func git(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitRefreshTests.Git", code: Int(process.terminationStatus))
        }
    }

    private func inode(of path: String) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}
