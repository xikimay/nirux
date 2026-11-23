import Foundation

extension MergeQueue {
    struct Conflict: Equatable, Sendable {
        let number: Int
        let branch: String
        let base: String

        init?(saved: SavedQueue?, repository: GitHubRepository, dryRun: Bool) {
            guard let saved, saved.status == .stopped, saved.stopReason?.kind == .conflict,
                  saved.dryRun == dryRun, GitHubRepository(ownerAndName: saved.repository) == repository,
                  let current = saved.current, let entry = saved.entries[safe: current],
                  case .stopped(let reason) = entry.step, reason.kind == .conflict,
                  entry.number > 0, BoardConfig.isValidBranchName(entry.branch) else { return nil }
            number = entry.number
            branch = entry.branch
            base = saved.baseBranch
        }

        var prompt: String? {
            guard BoardConfig.isValidBranchName(base), PRFollowUp.isPlainName(base) else { return nil }
            return "PR #\(number) conflicts with `\(base)`. Run `git pull`, then `git merge origin/\(base)`, "
                + "resolve the conflicts, run the tests, commit and push. Don't rebase or force-push."
        }

        func worktrees(in local: ProjectBoard.LocalSnapshot, repository: GitHubRepository) -> [String] {
            local.repositories.filter { $0.remotes.contains { $0.hasOwnerAndName(of: repository) } }
                .flatMap(\.worktrees).filter { !$0.isBare && !$0.isPrunable && $0.branch == branch }.map(\.path)
        }
    }
}
