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
    private var lastCameraX: CGFloat = 0
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
    /// Whether new shells get the Mission variables.
    var carriesMissions: Bool { missionHandoffsEnabled || isLead || reportsToLead }
    /// Opened by a `nirux://` request from outside Nirux (one the user
    /// confirmed, with no launch ID): its shells never get the space's
    /// environment, nor its first agent the setup script (docs/projects.md,
    /// section 5). Kept across launches.
    let startedOutsideNirux: Bool
    /// Opened by a `nirux://` request from a Nirux terminal (an agent's: the
    /// worktree skill's, say; a user rarely types one), not by the user from
    /// Nirux: the Lead's `list_tasks` says who started it. Kept across
    /// launches.
    let startedByAgent: Bool
    /// The space's Lead (docs/spaces.md, "The Lead"): pinned at the top of
    /// its space, one per space, never inactive. Its shells get
    /// `NIRUX_LEAD=1`, fixed when each starts, which gives their Claude the
    /// Lead's instructions (NiruxMCPServer). Cleared when its space is
    /// deleted and it moves to General.
    var isLead: Bool
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
            if prInfo?.url != oldValue?.url || prInfo?.state != "OPEN" { prFeedback = nil }
            // Merged (or first seen merged): what the Lead wrote is over, and
            // nothing tells it. The user's stays.
            if prInfo?.state == "MERGED", oldValue?.state != "MERGED" { clearLeadContext() }
        }
    }
    /// The open PR's feedback (docs/pr-feedback-inbox.md), read after each
    /// PR refresh. Cleared when the PR changes or stops being open.
    var prFeedback: PRFeedback?
    /// Bumped at each feedback read: only the latest one applies.
    var prFeedbackGeneration = 0
    /// The red checks already reported (`CIFailure.reportKey`), and on
    /// which branch. The first call, at launch or on another branch, only
    /// records: a pull request that was already red isn't news.
    private var reportedRedChecks: (branch: String?, keys: Set<String>)?
    /// What the triage made of the pull request's red checks
    /// (docs/ci-failure-triage.md), and of which ones (`CITriage.signature`):
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
    var lastActivityAt: TimeInterval?
    var nextStep: String?
    var blocker: String?
    /// The Lead wrote `nextStep` (or `blocker`), not the user: its next
    /// update may replace it. False for an empty field.
    var nextStepIsFromLead = false
    var blockerIsFromLead = false
    var unknownPhaseRawValue: String?
    /// Each review pass's latest run (docs/review-badges.md).
    var reviewRuns: [ReviewPass: ReviewRun] = [:]

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
    /// A column's terminal title changed (fires before onMetadataChanged).
    var onColumnTitleChanged: ((ColumnState) -> Void)?
    var onFocusedColumnChanged: (() -> Void)?
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
        initialAgentUUID: String = UUID().uuidString
    ) {
        self.id = id
        // Before the first column: its shell reads them.
        self.startedOutsideNirux = startedOutsideNirux
        self.startedByAgent = startedByAgent
        self.isLead = isLead
        self.reportsToLead = reportsToLead
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
        containerView.layer?.masksToBounds = true

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
    /// (docs/ci-failure-actions.md).
    func takeNewRedChecks() -> [ProjectBoard.Check] {
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
        guard let state = info?.state.uppercased() else { return false }
        return state == "MERGED" || state == "CLOSED"
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
        guard lastSummary != compactSummary else { return changed }
        lastSummary = compactSummary
        return true
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
        case .preToolUse, .postToolUse, .subagentStop, .approvalResolved:
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
                    // The title is the shell's now; only claude's exits are
                    // reported (see AgentStatusMachine.noteAgentExited).
                    processName = "claude"
                } else if let col, let title = col.terminalTitle,
                   !title.isEmpty, !ColumnState.boringTitles.contains(title) {
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
        launchID: String
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
    /// strip subviews. Closures resolve the handle back to its CURRENT
    /// column index at event time, so moveColumn/closeColumn can't leave
    /// them pointing at the wrong column.
    private func makeResizeHandle() {
        let handle = ColumnResizeHandle()
        handle.onDragStart = { [weak self, weak handle] in
            guard let self, let handle,
                  let index = self.resizeHandles.firstIndex(of: handle),
                  self.columns.indices.contains(index) else { return 0.5 }
            // Dragging a column's edge focuses it (camera + sidebar follow).
            self.focusedIndex = index
            self.onMetadataChanged?()
            return self.columns[index].widthFraction
        }
        handle.onDrag = { [weak self, weak handle] fraction in
            guard let handle else { return }
            self?.setColumnWidth(for: handle, fraction: fraction)
        }
        handle.onReset = { [weak self, weak handle] in
            guard let handle else { return }
            self?.setColumnWidth(for: handle, fraction: ColumnWidth.half.fraction)
        }
        stripView.addSubview(handle)
        resizeHandles.append(handle)
    }

    static let minWidthFraction: CGFloat = 0.15
    static let maxWidthFraction: CGFloat = 2.0

    private func setColumnWidth(for handle: ColumnResizeHandle, fraction: CGFloat) {
        guard let index = resizeHandles.firstIndex(of: handle), columns.indices.contains(index) else { return }
        let clamped = min(Self.maxWidthFraction, max(Self.minWidthFraction, fraction))
        guard clamped != columns[index].widthFraction else { return }
        columns[index].widthFraction = clamped
        layoutAndScroll(
            viewportWidth: containerView.bounds.width,
            height: containerView.bounds.height,
            animated: false
        )
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

    private static let columnGap: CGFloat = 2
    private static let resizeHandleWidth: CGFloat = 9
    private static let focusBorderWidth: CGFloat = 2
    private static let focusCornerRadius: CGFloat = 6
    private static let focusColor = Theme.Color.accent.withAlphaComponent(0.7)

    /// The size `layoutAndScroll` gives `column` (outside fit-all).
    func size(of column: ColumnState, viewportWidth: CGFloat, height: CGFloat) -> NSSize {
        let gap = columns.count > 1 ? Self.columnGap : 0
        let totalGaps = gap * CGFloat(columns.count - 1)
        return NSSize(width: floor(column.widthFraction * (viewportWidth - totalGaps)), height: height)
    }

    func layoutAndScroll(
        viewportWidth: CGFloat, height: CGFloat, animated: Bool,
        fitAll: Bool = false, skipTerminalResize: Bool = false
    ) {
        guard !columns.isEmpty else { return }

        let gap = columns.count > 1 ? Self.columnGap : 0
        let totalGaps = gap * CGFloat(columns.count - 1)

        var widths: [CGFloat] = []
        var totalWidth: CGFloat = 0

        if fitAll {
            let columnWidth = floor((viewportWidth - totalGaps) / CGFloat(columns.count))
            for _ in columns { widths.append(columnWidth); totalWidth += columnWidth }
        } else {
            for col in columns {
                let width = size(of: col, viewportWidth: viewportWidth, height: height).width
                widths.append(width); totalWidth += width
            }
        }
        totalWidth += totalGaps

        NiruxDebugLog.log("layoutAndScroll ws=\(id.prefix(8)) viewportW=\(viewportWidth) h=\(height) "
            + "widths=\(widths.map { Int($0) }) fitAll=\(fitAll)")

        // 2. Position each column with gap
        var xOffset: CGFloat = 0
        for (index, col) in columns.enumerated() {
            // Terminal frames are always set explicitly by layoutWithHeader;
            // autoresizing would push intermediate sizes to Ghostty during a
            // window resize before this layout pass runs (garbled display).
            col.terminalView?.autoresizingMask = []
            col.view.frame = NSRect(x: xOffset, y: 0, width: widths[index], height: height)
            col.light?.frame = col.view.frame
            col.layoutWithHeader(width: widths[index], height: height, resizeTerminal: !skipTerminalResize)
            col.view.layer?.masksToBounds = true

            col.view.layer?.cornerRadius = 0
            col.view.layer?.borderWidth = 0
            col.view.layer?.borderColor = nil

            // Resize handle straddling this column's right boundary.
            if resizeHandles.indices.contains(index) {
                let handle = resizeHandles[index]
                handle.referenceWidth = max(viewportWidth, 1)
                handle.isHidden = fitAll
                handle.frame = NSRect(
                    x: xOffset + widths[index] + gap / 2 - Self.resizeHandleWidth / 2,
                    y: 0,
                    width: Self.resizeHandleWidth,
                    height: height
                )
            }

            xOffset += widths[index] + gap
        }
        // Handles must stay above every column view, whichever order the
        // columns were inserted in.
        for handle in resizeHandles { stripView.addSubview(handle) }
        stripView.frame = NSRect(x: stripView.frame.origin.x, y: 0, width: totalWidth, height: height)

        // 3. Camera (scroll to keep focused column visible)
        let cameraX: CGFloat
        if fitAll || totalWidth <= viewportWidth {
            cameraX = 0
        } else {
            var focusedLeft: CGFloat = 0
            for index in 0..<focusedIndex { focusedLeft += widths[index] + gap }
            let focusedRight = focusedLeft + widths[focusedIndex]

            var camera = lastCameraX
            if focusedLeft < camera {
                camera = focusedLeft
            } else if focusedRight > camera + viewportWidth {
                camera = focusedRight - viewportWidth
            }
            cameraX = max(0, min(camera, totalWidth - viewportWidth))
        }

        lastCameraX = cameraX

        // 4. Apply
        let stripX = -cameraX
        let oldX = stripView.frame.origin.x
        stripView.frame.origin.x = stripX
        if animated, let layer = stripView.layer, oldX != stripX {
            let anim = CABasicAnimation(keyPath: "transform.translation.x")
            anim.fromValue = oldX - stripX
            anim.toValue = 0
            anim.duration = 0.3
            anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
            anim.isRemovedOnCompletion = true
            layer.add(anim, forKey: "colSlide")
        }
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
