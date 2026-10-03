import Foundation

// MARK: - Session history (see AgentSessionLedger)

extension NiruxShellView {
    /// What a routed event says about its session, with the workspace's git
    /// checkout and pull request at that moment. For Codex, right after
    /// `captureCodexSession` bound the event's thread.
    func recordAgentSession(_ appliedEvent: AgentHookCenter.AppliedEvent, snapshot: ProcessSnapshot) {
        let event = appliedEvent.event
        guard AgentSessionObservation.isTracked(event.name),
              let sessionID = event.sessionID, !sessionID.isEmpty else { return }
        let resolution = appliedEvent.resolution
        let workspace = resolution.workspace
        let agentProcess: ForegroundProcess?
        switch event.kind {
        case .claude:
            agentProcess = appliedEvent.claudeSessionAgent
        case .codex:
            let foreground = resolution.column.pty?.foregroundProcess(snapshot: snapshot)
            agentProcess = foreground.flatMap {
                !AgentHookCenter.isHeadlessCodex($0) && resolution.column.boundCodexSessionID(of: $0.instance) == sessionID
                    ? $0 : nil
            }
        }
        // A permission dialog and its answer only move the status: no disk
        // reads for them.
        let checkout = [.permissionRequest, .postToolUse].contains(event.name)
            ? nil
            : Self.sessionCheckout(context: workspace.gitContext, cwd: event.cwd)
        sessionLedger.record(AgentSessionObservation(
            agent: event.kind,
            sessionID: sessionID,
            event: event.name,
            source: event.source,
            timestamp: event.timestamp,
            agentProcess: agentProcess?.instance,
            name: event.kind == .claude
                ? agentProcess.flatMap { AgentSessionObservation.launchName(arguments: $0.arguments) }
                : nil,
            cwd: event.cwd,
            // A subagent's transcript is not the session's.
            transcriptPath: event.agentID == nil ? event.transcriptPath : nil,
            checkout: checkout,
            pullRequest: checkout == nil ? nil : workspace.prInfo.map(Self.sessionPullRequest),
            workspaceID: workspace.id,
            workspaceTitle: workspace.title,
            agentUUID: event.agentUUID,
            columnIndex: resolution.columnIndex
        ), spaceID: workspace.profileID)
    }

    /// The workspace's checkout (`context`), when the agent works in it
    /// rather than in a folder or worktree nested inside.
    static func sessionCheckout(context: GitContext?, cwd: String?) -> AgentSessionRecord.Checkout? {
        guard let context, !context.branch.isEmpty else { return nil }
        let root = URL(fileURLWithPath: context.identity.repositoryRoot).standardizedFileURL.path
        if let cwd {
            let cwd = URL(fileURLWithPath: cwd).standardizedFileURL.path
            guard ProjectBoard.contains(root, cwd), AgentSessionRecord.checkoutRoot(containing: cwd) == root else {
                return nil
            }
        }
        return AgentSessionRecord.Checkout(
            branch: context.branch,
            worktreeRoot: root,
            mainCheckout: AgentSessionRecord.mainCheckout(ofWorktreeAt: root),
            repository: context.upstreamRepository.map { "\($0.host)/\($0.owner)/\($0.name)" },
            head: context.identity.head
        )
    }

    static func sessionPullRequest(_ info: PRInfo) -> AgentSessionRecord.PullRequest {
        AgentSessionRecord.PullRequest(number: info.number, url: info.url, state: info.state.uppercased())
    }

    /// The pull request of the workspace's checkout, for every session that
    /// ran in it.
    func noteSessionPullRequest(of workspace: WorkspaceState) {
        guard let info = workspace.prInfo, let checkout = Self.sessionCheckout(context: workspace.gitContext, cwd: nil)
        else { return }
        sessionLedger.notePullRequest(
            Self.sessionPullRequest(info), branch: checkout.branch, worktreeRoot: checkout.worktreeRoot
        )
    }

    /// After every column's foreground agent was followed
    /// (`trackForegroundAgent`): a session whose agent exited, was replaced,
    /// or lost its column with a close has ended.
    func closeEndedAgentSessions(now: TimeInterval) {
        var live: [String: ProcessInstance] = [:]
        for workspace in workspaces {
            for column in workspace.columns {
                if let agentUUID = column.agentUUID, let agent = column.lastForegroundAgent {
                    live[agentUUID] = agent.instance
                }
            }
        }
        sessionLedger.closeSessions(notRunningIn: live, at: now)
    }
}
