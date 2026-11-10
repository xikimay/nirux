import AppKit

/// What happened while the user was away (Settings › Notifications): the
/// space's tasks whose last turn ended meanwhile, on a card above the task
/// list. Activating Nirux clears the rows' "finished" marks; this keeps the
/// list until the user has opened each task or dismissed it.
struct SidebarCatchUp: Hashable {
    /// What a listed task is now, in the order the card lists them.
    enum Kind: Int, Hashable, Comparable {
        /// Waits on the user (amber).
        case asks
        /// Broke (red).
        case broken
        /// Its turn is over: its status line, by a grey check.
        case done
        /// Blocked, or asking its parent: its row's line, by a grey dot.
        case quiet
        /// At work again (green).
        case working

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue > rhs.rawValue }
    }

    struct Row: Hashable {
        let workspaceID: String
        let title: String
        let kind: Kind
        let text: String
    }

    /// Tasks of another space the list holds: shown there.
    struct OtherSpace: Hashable {
        let profileID: String
        let name: String
        let count: Int
    }

    /// When the absence it lists began ("since 12:40").
    let since: String
    /// Needs-you first, then broken, then done; the latest turn end first
    /// within each.
    let rows: [Row]
    let otherSpaces: [OtherSpace]
    var isExpanded = false

    static let collapsedRowCount = 5

    var shownRows: [Row] {
        isExpanded || rows.count <= Self.collapsedRowCount ? rows : Array(rows.prefix(Self.collapsedRowCount))
    }

    var hiddenRowCount: Int { rows.count - shownRows.count }

    /// A listed task as its row says it: what it asks, what broke, that it
    /// works again, is blocked or asks its parent; else, its turn over (the
    /// pull request's line aside), its last turn's line.
    @MainActor
    static func row(for info: WorkspaceInfo) -> Row {
        let summary = info.rowSummary
        let kind: Kind = switch summary.mark {
        case .needsYou: .asks
        case .error: .broken
        case .working: .working
        case .blocked, .asking: .quiet
        case .idle, .finished, .readyToMerge, .merged, .checksRunning: .done
        }
        let text = kind == .done ? info.turnStatusLine ?? "Done" : summary.status.text
        return Row(workspaceID: info.id, title: info.title, kind: kind, text: text)
    }

    /// "since 12:40", in the user's clock format: it doesn't age on screen
    /// as "42m" would.
    static func sinceText(_ time: TimeInterval) -> String {
        "since " + DateFormatter.localizedString(from: Date(timeIntervalSince1970: time), dateStyle: .none, timeStyle: .short)
    }

    var accessibilityLabel: String {
        let count = rows.count + otherSpaces.reduce(0) { $0 + $1.count }
        return "While you were away, \(since): \(count == 1 ? "1 task" : "\(count) tasks")"
    }
}

/// What a click on the card does.
enum SidebarCatchUpAction: Hashable {
    case dismiss
    case expand
    case open(workspaceID: String)
    case space(profileID: String)
}

/// The catch-up card's views and hit areas, in the sidebar's coordinates:
/// in the flow above the task list, never over a row, and nothing in it
/// takes the keyboard.
@MainActor
struct SidebarCatchUpCardRenderer {
    enum Metrics {
        static let paddingTop: CGFloat = 7
        static let paddingBottom: CGFloat = 6
        static let headerHeight: CGFloat = 18
        static let rowHeight: CGFloat = 34
        static let lineHeight: CGFloat = 18
        static let dismissSize: CGFloat = 16
        /// Between the card and the first task row.
        static let gapBelow: CGFloat = 6
    }

    let catchUp: SidebarCatchUp
    let sidebarWidth: CGFloat
    /// The card's top edge.
    let top: CGFloat
    /// VoiceOver presses a row or a button.
    let press: (SidebarCatchUpAction) -> Void

    static func height(of catchUp: SidebarCatchUp) -> CGFloat {
        Metrics.paddingTop + Metrics.headerHeight + CGFloat(catchUp.shownRows.count) * Metrics.rowHeight
            + (catchUp.hiddenRowCount > 0 ? Metrics.lineHeight : 0)
            + CGFloat(catchUp.otherSpaces.count) * Metrics.lineHeight + Metrics.paddingBottom
    }

    func render() -> (views: [NSView], hitAreas: [SidebarHitArea]) {
        typealias Row = SidebarExpandedMetrics
        var views: [NSView] = []
        var hitAreas: [SidebarHitArea] = []
        let height = Self.height(of: catchUp)
        let card = NSRect(x: Row.workspaceInsetX, y: top - height, width: sidebarWidth - 2 * Row.workspaceInsetX, height: height)
        let background = SidebarBackgroundView(frame: card)
        background.wantsLayer = true
        background.layer?.cornerRadius = Theme.Radius.card
        background.layer?.backgroundColor = Theme.Color.fillHover.cgColor
        background.setAccessibilityElement(true)
        background.setAccessibilityRole(.group)
        background.setAccessibilityLabel(catchUp.accessibilityLabel)
        views.append(background)

        let textX = Row.textX
        let textWidth = card.maxX - Row.cardPaddingX - textX
        var y = card.maxY - Metrics.paddingTop - Metrics.headerHeight
        let header = label("While you were away · \(catchUp.since)", font: Theme.Font.captionEmphasized, color: Theme.Color.textSecondary)
        header.frame = NSRect(x: Row.workspaceInsetX + Row.cardPaddingX, y: y + 1, width: textWidth, height: 16)
        views.append(header)
        let dismissFrame = NSRect(
            x: card.maxX - Theme.Space.xs - Metrics.dismissSize, y: y + (Metrics.headerHeight - Metrics.dismissSize) / 2,
            width: Metrics.dismissSize, height: Metrics.dismissSize
        )
        let dismiss = SidebarBadgeView(text: "", textColor: Theme.Color.textTertiary, fillColor: .clear, font: Theme.Font.caption)
        dismiss.symbolName = Theme.Symbol.dismiss
        dismiss.frame = dismissFrame
        dismiss.toolTip = "Dismiss"
        dismiss.setAccessibilityElement(true)
        dismiss.setAccessibilityRole(.button)
        dismiss.setAccessibilityLabel("Dismiss what happened while you were away")
        dismiss.onPress = { press(.dismiss) }
        views.append(dismiss)
        hitAreas.append(SidebarHitArea(frame: dismissFrame.insetBy(dx: -3, dy: -1), region: .catchUp(.dismiss)))

        for row in catchUp.shownRows {
            y -= Metrics.rowHeight
            let frame = NSRect(x: card.minX, y: y, width: card.width, height: Metrics.rowHeight)
            views.append(mark(row.kind, centerY: y + Metrics.rowHeight - 10))
            let title = label(row.title, font: Theme.Font.body, color: Theme.Color.textPrimary)
            title.frame = NSRect(x: textX, y: y + 16, width: textWidth, height: 16)
            views.append(title)
            let line = label(row.text, font: Theme.Font.caption, color: color(of: row.kind))
            line.frame = NSRect(x: textX, y: y + 2, width: textWidth, height: 14)
            views.append(line)
            let action = SidebarCatchUpAction.open(workspaceID: row.workspaceID)
            // On top of the labels: the whole line, when the row cuts it.
            let button = pressable(frame: frame, label: "\(row.title): \(row.text)", action: action)
            button.toolTip = "\(row.title)\n\(row.text)"
            views.append(button)
            hitAreas.append(SidebarHitArea(frame: frame, region: .catchUp(action)))
        }
        var links: [(String, SidebarCatchUpAction)] = []
        if catchUp.hiddenRowCount > 0 { links.append(("\(catchUp.hiddenRowCount) more", .expand)) }
        for space in catchUp.otherSpaces {
            links.append(("Also in \(space.name) · \(space.count)", .space(profileID: space.profileID)))
        }
        for (text, action) in links {
            y -= Metrics.lineHeight
            let frame = NSRect(x: card.minX, y: y, width: card.width, height: Metrics.lineHeight)
            let link = label(text, font: Theme.Font.caption, color: Theme.Color.accent)
            link.frame = NSRect(x: textX, y: y + 2, width: textWidth, height: 14)
            views.append(link)
            views.append(pressable(frame: frame, label: text, action: action))
            hitAreas.append(SidebarHitArea(frame: frame, region: .catchUp(action)))
        }
        return (views, hitAreas)
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField.sidebarLine(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        label.setAccessibilityElement(false)
        return label
    }

    private func color(of kind: SidebarCatchUp.Kind) -> NSColor {
        switch kind {
        case .asks: Theme.Color.waiting
        case .broken: Theme.Color.error
        case .done, .quiet, .working: Theme.Color.textSecondary
        }
    }

    /// The row's sign, in the state marks' column, as its row's: amber,
    /// red, green or grey dots, a grey check for a finished turn.
    private func mark(_ kind: SidebarCatchUp.Kind, centerY: CGFloat) -> NSView {
        let centerX = SidebarExpandedMetrics.markCenterX
        let color: NSColor
        switch kind {
        case .done:
            let icon = SidebarImageView(image: SidebarRenderer.symbol(Theme.Symbol.checksPassed, color: Theme.Color.idle, pointSize: 11))
            icon.frame = NSRect(x: centerX - 7, y: centerY - 7, width: 14, height: 14)
            icon.setAccessibilityElement(false)
            return icon
        case .asks: color = Theme.Color.waiting
        case .broken: color = Theme.Color.error
        case .working: color = Theme.Color.working
        case .quiet: color = Theme.Color.idle
        }
        let size = SidebarExpandedMetrics.stateDotSize
        let dot = SidebarBackgroundView(frame: NSRect(x: centerX - size / 2, y: centerY - size / 2, width: size, height: size))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = size / 2
        dot.layer?.backgroundColor = color.cgColor
        return dot
    }

    /// What VoiceOver presses; clicks go through the hit areas.
    private func pressable(frame: NSRect, label: String, action: SidebarCatchUpAction) -> NSView {
        let view = SidebarCatchUpPressable(frame: frame)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(label)
        view.onPress = { [press] in press(action) }
        return view
    }
}

/// An invisible button for VoiceOver over a row of the card (an NSView:
/// it never takes the keyboard).
final class SidebarCatchUpPressable: NSView {
    var onPress: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }
}
