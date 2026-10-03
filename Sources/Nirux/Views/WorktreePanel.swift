import AppKit

struct GitResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Raycast-style floating panel for creating a git worktree + workspace
@MainActor
final class WorktreePanel {
    /// (branch, worktreePath, repoRoot, branch read back from the checkout,
    /// which names the Claude session; see `SessionName`).
    var onCreated: ((String, String, String, String?) -> Void)?

    private var panel: NSPanel?
    private var field: NSTextField?
    private var statusLabel: NSTextField?
    private var repoRoot: String?

    private static let size = NSSize(width: 520, height: 80)

    func show(relativeTo window: NSWindow, repoRoot: String) {
        self.repoRoot = repoRoot
        if panel == nil { createPanel() }
        guard let panel, let field, let statusLabel else { return }

        field.stringValue = ""
        statusLabel.stringValue = "Enter branch name — existing or new"
        RaycastPanel.show(panel, relativeTo: window, size: Self.size)
        panel.makeFirstResponder(field)
    }

    private func createPanel() {
        // Taller panel: push the icon + field to the top half, reserve the
        // bottom 14pt row for the status label.
        let built = RaycastPanel.build(
            RaycastPanel.Config(
                width: Self.size.width, height: Self.size.height,
                icon: "arrow.triangle.branch",
                placeholder: "Branch name (e.g. feat/my-feature)",
                iconY: Self.size.height - 36,
                fieldY: Self.size.height - 38
            ),
            fieldTarget: self, fieldAction: #selector(fieldAction)
        )

        // Status label lives below the field in the reserved 14pt row.
        let status = NSTextField(labelWithString: "Enter branch name — existing or new")
        status.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        status.textColor = NSColor.white.withAlphaComponent(0.4)
        status.frame = NSRect(x: 42, y: 8, width: Self.size.width - 54, height: 14)
        built.container.addSubview(status)

        panel = built.panel
        field = built.field
        statusLabel = status
    }

    @objc private func fieldAction() {
        guard let branch = field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !branch.isEmpty,
              let repoRoot
        else { return }

        statusLabel?.stringValue = "Creating worktree..."
        statusLabel?.textColor = .niruxAccent

        DispatchQueue.global(qos: .userInitiated).async {
            let (path, error) = GitWorktree.create(branch: branch, repoRoot: repoRoot)
            let checkedOutBranch = path.flatMap(GitWorktree.currentBranch(at:))
            DispatchQueue.main.async { [weak self] in
                if let path {
                    self?.panel?.orderOut(nil)
                    self?.onCreated?(branch, path, repoRoot, checkedOutBranch)
                } else {
                    self?.statusLabel?.stringValue = error ?? "git worktree add failed"
                    self?.statusLabel?.textColor = NSColor.systemRed.withAlphaComponent(0.9)
                }
            }
        }
    }
}

// MARK: - Git Worktree Operations

enum GitWorktree {
    /// Create a worktree for the given branch. Auto-detects existing vs new branch.
    /// Returns (path, nil) on success or (nil, errorMessage) on failure.
    /// Both inputs can come from a `nirux://new-worktree` URL, so they are
    /// validated here rather than trusted: `repoRoot` must be the top level
    /// of a git work tree, `branch` a valid branch name (a leading "-" would
    /// otherwise be parsed as a git option), and an existing directory is
    /// only reused when git lists it as a worktree of the repo on `branch`.
    /// `repoRoot` may be a linked worktree: the new one still goes next to
    /// the main checkout (see `mainWorktreeRoot(of:)`), but git runs in
    /// `repoRoot`, so a new branch starts from its HEAD.
    ///
    /// With `newBranchFrom` (New Task…), `branch` must be new (see
    /// `newBranchProblem`), so an agent is never handed work that already
    /// exists. It starts from that start point (a full ref name, or `HEAD`)
    /// without tracking it: the agent pushes it under its own name. When git
    /// fails after creating the worktree (a failing post-checkout hook), the
    /// worktree is returned along with git's error; when it fails after
    /// creating only the branch, the branch is deleted, so a retry can use
    /// the name. The other modes never return both a path and an error.
    static func create(
        branch: String, repoRoot: String, newBranchFrom startPoint: String? = nil
    ) -> (path: String?, error: String?) {
        if let problem = repositoryTopLevelProblem(repoRoot) {
            return (nil, problem)
        }
        guard isValidBranchName(branch, repoRoot: repoRoot) else {
            return (nil, "Invalid branch name: \(branch)")
        }
        var startCommit: String?
        if let startPoint {
            let start = newBranchStart(branch, from: startPoint, repoRoot: repoRoot)
            guard let commit = start.commit else { return (nil, start.problem) }
            startCommit = commit
        }

        // Sanitize branch name for directory path
        let dirName = branch.replacingOccurrences(of: "/", with: "-")
        let mainRoot = mainWorktreeRoot(of: repoRoot)
        let repoName = URL(fileURLWithPath: mainRoot).lastPathComponent
        let worktreePath = URL(fileURLWithPath: mainRoot)
            .deletingLastPathComponent()
            .appendingPathComponent("\(repoName).\(dirName)")
            .path

        // A branch is checked out in one worktree at most: open that one,
        // wherever it is (older versions named a worktree made from another
        // one `repo.feat-a.feat-b`). Not the main checkout (listed first) or
        // the requesting one, though: a second agent there would share its
        // files and replace its handover.
        let worktrees = list(repoRoot: repoRoot)
        if let index = worktrees.firstIndex(where: { $0.branch == branch }) {
            if index == 0 {
                return (nil, "\(branch) is already checked out in the main checkout")
            }
            if worktrees[index].path.realPath == repoRoot.realPath {
                return (nil, "\(branch) is already checked out in \(repoRoot)")
            }
            let existing = worktrees[index].path
            if let reusable = reusableWorktree(existing, branch: branch, requester: repoRoot, worktrees: worktrees) {
                return (reusable, nil)
            }
            if FileManager.default.fileExists(atPath: existing) {
                return (nil, "\(existing) is listed for \(branch) but can’t be reused from \(repoRoot)")
            }
            // Its folder is gone: `worktree add` below reports it.
        }

        // Any other directory at the target path would get a handover and
        // an agent ("a/b" and "a-b" share a folder name).
        if FileManager.default.fileExists(atPath: worktreePath) {
            guard let resolved = worktreePath.realPath,
                  let other = worktrees.first(where: { $0.path.realPath == resolved })
            else {
                return (nil, "\(worktreePath) already exists and is not a worktree of \(mainRoot)")
            }
            return (nil, "\(worktreePath) already exists on \(other.branch ?? "a detached HEAD"), not \(branch)")
        }

        // Check if branch exists locally or remotely
        let branchExists = gitRun(["branch", "--list", branch], cwd: repoRoot)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let remoteBranchExists = !branchExists && gitRun(["branch", "-r", "--list", "*/\(branch)"], cwd: repoRoot)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        // --quiet: no "Preparing worktree" line ahead of an error, which the
        // panel's one-line status would show instead of the error.
        let args: [String]
        if let startCommit {
            args = ["worktree", "add", "--quiet", "--no-track", "-b", branch, worktreePath, startCommit]
        } else if branchExists {
            args = ["worktree", "add", "--quiet", worktreePath, branch]
        } else if remoteBranchExists {
            args = ["worktree", "add", "--quiet", "--track", "-b", branch, worktreePath, "origin/\(branch)"]
        } else {
            args = ["worktree", "add", "--quiet", "-b", branch, worktreePath]
        }

        let result = gitRunFull(args, cwd: repoRoot)
        if result.status == 0 {
            return (worktreePath, nil)
        }
        let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let error = msg.isEmpty ? "git worktree add failed" : msg
        return startCommit.map {
            afterFailedNewBranch(branch, at: worktreePath, from: $0, repoRoot: repoRoot, error: error)
        } ?? (nil, error)
    }

    struct WorktreeEntry {
        let path: String
        let branch: String?  // nil for detached HEAD
    }

    /// List existing worktrees for the repo at the given root.
    static func list(repoRoot: String) -> [WorktreeEntry] {
        let output = gitRun(["worktree", "list", "--porcelain"], cwd: repoRoot)
        var entries: [WorktreeEntry] = []
        var currentPath: String?
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                currentPath = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/") {
                let branch = String(line.dropFirst("branch refs/heads/".count))
                if let path = currentPath {
                    entries.append(WorktreeEntry(path: path, branch: branch))
                }
                currentPath = nil
            } else if line.isEmpty {
                // End of entry — if no branch was found (detached HEAD), still add it
                if let path = currentPath {
                    entries.append(WorktreeEntry(path: path, branch: nil))
                }
                currentPath = nil
            }
        }
        return entries
    }

    /// A linked worktree checkout has `.git` as a *file* (gitdir pointer)
    /// rather than a directory. Cheap filesystem check — no git invocation.
    static func isLinkedWorktree(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path + "/.git", isDirectory: &isDirectory) else { return false }
        return !isDirectory.boolValue
    }

    /// Detect the git repo root from a path
    static func repoRoot(at path: String) -> String? {
        let output = gitRunFull(["rev-parse", "--show-toplevel"], cwd: path, timeout: mainThreadTimeout)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    /// Nil when `path` is the top level of a git work tree; otherwise why
    /// not, keeping git's own message (e.g. its safe.directory advice).
    static func repositoryTopLevelProblem(_ path: String) -> String? {
        let notTopLevel = "Not the top level of a git repository: \(path)"
        guard path.hasPrefix("/"), let resolved = path.realPath else { return notTopLevel }
        let result = gitRunFull(["rev-parse", "--show-toplevel"], cwd: resolved)
        let topLevel = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !topLevel.isEmpty else {
            let gitError = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return gitError.isEmpty ? notTopLevel : gitError
        }
        return topLevel.realPath == resolved ? nil : notTopLevel
    }

    /// The main checkout of the repository `repoRoot` is a work tree of:
    /// `repoRoot` itself, or the folder its linked worktrees hang off. New
    /// worktrees are placed and named after it, so one created from inside
    /// `repo.feat-a` is `repo.feat-b`, not `repo.feat-a.feat-b`. Resolved
    /// with realpath. Falls back to `repoRoot` when git can't tell where the
    /// main checkout is: a bare repository, a separate git dir, a submodule.
    static func mainWorktreeRoot(of repoRoot: String) -> String {
        let fallback = repoRoot.realPath ?? repoRoot
        // Same git dir and common dir: `repoRoot` is the main checkout.
        guard let dirs = absoluteGitPaths(["--git-dir", "--git-common-dir"], in: repoRoot),
              dirs[0].realPath != dirs[1].realPath
        else { return fallback }
        // git's own rule (worktree.c, get_main_worktree): the common git
        // dir without its trailing "/.git".
        let commonDir = dirs[1]
        guard (commonDir as NSString).lastPathComponent == ".git",
              let candidate = (commonDir as NSString).deletingLastPathComponent.realPath
        else { return fallback }
        // A bare repository kept in a ".git" folder has no work tree above
        // it: only trust the parent if git sees it as the top level of a
        // work tree sharing this very common dir…
        guard let paths = absoluteGitPaths(["--show-toplevel", "--git-common-dir"], in: candidate),
              paths[0].realPath == candidate,
              paths[1].realPath == commonDir.realPath
        else { return fallback }
        // …and that lists `repoRoot` as one of its worktrees: a ".git" file
        // with a crafted `commondir` can tie any folder to another repository.
        guard list(repoRoot: candidate).contains(where: { $0.path.realPath == fallback }) else {
            return fallback
        }
        return candidate
    }

    /// `path` resolved, if the agent can be handed the worktree git lists
    /// there for `branch`. Checked on the folder itself, since an entry not
    /// pruned yet can outlive its folder or have it replaced: it must be a
    /// linked worktree of this repository with `branch` checked out. And git
    /// must know `requester` as a checkout of the repository, not just as a
    /// folder whose `.git` file points into it.
    private static func reusableWorktree(
        _ path: String, branch: String, requester: String, worktrees: [WorktreeEntry]
    ) -> String? {
        guard let resolved = path.realPath,
              let requesterPath = requester.realPath,
              let own = absoluteGitPaths(["--git-dir", "--git-common-dir"], in: requester),
              let commonDir = own[1].realPath,
              let target = absoluteGitPaths(["--show-toplevel", "--git-dir", "--git-common-dir"], in: resolved),
              target[0].realPath == resolved,
              target[2].realPath == commonDir,
              let targetGitDir = target[1].realPath,
              (targetGitDir as NSString).deletingLastPathComponent == commonDir + "/worktrees",
              gitRunFull(["symbolic-ref", "-q", "HEAD"], cwd: resolved).stdout
                  .trimmingCharacters(in: .newlines) == "refs/heads/\(branch)"
        else { return nil }
        // git lists the main checkout first, except for a separate git dir or
        // a submodule: their common dir is not a ".git" folder.
        let requesterIsKnown = worktrees.contains { $0.path.realPath == requesterPath }
            || (own[0].realPath == commonDir && (commonDir as NSString).lastPathComponent != ".git")
        return requesterIsKnown ? resolved : nil
    }

    static func isValidBranchName(_ branch: String, repoRoot: String) -> Bool {
        guard !branch.isEmpty, !branch.hasPrefix("-") else { return false }
        return gitRunFull(["check-ref-format", "refs/heads/\(branch)"], cwd: repoRoot).status == 0
    }

    /// The branch checked out at `path`, when `path` is itself the top of a
    /// checkout rather than a folder inside another repository. Nil for a
    /// detached HEAD, a folder that isn't a checkout, or a failed read.
    /// Runs git, so call it off the main thread.
    static func currentBranch(at path: String) -> String? {
        let result = gitRunFull(
            ["rev-parse", "--show-toplevel", "--symbolic-full-name", "HEAD"],
            cwd: path,
            timeout: branchReadTimeout
        )
        // `--short` would print "heads/x" when a tag is also named x.
        let lines = result.stdout.split(separator: "\n").map(String.init)
        let branchPrefix = "refs/heads/"
        guard result.status == 0, lines.count == 2,
              isSameDirectory(lines[0], path),
              lines[1].hasPrefix(branchPrefix)
        else { return nil }
        let branch = String(lines[1].dropFirst(branchPrefix.count))
        return branch.isEmpty ? nil : branch
    }

    // MARK: - Helpers

    /// Compares file identity, so symlinks (/tmp vs /private/tmp) and case
    /// differences on a case-insensitive volume don't matter.
    private static func isSameDirectory(_ first: String, _ second: String) -> Bool {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let firstID = try? URL(fileURLWithPath: first).resourceValues(forKeys: keys).fileResourceIdentifier,
              let secondID = try? URL(fileURLWithPath: second).resourceValues(forKeys: keys).fileResourceIdentifier
        else { return false }
        return firstID.isEqual(secondID)
    }

    static func gitRun(_ args: [String], cwd: String) -> String {
        return gitRunFull(args, cwd: cwd).stdout
    }

    /// `git rev-parse --path-format=absolute <queries>`: one absolute path
    /// per query, or nil (including for a path containing a newline).
    static func absoluteGitPaths(_ queries: [String], in directory: String) -> [String]? {
        let result = gitRunFull(["rev-parse", "--path-format=absolute"] + queries, cwd: directory)
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard result.status == 0, lines.last == "" else { return nil }
        let paths = Array(lines.dropLast())
        guard paths.count == queries.count, paths.allSatisfy({ $0.hasPrefix("/") }) else { return nil }
        return paths
    }

    /// `repoRoot(at:)` runs on the main thread, which this blocks.
    private static let mainThreadTimeout: TimeInterval = 5
    /// A branch read is instant; past this, git is stuck and the session
    /// simply goes unnamed.
    private static let branchReadTimeout: TimeInterval = 5
    /// A last resort, not an expected outcome: killing `worktree add`
    /// mid-checkout leaves a half-made worktree behind, and draining both
    /// pipes already keeps large output from wedging git.
    private static let defaultTimeout: TimeInterval = 3600

    /// Runs git with both pipes drained while it runs, so large output
    /// cannot fill a pipe and wedge git before it exits.
    static func gitRunFull(
        _ args: [String],
        cwd: String,
        gitPath: String = "/usr/bin/git",
        timeout: TimeInterval = defaultTimeout,
        environment: [String: String] = [:]
    ) -> GitResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return GitResult(status: 1, stdout: "", stderr: "No such directory: \(cwd)")
        }
        guard let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: gitPath),
            arguments: args,
            currentDirectoryURL: URL(fileURLWithPath: cwd),
            environment: environment,
            timeout: timeout,
            captureStandardError: true
        ) else {
            return GitResult(
                status: 1,
                stdout: "",
                stderr: "git could not start or timed out after \(String(format: "%g", timeout))s"
            )
        }
        return GitResult(
            status: result.terminationStatus,
            stdout: String(data: result.standardOutput, encoding: .utf8) ?? "",
            stderr: String(data: result.standardError, encoding: .utf8) ?? ""
        )
    }
}
