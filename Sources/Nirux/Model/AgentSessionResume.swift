import Foundation

/// Where to resume a recorded session, including one whose worktree was
/// cleaned up. See "History" in docs/projects.md for the study behind it
/// (Claude Code 2.1.287, Codex CLI 0.151):
/// - `claude --resume <id>` finds a session from any folder, deleted
///   worktrees included, and keeps its id. It works in the folder it was
///   launched from, without a visible warning, while the conversation still
///   names the old paths.
/// - `codex resume <id>` finds a thread from any folder too, but asks which
///   folder to work in when the one it recorded differs, and offers that
///   one first even when it is gone: `codexCommand(resume:workingDirectory:)`
///   passes `-C <folder>`.
///
/// So a session goes back to its own checkout when it can; to the checkout
/// that has its branch now, when its worktree was moved; to the same path
/// recreated as a worktree when only the worktree is gone (from its
/// branch, or at its last commit once the branch was deleted after its
/// merge); otherwise to the repository's main checkout, with a warning.
enum AgentSessionResume {
    struct Plan: Equatable {
        enum Place: Equatable {
            /// The folder it ran in still exists.
            case original
            /// Another checkout has the session's branch checked out: its
            /// worktree was moved (`git worktree move`), or the branch was
            /// checked out again elsewhere.
            case branchCheckout
            /// `git worktree add <worktreeRoot> <ref>`, run in `mainCheckout`,
            /// brings the folder back at the same path first: the
            /// conversation's paths are valid again, and Codex has nothing to
            /// ask. `ref` is the branch, or the last commit.
            case recreatedWorktree(mainCheckout: String, ref: String)
            /// The repository's main checkout, on whatever it has checked out.
            case mainCheckout
        }

        let place: Place
        /// Where the column opens.
        let directory: String
        /// Shown before resuming somewhere that doesn't hold what the
        /// session worked on.
        let warning: String?
    }

    enum Unavailable: Error, Equatable {
        /// Never prompted: nothing to resume.
        case noConversation
        /// Claude deleted the transcript (its `cleanupPeriodDays`).
        case transcriptGone
        /// Neither its folder nor its repository's main checkout exists.
        case noFolder
    }

    /// What `plan` asks of the disk and of git.
    struct Probe {
        var directoryExists: (String) -> Bool
        var fileExists: (String) -> Bool
        /// The branch checked out at the top of a checkout; nil when
        /// detached or unknown.
        var currentBranch: (String) -> String?
        /// The worktrees git registers for the repository of a main
        /// checkout, the main checkout included; one whose folder is gone
        /// stays registered until it is pruned.
        var worktrees: (_ mainCheckout: String) -> [GitWorktree.WorktreeEntry]
        /// Whether the repository has that local branch.
        var hasBranch: (_ mainCheckout: String, _ branch: String) -> Bool
        /// Whether the repository still has that commit (a squash merge
        /// leaves it unreachable until `git gc` prunes it).
        var hasCommit: (_ mainCheckout: String, _ commit: String) -> Bool
    }

    static func plan(for record: AgentSessionRecord, probe: Probe) -> Result<Plan, Unavailable> {
        guard record.hasConversation else { return .failure(.noConversation) }
        if record.agent == .claude, let transcriptPath = record.transcriptPath, !probe.fileExists(transcriptPath) {
            return .failure(.transcriptGone)
        }
        let checkout = record.checkout
        // The top of its checkout first: the agent's last folder is often
        // one it moved to with `cd`, and the session started at the top.
        if let folder = [checkout?.worktreeRoot, record.cwd].compactMap({ $0 }).first(where: probe.directoryExists) {
            var warning: String?
            if let branch = checkout?.branchName, let current = probe.currentBranch(folder), current != branch {
                warning = "The session ran on branch \(branch); \(folder) now has \(current) checked out."
            }
            return .success(Plan(place: .original, directory: folder, warning: warning))
        }
        guard let checkout, let mainCheckout = checkout.mainCheckout, mainCheckout != checkout.worktreeRoot,
              probe.directoryExists(mainCheckout) else { return .failure(.noFolder) }
        let path = checkout.worktreeRoot
        let worktrees = probe.worktrees(mainCheckout)
        let registered = worktrees.first { isSamePath($0.path, path) }
        let others = worktrees.filter { !isSamePath($0.path, path) }
        if let branch = checkout.branchName,
           let holder = others.first(where: { $0.branch == branch && probe.directoryExists($0.path) }) {
            return .success(Plan(
                place: .branchCheckout,
                directory: holder.path,
                warning: "\(holder.path) has \(branch) checked out now: the session resumes there. "
                    + "Paths in the conversation point to \(path)."
            ))
        }
        // Nirux's clean-up leaves no entry behind: a folder git still lists
        // went away some other way, and may come back.
        let vanished = registered.map { _ in
            "Git still lists \(path), but the folder is gone: it may have been moved, or be on a disk that isn't "
                + "mounted. Resuming makes a new checkout there."
        }
        if registered?.isLocked != true {
            if let branch = checkout.branchName, probe.hasBranch(mainCheckout, branch) {
                guard let holder = others.first(where: { $0.branch == branch }) else {
                    return .success(recreated(path, from: mainCheckout, ref: branch, warnings: [vanished]))
                }
                if let head = checkout.head, probe.hasCommit(mainCheckout, head) {
                    let held = "Git lists \(branch) as checked out in \(holder.path), a folder that is gone: the worktree "
                        + "comes back at its last commit, \(head.prefix(12)), with no branch checked out."
                    return .success(recreated(path, from: mainCheckout, ref: head, warnings: [held, vanished]))
                }
            } else if let head = checkout.head, probe.hasCommit(mainCheckout, head) {
                // A session that ran detached comes back as it was.
                let gone = checkout.branchName.map {
                    "The branch \($0) no longer exists: the worktree comes back at its last commit, "
                        + "\(head.prefix(12)), with no branch checked out."
                }
                return .success(recreated(path, from: mainCheckout, ref: head, warnings: [gone, vanished]))
            }
        }
        let branch = checkout.branchName.map { " (branch \($0))" } ?? ""
        let gone = registered?.isLocked == true
            ? "Git keeps the worktree \(path)\(branch) locked, and its folder is gone: it may be on a disk that isn't mounted."
            : "The worktree \(path)\(branch) no longer exists."
        return .success(Plan(
            place: .mainCheckout,
            directory: mainCheckout,
            warning: gone + " The session resumes in \(mainCheckout). Paths in the conversation point to the old "
                + "worktree, and edits will apply to \(mainCheckout)."
        ))
    }

    private static func recreated(_ path: String, from mainCheckout: String, ref: String, warnings: [String?]) -> Plan {
        let warning = warnings.compactMap { $0 }.joined(separator: " ")
        return Plan(
            place: .recreatedWorktree(mainCheckout: mainCheckout, ref: ref),
            directory: path,
            warning: warning.isEmpty ? nil : warning
        )
    }

    /// Git lists worktrees by their real path; a folder that is gone can't
    /// be resolved, its parent can (`/var` is `/private/var`).
    static func isSamePath(_ first: String, _ second: String) -> Bool {
        func canonical(_ path: String) -> String {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard let parent = url.deletingLastPathComponent().path.realPath else { return url.path }
            return (parent as NSString).appendingPathComponent(url.lastPathComponent)
        }
        return canonical(first) == canonical(second)
    }
}

extension AgentSessionRecord.Checkout {
    /// Its branch; nil when it ran on a detached HEAD, which git context
    /// names "HEAD".
    var branchName: String? { branch == "HEAD" ? nil : branch }
}
