import AppKit

// MARK: - CI failure: notify once, Why Failed, Rerun Failed (docs/ci-failure-actions.md)

extension NiruxShellView {
    /// After each pull request read: a red run not reported yet marks the
    /// card like an agent asking for attention, and notifies while Nirux is
    /// in the background.
    func reportNewRedChecks(in workspace: WorkspaceState) {
        let red = workspace.takeNewRedChecks()
        guard !red.isEmpty, let pullRequest = workspace.prInfo else { return }
        workspace.hasNotification = true
        scheduleMetadataRefresh()
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
    /// workspace's agent (the focused column's first), through the remote
    /// prompt path. No agent, or no Actions run: the check opens instead.
    func askAgentWhyCIFailed(_ workspace: WorkspaceState) {
        guard let pullRequest = workspace.prInfo, !pullRequest.redChecks.isEmpty else { NSSound.beep(); return }
        let runs = CIFailure.runs(pullRequest.redChecks)
        let sessions = remoteAgentSessions().filter { $0.workspaceID == workspace.id }
        if !runs.isEmpty,
           let session = sessions.first(where: { $0.columnIndex == workspace.focusedIndex }) ?? sessions.first {
            switch sendRemotePrompt(
                agentUUID: session.id,
                prompt: CIFailure.whyFailedPrompt(pullRequest: pullRequest.number, runs: runs)
            ) {
            case .sent(let session):
                focusWorkspace(id: workspace.id, column: session.columnIndex)
                return
            case .blockedByDialog(let session):
                // Typing now would answer the dialog: show it instead.
                focusWorkspace(id: workspace.id, column: session.columnIndex)
                NSSound.beep()
                return
            case .sessionUnavailable, .emptyPrompt:
                break
            }
        }
        if let url = pullRequest.failedCheckUrl.flatMap(URL.init(string:)) { sideEffects.openURL(url) }
    }

    /// `gh run rerun --failed` of each red Actions run, once confirmed: it
    /// starts jobs on GitHub. Then the pull request is followed as after a
    /// push.
    func confirmRerunFailedCI(_ workspace: WorkspaceState) {
        guard let pullRequest = workspace.prInfo else { NSSound.beep(); return }
        let runs = CIFailure.runs(pullRequest.redChecks)
        guard !runs.isEmpty else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Rerun the failed jobs of #\(pullRequest.number)?"
        alert.informativeText = "GitHub reruns the failed jobs of "
            + (runs.count == 1 ? "run \(runs[0].id)" : "runs " + runs.map { "\($0.id)" }.joined(separator: ", "))
            + ", on \(workspace.title)."
        alert.addButton(withTitle: "Rerun")
        alert.addButton(withTitle: "Cancel")
        guard runModal(alert) == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let errors = runs.compactMap(Self.rerun)
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

    /// Nil when GitHub accepted the rerun, else why not. Runs gh: off the
    /// main thread.
    nonisolated private static func rerun(_ run: CIFailure.Run) -> String? {
        guard let ghPath = PRDetect.installedGHPath() else { return ProjectBoard.FetchError.ghMissing.message }
        guard let result = GitHubCLIBoardClient.runGH(ghPath, arguments: CIFailure.rerunArguments(run), timeout: 30)
        else { return "Run \(run.id): gh couldn’t start, or took longer than 30 s." }
        guard result.terminationStatus != 0 else { return nil }
        let stderr = String(data: result.standardError, encoding: .utf8) ?? ""
        return "Run \(run.id): " + (WorktreeCleanup.firstLine(stderr) ?? "exit status \(result.terminationStatus)")
    }
}
