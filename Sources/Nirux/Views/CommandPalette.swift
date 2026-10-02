import AppKit

/// Action item in the command palette
struct PaletteAction {
    let icon: String
    let title: String
    let subtitle: String
    /// Shown on the right. Only table chords, so every label is bound.
    let shortcut: NiruxShortcuts?
    /// What the search matches besides the title; nil: the subtitle. A
    /// workspace's branch, space and folder name.
    var searchKeys: [String]?
    /// Shown on the right instead of a shortcut: a workspace's agent state.
    var badge: PaletteBadge?
    /// Listed after the other rows of its section, its title dimmed: an
    /// inactive workspace.
    var isDimmed = false
    /// Draws the icon in this color: a workspace's space dot.
    var iconColor: NSColor?
    let action: () -> Void

    var rankingCandidate: PaletteRanking.Candidate {
        PaletteRanking.Candidate(title: title, keys: searchKeys ?? [subtitle], sinks: isDimmed)
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
        case .waiting: return .systemOrange
        case .failure: return .systemRed
        }
    }
}

/// Rows listed under their own header beside the commands: the
/// workspaces, and whatever else a provider adds (see
/// `NiruxShellView.paletteSections`).
struct PaletteSection {
    let title: String
    let rows: [PaletteAction]
}

/// Raycast-style command palette — Cmd+P to open
@MainActor
final class CommandPalette: NSObject {
    /// The commands, searched with `sections`.
    var actions: [PaletteAction] = []
    /// Listed after the commands when the query is empty, ranked with them
    /// otherwise; each section and the commands then show a header. Empty
    /// for a palette listing one kind of row (Open Worktree). Set by `show`.
    private(set) var sections: [PaletteSection] = []
    static let commandsSectionTitle = "Commands"
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
        palettePanel.appearance = NSAppearance(named: .darkAqua)
        palettePanel.becomesKeyOnlyIfNeeded = false
        palettePanel.acceptsMouseMovedEvents = true

        let background = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 340))
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.15, alpha: 0.98).cgColor
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        background.layer?.masksToBounds = true

        // Search field
        let fieldContainer = NSView(frame: NSRect(x: 0, y: 340 - 44, width: 520, height: 44))
        fieldContainer.wantsLayer = true
        fieldContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.03).cgColor

        let icon = NSTextField(labelWithString: "⌘")
        icon.font = .systemFont(ofSize: 14)
        icon.textColor = .tertiaryLabelColor
        icon.frame = NSRect(x: 14, y: 10, width: 24, height: 24)
        fieldContainer.addSubview(icon)

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
        let locInList = listContainer.convert(locInContent, from: contentView)
        guard listContainer.bounds.contains(locInList) else { return nil }

        // From the top of the list's content.
        let contentY = listContainer.bounds.height + scrollY - locInList.y
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
            let action = filteredActions[index]
            action.action()
            if mode == .actions { dismiss() }
        }
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

    private func updateScrollIndicator() {
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

    func rebuildList() {
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

    private static func headerView(_ title: String, frame: NSRect) -> NSView {
        let header = NSView(frame: frame)
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.frame = NSRect(x: 16, y: 3, width: frame.width - 32, height: 14)
        header.addSubview(label)
        return header
    }

    private static func rowView(_ action: PaletteAction, frame: NSRect) -> NSView {
        let row = NSView(frame: frame)
        row.wantsLayer = true
        row.layer?.cornerRadius = 6

        // Icon: an emoji, or a symbol in its color (a space's dot).
        let iconLabel = NSTextField(labelWithString: action.icon)
        if let iconColor = action.iconColor {
            iconLabel.font = .systemFont(ofSize: 12)
            iconLabel.textColor = iconColor
            iconLabel.alignment = .center
            iconLabel.frame = NSRect(x: 16, y: 13, width: 20, height: 18)
        } else {
            iconLabel.font = .systemFont(ofSize: 18)
            iconLabel.frame = NSRect(x: 16, y: 10, width: 28, height: 24)
        }
        row.addSubview(iconLabel)

        // Right side: the badge, else the shortcut.
        var textRight = frame.width - 18
        if let badge = action.badge {
            let label = NSTextField(labelWithString: badge.text)
            label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            label.textColor = badge.color
            label.sizeToFit()
            let width = ceil(label.frame.width)
            label.frame = NSRect(x: frame.width - 14 - width, y: 14, width: width, height: 16)
            row.addSubview(label)
            textRight = label.frame.minX - 12
        } else if let chord = action.shortcut?.chord {
            let shortcut = NSTextField(labelWithString: chord.display)
            shortcut.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            shortcut.textColor = .tertiaryLabelColor
            shortcut.alignment = .right
            shortcut.frame = NSRect(x: frame.width - 60, y: 14, width: 50, height: 16)
            row.addSubview(shortcut)
        }
        let textWidth = min(350, textRight - 52)

        let title = NSTextField(labelWithString: action.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = action.isDimmed ? .secondaryLabelColor : .white
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 52, y: 22, width: textWidth, height: 18)
        row.addSubview(title)

        let subtitle = NSTextField(labelWithString: action.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        // Keeps both ends: a workspace's branch and its folder's name.
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.frame = NSRect(x: 52, y: 4, width: textWidth, height: 16)
        row.addSubview(subtitle)

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
        let accent = NSColor.niruxAccent.withAlphaComponent(0.15)
        let selectedItem = listLayout.itemIndex(ofRow: selectedIndex)
        for (index, view) in rowViews.enumerated() {
            view.layer?.backgroundColor = (index == selectedItem) ? accent.cgColor : NSColor.clear.cgColor
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
            if filteredActions.indices.contains(selectedIndex) {
                let action = filteredActions[selectedIndex]
                action.action()
                // Only dismiss if the action didn't switch mode (e.g. URL input)
                if mode == .actions { dismiss() }
            }
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
        sections.isEmpty ? "Type a command..." : "Type a command or a workspace..."
    }

    /// Lists what `query` matches (see `PaletteRanking.rank`), the first
    /// row selected. Titles match above subtitles; fuzzy scoring keeps
    /// acronym-style queries ("nt" → "New Terminal") working.
    func filterActions(query: String) {
        // Don't filter actions when in URL mode — user is typing a URL
        guard mode == .actions else { return }

        let all = [PaletteSection(title: Self.commandsSectionTitle, rows: actions)] + sections
        let ranked = PaletteRanking.rank(query: query, sections: all.map { $0.rows.map(\.rankingCandidate) })
        var items: [PaletteListLayout.Item] = []
        var rows: [PaletteAction] = []
        for section in ranked {
            if !sections.isEmpty { items.append(.header(all[section.section].title)) }
            for row in section.rows {
                items.append(.row(rows.count))
                rows.append(all[section.section].rows[row])
            }
        }
        filteredActions = rows
        listLayout = PaletteListLayout(items: items)
        selectedIndex = 0
        rebuildList()
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

    static let rowHeight: CGFloat = 44
    static let headerHeight: CGFloat = 22

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
