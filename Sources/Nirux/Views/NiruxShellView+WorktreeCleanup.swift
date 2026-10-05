import AppKit

// MARK: - Worktree Cleanup

/// "Clean Up Worktree…" in a workspace's ⋯ menu and "Clean Up Merged
/// Worktrees…" in the palette. `WorktreeCleanup` runs the checks and the
/// git commands; this side finds the workspaces open in each worktree and
/// the agents and editors inside it, confirms, and closes the workspaces
/// once the folder is gone.
extension NiruxShellView {
    /// The worktree a workspace's folder belongs to: the nearest folder up
    /// from `cwd` whose `.git` file points into a repository's `worktrees`
    /// (a linked worktree's). `cwd` itself when it's gone: only the
    /// workspace is left to close, even inside a worktree that's still
    /// there (it may have been a worktree of its own). Nil in a main
    /// checkout, a submodule or outside git. Reads a few files, so the
    /// sidebar can ask while building its menu.
    nonisolated static func worktreeCleanupPath(forCwd cwd: String) -> String? {
        guard cwd.hasPrefix("/") else { return nil }
        var url = URL(fileURLWithPath: cwd).standardizedFileURL
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return url.path }
        while true {
            let gitPath = url.appendingPathComponent(".git").path
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: gitPath, isDirectory: &isDirectory) {
                return !isDirectory.boolValue && pointsIntoWorktrees(gitFile: gitPath) ? url.path : nil
            }
            let parent = url.deletingLastPathComponent()
            guard url.path != "/", parent.path != url.path else { return nil }
            url = parent
        }
    }

    /// `gitdir: …/worktrees/<id>`, as `git worktree add` writes it; a
    /// submodule's points into `modules` instead.
    private nonisolated static func pointsIntoWorktrees(gitFile: String) -> Bool {
        guard let contents = try? String(contentsOfFile: gitFile, encoding: .utf8),
              contents.hasPrefix("gitdir: ")
        else { return false }
        let target = contents.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let components = target.split(separator: "/")
        return components.count >= 2 && components[components.count - 2] == "worktrees"
    }

    func offersWorktreeCleanup(workspaceIndex: Int) -> Bool {
        worktreeCleanupPath(workspaceIndex: workspaceIndex) != nil
    }

    /// What "Clean Up Worktree…" would clean up for this workspace.
    private func worktreeCleanupPath(workspaceIndex: Int) -> String? {
        guard let workspace = workspaces[safe: workspaceIndex], !workspace.isClosing else { return nil }
        return Self.worktreeCleanupPath(forCwd: workspace.cwd)
    }

    /// The card's "merged · Clean up": the ⋯ menu's offer, once the card
    /// shows the pull request merged. That pull request is the focused
    /// folder's branch's, while the clean-up removes the worktree of the
    /// workspace's folder: offered only when they are the same worktree,
    /// still on disk. Asked on every sidebar refresh, so the files are
    /// read only for a merged one.
    func mergedCleanupOffer(workspaceIndex: Int) -> MergedCleanupOffer? {
        guard let workspace = workspaces[safe: workspaceIndex],
              let pullRequest = workspace.prInfo, pullRequest.state == "MERGED", !pullRequest.isDraft,
              let repositoryRoot = workspace.gitContext?.identity.repositoryRoot,
              let path = worktreeCleanupPath(workspaceIndex: workspaceIndex),
              FileManager.default.fileExists(atPath: path)
        else { return nil }
        let key = Self.comparablePath(path)
        guard Self.comparablePath(repositoryRoot) == key else { return nil }
        return worktreeCleanupsInFlight.contains(key) ? .inProgress : .available
    }

    // MARK: Candidates

    /// Every workspace open at `path` or below it, with the agents closing
    /// them would end; agents of other workspaces running inside the
    /// folder; unsaved editors among them or on a file in it. Not
    /// inspected yet.
    func worktreeCleanupCandidate(path: String, snapshot: ProcessSnapshot = ProcessSnapshot()) -> WorktreeCleanupCandidate {
        let isInside = Self.containment(in: path)
        let open = workspaces.filter { !$0.isClosing }
        let members = open.filter { isInside($0.cwd) }
        let memberIDs = Set(members.map(\.id))
        var foreignAgents: [String] = []
        var unsavedEditors: [String] = []
        for workspace in open {
            let isMember = memberIDs.contains(workspace.id)
            if workspace.columns.contains(where: { column in
                guard let unsaved = column.editorColumn?.unsavedPaths, !unsaved.isEmpty else { return false }
                return isMember || unsaved.contains { isInside($0) }
            }) {
                unsavedEditors.append(workspace.title)
            }
            guard !isMember else { continue }
            // A restored agent not resumed yet resumes in its folder.
            for column in workspace.openColumns where isInside(column.pty?.childCwd ?? column.awaitingResumeDirectory) {
                if let agent = column.liveAgent(snapshot: snapshot) {
                    let name = agent.isPaused ? "\(agent.displayName) (paused)" : agent.displayName
                    foreignAgents.append("\(name) in “\(workspace.title)”")
                }
            }
        }
        return WorktreeCleanupCandidate(
            path: path,
            workspaces: members.map { WorktreeCleanupCandidate.Workspace(id: $0.id, title: $0.title) },
            agents: members.flatMap { $0.openColumns.compactMap { $0.liveAgent(snapshot: snapshot) } },
            foreignAgents: foreignAgents,
            unsavedEditors: unsavedEditors,
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

    nonisolated static func comparablePath(_ path: String) -> String {
        path.realPath ?? URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Whether a path is `root` or inside it, symlinks resolved.
    private nonisolated static func containment(in root: String) -> (String?) -> Bool {
        let resolvedRoot = comparablePath(root)
        return { candidate in
            guard let candidate else { return false }
            // The Project Board places workspaces by the same rule.
            return ProjectBoard.contains(resolvedRoot, comparablePath(candidate))
        }
    }

    // MARK: Single workspace

    /// The ⋯ menu's "Clean Up Worktree…": check, then say why not or
    /// confirm exactly what goes. Nothing is deleted without that click.
    func requestWorktreeCleanup(workspaceIndex: Int) {
        guard let path = worktreeCleanupPath(workspaceIndex: workspaceIndex) else { return }
        requestWorktreeCleanup(path: path)
    }

    /// The same for a worktree named by its folder, which may have no
    /// workspace: the Project Board's "Clean Up…".
    func requestWorktreeCleanup(path: String) {
        let key = Self.comparablePath(path)
        guard worktreeCleanupsInFlight.insert(key).inserted else {
            return showToast("A clean-up of this worktree is already in progress")
        }
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
                let kept = closeWorkspacesAfterCleanup(of: candidate)
                if !kept.isEmpty { showKeptOpenNotice(kept) }
            }
            completion()
        case .ready(let plan, _):
            guard confirmDestructiveClose(
                message: "Clean up worktree “\(plan.branch)”?",
                details: candidate.confirmationLines(for: plan),
                confirmTitle: "Clean Up"
            ) else { return completion() }
            Self.stoppingExplains(in: plan.worktree.path) { resumeExplains in
                DispatchQueue.global(qos: .userInitiated).async {
                    let execution = WorktreeCleanup.execute(plan)
                    DispatchQueue.main.async { [weak self] in
                        defer {
                            resumeExplains()
                            completion()
                        }
                        guard let self else { return }
                        self.reportWorktreeCleanup(execution, of: candidate, plan: plan)
                    }
                }
            }
        }
    }

    /// Clean Up deletes the branch's review file once the branch is gone:
    /// an Explain of the worktree must not end after and create it again.
    /// `body` runs once the worktree's Explain is stopped, and gets the
    /// closure that lets the worktree take Explain runs again.
    static func stoppingExplains(
        in worktree: String, queue: ExplainQueue = .shared,
        _ body: @escaping @MainActor (_ resume: @escaping @MainActor () -> Void) -> Void
    ) {
        let key = ExplainQueue.worktreeKey(worktree)
        queue.stop(worktree: key) {
            body { queue.resume(worktree: key) }
        }
    }

    private func reportWorktreeCleanup(
        _ execution: WorktreeCleanup.Execution, of candidate: WorktreeCleanupCandidate, plan: WorktreeCleanup.Plan
    ) {
        let outcome = finishWorktreeCleanup(execution, of: candidate, plan: plan)
        if !outcome.succeeded {
            let kept = outcome.keptOpen.isEmpty ? [] : [Self.keptOpenText(outcome.keptOpen) + "."]
            showWorktreeCleanupNotice(message: "Clean-up of \(plan.branch) stopped", lines: [outcome.message] + kept)
        } else if !outcome.keptOpen.isEmpty {
            showKeptOpenNotice(outcome.keptOpen)
        }
    }

    private struct CleanupOutcome {
        let succeeded: Bool
        let message: String
        /// Workspaces left open for their unsaved editors.
        let keptOpen: [String]
    }

    /// Closes the workspaces once the folder is gone, and words the result.
    private func finishWorktreeCleanup(
        _ execution: WorktreeCleanup.Execution, of candidate: WorktreeCleanupCandidate, plan: WorktreeCleanup.Plan
    ) -> CleanupOutcome {
        defer { expireProjectBoardWorktrees() }
        switch execution {
        case .cleaned(let forced, let trashFolder):
            let kept = closeWorkspacesAfterCleanup(of: candidate)
            var message = "Folder and branch \(plan.branch) deleted"
            if forced { message += " (squash merge: -D)" }
            if let trashFolder { message += ", leftovers in the Trash (“\(trashFolder)”)" }
            return CleanupOutcome(succeeded: true, message: message, keptOpen: kept)
        case .branchKept(let reason, let trashFolder):
            let kept = closeWorkspacesAfterCleanup(of: candidate)
            let trashNote = trashFolder.map { "\nIts leftovers are in the Trash (“\($0)”)." } ?? ""
            return CleanupOutcome(succeeded: false, message: reason + trashNote, keptOpen: kept)
        case .failed(let reason):
            return CleanupOutcome(succeeded: false, message: reason, keptOpen: [])
        }
    }

    // MARK: Bulk

    /// The palette's "Clean Up Merged Worktrees…".
    func showWorktreeCleanupPanel() {
        guard let window else { return }
        if let panel = worktreeCleanupPanel {
            panel.focus()
            return
        }
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
        panel.onDismiss = { [weak self, weak panel] in
            queue.cancelAllOperations()
            guard let self else { return }
            if self.worktreeCleanupPanel === panel { self.worktreeCleanupPanel = nil }
            self.focusActiveTerminal(in: self.window)
        }
        let candidates = worktreeCleanupCandidates()
        panel.show(attachedTo: window, candidates: candidates)
        for candidate in candidates { inspectForPanel(candidate.path, panel: panel, queue: queue) }
        // Workspaces in a main checkout lead to its worktrees too.
        let otherFolders = Set(workspaces.filter { !$0.isClosing }.map(\.cwd))
            .filter { Self.worktreeCleanupPath(forCwd: $0) == nil }
        for folder in otherFolders { addUnopenedWorktrees(listedFrom: folder, to: panel, queue: queue) }
    }

    /// Runs `work` on `queue`, never on the main actor. A closure written
    /// inside this `@MainActor` view and passed straight to `addOperation`
    /// was compiled as `@MainActor @Sendable` by the Swift 6.1 toolchain
    /// that builds the nightly (Xcode 16.4), even though the SDK marks that
    /// block Sendable, and Swift 6 trapped when the queue ran it off the
    /// main thread. Swift 6.2 does not, so local runs can't show it. Taking
    /// the closure through this nonisolated function's `@Sendable`
    /// parameter keeps it nonisolated on both toolchains. Don't read
    /// "Sendable" on an imported callback as a guarantee.
    nonisolated private static func runOffMain(on queue: OperationQueue, _ work: @escaping @Sendable () -> Void) {
        queue.addOperation(work)
    }

    private func inspectForPanel(_ path: String, panel: WorktreeCleanupPanel, queue: OperationQueue) {
        Self.runOffMain(on: queue) {
            let inspection = WorktreeCleanup.inspect(path: path)
            DispatchQueue.main.async { @MainActor [weak self, weak panel] in
                guard let self, let panel else { return }
                panel.update(path: path, inspection: inspection)
                if case .inspected(let report) = inspection {
                    self.addUnopenedWorktrees(listedFrom: report.worktree.mainCheckout, to: panel, queue: queue)
                }
            }
        }
    }

    /// Worktrees of the repository `directory` is in that no workspace is
    /// open in: listed too, since they are the stale ones, but never
    /// preselected.
    private func addUnopenedWorktrees(listedFrom directory: String, to panel: WorktreeCleanupPanel, queue: OperationQueue) {
        guard panel.markFolderScanned(directory) else { return }
        Self.runOffMain(on: queue) {
            let listing = WorktreeCleanup.worktreeListing(in: directory, tools: .installed) ?? []
            // The first entry is the main checkout; a folder already gone
            // is for `git worktree prune`, not for this.
            let paths = listing.dropFirst().map(\.path).filter { $0.realPath != nil }
            let repository = listing.first.map { Self.comparablePath($0.path) }
            DispatchQueue.main.async { @MainActor [weak self, weak panel] in
                guard let self, let panel, panel.acceptsNewRows,
                      let repository, panel.markRepositoryScanned(repository)
                else { return }
                let snapshot = ProcessSnapshot()
                for path in paths where !panel.contains(comparablePath: Self.comparablePath(path)) {
                    panel.append(self.worktreeCleanupCandidate(path: path, snapshot: snapshot))
                    self.inspectForPanel(path, panel: panel, queue: queue)
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
        panel.isConfirming = true
        let confirmed = confirmDestructiveClose(
            message: count == 1 ? "Clean up 1 worktree?" : "Clean up \(count) worktrees?",
            details: WorktreeCleanupCandidate.summaryLines(for: runnable),
            confirmTitle: "Clean Up"
        )
        panel.isConfirming = false
        guard confirmed else { return }
        panel.beginRun()
        // Every worktree's Explain stops now, not when its row comes: one
        // waiting behind another's would start meanwhile, and be paid for
        // in vain. Each row still waits for its own to end.
        let worktrees = runnable.compactMap { candidate -> String? in
            if case .ready(let plan, _) = candidate.availability { return ExplainQueue.worktreeKey(plan.worktree.path) }
            return nil
        }
        for worktree in worktrees { ExplainQueue.shared.stop(worktree: worktree) {} }
        runWorktreeCleanups(runnable[...], in: panel) {
            for worktree in worktrees { ExplainQueue.shared.resume(worktree: worktree) }
        }
    }

    /// One after the other, reporting on each row; a failure stops only
    /// that worktree, whose row keeps git's output. Stop ends the run
    /// after the worktree in progress.
    private func runWorktreeCleanups(
        _ queue: ArraySlice<WorktreeCleanupCandidate>, in panel: WorktreeCleanupPanel, finished: @escaping @MainActor () -> Void
    ) {
        guard let candidate = queue.first else {
            finished()
            return panel.finishRun()
        }
        let rest = queue.dropFirst()
        guard !panel.stopRequested else {
            for skipped in queue { panel.setResult(.skipped("Not run: stopped"), for: skipped.path) }
            finished()
            return panel.finishRun()
        }
        panel.setResult(.running, for: candidate.path)
        switch candidate.availability {
        case .closeOnly:
            let kept = closeWorkspacesAfterCleanup(of: candidate)
            panel.setResult(kept.isEmpty ? .done("Workspace closed") : .skipped(Self.keptOpenText(kept)), for: candidate.path)
            runWorktreeCleanups(rest, in: panel, finished: finished)
        case .ready(let plan, _):
            // A "Clean Up Worktree…" of the same folder may still be running.
            let key = Self.comparablePath(candidate.path)
            guard worktreeCleanupsInFlight.insert(key).inserted else {
                panel.setResult(.skipped("Not run: another clean-up of it is in progress"), for: candidate.path)
                return runWorktreeCleanups(rest, in: panel, finished: finished)
            }
            Self.stoppingExplains(in: plan.worktree.path) { resumeExplains in
                DispatchQueue.global(qos: .userInitiated).async {
                    let execution = WorktreeCleanup.execute(plan)
                    DispatchQueue.main.async { [weak self, weak panel] in
                        resumeExplains()
                        guard let self else { return finished() }
                        self.worktreeCleanupsInFlight.remove(key)
                        let outcome = self.finishWorktreeCleanup(execution, of: candidate, plan: plan)
                        guard let panel else { return finished() }
                        let keptNote = outcome.keptOpen.isEmpty ? "" : ". \(Self.keptOpenText(outcome.keptOpen))"
                        panel.setResult(
                            outcome.succeeded ? .done(outcome.message + keptNote) : .failed(outcome.message + keptNote),
                            for: candidate.path
                        )
                        self.runWorktreeCleanups(rest, in: panel, finished: finished)
                    }
                }
            }
        case .checking, .blocked:
            panel.setResult(.skipped("Not run: no longer ready"), for: candidate.path)
            runWorktreeCleanups(rest, in: panel, finished: finished)
        }
    }

    // MARK: Closing

    /// Closes the workspaces open in the cleaned-up folder, without asking
    /// again: those confirmed, and any opened there since. One with an
    /// editor holding unsaved changes stays open, its buffer the only copy
    /// left; their titles are returned. Nirux keeps one workspace open: a
    /// fresh one in the home folder takes over if none would be left.
    @discardableResult
    func closeWorkspacesAfterCleanup(of candidate: WorktreeCleanupCandidate) -> [String] {
        let isInside = Self.containment(in: candidate.path)
        let ids = Set(candidate.workspaceIDs)
        let affected = workspaces.filter { !$0.isClosing && (ids.contains($0.id) || isInside($0.cwd)) }
        let kept = affected.filter { $0.columns.contains { !($0.editorColumn?.unsavedPaths.isEmpty ?? true) } }
        let closing = affected.filter { workspace in !kept.contains { $0 === workspace } }
        guard !closing.isEmpty else { return kept.map(\.title) }
        if workspaceStore.remainingWorkspaceCount <= closing.count {
            addWorkspace(cwd: sideEffects.homeDirectory())
        }
        // The selected one last: its successor is then picked among the
        // workspaces left, in one hop.
        let selected = activeWorkspace
        let selectedLast = closing.filter { $0 !== selected } + closing.filter { $0 === selected }
        for workspace in selectedLast {
            guard let index = workspaces.firstIndex(where: { $0 === workspace }) else { continue }
            closeWorkspace(at: index)
        }
        // After the close animation takes them out of the store.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.saveState()
        }
        return kept.map(\.title)
    }

    private static func keptOpenText(_ titles: [String]) -> String {
        "Kept open for unsaved editor changes: \(WorktreeCleanupCandidate.quotedList(titles))"
    }

    private func showKeptOpenNotice(_ titles: [String]) {
        showWorktreeCleanupNotice(
            message: "Some workspaces stayed open",
            lines: [Self.keptOpenText(titles) + ". Their folder is gone: save the changes elsewhere."]
        )
    }

    private func showWorktreeCleanupNotice(message: String, lines: [String]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        runModal(alert)
    }
}
