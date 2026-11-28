import AppKit
import WebKit

/// A Monaco-backed editor column. WKWebView hosts the Monaco editor; Swift
/// reads/writes files and pushes content over the JS bridge. Each open file
/// has its own Monaco model on the JS side, and the tab bar under the
/// column header lets the user switch between them.
@MainActor
final class EditorColumn: NSView, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
    let workspaceCwd: String

    /// Tabs in display order. Real files map 1:1 to Monaco models; virtual
    /// diff tabs render directly into Pierre without a backing text model.
    private var tabPaths: [String] = []
    var openPaths: [String] {
        tabPaths.filter { !Self.isDiffGroupPath($0) }
    }
    private(set) var activePath: String?

    /// Per-tab dirty state (mirror of what JS reports).
    private var dirtyByPath: [String: Bool] = [:]
    /// Per-tab version of the file on disk as last read or written: what a
    /// save may replace.
    private var diskVersionByPath: [String: DiskVersion] = [:]
    private enum DiskVersion: Equatable {
        case file(modified: Date)
        case missing
    }
    /// Per-tab version of the text Swift last gave the page (open, reload):
    /// a save carries the one its text grew from, and one from before a
    /// reload still on its way is refused.
    private var textVersionByPath: [String: Int] = [:]
    private var nextTextVersion = 0
    /// Per-tab encoding detected at open — saves round-trip the same
    /// encoding instead of silently transcoding everything to UTF-8.
    private var encodingByPath: [String: String.Encoding] = [:]
    /// Tabs whose file changed on disk under unsaved edits: nothing is
    /// saved until the user keeps theirs or takes the disk's.
    private var diskModifiedWhileDirty: Set<String> = []
    /// Path currently shown in diff mode, or nil when the
    /// regular editor is active. Resets on tab switch — diff is per-tab.
    private(set) var diffActivePath: String? {
        didSet { if diffActivePath != oldValue { diffViewer = nil } }
    }
    /// The viewer the page says the active diff is in ("pierre", "monaco"):
    /// its own fallback to Monaco included.
    private(set) var diffViewer: String?
    /// What the diff on screen compares with.
    private(set) var diffActiveBase: DiffBase?
    enum DiffBase: Equatable {
        case git(EditorDiffMode)
        /// The file as it is on disk: a conflict's Compare.
        case disk
    }
    private var diffModeByPath: [String: EditorDiffMode] = [:]
    /// Markdown tabs shown rendered. One opened in the front editor starts
    /// so, one opened in the row as source; the header's toggle changes it,
    /// and a diff, ⌘F or an open at a line ends it. It stays with the tab as
    /// the column moves.
    private(set) var renderedPaths: Set<String> = []
    /// Drafts among the tabs (`isDraft`), as each opened.
    private(set) var draftPaths: Set<String> = []
    /// The lines an open showed in a tab (nirux-show-code's range), where
    /// the page highlights them (an edit above moves them), until the next
    /// open in it, an edit in them or its rendering. `id`: what the page
    /// answers with.
    struct ShownRange: Equatable {
        let lines: ClosedRange<Int>
        let id: Int
    }
    private(set) var shownRanges: [String: ShownRange] = [:]
    private var nextShownRangeID = 0
    private(set) var diffGroupTabs: [String: DiffGroupTab] = [:]
    /// The title of the active tab when it shows several files' diff.
    var activeDiffGroupTitle: String? { activePath.flatMap { diffGroupTabs[$0]?.title } }
    private var selectedDiffMode: EditorDiffMode = .head
    private var diffLoadGeneration = 0

    /// Current path / dirty exposed for the persistence layer and sidebar.
    var currentPath: String? {
        guard let activePath, !Self.isDiffGroupPath(activePath) else { return nil }
        return activePath
    }
    var isDirty: Bool {
        guard let activePath, !Self.isDiffGroupPath(activePath) else { return false }
        return (dirtyByPath[activePath] ?? false) || diskModifiedWhileDirty.contains(activePath)
    }
    /// Every open file with unsaved changes, in any tab.
    var unsavedPaths: [String] {
        openPaths.filter { (dirtyByPath[$0] ?? false) || diskModifiedWhileDirty.contains($0) }
    }

    var onPathChanged: (() -> Void)?
    var onDirtyChanged: (() -> Void)?
    var onFilePickerRequest: ((EditorColumn) -> Void)?
    /// The user's own editors installed, for ⋯'s Open in (the shell's).
    var installedEditors: () -> [ExternalEditor] = { [] }
    /// Open in one of them: the file, at the caret's line and column (none
    /// read rendered).
    var onOpenElsewhere: ((ExternalEditor, String, Int?, Int?) -> Void)?
    var onRevealInFinder: ((String) -> Void)?
    /// Asked before a tab with unsaved edits closes. Unset, it stays.
    var askAboutUnsavedEdits: ([String]) -> UnsavedEditsChoice = { _ in .cancel }
    /// How long a Save All waits for the page to post its saves.
    var saveTimeout: TimeInterval = 10

    /// A Save All waiting for the page to post its saves.
    private struct SaveRequest {
        var allWritten: Bool
        let completion: (Bool) -> Void
    }
    private var saveRequests: [Int: SaveRequest] = [:]
    private var nextSaveRequestID = 0

    /// A Monaco selection as reported over the bridge. Lines are 1-based.
    struct Selection {
        let path: String
        let text: String
        let startLine: Int
        let endLine: Int
    }
    /// One-shot completions awaiting a "selection" reply, keyed by request
    /// ID so a dropped bridge message can't pair a reply with the wrong
    /// (earlier) request.
    private var selectionRequests: [Int: (Selection?) -> Void] = [:]
    private var nextSelectionRequestID = 0
    /// Monaco resolved Cmd+Opt+Enter outside the find widget — the shell
    /// runs the send-selection flow.
    var onSendSelectionShortcut: (() -> Void)?
    /// Esc that nothing in the page took (no widget, selection or find).
    var onEscapeKey: (() -> Void)?
    /// It is its workspace's front column (`ColumnState.isFront`).
    var isFront = false
    /// A web link clicked in a rendered tab.
    var onOpenLink: ((URL) -> Void)?
    /// Where Copy Draft puts the text.
    var pasteboard = NSPasteboard.general
    private var copiedFlashGeneration = 0

    /// The edge of Monaco's text a Cmd+Arrow moves the caret to.
    enum TextEdge: String, CaseIterable {
        case left, right, up, down
    }
    /// Cmd+Arrow found Monaco's caret already at that edge, with somewhere
    /// to go (see `textEdgeArrows` in bridge.js): the shell makes the move
    /// the key makes outside text.
    var onTextEdgeKey: ((TextEdge) -> Void)?

    /// Whether Monaco's web view has the window's keyboard.
    var webViewHasKeyboard: Bool {
        window?.firstResponder === webView
    }

    /// The edges whose key would find somewhere to go: a column beside, a
    /// workspace above or below.
    var textEdgeDestinations: (() -> Set<TextEdge>)?

    /// Tells the page where each edge key can go, just before the app hands
    /// it a plain Cmd+Arrow (the script runs first). With nowhere to go,
    /// Monaco moves the caret as it handles the key.
    func sendTextEdgeDestinations() {
        guard let destinations = textEdgeDestinations?() else { return }
        var payload: [String: Any] = ["type": "textEdgeDestinations"]
        for edge in TextEdge.allCases {
            payload[edge.rawValue] = destinations.contains(edge)
        }
        sendBridge(payload)
    }

    /// What Cmd+Arrow does in Monaco's text, for an edge key the shell found
    /// nowhere to go with after all.
    func moveCaretToTextEdge(_ edge: TextEdge) {
        sendBridge(["type": "moveCaretToTextEdge", "edge": edge.rawValue])
    }

    private let webView: WKWebView
    /// The active file and its directory, the diff toggle and the search.
    let header = ColumnHeaderView()
    let diffButton = ColumnHeaderButton(symbol: Theme.Symbol.diff, toolTip: "Toggle Editor Diff")
    let searchButton = ColumnHeaderButton(symbol: Theme.Symbol.search, toolTip: "Search Workspace")
    /// On a Markdown tab: its source or its rendered text.
    let renderButton = ColumnHeaderButton(symbol: Theme.Symbol.renderedText, toolTip: "Show Rendered")
    /// On a draft.
    let copyDraftButton = NiruxButton(title: EditorColumn.copyDraftTitle, kind: .primary, size: .small)
    static let copyDraftTitle = "Copy Draft"
    private let tabBar: EditorTabBar
    private let fileTree: EditorFileTree
    private let treeDivider: NSView
    private let conflictBanner = EditorConflictBanner()
    /// Over the "Full Branch Diff" tab.
    let branchReviewBanner = EditorBranchReviewBanner()
    /// The banner's button: review the branch in a Branch Review column.
    var onOpenBranchReview: (() -> Void)?
    private let loadFailureOverlay = EditorLoadFailureOverlay()
    private var monacoReady = false
    /// Fires once if `monacoReady` doesn't arrive shortly after loading —
    /// without it a failed Monaco load is a silent blank surface.
    private var monacoLoadWatchdog: Timer?
    private static let loadWatchdogInterval: TimeInterval = 8
    /// Operations queued before Monaco signaled `monacoReady`.
    private var pendingOps: [() -> Void] = []

    /// Width allocated to the file tree when visible. Hidden entirely on
    /// narrow columns (`bounds.width < treeHideThreshold`).
    private static let treeWidth: CGFloat = 200
    private static let treeHideThreshold: CGFloat = 500
    private nonisolated static let maxDiffCollectionFileBytes: UInt64 = 400_000
    private nonisolated static let diffGroupPathPrefix = "nirux://diff-group/"

    private var fileWatchTimer: Timer?
    private static let watchInterval: TimeInterval = 1.5
    /// Pending debounced git-status refresh (see `scheduleGitReload`).
    private var gitReloadWorkItem: DispatchWorkItem?
    /// Files above this size ask for confirmation before opening in Monaco.
    private static let largeFileWarningBytes = EditorFileLimits.maxEditableBytes

    init(workspaceCwd: String) {
        self.workspaceCwd = workspaceCwd

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView = WKWebView(frame: .zero, configuration: config)

        tabBar = EditorTabBar()
        fileTree = EditorFileTree(workspaceCwd: workspaceCwd)
        treeDivider = NSView()

        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.base.cgColor

        setupHeader()
        setupTree()
        setupTabBar()
        setupWebView(config: config)
        loadEditor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Cleanup hook. Fires when the column is detached from its window (i.e.
    /// when the user closes the column). Doing it here instead of `deinit`
    /// keeps everything inside main-actor isolation, which Swift 6 enforces
    /// strictly for non-Sendable stored properties like `Timer?`.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            fileWatchTimer?.invalidate()
            fileWatchTimer = nil
            monacoLoadWatchdog?.invalidate()
            monacoLoadWatchdog = nil
            drainSelectionRequests()
            drainSaveRequests()
            webView.configuration.userContentController
                .removeScriptMessageHandler(forName: "nirux")
        }
    }

    // MARK: - Setup

    private func setupTree() {
        addSubview(fileTree)
        fileTree.onFilePicked = { [weak self] path in
            self?.open(path: path)
        }
        fileTree.onDiffPicked = { [weak self] path, mode in
            self?.showDiff(path: path, mode: mode)
        }
        fileTree.onDiffCollectionPicked = { [weak self] title, paths, mode in
            self?.showDiffCollection(title: title, paths: paths, mode: mode)
        }

        treeDivider.wantsLayer = true
        treeDivider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        addSubview(treeDivider)
    }

    private func setupTabBar() {
        tabBar.onSelect = { [weak self] path in self?.switchTo(path: path) }
        tabBar.onClose = { [weak self] path in self?.closeAskingFirst(path: path) }
        addSubview(tabBar)
        refreshTabBar()
    }

    private func setupWebView(config: WKWebViewConfiguration) {
        config.userContentController.add(self, name: "nirux")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.bouncesOnlyVertically()
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = Theme.Color.surface
        addSubview(webView)

        // Conflict banner floats over the editor surface — added last so it
        // stacks above the webview.
        conflictBanner.isHidden = true
        conflictBanner.onCompare = { [weak self] in self?.toggleDiskCompare() }
        conflictBanner.onTakeDisk = { [weak self] in self?.takeDiskVersion() }
        conflictBanner.onKeepMine = { [weak self] in self?.keepMine() }
        addSubview(conflictBanner)

        branchReviewBanner.isHidden = true
        branchReviewBanner.onOpen = { [weak self] in self?.onOpenBranchReview?() }
        addSubview(branchReviewBanner)

        loadFailureOverlay.isHidden = true
        loadFailureOverlay.onRetry = { [weak self] in self?.retryEditorLoad() }
        addSubview(loadFailureOverlay)
    }

    private func loadEditor() {
        guard let indexURL = Self.findEditorIndex() else {
            showLoadFailure(message: "Editor assets are missing from this build.", showRetry: true)
            return
        }
        loadFailureOverlay.isHidden = true
        let assetsDir = indexURL.deletingLastPathComponent()
        webView.loadFileURL(indexURL, allowingReadAccessTo: assetsDir)
        startLoadWatchdog()
    }

    private func startLoadWatchdog() {
        monacoLoadWatchdog?.invalidate()
        monacoLoadWatchdog = Timer.scheduledTimer(
            withTimeInterval: Self.loadWatchdogInterval, repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.monacoReady else { return }
                self.showLoadFailure(message: "The editor took too long to load.", showRetry: true)
            }
        }
    }

    private func retryEditorLoad() {
        loadFailureOverlay.isHidden = true
        loadEditor()
    }

    private func showLoadFailure(message: String, showRetry: Bool) {
        loadFailureOverlay.configure(message: message, showRetry: showRetry)
        loadFailureOverlay.isHidden = false
        needsLayout = true
    }

    /// Locates `EditorAssets/index.html` in release (`bundle.sh` copies the
    /// assets straight into the .app's `Contents/Resources`) and in dev (SPM
    /// resource bundle, where `Bundle.module` works). Bundle.main is checked
    /// first because Bundle.module is a `static let` that `fatalError`s when
    /// the SPM bundle isn't on disk — and it isn't in the packaged .app.
    private static func findEditorIndex() -> URL? {
        if let resources = Bundle.main.resourceURL {
            let candidate = resources.appendingPathComponent("EditorAssets/index.html")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return Bundle.module.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "EditorAssets"
        )
    }

    // MARK: - Layout

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutViews()
    }

    override func layout() {
        super.layout()
        layoutViews()
    }

    private func layoutViews() {
        let headerH = ColumnHeaderView.height
        let tabH = EditorTabBar.tabHeight
        let showTree = bounds.width >= Self.treeHideThreshold
        let treeW: CGFloat = showTree ? Self.treeWidth : 0
        let dividerW: CGFloat = showTree ? 1 : 0
        // Below the header, which spans the tree too.
        let contentH = max(0, bounds.height - headerH)
        header.frame = NSRect(x: 0, y: contentH, width: bounds.width, height: headerH)

        fileTree.isHidden = !showTree
        treeDivider.isHidden = !showTree

        if showTree {
            fileTree.frame = NSRect(x: 0, y: 0, width: treeW, height: contentH)
            treeDivider.frame = NSRect(x: treeW, y: 0, width: dividerW, height: contentH)
        }

        let editorX = treeW + dividerW
        let editorW = bounds.width - editorX
        tabBar.frame = NSRect(x: editorX, y: contentH - tabH, width: editorW, height: tabH)
        // Above the diffs, not over them.
        var webH = max(0, contentH - tabH)
        if !branchReviewBanner.isHidden {
            let bannerH = EditorBranchReviewBanner.height
            branchReviewBanner.frame = NSRect(x: editorX + 8, y: webH - bannerH - 8, width: max(0, editorW - 16), height: bannerH)
            webH = max(0, webH - bannerH - 16)
        }
        webView.frame = NSRect(x: editorX, y: 0, width: editorW, height: webH)
        loadFailureOverlay.frame = webView.frame
        if !conflictBanner.isHidden {
            let bannerH = EditorConflictBanner.height
            conflictBanner.frame = NSRect(
                x: editorX + 8,
                y: contentH - tabH - bannerH - 8,
                width: editorW - 16,
                height: bannerH
            )
        }
    }

    // MARK: - Public API

    /// Open a file. If already open, switches to its tab; otherwise creates
    /// a new tab and makes it active. Path may be absolute or relative to
    /// the workspace cwd. When `line` is non-nil the editor jumps to and
    /// centers that line after the model is ready (used by workspace search
    /// to land on the matched line). `interactive` controls failure UX:
    /// explicit user opens get alerts and a large-file confirmation;
    /// session restore passes false so a problematic file can't pop a modal
    /// at every launch.
    func open(
        path: String, line: Int? = nil, endLine: Int? = nil,
        takeFocus: Bool = true, interactive: Bool = true
    ) {
        let absolute = absolutePath(for: path)
        let range = newShownRange(line: line, endLine: endLine)

        // Already open → just switch.
        if tabPaths.contains(absolute) {
            let showedRange = shownRanges[absolute] != nil
            shownRanges[absolute] = range
            // A line shows in the source, not under a git diff (Pierre's hides it).
            if line != nil, renderedPaths.contains(absolute) { setRendered(false, of: absolute) }
            if line != nil, diffModeByPath.removeValue(forKey: absolute) != nil {
                if diffActivePath == absolute { exitDiff(focus: takeFocus) } else if activePath == absolute { diffLoadGeneration += 1 }
            }
            switchTo(path: absolute, takeFocus: takeFocus)
            if let line {
                var payload: [String: Any] = ["type": "goToLine", "path": absolute, "line": line]
                Self.applyNavFlags(&payload, endLine: endLine, range: range, takeFocus: takeFocus)
                sendBridge(payload)
            } else if showedRange {
                sendBridge(["type": "clearShownRange", "path": absolute])
            }
            refreshHeader()
            return
        }

        // Very large files make Monaco sluggish — confirm before loading.
        if interactive,
           let size = Self.fileByteCount(path: absolute),
           size > Self.largeFileWarningBytes {
            let alert = NSAlert()
            alert.messageText = "Open large file?"
            let mb = String(format: "%.1f", Double(size) / 1_000_000)
            alert.informativeText = "\((absolute as NSString).lastPathComponent) is \(mb) MB. Editing may be slow."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        guard let file = readFileContent(at: absolute, interactive: interactive) else { return }

        shownRanges[absolute] = range
        openBuffer(
            path: absolute, content: file.content, version: file.version,
            line: line, endLine: endLine, takeFocus: takeFocus, encoding: file.encoding
        )
    }

    private func newShownRange(line: Int?, endLine: Int?) -> ShownRange? {
        guard let line, let endLine, endLine >= line else { return nil }
        nextShownRangeID += 1
        return ShownRange(lines: line...endLine, id: nextShownRangeID)
    }

    /// Read result with encoding fallbacks. `.binary` means NUL bytes were
    /// found (after ruling out UTF-16 BOM); `.unreadable` covers I/O errors
    /// and undecodable content. The detected encoding is carried so saves
    /// round-trip the file in its original encoding.
    private enum FileReadResult {
        case ok(String, String.Encoding)
        case binary
        case unreadable
    }

    private nonisolated static func readTextFile(at path: String) -> FileReadResult {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return .unreadable }
        // UTF-16 BOM first — those files are full of NUL bytes and would
        // trip the binary check below.
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let utf16 = String(data: data, encoding: .utf16) {
            return .ok(utf16, .utf16)
        }
        // Full-file NUL scan — an 8KB-prefix scan let binaries with an ASCII
        // header through, and the Latin-1 fallback then corrupted them on
        // save (mojibake byte expansion).
        if data.contains(0) { return .binary }
        if let utf8 = String(data: data, encoding: .utf8) { return .ok(utf8, .utf8) }
        // ISO Latin-1 maps every byte, so it always succeeds — last resort
        // for legacy single-byte encodings.
        if let latin = String(data: data, encoding: .isoLatin1) { return .ok(latin, .isoLatin1) }
        return .unreadable
    }

    /// Reads a text file for editing, with its version read just before: a
    /// write in between shows as a change at the next check, never as the
    /// version read. Explicit user opens (`interactive`) surface failures
    /// as alerts; internal reads just log.
    private func readFileContent(
        at absolute: String, interactive: Bool
    ) -> (content: String, encoding: String.Encoding, version: DiskVersion)? {
        let version = diskVersion(of: absolute)
        switch Self.readTextFile(at: absolute) {
        case .ok(let content, let encoding):
            return (content, encoding, version)
        case .binary:
            if interactive {
                showOpenFailureAlert(path: absolute, reason: "Binary files can't be edited.")
            } else {
                NSLog("[EditorColumn] skipping binary file \(absolute)")
            }
        case .unreadable:
            if interactive {
                showOpenFailureAlert(path: absolute, reason: "The file couldn't be read.")
            } else {
                NSLog("[EditorColumn] cannot read \(absolute)")
            }
        }
        return nil
    }

    private func showOpenFailureAlert(path: String, reason: String) {
        let alert = NSAlert()
        alert.messageText = "Can't open \((path as NSString).lastPathComponent)"
        alert.informativeText = reason
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func openDeletedBufferForDiff(path absolute: String, activate: Bool = true) {
        if tabPaths.contains(absolute) {
            if activate {
                switchTo(path: absolute)
            }
            return
        }
        openBuffer(path: absolute, content: "", version: .missing, line: nil, activate: activate, forDiff: true)
    }

    private func openBuffer(
        path absolute: String,
        content: String,
        version: DiskVersion,
        line: Int?,
        endLine: Int? = nil,
        takeFocus: Bool = true,
        activate: Bool = true,
        encoding: String.Encoding = .utf8,
        forDiff: Bool = false
    ) {
        tabPaths.append(absolute)
        dirtyByPath[absolute] = false
        encodingByPath[absolute] = encoding
        diskVersionByPath[absolute] = version
        diskModifiedWhileDirty.remove(absolute)

        if activate {
            activePath = absolute
        }
        if Self.isDraft(absolute) { draftPaths.insert(absolute) }
        // Not one opened at a line or for its diff: those show in the source.
        if isFront, line == nil, !forDiff, canRender(absolute) {
            renderedPaths.insert(absolute)
        }

        refreshTabBar()
        if activate {
            fileTree.reveal(absolutePath: absolute)
            onPathChanged?()
            onDirtyChanged?()
        }

        var payload: [String: Any] = [
            "type": "openFile",
            "path": absolute,
            "content": content,
            "activate": activate,
            "version": newTextVersion(of: absolute)
        ]
        payload.merge(tabFlags(of: absolute)) { $1 }
        if let line { payload["line"] = line }
        Self.applyNavFlags(&payload, endLine: endLine, range: shownRanges[absolute], takeFocus: takeFocus)
        sendBridge(payload)
        startFileWatch()
    }

    /// Gives Monaco the keyboard, as a click in it would: its column got
    /// the focus. The page refocuses what Monaco had focused, or with
    /// nothing focused yet (opened without the keyboard), the code editor.
    func takeKeyboard() {
        window?.makeFirstResponder(webView)
        sendBridge(["type": "takeKeyboard"])
    }

    /// Switch the active tab. The model already exists on the JS side; we
    /// only ask Monaco to swap to it.
    func switchTo(path: String, takeFocus: Bool = true) {
        guard tabPaths.contains(path), activePath != path else { return }
        // The JS surface exits the visible diff while switching models. Swift
        // keeps per-tab diff intent and re-enters it after the model swap.
        if diffActivePath != nil {
            diffActivePath = nil
            diffActiveBase = nil
            diffLoadGeneration += 1
        }
        activePath = path
        refreshTabBar()
        onPathChanged?()
        onDirtyChanged?()
        if let group = diffGroupTabs[path] {
            sendDiffGroup(group)
            return
        }
        fileTree.reveal(absolutePath: path)
        var payload: [String: Any] = ["type": "switchTab", "path": path]
        payload.merge(tabFlags(of: path)) { $1 }
        Self.applyNavFlags(&payload, endLine: nil, range: nil, takeFocus: takeFocus)
        sendBridge(payload)
        // Known gap: re-entering a saved diff intent below still grabs
        // focus JS-side even for takeFocus:false — rare enough (agent open
        // of an inactive tab the user has a diff pinned on) to not thread
        // the flag through the whole diff pipeline.
        if let mode = diffModeByPath[path] {
            enterDiff(for: path, mode: mode)
        }
    }

    /// Ask Monaco for the current selection (send-to-agent flow). The
    /// completion fires with nil when nothing is selected.
    func requestSelection(_ completion: @escaping (Selection?) -> Void) {
        nextSelectionRequestID += 1
        let requestID = nextSelectionRequestID
        selectionRequests[requestID] = completion
        sendBridge(["type": "getSelection", "requestID": requestID])
    }

    /// Fail every in-flight selection request. Called when the webview can
    /// no longer answer (content process crash, column closed).
    private func drainSelectionRequests() {
        let pending = selectionRequests.values
        selectionRequests.removeAll()
        for completion in pending { completion(nil) }
    }

    /// Toggle Monaco's selected diff view on the active tab. In HEAD mode the
    /// original side reads `git show HEAD:<relpath>`. In Branch mode it reads
    /// the merge-base version of the file so committed branch changes are
    /// included too. Modified side keeps the live buffer so the user can save
    /// edits straight from the diff.
    func toggleDiff() {
        toggleDiff(mode: selectedDiffMode)
    }

    /// The header's toggle: the active Markdown tab rendered, or its source.
    func toggleRendered() {
        guard let path = currentPath, canRender(path) else { return }
        setRendered(!renderedPaths.contains(path), of: path)
    }

    /// `find`: Monaco's find opens on the source, as ⌘F asked.
    private func setRendered(_ rendered: Bool, of path: String, find: Bool = false) {
        if rendered { renderedPaths.insert(path) } else { renderedPaths.remove(path) }
        // The reading view highlights no lines.
        if rendered, shownRanges.removeValue(forKey: path) != nil {
            sendBridge(["type": "clearShownRange", "path": path])
        }
        // Before a diff ends: the page then shows the reading view at once.
        sendBridge(["type": "setRendered", "path": path, "rendered": rendered, "find": find])
        if rendered {
            diffModeByPath.removeValue(forKey: path)
            diffLoadGeneration += 1
            if diffActivePath == path { return exitDiff() }
        }
        refreshHeader()
    }

    /// A diff shows the tab's text, over the reading view: once it is in,
    /// the tab no longer renders.
    private func endRendering(of path: String) {
        guard renderedPaths.remove(path) != nil else { return }
        sendBridge(["type": "setRendered", "path": path, "rendered": false])
    }

    /// Copy Draft: the active draft's text, unsaved edits included, as plain
    /// text; the button says so for a moment.
    func copyDraft() {
        guard let path = currentPath, draftPaths.contains(path) else { return }
        webView.callAsyncJavaScript("return window.niruxBridge.text(path)", arguments: ["path": path], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            guard case .success(let value) = result, let text = value as? String else {
                return self.showToast("Couldn’t copy the draft", tone: .error)
            }
            self.pasteboard.clearContents()
            self.pasteboard.setString(text, forType: .string)
            self.flashCopied()
        }
    }

    private func flashCopied() {
        copiedFlashGeneration += 1
        let generation = copiedFlashGeneration
        copyDraftButton.title = "Copied ✓"
        header.needsLayout = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { @MainActor [weak self] in
            guard let self, self.copiedFlashGeneration == generation else { return }
            self.copyDraftButton.title = Self.copyDraftTitle
            self.header.needsLayout = true
        }
    }

    /// Toggle word wrap in the Monaco surface (and diff surface when active).
    func toggleWordWrap() {
        sendBridge(["type": "toggleWordWrap"])
    }

    /// Save every dirty buffer, each through the Cmd+S write path;
    /// `completion` says whether all were written.
    func saveAll(then completion: @escaping (Bool) -> Void = { _ in }) {
        save(paths: nil, then: completion)
    }

    /// Saves `paths`, or every dirty buffer when nil: the page posts them,
    /// as it holds the text. A file changed on disk under its edits isn't
    /// saved: its tab shows, with the conflict banner.
    func save(paths: [String]?, then completion: @escaping (Bool) -> Void) {
        let targets = paths ?? unsavedPaths
        guard !targets.isEmpty else { return completion(true) }
        guard monacoReady else {
            showToast("Not saved: the editor isn’t running", tone: .error)
            return completion(false)
        }
        let conflicted = targets.filter(diskModifiedWhileDirty.contains)
        if let first = conflicted.first {
            switchTo(path: first)
            showSaveRefusal(path: first)
        }
        nextSaveRequestID += 1
        let requestID = nextSaveRequestID
        saveRequests[requestID] = SaveRequest(allWritten: conflicted.isEmpty, completion: completion)
        var payload: [String: Any] = ["type": "saveAll", "requestID": requestID, "skipPaths": conflicted]
        if let paths { payload["paths"] = paths }
        sendBridge(payload)
        // A page that never answers (its script threw) holds no close nor
        // the quit; in every mode, the quit's wait for an answer included.
        let timeout = Timer(timeInterval: saveTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireSaveRequest(requestID) }
        }
        RunLoop.main.add(timeout, forMode: .common)
    }

    private func expireSaveRequest(_ requestID: Int) {
        guard let request = saveRequests.removeValue(forKey: requestID) else { return }
        showToast("Not saved: the editor didn’t answer", tone: .error)
        request.completion(false)
    }

    /// Fails every save request the page can no longer answer.
    private func drainSaveRequests() {
        let pending = saveRequests.values
        saveRequests.removeAll()
        for request in pending { request.completion(false) }
    }

    /// Toggle the minimap in the Monaco surface (and diff surface when active).
    func toggleMinimap() {
        sendBridge(["type": "toggleMinimap"])
    }

    func toggleDiff(mode: EditorDiffMode) {
        guard let path = activePath, !Self.isDiffGroupPath(path) else { return }
        selectedDiffMode = mode
        refreshTabBar()
        if diffActivePath == path, diffActiveBase == .git(mode) {
            diffModeByPath.removeValue(forKey: path)
            exitDiff()
            return
        }
        diffModeByPath[path] = mode
        enterDiff(for: path, mode: mode)
    }

    /// Open a file, if needed, and show its diff.
    func showDiff(path: String) {
        showDiff(path: path, mode: .head)
    }

    func showDiff(path: String, mode: EditorDiffMode) {
        selectedDiffMode = mode
        let absolute = absolutePath(for: path)
        diffModeByPath[absolute] = mode
        guard ensureBufferOpen(path: absolute, activate: true) else { return }
        refreshTabBar()
        guard activePath == absolute else { return }
        guard diffActivePath != absolute || diffActiveBase != .git(mode) else { return }
        enterDiff(for: absolute, mode: mode)
    }

    func showDiffCollection(title: String, paths: [String], mode: EditorDiffMode) {
        selectedDiffMode = mode
        diffLoadGeneration += 1
        let groupPath = Self.diffGroupPath(mode: mode)
        let cwd = workspaceCwd
        var seen = Set<String>()
        let absolutePaths = paths
            .map { absolutePath(for: $0) }
            .filter { seen.insert($0).inserted }

        guard !absolutePaths.isEmpty else {
            showToast("No files to compare")
            return
        }

        let load = UUID()
        let loadingGroup = DiffGroupTab(title: title, mode: mode, files: [], load: load)
        openDiffGroup(loadingGroup, at: groupPath)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let files = absolutePaths.compactMap { path -> [String: Any]? in
                let started = Date()
                let payload = Self.diffFilePayload(of: path, cwd: cwd, mode: mode)
                NSLog("%@", "[probe] read \((path as NSString).lastPathComponent) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                return payload
            }
            Task { @MainActor [weak self] in
                NSLog("%@", "[probe] files in: wanted \(self?.diffGroupTabs[groupPath]?.load == load), group active \(self?.activePath == groupPath)")
                // Its tab still waits on it, in front or not: neither closed
                // nor loading another list since.
                guard let self, self.diffGroupTabs[groupPath]?.load == load else { return }
                guard !files.isEmpty else {
                    // Not left loading.
                    self.close(path: groupPath)
                    // Maybe over another tab's diff: it says which tab.
                    self.showToast("Couldn’t read the changes of “\(title)”", tone: .error)
                    return
                }
                let group = DiffGroupTab(title: title, mode: mode, files: files, load: nil)
                self.diffGroupTabs[groupPath] = group
                self.refreshTabBar()
                guard self.activePath == groupPath else { return }
                self.diffActivePath = nil
                self.diffActiveBase = .git(mode)
                self.onPathChanged?()
                self.onDirtyChanged?()
                self.sendDiffGroup(group)
            }
        }
    }

    func showCheckpointDiff(_ diff: LocalCheckpoints.Diff, title: String) {
        let group = DiffGroupTab(title: title, mode: nil, files: [], load: nil, checkpoint: diff)
        openDiffGroup(group, at: Self.diffGroupPathPrefix + "checkpoint")
    }

    private func openDiffGroup(_ group: DiffGroupTab, at groupPath: String) {
        diffGroupTabs[groupPath] = group
        if !tabPaths.contains(groupPath) {
            tabPaths.append(groupPath)
        }
        activePath = groupPath
        diffActivePath = nil
        diffActiveBase = group.mode.map(DiffBase.git)
        refreshTabBar()
        onPathChanged?()
        onDirtyChanged?()
        sendDiffGroup(group)
    }

    /// `focus` false: an agent's open, which leaves the keyboard where it is.
    private func exitDiff(focus: Bool = true) {
        diffLoadGeneration += 1
        diffActivePath = nil
        diffActiveBase = nil
        refreshTabBar()
        var payload: [String: Any] = ["type": "exitDiff"]
        if !focus { payload["focus"] = false }
        sendBridge(payload)
    }

    @discardableResult
    private func ensureBufferOpen(path absolute: String, activate: Bool) -> Bool {
        if tabPaths.contains(absolute) {
            if activate {
                switchTo(path: absolute)
            }
            return true
        }

        if FileManager.default.fileExists(atPath: absolute) {
            guard let file = readFileContent(at: absolute, interactive: false) else { return false }
            openBuffer(
                path: absolute, content: file.content, version: file.version, line: nil, activate: activate,
                encoding: file.encoding, forDiff: true
            )
        } else {
            openDeletedBufferForDiff(path: absolute, activate: activate)
        }
        return true
    }

    private func sendDiffGroup(_ group: DiffGroupTab) {
        NSLog("%@", "[probe] send enterDiffGroup loading \(group.isLoading) files \(group.files.count) page ready \(monacoReady)")
        var payload: [String: Any] = [
            "type": "enterDiffGroup",
            "title": group.title,
            "mode": group.mode?.rawValue ?? "checkpoint",
            "loading": group.isLoading,
            "files": group.files
        ]
        if let diff = group.checkpoint {
            payload["warning"] = diff.warning
            payload["notes"] = diff.notes
            payload["files"] = diff.files.map(Self.checkpointPayload)
        }
        sendBridge(payload)
    }

    /// A checkpoint's file as the page draws it: its hunks, or its note.
    private nonisolated static func checkpointPayload(_ file: LocalCheckpoints.Diff.File) -> [String: Any] {
        var payload: [String: Any] = ["path": file.path, "hunks": file.hunks.map { hunk -> [String: Any] in
            ["oldStart": hunk.oldStart, "newStart": hunk.newStart, "section": hunk.section,
             "lines": hunk.lines.map { ["kind": $0.kind, "text": $0.text] }]
        }]
        payload["note"] = file.note
        return payload
    }

    /// Whether the tab's diff is pierre's, which shows no highlighted lines
    /// (a draft's and Compare's are Monaco's, as is one pierre failed to draw).
    var showsPierreDiff: Bool { diffActivePath == activePath && diffViewer == "pierre" }

    private func enterDiff(for path: String, mode: EditorDiffMode) {
        diffLoadGeneration += 1
        let generation = diffLoadGeneration
        let cwd = workspaceCwd
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let original = Self.gitOriginalContent(
                of: path,
                cwd: cwd,
                mode: mode,
                maxBytes: EditorFileLimits.maxEditableBytes
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.diffLoadGeneration == generation else { return }
                guard self.activePath == path else { return } // stale request
                switch original {
                case nil:
                    NSLog("%@", "[EditorColumn] no git \(mode.rawValue) content for \(path) — file untracked, git missing, or branch base unavailable")
                    self.forgetFailedDiffMode(path: path)
                    self.showToast(Self.noDiffOriginalText(path: path, cwd: cwd, mode: mode))
                case .binary:
                    self.forgetFailedDiffMode(path: path)
                    self.showToast("This file isn’t text, so it isn’t compared")
                case .tooLarge(let byteCount):
                    NSLog("%@", "[EditorColumn] git \(mode.rawValue) original of \(path) too large to diff (\(byteCount) bytes)")
                    self.forgetFailedDiffMode(path: path)
                    self.showToast("This file is too large to compare")
                case .text(let original):
                    self.diffActivePath = path
                    self.diffActiveBase = .git(mode)
                    self.sendBridge(["type": "enterDiff", "path": path, "original": original, "viewer": self.draftPaths.contains(path) ? "monaco" : "pierre"])
                    self.endRendering(of: path)
                    self.refreshTabBar()
                }
            }
        }
    }

    /// A diff that failed isn't asked again each time its tab comes back;
    /// the one still on screen, if any, is.
    private func forgetFailedDiffMode(path: String) {
        if diffActivePath == path, case .git(let shown)? = diffActiveBase {
            diffModeByPath[path] = shown
            selectedDiffMode = shown
            refreshTabBar()
        } else {
            diffModeByPath.removeValue(forKey: path)
        }
    }

    func absolutePath(for path: String) -> String {
        (path as NSString).isAbsolutePath
            ? path
            : (workspaceCwd as NSString).appendingPathComponent(path)
    }

    /// The tab's × and ⌘W: unsaved edits ask first.
    func closeAskingFirst(path: String) {
        guard unsavedPaths.contains(path) else { return close(path: path) }
        switch askAboutUnsavedEdits([path]) {
        case .save:
            save(paths: [path]) { [weak self] written in
                if written { self?.close(path: path) }
            }
        case .discard:
            close(path: path)
        case .cancel:
            break
        }
    }

    /// Close a tab. Disposes its Monaco model and switches focus to a
    /// neighbor if the closed tab was active.
    func close(path: String) {
        guard let index = tabPaths.firstIndex(of: path) else { return }
        let isDiffGroup = Self.isDiffGroupPath(path)
        let wasActive = activePath == path
        tabPaths.remove(at: index)
        dirtyByPath.removeValue(forKey: path)
        diskVersionByPath.removeValue(forKey: path)
        textVersionByPath.removeValue(forKey: path)
        encodingByPath.removeValue(forKey: path)
        diskModifiedWhileDirty.remove(path)
        diffModeByPath.removeValue(forKey: path)
        renderedPaths.remove(path)
        draftPaths.remove(path)
        shownRanges.removeValue(forKey: path)
        diffGroupTabs.removeValue(forKey: path)
        if diffActivePath == path {
            diffLoadGeneration += 1
            diffActivePath = nil
            diffActiveBase = nil
            sendBridge(["type": "exitDiff"])
        }
        if !isDiffGroup {
            sendBridge(["type": "closeTab", "path": path])
        } else if wasActive {
            sendBridge(["type": "exitDiff"])
        }

        if wasActive {
            // Prefer the tab to the right (the one that visually "shifted"
            // into the closed slot); fall back to the previous neighbor.
            if index < tabPaths.count {
                activePath = tabPaths[index]
            } else if index - 1 >= 0, index - 1 < tabPaths.count {
                activePath = tabPaths[index - 1]
            } else {
                activePath = nil
            }
            if let next = activePath {
                if let group = diffGroupTabs[next] {
                    sendDiffGroup(group)
                } else {
                    var payload: [String: Any] = ["type": "switchTab", "path": next]
                    payload.merge(tabFlags(of: next)) { $1 }
                    sendBridge(payload)
                    fileTree.reveal(absolutePath: next)
                    if let mode = diffModeByPath[next] {
                        enterDiff(for: next, mode: mode)
                    }
                }
            }
            onPathChanged?()
            onDirtyChanged?()
        }
        refreshTabBar()
    }

    /// Re-read the active file from disk and push its content to Monaco.
    /// Used when an external change races a clean buffer.
    /// `keepingEdits`: the page keeps text typed that Swift hasn't heard
    /// of yet, and says so (`reloadRefused`).
    @discardableResult
    private func reloadFromDisk(path: String, keepingEdits: Bool = true) -> Bool {
        guard let (content, encoding, version) = readFileContent(at: path, interactive: false) else { return false }

        diskVersionByPath[path] = version
        encodingByPath[path] = encoding
        diskModifiedWhileDirty.remove(path)
        refreshTabBar()
        // activate: false is critical for background tabs — an openFile with
        // implicit activation would steal Monaco's active tab, and the next
        // Cmd+S (which saves the JS-side currentPath) would write the wrong
        // buffer to the wrong file. focus: false because a background disk
        // sync must never grab the keyboard — e.g. an agent edits the file
        // it just revealed while the user is typing in a terminal.
        var payload: [String: Any] = [
            "type": "openFile", "path": path, "content": content,
            "activate": path == activePath, "focus": false, "keepEdits": keepingEdits,
            "version": newTextVersion(of: path)
        ]
        payload.merge(tabFlags(of: path)) { $1 }
        sendBridge(payload)
        return true
    }

    /// How the page shows `path` (bridge.js's `adoptTabFlags`).
    private func tabFlags(of path: String) -> [String: Any] {
        ["rendered": renderedPaths.contains(path), "draft": draftPaths.contains(path)]
    }

    /// A text the nirux-draft skill wrote: a file in the folder its
    /// `mktemp -d` made in $TMPDIR, else /tmp, which is a temporary
    /// directory or one inside it (a sandboxed agent's).
    nonisolated static func isDraft(_ path: String, temporaryDirectories: [String] = [NSTemporaryDirectory(), "/tmp"]) -> Bool {
        let folder = (path as NSString).deletingLastPathComponent
        guard (folder as NSString).lastPathComponent.hasPrefix("nirux-draft-") else { return false }
        // Both sides resolved alike: /tmp and /private/tmp name one folder.
        let resolved = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let parent = resolved((folder as NSString).deletingLastPathComponent)
        return temporaryDirectories.map(resolved).contains { parent == $0 || parent.hasPrefix($0 + "/") }
    }

    nonisolated static func isMarkdown(_ path: String) -> Bool {
        ["md", "markdown"].contains((path as NSString).pathExtension.lowercased())
    }

    /// A Markdown tab that isn't a draft: it can show rendered.
    func canRender(_ path: String) -> Bool {
        Self.isMarkdown(path) && !draftPaths.contains(path)
    }

    private func newTextVersion(of path: String) -> Int {
        nextTextVersion += 1
        textVersionByPath[path] = nextTextVersion
        return nextTextVersion
    }

    /// Shared tail of every navigation payload — one place to add the next
    /// flag so the fresh-open, already-open and switch-tab paths can't
    /// drift apart.
    private static func applyNavFlags(_ payload: inout [String: Any], endLine: Int?, range: ShownRange?, takeFocus: Bool) {
        if let endLine { payload["endLine"] = endLine }
        if let range { payload["rangeID"] = range.id }
        if !takeFocus { payload["focus"] = false }
    }

    // MARK: - File watcher

    private func startFileWatch() {
        guard fileWatchTimer == nil, !openPaths.isEmpty else { return }
        fileWatchTimer = Timer.scheduledTimer(
            withTimeInterval: Self.watchInterval, repeats: true
        ) { [weak self] _ in
            // Timer callback fires nonisolated; bounce to MainActor for state access.
            Task { @MainActor [weak self] in
                self?.checkDisk()
            }
        }
    }

    /// Pause the 1.5s disk-watch timer. Called when the app resigns active so
    /// we don't burn cycles polling mtimes while backgrounded. `resumeFileWatch`
    /// restarts it if any files are still open.
    func pauseFileWatch() {
        fileWatchTimer?.invalidate()
        fileWatchTimer = nil
    }

    /// Resume the disk-watch timer (no-op if no files are open).
    func resumeFileWatch() {
        startFileWatch()
    }

    private func checkDisk() {
        // A conflict keeps the version the user was shown.
        for path in openPaths where !diskModifiedWhileDirty.contains(path) {
            guard let version = diskChange(of: path) else { continue }
            adoptDiskChange(of: path, version: version)
        }
    }

    /// The file changed on disk, or went: unsaved edits wait for the user's
    /// choice, nothing saved meanwhile; a clean buffer takes the new
    /// version, and keeps showing a file that went. `version`: the one Keep
    /// Mine may replace.
    private func adoptDiskChange(of path: String, version: DiskVersion) {
        guard dirtyByPath[path] ?? false else {
            if version != .missing { reloadFromDisk(path: path) }
            return
        }
        raiseConflict(path: path, version: version)
    }

    private func raiseConflict(path: String, version: DiskVersion) {
        diskVersionByPath[path] = version
        diskModifiedWhileDirty.insert(path)
        refreshTabBar()
        if path == activePath { onDirtyChanged?() }
    }

    /// The file's version when it is no longer the one last read or
    /// written, a file gone included; nil while it is.
    private func diskChange(of path: String) -> DiskVersion? {
        let version = diskVersion(of: path)
        return version == diskVersionByPath[path] ? nil : version
    }

    private func diskVersion(of path: String) -> DiskVersion {
        mtime(of: path).map { .file(modified: $0) } ?? .missing
    }

    private func mtime(of path: String) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: Self.linkTarget(of: path))
        return attrs?[.modificationDate] as? Date
    }

    /// Through symlinks, the file a path names, there or not: an agent
    /// edits AGENTS.md under a CLAUDE.md link, or moves it away.
    private nonisolated static func linkTarget(of path: String) -> String {
        var target = path
        // A loop of links stops somewhere.
        for _ in 0..<32 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: target) else { break }
            target = (destination as NSString).isAbsolutePath
                ? destination
                : ((target as NSString).deletingLastPathComponent as NSString).appendingPathComponent(destination)
        }
        return target
    }

    // MARK: - JS bridge

    /// The caret's line and column in `path`'s tab; none while another tab
    /// shows, or it reads rendered.
    func readCaret(of path: String, _ done: @escaping @MainActor (Int?, Int?) -> Void) {
        webView.callAsyncJavaScript("return window.niruxBridge.caret(path)", arguments: ["path": path], in: nil, in: .page) { result in
            let numbers = ((try? result.get()) as? String)?.split(separator: ":").compactMap { Int($0) } ?? []
            MainActor.assumeIsolated { done(numbers.first, numbers.dropFirst().first) }
        }
    }

    private func sendBridge(_ payload: [String: Any]) {
        let send = { [weak self] in
            guard let self else { return }
            guard let json = try? JSONSerialization.data(withJSONObject: payload)
            else { return }
            // Base64 transport: the payload can contain arbitrary file content
            // (backticks, ${...}, quotes) that breaks template-literal embedding.
            let b64 = json.base64EncodedString()
            let js = "window.niruxBridge.handleB64(\"\(b64)\")"
            self.webView.evaluateJavaScript(js, completionHandler: nil)
        }
        if monacoReady { send() } else { pendingOps.append(send) }
    }

    /// Persist a buffer to disk. Path comes from JS but we only honor saves
    /// for tabs we're actually tracking, so a compromised page can't redirect
    /// writes outside our open set.
    private func handleSave(body: [String: Any]) {
        let path = body["path"] as? String
        let written: Bool = {
            guard let path, openPaths.contains(path), let content = body["content"] as? String else { return false }
            // Its text grew from one Swift has since replaced: a reload
            // follows on the page.
            guard body["version"] as? Int == textVersionByPath[path] else {
                showSaveRefusal(path: path)
                return false
            }
            return write(content, to: path)
        }()
        // The page takes as clean the text of this save only, once written.
        var reply: [String: Any] = ["type": written ? "markSaved" : "saveRefused"]
        reply["path"] = path
        reply["saveID"] = body["saveID"]
        sendBridge(reply)
        if written {
            scheduleGitReload()
        } else if let requestID = body["requestID"] as? Int {
            saveRequests[requestID]?.allWritten = false
        }
    }

    /// Writes in the encoding detected at open — a UTF-16 (or Latin-1) file
    /// is not silently transcoded to UTF-8 — and only over the version last
    /// read or written: a change made on disk since is never overwritten
    /// unasked. False: nothing written.
    private func write(_ content: String, to path: String) -> Bool {
        if diskModifiedWhileDirty.contains(path) {
            showSaveRefusal(path: path)
            return false
        }
        if let version = diskChange(of: path) {
            adoptDiskChange(of: path, version: version)
            // A clean buffer took the new version, or keeps showing a file
            // gone, which a save doesn't bring back.
            if diskModifiedWhileDirty.contains(path) || version == .missing { showSaveRefusal(path: path) }
            return false
        }
        // Nor a clean buffer opened for a deleted file's diff.
        if diskVersionByPath[path] == .missing, !(dirtyByPath[path] ?? false) {
            showSaveRefusal(path: path)
            return false
        }

        let encoding = encodingByPath[path] ?? .utf8
        var data = content.data(using: encoding)
        if data == nil, encoding != .utf8 {
            // e.g. a Latin-1 file that now contains unrepresentable
            // characters — fall back to UTF-8 so the save can't fail.
            NSLog("[EditorColumn] \(path): \(encoding) can no longer represent the buffer; saving as UTF-8")
            data = content.data(using: .utf8)
            if data != nil { encodingByPath[path] = .utf8 }
        }
        guard let data else {
            NSLog("[EditorColumn] save failed for \(path): buffer not representable")
            showToast("Couldn’t save “\((path as NSString).lastPathComponent)”", tone: .error)
            return false
        }

        do {
            // Into the file a symlink names: replacing the path would replace
            // the link.
            let written = try Self.replaceFile(at: URL(fileURLWithPath: Self.linkTarget(of: path)), with: data)
            diskVersionByPath[path] = .file(modified: written)
        } catch {
            NSLog("[EditorColumn] save failed for \(path): \(error)")
            showToast("Couldn’t save “\((path as NSString).lastPathComponent)”", tone: .error)
            return false
        }
        return true
    }

    /// Writes `data` in a file of its own, then puts it in the place of the
    /// file at `url`, whose permissions it keeps. Returns the modification
    /// date of what was written, read before it takes the file's place: a
    /// write landing after it reads as a change.
    private nonisolated static func replaceFile(at url: URL, with data: Data) throws -> Date {
        let manager = FileManager.default
        let folder = try manager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url.deletingLastPathComponent(), create: true
        )
        defer { try? manager.removeItem(at: folder) }
        let written = folder.appendingPathComponent(url.lastPathComponent)
        try data.write(to: written)
        let original = try? manager.attributesOfItem(atPath: url.path)
        if let permissions = original?[.posixPermissions] {
            try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: written.path)
        }
        // Its group too, where we may give it (a shared repository).
        if let group = original?[.groupOwnerAccountID] {
            try? manager.setAttributes([.groupOwnerAccountID: group], ofItemAtPath: written.path)
        }
        guard let modified = try manager.attributesOfItem(atPath: written.path)[.modificationDate] as? Date else {
            throw CocoaError(.fileReadUnknown)
        }
        guard rename(written.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return modified
    }

    private func showSaveRefusal(path: String) {
        let change = diskVersion(of: path) == .missing ? "was deleted" : "changed"
        showToast("Not saved: “\((path as NSString).lastPathComponent)” \(change) on disk")
    }

    /// Coalesce git-status refreshes: Save All lands one save per dirty file
    /// in quick succession, and each would otherwise spawn its own burst of
    /// git subprocesses whose results all but the last get discarded.
    private func scheduleGitReload() {
        gitReloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.gitReloadWorkItem = nil
            self?.fileTree.reloadGitChanges()
        }
        gitReloadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func refreshTabBar() {
        let bars: [EditorTabBar.Tab] = tabPaths.map { path in
            let dirty = (dirtyByPath[path] ?? false) || diskModifiedWhileDirty.contains(path)
            return EditorTabBar.Tab(path: path, isDirty: dirty, title: diffGroupTabs[path]?.title)
        }
        tabBar.update(tabs: bars, activePath: activePath)
        refreshHeader()
        updateConflictBanner()
        updateBranchReviewBanner()
    }

    /// The banner shows over the branch's whole diff (Full Branch Diff),
    /// not over a file's or the uncommitted changes'.
    private func updateBranchReviewBanner() {
        let shows = activePath.flatMap { diffGroupTabs[$0]?.mode } == .branch
        guard branchReviewBanner.isHidden == shows else { return }
        branchReviewBanner.isHidden = !shows
        needsLayout = true
    }

    /// Show the disk-conflict banner when the active tab was modified
    /// externally while dirty.
    private func updateConflictBanner() {
        guard let path = activePath, diskModifiedWhileDirty.contains(path) else {
            conflictBanner.isHidden = true
            return
        }
        conflictBanner.configure(
            fileName: (path as NSString).lastPathComponent,
            isDeleted: diskVersionByPath[path] == .missing,
            isComparing: isComparingWithDisk(path)
        )
        conflictBanner.isHidden = false
        needsLayout = true
    }

    private func isComparingWithDisk(_ path: String) -> Bool {
        diffActivePath == path && diffActiveBase == .disk
    }

    /// Compare: the buffer beside the disk's version in Monaco's diff, its
    /// side still editable; again, back to the buffer alone.
    private func toggleDiskCompare() {
        guard let path = activePath, diskModifiedWhileDirty.contains(path) else { return }
        if isComparingWithDisk(path) { return exitDiff() }
        // A file gone compares with nothing.
        let disk: (content: String, version: DiskVersion)?
        if diskVersion(of: path) == .missing {
            disk = ("", .missing)
        } else {
            disk = readFileContent(at: path, interactive: false).map { ($0.content, $0.version) }
        }
        guard let disk else {
            // The button turned itself on.
            refreshTabBar()
            return showDiskReadFailure(path: path)
        }
        // Keep Mine replaces the version shown.
        diskVersionByPath[path] = disk.version
        diffLoadGeneration += 1
        diffActivePath = path
        diffActiveBase = .disk
        sendBridge(["type": "enterDiff", "viewer": "monaco", "path": path, "original": disk.content])
        endRendering(of: path)
        refreshTabBar()
    }

    /// Take Disk: the buffer becomes the file on disk, its edits gone; a
    /// file gone takes its tab with it.
    private func takeDiskVersion() {
        guard let path = activePath, diskModifiedWhileDirty.contains(path) else { return }
        if isComparingWithDisk(path) { exitDiff() }
        guard diskVersion(of: path) != .missing else { return close(path: path) }
        if !reloadFromDisk(path: path, keepingEdits: false) { showDiskReadFailure(path: path) }
    }

    private func showDiskReadFailure(path: String) {
        showToast("Couldn’t read “\((path as NSString).lastPathComponent)” on disk", tone: .error)
    }

    /// Keep Mine: the buffer replaces the version of the file the user was
    /// shown; one changed again since asks again.
    private func keepMine() {
        guard let path = activePath, diskModifiedWhileDirty.contains(path) else { return }
        if isComparingWithDisk(path) { exitDiff() }
        diskModifiedWhileDirty.remove(path)
        refreshTabBar()
        onDirtyChanged?()
        save(paths: [path]) { _ in }
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Monaco loads asynchronously after navigation finishes; we wait for the
        // "monacoReady" bridge message to actually push content.
    }

    /// The WebContent process died — Monaco and every model with it. Fail
    /// in-flight requests and surface the retry overlay instead of leaving
    /// a silently dead surface that still claims `monacoReady`.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            monacoReady = false
            pendingOps.removeAll()
            drainSelectionRequests()
            drainSaveRequests()
            showLoadFailure(message: "The editor process crashed.", showRetry: true)
        }
    }

    // MARK: - WKUIDelegate

    /// A scroll the page didn't handle goes on to the strip (`StripSwipe`).
    @objc(_webView:didNotHandleWheelEvent:)
    func webView(_ webView: WKWebView, didNotHandleWheelEvent event: NSEvent) {
        webView.passOnUnhandled(event)
    }

    // MARK: - WKScriptMessageHandler

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // WKScriptMessageHandler callbacks always arrive on the main thread
        // (per Apple's docs). Xcode 16.4 declares `WKScriptMessage.body` as
        // @MainActor-isolated, so we need to assume isolation to read it from
        // this nonisolated protocol method.
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String
            else { return }
            handleBridgeMessage(type: type, body: body)
        }
    }

    private func handleBridgeMessage(type: String, body: [String: Any]) {
        switch type {
        case "monacoReady":
            NSLog("%@", "[probe] monacoReady, \(pendingOps.count) queued")
            monacoReady = true
            monacoLoadWatchdog?.invalidate()
            monacoLoadWatchdog = nil
            loadFailureOverlay.isHidden = true
            let queued = pendingOps
            pendingOps.removeAll()
            for op in queued { op() }
        case "dirty":
            guard let path = body["path"] as? String else { return }
            let dirty = (body["isDirty"] as? Bool) ?? false
            if (dirtyByPath[path] ?? false) != dirty {
                dirtyByPath[path] = dirty
                refreshTabBar()
                if path == activePath { onDirtyChanged?() }
            }
            // Its edits undone, a conflict has nothing left to keep; a file
            // gone stays for the user to close.
            if !dirty, diskModifiedWhileDirty.contains(path), diskVersion(of: path) != .missing {
                if isComparingWithDisk(path) { exitDiff() }
                reloadFromDisk(path: path)
            }
        case "reloadRefused":
            // The page holds edits Swift hadn't heard of: the version read
            // waits beside them, as a conflict.
            guard let path = body["path"] as? String, let version = diskVersionByPath[path] else { return }
            // The page's text still grows from the version it holds.
            textVersionByPath[path] = body["version"] as? Int
            dirtyByPath[path] = true
            raiseConflict(path: path, version: version)
        case "save":
            handleSave(body: body)
        case "savedAll":
            guard let requestID = body["requestID"] as? Int,
                  let request = saveRequests.removeValue(forKey: requestID)
            else { return }
            request.completion(request.allWritten)
        case "selection":
            guard let requestID = body["requestID"] as? Int,
                  let completion = selectionRequests.removeValue(forKey: requestID)
            else { return }
            if let path = body["path"] as? String, !path.isEmpty,
               let text = body["text"] as? String, !text.isEmpty,
               let start = body["startLine"] as? Int,
               let end = body["endLine"] as? Int {
                completion(Selection(path: path, text: text, startLine: start, endLine: end))
            } else {
                completion(nil)
            }
        case "filePickerRequest":
            onFilePickerRequest?(self)
        case "sendSelectionShortcut":
            onSendSelectionShortcut?()
        case "escapeKey":
            onEscapeKey?()
        case "shownRangeMoved":
            guard let path = body["path"] as? String, let shown = shownRanges[path], shown.id == body["rangeID"] as? Int,
                  let start = body["start"] as? Int, let end = body["end"] as? Int, start <= end
            else { return }
            shownRanges[path] = ShownRange(lines: start...end, id: shown.id)
            refreshHeader()
        case "shownRangeCleared":
            guard let path = body["path"] as? String, shownRanges[path]?.id == body["rangeID"] as? Int else { return }
            shownRanges[path] = nil
            refreshHeader()
        case "findInSource":
            guard let path = body["path"] as? String, path == currentPath, renderedPaths.contains(path) else { return }
            setRendered(false, of: path, find: true)
        case "openLink":
            guard let text = body["url"] as? String, let url = BranchReviewView.webLink(text) else { return }
            onOpenLink?(url)
        case "textEdgeKey":
            guard let edge = (body["edge"] as? String).flatMap(TextEdge.init(rawValue:)) else { return }
            onTextEdgeKey?(edge)
        case "ready":
            // Monaco confirmed model swap; nothing to do.
            break
        case "diffViewer":
            guard let path = body["path"] as? String, path == diffActivePath else { return }
            diffViewer = body["viewer"] as? String
            refreshHeader()
        case "error":
            if let msg = body["message"] as? String {
                NSLog("[EditorColumn] bridge error: \(msg)")
            }
        default:
            break
        }
    }
}

struct DiffGroupTab {
    let title: String
    let mode: EditorDiffMode?
    let files: [[String: Any]]
    /// The read of its files, until they are in.
    let load: UUID?

    var checkpoint: LocalCheckpoints.Diff?

    var isLoading: Bool { load != nil }
}

// MARK: - Git / diff content helpers (nonisolated statics)

extension EditorColumn {
    /// The comparison side of a diff.
    enum DiffOriginal: Equatable, Sendable {
        case text(String)
        /// Not text (a NUL byte, or no UTF-8), so never compared.
        case binary
        /// Over the caller's size limit, so never loaded.
        case tooLarge(byteCount: UInt64)
    }

    /// Reads the comparison-side content for the requested diff mode.
    /// Nonisolated so we can call it from a background queue.
    nonisolated static func gitOriginalContent(
        of absPath: String,
        cwd: String,
        mode: EditorDiffMode,
        maxBytes: UInt64
    ) -> DiffOriginal? {
        guard let rel = relativeGitPath(of: absPath, cwd: cwd) else { return nil }
        switch mode {
        case .head:
            if let original = gitContent(relativePath: rel, ref: "HEAD", cwd: cwd, maxBytes: maxBytes) {
                return original
            }
            // New or untracked files have no blob in HEAD. Treat them as an
            // empty original so clicking a change always opens a useful diff.
            return FileManager.default.fileExists(atPath: absPath) ? .text("") : nil
        case .branch:
            guard let base = GitCommand.branchBaseRef(cwd: cwd) else { return nil }
            // A file added on the branch has no blob at the merge-base; an
            // empty original gives Monaco the expected "whole file added" diff.
            return gitContent(relativePath: rel, ref: base, cwd: cwd, maxBytes: maxBytes) ?? .text("")
        }
    }

    /// Why `gitOriginalContent` found nothing to compare with.
    private nonisolated static func noDiffOriginalText(path: String, cwd: String, mode: EditorDiffMode) -> String {
        if relativeGitPath(of: path, cwd: cwd) == nil { return "This file is outside the workspace’s folder" }
        return mode == .branch ? "No base branch to compare with" : "This file is no longer on disk"
    }

    private nonisolated static func relativeGitPath(of absPath: String, cwd: String) -> String? {
        let cwdPath = URL(fileURLWithPath: cwd).standardizedFileURL.path
        // Through the deepest folder that still exists, as `cwd` is:
        // standardizing drops a /private only from a path that exists, and a
        // deleted file (or folder) doesn't.
        var folder = URL(fileURLWithPath: absPath)
        var rest: [String] = []
        while folder.path != "/", !FileManager.default.fileExists(atPath: folder.path) {
            rest.insert(folder.lastPathComponent, at: 0)
            folder = folder.deletingLastPathComponent()
        }
        let absolutePath = rest.reduce(folder.standardizedFileURL) { $0.appendingPathComponent($1) }.path
        guard absolutePath == cwdPath || absolutePath.hasPrefix(cwdPath + "/") else { return nil }
        let rel = String(absolutePath.dropFirst(cwdPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !rel.isEmpty else { return nil }
        return rel
    }

    private nonisolated static func diffGroupPath(mode: EditorDiffMode) -> String {
        "\(diffGroupPathPrefix)\(mode.rawValue)"
    }

    nonisolated static func isDiffGroupPath(_ path: String) -> Bool {
        path.hasPrefix(diffGroupPathPrefix)
    }

    private nonisolated static func diffFilePayload(
        of absPath: String,
        cwd: String,
        mode: EditorDiffMode
    ) -> [String: Any]? {
        guard let rel = relativeGitPath(of: absPath, cwd: cwd) else { return nil }
        if let byteCount = fileByteCount(path: absPath), byteCount > maxDiffCollectionFileBytes {
            return largeDiffPlaceholderPayload(of: absPath, relativePath: rel, byteCount: byteCount)
        }
        // The original can be large even when the file is not: deleted or
        // shrunk since `mode`'s base.
        switch gitOriginalContent(of: absPath, cwd: cwd, mode: mode, maxBytes: maxDiffCollectionFileBytes) {
        case nil:
            return nil
        case .tooLarge(let byteCount):
            return largeDiffPlaceholderPayload(of: absPath, relativePath: rel, byteCount: byteCount)
        case .binary:
            return ["path": rel, "name": rel, "note": notText]
        case .text(let original):
            let present = FileManager.default.fileExists(atPath: absPath)
            guard let modified = present ? fileContent(at: absPath) : "" else {
                return ["path": rel, "name": rel, "note": notText]
            }
            var payload: [String: Any] = ["path": rel, "name": rel, "original": original, "modified": modified]
            // No lines to show: say what changed, as a checkpoint does.
            if original.isEmpty, modified.isEmpty {
                payload["note"] = !present ? "Empty file removed."
                    : existsAtBase(rel, cwd: cwd, mode: mode) ? "No change in its text." : "Empty file added."
            }
            return payload
        }
    }

    private nonisolated static let notText = "Binary or unreadable, not compared."

    private nonisolated static func existsAtBase(_ rel: String, cwd: String, mode: EditorDiffMode) -> Bool {
        guard let base = mode == .head ? "HEAD" : GitCommand.branchBaseRef(cwd: cwd) else { return false }
        return GitCommand.output(["cat-file", "-e", "\(base):\(rel)"], cwd: cwd) != nil
    }

    private nonisolated static func largeDiffPlaceholderPayload(
        of absPath: String,
        relativePath rel: String,
        byteCount: UInt64
    ) -> [String: Any] {
        NSLog("%@", "[EditorColumn] replacing large visual diff file \(absPath) (\(byteCount) bytes)")
        return ["path": rel, "name": rel, "note": "Too large to compare (\(byteCount) bytes)."]
    }

    private nonisolated static func fileByteCount(path: String) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber
        else { return nil }
        return size.uint64Value
    }

    private nonisolated static func fileContent(at path: String) -> String? {
        guard case .ok(let content, _) = readTextFile(at: path) else { return nil }
        return content
    }

    /// The blob at `ref:rel`, or only its size when over `maxBytes`. Nil
    /// when there is no such blob (or git fails). `cat-file blob` prints
    /// exactly the bytes `-s` counted; `show` would list a tree or print a
    /// submodule commit's whole patch.
    private nonisolated static func gitContent(
        relativePath rel: String,
        ref: String,
        cwd: String,
        maxBytes: UInt64
    ) -> DiffOriginal? {
        let object = "\(ref):\(rel)"
        guard let byteCount = GitCommand.output(["cat-file", "-s", object], cwd: cwd)
            .flatMap({ UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        else { return nil }
        guard byteCount <= maxBytes else { return .tooLarge(byteCount: byteCount) }
        guard let text = GitCommand.output(["cat-file", "blob", object], cwd: cwd) else { return nil }
        // GitCommand reads a blob that isn't UTF-8 as "".
        return text.contains("\0") || text.isEmpty && byteCount > 0 ? .binary : .text(text)
    }
}
