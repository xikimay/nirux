import AppKit

// MARK: - Merge queue (docs/project-board.md, sections 3.6 and 4)

/// The shell owns each project's merge queue, so a queue outlives the
/// board that shows it. It also tells a queue which agents are busy in a
/// pull request's worktrees, and fans the queue's changes out to the
/// board, the status bar, keep-awake and a quit waiting on it.
extension NiruxShellView {
    /// The project's merge queue, made the first time it is asked for.
    func mergeQueue(projectID: String) -> MergeQueueController {
        if let existing = mergeQueues[projectID] { return existing }
        let controller = MergeQueueController(
            projectID: projectID,
            client: mergeQueueClient ?? MergeQueue.client(),
            local: MergeQueueLocalAccess(
                folders: { [weak self] in self?.projectWorkspaces(of: projectID).map(\.cwd) ?? [] },
                busyAgents: { [weak self] worktrees, allWorktrees in
                    self?.mergeQueueBusyAgents(in: worktrees, allWorktrees: allWorktrees) ?? []
                }
            ),
            lockFolder: mergeQueueLockFolder
        )
        // One queue per repository in this Nirux; the lock covers the others.
        controller.isRepositoryBusy = { [weak self, weak controller] repository in
            guard let self else { return false }
            return self.mergeQueues.values.contains { $0 !== controller && $0.isRunning && $0.repository == repository }
        }
        controller.onChange = { [weak self] in self?.mergeQueueDidChange(projectID: projectID) }
        mergeQueues[projectID] = controller
        return controller
    }

    /// The agents working or waiting on a dialog in these worktrees (paths
    /// comparable): in any workspace open there, as the board's row counts
    /// them, or in another workspace's shell inside one, as the worktree
    /// clean-up counts foreign agents. "claude working in “api”".
    func mergeQueueBusyAgents(in worktrees: [String], allWorktrees: [String]) -> [String] {
        let snapshot = ProcessSnapshot()
        let now = Date().timeIntervalSince1970
        let isInside = { (folder: String?) -> Bool in
            guard let folder else { return false }
            return MergeQueue.isInside(Self.comparablePath(folder), roots: worktrees, allWorktrees: allWorktrees)
        }
        var busy: [String] = []
        for workspace in workspaces where !workspace.isClosing {
            let isMember = isInside(workspace.cwd)
            for column in workspace.openColumns where isMember || isInside(column.pty?.childCwd) {
                let foreground = column.pty?.foregroundProcess(snapshot: snapshot)
                let agent = projectBoardAgent(of: column, in: workspace, foreground: foreground, snapshot: snapshot, now: now)
                guard let label = MergeQueue.busyLabel(agent.state) else { continue }
                let name = column.pty?.agentProcessName(snapshot: snapshot) ?? "an agent"
                busy.append("\(name) \(label) in “\(workspace.title)”")
            }
        }
        return busy
    }

    /// Queues running in this Nirux, in sidebar order of their projects.
    var runningMergeQueues: [MergeQueueController] {
        sortedMergeQueues.filter(\.isRunning)
    }

    private var sortedMergeQueues: [MergeQueueController] {
        let order = profiles.map(\.id)
        return mergeQueues.values.sorted {
            (order.firstIndex(of: $0.projectID) ?? .max, $0.projectID) < (order.firstIndex(of: $1.projectID) ?? .max, $1.projectID)
        }
    }

    /// After every step of a queue, and every change to its list. A board
    /// out of sight draws when it shows again.
    func mergeQueueDidChange(projectID: String) {
        for location in projectBoardLocations where location.board.projectID == projectID
            && isProjectBoardShown(location.board) {
            renderProjectBoard(location.board)
        }
        updateMergeQueueStatusBar()
        keepAwake?.update(mergeQueueRunning: !runningMergeQueues.isEmpty)
        settleMergeQueueQuit()
    }

    // MARK: The board

    /// What the board shows of its project's queue; nil while it can't
    /// show one (no repository, a deleted project, board.json unread),
    /// unless a queue runs: its Stop stays in reach whatever board.json says.
    /// Only reads: `refreshMergeQueuesElsewhere` reads the saved file again.
    func projectBoardQueueState(_ board: ProjectBoardController) -> ProjectBoard.QueueState? {
        let existing = mergeQueues[board.projectID]
        let isActive = existing?.isRunning == true || existing?.runsElsewhere == true
        guard isActive || (board.repository != nil && board.loaded != nil && profiles.contains { $0.id == board.projectID })
        else { return nil }
        // Made once per project: it reads the saved queue.
        let controller = existing ?? mergeQueue(projectID: board.projectID)
        let repository = board.repository?.gitHub
        var state = ProjectBoard.QueueState(isDryRun: controller.isDryRun, dryRunReason: controller.dryRunReason)
        state.selection = controller.selection(for: repository)
        state.startProblems = board.loaded?.queueStartProblems ?? ["board.json isn’t read yet."]
        state.isConfirming = mergeQueueConfirmation != nil
        // The queue shown: running here, running elsewhere, or the last one.
        let shown: (entries: [MergeQueue.Entry], workflow: String?, repository: String)?
        if let engine = controller.engine, controller.isRunning {
            state.run = .running(isStopping: engine.phase == .stopping)
            state.status = engine.statusText
            shown = (engine.entries, engine.settings.postMergeWorkflow, engine.settings.repository)
        } else if controller.runsElsewhere, let saved = controller.saved {
            state.run = .elsewhere
            state.status = saved.statusText
            shown = (saved.entries, saved.postMergeWorkflow, saved.repository)
        } else if let engine = controller.engine {
            state.run = .ended
            state.status = engine.statusText
            if case .stopped(let reason) = engine.phase { state.statusIsFailure = reason.isProblem }
            shown = (engine.entries, engine.settings.postMergeWorkflow, engine.settings.repository)
        } else if let saved = controller.saved {
            state.run = .ended
            state.status = saved.statusText
            state.statusIsFailure = saved.status == .stopped && saved.stopReason?.isProblem != false
            shown = (saved.entries, saved.postMergeWorkflow, saved.repository)
        } else {
            shown = nil
        }
        if let shown {
            state.workflow = shown.workflow
            // Its numbers name other pull requests in another repository.
            if GitHubRepository(ownerAndName: shown.repository) == repository {
                state.entries = shown.entries
            } else {
                state.status = state.status.map { "\(shown.repository): \($0)" }
            }
        }
        return state
    }

    /// At each status refresh: a queue another Nirux runs is looked at
    /// again now and then (`reloadSavedIfStale`), outside any render.
    func refreshMergeQueuesElsewhere() {
        for controller in mergeQueues.values where controller.runsElsewhere {
            controller.reloadSavedIfStale()
        }
    }

    func addToMergeQueue(_ number: Int, board: ProjectBoardController) {
        if let busy = mergeQueueSelectionBusy { return showToast(busy) }
        guard let repository = board.repository?.gitHub else {
            return showToast("This board’s repository isn’t on GitHub")
        }
        mergeQueue(projectID: board.projectID).addToSelection(number, repository: repository)
    }

    func removeFromMergeQueue(_ number: Int, board: ProjectBoardController) {
        if let busy = mergeQueueSelectionBusy { return showToast(busy) }
        mergeQueue(projectID: board.projectID).removeFromSelection(number)
    }

    /// Why the queue's selection can't change now, if it can't.
    private var mergeQueueSelectionBusy: String? {
        if mergeQueueQuit != nil { return "Nirux is stopping the merge queue to quit" }
        if mergeQueueConfirmation != nil { return "Start or cancel the merge queue’s confirmation first" }
        return nil
    }

    /// Stop, from the board or the status bar: before the next command.
    func stopMergeQueue(projectID: String) {
        mergeQueues[projectID]?.stop()
    }

    /// Deleting a space whose queue runs would take its folders, and its
    /// board's Stop, away: stop the queue first.
    func refuseToDeleteSpaceWithRunningQueue(profileID: String) -> Bool {
        guard mergeQueues[profileID]?.isRunning == true else { return false }
        let alert = NSAlert()
        alert.messageText = "This space’s merge queue is running"
        alert.informativeText = "Stop it from the board or the status bar, then delete the space."
        runModal(alert)
        return true
    }

    // MARK: Start: the confirmation sheet

    /// Start: the sheet reads the queued pull requests on GitHub as they
    /// are now, then shows what will happen. Every Start opens a new one.
    func requestMergeQueueStart(board: ProjectBoardController) {
        // Already open: in front, which says it.
        if let open = mergeQueueConfirmation { return open.focus() }
        let controller = mergeQueue(projectID: board.projectID)
        guard mergeQueueQuit == nil else { return showToast("Nirux is stopping the merge queue to quit") }
        guard let loaded = board.loaded else { return showToast("The board is still loading") }
        guard let settings = loaded.queueSettings else {
            return showToast(loaded.queueStartProblems.first ?? "The board isn’t configured yet: open Board Settings…")
        }
        guard !controller.isRunning else { return showToast("The merge queue is already running") }
        guard !controller.runsElsewhere else { return showToast("Another Nirux runs this merge queue") }
        let numbers = controller.selection(for: settings.gitHubRepository)
        guard !numbers.isEmpty else { return showToast("Add pull requests to the queue first") }
        let panel = MergeQueueConfirmationPanel(
            projectID: board.projectID, isDryRun: controller.isDryRun, numbers: numbers, dryRunReason: controller.dryRunReason
        )
        panel.onStart = { [weak self, weak panel] confirmation in
            guard let self, let panel else { return }
            self.confirmMergeQueueStart(confirmation, panel: panel)
        }
        mergeQueueConfirmation = panel
        panel.show(attachedTo: window, repository: settings.repository, baseBranch: settings.baseBranch)
        renderMergeQueueBoards()
        let reading = controller.readConfirmation(settings: settings, numbers: numbers) { [weak panel, weak controller] reading in
            guard let panel, panel.isShown else { return }
            // Merged or closed: they can never join, and may have no row
            // left to remove them from.
            for candidate in reading.candidates where candidate.pullRequest.map({ !$0.isOpen }) == true {
                controller?.removeFromSelection(candidate.number)
            }
            panel.update(MergeQueue.confirmation(reading))
        }
        panel.onDismiss = { [weak self, weak panel] in
            // A sheet closed while it reads: the reads still to come don't run.
            reading.cancel()
            guard let self, let panel, self.mergeQueueConfirmation === panel else { return }
            self.mergeQueueConfirmation = nil
            self.renderMergeQueueBoards()
        }
    }

    /// The sheet's Start: with the settings it showed, which board.json
    /// must still hold, and its list in its order.
    func confirmMergeQueueStart(_ confirmation: MergeQueue.Confirmation, panel: MergeQueueConfirmationPanel) {
        guard confirmation.canStart else { return }
        guard mergeQueueQuit == nil else { return panel.showError("Nirux is quitting.") }
        guard profiles.contains(where: { $0.id == panel.projectID }) else {
            return panel.showError("This project was deleted.")
        }
        guard BoardConfigStore(spaceID: panel.projectID)?.load().queueSettings == confirmation.settings else {
            return panel.showError("Board Settings changed since this sheet read GitHub: Cancel, then Start again.")
        }
        let controller = mergeQueue(projectID: panel.projectID)
        guard controller.isDryRun == confirmation.isDryRun else { return panel.showError("Cancel, then Start again.") }
        if let refusal = controller.start(settings: confirmation.settings, entries: confirmation.entries) {
            return panel.showError(refusal.message)
        }
        dismissedMergeQueueNotices.remove(panel.projectID)
        panel.dismiss()
        mergeQueueDidChange(projectID: panel.projectID)
    }

    /// The boards on screen; the others draw when they show again.
    private func renderMergeQueueBoards() {
        for location in projectBoardLocations where isProjectBoardShown(location.board) {
            renderProjectBoard(location.board)
        }
    }

    // MARK: The status bar

    /// A running queue, with Stop; else one that ended this launch, until
    /// dismissed. A click shows its board.
    func updateMergeQueueStatusBar() {
        let queues = sortedMergeQueues
        let running = queues.filter(\.isRunning)
        // The last to end, so a newer stop never hides behind an older notice.
        let ended = queues.filter { !$0.isRunning && $0.engine != nil && !dismissedMergeQueueNotices.contains($0.projectID) }
            .max { ($0.saved?.savedAt ?? .distantPast) < ($1.saved?.savedAt ?? .distantPast) }
        guard let shown = running.first ?? ended, let engine = shown.engine else {
            return statusBar.showQueue(nil)
        }
        let projectID = shown.projectID
        let prefix = shown.isDryRun ? "Queue (dry run)" : "Queue"
        var text: String
        var isFailure = false
        switch engine.phase {
        case .idle, .running, .paused, .stopping:
            text = "\(prefix): \(engine.statusText)"
        case .stopped(let reason):
            text = "\(prefix) stopped: \(reason.message)"
            isFailure = reason.isProblem
        case .finished:
            text = "\(prefix) finished: \(engine.entries.filter { $0.step == .done }.count) merged"
        }
        if running.count > 1 { text += " (+\(running.count - 1) other queue\(running.count == 2 ? "" : "s"))" }
        // Stop reaches every running queue, not only the one shown.
        let stopsAll = running.count > 1
        let project = profiles.first { $0.id == projectID }?.name ?? "Deleted project"
        var notice = StatusBarView.QueueNotice(
            text: text,
            isRunning: shown.isRunning,
            // Stop All stays in reach while any queue isn't stopping yet.
            isStopping: stopsAll ? running.allSatisfy { $0.engine?.phase == .stopping } : engine.phase == .stopping,
            isDryRun: shown.isDryRun,
            isFailure: isFailure,
            stopsAll: stopsAll
        )
        notice.tooltip = "\(project) · \(engine.settings.repository) into \(engine.settings.baseBranch)\n\(text)\n"
            + "Click to show the project’s board."
            + (shown.isDryRun ? "\n" + ProjectBoardView.dryRunTooltip(reason: shown.dryRunReason) : "")
        statusBar.onQueueClick = { [weak self] in self?.showProjectBoard(projectID: projectID) }
        statusBar.onQueueStop = { [weak self] in
            guard let self else { return }
            if stopsAll {
                self.runningMergeQueues.forEach { $0.stop() }
            } else {
                self.stopMergeQueue(projectID: projectID)
            }
        }
        statusBar.onQueueDismiss = { [weak self] in
            guard let self else { return }
            self.dismissedMergeQueueNotices.insert(projectID)
            self.updateMergeQueueStatusBar()
        }
        statusBar.showQueue(notice)
    }

    /// Brings the project's board to the front, opening one in its first
    /// workspace if it has none.
    func showProjectBoard(projectID: String) {
        if let location = projectBoardLocation(projectID: projectID) {
            return focusProjectBoard(location)
        }
        guard let workspace = projectWorkspaces(of: projectID).first(where: { !$0.isInactive })
            ?? projectWorkspaces(of: projectID).first
        else { return showToast("This space has no workspace to open its board in") }
        focusWorkspace(id: workspace.id)
        guard activeWorkspace === workspace else { return showToast("Couldn’t open the board", tone: .error) }
        openProjectBoard()
    }

    // MARK: Quitting

    /// A quit while a queue runs: the question, then the wait for the
    /// queues to stop. Main thread only.
    @MainActor
    final class MergeQueueQuit {
        let reply: @MainActor (Bool) -> Void
        /// The user chose to stop the queues and quit.
        var isConfirmed = false
        var isAnswered = false

        init(reply: @escaping @MainActor (Bool) -> Void) {
            self.reply = reply
        }
    }

    /// A call already sent answers within the client's timeout (2 min);
    /// the quit doesn't wait longer than this (2.5 min).
    static let mergeQueueQuitTimeout: TimeInterval = GitHubCLIQueueClient.mutationTimeout + 30

    /// `applicationShouldTerminate`: while a queue runs, ask first
    /// (section 3.6), without a modal loop in the caller. On "Stop Queue
    /// and Quit", every queue stops before its next command; a call
    /// already sent is waited for, so the journal records its answer.
    /// `reply` gets the decision when this returns `.terminateLater`, never
    /// before it returns.
    func mergeQueueTerminateReply(reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        // The question is on screen, or a quit already waits for its queues.
        guard mergeQueueQuit == nil else { return .terminateCancel }
        guard !runningMergeQueues.isEmpty else { return .terminateNow }
        let quit = MergeQueueQuit(reply: reply)
        mergeQueueQuit = quit
        // After this returns: an answer that comes at once must not reach
        // AppKit before `.terminateLater` does. Through the run loop, which
        // AppKit's wait runs, not the main queue: a quit asked from a
        // main-queue block would never see a block of it (`requestQuit`).
        // The queues' own main-queue answers keep coming meanwhile.
        RunLoop.main.perform(inModes: [.default, .modalPanel]) { [weak self] in
            // On the main thread, which Swift 6.1 doesn't infer for this block.
            MainActor.assumeIsolated { self?.askToQuitWithMergeQueues(quit) }
        }
        return .terminateLater
    }

    /// The main window's close button quits Nirux. While a queue runs, the
    /// window stays, and the quit asks the one question of
    /// `mergeQueueTerminateReply`.
    func mainWindowShouldClose() -> Bool {
        guard !runningMergeQueues.isEmpty else { return true }
        // From the next turn of the run loop, after the close returns.
        sideEffects.requestQuit()
        return false
    }

    private func askToQuitWithMergeQueues(_ quit: MergeQueueQuit) {
        guard mergeQueueQuit === quit else { return }
        let running = runningMergeQueues
        guard !running.isEmpty else {
            // Ended meanwhile: nothing to ask.
            mergeQueueQuit = nil
            return answerMergeQueueQuit(quit, true)
        }
        let isDryRun = running.allSatisfy(\.isDryRun)
        let kind = isDryRun ? "dry-run merge queue" : "merge queue"
        let one = running.count == 1
        let message = one ? "A \(kind) is running" : "\(running.count) \(kind)s are running"
        var details = running.compactMap { controller -> String? in
            guard let engine = controller.engine else { return nil }
            return "\(engine.settings.repository): \(engine.statusText)"
        }
        details.append("")
        details.append(isDryRun
            ? "Quitting stops \(one ? "it" : "them") before the next command. A dry run sends nothing to GitHub: "
                + "nothing is left half done."
            : "Quitting stops \(one ? "the queue before its" : "the queues before their") next command. A merge or a "
                + "branch update already sent to GitHub finishes first: Nirux waits for its answer, "
                + "\(Int(Self.mergeQueueQuitTimeout)) seconds at most. Nothing resumes by itself at the "
                + "next launch: the board shows where \(one ? "it" : "each") stopped.")
        let confirm = one ? "Stop Queue and Quit" : "Stop Queues and Quit"
        sideEffects.confirmQuitWithMergeQueue(message, details.joined(separator: "\n"), confirm, window) { [weak self] confirmed in
            guard let self, self.mergeQueueQuit === quit else { return }
            guard confirmed else {
                self.mergeQueueQuit = nil
                return self.answerMergeQueueQuit(quit, false)
            }
            quit.isConfirmed = true
            // No new queue starts from here on.
            self.mergeQueueConfirmation?.dismiss()
            // A queue that stops at once answers through `settleMergeQueueQuit`.
            for controller in self.runningMergeQueues { controller.stop() }
            guard !self.runningMergeQueues.isEmpty else { return self.answerMergeQueueQuit(quit, true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.mergeQueueQuitTimeout) { [weak self] in
                guard let self, self.mergeQueueQuit === quit, !quit.isAnswered else { return }
                NiruxDebugLog.log("MergeQueue: quitting while a call already sent hasn’t answered")
                self.runningMergeQueues.forEach { $0.stop() }
                self.answerMergeQueueQuit(quit, true)
            }
        }
    }

    /// A queue changed: a confirmed quit goes on once none runs. (No queue
    /// starts once the quit is asked: Start refuses.)
    func settleMergeQueueQuit() {
        guard let quit = mergeQueueQuit, quit.isConfirmed, !quit.isAnswered, runningMergeQueues.isEmpty else { return }
        answerMergeQueueQuit(quit, true)
    }

    private func answerMergeQueueQuit(_ quit: MergeQueueQuit, _ confirmed: Bool) {
        guard !quit.isAnswered else { return }
        quit.isAnswered = true
        quit.reply(confirmed)
    }
}
