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

    private func setupOsc9Tracking(for col: ColumnState) {
        col.onOsc9Received = { [weak self] in
            guard let self else { return }
            self.hasNotification = true
            self.onMetadataChanged?()
            // Bounce dock icon when app is not active
            if !NSApp.isActive {
                NSApp.requestUserAttention(.informationalRequest)
            }
        }
    }

    private func setupAllTracking(for col: ColumnState) {
        setupCwdTracking(for: col)
        setupTitleTracking(for: col)
        setupOsc9Tracking(for: col)
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

    private func terminalEnvironment() -> [String: String] {
        [
            "NIRUX_PROFILE_ID": profileID,
            "NIRUX_WORKSPACE_ID": id
        ]
    }

    private func insertColumn(_ col: ColumnState) {
        let insertAt = columns.isEmpty ? 0 : min(focusedIndex + 1, columns.count)
        columns.insert(col, at: insertAt)
        stripView.addSubview(col.view)
        focusedIndex = insertAt
    }

    func addColumn() {
        let effectiveCwd = columns[safe: focusedIndex]?.pty?.childCwd ?? cwd
        let col = ColumnState(cwd: effectiveCwd, environment: terminalEnvironment())
        setupAllTracking(for: col)
        insertColumn(col)
    }

    func addColumn(command: String) {
        let effectiveCwd = columns[safe: focusedIndex]?.pty?.childCwd ?? cwd
        let col = ColumnState(cwd: effectiveCwd, command: command, environment: terminalEnvironment())
        setupAllTracking(for: col)
        insertColumn(col)
    }

    func addColumn(webViewURL: String) {
        let col = ColumnState(url: webViewURL)
        insertColumn(col)
    }

    /// Insert a Monaco editor column scoped to the provided cwd, defaulting
    /// to this workspace's original cwd.
    func addEditorColumn(initialFile: String? = nil, workspaceCwd: String? = nil) {
        let col = ColumnState(editorWorkspaceCwd: workspaceCwd ?? cwd)
        insertColumn(col)
        if let initialFile {
            col.editorColumn?.open(path: initialFile)
        }
    }

    func closeColumn(at index: Int) {
        guard columns.count > 1 else { return }
        let col = columns.remove(at: index)
        col.view.removeFromSuperview()
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
                let width = floor(col.widthPreset.fraction * (columnsViewportWidth - totalGaps))
                widths.append(width); totalWidth += width
            }
        }
        totalWidth += totalGaps

        // 2. Position each column with gap
        var xOffset: CGFloat = 0
        for (index, col) in columns.enumerated() {
            // Disable auto-resize BEFORE changing the parent frame to prevent
            // an intermediate terminal resize (which causes garbled display).
            if let terminal = col.terminalView {
                terminal.autoresizingMask = fitAll ? [] : [.width, .height]
            }
            col.view.frame = NSRect(x: xOffset, y: 0, width: widths[index], height: height)
            col.layoutWithTitleBar(width: widths[index], height: height, resizeTerminal: !skipTerminalResize)
            col.view.layer?.masksToBounds = true

            col.view.layer?.cornerRadius = 0
            col.view.layer?.borderWidth = 0
            col.view.layer?.borderColor = nil

            xOffset += widths[index] + gap
        }
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
