import AppKit

// MARK: - Mission Worktrees

extension NiruxShellView {
    /// Shared entry point: create a git worktree, move an optional handover file into it, and open a workspace.
    /// Used by both the `nirux://new-worktree` URL scheme and the WorktreePanel.
    func createWorktreeWorkspace(
        branch: String,
        repoRoot: String,
        agent: NiruxApp.WorkspaceAgent? = .claude,
        handoverPath: String? = nil,
        profileID requestedProfileID: String? = nil,
        parentWorkspaceID: String? = nil,
        parentAgentUUID: String? = nil
    ) {
        let targetProfileID = workspaceStore.targetProfileID(for: requestedProfileID)
        DispatchQueue.global(qos: .userInitiated).async {
            let (path, error) = GitWorktree.create(branch: branch, repoRoot: repoRoot)
            // Move handover file into the worktree if provided. The path comes
            // from a URL: HandoverFile only accepts the user's own regular file
            // directly in /tmp, never a symlink or hard link.
            if let path, let handoverPath {
                let result = HandoverFile.transfer(
                    from: handoverPath,
                    toDirectory: path,
                    filename: Self.handoverFilename(for: agent ?? .claude)
                )
                if case .failure(let error) = result {
                    NSLog("[Worktree] Ignored handover \(handoverPath): \(error)")
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let path {
                    let childWorkspaceID = UUID().uuidString
                    let childAgentUUID = UUID().uuidString
                    var missionID: String?
                    if let parent = self.validMissionParent(
                        workspaceID: parentWorkspaceID,
                        agentUUID: parentAgentUUID
                    ) {
                        let candidateID = UUID().uuidString
                        let request = MissionCreationRequest(
                            id: candidateID,
                            parentWorkspaceID: parent.workspaceID,
                            parentAgentUUID: parent.agentUUID,
                            childWorkspaceID: childWorkspaceID,
                            childAgentUUID: childAgentUUID,
                            childAgentKind: agent?.rawValue ?? "agent",
                            branch: branch
                        )
                        if MissionStore.shared.create(
                            request,
                            enabled: Self.currentMissionHandoffsEnabled()
                        ) != nil {
                            missionID = candidateID
                        }
                    }
                    self.addWorkspace(
                        title: branch,
                        cwd: path,
                        agent: agent,
                        profileID: targetProfileID,
                        workspaceID: childWorkspaceID,
                        initialAgentUUID: childAgentUUID,
                        missionID: missionID
                    )
                    self.saveState()
                } else {
                    NSLog("[Worktree] Failed to create worktree for \(branch): \(error ?? "unknown")")
                }
            }
        }
    }

    nonisolated static func handoverFilename(for agent: NiruxApp.WorkspaceAgent) -> String {
        switch agent {
        case .claude: return ".claude-handover.md"
        case .codex: return ".codex-handover.md"
        }
    }

    static func currentMissionHandoffsEnabled() -> Bool {
        Persistence.load()?.settings?.missionHandoffsEnabled == true
    }

    private func validMissionParent(
        workspaceID: String?, agentUUID: String?
    ) -> (workspaceID: String, agentUUID: String)? {
        guard Self.currentMissionHandoffsEnabled(),
              let workspaceID,
              let agentUUID,
              UUID(uuidString: workspaceID) != nil,
              UUID(uuidString: agentUUID) != nil,
              let workspace = workspaces.first(where: { $0.id == workspaceID }),
              workspace.columns.contains(where: { $0.agentUUID == agentUUID })
        else { return nil }
        return (workspaceID, agentUUID)
    }
}
