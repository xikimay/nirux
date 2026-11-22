import CryptoKit
import Darwin
import XCTest
@testable import Nirux

final class LocalCheckpointsTests: BranchReviewRepositoryTestCase {
    private func store(_ limits: LocalCheckpoints.Limits = .init(), workspace: String = "test") throws -> LocalCheckpoints {
        let state = URL(fileURLWithPath: root + "/state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        return try LocalCheckpoints(stateDirectory: state, workspaceID: workspace, limits: limits)
    }

    private func contents(of directory: String) throws -> [String: Data] {
        let fm = FileManager.default
        var files: [String: Data] = [:]
        for path in try fm.subpathsOfDirectory(atPath: directory) {
            let url = URL(fileURLWithPath: directory + "/" + path)
            files[path] = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true ? Data() : Data(contentsOf: url)
        }
        return files
    }

    func testWorkingBytesAndDeletionsWithoutTouchingGit() throws {
        try write("README.md", "staged")
        try git(["add", "README.md"])
        try write("README.md", "working")
        try write("new\nfile", "added")
        try git(["add", "new\nfile"])
        try FileManager.default.removeItem(atPath: repo + "/Sources/App.swift")
        try write("untracked", "outside snapshot")
        let before = try contents(of: repo + "/.git")
        let stamp = try FileManager.default.attributesOfItem(atPath: repo + "/.git/index")[.modificationDate] as? Date
        let store = try store()
        let saved = try store.save(worktree: repo + "/Sources", label: "Before refactor")
        XCTAssertEqual(try contents(of: repo + "/.git"), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: repo + "/.git/index")[.modificationDate] as? Date, stamp)
        XCTAssertEqual(saved.branch, "feat/x")
        XCTAssertEqual(saved.head, try head())
        XCTAssertEqual(saved.mergeBase, try head())
        XCTAssertEqual(saved.schemaVersion, 1)
        XCTAssertEqual(saved.label, "Before refactor")
        XCTAssertFalse(saved.isIncomplete)
        XCTAssertEqual(Set(saved.files.map(\.path)), ["README.md", "Sources/App.swift", "new\nfile"])
        let file = try XCTUnwrap(saved.files.first { $0.path == "README.md" })
        XCTAssertEqual(file.status, "MM")
        let hash = SHA256.hash(data: Data("working".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(file.sha256, hash)
        XCTAssertNil(saved.files.first { $0.path == "Sources/App.swift" }?.sha256)
        let directory = store.folder.appendingPathComponent(saved.id.uuidString)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(hash)), Data("working".utf8))
        XCTAssertEqual(try store.contents(of: "README.md", in: saved.id), Data("working".utf8))
        XCTAssertNil(try store.contents(of: "Sources/App.swift", in: saved.id))
        XCTAssertEqual(try store.list().first?.manifest, saved)
        for url in [directory, store.folder, store.folder.deletingLastPathComponent()] {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o700)
        }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        }
    }

    func testUnsafeFilesAreOmittedWithReasons() throws {
        for name in ["link", "pipe", "big", ".env", "config", "utf16.txt", "normal.bin"] { try write(name, "original") }
        try commit("fixtures")
        let fm = FileManager.default
        try fm.removeItem(atPath: repo + "/link")
        try fm.createSymbolicLink(atPath: repo + "/link", withDestinationPath: repo + "/README.md")
        try fm.removeItem(atPath: repo + "/pipe")
        XCTAssertEqual(mkfifo(repo + "/pipe", 0o600), 0)
        try write("big", Data(repeating: 65, count: 256))
        try write(".env", "private")
        try write("config", "ghp_" + String(repeating: "x", count: 36))
        try write("utf16.txt", try XCTUnwrap(("ghp_" + String(repeating: "z", count: 36)).data(using: .utf16)))
        try write("normal.bin", Data([0, 255, 2]))
        let saved = try store(.init(maxSingleFileBytes: 128)).save(worktree: repo, label: nil)
        XCTAssertTrue(saved.isIncomplete)
        XCTAssertEqual(saved.files.map(\.path), ["normal.bin"])
        let omissions = Dictionary(uniqueKeysWithValues: saved.omissions.map { ($0.path, $0.reason) })
        XCTAssertEqual(omissions["link"], "Symlink, hard link, or non-regular file")
        XCTAssertEqual(omissions["pipe"], omissions["link"])
        XCTAssertEqual(omissions["big"], "Single-file size limit")
        XCTAssertEqual(omissions[".env"], "Secret path")
        XCTAssertEqual(omissions["config"], "Secret content")
        XCTAssertEqual(omissions["utf16.txt"], "Secret content")
    }

    func testBudgetsAndTimeoutReportIncomplete() throws {
        try write("README.md", Data(repeating: 65, count: 910))
        try write("Sources/App.swift", "changed")
        let count = try store(.init(maxFilesPerCapture: 1)).save(worktree: repo, label: nil)
        XCTAssertEqual(count.files.count, 1)
        XCTAssertEqual(count.omissions.map(\.reason), ["File count limit"])
        let limited = try store(.init(maxWorkspaceBytes: 1024)).save(worktree: repo, label: nil)
        XCTAssertTrue(limited.isIncomplete)
        XCTAssertTrue(limited.omissions.contains { $0.path == "README.md" && $0.reason == "Workspace byte limit" })
        let timed = try store(.init(captureTimeout: 0)).save(worktree: repo, label: nil)
        XCTAssertTrue(timed.isIncomplete)
        XCTAssertTrue(timed.timedOut)
    }

    func testEvictionByCountAndActualStoredBytes() throws {
        for (name, limits) in [
            ("count", LocalCheckpoints.Limits(maxCheckpointsPerWorkspace: 2)),
            ("bytes", .init(maxWorkspaceBytes: 6_000))
        ] {
            let store = try store(limits, workspace: name)
            try write("README.md", Data(repeating: 65, count: 2_200))
            let saved = try (1...3).map { try store.save(worktree: repo, label: String($0)) }
            let entries = try store.list()
            XCTAssertEqual(entries.map(\.id), [saved[2].id, saved[1].id])
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder.appendingPathComponent(saved[0].id.uuidString).path))
            XCTAssertLessThanOrEqual(entries.reduce(0) { $0 + $1.storedBytes }, limits.maxWorkspaceBytes)
            try store.delete(saved[2].id)
            XCTAssertEqual(try store.list().map(\.id), [saved[1].id])
        }
    }

    func testUnknownFieldsAndFutureVersionsSurviveQuotaAndDeletion() throws {
        let store = try store(.init(maxCheckpointsPerWorkspace: 2))
        let saved = try store.save(worktree: repo, label: nil)
        let url = store.folder.appendingPathComponent(saved.id.uuidString).appendingPathComponent("manifest.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["extra"] = 42
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertEqual(try store.list().first?.manifest, saved)
        let future = Data(#"{"schemaVersion":2,"files":{"different":"shape"}}"#.utf8)
        try future.write(to: url)
        XCTAssertNil(try store.list().first?.manifest)
        XCTAssertThrowsError(try store.delete(saved.id))
        _ = try store.save(worktree: repo, label: nil)
        _ = try store.save(worktree: repo, label: nil)
        XCTAssertEqual(try store.list().count, 2)
        XCTAssertEqual(try Data(contentsOf: url), future)
    }

    func testInterruptedEvictionFinishesOnNextOpen() throws {
        let store = try store()
        let older = try store.save(worktree: repo, label: "Older")
        let saved = try store.save(worktree: repo, label: "Newer")
        let staging = store.folder.appendingPathComponent(".saving")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let plan: [String: Any] = ["saved": saved.id.uuidString, "victims": [older.id.uuidString]]
        try JSONSerialization.data(withJSONObject: plan).write(to: staging.appendingPathComponent("eviction.json"))
        XCTAssertEqual(try store.list().map(\.id), [saved.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testStoreRefusesGitDirectoriesAndSymlinkedStore() throws {
        let git = URL(fileURLWithPath: repo + "/.git")
        XCTAssertThrowsError(try LocalCheckpoints(stateDirectory: git, workspaceID: "test"))
        let store = try store()
        try FileManager.default.createSymbolicLink(at: store.folder.deletingLastPathComponent(), withDestinationURL: git)
        let before = try contents(of: git.path)
        XCTAssertThrowsError(try store.save(worktree: repo, label: nil))
        XCTAssertEqual(try contents(of: git.path), before)
    }
}
