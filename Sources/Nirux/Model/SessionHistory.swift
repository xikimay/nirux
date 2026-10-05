import Foundation

/// How the session history (see `AgentSessionLedger`) shows a recorded
/// session: ⌘P lists a space's past sessions under "Sessions", and picking
/// one resumes it (`NiruxShellView.resumeSession`).
enum SessionHistory {
    static let paletteSectionTitle = "Sessions"
    /// ⌘P lists this many past sessions at most, the most recently active.
    static let paletteLimit = 50

    /// The name it was launched with (a worktree's branch), else the
    /// workspace it ran in, else its branch or folder.
    static func title(of record: AgentSessionRecord) -> String {
        let candidates = [
            record.name,
            record.workspaceTitle,
            record.checkout?.branchName,
            folder(of: record).map { URL(fileURLWithPath: $0).lastPathComponent }
        ]
        if let title = candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return title
        }
        return agentName(record.agent) + " session"
    }

    /// "2 h ago · feat/x · #112 merged · ~/Projects/repo.feat-x": when it
    /// was last active, its branch unless the title says it already, its
    /// pull request, and its folder (kept by the palette's middle
    /// truncation).
    static func subtitle(of record: AgentSessionRecord, now: TimeInterval, displayPath: (String) -> String) -> String {
        ([ago(now - record.lastActivityAt)] + details(of: record, displayPath: displayPath)).joined(separator: " · ")
    }

    /// Its branch unless the title says it, its pull request, its folder.
    static func details(of record: AgentSessionRecord, displayPath: (String) -> String) -> [String] {
        let title = title(of: record)
        // A worktree session's name is "<branch> · <space>".
        let branch = record.checkout?.branchName.flatMap { $0 == title || title.hasPrefix($0 + " · ") ? nil : $0 }
        return [branch, record.pullRequest.map(pullRequestLabel), folder(of: record).map(displayPath)].compactMap { $0 }
    }

    /// What ⌘P searches: the title, then the branch, the workspace, the
    /// folder's name and the pull request ("#112").
    static func candidate(of record: AgentSessionRecord) -> PaletteRanking.Candidate {
        let keys = [
            record.checkout?.branchName,
            record.workspaceTitle,
            folder(of: record).map { URL(fileURLWithPath: $0).lastPathComponent },
            record.pullRequest.map { "#\($0.number)" }
        ]
        return PaletteRanking.Candidate(title: title(of: record), keys: keys.compactMap { $0 })
    }

    /// The checkout it ran in, else the folder it last reported.
    static func folder(of record: AgentSessionRecord) -> String? {
        record.checkout?.worktreeRoot ?? record.cwd
    }

    /// "#112 merged".
    static func pullRequestLabel(_ pullRequest: AgentSessionRecord.PullRequest) -> String {
        "#\(pullRequest.number) \(pullRequest.state.lowercased())"
    }

    static func agentName(_ agent: AgentHookEvent.Kind) -> String {
        switch agent {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// "just now", "12 min ago", "3 h ago", "yesterday", "5 days ago".
    static func ago(_ seconds: TimeInterval) -> String {
        let seconds = max(0, Int(seconds))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86_400: return "\(seconds / 3600) h ago"
        case ..<(2 * 86_400): return "yesterday"
        default: return "\(seconds / 86_400) days ago"
        }
    }

    /// Why a session can't be resumed, for a toast.
    static func message(_ reason: AgentSessionResume.Unavailable, agent: AgentHookEvent.Kind) -> String {
        switch reason {
        case .noConversation:
            return "This session was never prompted: there is nothing to resume"
        case .transcriptGone:
            return "\(agentName(agent)) deleted this session’s transcript: it can’t be resumed"
        case .noFolder:
            return "The session’s folder no longer exists, and there is no checkout of its repository to resume it in"
        }
    }
}

/// Where a session runs now, or is about to: a Resume goes there instead of
/// starting a second agent on the same conversation (two agents appending
/// to one transcript corrupt it).
struct HeldAgentSession: Equatable {
    enum State: Equatable {
        /// Its agent runs it, or was just launched to resume it.
        case running
        /// A restored column whose agent hasn't resumed yet: going there
        /// resumes it.
        case restored
        /// Its agent died mid-turn, and the column offers to resume it
        /// (`resumeExitedAgent`).
        case exited
    }

    let workspaceID: String
    let columnID: UUID
    let state: State
}

/// What one column holds, as `HeldAgentSession.find` reads it.
struct AgentSessionHolder {
    let workspaceID: String
    let columnID: UUID
    /// What its agents run: the sessions their hooks confirmed, else their
    /// arguments (a launch's `--resume <id>`).
    var liveText: [String] = []
    /// A launch typed or started in it resumes this session, and its agent
    /// may not show as a process yet (see `SessionResumeState`).
    var launchedSessionID: String?
    /// The session its restored agent will resume.
    var deferredSessionID: String?
    /// The session its agent ran when it died mid-turn.
    var exitedSessionID: String?

    /// Whether `texts` (arguments, session ids) name `sessionID`: as an
    /// argument of its own (`--resume <id>`) or after an `=`
    /// (`--resume=<id>`). Not inside another word: a short id would match
    /// anything.
    static func mentions(_ sessionID: String, in texts: [String]) -> Bool {
        guard !sessionID.isEmpty else { return false }
        let id = sessionID.lowercased()
        return texts.contains { text in
            let text = text.lowercased()
            return text == id || text.hasSuffix("=" + id)
        }
    }
}

extension HeldAgentSession {
    /// The column that holds `sessionID`: one whose agent runs it, else
    /// one that will (a restored column), else one whose agent died on it.
    static func find(_ sessionID: String, in holders: [AgentSessionHolder]) -> HeldAgentSession? {
        guard !sessionID.isEmpty else { return nil }
        let order: [(State, (AgentSessionHolder) -> Bool)] = [
            (.running, { $0.launchedSessionID == sessionID || AgentSessionHolder.mentions(sessionID, in: $0.liveText) }),
            (.restored, { $0.deferredSessionID == sessionID }),
            (.exited, { $0.exitedSessionID == sessionID })
        ]
        for (state, holds) in order {
            if let holder = holders.first(where: holds) {
                return HeldAgentSession(workspaceID: holder.workspaceID, columnID: holder.columnID, state: state)
            }
        }
        return nil
    }
}

extension DeferredAgentLaunch.Agent {
    /// The session it will resume; nil for a fresh agent or the picker.
    var sessionID: String? {
        switch self {
        case .claude(.session(let sessionID)?, _), .codex(.session(let sessionID), _):
            return sessionID
        default:
            return nil
        }
    }
}

// MARK: - The Session History panel

/// What the Session History panel lists: a space's sessions, the ones a
/// column holds first ("Open"), then the ended ones.
struct SessionHistoryFilter: Equatable {
    var text = ""
    var pullRequest = AgentSessionLedger.Query.PullRequestFilter.any
    /// The agent switch does what typing its name would.
    var agent: AgentHookEvent.Kind?

    func admits(_ record: AgentSessionRecord) -> Bool {
        switch pullRequest {
        case .any: break
        case .with: guard record.pullRequest != nil else { return false }
        case .without: guard record.pullRequest == nil else { return false }
        }
        return agent.map { $0 == record.agent } ?? true
    }
}

struct SessionHistoryRow: Equatable {
    let record: AgentSessionRecord
    /// The column that holds it, when the list was made: Return looks
    /// again before it goes there.
    let held: HeldAgentSession?
    /// "workspace › column", for a held session.
    let place: String?
    /// What its column's agent does now, as ⌘P shows it: the history only
    /// knows the last event it saw.
    var liveState: QuickSwitchAgentState?

    var isOpen: Bool { held != nil }
}

extension SessionHistory {
    /// The panel's rows: `records` (newest first, as the ledger gives them)
    /// that can be resumed, the held ones first. `holder` finds the column
    /// of a session, `place` names it, `liveState` reads its agent.
    static func rows(
        _ records: [AgentSessionRecord],
        holder: (AgentSessionRecord) -> HeldAgentSession?,
        place: (HeldAgentSession) -> String?,
        liveState: (AgentSessionRecord, HeldAgentSession) -> QuickSwitchAgentState?
    ) -> [SessionHistoryRow] {
        let rows = records.filter(\.isResumable).map { record in
            let held = holder(record)
            return SessionHistoryRow(
                record: record, held: held, place: held.flatMap(place), liveState: held.flatMap { liveState(record, $0) }
            )
        }
        return rows.filter(\.isOpen) + rows.filter { !$0.isOpen }
    }

    /// `rows` that `filter` admits. With text, each part (open, ended) lists
    /// what matches the way ⌘P ranks it: a title it names first, then the
    /// best match, the most recent first among equals.
    static func filtered(_ rows: [SessionHistoryRow], by filter: SessionHistoryFilter) -> [SessionHistoryRow] {
        let admitted = rows.filter { filter.admits($0.record) }
        let text = filter.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return admitted }
        func ranked(_ part: [SessionHistoryRow]) -> [SessionHistoryRow] {
            let order = PaletteRanking.rank(query: text, sections: [part.map { candidate(of: $0.record) }])
            return order.first?.rows.map { part[$0] } ?? []
        }
        return ranked(admitted.filter(\.isOpen)) + ranked(admitted.filter { !$0.isOpen })
    }

    /// What Return does on a row, shown under the list before it is
    /// pressed. `plan` is nil while it is computed.
    static func outcome(
        of row: SessionHistoryRow, plan: Result<AgentSessionResume.Plan, AgentSessionResume.Unavailable>?,
        displayPath: (String) -> String
    ) -> (action: String, detail: String?, isWarning: Bool, isPossible: Bool) {
        if let held = row.held {
            let place = row.place ?? "its column"
            switch held.state {
            case .running: return ("Go to \(place)", nil, false, true)
            case .restored: return ("Go to \(place)", "Its agent resumes there.", false, true)
            case .exited: return ("Go to \(place)", "Its agent exited mid-turn: it resumes there.", false, true)
            }
        }
        switch plan {
        case nil:
            return ("Resume", nil, false, true)
        case .failure(let reason):
            return ("Can’t resume", message(reason, agent: row.record.agent), false, false)
        case .success(let plan):
            var action: String
            switch plan.place {
            case .original, .branchCheckout, .mainCheckout:
                action = "Resume in \(displayPath(plan.directory))"
            case .recreatedWorktree:
                action = "Bring the worktree back at \(displayPath(plan.directory)), then resume"
            }
            if plan.warning != nil { action += " (asks first)" }
            return (action, plan.warning, plan.warning != nil, true)
        }
    }
}

extension AgentSessionRecord {
    /// Claude and Codex name sessions with UUIDs, as restores require: an
    /// id from a hand-edited history must not reach a launch line, where
    /// `--resume -x` would read as an option.
    var isResumable: Bool { UUID(uuidString: sessionID) != nil }
}
