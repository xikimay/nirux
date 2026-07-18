import AppKit

/// A clickable area in the pilot info panel
struct PilotClickableArea {
    let frame: NSRect
    let url: String
    let label: NSTextField
}

/// A workspace contains columns on an infinite horizontal strip
@MainActor
final class WorkspaceState {
    let id: String
    let containerView: NSView  // clips content, acts as viewport
    private let stripView: NSView  // holds all columns, slides horizontally
    var columns: [ColumnState] = []
    var focusedIndex: Int = 0
    private var lastCameraX: CGFloat = 0
    let cwd: String
    var title: String
    var titleIsManual: Bool = false
    var profileID: String = WorkspaceProfile.defaultID
    var isInactive: Bool = false
    var gitBranch: String?
    var hasNotification: Bool = false
    var prInfo: PRInfo?
    var diffStats: String?

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
    var onDiffStatsClicked: (() -> Void)?
    /// A terminal link was cmd-clicked — the shell opens a browser column
    /// in this workspace.
    var onTerminalOpenURL: ((WorkspaceState, String) -> Void)?

    init(
        id: String = UUID().uuidString,
        title: String? = nil,
        cwd: String,
        profileID: String = WorkspaceProfile.defaultID
    ) {
        self.id = id
        self.cwd = cwd
        self.title = title ?? "workspace"
        self.titleIsManual = (title != nil)
        self.profileID = profileID

        containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.masksToBounds = true

        stripView = NSView()
        stripView.wantsLayer = true
        containerView.addSubview(stripView)

        addColumn()
    }

    // MARK: - CWD / Git / Title Tracking

    private func setupCwdTracking(for col: ColumnState) {
        col.onCwdChanged = { [weak self] path in
            GitDetect.branchAsync(at: path) { [weak self] branch in
                guard let self else { return }
                self.gitBranch = branch
                // Auto-name workspace from branch (manual rename takes precedence)
                if !self.titleIsManual, let branch, !branch.isEmpty {
                    self.title = branch
                }
                self.onMetadataChanged?()
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
    }

    private func setupAllTracking(for col: ColumnState) {
        setupCwdTracking(for: col)
        setupTitleTracking(for: col)
        setupAgentAttentionTracking(for: col)
        setupLinkOpening(for: col)
    }

    func detectGitBranch() {
        // Use the shell's actual cwd (follows cd), not the initial cwd
        let detectPath: String
        if let col = columns.first, let realCwd = col.pty?.childCwd {
            detectPath = realCwd
        } else {
            detectPath = cwd
        }
        GitDetect.branchAsync(at: detectPath) { [weak self] branch in
            guard let self else { return }
            self.gitBranch = branch
            if !self.titleIsManual, let branch, !branch.isEmpty {
                self.title = branch
            }
        }
    }

    // MARK: - Column Management

    private func terminalEnvironment(agentUUID: String) -> [String: String] {
        [
            "NIRUX_PROFILE_ID": profileID,
            "NIRUX_WORKSPACE_ID": id,
            // Hook events carry this back — see AgentHookCenter.
            "NIRUX_AGENT_UUID": agentUUID
        ]
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
            self.focusedIndex = index
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
        let effectiveCwd = columns[safe: focusedIndex]?.pty?.childCwd ?? cwd
        let col = ColumnState(cwd: effectiveCwd, environment: terminalEnvironment(agentUUID: agentUUID))
        setupAllTracking(for: col)
        insertColumn(col)
    }

    func addColumn(command: String, agentUUID: String = UUID().uuidString) {
        let effectiveCwd = columns[safe: focusedIndex]?.pty?.childCwd ?? cwd
        let col = ColumnState(cwd: effectiveCwd, command: command, environment: terminalEnvironment(agentUUID: agentUUID))
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
        let col = columns.remove(at: index)
        col.view.removeFromSuperview()
        if resizeHandles.indices.contains(index) {
            let handle = resizeHandles.remove(at: index)
            handle.removeFromSuperview()
        }
        if focusedIndex >= columns.count {
            focusedIndex = columns.count - 1
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

        NiruxDebugLog.log("layoutAndScroll ws=\(id.prefix(8)) viewportW=\(viewportWidth) h=\(height) widths=\(widths.map { Int($0) }) fitAll=\(fitAll)")

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
