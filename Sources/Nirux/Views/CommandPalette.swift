import AppKit

/// Action item in the command palette
struct PaletteAction {
    let icon: PaletteIcon
    let title: String
    let subtitle: String
    /// Shown on the right. Only table chords, so every label is bound.
    let shortcut: NiruxShortcuts?
    /// What the search matches and how the row ranks; nil: its title, then
    /// its subtitle. A workspace's title, branch, space and folder, inactive
    /// ones below the active ones that match as well.
    var ranking: PaletteRanking.Candidate?
    /// Shown on the right instead of a shortcut: a workspace's agent state.
    var badge: PaletteBadge?
    /// The title dimmed: an inactive workspace.
    var isDimmed = false
    /// Return leaves the palette open: the row that unfolds a section.
    var keepsPaletteOpen = false
    let action: () -> Void

    var rankingCandidate: PaletteRanking.Candidate {
        ranking ?? PaletteRanking.Candidate(title: title, keys: [subtitle])
    }
}

/// A short colored label on the right of a row.
struct PaletteBadge: Equatable {
    enum Tone { case working, waiting, failure }
    let text: String
    let tone: Tone

    var color: NSColor {
        switch tone {
        case .working: return .systemGreen
        case .waiting: return Theme.Color.waiting
        case .failure: return .systemRed
        }
    }
}

/// Rows listed under their own header beside the actions: the active
/// space's workspaces and sessions, the other spaces' workspaces (see
/// `NiruxShellView.paletteSections`).
struct PaletteSection {
    let title: String
    let rows: [PaletteAction]
    /// Listed above the actions when nothing is typed (see
    /// `PaletteRanking.Group`).
    var leadsWhenEmpty = false
    /// Ranked as one section with the one before it, then listed apart
    /// (see `PaletteRanking.Group`).
    var ranksWithPrevious = false
    /// Listed folded unless it comes first (see `PaletteRanking.Group`).
    var folds = false
    /// With nothing typed, its first rows only, the rest folded (see
    /// `PaletteRanking.Group`).
    var emptyQueryLimit: Int?
    /// What the row standing for its folded rows says. Without it, a
    /// section lists every row.
    var fold: PaletteFold?
}

/// What the row standing for a section's folded rows says. Picking it
/// unfolds them.
struct PaletteFold {
    struct Summary: Equatable {
        let title: String
        let subtitle: String
        var badge: PaletteBadge?
    }

    /// The summary of the rows folded, given their indices in the
    /// section's rows: a query folds only its matches.
    let summary: ([Int]) -> Summary
}

/// Raycast-style command palette — Cmd+P to open
@MainActor
final class CommandPalette: NSObject {
    /// The commands, searched with `sections`.
    var actions: [PaletteAction] = []
    /// Ranked with the actions (see `PaletteRanking.list`); each section
    /// and the actions then show a header. Empty for a palette listing one
    /// kind of row (Open Worktree). Set by `show`.
    private(set) var sections: [PaletteSection] = []
    static let actionsSectionTitle = "Actions"
    /// Folding sections the user unfolded since the palette opened, by
    /// index in `allSections`.
    private var unfoldedSections: Set<Int> = []
    /// Called when user submits a URL in browser mode
    var onURLSubmit: ((String) -> Void)?

    enum Mode { case actions, urlInput }
    var mode: Mode = .actions
    var onDismiss: (() -> Void)?

    var panel: NSPanel?
    var searchField: NSTextField?
    var fieldContainer: NSView?
    var separator: NSView?
    var listContainer: NSView?
    var rowViews: [NSView] = []
    /// The rows the query matches, in display order: what the arrow keys
    /// walk and Return runs.
    var filteredActions: [PaletteAction] = []
    /// Where the headers and rows of `filteredActions` sit (actions mode).
    private(set) var listLayout = PaletteListLayout(items: [])
    var selectedIndex = 0
    var scrollY: CGFloat = 0
    var scrollIndicator: NSView?
    var urlSuggestions: [String] = []
    var urlSelectedIndex = 0
    /// Dev-server URLs detected in the active workspace's terminals —
    /// listed first in URL mode. Static: set once by the shell, whichever
    /// code path creates the palette.
    static var detectedURLsProvider: (() -> [String])?
    var detectedURLs: Set<String> = []

    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var moveMonitor: Any?
    private var scrollMonitor: Any?

    func show(relativeTo window: NSWindow, sections: [PaletteSection] = []) {
        if panel == nil { createPanel() }
        guard let panel, let searchField else { return }

        self.sections = sections
        unfoldedSections = []

        // Return on a URL, or a click outside, closes the palette still in
        // URL mode: it would read the next commands typed as a URL.
        mode = .actions
        searchField.placeholderString = actionsPlaceholder

        let windowFrame = window.frame
        let panelWidth: CGFloat = 520
        let panelHeight: CGFloat = 340
        let xPos = windowFrame.origin.x + (windowFrame.width - panelWidth) / 2
        let yPos = windowFrame.origin.y + windowFrame.height * 0.55
        panel.setFrame(NSRect(x: xPos, y: yPos, width: panelWidth, height: panelHeight), display: true)

        searchField.stringValue = ""
        filterActions(query: "")
        installMonitors()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)

        // Opening animation: scale from 0.96 → 1.0
        panel.contentView?.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.96, y: 0.96))
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.contentView?.layer?.setAffineTransform(.identity)
        }
    }

    /// Apply a prefilter to an already-visible palette without re-showing
    func applyPrefilter(_ query: String) {
        searchField?.stringValue = query
        filterActions(query: query)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// The drag and release of a press the palette took: AppKit would hand
    /// them to the view of the window's last click (a terminal would read
    /// a release it never saw pressed). A monitor of its own (`dismiss`
    /// removes the palette's), gone at the release, or at the next press
    /// should the release never come.
    static func swallowRestOfClick() {
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .leftMouseDown]) { event in
            if event.type != .leftMouseDragged, let installed = monitor {
                NSEvent.removeMonitor(installed)
                monitor = nil
            }
            return event.type == .leftMouseDown ? event : nil
        }
    }

    /// A press on the title bar's Search button (`TitleBarActions`) while
    /// the palette shows: it closes the palette here, on mouse-down, and
    /// is consumed, or the button would open it again on mouse-up.
    static func isSearchButtonPress(_ event: NSEvent) -> Bool {
        guard let frameView = event.window?.contentView?.superview else { return false }
        let hit = frameView.hitTest(frameView.convert(event.locationInWindow, from: nil))
        return hit?.identifier == TitleBarActions.searchButtonID
    }

    func dismiss() {
        removeMonitors()
        panel?.orderOut(nil)
        onDismiss?()
    }

    // MARK: - Panel creation

    private func createPanel() {
        let palettePanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        palettePanel.titlebarAppearsTransparent = true
        palettePanel.titleVisibility = .hidden
        palettePanel.isMovable = false
        palettePanel.level = .floating
        palettePanel.backgroundColor = .clear
        palettePanel.isOpaque = false
        palettePanel.hasShadow = true
        palettePanel.appearance = Theme.appearance
        palettePanel.becomesKeyOnlyIfNeeded = false
        palettePanel.acceptsMouseMovedEvents = true

        let background = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 340))
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.backgroundColor = Theme.Color.base.withAlphaComponent(0.98).cgColor
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        background.layer?.masksToBounds = true

        // Search field
        let fieldContainer = NSView(frame: NSRect(x: 0, y: 340 - 44, width: 520, height: 44))
        fieldContainer.wantsLayer = true
        fieldContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.03).cgColor

        fieldContainer.addSubview(PaletteIconView(.symbol("command"), frame: NSRect(x: 14, y: 10, width: 24, height: 24)))

        let field = NSTextField()
        field.font = .systemFont(ofSize: 15, weight: .regular)
        field.textColor = .white
        field.backgroundColor = .clear
        field.isBezeled = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.placeholderString = "Type a command..."
        field.frame = NSRect(x: 42, y: 10, width: 460, height: 24)
        field.delegate = self
        fieldContainer.addSubview(field)

        background.addSubview(fieldContainer)
        self.fieldContainer = fieldContainer

        // Separator
        let separatorView = NSView(frame: NSRect(x: 0, y: 340 - 45, width: 520, height: 1))
        separatorView.wantsLayer = true
        separatorView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        background.addSubview(separatorView)
        self.separator = separatorView

        // List container (scrollable area)
        let list = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 340 - 46))
        list.wantsLayer = true
        background.addSubview(list)
        list.layer?.masksToBounds = true

        // Scroll indicator
        let indicator = NSView(frame: NSRect(x: 520 - 6, y: 0, width: 3, height: 40))
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        indicator.layer?.cornerRadius = 1.5
        indicator.isHidden = true
        list.addSubview(indicator)

        // Tracking area for mouseMoved events
        let trackingArea = NSTrackingArea(
            rect: background.bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: background
        )
        background.addTrackingArea(trackingArea)

        palettePanel.contentView = background
        panel = palettePanel
        searchField = field
        listContainer = list
        scrollIndicator = indicator
    }

    // MARK: - Event Monitors

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyInPalette(event)
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window !== panel {
                self.dismiss()
                if Self.isSearchButtonPress(event) {
                    Self.swallowRestOfClick()
                    return nil
                }
            } else if let index = self.rowIndexAtEvent(event) {
                self.handleMouseClick(index)
            }
            return event
        }
        moveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            if let index = self.rowIndexAtEvent(event) {
                self.handleMouseHover(index)
            }
            return event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            self.handleScrollWheel(event)
            return event
        }
    }

    private func removeMonitors() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor); clickMonitor = nil }
        if let monitor = moveMonitor { NSEvent.removeMonitor(monitor); moveMonitor = nil }
        if let monitor = scrollMonitor { NSEvent.removeMonitor(monitor); scrollMonitor = nil }
    }

    // MARK: - Mouse

    private func rowIndexAtEvent(_ event: NSEvent) -> Int? {
        guard let listContainer, let contentView = panel?.contentView else { return nil }
        let locInContent = contentView.convert(event.locationInWindow, from: nil)
        return row(atListPoint: listContainer.convert(locInContent, from: contentView))
    }

    /// The row under `point`, in the list's coordinates: nil on a header.
    func row(atListPoint point: NSPoint) -> Int? {
        guard let listContainer, listContainer.bounds.contains(point) else { return nil }
        // From the top of the list's content.
        let contentY = listContainer.bounds.height + scrollY - point.y
        guard mode == .urlInput else { return listLayout.row(atContentY: contentY) }
        let index = Int(floor(contentY / Self.urlRowHeight))
        return urlSuggestions.indices.contains(index) ? index : nil
    }

    private func handleMouseHover(_ index: Int) {
        if mode == .urlInput {
            urlSelectedIndex = index
            highlightURLSelected()
        } else {
            selectedIndex = index
            highlightSelected(animated: false)
        }
    }

    private func handleMouseClick(_ index: Int) {
        if mode == .urlInput {
            urlSelectedIndex = index
            let url = urlSuggestions[index]
            addURLToHistory(url)
            dismiss()
            onURLSubmit?(url)
        } else {
            selectedIndex = index
            run(filteredActions[index])
        }
    }

    /// Runs a picked row, then closes the palette, unless the row switched
    /// it to URL input or unfolded a section.
    private func run(_ action: PaletteAction) {
        action.action()
        if mode == .actions && !action.keepsPaletteOpen { dismiss() }
    }

    private func handleScrollWheel(_ event: NSEvent) {
        guard let listContainer else { return }
        let maxScrollY = max(0, contentHeight - listContainer.bounds.height)
        scrollY = max(0, min(scrollY - event.scrollingDeltaY, maxScrollY))
        positionRows()
        updateScrollIndicator()
    }

    // MARK: - List

    static let urlRowHeight: CGFloat = 36

    /// The height of what the list scrolls through.
    private var contentHeight: CGFloat {
        mode == .urlInput ? CGFloat(urlSuggestions.count) * Self.urlRowHeight : listLayout.totalHeight
    }

    /// Places the list's views for the scroll offset. Masking clips the
    /// rows past the list's edges: the peek effect.
    func positionRows(animated: Bool = false) {
        guard let listContainer else { return }
        let containerHeight = listContainer.bounds.height
        for (index, view) in rowViews.enumerated() {
            let top: CGFloat
            let height: CGFloat
            if mode == .urlInput {
                (top, height) = (CGFloat(index) * Self.urlRowHeight, Self.urlRowHeight)
            } else {
                guard listLayout.tops.indices.contains(index) else { continue }
                (top, height) = (listLayout.tops[index], listLayout.heights[index])
            }
            let yPos = containerHeight - top - height + scrollY
            if animated { view.animator().frame.origin.y = yPos } else { view.frame.origin.y = yPos }
        }
    }

    func updateScrollIndicator() {
        guard let indicator = scrollIndicator, let listContainer else { return }
        let containerHeight = listContainer.bounds.height
        let totalHeight = contentHeight
        let maxScrollY = max(0, totalHeight - containerHeight)
        indicator.isHidden = maxScrollY <= 0
        guard maxScrollY > 0 else { return }
        let barHeight = max(20, containerHeight * containerHeight / totalHeight)
        let travel = containerHeight - barHeight
        let barY = travel - (scrollY / maxScrollY) * travel
        indicator.frame = NSRect(x: listContainer.bounds.width - 6, y: barY, width: 3, height: barHeight)
    }

    private func rebuildList() {
        guard let listContainer else { return }
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()
        scrollY = 0

        for (index, item) in listLayout.items.enumerated() {
            let frame = NSRect(x: 0, y: 0, width: listContainer.bounds.width, height: listLayout.heights[index])
            let view: NSView
            switch item {
            case .header(let title): view = Self.headerView(title, frame: frame)
            case .row(let row): view = Self.rowView(filteredActions[row], frame: frame)
            }
            listContainer.addSubview(view)
            rowViews.append(view)
        }

        highlightSelected(animated: false)
    }

    /// Where rows and header labels start from the list's edges.
    static let listInset = Theme.Space.sm
    /// Less than this, and a row leaves its subtitle out.
    static let minimumSubtitleWidth: CGFloat = 48

    private static func headerView(_ title: String, frame: NSRect) -> NSView {
        let header = NSView(frame: frame)
        // An attributed label wraps by its string's paragraph style: a long
        // space name would drop below the frame instead of truncating.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let label = NSTextField(labelWithAttributedString: NSAttributedString(string: title.uppercased(), attributes: [
            .font: Theme.Font.label, .foregroundColor: Theme.Color.textTertiary, .kern: Theme.Font.labelKern,
            .paragraphStyle: paragraph
        ]))
        label.maximumNumberOfLines = 1
        label.frame = NSRect(x: listInset + Theme.Space.sm, y: 2, width: frame.width - 2 * (listInset + Theme.Space.sm), height: 14)
        header.addSubview(label)
        return header
    }

    /// One line, as the October visual system draws palette rows: the
    /// icon, the title, the subtitle after it in a quieter color, then the
    /// badge or the shortcut on the right, all on the title's baseline.
    private static func rowView(_ action: PaletteAction, frame: NSRect) -> NSView {
        let row = NSView(frame: frame.insetBy(dx: listInset, dy: 0))
        row.wantsLayer = true
        row.layer?.cornerRadius = Theme.Radius.control
        let width = row.frame.width
        let height = row.frame.height
        let padding = Theme.Space.sm

        // Centered on a 16 pt slot. Symbols draw at their own size, in a
        // view 20 wide so wide ones (</>) aren't clipped; app icons scale to
        // the slot.
        let iconSide: CGFloat = if case .image = action.icon { 16 } else { 20 }
        row.addSubview(PaletteIconView(action.icon, frame: NSRect(
            x: padding + 8 - iconSide / 2, y: (height - iconSide) / 2, width: iconSide, height: iconSide
        )))
        let textLeft = padding + 16 + Theme.Space.sm
        let titleFrame = NSRect(x: textLeft, y: (height - 18) / 2, width: 0, height: 18)
        // Labels draw from their top: one whose top sits a font's ascender
        // above this line shares the title's baseline.
        let baseline = titleFrame.maxY - Theme.Font.title.ascender
        func onBaseline(_ label: NSTextField, x: CGFloat, width: CGFloat) {
            // On the pixel grid of a 2x screen: text off it renders soft.
            let top = ((baseline + (label.font?.ascender ?? 0)) * 2).rounded() / 2
            label.frame = NSRect(x: x, y: top - 16, width: width, height: 16)
        }

        // Right side: the badge, else the shortcut.
        var textRight = width - padding
        let accessory: NSTextField?
        if let badge = action.badge {
            accessory = NSTextField(labelWithString: badge.text)
            accessory?.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            accessory?.textColor = badge.color
        } else if let chord = action.shortcut?.chord {
            accessory = NSTextField(labelWithString: chord.display)
            accessory?.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            accessory?.textColor = Theme.Color.textTertiary
        } else {
            accessory = nil
        }
        if let accessory {
            let accessoryWidth = ceil(accessory.cell?.cellSize.width ?? 0)
            onBaseline(accessory, x: width - padding - accessoryWidth, width: accessoryWidth)
            row.addSubview(accessory)
            textRight = accessory.frame.minX - Theme.Space.md
        }
        let textWidth = max(0, textRight - textLeft)

        let title = NSTextField(labelWithString: action.title)
        title.font = Theme.Font.title
        title.textColor = action.isDimmed ? Theme.Color.textSecondary : Theme.Color.textPrimary
        title.lineBreakMode = .byTruncatingTail
        // The title comes first: the subtitle takes what it leaves, when
        // that's enough to read something.
        title.frame = titleFrame
        title.frame.size.width = min(ceil(title.cell?.cellSize.width ?? 0), textWidth)
        row.addSubview(title)

        let subtitleLeft = title.frame.maxX + Theme.Space.xs
        if !action.subtitle.isEmpty, textLeft + textWidth - subtitleLeft >= Self.minimumSubtitleWidth {
            let subtitle = NSTextField(labelWithString: action.subtitle)
            subtitle.font = Theme.Font.body
            subtitle.textColor = Theme.Color.textTertiary
            // Keeps both ends: a workspace's branch and its folder's name.
            subtitle.lineBreakMode = .byTruncatingMiddle
            onBaseline(subtitle, x: subtitleLeft, width: textLeft + textWidth - subtitleLeft)
            row.addSubview(subtitle)
        }

        return row
    }

    func highlightSelected(animated: Bool = true) {
        guard let listContainer else { return }
        let containerHeight = listContainer.bounds.height
        let maxScrollY = max(0, listLayout.totalHeight - containerHeight)

        // Ensure the selected row is fully visible — with its section's
        // header, when it's the first row under one.
        let oldScrollY = scrollY
        if let span = listLayout.visibleSpan(ofRow: selectedIndex) {
            if span.top < scrollY { scrollY = span.top }
            if span.bottom > scrollY + containerHeight { scrollY = span.bottom - containerHeight }
        }
        scrollY = max(0, min(scrollY, maxScrollY))

        if animated && oldScrollY != scrollY {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.positionRows(animated: true)
            }
        } else {
            positionRows()
        }

        // Highlight
        let accent = Theme.Color.fillSelected
        let selectedItem = listLayout.itemIndex(ofRow: selectedIndex)
        for (index, view) in rowViews.enumerated() {
            view.layer?.backgroundColor = (index == selectedItem) ? accent.cgColor : NSColor.clear.cgColor
            for case let icon as PaletteIconView in view.subviews {
                icon.setSelected(index == selectedItem)
            }
        }

        updateScrollIndicator()
    }

    // MARK: - Keyboard

    private func handleKeyInPalette(_ event: NSEvent) -> NSEvent? {
        if mode == .urlInput {
            return handleKeyInURLMode(event)
        }
        return handleKeyInActionsMode(event)
    }

    private func handleKeyInActionsMode(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 0x7E: // Up
            if selectedIndex > 0 { selectedIndex -= 1; highlightSelected() }
            return nil
        case 0x7D: // Down
            if selectedIndex < filteredActions.count - 1 { selectedIndex += 1; highlightSelected() }
            return nil
        case 0x24: // Enter
            if filteredActions.indices.contains(selectedIndex) { run(filteredActions[selectedIndex]) }
            return nil
        case 0x35: // Escape
            dismiss()
            return nil
        default:
            return event
        }
    }

    // MARK: - Filtering

    var actionsPlaceholder: String {
        sections.isEmpty ? "Type a command..." : "Type a command, a workspace or a session..."
    }

    /// The actions, first: at equal standing a query ranks them above the
    /// sections (see `PaletteRanking.rank`).
    private var allSections: [PaletteSection] {
        [PaletteSection(title: Self.actionsSectionTitle, rows: actions)] + sections
    }

    /// Lists what `query` matches (see `PaletteRanking.list`), the first
    /// row selected. Titles match above subtitles; fuzzy scoring keeps
    /// acronym-style queries ("nt" → "New Terminal") working.
    func filterActions(query: String) {
        // Don't filter actions when in URL mode — user is typing a URL
        guard mode == .actions else { return }

        let all = allSections
        // "billing " still finds billing-fix; "new t" keeps its space.
        let query = query.trimmingCharacters(in: .whitespaces)
        let groups = all.map {
            PaletteRanking.Group(
                candidates: $0.rows.map(\.rankingCandidate), leadsWhenEmpty: $0.leadsWhenEmpty,
                ranksWithPrevious: $0.ranksWithPrevious,
                folds: $0.fold != nil && $0.folds, emptyQueryLimit: $0.fold == nil ? nil : $0.emptyQueryLimit
            )
        }
        var items: [PaletteListLayout.Item] = []
        var rows: [PaletteAction] = []
        for listed in PaletteRanking.list(query: query, groups: groups, unfolded: unfoldedSections) {
            let section = all[listed.section]
            if !sections.isEmpty { items.append(.header(section.title)) }
            for row in listed.rows {
                items.append(.row(rows.count))
                rows.append(section.rows[row])
            }
            if !listed.folded.isEmpty, let fold = section.fold {
                items.append(.row(rows.count))
                rows.append(foldedRow(fold.summary(listed.folded), unfolding: listed.section, at: rows.count))
            }
        }
        filteredActions = rows
        listLayout = PaletteListLayout(items: items)
        selectedIndex = 0
        rebuildList()
    }

    /// The row standing for a folded section, at `row` in the list.
    private func foldedRow(_ summary: PaletteFold.Summary, unfolding section: Int, at row: Int) -> PaletteAction {
        PaletteAction(
            icon: .symbol(Theme.Symbol.unfold), title: summary.title, subtitle: summary.subtitle, shortcut: nil,
            badge: summary.badge, keepsPaletteOpen: true
        ) { [weak self] in
            self?.unfold(section, firstRow: row)
        }
    }

    /// Lists a section's folded rows in place, for as long as the palette
    /// stays open. Nothing above moves: the first of them takes the folded
    /// row's place, selected.
    private func unfold(_ section: Int, firstRow: Int) {
        unfoldedSections.insert(section)
        filterActions(query: searchField?.stringValue ?? "")
        guard filteredActions.indices.contains(firstRow) else { return }
        selectedIndex = firstRow
        highlightSelected(animated: false)
    }
}

/// Where the palette's headers and rows sit in the list's content, top
/// down.
struct PaletteListLayout {
    enum Item: Equatable {
        case header(String)
        /// An index into `filteredActions`.
        case row(Int)
    }

    static let rowHeight: CGFloat = 30
    static let headerHeight: CGFloat = 24

    let items: [Item]
    let tops: [CGFloat]
    let heights: [CGFloat]

    init(items: [Item]) {
        self.items = items
        heights = items.map { item in
            if case .header = item { return Self.headerHeight }
            return Self.rowHeight
        }
        var top: CGFloat = 0
        tops = heights.map { height in
            defer { top += height }
            return top
        }
    }

    var totalHeight: CGFloat { (tops.last ?? 0) + (heights.last ?? 0) }

    func itemIndex(ofRow row: Int) -> Int? {
        items.firstIndex(of: .row(row))
    }

    /// The row `y` points from the top of the content; nil on a header or
    /// past the rows.
    func row(atContentY y: CGFloat) -> Int? {
        guard let index = tops.lastIndex(where: { $0 <= y }), y < tops[index] + heights[index],
              case .row(let row) = items[index] else { return nil }
        return row
    }

    /// What scrolls into view to show `row`: the row, and its section's
    /// header when the row comes first under it.
    func visibleSpan(ofRow row: Int) -> (top: CGFloat, bottom: CGFloat)? {
        guard let index = itemIndex(ofRow: row) else { return nil }
        var top = tops[index]
        if index > 0, case .header = items[index - 1] { top = tops[index - 1] }
        return (top, tops[index] + heights[index])
    }
}

// MARK: - NSTextFieldDelegate

extension CommandPalette: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        let text = searchField?.stringValue ?? ""
        filterActions(query: text)
    }
}
