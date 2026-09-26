import AppKit

// MARK: - URL Input Mode

extension CommandPalette {
    func handleKeyInURLMode(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 0x7E: // Up — navigate suggestions
            if urlSelectedIndex > 0 { urlSelectedIndex -= 1; highlightURLSelected() }
            return nil
        case 0x7D: // Down — navigate suggestions
            if urlSelectedIndex < urlSuggestions.count - 1 { urlSelectedIndex += 1; highlightURLSelected() }
            return nil
        case 0x24: // Enter — submit URL or use selected suggestion
            let typed = searchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let url: String
            if typed.isEmpty, urlSuggestions.indices.contains(urlSelectedIndex) {
                url = urlSuggestions[urlSelectedIndex]
            } else {
                url = typed
            }
            if !url.isEmpty {
                addURLToHistory(url)
                dismiss()
                onURLSubmit?(url)
            }
            return nil
        case 0x35: // Escape — back to actions
            switchToActionsMode()
            return nil
        case 0x30: // Tab — fill suggestion into field
            if urlSuggestions.indices.contains(urlSelectedIndex) {
                searchField?.stringValue = urlSuggestions[urlSelectedIndex]
            }
            return nil
        default:
            return event
        }
    }

    /// Switch palette to URL input mode
    func switchToURLMode() {
        mode = .urlInput
        let detected = Self.detectedURLsProvider?() ?? []
        let history = URLHistory.load()
        detectedURLs = Set(detected)
        urlSuggestions = Self.urlSuggestions(detected: detected, history: history)
        urlSelectedIndex = Self.defaultURLSelection(in: urlSuggestions, history: history)
        searchField?.placeholderString = "Enter URL or search..."
        searchField?.stringValue = ""
        rebuildURLList()
        panel?.makeFirstResponder(searchField)
    }

    func rebuildURLList() {
        guard let listContainer else { return }
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()

        let containerHeight = listContainer.bounds.height
        let rowHeight: CGFloat = 36

        for (index, hint) in urlSuggestions.enumerated() {
            let yPos = containerHeight - CGFloat(index + 1) * rowHeight
            let row = NSView(frame: NSRect(x: 0, y: yPos, width: listContainer.bounds.width, height: rowHeight))
            row.wantsLayer = true
            row.layer?.cornerRadius = 6

            // Protocol badge: colored text "HTTPS" / "HTTP"
            let isSecure = hint.hasPrefix("https://")
            let badge = NSTextField(labelWithString: isSecure ? "HTTPS" : "HTTP")
            badge.font = .monospacedSystemFont(ofSize: 9, weight: .bold)
            badge.textColor = isSecure
                ? NSColor(red: 0.4, green: 0.8, blue: 0.5, alpha: 1)
                : NSColor(red: 0.9, green: 0.55, blue: 0.3, alpha: 1)
            badge.frame = NSRect(x: 12, y: 9, width: 38, height: 18)
            row.addSubview(badge)

            let isDetected = detectedURLs.contains(hint)
            let tagWidth: CGFloat = isDetected ? 72 : 0
            let label = NSTextField(labelWithString: hint)
            label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            label.textColor = .white
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 52, y: 8, width: min(400, row.bounds.width - 64 - tagWidth), height: 20)
            row.addSubview(label)

            if isDetected {
                let tag = NSTextField(labelWithString: "DETECTED")
                tag.font = .monospacedSystemFont(ofSize: 9, weight: .bold)
                tag.textColor = NSColor.systemGreen.withAlphaComponent(0.85)
                tag.alignment = .right
                tag.toolTip = "Printed by a terminal in this workspace and listening now"
                tag.frame = NSRect(x: row.bounds.width - tagWidth - 12, y: 10, width: tagWidth, height: 16)
                row.addSubview(tag)
            }

            listContainer.addSubview(row)
            rowViews.append(row)
        }

        highlightURLSelected()
    }

    func highlightURLSelected() {
        let accent = NSColor.niruxAccent.withAlphaComponent(0.15)
        for (index, row) in rowViews.enumerated() {
            row.layer?.backgroundColor = (index == urlSelectedIndex) ? accent.cgColor : NSColor.clear.cgColor
        }
    }

    nonisolated static let defaultURLSuggestions = ["http://localhost:3000", "http://localhost:8080", "http://localhost:5173"]

    /// Detected dev servers first, then history, then the fixed localhost
    /// defaults — each URL once, first position wins.
    nonisolated static func urlSuggestions(
        detected: [String],
        history: [String],
        defaults: [String] = defaultURLSuggestions
    ) -> [String] {
        var seen = Set<String>()
        return (detected + history + defaults).filter { seen.insert(normalizedSuggestionKey($0)).inserted }
    }

    /// ⌘B ↩ on an empty field keeps reopening the last URL: detected rows
    /// sit above it but don't take the selection.
    nonisolated static func defaultURLSelection(in suggestions: [String], history: [String]) -> Int {
        guard let last = history.first.map(normalizedSuggestionKey) else { return 0 }
        return suggestions.firstIndex { normalizedSuggestionKey($0) == last } ?? 0
    }

    /// "http://localhost:5173/" and "http://localhost:5173" are one entry.
    private nonisolated static func normalizedSuggestionKey(_ url: String) -> String {
        url.hasSuffix("/") ? String(url.dropLast()) : url
    }

    /// Add a URL to the persistent history (most recent first)
    func addURLToHistory(_ url: String) {
        URLHistory.add(url)
    }

    func switchToActionsMode() {
        mode = .actions
        searchField?.placeholderString = "Type a command..."
        searchField?.stringValue = ""
        filteredActions = actions
        selectedIndex = 0
        rebuildList()
    }
}
