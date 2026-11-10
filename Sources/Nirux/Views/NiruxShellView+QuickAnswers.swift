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
        let snapshot = ProcessSnapshot()
        for workspace in workspaces {
            guard let pty = workspace.columns.first(where: { $0.agentUUID == agentUUID })?.pty else { continue }
            return pty.typeQuickAnswer(terminalInput, to: turnEndedAt, foreground: pty.foregroundProcess(snapshot: snapshot))
        }
        return false
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
        if let place = agentPlace(target.agentUUID) {
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
        return SidebarTurnQuestion(text: text, turnEndedAt: asked.since, isYesNo: asked.isYesNo)
    }

    /// Yes, No or Reply… under a turn's question on a card. Yes and No go
    /// in at once (or say why not); Reply… opens a field next to the
    /// button.
    func answerFromCard(
        _ answer: SidebarTurnAnswer, workspaceIndex: Int, columnIndex: Int, turnEndedAt: TimeInterval, button: NSView?
    ) {
        guard let workspace = workspaces[safe: workspaceIndex], let column = workspace.columns[safe: columnIndex],
              let agentUUID = column.agentUUID
        else { return NSSound.beep() }
        guard let text = answer.typedText else {
            return showTurnReplyPopover(
                workspace: workspace, columnIndex: columnIndex, agentUUID: agentUUID, turnEndedAt: turnEndedAt, anchor: button
            )
        }
        if !answerTurnQuestion(agentUUID: agentUUID, turnEndedAt: turnEndedAt, answer: text) {
            refuseQuickAnswer(in: workspace, columnIndex: columnIndex)
        }
        updateSidebar()
    }

    private func showTurnReplyPopover(
        workspace: WorkspaceState, columnIndex: Int, agentUUID: String, turnEndedAt: TimeInterval, anchor: NSView?
    ) {
        let snapshot = ProcessSnapshot()
        guard let anchor, let pty = workspace.columns[safe: columnIndex]?.pty,
              let asked = pty.agentQuestion(foreground: pty.foregroundProcess(snapshot: snapshot)),
              asked.since == turnEndedAt, let question = asked.text
        else { return refuseQuickAnswer(in: workspace, columnIndex: columnIndex) }
        turnReplyPopover?.close()
        let controller = TurnReplyViewController(taskTitle: workspace.title, question: question) { [weak self] text in
            guard let self else { return false }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.showToast("Type an answer first")
                return false
            }
            guard self.answerTurnQuestion(agentUUID: agentUUID, turnEndedAt: turnEndedAt, answer: text) else {
                self.showToast("Not sent: Claude moved on, or something is typed at its prompt")
                return false
            }
            self.turnReplyPopover?.close()
            self.turnReplyPopover = nil
            self.updateSidebar()
            return true
        }
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.appearance = Theme.appearance
        controller.popover = popover
        // The sidebar rebuilds its rows; the document view under them stays.
        let host = anchor.superview ?? anchor
        popover.show(relativeTo: host === anchor ? anchor.bounds : anchor.frame, of: host, preferredEdge: .maxX)
        turnReplyPopover = popover
        controller.focusReplyField()
    }

    /// A quick answer that can't go in: the column shows why.
    private func refuseQuickAnswer(in workspace: WorkspaceState, columnIndex: Int) {
        let agent = workspace.columns[safe: columnIndex]?.agentUUID.flatMap(agentPlace)
        focusWorkspace(id: agent?.workspace.id ?? workspace.id, column: agent?.columnIndex ?? columnIndex)
        showToast("Not sent: Claude moved on, or something is typed at its prompt")
    }

    /// The workspace and column of the agent `agentUUID` now.
    func agentPlace(_ agentUUID: String) -> (workspace: WorkspaceState, columnIndex: Int)? {
        for workspace in workspaces {
            if let index = workspace.columns.firstIndex(where: { $0.agentUUID == agentUUID }) { return (workspace, index) }
        }
        return nil
    }
}
