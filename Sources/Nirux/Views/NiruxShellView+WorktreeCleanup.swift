import AppKit

// MARK: - Worktree Cleanup

/// "Clean Up Worktree…" in a workspace's ⋯ menu and "Clean Up Merged
/// Worktrees…" in the palette. `WorktreeCleanup` runs the checks and the
/// git commands; this side finds the workspaces open in each worktree,
/// confirms, and closes them once the folder and the branch are gone.
extension NiruxShellView {
    /// The worktree a workspace's folder belongs to: the nearest folder up
    /// from `cwd` holding a `.git` *file* (a linked worktree's), or `cwd`
    /// itself when it's gone, leaving only the workspace to close. Nil in
    /// a main checkout (its `.git` is a folder) or outside git. Filesystem
    /// checks only, so the sidebar can ask while building its menu.
    nonisolated static func worktreeCleanupPath(forCwd cwd: String) -> String? {
        guard cwd.hasPrefix("/") else { return nil }
        var url = URL(fileURLWithPath: cwd).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return url.path }
        while true {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? nil : url.path
            }
            let parent = url.deletingLastPathComponent()
            guard url.path != "/", parent.path != url.path else { return nil }
            url = parent
        }
    }

    func offersWorktreeCleanup(workspaceIndex: Int) -> Bool {
        guard let workspace = workspaces[safe: workspaceIndex], !workspace.isClosing else { return false }
        return Self.worktreeCleanupPath(forCwd: workspace.cwd) != nil
    }

    // MARK: Candidates

    /// Every workspace open at `path` or below it, with the agents closing
    /// them would end and their unsaved editors. Not inspected yet.
    func worktreeCleanupCandidate(path: String, snapshot: ProcessSnapshot = ProcessSnapshot()) -> WorktreeCleanupCandidate {
        let root = Self.comparablePath(path)
        let members = workspaces.filter { workspace in
            guard !workspace.isClosing else { return false }
            let cwd = Self.comparablePath(workspace.cwd)
            return cwd == root || cwd.hasPrefix(root + "/")
        }
        return WorktreeCleanupCandidate(
            path: path,
            workspaces: members.map { WorktreeCleanupCandidate.Workspace(id: $0.id, title: $0.title) },
            agents: members.flatMap { $0.openColumns.compactMap { $0.liveAgent(snapshot: snapshot) } },
            unsavedEditors: members.filter { $0.columns.contains { $0.editorColumn?.isDirty == true } }.map(\.title),
            inspection: nil
        )
    }

    /// One candidate per worktree, or missing folder, that a workspace in
    /// any space is open in, in sidebar order.
    func worktreeCleanupCandidates() -> [WorktreeCleanupCandidate] {
        let snapshot = ProcessSnapshot()
        var candidates: [WorktreeCleanupCandidate] = []
        var covered: Set<String> = []
        for workspace in workspaces where !workspace.isClosing && !covered.contains(workspace.id) {
            guard let path = Self.worktreeCleanupPath(forCwd: workspace.cwd) else { continue }
            let candidate = worktreeCleanupCandidate(path: path, snapshot: snapshot)
            covered.formUnion(candidate.workspaceIDs)
            candidates.append(candidate)
        }
        return candidates
    }

    /// Workspaces, agents and editors read again, keeping the inspection:
    /// the confirmation must list what closing kills right now.
    private func refreshed(_ candidate: WorktreeCleanupCandidate, snapshot: ProcessSnapshot) -> WorktreeCleanupCandidate {
        var current = worktreeCleanupCandidate(path: candidate.path, snapshot: snapshot)
        current.inspection = candidate.inspection
        return current
    }

    private static func comparablePath(_ path: String) -> String {
        path.realPath ?? URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // MARK: Single workspace

    /// The ⋯ menu's "Clean Up Worktree…": check, then say why not or
    /// confirm exactly what goes. Nothing is deleted without that click.
    func requestWorktreeCleanup(workspaceIndex: Int) {
        guard let workspace = workspaces[safe: workspaceIndex], !workspace.isClosing,
              let path = Self.worktreeCleanupPath(forCwd: workspace.cwd)
        else { return }
        let key = Self.comparablePath(path)
        guard worktreeCleanupsInFlight.insert(key).inserted else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let inspection = WorktreeCleanup.inspect(path: path)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var candidate = self.worktreeCleanupCandidate(path: path)
                candidate.inspection = inspection
                self.presentWorktreeCleanup(candidate) { [weak self] in
                    self?.worktreeCleanupsInFlight.remove(key)
                }
            }
        }
    }

    private func presentWorktreeCleanup(
        _ candidate: WorktreeCleanupCandidate, completion: @escaping @MainActor @Sendable () -> Void
    ) {
        switch candidate.availability {
        case .checking:
            completion()
        case .blocked(let problems):
            showWorktreeCleanupNotice(message: "Can’t clean up \(candidate.title)", lines: problems)
            completion()
        case .closeOnly:
            if confirmDestructiveClose(
                message: "The folder of “\(candidate.workspaces.first?.title ?? candidate.title)” is gone",
                details: candidate.closeOnlyLines(),
                confirmTitle: "Close Workspace"
            ) {
                closeWorkspacesAfterCleanup(candidate.workspaceIDs)
            }
            completion()
        case .ready(let plan, _):
            guard confirmDestructiveClose(
                message: "Clean up worktree “\(plan.branch)”?",
                details: candidate.confirmationLines(for: plan),
                confirmTitle: "Clean Up"
            ) else { return completion() }
            DispatchQueue.global(qos: .userInitiated).async {
                let execution = WorktreeCleanup.execute(plan)
                DispatchQueue.main.async { [weak self] in
                    defer { completion() }
                    guard let self else { return }
                    switch execution {
                    case .cleaned:
                        self.closeWorkspacesAfterCleanup(candidate.workspaceIDs)
                    case .failed(let message):
                        self.showWorktreeCleanupNotice(message: "Clean-up of \(plan.branch) stopped", lines: [message])
                    }
                }
            }
        }
    }

    // MARK: Bulk

    /// The palette's "Clean Up Merged Worktrees…".
    func showWorktreeCleanupPanel() {
        guard let window else { return }
        if let panel = worktreeCleanupPanel, panel.isVisible {
            panel.focus()
            return
        }
        let candidates = worktreeCleanupCandidates()
        let panel = WorktreeCleanupPanel()
        worktreeCleanupPanel = panel
        // gh and git per worktree, a few at a time.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        panel.onCleanUp = { [weak self, weak panel] selected in
            guard let self, let panel else { return }
            self.confirmBulkWorktreeCleanup(selected, in: panel)
        }
        panel.onDismiss = { [weak self] in
            queue.cancelAllOperations()
            self?.worktreeCleanupPanel = nil
            self?.focusActiveTerminal(in: self?.window)
        }
        panel.show(attachedTo: window, candidates: candidates)
        for path in candidates.map(\.path) {
            queue.addOperation {
                let inspection = WorktreeCleanup.inspect(path: path)
                DispatchQueue.main.async { [weak panel] in
                    panel?.update(path: path, inspection: inspection)
                }
            }
        }
    }

    private func confirmBulkWorktreeCleanup(_ selected: [WorktreeCleanupCandidate], in panel: WorktreeCleanupPanel) {
        let snapshot = ProcessSnapshot()
        let current = selected.map { refreshed($0, snapshot: snapshot) }
        current.forEach(panel.replace)
        let runnable = current.filter(WorktreeCleanupPanel.isSelectable)
        guard !runnable.isEmpty else { return }
        let count = runnable.count
        guard confirmDestructiveClose(
            message: count == 1 ? "Clean up 1 worktree?" : "Clean up \(count) worktrees?",
            details: WorktreeCleanupCandidate.summaryLines(for: runnable),
            confirmTitle: "Clean Up"
        ) else { return }
        panel.beginRun()
        runWorktreeCleanups(runnable[...], in: panel)
    }

    /// One after the other, reporting on each row; a failure stops only
    /// that worktree, whose row keeps git's output.
    private func runWorktreeCleanups(_ queue: ArraySlice<WorktreeCleanupCandidate>, in panel: WorktreeCleanupPanel) {
        guard let candidate = queue.first else {
            panel.finishRun()
            return
        }
        let rest = queue.dropFirst()
        panel.setResult(.running, for: candidate.path)
        switch candidate.availability {
        case .closeOnly:
            closeWorkspacesAfterCleanup(candidate.workspaceIDs)
            panel.setResult(.done("Workspace closed"), for: candidate.path)
            runWorktreeCleanups(rest, in: panel)
        case .ready(let plan, _):
            DispatchQueue.global(qos: .userInitiated).async {
                let execution = WorktreeCleanup.execute(plan)
                DispatchQueue.main.async { [weak self, weak panel] in
                    guard let self, let panel else { return }
                    switch execution {
                    case .cleaned(let forced):
                        self.closeWorkspacesAfterCleanup(candidate.workspaceIDs)
                        let branchNote = forced ? " (squash merge: deleted with -D)" : ""
                        panel.setResult(.done("Folder and branch \(plan.branch) deleted\(branchNote)"), for: candidate.path)
                    case .failed(let message):
                        panel.setResult(.failed(message), for: candidate.path)
                    }
                    self.runWorktreeCleanups(rest, in: panel)
                }
            }
        case .checking, .blocked:
            panel.setResult(.skipped("Skipped: no longer ready"), for: candidate.path)
            runWorktreeCleanups(rest, in: panel)
        }
    }

    // MARK: Closing

    /// Closes the workspaces a cleaned-up worktree held, without asking
    /// again. Nirux keeps one workspace open: a fresh one in the home
    /// folder takes over if none would be left.
    func closeWorkspacesAfterCleanup(_ ids: [String]) {
        let closing = workspaces.filter { ids.contains($0.id) && !$0.isClosing }
        guard !closing.isEmpty else { return }
        if workspaceStore.remainingWorkspaceCount <= closing.count {
            addWorkspace(cwd: NSHomeDirectory())
        }
        for workspace in closing {
            guard let index = workspaces.firstIndex(where: { $0 === workspace }) else { continue }
            closeWorkspace(at: index)
        }
        // After the close animation takes them out of the store.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.saveState()
        }
    }

    private func showWorktreeCleanupNotice(message: String, lines: [String]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
