import Foundation

/// One agent conversation in a space's session history (see
/// `AgentSessionLedger`): which session, where it ran, and when. Built from
/// the hook events of a column's own agent, never from transcripts, whose
/// format is internal to each agent.
struct AgentSessionRecord: Codable, Equatable, Sendable {
    /// What the agent was last doing. An ended session keeps the status it
    /// ended with: one that ended `working` was cut off mid-turn.
    enum Status: String, Codable, Sendable {
        /// Started, never prompted yet.
        case started
        case working
        /// A permission dialog waits on the user.
        case waiting
        /// The turn is over; the agent waits for the next prompt.
        case idle
        /// The last turn ended on an API error (rate limit, overload…).
        case failed
    }

    /// The git checkout the session ran in, read from its workspace.
    struct Checkout: Codable, Equatable, Sendable {
        var branch: String
        /// The checkout's top level. A worktree's goes away when it is
        /// cleaned up.
        var worktreeRoot: String
        /// The repository's main working tree, from which a removed worktree
        /// can be recreated. Nil for a bare repository.
        var mainCheckout: String?
        /// `host/owner/name` of the GitHub repository, when known.
        var repository: String?
        /// The commit checked out at the last event: once the branch is
        /// deleted after its merge, the worktree can come back at it.
        var head: String?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case branch, worktreeRoot, mainCheckout, repository, head
        }
    }

    struct PullRequest: Codable, Equatable, Sendable {
        var number: Int
        var url: String
        /// GitHub's state: OPEN, MERGED or CLOSED.
        var state: String

        enum CodingKeys: String, CodingKey, CaseIterable {
            case number, url, state
        }
    }

    /// Line format version (see `AgentSessionLedger.schemaVersion`).
    var schemaVersion: Int
    var agent: AgentHookEvent.Kind
    /// Claude `session_id` / Codex thread id.
    var sessionID: String
    /// The name the session was launched with (`claude --name`). Renames
    /// made later, with `/rename` or from claude.ai, aren't seen.
    var name: String?
    /// Where the agent last reported working.
    var cwd: String?
    /// Claude's transcript, as its turns report it.
    var transcriptPath: String?
    var checkout: Checkout?
    var pullRequest: PullRequest?
    /// Epoch seconds (the hook receiver's clock). `lastStartAt` is the
    /// latest start or resume: events older than it belong to an earlier
    /// run of the session.
    var startedAt: TimeInterval
    var lastStartAt: TimeInterval
    var lastActivityAt: TimeInterval
    /// Nil while the session runs. History, not a lock: a restored Codex
    /// thread reads as ended until its first turn completes.
    var endedAt: TimeInterval?
    var status: Status
    /// Prompted at least once: there is a conversation to resume.
    var hasConversation: Bool
    /// Where it ran: the workspace (title frozen at the last event) and the
    /// column, by its `NIRUX_AGENT_UUID` and its position then.
    var workspaceID: String?
    var workspaceTitle: String?
    var agentUUID: String?
    var columnIndex: Int?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "v"
        case agent, sessionID, name, cwd, transcriptPath, checkout, pullRequest
        case startedAt, lastStartAt, lastActivityAt, endedAt, status, hasConversation
        case workspaceID, workspaceTitle, agentUUID, columnIndex
    }

    /// Records are keyed by agent and session: two agents' ids never clash.
    var key: String { Self.key(agent: agent.rawValue, sessionID: sessionID) }

    static func key(agent: String, sessionID: String) -> String {
        "\(agent):\(sessionID)"
    }

    var isActive: Bool { endedAt == nil }
}

/// What one hook event says about its session, with the context the shell
/// read for it (workspace, git checkout, pull request).
struct AgentSessionObservation: Sendable {
    let agent: AgentHookEvent.Kind
    let sessionID: String
    let event: AgentHookEvent.Name
    /// Claude SessionStart `source`.
    let source: String?
    let timestamp: TimeInterval
    /// The column's agent, when it proved it runs this session: the event
    /// may then create or reopen its record. Nil for any other event (a
    /// replay after the agent exited, an emitter that can't be named),
    /// which only updates the open record of the same column.
    let agentProcess: ProcessInstance?
    let name: String?
    let cwd: String?
    let transcriptPath: String?
    let checkout: AgentSessionRecord.Checkout?
    let pullRequest: AgentSessionRecord.PullRequest?
    let workspaceID: String?
    let workspaceTitle: String?
    let agentUUID: String?
    let columnIndex: Int?

    var isFromColumnAgent: Bool { agentProcess != nil }
    var key: String { AgentSessionRecord.key(agent: agent.rawValue, sessionID: sessionID) }

    /// Events the history follows. Tool and notification events fire far
    /// too often and say nothing a record keeps; a PostToolUse only counts
    /// when it answers a permission dialog.
    static func isTracked(_ name: AgentHookEvent.Name) -> Bool {
        switch name {
        case .sessionStart, .userPromptSubmit, .permissionRequest, .postToolUse, .stop, .stopFailure,
             .sessionEnd, .turnComplete:
            return true
        case .preToolUse, .notification, .subagentStop, .approvalResolved:
            return false
        }
    }

    /// The name a `claude` was launched with: `--name=<name>`, `--name
    /// <name>` or `-n <name>`. Nirux passes none to a resume, which keeps
    /// its name.
    static func launchName(arguments: [String]) -> String? {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--" { return nil }
            if argument.hasPrefix("--name=") {
                return nonEmpty(String(argument.dropFirst("--name=".count)))
            }
            if argument == "--name" || argument == "-n" {
                return arguments[safe: index + 1].flatMap(nonEmpty)
            }
            index += 1
        }
        return nil
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(200))
    }
}

extension AgentSessionRecord {
    /// `existing` updated with `observation`, or a new record. Nil when the
    /// observation changes nothing or isn't allowed to: only the column's
    /// own agent creates or reopens a record, and anything else must come
    /// from the column the open record belongs to, for its current run.
    static func applying(_ observation: AgentSessionObservation, to existing: AgentSessionRecord?) -> AgentSessionRecord? {
        guard AgentSessionObservation.isTracked(observation.event) else { return nil }
        if observation.event == .postToolUse, existing?.status != .waiting { return nil }
        var record: AgentSessionRecord
        if let existing {
            record = existing
            // The end of an earlier run, drained late.
            if observation.event == .sessionEnd, observation.timestamp < existing.lastStartAt { return nil }
            if !observation.isFromColumnAgent {
                guard observation.agentUUID != nil, observation.agentUUID == existing.agentUUID,
                      observation.timestamp >= existing.lastStartAt else { return nil }
                // An ended session only learns when it really ended.
                if !existing.isActive {
                    guard observation.event == .sessionEnd, existing.endedAt != observation.timestamp else { return nil }
                    record.endedAt = observation.timestamp
                    return record
                }
            } else if let endedAt = existing.endedAt, observation.event != .sessionEnd {
                // Resumed (restore, `--resume`, `/resume`). A start always is:
                // its agent's exit may have been noticed before it was
                // drained. Any other event must come after the end.
                guard observation.event == .sessionStart || observation.timestamp >= endedAt else { return nil }
                record.endedAt = nil
                record.lastStartAt = max(existing.lastStartAt, observation.timestamp)
            }
        } else {
            guard observation.isFromColumnAgent, observation.event != .sessionEnd else { return nil }
            record = AgentSessionRecord(
                schemaVersion: AgentSessionLedger.schemaVersion,
                agent: observation.agent,
                sessionID: observation.sessionID,
                startedAt: observation.timestamp,
                lastStartAt: observation.timestamp,
                lastActivityAt: observation.timestamp,
                status: .started,
                hasConversation: false
            )
        }
        record.apply(observation)
        return record == existing ? nil : record
    }

    private mutating func apply(_ observation: AgentSessionObservation) {
        let timestamp = observation.timestamp
        // Replays can arrive out of order: only the newest event sets the
        // status.
        let isNewest = timestamp >= lastActivityAt
        lastActivityAt = max(lastActivityAt, timestamp)
        // A compaction goes on with the same run.
        if observation.event == .sessionStart, observation.source != "compact" {
            lastStartAt = max(lastStartAt, timestamp)
        }
        if isNewest, let status = nextStatus(after: observation) {
            self.status = status
        }
        if Self.hasConversation(after: observation) { hasConversation = true }
        if observation.event == .sessionEnd {
            endedAt = timestamp
        }
        if let name = observation.name { self.name = name }
        if let cwd = observation.cwd { self.cwd = cwd }
        if let transcriptPath = observation.transcriptPath, isReliable(transcriptPathOf: observation) {
            self.transcriptPath = transcriptPath
        }
        if let checkout = observation.checkout {
            if let current = self.checkout, Self.isResumed(current, at: checkout) {
                if checkout.worktreeRoot == current.worktreeRoot { self.checkout?.head = checkout.head ?? current.head }
            } else {
                // Another branch or checkout: its pull request, if known yet.
                if checkout.branch != self.checkout?.branch || checkout.worktreeRoot != self.checkout?.worktreeRoot {
                    pullRequest = observation.pullRequest
                }
                self.checkout = checkout
                if let pullRequest = observation.pullRequest { self.pullRequest = pullRequest }
            }
        }
        if let workspaceID = observation.workspaceID { self.workspaceID = workspaceID }
        if let workspaceTitle = observation.workspaceTitle { self.workspaceTitle = workspaceTitle }
        if let agentUUID = observation.agentUUID { self.agentUUID = agentUUID }
        if let columnIndex = observation.columnIndex { self.columnIndex = columnIndex }
    }

    /// Where a Resume brings a session whose worktree was cleaned up (see
    /// AgentSessionResume): its worktree back at its last commit, detached
    /// ("HEAD"), or the repository's main checkout. It keeps its branch and
    /// pull request, and a later Resume still knows its worktree.
    private static func isResumed(_ current: Checkout, at checkout: Checkout) -> Bool {
        let detachedInPlace = checkout.worktreeRoot == current.worktreeRoot
            && checkout.branchName == nil && current.branchName != nil
        let inMainCheckout = current.mainCheckout != current.worktreeRoot && checkout.worktreeRoot == current.mainCheckout
        return detachedInPlace || inMainCheckout
    }

    /// A session resumed from another folder reports, at its start, a
    /// transcript under that folder, which doesn't exist: Claude keeps
    /// appending to the original file, and its turns report that one. A new
    /// session's start reports its own file.
    private func isReliable(transcriptPathOf observation: AgentSessionObservation) -> Bool {
        switch observation.event {
        case .stop, .stopFailure:
            return true
        case .sessionStart:
            return transcriptPath == nil && ["startup", "clear", "fork"].contains(observation.source)
        default:
            return false
        }
    }

    private func nextStatus(after observation: AgentSessionObservation) -> Status? {
        switch observation.event {
        case .sessionStart:
            switch observation.source {
            case "startup", "clear": return .started
            case "resume": return .idle
            // A compaction happens mid-turn as often as between turns.
            default: return nil
            }
        case .userPromptSubmit: return .working
        case .permissionRequest: return .waiting
        // The dialog was answered and the tool ran.
        case .postToolUse: return .working
        case .stop, .turnComplete: return .idle
        case .stopFailure: return .failed
        case .sessionEnd, .preToolUse, .notification, .subagentStop, .approvalResolved: return nil
        }
    }

    /// Mirrors `ClaudeSessionTracker`: a session started fresh or by
    /// `/clear` has nothing to resume until its first prompt; any other
    /// start (resume, compaction, fork) carries a conversation.
    private static func hasConversation(after observation: AgentSessionObservation) -> Bool {
        switch observation.event {
        case .userPromptSubmit, .permissionRequest, .postToolUse, .stop, .stopFailure, .turnComplete:
            return true
        case .sessionStart:
            guard let source = observation.source else { return false }
            return source != "startup" && source != "clear"
        case .sessionEnd, .preToolUse, .notification, .subagentStop, .approvalResolved:
            return false
        }
    }

    // MARK: - Checkouts on disk

    /// Main working tree of the repository whose checkout is at
    /// `worktreeRoot`, read from its `.git` without running git: the
    /// checkout itself unless it is a linked worktree, then the folder
    /// holding the shared `.git`. Nil for a bare repository's worktree or
    /// a folder that isn't a checkout.
    static func mainCheckout(ofWorktreeAt worktreeRoot: String) -> String? {
        let layout = GitRepositoryLayout.resolve(worktreeRoot: worktreeRoot)
        guard let gitDirectory = layout.gitDirectory, let commonDirectory = layout.commonDirectory else { return nil }
        guard gitDirectory != commonDirectory else { return layout.worktreeRoot }
        let common = URL(fileURLWithPath: commonDirectory)
        guard common.lastPathComponent == ".git" else { return nil }
        return common.deletingLastPathComponent().path
    }

    /// The top level of the checkout holding `path`: the nearest folder,
    /// `path` included, with a `.git`. A worktree nested in another
    /// checkout (`claude --worktree` puts them under `.claude/worktrees/`)
    /// is its own.
    static func checkoutRoot(containing path: String) -> String? {
        var folder = URL(fileURLWithPath: path).standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) {
                return folder.path
            }
            let parent = folder.deletingLastPathComponent()
            guard parent.path != folder.path else { return nil }
            folder = parent
        }
    }
}
