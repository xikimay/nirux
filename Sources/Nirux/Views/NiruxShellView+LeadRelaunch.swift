import AppKit

enum LeadLaunchIssue: String, CaseIterable {
    case olderOptions, stopped, missingTools

    var title: String {
        switch self {
        case .olderOptions: "Launched with older options"
        case .stopped: "Lead agent isn’t running"
        case .missingTools: "Started without Nirux’s tools"
        }
    }

    var action: String { self == .olderOptions ? "Relaunch" : "Restart Lead" }
}

enum LeadRecovery: Equatable {
    case launchIssue(LeadLaunchIssue)
    case relaunchAntigravity
}

struct LeadLaunchOptions {
    let claudeMode: ClaudeLaunchMode
    let codexMode: CodexLaunchMode
    let safety: ClaudeSpaceSettings.File?
}

extension ColumnState {
    func leadSessionID(for process: ForegroundProcess) -> String? {
        switch process.interactiveAgent {
        case .claude:
            guard case .resume(let id)? = persistedClaudeRestore(foregroundProcess: process) else { return nil }
            return id
        case .codex: return provenCodexSessionID(of: process)
        case .agy: return persistedAgySessionID(foregroundProcess: process)
        default: return nil
        }
    }

    func offersAntigravityRelaunch(foreground: ForegroundProcess?) -> Bool {
        foreground?.interactiveAgent == .agy && !isRestartingShell && relaunchingLeadSessionID == nil
    }

    func recordLeadSafety(file: String?) {
        leadSafetyAtLaunch = file.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            .flatMap { try? JSONDecoder().decode(ClaudeSpaceSettings.File.self, from: $0) }
    }
}

extension NiruxShellView {
    nonisolated static let leadRelaunchPrompt = "[Nirux] You resumed this conversation with the space’s current launch options. "
        + "Call list_tasks for pending questions and results."

    nonisolated static func leadRelaunchPrompt(for agent: CodingAgent) -> String {
        agent == .agy ? "You resumed this conversation. " + agyLeadPrompt : leadRelaunchPrompt
    }

    func currentLeadOptions(in lead: WorkspaceState) -> LeadLaunchOptions {
        let now = ProcessInfo.processInfo.systemUptime
        // Sidebar redraws share a read. Settings saves invalidate it immediately.
        if let cached = lead.leadOptionsCache, now - cached.readAt < 10 { return cached.options }
        let defaults = SpaceDefaultsStore.defaults(forSpace: lead.profileID)
        let anchors = profiles.first { $0.id == lead.profileID }?.anchors ?? []
        let options = LeadLaunchOptions(
            claudeMode: defaults.claudeLaunchMode ?? Self.currentClaudeLaunchMode(),
            codexMode: defaults.codexLaunchMode ?? Self.currentCodexLaunchMode(),
            safety: ClaudeSpaceSettings.file(defaults, repositories: ClaudeSpaceSettings.repositories(anchors),
                                             userEnvironment: Self.claudeUserEnvironment())
        )
        lead.leadOptionsCache = (options, now)
        return options
    }

    func leadLaunchIssue(in lead: WorkspaceState, foreground: ForegroundProcess?, snapshot: ProcessSnapshot) -> LeadLaunchIssue? {
        guard lead.isLead, !lead.isClosing else { return nil }
        guard let column = lead.leadTerminal else { return .stopped }
        guard !column.isAwaitingResume, !column.isRestartingShell, column.relaunchingLeadSessionID == nil, let pty = column.pty else { return nil }
        if pty.hasExited { return .stopped }
        guard let process = foreground, !process.arguments.isEmpty else { return nil }
        guard let agent = process.interactiveAgent, agent.isLaunchable else {
            guard let pid = pty.shellPID, !Self.isLaunchingRestoredAgent(foreground: process, shellPID: pid, hasExited: false),
                  snapshot.firstDescendantName(of: pid, where: { CodingAgent(launchable: $0) != nil }) == nil else { return nil }
            return .stopped
        }
        if agent == .codex {
            guard NiruxMCPServer.hasCodexLaunchOverride(in: process.arguments) else { return .missingTools }
            let mode = CodexLaunchMode.detect(arguments: process.arguments) ?? .default
            return mode == currentLeadOptions(in: lead).codexMode ? nil : .olderOptions
        }
        guard agent == .claude else { return nil }
        guard Self.hasNiruxTools(process.arguments) else { return .missingTools }
        let current = currentLeadOptions(in: lead)
        let mode = ClaudeLaunchMode.detect(arguments: process.arguments) ?? .default
        let equivalentBypass = [ClaudeLaunchMode.bypassPermissions, .skipPermissions]
        let sameMode = mode == current.claudeMode || (equivalentBypass.contains(mode) && equivalentBypass.contains(current.claudeMode))
        let passedSafety = process.arguments.filter { $0.hasPrefix("--settings=") }
        let expectedSafety = current.safety.flatMap { _ in ClaudeSpaceSettings.fileURL(spaceID: lead.profileID) }
            .map { ["--settings=" + $0.path] } ?? []
        return !sameMode || passedSafety != expectedSafety || (!passedSafety.isEmpty && column.leadSafetyAtLaunch != current.safety)
            ? .olderOptions : nil
    }

    private static func hasNiruxTools(_ arguments: [String]) -> Bool {
        let prefix = "--mcp-config="
        for argument in arguments where argument.hasPrefix(prefix) {
            let data = Data(argument.dropFirst(prefix.count).utf8)
            guard let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = config["mcpServers"] as? [String: [String: Any]],
                  let server = servers[NiruxMCPServer.serverName],
                  let command = server["command"] as? String, (command as NSString).lastPathComponent == "Nirux",
                  server["args"] as? [String] == ["--hook", "claude", "--mcp"] else { continue }
            return true
        }
        return false
    }

    func canRelaunchLeadSession(_ id: String, agent: CodingAgent, in column: ColumnState) -> Bool {
        let record = sessionLedger.session(agent: agent, sessionID: id)
        if let record, !AgentSessionResume.hasTranscript(for: record) {
            showToast(SessionHistory.message(.transcriptGone, agent: agent), tone: .error)
            return false
        }
        let others = agentSessionHolders(snapshot: ProcessSnapshot()).filter { $0.columnID != column.id }
        let recorded = record.flatMap(recordedColumn)
        guard !sessionResume.inFlight.contains(AgentSessionRecord.key(agent: agent.rawValue, sessionID: id)),
              HeldAgentSession.find(id, in: others) == nil, recorded == nil || recorded?.columnID == column.id else {
            showToast("Another column is holding or resuming this conversation.")
            return false
        }
        return true
    }

    func requestLeadRecovery(_ recovery: LeadRecovery, in lead: WorkspaceState) {
        guard leadWorkspace(inSpace: lead.profileID) === lead else { return }
        lead.leadOptionsCache = nil
        let snapshot = ProcessSnapshot()
        let column = lead.leadTerminal
        let process = column?.pty?.foregroundProcess(snapshot: snapshot)
        func applies(to foreground: ForegroundProcess?, snapshot: ProcessSnapshot) -> Bool {
            switch recovery {
            case .launchIssue(let issue): leadLaunchIssue(in: lead, foreground: foreground, snapshot: snapshot) == issue
            case .relaunchAntigravity: column?.offersAntigravityRelaunch(foreground: foreground) == true
            }
        }
        guard applies(to: process, snapshot: snapshot) else { return updateSidebar() }
        func stillApplies() -> Bool {
            lead.leadOptionsCache = nil
            let latest = ProcessSnapshot()
            let foreground = column?.pty?.foregroundProcess(snapshot: latest)
            return lead.leadTerminal === column && foreground?.instance == process?.instance
                && applies(to: foreground, snapshot: latest)
        }
        if case .launchIssue(let issue) = recovery, issue != .olderOptions {
            return requestRestartLead(spaceID: lead.profileID, stillApplies: stillApplies)
        }
        guard let column, let process, let agent = process.interactiveAgent else { return }
        guard let sessionID = column.leadSessionID(for: process), UUID(uuidString: sessionID) != nil else {
            return showToast("\(agent.name) hasn’t recorded a conversation to resume yet.")
        }
        let space = profiles.first { $0.id == lead.profileID }?.name ?? lead.profileID
        let options = agent == .claude ? "launch options and safety settings" : "launch options"
        var details = ["\(agent.productName) will resume this conversation with the space’s current \(options)."]
        if let warning = Self.leadTurnWarning(column.liveAgent(snapshot: snapshot)) { details.append(warning) }
        guard confirmDestructiveClose(message: "Relaunch the Lead of “\(space)”?", details: details, confirmTitle: "Relaunch"),
              leadWorkspace(inSpace: lead.profileID) === lead, stillApplies(),
              column.leadSessionID(for: process) == sessionID else { return }
        restartLead(lead, agent: agent, resuming: sessionID)
    }
}
