import AppKit

/// A view among a column header's accessories: the terminal's dev-server
/// chip, its context usage, or a column's text button. It gives up room
/// when the header is narrow: it returns the width it takes within
/// `maxWidth`, 0 to be hidden (an empty accessory takes none).
@MainActor
protocol ColumnHeaderAccessory: NSView {
    func width(fitting maxWidth: CGFloat) -> CGFloat
    /// Its height in the bar, centered.
    var accessoryHeight: CGFloat { get }
    /// Blank its frame keeps on each side of what it draws (a label cell's
    /// margin): the gaps around it absorb it.
    var accessoryInset: CGFloat { get }
}

extension ColumnHeaderAccessory {
    var accessoryHeight: CGFloat { ColumnHeaderButton.size }
    var accessoryInset: CGFloat { 0 }
}

/// The bar on top of every column: terminal, editor, browser, Project Board,
/// and any new column type. 30 pt on `surface`, with the same slots in the
/// same places whatever the column shows:
///
///     [icon] [leading buttons] [title] [context…] [status] [accessories] [buttons] [⋯]
///
/// - icon: the column's type, or the running agent's app icon. Accent
///   while the column has the focus; the title stays primary.
/// - title: what runs or shows (the process, the active file).
/// - context: where (folder, file directory, repository): machine text,
///   truncated in the middle. A column may put its own view in place of
///   title and context (the browser's URL field).
/// - status: a pill, only for an agent or a run.
/// - buttons: the column's own icon actions, two at most; the ⋯ menu holds
///   the rest. A text button goes among the accessories.
///
/// When the bar runs out of room, the context goes first, then the
/// accessories, the status, the trailing buttons and the leading ones,
/// whose actions then head the ⋯ menu. Narrowing the bar never brings
/// back what it hid.
///
/// A new column type puts one on top of its view, `height` tall, sets its
/// icon (the terminal's by default), title, context, buttons and
/// `menuProvider` (a fresh menu each time, ending with
/// `columnMenuItems()`), and returns it from `ColumnState.header` so that
/// it follows the focus. The header shows and hides its buttons itself: to
/// drop one, take it out of its array.
@MainActor
final class ColumnHeaderView: NSView {
    static let height: CGFloat = 30

    enum Icon: Equatable {
        /// An SF Symbol, tinted by the focus.
        case symbol(String)
        /// An image drawn as is: an agent's app icon.
        case image(NSImage)
    }

    /// A status's color: the state it tells (`Theme.Color`'s states).
    enum Tone: Equatable { case neutral, working, waiting, error, done, success }

    struct Status: Equatable {
        var text: String
        var tone: Tone
        /// SF Symbol before the text; nil draws a dot.
        var symbol: String?
        /// The symbol's own tone when it differs from the pill's (a green
        /// check on a neutral pill).
        var symbolTone: Tone?
        var toolTip: String?

        init(_ text: String, tone: Tone, symbol: String? = nil, symbolTone: Tone? = nil, toolTip: String? = nil) {
            self.text = text
            self.tone = tone
            self.symbol = symbol
            self.symbolTone = symbolTone
            self.toolTip = toolTip
        }
    }

    var icon: Icon = .symbol(Theme.Symbol.terminal) {
        didSet { if icon != oldValue { applyIcon() } }
    }
    var title = "" {
        didSet {
            guard title != oldValue else { return }
            titleLabel.stringValue = title
            menuButton.setAccessibilityLabel(title.isEmpty ? "More actions" : "More actions: \(title)")
            needsLayout = true
        }
    }
    /// The title's tooltip; when nil, the title itself while it is cut
    /// short.
    var titleToolTip: String? {
        didSet { applyTitleToolTip() }
    }
    private var isTitleCutShort = false
    var context = "" {
        didSet {
            guard context != oldValue else { return }
            contextLabel.stringValue = context
            contextLabel.toolTip = context.isEmpty ? nil : context
            needsLayout = true
        }
    }
    var status: Status? {
        didSet {
            guard status != oldValue else { return }
            statusPill.status = status
            needsLayout = true
        }
    }
    var isFocused = false {
        didSet { if isFocused != oldValue { applyIcon() } }
    }
    /// Buttons right after the icon (the browser's back, forward, reload).
    var leadingButtons: [ColumnHeaderButton] = [] {
        didSet { replace(oldValue, with: leadingButtons) }
    }
    /// The column's own actions, before ⋯. Two at most.
    var trailingButtons: [ColumnHeaderButton] = [] {
        didSet { replace(oldValue, with: trailingButtons) }
    }
    var accessories: [ColumnHeaderAccessory] = [] {
        didSet { replace(oldValue, with: accessories) }
    }
    /// Shown in place of title and context, as tall as a button.
    var centerView: NSView? {
        didSet {
            guard centerView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let centerView { addSubview(centerView) }
            needsLayout = true
        }
    }
    /// The ⋯ menu, built each time it opens. Without one, ⋯ shows only to
    /// hold buttons the bar has no room for.
    var menuProvider: (() -> NSMenu)? {
        didSet { needsLayout = true }
    }

    let menuButton = ColumnHeaderButton(symbol: Theme.Symbol.more, toolTip: "More")
    /// Buttons hidden for lack of room, in bar order: their actions head
    /// the ⋯ menu.
    private(set) var overflowButtons: [ColumnHeaderButton] = []

    let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let contextLabel = NSTextField(labelWithString: "")
    let statusPill = ColumnStatusPill()
    private let bottomLine = NSView()

    // The validated mockup's insets: 10 before the icon, 6 after ⋯.
    private static let leadingInset: CGFloat = 10
    private static let trailingInset: CGFloat = 6
    private static let gap = Theme.Space.sm
    private static let buttonGap: CGFloat = 2
    private static let iconSize: CGFloat = 14
    /// A symbol's image runs wider than its point size: its view is wider
    /// than the slot, centered on it, and draws it unscaled.
    private static let iconFrame: CGFloat = 18
    private static let textHeight: CGFloat = 16
    /// Room the title (or the center view) keeps before the other slots
    /// give way.
    static let minimumTitleWidth: CGFloat = 60
    private static let minimumContextWidth: CGFloat = 40
    private static let minimumTitleBesideContext: CGFloat = 80
    /// The margin an NSTextField cell keeps on each side of its text.
    static let labelInset: CGFloat = 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.surface.cgColor

        iconView.cell?.setAccessibilityElement(false)
        addSubview(iconView)

        titleLabel.font = Theme.Font.bodyEmphasized
        titleLabel.textColor = Theme.Color.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        contextLabel.font = Theme.Font.mono
        contextLabel.textColor = Theme.Color.textTertiary
        contextLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(contextLabel)

        statusPill.isHidden = true
        addSubview(statusPill)

        menuButton.target = self
        menuButton.action = #selector(showMenu(_:))
        menuButton.setAccessibilityLabel("More actions")
        menuButton.isHidden = true
        addSubview(menuButton)

        bottomLine.wantsLayer = true
        bottomLine.layer?.backgroundColor = Theme.Color.line.cgColor
        addSubview(bottomLine)

        applyIcon()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// As the terminal's title bar did: the window may move from the bar
    /// (where the window allows it), never from its controls.
    override var mouseDownCanMoveWindow: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// Lays the slots out now rather than before the next display: what
    /// the column just changed is in place for whoever reads it next.
    func layoutNow() {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func replace(_ old: [NSView], with new: [NSView]) {
        for view in old where !new.contains(where: { $0 === view }) { view.removeFromSuperview() }
        for view in new where view.superview !== self { addSubview(view) }
        needsLayout = true
    }

    /// Set only when it changes: a terminal's title changes several times
    /// a second while its agent works, and a new tooltip closes the one
    /// shown.
    private func applyTitleToolTip() {
        let toolTip = titleToolTip ?? (isTitleCutShort ? title : nil)
        if titleLabel.toolTip != toolTip { titleLabel.toolTip = toolTip }
    }

    private func applyIcon() {
        switch icon {
        case .symbol(let name):
            iconView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Self.iconSize, weight: .regular))
            assert(iconView.image != nil, "No SF Symbol named \(name)")
            iconView.imageScaling = .scaleNone
            iconView.contentTintColor = isFocused ? Theme.Color.accent : Theme.Color.textTertiary
        case .image(let image):
            // An app icon keeps a margin inside its artwork: drawn in the
            // whole frame, it looks the size of a symbol.
            let sized = image.copy() as? NSImage ?? image
            sized.size = NSSize(width: Self.iconFrame, height: Self.iconFrame)
            iconView.image = sized
            iconView.imageScaling = .scaleProportionallyDown
            iconView.contentTintColor = nil
        }
    }

    /// The width a label draws its whole text in, its cell's margins
    /// included: a truncating label's intrinsic width leaves them out, and
    /// truncates.
    static func textWidth(_ label: NSTextField) -> CGFloat {
        ceil(label.cell?.cellSize.width ?? label.intrinsicContentSize.width)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        bottomLine.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        iconView.frame = NSRect(
            x: Self.leadingInset - (Self.iconFrame - Self.iconSize) / 2,
            y: ((bounds.height - Self.iconFrame) / 2).rounded(),
            width: Self.iconFrame, height: Self.iconFrame
        )
        let buttonsToShow = !leadingButtons.isEmpty || !trailingButtons.isEmpty
        layoutSlots(showsMenu: menuProvider != nil)
        // A button left without room needs ⋯ to be reached.
        if menuProvider == nil, buttonsToShow, !overflowButtons.isEmpty { layoutSlots(showsMenu: true) }
    }

    /// From the right edge leftwards: ⋯, the trailing buttons, the
    /// accessories, the status; then the leading buttons and the middle.
    /// Buttons sit 2 pt apart, everything else a gap. Each slot shows only
    /// while every slot before it in that order does.
    private func layoutSlots(showsMenu: Bool) {
        let height = bounds.height
        let buttonSize = ColumnHeaderButton.size
        let buttonY = ((height - buttonSize) / 2).rounded()
        let leadingStart = Self.leadingInset + Self.iconSize + Self.gap
        func leadingEnd(_ count: Int) -> CGFloat {
            count == 0 ? leadingStart
                : leadingStart + CGFloat(count) * (buttonSize + Self.buttonGap) - Self.buttonGap + Self.gap
        }
        var edge = bounds.width - Self.trailingInset
        var lastWasButton: Bool?
        func gap(beforeButton isButton: Bool) -> CGFloat {
            guard let lastWasButton else { return 0 }
            return lastWasButton && isButton ? Self.buttonGap : Self.gap
        }
        /// The frame's x for a slot `width` wide whose drawing is inset by
        /// `inset` on each side.
        func place(_ width: CGFloat, isButton: Bool, inset: CGFloat = 0) -> CGFloat {
            let maxX = edge - gap(beforeButton: isButton) + inset
            edge = maxX - width + inset
            lastWasButton = isButton
            return maxX - width
        }
        // What the middle keeps before a slot on the right gives way.
        let titleWidth = Self.textWidth(titleLabel) - 2 * Self.labelInset
        let middleNeed = centerView != nil ? Self.minimumTitleWidth : min(max(0, titleWidth), Self.minimumTitleWidth)
        func room(beforeButton isButton: Bool, reserving reserved: CGFloat = 0) -> CGFloat {
            edge - gap(beforeButton: isButton) - Self.gap - leadingEnd(leadingButtons.count) - middleNeed - reserved
        }

        menuButton.isHidden = !showsMenu
        if showsMenu {
            menuButton.frame = NSRect(x: place(buttonSize, isButton: true), y: buttonY, width: buttonSize, height: buttonSize)
        }
        // The rightmost trailing buttons that fit.
        var shownTrailing: [ColumnHeaderButton] = []
        for button in trailingButtons.reversed() {
            guard room(beforeButton: true) >= buttonSize else { break }
            button.frame = NSRect(x: place(buttonSize, isButton: true), y: buttonY, width: buttonSize, height: buttonSize)
            shownTrailing.append(button)
        }
        var gaveWay = shownTrailing.count < trailingButtons.count

        // The status keeps its room before the accessories take theirs.
        let pillWidth = statusPill.idealWidth
        let showsStatus = status != nil && !gaveWay && room(beforeButton: false) >= pillWidth
        if status != nil, !showsStatus { gaveWay = true }
        let statusReserve = showsStatus ? pillWidth + Self.gap : 0
        for accessory in accessories.reversed() {
            let inset = accessory.accessoryInset
            let fitting = room(beforeButton: false, reserving: statusReserve) + 2 * inset
            let width = gaveWay ? 0 : accessory.width(fitting: max(0, fitting))
            accessory.isHidden = width == 0
            guard width > 0 else {
                if accessory.width(fitting: .greatestFiniteMagnitude) > 0 { gaveWay = true }
                continue
            }
            let accessoryHeight = min(accessory.accessoryHeight, height)
            accessory.frame = NSRect(
                x: place(width, isButton: false, inset: inset), y: ((height - accessoryHeight) / 2).rounded(),
                width: width, height: accessoryHeight
            )
        }
        statusPill.isHidden = !showsStatus
        if showsStatus {
            statusPill.frame = NSRect(
                x: place(pillWidth, isButton: false), y: ((height - ColumnStatusPill.height) / 2).rounded(),
                width: pillWidth, height: ColumnStatusPill.height
            )
        }
        let middleEnd = lastWasButton == nil ? edge : edge - Self.gap

        // The leading buttons that leave the middle its room, from the left.
        var leadingCount = leadingButtons.count
        while leadingCount > 0, middleEnd - leadingEnd(leadingCount) < middleNeed { leadingCount -= 1 }
        for (index, button) in leadingButtons.enumerated() where index < leadingCount {
            let x = leadingStart + CGFloat(index) * (buttonSize + Self.buttonGap)
            button.frame = NSRect(x: x, y: buttonY, width: buttonSize, height: buttonSize)
        }
        let shownLeading = Array(leadingButtons.prefix(leadingCount))
        gaveWay = gaveWay || leadingCount < leadingButtons.count
        overflowButtons = (leadingButtons + trailingButtons).filter { button in
            !shownLeading.contains { $0 === button } && !shownTrailing.contains { $0 === button }
        }
        for button in leadingButtons + trailingButtons {
            button.isHidden = overflowButtons.contains { $0 === button }
        }

        let middleStart = leadingEnd(leadingCount)
        let middleWidth = max(0, middleEnd - middleStart)
        if let centerView {
            titleLabel.isHidden = true
            contextLabel.isHidden = true
            centerView.isHidden = middleWidth < Self.minimumTitleWidth
            centerView.frame = NSRect(x: middleStart, y: buttonY, width: middleWidth, height: buttonSize)
            return
        }
        layoutTitle(x: middleStart, width: middleWidth, titleWidth: titleWidth, showsContext: !gaveWay)
    }

    /// The title takes what it needs, but no more than what leaves the
    /// context its full width, or 40 % of the room when both are long. The
    /// context goes when it would squeeze the title further. Widths here
    /// are the texts'; each label's frame adds its cell's margins.
    private func layoutTitle(x: CGFloat, width: CGFloat, titleWidth: CGFloat, showsContext: Bool) {
        let inset = Self.labelInset
        titleLabel.isHidden = title.isEmpty
        let textY = ((bounds.height - Self.textHeight) / 2).rounded()
        let contextWidth = Self.textWidth(contextLabel) - 2 * inset
        var shownTitleWidth = title.isEmpty ? 0 : min(titleWidth, max(width * 0.4, width - contextWidth - Self.gap))
        let contextX = title.isEmpty ? x : x + shownTitleWidth + Self.gap
        let contextRoom = x + width - contextX
        contextLabel.isHidden = !showsContext || context.isEmpty || contextRoom < Self.minimumContextWidth
            || shownTitleWidth < min(titleWidth, Self.minimumTitleBesideContext)
        if contextLabel.isHidden { shownTitleWidth = min(titleWidth, width) }
        isTitleCutShort = shownTitleWidth < titleWidth
        applyTitleToolTip()
        titleLabel.frame = NSRect(x: x - inset, y: textY, width: max(0, shownTitleWidth) + 2 * inset, height: Self.textHeight)
        contextLabel.frame = NSRect(x: contextX - inset, y: textY, width: max(0, contextRoom) + 2 * inset, height: Self.textHeight)
    }

    // MARK: - Menu

    /// The ⋯ menu as it opens now: the hidden buttons' actions, then the
    /// column's own items, bound to this header's column.
    func currentMenu() -> NSMenu {
        let menu = menuProvider?() ?? NSMenu()
        for item in menu.items where item.representedObject is ColumnCommand {
            item.target = self
        }
        guard !overflowButtons.isEmpty else { return menu }
        for (index, button) in overflowButtons.enumerated() {
            let item = NSMenuItem(title: button.menuTitle, action: button.isEnabled ? button.action : nil, keyEquivalent: "")
            item.target = button.target
            item.state = button.isOn ? .on : .off
            menu.insertItem(item, at: index)
        }
        if menu.items.count > overflowButtons.count { menu.insertItem(.separator(), at: overflowButtons.count) }
        return menu
    }

    @objc private func showMenu(_ sender: NSButton) {
        let below = NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 2 : -2)
        currentMenu().popUp(positioning: nil, at: below, in: sender)
    }

    /// Runs a column item on this header's column: it takes the focus
    /// first, as a click in it does, so the item can't reach the column
    /// the focus moved to meanwhile, nor one a keyboard press left focused.
    @objc func runColumnCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? ColumnCommand,
              let shell = sequence(first: superview, next: { $0?.superview }).lazy.compactMap({ $0 as? NiruxShellView }).first,
              shell.focusColumn(withHeader: self)
        else { return }
        command.perform(shell)
    }

    /// What every column's ⋯ menu ends with: moving, resizing and closing
    /// the column.
    static func columnMenuItems() -> [NSMenuItem] {
        [
            columnItem("Move Left", mainMenuAction: #selector(NiruxApp.moveColumnLeft(_:))) { $0.moveColumn(.left) },
            columnItem("Move Right", mainMenuAction: #selector(NiruxApp.moveColumnRight(_:))) { $0.moveColumn(.right) },
            columnItem("Cycle Width", mainMenuAction: #selector(NiruxApp.cycleWidth(_:))) { $0.cycleActiveColumnWidth() },
            .separator(),
            columnItem("Close Column", mainMenuAction: #selector(NiruxApp.closeColumn(_:))) { $0.closeActiveColumn() }
        ]
    }

    /// A ⋯ item doing to the header's column what `mainMenuAction` does to
    /// the focused one (`perform`), with that main-menu item's shortcut.
    static func columnItem(
        _ title: String, mainMenuAction: Selector, perform: @escaping @MainActor (NiruxShellView) -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runColumnCommand(_:)), keyEquivalent: "")
        item.representedObject = ColumnCommand(perform)
        if let shortcut = NSApp?.mainMenu.flatMap({ Self.item(in: $0, action: mainMenuAction) }) {
            item.keyEquivalent = shortcut.keyEquivalent
            item.keyEquivalentModifierMask = shortcut.keyEquivalentModifierMask
        }
        return item
    }

    private static func item(in menu: NSMenu, action: Selector) -> NSMenuItem? {
        for item in menu.items {
            if item.action == action, !item.isAlternate { return item }
            if let found = item.submenu.flatMap({ self.item(in: $0, action: action) }) { return found }
        }
        return nil
    }
}

/// What a column item does, carried by its menu item.
@MainActor
final class ColumnCommand: NSObject {
    let perform: @MainActor (NiruxShellView) -> Void

    init(_ perform: @escaping @MainActor (NiruxShellView) -> Void) {
        self.perform = perform
    }
}

/// A 22 pt icon button of a column header: secondary, filled while hovered
/// or pressed, accent on a selected fill while its toggle is on.
@MainActor
final class ColumnHeaderButton: NSButton {
    static let size: CGFloat = 22

    /// A toggle's state (the editor's diff).
    var isOn = false {
        didSet { applyColors() }
    }
    override var isEnabled: Bool {
        didSet { applyColors() }
    }
    /// Its item's title in ⋯ when the bar has no room for it: its first
    /// tooltip, which a column may change to say more.
    private(set) var menuTitle = ""
    /// Hidden under the pointer, it would never hear the mouse leave.
    override var isHidden: Bool {
        didSet { if isHidden { isHovered = false } }
    }

    private var isHovered = false {
        didSet { applyColors() }
    }
    private var isPressed = false {
        didSet { applyColors() }
    }
    private var hoverArea: NSTrackingArea?

    convenience init(symbol: String, toolTip: String) {
        self.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        assert(image != nil, "No SF Symbol named \(symbol)")
        self.toolTip = toolTip
        menuTitle = toolTip
        setAccessibilityLabel(toolTip)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.control
        // A click leaves the keyboard where it was (the terminal, Monaco).
        refusesFirstResponder = true
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Filled while the button tracks the mouse (the cell draws no
    /// highlight of its own without a border).
    override func mouseDown(with event: NSEvent) {
        isPressed = true
        super.mouseDown(with: event)
        isPressed = false
    }

    private func applyColors() {
        let fill: NSColor
        if isOn {
            fill = Theme.Color.fillSelected
        } else if isPressed, isEnabled {
            fill = Theme.Color.fillPressed
        } else if isHovered, isEnabled {
            fill = Theme.Color.fillHover
        } else {
            fill = .clear
        }
        layer?.backgroundColor = fill.cgColor
        contentTintColor = !isEnabled ? Theme.Color.textDisabled
            : isOn ? Theme.Color.accent : Theme.Color.textSecondary
    }
}

/// A caption among a header's accessories (the terminal's context usage):
/// hidden while empty or when it doesn't fit.
@MainActor
final class ColumnHeaderLabel: NSTextField, ColumnHeaderAccessory {
    convenience init() {
        self.init(labelWithString: "")
        font = NSFont.monospacedDigitSystemFont(ofSize: Theme.Font.caption.pointSize, weight: .regular)
        textColor = Theme.Color.textTertiary
    }

    var accessoryHeight: CGFloat { 16 }
    var accessoryInset: CGFloat { ColumnHeaderView.labelInset }

    func width(fitting maxWidth: CGFloat) -> CGFloat {
        guard !stringValue.isEmpty else { return 0 }
        let width = ColumnHeaderView.textWidth(self)
        return width <= maxWidth ? width : 0
    }
}

/// The header's status: a dot or a symbol, then a short text, on a pill
/// tinted by the state. A working agent's dot breathes.
@MainActor
final class ColumnStatusPill: NSView {
    static let height: CGFloat = 18
    private static let padding: CGFloat = 7
    private static let gap: CGFloat = 5
    private static let dotSize: CGFloat = 6
    private static let symbolSize: CGFloat = 12

    var status: ColumnHeaderView.Status? {
        didSet { if status != oldValue { apply() } }
    }

    let label = NSTextField(labelWithString: "")
    private let symbolView = NSImageView()
    private let dot = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        label.font = NSFont.monospacedDigitSystemFont(ofSize: Theme.Font.caption.pointSize, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        symbolView.imageScaling = .scaleNone
        symbolView.cell?.setAccessibilityElement(false)
        addSubview(symbolView)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSize / 2
        addSubview(dot)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var idealWidth: CGFloat {
        guard status != nil else { return 0 }
        let markWidth = status?.symbol == nil ? Self.dotSize : Self.symbolSize
        return Self.padding * 2 + markWidth + Self.gap - 2 * 2 + ColumnHeaderView.textWidth(label)
    }

    static func color(_ tone: ColumnHeaderView.Tone) -> NSColor {
        switch tone {
        case .neutral: Theme.Color.textSecondary
        case .working: Theme.Color.working
        case .waiting: Theme.Color.waiting
        case .error: Theme.Color.error
        case .done: Theme.Color.done
        case .success: Theme.Color.success
        }
    }

    static func fill(_ tone: ColumnHeaderView.Tone) -> NSColor {
        switch tone {
        case .neutral: Theme.Color.fillHover
        case .working: Theme.Color.working.withAlphaComponent(0.12)
        case .waiting: Theme.Color.waiting.withAlphaComponent(0.16)
        case .error: Theme.Color.error.withAlphaComponent(0.15)
        case .done: Theme.Color.done.withAlphaComponent(0.14)
        case .success: Theme.Color.success.withAlphaComponent(0.12)
        }
    }

    private func apply() {
        guard let status else {
            dot.layer?.removeAnimation(forKey: "breathe")
            return
        }
        layer?.backgroundColor = Self.fill(status.tone).cgColor
        label.stringValue = status.text
        label.textColor = Self.color(status.tone)
        toolTip = status.toolTip
        setAccessibilityLabel(status.toolTip ?? status.text)
        let markColor = Self.color(status.symbolTone ?? status.tone)
        if let symbol = status.symbol {
            symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Self.symbolSize, weight: .regular))
            assert(symbolView.image != nil, "No SF Symbol named \(symbol)")
            symbolView.contentTintColor = markColor
        } else {
            dot.layer?.backgroundColor = markColor.cgColor
        }
        symbolView.isHidden = status.symbol == nil
        dot.isHidden = status.symbol != nil
        updateBreathing()
        needsLayout = true
    }

    /// A working agent's dot breathes, unless the user reduces motion.
    private func updateBreathing() {
        guard let dotLayer = dot.layer else { return }
        let breathes = status?.tone == .working && status?.symbol == nil
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if breathes, dotLayer.animation(forKey: "breathe") == nil {
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1.0
            breathe.toValue = 0.35
            breathe.duration = 0.9
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dotLayer.add(breathe, forKey: "breathe")
        } else if !breathes {
            dotLayer.removeAnimation(forKey: "breathe")
        }
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        var x = Self.padding
        if status?.symbol == nil {
            dot.frame = NSRect(x: x, y: ((height - Self.dotSize) / 2).rounded(), width: Self.dotSize, height: Self.dotSize)
            x += Self.dotSize + Self.gap
        } else {
            symbolView.frame = NSRect(
                x: x, y: ((height - Self.symbolSize) / 2).rounded(), width: Self.symbolSize, height: Self.symbolSize
            )
            x += Self.symbolSize + Self.gap
        }
        // The label's cell margin is part of the gap and the padding.
        let labelHeight: CGFloat = 14
        label.frame = NSRect(
            x: x - 2, y: ((height - labelHeight) / 2).rounded(),
            width: max(0, bounds.width - x - Self.padding + 4), height: labelHeight
        )
    }
}
