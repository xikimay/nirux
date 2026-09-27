import Foundation

/// Removes a linked git worktree whose pull request is merged: its folder
/// and its local branch (Nirux then closes the workspaces open in it). It
/// never merges, pushes or fetches, and never touches the remote branch.
/// Every check is required:
/// - GitHub reports the branch's pull request MERGED. Its state decides,
///   not git ancestry, so a squash merge counts; an open one blocks.
/// - The branch tip is that pull request's head, or an ancestor of it: no
///   local commit is missing from what was merged.
/// - Nothing uncommitted or untracked, except `disposablePaths`.
/// - The worktree is not locked.
/// Runs git and gh: call it off the main thread.
enum WorktreeCleanup {
    /// Handover files and Claude Code's local settings: an untracked copy is
    /// deleted along with the worktree, and listed in the confirmation,
    /// instead of blocking it.
    static let disposablePaths: Set<String> = [
        ".claude-handover.md", ".codex-handover.md", ".claude/settings.local.json"
    ]

    struct Tools: Sendable {
        var gitPath = "/usr/bin/git"
        /// Nil when the GitHub CLI isn't installed.
        var ghPath: String?
        /// Added to the environment of every git and gh run.
        var environment: [String: String] = [:]
        var timeout: TimeInterval = 60

        /// The system git and the GitHub CLI where PRDetect looks for it.
        static var installed: Tools {
            Tools(ghPath: ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first {
                FileManager.default.isExecutableFile(atPath: $0)
            })
        }
    }

    struct PullRequest: Equatable, Sendable {
        let number: Int
        /// OPEN, CLOSED or MERGED.
        let state: String
        let headOid: String
        let url: String
    }

    /// A linked worktree as git sees it. Paths are relative to its top level.
    struct Worktree: Equatable, Sendable {
        /// Top level, resolved with realpath.
        let path: String
        /// Where git runs to remove it: the repository's main checkout.
        let mainCheckout: String
        /// Nil on a detached HEAD.
        let branch: String?
        /// Nil on a branch without commits.
        let tip: String?
        let isLocked: Bool
        /// `git status` entries that block the cleanup, e.g. "M Sources/a.swift".
        let changes: [String]
        /// `disposablePaths` present and untracked: deleted before
        /// `git worktree remove`, which would otherwise refuse.
        let untrackedDisposable: [String]
        /// `disposablePaths` present and ignored: removed with the folder.
        let ignoredDisposable: [String]
        /// Other ignored files and folders ("build/"): `git worktree remove`
        /// deletes them with the folder without asking.
        let ignoredEntries: [String]

        var repositoryName: String { (mainCheckout as NSString).lastPathComponent }
        var disposableFiles: [String] { (untrackedDisposable + ignoredDisposable).sorted() }
    }

    struct Report: Equatable, Sendable {
        let worktree: Worktree
        let pullRequest: PullRequest?
        /// Why it can't be cleaned up; empty when it can.
        let problems: [String]

        var plan: Plan? {
            guard problems.isEmpty, let branch = worktree.branch, let tip = worktree.tip,
                  let pullRequest, pullRequest.state == "MERGED"
            else { return nil }
            return Plan(worktree: worktree, branch: branch, tip: tip, pullRequest: pullRequest)
        }
    }

    /// Everything checked, ready for `execute`.
    struct Plan: Equatable, Sendable {
        let worktree: Worktree
        let branch: String
        let tip: String
        let pullRequest: PullRequest
    }

    enum Inspection: Equatable, Sendable {
        /// The folder is gone: only the workspace is left to close.
        case folderMissing
        /// Not a linked worktree (main checkout, plain folder, submodule…),
        /// or git couldn't read it.
        case unavailable(String)
        case inspected(Report)
    }

    enum Execution: Equatable, Sendable {
        /// `forcedBranchDelete`: `git branch -d` refused (squash merge) and
        /// the branch went with `-D`.
        case cleaned(forcedBranchDelete: Bool)
        /// What failed, with git's output, and what was already done.
        case failed(String)
    }

    // MARK: - Inspection

    static func inspect(path: String, tools: Tools = .installed) -> Inspection {
        let worktree: Worktree
        switch readWorktree(at: path, tools: tools) {
        case .folderMissing: return .folderMissing
        case .unavailable(let reason): return .unavailable(reason)
        case .worktree(let read): worktree = read
        }
        var problems = localProblems(worktree)
        guard let branch = worktree.branch, let tip = worktree.tip else {
            return .inspected(Report(worktree: worktree, pullRequest: nil, problems: problems))
        }
        let lookup = pullRequestLookup(branch: branch, tip: tip, worktree: worktree, tools: tools)
        problems += lookup.problems
        return .inspected(Report(worktree: worktree, pullRequest: lookup.pullRequest, problems: problems))
    }

    static func localProblems(_ worktree: Worktree) -> [String] {
        var problems: [String] = []
        if worktree.branch == nil {
            problems.append("HEAD is detached: there is no branch to match with a pull request.")
        } else if worktree.tip == nil {
            problems.append("The branch has no commits.")
        }
        if !worktree.changes.isEmpty {
            problems.append("Uncommitted changes: \(summarized(worktree.changes)).")
        }
        if worktree.isLocked {
            problems.append("The worktree is locked (git worktree unlock).")
        }
        return problems
    }

    enum WorktreeRead: Equatable {
        case folderMissing
        case unavailable(String)
        case worktree(Worktree)
    }

    static func readWorktree(at path: String, tools: Tools) -> WorktreeRead {
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        else { return .folderMissing }
        guard isDirectory.boolValue, let resolved = path.realPath else {
            return .unavailable("\(path) is not a folder.")
        }
        let paths = git(
            ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"],
            in: resolved, tools: tools
        )
        guard paths.status == 0 else {
            return .unavailable(firstLine(paths.stderr) ?? "\(path) is not in a git repository.")
        }
        let lines = paths.stdout.split(separator: "\n").map(String.init)
        guard lines.count == 3, lines[0].realPath == resolved else {
            return .unavailable("\(path) is not the top level of a git checkout.")
        }
        guard let gitDir = lines[1].realPath, let commonDir = lines[2].realPath else {
            return .unavailable("git couldn't locate the repository of \(path).")
        }
        guard gitDir != commonDir else {
            return .unavailable("\(path) is a repository's main checkout, not a linked worktree.")
        }
        guard (gitDir as NSString).deletingLastPathComponent == commonDir + "/worktrees" else {
            return .unavailable("\(path) is not a linked worktree.")
        }
        let mainCheckout = GitWorktree.mainWorktreeRoot(of: resolved)
        guard mainCheckout != resolved else {
            return .unavailable("The main checkout of \(path) can't be found (bare repository?).")
        }
        guard let listing = worktreeListing(in: mainCheckout, tools: tools),
              let entry = listing.first(where: { $0.path.realPath == resolved })
        else {
            return .unavailable("\(mainCheckout) doesn't list \(path) as one of its worktrees.")
        }

        let head = git(["symbolic-ref", "-q", "HEAD"], in: resolved, tools: tools)
        let headRef = head.stdout.trimmingCharacters(in: .newlines)
        let branch: String?
        if head.status == 0, headRef.hasPrefix("refs/heads/") {
            branch = String(headRef.dropFirst("refs/heads/".count))
        } else if head.status == 1 {
            branch = nil
        } else {
            return .unavailable(firstLine(head.stderr) ?? "git couldn't read HEAD in \(path).")
        }
        let tipRead = git(["rev-parse", "-q", "--verify", "HEAD"], in: resolved, tools: tools)
        let tip = tipRead.status == 0 ? tipRead.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil

        let files: FileState
        switch readFiles(at: resolved, tools: tools) {
        case .success(let read): files = read
        case .failure(let failure): return .unavailable(failure.message)
        }
        return .worktree(Worktree(
            path: resolved,
            mainCheckout: mainCheckout,
            branch: branch,
            tip: tip?.isEmpty == false ? tip : nil,
            isLocked: entry.isLocked,
            changes: files.changes,
            untrackedDisposable: files.untrackedDisposable,
            ignoredDisposable: files.ignoredDisposable,
            ignoredEntries: files.ignoredEntries
        ))
    }

    private struct FileState {
        var changes: [String] = []
        var untrackedDisposable: [String] = []
        var ignoredDisposable: [String] = []
        var ignoredEntries: [String] = []
    }

    private struct ReadFailure: Error {
        let message: String
    }

    /// What `git worktree remove` would find in the folder: changes and
    /// untracked files (which make it refuse) and ignored ones (which it
    /// deletes).
    private static func readFiles(at path: String, tools: Tools) -> Result<FileState, ReadFailure> {
        let status = git(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"],
            in: path, tools: tools
        )
        guard status.status == 0 else {
            return .failure(ReadFailure(message: firstLine(status.stderr) ?? "git status failed in \(path)."))
        }
        let ignored = git(
            ["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory", "--no-empty-directory"],
            in: path, tools: tools
        )
        guard ignored.status == 0 else {
            return .failure(ReadFailure(message: firstLine(ignored.stderr) ?? "git ls-files failed in \(path)."))
        }
        var files = FileState()
        for entry in statusEntries(status.stdout) {
            if entry.code == "??", disposablePaths.contains(entry.path) {
                files.untrackedDisposable.append(entry.path)
            } else {
                files.changes.append("\(entry.code.trimmingCharacters(in: .whitespaces)) \(entry.path)")
            }
        }
        files.untrackedDisposable.sort()
        let ignoredPaths = ignored.stdout.split(separator: "\0").map(String.init)
        files.ignoredDisposable = ignoredPaths.filter { disposablePaths.contains($0) }.sorted()
        files.ignoredEntries = ignoredPaths.filter { !disposablePaths.contains($0) }.sorted()
        return .success(files)
    }

    struct StatusEntry: Equatable {
        /// The two-letter XY code, e.g. " M", "??", "R ".
        let code: String
        let path: String
    }

    /// Parses `git status --porcelain=v1 -z`. A rename or copy entry is
    /// followed by its original path, which is skipped.
    static func statusEntries(_ output: String) -> [StatusEntry] {
        var entries: [StatusEntry] = []
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let field = fields.next() {
            guard field.count > 3 else { continue }
            let code = String(field.prefix(2))
            entries.append(StatusEntry(code: code, path: String(field.dropFirst(3))))
            if code.contains("R") || code.contains("C") { _ = fields.next() }
        }
        return entries
    }

    private struct ListedWorktree {
        let path: String
        let isLocked: Bool
    }

    private static func worktreeListing(in mainCheckout: String, tools: Tools) -> [ListedWorktree]? {
        let result = git(["worktree", "list", "--porcelain", "-z"], in: mainCheckout, tools: tools)
        guard result.status == 0 else { return nil }
        var listed: [ListedWorktree] = []
        var path: String?
        var isLocked = false
        // Attributes end with NUL; an empty field ends an entry.
        for field in result.stdout.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.hasPrefix("worktree ") {
                path = String(field.dropFirst("worktree ".count))
                isLocked = false
            } else if field == "locked" || field.hasPrefix("locked ") {
                isLocked = true
            } else if field.isEmpty, let current = path {
                listed.append(ListedWorktree(path: current, isLocked: isLocked))
                path = nil
            }
        }
        return listed
    }

    // MARK: - Pull request

    enum Ancestry: Equatable {
        case contained
        case notContained
        /// The commit isn't in the local repository.
        case unknownCommit
    }

    private static func pullRequestLookup(
        branch: String, tip: String, worktree: Worktree, tools: Tools
    ) -> (pullRequest: PullRequest?, problems: [String]) {
        guard let ghPath = tools.ghPath else {
            return (nil, ["The GitHub CLI (gh) isn't installed: the pull request can't be checked."])
        }
        guard let repository = headRepository(branch: branch, at: worktree.path, tools: tools) else {
            return (nil, ["\(branch) has no GitHub remote: its pull request can't be looked up."])
        }
        let fields = "number,state,headRefOid,headRepositoryOwner,headRepository,url"
        let result = run(
            executable: ghPath,
            arguments: ["pr", "list", "--head=\(branch)", "--state", "all", "--json", fields, "--limit", "1000"],
            in: worktree.path, tools: tools
        )
        guard result.status == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]]
        else {
            let reason = firstLine(result.stderr).map { ": \($0)" } ?? ""
            return (nil, ["gh couldn't list the pull requests of \(branch)\(reason)"])
        }
        let candidates = json.compactMap { pullRequest(from: $0, headRepository: repository) }
        return verdict(branch: branch, tip: tip, candidates: candidates) { headOid in
            ancestry(of: tip, in: headOid, at: worktree.path, tools: tools)
        }
    }

    /// Which pull request the branch belongs to, and why it can't be
    /// cleaned up if so. An open pull request blocks: the branch is still
    /// in use. Otherwise a merged one must contain the tip.
    static func verdict(
        branch: String,
        tip: String,
        candidates: [PullRequest],
        ancestry: (String) -> Ancestry
    ) -> (pullRequest: PullRequest?, problems: [String]) {
        let sorted = candidates.sorted { $0.number > $1.number }
        if let open = sorted.first(where: { $0.state == "OPEN" }) {
            return (open, ["Pull request #\(open.number) for \(branch) is still open."])
        }
        let merged = sorted.filter { $0.state == "MERGED" }
        guard let latest = merged.first else {
            if let closed = sorted.first {
                return (closed, ["Pull request #\(closed.number) was closed without being merged."])
            }
            return (nil, ["No pull request found for \(branch)."])
        }
        if let exact = merged.first(where: { $0.headOid == tip }) {
            return (exact, [])
        }
        var unknown: PullRequest?
        for pullRequest in merged {
            switch ancestry(pullRequest.headOid) {
            case .contained: return (pullRequest, [])
            case .unknownCommit: unknown = unknown ?? pullRequest
            case .notContained: continue
            }
        }
        if let unknown {
            return (unknown, [
                "The head of merged pull request #\(unknown.number) (\(short(unknown.headOid))) isn't in "
                    + "the local repository, so \(branch) can't be compared with it."
            ])
        }
        return (latest, [
            "\(branch) has commits that aren't in merged pull request #\(latest.number) "
                + "(local \(short(tip)), merged head \(short(latest.headOid)))."
        ])
    }

    static func pullRequest(from candidate: [String: Any], headRepository: GitHubRepository) -> PullRequest? {
        guard let number = candidate["number"] as? Int,
              let state = (candidate["state"] as? String)?.uppercased(),
              let headOid = candidate["headRefOid"] as? String, isObjectID(headOid),
              let url = candidate["url"] as? String,
              let owner = (candidate["headRepositoryOwner"] as? [String: Any])?["login"] as? String,
              let name = (candidate["headRepository"] as? [String: Any])?["name"] as? String,
              GitHubRepository(repositoryURL: url, owner: owner, name: name) == headRepository
        else { return nil }
        return PullRequest(number: number, state: state, headOid: headOid.lowercased(), url: url)
    }

    /// The repository the branch is pushed to, as PRDetect matches it; the
    /// `origin` remote for a branch pushed without an upstream.
    private static func headRepository(branch: String, at path: String, tools: Tools) -> GitHubRepository? {
        switch GitDetect.upstreamRepositoryObservation(at: path, branch: branch, gitPath: tools.gitPath) {
        case .repository(let repository):
            return repository
        case .failure:
            return nil
        case .absent:
            let origin = git(["remote", "get-url", "--push", "origin"], in: path, tools: tools)
            guard origin.status == 0 else { return nil }
            return GitHubRepository(remoteURL: origin.stdout)
        }
    }

    private static func ancestry(of tip: String, in headOid: String, at path: String, tools: Tools) -> Ancestry {
        guard isObjectID(headOid),
              git(["cat-file", "-e", "\(headOid)^{commit}"], in: path, tools: tools).status == 0
        else { return .unknownCommit }
        switch git(["merge-base", "--is-ancestor", tip, headOid], in: path, tools: tools).status {
        case 0: return .contained
        case 1: return .notContained
        default: return .unknownCommit
        }
    }

    private static func isObjectID(_ value: String) -> Bool {
        [40, 64].contains(value.count) && value.allSatisfy(\.isHexDigit)
    }

    // MARK: - Execution

    /// Deletes the worktree and its branch as `plan` describes them, after
    /// reading the worktree again: an agent may have committed or written
    /// files since the check. Stops at the first failure.
    static func execute(_ plan: Plan, tools: Tools = .installed) -> Execution {
        guard case .worktree(let current) = readWorktree(at: plan.worktree.path, tools: tools) else {
            return .failed("\(plan.worktree.path) can no longer be read. Nothing was deleted.")
        }
        var changed = localProblems(current)
        if current.branch != plan.branch || current.tip != plan.tip {
            changed.append("\(plan.branch) moved since it was checked.")
        }
        if current.mainCheckout != plan.worktree.mainCheckout {
            changed.append("Its main checkout is no longer \(plan.worktree.mainCheckout).")
        }
        let unlisted = Set(current.untrackedDisposable).subtracting(plan.worktree.disposableFiles)
        if !unlisted.isEmpty {
            changed.append("New files appeared: \(unlisted.sorted().joined(separator: ", ")).")
        }
        guard changed.isEmpty else {
            return .failed(
                (["The worktree changed since it was checked. Nothing was deleted."] + changed)
                    .joined(separator: "\n")
            )
        }

        for relative in current.untrackedDisposable {
            let fullPath = current.path + "/" + relative
            do {
                // Only a file or a symlink: a folder by that name would be
                // listed as its own files, never as a disposable path.
                let type = try FileManager.default.attributesOfItem(atPath: fullPath)[.type] as? FileAttributeType
                guard type == .typeRegular || type == .typeSymbolicLink else {
                    return .failed("\(relative) is not a file. Nothing was deleted.")
                }
                try FileManager.default.removeItem(atPath: fullPath)
            } catch {
                return .failed("Couldn't delete \(relative): \(error.localizedDescription)")
            }
        }

        // No --force: git checks once more that nothing uncommitted or
        // untracked is left, and refuses otherwise.
        let removal = git(["worktree", "remove", current.path], in: current.mainCheckout, tools: tools)
        guard removal.status == 0 else {
            return .failed("git worktree remove failed:\n\(output(of: removal))")
        }

        let softDelete = git(["branch", "-d", "--", plan.branch], in: current.mainCheckout, tools: tools)
        if softDelete.status == 0 { return .cleaned(forcedBranchDelete: false) }
        // A squash merge leaves the branch unmerged as far as git knows. The
        // pull request is MERGED and contains the tip, which must not have
        // moved since.
        let tipNow = git(["rev-parse", "-q", "--verify", "refs/heads/\(plan.branch)"], in: current.mainCheckout, tools: tools)
        guard tipNow.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == plan.tip else {
            return .failed(
                "The worktree folder was removed, but \(plan.branch) moved since it was checked, "
                    + "so the branch was kept.\n\(output(of: softDelete))"
            )
        }
        let forcedDelete = git(["branch", "-D", "--", plan.branch], in: current.mainCheckout, tools: tools)
        guard forcedDelete.status == 0 else {
            return .failed(
                "The worktree folder was removed, but deleting \(plan.branch) failed:\n\(output(of: forcedDelete))"
            )
        }
        return .cleaned(forcedBranchDelete: true)
    }

    // MARK: - Helpers

    /// "a, b, c and 4 more".
    static func summarized(_ items: [String], limit: Int = 3) -> String {
        guard items.count > limit else { return items.joined(separator: ", ") }
        return items.prefix(limit).joined(separator: ", ") + " and \(items.count - limit) more"
    }

    static func short(_ objectID: String) -> String { String(objectID.prefix(7)) }

    private static func firstLine(_ text: String) -> String? {
        text.split(separator: "\n").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    private static func output(of result: GitResult) -> String {
        let text = [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return text.isEmpty ? "exit status \(result.status)" : text
    }

    private static func git(_ arguments: [String], in directory: String, tools: Tools) -> GitResult {
        run(executable: tools.gitPath, arguments: arguments, in: directory, tools: tools)
    }

    /// Reads never take optional locks (`git status` would rewrite the
    /// index); writes take the locks they need regardless.
    private static func run(executable: String, arguments: [String], in directory: String, tools: Tools) -> GitResult {
        guard let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            currentDirectoryURL: URL(fileURLWithPath: directory),
            environment: GitDetect.readOnlyEnvironment.merging(tools.environment) { _, override in override },
            timeout: tools.timeout,
            captureStandardError: true
        ) else {
            let name = (executable as NSString).lastPathComponent
            return GitResult(status: -1, stdout: "", stderr: "\(name) could not start or timed out")
        }
        return GitResult(
            status: result.terminationStatus,
            stdout: String(data: result.standardOutput, encoding: .utf8) ?? "",
            stderr: String(data: result.standardError, encoding: .utf8) ?? ""
        )
    }
}
