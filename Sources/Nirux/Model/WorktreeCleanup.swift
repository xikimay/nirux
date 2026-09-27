import Foundation

/// Removes a linked git worktree whose pull request is merged: its folder
/// and its local branch (Nirux then closes the workspaces open in it). It
/// never merges, pushes or fetches, and never touches the remote branch.
/// Every check is required:
/// - GitHub reports the branch's pull request MERGED. Its state decides,
///   not git ancestry, so a squash merge counts; an open one blocks.
/// - The branch tip is that pull request's head, or an ancestor of it: no
///   local commit is missing from what was merged.
/// - Nothing uncommitted or untracked, except `disposablePaths`; no edit
///   hidden from `git status` (skip-worktree, assume-unchanged).
/// - No other worktree inside it, and it is not locked.
/// Ignored files are not a reason to refuse, but `git worktree remove`
/// deletes them: everything but build output goes to the Trash first.
/// Runs git and gh: call it off the main thread.
enum WorktreeCleanup {
    /// Handover files and Claude Code's local settings: an untracked copy
    /// goes to the Trash with the worktree's other leftovers instead of
    /// blocking it.
    static let disposablePaths: Set<String> = [
        ".claude-handover.md", ".codex-handover.md", ".claude/settings.local.json"
    ]

    /// Ignored folders (or files) a build or an install recreates. They are
    /// deleted with the worktree; any other ignored entry goes to the Trash.
    static let regenerableNames: Set<String> = [
        ".build", ".swiftpm", "DerivedData", "build", "dist", "node_modules", "target", ".next",
        ".gradle", "Pods", "__pycache__", ".pytest_cache", ".mypy_cache", ".venv", "coverage", ".DS_Store"
    ]

    struct Tools: Sendable {
        var gitPath = "/usr/bin/git"
        /// Nil when the GitHub CLI isn't installed.
        var ghPath: String?
        /// Added to the environment of every git and gh run.
        var environment: [String: String] = [:]
        /// For reads and gh: past it, the check fails.
        var timeout: TimeInterval = 60
        /// For the git commands that delete: killing `git worktree remove`
        /// midway would leave half a worktree, so only a wedged git hits it.
        var writeTimeout: TimeInterval = 3600
        /// Moves a folder to the Trash and returns where it went.
        var trash: @Sendable (URL) throws -> URL = { url in
            var trashed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            return (trashed as URL?) ?? url
        }

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
        /// Where git runs to remove it: the main checkout, or the bare
        /// repository, listed first by `git worktree list`.
        let mainCheckout: String
        /// Nil on a detached HEAD.
        let branch: String?
        /// Nil on a branch without commits.
        let tip: String?
        let isLocked: Bool
        /// `git status` entries that block the cleanup, e.g. "M Sources/a.swift".
        let changes: [String]
        /// Tracked files on disk that `git status` doesn't look at
        /// (skip-worktree, assume-unchanged): their edits would go unseen.
        let hiddenFiles: [String]
        /// Other worktrees of the repository inside this one (Claude Code
        /// makes its own under `.claude/worktrees`): the folder would take
        /// them along.
        let nestedWorktrees: [String]
        /// `disposablePaths` present and untracked.
        let untrackedDisposable: [String]
        /// Ignored files and folders, as `git ls-files --directory` groups them.
        let ignoredEntries: [String]
        /// The ignored entries that are build output: a `regenerableNames`
        /// name an ignore pattern matches itself. (git also groups a folder
        /// whose files are all ignored, e.g. `target/` holding `*.secret`.)
        let buildOutput: [String]

        var repositoryName: String {
            let name = (mainCheckout as NSString).lastPathComponent
            return name.hasSuffix(".git") ? String(name.dropLast(4)) : name
        }

        var folderName: String { (path as NSString).lastPathComponent }

        /// What goes to the Trash before the folder is removed; the build
        /// output is deleted with it.
        var leftovers: [String] {
            let deleted = Set(buildOutput)
            return (untrackedDisposable + ignoredEntries.filter { !deleted.contains($0) }).sorted()
        }

        /// `buildOutput` with one name's copies folded: ".DS_Store ×12".
        var buildOutputSummary: [String] {
            let names = buildOutput.map { entry -> String in
                let trimmed = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
                return (trimmed as NSString).lastPathComponent + (entry.hasSuffix("/") ? "/" : "")
            }
            var counts: [String: Int] = [:]
            for name in names { counts[name, default: 0] += 1 }
            var seen: Set<String> = []
            return zip(buildOutput, names).compactMap { entry, name in
                guard let count = counts[name], count > 1 else { return entry }
                return seen.insert(name).inserted ? "\(name) ×\(count)" : nil
            }
        }

        /// Whether the folder is the one `GitWorktree.create` makes for
        /// `branch`. One named for another branch may be a base that moves
        /// from branch to branch, with a plan of its own in its handover.
        var folderMatchesBranch: Bool {
            guard let branch else { return false }
            return folderName == "\(repositoryName).\(branch.replacingOccurrences(of: "/", with: "-"))"
        }
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

    static func isRegenerable(_ entry: String) -> Bool {
        let trimmed = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
        return regenerableNames.contains((trimmed as NSString).lastPathComponent)
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
        if !worktree.hiddenFiles.isEmpty {
            problems.append(
                "Files git status doesn't check (skip-worktree or assume-unchanged): \(summarized(worktree.hiddenFiles))."
            )
        }
        if !worktree.nestedWorktrees.isEmpty {
            problems.append("Other worktrees are inside it: \(summarized(worktree.nestedWorktrees)).")
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
        let location: Location
        switch locate(resolved, tools: tools) {
        case .success(let found): location = found
        case .failure(let failure): return .unavailable(failure.message)
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
        let tip = tipRead.status == 0 ? tipRead.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""

        let files: FileState
        switch readFiles(at: resolved, tools: tools) {
        case .success(let read): files = read
        case .failure(let failure): return .unavailable(failure.message)
        }
        return .worktree(Worktree(
            path: resolved,
            mainCheckout: location.mainCheckout,
            branch: branch,
            tip: tip.isEmpty ? nil : tip,
            isLocked: location.isLocked,
            changes: files.changes,
            hiddenFiles: files.hiddenFiles,
            nestedWorktrees: location.nestedWorktrees,
            untrackedDisposable: files.untrackedDisposable,
            ignoredEntries: files.ignoredEntries,
            buildOutput: files.buildOutput
        ))
    }

    struct ReadFailure: Error {
        let message: String
    }

    private struct Location {
        let mainCheckout: String
        let isLocked: Bool
        let nestedWorktrees: [String]
    }

    /// Where the worktree sits in its repository, from git's own listing:
    /// the checkout git runs in to remove it, and worktrees nested inside.
    private static func locate(_ resolved: String, tools: Tools) -> Result<Location, ReadFailure> {
        let paths = git(
            ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"],
            in: resolved, tools: tools
        )
        guard paths.status == 0 else {
            if isDanglingWorktreeLink(resolved) {
                return .failure(ReadFailure(message:
                    "git no longer tracks \(resolved): its worktree entry is gone. Delete the folder yourself."))
            }
            return .failure(ReadFailure(message: firstLine(paths.stderr) ?? "\(resolved) is not in a git repository."))
        }
        let lines = paths.stdout.split(separator: "\n").map(String.init)
        guard lines.count == 3, lines[0].realPath == resolved else {
            return .failure(ReadFailure(message: "\(resolved) is not the top level of a git checkout."))
        }
        guard let gitDir = lines[1].realPath, let commonDir = lines[2].realPath else {
            return .failure(ReadFailure(message: "git couldn't locate the repository of \(resolved)."))
        }
        guard gitDir != commonDir else {
            return .failure(ReadFailure(message: "\(resolved) is a repository's main checkout, not a linked worktree."))
        }
        guard (gitDir as NSString).deletingLastPathComponent == commonDir + "/worktrees" else {
            return .failure(ReadFailure(message: "\(resolved) is not a linked worktree."))
        }
        // git lists the main checkout (or the bare repository) first. The
        // listing must also hold this very folder: a crafted `.git` file can
        // point any folder at another repository's worktree entry.
        guard let listing = worktreeListing(in: resolved, tools: tools),
              let main = listing.first?.path.realPath,
              main != resolved,
              let entry = listing.first(where: { $0.path.realPath == resolved })
        else {
            return .failure(ReadFailure(message: "git doesn't list \(resolved) as a worktree of its repository."))
        }
        let mainDirs = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: main, tools: tools)
        guard mainDirs.status == 0,
              mainDirs.stdout.trimmingCharacters(in: .newlines).realPath == commonDir
        else {
            return .failure(ReadFailure(message: "The main checkout of \(resolved), \(main), can't be used."))
        }
        let nested = listing.compactMap { other -> String? in
            guard let otherPath = other.path.realPath, otherPath.hasPrefix(resolved + "/") else { return nil }
            return String(otherPath.dropFirst(resolved.count + 1))
        }
        return .success(Location(mainCheckout: main, isLocked: entry.isLocked, nestedWorktrees: nested.sorted()))
    }

    /// A `.git` file whose `gitdir:` points at a folder that's gone: what
    /// a `git worktree remove` that failed midway leaves behind.
    private static func isDanglingWorktreeLink(_ path: String) -> Bool {
        guard let contents = try? String(contentsOfFile: path + "/.git", encoding: .utf8),
              contents.hasPrefix("gitdir: ")
        else { return false }
        let target = contents.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let absolute = target.hasPrefix("/") ? target : path + "/" + target
        return !FileManager.default.fileExists(atPath: absolute)
    }

    private struct FileState {
        var changes: [String] = []
        var hiddenFiles: [String] = []
        var untrackedDisposable: [String] = []
        var ignoredEntries: [String] = []
        var buildOutput: [String] = []
    }

    /// What `git worktree remove` would find in the folder: changes and
    /// untracked files (which make it refuse), ignored ones (which it
    /// deletes), and edits hidden from both.
    private static func readFiles(at path: String, tools: Tools) -> Result<FileState, ReadFailure> {
        let status = git(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"],
            in: path, tools: tools
        )
        let ignored = git(
            ["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory", "--no-empty-directory"],
            in: path, tools: tools
        )
        let flagged = git(["ls-files", "-z", "-v"], in: path, tools: tools)
        for result in [status, ignored, flagged] where result.status != 0 {
            return .failure(ReadFailure(message: firstLine(result.stderr) ?? "git couldn't list the files of \(path)."))
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
        files.ignoredEntries = ignored.stdout.split(separator: "\0").map(String.init).sorted()
        let named = files.ignoredEntries.filter(isRegenerable)
        if !named.isEmpty {
            // Exit 1: none of them is ignored by a pattern of its own. (-z
            // needs --stdin; a path with a newline just goes to the Trash.)
            let matched = git(["check-ignore", "--"] + named, in: path, tools: tools)
            guard [0, 1].contains(matched.status) else {
                return .failure(ReadFailure(message: firstLine(matched.stderr) ?? "git check-ignore failed in \(path)."))
            }
            let patterned = Set(matched.stdout.split(separator: "\n").map(String.init))
            files.buildOutput = named.filter { patterned.contains($0) }
        }
        files.hiddenFiles = hiddenEntries(flagged.stdout).filter { relative in
            var info = stat()
            return lstat(path + "/" + relative, &info) == 0
        }
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

    /// Paths `git ls-files -v -z` tags skip-worktree ("S") or
    /// assume-unchanged (a lowercase tag).
    static func hiddenEntries(_ output: String) -> [String] {
        output.split(separator: "\0").compactMap { field in
            guard field.count > 2, let tag = field.first, tag.isLowercase || tag == "S" else { return nil }
            return String(field.dropFirst(2))
        }
    }

    struct ListedWorktree: Equatable {
        let path: String
        let isLocked: Bool
    }

    /// `git worktree list --porcelain -z`, run in `directory`.
    static func worktreeListing(in directory: String, tools: Tools) -> [ListedWorktree]? {
        let result = git(["worktree", "list", "--porcelain", "-z"], in: directory, tools: tools)
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

    // MARK: - Helpers

    /// "a, b, c and 4 more".
    static func summarized(_ items: [String], limit: Int = 3) -> String {
        guard items.count > limit else { return items.joined(separator: ", ") }
        return items.prefix(limit).joined(separator: ", ") + " and \(items.count - limit) more"
    }

    static func short(_ objectID: String) -> String { String(objectID.prefix(7)) }

    static func firstLine(_ text: String) -> String? {
        text.split(separator: "\n").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    static func output(of result: GitResult) -> String {
        let text = [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return text.isEmpty ? "exit status \(result.status)" : text
    }

    static func git(
        _ arguments: [String], in directory: String, tools: Tools, timeout: TimeInterval? = nil
    ) -> GitResult {
        run(executable: tools.gitPath, arguments: arguments, in: directory, tools: tools, timeout: timeout)
    }

    /// Reads never take optional locks (`git status` would rewrite the
    /// index); writes take the locks they need regardless. Output that
    /// isn't UTF-8 fails the run rather than reading as empty.
    static func run(
        executable: String, arguments: [String], in directory: String, tools: Tools, timeout: TimeInterval? = nil
    ) -> GitResult {
        let name = (executable as NSString).lastPathComponent
        guard let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            currentDirectoryURL: URL(fileURLWithPath: directory),
            environment: GitDetect.readOnlyEnvironment.merging(tools.environment) { _, override in override },
            timeout: timeout ?? tools.timeout,
            captureStandardError: true
        ) else {
            return GitResult(status: -1, stdout: "", stderr: "\(name) could not start or timed out")
        }
        let stderr = String(data: result.standardError, encoding: .utf8) ?? ""
        guard let stdout = String(data: result.standardOutput, encoding: .utf8) else {
            return GitResult(status: -1, stdout: "", stderr: "\(name) printed output that isn't UTF-8\n\(stderr)")
        }
        return GitResult(status: result.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
