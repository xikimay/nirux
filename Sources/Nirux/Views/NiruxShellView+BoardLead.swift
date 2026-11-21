import Foundation

extension NiruxShellView {
    func boardLeadStatus(
        of lead: WorkspaceState, columns: [ColumnInfo], foreground: [ObjectIdentifier: ForegroundProcess],
        snapshot: ProcessSnapshot, now: TimeInterval, store: MissionStore = .shared
    ) -> BoardStagesView.Lead {
        let sessions = lead.openColumns.compactMap { column -> BoardLeadSession? in
            guard let info = columns.first(where: { $0.id == column.id }) else { return nil }
            return BoardLeadSession(column, info: info, foreground: foreground[ObjectIdentifier(column)], snapshot: snapshot, now: now)
        }
        guard store.ensureLoaded() else { return .init(state: .idle, text: "Lead · Mission routes unavailable") }
        lazy var handoffsEnabled = Self.currentMissionHandoffsEnabled()
        var routes: [String: [String]] = [:]
        for mission in store.missions where mission.parentWorkspaceID == lead.id && mission.oneWay != true
            && (mission.isAlwaysCarried || handoffsEnabled) {
            let child = workspaces.first { $0.id == mission.childWorkspaceID }
            guard child == nil || child?.profileID == lead.profileID else { continue }
            let isOpen = child?.isClosing == false
            let session = sessions.first { $0.agentUUID == mission.parentAgentUUID }
            guard (isOpen && mission.status == .active) || mission.events.contains(where: { event in
                guard Self.goesToParent(event) else { return false }
                if session?.agent == .claude { return MissionStore.isPendingDelivery(event, in: mission, now: now) }
                return MissionStore.awaitsParentReceipt(event, in: mission)
            }) else { continue }
            routes[mission.parentAgentUUID, default: []].append(child?.title ?? mission.branch)
        }
        return BoardLeadSession.header(sessions: sessions, routes: routes)
    }
}

private struct BoardLeadSession {
    let agentUUID: String
    let agent: CodingAgent
    let index: Int
    let name: String
    var status: BoardStagesView.Lead

    @MainActor
    init?(_ column: ColumnState, info: ColumnInfo, foreground: ForegroundProcess?, snapshot: ProcessSnapshot, now: TimeInterval) {
        guard let uuid = column.agentUUID, NiruxShellView.terminalCarriesMissions(column.launchEnvironment),
              let agent = column.missionAgent(foreground: foreground) ?? info.stuck?.agentName.flatMap(CodingAgent.init(launchable:))
        else { return nil }
        self.agentUUID = uuid
        self.agent = agent
        self.index = info.index
        self.name = agent.productName
        if agent == .claude, case .stoppedOnError? = info.stuck, let emitter = column.pty?.agentTurnFailure?.emitter,
           let foreground, !snapshot.ownsEmitter(emitter, foreground: foreground) {
            status = .init(state: .idle, text: "Status unknown")
        } else {
            status = Self.status(of: column, info: info, agent: agent, foreground: foreground, now: now)
        }
        status.columnID = column.id
    }

    @MainActor
    private static func status(
        of column: ColumnState, info: ColumnInfo, agent: CodingAgent, foreground: ForegroundProcess?, now: TimeInterval
    ) -> BoardStagesView.Lead {
        if column.deferredAgent != nil { return .init(state: .idle, text: "Paused · Resume in terminal") }
        if let stuck = info.stuck, stuck.isFailure, agent == .claude || stuck.agentName == agent.rawValue {
            var advice = "Open its terminal to continue."
            if case .stoppedOnError(_, _, _, let resume) = stuck {
                advice = resume.status ?? "Use Resume in the sidebar or continue in its terminal."
            }
            return .init(state: .failed, text: sentence(stuck.headline), detail: [stuck.detail, advice].compactMap { $0 }.joined(separator: "\n"))
        }
        if agent == .codex, let foreground {
            guard let report = column.pty?.codexStatus(of: foreground.instance) else { return .init(state: .idle, text: "Status unknown") }
            switch report.state {
            case .working: return .init(state: .working, text: "Working")
            case .done, .idle: return .init(state: .idle, text: "Idle")
            case .blocked:
                return .init(state: .needsYou, text: "Needs you", detail: report.message, reason: StateIcon.Reason(report.attentionReason) ?? .question)
            case .error:
                return .init(state: .failed, text: "Stopped on an error", detail: failureDetail(report.message))
            }
        }
        if agent == .agy, let wait = column.pty?.agentBlockedWait(now: now, waitThreshold: nil, foreground: foreground) {
            if wait.reason.isFailure {
                return .init(state: .failed, text: sentence(wait.reason.headline), detail: failureDetail(wait.reason.cleanDetailLine))
            }
            return .init(state: .needsYou, text: "Needs you", detail: wait.reason.toolTip, reason: StateIcon.Reason(wait.reason) ?? .question)
        }
        switch info.attention {
        case .error where agent != .claude:
            return .init(state: .failed, text: info.attentionSummary.map { sentence($0.headline) } ?? "Stopped",
                         detail: failureDetail(info.attentionSummary?.detail))
        case .waiting:
            return .init(state: .needsYou, text: "Needs you", detail: info.attentionToolTip, reason: WorkspaceInfo.waitReason(of: info))
        default:
            return info.agentStatus == .working ? .init(state: .working, text: "Working") : .init(state: .idle, text: "Idle")
        }
    }

    private static func failureDetail(_ message: String?) -> String {
        [message, "Open its terminal to continue."].compactMap { $0 }.joined(separator: "\n")
    }

    private static func sentence(_ phrase: String) -> String { phrase.prefix(1).uppercased() + phrase.dropFirst() }

    static func header(sessions: [Self], routes: [String: [String]]) -> BoardStagesView.Lead {
        let candidates = sessions.filter { routes.isEmpty || routes[$0.agentUUID] != nil }
        let missing = routes.keys.filter { uuid in !sessions.contains { $0.agentUUID == uuid } }
        var header: BoardStagesView.Lead
        if candidates.count > 1 && routes.count > 1 {
            let names = candidates.map(\.name) + (missing.isEmpty ? [] : ["unknown destination"])
            let stopped = missing.isEmpty && candidates.allSatisfy { $0.status.state == .failed }
            let destinations = stopped ? "multiple stopped sessions" : "multiple sessions"
            header = .init(state: stopped ? .failed : .idle, text: "Lead · Missions report to \(destinations) (\(names.joined(separator: ", ")))")
        } else if !missing.isEmpty {
            header = .init(state: .idle, text: "Lead · Mission destination unknown")
        } else if candidates.count == 1, let session = candidates.first {
            header = session.status
            header.text = "Lead · \(session.name) · \(session.status.text)"
        } else {
            header = .init(state: .idle, text: candidates.isEmpty ? "Lead · No identifiable session" : "Lead · Active session unclear")
        }
        var details: [String] = []
        for session in sessions {
            let tasks = routes[session.agentUUID]
            guard routes.isEmpty || tasks != nil || session.status.state == .failed else { continue }
            let terminal = "\(session.name) (terminal \(session.index + 1))"
            var line = "\(terminal) · \(session.status.text)"
            if let tasks { line += " — " + tasks.sorted().joined(separator: ", ") }
            if !routes.isEmpty && tasks == nil { line += " (no reporting Missions)" }
            if let detail = session.status.detail { line += "\n" + detail }
            details.append(line)
        }
        for uuid in missing.sorted() {
            details.append("Unidentified terminal — " + (routes[uuid] ?? []).sorted().joined(separator: ", "))
        }
        header.detail = details.isEmpty ? nil : details.joined(separator: "\n")
        return header
    }
}
