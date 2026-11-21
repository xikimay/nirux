import AppKit

struct GitContextObservation: Sendable {
    fileprivate let generation: UInt64
    fileprivate let workingDirectory: String
}

struct PullRequestObservation: Sendable {
    fileprivate let generation: UInt64
    fileprivate let context: GitContext
}

struct DiffStatsObservation: Sendable {
    fileprivate let generation: UInt64
    fileprivate let workingDirectory: String
    fileprivate let context: GitContext
}

enum GitContextObservationResult: Equatable {
    case stale
    case unchanged
    case changed
}

/// A workspace contains columns on an infinite horizontal strip
@MainActor
final class WorkspaceState {
    let id: String
    let containerView: NSView  // clips content, acts as viewport
    private let stripView: NSView  // holds all columns, slides horizontally
    var columns: [ColumnState] = []
    private var resizeHandles: [ColumnResizeHandle] = []
    var focusedIndex: Int = 0 {
        didSet {
            guard focusedIndex != oldValue else { return }
            onFocusedColumnChanged?()
        }
    }
    private(set) var lastCameraX: CGFloat = 0
    /// Where the camera stays while the pointer works on a card; nil: where
    /// the strip wants it.
    var heldCamera: CameraHold?
    let cwd: String
    var title: String
    var titleIsManual: Bool = false
    var profileID: String = WorkspaceProfile.defaultID
    var isInactive: Bool = false
    /// Close in flight: `closeWorkspace` keeps the workspace in the store
    /// until its exit animation ends. It no longer counts as remaining and
    /// must not be selected or closed again.
    var isClosing = false
    let missionID: String?
    /// The task this one is a sub-task of: it lists under it in the
    /// sidebar (see `WorkspaceStore.visibleWorkspaceIndices(in:)`). Set
    /// when it opens: by ⌘N's "Sub-task of", or by the worktree skill's
    /// `parentWorkspace`, Missions on or off, when that one is a task
    /// (`NiruxShellView.isTask`): never the main checkout or a Lead.
    /// Changed by Organize › Move Out of “<task>”.
    var parentWorkspaceID: String?
    /// `parentWorkspaceID` says where it lists, nil at the top level: set
    /// for every workspace this build opens, and at restore once a Mission
    /// child saved before has its parent decided (see
    /// `NiruxShellView.missionChildParents`). Kept across launches.
    let parentIsSettled: Bool
    /// See `NiruxShellView.taskLocation(of:)`.
    var taskLocationCache: (location: FolderIdentity, gitFile: String, gitFileDate: Date)?
    /// Controls mission variables for terminals created after a Settings
    /// change. Already-running shells retain the environment they launched
    /// with and pick up changes after a new terminal or app restart.
    var missionHandoffsEnabled: Bool
    /// A task a space's Lead started (`Mission.reportsToLead`): like the
    /// Lead's, its shells get the Mission variables whatever the setting.
    let reportsToLead: Bool
    /// A sub-task a task's agent started with its tools
    /// (`Mission.reportsToTask`): its shells get the Mission variables
    /// whatever the setting, as a Lead's task's do.
    let reportsToTask: Bool
    /// Whether new shells get the Mission variables.
    var carriesMissions: Bool { missionHandoffsEnabled || isLead || reportsToLead || reportsToTask }
    /// Opened by a `nirux://` request from outside Nirux (one the user
    /// confirmed, with no launch ID): its shells never get the space's
    /// environment, nor its first agent the setup script (docs/design/projects.md,
    /// section 5). Kept across launches.
    let startedOutsideNirux: Bool
    /// Opened by a `nirux://` request from a Nirux terminal (an agent's: the
    /// worktree skill's, say; a user rarely types one), not by the user from
    /// Nirux: the Lead's `list_tasks` says who started it. Kept across
    /// launches.
    let startedByAgent: Bool
    /// The space's Lead (docs/design/spaces.md, "The Lead"): pinned at the top of
    /// its space, one per space, never inactive. Its shells get
    /// `NIRUX_LEAD=1`, fixed when each starts, which gives their Claude the
    /// Lead's instructions (NiruxMCPServer). Cleared when its space is
    /// deleted and it moves to General.
    var isLead: Bool
    /// The folder Nirux made for a task without a repository
    /// (NewTask+Folder), kept across launches whatever folder its shells
    /// are in: its sub-tasks get their folders there, and it is never a
    /// worktree to clean up. Nil for any other workspace.
    let taskFolder: String?
    var isFolderTask: Bool { taskFolder != nil }
    private(set) var gitContext: GitContext?
    private var gitContextObservationGeneration: UInt64 = 0
    private var gitContextObservation: GitContextObservation?
    private var pullRequestObservationGeneration: UInt64 = 0
    private var pullRequestObservation: PullRequestObservation?
    private var diffStatsObservationGeneration: UInt64 = 0
    var gitBranch: String? { gitContext?.branch }
    var focusedWorkingDirectory: String {
        let column = columns[safe: focusedIndex]
        if column?.isWebView == true,
           let repositoryRoot = gitContext?.identity.repositoryRoot {
            return repositoryRoot
        }
        return Self.resolveWorkingDirectory(
            terminalCwd: column?.pty?.childCwd,
            editorCwd: column?.editorColumn?.workspaceCwd,
            workspaceCwd: cwd
        )
    }
    /// The most urgent of what happened while the user looked elsewhere.
    var notification: AttentionSignal?
    var hasNotification: Bool { notification != nil }
    var prInfo: PRInfo? {
        didSet {
            if prInfo?.url != oldValue?.url || prInfo?.state != .open { prFeedback = nil }
            // Merged (or first seen merged): what the Lead wrote is over, and
            // nothing tells it. The user's stays.
            if prInfo?.state == .merged, oldValue?.state != .merged { clearLeadContext() }
        }
    }
    /// The open PR's feedback (docs/design/pr-feedback-inbox.md), read after each
    /// PR refresh. Cleared when the PR changes or stops being open.
    var prFeedback: PRFeedback?
    /// Bumped at each feedback read: only the latest one applies.
    var prFeedbackGeneration = 0
    /// The red checks already reported (`CIFailure.reportKey`), and on
    /// which branch. The first call, at launch or on another branch, only
    /// records: a pull request that was already red isn't news.
    private var reportedRedChecks: (branch: String?, keys: Set<String>)?
    /// What the triage made of the pull request's red checks
    /// (docs/design/ci-failure-triage.md), and of which ones (`CITriage.signature`):
    /// a new failure isn't the one it was about. `retryAt` is set while an
    /// answer is still owed (a run `gh` couldn't read, a model that
    /// couldn't run): when to ask again.
    var ciTriage: (signature: String, verdict: CITriage.Verdict, retryAt: TimeInterval?)?

    /// Why the pull request's red checks look flaky, when the triage said
    /// so of the checks that are red now. The verdict first: this is read
    /// at every sidebar refresh, and most red pull requests aren't flaky.
    var ciFlakyReason: String? {
        guard let ciTriage, let reason = ciTriage.verdict.flakyReason, let prInfo,
              ciTriage.signature == CITriage.signature(of: CIFailure.redChecks(prInfo))
        else { return nil }
        return reason
    }
    var diffStats: String?

    // Workspace context. The purpose is the user's. `phase` is a manual
    // override (nil means derive from live state), while automatic agent
    // summaries are allowed only until the user edits one. The next step
    // and blocker are the user's, or the Lead's (`set_task_context`) until
    // the user writes one by hand: see `setContextByLead`.
    var purpose: String?
    var phase: WorkspacePhase?
    var lastSummary: String?
    var lastSummaryIsManual: Bool = false
    /// `lastSummary` is the status line of the task's last turn end
    /// (`settleTurnStatus`), not an agent's report as it came (Codex's
    /// message), nor one from before a turn whose line is unknown.
    var lastSummaryIsStatus = false
    /// The newest turn end whose status line is on its way, and the newest
    /// one settled (its line, "unchanged", or none). In memory only: runs
    /// don't outlive the app.
    private(set) var awaitedTurnStatus: TimeInterval?
    private(set) var settledTurnStatus: TimeInterval?
    var lastActivityAt: TimeInterval?
    var nextStep: String?
    var blocker: String?
    /// The Lead wrote `nextStep` (or `blocker`), not the user: its next
    /// update may replace it. False for an empty field.
    var nextStepIsFromLead = false
    var blockerIsFromLead = false
    var unknownPhaseRawValue: String?
    /// Each review pass's latest run (docs/design/review-badges.md).
    var reviewRuns: [ReviewPass: ReviewRun] = [:]
    /// The passes running now: started by the pass's own event, ended by
    /// events (`noteReviewPasses(of:in:now:)`, `followReviewPasses(_:)`).
    /// Apart from `reviewRuns`, whose run needs a HEAD git may not find.
    /// Not kept across launches: no turn outlives one.
    var reviewsRunning: [RunningPass] = []

    var effectivePhase: WorkspacePhase {
        if let phase { return phase }
        return WorkspacePhase.derived(
            isInactive: isInactive,
            hasBlocker: Self.normalizedContextText(blocker) != nil,
            agentStatuses: columns.map { $0.pty?.cachedAgentState ?? .idle },
            pullRequestState: prInfo?.state
        )
    }

    /// Called by NiruxShellView to wire up sidebar refresh
    var onMetadataChanged: (() -> Void)?
    /// A column's agent reported its turn over (`ColumnState.onProgramTurnOver`).
    var onProgramTurnOver: (() -> Void)?
    /// A column's terminal title changed (fires before onMetadataChanged).
    var onColumnTitleChanged: ((ColumnState) -> Void)?
    var onFocusedColumnChanged: (() -> Void)?
    /// The columns were laid out (`layoutAndScroll`): which ones show may
    /// have changed.
    var onColumnsLaidOut: (() -> Void)?
    var onGitContextChanged: (() -> Void)?
    /// A terminal link was cmd-clicked — the shell opens a browser column
    /// in this workspace.
    var onTerminalOpenURL: ((WorkspaceState, String) -> Void)?
    /// A terminal file: link was cmd-clicked — the shell opens it in an
    /// editor column in this workspace, at the optional line.
    var onTerminalOpenFile: ((WorkspaceState, String, Int?) -> Void)?
    /// A column's agent died mid-turn and the user asked to resume it.
    var onResumeExitedAgent: ((WorkspaceState, ColumnState) -> Void)?
    /// A column's shell is about to start (see `ColumnState.onShellStarting`).
    var onTerminalStarting: ((WorkspaceState, ColumnState) -> Void)?
    /// Bring an existing column of this workspace into view and focus it.
    var onRevealColumn: ((WorkspaceState, Int) -> Void)?
    /// Dev-server proposals — see WorkspaceState+LocalServers.swift.
    var localServers = LocalServerTracking()

    init(
        id: String = UUID().uuidString,
        title: String? = nil,
        cwd: String,
        profileID: String = WorkspaceProfile.defaultID,
        missionID: String? = nil,
        parentWorkspaceID: String? = nil,
        parentIsSettled: Bool = true,
        missionHandoffsEnabled: Bool = false,
        startedOutsideNirux: Bool = false,
        startedByAgent: Bool = false,
        isLead: Bool = false,
        reportsToLead: Bool = false,
        reportsToTask: Bool = false,
        taskFolder: String? = nil,
        initialAgentUUID: String = UUID().uuidString
    ) {
        self.id = id
        self.taskFolder = taskFolder
        // Before the first column: its shell reads them.
        self.startedOutsideNirux = startedOutsideNirux
        self.startedByAgent = startedByAgent
        self.isLead = isLead
        self.reportsToLead = reportsToLead
        self.reportsToTask = reportsToTask
        self.cwd = cwd
        self.title = title ?? "workspace"
        self.titleIsManual = (title != nil)
        self.profileID = profileID
        self.missionID = missionID
        self.parentWorkspaceID = parentWorkspaceID
        self.parentIsSettled = parentIsSettled
        self.missionHandoffsEnabled = missionHandoffsEnabled

        containerView = NSView()
        containerView.wantsLayer = true
        containerView.clipsToBounds = true

        stripView = NSView()
        stripView.wantsLayer = true
        containerView.addSubview(stripView)

        addColumn(agentUUID: initialAgentUUID)
    }
}

extension WorkspaceState {
    /// Trim human-entered context and collapse blank values back to nil so
    /// optional sidebar rows do not consume space for whitespace-only text.
    static func normalizedContextText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The next step and blocker, which the Lead keeps for its tasks.
    enum ContextField: CaseIterable {
        case nextStep, blocker
    }

    func contextText(_ field: ContextField) -> String? {
        switch field {
        case .nextStep: return nextStep
        case .blocker: return blocker
        }
    }

    func contextIsFromLead(_ field: ContextField) -> Bool {
        switch field {
        case .nextStep: return nextStepIsFromLead
        case .blocker: return blockerIsFromLead
        }
    }

    private func setContext(_ field: ContextField, _ text: String?, fromLead: Bool) {
        switch field {
        case .nextStep:
            nextStep = text
            nextStepIsFromLead = fromLead && text != nil
        case .blocker:
            blocker = text
            blockerIsFromLead = fromLead && text != nil
        }
    }

    /// A field saved from View/Edit Context…: one the user changed from
    /// what the panel showed (`presented`) is theirs, and the Lead leaves
    /// it; one they cleared goes back to the Lead. One they didn't touch
    /// keeps what it holds now, which the Lead may have changed meanwhile.
    func setContextByHand(_ field: ContextField, _ text: String, presented: String?) {
        let value = Self.normalizedContextText(text)
        guard value != Self.normalizedContextText(presented) else { return }
        setContext(field, value, fromLead: false)
    }

    /// Clears the next step and blocker the Lead wrote.
    func clearLeadContext() {
        for field in ContextField.allCases where contextIsFromLead(field) {
            setContext(field, nil, fromLead: false)
        }
    }

    enum LeadContextOutcome: Equatable {
        case set(String)
        case cleared
        case unchanged
        /// The user wrote it by hand: theirs stays.
        case keptUsers(String)
    }

    /// The Lead's update of a field: empty clears it. A field the user
    /// wrote by hand stays theirs until they clear it.
    func setContextByLead(_ field: ContextField, _ text: String) -> LeadContextOutcome {
        let value = Self.normalizedContextText(text)
        let current = Self.normalizedContextText(contextText(field))
        if let current, !contextIsFromLead(field) {
            return value == current ? .unchanged : .keptUsers(current)
        }
        guard value != current else { return .unchanged }
        setContext(field, value, fromLead: true)
        return value.map { .set($0) } ?? .cleared
    }

    static func resolveWorkingDirectory(
        terminalCwd: String?,
        editorCwd: String?,
        workspaceCwd: String
    ) -> String {
        terminalCwd ?? editorCwd ?? workspaceCwd
    }

    @discardableResult
    func updateGitContext(_ context: GitContext?) -> Bool {
        gitContextObservationGeneration &+= 1
        gitContextObservation = nil
        return replaceGitContext(context)
    }

    func beginGitContextObservation(at workingDirectory: String) -> GitContextObservation? {
        let workingDirectory = URL(fileURLWithPath: workingDirectory).standardizedFileURL.path
        guard gitContextObservation?.workingDirectory != workingDirectory else { return nil }
        gitContextObservationGeneration &+= 1
        let observation = GitContextObservation(
            generation: gitContextObservationGeneration,
            workingDirectory: workingDirectory
        )
        gitContextObservation = observation
        return observation
    }

    @discardableResult
    func applyGitContextObservation(
        _ result: GitContextDetectionResult,
        observation: GitContextObservation
    ) -> GitContextObservationResult {
        guard observation.generation == gitContextObservationGeneration,
              gitContextObservation?.generation == observation.generation
        else { return .stale }
        gitContextObservation = nil
        switch result {
        case .observed(let context):
            return replaceGitContext(context) ? .changed : .unchanged
        case .notRepository:
            return replaceGitContext(nil) ? .changed : .unchanged
        case .failure:
            return .unchanged
        }
    }

    private func replaceGitContext(_ context: GitContext?) -> Bool {
        let context = preservingKnownUpstreamRepository(in: context)
        guard gitContext != context else { return false }
        pullRequestObservationGeneration &+= 1
        pullRequestObservation = nil
        diffStatsObservationGeneration &+= 1
        let previousContext = gitContext
        gitContext = context
        let sameRevision = previousContext?.branch == context?.branch
            && previousContext?.identity.repositoryRoot == context?.identity.repositoryRoot
            && previousContext?.identity.head == context?.identity.head
            && previousContext?.upstreamRepositoryObservation
                == context?.upstreamRepositoryObservation
        if !sameRevision || (context?.identity.isDirty == true && Self.isTerminalPullRequest(prInfo)) {
            prInfo = nil
        }
        diffStats = nil
        if !titleIsManual, let branch = context?.branch, !branch.isEmpty {
            title = branch
        }
        onGitContextChanged?()
        return true
    }

    private func preservingKnownUpstreamRepository(in context: GitContext?) -> GitContext? {
        guard let context,
              context.upstreamRepositoryObservation == .failure,
              let previousContext = gitContext,
              previousContext.branch == context.branch,
              previousContext.identity.repositoryRoot == context.identity.repositoryRoot
        else { return context }
        return GitContext(
            branch: context.branch,
            identity: context.identity,
            upstreamRepositoryObservation: previousContext.upstreamRepositoryObservation
        )
    }

    @discardableResult
    func applyPullRequestInfo(_ info: PRInfo?, for context: GitContext) -> Bool {
        guard gitContext == context,
              !(context.identity.isDirty && Self.isTerminalPullRequest(info)),
              prInfo != info
        else { return false }
        prInfo = info
        return true
    }

    /// The red checks of `prInfo` not reported yet, each once
    /// (docs/design/ci-failure-actions.md).
    func takeNewRedChecks() -> [GitHub.Check] {
        let red = prInfo.map(CIFailure.redChecks) ?? []
        let keys = red.map(CIFailure.reportKey)
        let branch = gitContext?.branch
        guard let reported = reportedRedChecks, reported.branch == branch else {
            reportedRedChecks = (branch, Set(keys))
            return []
        }
        reportedRedChecks = (branch, reported.keys.union(keys))
        return red.filter { !reported.keys.contains(CIFailure.reportKey($0)) }
    }

    func beginPullRequestObservation(for context: GitContext) -> PullRequestObservation? {
        guard gitContext == context,
              pullRequestObservation?.context != context
        else { return nil }
        pullRequestObservationGeneration &+= 1
        let observation = PullRequestObservation(
            generation: pullRequestObservationGeneration,
            context: context
        )
        pullRequestObservation = observation
        return observation
    }

    func isCurrentPullRequestObservation(
        _ observation: PullRequestObservation,
        for context: GitContext
    ) -> Bool {
        observation.generation == pullRequestObservationGeneration
            && pullRequestObservation?.generation == observation.generation
            && observation.context == context
            && gitContext == context
    }

    @discardableResult
    func finishPullRequestObservation(_ observation: PullRequestObservation) -> Bool {
        guard observation.generation == pullRequestObservationGeneration,
              pullRequestObservation?.generation == observation.generation
        else { return false }
        pullRequestObservation = nil
        return true
    }

    @discardableResult
    func applyPullRequestInfo(
        _ info: PRInfo?,
        for context: GitContext,
        observation: PullRequestObservation
    ) -> Bool {
        guard isCurrentPullRequestObservation(observation, for: context) else { return false }
        pullRequestObservation = nil
        return applyPullRequestInfo(info, for: context)
    }

    func beginDiffStatsObservation(
        at workingDirectory: String,
        for context: GitContext
    ) -> DiffStatsObservation? {
        let workingDirectory = URL(fileURLWithPath: workingDirectory).standardizedFileURL.path
        let focusedWorkingDirectory = URL(
            fileURLWithPath: self.focusedWorkingDirectory
        ).standardizedFileURL.path
        guard gitContext == context,
              workingDirectory == focusedWorkingDirectory else { return nil }
        diffStatsObservationGeneration &+= 1
        return DiffStatsObservation(
            generation: diffStatsObservationGeneration,
            workingDirectory: workingDirectory,
            context: context
        )
    }

    @discardableResult
    func applyDiffStatsObservation(
        _ result: PRDetect.DiffStatsResult,
        observation: DiffStatsObservation
    ) -> Bool {
        let focusedWorkingDirectory = URL(
            fileURLWithPath: self.focusedWorkingDirectory
        ).standardizedFileURL.path
        guard observation.generation == diffStatsObservationGeneration,
              observation.workingDirectory == focusedWorkingDirectory,
              observation.context == gitContext else { return false }
        let stats: String?
        switch result {
        case .observed(let observedContext, let observedStats):
            guard preservingKnownUpstreamRepository(in: observedContext)
                == observation.context else { return false }
            stats = observedStats
        case .notApplicable:
            stats = nil
        case .failure:
            return false
        }
        guard diffStats != stats else { return false }
        diffStats = stats
        return true
    }

    private static func isTerminalPullRequest(_ info: PRInfo?) -> Bool {
        guard let state = info?.state else { return false }
        return state == .merged || state == .closed
    }

    /// Record meaningful agent activity without overwriting a user-edited
    /// summary. Replayed hook events can be older than persisted context, so
    /// only the newest event is allowed to replace the automatic summary.
    @discardableResult
    func recordAgentActivity(at timestamp: TimeInterval, automaticSummary: String?) -> Bool {
        let isNewest = lastActivityAt.map { timestamp >= $0 } ?? true
        var changed = false
        if lastActivityAt.map({ timestamp > $0 }) ?? true {
            lastActivityAt = timestamp
            changed = true
        }
        guard isNewest, !lastSummaryIsManual,
              let automaticSummary = Self.normalizedContextText(automaticSummary)
        else { return changed }

        let compactSummary = automaticSummary
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // A Claude line on its way for an older turn would replace it.
        if let awaited = awaitedTurnStatus, awaited < timestamp { awaitedTurnStatus = nil }
        settledTurnStatus = max(settledTurnStatus ?? timestamp, timestamp)
        guard lastSummary != compactSummary || lastSummaryIsStatus else { return changed }
        lastSummary = compactSummary
        lastSummaryIsStatus = false
        return true
    }

    /// A run started for the status line of the turn that ended at
    /// `turnEndedAt`: until it settles, the row shows no line from an
    /// older turn. False for a turn end older than one already known.
    @discardableResult
    func awaitTurnStatus(turnEndedAt: TimeInterval) -> Bool {
        guard turnEndedAt > (awaitedTurnStatus ?? settledTurnStatus ?? -.infinity) else { return false }
        awaitedTurnStatus = turnEndedAt
        return true
    }

    /// A turn ended at `turnEndedAt` with no run for its line (no final
    /// message: another account, a headless run; the option off): the
    /// line from before it says nothing of it. Unless a newer turn end is
    /// known already.
    func forgetTurnStatus(turnEndedAt: TimeInterval) {
        guard turnEndedAt > (awaitedTurnStatus ?? settledTurnStatus ?? -.infinity) else { return }
        awaitedTurnStatus = nil
        settledTurnStatus = turnEndedAt
        lastSummaryIsStatus = false
    }

    /// The run for the turn that ended at `turnEndedAt` answered, if no
    /// newer turn end's run started since: its line goes in `lastSummary`
    /// unless the user wrote it; "unchanged" keeps the line as it was; no
    /// answer leaves the row without a line until the next turn. True when
    /// the row may have changed.
    @discardableResult
    func settleTurnStatus(_ status: TurnStatus?, turnEndedAt: TimeInterval) -> Bool {
        guard awaitedTurnStatus == turnEndedAt else { return false }
        awaitedTurnStatus = nil
        settledTurnStatus = turnEndedAt
        switch status {
        case .line(let line)? where !lastSummaryIsManual:
            lastSummary = line
            lastSummaryIsStatus = true
        case .unchanged?, .line?:
            break
        case nil:
            lastSummaryIsStatus = false
        }
        return true
    }

    /// The last turn end's status line, once it is known. (Never the
    /// user's summary: writing one clears `lastSummaryIsStatus`.)
    var turnStatusLine: String? {
        lastSummaryIsStatus && awaitedTurnStatus == nil ? lastSummary : nil
    }

    /// The task's line on its row: the summary the user wrote, else the
    /// last status line (still while the next one is on its way). Never an
    /// agent's report as it came, nor a line from before a turn whose line
    /// is unknown. One line.
    var statusLine: String? {
        let line = lastSummaryIsManual ? lastSummary : lastSummaryIsStatus ? lastSummary : nil
        return line.flatMap(Self.normalizedContextText)?
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    @discardableResult
    func recordAgentHookActivity(_ event: AgentHookEvent) -> Bool {
        switch event.name {
        // Claude's reminder of a turn already over, and its compactions
        // (mostly its own, while idle): the card's age stays the agent's
        // last real work.
        case .notification where event.notificationType == "idle_prompt",
             .sessionStart where event.source == "compact":
            return false
        case .stop, .turnComplete:
            return recordAgentActivity(at: event.timestamp, automaticSummary: event.detail)
        case .notification, .permissionRequest, .sessionStart, .sessionEnd, .userPromptSubmit, .stopFailure:
            return recordAgentActivity(at: event.timestamp, automaticSummary: nil)
        case .preToolUse, .postToolUse, .permissionDenied, .subagentStop, .approvalResolved:
            return false
        }
    }

    // MARK: - CWD / Git / Title Tracking

    private func setupCwdTracking(for col: ColumnState) {
        col.onCwdChanged = { [weak self, weak col] _ in
            guard let self, let col,
                  self.columns[safe: self.focusedIndex] === col
            else { return }
            let workingDirectory = self.focusedWorkingDirectory
            guard let observation = self.beginGitContextObservation(at: workingDirectory) else { return }
            GitDetect.contextAsync(at: workingDirectory, startFolder: self.cwd) { [weak self] result in
                guard let self else { return }
                let observationResult = self.applyGitContextObservation(
                    result,
                    observation: observation
                )
                guard observationResult != .stale else { return }
                if observationResult == .unchanged { self.onMetadataChanged?() }
            }
        }
    }

    private func setupTitleTracking(for col: ColumnState) {
        col.onTitleChanged = { [weak self, weak col] in
            guard let self else { return }
            if let col { self.onColumnTitleChanged?(col) }
            self.onMetadataChanged?()
        }
    }

    /// A Mission child that asked its parent and ended its turn to wait:
    /// it waits on the parent, not on the user.
    func waitsOnParent(_ col: ColumnState) -> Bool {
        guard let uuid = col.agentUUID else { return false }
        return MissionStore.shared.waitingQuestion(childWorkspaceID: id, childAgentUUID: uuid) != nil
            || MissionStore.shared.pendingAnswer(childWorkspaceID: id, childAgentUUID: uuid) != nil
    }

    private func setupAgentAttentionTracking(for col: ColumnState) {
        col.onProgramTurnOver = { [weak self] in self?.onProgramTurnOver?() }
        col.onAgentAttention = { [weak self, weak col] reason in
            guard let self else { return }
            // A Mission child ends its turn after asking (even in prose).
            if reason?.isTurnEnd == true, let col, self.waitsOnParent(col) {
                self.onMetadataChanged?()
                return
            }
            // Its columns show a wait or an error while it lasts, not after.
            self.raiseNotification(.finished)
            self.onMetadataChanged?()
            // Bounce dock icon when app is not active
            if !NSApp.isActive {
                NSApp.requestUserAttention(.informationalRequest)
                // Native notification with click-to-focus routing.
                let processName: String
                if reason == .exitedMidTurn {
                    // The title is the shell's now.
                    processName = col?.pty?.agentMidTurnExit?.agent.rawValue ?? "Agent"
                } else if let col, let title = col.terminalTitle, !title.isEmpty, !Shell.isShell(title) {
                    processName = title
                } else {
                    processName = "Agent"
                }
                let columnIndex = col.flatMap { column in self.columns.firstIndex(where: { $0 === column }) }
                NiruxNotifier.shared.postAgentAttention(
                    workspaceID: self.id,
                    workspaceTitle: self.title,
                    columnIndex: columnIndex,
                    processName: processName,
                    reason: reason,
                    quickReply: col.flatMap { Self.quickReplyTarget(of: $0, reason: reason) }
                )
            }
        }
    }

    /// A question the agent's turn asked, still waiting: its notification
    /// takes a reply (`NiruxNotifier.QuickReplyTarget`).
    static func quickReplyTarget(of column: ColumnState, reason: AgentAttentionReason?) -> NiruxNotifier.QuickReplyTarget? {
        guard case .askedInReply = reason, let agentUUID = column.agentUUID, let pty = column.pty,
              let question = pty.agentQuestion(foreground: pty.foregroundProcess(snapshot: ProcessSnapshot()))
        else { return nil }
        return NiruxNotifier.QuickReplyTarget(agentUUID: agentUUID, turnEndedAt: question.since)
    }

    private func setupLinkOpening(for col: ColumnState) {
        col.onOpenURL = { [weak self] url in
            guard let self else { return }
            self.onTerminalOpenURL?(self, url)
        }
        col.onOpenFile = { [weak self] path, line in
            guard let self else { return }
            self.onTerminalOpenFile?(self, path, line)
        }
        col.onResumeExitedAgent = { [weak self, weak col] in
            guard let self, let col else { return }
            self.onResumeExitedAgent?(self, col)
        }
    }

    private func setupAllTracking(for col: ColumnState) {
        col.onShellStarting = { [weak self, weak col] in
            guard let self, let col else { return }
            self.onTerminalStarting?(self, col)
        }
        setupCwdTracking(for: col)
        setupTitleTracking(for: col)
        setupAgentAttentionTracking(for: col)
        setupLinkOpening(for: col)
        setupLocalServerDetection(for: col)
    }

    // MARK: - Column Management

    func terminalEnvironment(agentUUID: String) -> [String: String] {
        var environment = Self.makeTerminalEnvironment(
            profileID: profileID,
            workspaceID: id,
            agentUUID: agentUUID,
            missionID: missionID,
            missionHandoffsEnabled: carriesMissions,
            executablePath: Bundle.main.executableURL?.path,
            launchID: NiruxLaunchAuthorization.launchID
        )
        // Where agents edit the space brief when the user asks. Like the rest
        // of this environment, it is fixed when the shell starts.
        if let briefURL = SpaceBrief.briefURL(spaceID: profileID) {
            environment["NIRUX_PROJECT_BRIEF"] = briefURL.path
        }
        // Blank elsewhere: a Nirux started from a Lead's shell must not
        // pass the role on to every terminal it opens.
        environment[Self.leadEnvironmentKey] = isLead ? "1" : ""
        // Nor from an SDK run's: its agents would read as headless
        // (`TurnEndText.isHeadless`). Blank, Claude Code sets its own.
        environment["CLAUDE_CODE_ENTRYPOINT"] = ""
        guard !startedOutsideNirux else {
            // Its agents' nirux:// requests ask first, as its own did: they
            // come from outside Nirux too.
            environment[NiruxLaunchAuthorization.environmentKey] = ""
            return environment
        }
        // The space's variables, under Nirux's own: they never replace a
        // NIRUX_ one (SpaceDefaults refuses those names anyway).
        return environment.merging(SpaceDefaultsStore.defaults(forSpace: profileID).effectiveEnvironment) { nirux, _ in nirux }
    }

    /// Set to "1" in the Lead's shells (see `isLead`).
    nonisolated static let leadEnvironmentKey = "NIRUX_LEAD"

    // Pure builder so feature-gating of terminal metadata can be tested
    // without starting a PTY-backed WorkspaceState.
    // The inputs mirror the independently persisted routing identities and
    // optional Mission context; grouping them would obscure that wire contract.
    // swiftlint:disable:next function_parameter_count
    nonisolated static func makeTerminalEnvironment(
        profileID: String,
        workspaceID: String,
        agentUUID: String,
        missionID: String?,
        missionHandoffsEnabled: Bool,
        executablePath: String?,
        launchID: String,
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = [
            "NIRUX_PROFILE_ID": profileID,
            "NIRUX_WORKSPACE_ID": workspaceID,
            // Hook events carry this back — see AgentHookCenter.
            "NIRUX_AGENT_UUID": agentUUID,
            // Authorizes nirux:// requests from this terminal's agents.
            NiruxLaunchAuthorization.environmentKey: launchID,
            // A live merge queue is never passed on to the builds an agent
            // runs here: they stay dry runs unless asked for by hand.
            "NIRUX_MERGE_QUEUE_LIVE": "",
            // Nor is a copy's opt-in to the real state (see RealStateGuard).
            "NIRUX_ALLOW_REAL_STATE": ""
        ]
        // Antigravity then says what it does and why it waits
        // (AgentProgramStatus): Nirux doesn't answer its query. A user's own
        // setting stays.
        if inherited["AGY_CLI_OSC7501"] == nil { environment["AGY_CLI_OSC7501"] = "on" }
        if missionHandoffsEnabled {
            environment["NIRUX_MISSION_HANDOFFS"] = "1"
            if let executablePath {
                environment["NIRUX_CLI_PATH"] = executablePath
            }
            if let missionID {
                environment["NIRUX_MISSION_ID"] = missionID
            }
        }
        return environment
    }

    private func insertColumn(_ col: ColumnState) {
        let insertAt = columns.isEmpty ? 0 : min(focusedIndex + 1, columns.count)
        columns.insert(col, at: insertAt)
        stripView.addSubview(col.view)
        focusedIndex = insertAt
        makeResizeHandle()
    }

    /// One resize handle per column (its right edge), always the topmost
    /// strip subviews; only the focused card's two edges show. Closures
    /// resolve the handle back to its CURRENT column index at event time,
    /// so moveColumn/closeColumn can't leave them pointing at the wrong
    /// column.
    private func makeResizeHandle() {
        let handle = ColumnResizeHandle()
        handle.onDragStart = { [weak self, weak handle] in
            guard let self, let handle, let edge = self.resizeHandles.firstIndex(of: handle),
                  edge == self.focusedIndex || edge == self.focusedIndex - 1 else { return nil }
            let widths = self.columns.map(\.view.frame.width)
            let centred = Self.centres(widths, focus: self.focusedIndex, viewport: self.containerView.bounds.width)
            return (widths, self.stripView.frame.width, self.lastCameraX, self.focusedIndex, centred)
        }
        handle.onDrag = { [weak self, weak handle] start, delta in
            guard let self, let handle, let edge = self.resizeHandles.firstIndex(of: handle) else { return }
            self.drag(edge: edge, from: start, by: delta)
        }
        // Let go: the camera goes where the strip now wants it.
        handle.onDragEnd = { [weak self] in
            guard let self else { return }
            self.heldCamera = nil
            self.layoutAndScroll(viewportWidth: self.containerView.bounds.width, height: self.containerView.bounds.height, animated: true)
        }
        // Double-click: the focused card back to half, by the same share.
        handle.onReset = { [weak self, weak handle] in
            guard let self, let handle, let edge = self.resizeHandles.firstIndex(of: handle),
                  edge == self.focusedIndex || edge == self.focusedIndex - 1 else { return }
            let viewport = self.containerView.bounds.width, focus = self.focusedIndex
            let widths = self.columns.map(\.view.frame.width)
            let share = Self.share(
                edge: edge, focus: focus, count: widths.count, centred: Self.centres(widths, focus: focus, viewport: viewport)
            )
            self.setColumnWidths(Self.resized(
                widths, focus: focus, to: Self.width(ColumnWidth.half.fraction, in: viewport), share: share,
                first: edge == focus ? focus + 1 : focus - 1, viewport: viewport
            ), viewport: viewport)
        }
        handle.wantsLayer = true
        stripView.addSubview(handle)
        // Over a card passing over its neighbours, as it takes their clicks.
        handle.layer?.zPosition = 2
        resizeHandles.append(handle)
    }

    /// Who pays for the width the focused card takes from an edge: both
    /// neighbours alike while it is centred between them, so that it stays
    /// centred; else the neighbour across the edge; the strip's last edge
    /// grows it alone.
    enum ResizeShare { case both, left, right, none }

    static func share(edge: Int, focus: Int, count: Int, centred: Bool) -> ResizeShare {
        if centred, focus > 0, focus < count - 1 { return .both }
        if edge < focus { return .left }
        return edge < count - 1 ? .right : .none
    }

    /// The widths `widths` take when the focused column `focus` takes
    /// `points` from each column of `asks` in turn (a negative ask gives
    /// back), every one kept between the minimum and the maximum width, the
    /// focused one, when `share` is `.both`, within the viewport: a
    /// column that runs out pays what it can. An ask on `focus` itself
    /// grows it alone.
    static func resized(
        _ widths: [CGFloat], focus: Int, taking asks: [(column: Int, points: CGFloat)], share: ResizeShare, viewport: CGFloat
    ) -> [CGFloat] {
        let low = width(minWidthFraction, in: viewport), high = width(maxWidthFraction, in: viewport)
        let focusHigh = share == .both ? width(1, in: viewport) : high
        var resized = widths
        for ask in asks {
            // What the focused card may take without leaving its range, and
            // the payer its own; a column already outside keeps where it is.
            var lower = min(0, low - resized[focus]), upper = max(0, focusHigh - resized[focus])
            if ask.column != focus {
                lower = max(lower, min(0, resized[ask.column] - high))
                upper = min(upper, max(0, resized[ask.column] - low))
            }
            let paid = min(max(ask.points, lower), upper)
            resized[focus] += paid
            if ask.column != focus { resized[ask.column] -= paid }
        }
        return resized
    }

    /// The focused column `focus` set to `target` wide, its neighbours paying
    /// by `share`: half each when both, `first` paying the odd point, and
    /// one that runs out leaves the rest to the other.
    static func resized(
        _ widths: [CGFloat], focus: Int, to target: CGFloat, share: ResizeShare, first: Int, viewport: CGFloat
    ) -> [CGFloat] {
        let gap = target - widths[focus]
        let asks: [(column: Int, points: CGFloat)] = switch share {
        case .both: [(first, ceil(gap / 2)), (2 * focus - first, floor(gap / 2))]
        case .left, .right: [(first, gap)]
        case .none: [(focus, gap)]
        }
        var resized = Self.resized(widths, focus: focus, taking: asks, share: share, viewport: viewport)
        for ask in asks {
            resized = Self.resized(resized, focus: focus, taking: [(ask.column, target - resized[focus])], share: share, viewport: viewport)
        }
        return resized
    }

    /// The focused card's edge right of column `edge` dragged `delta`
    /// points from `start`, staying under the pointer: the neighbour across
    /// the edge pays what the pointer moved, and the other as much while the
    /// card is centred (`share`); the strip's last edge moves as
    /// `draggedWidth` and `dragCamera` say. A focus moved since the drag
    /// began leaves it there.
    private func drag(edge: Int, from start: ColumnResizeHandle.Start, by delta: CGFloat) {
        let viewport = containerView.bounds.width, focus = start.focus
        guard focus == focusedIndex, start.widths.count == columns.count else { return }
        let share = Self.share(edge: edge, focus: focus, count: columns.count, centred: start.centred)
        let pull = edge == focus ? delta : -delta, width = start.widths[focus]
        let near = edge == focus ? focus + 1 : focus - 1, far = edge == focus ? focus - 1 : focus + 1
        // Each side takes half the card's room, so that it stops centred.
        let half = min(max(pull, floor((Self.width(Self.minWidthFraction, in: viewport) - width) / 2)), floor((Self.width(1, in: viewport) - width) / 2))
        let asks: [(column: Int, points: CGFloat)] = switch share {
        case .both: [(near, half), (far, half)]
        case .left, .right: [(near, pull)]
        case .none: [(focus, Self.draggedWidth(start.widths[focus], strip: start.strip, viewport: viewport, by: delta) - start.widths[focus])]
        }
        var widths = Self.resized(start.widths, focus: focus, taking: asks, share: share, viewport: viewport)
        // Near a third, a half or two thirds of the viewport (`cycleWidth`'s
        // stops), it lands there with a tick of the trackpad; the one it
        // started on lets it go at once.
        let stops = [ColumnWidth.third, .half, .twoThirds].map { Self.width($0.fraction, in: viewport) }
        if let stop = stops.first(where: { $0 != width && abs($0 - widths[focus]) <= Self.snapDistance }) {
            let landed = Self.resized(start.widths, focus: focus, to: stop, share: share, first: near, viewport: viewport)
            if landed[focus] == stop { widths = landed }
        }
        if stops.contains(widths[focus]), widths[focus] != columns[focus].view.frame.width {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        let camera = share == .none
            ? Self.dragCamera(width: start.widths[focus], strip: start.strip, camera: start.camera, viewport: viewport, to: widths[focus])
            : start.camera
        heldCamera = camera.map { CameraHold(x: $0, column: columns[focus].id, isDrag: true) }
        setColumnWidths(widths, viewport: viewport)
    }

    /// The width a column `width` wide on a strip `strip` wide gets from its
    /// right edge dragged `delta` points, the edge staying under the
    /// pointer. A centred strip moves both its ends, so the column grows
    /// twice the pointer's way until it fills the viewport; past that, and
    /// on a strip that started wider, the camera holds (`dragCamera`) and
    /// the column follows the pointer.
    static func draggedWidth(_ width: CGFloat, strip: CGFloat, viewport: CGFloat, by delta: CGFloat) -> CGFloat {
        let slack = viewport - strip
        guard slack > 0 else { return width + delta }
        return width + (delta <= slack / 2 ? delta * 2 : slack + (delta - slack / 2))
    }

    /// Where the camera stays while that edge is dragged to `target`: nil,
    /// the strip centred, while a strip that started narrower than the
    /// viewport still is; at its left end once that strip outgrows it;
    /// where the drag found it on a strip that started wider. Let go, it
    /// goes where the strip wants it.
    static func dragCamera(width: CGFloat, strip: CGFloat, camera: CGFloat, viewport: CGFloat, to target: CGFloat) -> CGFloat? {
        guard strip <= viewport else { return camera }
        return strip - width + target <= viewport ? nil : 0
    }

    /// Where the camera goes when nothing holds it, for cards `widths` wide
    /// in a viewport `viewport` wide, `focus` focused: a strip narrower
    /// than the viewport lies in its middle; a wider one brings the focused
    /// card to the middle, stopping at the strip's ends. A card wider than
    /// the viewport shows from its left edge, with its air.
    static func camera(for widths: [CGFloat], focus: Int, viewport: CGFloat) -> CGFloat {
        let total = widths.reduce(0, +) + columnGap * CGFloat(widths.count - 1) + columnInset * 2
        guard total > viewport else { return -floor((viewport - total) / 2) }
        let left = widths[..<focus].reduce(columnInset) { $0 + $1 + columnGap }, width = widths[focus]
        let camera = width + columnInset * 2 > viewport ? left - columnInset : floor(left + width / 2 - viewport / 2)
        return max(0, min(camera, total - viewport))
    }

    /// Whether that camera centres the focused card.
    static func centres(_ widths: [CGFloat], focus: Int, viewport: CGFloat) -> Bool {
        let left = widths[..<focus].reduce(columnInset) { $0 + $1 + columnGap }
        return abs(left + widths[focus] / 2 - camera(for: widths, focus: focus, viewport: viewport) - viewport / 2) <= 1
    }

    static let minWidthFraction: CGFloat = 0.15
    /// How near a stop (a third, a half, two thirds) a dragged card lands on it.
    static let snapDistance: CGFloat = 10
    static let maxWidthFraction: CGFloat = 2.0

    /// Where the camera stays while the pointer works on a card. A click's
    /// (`NiruxShellView.clickBegan`) lasts until the click is over, while
    /// its card has the focus, within the strip; a dragged edge's lasts
    /// until let go, past the strip's ends too, so that its last edge
    /// dragged in stays under the pointer.
    struct CameraHold {
        var x: CGFloat
        var column: UUID
        var isDrag = false
    }

    /// Holds the camera where the strip shows for the column at `index`: a
    /// slide on its way stops there.
    func holdCamera(for index: Int) {
        stripView.frame.origin.x = shownStripX
        stripView.layer?.removeAnimation(forKey: Self.slideKey)
        lastCameraX = -stripView.frame.origin.x
        heldCamera = columns[safe: index].map { CameraHold(x: lastCameraX, column: $0.id) }
    }

    /// Where the strip shows: its place, plus a slide's offset on its way.
    private var shownStripX: CGFloat {
        let offset = stripView.layer?.presentation()?.value(forKeyPath: "transform.translation.x") as? NSNumber
        return stripView.frame.origin.x + (offset.map { CGFloat($0.doubleValue) } ?? 0)
    }

    /// Only the columns whose width changes take a new fraction: the others
    /// keep theirs as they are. Half a point over, so that `width(_:in:)`
    /// floors it back to the same width whatever the rounding.
    private func setColumnWidths(_ widths: [CGFloat], viewport: CGFloat) {
        let laidOut = columns.map(\.view.frame.width)
        guard widths.count == columns.count, widths != laidOut else { return }
        for (index, width) in widths.enumerated() where width != laidOut[index] {
            columns[index].widthFraction = min(Self.maxWidthFraction, max(Self.minWidthFraction, (width + Self.columnGap + 0.5) / max(Self.span(viewport), 1)))
        }
        layoutAndScroll(viewportWidth: viewport, height: containerView.bounds.height, animated: false)
    }

    func addColumn(agentUUID: String = UUID().uuidString, cwd: String? = nil) {
        let col = ColumnState(
            cwd: cwd ?? focusedWorkingDirectory,
            environment: terminalEnvironment(agentUUID: agentUUID)
        )
        setupAllTracking(for: col)
        insertColumn(col)
    }

    func addColumn(command: String, agentUUID: String = UUID().uuidString, cwd: String? = nil) {
        let col = ColumnState(
            cwd: cwd ?? focusedWorkingDirectory,
            command: command,
            environment: terminalEnvironment(agentUUID: agentUUID)
        )
        setupAllTracking(for: col)
        insertColumn(col)
    }

    func addColumn(deferredAgent: DeferredAgentLaunch, agentUUID: String, cwd: String?) {
        let environment = terminalEnvironment(agentUUID: agentUUID)
        let col = ColumnState(cwd: cwd ?? focusedWorkingDirectory, deferredAgent: deferredAgent, environment: environment)
        setupAllTracking(for: col)
        insertColumn(col)
    }

    func addColumn(webViewURL: String) {
        let col = ColumnState(url: webViewURL)
        insertColumn(col)
        // A browser column on a proposed port makes that proposal moot.
        col.webViewColumn?.onURLChanged = { [weak self] in self?.pruneLocalServerProposals() }
        pruneLocalServerProposals()
    }

    /// Insert a Monaco editor column scoped to the provided cwd, defaulting
    /// to this workspace's original cwd. `interactive` forwards to the file
    /// open path — session restore passes false so a binary or huge file in
    /// the persisted tabs can't pop a modal alert at every launch.
    func addEditorColumn(initialFile: String? = nil, workspaceCwd: String? = nil, interactive: Bool = true) {
        let col = ColumnState(editorWorkspaceCwd: workspaceCwd ?? cwd)
        insertColumn(col)
        if let initialFile {
            col.editorColumn?.open(path: initialFile, interactive: interactive)
        }
    }

    /// Insert a Project Board column next to the focused one.
    func addProjectBoardColumn(_ board: ProjectBoardController) {
        insertColumn(ColumnState(projectBoard: board))
    }

    /// Insert a Branch Review column next to the focused one.
    func addBranchReviewColumn(_ review: BranchReviewController) {
        insertColumn(ColumnState(branchReview: review))
    }

    func closeColumn(at index: Int) {
        guard columns.count > 1 else { return }
        let previouslyFocusedColumn = columns[safe: focusedIndex]
        let previousFocusedIndex = focusedIndex
        let col = columns.remove(at: index)
        col.view.removeFromSuperview()
        col.light?.removeFromSuperview()
        col.shadow?.removeFromSuperview()
        if resizeHandles.indices.contains(index) {
            let handle = resizeHandles.remove(at: index)
            handle.removeFromSuperview()
        }
        if focusedIndex >= columns.count {
            focusedIndex = columns.count - 1
        }
        if focusedIndex == previousFocusedIndex,
           columns[safe: focusedIndex] !== previouslyFocusedColumn {
            onFocusedColumnChanged?()
        }
    }

    enum MoveDir { case left, right }
    func moveColumn(_ dir: MoveDir) {
        let from = focusedIndex
        let to = dir == .left ? from - 1 : from + 1
        guard columns.indices.contains(to) else { return }
        columns.swapAt(from, to)
        focusedIndex = to
    }

    // MARK: - Layout & Scroll

    /// Air between the columns and around them: each rests on the window
    /// as a card (docs/design/glass-interface.md, depth study P1).
    static let columnGap = Theme.Space.sm
    static let columnInset = Theme.Space.sm
    private static let resizeHandleWidth: CGFloat = 9
    private static let slideKey = "colSlide"
    /// The strip's slide to a card.
    static let slideDuration: CFTimeInterval = 0.3

    /// Every column as it shows, whatever the camera shows, frozen at
    /// `scale` (depth study P5's plan); nil before a layout.
    func frozenColumns(scale: CGFloat) -> FrozenView? {
        FrozenView.freeze(stripView, scale: scale)
    }

    /// The strip that holds the columns: its size, and each column's frame
    /// in it.
    var stripSize: NSSize { stripView.frame.size }
    var columnFrames: [NSRect] { columns.map(\.view.frame) }

    /// What a width fraction of 1 spans, its gap included: the viewport
    /// less the air at its edges, plus one gap. Two halves then fill the
    /// viewport exactly, whatever the number of columns.
    static func span(_ viewportWidth: CGFloat) -> CGFloat {
        viewportWidth - columnInset * 2 + columnGap
    }

    /// The width a fraction of the viewport `viewportWidth` gives a column.
    private static func width(_ fraction: CGFloat, in viewportWidth: CGFloat) -> CGFloat {
        max(0, floor(fraction * span(viewportWidth) - columnGap))
    }

    /// The size `layoutAndScroll` gives `column` (outside fit-all) in a
    /// viewport `viewportWidth` by `height`.
    func size(of column: ColumnState, viewportWidth: CGFloat, height: CGFloat) -> NSSize {
        NSSize(width: Self.width(column.widthFraction, in: viewportWidth), height: max(0, height - Self.columnInset * 2))
    }

    /// `glides`: a card a neighbour pushed or let go glides to its place.
    func layoutAndScroll(
        viewportWidth: CGFloat, height: CGFloat, animated: Bool,
        fitAll: Bool = false, skipTerminalResize: Bool = false, glides: Bool = false
    ) {
        defer { onColumnsLaidOut?() }
        guard !columns.isEmpty else { return }
        let shown = glides ? columns.map(\.shownPlace) : []

        let gap = Self.columnGap, inset = Self.columnInset
        let innerHeight = max(0, height - inset * 2)
        let widths = fitAll
            ? Array(repeating: Self.width(1 / CGFloat(columns.count), in: viewportWidth), count: columns.count)
            : columns.map { size(of: $0, viewportWidth: viewportWidth, height: height).width }
        let totalWidth = widths.reduce(0, +) + gap * CGFloat(columns.count - 1) + inset * 2

        NiruxDebugLog.log("layoutAndScroll ws=\(id.prefix(8)) viewportW=\(viewportWidth) h=\(height) "
            + "widths=\(widths.map { Int($0) }) fitAll=\(fitAll)")

        // 2. Position each column, a card with air around it
        var xOffset = inset
        for (index, col) in columns.enumerated() {
            // Terminal frames are always set explicitly by layoutWithHeader;
            // autoresizing would push intermediate sizes to Ghostty during a
            // window resize before this layout pass runs (garbled display).
            col.terminalView?.autoresizingMask = []
            // A card passing in or out scales about the middle it had: one
            // that changes size is in place at once.
            if col.view.frame.size != NSSize(width: widths[index], height: innerHeight) {
                col.view.layer?.removeAnimation(forKey: ColumnState.passKey)
            }
            col.view.frame = NSRect(x: xOffset, y: inset, width: widths[index], height: innerHeight)
            col.light?.frame = col.view.frame
            shadow(for: col).frame = col.view.frame
            col.layoutWithHeader(width: widths[index], height: innerHeight, resizeTerminal: !skipTerminalResize)
            if let was = shown[safe: index], was.width == widths[index], !col.isArriving, abs(was.x - xOffset) > 0.5 {
                col.glide(by: was.x - xOffset)
            }
            // Its content clipped to its corners; its border (the focus) is
            // the shell's.
            col.view.layer?.masksToBounds = true
            col.view.layer?.cornerRadius = Theme.Radius.column

            // Resize handle straddling the air at this column's right edge.
            if resizeHandles.indices.contains(index) {
                let handle = resizeHandles[index]
                handle.isHidden = fitAll || (index != focusedIndex && index != focusedIndex - 1)
                handle.frame = NSRect(
                    x: xOffset + widths[index] + gap / 2 - Self.resizeHandleWidth / 2,
                    y: 0,
                    width: Self.resizeHandleWidth,
                    height: height
                )
            }

            xOffset += widths[index] + gap
        }
        showShadows()
        // Handles must stay above every column view, whichever order the
        // columns were inserted in.
        for handle in resizeHandles { stripView.addSubview(handle) }
        stripView.frame = NSRect(x: stripView.frame.origin.x, y: 0, width: totalWidth, height: height)

        // 3. Camera (`camera(for:focus:viewport:)`), unless a hold keeps it
        // (`CameraHold`). A click's hold is over once its card has lost the
        // focus.
        if let held = heldCamera, !held.isDrag, held.column != columns[safe: focusedIndex]?.id { heldCamera = nil }
        let cameraX: CGFloat
        if let held = heldCamera, held.isDrag {
            cameraX = held.x
        } else if let held = heldCamera, totalWidth > viewportWidth {
            cameraX = max(0, min(held.x, totalWidth - viewportWidth))
        } else {
            cameraX = Self.camera(for: widths, focus: focusedIndex, viewport: viewportWidth)
        }

        lastCameraX = cameraX

        // 4. Apply
        let stripX = -cameraX
        let oldX = stripView.frame.origin.x
        // From where it shows: a slide on its way goes on from there.
        let shownX = shownStripX
        stripView.frame.origin.x = stripX
        if animated, let layer = stripView.layer, oldX != stripX {
            let anim = CABasicAnimation(keyPath: "transform.translation.x")
            anim.fromValue = shownX - stripX
            anim.toValue = 0
            anim.duration = Self.slideDuration
            anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
            anim.isRemovedOnCompletion = true
            layer.add(anim, forKey: Self.slideKey)
        }
    }

    /// The column's shadow, made on first use: under every column of the
    /// strip, so that it falls only on the air around them.
    func shadow(for column: ColumnState) -> ColumnShadowView {
        if let shadow = column.shadow { return shadow }
        let shadow = ColumnShadowView(frame: column.view.frame)
        shadow.isCardClear = column.isCardClear
        stripView.addSubview(shadow, positioned: .below, relativeTo: nil)
        column.shadow = shadow
        return shadow
    }

    /// Each column's shadow, hidden while its card comes or goes: the fading
    /// card would show it. The fade's alpha can't tell: an animator sets
    /// the final one at once.
    func showShadows() {
        for column in columns { column.shadow?.isHidden = column.isArriving || column.isClosing }
    }

    /// The column's light (see `EdgeGlowView`), made on first use. It lies
    /// over the column, as its sibling: above the column's focus border,
    /// and never a layer of the terminal's own.
    func light(for column: ColumnState) -> EdgeGlowView {
        if let light = column.light { return light }
        let light = EdgeGlowView(edge: .around)
        light.frame = column.view.frame
        stripView.addSubview(light, positioned: .above, relativeTo: column.view)
        column.light = light
        return light
    }

    /// Whether the viewport shows the column at `index`: enough of it for
    /// its agent to be seen, not an edge sliver (see
    /// `NiruxShellView.showsColumn(left:width:cameraX:viewportWidth:)`).
    /// The one definition of "in view": for the lights, the agents
    /// restored on sight, a branch review.
    func showsColumn(at index: Int) -> Bool {
        guard let column = columns[safe: index] else { return false }
        let frame = column.view.frame
        return NiruxShellView.showsColumn(
            left: frame.minX, width: frame.width, cameraX: lastCameraX, viewportWidth: containerView.frame.width
        )
    }
}
