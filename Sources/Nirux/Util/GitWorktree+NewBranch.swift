import Darwin
import Foundation

// MARK: - New branches (New Task…, see NewTask)

extension GitWorktree {
    /// Why `branch` can't be a new task's branch, or nil:
    /// - it exists, locally or on a remote, in any case: the filesystem
    ///   ignores case, so a new `Feat/X` would shadow a packed `feat/x`;
    /// - a worktree has it checked out (one not committed to yet has no ref);
    /// - it starts with a remote's name: `origin/main` would hide the
    ///   remote branch from every `git log origin/main`.
    /// `refs/remotes/*/<branch>` matches one remote level only, unlike
    /// `git branch -r --list`, so `origin/alice/feat/x` doesn't take `feat/x`.
    static func newBranchProblem(_ branch: String, repoRoot: String) -> String? {
        let lowered = branch.lowercased()
        let remotes = gitRun(["remote"], cwd: repoRoot).split(separator: "\n").map(String.init)
        if let remote = remotes.first(where: { lowered.hasPrefix($0.lowercased() + "/") }) {
            return "\(branch) starts with the name of the remote \(remote): choose another branch name"
        }
        let existing = gitRun(
            ["for-each-ref", "--ignore-case", "--format=%(refname:short)", "refs/heads/\(branch)", "refs/remotes/*/\(branch)"],
            cwd: repoRoot
        ).split(separator: "\n").first
        if let existing {
            return "\(existing) already exists: choose another branch name"
        }
        if let entry = list(repoRoot: repoRoot).first(where: { $0.branch?.lowercased() == lowered }) {
            return "\(entry.branch ?? branch) is already checked out in \(entry.path): choose another branch name"
        }
        return nil
    }

    /// The commit a new task's branch starts from, or why it can't start.
    static func newBranchStart(
        _ branch: String, from startPoint: String, repoRoot: String
    ) -> (commit: String?, problem: String?) {
        if let problem = newBranchProblem(branch, repoRoot: repoRoot) {
            return (nil, problem)
        }
        guard let commit = commitID(of: startPoint, in: repoRoot) else {
            return (nil, "\(startPoint) isn’t a commit of \(repoRoot)")
        }
        return (commit, nil)
    }

    /// The commit `revision` names in `repoRoot`, or nil.
    static func commitID(of revision: String, in repoRoot: String) -> String? {
        let result = gitRunFull(["rev-parse", "--verify", "--quiet", "\(revision)^{commit}"], cwd: repoRoot, timeout: 10)
        let commit = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && !commit.isEmpty ? commit : nil
    }

    /// `git worktree add -b` creates the branch before checking it out, and
    /// keeps what it made when a later step fails: the worktree too after a
    /// failing post-checkout hook (returned, with git's error), the branch
    /// alone after a failed checkout (a required filter, say). That branch
    /// is deleted while it still sits on `startCommit` and no worktree has
    /// it, so the same name can be retried.
    static func afterFailedNewBranch(
        _ branch: String, at path: String, from startCommit: String, repoRoot: String, error: String
    ) -> (path: String?, error: String?) {
        let worktrees = list(repoRoot: repoRoot)
        if let resolved = path.realPath,
           worktrees.contains(where: { $0.branch == branch && $0.path.realPath == resolved }) {
            return (resolved, error)
        }
        if !worktrees.contains(where: { $0.branch == branch }),
           commitID(of: "refs/heads/\(branch)", in: repoRoot) == startCommit {
            _ = gitRunFull(["branch", "-D", "--", branch], cwd: repoRoot, timeout: 10)
        }
        return (nil, error)
    }

    /// Fetches `remote`'s `branch` into `refs/remotes/<remote>/<branch>`:
    /// no tags, no submodules, never a credentials prompt, and given up after
    /// `timeout`. Nil once fetched, else why not.
    static func fetch(branch: String, from remote: String = "origin", repoRoot: String, timeout: TimeInterval = 10) -> String? {
        let result = gitRunFull(
            [
                "fetch", "--quiet", "--no-tags", "--no-recurse-submodules", remote,
                "+refs/heads/\(branch):refs/remotes/\(remote)/\(branch)"
            ],
            cwd: repoRoot,
            timeout: timeout,
            environment: ["GIT_TERMINAL_PROMPT": "0"]
        )
        guard result.status != 0 else { return nil }
        let lines = result.stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // git's first "fatal:" says why; the advice around it doesn't.
        return lines.first { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") } ?? lines.last ?? "git fetch failed"
    }

    /// Adds the `patterns` it lacks to the repository's `info/exclude`, in
    /// the common git dir, so every worktree of the repository ignores them.
    /// Only the same line counts: `/x` covers `x` at the top alone. Never
    /// writes through a link or into a file that isn't a regular one. False
    /// when it couldn't.
    @discardableResult
    static func ensureExcluded(_ patterns: [String], repoRoot: String) -> Bool {
        guard let commonDir = absoluteGitPaths(["--git-common-dir"], in: repoRoot)?.first else { return false }
        let info = URL(fileURLWithPath: commonDir).appendingPathComponent("info", isDirectory: true)
        let file = info.appendingPathComponent("exclude")
        let existing: String
        switch BoardConfigStore.read(file, maxBytes: SpaceBrief.maxFileBytes) {
        case .missing: existing = ""
        case .data(let data):
            guard let text = String(bytes: data, encoding: .utf8) else { return false }
            existing = text
        case .notARegularFile, .tooLarge, .unreadableBytes: return false
        }
        let lines = Set(existing.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        let missing = patterns.filter { !lines.contains($0) }
        guard !missing.isEmpty else { return true }
        var text = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        text += "# Nirux handovers\n" + missing.joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return false }
        do {
            try handle.write(contentsOf: Data(text.utf8))
            return true
        } catch {
            return false
        }
    }
}
