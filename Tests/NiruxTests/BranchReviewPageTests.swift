import XCTest
@testable import Nirux

/// The data Swift sends the review page (`BranchReview.Page`), and a file's
/// diff when its row opens (`BranchReview.FileDiff`).
final class BranchReviewPageTests: XCTestCase {
    func testHeaderCountsTheBranchAndSaysWhatTheReaderMustKnow() {
        let snapshot = Self.snapshot(
            pullRequest: .found(Self.pullRequest(baseRefName: "release")),
            fetchProblem: "git fetch of release didn’t finish in 30 s.",
            upstream: .counted(ahead: 2, behind: 0), pullRequestHead: .counted(ahead: 2, behind: 1), hasUncommittedChanges: true
        )
        let header = BranchReview.page(for: snapshot, handover: nil).header
        XCTAssertEqual(header.branch, "feat/keep-awake")
        XCTAssertEqual(header.base, "main")
        XCTAssertEqual(header.pullRequest, .init(number: 57, title: "Keep the Mac awake", url: "https://github.com/o/r/pull/57", isDraft: false))
        XCTAssertEqual(header.commits, 3)
        XCTAssertEqual(header.mergesFromBase, 1)
        XCTAssertEqual(header.files, 3)
        XCTAssertEqual(header.additions, 190)
        XCTAssertEqual(header.deletions, 4)
        XCTAssertEqual(header.notes, [
            "Some changes aren’t committed: they’re in “Not committed”, not in the branch’s commits yet.",
            "2 commits not pushed.",
            "Pull request #57 has 1 commit this worktree doesn’t.",
            "Compared with main, not with the pull request’s base release: Nirux couldn’t use it.",
            "Nirux couldn’t fetch the pull request’s base: git fetch of release didn’t finish in 30 s."
        ])
    }

    func testNotesWithoutAnUpstreamOrAPullRequest() {
        let found = BranchReview.PullRequestLookup.found(Self.pullRequest(baseRefName: "main"))
        XCTAssertEqual(
            BranchReview.notes(of: Self.snapshot(pullRequest: found, pullRequestHead: .counted(ahead: 1, behind: 0))),
            ["1 local commit not in pull request #57."]
        )
        XCTAssertEqual(
            BranchReview.notes(of: Self.snapshot(pullRequest: found, pullRequestHead: .notLocal)),
            ["Pull request #57 has commits this worktree doesn’t have."]
        )
        XCTAssertEqual(
            BranchReview.notes(of: Self.snapshot(pullRequest: .unavailable("gh is logged out."))),
            ["No pull request information: gh is logged out."]
        )
    }

    /// Without a remote named origin, the base is a local branch.
    func testNotesSayWhenTheBaseIsTheLocalBranch() {
        let base = Self.snapshot(pullRequest: .found(Self.pullRequest(baseRefName: "main")))
        let local = BranchReview.Snapshot(
            root: base.root, branch: base.branch, head: base.head,
            base: .init(name: "main", ref: "refs/heads/main", mergeBase: base.base.mergeBase), pullRequest: base.pullRequest,
            fetchProblem: nil, upstream: nil, pullRequestHead: nil, hasUncommittedChanges: false, commits: base.commits,
            files: base.files, testsAgainstCode: base.testsAgainstCode
        )
        XCTAssertEqual(BranchReview.notes(of: local), [
            "Compared with the local main, not with the pull request’s base main: Nirux couldn’t use it."
        ])
    }

    /// The upstream is often the pull request's head: the same commits
    /// aren't counted twice.
    func testCommitsTheWorktreeLacksAreCountedOnce() {
        let found = BranchReview.PullRequestLookup.found(Self.pullRequest(baseRefName: "main"))
        XCTAssertEqual(
            BranchReview.notes(of: Self.snapshot(
                pullRequest: found, upstream: .counted(ahead: 0, behind: 2), pullRequestHead: .counted(ahead: 0, behind: 2)
            )),
            ["The remote branch has 2 commits this worktree doesn’t."]
        )
        XCTAssertEqual(
            BranchReview.notes(of: Self.snapshot(
                pullRequest: found, upstream: .counted(ahead: 0, behind: 0), pullRequestHead: .counted(ahead: 0, behind: 3)
            )),
            ["Pull request #57 has 3 commits this worktree doesn’t."]
        )
    }

    /// The pull request, then the handover, then the commits, oldest first,
    /// without the merges from the base.
    func testAccountsComeInTheirOrderOfPreference() {
        let snapshot = Self.snapshot(pullRequest: .found(Self.pullRequest(baseRefName: "main")))
        let handover = BranchReview.Handover(name: ".claude-handover.md", text: "# Goal", isCut: true)
        let accounts = BranchReview.page(for: snapshot, handover: handover).accounts
        XCTAssertEqual(accounts.map(\.source), [.pullRequest, .handover, .commits])
        XCTAssertEqual(accounts.map(\.label), ["Pull request #57", ".claude-handover.md (beginning)", "2 commits"])
        XCTAssertEqual(accounts[0].title, "Keep the Mac awake")
        XCTAssertEqual(accounts[0].text, "## Decisions\n- Title bar")
        XCTAssertEqual(accounts[2].commits?.map(\.subject), ["feat: keep awake", "fix: release on quit"])
        XCTAssertEqual(BranchReview.page(for: Self.snapshot(), handover: nil).accounts.map(\.source), [.commits])
    }

    func testRisksCountFilesAndListReasonsMostFrequentFirst() {
        let risks = BranchReview.page(for: Self.snapshot(), handover: nil).risks
        XCTAssertEqual(risks.map(\.kind), BranchReview.RiskKind.allCases.map(\.rawValue))
        let concurrency = risks.first { $0.kind == "concurrency" }
        XCTAssertEqual(concurrency, .init(kind: "concurrency", label: "Concurrency", files: 2, reasons: ["@MainActor", "DispatchQueue"]))
        XCTAssertEqual(risks.first { $0.kind == "security" }?.files, 0)
    }

    func testGroupsAndFilesCarryIdsAndWhyAFileHasNoHunks() {
        let page = BranchReview.page(for: Self.snapshot(), handover: nil)
        XCTAssertEqual(page.groups.map(\.key), ["uncommitted", "code", "folded.lockfile"])
        XCTAssertEqual(page.groups.map(\.title), ["Not committed", "Code", "Lockfiles"])
        XCTAssertEqual(page.groups.map(\.isFolded), [false, false, true])
        XCTAssertEqual(page.groups.map(\.files), [[2], [0], [1]])
        XCTAssertEqual(page.files.map(\.path), ["Sources/KeepAwake.swift", "Package.resolved", "Sources/New.swift"])
        XCTAssertEqual(page.files[0].risks, ["concurrency", "sideEffects"])
        XCTAssertEqual(page.files[1].omission, "onDemand")
        XCTAssertEqual(page.files[1].fold, "lockfile")
        XCTAssertTrue(page.files[2].isUntracked)
        XCTAssertEqual(page.tests.unmentioned, [.init(name: "KeepAwake.setUp", path: "Sources/KeepAwake.swift", line: 4)])
    }

    func testFileDiffShowsHunksOrWhyThereAreNone() throws {
        let snapshot = Self.snapshot()
        let diff = try XCTUnwrap(BranchReview.FileDiff(id: 0, generation: 3, file: snapshot.files[0]))
        XCTAssertNil(diff.message)
        XCTAssertEqual(diff.generation, 3)
        XCTAssertEqual(diff.hunks, [.init(oldStart: 1, newStart: 1, section: " struct KeepAwake {", lines: [
            .init(kind: "context", text: "import IOKit"),
            .init(kind: "removed", text: "let a = 1"),
            .init(kind: "added", text: "let a = 2"),
            .init(kind: "noNewlineMarker", text: "")
        ])])
        // Read when its row opens.
        XCTAssertNil(BranchReview.FileDiff(id: 1, generation: 3, file: snapshot.files[1]))

        var file = snapshot.files[0]
        file.hunks = []
        file.omission = .tooLarge
        file.patchBytes = 512_000
        XCTAssertEqual(BranchReview.FileDiff(id: 0, generation: 3, file: file)?.message, "Too large to show here (512 KB of diff).")
        file.omission = nil
        file.isBinary = true
        XCTAssertEqual(BranchReview.FileDiff(id: 0, generation: 3, read: file).message, "Binary file.")
        // Without reading it first, folded or not.
        file.omission = .onDemand
        XCTAssertEqual(BranchReview.FileDiff(id: 0, generation: 3, file: file)?.message, "Binary file.")
        file.omission = nil
        file.isBinary = false
        file.status = .renamed
        XCTAssertEqual(BranchReview.FileDiff(id: 0, generation: 3, read: file).message, "Renamed, no line changed.")
        file.oldMode = "100644"
        file.newMode = "100755"
        XCTAssertEqual(BranchReview.FileDiff(id: 0, generation: 3, read: file).message, "Mode changed from 100644 to 100755.")
        // Read again, still too large for git's whole diff.
        file.omission = .notRead
        XCTAssertEqual(BranchReview.FileDiff(id: 0, generation: 3, read: file).message, "Nirux couldn’t read this file’s diff: too large, or git took too long.")
        XCTAssertEqual(BranchReview.FileDiff(id: 0, generation: 3, read: file).path, "Sources/KeepAwake.swift")
    }

    func testHandoverIsTheClaudeOneFirstAndCutPastItsLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-handover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(BranchReview.Handover.read(in: root.path))
        try "codex".write(to: root.appendingPathComponent(".codex-handover.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(BranchReview.Handover.read(in: root.path), .init(name: ".codex-handover.md", text: "codex", isCut: false))
        let long = String(repeating: "a", count: BranchReview.Handover.maxBytes + 10)
        try long.write(to: root.appendingPathComponent(".claude-handover.md"), atomically: true, encoding: .utf8)
        let handover = try XCTUnwrap(BranchReview.Handover.read(in: root.path))
        XCTAssertEqual(handover.name, ".claude-handover.md")
        XCTAssertEqual(handover.text.utf8.count, BranchReview.Handover.maxBytes)
        XCTAssertTrue(handover.isCut)
    }

    /// A branch can commit a link in the handover's place, to a key or any
    /// file on the Mac, or a FIFO that would block the read forever.
    func testHandoverIsReadOnlyFromARegularFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-handover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = root.appendingPathComponent("secret")
        try "key".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent(".claude-handover.md").path, withDestinationPath: secret.path
        )
        XCTAssertEqual(mkfifo(root.appendingPathComponent(".codex-handover.md").path, 0o600), 0)
        XCTAssertNil(BranchReview.Handover.read(in: root.path))
    }

    // MARK: - Fixtures

    /// A column's reader that answers `snapshot()`, off the main thread as
    /// git does.
    static let reader: BranchReviewController.Reader = { _, _, _ in
        XCTAssertFalse(Thread.isMainThread)
        return (.snapshot(snapshot()), nil)
    }

    static func pullRequest(baseRefName: String) -> BranchReview.PullRequest {
        BranchReview.PullRequest(
            number: 57, title: "Keep the Mac awake", body: "## Decisions\n- Title bar",
            url: "https://github.com/o/r/pull/57", baseRefName: baseRefName, headRefOid: String(repeating: "b", count: 40),
            isDraft: false
        )
    }

    /// `feat/keep-awake` against main: a Swift file with two signals, a
    /// lockfile read on demand, an untracked file; two commits and a merge
    /// from main.
    static func snapshot(
        pullRequest: BranchReview.PullRequestLookup = .notFound, fetchProblem: String? = nil,
        upstream: BranchReview.HeadComparison? = nil, pullRequestHead: BranchReview.HeadComparison? = nil,
        hasUncommittedChanges: Bool = false
    ) -> BranchReview.Snapshot {
        var swift = BranchReview.FileChange(path: "Sources/KeepAwake.swift", status: .modified)
        swift.additions = 180
        swift.deletions = 4
        swift.patchHash = "h0"
        swift.hunks = [BranchReview.Hunk(
            oldStart: 1, oldCount: 2, newStart: 1, newCount: 2, section: " struct KeepAwake {",
            lines: [
                .init(kind: .context, text: "import IOKit"), .init(kind: .removed, text: "let a = 1"),
                .init(kind: .added, text: "let a = 2"), .init(kind: .noNewlineMarker, text: "")
            ]
        )]
        swift.signals = [
            .init(kind: .concurrency, reasons: ["@MainActor", "DispatchQueue"], hunks: [0], byPath: false),
            .init(kind: .sideEffects, reasons: ["IOKit"], hunks: [0], byPath: false)
        ]
        var lockfile = BranchReview.FileChange(path: "Package.resolved", status: .modified)
        lockfile.additions = 4
        lockfile.omission = .onDemand
        lockfile.fold = .lockfile
        lockfile.patchHash = "h1"
        lockfile.signals = [.init(kind: .dependencies, reasons: ["Package.resolved"], hunks: [], byPath: true)]
        var untracked = BranchReview.FileChange(path: "Sources/New.swift", status: .added)
        untracked.additions = 6
        untracked.isUntracked = true
        untracked.isUncommitted = true
        untracked.patchHash = "h2"
        untracked.signals = [.init(kind: .concurrency, reasons: ["@MainActor"], hunks: [0], byPath: false)]
        var tests = BranchReview.TestsAgainstCode()
        tests.testLines = 40
        tests.codeLines = 186
        tests.declared = 3
        tests.unmentioned = [.init(path: "Sources/KeepAwake.swift", symbol: .init(name: "setUp", line: 4, kind: .function, container: "KeepAwake"))]
        return BranchReview.Snapshot(
            root: "/repo", branch: "feat/keep-awake", head: String(repeating: "a", count: 40),
            base: .init(name: "main", ref: "refs/remotes/origin/main", mergeBase: String(repeating: "c", count: 40)),
            pullRequest: pullRequest, fetchProblem: fetchProblem, upstream: upstream, pullRequestHead: pullRequestHead,
            hasUncommittedChanges: hasUncommittedChanges,
            commits: [
                .init(oid: "3", parents: ["2"], subject: "fix: release on quit", body: "", isMergeFromBase: false),
                .init(oid: "m", parents: ["1", "x"], subject: "Merge main", body: "", isMergeFromBase: true),
                .init(oid: "1", parents: ["0"], subject: "feat: keep awake", body: "Why.", isMergeFromBase: false)
            ],
            files: [swift, lockfile, untracked], testsAgainstCode: tests
        )
    }
}
