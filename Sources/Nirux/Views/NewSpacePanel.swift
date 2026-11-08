import AppKit

/// "New Space…": a sheet on the main window with the space's name, its
/// color and its repositories or folders (see SpaceAnchor), one of them
/// the default. The shell picks and checks the folders ("Add Repository…",
/// "Add Folder…") and hands them back with `add(_:movingFrom:)`; Create
/// Space hands the draft over and closes the sheet.
@MainActor
final class NewSpacePanel: NSObject, NSTextFieldDelegate {
    struct Row: Equatable {
        var anchor: SpaceAnchor
        /// The space it is taken from, when it belongs to another.
        var movingFrom: String?
    }

    struct Draft: Equatable {
        let name: String
        let colorHex: String
        let anchors: [SpaceAnchor]
        /// "Start a Lead" (docs/spaces.md, "The Lead"): off unless chosen.
        var startsLead = false
    }

    var onAddRepository: (() -> Void)?
    var onAddFolder: (() -> Void)?
    var onCreate: ((Draft) -> Void)?
    var onDismiss: (() -> Void)?

    private(set) var panel: NSPanel?
    private(set) var rows: [Row] = []
    private(set) var colorHex = WorkspaceProfile.palette[0].hex
    /// The user typed a name: the default repository no longer names the
    /// space.
    private(set) var nameIsEdited = false

    let nameField = NSTextField()
    let addRepositoryButton = NSButton(title: "Add Repository…", target: nil, action: nil)
    let addFolderButton = NSButton(title: "Add Folder…", target: nil, action: nil)
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    let leadSwitch = NSSwitch()
    let createButton = NSButton(title: "Create Space", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private(set) var swatches: [ColorSwatchButton] = []
    private(set) var rowViews: [AnchorRowView] = []

    private let content = NewSpaceFlippedView()
    private let heading = NSTextField(labelWithString: "New Space")
    private let nameLabel = NSTextField(labelWithString: "Name")
    private let colorLabel = NSTextField(labelWithString: "Color")
    private let sectionLabel = NSTextField(labelWithString: "")
    private let sectionHint = NSTextField(labelWithString: "Where this space’s work starts. Optional: a space can have none.")
    private let note = NSTextField(wrappingLabelWithString:
        "A repository belongs to one space: its worktrees open here, even when you are looking at another space.")
    private let leadSectionLabel = NSTextField(labelWithString: "")
    private let leadTitle = NSTextField(labelWithString: "Start a Lead")
    private let leadHint = NSTextField(wrappingLabelWithString: "")
    private let separator = NSBox()
    private static let width: CGFloat = 520
    private static let margin: CGFloat = 24

    // Explicit, so the controls' default values are made on the main actor
    // with every toolchain.
    override init() {
        super.init()
    }

    /// `suggestion`: the focused terminal's repository, already in the
    /// list and naming the space.
    func show(attachedTo window: NSWindow, colorHex: String, suggestion: SpaceAnchor?) {
        self.colorHex = colorHex
        rows = []
        nameIsEdited = false
        leadSwitch.state = .off
        let panel = buildPanel()
        self.panel = panel
        if let suggestion { add(suggestion, movingFrom: nil) } else { layout() }
        window.beginSheet(panel)
        panel.makeFirstResponder(nameField)
    }

    func dismiss() {
        guard let panel else { return }
        panel.sheetParent?.endSheet(panel)
        panel.orderOut(nil)
        self.panel = nil
        onDismiss?()
    }

    // MARK: - Rows

    /// Adds a repository or folder; one already listed is left as it is.
    /// The first one becomes the default.
    func add(_ anchor: SpaceAnchor, movingFrom: String?) {
        guard panel != nil, anchor.isKnown, !rows.contains(where: { $0.anchor.key == anchor.key }) else { return }
        var added = anchor
        added.isDefault = rows.isEmpty
        rows.append(Row(anchor: added, movingFrom: movingFrom))
        rowsChanged()
    }

    func remove(at index: Int) {
        guard rows.indices.contains(index) else { return }
        let wasDefault = rows[index].anchor.isDefault
        rows.remove(at: index)
        if wasDefault, !rows.isEmpty { rows[0].anchor.isDefault = true }
        rowsChanged()
    }

    func makeDefault(at index: Int) {
        guard rows.indices.contains(index) else { return }
        for row in rows.indices { rows[row].anchor.isDefault = row == index }
        rowsChanged()
    }

    func selectColor(_ hex: String) {
        colorHex = hex
        for swatch in swatches { swatch.isChosen = swatch.colorHex.caseInsensitiveCompare(hex) == .orderedSame }
    }

    private func rowsChanged() {
        hideError()
        if !nameIsEdited { nameField.stringValue = rows.first(where: \.anchor.isDefault)?.anchor.name ?? "" }
        layout()
    }

    // MARK: - Values

    /// The space to create, or nil with the reason shown. With no name
    /// typed, the default repository's name.
    var draft: Draft? {
        let typed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = typed.isEmpty ? (rows.first(where: \.anchor.isDefault)?.anchor.name ?? "") : typed
        guard !name.isEmpty else {
            showError("Name the space.")
            panel?.makeFirstResponder(nameField)
            return nil
        }
        return Draft(name: name, colorHex: colorHex, anchors: rows.map(\.anchor), startsLead: leadSwitch.state == .on)
    }

    func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        layout()
    }

    private func hideError() {
        guard !errorLabel.isHidden else { return }
        errorLabel.isHidden = true
        layout()
    }

    // MARK: - Actions

    @objc func createAction(_ sender: Any?) {
        guard panel != nil, let draft else { return }
        let onCreate = onCreate
        dismiss()
        onCreate?(draft)
    }

    @objc func cancelAction(_ sender: Any?) {
        dismiss()
    }

    @objc private func addRepositoryAction(_ sender: Any?) {
        hideError()
        onAddRepository?()
    }

    @objc private func addFolderAction(_ sender: Any?) {
        hideError()
        onAddFolder?()
    }

    @objc private func swatchClicked(_ sender: ColorSwatchButton) {
        selectColor(sender.colorHex)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === nameField else { return }
        hideError()
        // Cleared: the default repository names the space again.
        nameIsEdited = !nameField.stringValue.isEmpty
    }

    // MARK: - Construction

    private func buildPanel() -> NSPanel {
        nameField.font = .systemFont(ofSize: 13)
        nameField.placeholderString = "Space name"
        nameField.usesSingleLineMode = true
        nameField.lineBreakMode = .byTruncatingTail
        nameField.delegate = self
        nameField.stringValue = ""
        nameField.setAccessibilityLabel("Name")

        swatches = WorkspaceProfile.palette.map { color in
            let swatch = ColorSwatchButton(colorHex: color.hex, name: color.name)
            swatch.target = self
            swatch.action = #selector(swatchClicked(_:))
            return swatch
        }
        selectColor(colorHex)

        for button in [addRepositoryButton, addFolderButton] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.target = self
        }
        addRepositoryButton.image = NSImage(systemSymbolName: Theme.Symbol.add, accessibilityDescription: nil)
        addRepositoryButton.imagePosition = .imageLeading
        addRepositoryButton.action = #selector(addRepositoryAction(_:))
        addFolderButton.image = NSImage(systemSymbolName: Theme.Symbol.openWorktree, accessibilityDescription: nil)
        addFolderButton.imagePosition = .imageLeading
        addFolderButton.action = #selector(addFolderAction(_:))

        errorLabel.font = Theme.Font.caption
        errorLabel.textColor = Theme.Color.error
        errorLabel.maximumNumberOfLines = 0
        errorLabel.isHidden = true

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelAction(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        createButton.bezelStyle = .rounded
        createButton.target = self
        createButton.action = #selector(createAction(_:))
        createButton.keyEquivalent = "\r"

        heading.font = Theme.Font.display
        heading.textColor = Theme.Color.textPrimary
        for label in [nameLabel, colorLabel, sectionHint] {
            label.font = Theme.Font.caption
            label.textColor = Theme.Color.textSecondary
            label.lineBreakMode = .byTruncatingTail
        }
        sectionLabel.attributedStringValue = NSAttributedString(string: "REPOSITORIES", attributes: [
            .font: Theme.Font.label, .foregroundColor: Theme.Color.textTertiary, .kern: Theme.Font.labelKern
        ])
        note.font = Theme.Font.caption
        note.textColor = Theme.Color.textTertiary
        leadSectionLabel.attributedStringValue = NSAttributedString(string: "LEAD", attributes: [
            .font: Theme.Font.label, .foregroundColor: Theme.Color.textTertiary, .kern: Theme.Font.labelKern
        ])
        leadSwitch.controlSize = .small
        leadSwitch.setAccessibilityLabel("Start a Lead")
        leadTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        leadTitle.textColor = Theme.Color.textPrimary
        leadTitle.setAccessibilityElement(false)
        leadHint.font = Theme.Font.caption
        leadHint.textColor = Theme.Color.textSecondary
        leadHint.maximumNumberOfLines = 0
        leadHint.setAccessibilityElement(false)
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = Theme.Color.line
        // Added once: `layout` only moves them, so the field being edited
        // keeps the keyboard.
        content.subviews.forEach { $0.removeFromSuperview() }
        let persistent: [NSView] = [
            heading, nameLabel, nameField, colorLabel, sectionLabel, sectionHint, addRepositoryButton, addFolderButton,
            note, leadSectionLabel, leadSwitch, leadTitle, leadHint, errorLabel, separator, cancelButton, createButton
        ] + swatches
        persistent.forEach(content.addSubview)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.appearance = Theme.appearance
        panel.backgroundColor = Theme.Color.base
        panel.isReleasedWhenClosed = false
        panel.autorecalculatesKeyViewLoop = true
        panel.contentView = content
        return panel
    }

    /// Places everything from the top; the sheet takes the height it needs.
    /// Only the rows are rebuilt.
    private func layout() {
        guard let panel else { return }
        let margin = Self.margin
        let inner = Self.width - margin * 2
        var y: CGFloat = 22

        heading.frame = NSRect(x: margin, y: y, width: inner, height: 20)
        y += 36
        y = place(nameLabel, y: y, height: 14) + 6
        nameField.frame = NSRect(x: margin, y: y, width: inner, height: 26)
        y += 26 + 18

        y = place(colorLabel, y: y, height: 14) + 8
        for (index, swatch) in swatches.enumerated() {
            swatch.frame = NSRect(x: margin + CGFloat(index) * 30, y: y, width: 22, height: 22)
        }
        y += 22 + 22

        y = place(sectionLabel, y: y, height: 13) + 3
        y = place(sectionHint, y: y, height: 15) + 10

        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = rows.enumerated().map { index, row in
            let view = AnchorRowView(row: row)
            view.onRemove = { [weak self] in self?.remove(at: index) }
            view.onMakeDefault = { [weak self] in self?.makeDefault(at: index) }
            return view
        }
        for view in rowViews {
            view.frame = NSRect(x: margin, y: y, width: inner, height: AnchorRowView.height)
            content.addSubview(view)
            y += AnchorRowView.height + 8
        }

        let repositorySize = addRepositoryButton.fittingSize
        addRepositoryButton.frame = NSRect(x: margin - 6, y: y, width: repositorySize.width + 8, height: repositorySize.height)
        let folderSize = addFolderButton.fittingSize
        addFolderButton.frame = NSRect(
            x: addRepositoryButton.frame.maxX + 2, y: y, width: folderSize.width + 8, height: folderSize.height
        )
        y += repositorySize.height + 12

        y = place(note, y: y, height: Self.wrappedHeight(of: note, width: inner)) + 20

        y = place(leadSectionLabel, y: y, height: 13) + 8
        let switchSize = leadSwitch.fittingSize
        leadSwitch.frame = NSRect(x: margin, y: y, width: switchSize.width, height: switchSize.height)
        let textX = margin + switchSize.width + 10
        let textWidth = Self.width - margin - textX
        leadTitle.frame = NSRect(x: textX, y: y, width: textWidth, height: 16)
        leadHint.stringValue = SpaceSettingsLeadPane.description(place: leadPlace, spaceName: nil)
        leadSwitch.setAccessibilityHelp(leadHint.stringValue)
        let hintHeight = Self.wrappedHeight(of: leadHint, width: textWidth)
        leadHint.frame = NSRect(x: textX, y: y + 19, width: textWidth, height: hintHeight)
        y += max(switchSize.height, 19 + hintHeight) + 16

        if !errorLabel.isHidden {
            y = place(errorLabel, y: y, height: Self.wrappedHeight(of: errorLabel, width: inner)) + 10
        }

        separator.frame = NSRect(x: 0, y: y, width: Self.width, height: 1)
        y += 1 + 14
        createButton.frame = NSRect(x: Self.width - margin - 120, y: y, width: 120, height: 30)
        cancelButton.frame = NSRect(x: createButton.frame.minX - 8 - 96, y: y, width: 96, height: 30)
        y += 30 + 18

        panel.setContentSize(NSSize(width: Self.width, height: y))
        content.frame = NSRect(x: 0, y: 0, width: Self.width, height: y)
        panel.recalculateKeyViewLoop()
    }

    /// Where the Lead would start: the default row's folder.
    private var leadPlace: SpaceSettingsLeadPane.Place {
        guard let anchor = rows.first(where: \.anchor.isDefault)?.anchor else { return .home }
        if case .gitRepository = anchor.kind { return .repository(anchor.name) }
        return .folder(anchor.name)
    }

    private func place(_ view: NSView, y: CGFloat, height: CGFloat) -> CGFloat {
        view.frame = NSRect(x: Self.margin, y: y, width: Self.width - Self.margin * 2, height: height)
        return y + height
    }

    private static func wrappedHeight(of label: NSTextField, width: CGFloat) -> CGFloat {
        label.preferredMaxLayoutWidth = width
        return ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)).height ?? 16)
    }
}

/// One repository or folder of the sheet: its name and path, "Default" or
/// "Make Default", and a remove button.
@MainActor
final class AnchorRowView: NSView {
    static let height: CGFloat = 48

    var onRemove: (() -> Void)?
    var onMakeDefault: (() -> Void)?
    let nameLabel = NSTextField(labelWithString: "")
    let pathLabel = NSTextField(labelWithString: "")
    let defaultChip = NSTextField(labelWithString: "Default")
    let makeDefaultButton = NSButton(title: "Make Default", target: nil, action: nil)
    let removeButton = NSButton(title: "", target: nil, action: nil)
    private let icon = NSImageView()

    override var isFlipped: Bool { true }

    init(row: NewSpacePanel.Row) {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.height))
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.card
        layer?.backgroundColor = Theme.Color.surface.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.Color.line.cgColor

        let isRepository: Bool
        if case .gitRepository = row.anchor.kind { isRepository = true } else { isRepository = false }
        icon.image = NSImage(
            systemSymbolName: isRepository ? Theme.Symbol.branch : Theme.Symbol.openWorktree,
            accessibilityDescription: isRepository ? "Repository" : "Folder"
        )
        icon.contentTintColor = Theme.Color.textSecondary
        addSubview(icon)

        nameLabel.stringValue = row.anchor.name
        nameLabel.font = Theme.Font.bodyEmphasized
        nameLabel.textColor = Theme.Color.textPrimary
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        var path = (row.anchor.folder ?? Self.storedPath(row.anchor)).abbreviatedPath(maxComponents: 4)
        if let from = row.movingFrom { path += " · moves from “\(from)”" }
        pathLabel.stringValue = path
        pathLabel.font = Theme.Font.mono
        pathLabel.textColor = Theme.Color.textSecondary
        pathLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(pathLabel)

        defaultChip.font = Theme.Font.caption
        defaultChip.textColor = Theme.Color.accent
        defaultChip.alignment = .center
        defaultChip.wantsLayer = true
        defaultChip.drawsBackground = true
        defaultChip.backgroundColor = Theme.Color.fillSelected
        defaultChip.layer?.cornerRadius = Theme.Radius.chip
        defaultChip.isHidden = !row.anchor.isDefault
        addSubview(defaultChip)

        makeDefaultButton.isBordered = false
        makeDefaultButton.attributedTitle = NSAttributedString(string: "Make Default", attributes: [
            .font: Theme.Font.caption, .foregroundColor: Theme.Color.accent
        ])
        makeDefaultButton.target = self
        makeDefaultButton.action = #selector(makeDefaultAction(_:))
        makeDefaultButton.isHidden = row.anchor.isDefault
        addSubview(makeDefaultButton)

        removeButton.isBordered = false
        removeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove \(row.anchor.name)")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        removeButton.contentTintColor = Theme.Color.textSecondary
        removeButton.target = self
        removeButton.action = #selector(removeAction(_:))
        removeButton.setAccessibilityLabel("Remove \(row.anchor.name)")
        addSubview(removeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let height = bounds.height
        icon.frame = NSRect(x: 12, y: (height - 16) / 2, width: 16, height: 16)
        removeButton.frame = NSRect(x: bounds.width - 32, y: (height - 24) / 2, width: 24, height: 24)
        var trailing = removeButton.frame.minX - 8
        if !defaultChip.isHidden {
            let width = ceil(defaultChip.fittingSize.width) + 14
            defaultChip.frame = NSRect(x: trailing - width, y: (height - 18) / 2, width: width, height: 18)
            trailing = defaultChip.frame.minX - 8
        }
        if !makeDefaultButton.isHidden {
            let width = ceil(makeDefaultButton.fittingSize.width)
            makeDefaultButton.frame = NSRect(x: trailing - width, y: (height - 20) / 2, width: width, height: 20)
            trailing = makeDefaultButton.frame.minX - 8
        }
        let textX = icon.frame.maxX + 10
        nameLabel.frame = NSRect(x: textX, y: 7, width: max(0, trailing - textX), height: 17)
        pathLabel.frame = NSRect(x: textX, y: 25, width: max(0, trailing - textX), height: 15)
    }

    @objc private func makeDefaultAction(_ sender: Any?) {
        onMakeDefault?()
    }

    @objc private func removeAction(_ sender: Any?) {
        onRemove?()
    }

    private static func storedPath(_ anchor: SpaceAnchor) -> String {
        switch anchor.kind {
        case .gitRepository(let commonDir): return commonDir
        case .folder(let path): return path
        case .unknown: return ""
        }
    }
}

/// A space color to pick: a dot, ringed when chosen.
@MainActor
final class ColorSwatchButton: NSButton {
    let colorHex: String
    let colorName: String
    var isChosen = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(isChosen ? "selected" : nil)
        }
    }

    init(colorHex: String, name: String) {
        self.colorHex = colorHex
        self.colorName = name
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        setAccessibilityLabel(name)
        setAccessibilityRole(.radioButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor.niruxColor(hex: colorHex) ?? Theme.Color.accent
        if isChosen {
            color.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            ring.stroke()
        }
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: isChosen ? 5 : 2, dy: isChosen ? 5 : 2)).fill()
    }
}

private final class NewSpaceFlippedView: NSView {
    override var isFlipped: Bool { true }
}
