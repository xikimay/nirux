import AppKit

/// Action item in the command palette
struct PaletteAction {
    let icon: String
    let title: String
    let subtitle: String
    let shortcut: String  // e.g. "⌘T" displayed on the right
    let action: () -> Void
}

/// Raycast-style command palette — Cmd+P to open
@MainActor
final class CommandPalette: NSObject {
    var actions: [PaletteAction] = []
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
    var filteredActions: [PaletteAction] = []
    var selectedIndex = 0
    var scrollY: CGFloat = 0
    var scrollIndicator: NSView?
    var urlSuggestions: [String] = []
    var urlSelectedIndex = 0

    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var moveMonitor: Any?
    private var scrollMonitor: Any?

    func show(relativeTo window: NSWindow) {
        if panel == nil { createPanel() }
        guard let panel, let searchField else { return }

        filteredActions = actions
        selectedIndex = 0

        let windowFrame = window.frame
        let panelWidth: CGFloat = 520
        let panelHeight: CGFloat = 340
        let xPos = windowFrame.origin.x + (windowFrame.width - panelWidth) / 2
        let yPos = windowFrame.origin.y + windowFrame.height * 0.55
        panel.setFrame(NSRect(x: xPos, y: yPos, width: panelWidth, height: panelHeight), display: true)

        searchField.stringValue = ""
        rebuildList()
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

        let rowHeight: CGFloat = mode == .urlInput ? 36 : 44
        let containerHeight = listContainer.bounds.height
        let index = Int(floor((containerHeight + scrollY - locInList.y) / rowHeight))
        let count = mode == .urlInput ? urlSuggestions.count : filteredActions.count
        guard index >= 0, index < count else { return nil }
        return index
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
        let rowHeight: CGFloat = mode == .urlInput ? 36 : 44
        let count = mode == .urlInput ? urlSuggestions.count : filteredActions.count
        let containerHeight = listContainer.bounds.height
        let totalHeight = CGFloat(count) * rowHeight
        let maxScrollY = max(0, totalHeight - containerHeight)

        scrollY = max(0, min(scrollY - event.scrollingDeltaY, maxScrollY))

        for (index, row) in rowViews.enumerated() {
            row.frame.origin.y = containerHeight - CGFloat(index + 1) * rowHeight + scrollY
        }

        // Update scroll indicator
        if let indicator = scrollIndicator {
            let canScroll = maxScrollY > 0
            indicator.isHidden = !canScroll
            if canScroll {
                let ratio = containerHeight / totalHeight
                let barHeight = max(20, containerHeight * ratio)
                let travel = containerHeight - barHeight
                let barY = travel - (scrollY / maxScrollY) * travel
                indicator.frame = NSRect(x: listContainer.bounds.width - 6, y: barY, width: 3, height: barHeight)
            }
        }
    }

    // MARK: - List

    func rebuildList() {
        guard let listContainer else { return }
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()
        scrollY = 0

        let rowHeight: CGFloat = 44
        let containerHeight = listContainer.bounds.height

        for (index, action) in filteredActions.enumerated() {
            let yPos = containerHeight - CGFloat(index + 1) * rowHeight

            let row = NSView(frame: NSRect(x: 0, y: yPos, width: listContainer.bounds.width, height: rowHeight))
            row.wantsLayer = true

            // Icon
            let iconLabel = NSTextField(labelWithString: action.icon)
            iconLabel.font = .systemFont(ofSize: 18)
            iconLabel.frame = NSRect(x: 16, y: 10, width: 28, height: 24)
            row.addSubview(iconLabel)

            // Title
            let title = NSTextField(labelWithString: action.title)
            title.font = .systemFont(ofSize: 13, weight: .medium)
            title.textColor = .white
            title.frame = NSRect(x: 52, y: 22, width: 350, height: 18)
            row.addSubview(title)

            // Subtitle
            let subtitle = NSTextField(labelWithString: action.subtitle)
            subtitle.font = .systemFont(ofSize: 11)
            subtitle.textColor = .secondaryLabelColor
            subtitle.frame = NSRect(x: 52, y: 4, width: 350, height: 16)
            row.addSubview(subtitle)

            // Shortcut label (right side)
            if !action.shortcut.isEmpty {
                let shortcut = NSTextField(labelWithString: action.shortcut)
                shortcut.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
                shortcut.textColor = .tertiaryLabelColor
                shortcut.alignment = .right
                shortcut.frame = NSRect(x: listContainer.bounds.width - 60, y: 14, width: 50, height: 16)
                row.addSubview(shortcut)
            }

            listContainer.addSubview(row)
            rowViews.append(row)
        }

        highlightSelected(animated: false)
    }

    func highlightSelected(animated: Bool = true) {
        guard let listContainer else { return }
        let rowHeight: CGFloat = 44
        let containerHeight = listContainer.bounds.height
        let totalHeight = CGFloat(filteredActions.count) * rowHeight
        let maxScrollY = max(0, totalHeight - containerHeight)

        // Ensure selected row is fully visible
        let oldScrollY = scrollY
        let selTop = CGFloat(selectedIndex) * rowHeight
        let selBottom = selTop + rowHeight
        if selTop < scrollY { scrollY = selTop }
        if selBottom > scrollY + containerHeight { scrollY = selBottom - containerHeight }
        scrollY = max(0, min(scrollY, maxScrollY))

        let needsScroll = animated && oldScrollY != scrollY

        // Position rows (masksToBounds clips naturally → peek effect)
        if needsScroll {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for (index, row) in self.rowViews.enumerated() {
                    row.animator().frame.origin.y = containerHeight - CGFloat(index + 1) * rowHeight + self.scrollY
                }
            }
        } else {
            for (index, row) in rowViews.enumerated() {
                row.frame.origin.y = containerHeight - CGFloat(index + 1) * rowHeight + scrollY
            }
        }

        // Highlight
        let accent = NSColor.niruxAccent.withAlphaComponent(0.15)
        for (index, row) in rowViews.enumerated() {
            row.layer?.backgroundColor = (index == selectedIndex) ? accent.cgColor : NSColor.clear.cgColor
            row.layer?.cornerRadius = 6
        }

        // Scroll indicator
        if let indicator = scrollIndicator {
            let canScroll = maxScrollY > 0
            indicator.isHidden = !canScroll
            if canScroll {
                let ratio = containerHeight / totalHeight
                let barHeight = max(20, containerHeight * ratio)
                let travel = containerHeight - barHeight
                let barY = travel - (scrollY / maxScrollY) * travel
                indicator.frame = NSRect(x: listContainer.bounds.width - 6, y: barY, width: 3, height: barHeight)
            }
        }
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

    private func filterActions(query: String) {
        // Don't filter actions when in URL mode — user is typing a URL
        guard mode == .actions else { return }

        if query.isEmpty {
            filteredActions = actions
        } else {
            let lowercasedQuery = query.lowercased()
            filteredActions = actions.filter {
                $0.title.lowercased().contains(lowercasedQuery) || $0.subtitle.lowercased().contains(lowercasedQuery)
            }
        }
        selectedIndex = 0
        rebuildList()
    }
}

// MARK: - NSTextFieldDelegate

extension CommandPalette: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        let text = searchField?.stringValue ?? ""
        filterActions(query: text)
    }
}
