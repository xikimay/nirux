import CryptoKit
import Darwin
import XCTest
@testable import Nirux

final class LocalCheckpointsTests: BranchReviewRepositoryTestCase {
    /// Limits with a capture time no loaded runner uses up (a save runs about
    /// ten `git` calls against the 5 s default; a capture past it keeps no
    /// file), then the test's own.
    private func store(
        workspace: String = "test", _ adjust: (inout LocalCheckpoints.Limits) -> Void = { _ in }
    ) throws -> LocalCheckpoints {
        var limits = LocalCheckpoints.Limits(captureTimeout: 120)
        adjust(&limits)
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

    func testReadOnlyDiffAgainstWorkingTreeAndCheckpoint() async throws {
        let store = try store()
        try write("README.md", "first\n")
        let first = try store.save(worktree: repo, label: nil)
        try write("README.md", "second\n")
        let second = try store.save(worktree: repo, label: nil)
        try write("README.md", "third")
        let before = try contents(of: repo)
        let live = try await store.diff(from: first.id, to: nil, worktree: repo + "/Sources")
        XCTAssertNil(live.warning)
        XCTAssertTrue(live.text.contains("--- a/README.md\n+++ b/README.md\n@@ -1,1 +1,1 @@\n-first\n+third\n\\ No newline at end of file"))
        let saved = try await store.diff(from: first.id, to: second.id, worktree: repo)
        XCTAssertTrue(saved.text.contains("-first\n+second\n"))
        XCTAssertFalse(saved.text.contains("third"))
        XCTAssertEqual(try contents(of: repo), before)
    }

    func testCleanPathsUseEachRecordedHeadAndIncludeNewTrackedEdits() async throws {
        let store = try store()
        let clean = try store.save(worktree: repo, label: nil)
        XCTAssertTrue(clean.files.isEmpty)
        try write("README.md", "edited after capture\n")
        try write("new tracked", "added\n")
        try git(["add", "new tracked"])
        try write("untracked", "private")
        let live = try await store.diff(from: clean.id, to: nil, worktree: repo)
        XCTAssertTrue(live.text.contains("-widgets\n+edited after capture\n"))
        XCTAssertTrue(live.text.contains("--- /dev/null\n+++ b/new tracked"))
        XCTAssertFalse(live.text.contains("private"))
        let dirty = try store.save(worktree: repo, label: nil)
        let pair = try await store.diff(from: clean.id, to: dirty.id, worktree: repo + "/Sources")
        XCTAssertEqual(pair.text, live.text)

        try write("README.md", "committed later\n")
        try git(["add", "README.md"])
        try git(["commit", "-qm", "new baseline"])
        let later = try store.save(worktree: repo, label: nil)
        XCTAssertTrue(later.files.isEmpty)
        let committed = try await store.diff(from: clean.id, to: later.id, worktree: repo)
        XCTAssertTrue(committed.text.contains("-widgets\n+committed later\n"))
        XCTAssertTrue(committed.text.contains("--- /dev/null\n+++ b/new tracked"))
    }

    func testUnavailableBaselineIsReportedWithoutInventingAnAddition() async throws {
        let store = try store()
        var missing = LocalCheckpoints.Manifest(label: nil)
        missing.head = String(repeating: "a", count: 40)
        _ = try store.persist(.init(manifest: missing))
        try write("README.md", "changed\n")
        let diff = try await store.diff(from: missing.id, to: nil, worktree: repo)
        XCTAssertTrue(diff.text.contains("baseline unavailable"))
        XCTAssertFalse(diff.text.contains("--- /dev/null"))
    }

    func testDiffWarnsForEitherIncompleteCheckpointAndSkipsUnsafeInputs() async throws {
        let store = try store { $0.maxSingleFileBytes = 64 }
        try write("README.md", "one")
        let complete = try store.save(worktree: repo, label: nil)
        try write("Sources/App.swift", Data(repeating: 65, count: 65))
        let incomplete = try store.save(worktree: repo, label: nil)
        let toIncomplete = try await store.diff(from: complete.id, to: incomplete.id, worktree: repo)
        XCTAssertNotNil(toIncomplete.warning)
        let fromIncomplete = try await store.diff(from: incomplete.id, to: complete.id, worktree: repo)
        XCTAssertNotNil(fromIncomplete.warning)
        try write("README.md", Data([0, 255, 2]))
        let binary = try await store.diff(from: incomplete.id, to: nil, worktree: repo)
        XCTAssertNotNil(binary.warning)
        XCTAssertTrue(binary.text.contains("Binary"), binary.text)
        XCTAssertFalse(binary.text.contains("@@"))
        try write("README.md", Data(repeating: 65, count: 65))
        let large = try await store.diff(from: complete.id, to: nil, worktree: repo)
        XCTAssertTrue(large.text.localizedCaseInsensitiveContains("size limit"), large.text)
        XCTAssertFalse(large.text.contains("@@"))
    }

    func testWorkingDiffDistinguishesRecordedDeletionFromUnreadableFile() async throws {
        let store = try store()
        let fm = FileManager.default
        try fm.removeItem(atPath: repo + "/README.md")
        try write("Sources/App.swift", "saved\n")
        let saved = try store.save(worktree: repo, label: nil)
        try write("README.md", "restored\n")
        try fm.removeItem(atPath: repo + "/Sources")
        let missing = try await store.diff(from: saved.id, to: nil, worktree: repo)
        XCTAssertTrue(missing.text.contains("--- /dev/null\n+++ b/README.md"))
        XCTAssertTrue(missing.text.contains("--- a/Sources/App.swift\n+++ /dev/null"))
        try write("outside/App.swift", "external content", at: root)
        try fm.createSymbolicLink(atPath: repo + "/Sources", withDestinationPath: root + "/outside")
        let linked = try await store.diff(from: saved.id, to: nil, worktree: repo)
        XCTAssertTrue(linked.text.contains("Skipped Sources/App.swift"))
        XCTAssertFalse(linked.text.contains("external content"))
    }

    func testExportPublishesStoredBytesAndRefusesOccupiedOrProtectedFolders() throws {
        let fm = FileManager.default
        let store = try store()
        try fm.removeItem(atPath: repo + "/README.md")
        let bytes = Data([0, 255, 2])
        try write("Sources/App.swift", bytes)
        let saved = try store.save(worktree: repo, label: nil)
        func directory(_ path: String) throws -> URL {
            let url = URL(fileURLWithPath: path)
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }
        let export = try directory(root + "/export")
        let occupied = try directory(root + "/occupied")
        try Data([42]).write(to: occupied.appendingPathComponent(".hidden"))
        let nested = try directory(repo + "/empty")
        let git = try directory(repo + "/.git/empty")
        let alias = URL(fileURLWithPath: root + "/alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: export)
        let before = try contents(of: repo)
        for refused in [occupied, nested, git, alias] {
            XCTAssertThrowsError(try store.exportCopy(saved.id, to: refused, worktree: repo + "/Sources"))
        }
        XCTAssertEqual(try contents(of: occupied.path), [".hidden": Data([42])])
        try store.exportCopy(saved.id, to: export, worktree: repo)
        XCTAssertEqual(try contents(of: export.path), ["Sources": Data(), "Sources/App.swift": bytes])
        let mode = try fm.attributesOfItem(atPath: export.path + "/Sources/App.swift")[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o400)
        XCTAssertEqual(try contents(of: repo), before)
    }

    func testFailedExportRemovesOnlyTheFilesItCreated() throws {
        let store = try store()
        try write("README.md", "readme")
        try write("Sources/App.swift", "code")
        let saved = try store.save(worktree: repo, label: nil)
        let last = try XCTUnwrap(saved.files.last?.sha256)
        let fm = FileManager.default
        let payload = store.folder.appendingPathComponent(saved.id.uuidString).appendingPathComponent(last)
        try fm.removeItem(at: payload)
        try fm.createSymbolicLink(at: payload, withDestinationURL: URL(fileURLWithPath: repo + "/README.md"))
        let export = URL(fileURLWithPath: root + "/empty-export")
        try fm.createDirectory(at: export, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.exportCopy(saved.id, to: export, worktree: repo))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: export.path), [])
    }

    func testUnifiedDiffPreservesLineEndingsAndSeparatesDistantEdits() throws {
        let middle = (1...10).map { "line \($0)\n" }.joined()
        let old = Data(("first\r\n" + middle + "last").utf8)
        let new = Data(("first\n" + middle + "last\n").utf8)
        let patch = try XCTUnwrap(LocalCheckpoints.unifiedDiff(path: "note", before: old, after: new))
        XCTAssertTrue(patch.contains("@@ -1,4 +1,4 @@\n-first\r\n+first\n"))
        XCTAssertTrue(patch.contains("@@ -9,4 +9,4 @@\n"))
        XCTAssertTrue(patch.hasSuffix("-last\n\\ No newline at end of file\n+last\n"))
        let empty = try LocalCheckpoints.unifiedDiff(path: "empty", before: nil, after: Data())
        XCTAssertEqual(empty, "--- /dev/null\n+++ b/empty\n")
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
        let saved = try store { $0.maxSingleFileBytes = 128 }.save(worktree: repo, label: nil)
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
        let count = try store { $0.maxFilesPerCapture = 1 }.save(worktree: repo, label: nil)
        XCTAssertEqual(count.files.count, 1)
        XCTAssertEqual(count.omissions.map(\.reason), ["File count limit"])
        let limited = try store { $0.maxWorkspaceBytes = 1024 }.save(worktree: repo, label: nil)
        XCTAssertTrue(limited.isIncomplete)
        XCTAssertTrue(limited.omissions.contains { $0.path == "README.md" && $0.reason == "Workspace byte limit" })
        let timed = try store { $0.captureTimeout = 0 }.save(worktree: repo, label: nil)
        XCTAssertTrue(timed.isIncomplete)
        XCTAssertTrue(timed.timedOut)
    }

    func testEvictionByCountAndActualStoredBytes() throws {
        let quotas: [(String, (inout LocalCheckpoints.Limits) -> Void)] = [
            ("count", { $0.maxCheckpointsPerWorkspace = 2 }),
            ("bytes", { $0.maxWorkspaceBytes = 6_000 })
        ]
        for (name, quota) in quotas {
            let store = try store(workspace: name, quota)
            try write("README.md", Data(repeating: 65, count: 2_200))
            let saved = try (1...3).map { try store.save(worktree: repo, label: String($0)) }
            let entries = try store.list()
            XCTAssertEqual(entries.map(\.id), [saved[2].id, saved[1].id])
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder.appendingPathComponent(saved[0].id.uuidString).path))
            XCTAssertLessThanOrEqual(entries.reduce(0) { $0 + $1.storedBytes }, store.limits.maxWorkspaceBytes)
            try store.delete(saved[2].id)
            XCTAssertEqual(try store.list().map(\.id), [saved[1].id])
        }
    }

    func testUnknownFieldsAndFutureVersionsSurviveQuotaAndDeletion() throws {
        let store = try store { $0.maxCheckpointsPerWorkspace = 2 }
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
