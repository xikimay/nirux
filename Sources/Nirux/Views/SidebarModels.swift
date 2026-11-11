import AppKit

struct ColumnInfo: Hashable {
    let index: Int
    let processName: String?
    let abbreviatedCwd: String?
    let isFocused: Bool
    let isWebView: Bool
    let webTitle: String?
    let terminalTitle: String?
    let agentStatus: AgentStatus
    let isEditor: Bool
    let editorFileName: String?
    var isProjectBoard = false
    var isBranchReview = false
    /// Active editor tab has unsaved changes — rendered as a dirty dot
    /// next to the file name.
    var editorIsDirty: Bool = false
    /// Elapsed time in the agent's current turn — shown for working agents
    /// ("· 12m"). Nil for non-terminal columns / between turns.
    var agentElapsedSeconds: TimeInterval?
    /// Why the agent waits on the user (set with `.needsAttention`).
    var attentionReason: AgentAttentionReason?
    /// A permission request the sidebar can answer (Allow / Deny).
    var permissionApproval: SidebarPermissionApproval?
    /// The dialog the agent in front shows while it doesn't work, whatever
    /// its status: focusing the column, or the app, clears the attention,
    /// not the dialog (`AgentStatusMachine.visibleDialog`).
    var openDialog: AgentAttentionReason?
    /// An agent that won't go on by itself, whatever the status says.
    var stuck: SidebarStuckState?
    /// A restored agent that hasn't resumed yet.
    var deferredAgent: SidebarDeferredAgent?
    /// A Mission question this column's agent waits on.
    var missionQuestion: SidebarMissionQuestion?
    /// The agent may be going in circles in its turn in flight
    /// (`AgentCirclingHint`), which the row says while it works; nil with
    /// the hint turned off in Settings.
    var circling: AgentCirclingHint?
    /// The question this column's Claude ended its turn on, while it waits
    /// at a quiet prompt: Yes / No / Reply… answer it from the card.
    var turnQuestion: SidebarTurnQuestion?
    /// The column's identity (`ColumnState.id`): a menu's items find it by it.
    var id: UUID?

    /// Hashable is hand-written to compare `agentElapsedSeconds` at the
    /// granularity it's *displayed* ("12m" via shortDuration), not raw
    /// seconds: the sidebar's render-signature gate would otherwise see a
    /// change on every 2s heartbeat while an agent merely gets older. The
    /// terminal title, which the row doesn't show, is left out: a working
    /// agent's spinner retitles its column 4 times a second. The cwd counts:
    /// a row without a branch shows it.
    /// Nothing in the first minute: a time in seconds would rebuild the
    /// sidebar (and drop its tooltips) every heartbeat.
    var elapsedDisplay: String? {
        guard agentStatus == .working, let agentElapsedSeconds, agentElapsedSeconds >= 60 else { return nil }
        return SidebarRenderer.shortDuration(agentElapsedSeconds)
    }

    static func == (lhs: ColumnInfo, rhs: ColumnInfo) -> Bool {
        lhs.index == rhs.index
            && lhs.processName == rhs.processName
            && lhs.abbreviatedCwd == rhs.abbreviatedCwd
            && lhs.isFocused == rhs.isFocused
            && lhs.isWebView == rhs.isWebView
            && lhs.webTitle == rhs.webTitle
            && lhs.agentStatus == rhs.agentStatus
            && lhs.isEditor == rhs.isEditor
            && lhs.editorFileName == rhs.editorFileName
            && lhs.isProjectBoard == rhs.isProjectBoard
            && lhs.isBranchReview == rhs.isBranchReview
            && lhs.editorIsDirty == rhs.editorIsDirty
            && lhs.elapsedDisplay == rhs.elapsedDisplay
            && lhs.attentionReason == rhs.attentionReason
            && lhs.permissionApproval == rhs.permissionApproval
            && lhs.openDialog == rhs.openDialog
            && lhs.stuck == rhs.stuck
            && lhs.deferredAgent == rhs.deferredAgent
            && lhs.missionQuestion == rhs.missionQuestion
            && lhs.turnQuestion == rhs.turnQuestion
            && lhs.circling == rhs.circling
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(index)
        hasher.combine(processName)
        hasher.combine(abbreviatedCwd)
        hasher.combine(isFocused)
        hasher.combine(isWebView)
        hasher.combine(webTitle)
        hasher.combine(agentStatus)
        hasher.combine(isEditor)
        hasher.combine(editorFileName)
        hasher.combine(isProjectBoard)
        hasher.combine(isBranchReview)
        hasher.combine(editorIsDirty)
        hasher.combine(elapsedDisplay)
        hasher.combine(attentionReason)
        hasher.combine(permissionApproval)
        hasher.combine(openDialog)
        hasher.combine(stuck)
        hasher.combine(deferredAgent)
        hasher.combine(missionQuestion)
        hasher.combine(turnQuestion)
        hasher.combine(circling)
    }
}

/// A question a Mission child asked and nobody answered yet: "Asking
/// <parent>" in grey while the parent may answer, amber once it waits on
/// the user (`handOff`). Either way a click opens the reply popover.
struct SidebarMissionQuestion: Hashable {
    /// Why the question now waits on the user.
    enum HandOff: Hashable {
        case parentClosed
        case parentNotClaude
        /// The parent took the question and ended its turn without `reply`.
        case parentDidNotAnswer
        /// Nobody answered within the stuck-agent threshold.
        case unanswered(minutes: Int)
        /// The parent, a space's Lead, handed it over (`ask_user`), saying why.
        case lead(why: String)
    }

    /// What the parent's column runs now.
    enum Parent {
        /// No workspace or column any more.
        case closed
        /// Anything but an interactive `claude` in front, or no terminal yet
        /// (a restored agent that hasn't resumed).
        case notClaude
        /// Its `claude` took the question and ended its turn, no answer.
        case stoppedWithoutAnswer
        case claude
    }

    let questionID: String
    let parentTitle: String
    /// The question, or the answer once `isAnswered`.
    let text: String
    let handOff: HandOff?
    /// Answered, the answer not typed into the child's prompt yet: a
    /// `claude` restarted since takes it only after one prompt.
    /// `parentTitle` then names who answered ("you" for the user).
    var isAnswered = false

    /// Whether a question asked at `askedAt` now waits on the user: at once
    /// when its parent can't take it, else once nobody answered within
    /// `threshold`.
    static func handOff(
        parent: Parent, askedAt: TimeInterval, threshold: TimeInterval, now: TimeInterval
    ) -> HandOff? {
        switch parent {
        case .closed: return .parentClosed
        case .notClaude: return .parentNotClaude
        case .stoppedWithoutAnswer: return .parentDidNotAnswer
        case .claude:
            guard now - askedAt >= threshold else { return nil }
            return .unanswered(minutes: Int(threshold / 60))
        }
    }

    /// The popover's line under the question.
    var explanation: String {
        switch handOff {
        case .parentClosed: return "“\(parentTitle)” was closed, so the question comes to you."
        case .parentNotClaude: return "“\(parentTitle)” isn’t running Claude Code, so the question comes to you."
        case .parentDidNotAnswer: return "“\(parentTitle)” ended its turn without answering, so the question comes to you."
        case .unanswered(let minutes):
            return "“\(parentTitle)” hasn’t answered in \(minutes) minutes. You can answer instead."
        case .lead(let why):
            return "The Lead passed this one to you: \(why)"
        case nil: return "Waiting for “\(parentTitle)” to answer. You can answer instead."
        }
    }
}

/// What a column row shows of a restored agent that hasn't resumed yet
/// (see `DeferredAgentLaunch`). `columnID` tells a Resume click aimed at
/// it from one that lands on another column after a rebuild.
struct SidebarDeferredAgent: Hashable {
    let processName: String
    let summary: String
    let columnID: UUID

    var tooltip: String {
        "Not resumed yet: \(summary). Resume starts it here; showing its column does too."
    }
}

/// What a column row shows of a stuck agent (see `AgentStuckState`), at
/// display granularity.
enum SidebarStuckState: Hashable {
    /// A dialog waiting past the threshold, and for how long ("2h05m").
    case waiting(AgentAttentionReason, duration: String)
    /// The turn failed on an API error. `failedAt` tells the failure a
    /// Resume click was aimed at from any later one.
    case stoppedOnError(kind: String?, detail: String?, failedAt: TimeInterval, resume: Resume)
    case exitedMidTurn(processName: String)

    enum Resume: Hashable {
        /// The button: `continue` can go out.
        case offered
        /// `continue` went out; the next turn has not started yet.
        case sending
        /// The user typed at its prompt since the turn began: their draft,
        /// their Enter.
        case userTyped
        /// The error needs the user first (log in, billing, a limit…).
        case needsFix
        /// Claude is not at its prompt (or not in front).
        case unavailable

        init(_ refusal: AgentResumeRefusal?) {
            switch refusal {
            case nil: self = .offered
            case .alreadySent?: self = .sending
            case .userTyped?: self = .userTyped
            case .needsFix?: self = .needsFix
            case .notStopped?, .notClaude?, .notAtPrompt?: self = .unavailable
            }
        }

        /// Where Resume stands, when it isn't the button.
        var status: String? {
            switch self {
            case .offered: return nil
            case .sending: return "Resuming…"
            case .userTyped: return "Typed in its prompt: go on from the terminal"
            case .needsFix: return "Needs a fix in the terminal first"
            case .unavailable: return "Resume once claude is back at its prompt"
            }
        }
    }

    /// The name the row shows: the agent that died, not the shell that
    /// took its place in front.
    var agentName: String? {
        if case .exitedMidTurn(let processName) = self { return processName }
        return nil
    }

    var tooltip: String {
        switch self {
        case .waiting(let reason, let duration):
            let detail = reason.detailLine.flatMap { AgentText.clean($0, maxLength: 300) }
            return (["\(reason.headline) — waiting \(duration)", detail].compactMap { $0 }).joined(separator: " — ")
        case .stoppedOnError(let kind, let detail, _, _):
            let error = AgentAttentionReason.apiError(kind: kind, detail: detail).detailLine
            return ["Stopped on an API error", error].compactMap { $0 }.joined(separator: " — ")
        case .exitedMidTurn(let processName):
            return "\(processName) exited in the middle of a turn, without ending its session"
        }
    }

    /// Red when something broke, amber while a dialog waits.
    var isFailure: Bool {
        if case .waiting = self { return false }
        return true
    }
}

/// A permission request answerable from the sidebar (see
/// `PermissionApproval`).
struct SidebarPermissionApproval: Hashable {
    let requestID: String
    let toolName: String
    /// Exactly what the call does, as the receiver checked it.
    let text: String
    /// Buttons, the decision on its way, or its failure.
    let display: PermissionApprovalTicket.Display

    init?(_ request: AgentPermissionRequest, now: TimeInterval) {
        guard let ticket = request.approval, let toolName = request.toolName,
              let display = ticket.display(now: now) else { return nil }
        requestID = ticket.requestID
        self.toolName = toolName
        text = ticket.text
        self.display = display
    }
}

struct PRInfo: Hashable, Sendable {
    let number: Int
    let state: String
    let isDraft: Bool
    let ciStatus: String?
    /// The latest run of each check (docs/design/ci-failure-actions.md).
    let checks: [ProjectBoard.Check]
    let reviewDecision: String?
    let mergeable: String?
    let url: String
    let additions: Int?
    let deletions: Int?
    let changedFiles: Int?

    var failedCheckUrl: String? {
        checks.lazy.filter { $0.result == .failure }.compactMap(\.url).first
    }
}

struct WorkspaceInfo: Hashable {
    /// Stable workspace identity (WorkspaceState.id). Used to re-resolve
    /// `index` when the store may have mutated since this snapshot.
    let id: String
    let index: Int
    let title: String
    let profileID: String
    let isInactive: Bool
    let columnCount: Int
    let focusedColumn: Int
    let gitBranch: String?
    /// What happened while the user was away (`WorkspaceState.notification`).
    let notification: AttentionSignal?
    let isActive: Bool
    let columns: [ColumnInfo]
    let prInfo: PRInfo?
    /// The open PR's feedback: the card shows the counts only.
    var prFeedback: SidebarPRFeedback?
    /// Why the pull request's red checks look flaky
    /// (`WorkspaceState.ciFlakyReason`); nil: a failure like any other.
    var ciFlakyReason: String?
    let diffStats: String?
    let purpose: String?
    let nextStep: String?
    let blocker: String?
    let phase: WorkspacePhase
    let lastSummary: String?
    let lastActivityAt: TimeInterval?
    var reviewBadges: ReviewBadges? = nil
    /// What the card shows after "#N merged"; nil shows nothing.
    var mergedCleanup: MergedCleanupOffer?
    /// The space's Lead: first, never moved, dragged or parked.
    var isLead = false
    /// The task this one is listed under (a sub-task, or a Mission child):
    /// drawn indented, moved among its siblings only, never dragged.
    var parentTitle: String?
    /// Where the task stands (`WorkspaceState.statusLine`), when rows show
    /// it: the user's summary, else the last turn end's line.
    var statusLine: String?
    /// The last turn end's line alone (`WorkspaceState.turnStatusLine`):
    /// what a finished turn says beside its check.
    var turnStatusLine: String?
    /// The Lead's row: how many rules it proposed wait for the user.
    var ruleProposalCount = 0
    var isNested: Bool { parentTitle != nil }
    /// "Sub-task of “<parent>”": the row's tooltip and VoiceOver say it.
    var subtaskText: String? { parentTitle.map(Self.subtaskText(of:)) }

    static func subtaskText(of parentTitle: String) -> String {
        "Sub-task of “\(parentTitle)”"
    }

    /// The blocker and the next step (the user's, or the Lead's), trimmed;
    /// nil when empty.
    var blockerText: String? { normalizedContextText(blocker) }
    var nextStepText: String? { normalizedContextText(nextStep) }

    private func normalizedContextText(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

/// A merged pull request's worktree, offered for clean-up on its card.
enum MergedCleanupOffer: Hashable {
    /// "Clean up": runs "Clean Up Worktree…".
    case available
    /// A clean-up of the worktree is being checked, confirmed or run:
    /// "Cleaning up…", which does nothing.
    case inProgress
}

struct ProfileInfo: Hashable {
    let id: String
    let name: String
    let colorHex: String
    let isActive: Bool
    let workspaceCount: Int
    /// Its workspaces that aren't archived: the space picker's count.
    let taskCount: Int
    /// What its workspaces ask of the user: amber in the space picker
    /// while one waits on the user.
    let attention: AttentionSignal?
}

struct SidebarHitArea {
    let frame: NSRect
    let region: SidebarHitRegion
}

enum SidebarHitRegion {
    /// The space picker at the top: its menu switches spaces.
    case spacePicker
    /// The "+" of the Tasks header.
    case newTask
    /// The Archived row: folds and unfolds the archived list.
    case archivedToggle
    case link(url: String, label: NSTextField)
    case column(workspaceIndex: Int, columnIndex: Int)
    case workspace(Int)
    /// The "⋯" button on a workspace card — opens the workspace action menu.
    case workspaceMenu(Int)
    /// The catch-up card: a task, "N more", another space, or ×.
    case catchUp(SidebarCatchUpAction)
    /// Allow / Deny under a column holding a permission request.
    case permissionDecision(
        workspaceIndex: Int, columnIndex: Int, requestID: String, behavior: PermissionApproval.Behavior
    )
    /// Resume under a column whose turn failed on an API error.
    case agentResume(workspaceIndex: Int, columnIndex: Int, failedAt: TimeInterval)
    /// Resume on the row of a restored agent that hasn't resumed yet.
    case deferredAgentResume(workspaceIndex: Int, columnIndex: Int, columnID: UUID)
    /// Yes, No or Reply… under the question a Claude turn ended on.
    case turnAnswer(workspaceIndex: Int, columnIndex: Int, question: SidebarTurnQuestion, answer: SidebarTurnAnswer)
    /// The rest of an Allow / Deny or Resume block: clicks there do nothing
    /// (a press meant for a button that just moved must not reach the card
    /// below).
    case actionBlock(workspaceIndex: Int)
    /// A tile of the collapsed rail that isn't a workspace.
    case railButton(SidebarRailButton)
}

/// The collapsed rail's tiles that aren't workspaces.
enum SidebarRailButton: Hashable {
    /// The project: a menu to switch projects, and its options.
    case project
    /// Folds and unfolds the INACTIVE section.
    case inactiveSection
    case newWorkspace
}

/// Full parameter set of SidebarView.update(...) — stashed while a
/// drag-reorder is in flight and replayed when the drag ends.
struct SidebarUpdatePayload {
    let profiles: [ProfileInfo]
    let workspaces: [WorkspaceInfo]
}

/// Where a card's menu shows "Clean Up Worktree…".
enum WorktreeCleanupMenuOffer {
    /// The pull request is merged, or the folder is gone: on top, among
    /// what the workspace's state offers.
    case suggested
    /// Any other linked worktree: next to Close Workspace; the checks say
    /// what stands in the way.
    case available
}

enum WorkspaceSidebarAction {
    case moveUp, moveDown, markActive, markInactive
    case close, rename, editContext, reviewBranch, newSubtask, moveOutOfParent
    case closeColumn(columnIndex: Int)
    case cleanUpWorktree
    case askWhyCIFailed, rerunFailedCI
    /// "Add a Rule to the Brief…" (see LearnedRules).
    case addRuleToBrief
}

/// Hover highlight target in the sidebar. Links have their own dedicated
/// hover treatment; this covers the rest. In the collapsed rail, a
/// workspace tile is its `workspaceCard`.
enum SidebarHoverTarget: Hashable {
    case spacePicker
    case newTask
    case archivedToggle
    case workspaceCard(Int)
    case menuBadge(Int)
    case columnRow(workspaceIndex: Int, columnIndex: Int)
    case approvalButton(workspaceIndex: Int, key: String)
    case railButton(SidebarRailButton)

    /// The card containing the target — hovering any sub-region keeps the
    /// whole card lit. Nil for targets outside the workspace list.
    var workspaceIndex: Int? {
        switch self {
        case .spacePicker, .newTask, .archivedToggle, .railButton: return nil
        case .workspaceCard(let index), .menuBadge(let index): return index
        case .columnRow(let workspaceIndex, _), .approvalButton(let workspaceIndex, _): return workspaceIndex
        }
    }

    /// Key of an Allow / Deny button's view in `SidebarView.approvalButtonViews`.
    static func approvalButtonKey(requestID: String, behavior: PermissionApproval.Behavior) -> String {
        "\(requestID)|\(behavior.rawValue)"
    }

    /// Key of a Resume button's view, among the approval buttons (hover and
    /// click arming treat them alike). The failure is part of it: a button
    /// for another failure at the same place arms again.
    static func resumeButtonKey(workspaceIndex: Int, columnIndex: Int, failedAt: TimeInterval) -> String {
        "resume|\(workspaceIndex)|\(columnIndex)|\(failedAt)"
    }

    /// Key of a Yes / No / Reply… button, among the approval buttons: its
    /// column and question, wherever the card moves; a later question arms
    /// again.
    static func turnAnswerButtonKey(question: SidebarTurnQuestion, answer: SidebarTurnAnswer) -> String {
        "turn-answer|\(question.columnID.uuidString)|\(question.turnEndedAt)|\(answer.rawValue)"
    }

    /// Key of a not-resumed agent's Resume button: its column, wherever
    /// the row moves.
    static func deferredResumeButtonKey(columnID: UUID) -> String {
        "deferred-resume|\(columnID.uuidString)"
    }
}

/// The question a Claude turn ended on, for its card: the sentence that
/// asks (`AgentStatusMachine.AskedQuestion`), when it was asked, and
/// whether Yes and No may answer it.
struct SidebarTurnQuestion: Hashable {
    let text: String
    let turnEndedAt: TimeInterval
    let isYesNo: Bool
    /// Its column (`ColumnState.id`): a click finds it there, wherever a
    /// rebuild moved the card.
    let columnID: UUID
}

/// A quick answer's button under a turn's question.
enum SidebarTurnAnswer: String, Hashable {
    case yes, no, reply

    /// What Yes and No type into the agent's prompt.
    var typedText: String? {
        switch self {
        case .yes: return "yes"
        case .no: return "no"
        case .reply: return nil
        }
    }
}
