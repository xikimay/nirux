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

    /// After every step of a queue, and every change to its list.
    func mergeQueueDidChange(projectID: String) {
        for location in projectBoardLocations where location.board.projectID == projectID {
            renderProjectBoard(location.board)
        }
        updateMergeQueueStatusBar()
        keepAwake?.update(mergeQueueRunning: !runningMergeQueues.isEmpty)
        settleMergeQueueQuit()
    }

    // MARK: The board

    /// What the board shows of its project's queue; nil while it can't
    /// show one (no repository, a deleted project, board.json unread).
    func projectBoardQueueState(_ board: ProjectBoardController) -> ProjectBoard.QueueState? {
        guard board.repository != nil, let loaded = board.loaded, profiles.contains(where: { $0.id == board.projectID })
        else { return nil }
        let controller = mergeQueue(projectID: board.projectID)
        controller.reloadSavedIfStale()
        var state = ProjectBoard.QueueState(isDryRun: controller.isDryRun)
        state.selection = controller.selection
        state.startProblems = loaded.queueStartProblems
        state.isConfirming = mergeQueueConfirmation != nil
        if let engine = controller.engine, controller.isRunning {
            state.run = .running(isStopping: engine.phase == .stopping)
            state.status = engine.statusText
            state.entries = engine.entries
            state.workflow = engine.settings.postMergeWorkflow
        } else if controller.runsElsewhere, let saved = controller.saved {
            state.run = .elsewhere
            state.status = saved.statusText
            state.entries = saved.entries
            state.workflow = saved.postMergeWorkflow
        } else if let engine = controller.engine {
            state.run = .ended
            state.status = engine.statusText
            if case .stopped(let reason) = engine.phase { state.statusIsFailure = reason.isProblem }
            state.entries = engine.entries
            state.workflow = engine.settings.postMergeWorkflow
        } else if let saved = controller.saved {
            state.run = .ended
            state.status = saved.statusText
            state.statusIsFailure = saved.status == .stopped && saved.stopReason?.isProblem != false
            state.entries = saved.entries
            state.workflow = saved.postMergeWorkflow
        }
        return state
    }

    func addToMergeQueue(_ number: Int, board: ProjectBoardController) {
        mergeQueue(projectID: board.projectID).addToSelection(number)
    }

    func removeFromMergeQueue(_ number: Int, board: ProjectBoardController) {
        mergeQueue(projectID: board.projectID).removeFromSelection(number)
    }

    /// Stop, from the board or the status bar: before the next command.
    func stopMergeQueue(projectID: String) {
        mergeQueues[projectID]?.stop()
    }

    // MARK: Start: the confirmation sheet

    /// Start: the sheet reads the queued pull requests on GitHub as they
    /// are now, then shows what will happen. Every Start opens a new one.
    func requestMergeQueueStart(board: ProjectBoardController) {
        if let open = mergeQueueConfirmation {
            open.focus()
            return NSSound.beep()
        }
        let controller = mergeQueue(projectID: board.projectID)
        guard let settings = board.loaded?.queueSettings, !controller.isRunning, !controller.runsElsewhere,
              !controller.selection.isEmpty
        else { return NSSound.beep() }
        let panel = MergeQueueConfirmationPanel(
            projectID: board.projectID, isDryRun: controller.isDryRun, numbers: controller.selection
        )
        panel.onStart = { [weak self, weak panel] confirmation in
            guard let self, let panel else { return }
            self.confirmMergeQueueStart(confirmation, panel: panel)
        }
        panel.onDismiss = { [weak self, weak panel] in
            guard let self, let panel, self.mergeQueueConfirmation === panel else { return }
            self.mergeQueueConfirmation = nil
            self.renderMergeQueueBoards()
        }
        mergeQueueConfirmation = panel
        panel.show(attachedTo: window, repository: settings.repository, baseBranch: settings.baseBranch)
        renderMergeQueueBoards()
        controller.readConfirmation(settings: settings, numbers: controller.selection) { [weak panel] reading in
            guard let panel, panel.isShown else { return }
            panel.update(MergeQueue.confirmation(reading))
        }
    }

    /// The sheet's Start: with the settings it showed, which board.json
    /// must still hold, and its list in its order.
    func confirmMergeQueueStart(_ confirmation: MergeQueue.Confirmation, panel: MergeQueueConfirmationPanel) {
        guard confirmation.canStart else { return }
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

    private func renderMergeQueueBoards() {
        for location in projectBoardLocations { renderProjectBoard(location.board) }
    }

    // MARK: The status bar

    /// A running queue, with Stop; else one that ended this launch, until
    /// dismissed. A click shows its board.
    func updateMergeQueueStatusBar() {
        let queues = sortedMergeQueues
        let running = queues.filter(\.isRunning)
        let ended = queues.filter { !$0.isRunning && $0.engine != nil && !dismissedMergeQueueNotices.contains($0.projectID) }
        guard let shown = running.first ?? ended.first, let engine = shown.engine else {
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
        let project = profiles.first { $0.id == projectID }?.name ?? "Deleted project"
        var notice = StatusBarView.QueueNotice(
            text: text,
            isRunning: shown.isRunning,
            isStopping: engine.phase == .stopping,
            isDryRun: shown.isDryRun,
            isFailure: isFailure
        )
        notice.tooltip = "\(project) · \(engine.settings.repository) into \(engine.settings.baseBranch)\n\(text)\n"
            + "Click to show the project’s board." + (shown.isDryRun ? "\n" + ProjectBoardView.dryRunTooltip : "")
        statusBar.onQueueClick = { [weak self] in self?.showProjectBoard(projectID: projectID) }
        statusBar.onQueueStop = { [weak self] in self?.stopMergeQueue(projectID: projectID) }
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
        else { return NSSound.beep() }
        focusWorkspace(id: workspace.id)
        guard activeWorkspace === workspace else { return NSSound.beep() }
        openProjectBoard()
    }

    // MARK: Quitting

    /// A quit while a queue runs: the question, then the wait for the
    /// queues to stop.
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
    /// the quit doesn't wait longer than this.
    static let mergeQueueQuitTimeout: TimeInterval = GitHubCLIQueueClient.mutationTimeout + 30

    /// `applicationShouldTerminate`: while a queue runs, ask first
    /// (section 3.6), without a modal loop in the caller. On "Stop Queue
    /// and Quit", every queue stops before its next command; a call
    /// already sent is waited for, so the journal records its answer.
    /// `reply` gets the decision when this returns `.terminateLater`, never
    /// before it returns.
    func mergeQueueTerminateReply(reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        if let pending = mergeQueueQuit {
            // The question is on screen, or a quit already waits.
            guard pending.isConfirmed, pending.isAnswered else { return .terminateCancel }
            // The window's close button asked, and the user said quit.
            mergeQueueQuit = nil
            return stopMergeQueuesForQuit(reply: reply)
        }
        guard !runningMergeQueues.isEmpty else { return .terminateNow }
        let quit = MergeQueueQuit(reply: reply)
        mergeQueueQuit = quit
        // After this returns: an answer that comes at once must not reach
        // AppKit before `.terminateLater` does.
        DispatchQueue.main.async { [weak self] in
            self?.askToQuitWithMergeQueues(quit)
        }
        return .terminateLater
    }

    /// The main window's close button quits Nirux: while a queue runs, it
    /// asks the same question and returns false. On yes, `quit` runs, and
    /// the quit that follows doesn't ask again.
    func confirmCloseWithMergeQueues(then quit: @escaping @MainActor () -> Void) -> Bool {
        guard !runningMergeQueues.isEmpty else { return true }
        guard mergeQueueQuit == nil else { return false }
        let pending = MergeQueueQuit { confirmed in
            if confirmed { quit() }
        }
        mergeQueueQuit = pending
        askToQuitWithMergeQueues(pending, closesWindow: true)
        return false
    }

    private func askToQuitWithMergeQueues(_ quit: MergeQueueQuit, closesWindow: Bool = false) {
        let running = runningMergeQueues
        guard mergeQueueQuit === quit else { return }
        guard !running.isEmpty else {
            // Ended meanwhile: nothing to ask.
            quit.isConfirmed = true
            if !closesWindow { mergeQueueQuit = nil }
            return answerMergeQueueQuit(quit, true)
        }
        let isDryRun = running.allSatisfy(\.isDryRun)
        let message = (running.count == 1 ? "A \(isDryRun ? "dry-run " : "")merge queue is running"
            : "\(running.count) merge queues are running") + (closesWindow ? ": closing the window quits Nirux" : "")
        var details = running.compactMap { controller -> String? in
            guard let engine = controller.engine else { return nil }
            return "\(engine.settings.repository): \(engine.statusText)"
        }
        details.append("")
        details.append("Quitting stops the queue before its next command. A merge or a branch update already sent to "
            + "GitHub finishes first, which may take up to 2 minutes. Nothing resumes by itself at the next launch: "
            + "the board shows where it stopped.")
        sideEffects.confirmQuitWithMergeQueue(message, details.joined(separator: "\n"), window) { [weak self] confirmed in
            guard let self, self.mergeQueueQuit === quit else { return }
            guard confirmed else {
                self.mergeQueueQuit = nil
                return self.answerMergeQueueQuit(quit, false)
            }
            quit.isConfirmed = true
            // The window's close button: the quit that follows stops the queues.
            if closesWindow { return self.answerMergeQueueQuit(quit, true) }
            self.mergeQueueQuit = nil
            if self.stopMergeQueuesForQuit(reply: quit.reply) == .terminateNow { self.answerMergeQueueQuit(quit, true) }
        }
    }

    /// Stops every running queue. `.terminateNow` when none runs any more;
    /// otherwise the quit waits for them (`settleMergeQueueQuit`), at most
    /// `mergeQueueQuitTimeout`, and `reply` gets the answer.
    private func stopMergeQueuesForQuit(reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        // Nothing waits yet: a queue that stops at once answers no one.
        for controller in runningMergeQueues { controller.stop() }
        guard !runningMergeQueues.isEmpty else { return .terminateNow }
        let quit = MergeQueueQuit(reply: reply)
        quit.isConfirmed = true
        mergeQueueQuit = quit
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.mergeQueueQuitTimeout) { [weak self] in
            guard let self, self.mergeQueueQuit === quit else { return }
            NiruxDebugLog.log("MergeQueue: quitting while a call already sent hasn’t answered")
            self.answerMergeQueueQuit(quit, true)
        }
        return .terminateLater
    }

    /// A queue changed: a confirmed quit goes on once none runs.
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
