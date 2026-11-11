import AppKit

/// Space Settings › Defaults (docs/design/projects.md, section 5): the agent its
/// tasks preselect, the Claude and Codex launch modes, and environment
/// variables for new shells. Each change is written at once
/// (SpaceDefaultsStore); a variable list with a problem isn't, until it's
/// fixed. A launch takes an explicit choice first, then these, then
/// Settings.
@MainActor
final class SpaceSettingsDefaultsPane: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    struct Actions {
        /// Writes the defaults: what the file holds now, or why it failed.
        var save: @MainActor (SpaceDefaults, SpaceDefaultsStore.Loaded) -> Result<SpaceDefaultsStore.Loaded, SpaceDefaultsStore.SaveError> = {
            _, loaded in .success(loaded)
        }
        /// Reads the file again (after a failed save).
        var reload: @MainActor () -> SpaceDefaultsStore.Loaded = { SpaceDefaultsStore.Loaded(defaults: SpaceDefaults(), status: .missing) }
        /// Settings' modes, which "Same as Settings" stands for.
        var settingsClaudeMode: @MainActor () -> ClaudeLaunchMode = { .default }
        var settingsCodexMode: @MainActor () -> CodexLaunchMode = { .default }
    }

    static let width: CGFloat = 680
    private static let insets = NSEdgeInsets(top: 20, left: 28, bottom: 24, right: 28)
    private static var contentWidth: CGFloat { width - insets.left - insets.right }
    /// "Same as Settings" in the mode pop-ups.
    static let settingsChoice = ""

    let view = NSView()
    let agentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let claudePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let codexPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let tableView = NSTableView()
    let addButton = NSButton(title: "Add Variable", target: nil, action: nil)
    let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    let problemsLabel = NSTextField(wrappingLabelWithString: "")
    let warningsLabel = NSTextField(wrappingLabelWithString: "")
    let bannerLabel = NSTextField(wrappingLabelWithString: "")

    private(set) var loaded: SpaceDefaultsStore.Loaded
    /// The variables as listed, typed ones included.
    private(set) var rows: [SpaceDefaults.EnvironmentVariable]
    var actions: Actions

    init(loaded: SpaceDefaultsStore.Loaded, actions: Actions) {
        self.loaded = loaded
        self.rows = loaded.defaults.environment
        self.actions = actions
        super.init()
        build()
        show(loaded)
    }

    /// Shows what the file holds, dropping typed variables.
    func show(_ loaded: SpaceDefaultsStore.Loaded, message: String? = nil) {
        self.loaded = loaded
        rows = loaded.defaults.environment
        fillPopups()
        tableView.reloadData()
        let writable = loaded.isWritable
        for control in [agentPopup, claudePopup, codexPopup, addButton, tableView] as [NSControl] { control.isEnabled = writable }
        updateRemoveButton()
        let banner: String?
        if let message {
            banner = message
        } else if case .readOnly(let reason) = loaded.status {
            banner = reason.message
        } else if loaded.status == .unreadable {
            banner = "defaults.json can’t be read: the next change keeps a copy of it (defaults.corrupt.….json) and replaces it."
        } else {
            banner = nil
        }
        bannerLabel.stringValue = banner ?? ""
        bannerLabel.isHidden = banner == nil
        showProblems()
    }

    // MARK: - Pop-ups

    private func fillPopups() {
        let defaults = loaded.defaults
        agentPopup.removeAllItems()
        for (agent, title) in NewTaskPanel.agents {
            agentPopup.addItem(withTitle: title)
            agentPopup.lastItem?.representedObject = agent.rawValue
        }
        SettingsForm.select(defaults.taskAgent.rawValue, in: agentPopup)

        fill(claudePopup, settings: Self.shortName(actions.settingsClaudeMode().displayName),
             modes: ClaudeLaunchMode.allCases.map { ($0.rawValue, $0.displayName) },
             selected: defaults.claudeLaunchMode?.rawValue)
        fill(codexPopup, settings: Self.shortName(actions.settingsCodexMode().displayName),
             modes: CodexLaunchMode.allCases.map { ($0.rawValue, $0.displayName) },
             selected: defaults.codexLaunchMode?.rawValue)
    }

    private func fill(_ popup: NSPopUpButton, settings: String, modes: [(String, String)], selected: String?) {
        popup.removeAllItems()
        let first = NSMenuItem(title: "Same as Settings (\(settings))", action: nil, keyEquivalent: "")
        first.representedObject = Self.settingsChoice
        popup.menu?.addItem(first)
        popup.menu?.addItem(.separator())
        for (raw, title) in modes {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = raw
            popup.menu?.addItem(item)
        }
        SettingsForm.select(selected ?? Self.settingsChoice, in: popup)
    }

    /// "Accept edits (file edits + …)" reads "Accept edits".
    static func shortName(_ displayName: String) -> String {
        displayName.components(separatedBy: " (").first ?? displayName
    }

    @objc func agentChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let agent = NiruxApp.WorkspaceAgent(rawValue: raw)
        else { return }
        var defaults = loaded.defaults
        defaults.agent = agent
        guard defaults != loaded.defaults else { return }
        write(defaults)
    }

    @objc func claudeModeChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String else { return }
        var defaults = loaded.defaults
        defaults.claudeLaunchMode = ClaudeLaunchMode(rawValue: raw)
        guard defaults != loaded.defaults else { return }
        write(defaults)
    }

    @objc func codexModeChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String else { return }
        var defaults = loaded.defaults
        defaults.codexLaunchMode = CodexLaunchMode(rawValue: raw)
        guard defaults != loaded.defaults else { return }
        write(defaults)
    }

    /// Typed variables stay listed: a failed write shows the file again,
    /// with why.
    private func write(_ defaults: SpaceDefaults) {
        switch actions.save(defaults, loaded) {
        case .success(let saved):
            let typed = rows
            loaded = saved
            rows = typed
            bannerLabel.isHidden = true
            showProblems()
        case .failure(let error):
            writeFailed = true
            show(actions.reload(), message: error.message)
        }
    }

    // MARK: - Environment

    @objc func addVariable(_ sender: Any?) {
        rows.append(SpaceDefaults.EnvironmentVariable(name: "", value: ""))
        tableView.reloadData()
        let row = rows.count - 1
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.editColumn(0, row: row, with: nil, select: true)
    }

    @objc func removeVariable(_ sender: Any?) {
        let row = tableView.selectedRow
        guard rows.indices.contains(row) else { return }
        view.window?.makeFirstResponder(nil)
        // Ending the edit may have dropped an empty row.
        guard rows.indices.contains(row) else { return }
        rows.remove(at: row)
        tableView.reloadData()
        commitEnvironment()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, rows.indices.contains(field.tag) else { return }
        if field.identifier?.rawValue == "name" {
            rows[field.tag].name = field.stringValue.trimmingCharacters(in: .whitespaces)
        } else {
            rows[field.tag].value = field.stringValue
        }
        commitEnvironment()
    }

    /// Variables typed and not written (a problem holds them back).
    var hasUnsavedRows: Bool { rows != loaded.defaults.environment }

    /// Writes the typed variables; false while a problem holds them back,
    /// or when the write failed (the pane then says why).
    func saveRows() -> Bool {
        writeFailed = false
        view.window?.makeFirstResponder(nil)
        commitEnvironment()
        return !writeFailed && !hasUnsavedRows
    }

    /// The last write failed: the pane shows the file again, with why.
    private var writeFailed = false

    /// Writes the list unless a variable has a problem; an empty row goes.
    func commitEnvironment() {
        let before = rows.count
        rows.removeAll { $0.name.isEmpty && $0.value.isEmpty }
        if rows.count != before { tableView.reloadData() }
        var defaults = loaded.defaults
        defaults.environment = rows
        guard defaults.environmentProblems.isEmpty else { return showProblems() }
        guard defaults != loaded.defaults else { return showProblems() }
        write(defaults)
    }

    private func showProblems() {
        var draft = loaded.defaults
        draft.environment = rows
        let problems = draft.environmentProblems
        problemsLabel.stringValue = problems.isEmpty ? "" : (problems + ["Fix them to save the variables."]).joined(separator: "\n")
        problemsLabel.isHidden = problems.isEmpty
        let warnings = draft.environmentWarnings
        warningsLabel.stringValue = warnings.joined(separator: "\n")
        warningsLabel.isHidden = warnings.isEmpty
        updateRemoveButton()
    }

    private func updateRemoveButton() {
        removeButton.isEnabled = loaded.isWritable && rows.indices.contains(tableView.selectedRow)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButton()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier.rawValue, let variable = rows[safe: row] else { return nil }
        let field = NSTextField(string: identifier == "name" ? variable.name : variable.value)
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.tag = row
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = loaded.isWritable
        field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.placeholderString = identifier == "name" ? "NAME" : "value"
        field.delegate = self
        field.setAccessibilityLabel(identifier == "name" ? "Variable name" : "Value of \(variable.name)")
        let cell = NSTableCellView()
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    // MARK: - Construction

    private func build() {
        view.translatesAutoresizingMaskIntoConstraints = false
        for (popup, action, label) in [
            (agentPopup, #selector(agentChanged(_:)), "Agent for new tasks"),
            (claudePopup, #selector(claudeModeChanged(_:)), "Claude Code permission mode"),
            (codexPopup, #selector(codexModeChanged(_:)), "Codex mode")
        ] {
            popup.target = self
            popup.action = action
            popup.setAccessibilityLabel(label)
        }
        let form = NSGridView(views: [
            [Self.formLabel("Agent for new tasks"), agentPopup],
            [Self.formLabel("Claude Code permissions"), claudePopup],
            [Self.formLabel("Codex mode"), codexPopup]
        ])
        form.rowSpacing = 10
        form.columnSpacing = 10
        form.column(at: 0).xPlacement = .trailing
        form.rowAlignment = .firstBaseline

        let formHint = Self.hint(
            "New Task… preselects this agent; a plain new workspace stays a shell. A launch uses these modes unless "
                + "you choose one for it, and Settings’ modes when they say Same as Settings."
        )

        let header = NSTextField(labelWithString: "Environment")
        header.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        for (identifier, title, width) in [("name", "Name", CGFloat(200)), ("value", "Value", CGFloat(400))] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.rowHeight = 24
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("Environment variables")
        scroll.documentView = tableView

        for (button, action) in [(addButton, #selector(addVariable(_:))), (removeButton, #selector(removeVariable(_:)))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        let buttons = NSStackView(views: [addButton, removeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let envHint = Self.hint(
            "Set in new shells of the workspaces you start in this space, not in ones opened from outside Nirux. "
                + "Values are literal: $PATH isn’t expanded. NIRUX_ names are reserved. They are kept in this space’s "
                + "defaults.json, readable only by you: keep secrets in the Keychain or a secret manager instead."
        )
        problemsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        problemsLabel.textColor = .systemRed
        problemsLabel.isSelectable = false
        problemsLabel.preferredMaxLayoutWidth = Self.contentWidth
        warningsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        warningsLabel.textColor = .systemOrange
        warningsLabel.isSelectable = false
        warningsLabel.preferredMaxLayoutWidth = Self.contentWidth
        bannerLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        bannerLabel.textColor = .systemOrange
        bannerLabel.isSelectable = false
        bannerLabel.preferredMaxLayoutWidth = Self.contentWidth

        let environment = NSStackView(views: [header, scroll, buttons, problemsLabel, warningsLabel, envHint])
        environment.orientation = .vertical
        environment.alignment = .leading
        environment.spacing = 8

        let stack = NSStackView(views: [bannerLabel, form, formHint, environment])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(22, after: formHint)
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
            scroll.heightAnchor.constraint(equalToConstant: 150),
            bannerLabel.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            problemsLabel.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            warningsLabel.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            envHint.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            formHint.widthAnchor.constraint(equalToConstant: Self.contentWidth)
        ])
    }

    private static func formLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        return label
    }

    private static func hint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.preferredMaxLayoutWidth = contentWidth
        return label
    }
}
