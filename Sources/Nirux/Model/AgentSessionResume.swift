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
/// So a session goes back to its own folder when it can; to the same path
/// recreated as a worktree when only the worktree is gone (from its
/// branch, or at its last commit once the branch was deleted after its
/// merge); otherwise to the repository's main checkout, with a warning.
enum AgentSessionResume {
    struct Plan: Equatable {
        enum Place: Equatable {
            /// The folder it ran in still exists.
            case original
            /// `git worktree add <worktreeRoot> <ref>` (after `git worktree
            /// prune`, in case it was deleted without git), run in
            /// `mainCheckout`, brings the folder back at the same path first:
            /// the conversation's paths are valid again, and Codex has
            /// nothing to ask. `ref` is the branch, or the last commit.
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
        /// The branch checked out in a folder; nil when detached or unknown.
        var currentBranch: (String) -> String?
        /// Whether `git worktree add <path> <ref>` would work from that main
        /// checkout: the branch or commit exists, and no other worktree has
        /// the branch checked out.
        var canCheckOut: (_ mainCheckout: String, _ ref: String) -> Bool
    }

    static func plan(for record: AgentSessionRecord, probe: Probe) -> Result<Plan, Unavailable> {
        guard record.hasConversation else { return .failure(.noConversation) }
        if record.agent == .claude, let transcriptPath = record.transcriptPath, !probe.fileExists(transcriptPath) {
            return .failure(.transcriptGone)
        }
        let checkout = record.checkout
        if let folder = [record.cwd, checkout?.worktreeRoot].compactMap({ $0 }).first(where: probe.directoryExists) {
            var warning: String?
            if let checkout, let current = probe.currentBranch(folder), current != checkout.branch {
                warning = "The session ran on branch \(checkout.branch); \(folder) now has \(current) checked out."
            }
            return .success(Plan(place: .original, directory: folder, warning: warning))
        }
        guard let checkout, let mainCheckout = checkout.mainCheckout, mainCheckout != checkout.worktreeRoot,
              probe.directoryExists(mainCheckout) else { return .failure(.noFolder) }
        if probe.canCheckOut(mainCheckout, checkout.branch) {
            return .success(Plan(
                place: .recreatedWorktree(mainCheckout: mainCheckout, ref: checkout.branch),
                directory: checkout.worktreeRoot,
                warning: nil
            ))
        }
        if let head = checkout.head, probe.canCheckOut(mainCheckout, head) {
            return .success(Plan(
                place: .recreatedWorktree(mainCheckout: mainCheckout, ref: head),
                directory: checkout.worktreeRoot,
                warning: "The branch \(checkout.branch) no longer exists: the worktree comes back at its last commit, "
                    + "\(head.prefix(12)), with no branch checked out."
            ))
        }
        return .success(Plan(
            place: .mainCheckout,
            directory: mainCheckout,
            warning: "The worktree \(checkout.worktreeRoot) (branch \(checkout.branch)) no longer exists. "
                + "The session resumes in \(mainCheckout). Paths in the conversation point to the old worktree, "
                + "and edits will apply to \(mainCheckout)."
        ))
    }
}
