import AppKit

/// New Task… in the palette (see NewTask): a sheet on the main window with
/// the task's description, a template, the agent, the project and the
/// branch. The branch follows the description until the user edits it.
/// Start Task hands a `NewTask.Request` to the shell and waits: the sheet
/// stays open, with the error, when the worktree can't be created. Close
/// hides it meanwhile, so the window isn't held up by a long checkout; it
/// comes back if creating fails.
@MainActor
final class NewTaskPanel: NSObject, NSTextViewDelegate, NSTextFieldDelegate {
    struct Project: Equatable {
        let id: String
        let name: String
    }

    /// What the shell found for a project: where its tasks branch from
    /// (nil: no workspace of it is in a git repository) and its templates.
    struct ProjectInfo {
        let target: NewTask.Target?
        let templates: [TaskTemplates.Template]
    }

    /// Asks the shell to read a project's info off the main thread, then call
    /// `update(projectID:info:)`.
    var onProjectSelected: ((String) -> Void)?
    /// Creates the task, then calls `finishStarting(_:)`.
    var onStart: ((NewTask.Request) -> Void)?
    var onDismiss: (() -> Void)?

    private(set) var panel: NSPanel?
    private weak var parentWindow: NSWindow?
    private(set) var projects: [Project] = []
    /// The selected project's info; nil while it is read.
    private(set) var info: ProjectInfo?
    /// The user typed a branch of their own: the description no longer
    /// changes it.
    private(set) var branchIsEdited = false
    private(set) var isStarting = false
    /// Closed while the task starts: it shows again if starting fails.
    private(set) var isHidden = false
    /// The fetch failed and the user was told: the next Start goes from
    /// origin's branch as last fetched.
    private(set) var startsWithoutFetch = false

    /// How Start Task's work ended.
    enum Outcome: Equatable {
        /// The workspace opened: the sheet closes.
        case opened
        /// Nothing was created.
        case failed(String)
        /// Origin's branch couldn't be fetched; nothing was created.
        case fetchFailed(String)
    }

    let descriptionView = NSTextView()
    let templatePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let agentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let projectPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let repositoryLabel = NSTextField(labelWithString: "")
    let branchField = NSTextField()
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    let startButton = NSButton(title: "Start Task", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    static let agents: [(agent: NiruxApp.WorkspaceAgent, title: String)] = [(.claude, "Claude Code"), (.codex, "Codex")]

    private let scrollView = NSScrollView()
    private var documentHeight: CGFloat = 0
    private var maxHeight: CGFloat = .greatestFiniteMagnitude

    private static let width: CGFloat = 620
    private static let labelX: CGFloat = 24
    private static let fieldX: CGFloat = 132
    private static var fieldWidth: CGFloat { width - fieldX - 24 }
    private static let buttonsHeight: CGFloat = 66

    // Explicit, so the controls' default values are made on the main actor
    // with every toolchain.
    override init() {
        super.init()
    }

    func show(attachedTo window: NSWindow, projects: [Project], selectedProjectID: String) {
        parentWindow = window
        self.projects = projects
        let top = window.frame.minY + window.contentLayoutRect.maxY
        let visibleBottom = (window.screen ?? NSScreen.main)?.visibleFrame.minY ?? window.frame.minY
        maxHeight = max(320, top - max(window.frame.minY, visibleBottom) - 40)
        let panel = buildPanel()
        self.panel = panel
        projectPopup.selectItem(at: projects.firstIndex { $0.id == selectedProjectID } ?? 0)
        layoutPanel()
        window.beginSheet(panel)
        panel.makeFirstResponder(descriptionView)
        projectChanged(nil)
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

    /// Shows the sheet again: New Task… while it is hidden, or a failure.
    func reshow() {
        guard let panel, isHidden, let parentWindow else { return }
        isHidden = false
        parentWindow.beginSheet(panel)
    }

    // MARK: - Values

    var selectedProjectID: String? {
        projects[safe: projectPopup.indexOfSelectedItem]?.id
    }

    /// Nil for "None", the first item.
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

    /// The project's info, read by the shell. Ignored when another project
    /// was selected since.
    func update(projectID: String, info: ProjectInfo) {
        guard panel != nil, projectID == selectedProjectID else { return }
        let previousTemplate = selectedTemplate?.name
        self.info = info
        startsWithoutFetch = false
        templatePopup.removeAllItems()
        // Menu items, not addItem(withTitle:), which drops a title already
        // there: indexes must match `info.templates`.
        templatePopup.menu?.addItem(NSMenuItem(title: "None", action: nil, keyEquivalent: ""))
        for template in info.templates {
            templatePopup.menu?.addItem(NSMenuItem(title: template.name, action: nil, keyEquivalent: ""))
        }
        templatePopup.selectItem(at: previousTemplate.flatMap { name in
            info.templates.firstIndex { $0.name == name }.map { $0 + 1 }
        } ?? 0)
        templatePopup.isEnabled = !isStarting
        repositoryLabel.stringValue = Self.repositoryText(info.target)
        // Orange without a repository, or when the branch starts from
        // whatever the checkout has out rather than origin's branch.
        repositoryLabel.textColor = info.target?.remoteBranch == nil
            ? NSColor.systemOrange : NSColor.white.withAlphaComponent(0.5)
        updateBranchSuggestion()
        updateStartButton()
    }

    /// Called by the shell once Start Task's work is over.
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
            message = "Couldn’t fetch \(branch): \(error)\nStart Task again to start from \(branch) as last fetched."
            startsWithoutFetch = true
        }
        let wasHidden = isHidden
        reshow()
        setControlsEnabled(true)
        showError(message)
        if wasHidden {
            // It comes back while the user types elsewhere: no field takes
            // the keys, and Return doesn't start the task until they edit
            // something here (⌘Return and a click still do).
            panel?.makeFirstResponder(nil)
            startButton.keyEquivalent = ""
        } else {
            // The field being edited lost the focus when it was disabled.
            panel?.makeFirstResponder(branchField)
            branchField.selectText(nil)
        }
    }

    /// The user edits the form: Return starts the task again.
    private func restoreReturnKey() {
        startButton.keyEquivalent = "\r"
    }

    // MARK: - Actions

    @objc func startAction(_ sender: Any?) {
        guard panel != nil, !isStarting else { return }
        guard let request = draftRequest() else { return }
        hideError()
        isStarting = true
        setControlsEnabled(false)
        let fetching = request.fetchesFirst ? request.target.remoteBranchName.map { "Fetching \($0), then creating" } : nil
        repositoryLabel.stringValue = (fetching ?? "Creating") + " the worktree… Close keeps it going: "
            + "the workspace opens when it’s ready."
        onStart?(request)
    }

    @objc func cancelAction(_ sender: Any?) {
        if isStarting { return hide() }
        dismiss()
    }

    @objc func projectChanged(_ sender: Any?) {
        guard let projectID = selectedProjectID else { return }
        info = nil
        repositoryLabel.stringValue = "Looking for the project’s repository…"
        repositoryLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        templatePopup.isEnabled = false
        updateStartButton()
        onProjectSelected?(projectID)
    }

    @objc func templateChanged(_ sender: Any?) {
        restoreReturnKey()
        updateBranchSuggestion()
    }

    /// The request for the values on screen, or nil with the reason shown.
    private func draftRequest() -> NewTask.Request? {
        let description = descriptionView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            showError("Describe the task first.")
            panel?.makeFirstResponder(descriptionView)
            return nil
        }
        guard !branch.isEmpty else {
            showError("Name the branch.")
            panel?.makeFirstResponder(branchField)
            return nil
        }
        guard let projectID = selectedProjectID, let target = info?.target else {
            showError(info == nil ? "The project’s repository is still being looked for." : Self.repositoryText(nil))
            return nil
        }
        return NewTask.Request(
            description: description, template: selectedTemplate, agent: selectedAgent,
            projectID: projectID, branch: branch, target: target, fetchesFirst: !startsWithoutFetch
        )
    }

    private func updateBranchSuggestion() {
        guard !branchIsEdited else { return }
        branchField.stringValue = NewTask.suggestedBranch(
            description: descriptionView.string, templateName: selectedTemplate?.name
        )
    }

    private func updateStartButton() {
        startButton.isEnabled = !isStarting && info?.target != nil
    }

    private func setControlsEnabled(_ enabled: Bool) {
        descriptionView.isEditable = enabled
        descriptionView.textColor = NSColor.white.withAlphaComponent(enabled ? 0.92 : 0.45)
        for control in [templatePopup, agentPopup, projectPopup, branchField] as [NSControl] {
            control.isEnabled = enabled
        }
        if enabled { templatePopup.isEnabled = info != nil }
        cancelButton.title = enabled ? "Cancel" : "Close"
        updateStartButton()
        if enabled, let target = info?.target {
            repositoryLabel.stringValue = Self.repositoryText(target, fetches: !startsWithoutFetch)
        }
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
        layoutPanel()
    }

    private func hideError() {
        errorLabel.isHidden = true
        layoutPanel()
    }

    // MARK: - Delegates

    func textDidChange(_ notification: Notification) {
        restoreReturnKey()
        updateBranchSuggestion()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === branchField else { return }
        restoreReturnKey()
        // Cleared: the description names the branch again.
        branchIsEdited = !branch.isEmpty
        if !branchIsEdited { updateBranchSuggestion() }
    }

    /// Tab leaves the description instead of typing a tab into it.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
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

    private func layoutPanel() {
        guard let panel else { return }
        let errorHeight = errorLabel.isHidden ? 0 : Self.wrappedHeight(of: errorLabel, width: Self.width - 48)
        let bottom = Self.buttonsHeight + (errorLabel.isHidden ? 0 : errorHeight + 8)
        let height = min(documentHeight + bottom, max(maxHeight, bottom + 120))
        panel.setContentSize(NSSize(width: Self.width, height: height))
        scrollView.frame = NSRect(x: 0, y: bottom, width: Self.width, height: height - bottom)
        scrollView.documentView?.setFrameSize(NSSize(width: scrollView.contentSize.width, height: documentHeight))
        errorLabel.frame = NSRect(x: 24, y: Self.buttonsHeight - 4, width: Self.width - 48, height: errorHeight)
        cancelButton.frame = NSRect(x: Self.width - 238, y: 18, width: 96, height: 30)
        startButton.frame = NSRect(x: Self.width - 136, y: 18, width: 112, height: 30)
    }

    // MARK: - Construction

    private func buildPanel() -> NSPanel {
        let view = buildFields()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: documentHeight + Self.buttonsHeight))
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = view
        container.addSubview(scrollView)

        errorLabel.font = .systemFont(ofSize: 11.5)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 0
        errorLabel.preferredMaxLayoutWidth = Self.width - 48
        errorLabel.isHidden = true
        container.addSubview(errorLabel)

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelAction(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        container.addSubview(cancelButton)
        startButton.bezelStyle = .rounded
        startButton.target = self
        startButton.action = #selector(startAction(_:))
        startButton.keyEquivalent = "\r"
        startButton.isEnabled = false
        container.addSubview(startButton)

        let panel = NewTaskSheet(
            contentRect: container.frame,
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
        panel.contentView = container
        panel.multilineView = descriptionView
        panel.onCommandReturn = { [weak self] in self?.startAction(nil) }
        return panel
    }

    /// The scrolling part: everything above the error and the buttons.
    private func buildFields() -> NSView {
        let view = FlippedView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        var y: CGFloat = 20

        let heading = NSTextField(labelWithString: "New Task")
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        heading.textColor = NSColor.white.withAlphaComponent(0.94)
        heading.frame = NSRect(x: 24, y: y, width: Self.width - 48, height: 22)
        view.addSubview(heading)
        y += 28
        let intro = Self.wrappingLabel(
            "Nirux creates a worktree on a new branch, writes the task into its handover, "
                + "and starts the agent in a new workspace named after the task.",
            width: Self.width - 48, size: 11.5, alpha: 0.5
        )
        intro.frame.origin = NSPoint(x: 24, y: y)
        view.addSubview(intro)
        y += intro.frame.height + 16

        y = addLabel("Task", y: y, in: view)
        y = addDescriptionView(y: y, in: view)
        y = addHint(
            "What the agent should do. The first line names the workspace and the branch. ⌘Return starts the task.",
            y: y, in: view
        ) + 10

        y = addLabel("Template", y: y, in: view)
        templatePopup.target = self
        templatePopup.action = #selector(templateChanged(_:))
        templatePopup.menu?.addItem(NSMenuItem(title: "None", action: nil, keyEquivalent: ""))
        templatePopup.isEnabled = false
        y = addPopup(templatePopup, y: y, in: view)
        y = addHint("How to proceed, added to the handover: Edit Task Templates… in the project’s menu.", y: y, in: view) + 10

        y = addLabel("Agent", y: y, in: view)
        agentPopup.addItems(withTitles: Self.agents.map(\.title))
        y = addPopup(agentPopup, y: y, in: view) + 6

        y = addLabel("Project", y: y, in: view)
        for project in projects {
            projectPopup.menu?.addItem(NSMenuItem(title: project.name, action: nil, keyEquivalent: ""))
        }
        projectPopup.target = self
        projectPopup.action = #selector(projectChanged(_:))
        y = addPopup(projectPopup, y: y, in: view)
        repositoryLabel.font = .systemFont(ofSize: 11)
        repositoryLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        repositoryLabel.lineBreakMode = .byTruncatingMiddle
        repositoryLabel.maximumNumberOfLines = 2
        repositoryLabel.cell?.wraps = true
        repositoryLabel.frame = NSRect(x: Self.fieldX, y: y, width: Self.fieldWidth, height: 30)
        view.addSubview(repositoryLabel)
        y += 30 + 10

        y = addLabel("Branch", y: y, in: view)
        branchField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        branchField.placeholderString = "feat/… or fix/…"
        branchField.usesSingleLineMode = true
        branchField.lineBreakMode = .byTruncatingTail
        branchField.delegate = self
        branchField.frame = NSRect(x: Self.fieldX, y: y, width: Self.fieldWidth, height: 24)
        view.addSubview(branchField)
        y += 28
        y = addHint("A new branch: one that already exists, here or on a remote, is refused.", y: y, in: view) + 16

        view.setFrameSize(NSSize(width: Self.width, height: y))
        documentHeight = y
        return view
    }

    private func addLabel(_ text: String, y: CGFloat, in view: NSView) -> CGFloat {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.frame = NSRect(x: Self.labelX, y: y + 3, width: Self.fieldX - Self.labelX - 8, height: 18)
        view.addSubview(label)
        return y
    }

    private func addPopup(_ popup: NSPopUpButton, y: CGFloat, in view: NSView) -> CGFloat {
        popup.frame = NSRect(x: Self.fieldX, y: y - 1, width: Self.fieldWidth, height: 26)
        view.addSubview(popup)
        return y + 28
    }

    private func addDescriptionView(y: CGFloat, in view: NSView) -> CGFloat {
        let scroll = NSScrollView(frame: NSRect(x: Self.fieldX, y: y, width: Self.fieldWidth, height: 128))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        descriptionView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        descriptionView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        descriptionView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        descriptionView.isVerticallyResizable = true
        descriptionView.autoresizingMask = [.width]
        descriptionView.textContainer?.widthTracksTextView = true
        descriptionView.isRichText = false
        descriptionView.allowsUndo = true
        descriptionView.font = .systemFont(ofSize: 13)
        descriptionView.textColor = NSColor.white.withAlphaComponent(0.92)
        descriptionView.insertionPointColor = .white
        descriptionView.isAutomaticQuoteSubstitutionEnabled = false
        descriptionView.isAutomaticDashSubstitutionEnabled = false
        descriptionView.isAutomaticTextReplacementEnabled = false
        descriptionView.delegate = self
        scroll.documentView = descriptionView
        view.addSubview(scroll)
        return y + 132
    }

    private func addHint(_ text: String, y: CGFloat, in view: NSView) -> CGFloat {
        let label = Self.wrappingLabel(text, width: Self.fieldWidth, size: 11, alpha: 0.4)
        label.frame.origin = NSPoint(x: Self.fieldX, y: y)
        view.addSubview(label)
        return y + label.frame.height
    }

    /// Sized for its text at `width`.
    private static func wrappingLabel(_ text: String, width: CGFloat, size: CGFloat, alpha: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = NSColor.white.withAlphaComponent(alpha)
        label.preferredMaxLayoutWidth = width
        label.frame.size = NSSize(width: width, height: wrappedHeight(of: label, width: width))
        return label
    }

    private static func wrappedHeight(of label: NSTextField, width: CGFloat) -> CGFloat {
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        return ceil(label.cell?.cellSize(forBounds: bounds).height ?? 16)
    }

    // MARK: - Text

    /// Under the project: its repository and where the branch starts, or why
    /// there is none.
    static func repositoryText(_ target: NewTask.Target?, fetches: Bool = true) -> String {
        guard let target else {
            return "No workspace of this project is in a git repository: open one in it first."
        }
        var path = (target.repository as NSString).abbreviatingWithTildeInPath
        if let subdirectory = target.subdirectory { path += ", in \(subdirectory)" }
        if let remoteBranch = target.remoteBranchName {
            return fetches
                ? "\(path)\nStarts from \(remoteBranch), fetched when the task starts."
                : "\(path)\nStarts from \(remoteBranch) as last fetched: the fetch failed."
        }
        let head = target.checkoutBranch.map { "HEAD (\($0))" } ?? "HEAD"
        return "\(path)\nStarts from this checkout’s \(head): origin has no default branch Nirux knows of."
    }
}

/// Return in the description adds a line, and ⌘Return starts the task from
/// anywhere in the sheet.
final class NewTaskSheet: NSPanel {
    weak var multilineView: NSTextView?
    var onCommandReturn: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .command, event.charactersIgnoringModifiers == "\r" {
            onCommandReturn?()
            return true
        }
        if BoardSettingsSheet.leavesToTextView(event, firstResponder: firstResponder, multilineView: multilineView) {
            return false
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
