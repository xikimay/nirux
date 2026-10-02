import AppKit

// MARK: - CI failure: notify once, Why Failed, Rerun Failed (docs/ci-failure-actions.md)

extension NiruxShellView {
    /// After each pull request read: a red run not reported yet marks the
    /// card like an agent asking for attention, and notifies while Nirux is
    /// in the background. The caller refreshes the sidebar.
    func reportNewRedChecks(in workspace: WorkspaceState) {
        let red = workspace.takeNewRedChecks()
        guard !red.isEmpty, let pullRequest = workspace.prInfo,
              !(NSApp.isActive && workspace === activeWorkspace) else { return }
        workspace.hasNotification = true
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)
        NiruxNotifier.shared.postCIFailure(
            workspaceID: workspace.id,
            workspaceTitle: workspace.title,
            pullRequest: pullRequest.number,
            checkNames: red.map(\.name)
        )
    }

    func handleCIFailureAction(_ action: NiruxNotifier.CIFailureAction, workspaceID: String) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        focusWorkspace(id: workspaceID)
        switch action {
        case .whyFailed: askAgentWhyCIFailed(workspace)
        case .rerunFailed: confirmRerunFailedCI(workspace)
        }
    }

    /// Types the `gh run view --log-failed` of each red Actions run into the
    /// workspace's agent (the focused column's, else the first), through the
    /// remote prompt path. No agent, or no such run: the check opens instead.
    func askAgentWhyCIFailed(_ workspace: WorkspaceState) {
        guard let pullRequest = workspace.prInfo, !CIFailure.redChecks(pullRequest).isEmpty else {
            NSSound.beep()
            return
        }
        let runs = CIFailure.runs(pullRequest)
        let sessions = remoteAgentSessions().filter { $0.workspaceID == workspace.id }
        if !runs.isEmpty,
           let session = sessions.first(where: { $0.columnIndex == workspace.focusedIndex }) ?? sessions.first {
            let result = sendRemotePrompt(
                agentUUID: session.id,
                prompt: CIFailure.whyFailedPrompt(pullRequest: pullRequest.number, runs: runs)
            )
            switch result {
            case .sent(let session), .blockedByDialog(let session):
                focusWorkspace(id: workspace.id, column: session.columnIndex)
                // Typing would have answered the dialog: it shows instead.
                if case .blockedByDialog = result { NSSound.beep() }
                return
            case .sessionUnavailable, .emptyPrompt:
                break
            }
        }
        // The check's URL comes from whoever posted it: https only.
        let check = pullRequest.failedCheckUrl.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        if let url = check ?? URL(string: pullRequest.url) { sideEffects.openURL(url) }
    }

    /// `gh run rerun --failed` of each red Actions run, once confirmed: it
    /// starts jobs on GitHub. Then the pull request is followed as after a
    /// push.
    func confirmRerunFailedCI(_ workspace: WorkspaceState) {
        let runs = workspace.prInfo.map(CIFailure.runs) ?? []
        guard let pullRequest = workspace.prInfo, !runs.isEmpty else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Rerun the failed jobs of #\(pullRequest.number)?"
        alert.informativeText = "GitHub reruns the failed jobs of "
            + runs.map { "run \($0.id) of \($0.repository)" }.joined(separator: ", ") + "."
        alert.addButton(withTitle: "Rerun")
        alert.addButton(withTitle: "Cancel")
        guard runModal(alert) == .alertFirstButtonReturn else { return }
        let rerun = sideEffects.rerunFailedJobs
        DispatchQueue.global(qos: .userInitiated).async {
            let errors = runs.compactMap(rerun)
            DispatchQueue.main.async { [weak self, weak workspace] in
                guard let self else { return }
                if let workspace { self.gitRefresh.noteChange(.remoteBranch, for: workspace) }
                guard !errors.isEmpty else { return }
                let failure = NSAlert()
                failure.alertStyle = .warning
                failure.messageText = "Nirux couldn’t rerun the failed jobs"
                failure.informativeText = errors.joined(separator: "\n")
                failure.addButton(withTitle: "OK")
                self.runModal(failure)
            }
        }
    }
}
