import Foundation

// MARK: - Prompts Nirux types into an agent

extension NiruxShellView {
    /// The agents Nirux may type a prompt into: recognized, live agent
    /// processes only. Browser/editor columns, idle shells and exited
    /// terminals are never among them.
    func remoteAgentSessions() -> [RemoteAgentSession] {
        let snapshot = ProcessSnapshot()
        return workspaces.flatMap { workspace in
            workspace.columns.enumerated().compactMap { columnIndex, column in
                makeRemoteSession(
                    workspace: workspace,
                    column: column,
                    columnIndex: columnIndex,
                    snapshot: snapshot
                )
            }
        }
    }

    /// Types `prompt` and Return into that agent, unless it may be showing
    /// a dialog the text would answer.
    func sendRemotePrompt(agentUUID: String, prompt: String) -> RemotePromptResult {
        guard let terminalInput = RemotePromptSanitizer.terminalInput(for: prompt) else {
            return .emptyPrompt
        }
        // A PermissionRequest may still wait out the hook queue's drain
        // debounce: apply it before deciding whether a dialog is open.
        AgentHookCenter.shared.drain()
        let snapshot = ProcessSnapshot()
        for workspace in workspaces {
            guard let columnIndex = workspace.columns.firstIndex(where: { $0.agentUUID == agentUUID }) else {
                continue
            }
            let column = workspace.columns[columnIndex]
            guard let session = makeRemoteSession(
                workspace: workspace,
                column: column,
                columnIndex: columnIndex,
                snapshot: snapshot
            ), let pty = column.pty else { return .sessionUnavailable }
            if session.pendingDialog != nil { return .blockedByDialog(session) }
            pty.sendRaw(terminalInput)
            return .sent(session)
        }
        return .sessionUnavailable
    }

    private func makeRemoteSession(
        workspace: WorkspaceState,
        column: ColumnState,
        columnIndex: Int,
        snapshot: ProcessSnapshot
    ) -> RemoteAgentSession? {
        guard let agentUUID = column.agentUUID,
              let pty = column.pty,
              pty.acceptsRemotePrompts(snapshot: snapshot)
        else { return nil }
        return RemoteAgentSession(
            id: agentUUID,
            workspaceID: workspace.id,
            columnIndex: columnIndex,
            cwd: pty.childCwd ?? workspace.cwd,
            status: pty.cachedAgentState,
            pendingDialog: pty.pendingAgentDialog?.reason
        )
    }
}
