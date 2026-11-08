import AppKit

// MARK: - Space defaults at launch (docs/projects.md, section 5)

extension NiruxShellView {
    /// `Nirux --hook codex --setup-failed <id>` ran in a new worktree's
    /// terminal (see SetupFailureSignal): its card turns red, and a
    /// notification says so unless the user is looking at it.
    func setupScriptFailed(workspaceID: String) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID && !$0.isClosing }),
              let column = workspace.columns.first
        else { return }
        let title = NiruxURLRequest.displaySafe(workspace.title, limit: 60)
        if NSApp.isActive, workspace === activeWorkspace {
            showToast("The setup script failed in “\(title)”: the agent started anyway", tone: .error)
        } else {
            workspace.raiseNotification(.error)
            sideEffects.notifySetupFailure(workspace.id, workspace.title)
        }
        updateSidebar()
        onSetupScriptFailed?(workspace, 0, column)
    }
}

extension NiruxApp {
    /// Setup scripts report a failure through a distributed notification
    /// naming the state directory they belong to (SetupFailureSignal):
    /// another Nirux's, a debug build's own, is ignored.
    func observeSetupFailures() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(setupScriptFailed(_:)),
            name: SetupFailureSignal.notificationName,
            object: Persistence.stateDirectory.standardizedFileURL.path,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc func setupScriptFailed(_ notification: Notification) {
        guard let workspaceID = notification.userInfo?["workspaceID"] as? String,
              SetupFailureSignal.isPlausibleWorkspaceID(workspaceID)
        else { return }
        shell?.setupScriptFailed(workspaceID: workspaceID)
    }
}
