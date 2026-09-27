import AppKit
import GhosttyTerminal

// WindowDragView and DropTargetView now live in Views/ColumnInternalViews.swift
// — NSView subclasses don't belong in the model layer.

/// A single column in a workspace — terminal or webview
@MainActor
final class ColumnState {
    /// Stable identity (unlike ObjectIdentifier, never reused after close).
    let id = UUID()
    let view: NSView
    var terminalView: TerminalView?
    var webViewColumn: WebViewColumn?
    var editorColumn: EditorColumn?
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

    private var codexSessionTracker = CodexSessionTracker()
    private var claudeSessionTracker = ClaudeSessionTracker()
    /// State this agent column was restored from — saved as-is while its
    /// launch command hasn't started the agent yet (see
    /// `NiruxShellView.isLaunchingRestoredAgent`), then dropped.
    var restoredColumn: PersistedColumn?

    /// Terminal title from OSC 0/2 (agent context, vim filename, etc.)
    var terminalTitle: String? {
        didSet { titleLabel?.stringValue = terminalTitle ?? "" }
    }

    // MARK: - Integrated title bar (pushes terminal down)
    static let boringTitles: Set<String> = ["zsh", "bash", "fish", "sh", "-zsh", "-bash"]
    private(set) var titleBar: NSView?
    private var titleLabel: NSTextField?
    private var titleBorder: NSView?

    /// Height reserved for the title bar (always shown for terminal columns)
    var titleBarHeight: CGFloat {
        pty != nil ? 32 : 0
    }

    /// Spec needed to respawn the shell after it exits.
    private var terminalSpec: (cwd: String, shellArgs: [String], environment: [String: String])?
    private var shellExitedOverlay: ShellExitedOverlay?

    /// ⌘F find bar and the search it drives, created on first use
    /// (ColumnState+TerminalFind.swift).
    var findBar: TerminalFindBar?
    var terminalSearch: TerminalSearchSession?

    /// Claude session transcript this column follows, its latest usage and
    /// the title-bar label showing it (ColumnState+AgentUsage.swift).
    var claudeTranscript: ClaudeTranscriptFollow?
    var agentUsage: ClaudeSessionUsage?
    var usageLabel: NSTextField?

    private func setupTitleBar() {
        let bar = WindowDragView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1).cgColor

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor(red: 0.55, green: 0.70, blue: 1.0, alpha: 0.95)
        label.lineBreakMode = .byTruncatingTail
        label.isBezeled = false
        label.drawsBackground = false
        bar.addSubview(label)

        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        bar.addSubview(border)

        bar.isHidden = true
        view.addSubview(bar)
        titleBar = bar
        titleLabel = label
        titleBorder = border
    }

    /// Update the title bar label text: [title or process] · [path]
    /// The snapshot is only evaluated for shell titles, which fall back to
    /// the foreground process name.
    func updateTitleBarLabel(snapshot: @autoclosure () -> ProcessSnapshot) {
        guard let label = titleLabel else { return }
        let name: String
        if let termTitle = terminalTitle, !termTitle.isEmpty, !Self.boringTitles.contains(termTitle) {
            name = termTitle
        } else {
            name = pty?.foregroundProcessName(snapshot: snapshot()) ?? "shell"
        }
        let path = pty?.childCwd?.abbreviatedPath(maxComponents: 2) ?? ""
        label.stringValue = path.isEmpty ? name : "\(name) · \(path)"
    }

    /// Position title bar and optionally resize terminal to fit. Called from layoutAndScroll.
    func layoutWithTitleBar(width: CGFloat, height: CGFloat, resizeTerminal: Bool = true) {
        let barHeight = titleBarHeight
        titleBar?.isHidden = (barHeight == 0)

        if barHeight > 0, let bar = titleBar {
            // Title bar at top of column (NSView: y=0 is bottom)
            bar.frame = NSRect(x: 0, y: height - barHeight, width: width, height: barHeight)
            layoutTitleBarContents()
            titleBorder?.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        }

        // Terminal fills the remaining space below the title bar
        if resizeTerminal, let terminal = terminalView {
            terminal.frame = NSRect(x: 0, y: 0, width: width, height: height - barHeight)
            shellExitedOverlay?.frame = terminal.frame
        }
        layoutFindBar()
    }

    /// Title label on the left; the dev-server chip, when shown, on the
    /// right. The chip gets priority up to half the bar, then goes compact.
    /// The agent usage label sits before the chip while the title keeps
    /// room to be read.
    func layoutTitleBarContents() {
        guard let bar = titleBar else { return }
        let width = bar.bounds.width
        var trailingX = width - 12
        if let chip = localServerChip, chip.url != nil {
            let chipWidth = chip.width(fitting: max(0, width / 2 - 12))
            chip.isHidden = chipWidth == 0
            if chipWidth > 0 {
                let chipX = width - chipWidth - 8
                chip.frame = NSRect(
                    x: chipX,
                    y: (bar.bounds.height - LocalServerChipView.height) / 2,
                    width: chipWidth,
                    height: LocalServerChipView.height
                )
                trailingX = chipX - 8
            }
        }
        if let usageLabel {
            let usageWidth = ceil(usageLabel.intrinsicContentSize.width)
            let fits = trailingX - usageWidth - 8 - 12 >= Self.minTitleWidthBesideUsage
            usageLabel.isHidden = agentUsage?.titleBarText == nil || !fits
            if !usageLabel.isHidden {
                usageLabel.frame = NSRect(x: trailingX - usageWidth, y: 8, width: usageWidth, height: 16)
                trailingX -= usageWidth + 8
            }
        }
        titleLabel?.frame = NSRect(x: 12, y: 8, width: max(0, trailingX - 12), height: 16)
    }

    private static let minTitleWidthBesideUsage: CGFloat = 80

    /// Show (or hide, with nil) the "open this dev server" chip.
    func setLocalServerChip(_ url: LocalServerURL?) {
        if localServerChip == nil {
            guard url != nil, let bar = titleBar else { return }
            let chip = LocalServerChipView(frame: .zero)
            chip.onOpen = { [weak self] url in self?.onLocalServerChipOpen?(url) }
            chip.onDismiss = { [weak self] url in self?.onLocalServerChipDismiss?(url) }
            bar.addSubview(chip)
            localServerChip = chip
        }
        localServerChip?.configure(url: url)
        layoutTitleBarContents()
    }

    /// True if this column is a WebView (not a terminal)
    var isWebView: Bool { webViewColumn != nil }

    /// True if this column is an Editor (Monaco-backed)
    var isEditor: Bool { editorColumn != nil }

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
        // The shell path is single-quoted — an unquoted path with spaces or
        // metacharacters would be word-split by the -c string.
        let shell = PtySession.defaultShell
        let quotedShell = "'" + shell.replacingOccurrences(of: "'", with: "'\\''") + "'"
        self.init(
            cwd: cwd,
            shellArgs: ["-i", "-l", "-c", "\(command); exec \(quotedShell) -i -l"],
            environment: environment
        )
    }

    /// Shared terminal init — pass extra shell args for command mode.
    private init(cwd: String, shellArgs: [String], environment: [String: String]) {
        terminalSpec = (cwd, shellArgs, environment)
        agentUUID = environment["NIRUX_AGENT_UUID"]
        let dropView = DropTargetView()
        dropView.wantsLayer = true
        view = dropView

        let ptySession = PtySession()
        pty = ptySession

        // File drop → paste escaped path(s) into PTY
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
        view.addSubview(terminal)
        terminalView = terminal

        // Title bar (above terminal, not overlapping)
        setupTitleBar()

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

        ptySession.onLocalServerURL = { [weak self] url in
            self?.onLocalServerURLDetected?(url)
        }

        // Shell exit → show the restart overlay over the (still visible)
        // terminal. Scrollback survives a restart.
        ptySession.onProcessExit = { [weak self] in
            self?.showShellExitedOverlay()
        }

        // Delay shell start so the terminal surface is created first
        let args = shellArgs
        let env = environment
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            ptySession.start(
                shell: PtySession.defaultShell,
                args: args,
                cwd: cwd,
                cols: 80,
                rows: 24,
                environment: env
            )
        }
    }

    /// WebView column
    init(url: String) {
        agentUUID = nil
        view = NSView()
        view.wantsLayer = true

        let webView = WebViewColumn(url: url)
        webView.autoresizingMask = [.width, .height]
        view.addSubview(webView)
        webViewColumn = webView
    }

    /// Editor column (Monaco-backed). Scoped to a workspace cwd.
    init(editorWorkspaceCwd: String) {
        agentUUID = nil
        view = NSView()
        view.wantsLayer = true

        let editor = EditorColumn(workspaceCwd: editorWorkspaceCwd)
        editor.autoresizingMask = [.width, .height]
        view.addSubview(editor)
        editorColumn = editor
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
        emitterProcess: ProcessInstance?,
        snapshot: ProcessSnapshot
    ) -> Bool {
        guard let pty else { return false }
        let foregroundProcess = pty.foregroundProcess(snapshot: snapshot)
        let emitterBelongsToForegroundJob = emitterProcess.map {
            pty.isProcessInForegroundJob($0, snapshot: snapshot)
        } ?? false
        return codexSessionTracker.capture(
            sessionID: sessionID,
            emitterBelongsToForegroundJob: emitterBelongsToForegroundJob,
            foregroundProcess: foregroundProcess
        )
    }

    func persistedCodexSessionID(foregroundProcess: ForegroundProcess?) -> String? {
        codexSessionTracker.sessionID(for: foregroundProcess)
    }

    func prepareClaudeResume(sessionID: String) {
        claudeSessionTracker.prepareResume(sessionID: sessionID)
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
           let transcriptPath = event.transcriptPath,
           let sessionID = event.sessionID,
           let foregroundProcess,
           claudeSessionTracker.boundSessionID(for: foregroundProcess.instance) == sessionID {
            followClaudeTranscript(at: transcriptPath, sessionID: sessionID, process: foregroundProcess.instance)
        }
        return admission
    }

    func persistedClaudeRestore(foregroundProcess: ForegroundProcess?) -> ClaudeSessionTracker.Restore? {
        claudeSessionTracker.restore(for: foregroundProcess)
    }

    /// Drop Codex/Claude session bindings whose process was replaced, so
    /// the next save cannot hand a dead session to its successor.
    func invalidateAgentSessionsIfProcessChanged(
        foregroundProcess: ForegroundProcess?
    ) -> Bool {
        let codexChanged = codexSessionTracker.invalidateBinding(ifProcessChangedTo: foregroundProcess)
        let claudeChanged = claudeSessionTracker.invalidateBinding(ifProcessChangedTo: foregroundProcess)
        return codexChanged || claudeChanged
    }

    // MARK: - Shell exit / restart

    private func showShellExitedOverlay() {
        // Column closing also detaches the view — no overlay on a dead column.
        guard view.window != nil, let terminal = terminalView else { return }
        // The overlay would cover the find bar while its field kept the
        // keyboard, and Enter would navigate instead of restarting.
        closeFindBar()
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
