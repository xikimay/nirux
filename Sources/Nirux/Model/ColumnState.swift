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
    var widthPreset: ColumnWidth = .half
    private(set) var pty: PtySession?
    var onCwdChanged: ((String) -> Void)?
    var onTitleChanged: (() -> Void)?
    var onOsc9Received: (() -> Void)?

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

    convenience init(cwd: String) {
        self.init(cwd: cwd, shellArgs: ["-l"])
    }

    /// Init for a terminal that runs a command immediately (e.g. claude --continue).
    /// When the command exits, drops into an interactive shell.
    convenience init(cwd: String, command: String) {
        // Match a normal terminal launch: interactive + login shell. This
        // ensures PATH/bootstrap logic from .zprofile/.zshrc is available
        // when Nirux restores command-backed columns after a Finder relaunch.
        self.init(cwd: cwd, shellArgs: ["-i", "-l", "-c", "\(command); exec /bin/zsh -i -l"])
    }

    /// Shared terminal init — pass extra shell args for command mode.
    private init(cwd: String, shellArgs: [String]) {
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

        // Forward OSC 9 (agent turn completed)
        ptySession.onOsc9Received = { [weak self] in
            self?.onOsc9Received?()
        }

        // Delay shell start so the terminal surface is created first
        let args = shellArgs
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            ptySession.start(shell: "/bin/zsh", args: args, cwd: cwd, cols: 80, rows: 24)
        }
    }

    /// WebView column
    init(url: String) {
        view = NSView()
        view.wantsLayer = true

        let webView = WebViewColumn(url: url)
        webView.autoresizingMask = [.width, .height]
        view.addSubview(webView)
        webViewColumn = webView
    }

    /// Editor column (Monaco-backed). Scoped to a workspace cwd.
    init(editorWorkspaceCwd: String) {
        view = NSView()
        view.wantsLayer = true

        let editor = EditorColumn(workspaceCwd: editorWorkspaceCwd)
        editor.autoresizingMask = [.width, .height]
        view.addSubview(editor)
        editorColumn = editor
    }

    func cycleWidth() {
        widthPreset = widthPreset.next
    }
}

enum ColumnWidth: CaseIterable, Equatable {
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

    var rawValue: CGFloat { fraction }

    init?(rawValue: CGFloat) {
        switch rawValue {
        case 1.0: self = .full
        case let value where abs(value - 2.0/3.0) < 0.01: self = .twoThirds
        case 0.5: self = .half
        case let value where abs(value - 1.0/3.0) < 0.01: self = .third
        case 0.25: self = .quarter
        default: return nil
        }
    }

    var next: ColumnWidth {
        let all = ColumnWidth.allCases
        let idx = all.firstIndex(of: self)!
        return all[(idx + 1) % all.count]
    }
}
