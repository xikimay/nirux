import AppKit

struct GitResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Raycast-style floating panel for creating a git worktree + workspace
@MainActor
final class WorktreePanel {
    var onCreated: ((String, String, String) -> Void)?  // (branch, worktreePath, repoRoot)

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
                icon: "\u{1F333}",
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
            DispatchQueue.main.async { [weak self] in
                if let path {
                    self?.panel?.orderOut(nil)
                    self?.onCreated?(branch, path, repoRoot)
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
    /// otherwise be parsed as a git option), and an existing directory at the
    /// target path is only reused when git lists it as a worktree of the repo.
    static func create(branch: String, repoRoot: String) -> (path: String?, error: String?) {
        if let problem = repositoryTopLevelProblem(repoRoot) {
            return (nil, problem)
        }
        guard isValidBranchName(branch, repoRoot: repoRoot) else {
            return (nil, "Invalid branch name: \(branch)")
        }

        // Sanitize branch name for directory path
        let dirName = branch.replacingOccurrences(of: "/", with: "-")
        let repoName = URL(fileURLWithPath: repoRoot).lastPathComponent
        let worktreePath = URL(fileURLWithPath: repoRoot)
            .deletingLastPathComponent()
            .appendingPathComponent("\(repoName).\(dirName)")
            .path

        // Reuse an existing checkout only if it really is one of this repo's
        // worktrees, on the requested branch ("a/b" and "a-b" share a folder
        // name); any other directory would get a handover and an agent.
        if FileManager.default.fileExists(atPath: worktreePath) {
            guard let existing = worktree(at: worktreePath, of: repoRoot) else {
                return (nil, "\(worktreePath) already exists and is not a worktree of \(repoRoot)")
            }
            guard existing.branch == branch else {
                return (nil, "\(worktreePath) already exists on \(existing.branch ?? "a detached HEAD"), not \(branch)")
            }
            return (worktreePath, nil)
        }

        // Check if branch exists locally or remotely
        let branchExists = gitRun(["branch", "--list", branch], cwd: repoRoot)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let remoteBranchExists = !branchExists && gitRun(["branch", "-r", "--list", "*/\(branch)"], cwd: repoRoot)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        let args: [String]
        if branchExists {
            args = ["worktree", "add", worktreePath, branch]
        } else if remoteBranchExists {
            args = ["worktree", "add", "--track", "-b", branch, worktreePath, "origin/\(branch)"]
        } else {
            args = ["worktree", "add", "-b", branch, worktreePath]
        }

        let result = gitRunFull(args, cwd: repoRoot)
        if result.status == 0 {
            return (worktreePath, nil)
        } else {
            let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, msg.isEmpty ? "git worktree add failed" : msg)
        }
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

    static func isRepositoryTopLevel(_ path: String) -> Bool {
        repositoryTopLevelProblem(path) == nil
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

    static func isValidBranchName(_ branch: String, repoRoot: String) -> Bool {
        guard !branch.isEmpty, !branch.hasPrefix("-") else { return false }
        return gitRunFull(["check-ref-format", "refs/heads/\(branch)"], cwd: repoRoot).status == 0
    }

    static func worktree(at path: String, of repoRoot: String) -> WorktreeEntry? {
        guard let resolved = path.realPath else { return nil }
        return list(repoRoot: repoRoot).first { $0.path.realPath == resolved }
    }

    // MARK: - Helpers

    private static func gitRun(_ args: [String], cwd: String) -> String {
        return gitRunFull(args, cwd: cwd).stdout
    }

    /// `repoRoot(at:)` runs on the main thread, which this blocks.
    private static let mainThreadTimeout: TimeInterval = 5
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
        timeout: TimeInterval = defaultTimeout
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
