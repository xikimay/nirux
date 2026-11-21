import AppKit

enum LeadLaunchIssue: String, CaseIterable {
    case olderOptions, stopped, missingTools

    var title: String {
        switch self {
        case .olderOptions: "Launched with older options"
        case .stopped: "Claude isn’t running"
        case .missingTools: "Started without Nirux’s tools"
        }
    }

    var action: String { self == .olderOptions ? "Relaunch" : "Restart Lead" }
}

struct LeadLaunchOptions {
    let mode: ClaudeLaunchMode
    let safety: ClaudeSpaceSettings.File?
}

extension ColumnState {
    func recordLeadSafety(file: String?) {
        leadSafetyAtLaunch = file.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            .flatMap { try? JSONDecoder().decode(ClaudeSpaceSettings.File.self, from: $0) }
    }
}

extension NiruxShellView {
    nonisolated static let leadRelaunchPrompt = "[Nirux] You resumed this conversation with the space’s current launch options. "
        + "Call list_tasks for pending questions and results."

    func currentLeadOptions(in lead: WorkspaceState) -> LeadLaunchOptions {
        let now = ProcessInfo.processInfo.systemUptime
        // Sidebar redraws share a read. Settings saves invalidate it immediately.
        if let cached = lead.leadOptionsCache, now - cached.readAt < 10 { return cached.options }
        let defaults = SpaceDefaultsStore.defaults(forSpace: lead.profileID)
        let anchors = profiles.first { $0.id == lead.profileID }?.anchors ?? []
        let options = LeadLaunchOptions(
            mode: defaults.claudeLaunchMode ?? Self.currentClaudeLaunchMode(),
            safety: ClaudeSpaceSettings.file(defaults, repositories: ClaudeSpaceSettings.repositories(anchors),
                                             userEnvironment: Self.claudeUserEnvironment())
        )
        lead.leadOptionsCache = (options, now)
        return options
    }

    func leadLaunchIssue(in lead: WorkspaceState, foreground: ForegroundProcess?, snapshot: ProcessSnapshot) -> LeadLaunchIssue? {
        guard lead.isLead, !lead.isClosing else { return nil }
        guard let column = lead.leadTerminal else { return .stopped }
        guard !column.isAwaitingResume, !column.isRestartingShell, let pty = column.pty else { return nil }
        if pty.hasExited { return .stopped }
        guard let process = foreground, !process.arguments.isEmpty else { return nil }
        guard AgentHookCenter.isInteractiveClaude(process) else {
            guard let pid = pty.shellPID, !Self.isLaunchingRestoredAgent(foreground: process, shellPID: pid, hasExited: false),
                  snapshot.firstDescendantName(of: pid, where: { $0 == "claude" }) == nil else { return nil }
            return .stopped
        }
        guard Self.hasNiruxTools(process.arguments) else { return .missingTools }
        let current = currentLeadOptions(in: lead)
        let mode = ClaudeLaunchMode.detect(arguments: process.arguments) ?? .default
        let equivalentBypass = [ClaudeLaunchMode.bypassPermissions, .skipPermissions]
        let sameMode = mode == current.mode || (equivalentBypass.contains(mode) && equivalentBypass.contains(current.mode))
        let passedSafety = process.arguments.filter { $0.hasPrefix("--settings=") }
        let expectedSafety = current.safety.flatMap { _ in ClaudeSpaceSettings.fileURL(spaceID: lead.profileID) }
            .map { ["--settings=" + $0.path] } ?? []
        return !sameMode || passedSafety != expectedSafety || column.leadSafetyAtLaunch != current.safety
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

    func requestLeadRecovery(_ issue: LeadLaunchIssue, in lead: WorkspaceState) {
        guard leadWorkspace(inSpace: lead.profileID) === lead else { return }
        lead.leadOptionsCache = nil
        let snapshot = ProcessSnapshot()
        let column = lead.leadTerminal
        let process = column?.pty?.foregroundProcess(snapshot: snapshot)
        guard leadLaunchIssue(in: lead, foreground: process, snapshot: snapshot) == issue else { return updateSidebar() }
        func stillApplies() -> Bool {
            lead.leadOptionsCache = nil
            let latest = ProcessSnapshot()
            let foreground = column?.pty?.foregroundProcess(snapshot: latest)
            return lead.leadTerminal === column && foreground?.instance == process?.instance
                && leadLaunchIssue(in: lead, foreground: foreground, snapshot: latest) == issue
        }
        guard issue == .olderOptions else { return requestRestartLead(spaceID: lead.profileID, stillApplies: stillApplies) }
        guard let column, let process, case .resume(let sessionID)? = column.persistedClaudeRestore(foregroundProcess: process) else {
            return showToast("Claude hasn’t recorded a conversation to resume yet.")
        }
        let space = profiles.first { $0.id == lead.profileID }?.name ?? lead.profileID
        var details = ["Claude Code will resume this conversation with the space’s current launch options and safety settings."]
        if let warning = Self.leadTurnWarning(column.liveAgent(snapshot: snapshot)?.status) { details.append(warning) }
        guard confirmDestructiveClose(message: "Relaunch the Lead of “\(space)”?", details: details, confirmTitle: "Relaunch"),
              leadWorkspace(inSpace: lead.profileID) === lead, stillApplies(),
              column.persistedClaudeRestore(foregroundProcess: process) == .resume(sessionID) else { return }
        restartLead(lead, resuming: sessionID)
    }
}
