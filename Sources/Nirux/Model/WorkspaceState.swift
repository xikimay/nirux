import AppKit

/// Human-readable lifecycle state for a workspace. `WorkspaceState.phase`
/// is an optional manual override; when it is nil Nirux derives a phase from
/// the live agent, blocker, inactive, and pull-request state.
enum WorkspacePhase: String, Codable, CaseIterable {
    case active, waiting, blocked, review, parked, done

    var displayName: String {
        switch self {
        case .active: return "Active"
        case .waiting: return "Waiting"
        case .blocked: return "Blocked"
        case .review: return "Review"
        case .parked: return "Parked"
        case .done: return "Done"
        }
    }

    var symbol: String {
        switch self {
        case .active: return "▶"
        case .waiting: return "◷"
        case .blocked: return "!"
        case .review: return "◇"
        case .parked: return "–"
        case .done: return "✓"
        }
    }

    /// Pure derivation kept separate from the live workspace so phase rules
    /// remain predictable and unit-testable.
    static func derived(
        isInactive: Bool,
        hasBlocker: Bool,
        agentStatuses: [AgentStatus],
        pullRequestState: String?
    ) -> WorkspacePhase {
        if hasBlocker { return .blocked }
        if agentStatuses.contains(.needsAttention) { return .waiting }
        if agentStatuses.contains(.working) { return .active }
        if isInactive { return .parked }
        switch pullRequestState?.uppercased() {
        case "MERGED", "CLOSED": return .done
        case "OPEN": return .review
        default: return .active
        }
    }
}

/// A clickable area in the pilot info panel
struct PilotClickableArea {
    let frame: NSRect
    let url: String
    let label: NSTextField
}

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
    let missionID: String?
    /// Controls mission variables for terminals created after a Settings
    /// change. Already-running shells retain the environment they launched
    /// with and pick up changes after a new terminal or app restart.
    var missionHandoffsEnabled: Bool
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
    var hasNotification: Bool = false
    var prInfo: PRInfo?
    var diffStats: String?

    // Workspace context. Purpose/next step/blocker are always human-owned.
    // `phase` is a manual override (nil means derive from live state), while
    // automatic agent summaries are allowed only until the user edits one.
    var purpose: String?
    var phase: WorkspacePhase?
    var lastSummary: String?
    var lastSummaryIsManual: Bool = false
    var lastActivityAt: TimeInterval?
    var nextStep: String?
    var blocker: String?
    var unknownPhaseRawValue: String?

    var effectivePhase: WorkspacePhase {
        if let phase { return phase }
        return WorkspacePhase.derived(
            isInactive: isInactive,
            hasBlocker: Self.normalizedContextText(blocker) != nil,
            agentStatuses: columns.map { $0.pty?.cachedAgentState ?? .idle },
            pullRequestState: prInfo?.state
        )
    }

    // Pilot info panel (per-workspace, shown in pilot mode)
    var pilotPanel: NSView?
    var pilotDivider: NSView?
    var pilotAccentBar: NSView?
    var pilotPanelViews: [NSView] = []
    var pilotClickableAreas: [PilotClickableArea] = []
    var pilotColumnClickAreas: [(frame: NSRect, colIndex: Int)] = []
    weak var hoveredLabel: NSTextField?
    var lastPilotFingerprint: String = ""
    static let pilotAccentColor: NSColor = .niruxAccent

    /// Called by NiruxShellView to wire up sidebar refresh
    var onMetadataChanged: (() -> Void)?
    var onFocusedColumnChanged: (() -> Void)?
    var onGitContextChanged: (() -> Void)?
    var onDiffStatsClicked: (() -> Void)?
    /// A terminal link was cmd-clicked — the shell opens a browser column
    /// in this workspace.
    var onTerminalOpenURL: ((WorkspaceState, String) -> Void)?
    /// A terminal file: link was cmd-clicked — the shell opens it in an
    /// editor column in this workspace, at the optional line.
    var onTerminalOpenFile: ((WorkspaceState, String, Int?) -> Void)?

    init(
        id: String = UUID().uuidString,
        title: String? = nil,
        cwd: String,
        profileID: String = WorkspaceProfile.defaultID,
        missionID: String? = nil,
        missionHandoffsEnabled: Bool = false,
        initialAgentUUID: String = UUID().uuidString
    ) {
        self.id = id
        self.cwd = cwd
        self.title = title ?? "workspace"
        self.titleIsManual = (title != nil)
        self.profileID = profileID
        self.missionID = missionID
        self.missionHandoffsEnabled = missionHandoffsEnabled

        containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.masksToBounds = true

        stripView = NSView()
        stripView.wantsLayer = true
        containerView.addSubview(stripView)

        addColumn(agentUUID: initialAgentUUID)
    }

    /// Trim human-entered context and collapse blank values back to nil so
    /// optional sidebar rows do not consume space for whitespace-only text.
    static func normalizedContextText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
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
        case .stop, .turnComplete:
            return recordAgentActivity(at: event.timestamp, automaticSummary: event.detail)
        case .notification, .sessionStart, .sessionEnd, .userPromptSubmit:
            return recordAgentActivity(at: event.timestamp, automaticSummary: nil)
        case .preToolUse:
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
            GitDetect.contextAsync(at: workingDirectory) { [weak self] result in
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
        col.onTitleChanged = { [weak self] in
            self?.onMetadataChanged?()
        }
    }

    private func setupAgentAttentionTracking(for col: ColumnState) {
        col.onAgentAttention = { [weak self, weak col] in
            guard let self else { return }
            self.hasNotification = true
            self.onMetadataChanged?()
            // Bounce dock icon when app is not active
            if !NSApp.isActive {
                NSApp.requestUserAttention(.informationalRequest)
                // Native notification with click-to-focus routing.
                let processName: String
                if let col, let title = col.terminalTitle,
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
                    processName: processName
                )
            }
        }
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
    }

    private func setupAllTracking(for col: ColumnState) {
        setupCwdTracking(for: col)
        setupTitleTracking(for: col)
        setupAgentAttentionTracking(for: col)
        setupLinkOpening(for: col)
    }

    func detectGitBranch() {
        let workingDirectory = focusedWorkingDirectory
        guard let observation = beginGitContextObservation(at: workingDirectory) else { return }
        GitDetect.contextAsync(at: workingDirectory) { [weak self] result in
            self?.applyGitContextObservation(result, observation: observation)
        }
    }

    // MARK: - Column Management

    private func terminalEnvironment(agentUUID: String) -> [String: String] {
        Self.makeTerminalEnvironment(
            profileID: profileID,
            workspaceID: id,
            agentUUID: agentUUID,
            missionID: missionID,
            missionHandoffsEnabled: missionHandoffsEnabled,
            executablePath: Bundle.main.executableURL?.path
        )
    }

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
        executablePath: String?
    ) -> [String: String] {
        var environment = [
            "NIRUX_PROFILE_ID": profileID,
            "NIRUX_WORKSPACE_ID": workspaceID,
            // Hook events carry this back — see AgentHookCenter.
            "NIRUX_AGENT_UUID": agentUUID
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
    private var resizeHandles: [ColumnResizeHandle] = []

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

    func addColumn(agentUUID: String = UUID().uuidString) {
        let col = ColumnState(
            cwd: focusedWorkingDirectory,
            environment: terminalEnvironment(agentUUID: agentUUID)
        )
        setupAllTracking(for: col)
        insertColumn(col)
    }

    func addColumn(command: String, agentUUID: String = UUID().uuidString) {
        let col = ColumnState(
            cwd: focusedWorkingDirectory,
            command: command,
            environment: terminalEnvironment(agentUUID: agentUUID)
        )
        setupAllTracking(for: col)
        insertColumn(col)
    }

    func addColumn(webViewURL: String) {
        let col = ColumnState(url: webViewURL)
        insertColumn(col)
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

    func closeColumn(at index: Int) {
        guard columns.count > 1 else { return }
        let previouslyFocusedColumn = columns[safe: focusedIndex]
        let previousFocusedIndex = focusedIndex
        let col = columns.remove(at: index)
        col.view.removeFromSuperview()
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
    private static let focusColor = NSColor.niruxAccent.withAlphaComponent(0.7)

    func layoutAndScroll(
        viewportWidth: CGFloat, height: CGFloat, animated: Bool,
        fitAll: Bool = false, pilotMode: Bool = false, skipTerminalResize: Bool = false
    ) {
        guard !columns.isEmpty else { return }

        // Pilot panel: reserve space on the left in pilot mode
        let showPanel = pilotMode && pilotPanel != nil
        let panelWidth: CGFloat = showPanel ? Self.pilotPanelWidth : 0
        let dividerWidth: CGFloat = panelWidth > 0 ? 1 : 0
        let columnsViewportWidth = viewportWidth - panelWidth - dividerWidth

        // Position pilot panel and divider
        if let panel = pilotPanel {
            panel.frame = NSRect(x: 0, y: 0, width: panelWidth, height: height)
            panel.isHidden = !showPanel
            pilotDivider?.frame = NSRect(x: panelWidth, y: 0, width: dividerWidth, height: height)
            pilotDivider?.isHidden = !showPanel
            pilotAccentBar?.frame = NSRect(x: 0, y: 0, width: 4, height: height)
        }

        let gap = columns.count > 1 ? Self.columnGap : 0
        let totalGaps = gap * CGFloat(columns.count - 1)

        var widths: [CGFloat] = []
        var totalWidth: CGFloat = 0

        if fitAll {
            let columnWidth = floor((columnsViewportWidth - totalGaps) / CGFloat(columns.count))
            for _ in columns { widths.append(columnWidth); totalWidth += columnWidth }
        } else {
            for col in columns {
                let width = floor(col.widthFraction * (columnsViewportWidth - totalGaps))
                widths.append(width); totalWidth += width
            }
        }
        totalWidth += totalGaps

        NiruxDebugLog.log("layoutAndScroll ws=\(id.prefix(8)) viewportW=\(viewportWidth) h=\(height) "
            + "widths=\(widths.map { Int($0) }) fitAll=\(fitAll)")

        // 2. Position each column with gap
        var xOffset: CGFloat = 0
        for (index, col) in columns.enumerated() {
            // Terminal frames are always set explicitly by layoutWithTitleBar;
            // autoresizing would push intermediate sizes to Ghostty during a
            // window resize before this layout pass runs (garbled display).
            col.terminalView?.autoresizingMask = []
            col.view.frame = NSRect(x: xOffset, y: 0, width: widths[index], height: height)
            col.layoutWithTitleBar(width: widths[index], height: height, resizeTerminal: !skipTerminalResize)
            col.view.layer?.masksToBounds = true

            col.view.layer?.cornerRadius = 0
            col.view.layer?.borderWidth = 0
            col.view.layer?.borderColor = nil

            // Resize handle straddling this column's right boundary.
            if resizeHandles.indices.contains(index) {
                let handle = resizeHandles[index]
                handle.referenceWidth = max(columnsViewportWidth, 1)
                handle.isHidden = fitAll || pilotMode
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
        if fitAll || totalWidth <= columnsViewportWidth {
            cameraX = 0
        } else {
            var focusedLeft: CGFloat = 0
            for index in 0..<focusedIndex { focusedLeft += widths[index] + gap }
            let focusedRight = focusedLeft + widths[focusedIndex]

            var camera = lastCameraX
            if focusedLeft < camera {
                camera = focusedLeft
            } else if focusedRight > camera + columnsViewportWidth {
                camera = focusedRight - columnsViewportWidth
            }
            cameraX = max(0, min(camera, totalWidth - columnsViewportWidth))
        }

        lastCameraX = cameraX

        // 4. Apply — offset strip by panel width
        let stripX = -cameraX + panelWidth + dividerWidth
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

    /// Current horizontal scroll offset (for determining off-screen columns)
    var attentionCameraX: CGFloat { lastCameraX }

    /// Whether a column is currently visible in the viewport (not scrolled off-screen)
    func isColumnInViewport(_ index: Int) -> Bool {
        guard columns.indices.contains(index) else { return false }
        let viewportWidth = containerView.frame.width
        guard viewportWidth > 0 else { return true }
        let col = columns[index]
        let colLeft = col.view.frame.origin.x
        let colRight = colLeft + col.view.frame.width
        return colRight > lastCameraX && colLeft < lastCameraX + viewportWidth
    }
}
