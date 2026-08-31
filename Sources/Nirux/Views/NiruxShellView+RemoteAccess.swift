import Foundation

// MARK: - Telegram Remote Access capability bridge

extension NiruxShellView {
    /// Exposes only recognized, live agent processes. Browser/editor columns,
    /// idle shells and exited terminals never enter the remote routing table.
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

    func sendRemotePrompt(agentUUID: String, prompt: String) -> RemotePromptResult {
        guard let terminalInput = RemotePromptSanitizer.terminalInput(for: prompt) else {
            return .emptyPrompt
        }
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
              pty.acceptsRemotePrompts(snapshot: snapshot),
              let processName = pty.foregroundProcessName(snapshot: snapshot)
        else { return nil }
        let displayName: String
        if let title = column.terminalTitle,
           !title.isEmpty,
           !ColumnState.boringTitles.contains(title) {
            displayName = title
        } else {
            displayName = processName
        }
        return RemoteAgentSession(
            id: agentUUID,
            workspaceID: workspace.id,
            workspaceTitle: workspace.title,
            columnIndex: columnIndex,
            displayName: displayName,
            cwd: pty.childCwd ?? workspace.cwd,
            status: pty.cachedAgentState,
            recentOutput: pty.recentOutput()
        )
    }
}
