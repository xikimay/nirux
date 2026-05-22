import AppKit

/// Sidebar: minimal dots in normal mode, expanded detail panel (pilot-style) in expanded mode.
/// Dragging on empty sidebar area moves the window.
final class SidebarView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    var onWorkspaceClicked: ((Int) -> Void)?
    var onColumnClicked: ((Int, Int) -> Void)?  // (workspaceIndex, columnIndex)
    var onDiffStatsClicked: ((Int) -> Void)?
    var onWorkspaceAction: ((WorkspaceSidebarAction, Int) -> Void)?
    var onProfileClicked: ((String) -> Void)?
    var onCreateProfile: (() -> Void)?
    var isExpanded: Bool = false {
        didSet {
            // Clear dot pulse layers when switching modes
            pulseLayers.forEach { $0.removeFromSuperlayer() }
            pulseLayers.removeAll()
            if !isExpanded { dotsHidden = false }
            // Force redraw to clear old dot content from backing store
            setNeedsDisplay(bounds)
            contentScrollView.isHidden = !isExpanded
            // Reset on collapse so the next expansion re-follows the active
            // workspace instead of staying at whatever offset was left.
            if !isExpanded { lastFollowedActiveIndex = Int.min }
            rebuildContent()
        }
    }

    var lastInfos: [WorkspaceInfo] = []
    var lastProfiles: [ProfileInfo] = []
    var expandedViews: [NSView] = []
    var profileIndicatorView: SidebarDotIndicatorView?
    var clickableAreas: [(frame: NSRect, url: String, label: NSTextField)] = []
    var columnClickAreas: [(frame: NSRect, wsIndex: Int, colIndex: Int)] = []
    var workspaceClickAreas: [(frame: NSRect, wsIndex: Int)] = []

    /// Active workspace the sidebar last auto-scrolled to. Used by
    /// `rebuildContent` so we only follow the active workspace when it
    /// actually changes — not on every periodic refresh, which would yank
    /// the viewport back while the user is dragging the scroller.
    var lastFollowedActiveIndex: Int = Int.min
    private var hoveredLabel: NSTextField?
    private var pulseLayers: [CALayer] = []
    private var trackingArea: NSTrackingArea?

    private static let dotSize: CGFloat = 6
    private static let dotGap: CGFloat = 8
    static let accentColor: NSColor = .niruxAccent
    private static let dimColor = NSColor.white.withAlphaComponent(0.25)
    private static let notifColor = NSColor.systemOrange

    /// Scrollable container for expanded-mode content. In collapsed mode it's
    /// hidden and we just draw dots into the sidebar's own layer.
    let contentScrollView = NSScrollView()
    let contentDocumentView = NSView()

    /// Add a child to the scrollable document view. Used by SidebarView+Rendering
    /// so that rebuilt content scrolls when the workspace list overflows.
    func addSubviewDoc(_ view: NSView) {
        contentDocumentView.addSubview(view)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.14, alpha: 1).cgColor

        contentScrollView.drawsBackground = false
        contentScrollView.hasVerticalScroller = true
        contentScrollView.hasHorizontalScroller = false
        contentScrollView.scrollerStyle = .overlay
        contentScrollView.autohidesScrollers = true
        contentScrollView.documentView = contentDocumentView
        contentScrollView.isHidden = true
        addSubview(contentScrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        contentScrollView.frame = bounds
        if isExpanded { rebuildContent() } else { setNeedsDisplay(bounds) }
    }

    func update(profiles: [ProfileInfo], workspaces: [WorkspaceInfo]) {
        lastProfiles = profiles
        lastInfos = workspaces
        if isExpanded { rebuildContent() } else { setNeedsDisplay(bounds) }
    }

    /// Fade out the collapsed dots, then call completion.
    func fadeOutDots(completion: @escaping () -> Void) {
        // Snapshot the current dot content into a temporary layer
        guard let bitmapRep = bitmapImageRepForCachingDisplay(in: bounds) else {
            completion()
            return
        }
        cacheDisplay(in: bounds, to: bitmapRep)

        let fadeLayer = CALayer()
        fadeLayer.frame = bounds
        fadeLayer.contents = bitmapRep.cgImage
        layer?.addSublayer(fadeLayer)

        // Remove pulse layers immediately (they'd keep pulsing otherwise)
        pulseLayers.forEach { $0.removeFromSuperlayer() }
        pulseLayers.removeAll()
        // Clear the CG-drawn dots so they don't show behind the fade
        dotsHidden = true
        setNeedsDisplay(bounds)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak fadeLayer] in
            fadeLayer?.removeFromSuperlayer()
            completion()
        }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.0
        anim.duration = 0.15
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        fadeLayer.add(anim, forKey: "fadeOut")
        CATransaction.commit()
    }

    private var dotsHidden = false

    // MARK: - Collapsed mode (dots)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Clear previous dot drawing when expanded or during fade
        if isExpanded || dotsHidden {
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.clear(bounds)
            }
            return
        }
        guard !lastInfos.isEmpty,
              let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Remove old pulse layers
        pulseLayers.forEach { $0.removeFromSuperlayer() }
        pulseLayers.removeAll()

        let dotDiameter = Self.dotSize
        let gap = Self.dotGap
        let displayInfos = displayedWorkspaceInfos
        let totalHeight = CGFloat(displayInfos.count) * dotDiameter + CGFloat(displayInfos.count - 1) * gap
        let startY = bounds.midY + totalHeight / 2

        for (position, workspace) in displayInfos.enumerated() {
            let dotY = startY - CGFloat(position) * (dotDiameter + gap) - dotDiameter
            let isFocused = workspace.isActive
            let dotWidth = isFocused ? dotDiameter + 2 : dotDiameter
            let dotX = (bounds.width - dotWidth) / 2

            let hasColumnAttention = workspace.columns.contains { $0.agentStatus == .needsAttention }
            let isNotification = hasColumnAttention || (workspace.hasNotification && !workspace.isActive)

            if isNotification {
                ctx.setFillColor(Self.notifColor.cgColor)
            } else if isFocused {
                ctx.setFillColor(Self.accentColor.cgColor)
            } else {
                ctx.setFillColor(Self.dimColor.cgColor)
            }

            ctx.fillEllipse(in: CGRect(x: dotX, y: dotY - (isFocused ? 1 : 0), width: dotWidth, height: dotWidth))

            // Add pulsing glow ring for notification dots
            if isNotification, let rootLayer = layer {
                let glowSize = dotWidth + 6
                let glow = CALayer()
                glow.frame = CGRect(x: dotX - 3, y: dotY - (isFocused ? 1 : 0) - 3, width: glowSize, height: glowSize)
                glow.cornerRadius = glowSize / 2
                glow.backgroundColor = NSColor.clear.cgColor
                glow.borderWidth = 1.5
                glow.borderColor = Self.notifColor.cgColor

                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1.0
                pulse.toValue = 0.15
                pulse.duration = 0.6
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                glow.add(pulse, forKey: "pulse")

                rootLayer.addSublayer(glow)
                pulseLayers.append(glow)
            }
        }
    }

    // Diff stat formatting, column icons, and attributed column rows are
    // shared with the pilot panel via PilotSidebarRenderer.
    func attributedColumn(_ column: ColumnInfo) -> NSAttributedString {
        PilotSidebarRenderer.attributedColumn(column, fontSize: 11)
    }

    var displayedWorkspaceInfos: [WorkspaceInfo] {
        lastInfos.filter { !$0.isInactive } + lastInfos.filter { $0.isInactive }
    }

    // MARK: - Click handling

    override func mouseDown(with event: NSEvent) {
        if isExpanded {
            // Click areas are registered in the scrollable document view's
            // coordinate space, so we hit-test there (which automatically
            // accounts for the current scroll offset).
            let docLocation = contentDocumentView.convert(event.locationInWindow, from: nil)

            // Check clickable areas first (PR links, CI status, actions)
            for area in clickableAreas where area.frame.contains(docLocation) {
                if let workspaceIndex = Self.diffActionWorkspaceIndex(area.url) {
                    onDiffStatsClicked?(workspaceIndex)
                } else if let url = URL(string: area.url) {
                    NSWorkspace.shared.open(url)
                }
                return
            }

            // Check column click areas
            for area in columnClickAreas where area.frame.contains(docLocation) {
                onColumnClicked?(area.wsIndex, area.colIndex)
                return
            }

            // Hit-test workspace section areas (registered during rendering)
            for area in workspaceClickAreas where area.frame.contains(docLocation) {
                onWorkspaceClicked?(area.wsIndex)
                return
            }
            super.mouseDown(with: event)
            return
        }

        // Collapsed mode: dot hit-test in self's coordinate space.
        let clickLocation = convert(event.locationInWindow, from: nil)
        let dotDiameter = Self.dotSize
        let gap = Self.dotGap
        let displayInfos = displayedWorkspaceInfos
        let totalHeight = CGFloat(displayInfos.count) * dotDiameter + CGFloat(displayInfos.count - 1) * gap
        let startY = bounds.midY + totalHeight / 2

        for (position, workspace) in displayInfos.enumerated() {
            let dotY = startY - CGFloat(position) * (dotDiameter + gap) - dotDiameter
            let hitRect = NSRect(x: 0, y: dotY - 4, width: bounds.width, height: dotDiameter + 8)
            if hitRect.contains(clickLocation) {
                onWorkspaceClicked?(workspace.index)
                return
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: - Hover handling

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard isExpanded else { clearHover(); return }
        let point = contentDocumentView.convert(event.locationInWindow, from: nil)
        for area in clickableAreas where area.frame.contains(point) {
            NSCursor.pointingHand.set()
            if hoveredLabel !== area.label {
                clearHover()
                applyUnderline(to: area.label)
                hoveredLabel = area.label
            }
            return
        }
        // Remove link underline if we left a clickable area
        if let label = hoveredLabel {
            let attr = NSMutableAttributedString(attributedString: label.attributedStringValue)
            attr.removeAttribute(.underlineStyle, range: NSRange(location: 0, length: attr.length))
            label.attributedStringValue = attr
            hoveredLabel = nil
        }
        // Show pointer for column and workspace click areas
        for area in columnClickAreas where area.frame.contains(point) {
            NSCursor.pointingHand.set()
            return
        }
        for area in workspaceClickAreas where area.frame.contains(point) {
            NSCursor.pointingHand.set()
            return
        }
        NSCursor.arrow.set()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let workspaceIndex = workspaceIndex(at: event)
        guard let workspaceIndex else { return super.menu(for: event) }
        let workspace = lastInfos.first { $0.index == workspaceIndex }

        let menu = NSMenu()
        menu.addClosureItem(title: "Move Up") { [weak self] in
            self?.onWorkspaceAction?(.moveUp, workspaceIndex)
        }
        menu.addClosureItem(title: "Move Down") { [weak self] in
            self?.onWorkspaceAction?(.moveDown, workspaceIndex)
        }
        menu.addItem(.separator())
        if workspace?.isInactive == true {
            menu.addClosureItem(title: "Move to Active") { [weak self] in
                self?.onWorkspaceAction?(.markActive, workspaceIndex)
            }
        } else {
            menu.addClosureItem(title: "Move to Inactive") { [weak self] in
                self?.onWorkspaceAction?(.markInactive, workspaceIndex)
            }
        }
        return menu
    }

    private func workspaceIndex(at event: NSEvent) -> Int? {
        if isExpanded {
            let docLocation = contentDocumentView.convert(event.locationInWindow, from: nil)
            if let area = columnClickAreas.first(where: { $0.frame.contains(docLocation) }) {
                return area.wsIndex
            }
            if let area = workspaceClickAreas.first(where: { $0.frame.contains(docLocation) }) {
                return area.wsIndex
            }
            return nil
        }

        let clickLocation = convert(event.locationInWindow, from: nil)
        let dotDiameter = Self.dotSize
        let gap = Self.dotGap
        let displayInfos = displayedWorkspaceInfos
        let totalHeight = CGFloat(displayInfos.count) * dotDiameter + CGFloat(displayInfos.count - 1) * gap
        let startY = bounds.midY + totalHeight / 2

        for (position, workspace) in displayInfos.enumerated() {
            let dotY = startY - CGFloat(position) * (dotDiameter + gap) - dotDiameter
            let hitRect = NSRect(x: 0, y: dotY - 4, width: bounds.width, height: dotDiameter + 8)
            if hitRect.contains(clickLocation) { return workspace.index }
        }
        return nil
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    private func applyUnderline(to label: NSTextField) {
        let attr = NSMutableAttributedString(attributedString: label.attributedStringValue)
        attr.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                          range: NSRange(location: 0, length: attr.length))
        label.attributedStringValue = attr
    }

    private func clearHover() {
        guard let label = hoveredLabel else { return }
        let attr = NSMutableAttributedString(attributedString: label.attributedStringValue)
        attr.removeAttribute(.underlineStyle, range: NSRange(location: 0, length: attr.length))
        label.attributedStringValue = attr
        hoveredLabel = nil
        NSCursor.arrow.set()
    }

    static func diffActionURL(workspaceIndex: Int) -> String {
        "action:diff:\(workspaceIndex)"
    }

    private static func diffActionWorkspaceIndex(_ value: String) -> Int? {
        let prefix = "action:diff:"
        guard value.hasPrefix(prefix) else { return nil }
        return Int(value.dropFirst(prefix.count))
    }
}
