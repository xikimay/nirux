import AppKit

// MARK: - PR feedback inbox (docs/pr-feedback-inbox.md)

extension NiruxShellView {
    /// Shown in the card's menu; the rest is on GitHub.
    private static let prFeedbackMenuLimit = 10

    /// After each read of an open PR. A failed read keeps the last value;
    /// a read started before another one is dropped.
    func refreshPRFeedback(for workspace: WorkspaceState) {
        guard let pullRequest = workspace.prInfo, pullRequest.state == "OPEN" else { return }
        workspace.prFeedbackGeneration &+= 1
        let generation = workspace.prFeedbackGeneration
        PRFeedbackReader.fetchAsync(pullRequestURL: pullRequest.url) { [weak self, weak workspace] feedback in
            guard let workspace, let feedback,
                  workspace.prFeedbackGeneration == generation,
                  workspace.prInfo?.url == pullRequest.url, workspace.prInfo?.state == "OPEN",
                  workspace.prFeedback != feedback
            else { return }
            workspace.prFeedback = feedback
            self?.scheduleMetadataRefresh()
        }
    }

    /// The card line's menu: the items, then Address. By id: the card's
    /// index may be stale until the next render.
    func prFeedbackMenu(workspaceID: String) -> NSMenu? {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
              let pullRequest = workspace.prInfo, let feedback = workspace.prFeedback, !feedback.items.isEmpty
        else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in feedback.items.prefix(Self.prFeedbackMenuLimit) {
            menu.addClosureItem(title: Self.prFeedbackMenuTitle(item)) {
                if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
            }
        }
        if feedback.items.count > Self.prFeedbackMenuLimit {
            menu.addClosureItem(title: "\(feedback.items.count - Self.prFeedbackMenuLimit) More on GitHub") {
                if let url = URL(string: pullRequest.url) { NSWorkspace.shared.open(url) }
            }
        }
        menu.addItem(.separator())
        let refusal = Self.prFeedbackAddressRefusal(prFeedbackAgent(in: workspace))
        var scopes = [(title: "Address", items: feedback.items)]
        if feedback.humanCount > 0, feedback.botCount > 0 {
            scopes.append(("Address Bot Feedback", feedback.items.filter(\.isBot)))
        }
        for scope in scopes {
            let title = refusal.map { "\(scope.title) (\($0))" } ?? scope.title
            let prompt = Self.prFeedbackAddressPrompt(for: pullRequest, items: scope.items)
            menu.addClosureItem(title: title) { [weak self, weak workspace] in
                guard let self, let workspace else { return }
                self.addressPRFeedback(in: workspace, prompt: prompt)
            }.isEnabled = refusal == nil
        }
        return menu
    }

    private static func prFeedbackMenuTitle(_ item: PRFeedback.Item) -> String {
        let outdated = item.isOutdated ? " (outdated)" : ""
        return "\(item.isBot ? "🤖" : "💬") \(item.author) · \(item.location)\(outdated) · \(item.excerpt)"
    }

    /// Names the items the user saw, so the agent addresses those and not
    /// whatever else the PR holds.
    static func prFeedbackAddressPrompt(for pullRequest: PRInfo, items: [PRFeedback.Item]) -> String {
        "/receiving-code-review Address this feedback on PR #\(pullRequest.number) (\(pullRequest.url)): "
            + items.map(\.url).joined(separator: " ")
    }

    /// Why Address can't type into the agent now; nil when it can.
    static func prFeedbackAddressRefusal(_ session: RemoteAgentSession?) -> String? {
        guard let session else { return "no Claude agent running" }
        if session.pendingDialog != nil { return "the agent is waiting on a dialog" }
        if session.status == .working { return "the agent is working" }
        return nil
    }

    /// The workspace's focused Claude agent, else its first one, in the
    /// PR's checkout: the skill is Claude's. Telegram's rules decide what
    /// is live.
    private func prFeedbackAgent(in workspace: WorkspaceState) -> RemoteAgentSession? {
        guard let root = workspace.gitContext?.identity.repositoryRoot else { return nil }
        let resolvedRoot = Self.comparablePath(root)
        let snapshot = ProcessSnapshot()
        let sessions = remoteAgentSessions().filter {
            $0.workspaceID == workspace.id
                && workspace.columns[$0.columnIndex].pty?.foregroundProcessName(snapshot: snapshot) == "claude"
                && ProjectBoard.contains(resolvedRoot, Self.comparablePath($0.cwd))
        }
        return sessions.first { $0.columnIndex == workspace.focusedIndex } ?? sessions.first
    }

    /// Checks again at the click: the menu may have stayed open a while.
    /// Hooks still in the queue may say the agent started working.
    private func addressPRFeedback(in workspace: WorkspaceState, prompt: String) {
        AgentHookCenter.shared.drain()
        if let session = prFeedbackAgent(in: workspace), Self.prFeedbackAddressRefusal(session) == nil,
           case .sent = sendRemotePrompt(agentUUID: session.id, prompt: prompt) {
            return
        }
        NSSound.beep()
    }
}
