import AppKit

private struct GitResult {
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
    static func create(branch: String, repoRoot: String) -> (path: String?, error: String?) {
        // Sanitize branch name for directory path
        let dirName = branch.replacingOccurrences(of: "/", with: "-")
        let repoName = URL(fileURLWithPath: repoRoot).lastPathComponent
        let worktreePath = URL(fileURLWithPath: repoRoot)
            .deletingLastPathComponent()
            .appendingPathComponent("\(repoName).\(dirName)")
            .path

        // Check if worktree path already exists
        if FileManager.default.fileExists(atPath: worktreePath) {
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

    /// Detect the git repo root from a path
    static func repoRoot(at path: String) -> String? {
        let output = gitRun(["rev-parse", "--show-toplevel"], cwd: path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    // MARK: - Helpers

    private static func gitRun(_ args: [String], cwd: String) -> String {
        return gitRunFull(args, cwd: cwd).stdout
    }

    private static func gitRunFull(_ args: [String], cwd: String) -> GitResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            return GitResult(
                status: proc.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        } catch {
            return GitResult(status: 1, stdout: "", stderr: error.localizedDescription)
        }
    }
}
