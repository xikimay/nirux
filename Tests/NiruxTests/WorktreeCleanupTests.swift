import XCTest
@testable import Nirux

/// `WorktreeCleanup` on real, temporary git repositories, with a stub `gh`
/// answering from a JSON file. Git runs pinned against the developer's
/// global and system config (hooks, signing, excludes, templates).
final class WorktreeCleanupTests: XCTestCase {
    private var root: String!
    private var repo: String!
    private var remote: String!
    private var worktree: String!
    private var environment: [String: String]!
    private var tools: WorktreeCleanup.Tools!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-cleanup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = try XCTUnwrap(base.path.realPath)
        let home = root + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        environment = ["HOME": home, "XDG_CONFIG_HOME": home, "GIT_CONFIG_NOSYSTEM": "1"]

        remote = root + "/remote.git"
        repo = root + "/widgets"
        worktree = root + "/widgets.feat-x"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "--bare", "--template=", remote], at: root)
        try git(["init", "-q", "--template=", "-b", "main"], at: repo)
        try commit("initial", at: repo)
        try git(["remote", "add", "origin", remote], at: repo)
        try git(["push", "-q", "-u", "origin", "main"], at: repo)
        try git(["worktree", "add", "-q", "-b", "feat/x", worktree], at: repo)
        try commit("work on x", at: worktree)
        try git(["push", "-q", "-u", "origin", "feat/x"], at: worktree)
        // gh matches the head repository on the push URL; git never pushes again.
        try git(["remote", "set-url", "--push", "origin", "https://github.com/acme/widgets.git"], at: repo)

        let gh = root + "/gh"
        try """
        #!/bin/sh
        dir="$(dirname "$0")"
        printf '%s\\n' "$*" >> "$dir/gh-args"
        if [ -f "$dir/gh-error" ]; then cat "$dir/gh-error" >&2; exit 1; fi
        cat "$dir/gh-prs.json"
        """.write(toFile: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
        try setPullRequests([])
        tools = WorktreeCleanup.Tools(ghPath: gh, environment: environment, timeout: 30)
        // Never the developer's Trash.
        let trash = root + "/Trash"
        tools.trash = { url in
            try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
            let target = URL(fileURLWithPath: trash).appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(atPath: root) }
    }

    // MARK: - Helpers

    @discardableResult
    private func git(_ arguments: [String], at directory: String) throws -> String {
        let pinned = [
            "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "tag.gpgSign=false",
            "-c", "user.name=Nirux Tests", "-c", "user.email=nirux@example.test"
        ]
        let result = try XCTUnwrap(BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: pinned + arguments,
            currentDirectoryURL: URL(fileURLWithPath: directory),
            environment: environment,
            timeout: 30,
            captureStandardError: true
        ))
        let stderr = String(data: result.standardError, encoding: .utf8) ?? ""
        guard result.terminationStatus == 0 else {
            throw NSError(domain: "WorktreeCleanupTests.git", code: Int(result.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")): \(stderr)"])
        }
        return (String(data: result.standardOutput, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(_ message: String, at directory: String) throws {
        try git(["commit", "-q", "--allow-empty", "-m", message], at: directory)
    }

    private func head(at directory: String) throws -> String {
        try git(["rev-parse", "HEAD"], at: directory)
    }

    private func pullRequest(
        _ number: Int, _ state: String, head: String, owner: String = "acme"
    ) -> [String: Any] {
        [
            "number": number,
            "state": state,
            "headRefOid": head,
            "url": "https://github.com/acme/widgets/pull/\(number)",
            "headRepositoryOwner": ["login": owner],
            "headRepository": ["name": "widgets"]
        ]
    }

    private func setPullRequests(_ pullRequests: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: pullRequests)
        try data.write(to: URL(fileURLWithPath: root + "/gh-prs.json"))
    }

    private func write(_ text: String, to relative: String, in directory: String) throws {
        let path = directory + "/" + relative
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func report(_ path: String? = nil) throws -> WorktreeCleanup.Report {
        guard case .inspected(let report) = WorktreeCleanup.inspect(path: path ?? worktree, tools: tools) else {
            XCTFail("expected an inspected worktree")
            throw NSError(domain: "WorktreeCleanupTests", code: 1)
        }
        return report
    }

    private func readyPlan() throws -> WorktreeCleanup.Plan {
        let report = try report()
        XCTAssertEqual(report.problems, [])
        return try XCTUnwrap(report.plan)
    }

    private func trashed(_ relative: String) -> String {
        root + "/Trash/widgets.feat-x leftovers/" + relative
    }

    private func isListed(_ path: String) throws -> Bool {
        try git(["worktree", "list", "--porcelain"], at: repo).contains("worktree \(path)\n")
    }

    private func branchExists(_ branch: String) -> Bool {
        (try? git(["rev-parse", "--verify", "-q", "refs/heads/\(branch)"], at: repo)) != nil
    }

    // MARK: - Ready and executed

    func testSquashMergedWorktreeIsCleanedUpWithForcedBranchDelete() throws {
        let tip = try head(at: worktree)
        try setPullRequests([pullRequest(12, "MERGED", head: tip)])
        // GitHub deleted the head branch and a pruning fetch dropped its
        // remote-tracking ref: git sees feat/x merged nowhere.
        try git(["update-ref", "-d", "refs/remotes/origin/feat/x"], at: repo)
        // Handover leftovers and ignored files don't block: they go to the
        // Trash, except build output.
        try write("# handover\n", to: ".claude-handover.md", in: worktree)
        try write("{}\n", to: ".claude/settings.local.json", in: worktree)
        try write("build/\n.env\n", to: "info/exclude", in: root + "/widgets/.git")
        try write("artifact\n", to: "build/output.o", in: worktree)
        try write("TOKEN=1\n", to: ".env", in: worktree)

        let plan = try readyPlan()
        XCTAssertEqual(plan.branch, "feat/x")
        XCTAssertEqual(plan.tip, tip)
        XCTAssertEqual(plan.pullRequest.number, 12)
        XCTAssertEqual(plan.worktree.path, worktree)
        XCTAssertEqual(plan.worktree.mainCheckout, repo)
        XCTAssertEqual(plan.worktree.untrackedDisposable, [".claude-handover.md", ".claude/settings.local.json"])
        XCTAssertEqual(plan.worktree.ignoredEntries, [".env", "build/"])
        XCTAssertEqual(plan.worktree.leftovers, [".claude-handover.md", ".claude/settings.local.json", ".env"])
        XCTAssertEqual(plan.worktree.buildOutput, ["build/"])
        XCTAssertTrue(plan.worktree.folderMatchesBranch)
        XCTAssertTrue(try String(contentsOfFile: root + "/gh-args", encoding: .utf8).contains("--head=feat/x"))

        // The squash left feat/x unmerged as far as git knows: -D after -d.
        XCTAssertEqual(
            WorktreeCleanup.execute(plan, tools: tools),
            .cleaned(forcedBranchDelete: true, trashFolder: "widgets.feat-x leftovers")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
        XCTAssertEqual(try String(contentsOfFile: trashed(".claude-handover.md"), encoding: .utf8), "# handover\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed(".claude/settings.local.json")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed(".env")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed("build")))
        XCTAssertFalse(branchExists("feat/x"))
        XCTAssertFalse(try git(["worktree", "list", "--porcelain"], at: repo).contains("widgets.feat-x"))
        // The remote branch is untouched.
        XCTAssertEqual(try git(["rev-parse", "refs/heads/feat/x"], at: remote), tip)
    }

    func testBranchMergedIntoItsUpstreamIsDeletedWithoutForce() throws {
        let tip = try head(at: worktree)
        try setPullRequests([pullRequest(12, "MERGED", head: tip)])

        XCTAssertEqual(
            WorktreeCleanup.execute(try readyPlan(), tools: tools),
            .cleaned(forcedBranchDelete: false, trashFolder: nil)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
        XCTAssertFalse(branchExists("feat/x"))
        XCTAssertEqual(try git(["rev-parse", "refs/remotes/origin/feat/x"], at: repo), tip)
        XCTAssertEqual(try git(["rev-parse", "refs/heads/feat/x"], at: remote), tip)
    }

    func testTipBehindTheMergedHeadIsReady() throws {
        // The pull request got one more commit (pushed from elsewhere) that
        // this checkout never pulled: nothing local is missing from it.
        let tip = try head(at: worktree)
        try commit("pushed from elsewhere", at: worktree)
        let mergedHead = try head(at: worktree)
        try git(["reset", "-q", "--hard", tip], at: worktree)
        try setPullRequests([pullRequest(12, "MERGED", head: mergedHead)])

        let plan = try readyPlan()
        XCTAssertEqual(plan.pullRequest.headOid, mergedHead)

        // Squash-merged and pruned: -D, since the tip is in the merged head.
        try git(["update-ref", "-d", "refs/remotes/origin/feat/x"], at: repo)
        XCTAssertEqual(WorktreeCleanup.execute(plan, tools: tools), .cleaned(forcedBranchDelete: true, trashFolder: nil))
        XCTAssertFalse(branchExists("feat/x"))
    }

    func testBranchWithoutUpstreamMatchesOriginPushURL() throws {
        try git(["branch", "--unset-upstream", "feat/x"], at: worktree)
        try setPullRequests([pullRequest(12, "MERGED", head: try head(at: worktree))])
        XCTAssertEqual(try readyPlan().pullRequest.number, 12)
    }

    // MARK: - Blocked

    func testOpenPullRequestBlocks() throws {
        let tip = try head(at: worktree)
        try setPullRequests([pullRequest(12, "MERGED", head: tip), pullRequest(15, "OPEN", head: tip)])
        let report = try report()
        XCTAssertNil(report.plan)
        XCTAssertEqual(report.pullRequest?.number, 15)
        XCTAssertEqual(report.problems, ["Pull request #15 for feat/x is still open."])
    }

    func testClosedOrMissingPullRequestBlocks() throws {
        try setPullRequests([pullRequest(12, "CLOSED", head: try head(at: worktree))])
        XCTAssertEqual(try report().problems, ["Pull request #12 was closed without being merged."])

        try setPullRequests([])
        XCTAssertEqual(try report().problems, ["No pull request found for feat/x."])
    }

    func testPullRequestFromAnotherRepositoryIsIgnored() throws {
        // Same branch name, merged from someone's fork.
        try setPullRequests([pullRequest(12, "MERGED", head: try head(at: worktree), owner: "someone")])
        XCTAssertEqual(try report().problems, ["No pull request found for feat/x."])
    }

    func testLocalCommitsMissingFromTheMergedPullRequestBlock() throws {
        let mergedHead = try head(at: worktree)
        try commit("after the merge", at: worktree)
        try setPullRequests([pullRequest(12, "MERGED", head: mergedHead)])
        let report = try report()
        XCTAssertNil(report.plan)
        XCTAssertEqual(report.problems.count, 1)
        XCTAssertTrue(report.problems[0].hasPrefix("feat/x has commits that aren't in merged pull request #12"))
    }

    func testMergedHeadMissingLocallyBlocks() throws {
        try setPullRequests([pullRequest(12, "MERGED", head: String(repeating: "ab", count: 20))])
        let problems = try report().problems
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("isn't in the local repository"), problems[0])
    }

    func testUncommittedAndUntrackedChangesBlock() throws {
        try write("tracked\n", to: "tracked.txt", in: worktree)
        try git(["add", "tracked.txt"], at: worktree)
        try commit("add tracked", at: worktree)
        try setPullRequests([pullRequest(12, "MERGED", head: try head(at: worktree))])
        try write("changed\n", to: "tracked.txt", in: worktree)
        try write("notes\n", to: "notes.txt", in: worktree)
        // A handover file's name elsewhere in the tree is not a handover.
        try write("x\n", to: "docs/.claude-handover.md", in: worktree)

        let report = try report()
        XCTAssertNil(report.plan)
        XCTAssertEqual(report.worktree.changes, ["M tracked.txt", "?? docs/.claude-handover.md", "?? notes.txt"])
        XCTAssertEqual(
            report.problems,
            ["Uncommitted changes: M tracked.txt, ?? docs/.claude-handover.md, ?? notes.txt."]
        )
    }

    func testDetachedHeadBlocksWithoutAskingGitHub() throws {
        try git(["checkout", "-q", "--detach"], at: worktree)
        let report = try report()
        XCTAssertNil(report.pullRequest)
        XCTAssertEqual(report.problems, ["HEAD is detached: there is no branch to match with a pull request."])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/gh-args"))
    }

    func testLockedWorktreeBlocks() throws {
        try setPullRequests([pullRequest(12, "MERGED", head: try head(at: worktree))])
        try git(["worktree", "lock", worktree], at: repo)
        XCTAssertEqual(try report().problems, ["The worktree is locked (git worktree unlock)."])
    }

    func testGitHubCLIFailureOrAbsenceBlocks() throws {
        try "gh: To get started with GitHub CLI, please run: gh auth login\n"
            .write(toFile: root + "/gh-error", atomically: true, encoding: .utf8)
        XCTAssertEqual(
            try report().problems,
            ["gh couldn't list the pull requests of feat/x: gh: To get started with GitHub CLI, please run: gh auth login"]
        )

        tools.ghPath = nil
        XCTAssertEqual(
            try report().problems,
            ["The GitHub CLI (gh) isn't installed: the pull request can't be checked."]
        )
    }

    // MARK: - Not a linked worktree

    func testMainCheckoutPlainFolderAndMissingFolder() throws {
        guard case .unavailable(let main) = WorktreeCleanup.inspect(path: repo, tools: tools) else {
            return XCTFail("the main checkout is not a cleanup target")
        }
        XCTAssertTrue(main.contains("main checkout"), main)

        let plain = root + "/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        guard case .unavailable = WorktreeCleanup.inspect(path: plain, tools: tools) else {
            return XCTFail("a folder outside git is not a cleanup target")
        }
        XCTAssertEqual(WorktreeCleanup.inspect(path: root + "/gone", tools: tools), .folderMissing)
    }

    // MARK: - Execution re-checks

    func testExecuteRefusesWhenFilesAppearAfterTheCheck() throws {
        try setPullRequests([pullRequest(12, "MERGED", head: try head(at: worktree))])
        let plan = try readyPlan()
        try write("new work\n", to: "draft.txt", in: worktree)

        guard case .failed(let message) = WorktreeCleanup.execute(plan, tools: tools) else {
            return XCTFail("a changed worktree must not be removed")
        }
        XCTAssertTrue(message.contains("Nothing was deleted"), message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/draft.txt"))
        XCTAssertTrue(branchExists("feat/x"))
    }

    func testExecuteRefusesWhenTheBranchMovedAfterTheCheck() throws {
        try setPullRequests([pullRequest(12, "MERGED", head: try head(at: worktree))])
        let plan = try readyPlan()
        try commit("late commit", at: worktree)

        guard case .failed(let message) = WorktreeCleanup.execute(plan, tools: tools) else {
            return XCTFail("a moved branch must not be removed")
        }
        XCTAssertTrue(message.contains("feat/x moved"), message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree))
        XCTAssertTrue(branchExists("feat/x"))
    }

    func testExecuteRefusesAHandoverFileThatWasNotListed() throws {
        try setPullRequests([pullRequest(12, "MERGED", head: try head(at: worktree))])
        let plan = try readyPlan()
        try write("# late\n", to: ".codex-handover.md", in: worktree)

        guard case .failed(let message) = WorktreeCleanup.execute(plan, tools: tools) else {
            return XCTFail("only confirmed files may be deleted")
        }
        XCTAssertTrue(message.contains(".codex-handover.md"), message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/.codex-handover.md"))
    }

    func testLockedAfterTheCheckIsRefused() throws {
        try setPullRequests([pullRequest(12, "MERGED", head: try head(at: worktree))])
        let plan = try readyPlan()
        try git(["worktree", "lock", "--reason", "in use", worktree], at: repo)

        guard case .failed(let message) = WorktreeCleanup.execute(plan, tools: tools) else {
            return XCTFail("a locked worktree must not be removed")
        }
        XCTAssertTrue(message.contains("locked"), message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree))
        XCTAssertTrue(branchExists("feat/x"))
    }

    func testFailedRemovalStopsWithGitsOutputAndKeepsTheBranch() throws {
        // A tracked file git can't unlink: its folder is read-only.
        try write("# handover\n", to: ".claude-handover.md", in: worktree)
        try write("kept\n", to: "readonly/file.txt", in: worktree)
        try git(["add", "readonly/file.txt"], at: worktree)
        try commit("read-only folder", at: worktree)
        try setPullRequests([pullRequest(12, "MERGED", head: try head(at: worktree))])
        let plan = try readyPlan()
        let folder = worktree + "/readonly"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }

        guard case .failed(let message) = WorktreeCleanup.execute(plan, tools: tools) else {
            return XCTFail("git's failure must stop the cleanup")
        }
        XCTAssertTrue(message.hasPrefix("git worktree remove failed:\n"), message)
        XCTAssertTrue(message.contains("failed to delete"), message)
        // git dropped the worktree's entry but not all of its folder: said
        // so, and the handover stays in the Trash rather than in a folder
        // that is no longer a worktree.
        XCTAssertFalse(try isListed(worktree))
        XCTAssertTrue(message.contains("git no longer tracks"), message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder + "/file.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed(".claude-handover.md")))
        XCTAssertTrue(branchExists("feat/x"))
        guard case .unavailable(let reason) = WorktreeCleanup.inspect(path: worktree, tools: tools) else {
            return XCTFail("what's left is no longer a worktree")
        }
        XCTAssertTrue(reason.contains("git no longer tracks"), reason)
    }

    func testRefusedRemovalPutsTheLeftoversBack() throws {
        // git refuses a worktree holding a submodule before deleting anything.
        let library = root + "/library"
        try FileManager.default.createDirectory(atPath: library, withIntermediateDirectories: true)
        try git(["init", "-q", "--template=", "-b", "main"], at: library)
        try commit("library", at: library)
        try git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", library, "library"], at: worktree)
        try commit("add submodule", at: worktree)
        try setPullRequests([pullRequest(12, "MERGED", head: try head(at: worktree))])
        try write("# handover\n", to: ".claude-handover.md", in: worktree)
        let plan = try readyPlan()

        guard case .failed(let message) = WorktreeCleanup.execute(plan, tools: tools) else {
            return XCTFail("git's refusal must stop the cleanup")
        }
        XCTAssertTrue(message.contains("submodules"), message)
        XCTAssertTrue(message.contains("still there"), message)
        XCTAssertEqual(try String(contentsOfFile: worktree + "/.claude-handover.md", encoding: .utf8), "# handover\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/Trash/widgets.feat-x leftovers"))
        XCTAssertTrue(try isListed(worktree))
        XCTAssertTrue(branchExists("feat/x"))
    }

    func testIgnoredFilesAppearingAfterTheCheckStopIt() throws {
        try setPullRequests([pullRequest(12, "MERGED", head: try head(at: worktree))])
        try write("vendor/\n", to: "info/exclude", in: root + "/widgets/.git")
        let plan = try readyPlan()
        try write("unpushed work\n", to: "vendor/clone/notes.txt", in: worktree)

        guard case .failed(let message) = WorktreeCleanup.execute(plan, tools: tools) else {
            return XCTFail("files the confirmation didn't list must not go")
        }
        XCTAssertTrue(message.contains("vendor/"), message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/vendor/clone/notes.txt"))
    }

    // MARK: - Hidden work

    func testNestedWorktreeBlocks() throws {
        // Claude Code keeps its own worktrees under an ignored .claude/.
        try write(".claude/\n", to: "info/exclude", in: root + "/widgets/.git")
        try git(["worktree", "add", "-q", "-b", "agent", worktree + "/.claude/worktrees/agent"], at: repo)
        try setPullRequests([pullRequest(12, "MERGED", head: try head(at: worktree))])
        let report = try report()
        XCTAssertNil(report.plan)
        XCTAssertEqual(report.problems, ["Other worktrees are inside it: .claude/worktrees/agent."])
    }

    func testEditsHiddenFromStatusBlock() throws {
        try write("secret=placeholder\n", to: "config.txt", in: worktree)
        try git(["add", "config.txt"], at: worktree)
        try commit("config", at: worktree)
        try setPullRequests([pullRequest(12, "MERGED", head: try head(at: worktree))])
        try git(["update-index", "--skip-worktree", "config.txt"], at: worktree)
        try write("secret=real\n", to: "config.txt", in: worktree)

        let report = try report()
        XCTAssertNil(report.plan)
        XCTAssertEqual(report.worktree.changes, [])
        XCTAssertEqual(report.problems, ["Files git status doesn't check (skip-worktree or assume-unchanged): config.txt."])
    }

    func testFolderNamedForAnotherBranchIsFlagged() throws {
        try git(["checkout", "-q", "-b", "fix/other"], at: worktree)
        try setPullRequests([pullRequest(20, "MERGED", head: try head(at: worktree))])
        XCTAssertFalse(try readyPlan().worktree.folderMatchesBranch)
    }
}

/// The pure parts: status parsing and the pull request verdict.
final class WorktreeCleanupVerdictTests: XCTestCase {
    private let tip = String(repeating: "a", count: 40)
    private let other = String(repeating: "b", count: 40)

    private func pullRequest(_ number: Int, _ state: String, head: String) -> WorktreeCleanup.PullRequest {
        WorktreeCleanup.PullRequest(number: number, state: state, headOid: head, url: "https://github.com/acme/w/pull/\(number)")
    }

    func testStatusEntriesSkipTheOriginalPathOfARename() {
        let output = "R  new.swift\0old.swift\0 M changed.swift\0?? .claude-handover.md\0"
        XCTAssertEqual(WorktreeCleanup.statusEntries(output), [
            .init(code: "R ", path: "new.swift"),
            .init(code: " M", path: "changed.swift"),
            .init(code: "??", path: ".claude-handover.md")
        ])
    }

    func testExactHeadWinsWithoutAskingGit() {
        let verdict = WorktreeCleanup.verdict(
            branch: "b", tip: tip, candidates: [pullRequest(3, "MERGED", head: other), pullRequest(2, "MERGED", head: tip)]
        ) { _ in
            XCTFail("no ancestry check for an exact head")
            return .notContained
        }
        XCTAssertEqual(verdict.pullRequest?.number, 2)
        XCTAssertEqual(verdict.problems, [])
    }

    func testAncestorOfAnyMergedHeadIsEnough() {
        let verdict = WorktreeCleanup.verdict(
            branch: "b", tip: tip, candidates: [pullRequest(3, "MERGED", head: other), pullRequest(2, "CLOSED", head: tip)]
        ) { $0 == self.other ? .contained : .notContained }
        XCTAssertEqual(verdict.pullRequest?.number, 3)
        XCTAssertEqual(verdict.problems, [])
    }

    func testClosedPullRequestWithTheSameHeadIsNotAMerge() {
        let verdict = WorktreeCleanup.verdict(
            branch: "b", tip: tip, candidates: [pullRequest(2, "CLOSED", head: tip)]
        ) { _ in .contained }
        XCTAssertEqual(verdict.problems, ["Pull request #2 was closed without being merged."])
    }

    func testHiddenEntriesAreSkipWorktreeOrAssumeUnchanged() {
        let output = "H tracked.txt\0S config.json\0h assumed.txt\0s both.txt\0M conflict.txt\0"
        XCTAssertEqual(WorktreeCleanup.hiddenEntries(output), ["config.json", "assumed.txt", "both.txt"])
    }

    func testBuildOutputIsTheOnlyIgnoredEntryNotTrashed() {
        XCTAssertTrue(WorktreeCleanup.isRegenerable(".build/"))
        XCTAssertTrue(WorktreeCleanup.isRegenerable("app/node_modules/"))
        XCTAssertTrue(WorktreeCleanup.isRegenerable("Sources/.DS_Store"))
        XCTAssertFalse(WorktreeCleanup.isRegenerable(".env"))
        XCTAssertFalse(WorktreeCleanup.isRegenerable(".claude/"))
        XCTAssertFalse(WorktreeCleanup.isRegenerable("vendor/"))
    }
}

/// What the confirmations list and which rows the bulk list preselects.
final class WorktreeCleanupCandidateTests: XCTestCase {
    private typealias LiveAgent = WorkspaceClosePolicy.LiveAgent

    private func plan(
        folder: String = "widgets.feat-x", disposable: [String] = [], ignored: [String] = []
    ) -> WorktreeCleanup.Plan {
        let worktree = WorktreeCleanup.Worktree(
            path: "/tmp/\(folder)", mainCheckout: "/tmp/widgets", branch: "feat/x",
            tip: String(repeating: "a", count: 40), isLocked: false, changes: [], hiddenFiles: [],
            nestedWorktrees: [], untrackedDisposable: disposable, ignoredEntries: ignored
        )
        let pullRequest = WorktreeCleanup.PullRequest(
            number: 12, state: "MERGED", headOid: String(repeating: "a", count: 40), url: "https://github.com/acme/widgets/pull/12"
        )
        return WorktreeCleanup.Plan(worktree: worktree, branch: "feat/x", tip: worktree.tip ?? "", pullRequest: pullRequest)
    }

    private func candidate(
        _ plan: WorktreeCleanup.Plan?,
        agents: [LiveAgent] = [],
        foreignAgents: [String] = [],
        unsavedEditors: [String] = [],
        titles: [String] = ["feat/x"]
    ) -> WorktreeCleanupCandidate {
        WorktreeCleanupCandidate(
            path: plan?.worktree.path ?? "/tmp/widgets.feat-x",
            workspaces: titles.enumerated().map { .init(id: "ws\($0.offset)", title: $0.element) },
            agents: agents,
            foreignAgents: foreignAgents,
            unsavedEditors: unsavedEditors,
            inspection: plan.map {
                .inspected(WorktreeCleanup.Report(worktree: $0.worktree, pullRequest: $0.pullRequest, problems: []))
            } ?? .folderMissing
        )
    }

    func testReadyWithoutAgentsOrWithIdleOnesIsPreselected() {
        let ready = plan()
        XCTAssertEqual(candidate(ready).availability, .ready(ready, preselected: true))
        XCTAssertEqual(
            candidate(ready, agents: [LiveAgent(processName: "claude", status: .idle)]).availability,
            .ready(ready, preselected: true)
        )
    }

    func testBusyOrUntrustedAgentIsOfferedButNotPreselected() {
        let ready = plan()
        for status in [AgentStatus.working, .needsAttention, nil] {
            XCTAssertEqual(
                candidate(ready, agents: [LiveAgent(processName: "claude", status: status)]).availability,
                .ready(ready, preselected: false)
            )
        }
    }

    func testHubOrUnopenedWorktreeIsOfferedButNotPreselected() {
        let hub = plan(folder: "widgets.chore-audit")
        XCTAssertEqual(candidate(hub).availability, .ready(hub, preselected: false))
        XCTAssertTrue(candidate(hub).detail.contains("folder named for another branch"))
        let ready = plan()
        XCTAssertEqual(candidate(ready, titles: []).availability, .ready(ready, preselected: false))
        XCTAssertTrue(candidate(ready, titles: []).detail.contains("not open in Nirux"))
    }

    func testUnsavedEditorOrForeignAgentBlocks() {
        XCTAssertEqual(candidate(nil).availability, .closeOnly)
        XCTAssertEqual(
            candidate(nil, unsavedEditors: ["feat/x"]).availability,
            .blocked(["Unsaved editor changes in “feat/x”."])
        )
        XCTAssertEqual(
            candidate(plan(), unsavedEditors: ["feat/x"]).availability,
            .blocked(["Unsaved editor changes in “feat/x”."])
        )
        XCTAssertEqual(
            candidate(plan(), foreignAgents: ["Claude in “main”"]).availability,
            .blocked(["Running in this folder from another workspace: Claude in “main”."])
        )
    }

    func testProblemsBlock() {
        let ready = plan()
        let blocked = WorktreeCleanupCandidate(
            path: ready.worktree.path, workspaces: [], agents: [], unsavedEditors: [],
            inspection: .inspected(WorktreeCleanup.Report(
                worktree: ready.worktree, pullRequest: ready.pullRequest,
                problems: ["Uncommitted changes: M a.", "The worktree is locked (git worktree unlock)."]
            ))
        )
        XCTAssertEqual(
            blocked.availability,
            .blocked(["Uncommitted changes: M a.", "The worktree is locked (git worktree unlock)."])
        )
        XCTAssertEqual(blocked.detail, "PR #12 merged · Uncommitted changes: M a. (+1 more)")
        XCTAssertEqual(blocked.title, "widgets.feat-x · feat/x")
    }

    func testConfirmationListsExactlyWhatGoes() {
        let ignored = [".build/", ".env", "a/", "b/", "c/", "d/", "e/", "f/", "g/", "h/"]
        let ready = plan(disposable: [".claude-handover.md"], ignored: ignored)
        let lines = candidate(ready, agents: [LiveAgent(processName: "claude", status: .idle)], titles: ["x", "x tests"])
            .confirmationLines(for: ready)
        XCTAssertEqual(lines, [
            "Pull request #12 is merged. This:",
            "• deletes the folder /tmp/widgets.feat-x",
            "• deletes the local branch feat/x",
            "• moves to the Trash, in “widgets.feat-x leftovers”: .claude-handover.md, .env, a/, b/, c/, d/, e/, f/, g/, h/",
            "• deletes its build output: .build/",
            "• closes the workspaces “x”, “x tests”",
            "Claude is idle — closing the workspaces ends its session.",
            "The remote branch is not touched."
        ])
    }

    func testConfirmationWarnsAboutAFolderNamedForAnotherBranch() {
        let hub = plan(folder: "widgets.chore-audit")
        let lines = candidate(hub).confirmationLines(for: hub)
        XCTAssertTrue(lines.contains(
            "The folder isn’t named for feat/x: it may be a base reused across branches, with plans of its own."
        ))
    }

    func testSummaryRecapsEachCheckedWorktreeAndTheAgents() {
        let ready = plan(disposable: [".claude-handover.md"], ignored: [".build/"])
        let lines = WorktreeCleanupCandidate.summaryLines(for: [
            candidate(ready, agents: [LiveAgent(processName: "claude", status: .idle)]),
            candidate(nil, titles: ["old"])
        ])
        XCTAssertEqual(lines, [
            "• widgets.feat-x · feat/x, PR #12: folder and branch feat/x",
            "    to the Trash: .claude-handover.md",
            "    build output deleted: .build/",
            "• widgets.feat-x: folder already gone, workspace closes",
            "",
            "Closing their workspaces ends these agent sessions:",
            "• Claude idle in “feat/x”",
            "",
            "Leftovers go to the Trash, one folder per worktree. Remote branches are not touched."
        ])
    }

    @MainActor
    func testCleanupPathFollowsLinkedWorktreesOnly() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-cleanup-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let main = base.appendingPathComponent("repo")
        let linked = base.appendingPathComponent("repo.feat-x")
        let submodule = main.appendingPathComponent("vendor/lib")
        try FileManager.default.createDirectory(at: main.appendingPathComponent(".git/objects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: submodule, withIntermediateDirectories: true)
        try "gitdir: \(main.path)/.git/worktrees/repo.feat-x\n"
            .write(to: linked.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "gitdir: ../../.git/modules/vendor/lib\n"
            .write(to: submodule.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        XCTAssertEqual(NiruxShellView.worktreeCleanupPath(forCwd: linked.path), linked.path)
        XCTAssertEqual(NiruxShellView.worktreeCleanupPath(forCwd: linked.path + "/Sources"), linked.path)
        // A deleted subfolder of a worktree that's still there is that worktree.
        XCTAssertEqual(NiruxShellView.worktreeCleanupPath(forCwd: linked.path + "/Gone/Deeper"), linked.path)
        XCTAssertNil(NiruxShellView.worktreeCleanupPath(forCwd: main.path))
        XCTAssertNil(NiruxShellView.worktreeCleanupPath(forCwd: submodule.path))
        XCTAssertNil(NiruxShellView.worktreeCleanupPath(forCwd: base.path))
        let gone = base.appendingPathComponent("gone").path
        XCTAssertEqual(NiruxShellView.worktreeCleanupPath(forCwd: gone), gone)
        XCTAssertEqual(NiruxShellView.worktreeCleanupPath(forCwd: main.path + "/deleted"), main.path + "/deleted")
    }
}
