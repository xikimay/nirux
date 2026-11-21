import AppKit

// MARK: - What the Board as stages' clicks do (docs/design/board-stages.md, section 7)

/// Each click of the Board goes to the flow the table's buttons ran
/// (`performProjectBoardAction`, the queue's Start and Stop, Board
/// Settings): what a line or a menu item doesn't carry, the Board kept
/// as it showed it (`ProjectBoardController.stagesTargets`). The view
/// sends no click that does nothing for now (`blocked`).
extension NiruxShellView {
    func wireBoardStages(_ board: ProjectBoardController) {
        let stages = board.view.stages
        stages.onOrder = { [weak self, weak board] order in
            guard let self, let board else { return }
            self.setBoardOrder(order, from: board)
        }
        stages.onStart = { [weak self, weak board] id in
            guard let self, let board else { return }
            self.requestMergeQueueStart(board: board, section: id)
        }
        stages.onStop = { [weak self, weak board] id in
            guard let self, let board else { return }
            self.stopMergeQueue(board: board, section: id)
        }
        stages.onSectionMenu = { [weak self, weak board] section, item in
            guard let self, let board else { return }
            switch item {
            case .boardSettings:
                self.showBoardSettings(of: board, repository: section)
            case .openMainCheckout(let path):
                guard let action = board.stagesTargets.mainCheckouts[path] else { return }
                self.performProjectBoardAction(action, board: board)
            }
        }
        stages.onBoardSettings = { [weak self, weak board] in
            guard let self, let board else { return }
            self.showBoardSettings(of: board, repository: nil)
        }
        stages.onLead = { [weak self, weak board] in
            guard let self, let board else { return }
            guard let lead = self.leadWorkspace(inSpace: board.projectID) else { return self.showToast("The Lead was closed") }
            let columnID = board.view.stages.content?.header.lead?.columnID
            let index = columnID.flatMap { id in lead.columns.firstIndex { $0.id == id && !$0.isClosing } }
            if let index { self.focusWorkspace(id: lead.id, column: index) } else { self.focusLead(lead) }
        }
        stages.onOpen = { [weak self, weak board] line in
            // A pull request without a task opens nothing: its menu has what it offers.
            guard let self, let board, let focus = board.stagesTargets.focus[line] else { return }
            self.performProjectBoardAction(focus, board: board)
        }
        stages.onTaskGone = { [weak self, weak board] workspaceID in
            // As the table's Focus: the workspace where it went (another space, another repository), else "That workspace
            // was closed".
            guard let self, let board else { return }
            self.performProjectBoardAction(.focus(workspaceID: workspaceID, columnID: nil), board: board)
        }
        stages.onOffer = { [weak self, weak board] section, offer in
            guard let self, let board else { return }
            self.performBoardOffer(offer, section: section, board: board)
        }
        stages.onLink = { [weak self, weak board] section, line, link in
            guard let self, let board else { return }
            self.performBoardLink(link, line: line, section: section, board: board)
        }
        stages.onMenu = { [weak self, weak board] section, line, item in
            guard let self, let board else { return }
            self.performBoardMenuItem(item, line: line, section: section, board: board)
        }
        stages.onWorktree = { [weak self, weak board] section, item in
            guard let self, let board else { return }
            self.performBoardMenuItem(item, line: nil, section: section, board: board)
        }
    }

    /// `board`'s order switch: every Board takes it (a hidden one when it
    /// shows next), and it is saved with the shell's state, which holds it
    /// (`persistedState`). `board` draws in it even when it is the order
    /// set already: hidden while another Board's switch changed it, it
    /// still showed the old one.
    func setBoardOrder(_ order: BoardStages.Order, from board: ProjectBoardController) {
        let isNew = order != boardOrder
        if isNew {
            boardOrder = order
            saveState()
        }
        let snapshot = ProcessSnapshot()
        for location in projectBoardLocations where location.board === board || (isNew && isProjectBoardShown(location.board)) {
            renderProjectBoard(location.board, snapshot: snapshot)
        }
    }

    /// As the Board shows that pull request now: a line held under the
    /// pointer may still show an offer since refused (a draft, a queue
    /// started), or another repository's number. A refused one says why.
    func performBoardOffer(_ offer: BoardStages.QueueOffer, section: String, board: ProjectBoardController) {
        guard let current = board.stagesTargets.offers[section]?[offer.number], current.change == offer.change
        else { return NSSound.beep() }
        if let blocked = current.blocked { return showToast(blocked) }
        let action: ProjectBoard.Action = offer.change == .add
            ? .addToQueue(number: offer.number, section: section) : .removeFromQueue(number: offer.number, section: section)
        performProjectBoardAction(action, board: board)
    }

    /// `line`: the line's id, or the task's of a "Merged today" entry,
    /// which has left the list.
    func performBoardLink(_ link: BoardStages.Link, line: String?, section: String, board: ProjectBoardController) {
        switch link {
        case .retarget(let number, let onto):
            // As the Board offers it now: a line held under the pointer may still show it once a queue started, or
            // once the queue's list holds it, or another repository's number.
            guard let current = board.stagesTargets.retargets[section]?[number], current.onto == onto else { return NSSound.beep() }
            if let blocked = current.blocked { return showToast(blocked) }
            performProjectBoardAction(.retarget(number: number, base: onto, section: section), board: board)
        case .cleanUp:
            guard let line, let folder = board.stagesTargets.folders[line] else { return }
            performProjectBoardAction(.cleanUp(path: folder.path), board: board)
        }
    }

    /// `line`: the line's id; nil for an item of "Other worktrees" or
    /// "Other workspaces".
    func performBoardMenuItem(_ item: BoardStages.MenuItem, line: String?, section: String, board: ProjectBoardController) {
        switch item {
        case .openPullRequest(let address):
            // Whatever made the item: never an address but GitHub's.
            guard BoardStages.isGitHubAddress(address), let url = URL(string: address) else { return }
            sideEffects.openURL(url)
        case .queue(let offer):
            performBoardOffer(offer, section: section, board: board)
        case .retarget(let link, _):
            performBoardLink(link, line: line, section: section, board: board)
        case .resume(let resume):
            // A task's line: its id is its workspace's.
            guard let line else { return }
            resumeFromBoard(resume, workspaceID: line, board: board)
        case .cleanUp(let path, _):
            performProjectBoardAction(.cleanUp(path: path), board: board)
        case .openWorktree(let path, let title):
            performProjectBoardAction(.open(path: path, title: title), board: board)
        case .focus(let workspaceID, let columnID):
            performProjectBoardAction(.focus(workspaceID: workspaceID, columnID: columnID), board: board)
        }
    }

    /// Resume, as the sidebar offers it.
    private func resumeFromBoard(_ resume: BoardStages.Resume, workspaceID: String, board: ProjectBoardController) {
        guard resume.kind == .afterRelaunch else {
            guard let action = Self.resumeAction(resume, workspaceID: workspaceID) else { return }
            return performProjectBoardAction(action, board: board)
        }
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID && !$0.isClosing }),
              let columnIndex = workspaces[workspaceIndex].columns.firstIndex(where: { $0.id == resume.column && !$0.isClosing })
        else { return showToast("That agent’s column was closed") }
        // Its sidebar pass draws the Board.
        resumeDeferredAgent(workspaceIndex: workspaceIndex, columnIndex: columnIndex, columnID: resume.column)
    }

    /// The table's Resume of a stopped agent: after an error, only that
    /// failed turn (none named, nothing); after an exit, its conversation.
    /// Nil for an agent restored at launch, which the sidebar's Resume
    /// starts.
    nonisolated static func resumeAction(_ resume: BoardStages.Resume, workspaceID: String) -> ProjectBoard.Action? {
        switch resume.kind {
        case .afterError: return resume.failedAt.map { .resumeFailed(workspaceID: workspaceID, columnID: resume.column, failedAt: $0) }
        case .afterExit: return .resumeExited(workspaceID: workspaceID, columnID: resume.column)
        case .afterRelaunch: return nil
        }
    }
}
