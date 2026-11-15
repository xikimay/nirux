import AppKit

/// The glass interface's command bar (docs/design/glass-interface.md): one
/// capsule floating at the top of the window with the space, the current
/// task and its state, ⌘P, and how many agents wait for the user (⌘J).
/// Built, not shown yet: phase 3 puts it in the window and wires its
/// actions.
final class CommandBarView: NSView {
    /// What the bar says, read from the shell by its caller.
    struct Content: Equatable {
        var spaceName: String
        var spaceColor: NSColor
        /// The task on screen; nil in a space with nothing open.
        var taskTitle: String?
        var taskIcon: StateIcon?
        /// Where it stands, after its title: "working 12m".
        var taskDetail: String?
        /// Agents waiting for the user, across the space.
        var waitingCount: Int
    }

    static let height: CGFloat = 36
    /// Left and right of each segment's content.
    private static let inset: CGFloat = 14
    private static let gap: CGFloat = 8
    /// The task's title keeps at least this much (or all of a shorter one)
    /// before anything else gives way: its detail, then the space's name,
    /// then the search's key.
    private static let titleMinimum: CGFloat = 120

    var onSpace: (() -> Void)?
    var onTask: (() -> Void)?
    var onSearch: (() -> Void)?
    var onWaiting: (() -> Void)?

    var level: InterfaceTransparency {
        get { glass.level }
        set { glass.level = newValue }
    }

    private(set) var content: Content?
    private let glass: GlassView

    let spaceChip = NSView()
    let spaceLabel = NSTextField(labelWithString: "")
    let spaceChevron = NSImageView()
    let taskIcon = StateIconView(StateIcon(.idle), size: 13)
    let taskLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let searchIcon = NSImageView()
    let searchKey = KeyCap("⌘P")
    let waitingBadge = CountBadge()
    let waitingKey = KeyCap("⌘J")
    private var separators: [NSView] = []

    /// One overlay button per segment: its hover, its press, its click and
    /// what VoiceOver says.
    let spaceButton = NiruxButton(title: "", kind: .quiet)
    let taskButton = NiruxButton(title: "", kind: .quiet)
    let searchButton = NiruxButton(title: "", kind: .quiet)
    let waitingButton = NiruxButton(title: "", kind: .quiet)

    init(level: InterfaceTransparency) {
        glass = GlassView(role: .chrome, level: level, cornerRadius: Self.height / 2)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: Self.height))
        glass.autoresizingMask = [.width, .height]
        glass.frame = bounds
        addSubview(glass)
        let host = glass.contentView

        spaceChip.wantsLayer = true
        spaceChip.layer?.cornerRadius = Theme.Radius.spaceMark
        spaceLabel.font = Theme.Font.title
        spaceLabel.textColor = Theme.Color.textPrimary
        spaceChevron.image = Self.symbol(Theme.Symbol.spacePicker)
        spaceChevron.contentTintColor = Theme.Color.textTertiary
        taskLabel.font = Theme.Font.listTitle
        taskLabel.textColor = Theme.Color.textPrimary
        detailLabel.font = Theme.Font.body
        detailLabel.textColor = Theme.Color.textTertiary
        searchIcon.image = Self.symbol(Theme.Symbol.search)
        searchIcon.contentTintColor = Theme.Color.textTertiary
        for label in [spaceLabel, taskLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = true
            label.setAccessibilityElement(false)
        }
        for view: NSView in [spaceChip, spaceLabel, spaceChevron, taskIcon, taskLabel, detailLabel, searchIcon, searchKey, waitingBadge, waitingKey] {
            view.setAccessibilityElement(false)
            host.addSubview(view)
        }
        for _ in 0..<3 {
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = Theme.Color.line.cgColor
            separators.append(line)
            host.addSubview(line)
        }
        let actions: [(NiruxButton, Selector)] = [
            (spaceButton, #selector(spacePressed)), (taskButton, #selector(taskPressed)),
            (searchButton, #selector(searchPressed)), (waitingButton, #selector(waitingPressed)),
        ]
        for (button, action) in actions {
            button.target = self
            button.action = action
            host.addSubview(button)
        }
        searchButton.setAccessibilityLabel("Search, Command P")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
    }

    /// Shows `content`, updating the views in place.
    func show(_ content: Content) {
        guard content != self.content else { return }
        self.content = content
        spaceChip.layer?.backgroundColor = content.spaceColor.cgColor
        spaceLabel.stringValue = content.spaceName
        spaceButton.setAccessibilityLabel("Space: \(content.spaceName)")
        taskLabel.stringValue = content.taskTitle ?? "Nothing open"
        taskLabel.textColor = content.taskTitle == nil ? Theme.Color.textTertiary : Theme.Color.textPrimary
        if let icon = content.taskIcon { taskIcon.icon = icon }
        taskIcon.isHidden = content.taskIcon == nil
        detailLabel.stringValue = content.taskDetail.map { "· \($0)" } ?? ""
        taskButton.setAccessibilityLabel([content.taskTitle, content.taskIcon?.accessibilityText, content.taskDetail]
            .compactMap { $0 }.joined(separator: ", "))
        waitingBadge.count = content.waitingCount
        let waiting = content.waitingCount
        waitingButton.setAccessibilityLabel(
            "\(waiting) agent\(waiting == 1 ? "" : "s") waiting for you, Command J"
        )
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layoutSegments()
    }

    private func layoutSegments() {
        let height = bounds.height
        let waits = (content?.waitingCount ?? 0) > 0
        func textWidth(_ label: NSTextField) -> CGFloat { ceil(label.attributedStringValue.size().width) + 4 }
        let chip: CGFloat = 10, chevron: CGFloat = 10, icon: CGFloat = 13

        // The widths each segment wants, then what gives way.
        var showsDetail = !(content?.taskDetail ?? "").isEmpty
        var showsSpaceName = true
        var showsSearchKey = true
        func spaceWidth() -> CGFloat {
            showsSpaceName
                ? Self.inset + chip + Self.gap + textWidth(spaceLabel) + 6 + chevron + Self.inset
                : Self.inset + chip + Self.inset
        }
        func searchWidth() -> CGFloat {
            12 + icon + (showsSearchKey ? Self.gap + searchKey.fittingWidth : 0) + 12
        }
        let waitingWidth = waits ? 10 + waitingBadge.fittingWidth + 7 + waitingKey.fittingWidth + 12 : 0
        func taskWidth() -> CGFloat { bounds.width - spaceWidth() - searchWidth() - waitingWidth }
        func taskNeed() -> CGFloat {
            let iconSpace = taskIcon.isHidden ? 0 : icon + Self.gap
            let detail = showsDetail ? 6 + textWidth(detailLabel) : 0
            return Self.inset + iconSpace + min(textWidth(taskLabel), Self.titleMinimum) + detail + Self.inset
        }
        if taskWidth() < taskNeed() { showsDetail = false }
        if taskWidth() < taskNeed() { showsSpaceName = false }
        if taskWidth() < taskNeed() { showsSearchKey = false }

        var x: CGFloat = 0
        func center(_ view: NSView, x: CGFloat, width: CGFloat, height viewHeight: CGFloat) {
            view.frame = NSRect(x: x, y: ((height - viewHeight) / 2).rounded(), width: width, height: viewHeight)
        }
        func place(_ label: NSTextField, x: CGFloat, width: CGFloat) {
            let lineHeight = ceil(label.font?.boundingRectForFont.height ?? 16)
            center(label, x: x, width: max(0, width), height: lineHeight)
        }
        // Space.
        let space = spaceWidth()
        center(spaceChip, x: Self.inset, width: chip, height: chip)
        spaceLabel.isHidden = !showsSpaceName
        spaceChevron.isHidden = !showsSpaceName
        if showsSpaceName {
            let nameX = Self.inset + chip + Self.gap
            place(spaceLabel, x: nameX, width: textWidth(spaceLabel))
            center(spaceChevron, x: nameX + textWidth(spaceLabel) + 6, width: chevron, height: chevron)
        }
        spaceButton.frame = NSRect(x: 3, y: 3, width: space - 6, height: height - 6)
        x = space
        separators[0].frame = NSRect(x: x, y: 9, width: 1, height: height - 18)

        // Task: what's left, its title cut before anything else of it.
        let task = max(0, taskWidth())
        var taskX = x + Self.inset
        taskIcon.frame.origin = NSPoint(x: taskX, y: ((height - icon) / 2).rounded())
        if !taskIcon.isHidden { taskX += icon + Self.gap }
        let taskEnd = x + task - Self.inset
        detailLabel.isHidden = !showsDetail
        let detail = showsDetail ? min(textWidth(detailLabel), max(0, taskEnd - taskX) / 2) : 0
        let title = min(textWidth(taskLabel), max(0, taskEnd - taskX - (showsDetail ? 6 + detail : 0)))
        place(taskLabel, x: taskX, width: title)
        if showsDetail { place(detailLabel, x: taskX + title + 6, width: detail) }
        taskButton.frame = NSRect(x: x + 3, y: 3, width: max(0, task - 6), height: height - 6)
        x += task
        separators[1].frame = NSRect(x: x, y: 9, width: 1, height: height - 18)

        // Search.
        let search = searchWidth()
        center(searchIcon, x: x + 12, width: icon, height: icon)
        searchKey.isHidden = !showsSearchKey
        if showsSearchKey { center(searchKey, x: x + 12 + icon + Self.gap, width: searchKey.fittingWidth, height: KeyCap.height) }
        searchButton.frame = NSRect(x: x + 3, y: 3, width: search - 6, height: height - 6)
        x += search

        // Waiting: only while an agent waits.
        separators[2].isHidden = !waits
        waitingBadge.isHidden = !waits
        waitingKey.isHidden = !waits
        waitingButton.isHidden = !waits
        if waits {
            separators[2].frame = NSRect(x: x, y: 9, width: 1, height: height - 18)
            center(waitingBadge, x: x + 10, width: waitingBadge.fittingWidth, height: CountBadge.height)
            center(waitingKey, x: x + 10 + waitingBadge.fittingWidth + 7, width: waitingKey.fittingWidth, height: KeyCap.height)
            waitingButton.frame = NSRect(x: x + 3, y: 3, width: waitingWidth - 6, height: height - 6)
        }
    }

    @objc private func spacePressed() { onSpace?() }
    @objc private func taskPressed() { onTask?() }
    @objc private func searchPressed() { onSearch?() }
    @objc private func waitingPressed() { onWaiting?() }
}

/// A shortcut shown as a key cap: "⌘P".
final class KeyCap: NSView {
    static let height: CGFloat = 18
    private let label: NSTextField

    init(_ text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.chip
        layer?.borderWidth = 1
        layer?.borderColor = Theme.Color.lineStrong.cgColor
        label.font = Theme.Font.caption
        label.textColor = Theme.Color.textSecondary
        label.alignment = .center
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var fittingWidth: CGFloat { ceil(label.attributedStringValue.size().width) + 10 }

    override func layout() {
        super.layout()
        let lineHeight = ceil(label.font?.boundingRectForFont.height ?? 14)
        label.frame = NSRect(x: 0, y: ((bounds.height - lineHeight) / 2).rounded(), width: bounds.width, height: lineHeight)
    }
}

/// How many agents wait for the user: an amber disc with the count. Amber,
/// because that is all it says.
final class CountBadge: NSView {
    static let height: CGFloat = 18
    private let label = NSTextField(labelWithString: "")

    var count = 0 {
        didSet { label.stringValue = "\(count)" }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.waiting.cgColor
        label.font = Theme.Font.captionEmphasized
        label.textColor = Theme.Color.canvas
        label.alignment = .center
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var fittingWidth: CGFloat { max(Self.height, ceil(label.attributedStringValue.size().width) + 10) }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let lineHeight = ceil(label.font?.boundingRectForFont.height ?? 14)
        label.frame = NSRect(x: 0, y: ((bounds.height - lineHeight) / 2).rounded(), width: bounds.width, height: lineHeight)
    }
}
