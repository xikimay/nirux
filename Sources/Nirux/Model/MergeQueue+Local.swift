import Foundation

// MARK: - Local preflight (section 3.2, step 1)

extension MergeQueue {
    /// The pull request's branch on this Mac, as read off the main thread.
    struct LocalInspection: Equatable, Sendable {
        var worktrees: [LocalWorktree] = []
        /// Every worktree listed in the project's repositories (comparable
        /// paths): a workspace in a worktree nested inside the branch's
        /// belongs to that one.
        var allWorktreePaths: [String] = []
    }

    /// The branch's worktrees in the project's local repositories (those
    /// with a remote naming the configured repository), each checked for
    /// changes to tracked files and for commits GitHub doesn't have.
    /// Untracked files, such as a handover, don't count. Runs git and gh:
    /// call it off the main thread.
    static func inspectLocal(
        folders: [String],
        branch: String,
        head: String,
        settings: BoardConfig.QueueSettings,
        client: any MergeQueueGitHub,
        tools: WorktreeCleanup.Tools = .installed
    ) -> Result<LocalInspection, ClientError> {
        let snapshot = ProjectBoard.readLocal(folders: folders, tools: tools)
        let configured = settings.gitHubRepository
        let repositories = snapshot.repositories.filter { repository in
            repository.remotes.contains { $0.owner == configured.owner && $0.name == configured.name }
        }
        var inspection = LocalInspection()
        for repository in repositories {
            for worktree in repository.worktrees where !worktree.isBare && !worktree.isPrunable {
                inspection.allWorktreePaths.append(worktree.path)
                guard worktree.branch == branch else { continue }
                let status = WorktreeCleanup.git(["status", "--porcelain", "--untracked-files=no"], in: worktree.path, tools: tools)
                guard status.status == 0 else {
                    let reason = WorktreeCleanup.firstLine(status.stderr) ?? "git status failed"
                    inspection.worktrees.append(LocalWorktree(path: worktree.path, problem: .unreadable(reason)))
                    continue
                }
                guard status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    inspection.worktrees.append(LocalWorktree(path: worktree.path, problem: .trackedChanges))
                    continue
                }
                guard let localHead = worktree.head?.lowercased() else {
                    inspection.worktrees.append(LocalWorktree(path: worktree.path, problem: .unreadable("it has no commit")))
                    continue
                }
                guard localHead != head.lowercased() else {
                    inspection.worktrees.append(LocalWorktree(path: worktree.path, problem: nil))
                    continue
                }
                // After the queue's own update the local repository may lack
                // the PR head, so only GitHub can tell.
                switch client.read(.compare(base: head, head: localHead), settings: settings) {
                case .success(.comparison(let comparison)):
                    inspection.worktrees.append(LocalWorktree(path: worktree.path, problem: unpushed(comparison) ? .unpushed : nil))
                case .success:
                    return .failure(.unreadable("compare"))
                case .failure(let error):
                    return .failure(error)
                }
            }
        }
        return .success(inspection)
    }

    /// `compare/{PR head}...{local HEAD}`: commits ahead, or a 404
    /// because GitHub doesn't have the local commit.
    static func unpushed(_ comparison: Comparison?) -> Bool {
        guard let comparison else { return true }
        return comparison.aheadBy > 0
    }

    /// What an agent column's state means for the queue: working, or
    /// waiting on a dialog, keeps a pull request out of a merge (section
    /// 3.2). Nil for any other state.
    static func busyLabel(_ state: ProjectBoard.AgentState) -> String? {
        switch state {
        case .working: return "working"
        case .waiting(let reason), .waitingLong(let reason, _): return "waiting (\(reason.shortLabel))"
        case .none, .idle, .exitedMidTurn, .stoppedOnError: return nil
        }
    }

    /// Whether a folder is inside one of `roots` and not inside another
    /// worktree nested in that root. Paths comparable.
    static func isInside(_ path: String, roots: [String], allWorktrees: [String]) -> Bool {
        roots.contains { root in
            ProjectBoard.contains(root, path) && !allWorktrees.contains { other in
                other != root && ProjectBoard.contains(root, other) && ProjectBoard.contains(other, path)
            }
        }
    }
}
