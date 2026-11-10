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
        focusWorkspace(id: workspaceID, column: columnIndex)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("Your reply wasn’t sent: the agent moved on, or something is typed at its prompt. It’s on the clipboard.")
    }
}
