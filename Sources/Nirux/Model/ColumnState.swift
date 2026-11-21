import AppKit
import GhosttyTerminal

// DropTargetView lives in Views/ColumnInternalViews.swift — NSView
// subclasses don't belong in the model layer.

/// A single column in a workspace — terminal or webview
@MainActor
final class ColumnState {
    /// Stable identity (unlike ObjectIdentifier, never reused after close).
    let id = UUID()
    let view: NSView
    var terminalView: TerminalView?
    /// Called on the main thread just before its shell starts: its
    /// workspace may give it a size first (see
    /// `NiruxShellView.sizeTerminalOffScreen`).
    var onShellStarting: (() -> Void)?
    /// Its terminal has a Ghostty surface.
    private(set) var hasSurface = false
    var webViewColumn: WebViewColumn?
    var editorColumn: EditorColumn?
    /// The Project Board this column shows.
    private(set) var projectBoard: ProjectBoardController?
    /// The branch this column reviews.
    private(set) var branchReview: BranchReviewController?
    /// Column width as a fraction of the columns viewport (0.15…2.0).
    /// Freeform (drag the resize handles); the ColumnWidth presets are just
    /// named stops the width cycler snaps to.
    var widthFraction: CGFloat = ColumnWidth.half.fraction
    private(set) var pty: PtySession?
    /// Close in flight: ⌘W removes the column after its exit animation.
    var isClosing = false
    var onCwdChanged: ((String) -> Void)?
    var onTitleChanged: (() -> Void)?
    /// Fires when the agent asks for attention (hook-routed turn end /
    /// permission prompt while the user isn't watching this column).
    /// The agent asks for the user (alert), with why when known.
    var onAgentAttention: ((AgentAttentionReason?) -> Void)?
    /// An agent that says its state (OSC 7501) reported its turn over:
    /// Codex done or idle, Antigravity done. A Mission message may go to it.
    var onProgramTurnOver: (() -> Void)?

    /// Fires when the user cmd-clicks an http(s) link in the terminal —
    /// the workspace opens it in a browser column.
    var onOpenURL: ((String) -> Void)?

    /// Fires when the user cmd-clicks a file: link in the terminal — the
    /// workspace routes it into an editor column at the optional line.
    var onOpenFile: ((String, Int?) -> Void)?

    /// Fires (main queue) when the terminal prints a local dev-server URL.
    /// The workspace decides whether it becomes a proposal chip.
    var onLocalServerURLDetected: ((LocalServerURL) -> Void)?
    var onLocalServerChipOpen: ((LocalServerURL) -> Void)?
    var onLocalServerChipDismiss: ((LocalServerURL) -> Void)?
    private var localServerChip: LocalServerChipView?

    /// Stable identity injected into the terminal environment as
    /// NIRUX_AGENT_UUID — Claude/Codex hook events carry it back so
    /// AgentHookCenter can route them to THIS column. Persisted across
    /// restarts; survives shell restarts (same terminal spec).
    let agentUUID: String?

    private var codexSessionTracker = ForegroundSessionTracker.codex
    private var agySessionTracker = ForegroundSessionTracker.agy
    private var claudeSessionTracker = ClaudeSessionTracker()
    /// State this agent column was restored from — saved as-is while its
    /// launch command hasn't started the agent yet (see
    /// `NiruxShellView.isLaunchingRestoredAgent`), then dropped.
    var restoredColumn: PersistedColumn?
    /// The restored agent this column starts when it resumes; no shell runs
    /// until then (ColumnState+DeferredAgent.swift).
    private(set) var deferredAgent: DeferredAgentLaunch?
    /// The user asked the column to resume its agent (its notice).
    var onResumeDeferredAgent: (() -> Void)?
    var deferredAgentOverlay: ShellExitedOverlay?

    /// Terminal title from OSC 0/2 (agent context, vim filename, etc.)
    var terminalTitle: String? {
        didSet { terminalHeader?.title = terminalTitle ?? "" }
    }

    // MARK: - Header (pushes the terminal down)
    static let boringTitles: Set<String> = ["zsh", "bash", "fish", "sh", "-zsh", "-bash"]
    /// A terminal column's header; the other types own theirs.
    private(set) var terminalHeader: ColumnHeaderView?
    /// The column's header, whatever its type (see `ColumnHeaderView`).
    var header: ColumnHeaderView? {
        terminalHeader ?? webViewColumn?.header ?? editorColumn?.header ?? projectBoard?.view.header
            ?? branchReview?.view.header
    }
    /// What a terminal is and where, for Global Search and Session History
    /// ("claude · ~/repo", "claude (not resumed) · ~/repo"): its title and
    /// its folder's last two parts. Empty before its first refresh.
    var titleText: String {
        guard let terminalHeader else { return "" }
        let title = deferredAgent == nil || terminalHeader.title.isEmpty
            ? terminalHeader.title : "\(terminalHeader.title) (not resumed)"
        return [title, folder.abbreviatedPath(maxComponents: 2)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The terminal's folder, whole, as last read (`updateHeaderTitle`): its
    /// title's tooltip, off the bar, which the command bar's task names.
    private(set) var folder = ""

    /// Height reserved for the terminal's header.
    var headerHeight: CGFloat {
        pty != nil ? ColumnHeaderView.height : 0
    }

    /// The header shows the column has the focus.
    func setHeaderFocused(_ isFocused: Bool) {
        header?.isFocused = isFocused
    }

    /// Spec needed to respawn the shell after it exits.
    private var terminalSpec: (cwd: String, shellArgs: [String], environment: [String: String])?
    /// The first shell start is on its way (or done): a column restored
    /// without its agent starts one only when the agent resumes.
    private(set) var isShellStartScheduled = false
    private var shellExitedOverlay: ShellExitedOverlay?
    /// An agent died mid-turn in the shell that still runs here
    /// (ColumnState+StuckAgent.swift).
    var agentExitOverlay: ShellExitedOverlay?
    /// The agent last seen in the foreground, and when: gone from the
    /// process table once it leaves, it exited rather than being suspended.
    var lastForegroundAgent: ForegroundProcess?
    /// Reads the process table where a terminal's own report needs it
    /// (tests give an empty one, as an ENOMEM read gives).
    var readsProcesses: () -> ProcessSnapshot = { ProcessSnapshot() }
    var lastForegroundAgentSeenAt: TimeInterval = 0
    /// The user asked to resume the agent that died mid-turn.
    var onResumeExitedAgent: (() -> Void)?
    /// The agent's state as light, laid over the column in its workspace's
    /// strip once it first shows (`WorkspaceState.light(for:)`).
    var light: EdgeGlowView?
    /// The column's shadow, under every column of its strip
    /// (`WorkspaceState.shadow(for:)`).
    var shadow: ColumnShadowView?
    /// Its card fades in (`NiruxShellView.addColumn`).
    var isArriving = false
    /// Passes in or out its card took, the last one owning it (`pass`).
    var passes = 0
    /// Moves on their way that lift its card over a neighbour (`lift`).
    var lifts = 0
    /// Moves on their way that pass over its card, and the shade they dim
    /// it with (`lift`).
    var dims = 0
    var passShadeView: PassShadeView?

    /// ⌘F find bar, created on first use, and the terminal search it
    /// drives; a browser column's bar drives its `pageFind`
    /// (ColumnState+Find.swift).
    var findBar: FindBar?
    var terminalSearch: TerminalSearchSession?

    /// Claude session transcript this column follows, its latest usage and
    /// the header label showing it (ColumnState+AgentUsage.swift).
    var claudeTranscript: ClaudeTranscriptFollow?
    var agentUsage: ClaudeSessionUsage?
    var usageLabel: ColumnHeaderLabel?

    private func setupHeader() {
        let header = ColumnHeaderView()
        header.icon = .symbol(Theme.Symbol.terminal)
        header.menuProvider = { Self.terminalMenu() }
        header.isHidden = true
        view.addSubview(header)
        terminalHeader = header
    }

    /// The terminal's ⋯ menu.
    private static func terminalMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ColumnHeaderView.columnItem(
            "Find in Terminal…", mainMenuAction: #selector(NiruxApp.showFind(_:))
        ) { $0.showFind() })
        menu.addItem(.separator())
        ColumnHeaderView.columnMenuItems().forEach(menu.addItem)
        return menu
    }

    /// Update the header's title, the title or the process, and its
    /// tooltip, the folder. The snapshot is only evaluated for shell
    /// titles, which fall back to the foreground process name.
    func updateHeaderTitle(snapshot: @autoclosure () -> ProcessSnapshot) {
        guard let header = terminalHeader else { return }
        if let deferredAgent {
            header.title = deferredAgent.processName
        } else if let termTitle = terminalTitle, !termTitle.isEmpty, !Self.boringTitles.contains(termTitle) {
            header.title = termTitle
        } else {
            header.title = pty?.foregroundProcessName(snapshot: snapshot()) ?? "shell"
        }
        // An agent waiting to resume: the folder it will launch in.
        let path = deferredAgent != nil ? launchDirectory : pty?.childCwd
        folder = path?.abbreviatedPath(maxComponents: .max) ?? ""
        header.titleToolTip = folder.isEmpty ? nil : folder
    }

    /// The terminal header's agent icon and status, from the sidebar's
    /// reading of the column, what blocks its agent on the user, and its
    /// task's station.
    func updateHeaderAgentState(_ column: ColumnInfo, wait: AgentWait?, now: TimeInterval, station: BoardStages.Station?) {
        guard let header = terminalHeader else { return }
        header.icon = .terminal(processName: column.deferredAgent?.processName ?? column.processName)
        header.status = .agent(column, wait: wait, now: now, station: station)
    }

    /// Position the header and optionally resize terminal to fit. Called from layoutAndScroll.
    func layoutWithHeader(width: CGFloat, height: CGFloat, resizeTerminal: Bool = true) {
        let barHeight = headerHeight
        terminalHeader?.isHidden = (barHeight == 0)

        if barHeight > 0, let header = terminalHeader {
            // Header at the top of the column (NSView: y=0 is bottom).
            header.frame = NSRect(x: 0, y: height - barHeight, width: width, height: barHeight)
            header.layoutNow()
        }

        // Terminal fills the remaining space below the header
        if resizeTerminal, let terminal = terminalView {
            terminal.frame = NSRect(x: 0, y: 0, width: width, height: height - barHeight)
            shellExitedOverlay?.frame = terminal.frame
            agentExitOverlay?.frame = terminal.frame
            deferredAgentOverlay?.frame = terminal.frame
        }
        roundTerminal()
        layoutFindBar()
    }

    /// Show (or hide, with nil) the "open this dev server" chip, the
    /// header's last accessory: it keeps its room before the usage label.
    func setLocalServerChip(_ url: LocalServerURL?) {
        if localServerChip == nil {
            guard url != nil, let header = terminalHeader else { return }
            let chip = LocalServerChipView(frame: .zero)
            chip.onOpen = { [weak self] url in self?.onLocalServerChipOpen?(url) }
            chip.onDismiss = { [weak self] url in self?.onLocalServerChipDismiss?(url) }
            header.accessories.append(chip)
            localServerChip = chip
        }
        localServerChip?.configure(url: url)
        terminalHeader?.layoutNow()
    }

    /// True if this column is a WebView (not a terminal)
    var isWebView: Bool { webViewColumn != nil }

    /// True if this column is an Editor (Monaco-backed)
    var isEditor: Bool { editorColumn != nil }

    var isProjectBoard: Bool { projectBoard != nil }

    var isBranchReview: Bool { branchReview != nil }

    /// Escape a file path for safe pasting into a shell.
    private static func shellEscape(_ path: String) -> String {
        if path.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "/" || $0 == "." || $0 == "-" || $0 == "_" }) {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    convenience init(cwd: String, environment: [String: String] = [:]) {
        self.init(cwd: cwd, shellArgs: ["-l"], environment: environment)
    }

    /// Init for a terminal that runs a command immediately (e.g. claude --resume <id>).
    /// When the command exits, drops into an interactive shell.
    convenience init(cwd: String, command: String, environment: [String: String] = [:]) {
        // Match a normal terminal launch: interactive + login shell. This
        // ensures PATH/bootstrap logic from .zprofile/.zshrc is available
        // when Nirux restores command-backed columns after a Finder relaunch.
        self.init(cwd: cwd, shellArgs: Self.commandShellArgs(command), environment: environment)
    }

    /// A restored agent column whose agent waits to resume: the terminal is
    /// there, its shell starts with the agent's launch command later
    /// (`startDeferredAgent`).
    convenience init(cwd: String, deferredAgent: DeferredAgentLaunch, environment: [String: String] = [:]) {
        self.init(cwd: cwd, shellArgs: nil, environment: environment)
        self.deferredAgent = deferredAgent
        showDeferredAgentNotice(deferredAgent)
    }

    /// The terminal's background opacity (Settings › Appearance ›
    /// Terminals); 1, opaque on the canvas fill.
    private(set) var terminalOpacity: Double = 1
    /// Whether the shell last said the column is on screen.
    private var terminalOnScreen = false
    /// The desktop's blur under the terminal, in place of the canvas fill,
    /// so that nothing of the window lies between them: below 100 %, on
    /// screen, once the terminal draws.
    private(set) var terminalFrost: NSVisualEffectView?

    /// Shows the terminal's background at `opacity` over the desktop's blur
    /// (`TerminalOpacity`), with the minimum contrast its own config allows;
    /// a column without a terminal stays opaque.
    func showTerminalOpacity(_ opacity: Double, onScreen: Bool) {
        guard let terminal = terminalView else { return }
        terminalOnScreen = onScreen
        if opacity != terminalOpacity, let controller = terminal.controller {
            terminalOpacity = opacity
            controller.setTerminalConfiguration(TerminalOpacity.configuration(
                opacity, userSetsContrast: TerminalOpacity.setsContrast(controller.currentConfigSource)
            ))
        }
        updateTerminalFrost()
    }

    /// The frost goes in once the terminal can draw over it: before its
    /// first frame the opaque fill stays, rather than the bare blur.
    private func updateTerminalFrost() {
        let wanted = terminalOpacity < 1 && terminalOnScreen && hasSurface
        guard wanted != (terminalFrost != nil) else { return }
        if wanted {
            let frost = NSVisualEffectView()
            MainWindowContent.makeDesktopFrost(frost, in: view.bounds)
            // Blending behind the window ignores the column's rounded
            // clip: the mask holds the corners.
            frost.maskImage = Self.frostMask
            view.addSubview(frost, positioned: .below, relativeTo: nil)
            terminalFrost = frost
            view.layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            terminalFrost?.removeFromSuperview()
            terminalFrost = nil
            view.layer?.backgroundColor = Theme.Color.canvas.cgColor
        }
        shadow?.isCardClear = isCardClear
    }

    /// The desktop's blur shows through the card (`terminalFrost`).
    var isCardClear: Bool { terminalFrost != nil }

    private static let frostMask = GlassView.mask(
        radius: Theme.Radius.column, in: CGSize(width: CGFloat.infinity, height: .infinity), curve: .circular
    )

    /// The terminal's surface came or went.
    func surfaceChanged(attached: Bool) {
        hasSurface = attached
        updateTerminalFrost()
        roundTerminal()
    }

    /// The card's bottom corners on the terminal's own layer, rounded as
    /// the compositor draws Ghostty's surface: nothing of it lies in the
    /// corners its column clips. Ghostty swaps the layer for its own once
    /// the surface comes.
    private func roundTerminal() {
        guard let layer = terminalView?.layer else { return }
        layer.roundCardCorners(top: false)
        layer.masksToBounds = true
    }

    /// A column's view, opaque under its content in the canvas's colour,
    /// which showed there before the window could be translucent: a
    /// terminal before its first frame, or a page still loading, never
    /// lets the desktop through; only a terminal below 100 % does
    /// (`showTerminalOpacity`).
    private static func filled<View: NSView>(_ view: View) -> View {
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.Color.canvas.cgColor
        return view
    }

    /// The login shell's arguments to run `command`, then stay as a shell.
    /// The shell path is single-quoted — an unquoted path with spaces or
    /// metacharacters would be word-split by the -c string.
    private static func commandShellArgs(_ command: String) -> [String] {
        let shell = PtySession.defaultShell
        let quotedShell = "'" + shell.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return ["-i", "-l", "-c", "\(command); exec \(quotedShell) -i -l"]
    }

    /// Shared terminal init — pass extra shell args for command mode, nil
    /// to start no shell yet.
    private init(cwd: String, shellArgs: [String]?, environment: [String: String]) {
        terminalSpec = (cwd, shellArgs ?? [], environment)
        agentUUID = environment["NIRUX_AGENT_UUID"]
        let dropView = Self.filled(DropTargetView())
        view = dropView

        let ptySession = PtySession()
        pty = ptySession

        // File drop → paste escaped path(s) into PTY, once one runs.
        dropView.acceptsFileDrops = { [weak self] in self?.isAwaitingResume != true }
        dropView.onFileDrop = { [weak ptySession] urls in
            let paths = urls.map { Self.shellEscape($0.path) }.joined(separator: " ")
            if let data = paths.data(using: .utf8) {
                ptySession?.sendRaw(data)
            }
        }

        let terminal = TerminalView(frame: .zero)
        terminal.controller = TerminalAppearance.makeController()
        terminal.configuration = TerminalSurfaceOptions(
            backend: .inMemory(ptySession.terminalSession),
            workingDirectory: cwd
        )
        terminal.delegate = self
        // libghostty-spm takes drops on the terminal itself: Nirux's own
        // drop view underneath keeps them (paths into the PTY, none while
        // the agent waits to resume).
        terminal.unregisterDraggedTypes()
        view.addSubview(terminal)
        terminalView = terminal

        // Header (above the terminal, not overlapping)
        setupHeader()

        // Forward cwd changes
        ptySession.onCwdChanged = { [weak self] path in
            self?.onCwdChanged?(path)
        }

        // Forward title changes (OSC 0/2)
        ptySession.onTitleChanged = { [weak self] title in
            self?.terminalTitle = title
            self?.onTitleChanged?()
        }

        // Forward OSC 9 (turn complete for sessions without hook coverage)
        ptySession.onOsc9Received = { [weak self] in
            self?.onAgentAttention?(nil)
        }
        ptySession.onApprovalsAbandoned = { [weak self] requests in
            requests.forEach { AgentHookCenter.shared.release($0, agentUUID: self?.agentUUID) }
        }
        // Only the agent's own, in front: any program can print the sequence.
        ptySession.onProgramStatus = { [weak self, weak ptySession] status in
            guard let self, let ptySession else { return }
            guard status.process != AgentProgramStatus.codex else { return noteCodexStatus(status, in: ptySession) }
            // One read on an empty process table goes to the agy last seen in front.
            let snapshot = readsProcesses()
            guard ptySession.isNewProgramStatus(status),
                  let agy = snapshot.isEmpty ? lastForegroundAgent : ptySession.foregroundProcess(snapshot: snapshot),
                  agy.name == status.process
            else { return }
            let isUserFocused = agentUUID.flatMap { AgentHookCenter.shared.resolver?($0) }?.isUserFocused ?? false
            if let reason = ptySession.applyProgramStatus(status, from: agy.instance, isUserFocused: isUserFocused) {
                onAgentAttention?(reason)
            }
            if status.state == .done { onProgramTurnOver?() }
        }

        ptySession.onLocalServerURL = { [weak self] url in
            self?.onLocalServerURLDetected?(url)
        }

        // Shell exit → show the restart overlay over the (still visible)
        // terminal. Scrollback survives a restart.
        ptySession.onProcessExit = { [weak self] in
            self?.showShellExitedOverlay()
        }

        if let shellArgs { scheduleShellStart(cwd: cwd, args: shellArgs, environment: environment) }
    }

    /// Delay shell start so the terminal surface is created first. Weak: a
    /// column closed meanwhile forks no shell.
    private func scheduleShellStart(cwd: String, args: [String], environment: [String: String]) {
        isShellStartScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak pty] in
            MainActor.assumeIsolated { self?.onShellStarting?() }
            pty?.start(
                shell: PtySession.defaultShell,
                args: args,
                cwd: cwd,
                cols: 80,
                rows: 24,
                environment: environment
            )
        }
    }

    /// Take the agent this column waits to start: its notice goes and the
    /// column no longer waits. Nil when nothing waits.
    func takeDeferredAgent() -> DeferredAgentLaunch? {
        guard let deferredAgent else { return nil }
        self.deferredAgent = nil
        hideDeferredAgentNotice()
        return deferredAgent
    }

    /// Start the shell of a column created without one, running `command`
    /// like any agent column restored at launch. Once only.
    func startShell(command: String) {
        guard !isShellStartScheduled, let spec = terminalSpec else { return }
        let args = Self.commandShellArgs(command)
        terminalSpec = (spec.cwd, args, spec.environment)
        scheduleShellStart(cwd: spec.cwd, args: args, environment: spec.environment)
    }

    /// Where, and with what environment, the column's shell starts.
    var launchDirectory: String? { terminalSpec?.cwd }
    var launchEnvironment: [String: String]? { terminalSpec?.environment }

    /// Where, and with what environment, the shell of a column created
    /// without one starts. No effect once it started.
    func setLaunch(directory: String, environment: [String: String]) {
        guard !isShellStartScheduled, let spec = terminalSpec else { return }
        terminalSpec = (directory, spec.shellArgs, environment)
    }

    /// WebView column
    init(url: String) {
        agentUUID = nil
        view = Self.filled(NSView())

        let webView = WebViewColumn(url: url)
        webView.autoresizingMask = [.width, .height]
        view.addSubview(webView)
        webViewColumn = webView
    }

    /// Editor column (Monaco-backed). Scoped to a workspace cwd.
    init(editorWorkspaceCwd: String) {
        agentUUID = nil
        view = Self.filled(NSView())

        let editor = EditorColumn(workspaceCwd: editorWorkspaceCwd)
        editor.autoresizingMask = [.width, .height]
        view.addSubview(editor)
        editorColumn = editor
    }

    /// Project Board column: a project's branches, agents and pull requests.
    init(projectBoard: ProjectBoardController) {
        agentUUID = nil
        view = Self.filled(NSView())

        let board = projectBoard.view
        board.autoresizingMask = [.width, .height]
        view.addSubview(board)
        self.projectBoard = projectBoard
    }

    /// Branch Review column: one branch, read-only.
    init(branchReview: BranchReviewController) {
        agentUUID = nil
        view = Self.filled(NSView())

        let review = branchReview.view
        review.autoresizingMask = [.width, .height]
        view.addSubview(review)
        self.branchReview = branchReview
    }

    /// Snap to the next preset (same cycle order as before: from any
    /// freeform width, jump to whatever preset follows the nearest one).
    func cycleWidth() {
        let all = ColumnWidth.allCases
        let nearest = all.indices.min(by: {
            abs(all[$0].fraction - widthFraction) < abs(all[$1].fraction - widthFraction)
        }) ?? 0
        widthFraction = all[(nearest + 1) % all.count].fraction
        NiruxDebugLog.log("cycleWidth -> \(widthFraction)")
    }

    /// AgentHookCenter entry point: the agent in this column just asked for
    /// attention — forward to the workspace-level notification wiring.
    func notifyAgentAttention(reason: AgentAttentionReason?) {
        onAgentAttention?(reason)
    }

    func prepareCodexResume(sessionID: String) {
        codexSessionTracker.prepareResume(sessionID: sessionID)
    }

    func captureCodexSession(
        sessionID: String?,
        soleInputDigest: String? = nil,
        emitterProcess: ProcessInstance?,
        snapshot: ProcessSnapshot
    ) -> Bool {
        guard let place = hookEmitterPlace(emitterProcess, snapshot: snapshot) else { return false }
        return codexSessionTracker.capture(
            sessionID: sessionID, soleInputDigest: soleInputDigest, emitterBelongsToForegroundJob: place.inForegroundJob,
            foregroundProcess: place.foreground
        )
    }

    /// Binds the conversation the column's `agy` reports in its hooks: its
    /// own, not a nested agy's that its shell tool started in its job.
    func captureAgySession(sessionID: String?, emitterProcess: ProcessInstance?, snapshot: ProcessSnapshot) -> Bool {
        guard let place = hookEmitterPlace(emitterProcess, snapshot: snapshot),
              !AgentHookCenter.isHeadlessAgy(place.foreground) else { return false }
        return agySessionTracker.capture(
            sessionID: sessionID, emitterBelongsToForegroundJob: emitterProcess == place.foreground?.instance,
            foregroundProcess: place.foreground
        )
    }

    /// The Antigravity conversation this column's `agy` process proved it runs.
    func boundAgySessionID(of process: ProcessInstance) -> String? {
        agySessionTracker.boundSessionID(for: process)
    }

    /// The process in front, and whether a hook's emitter runs in its job.
    private func hookEmitterPlace(
        _ emitterProcess: ProcessInstance?, snapshot: ProcessSnapshot
    ) -> (foreground: ForegroundProcess?, inForegroundJob: Bool)? {
        guard let pty else { return nil }
        let inForegroundJob = emitterProcess.map { pty.isProcessInForegroundJob($0, snapshot: snapshot) } ?? false
        return (pty.foregroundProcess(snapshot: snapshot), inForegroundJob)
    }

    func prepareAgyResume(sessionID: String) {
        agySessionTracker.prepareResume(sessionID: sessionID)
    }

    func persistedAgySessionID(foregroundProcess: ForegroundProcess?) -> String? {
        agySessionTracker.sessionID(for: foregroundProcess)
    }

    func persistedCodexSessionID(foregroundProcess: ForegroundProcess?) -> String? {
        codexSessionTracker.sessionID(for: foregroundProcess)
    }

    /// The Codex thread this column's `codex` process proved it runs.
    func boundCodexSessionID(of process: ProcessInstance) -> String? {
        codexSessionTracker.boundSessionID(for: process)
    }

    /// Codex says each state once (its own cache): every one is kept, a
    /// restarted codex's first too, which may equal the last of the one
    /// before. One read on an empty process table belongs to the codex in
    /// front then, which is checked where it is read.
    private func noteCodexStatus(_ status: AgentProgramStatus, in pty: PtySession) {
        let snapshot = ProcessSnapshot()
        let front = pty.foregroundProcess(snapshot: snapshot)
        guard snapshot.isEmpty || front?.name == status.process else { return }
        pty.noteCodexStatus(status, from: snapshot.isEmpty ? nil : front?.instance)
        if [.done, .idle].contains(status.state) { onProgramTurnOver?() }
    }

    /// Why a Mission message can't go into the queue of this column's Codex
    /// now (`AgentStatusMachine.codexQueueRefusal`), or `.noConversation`
    /// while its `codex` proved no thread; nil when it can.
    func codexMissionRefusal(runningSince: TimeInterval, snapshot: ProcessSnapshot) -> AgentPromptRefusal? {
        guard let pty else { return .noClaude }
        if let refusal = pty.codexQueueRefusal(runningSince: runningSince, snapshot: snapshot) { return refusal }
        guard let codex = pty.foregroundProcess(snapshot: snapshot), provenCodexSessionID(of: codex) != nil else { return .noConversation }
        return nil
    }

    /// Whether this column's `codex` will never prove a thread: one started
    /// without a prompt, and not resumed (`CodexLaunch.canProve`).
    func runsUnprovableCodex(snapshot: ProcessSnapshot) -> Bool {
        guard let codex = pty?.foregroundProcess(snapshot: snapshot), codex.name == AgentProgramStatus.codex,
              !AgentHookCenter.isHeadlessCodex(codex) else { return false }
        return provenCodexSessionID(of: codex) == nil && !CodexLaunch.canProve(codex)
    }

    /// The thread `process`, this column's `codex`, started with its
    /// launch prompt or resumed (see `ForegroundSessionTracker`): the one a
    /// Mission message goes to.
    func provenCodexSessionID(of process: ForegroundProcess) -> String? {
        codexSessionTracker.provenSessionID(for: process)
    }

    func prepareClaudeResume(sessionID: String) {
        claudeSessionTracker.prepareResume(sessionID: sessionID)
    }

    private var planningSession: (process: ProcessInstance, id: String)?

    func isPlanning(in foreground: ForegroundProcess?) -> Bool {
        guard let planningSession, let foreground, foreground.instance == planningSession.process else { return false }
        return claudeSessionTracker.boundSessionID(for: foreground.instance) == planningSession.id
    }

    /// Whether a Claude hook event comes from this column's own `claude`
    /// (see ClaudeSessionTracker) — and bind the session it reports.
    func admitClaudeHook(
        _ event: AgentHookEvent,
        foregroundProcess: ForegroundProcess?,
        snapshot: ProcessSnapshot
    ) -> ClaudeSessionTracker.Admission {
        let emitter = ClaudeSessionTracker.Emitter.placing(
            event.emitterProcess,
            foreground: foregroundProcess,
            shellPID: pty?.shellPID ?? 0,
            snapshot: snapshot
        )
        let admission = claudeSessionTracker.admit(
            event.name,
            sessionID: event.sessionID,
            source: event.source,
            emitter: emitter,
            foregroundProcess: foregroundProcess
        )
        // Follow the transcript of the session now bound to the foreground
        // `claude` — never one a subagent, teammate or nested run reports.
        if admission != .rejected, event.agentID == nil,
           let sessionID = event.sessionID,
           let foregroundProcess,
           claudeSessionTracker.boundSessionID(for: foregroundProcess.instance) == sessionID {
            if event.name == .sessionEnd || event.name == .sessionStart || event.permissionMode != nil {
                planningSession = event.name != .sessionEnd && event.permissionMode == "plan" ? (foregroundProcess.instance, sessionID) : nil
            }
            if let path = event.transcriptPath.flatMap(AgentHookEvent.validTranscriptPath) {
                followClaudeTranscript(at: path, sessionID: sessionID, process: foregroundProcess.instance)
            }
        }
        return admission
    }

    /// Whether the column's `claude` runs on the login Nirux's own `claude
    /// -p` uses, as its hooks last said (`AgentHookEvent.onNiruxAccount`),
    /// of which process (another `claude` in the column starts unknown)
    /// and from which folder.
    private var claudeAccount: (process: ProcessInstance, onNiruxAccount: Bool, cwd: String?)?

    func noteClaudeAccount(onNiruxAccount: Bool, of process: ProcessInstance, cwd: String?) {
        claudeAccount = (process, onNiruxAccount, cwd)
    }

    /// What the `claude` in front said, when it works in `repositoryRoot`
    /// (a `claude` of another project says nothing of this one). Nil: none
    /// in front, one that hasn't said, or one working elsewhere. It fails
    /// safe: nothing of the project goes to a model.
    func isClaudeOnNiruxAccount(foregroundProcess: ForegroundProcess?, inRepository repositoryRoot: String) -> Bool? {
        guard let claudeAccount, let foregroundProcess, foregroundProcess.instance == claudeAccount.process,
              let cwd = claudeAccount.cwd
        else { return nil }
        let root = (repositoryRoot as NSString).resolvingSymlinksInPath
        let folder = (cwd as NSString).resolvingSymlinksInPath
        guard folder == root || folder.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
        return claudeAccount.onNiruxAccount
    }

    /// Whether the event was fired by the column's own `claude` (or the real
    /// one under its launcher) for the session it confirmed (#23, #28): the
    /// sidebar may answer its PermissionRequest, and the session history
    /// may record it.
    func isFromOwnClaude(
        _ event: AgentHookEvent,
        foregroundProcess: ForegroundProcess?,
        snapshot: ProcessSnapshot
    ) -> Bool {
        guard let foregroundProcess, let sessionID = event.sessionID, !sessionID.isEmpty else { return false }
        let emitter = ClaudeSessionTracker.Emitter.placing(
            event.emitterProcess,
            foreground: foregroundProcess,
            shellPID: pty?.shellPID ?? 0,
            snapshot: snapshot
        )
        return claudeSessionTracker.approvableSessionID(emitter: emitter, foregroundProcess: foregroundProcess)
            == sessionID
    }

    /// The session the column's `claude` confirmed, if it still runs.
    func confirmedClaudeSessionID(foregroundProcess: ForegroundProcess?) -> String? {
        foregroundProcess.flatMap { claudeSessionTracker.confirmedSessionID(of: $0) }
    }

    /// The conversation a `claude` of this column confirmed through its own
    /// hooks, known even after it exited.
    func lastConfirmedClaudeSessionID(of process: ProcessInstance) -> String? {
        claudeSessionTracker.lastConfirmedSessionID(of: process)
    }

    func claudeHooksFired(by process: ProcessInstance) -> Bool {
        claudeSessionTracker.hasFiredHooks(process)
    }

    func persistedClaudeRestore(foregroundProcess: ForegroundProcess?) -> ClaudeSessionTracker.Restore? {
        claudeSessionTracker.restore(for: foregroundProcess)
    }

    /// Drop Codex/Claude/agy session bindings whose process was replaced, so
    /// the next save cannot hand a dead session to its successor.
    func invalidateAgentSessionsIfProcessChanged(
        foregroundProcess: ForegroundProcess?
    ) -> Bool {
        let codexChanged = codexSessionTracker.invalidateBinding(ifProcessChangedTo: foregroundProcess)
        let claudeChanged = claudeSessionTracker.invalidateBinding(ifProcessChangedTo: foregroundProcess)
        let agyChanged = agySessionTracker.invalidateBinding(ifProcessChangedTo: foregroundProcess)
        return codexChanged || claudeChanged || agyChanged
    }

    // MARK: - Shell exit / restart

    private func showShellExitedOverlay() {
        // Column closing also detaches the view — no overlay on a dead column.
        guard view.window != nil, let terminal = terminalView else { return }
        // The overlay would cover the find bar while its field kept the
        // keyboard, and Enter would navigate instead of restarting.
        closeFindBar()
        // The shell went with the agent's notice.
        agentExitOverlay?.isHidden = true
        if shellExitedOverlay == nil {
            let overlay = ShellExitedOverlay()
            overlay.onRestart = { [weak self] in self?.restartShell() }
            view.addSubview(overlay)
            shellExitedOverlay = overlay
        }
        shellExitedOverlay?.frame = terminal.frame
        shellExitedOverlay?.isHidden = false
    }

    /// Respawn the shell with the original spec after it exited. No-op while
    /// the shell is alive. The new shell starts at the last known grid size
    /// and the terminal surface keeps its scrollback.
    func restartShell() {
        guard pty?.hasExited == true, let spec = terminalSpec else { return }
        shellExitedOverlay?.isHidden = true
        let size = pty?.lastSize ?? (cols: 80, rows: 24)
        pty?.start(
            shell: PtySession.defaultShell,
            args: spec.shellArgs,
            cwd: spec.cwd,
            cols: size.cols > 0 ? size.cols : 80,
            rows: size.rows > 0 ? size.rows : 24,
            environment: spec.environment
        )
    }
}

// MARK: - Surface

extension ColumnState: TerminalSurfaceLifecycleDelegate {
    func terminalDidAttachSurface(_ surface: TerminalSurface) { surfaceChanged(attached: true) }
    func terminalDidDetachSurface() { surfaceChanged(attached: false) }
}

// MARK: - Clipboard confirmation

extension ColumnState: TerminalSurfaceClipboardConfirmationDelegate {
    /// Ghostty asks before a paste it deems unsafe (several lines into a
    /// program without bracketed paste) and, as configured, before a
    /// program reads or writes the clipboard (OSC 52); unanswered, it
    /// refuses. Pastes and writes go through, as with libghostty-spm 1.3.1;
    /// a program asking to read the clipboard gets an empty answer.
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        request.respond(allow: request.kind != .osc52Read)
    }
}

// MARK: - Link opening (cmd+click / hover)

extension ColumnState: TerminalSurfaceOpenURLDelegate {
    /// Ghostty auto-detects URLs (plain text and OSC 8 hyperlinks) and
    /// forwards cmd+click here. Web links open inside Nirux as a browser
    /// column; file: links (Claude Code emits OSC 8 file:// links for
    /// paths) open inside Nirux as an editor column; anything else
    /// (mailto:, custom schemes) goes to the system handler. Routing is
    /// deferred one run-loop turn: mutating columns/focus synchronously from
    /// Ghostty's mouse callback can invalidate its event state and crash.
    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        guard let target = TerminalLinkTarget.parse(url) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.openTerminalLink(target)
        }
    }

    private func openTerminalLink(_ target: TerminalLinkTarget) {
        switch target {
        case .web(let url):
            onOpenURL?(url.absoluteString)
        case .file(let url):
            guard let file = FileLink.parse(url) else { return }
            // Resolve symlinks so the editor's size/content checks see the
            // real target; hand non-text targets (directories, FIFOs,
            // images…) to the system like before this route existed.
            let resolved = URL(fileURLWithPath: file.path).resolvingSymlinksInPath().path
            if FileLink.opensInEditor(path: resolved) {
                onOpenFile?(resolved, file.line)
            } else {
                NSWorkspace.shared.open(url)
            }
        case .external(let url):
            NSWorkspace.shared.open(url)
        }
    }
}

extension ColumnState: TerminalSurfaceHoverLinkDelegate {
    func terminalDidUpdateHoverLink(_ url: String?) {
        (url == nil ? NSCursor.arrow : .pointingHand).set()
    }
}

enum ColumnWidth: CaseIterable {
    case full, twoThirds, half, third, quarter

    var fraction: CGFloat {
        switch self {
        case .full: 1.0
        case .twoThirds: 2.0 / 3.0
        case .half: 1.0 / 2.0
        case .third: 1.0 / 3.0
        case .quarter: 1.0 / 4.0
        }
    }
}
