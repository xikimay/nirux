import Foundation

// MARK: - Prompts Nirux types into an agent

extension NiruxShellView {
    /// The agents Nirux may type a prompt into: recognized, live agent
    /// processes only. Browser/editor columns, idle shells and exited
    /// terminals are never among them.
    func typedPromptTargets() -> [TypedPromptTarget] {
        let snapshot = ProcessSnapshot()
        return workspaces.flatMap { workspace in
            workspace.columns.enumerated().compactMap { columnIndex, column in
                makeTypedPromptTarget(
                    workspace: workspace,
                    column: column,
                    columnIndex: columnIndex,
                    snapshot: snapshot
                )
            }
        }
    }

    /// Types `prompt` and Return into that agent for the user's click
    /// (Address PR Feedback, Why Failed), unless it may be showing a dialog
    /// the text would answer. Its turn end is then read: neither the
    /// prompt nor a verdict on its way alerts. Nirux's own messages wait
    /// instead (`PtySession.acceptsMissionMessage`).
    func sendTypedPrompt(agentUUID: String, prompt: String) -> TypedPromptResult {
        guard let terminalInput = TypedPromptSanitizer.terminalInput(for: prompt) else {
            return .emptyPrompt
        }
        // A PermissionRequest may still wait out the hook queue's drain
        // debounce: apply it before deciding whether a dialog is open.
        AgentHookCenter.shared.drain()
        guard let place = liveColumn(where: { $0.agentUUID == agentUUID }),
              let session = makeTypedPromptTarget(
                  workspace: place.workspace, column: place.column, columnIndex: place.columnIndex, snapshot: ProcessSnapshot()
              ),
              let pty = place.column.pty
        else { return .sessionUnavailable }
        if session.pendingDialog != nil { return .blockedByDialog(session) }
        pty.typePromptFromUser(terminalInput)
        return .sent(session)
    }

    private func makeTypedPromptTarget(
        workspace: WorkspaceState,
        column: ColumnState,
        columnIndex: Int,
        snapshot: ProcessSnapshot
    ) -> TypedPromptTarget? {
        guard let agentUUID = column.agentUUID,
              let pty = column.pty,
              pty.acceptsTypedPrompts(snapshot: snapshot)
        else { return nil }
        return TypedPromptTarget(
            id: agentUUID,
            workspaceID: workspace.id,
            columnIndex: columnIndex,
            cwd: pty.childCwd ?? workspace.cwd,
            status: pty.cachedAgentState,
            pendingDialog: pty.pendingAgentDialog?.reason
        )
    }
}
