import AppKit
import WebKit

/// A Monaco-backed editor column. WKWebView hosts the Monaco editor; Swift
/// reads/writes files and pushes content over the JS bridge. Each open file
/// has its own Monaco model on the JS side, and the tab bar at the top lets
/// the user switch between them.
@MainActor
final class EditorColumn: NSView, WKNavigationDelegate, WKScriptMessageHandler {
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
    /// Per-tab on-disk mtime as of the last open / external-modification check.
    private var mtimeByPath: [String: Date] = [:]
    /// Tabs whose disk version moved while the buffer was dirty — saving would
    /// clobber the on-disk content.
    private var diskModifiedWhileDirty: Set<String> = []
    /// Path currently shown in diff mode, or nil when the
    /// regular editor is active. Resets on tab switch — diff is per-tab.
    private(set) var diffActivePath: String?
    private(set) var diffActiveMode: EditorDiffMode?
    private var diffModeByPath: [String: EditorDiffMode] = [:]
    private var diffGroupTabs: [String: DiffGroupTab] = [:]
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

    var onPathChanged: (() -> Void)?
    var onDirtyChanged: (() -> Void)?
    var onFilePickerRequest: ((EditorColumn) -> Void)?

    private let webView: WKWebView
    private let tabBar: EditorTabBar
    private let fileTree: EditorFileTree
    private let treeDivider: NSView
    private var monacoReady = false
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
        layer?.backgroundColor = NSColor(red: 0.10, green: 0.11, blue: 0.15, alpha: 1).cgColor

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
        tabBar.onClose = { [weak self] path in self?.close(path: path) }
        addSubview(tabBar)
        refreshTabBar()
    }

    private func setupWebView(config: WKWebViewConfiguration) {
        config.userContentController.add(self, name: "nirux")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = NSColor(red: 0.10, green: 0.11, blue: 0.15, alpha: 1)
        addSubview(webView)
    }

    private func loadEditor() {
        guard let indexURL = Self.findEditorIndex() else {
            // No assets — surface it via the tab bar so the user sees the error.
            tabBar.update(tabs: [.init(path: "Editor assets missing", isDirty: false, title: nil)], activePath: nil)
            return
        }
        let assetsDir = indexURL.deletingLastPathComponent()
        webView.loadFileURL(indexURL, allowingReadAccessTo: assetsDir)
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
        let tabH = EditorTabBar.tabHeight
        let showTree = bounds.width >= Self.treeHideThreshold
        let treeW: CGFloat = showTree ? Self.treeWidth : 0
        let dividerW: CGFloat = showTree ? 1 : 0

        fileTree.isHidden = !showTree
        treeDivider.isHidden = !showTree

        if showTree {
            fileTree.frame = NSRect(x: 0, y: 0, width: treeW, height: bounds.height)
            treeDivider.frame = NSRect(x: treeW, y: 0, width: dividerW, height: bounds.height)
        }

        let editorX = treeW + dividerW
        let editorW = bounds.width - editorX
        tabBar.frame = NSRect(x: editorX, y: bounds.height - tabH, width: editorW, height: tabH)
        webView.frame = NSRect(x: editorX, y: 0, width: editorW, height: bounds.height - tabH)
    }

    // MARK: - Public API

    /// Open a file. If already open, switches to its tab; otherwise creates
    /// a new tab and makes it active. Path may be absolute or relative to
    /// the workspace cwd. When `line` is non-nil the editor jumps to and
    /// centers that line after the model is ready (used by workspace search
    /// to land on the matched line).
    func open(path: String, line: Int? = nil) {
        let absolute = absolutePath(for: path)

        // Already open → just switch.
        if tabPaths.contains(absolute) {
            switchTo(path: absolute)
            if let line { sendBridge(["type": "goToLine", "path": absolute, "line": line]) }
            return
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: absolute)),
              let content = String(data: data, encoding: .utf8)
        else {
            NSLog("[EditorColumn] cannot read \(absolute)")
            return
        }

        openBuffer(path: absolute, content: content, mtime: mtime(of: absolute), line: line)
    }

    private func openDeletedBufferForDiff(path absolute: String, activate: Bool = true) {
        if tabPaths.contains(absolute) {
            if activate {
                switchTo(path: absolute)
            }
            return
        }
        openBuffer(path: absolute, content: "", mtime: nil, line: nil, activate: activate)
    }

    private func openBuffer(
        path absolute: String,
        content: String,
        mtime: Date?,
        line: Int?,
        activate: Bool = true
    ) {
        tabPaths.append(absolute)
        dirtyByPath[absolute] = false
        if let mtime {
            mtimeByPath[absolute] = mtime
        } else {
            mtimeByPath.removeValue(forKey: absolute)
        }
        diskModifiedWhileDirty.remove(absolute)

        if activate {
            activePath = absolute
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
            "activate": activate
        ]
        if let line { payload["line"] = line }
        sendBridge(payload)
        startFileWatch()
    }

    /// Switch the active tab. The model already exists on the JS side; we
    /// only ask Monaco to swap to it.
    func switchTo(path: String) {
        guard tabPaths.contains(path), activePath != path else { return }
        // The JS surface exits the visible diff while switching models. Swift
        // keeps per-tab diff intent and re-enters it after the model swap.
        if diffActivePath != nil {
            diffActivePath = nil
            diffActiveMode = nil
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
        sendBridge(["type": "switchTab", "path": path])
        if let mode = diffModeByPath[path] {
            enterDiff(for: path, mode: mode)
        }
    }

    /// Toggle the visual diff for the active tab. In HEAD mode the
    /// original side reads `git show HEAD:<relpath>`. In Branch mode it reads
    /// the merge-base version of the file so committed branch changes are
    /// included too. Modified side keeps the live buffer so the user can save
    /// edits straight from the diff.
    func toggleDiff() {
        toggleDiff(mode: selectedDiffMode)
    }

    func toggleDiff(mode: EditorDiffMode) {
        selectedDiffMode = mode
        refreshTabBar()
        guard let path = activePath else { return }
        if diffActivePath == path, diffActiveMode == mode {
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
        guard diffActivePath != absolute || diffActiveMode != mode else { return }
        enterDiff(for: absolute, mode: mode)
    }

    func showDiffCollection(title: String, paths: [String], mode: EditorDiffMode) {
        selectedDiffMode = mode
        diffLoadGeneration += 1
        let generation = diffLoadGeneration
        let groupPath = Self.diffGroupPath(mode: mode)
        let cwd = workspaceCwd
        var seen = Set<String>()
        let absolutePaths = paths
            .map { absolutePath(for: $0) }
            .filter { seen.insert($0).inserted }

        guard !absolutePaths.isEmpty else {
            NSSound.beep()
            return
        }

        let loadingGroup = DiffGroupTab(title: title, mode: mode, files: [], isLoading: true)
        diffGroupTabs[groupPath] = loadingGroup
        if !tabPaths.contains(groupPath) {
            tabPaths.append(groupPath)
        }
        activePath = groupPath
        diffActivePath = nil
        diffActiveMode = mode
        refreshTabBar()
        onPathChanged?()
        onDirtyChanged?()
        sendDiffGroup(loadingGroup)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let files = absolutePaths.compactMap { path in
                Self.diffFilePayload(of: path, cwd: cwd, mode: mode)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.diffLoadGeneration == generation else { return }
                guard self.diffGroupTabs[groupPath] != nil else { return }
                guard !files.isEmpty else {
                    NSSound.beep()
                    return
                }
                let group = DiffGroupTab(title: title, mode: mode, files: files, isLoading: false)
                self.diffGroupTabs[groupPath] = group
                self.diffActivePath = nil
                self.diffActiveMode = mode
                self.refreshTabBar()
                if self.activePath == groupPath {
                    self.onPathChanged?()
                    self.onDirtyChanged?()
                    self.sendDiffGroup(group)
                }
            }
        }
    }

    private func exitDiff() {
        diffLoadGeneration += 1
        diffActivePath = nil
        diffActiveMode = nil
        refreshTabBar()
        sendBridge(["type": "exitDiff"])
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
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: absolute)),
                  let content = String(data: data, encoding: .utf8)
            else {
                NSLog("[EditorColumn] cannot read \(absolute)")
                return false
            }
            openBuffer(path: absolute, content: content, mtime: mtime(of: absolute), line: nil, activate: activate)
        } else {
            openDeletedBufferForDiff(path: absolute, activate: activate)
        }
        return true
    }

    private func sendDiffGroup(_ group: DiffGroupTab) {
        sendBridge([
            "type": "enterDiffGroup",
            "title": group.title,
            "mode": group.mode.rawValue,
            "loading": group.isLoading,
            "files": group.files
        ])
    }

    private func enterDiff(for path: String, mode: EditorDiffMode) {
        diffLoadGeneration += 1
        let generation = diffLoadGeneration
        let cwd = workspaceCwd
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let original = Self.gitOriginalContent(of: path, cwd: cwd, mode: mode)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.diffLoadGeneration == generation else { return }
                guard self.activePath == path else { return } // stale request
                if original == nil {
                    NSLog("[EditorColumn] no git \(mode.rawValue) content for \(path) — file untracked, git missing, or branch base unavailable")
                    NSSound.beep()
                    return
                }
                self.diffActivePath = path
                self.diffActiveMode = mode
                self.refreshTabBar()
                self.sendBridge(["type": "enterDiff", "path": path, "original": original ?? ""])
            }
        }
    }

    private func absolutePath(for path: String) -> String {
        (path as NSString).isAbsolutePath
            ? path
            : (workspaceCwd as NSString).appendingPathComponent(path)
    }

    /// Reads the comparison-side content for the requested diff mode.
    /// Nonisolated so we can call it from a background queue.
    private nonisolated static func gitOriginalContent(
        of absPath: String,
        cwd: String,
        mode: EditorDiffMode
    ) -> String? {
        guard let rel = relativeGitPath(of: absPath, cwd: cwd) else { return nil }
        switch mode {
        case .head:
            if let content = gitContent(relativePath: rel, ref: "HEAD", cwd: cwd) {
                return content
            }
            // New or untracked files have no blob in HEAD. Treat them as an
            // empty original so clicking a change always opens a useful diff.
            return FileManager.default.fileExists(atPath: absPath) ? "" : nil
        case .branch:
            guard let base = branchBaseRef(cwd: cwd) else { return nil }
            // A file added on the branch has no blob at the merge-base; an
            // empty original gives Monaco the expected "whole file added" diff.
            return gitContent(relativePath: rel, ref: base, cwd: cwd) ?? ""
        }
    }

    private nonisolated static func relativeGitPath(of absPath: String, cwd: String) -> String? {
        let cwdPath = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let absolutePath = URL(fileURLWithPath: absPath).standardizedFileURL.path
        guard absolutePath == cwdPath || absolutePath.hasPrefix(cwdPath + "/") else { return nil }
        let rel = String(absolutePath.dropFirst(cwdPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !rel.isEmpty else { return nil }
        return rel
    }

    private nonisolated static func diffGroupPath(mode: EditorDiffMode) -> String {
        "\(diffGroupPathPrefix)\(mode.rawValue)"
    }

    private nonisolated static func isDiffGroupPath(_ path: String) -> Bool {
        path.hasPrefix(diffGroupPathPrefix)
    }

    private nonisolated static func diffFilePayload(
        of absPath: String,
        cwd: String,
        mode: EditorDiffMode
    ) -> [String: Any]? {
        guard let rel = relativeGitPath(of: absPath, cwd: cwd) else { return nil }
        if let largePayload = largeDiffPlaceholderPayload(of: absPath, relativePath: rel) {
            return largePayload
        }
        guard let original = gitOriginalContent(of: absPath, cwd: cwd, mode: mode) else { return nil }
        let modified = fileContent(at: absPath) ?? ""
        return [
            "path": rel,
            "name": rel,
            "original": original,
            "modified": modified
        ]
    }

    private nonisolated static func largeDiffPlaceholderPayload(
        of absPath: String,
        relativePath rel: String
    ) -> [String: Any]? {
        guard let byteCount = diffCollectionFileByteCount(path: absPath),
              byteCount > maxDiffCollectionFileBytes
        else { return nil }
        NSLog("[EditorColumn] replacing large visual diff file \(absPath) (\(byteCount) bytes)")
        return [
            "path": rel,
            "name": rel,
            "original": "",
            "modified": "Large file omitted from visual diff (\(byteCount) bytes).",
            "language": "plaintext"
        ]
    }

    private nonisolated static func diffCollectionFileByteCount(path: String) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber
        else { return nil }
        return size.uint64Value
    }

    private nonisolated static func fileContent(at path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func gitContent(relativePath rel: String, ref: String, cwd: String) -> String? {
        guard let result = runGit(["show", "\(ref):\(rel)"], cwd: cwd),
              result.status == 0
        else { return nil }
        return result.output
    }

    private nonisolated static func branchBaseRef(cwd: String) -> String? {
        for candidate in ["@{upstream}", "origin/main", "origin/master", "main", "master"] {
            guard let result = runGit(["merge-base", "HEAD", candidate], cwd: cwd),
                  result.status == 0
            else { continue }
            let sha = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty { return sha }
        }
        return nil
    }

    private nonisolated static func runGit(_ arguments: [String], cwd: String) -> (status: Int32, output: String)? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Close a tab. Disposes its Monaco model and switches focus to a
    /// neighbor if the closed tab was active.
    func close(path: String) {
        guard let index = tabPaths.firstIndex(of: path) else { return }
        let isDiffGroup = Self.isDiffGroupPath(path)
        let wasActive = activePath == path
        tabPaths.remove(at: index)
        if isDiffGroup {
            diffLoadGeneration += 1
        }
        dirtyByPath.removeValue(forKey: path)
        mtimeByPath.removeValue(forKey: path)
        diskModifiedWhileDirty.remove(path)
        diffModeByPath.removeValue(forKey: path)
        diffGroupTabs.removeValue(forKey: path)
        if diffActivePath == path {
            diffLoadGeneration += 1
            diffActivePath = nil
            diffActiveMode = nil
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
                    sendBridge(["type": "switchTab", "path": next])
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
    private func reloadFromDisk(path: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let content = String(data: data, encoding: .utf8)
        else { return }

        mtimeByPath[path] = mtime(of: path)
        diskModifiedWhileDirty.remove(path)
        refreshTabBar()
        sendBridge(["type": "openFile", "path": path, "content": content])
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
        for path in openPaths {
            guard let last = mtimeByPath[path] else { continue }
            guard let now = mtime(of: path) else { continue }
            guard now > last else { continue }

            let isDirtyHere = dirtyByPath[path] ?? false
            if isDirtyHere {
                if !diskModifiedWhileDirty.contains(path) {
                    diskModifiedWhileDirty.insert(path)
                    mtimeByPath[path] = now
                    refreshTabBar()
                }
            } else {
                reloadFromDisk(path: path)
            }
        }
    }

    private func mtime(of path: String) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.modificationDate] as? Date
    }

    // MARK: - JS bridge

    private func sendBridge(_ payload: [String: Any]) {
        let send = { [weak self] in
            guard let self else { return }
            guard let json = try? JSONSerialization.data(withJSONObject: payload),
                  let jsonStr = String(data: json, encoding: .utf8)
            else { return }
            let escaped = jsonStr
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")
            let js = "window.niruxBridge.handle(`\(escaped)`)"
            self.webView.evaluateJavaScript(js, completionHandler: nil)
        }
        if monacoReady { send() } else { pendingOps.append(send) }
    }

    /// Persist a buffer to disk. Path comes from JS but we only honor saves
    /// for tabs we're actually tracking, so a compromised page can't redirect
    /// writes outside our open set.
    private func handleSave(body: [String: Any]) {
        guard let path = body["path"] as? String,
              openPaths.contains(path),
              let content = body["content"] as? String
        else { return }

        let url = URL(fileURLWithPath: path)
        do {
            try content.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            NSLog("[EditorColumn] save failed for \(path): \(error)")
            return
        }

        // Refresh the watcher's mtime baseline so we don't immediately re-detect
        // our own atomic-write as an external modification.
        mtimeByPath[path] = mtime(of: path)
        diskModifiedWhileDirty.remove(path)

        // Tell JS the buffer is now clean for this path.
        sendBridge(["type": "markSaved", "path": path])
        fileTree.reloadGitChanges()
    }

    private func refreshTabBar() {
        let bars: [EditorTabBar.Tab] = tabPaths.map { path in
            let dirty = (dirtyByPath[path] ?? false) || diskModifiedWhileDirty.contains(path)
            return EditorTabBar.Tab(path: path, isDirty: dirty, title: diffGroupTabs[path]?.title)
        }
        tabBar.update(tabs: bars, activePath: activePath)
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Monaco loads asynchronously after navigation finishes; we wait for the
        // "monacoReady" bridge message to actually push content.
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
            monacoReady = true
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
        case "save":
            handleSave(body: body)
        case "filePickerRequest":
            onFilePickerRequest?(self)
        case "ready":
            // Monaco confirmed model swap; nothing to do.
            break
        case "error":
            if let msg = body["message"] as? String {
                NSLog("[EditorColumn] bridge error: \(msg)")
            }
        default:
            break
        }
    }
}

private struct DiffGroupTab {
    let title: String
    let mode: EditorDiffMode
    let files: [[String: Any]]
    let isLoading: Bool
}
