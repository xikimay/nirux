import AppKit
import GhosttyTerminal

// WindowDragView and DropTargetView now live in Views/ColumnInternalViews.swift
// — NSView subclasses don't belong in the model layer.

/// A single column in a workspace — terminal or webview
@MainActor
final class ColumnState {
    let view: NSView
    var terminalView: TerminalView?
    var webViewColumn: WebViewColumn?
    var editorColumn: EditorColumn?
    /// Column width as a fraction of the columns viewport (0.15…2.0).
    /// Freeform (drag the resize handles); the ColumnWidth presets are just
    /// named stops the width cycler snaps to.
    var widthFraction: CGFloat = ColumnWidth.half.fraction
    private(set) var pty: PtySession?
    var onCwdChanged: ((String) -> Void)?
    var onTitleChanged: (() -> Void)?
    /// Fires when the agent asks for attention (hook-routed turn end /
    /// permission prompt while the user isn't watching this column).
    var onAgentAttention: (() -> Void)?

    /// Fires when the user cmd-clicks an http(s) link in the terminal —
    /// the workspace opens it in a browser column.
    var onOpenURL: ((String) -> Void)?

    /// Fires when the user cmd-clicks a file: link in the terminal — the
    /// workspace routes it into an editor column at the optional line.
    var onOpenFile: ((String, Int?) -> Void)?

    /// Stable identity injected into the terminal environment as
    /// NIRUX_AGENT_UUID — Claude/Codex hook events carry it back so
    /// AgentHookCenter can route them to THIS column. Persisted across
    /// restarts; survives shell restarts (same terminal spec).
    let agentUUID: String?

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
    func updateTitleBarLabel(snapshot: ProcessSnapshot) {
        guard let label = titleLabel else { return }
        let name: String
        if let termTitle = terminalTitle, !termTitle.isEmpty, !Self.boringTitles.contains(termTitle) {
            name = termTitle
        } else {
            name = pty?.foregroundProcessName(snapshot: snapshot) ?? "shell"
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
            titleLabel?.frame = NSRect(x: 12, y: 8, width: width - 24, height: 16)
            titleBorder?.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        }

        // Terminal fills the remaining space below the title bar
        if resizeTerminal, let terminal = terminalView {
            terminal.frame = NSRect(x: 0, y: 0, width: width, height: height - barHeight)
            shellExitedOverlay?.frame = terminal.frame
        }
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

    /// Init for a terminal that runs a command immediately (e.g. claude --continue).
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
        terminal.controller = TerminalController {
            $0.withCustom("term", "xterm-256color")
            $0.withBackground("#1a1b26")
            $0.withForeground("#c0caf5")
        }
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
            self?.onAgentAttention?()
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
    func notifyAgentAttention() {
        onAgentAttention?()
    }

    // MARK: - Shell exit / restart

    private func showShellExitedOverlay() {
        // Column closing also detaches the view — no overlay on a dead column.
        guard view.window != nil, let terminal = terminalView else { return }
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
    /// (mailto:, custom schemes) goes to the system handler.
    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased() else { return }
        switch scheme {
        case "http", "https":
            onOpenURL?(url)
        case "file":
            guard let target = FileLink.parse(parsed) else { return }
            // Resolve symlinks so the editor's size/content checks see the
            // real target; hand non-text targets (directories, FIFOs,
            // images…) to the system like before this route existed.
            let resolved = URL(fileURLWithPath: target.path).resolvingSymlinksInPath().path
            if FileLink.opensInEditor(path: resolved) {
                onOpenFile?(resolved, target.line)
            } else {
                NSWorkspace.shared.open(parsed)
            }
        default:
            NSWorkspace.shared.open(parsed)
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
