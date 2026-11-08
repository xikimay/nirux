import AppKit

/// The ⌘N sheet, "New in <space>" (docs/spaces.md, "One door: ⌘N"): a
/// description, the repository (shown with two or more), the agent, the
/// template, and the branch the task gets, which follows the description
/// until the user edits it.
///
/// Start with a description hands a `NewTask.Request` to the shell and
/// waits: the sheet stays open, with the error, when the worktree can't be
/// created. Close hides it meanwhile, so the window isn't held up by a long
/// checkout; it comes back if creating fails. Start with nothing typed opens
/// a shell in the repository's main checkout, or the home folder in a space
/// without one. Return starts; ⇧Return adds a line.
@MainActor
final class NewTaskPanel: NSObject, NSTextViewDelegate, NSTextFieldDelegate {
    /// One of the space's repositories or folders (its anchors).
    struct Repository: Equatable {
        let key: String
        let name: String
        /// The repository's main checkout, or the folder.
        let folder: String
    }

    /// The space the sheet creates in.
    struct Space: Equatable {
        let id: String
        let name: String
        /// General never has a repository (docs/spaces.md).
        let isGeneral: Bool
    }

    /// What the shell read for the selected repository: where its tasks
    /// branch from (nil: none selected, or not in a git repository) and the
    /// space's templates.
    struct ProjectInfo {
        let target: NewTask.Target?
        let templates: [TaskTemplates.Template]
    }

    /// Asks the shell to read the repository's info off the main thread,
    /// then call `update(repositoryKey:info:)`.
    var onRepositorySelected: ((Repository?) -> Void)?
    /// Creates the task, then calls `finishStarting(_:)`.
    var onStart: ((NewTask.Request) -> Void)?
    /// Nothing typed: opens a shell. The sheet is gone by then.
    var onOpenShell: ((Repository?) -> Void)?
    /// Anchors the suggested repository to the space, then calls
    /// `updateRepositories(_:selecting:)`.
    var onAddSuggested: ((SpaceAnchor) -> Void)?
    /// Picks a folder and anchors its repository to the space, then calls
    /// `updateRepositories(_:selecting:)`.
    var onAddRepository: (() -> Void)?
    /// General: opens New Space…. The sheet is gone by then.
    var onNewSpace: (() -> Void)?
    /// Opens the repository's worktrees. The sheet is gone by then.
    var onExistingBranch: ((Repository?) -> Void)?
    var onDismiss: (() -> Void)?

    private(set) var panel: NSPanel?
    private weak var parentWindow: NSWindow?
    private(set) var space = Space(id: WorkspaceProfile.defaultID, name: "", isGeneral: true)
    private(set) var repositories: [Repository] = []
    private(set) var selectedRepositoryKey: String?
    /// The focused terminal's repository, offered while the space has none.
    private(set) var suggestion: SpaceAnchor?
    /// Where a shell opens without a repository.
    private var homeFolder = NSHomeDirectory()
    /// The selected repository's info; nil while it is read.
    private(set) var info: ProjectInfo?
    /// The user typed a branch of their own: the description no longer
    /// changes it.
    private(set) var branchIsEdited = false
    /// Edit was clicked: the branch shows in a field.
    private(set) var isEditingBranch = false
    private(set) var isStarting = false
    /// Closed while the task starts: it shows again if starting fails.
    private(set) var isHidden = false
    /// The fetch failed and the user was told: the next Start goes from
    /// origin's branch as last fetched.
    private(set) var startsWithoutFetch = false
    /// The template picked, kept while another repository's info is read:
    /// templates are the space's, the same for each.
    private var pickedTemplateName: String?
    /// The agent the task reports to (a Lead's proposal): carried into the
    /// request (see `NewTask.Request.reportsTo`).
    var reportsTo: NewTask.MissionParent? {
        didSet { if let reportsTo, lead == nil { lead = reportsTo } }
    }
    /// The space's Lead: "Report to the Lead" shows, checked (docs/spaces.md,
    /// "One door: ⌘N"). Nil: no Lead, no checkbox.
    var lead: NewTask.MissionParent? {
        didSet {
            reportCheckbox.isHidden = lead == nil
            reportHint.isHidden = lead == nil
            if lead != nil, oldValue == nil { reportCheckbox.state = .on }
            layout()
        }
    }
    let reportCheckbox = NSButton(checkboxWithTitle: "Report to the Lead", target: nil, action: nil)
    private let reportHint = NSTextField(wrappingLabelWithString:
        "The Lead follows this task and answers its questions. Only what needs you reaches you, in amber.")

    /// How Start's work ended.
    enum Outcome: Equatable {
        /// The workspace opened: the sheet closes.
        case opened
        /// Nothing was created.
        case failed(String)
        /// Origin's branch couldn't be fetched; nothing was created.
        case fetchFailed(String)
    }

    let headingLabel = NSTextField(labelWithString: "")
    let descriptionView = NewTaskTextView()
    let placeholderLabel = PassThroughLabel(labelWithString: "Describe a task for an agent. ⇧Return adds a line.")
    let repositoryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let agentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let templatePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// The branch and where it starts from, where a shell opens, or why no
    /// task can start.
    let lineLabel = NSTextField(labelWithString: "")
    let editBranchButton = NSButton(title: "Edit", target: nil, action: nil)
    let branchField = NSTextField()
    let fromLabel = NSTextField(labelWithString: "")
    let newSpaceButton = NSButton(title: "New Space…", target: nil, action: nil)
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    let existingBranchButton = NSButton(title: "Existing Branch…", target: nil, action: nil)
    let startButton = NSButton(title: "Start", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    static let agents: [(agent: NiruxApp.WorkspaceAgent, title: String)] = [(.claude, "Claude Code"), (.codex, "Codex")]
    static let noTemplateTitle = "No Template"
    static let noRepositoryTitle = "No Repository"
    /// Tags of the repository popup's items that add one instead of
    /// selecting it.
    static let addSuggestedTag = 1
    static let addRepositoryTag = 2

    private let content = NewTaskFlippedView()
    private let descriptionBox = NewTaskFlippedView()
    private let descriptionScroll = NSScrollView()

    private static let width: CGFloat = 620
    private static let margin: CGFloat = 22

    // Explicit, so the controls' default values are made on the main actor
    // with every toolchain.
    override init() {
        super.init()
    }

    /// `selectedKey`: the space's default repository; `agent`: the one its
    /// tasks start by default.
    func show(
        attachedTo window: NSWindow, space: Space, repositories: [Repository], selectedKey: String?,
        agent: NiruxApp.WorkspaceAgent, homeFolder: String
    ) {
        parentWindow = window
        self.space = space
        self.repositories = repositories
        self.homeFolder = homeFolder
        selectedRepositoryKey = repositories.contains { $0.key == selectedKey } ? selectedKey : repositories.first?.key
        let panel = buildPanel()
        self.panel = panel
        agentPopup.selectItem(at: Self.agents.firstIndex { $0.agent == agent } ?? 0)
        headingLabel.stringValue = "New in \(space.name)"
        rebuildRepositoryPopup()
        // Laid out first: the sheet comes down at its size.
        repositoryChanged()
        window.beginSheet(panel)
        panel.makeFirstResponder(descriptionView)
    }

    func focus() {
        panel?.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard let panel else { return }
        panel.sheetParent?.endSheet(panel)
        panel.orderOut(nil)
        self.panel = nil
        isHidden = false
        onDismiss?()
    }

    /// Close while the task starts: the work goes on.
    private func hide() {
        guard let panel, isStarting, !isHidden else { return }
        panel.sheetParent?.endSheet(panel)
        panel.orderOut(nil)
        isHidden = true
    }

    /// Shows the sheet again: ⌘N while it is hidden, or a failure.
    func reshow() {
        guard let panel, isHidden, let parentWindow else { return }
        isHidden = false
        parentWindow.beginSheet(panel)
    }

    // MARK: - Values

    var selectedRepository: Repository? {
        repositories.first { $0.key == selectedRepositoryKey }
    }

    /// The description, trimmed: empty opens a shell.
    var taskText: String {
        descriptionView.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nil for "No Template", the first item.
    var selectedTemplate: TaskTemplates.Template? {
        let index = templatePopup.indexOfSelectedItem
        return index > 0 ? info?.templates[safe: index - 1] : nil
    }

    var selectedAgent: NiruxApp.WorkspaceAgent {
        Self.agents[safe: agentPopup.indexOfSelectedItem]?.agent ?? .claude
    }

    var branch: String {
        branchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The space's repositories changed while the sheet is open (one was
    /// added from it): selects `key` when listed, else the first.
    func updateRepositories(_ repositories: [Repository], selecting key: String?) {
        guard panel != nil else { return }
        self.repositories = repositories
        if !repositories.isEmpty { suggestion = nil }
        let previous = selectedRepositoryKey
        selectedRepositoryKey = repositories.contains { $0.key == key } ? key : repositories.first?.key
        rebuildRepositoryPopup()
        if selectedRepositoryKey != previous || info == nil { repositoryChanged() } else { refresh() }
    }

    /// The focused terminal's repository, once git has named it: offered
    /// while the space has none.
    func setSuggestion(_ anchor: SpaceAnchor?) {
        guard panel != nil, repositories.isEmpty, !space.isGeneral else { return }
        suggestion = anchor
        rebuildRepositoryPopup()
        refresh()
    }

    /// A Lead's proposal (`start_task` with "Starts tasks without asking"
    /// off): its description, and its template, picked once the
    /// repository's templates are read.
    func prefill(description: String, templateName: String?) {
        guard panel != nil else { return }
        descriptionView.string = description
        if let templateName { pickedTemplateName = templateName }
        headingLabel.stringValue = "Proposed by the Lead · \(space.name)"
        hideError()
        updateBranchSuggestion()
        refresh()
        // It comes while the user types elsewhere: no field takes the keys,
        // and neither Return nor Escape answers it until they edit
        // something here (a click, or ⌘Return, still does).
        panel?.makeFirstResponder(nil)
        startButton.keyEquivalent = ""
        cancelButton.keyEquivalent = ""
    }

    /// The repository's info, read by the shell. Ignored when another
    /// repository was selected since.
    func update(repositoryKey: String?, info: ProjectInfo) {
        guard panel != nil, repositoryKey == selectedRepositoryKey else { return }
        let previousTemplate = selectedTemplate?.name ?? pickedTemplateName
        self.info = info
        hideError()
        startsWithoutFetch = false
        templatePopup.removeAllItems()
        // Menu items, not addItem(withTitle:), which drops a title already
        // there: indexes must match `info.templates`.
        templatePopup.menu?.addItem(NSMenuItem(title: Self.noTemplateTitle, action: nil, keyEquivalent: ""))
        for template in info.templates {
            templatePopup.menu?.addItem(NSMenuItem(title: template.name, action: nil, keyEquivalent: ""))
        }
        templatePopup.selectItem(at: previousTemplate.flatMap { name in
            info.templates.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map { $0 + 1 }
        } ?? 0)
        templatePopup.isEnabled = !isStarting
        updateBranchSuggestion()
        refresh()
    }

    /// Called by the shell once Start's work is over.
    func finishStarting(_ outcome: Outcome) {
        isStarting = false
        let message: String
        switch outcome {
        case .opened:
            return dismiss()
        case .failed(let error):
            message = error
        case .fetchFailed(let error):
            let branch = info?.target?.remoteBranchName ?? "origin's branch"
            message = "Couldn’t fetch \(branch): \(error)\nStart again to start from \(branch) as last fetched."
            startsWithoutFetch = true
        }
        let wasHidden = isHidden
        reshow()
        setControlsEnabled(true)
        showError(message)
        if wasHidden {
            // It comes back while the user types elsewhere: no field takes
            // the keys, and neither Return nor Escape answers it until they
            // edit something here (⌘Return and a click still do).
            panel?.makeFirstResponder(nil)
            startButton.keyEquivalent = ""
            cancelButton.keyEquivalent = ""
        } else {
            // The field being edited lost the focus when it was disabled.
            beginEditingBranch()
        }
    }

    /// The user edits the sheet: Return starts and Escape cancels again.
    private func restoreReturnKey() {
        startButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
    }

    // MARK: - Actions

    @objc func startAction(_ sender: Any?) {
        guard panel != nil, !isStarting else { return }
        guard !taskText.isEmpty else {
            let open = onOpenShell
            let repository = selectedRepository
            dismiss()
            open?(repository)
            return
        }
        guard let request = draftRequest() else { return }
        restoreReturnKey()
        hideError()
        isStarting = true
        setControlsEnabled(false)
        onStart?(request)
    }

    @objc func cancelAction(_ sender: Any?) {
        if isStarting { return hide() }
        dismiss()
    }

    @objc func existingBranchAction(_ sender: Any?) {
        guard !isStarting else { return }
        let open = onExistingBranch
        let repository = selectedRepository
        dismiss()
        open?(repository)
    }

    @objc func newSpaceAction(_ sender: Any?) {
        let open = onNewSpace
        dismiss()
        open?()
    }

    @objc func editBranchAction(_ sender: Any?) {
        beginEditingBranch()
    }

    @objc func repositoryPopupChanged(_ sender: Any?) {
        guard let item = repositoryPopup.selectedItem else { return }
        switch item.tag {
        case Self.addSuggestedTag:
            selectRepositoryItem()
            if let suggestion { onAddSuggested?(suggestion) }
        case Self.addRepositoryTag:
            selectRepositoryItem()
            onAddRepository?()
        default:
            let key = item.representedObject as? String
            guard key != selectedRepositoryKey else { return }
            selectedRepositoryKey = key
            repositoryChanged()
        }
    }

    @objc func templateChanged(_ sender: Any?) {
        restoreReturnKey()
        updateBranchSuggestion()
        refresh()
    }

    private func repositoryChanged() {
        if info != nil { pickedTemplateName = selectedTemplate?.name }
        hideError()
        info = nil
        startsWithoutFetch = false
        templatePopup.isEnabled = false
        refresh()
        onRepositorySelected?(selectedRepository)
    }

    /// The request for the values on screen, or nil with the reason shown.
    private func draftRequest() -> NewTask.Request? {
        guard let target = info?.target else {
            showError(info == nil ? "Nirux is still reading the repository." : noTaskReason ?? "No repository to start from.")
            return nil
        }
        guard !branch.isEmpty else {
            showError("Name the branch.")
            beginEditingBranch()
            return nil
        }
        return NewTask.Request(
            description: taskText, template: selectedTemplate, agent: selectedAgent,
            projectID: space.id, branch: branch, target: target, fetchesFirst: !startsWithoutFetch,
            reportsTo: lead != nil && reportCheckbox.state == .on ? (reportsTo ?? lead) : nil
        )
    }

    private func beginEditingBranch() {
        guard panel != nil else { return }
        isEditingBranch = true
        refresh()
        panel?.makeFirstResponder(branchField)
        branchField.selectText(nil)
    }

    private func updateBranchSuggestion() {
        guard !branchIsEdited else { return }
        branchField.stringValue = NewTask.suggestedBranch(description: descriptionView.string, templateName: selectedTemplate?.name)
    }

    // MARK: - Text

    /// Why a task can't start from what is selected, or nil.
    var noTaskReason: String? {
        if repositories.isEmpty {
            return space.isGeneral
                ? "\(space.name) has no repository: tasks start in a space that has one."
                : "This space has no repository yet: add one with the menu above."
        }
        guard let info, info.target == nil else { return nil }
        return "“\(selectedRepository?.name ?? "")” isn’t in a git repository: tasks need one."
    }

    /// Where the branch starts, after the branch.
    private func startText(_ target: NewTask.Target) -> String {
        if let remoteBranch = target.remoteBranchName {
            return startsWithoutFetch ? "from \(remoteBranch) as last fetched" : "from \(remoteBranch)"
        }
        let head = target.checkoutBranch.map { "HEAD (\($0))" } ?? "HEAD"
        return "from the checkout’s \(head): origin has no default branch"
    }

    /// The line under the popups, and what it holds.
    private func refresh() {
        guard panel != nil else { return }
        placeholderLabel.isHidden = !descriptionView.string.isEmpty
        repositoryPopup.isHidden = !(repositories.count >= 2 || (repositories.isEmpty && !space.isGeneral))
        startButton.isEnabled = !isStarting && (taskText.isEmpty || info?.target != nil)
        var showsField = false
        var showsEdit = false
        var showsNewSpace = false
        let secondary = Theme.Color.textSecondary
        if isStarting {
            let fetching = startsWithoutFetch ? nil : info?.target?.remoteBranchName.map { "Fetching \($0), then creating" }
            setLine((fetching ?? "Creating") + " the worktree… Close keeps it going: the workspace opens when it’s ready.", secondary)
        } else if taskText.isEmpty {
            let folder = selectedRepository?.folder ?? homeFolder
            let shown = folder == homeFolder ? "~" : (folder as NSString).abbreviatingWithTildeInPath
            setLine("Nothing typed: Start opens a shell in \(shown).", secondary)
        } else if let reason = noTaskReason {
            setLine(reason, Theme.Color.error)
            showsNewSpace = space.isGeneral
        } else if let target = info?.target {
            let start = startText(target)
            let color = secondary
            if isEditingBranch {
                showsField = true
                fromLabel.stringValue = start
                fromLabel.textColor = color
            } else {
                showsEdit = true
                let line = NSMutableAttributedString(
                    string: branch.isEmpty ? "No branch name" : branch,
                    attributes: [.font: Theme.Font.code, .foregroundColor: branch.isEmpty ? Theme.Color.error : Theme.Color.textPrimary]
                )
                line.append(NSAttributedString(string: "  ·  \(start)", attributes: [.font: Theme.Font.body, .foregroundColor: color]))
                lineLabel.attributedStringValue = line
            }
        } else {
            setLine("\(branch.isEmpty ? "No branch name" : branch)  ·  reading the repository…", secondary)
        }
        lineLabel.isHidden = showsField
        branchField.isHidden = !showsField
        fromLabel.isHidden = !showsField
        editBranchButton.isHidden = !showsEdit
        newSpaceButton.isHidden = !showsNewSpace
        layout()
    }

    private func setLine(_ text: String, _ color: NSColor) {
        lineLabel.attributedStringValue = NSAttributedString(string: text, attributes: [.font: Theme.Font.body, .foregroundColor: color])
    }

    /// Git's error can run to pages (a hook's output): its end, which says
    /// why, at most `maxLines` lines. A line longer than `maxLineLength`
    /// loses its middle (a long path, say): its start and end tell what.
    static func lastLines(of message: String, maxLines: Int = 5, maxLineLength: Int = 160) -> String {
        var lines = message.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard line.count > maxLineLength else { return String(line) }
            return line.prefix(maxLineLength / 2 - 1) + "…" + line.suffix(maxLineLength / 2)
        }
        if lines.count > maxLines { lines = ["…"] + lines.suffix(maxLines) }
        return lines.joined(separator: "\n")
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = Self.lastLines(of: message)
        errorLabel.isHidden = false
        layout()
    }

    private func hideError() {
        guard !errorLabel.isHidden else { return }
        errorLabel.isHidden = true
        layout()
    }

    private func setControlsEnabled(_ enabled: Bool) {
        descriptionView.isEditable = enabled
        descriptionView.textColor = enabled ? Theme.Color.textPrimary : Theme.Color.textTertiary
        for control in [repositoryPopup, agentPopup, templatePopup, branchField, existingBranchButton, reportCheckbox] as [NSControl] {
            control.isEnabled = enabled
        }
        if enabled { templatePopup.isEnabled = info != nil }
        cancelButton.title = enabled ? "Cancel" : "Close"
        refresh()
    }

    // MARK: - Repository popup

    /// The space's repositories; in a space without any, "No Repository"
    /// and the items that add one.
    private func rebuildRepositoryPopup() {
        repositoryPopup.removeAllItems()
        guard let menu = repositoryPopup.menu else { return }
        if repositories.isEmpty {
            menu.addItem(NSMenuItem(title: Self.noRepositoryTitle, action: nil, keyEquivalent: ""))
            menu.addItem(.separator())
            if let suggestion {
                let item = NSMenuItem(title: "Add “\(suggestion.name)”", action: nil, keyEquivalent: "")
                item.tag = Self.addSuggestedTag
                menu.addItem(item)
            }
            let add = NSMenuItem(title: "Add Repository…", action: nil, keyEquivalent: "")
            add.tag = Self.addRepositoryTag
            menu.addItem(add)
        } else {
            for repository in repositories {
                let item = NSMenuItem(title: repository.name, action: nil, keyEquivalent: "")
                item.representedObject = repository.key
                item.toolTip = repository.folder.abbreviatedPath()
                menu.addItem(item)
            }
        }
        selectRepositoryItem()
    }

    /// Back on the selected repository, after an item that adds one.
    private func selectRepositoryItem() {
        let index = repositoryPopup.itemArray.firstIndex { ($0.representedObject as? String) == selectedRepositoryKey }
        repositoryPopup.selectItem(at: index ?? 0)
    }

    // MARK: - Delegates

    func textDidChange(_ notification: Notification) {
        restoreReturnKey()
        hideError()
        updateBranchSuggestion()
        refresh()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === branchField else { return }
        restoreReturnKey()
        // Cleared: the description names the branch again.
        branchIsEdited = !branch.isEmpty
        if !branchIsEdited { updateBranchSuggestion() }
    }

    /// Return starts, ⇧Return adds a line (⌥Return does too: it asks for
    /// another command), and Tab leaves the description instead of typing a
    /// tab into it.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if descriptionView.keyModifiers.contains(.shift) { return false }
            startAction(nil)
            return true
        case #selector(NSResponder.insertTab(_:)):
            panel?.selectNextKeyView(nil)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            panel?.selectPreviousKeyView(nil)
            return true
        default:
            return false
        }
    }

    // MARK: - Layout

    /// Places everything from the top; the sheet takes the height it needs.
    /// Views are only moved, so the field being edited keeps the keyboard.
    private func layout() {
        guard let panel else { return }
        let margin = Self.margin
        let inner = Self.width - margin * 2
        var y: CGFloat = 20

        headingLabel.frame = NSRect(x: margin, y: y, width: inner, height: 16)
        y += 16 + 8
        descriptionBox.frame = NSRect(x: margin, y: y, width: inner, height: 108)
        descriptionScroll.frame = descriptionBox.bounds
        placeholderLabel.frame = NSRect(x: 14, y: 10, width: inner - 28, height: 20)
        y += 108 + 14

        var x = margin
        let popups = [repositoryPopup, agentPopup, templatePopup].filter { !$0.isHidden }
        let widest = floor((inner - 6 * CGFloat(popups.count - 1)) / CGFloat(max(popups.count, 1)))
        for popup in popups {
            let width = min(max(ceil(popup.fittingSize.width), 120), 240, widest)
            popup.frame = NSRect(x: x - 2, y: y, width: width, height: 26)
            x += width + 6
        }
        y += 26 + 12

        let editWidth = ceil(editBranchButton.fittingSize.width)
        let newSpaceWidth = ceil(newSpaceButton.fittingSize.width)
        let trailing = !editBranchButton.isHidden ? editWidth + 8 : !newSpaceButton.isHidden ? newSpaceWidth + 8 : 0
        let lineHeight = max(18, Self.wrappedHeight(of: lineLabel, width: inner - trailing))
        lineLabel.frame = NSRect(x: margin, y: y + 2, width: inner - trailing, height: lineHeight)
        editBranchButton.frame = NSRect(x: margin + inner - editWidth, y: y, width: editWidth, height: 22)
        newSpaceButton.frame = NSRect(x: margin + inner - newSpaceWidth, y: y - 2, width: newSpaceWidth, height: 26)
        let fieldWidth = floor(inner * 0.6)
        branchField.frame = NSRect(x: margin, y: y, width: fieldWidth, height: 22)
        fromLabel.frame = NSRect(x: margin + fieldWidth + 10, y: y + 3, width: inner - fieldWidth - 10, height: 18)
        y += max(22, lineHeight + 4) + 12

        if !reportCheckbox.isHidden {
            // Its own width: a click beside it doesn't toggle it.
            reportCheckbox.frame = NSRect(x: margin - 2, y: y, width: min(inner, ceil(reportCheckbox.fittingSize.width)), height: 18)
            let hintHeight = Self.wrappedHeight(of: reportHint, width: inner - 20)
            reportHint.frame = NSRect(x: margin + 18, y: y + 20, width: inner - 20, height: hintHeight)
            y += 20 + hintHeight + 12
        }

        if !errorLabel.isHidden {
            let height = Self.wrappedHeight(of: errorLabel, width: inner)
            errorLabel.frame = NSRect(x: margin, y: y, width: inner, height: height)
            y += height + 12
        }

        y += 6
        let existingWidth = ceil(existingBranchButton.fittingSize.width)
        existingBranchButton.frame = NSRect(x: margin, y: y + 4, width: existingWidth, height: 22)
        startButton.frame = NSRect(x: Self.width - margin - 96, y: y, width: 96, height: 30)
        cancelButton.frame = NSRect(x: startButton.frame.minX - 8 - 96, y: y, width: 96, height: 30)
        y += 30 + 18

        panel.setContentSize(NSSize(width: Self.width, height: y))
        content.frame = NSRect(x: 0, y: 0, width: Self.width, height: y)
        panel.recalculateKeyViewLoop()
    }

    private static func wrappedHeight(of label: NSTextField, width: CGFloat) -> CGFloat {
        label.preferredMaxLayoutWidth = width
        return ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)).height ?? 16)
    }

    // MARK: - Construction

    private func buildPanel() -> NSPanel {
        headingLabel.font = Theme.Font.captionEmphasized
        headingLabel.textColor = Theme.Color.textSecondary
        headingLabel.lineBreakMode = .byTruncatingTail

        descriptionBox.wantsLayer = true
        descriptionBox.layer?.cornerRadius = 10
        descriptionBox.layer?.borderWidth = 1
        descriptionBox.layer?.borderColor = Theme.Color.accent.withAlphaComponent(0.6).cgColor
        descriptionBox.layer?.backgroundColor = Theme.Color.canvas.cgColor
        descriptionScroll.drawsBackground = false
        descriptionScroll.hasVerticalScroller = true
        descriptionScroll.autohidesScrollers = true
        descriptionScroll.borderType = .noBorder
        descriptionScroll.autoresizingMask = [.width, .height]
        descriptionView.minSize = NSSize(width: 0, height: 108)
        descriptionView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        descriptionView.isVerticallyResizable = true
        descriptionView.autoresizingMask = [.width]
        descriptionView.textContainer?.widthTracksTextView = true
        descriptionView.textContainerInset = NSSize(width: 9, height: 10)
        descriptionView.drawsBackground = false
        descriptionView.isRichText = false
        descriptionView.allowsUndo = true
        descriptionView.font = .systemFont(ofSize: 15)
        descriptionView.textColor = Theme.Color.textPrimary
        descriptionView.insertionPointColor = Theme.Color.textPrimary
        descriptionView.isAutomaticQuoteSubstitutionEnabled = false
        descriptionView.isAutomaticDashSubstitutionEnabled = false
        descriptionView.isAutomaticTextReplacementEnabled = false
        descriptionView.delegate = self
        descriptionView.setAccessibilityLabel("Task")
        descriptionView.frame = NSRect(x: 0, y: 0, width: Self.width - Self.margin * 2, height: 108)
        descriptionScroll.documentView = descriptionView
        descriptionBox.subviews.forEach { $0.removeFromSuperview() }
        descriptionBox.addSubview(descriptionScroll)
        placeholderLabel.font = .systemFont(ofSize: 15)
        placeholderLabel.textColor = Theme.Color.textTertiary
        placeholderLabel.lineBreakMode = .byTruncatingTail
        descriptionBox.addSubview(placeholderLabel)

        repositoryPopup.target = self
        repositoryPopup.action = #selector(repositoryPopupChanged(_:))
        repositoryPopup.autoenablesItems = false
        repositoryPopup.setAccessibilityLabel("Repository")
        agentPopup.removeAllItems()
        agentPopup.addItems(withTitles: Self.agents.map(\.title))
        agentPopup.setAccessibilityLabel("Agent")
        templatePopup.target = self
        templatePopup.action = #selector(templateChanged(_:))
        templatePopup.removeAllItems()
        templatePopup.menu?.addItem(NSMenuItem(title: Self.noTemplateTitle, action: nil, keyEquivalent: ""))
        templatePopup.isEnabled = false
        templatePopup.setAccessibilityLabel("Template")

        lineLabel.lineBreakMode = .byTruncatingTail
        lineLabel.maximumNumberOfLines = 2
        lineLabel.cell?.wraps = true
        branchField.font = Theme.Font.code
        branchField.placeholderString = "feat/… or fix/…"
        branchField.usesSingleLineMode = true
        branchField.lineBreakMode = .byTruncatingTail
        branchField.delegate = self
        branchField.setAccessibilityLabel("Branch")
        fromLabel.font = Theme.Font.body
        fromLabel.lineBreakMode = .byTruncatingTail
        for (button, action) in [
            (editBranchButton, #selector(editBranchAction(_:))),
            (existingBranchButton, #selector(existingBranchAction(_:)))
        ] {
            button.isBordered = false
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .font: Theme.Font.body, .foregroundColor: Theme.Color.accent
            ])
            button.target = self
            button.action = action
        }
        editBranchButton.setAccessibilityLabel("Edit Branch")
        newSpaceButton.bezelStyle = .rounded
        newSpaceButton.target = self
        newSpaceButton.action = #selector(newSpaceAction(_:))

        errorLabel.font = Theme.Font.caption
        errorLabel.textColor = Theme.Color.error
        errorLabel.maximumNumberOfLines = 0
        errorLabel.isHidden = true

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelAction(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        startButton.bezelStyle = .rounded
        startButton.target = self
        startButton.action = #selector(startAction(_:))
        startButton.keyEquivalent = "\r"

        content.subviews.forEach { $0.removeFromSuperview() }
        let views: [NSView] = [
            headingLabel, descriptionBox, repositoryPopup, agentPopup, templatePopup, lineLabel, editBranchButton,
            branchField, fromLabel, newSpaceButton, reportCheckbox, reportHint, errorLabel, existingBranchButton,
            cancelButton, startButton
        ]
        views.forEach(content.addSubview)
        reportHint.font = Theme.Font.caption
        reportHint.textColor = Theme.Color.textSecondary
        reportHint.isSelectable = false
        reportHint.setAccessibilityElement(false)
        reportCheckbox.setAccessibilityHelp(reportHint.stringValue)
        reportCheckbox.isHidden = lead == nil
        reportHint.isHidden = lead == nil

        let panel = NewTaskSheet(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 320),
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
        panel.multilineView = descriptionView
        panel.onCommandReturn = { [weak self] in self?.startAction(nil) }
        return panel
    }
}

/// The description: remembers the modifiers of the key it is handling, so
/// Return alone starts and ⇧Return adds a line.
final class NewTaskTextView: NSTextView {
    private(set) var keyModifiers: NSEvent.ModifierFlags = []

    override func keyDown(with event: NSEvent) {
        keyModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        defer { keyModifiers = [] }
        super.keyDown(with: event)
    }
}

/// A placeholder over the description: clicks reach the text view.
final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Return in the description goes to it (it starts the task, or adds a line
/// with ⇧ or ⌥, and an input method composing text sees it first), and
/// ⌘Return starts the task from anywhere in the sheet.
final class NewTaskSheet: NSPanel {
    weak var multilineView: NSTextView?
    var onCommandReturn: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.leavesToTextView(event, firstResponder: firstResponder, multilineView: multilineView) {
            return false
        }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .command, event.charactersIgnoringModifiers == "\r" {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Return or Enter, alone or with ⇧ or ⌥, while `multilineView` has the
    /// focus, and any key while an input method composes text there.
    static func leavesToTextView(_ event: NSEvent, firstResponder: NSResponder?, multilineView: NSTextView?) -> Bool {
        guard let multilineView, firstResponder === multilineView else { return false }
        if multilineView.hasMarkedText() { return true }
        let modifiers = event.modifierFlags.intersection([.command, .control])
        return modifiers.isEmpty && (event.charactersIgnoringModifiers == "\r" || event.charactersIgnoringModifiers == "\u{3}")
    }
}

private final class NewTaskFlippedView: NSView {
    override var isFlipped: Bool { true }
}
