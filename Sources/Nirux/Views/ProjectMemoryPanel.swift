import AppKit

/// Project Memory (⌘P › Project Memory…, the project's menu): what agents
/// know about the workspace's repository, in one list (see
/// ProjectMemory.Knowledge): the project brief's rules apply always, the
/// repository's CLAUDE.md and AGENTS.md are the team's, Claude Code's
/// memory is read when relevant. Filtered by text and scope; on the right,
/// the selected item, its `[[links]]` clickable, its file in small. Return,
/// the button or a double click opens that file. An item of the brief or of
/// the memory switches between Always and When relevant, is edited as
/// written, or deleted; "+ Add" adds one (see `Actions`: the shell writes).
/// The team's files change in the editor. The History tab comes later.
@MainActor
final class ProjectMemoryPanel: NSObject {
    static let panelSize = NSSize(width: 900, height: 600)
    static let listWidth: CGFloat = 380
    static let title = "Project Memory"
    static let tabs = ["What agents know", "History"]
    static let openTitle = "Open in Editor"
    static let addTitle = "+ Add"
    static let editTitle = "Edit"
    static let deleteTitle = "Delete…"
    static let saveTitle = "Save"
    static let cancelTitle = "Cancel"

    static func placeholder(repository: String) -> String { "Filter what agents know about \(repository)…" }

    /// What the panel shows: where Claude Code keeps the memory, whether it
    /// uses it, and every item.
    struct Model: Sendable {
        let repository: String
        let location: ProjectMemory.Location
        let knowledge: ProjectMemory.Knowledge
    }

    private var panel: NSPanel?
    private(set) var searchField: NSTextField?
    private(set) var scopeControl: NSSegmentedControl?
    private(set) var summaryLabel: NSTextField?
    private(set) var noticeLabel: NSTextField?
    private(set) var tableView: NSTableView?
    private(set) var preview: ProjectMemoryPreview?
    private(set) var openButton: NSButton?
    private var scrollView: NSScrollView?
    private(set) var noticeRow: NSView?

    /// What the panel asks the shell to do. A write returns whether it
    /// started; one that did ends with `update(model:selecting:)` or
    /// `writeFailed(_:)`, and the panel takes no other until then.
    struct Actions {
        /// A file to open, and the line to show.
        var open: @MainActor (URL, Int?) -> Void = { _, _ in }
        /// An item to move to the other scope.
        var move: @MainActor (ProjectMemory.Target, ProjectMemory.Scope) -> Bool = { _, _ in false }
        /// An item's new text, as written.
        var save: @MainActor (ProjectMemory.Target, String) -> Bool = { _, _ in false }
        var add: @MainActor (ProjectMemoryAddSheet.Item) -> Bool = { _ in false }
        var delete: @MainActor (ProjectMemory.Target) -> Bool = { _ in false }
        /// Asks `alert`'s question; true on its first button.
        var confirm: @MainActor (NSAlert) -> Bool = { $0.runModal() == .alertFirstButtonReturn }
    }

    private(set) var model: Model?
    /// Indexes into `model.knowledge.entries`, as listed.
    private(set) var rows: [Int] = []
    private var actions = Actions()
    /// The item whose text is being edited, and its text as it was.
    private(set) var editing: (target: ProjectMemory.Target, text: String)?
    /// A write the shell runs: the panel takes no other until it ends.
    private(set) var isWriting = false
    private(set) var errorLabel: NSTextField?
    /// The files as read after a refused save, shown once the edit ends.
    private var freshModel: Model?
    /// Counts `show`s: a write started before the last one isn't its.
    private(set) var opening = 0
    /// An item being added: back in its sheet if the write fails.
    private var pendingAdd: ProjectMemoryAddSheet.Item?
    private(set) var addSheet: ProjectMemoryAddSheet?
    private(set) var addButton: NSButton?
    private(set) var editButton: NSButton?
    private(set) var deleteButton: NSButton?
    private(set) var saveButton: NSButton?
    private(set) var cancelButton: NSButton?

    private var keyMonitor: Any?
    private var clickMonitor: Any?

    var isVisible: Bool { panel?.isVisible == true }

    /// The scopes the control offers after "All": team rules apply always.
    static let scopes: [ProjectMemory.Scope] = [.always, .whenRelevant]

    var selectedEntry: ProjectMemory.Entry? {
        guard let table = tableView, let index = rows[safe: table.selectedRow] else { return nil }
        return model?.knowledge.entries[safe: index]
    }

    /// Shows `model` over `window`, filters cleared, the first item
    /// selected.
    func show(relativeTo window: NSWindow, model: Model, actions: Actions) {
        self.model = model
        self.actions = actions
        // A write that ended after a close never reported to this opening.
        opening += 1
        isWriting = false
        editing = nil
        freshModel = nil
        pendingAdd = nil
        errorLabel?.stringValue = ""
        preview?.endEditing()
        setFiltersEnabled(true)
        if panel == nil { createPanel() }
        guard let panel, let searchField else { return }
        searchField.stringValue = ""
        searchField.placeholderString = Self.placeholder(repository: model.repository)
        scopeControl?.selectedSegment = 0
        let notice = model.location.notice
        noticeLabel?.stringValue = notice ?? ""
        noticeLabel?.toolTip = notice
        noticeRow?.isHidden = notice == nil
        layoutBody(noticeShown: notice != nil)

        let frame = window.frame
        panel.setFrame(
            NSRect(
                x: frame.origin.x + (frame.width - Self.panelSize.width) / 2,
                y: frame.origin.y + max(frame.height * 0.55 - Self.panelSize.height / 2, 0),
                width: Self.panelSize.width,
                height: Self.panelSize.height
            ),
            display: true
        )
        installMonitors()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        reload()
    }

    func dismiss() {
        if let sheet = addSheet?.window { panel?.endSheet(sheet) }
        addSheet = nil
        editing = nil
        freshModel = nil
        preview?.endEditing()
        setFiltersEnabled(true)
        removeMonitors()
        panel?.orderOut(nil)
    }

    /// Shows `model` again after a write, the filters kept, the first item
    /// `select` picks selected (the filters cleared when they hide it).
    func update(model: Model, selecting isWanted: (ProjectMemory.Entry) -> Bool) {
        self.model = model
        isWriting = false
        editing = nil
        freshModel = nil
        pendingAdd = nil
        preview?.endEditing()
        setFiltersEnabled(true)
        reload()
        defer { focusField() }
        guard let entry = model.knowledge.entries.firstIndex(where: isWanted) else { return }
        if !rows.contains(entry) {
            searchField?.stringValue = ""
            scopeControl?.selectedSegment = 0
            reload()
        }
        if let row = rows.firstIndex(of: entry) { select(row: row) }
    }

    // MARK: - Rows

    var scope: ProjectMemory.Scope? {
        let segment = scopeControl?.selectedSegment ?? 0
        return segment > 0 ? Self.scopes[safe: segment - 1] : nil
    }

    private var isFiltered: Bool {
        !(searchField?.stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty || scope != nil
    }

    /// Lists what the filters match, the first item selected.
    @objc func reload() {
        guard let knowledge = model?.knowledge else { return }
        rows = ProjectMemory.entries(in: knowledge, text: searchField?.stringValue ?? "", scope: scope)
        summaryLabel?.stringValue = ProjectMemory.summary(of: knowledge, shown: isFiltered ? rows.count : nil)
        tableView?.reloadData()
        if rows.isEmpty {
            updateSelection()
        } else {
            select(row: 0)
        }
    }

    /// Selects the memory in `fileName` (a `[[link]]`'s), clearing the
    /// filters that hide it; the keyboard goes back to the field.
    func reveal(fileName: String) {
        defer { focusField() }
        guard let knowledge = model?.knowledge,
              let entry = knowledge.entries.firstIndex(where: { knowledge.memory(of: $0)?.fileName == fileName })
        else { return NSSound.beep() }
        if !rows.contains(entry) {
            searchField?.stringValue = ""
            scopeControl?.selectedSegment = 0
            reload()
        }
        if let row = rows.firstIndex(of: entry) { select(row: row) }
    }

    private func select(row: Int) {
        guard let table = tableView else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        updateSelection()
    }

    private func moveSelection(by step: Int) {
        guard let table = tableView, !rows.isEmpty else { return }
        select(row: min(max(table.selectedRow + step, 0), rows.count - 1))
    }

    // MARK: - Preview

    private func updateSelection() {
        guard let model else { return }
        editing = nil
        errorLabel?.stringValue = ""
        if let entry = selectedEntry {
            preview?.show(entry, in: model.knowledge, location: model.location)
        } else {
            preview?.showEmpty(Self.emptyText(model: model, filtered: isFiltered))
        }
        updateButtons()
    }

    /// Reading: + Add, Edit and Delete… for what can be; editing: Save and
    /// Cancel; none while a write runs.
    private func updateButtons() {
        let target = selectedTarget
        let isEditing = editing != nil
        openButton?.isEnabled = !isEditing && selectedFile != nil
        addButton?.isHidden = isEditing
        editButton?.isHidden = isEditing
        deleteButton?.isHidden = isEditing
        saveButton?.isHidden = !isEditing
        cancelButton?.isHidden = !isEditing
        addButton?.isEnabled = !isWriting
        editButton?.isEnabled = !isWriting && target.flatMap(Self.editableText) != nil
        deleteButton?.isEnabled = !isWriting && target != nil
        saveButton?.isEnabled = !isWriting
        preview?.scopeControl.isEnabled = !isWriting
    }

    static func emptyText(model: Model, filtered: Bool) -> String {
        guard model.knowledge.entries.isEmpty else { return filtered ? "Nothing matches." : "" }
        return "Agents know nothing about \(model.repository) yet.\n\n"
            + "The project brief’s rules (Edit Project Brief…) apply to every session; "
            + "Claude Code notes what it learns as its sessions work."
    }

    /// What a write would act on for the selected item; nil for a team rule.
    var selectedTarget: ProjectMemory.Target? {
        selectedEntry.flatMap { model?.knowledge.target(of: $0) }
    }

    /// A target's text as written, when it can be edited here: a brief rule
    /// or a memory.
    static func editableText(of target: ProjectMemory.Target) -> String? {
        switch target {
        case .briefRule(let rule, _): return rule.text
        case .memory(let memory, _): return memory.body
        case .missingFile: return nil
        }
    }

    /// While an item is edited, nothing else can be picked: the edit would go.
    private func setFiltersEnabled(_ enabled: Bool) {
        searchField?.isEnabled = enabled
        scopeControl?.isEnabled = enabled
    }

    /// Ends a write that failed, with why: an edit stays as it was typed,
    /// what the files hold now showing once it is cancelled; an item that
    /// was being added comes back in its sheet.
    func writeFailed(_ message: String, model: Model? = nil, selecting isWanted: (ProjectMemory.Entry) -> Bool = { _ in false }) {
        if editing != nil {
            isWriting = false
            freshModel = model
            preview?.setEditable(true)
        } else if let model {
            update(model: model, selecting: isWanted)
        } else {
            isWriting = false
        }
        errorLabel?.stringValue = message
        errorLabel?.toolTip = message
        if let errorLabel {
            NSAccessibility.post(element: errorLabel, notification: .announcementRequested, userInfo: [
                .announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue
            ])
        }
        updateButtons()
        if let item = pendingAdd {
            pendingAdd = nil
            showAddSheet(filledWith: item)
        }
    }

    /// Ends a write whose result the panel doesn't show (it was closed or
    /// reopened since): it takes the next one, unless it was reopened (that
    /// opening's own writes are its own).
    func writeEnded(opening: Int) {
        guard opening == self.opening else { return }
        isWriting = false
        pendingAdd = nil
        updateButtons()
    }

    // MARK: - Writing

    /// Starts a write; false when the panel already waits on one, or when
    /// the shell started none.
    private func write(_ start: () -> Bool) -> Bool {
        guard !isWriting else { NSSound.beep(); return false }
        errorLabel?.stringValue = ""
        isWriting = true
        guard start() else {
            isWriting = false
            pendingAdd = nil
            return false
        }
        // Typed while it is written, it would be lost.
        preview?.setEditable(false)
        updateButtons()
        return true
    }

    @objc func beginEditing() {
        guard !isWriting, let target = selectedTarget, let text = Self.editableText(of: target) else { return NSSound.beep() }
        editing = (target, text)
        setFiltersEnabled(false)
        preview?.beginEditing(text)
        updateButtons()
    }

    /// Writes the edit; an unchanged one just ends, an emptied one is
    /// refused (Delete… asks first).
    @objc func saveEditing() {
        guard let (target, original) = editing, let text = preview?.editedText else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return NSSound.beep() }
        guard trimmed != original.trimmingCharacters(in: .whitespacesAndNewlines) else { return cancelEditing() }
        _ = write { actions.save(target, text) }
    }

    @objc func cancelEditing() {
        guard !isWriting else { return NSSound.beep() }
        let target = editing?.target
        editing = nil
        setFiltersEnabled(true)
        // A refused save read the files again: they show now.
        if let freshModel {
            update(model: freshModel) { [weak self] entry in self?.model?.knowledge.target(of: entry).map { Self.sameItem($0, target) } ?? false }
        } else {
            updateSelection()
        }
        focusField()
    }

    /// The same memory file or brief rule text, read again.
    static func sameItem(_ lhs: ProjectMemory.Target, _ rhs: ProjectMemory.Target?) -> Bool {
        switch (lhs, rhs) {
        case let (.memory(left, _), .memory(right, _)?): return left.fileName == right.fileName
        case let (.briefRule(left, _), .briefRule(right, _)?): return left.text == right.text
        case let (.missingFile(left, _), .missingFile(right, _)?): return left.fileName == right.fileName
        default: return false
        }
    }

    @objc func showAddSheet() {
        showAddSheet(filledWith: nil)
    }

    private func showAddSheet(filledWith item: ProjectMemoryAddSheet.Item?) {
        guard !isWriting, editing == nil, let panel, let model else { return NSSound.beep() }
        let sheet = ProjectMemoryAddSheet()
        addSheet = sheet
        sheet.begin(on: panel, memoryFolder: model.location.directory, allowsMemory: model.location.disabledBy == nil, filledWith: item) { [weak self] item in
            guard let self else { return }
            addSheet = nil
            pendingAdd = item
            _ = write { self.actions.add(item) }
        }
    }

    @objc func deleteSelected() {
        guard !isWriting, let entry = selectedEntry, let target = selectedTarget else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = "Delete “\(entry.title)”?"
        switch target {
        case .briefRule: alert.informativeText = "It leaves the project brief."
        case .memory: alert.informativeText = "Its file goes to the Trash and its line leaves MEMORY.md."
        case .missingFile: alert.informativeText = "Its line leaves MEMORY.md."
        }
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        // The target was resolved before the question: a write ending
        // meanwhile can't turn it into another item.
        guard actions.confirm(alert) else { return }
        _ = write { actions.delete(target) }
    }

    /// A memory moved to Always loses its file to the Trash: asked first.
    private func moveSelected(to scope: ProjectMemory.Scope) {
        guard let entry = selectedEntry, entry.scope != scope, let target = selectedTarget else { return }
        defer { if !isWriting { preview?.reshowScope(entry.scope) } }
        if case .memory = target, scope == .always {
            let alert = NSAlert()
            alert.messageText = "Move “\(entry.title)” to Always?"
            alert.informativeText = "It joins the project brief, which every session Nirux starts in this project gets. "
                + "Its memory file goes to the Trash."
            alert.addButton(withTitle: "Move")
            alert.addButton(withTitle: "Cancel")
            guard actions.confirm(alert) else { return }
        }
        _ = write { actions.move(target, scope) }
    }

    // MARK: - Opening

    /// The file of the selected item, and the line where it starts.
    var selectedFile: (url: URL, line: Int?)? {
        selectedEntry.flatMap { model?.knowledge.location(of: $0) }
    }

    @objc private func commit() {
        guard editing == nil, !isWriting, let file = selectedFile else { return NSSound.beep() }
        dismiss()
        actions.open(file.url, file.line)
    }

    @objc private func tableDoubleClicked() {
        guard editing == nil, !isWriting, let table = tableView, rows.indices.contains(table.clickedRow) else { return }
        select(row: table.clickedRow)
        commit()
    }

    // MARK: - Keys and clicks

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            // Its own sheet and its alerts keep it open, and so does an edit:
            // it would go with it.
            if event.window !== panel, event.window?.sheetParent !== panel, NSApp.modalWindow == nil,
               self.editing == nil, !self.isWriting {
                self.dismiss()
            }
            return event
        }
    }

    private func removeMonitors() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor); clickMonitor = nil }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel else { return event }
        // An input method composing in the field keeps its keys.
        if (searchField?.currentEditor() as? NSTextView)?.hasMarkedText() == true { return event }
        if editing != nil {
            // The text being edited gets every key but these; an input
            // method composing keeps Escape.
            if event.keyCode == 0x35, preview?.isComposing == false { cancelEditing(); return nil }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "s" { saveEditing(); return nil }
            return event
        }
        switch event.keyCode {
        case 0x35: // Escape
            if !isWriting { dismiss() }
            return nil
        case 0x24, 0x4C: // Return / Enter
            commit()
            return nil
        case 0x7E: // Up
            moveSelection(by: -1)
            return nil
        case 0x7D: // Down
            moveSelection(by: 1)
            return nil
        default:
            // Typed after a click in the preview: the filter gets it, ⌘C
            // still copies the preview's selection.
            if event.modifierFlags.isDisjoint(with: [.command, .control]),
               event.characters?.unicodeScalars.contains(where: { !CharacterSet.controlCharacters.contains($0) }) == true {
                focusField()
            }
            return event
        }
    }

    /// The keyboard back in the field, the caret at its end.
    private func focusField() {
        guard let panel, let searchField else { return }
        if let editor = searchField.currentEditor(), panel.firstResponder === editor { return }
        panel.makeFirstResponder(searchField)
        let end = (searchField.stringValue as NSString).length
        searchField.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
    }

    // MARK: - Panel construction

    private static let tabRowHeight: CGFloat = 40
    private static let fieldRowHeight: CGFloat = 44
    private static let filterRowHeight: CGFloat = 36
    private static let noticeHeight: CGFloat = 30
    private static let footerHeight: CGFloat = 48
    private static var headerHeight: CGFloat { tabRowHeight + fieldRowHeight + filterRowHeight }

    private func createPanel() {
        let size = Self.panelSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovable = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = Theme.appearance
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false

        let background = NSView(frame: NSRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.cornerRadius = Theme.Radius.panel
        background.layer?.backgroundColor = Theme.Color.base.cgColor
        background.layer?.borderWidth = 1
        background.layer?.borderColor = Theme.Color.lineStrong.cgColor
        background.layer?.masksToBounds = true
        addTabRow(to: background)
        addFieldRow(to: background)
        addFilterRow(to: background)
        addNoticeRow(to: background)
        addFooter(to: background)
        addBody(to: background)
        panel.contentView = background
        self.panel = panel
        layoutBody(noticeShown: false)
    }

    /// The panel's name and its tabs: "What agents know", and "History",
    /// greyed until it exists.
    private func addTabRow(to background: NSView) {
        let size = Self.panelSize
        let row = NSView(frame: NSRect(x: 0, y: size.height - Self.tabRowHeight, width: size.width, height: Self.tabRowHeight))
        row.wantsLayer = true
        row.layer?.backgroundColor = Theme.Color.canvas.cgColor
        func label(_ text: String, font: NSFont, color: NSColor, x: CGFloat) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = font
            label.textColor = color
            label.sizeToFit()
            label.frame.origin = NSPoint(x: x, y: (Self.tabRowHeight - label.frame.height) / 2)
            row.addSubview(label)
            return label
        }
        let title = label(Self.title, font: Theme.Font.display, color: Theme.Color.textPrimary, x: Theme.Space.lg)
        let current = label(Self.tabs[0], font: Theme.Font.bodyEmphasized, color: Theme.Color.textPrimary, x: title.frame.maxX + Theme.Space.xl)
        let underline = NSView(frame: NSRect(x: current.frame.minX, y: 0, width: current.frame.width, height: 2))
        underline.wantsLayer = true
        underline.layer?.backgroundColor = Theme.Color.accent.cgColor
        row.addSubview(underline)
        let history = label(Self.tabs[1], font: Theme.Font.body, color: Theme.Color.textDisabled, x: current.frame.maxX + Theme.Space.xl)
        let later = label("later", font: Theme.Font.caption, color: Theme.Color.textDisabled, x: history.frame.maxX + Theme.Space.xs)
        for view in [history, later] { view.toolTip = "Coming later: what was said and decided in this project" }
        row.addSubview(Self.line(at: 0))
        background.addSubview(row)
    }

    /// The field, under the tabs.
    private func addFieldRow(to background: NSView) {
        let size = Self.panelSize
        let y = size.height - Self.tabRowHeight - Self.fieldRowHeight
        let row = NSView(frame: NSRect(x: 0, y: y, width: size.width, height: Self.fieldRowHeight))
        row.wantsLayer = true
        row.layer?.backgroundColor = Theme.Color.fillHover.cgColor
        row.addSubview(PaletteIconView(.symbol(Theme.Symbol.projectMemory), frame: NSRect(x: 14, y: 10, width: 24, height: 24)))
        let field = NSTextField()
        field.font = .systemFont(ofSize: 15)
        field.textColor = Theme.Color.textPrimary
        field.backgroundColor = .clear
        field.isBezeled = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.frame = NSRect(x: 42, y: 10, width: size.width - 56, height: 24)
        field.delegate = self
        row.addSubview(field)
        background.addSubview(row)
        searchField = field
    }

    /// The scope filter, and how many items each scope holds.
    private func addFilterRow(to background: NSView) {
        let size = Self.panelSize
        let scopes = NSSegmentedControl(
            labels: ["All"] + Self.scopes.map(\.title), trackingMode: .selectOne, target: self, action: #selector(reload)
        )
        // The keyboard stays in the field, whatever is clicked.
        scopes.refusesFirstResponder = true
        scopes.selectedSegmentBezelColor = Theme.Color.accent
        scopes.controlSize = .small
        scopes.font = Theme.Font.caption
        scopes.sizeToFit()
        let y = size.height - Self.headerHeight
        scopes.frame.origin = NSPoint(x: Theme.Space.lg, y: y + (Self.filterRowHeight - scopes.frame.height) / 2)
        background.addSubview(scopes)
        let summary = NSTextField(labelWithString: "")
        summary.font = Theme.Font.caption
        summary.textColor = Theme.Color.textTertiary
        summary.alignment = .right
        summary.lineBreakMode = .byTruncatingHead
        let summaryX = scopes.frame.maxX + Theme.Space.lg
        summary.frame = NSRect(
            x: summaryX, y: y + (Self.filterRowHeight - 15) / 2, width: size.width - Theme.Space.lg - summaryX, height: 15
        )
        background.addSubview(summary)
        background.addSubview(Self.line(at: y))
        scopeControl = scopes
        summaryLabel = summary
    }

    /// Why Claude Code doesn't use its memory, when it doesn't, or which
    /// setting moved it. A notice, not a wait on the user: never amber.
    private func addNoticeRow(to background: NSView) {
        let size = Self.panelSize
        let row = NSView(frame: NSRect(
            x: 0, y: size.height - Self.headerHeight - Self.noticeHeight, width: size.width, height: Self.noticeHeight
        ))
        row.wantsLayer = true
        row.layer?.backgroundColor = Theme.Color.surface.cgColor
        let icon = NSImageView(frame: NSRect(x: Theme.Space.lg, y: 8, width: 14, height: 14))
        icon.image = NSImage(systemSymbolName: Theme.Symbol.notice, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        icon.contentTintColor = Theme.Color.textSecondary
        row.addSubview(icon)
        let notice = NSTextField(labelWithString: "")
        notice.font = Theme.Font.caption
        notice.textColor = Theme.Color.textSecondary
        notice.lineBreakMode = .byTruncatingTail
        notice.frame = NSRect(x: Theme.Space.lg + 22, y: 7, width: size.width - 2 * Theme.Space.lg - 22, height: 15)
        row.addSubview(notice)
        row.isHidden = true
        background.addSubview(row)
        noticeRow = row
        noticeLabel = notice
    }

    /// What can be done with the selected item on the left, what Return
    /// does on the right.
    private func addFooter(to background: NSView) {
        let size = Self.panelSize
        var x = Theme.Space.lg
        func button(_ title: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.sizeToFit()
            button.frame.size.width = max(button.frame.width, 72)
            button.frame.origin = NSPoint(x: x, y: (Self.footerHeight - button.frame.height) / 2)
            // The keyboard stays in the field, whatever is clicked.
            button.refusesFirstResponder = true
            background.addSubview(button)
            x = button.frame.maxX + Theme.Space.sm
            return button
        }
        addButton = button(Self.addTitle, #selector(showAddSheet as () -> Void))
        editButton = button(Self.editTitle, #selector(beginEditing))
        deleteButton = button(Self.deleteTitle, #selector(deleteSelected))
        x = Theme.Space.lg
        saveButton = button(Self.saveTitle, #selector(saveEditing))
        cancelButton = button(Self.cancelTitle, #selector(cancelEditing))
        saveButton?.isHidden = true
        cancelButton?.isHidden = true
        // A failed write says why here: the panel would hide a toast.
        let error = NSTextField(labelWithString: "")
        error.font = Theme.Font.caption
        error.textColor = Theme.Color.error
        error.lineBreakMode = .byTruncatingTail
        background.addSubview(error)
        errorLabel = error
        let button = NSButton(title: Self.openTitle, target: self, action: #selector(commit))
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.sizeToFit()
        button.frame.size.width = max(button.frame.width, 120)
        button.frame.origin = NSPoint(
            x: size.width - Theme.Space.lg - button.frame.width, y: (Self.footerHeight - button.frame.height) / 2
        )
        background.addSubview(button)
        background.addSubview(Self.line(at: Self.footerHeight))
        openButton = button
        let errorX = (deleteButton?.frame.maxX ?? x) + Theme.Space.md
        error.frame = NSRect(x: errorX, y: (Self.footerHeight - 15) / 2, width: button.frame.minX - Theme.Space.md - errorX, height: 15)
    }

    /// The list on the left, the item on the right.
    private func addBody(to background: NSView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let table = NSTableView()
        table.refusesFirstResponder = true
        table.allowsEmptySelection = false
        table.headerView = nil
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowSizeStyle = .custom
        table.rowHeight = 50
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(tableDoubleClicked)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        column.width = Self.listWidth
        table.addTableColumn(column)
        scroll.documentView = table
        background.addSubview(scroll)

        let preview = ProjectMemoryPreview(frame: .zero)
        preview.onLink = { [weak self] fileName in self?.reveal(fileName: fileName) }
        preview.onScope = { [weak self] scope in self?.moveSelected(to: scope) }
        background.addSubview(preview)
        tableView = table
        scrollView = scroll
        self.preview = preview
    }

    private static func line(at y: CGFloat) -> NSView {
        let line = NSView(frame: NSRect(x: 0, y: y, width: panelSize.width, height: 1))
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.Color.line.cgColor
        return line
    }

    /// The list and the preview fill what the notice leaves.
    private func layoutBody(noticeShown: Bool) {
        let size = Self.panelSize
        let top = size.height - Self.headerHeight - (noticeShown ? Self.noticeHeight : 0)
        let bottom = Self.footerHeight + 1
        scrollView?.frame = NSRect(x: 0, y: bottom, width: Self.listWidth, height: top - bottom)
        preview?.frame = NSRect(x: Self.listWidth, y: bottom, width: size.width - Self.listWidth, height: top - bottom)
    }
}

// MARK: - NSTextFieldDelegate

extension ProjectMemoryPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        reload()
    }
}

// MARK: - Table

extension ProjectMemoryPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// An edit keeps its item until it is saved or cancelled.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        editing == nil && !isWriting
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelection()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let entry = rows[safe: row].flatMap({ model?.knowledge.entries[safe: $0] }) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ProjectMemoryCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? ProjectMemoryCellView)
            ?? ProjectMemoryCellView()
        cell.identifier = identifier
        cell.configure(entry)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SearchResultRowView()
    }
}

/// The item's title, its scope in a chip on the right (a lock for the
/// team's); below, what follows the title, or that its file is gone.
final class ProjectMemoryCellView: NSTableCellView {
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let chipLabel = NSTextField(labelWithString: "")
    private let chip = NSView()
    private let lock = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = Theme.Font.title
        titleLabel.textColor = Theme.Color.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = Theme.Font.caption
        detailLabel.lineBreakMode = .byTruncatingTail
        chip.wantsLayer = true
        chip.layer?.cornerRadius = Theme.Radius.chip
        chip.layer?.backgroundColor = Theme.Color.fillPressed.cgColor
        chipLabel.font = Theme.Font.caption
        chipLabel.alignment = .center
        lock.image = NSImage(systemSymbolName: Theme.Symbol.locked, accessibilityDescription: "Team")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .regular))
        lock.contentTintColor = Theme.Color.textSecondary
        chip.addSubview(lock)
        chip.addSubview(chipLabel)
        [titleLabel, detailLabel, chip].forEach(addSubview)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let inset = Theme.Space.lg
        let lockWidth: CGFloat = lock.isHidden ? 0 : 12
        let labelWidth = ceil(chipLabel.intrinsicContentSize.width)
        let chipWidth = labelWidth + lockWidth + 2 * Theme.Space.sm
        // A title alone sits in the middle of its row.
        let titleY: CGFloat = detailLabel.stringValue.isEmpty ? floor((bounds.height - 17) / 2) : 25
        chip.frame = NSRect(x: bounds.width - inset - chipWidth, y: titleY + 1, width: chipWidth, height: 16)
        lock.frame = NSRect(x: Theme.Space.sm - 1, y: 2, width: 12, height: 12)
        chipLabel.frame = NSRect(x: Theme.Space.sm + lockWidth, y: 1, width: labelWidth, height: 14)
        titleLabel.frame = NSRect(x: inset, y: titleY, width: chip.frame.minX - inset - Theme.Space.sm, height: 17)
        detailLabel.frame = NSRect(x: inset, y: 7, width: bounds.width - 2 * inset, height: 15)
    }

    func configure(_ entry: ProjectMemory.Entry) {
        titleLabel.stringValue = entry.title
        detailLabel.stringValue = entry.detail
        let isGone: Bool
        if case .missingFile = entry.source { isGone = true } else { isGone = false }
        detailLabel.textColor = isGone ? Theme.Color.error : Theme.Color.textSecondary
        chipLabel.stringValue = entry.scope.title.lowercased()
        chipLabel.textColor = entry.scope == .whenRelevant ? Theme.Color.textSecondary : Theme.Color.textPrimary
        lock.isHidden = entry.scope != .team
        needsLayout = true
    }
}
