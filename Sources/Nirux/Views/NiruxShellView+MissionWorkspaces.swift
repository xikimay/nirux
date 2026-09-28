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
            // Read back from the checkout: the session is named after the
            // branch it will actually work on (see `SessionName`).
            let checkedOutBranch = path.flatMap(GitWorktree.currentBranch(at:))
            // Move handover file into the worktree if provided. The path comes
            // from a URL: HandoverFile only accepts the user's own regular file
            // directly in /tmp, never a symlink or hard link.
            var deliveredHandover = false
            var handoverError: HandoverFile.TransferError?
            if let path, let handoverPath {
                switch HandoverFile.transfer(
                    from: handoverPath,
                    toDirectory: path,
                    filename: Self.handoverFilename(for: agent ?? .claude)
                ) {
                case .success: deliveredHandover = true
                case .failure(let error): handoverError = error
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // An agent retrying the same `open` after its handover was
                // delivered: focus the workspace the first request opened
                // instead of adding a duplicate agent in the same folder.
                if let handoverPath, handoverError == .cannotOpen(ENOENT),
                   let previousID = DeliveredHandovers.workspaceID(for: handoverPath),
                   self.workspaces.contains(where: { $0.id == previousID }) {
                    self.focusWorkspace(id: previousID)
                    return
                }
                if let handoverPath, let handoverError {
                    NSLog("[Worktree] Ignored handover \(handoverPath): \(handoverError)")
                    self.presentProblem(
                        "Handover ignored for “\(branch)”",
                        "The worktree opens without it. \(handoverError.explanation)\n\n\(handoverPath)"
                    )
                }
                if let path {
                    let childWorkspaceID = UUID().uuidString
                    let childAgentUUID = UUID().uuidString
                    if deliveredHandover, let handoverPath {
                        DeliveredHandovers.record(handoverPath, workspaceID: childWorkspaceID)
                    }
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
                        missionID: missionID,
                        deliveredHandover: deliveredHandover,
                        worktreeBranch: checkedOutBranch
                    )
                    self.saveState()
                } else {
                    NSLog("[Worktree] Failed to create worktree for \(branch): \(error ?? "unknown")")
                    self.presentProblem(
                        "Couldn’t create worktree “\(branch)”",
                        error ?? "git worktree add failed"
                    )
                }
            }
        }
    }

    /// Non-blocking report for URL-driven actions that fail after the
    /// request was accepted (the agent's `open` already exited 0).
    func presentProblem(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NiruxURLRequest.displaySafe(title)
        alert.informativeText = NiruxURLRequest.displaySafeLines(message)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            runModal(alert)
        }
    }

    /// `nirux://new-worktree` URL the in-app flow asks the running agent to
    /// open. Values are percent-encoded down to unreserved ASCII, so the URL
    /// is inert inside the double quotes of `open "…"`; the one shell
    /// expansion left is `${NIRUX_LAUNCH_ID}`, which the agent's shell fills in.
    nonisolated static func inAppWorktreeURL(for request: NiruxURLRequest.NewWorktree, profileID: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/"
        )
        var query: [(String, String?)] = [
            ("branch", request.branch),
            ("repo", request.repo),
            ("agent", request.agent?.rawValue),
            ("handover", request.handoverPath),
            ("profile", profileID),
            ("parentWorkspace", request.parentWorkspaceID),
            ("parentAgent", request.parentAgentUUID)
        ]
        query.removeAll { $0.1 == nil }
        let encoded = query.map { name, value in
            "\(name)=\(value?.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")"
        }
        return "nirux://new-worktree?" + encoded.joined(separator: "&")
            + "&\(NiruxLaunchAuthorization.queryItemName)=${\(NiruxLaunchAuthorization.environmentKey)}"
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

/// Handover paths already moved into a worktree, so a retried request for
/// the same handover can be recognized (bounded; newest kept).
@MainActor
private enum DeliveredHandovers {
    private static var workspaceByPath: [(path: String, workspaceID: String)] = []

    static func record(_ path: String, workspaceID: String) {
        workspaceByPath.removeAll { $0.path == path }
        workspaceByPath.append((path, workspaceID))
        if workspaceByPath.count > 32 { workspaceByPath.removeFirst() }
    }

    static func workspaceID(for path: String) -> String? {
        workspaceByPath.last { $0.path == path }?.workspaceID
    }
}
