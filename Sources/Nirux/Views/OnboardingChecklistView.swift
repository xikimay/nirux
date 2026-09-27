import AppKit

/// First-launch checklist card in the expanded sidebar. Lays itself out top
/// down for the width SidebarView gives it; SidebarView reads `height` to
/// place it. The view is kept across sidebar rebuilds so transient state
/// (a "Copied" flash) survives the heartbeat.
final class OnboardingChecklistView: NSView {
    private enum Metrics {
        static let insetX: CGFloat = 12
        static let insetY: CGFloat = 12
        static let headerHeight: CGFloat = 18
        static let rowGap: CGFloat = 14
        static let markSize: CGFloat = 13
        static let textIndent: CGFloat = 20
        static let titleDetailGap: CGFloat = 2
        static let controlGap: CGFloat = 6
        static let controlSpacing: CGFloat = 10
        static let shortcutRowHeight: CGFloat = 22
    }

    override var isFlipped: Bool { true }

    var onAction: ((OnboardingChecklistAction) -> Void)?
    private(set) var checklist: OnboardingChecklist?
    private(set) var height: CGFloat = 0
    private var laidOutWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.040).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Getting Started")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Rebuilds only when the content or the width changed.
    func update(checklist: OnboardingChecklist, width: CGFloat) {
        guard checklist != self.checklist || width != laidOutWidth else { return }
        self.checklist = checklist
        laidOutWidth = width
        rebuild(checklist, width: width)
    }

    // MARK: - Layout

    private func rebuild(_ checklist: OnboardingChecklist, width: CGFloat) {
        subviews.forEach { $0.removeFromSuperview() }
        let textX = Metrics.insetX + Metrics.textIndent
        let textWidth = max(40, width - textX - Metrics.insetX)

        var y = addHeader(width: width)
        for row in checklist.rows {
            y += Metrics.rowGap
            y = addRow(row, y: y, textX: textX, textWidth: textWidth)
        }
        y += Metrics.rowGap
        y = addShortcuts(y: y, textX: textX, textWidth: textWidth)
        if checklist.isComplete {
            y += Metrics.rowGap
            y = addFooter(y: y, width: width)
        }
        height = ceil(y + Metrics.insetY)
        setFrameSize(NSSize(width: width, height: height))
    }

    private func addHeader(width: CGFloat) -> CGFloat {
        let title = label(
            "GETTING STARTED",
            font: .monospacedSystemFont(ofSize: 10, weight: .bold),
            color: NSColor.white.withAlphaComponent(0.55)
        )
        title.frame = NSRect(
            x: Metrics.insetX, y: Metrics.insetY + 2,
            width: width - Metrics.insetX * 2 - 24, height: 14
        )
        addSubview(title)

        let close = OnboardingChecklistButton(title: "×", style: .close) { [weak self] in
            self?.onAction?(.close)
        }
        close.toolTip = "Hide this checklist. Reopen it from ⌘P → Show Getting Started."
        close.setAccessibilityLabel("Hide Getting Started")
        close.frame = NSRect(
            x: width - Metrics.insetX - 18 + 4, y: Metrics.insetY - 1,
            width: 18, height: 18
        )
        addSubview(close)
        return Metrics.insetY + Metrics.headerHeight
    }

    private func addRow(_ row: OnboardingChecklistRow, y: CGFloat, textX: CGFloat, textWidth: CGFloat) -> CGFloat {
        let mark = markView(row.mark)
        mark.frame = NSRect(x: Metrics.insetX, y: y + 1, width: Metrics.markSize, height: Metrics.markSize)
        addSubview(mark)

        let title = wrappingLabel(
            row.title,
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: NSColor.white.withAlphaComponent(row.mark == .done ? 0.72 : 0.90),
            width: textWidth
        )
        title.frame.origin = NSPoint(x: textX, y: y)
        addSubview(title)
        var currentY = title.frame.maxY

        if let detail = row.detail {
            let detailLabel = wrappingLabel(
                detail,
                font: .systemFont(ofSize: 11, weight: .regular),
                color: NSColor.white.withAlphaComponent(0.50),
                width: textWidth
            )
            detailLabel.frame.origin = NSPoint(x: textX, y: currentY + Metrics.titleDetailGap)
            addSubview(detailLabel)
            currentY = detailLabel.frame.maxY
        }
        if !row.controls.isEmpty {
            currentY = addControls(row.controls, y: currentY + Metrics.controlGap, x: textX, width: textWidth)
        }
        return currentY
    }

    /// Flow layout: controls fill a line left to right and wrap when the
    /// next one would overflow.
    private func addControls(
        _ controls: [OnboardingChecklistRow.Control], y: CGFloat, x: CGFloat, width: CGFloat
    ) -> CGFloat {
        var cursorX = x
        var lineY = y
        var lineHeight: CGFloat = 0
        for control in controls {
            let button = makeButton(for: control)
            let size = button.preferredSize(maxWidth: width)
            if cursorX > x, cursorX + size.width > x + width {
                cursorX = x
                lineY += lineHeight + Metrics.controlGap
                lineHeight = 0
            }
            button.frame = NSRect(origin: NSPoint(x: cursorX, y: lineY), size: size)
            addSubview(button)
            cursorX += size.width + Metrics.controlSpacing
            lineHeight = max(lineHeight, size.height)
        }
        return lineY + lineHeight
    }

    private func makeButton(for control: OnboardingChecklistRow.Control) -> OnboardingChecklistButton {
        switch control {
        case .button(let title, let action):
            return OnboardingChecklistButton(title: title, style: .primary) { [weak self] in
                self?.onAction?(action)
            }
        case .action(let title, let action):
            let button = OnboardingChecklistButton(title: title, style: .link) {}
            button.onPress = { [weak self, weak button] in
                guard let self else { return }
                self.onAction?(action)
                // A re-check that changes anything rebuilds the card, which
                // then speaks for itself; an unchanged one still answers.
                guard action == .checkAgain, let button, button.superview === self,
                      self.checklist?.agents.anyFound == false else { return }
                button.flash("Not found")
            }
            return button
        case .link(let title, let url):
            let button = OnboardingChecklistButton(title: title, style: .link) {
                NSWorkspace.shared.open(url)
            }
            button.toolTip = url.absoluteString
            button.setAccessibilityLabel(title.replacingOccurrences(of: " ↗", with: ""))
            button.setAccessibilityHelp("Opens in your browser")
            return button
        case .copyCommand(let command):
            let button = OnboardingChecklistButton(title: command, style: .command) {}
            button.onPress = { [weak button] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                button?.flash("Copied to clipboard")
            }
            button.toolTip = "Copy “\(command)”"
            button.setAccessibilityLabel("Copy \(command)")
            return button
        }
    }

    private func addShortcuts(y: CGFloat, textX: CGFloat, textWidth: CGFloat) -> CGFloat {
        let mark = symbolView("keyboard", color: NSColor.white.withAlphaComponent(0.50))
        mark.frame = NSRect(x: Metrics.insetX, y: y + 1, width: Metrics.markSize, height: Metrics.markSize)
        addSubview(mark)
        let title = label(
            "Shortcuts",
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.90)
        )
        title.frame = NSRect(x: textX, y: y, width: textWidth, height: 16)
        addSubview(title)

        var rowY = y + 16 + Metrics.controlGap
        let columnWidth = textWidth / 2
        let shortcuts = OnboardingChecklist.shortcuts
        for start in stride(from: 0, to: shortcuts.count, by: 2) {
            for column in 0..<2 where start + column < shortcuts.count {
                let shortcut = shortcuts[start + column]
                let hint = SidebarShortcutHintView(hints: [SidebarShortcutHint(key: shortcut.key, label: shortcut.label)])
                hint.frame = NSRect(
                    x: textX + CGFloat(column) * columnWidth, y: rowY,
                    width: columnWidth, height: Metrics.shortcutRowHeight
                )
                hint.setAccessibilityElement(true)
                hint.setAccessibilityRole(.staticText)
                hint.setAccessibilityLabel("\(shortcut.key) \(shortcut.label)")
                addSubview(hint)
            }
            rowY += Metrics.shortcutRowHeight + 4
        }
        return rowY - 4
    }

    private func addFooter(y: CGFloat, width: CGFloat) -> CGFloat {
        let done = OnboardingChecklistButton(title: "Done", style: .primary) { [weak self] in
            self?.onAction?(.close)
        }
        let size = done.preferredSize(maxWidth: width)
        done.frame = NSRect(x: width - Metrics.insetX - size.width, y: y, width: size.width, height: size.height)
        addSubview(done)

        let message = label(
            "You're all set.",
            font: .systemFont(ofSize: 12, weight: .medium),
            color: NSColor.systemGreen.withAlphaComponent(0.90)
        )
        message.frame = NSRect(
            x: Metrics.insetX, y: y + (size.height - 16) / 2,
            width: done.frame.minX - Metrics.insetX - 8, height: 16
        )
        addSubview(message)
        return y + size.height
    }

    /// Whether `point`, in the superview's coordinates, is over a button.
    func hasButton(at point: NSPoint) -> Bool {
        let local = convert(point, from: superview)
        return subviews.contains { $0 is OnboardingChecklistButton && $0.frame.contains(local) }
    }

    // MARK: - Small views

    private func markView(_ mark: OnboardingChecklistRow.Mark) -> NSView {
        switch mark {
        case .done: return symbolView("checkmark.circle.fill", color: .systemGreen, description: "Done")
        case .todo:
            return symbolView("circle", color: NSColor.white.withAlphaComponent(0.55), description: "To do")
        case .off:
            return symbolView("minus.circle", color: NSColor.white.withAlphaComponent(0.40), description: "Off")
        }
    }

    private func symbolView(_ name: String, color: NSColor, description: String? = nil) -> NSView {
        let view = NSImageView()
        let configuration = NSImage.SymbolConfiguration(pointSize: Metrics.markSize - 1, weight: .medium)
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
        view.contentTintColor = color
        view.imageScaling = .scaleProportionallyDown
        return view
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func wrappingLabel(_ text: String, font: NSFont, color: NSColor, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.isSelectable = false
        label.preferredMaxLayoutWidth = width
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let fitted = label.cell?.cellSize(forBounds: bounds).height ?? 16
        label.frame = NSRect(x: 0, y: 0, width: width, height: ceil(fitted))
        return label
    }
}

/// Button drawn to match the sidebar's custom look, with the accessibility
/// of a real button.
final class OnboardingChecklistButton: NSView {
    enum Style {
        /// Accent-filled pill.
        case primary
        /// Accent text, underlined while hovered.
        case link
        /// Monospaced chip.
        case command
        /// Small "×".
        case close
    }

    private let style: Style
    private let title: String
    /// The title as drawn: `title`, or a message during `flash`.
    private(set) var displayedTitle: String
    var onPress: () -> Void
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?
    private var flashGeneration = 0

    init(title: String, style: Style, onPress: @escaping () -> Void) {
        self.style = style
        self.title = title
        self.displayedTitle = title
        self.onPress = onPress
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var font: NSFont {
        switch style {
        case .primary: return .systemFont(ofSize: 11, weight: .semibold)
        case .link: return .systemFont(ofSize: 11, weight: .medium)
        case .command: return .monospacedSystemFont(ofSize: 10, weight: .medium)
        case .close: return .systemFont(ofSize: 14, weight: .regular)
        }
    }

    private static let commandInsets = NSSize(width: 6, height: 4)

    /// Size for the title in this style, at most `maxWidth` wide; the card
    /// lays buttons out by hand. A command wider than that wraps onto more
    /// lines instead of being truncated, so what is copied is what shows.
    func preferredSize(maxWidth: CGFloat) -> NSSize {
        let text = title.size(withAttributes: [.font: font])
        switch style {
        case .primary: return NSSize(width: min(maxWidth, ceil(text.width) + 20), height: 20)
        case .link: return NSSize(width: min(maxWidth, ceil(text.width) + 2), height: 16)
        case .close: return NSSize(width: 18, height: 18)
        case .command:
            let insets = Self.commandInsets
            let singleLine = ceil(text.width) + insets.width * 2
            guard singleLine > maxWidth else { return NSSize(width: singleLine, height: 20) }
            let textHeight = wrappedHeight(title, width: maxWidth - insets.width * 2)
            return NSSize(width: maxWidth, height: max(20, textHeight + insets.height * 2))
        }
    }

    private var commandAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        return [.font: font, .paragraphStyle: paragraph]
    }

    private func wrappedHeight(_ text: String, width: CGFloat) -> CGFloat {
        ceil((text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: commandAttributes
        ).height)
    }

    /// Shows `message` in place of the title for a moment.
    func flash(_ message: String) {
        flashGeneration += 1
        let generation = flashGeneration
        displayedTitle = message
        needsDisplay = true
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, generation == self.flashGeneration else { return }
            self.displayedTitle = self.title
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        var textColor = NSColor.white
        switch style {
        case .primary:
            NSColor.niruxAccent.withAlphaComponent(isPressed ? 0.65 : (isHovered ? 1.0 : 0.85)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        case .command:
            NSColor.white.withAlphaComponent(isHovered ? 0.11 : 0.06).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            NSColor.white.withAlphaComponent(0.13).setStroke()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).stroke()
            textColor = NSColor.white.withAlphaComponent(0.80)
        case .link:
            textColor = NSColor.niruxAccent.withAlphaComponent(isPressed ? 0.7 : 1.0)
        case .close:
            if isHovered {
                NSColor.white.withAlphaComponent(0.10).setFill()
                NSBezierPath(ovalIn: rect).fill()
            }
            textColor = NSColor.white.withAlphaComponent(isHovered ? 0.90 : 0.50)
        }

        if style == .command {
            var attributes = commandAttributes
            attributes[.foregroundColor] = textColor
            let insets = Self.commandInsets
            let width = bounds.width - insets.width * 2
            let height = min(wrappedHeight(displayedTitle, width: width), bounds.height)
            let textRect = NSRect(x: insets.width, y: (bounds.height - height) / 2, width: width, height: height)
            (displayedTitle as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin], attributes: attributes)
            return
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: textColor, .paragraphStyle: paragraph
        ]
        if style == .link, isHovered {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        let textHeight = displayedTitle.size(withAttributes: [.font: font]).height
        let horizontalInset: CGFloat = style == .link ? 1 : 4
        let textRect = NSRect(
            x: horizontalInset, y: (bounds.height - textHeight) / 2,
            width: bounds.width - horizontalInset * 2, height: textHeight
        )
        (displayedTitle as NSString).draw(in: textRect, withAttributes: attributes)
    }

    // MARK: - Input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        guard wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress()
        return true
    }
}
