import AppKit

/// Space Settings › General: the space's name and color, and its
/// repositories and folders (docs/spaces.md, "Spaces and anchors"): each
/// with its setup script, its GitHub repository, and which one is the
/// default. The name applies on Return or when the field is left, every
/// other control at once; the shell writes (see `Actions`) and sends the
/// new state back with `update(_:)`.
@MainActor
final class SpaceSettingsGeneralPane: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    struct Row: Equatable {
        let anchor: SpaceAnchor
        let key: String
        /// The main checkout or the folder; nil for a bare repository.
        let folder: String?
        /// `owner/name` of its GitHub remote, once read.
        var gitHub: String?
        var hasScript: Bool
    }

    struct Model: Equatable {
        var name: String
        var colorHex: String
        /// General has no repositories.
        var isGeneral: Bool
        var rows: [Row]
        /// projects.json can't be written: anchors can't change.
        var anchorsLocked: Bool
    }

    struct Actions {
        /// False when refused (an empty or taken name): the field shows the
        /// old name again.
        var rename: @MainActor (String) -> Bool = { _ in false }
        var recolor: @MainActor (String) -> Void = { _ in }
        var addRepository: @MainActor () -> Void = {}
        var addFolder: @MainActor () -> Void = {}
        var remove: @MainActor (String) -> Void = { _ in }
        var makeDefault: @MainActor (String) -> Void = { _ in }
        var editScript: @MainActor (SpaceAnchor) -> Void = { _ in }
    }

    static let width: CGFloat = 680
    private static let insets = NSEdgeInsets(top: 20, left: 28, bottom: 24, right: 28)
    private static var contentWidth: CGFloat { width - insets.left - insets.right }

    let view = NSView()
    let nameField = NSTextField()
    let colorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let tableView = NSTableView()
    let emptyLabel = NSTextField(labelWithString: "No repository or folder yet.")
    let addRepositoryButton = NSButton(title: "Add Repository…", target: nil, action: nil)
    let addFolderButton = NSButton(title: "Add Folder…", target: nil, action: nil)
    let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let repositoriesSection = NSStackView()

    private(set) var model: Model
    var actions = Actions()

    init(model: Model) {
        self.model = model
        super.init()
        build()
        update(model)
    }

    func update(_ model: Model) {
        let selectedKey = self.model.rows[safe: tableView.selectedRow]?.key
        // A pop-up menu open on screen isn't rebuilt under the pointer.
        let colorChanged = model.colorHex != self.model.colorHex || colorPopup.numberOfItems == 0
        self.model = model
        // Leaves typed text alone while the field is being edited.
        if nameField.currentEditor() == nil { nameField.stringValue = model.name }
        if colorChanged { fillColors() }
        repositoriesSection.isHidden = model.isGeneral
        tableView.reloadData()
        if let selectedKey, let row = model.rows.firstIndex(where: { $0.key == selectedKey }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        emptyLabel.isHidden = !model.rows.isEmpty
        for button in [addRepositoryButton, addFolderButton] { button.isEnabled = !model.anchorsLocked }
        updateRemoveButton()
        tableView.isEnabled = !model.anchorsLocked
        if model.isGeneral {
            noteLabel.stringValue = "General takes the workspaces no other space claims: it has no repositories."
        } else if model.anchorsLocked {
            noteLabel.stringValue = NiruxShellView.anchorsLockedMessage + "."
        } else {
            noteLabel.stringValue = "A plain new workspace opens in the default one. A worktree Nirux makes for you "
                + "runs its repository’s setup script before the agent starts."
        }
    }

    /// "Rename Space…": the name, selected.
    func focusName() {
        view.window?.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }

    // MARK: - Actions

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === nameField else { return }
        commitName()
    }

    @objc func commitName() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != model.name, actions.rename(name) else {
            nameField.stringValue = model.name
            return
        }
        model.name = name
        nameField.stringValue = name
    }

    @objc func colorChanged(_ sender: NSPopUpButton) {
        guard let hex = sender.selectedItem?.representedObject as? String, hex != model.colorHex else { return }
        actions.recolor(hex)
    }

    @objc func addRepository(_ sender: Any?) { actions.addRepository() }

    @objc func addFolder(_ sender: Any?) { actions.addFolder() }

    @objc func removeSelected(_ sender: Any?) {
        guard !model.anchorsLocked, let row = model.rows[safe: tableView.selectedRow] else { return }
        actions.remove(row.key)
    }

    @objc func defaultClicked(_ sender: NSButton) {
        guard let row = model.rows[safe: sender.tag] else { return }
        // A radio button: the click turned it on; the update says what holds.
        if !row.anchor.isDefault, !model.anchorsLocked { actions.makeDefault(row.key) }
        tableView.reloadData()
    }

    @objc func scriptClicked(_ sender: NSButton) {
        guard let row = model.rows[safe: sender.tag] else { return }
        actions.editScript(row.anchor)
    }

    private func updateRemoveButton() {
        removeButton.isEnabled = !model.anchorsLocked && model.rows.indices.contains(tableView.selectedRow)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButton()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn?.identifier.rawValue, let item = model.rows[safe: row] else { return nil }
        switch column {
        case "repository":
            let name = NSTextField(labelWithString: item.anchor.name)
            name.font = .systemFont(ofSize: 12, weight: .semibold)
            name.lineBreakMode = .byTruncatingTail
            let path = NSTextField(labelWithString: item.folder?.abbreviatedPath(maxComponents: 6) ?? "bare repository")
            path.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
            path.textColor = .secondaryLabelColor
            path.lineBreakMode = .byTruncatingMiddle
            path.toolTip = item.folder
            let stack = NSStackView(views: [name, path])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 1
            return Self.cell(stack)
        case "script":
            guard case .gitRepository = item.anchor.kind else {
                return Self.cell(Self.secondaryLabel("—", tooltip: "Only repositories have a setup script."))
            }
            let button = NSButton(title: item.hasScript ? "Edit…" : "Add…", target: self, action: #selector(scriptClicked(_:)))
            button.controlSize = .small
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.tag = row
            button.setAccessibilityLabel("\(item.hasScript ? "Edit" : "Add") the setup script of \(item.anchor.name)")
            return Self.cell(button)
        case "github":
            let label = Self.secondaryLabel(item.gitHub ?? "—", tooltip: item.gitHub.map { "github.com/\($0)" })
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            return Self.cell(label)
        default:
            let radio = NSButton(radioButtonWithTitle: "", target: self, action: #selector(defaultClicked(_:)))
            radio.state = item.anchor.isDefault ? .on : .off
            radio.tag = row
            radio.isEnabled = !model.anchorsLocked
            radio.setAccessibilityLabel(item.anchor.isDefault
                ? "\(item.anchor.name) is the default" : "Make \(item.anchor.name) the default")
            return Self.cell(radio)
        }
    }

    private static func secondaryLabel(_ text: String, tooltip: String?) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = tooltip
        return label
    }

    /// `content` centered vertically at the cell's leading edge.
    private static func cell(_ content: NSView) -> NSView {
        let cell = NSTableCellView()
        content.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            content.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            content.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    // MARK: - Construction

    private func fillColors() {
        colorPopup.removeAllItems()
        var palette = WorkspaceProfile.palette
        if !palette.contains(where: { $0.hex.caseInsensitiveCompare(model.colorHex) == .orderedSame }) {
            palette.append((name: "Custom", hex: model.colorHex))
        }
        for color in palette {
            let item = NSMenuItem(title: color.name, action: nil, keyEquivalent: "")
            item.representedObject = color.hex
            item.image = Self.swatch(SidebarView.profileColor(hex: color.hex))
            colorPopup.menu?.addItem(item)
            if color.hex.caseInsensitiveCompare(model.colorHex) == .orderedSame { colorPopup.select(item) }
        }
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }

    private func build() {
        view.translatesAutoresizingMaskIntoConstraints = false

        nameField.placeholderString = "Space name"
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(commitName)
        nameField.setAccessibilityLabel("Space name")
        colorPopup.target = self
        colorPopup.action = #selector(colorChanged(_:))
        colorPopup.setAccessibilityLabel("Space color")

        let form = NSGridView(views: [
            [Self.formLabel("Name"), nameField],
            [Self.formLabel("Color"), colorPopup]
        ])
        form.rowSpacing = 10
        form.columnSpacing = 10
        form.column(at: 0).xPlacement = .trailing
        form.rowAlignment = .firstBaseline
        nameField.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let header = NSTextField(labelWithString: "Repositories and folders")
        header.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        let columns: [(String, String, CGFloat)] = [
            ("repository", "Repository", 270), ("script", "Setup Script", 100), ("github", "GitHub", 150), ("default", "Default", 56)
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = min(width, 56)
            tableView.addTableColumn(column)
        }
        tableView.rowHeight = 38
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("Repositories and folders")
        scroll.documentView = tableView
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(emptyLabel)

        for (button, action) in [(addRepositoryButton, #selector(addRepository(_:))), (addFolderButton, #selector(addFolder(_:))),
                                 (removeButton, #selector(removeSelected(_:)))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        addFolderButton.toolTip = "A folder of its own, even inside a repository: workspaces opened in it or below join the space."
        let buttons = NSStackView(views: [addRepositoryButton, addFolderButton, NSView(), removeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        noteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.isSelectable = false
        noteLabel.preferredMaxLayoutWidth = Self.contentWidth

        repositoriesSection.orientation = .vertical
        repositoriesSection.alignment = .leading
        repositoriesSection.spacing = 8
        for subview in [header, scroll, buttons] as [NSView] { repositoriesSection.addArrangedSubview(subview) }

        let stack = NSStackView(views: [form, repositoriesSection, noteLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.edgeInsets = Self.insets
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: Self.width),
            scroll.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            scroll.heightAnchor.constraint(equalToConstant: 196),
            buttons.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            noteLabel.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: 10)
        ])
    }

    private static func formLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        return label
    }
}
