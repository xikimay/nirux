import Foundation

// MARK: - Project history (see ProjectHistoryCenter)

extension NiruxShellView {
    /// A turn or a session of a column's Claude ended: its project's
    /// journal reads the new turns. Only sessions the session history
    /// records (the column's own agent, not a subagent), with the project
    /// the workspace belongs to now. A session resumed in the column joins
    /// the project then: its turns that ended before were said elsewhere,
    /// or before history was on.
    func feedProjectHistory(_ appliedEvent: AgentHookCenter.AppliedEvent) {
        let event = appliedEvent.event
        guard event.kind == .claude, event.agentID == nil, let sessionID = event.sessionID else { return }
        let spaceID = appliedEvent.resolution.workspace.profileID
        let record = sessionLedger.session(agent: .claude, sessionID: sessionID)
        switch event.name {
        case .sessionStart where event.source == "resume":
            // Claude keeps writing to the session's first file, which a
            // resume from another folder doesn't name: the date is enough.
            projectHistory.sessionsJoined(
                spaceID: spaceID, sessions: [.init(sessionID: sessionID, transcriptPath: nil)],
                at: Date(timeIntervalSince1970: event.timestamp)
            )
        case .stop, .stopFailure, .sessionEnd:
            guard let record, let path = ProjectHistory.feedPath(
                eventPath: event.transcriptPath, recordPath: record.transcriptPath, sessionID: sessionID
            ) else { return }
            if event.name == .sessionEnd {
                projectHistory.sessionEnded(spaceID: spaceID, transcriptPath: path, sessionID: sessionID)
            } else {
                projectHistory.turnEnded(spaceID: spaceID, transcriptPath: path, sessionID: sessionID)
            }
        default:
            return
        }
    }

    /// Workspaces moved to another project: their running Claude sessions
    /// write for it from now on, and what they said before stays with the
    /// project they left.
    func projectHistoryWorkspacesMoved(_ workspaceIDs: Set<String>, from oldSpaceID: String, to spaceID: String) {
        guard !workspaceIDs.isEmpty, oldSpaceID != spaceID else { return }
        // A session's record moves with its next event: look in every space.
        let spaces = Set(workspaceStore.profiles.map(\.id) + [WorkspaceProfile.defaultID, oldSpaceID, spaceID])
        var sessions: [String: ProjectHistoryCenter.Joining] = [:]
        for space in spaces.sorted() {
            for record in sessionLedger.sessions(inSpace: space, matching: AgentSessionLedger.Query(state: .active, agent: .claude))
            where record.workspaceID.map(workspaceIDs.contains) == true {
                sessions[record.sessionID] = .init(
                    sessionID: record.sessionID,
                    transcriptPath: ProjectHistory.feedPath(eventPath: nil, recordPath: record.transcriptPath, sessionID: record.sessionID)
                )
            }
        }
        guard !sessions.isEmpty else { return }
        projectHistory.sessionsJoined(
            spaceID: spaceID, sessions: sessions.values.sorted { $0.sessionID < $1.sessionID }, at: Date(), leaving: oldSpaceID
        )
    }

    /// At launch, after the hook backlog: turns written while Nirux was
    /// closed, in projects whose history is on.
    func catchUpProjectHistory() {
        let directory = Persistence.stateDirectory
        var sessions: [ProjectHistoryCenter.CatchUp] = []
        for spaceID in Set(workspaces.map(\.profileID)).sorted()
        where ProjectHistory.isEnabled(spaceID: spaceID, stateDirectory: directory) {
            for record in sessionLedger.sessions(
                inSpace: spaceID, matching: AgentSessionLedger.Query(agent: .claude, limit: 200)
            ) {
                guard let path = ProjectHistory.feedPath(
                    eventPath: nil, recordPath: record.transcriptPath, sessionID: record.sessionID
                ) else { continue }
                sessions.append(.init(
                    spaceID: spaceID, transcriptPath: path, sessionID: record.sessionID,
                    startedAt: record.startedAt, isRunning: record.isActive
                ))
            }
        }
        // Even with none: an import a crash cut short goes on.
        projectHistory.catchUp(sessions)
    }
}
