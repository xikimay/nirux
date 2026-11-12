import AppKit

// MARK: - Quick answers to a turn's question (Yes, No, Reply…)

extension NiruxShellView {
    /// Types `answer` into the agent `agentUUID` as its answer to the turn
    /// end of `turnEndedAt`, when that turn end is still the last thing
    /// that happened at a quiet prompt (`AgentStatusMachine
    /// .acceptsQuickAnswer`). False, and nothing typed, otherwise.
    @discardableResult
    func answerTurnQuestion(agentUUID: String, turnEndedAt: TimeInterval, answer: String) -> Bool {
        guard let terminalInput = TypedPromptSanitizer.terminalInput(for: answer) else { return false }
        // A hook still in the queue may say the agent moved on.
        AgentHookCenter.shared.drain()
        guard let place = liveColumn(where: { $0.agentUUID == agentUUID }), let pty = place.column.pty,
              pty.typeQuickAnswer(terminalInput, to: turnEndedAt, foreground: pty.foregroundProcess(snapshot: ProcessSnapshot()))
        else { return false }
        if let index = workspaces.firstIndex(where: { $0 === place.workspace }) { noteCatchUpTaskAnswered(workspaceIndex: index) }
        return true
    }

    /// The first column `matches` picks among those not closing, in a
    /// workspace not closing: where an agent is now.
    func liveColumn(where matches: (ColumnState) -> Bool) -> (workspace: WorkspaceState, columnIndex: Int, column: ColumnState)? {
        for workspace in workspaces where !workspace.isClosing {
            if let index = workspace.columns.firstIndex(where: { !$0.isClosing && matches($0) }) {
                return (workspace, index, workspace.columns[index])
            }
        }
        return nil
    }

    /// A reply typed in a turn question's notification. When it can't go
    /// in (the agent moved on, a draft waits at its prompt…), Nirux comes
    /// forward on that column and keeps the text on the clipboard.
    func replyFromNotification(
        _ text: String, to target: NiruxNotifier.QuickReplyTarget, workspaceID: String, columnIndex: Int?
    ) {
        if answerTurnQuestion(agentUUID: target.agentUUID, turnEndedAt: target.turnEndedAt, answer: text) { return }
        NSApp.activate(ignoringOtherApps: true)
        // Where that agent is now (columns may have moved since the banner).
        if let place = liveColumn(where: { $0.agentUUID == target.agentUUID }) {
            focusWorkspace(id: place.workspace.id, column: place.columnIndex)
        } else {
            focusWorkspace(id: workspaceID, column: columnIndex)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("Your reply wasn’t sent: the agent moved on, or something is typed at its prompt. It’s on the clipboard.")
    }
}

extension NiruxShellView {
    /// The question a column's Claude ended its turn on, for its card,
    /// while it waits at a prompt Nirux could answer into: not while it
    /// works (subagents included) or a dialog is open.
    static func sidebarTurnQuestion(
        of column: ColumnState, status: AgentStatus, foreground: ForegroundProcess?
    ) -> SidebarTurnQuestion? {
        guard status != .working, let pty = column.pty, pty.agentVisibleDialog(foreground: foreground) == nil,
              let asked = pty.agentQuestion(foreground: foreground), let text = asked.text
        else { return nil }
        return SidebarTurnQuestion(
            text: text, turnEndedAt: asked.since, isYesNo: asked.isYesNo, columnID: column.id, choices: asked.choices
        )
    }

    /// Yes, No, Reply… or Dismiss under a turn's question on a card, found
    /// by its column wherever the card moved. Yes and No go in at once (or
    /// say why not); Reply… opens a field next to the button; Dismiss puts
    /// the question aside.
    func answerFromCard(_ answer: SidebarTurnAnswer, to question: SidebarTurnQuestion, button: NSView?) {
        // Not an answer: no agent to type into.
        guard answer != .dismiss else {
            return dismissTurnQuestion(columnID: question.columnID, askedAt: question.turnEndedAt)
        }
        guard let place = liveColumn(where: { $0.id == question.columnID }), let agentUUID = place.column.agentUUID
        else { return NSSound.beep() }
        guard let text = answer.typedText else {
            return showTurnReplyPopover(for: question, in: place.workspace, agentUUID: agentUUID, anchor: button)
        }
        if !answerTurnQuestion(agentUUID: agentUUID, turnEndedAt: question.turnEndedAt, answer: text) {
            refuseQuickAnswer(in: place.workspace, columnIndex: place.columnIndex)
        }
        updateSidebar()
    }

    /// Dismiss on a question's card, "Dismiss Question" in its row's menu:
    /// the question asked at `askedAt` in that column is put aside,
    /// unanswered (`AgentStatusMachine.dismissQuestion`); a later one
    /// stays. The user dealt with the row: it leaves the catch-up card, and
    /// the turn end its workspace kept for a user away is seen.
    func dismissTurnQuestion(columnID: UUID, askedAt: TimeInterval) {
        defer { updateSidebar() }
        guard !ZZ("no-dismiss"), let place = liveColumn(where: { $0.id == columnID }),
              place.column.pty?.dismissAgentQuestion(askedAt: askedAt) == true
        else { return }
        if !ZZ("keep-catch-up"), let index = workspaces.firstIndex(where: { $0 === place.workspace }) { noteCatchUpTaskAnswered(workspaceIndex: index) }
        if !ZZ("keep-notification"), place.workspace.notification == .finished { place.workspace.notification = nil }
    }

    /// An archived task asks nothing: the questions its agents' turns
    /// ended on are put aside, or its row would stay listed, amber, in the
    /// folded Archived list; and the turn end kept for a user away is
    /// seen, as when one is dismissed from its row.
    func dismissTurnQuestions(in workspace: WorkspaceState) {
        guard !ZZ("archive-keeps") else { return }
        let dismissed = workspace.columns.filter { $0.pty?.dismissAgentQuestion() == true }
        if !ZZ("archive-keeps-notification"), !dismissed.isEmpty, workspace.notification == .finished { workspace.notification = nil }
    }

    private func showTurnReplyPopover(
        for question: SidebarTurnQuestion, in workspace: WorkspaceState, agentUUID: String, anchor: NSView?
    ) {
        closeTurnReply()
        let controller = TurnReplyViewController(taskTitle: workspace.title, question: question.text) { [weak self] text in
            guard let self else { return false }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.showToast("Type an answer first")
                return false
            }
            guard self.answerTurnQuestion(agentUUID: agentUUID, turnEndedAt: question.turnEndedAt, answer: text) else {
                self.showToast("Not sent: Claude moved on, or something is typed at its prompt")
                return false
            }
            self.closeTurnReply()
            self.updateSidebar()
            return true
        }
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.appearance = Theme.appearance
        controller.popover = popover
        if let anchor, anchor.window != nil {
            // The sidebar rebuilds its rows; the document view under them stays.
            let host = anchor.superview ?? anchor
            popover.show(relativeTo: host === anchor ? anchor.bounds : anchor.frame, of: host, preferredEdge: .maxX)
        } else if let pointer = sidebar.anchorAtPointer() {
            // A rebuild replaced the button between press and release.
            popover.show(relativeTo: pointer.rect, of: pointer.view, preferredEdge: .maxX)
        } else {
            return NSSound.beep()
        }
        turnReplyPopover = popover
        turnReplyQuestion = question
        controller.focusReplyField()
    }

    /// Its question went (Claude moved on, the user answered at the
    /// terminal, the column closed): the Reply… popover goes, its text kept
    /// on the clipboard. Decided by the column's turn end, not by the card:
    /// a question put aside leaves the card, not the conversation. A
    /// popover closed meanwhile is let go. The sidebar's refresh calls it.
    func closeStaleTurnReply() {
        guard let popover = turnReplyPopover, let question = turnReplyQuestion else { return }
        guard popover.isShown else { return closeTurnReply() }
        let column = liveColumn(where: { $0.id == question.columnID })?.column
        guard column?.pty?.isCurrentTurnEnd(question.turnEndedAt) != true else { return }
        let text = (popover.contentViewController as? TurnReplyViewController)?.replyView?.string ?? ""
        closeTurnReply()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("Claude moved on before your reply went: it’s on the clipboard")
    }

    private func closeTurnReply() {
        turnReplyPopover?.close()
        turnReplyPopover = nil
        turnReplyQuestion = nil
    }

    /// A quick answer that can't go in: the column shows why.
    private func refuseQuickAnswer(in workspace: WorkspaceState, columnIndex: Int) {
        focusWorkspace(id: workspace.id, column: columnIndex)
        showToast("Not sent: Claude moved on, or something is typed at its prompt")
    }
}
