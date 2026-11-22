import AppKit

extension NiruxShellView {
    enum QueueResolution: Equatable {
        case hidden
        case blocked(String)
        case ready(MergeQueue.Conflict, [ReviewSendColumn])

        static func offer(_ conflict: MergeQueue.Conflict, columns: [ReviewSendColumn]) -> Self {
            guard !columns.isEmpty else { return .blocked("No agent runs in this branch’s worktree workspace.") }
            let eligible = columns.filter { $0.refusal == nil && !$0.hasDraft && $0.process != nil }
            if !eligible.isEmpty { return .ready(conflict, eligible) }
            return .blocked(columns.map { column in
                let reason = column.refusal?.message ?? (column.hasDraft
                    ? "Its prompt already holds a draft." : ReviewSendRefusal.notInFront.message)
                return columns.count == 1 ? reason : "\(column.label): \(reason)"
            }.joined(separator: "\n"))
        }
    }

    func showQueueJournal(board: ProjectBoardController, section: String, in window: NSWindow) {
        guard let queue = boardQueue(board, section: section) else { return }
        let panel = MergeQueueJournalPanel(queue: queue, openURL: sideEffects.openURL)
        panel.readResolution = { [weak self, weak board, weak panel] snapshot in
            guard let self, let board else { return .hidden }
            return self.queueResolution(queue, shown: panel?.snapshot?.conflict, board: board, section: section, snapshot: snapshot)
        }
        panel.onResolve = { [weak self, weak panel] conflict, column in
            guard let self, let panel else { return nil }
            return await self.resolve(conflict, column: column, queue: queue, panel: panel)
        }
        panel.show(in: window)
    }

    private func queueResolution(
        _ queue: MergeQueueController, shown: MergeQueue.Conflict?, board: ProjectBoardController, section id: String, snapshot: ProcessSnapshot
    ) -> QueueResolution {
        guard !queue.isRunning, !queue.runsElsewhere, !queue.isRepositoryBusy(queue.queueRepository) else {
            return .blocked("The repository’s merge queue is running.")
        }
        guard let conflict = MergeQueue.Conflict(saved: queue.saved, repository: queue.queueRepository, dryRun: queue.isDryRun)
        else { return .hidden }
        guard conflict == shown else { return .blocked("Refresh the Journal to read the current conflict.") }
        guard let section = board.section(id: id), board.repository(of: section)?.gitHub == queue.queueRepository,
              board.loaded(for: section)?.config?.baseBranch == conflict.base, conflict.prompt != nil else {
            return .blocked("The stopped queue’s base must match a configured branch that is safe to type in the prompt.")
        }
        guard let local = board.local else { return .blocked("Reading the repository’s worktrees…") }
        let roots = conflict.worktrees(in: local, repository: queue.queueRepository)
        guard !roots.isEmpty else { return .blocked("No worktree has the conflicting PR’s branch checked out.") }
        let all = local.repositories.flatMap { $0.worktrees.map(\.path) }
        let spaces = projectWorkspaces(of: board.projectID).filter {
            MergeQueue.isInside($0.cwd.comparablePath, roots: roots, allWorktrees: all)
        }
        return .offer(conflict, columns: reviewSendColumns(in: spaces, roots: roots, allWorktrees: all, snapshot: snapshot))
    }

    private func resolve(
        _ conflict: MergeQueue.Conflict, column: ReviewSendColumn, queue: MergeQueueController, panel: MergeQueueJournalPanel
    ) async -> String? {
        let changed = "The queue, worktree or agent changed. Refresh the Journal and choose again."
        guard let workspace = workspaces.first(where: { $0.id == column.workspaceID }),
              let target = workspace.columns.first(where: { $0.id == column.columnID }),
              let pty = target.pty, let folder = pty.agentCwd(snapshot: ProcessSnapshot()),
              let process = column.process, let prompt = conflict.prompt else { return changed }
        let repository = queue.queueRepository
        let workspaceFolder = workspace.cwd
        let matches = await Task.detached {
            guard let root = GitWorktree.repoRoot(at: folder),
                  GitWorktree.repoRoot(at: workspaceFolder)?.comparablePath == root.comparablePath,
                  GitWorktree.currentBranch(at: root) == conflict.branch else { return false }
            let origin = GitWorktree.gitRunFull(["remote", "get-url", "origin"], cwd: root, timeout: 5)
            return origin.status == 0 && GitHubRepository(remoteURL: origin.stdout)?.hasOwnerAndName(of: repository) == true
        }.value
        guard matches else { return "The agent’s checkout must be on the conflicting branch with this repository as origin." }
        guard let parent = panel.sheetParent, parent.attachedSheet === panel else { return changed }
        let lock: MergeQueueLock
        switch queue.lockForResolution(of: conflict) {
        case .success(let acquired): lock = acquired
        case .failure(let refusal): return refusal.message
        }
        defer { lock.release() }
        guard AgentHookCenter.shared.drain() else { return Self.hooksStillComing }
        let snapshot = ProcessSnapshot()
        switch panel.readResolution?(snapshot) {
        case .blocked(let reason): return reason
        case .ready(let current, let eligible) where current == conflict && eligible.contains(column): break
        default: return changed
        }
        guard workspace.cwd == workspaceFolder, pty.agentCwd(snapshot: snapshot) == folder else { return changed }
        let result = await withCheckedContinuation { continuation in
            pty.pasteInBackground(BranchReview.agentPaste(prompt), keepingInFront: process, cancelled: { false }) { result, _ in
                continuation.resume(returning: result)
            }
        }
        guard result.outcome == .pasted else { return Self.pasteProblem(result.outcome) }
        panel.sheetParent?.endSheet(panel)
        if let index = workspace.columns.firstIndex(where: { $0 === target && !$0.isClosing }) {
            focusWorkspace(id: workspace.id, column: index)
        }
        return nil
    }
}
