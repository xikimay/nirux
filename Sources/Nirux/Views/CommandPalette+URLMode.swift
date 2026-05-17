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
        urlSelectedIndex = 0
        let defaults = ["http://localhost:3000", "http://localhost:8080", "http://localhost:5173"]
        let history = URLHistory.load()
        urlSuggestions = history + defaults.filter { defaultURL in !history.contains(defaultURL) }
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

            let label = NSTextField(labelWithString: hint)
            label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            label.textColor = .white
            label.frame = NSRect(x: 52, y: 8, width: 400, height: 20)
            row.addSubview(label)

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
