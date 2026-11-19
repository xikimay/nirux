import AppKit

/// The glass interface's command bar (docs/design/glass-interface.md): one
/// capsule floating at the top of the window with the space, the current
/// task and its state, ⌘P, and how many agents wait for the user (⌘J).
/// The window's toolbar holds it (`CommandBarToolbar`, step 3.1).
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
        /// Agents waiting for the user's answer in every space, as ⌘J
        /// reaches them (not the column on screen).
        var waitingCount: Int
    }

    static let height: CGFloat = 36
    /// The search segment's: `CommandPalette` knows it opens the palette.
    static let searchButtonID = NSUserInterfaceItemIdentifier("nirux.commandbar.search")
    /// Left and right of each segment's content.
    private static let inset = Theme.Space.md
    private static let gap = Theme.Space.sm
    /// Between a name and its chevron, a title and its detail.
    private static let tight = Theme.Space.xs
    /// Around each segment's hover capsule, and above and below its
    /// separator.
    private static let buttonInset = Theme.Space.xs
    private static let separatorInset = Theme.Space.sm
    /// The task's title keeps at least this much (or all of a shorter one)
    /// before anything else gives way: its detail, then the space's name,
    /// then the search's key, then the waiting count's key.
    private static let titleMinimum: CGFloat = 120
    /// A space's name is cut past this.
    private static let spaceNameMaximum: CGFloat = 160

    var onSpace: (() -> Void)?
    var onTask: (() -> Void)?
    var onSearch: (() -> Void)?
    var onWaiting: (() -> Void)?

    var level: InterfaceTransparency {
        get { glass.level }
        set { glass.level = newValue }
    }
    /// Turns the picked level into the one drawn (the shell's, so that the
    /// window and its chrome agree).
    var resolveLevel: @MainActor (InterfaceTransparency) -> InterfaceTransparency {
        get { glass.resolveLevel }
        set { glass.resolveLevel = newValue }
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
    private let spaceSegment = CommandBarSegment()
    private let taskSegment = CommandBarSegment()
    private let searchSegment = CommandBarSegment()
    private let waitingSegment = CommandBarSegment()
    /// Each segment and the button over it.
    private var segments: [(segment: CommandBarSegment, button: NiruxButton)] {
        [(spaceSegment, spaceButton), (taskSegment, taskButton), (searchSegment, searchButton), (waitingSegment, waitingButton)]
    }
    /// A segment rises whole under the pointer while the interface may move
    /// (`Relief`); false: they lie flat at once.
    var lifts = false {
        didSet {
            guard lifts != oldValue else { return }
            for (segment, button) in segments { button.relief = lifts ? (1, segment) : nil }
        }
    }

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
            // The segments' buttons say it all; VoiceOver reads a control's
            // cell, so the cells go quiet too.
            view.setAccessibilityElement(false)
            (view as? NSControl)?.cell?.setAccessibilityElement(false)
        }
        let contents: [(CommandBarSegment, [NSView])] = [
            (spaceSegment, [spaceChip, spaceLabel, spaceChevron, spaceButton]),
            (taskSegment, [taskIcon, taskLabel, detailLabel, taskButton]),
            (searchSegment, [searchIcon, searchKey, searchButton]),
            (waitingSegment, [waitingBadge, waitingKey, waitingButton]),
        ]
        for (segment, views) in contents {
            host.addSubview(segment)
            views.forEach(segment.addSubview)
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
        }
        searchButton.setAccessibilityLabel("Search, Command P")
        // A press on it while ⌘P shows closes the palette instead of opening
        // it again (`CommandPalette.searchButtonIDs`).
        searchButton.identifier = Self.searchButtonID
        spaceButton.toolTip = "Spaces"
        searchButton.toolTip = "Search (\(NiruxShortcuts.commandPalette.chord.display), "
            + "\(NiruxShortcuts.commandPaletteAlternate.chord.display) in the editor)"
        waitingButton.toolTip = "Next agent waiting for you (\(NiruxShortcuts.nextWaitingAgent.chord.display))"
        // Before the first content: no state to show, words to say.
        taskIcon.isHidden = true
        spaceButton.setAccessibilityLabel("Space")
        taskButton.setAccessibilityLabel("Nothing open")
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
        // What a click does: the task's menu, or with nothing open, a new task.
        taskButton.toolTip = content.taskTitle == nil
            ? "Start a task (\(NiruxShortcuts.newWorkspace.chord.display))" : "The task's menu"
        if let icon = content.taskIcon { taskIcon.icon = icon }
        taskIcon.isHidden = content.taskIcon == nil
        detailLabel.stringValue = content.taskDetail.map { "· \($0)" } ?? ""
        let taskWords = [content.taskTitle, content.taskIcon?.accessibilityText, content.taskDetail].compactMap { $0 }
        taskButton.setAccessibilityLabel(taskWords.isEmpty ? "Nothing open" : taskWords.joined(separator: ", "))
        waitingBadge.count = content.waitingCount
        let waiting = content.waitingCount
        waitingButton.setAccessibilityLabel(
            "\(waiting) agent\(waiting == 1 ? "" : "s") waiting for you, Command J"
        )
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // As wide as the bar: their views' frames stay the bar's.
        for (segment, _) in segments { segment.frame = segment.superview?.bounds ?? bounds }
        layoutSegments()
        for (segment, button) in segments {
            if let layer = segment.layer { Relief.reshape(layer, shape: button.frame, radius: button.frame.height / 2) }
        }
    }

    private func layoutSegments() {
        let height = bounds.height
        let waits = (content?.waitingCount ?? 0) > 0
        func textWidth(_ label: NSTextField) -> CGFloat { ceil(label.attributedStringValue.size().width) + 4 }
        let chip: CGFloat = 10, chevron: CGFloat = 10, icon: CGFloat = 13
        // Each string measured once.
        let nameWidth = min(textWidth(spaceLabel), Self.spaceNameMaximum)
        let titleWidth = textWidth(taskLabel)
        let detailWidth = textWidth(detailLabel)
        let searchKeyWidth = searchKey.fittingWidth, waitingKeyWidth = waitingKey.fittingWidth
        let badgeWidth = waitingBadge.fittingWidth
        let iconSpace = taskIcon.isHidden ? 0 : icon + Self.gap

        // The widths each segment wants, then what gives way.
        var showsDetail = !(content?.taskDetail ?? "").isEmpty
        var showsSpaceName = true
        var showsSearchKey = true
        var showsWaitingKey = true
        func spaceWidth() -> CGFloat {
            showsSpaceName
                ? Self.inset + chip + Self.gap + nameWidth + Self.tight + chevron + Self.inset
                : Self.inset + chip + Self.inset
        }
        func searchWidth() -> CGFloat {
            Self.inset + icon + (showsSearchKey ? Self.gap + searchKeyWidth : 0) + Self.inset
        }
        func waitingWidth() -> CGFloat {
            guard waits else { return 0 }
            return Self.inset + badgeWidth + (showsWaitingKey ? Self.gap + waitingKeyWidth : 0) + Self.inset
        }
        func taskWidth() -> CGFloat { bounds.width - spaceWidth() - searchWidth() - waitingWidth() }
        func taskNeed() -> CGFloat {
            Self.inset + iconSpace + min(titleWidth, Self.titleMinimum)
                + (showsDetail ? Self.tight + detailWidth : 0) + Self.inset
        }
        if taskWidth() < taskNeed() { showsDetail = false }
        if taskWidth() < taskNeed() { showsSpaceName = false }
        if taskWidth() < taskNeed() { showsSearchKey = false }
        if taskWidth() < taskNeed() { showsWaitingKey = false }

        var x: CGFloat = 0
        func center(_ view: NSView, x: CGFloat, width: CGFloat, height viewHeight: CGFloat) {
            view.frame = NSRect(x: x, y: ((height - viewHeight) / 2).rounded(), width: max(0, width), height: viewHeight)
        }
        func place(_ label: NSTextField, x: CGFloat, width: CGFloat) {
            center(label, x: x, width: width, height: ceil(label.font?.boundingRectForFont.height ?? 16))
        }
        func capsule(_ button: NSView, x: CGFloat, width: CGFloat) {
            let inset = Self.buttonInset
            button.frame = NSRect(x: x + inset, y: inset, width: max(0, width - 2 * inset), height: height - 2 * inset)
        }
        func separator(_ index: Int, at x: CGFloat) {
            separators[index].frame = NSRect(x: x, y: Self.separatorInset, width: 1, height: height - 2 * Self.separatorInset)
        }
        // Space: its name cut past a maximum.
        let space = spaceWidth()
        center(spaceChip, x: Self.inset, width: chip, height: chip)
        spaceLabel.isHidden = !showsSpaceName
        spaceChevron.isHidden = !showsSpaceName
        if showsSpaceName {
            let nameX = Self.inset + chip + Self.gap
            place(spaceLabel, x: nameX, width: nameWidth)
            center(spaceChevron, x: nameX + nameWidth + Self.tight, width: chevron, height: chevron)
        }
        capsule(spaceButton, x: 0, width: space)
        x = space
        separator(0, at: x)

        // Task: what's left; its detail whole when shown, its title cut.
        let task = max(0, taskWidth())
        let taskX = x + Self.inset + iconSpace
        taskIcon.frame.origin = NSPoint(x: x + Self.inset, y: ((height - icon) / 2).rounded())
        let room = max(0, task - 2 * Self.inset - iconSpace)
        detailLabel.isHidden = !showsDetail
        let detail = showsDetail ? min(detailWidth, room) : 0
        let title = min(titleWidth, max(0, room - (showsDetail ? Self.tight + detail : 0)))
        place(taskLabel, x: taskX, width: title)
        if showsDetail { place(detailLabel, x: taskX + title + Self.tight, width: detail) }
        capsule(taskButton, x: x, width: task)
        x += task
        separator(1, at: x)

        // Search.
        let search = searchWidth()
        center(searchIcon, x: x + Self.inset, width: icon, height: icon)
        searchKey.isHidden = !showsSearchKey
        if showsSearchKey {
            center(searchKey, x: x + Self.inset + icon + Self.gap, width: searchKeyWidth, height: KeyCap.height)
        }
        capsule(searchButton, x: x, width: search)
        x += search

        // Waiting: only while an agent waits.
        separators[2].isHidden = !waits
        waitingBadge.isHidden = !waits
        waitingKey.isHidden = !waits || !showsWaitingKey
        waitingButton.isHidden = !waits
        if waits {
            separator(2, at: x)
            center(waitingBadge, x: x + Self.inset, width: badgeWidth, height: CountBadge.height)
            if showsWaitingKey {
                center(waitingKey, x: x + Self.inset + badgeWidth + Self.gap, width: waitingKeyWidth, height: KeyCap.height)
            }
            capsule(waitingButton, x: x, width: waitingWidth())
        }
    }

    @objc private func spacePressed() { onSpace?() }
    @objc private func taskPressed() { onTask?() }
    @objc private func searchPressed() { onSearch?() }
    @objc private func waitingPressed() { onWaiting?() }
}

/// One segment of the bar, its content and its button, as wide as the bar
/// so that their frames stay the bar's: it rises whole (`Relief`). A click
/// beside its views falls through to the segment under it.
private final class CommandBarSegment: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
