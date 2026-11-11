import AppKit

/// Space Settings › Board: the Project Board's config for that space (see
/// BoardConfig), in the tab's view. Each field shows what board.json
/// holds, else what the space's checkouts suggest (BoardConfigSuggestions),
/// else the default. Nothing is written before Save, and Save refuses
/// invalid values; Revert reads the file again. The post-merge workflow is
/// never preselected: it stays unset until the user picks a file or None.
/// A file this build must not rewrite is shown read-only, with the reason,
/// and Save disabled. A space with several repositories (docs/design/spaces.md,
/// S12) picks the one it edits in a Repository pop-up; leaving one with
/// unsaved values asks first.
@MainActor
final class BoardSettingsPanel: NSObject, NSTextViewDelegate {
    struct Content {
        let spaceID: String
        let spaceName: String
        let filePath: String
        /// board.json about the repository shown.
        let loaded: BoardConfigStore.Loaded
        let suggestions: BoardConfigSuggestions
        /// The space's repositories when it has several (the pop-up's
        /// items), else none.
        var repositories: [Repository] = []
        /// The id of the one shown.
        var selectedRepository: String?
    }

    struct Repository: Equatable {
        let id: String
        let title: String
    }

    /// What to do with values typed but not saved, before showing another
    /// repository.
    enum ChangesAnswer {
        case save, discard, cancel
    }

    enum WorkflowChoice: Equatable {
        case unset
        case file(String)
        case noWorkflow
        /// A name typed in `workflowNameField`.
        case other
    }

    /// Writes the config. Returns nil once it is saved, else what to show.
    var onSave: ((BoardConfig) -> String?)?
    /// Revert: the shell reads the file again and shows a new form.
    var onRevert: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// The pop-up picked another repository: the shell shows its form.
    var onSelectRepository: ((String) -> Void)?
    /// Asks whether to save the values typed for the repository named, before
    /// leaving it. An alert on the window; tests answer for the user.
    lazy var askToSaveChanges: (String, @escaping (ChangesAnswer) -> Void) -> Void = { [weak self] name, answer in
        self?.askToSave(name, answer: answer)
    }

    /// The tab's view the form fills; nil once dismissed.
    private(set) weak var hostView: NSView?
    private var container: NSView?
    /// The values as shown: anything else typed isn't saved.
    private var shownConfig: BoardConfig?
    private(set) var spaceID: String?
    private(set) var isWritable = true

    let repositoryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// The repository behind each item of `repositoryPopup`.
    private(set) var repositoryChoices: [Repository] = []
    /// The one shown, which the pop-up goes back to when leaving is cancelled.
    private var shownRepository: String?
    let repositoryField = NSTextField()
    let baseBranchField = NSTextField()
    let checksView = NSTextView()
    let workflowPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let workflowNameField = NSTextField()
    let mergeMethodPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let checksTimeoutField = NSTextField()
    let postMergeTimeoutField = NSTextField()
    let bannerLabel = NSTextField(wrappingLabelWithString: "")
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let saveButton = NSButton(title: "Save", target: nil, action: nil)
    let revertButton = NSButton(title: "Revert", target: nil, action: nil)
    /// The choice behind each item of `workflowPopup`, by index; nil for a
    /// separator.
    private(set) var workflowChoices: [WorkflowChoice?] = []

    private let scrollView = NSScrollView()
    /// The fields' height: they scroll beyond the tab's.
    private var documentHeight: CGFloat = 0

    /// The tab's size: the fields scroll inside it.
    static let hostSize = NSSize(width: 620, height: 600)
    private static let width: CGFloat = hostSize.width
    private static let labelX: CGFloat = 24
    private static let fieldX: CGFloat = 184
    private static var fieldWidth: CGFloat { width - fieldX - 24 }
    /// The buttons' band at the bottom, outside the scrolling fields.
    private static let buttonsHeight: CGFloat = 66

    // Explicit, so the controls' default values are made on the main actor
    // with every toolchain.
    override init() {
        super.init()
    }

    /// Fills `host` (a Space Settings tab) with the form. `status` shows
    /// next to the buttons ("Saved." after a save, which shows a new form).
    func show(in host: NSView, content: Content, status: String? = nil) {
        hostView = host
        spaceID = content.spaceID
        isWritable = content.loaded.isWritable
        let container = buildContainer(content)
        self.container = container
        // The host is held at this size; it may not be laid out yet, and
        // resizing masks would add its first size to the container's.
        container.frame = NSRect(origin: .zero, size: Self.hostSize)
        host.addSubview(container)
        shownConfig = draftConfig()
        shownRepository = content.selectedRepository
        statusLabel.stringValue = status ?? ""
        layoutPanel()
        if host.window != nil, isWritable { host.window?.makeFirstResponder(repositoryField) }
    }

    func dismiss() {
        guard let container else { return }
        container.removeFromSuperview()
        self.container = nil
        hostView = nil
        onDismiss?()
    }

    // MARK: - Values

    var selectedWorkflowChoice: WorkflowChoice {
        let index = workflowPopup.indexOfSelectedItem
        return workflowChoices.indices.contains(index) ? workflowChoices[index] ?? .unset : .unset
    }

    /// The values on screen, as a config. A pasted github.com URL reads as
    /// its `owner/name`, blank check lines are dropped, and a timeout that
    /// isn't a number reads as 0, which `problems` refuses.
    func draftConfig() -> BoardConfig {
        var config = BoardConfig()
        config.repository = Self.trimmedValue(of: repositoryField).map { value in
            value.contains("github.com") ? BoardConfigSuggestions.repositoryName(remoteURL: value) ?? value : value
        }
        config.baseBranch = Self.trimmedValue(of: baseBranchField)
        var checks: [String] = []
        for line in checksView.string.components(separatedBy: .newlines) {
            let name = line.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !checks.contains(name) { checks.append(name) }
        }
        config.requiredChecks = checks
        switch selectedWorkflowChoice {
        case .unset: config.postMergeWorkflow = .unset
        case .noWorkflow: config.postMergeWorkflow = .noWorkflow
        case .file(let file): config.postMergeWorkflow = .workflow(file)
        case .other: config.postMergeWorkflow = Self.trimmedValue(of: workflowNameField).map { .workflow($0) } ?? .unset
        }
        let methods = BoardConfig.MergeMethod.allCases
        let methodIndex = mergeMethodPopup.indexOfSelectedItem
        config.mergeMethod = methods.indices.contains(methodIndex) ? methods[methodIndex] : .merge
        config.checksTimeoutMinutes = Self.trimmedValue(of: checksTimeoutField).flatMap { Int($0) } ?? 0
        config.postMergeTimeoutMinutes = Self.trimmedValue(of: postMergeTimeoutField).flatMap { Int($0) } ?? 0
        return config
    }

    private static func trimmedValue(of field: NSTextField) -> String? {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - Actions

    /// Values typed and not saved.
    var isDirty: Bool { isWritable && container != nil && draftConfig() != shownConfig }

    /// Saves what is typed; false with the reason shown when it can't.
    @discardableResult
    func save() -> Bool {
        guard isWritable, container != nil else { return false }
        let config = draftConfig()
        let problems = config.problems
        guard problems.isEmpty else {
            showError(problems.joined(separator: "\n"))
            return false
        }
        if let failure = onSave?(config) {
            showError(failure)
            return false
        }
        return true
    }

    @objc func saveAction(_ sender: Any?) {
        save()
    }

    @objc func revertAction(_ sender: Any?) {
        onRevert?()
    }

    /// Another repository: its form, once what was typed here is saved or
    /// let go.
    @objc func repositoryChanged(_ sender: Any?) {
        let index = repositoryPopup.indexOfSelectedItem
        guard repositoryChoices.indices.contains(index) else { return }
        requestRepository(repositoryChoices[index].id)
    }

    /// The form of repository `target` (a section's id), even one its
    /// pop-up doesn't list yet (an anchor added since it opened), once what
    /// was typed here is saved or let go.
    func requestRepository(_ target: String) {
        guard target != shownRepository else { return }
        guard isDirty else { return onSelectRepository?(target) ?? () }
        // One question at a time: the board's button, in another window,
        // can ask again while it shows.
        if let window = hostView?.window, window.attachedSheet != nil {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let name = repositoryChoices.first { $0.id == shownRepository }?.title ?? "this repository"
        askToSaveChanges(name) { [weak self] answer in
            guard let self, self.container != nil else { return }
            // A save refused says why, and the form stays.
            if answer == .discard || (answer == .save && self.save()) {
                self.onSelectRepository?(target)
            } else {
                self.repositoryPopup.selectItem(at: self.repositoryChoices.firstIndex { $0.id == self.shownRepository } ?? 0)
            }
        }
    }

    private func askToSave(_ name: String, answer: @escaping (ChangesAnswer) -> Void) {
        guard let window = hostView?.window else { return answer(.cancel) }
        let alert = NSAlert()
        alert.messageText = "Save the changes to “\(name)”?"
        alert.informativeText = "They are lost if you show another repository without saving them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: answer(.save)
            case .alertThirdButtonReturn: answer(.discard)
            default: answer(.cancel)
            }
        }
    }

    @objc func workflowChanged(_ sender: Any?) {
        let isOther = selectedWorkflowChoice == .other
        workflowNameField.isEnabled = isWritable && isOther
        if isOther { hostView?.window?.makeFirstResponder(workflowNameField) }
    }

    private func showError(_ message: String) {
        statusLabel.stringValue = ""
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        layoutPanel()
    }

    /// The fields scroll above the buttons; an error shows between them,
    /// whole.
    private func layoutPanel() {
        guard let container else { return }
        let size = container.bounds.size
        let errorHeight = errorLabel.isHidden ? 0 : Self.wrappedHeight(of: errorLabel, width: Self.width - 48)
        let bottom = Self.buttonsHeight + (errorLabel.isHidden ? 0 : errorHeight + 8)
        scrollView.frame = NSRect(x: 0, y: bottom, width: size.width, height: max(120, size.height - bottom))
        // No sideways scrolling when scroll bars take room of their own.
        scrollView.documentView?.setFrameSize(NSSize(width: scrollView.contentSize.width, height: documentHeight))
        scrollView.documentView?.scroll(.zero)
        errorLabel.frame = NSRect(x: 24, y: Self.buttonsHeight - 4, width: Self.width - 48, height: errorHeight)
        revertButton.frame = NSRect(x: Self.width - 222, y: 18, width: 96, height: 30)
        saveButton.frame = NSRect(x: Self.width - 120, y: 18, width: 96, height: 30)
        statusLabel.frame = NSRect(x: 24, y: 24, width: Self.width - 260, height: 18)
    }

    /// Tab leaves the checks list instead of typing a tab into it.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            textView.window?.selectNextKeyView(nil)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            textView.window?.selectPreviousKeyView(nil)
            return true
        default:
            return false
        }
    }

    // MARK: - Construction

    private func buildContainer(_ content: Content) -> NSView {
        let saved = content.loaded.config
        let suggestions = content.suggestions
        // A read-only file shows what it holds and nothing else: suggestions
        // mustn't pass for its values. The hints still say what they are.
        let isUnread = saved == nil && !content.loaded.isWritable
        let suggested = content.loaded.isWritable ? suggestions : nil
        let view = FlippedView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        var y: CGFloat = 20

        let path = (content.filePath as NSString).abbreviatingWithTildeInPath
        y = addWrappingLabel(
            "The Board and its merge queue use these settings. They are kept in \(path), "
                + "never in the repository. Nothing is written before Save.",
            x: 24, y: y, width: Self.width - 48, size: 11.5, alpha: 0.5, in: view
        ) + 12

        if let banner = Self.bannerText(for: content.loaded.status) {
            y = addBanner(banner, y: y, in: view) + 14
        }

        repositoryChoices = content.repositories.count > 1 ? content.repositories : []
        if !repositoryChoices.isEmpty {
            y = addLabel("Repository", y: y, in: view)
            repositoryPopup.removeAllItems()
            // One item each, even with the same title: `addItems(withTitles:)`
            // would merge them and shift the indexes.
            for choice in repositoryChoices {
                repositoryPopup.menu?.addItem(withTitle: choice.title, action: nil, keyEquivalent: "")
            }
            repositoryPopup.selectItem(at: repositoryChoices.firstIndex { $0.id == content.selectedRepository } ?? 0)
            repositoryPopup.target = self
            repositoryPopup.action = #selector(repositoryChanged(_:))
            repositoryPopup.frame = NSRect(x: Self.fieldX, y: y - 1, width: 240, height: 26)
            view.addSubview(repositoryPopup)
            y += 28
            y = addHint("Each repository of the space has its own settings and its own merge queue.", y: y, in: view) + 14
        }

        y = addLabel(repositoryChoices.isEmpty ? "Repository" : "GitHub repository", y: y, in: view)
        repositoryField.stringValue = isUnread ? "" : saved?.repository ?? suggested?.repository ?? ""
        repositoryField.placeholderString = "owner/name"
        y = addField(repositoryField, y: y, in: view)
        y = addHint(Self.repositoryHint(suggestions, saved: saved?.repository), y: y, in: view) + 10

        y = addLabel("Base branch", y: y, in: view)
        baseBranchField.stringValue = isUnread ? "" : saved?.baseBranch ?? suggested?.baseBranch ?? ""
        baseBranchField.placeholderString = "main"
        y = addField(baseBranchField, y: y, in: view)
        y = addHint(Self.baseBranchHint(suggestions), y: y, in: view) + 10

        y = addLabel("Required checks", y: y, in: view)
        let checks = isUnread ? [] : saved?.requiredChecks ?? BoardConfig.defaultRequiredChecks
        y = addChecksView(text: checks.joined(separator: "\n"), y: y, in: view)
        y = addHint(
            "One per line: a check run’s name, or Workflow / job, without the (pull_request) the pull request "
                + "page adds. The queue merges only when each is green; a name that never shows up stops it.",
            y: y, in: view
        ) + 10

        y = addLabel("Post-merge workflow", y: y, in: view)
        y = addWorkflowControls(
            saved: isUnread ? .unset : saved?.postMergeWorkflow ?? .unset,
            files: suggestions.workflowFiles, y: y, in: view
        )
        y = addHint(Self.workflowHint(suggestions), y: y, in: view) + 10

        y = addLabel("Merge method", y: y, in: view)
        mergeMethodPopup.addItems(withTitles: BoardConfig.MergeMethod.allCases.map(Self.title(of:)))
        mergeMethodPopup.selectItem(at: BoardConfig.MergeMethod.allCases.firstIndex(of: saved?.mergeMethod ?? .merge) ?? 0)
        if case .readOnly(.unsupportedMergeMethod(let method)) = content.loaded.status {
            // What the file says, not the merge it reads as.
            mergeMethodPopup.addItem(withTitle: "\(method) (not supported)")
            mergeMethodPopup.selectItem(at: mergeMethodPopup.numberOfItems - 1)
        }
        mergeMethodPopup.frame = NSRect(x: Self.fieldX, y: y - 1, width: 200, height: 26)
        view.addSubview(mergeMethodPopup)
        y += 28
        y = addHint("Never rebase: the queue checks that each merge sits on the base it tested.", y: y, in: view) + 10

        y = addTimeoutRow(
            "Checks timeout", field: checksTimeoutField,
            minutes: isUnread ? nil : saved?.checksTimeoutMinutes ?? BoardConfig.defaultTimeoutMinutes, y: y, in: view
        )
        y = addTimeoutRow(
            "Post-merge timeout", field: postMergeTimeoutField,
            minutes: isUnread ? nil : saved?.postMergeTimeoutMinutes ?? BoardConfig.defaultTimeoutMinutes, y: y, in: view
        )
        y = addHint(
            "Minutes the queue waits for the required checks, and for the post-merge run, before it stops.",
            y: y, in: view
        ) + 16

        if !isWritable {
            // Disabled, so they look it: nothing here can be saved.
            for field in [repositoryField, baseBranchField, workflowNameField, checksTimeoutField, postMergeTimeoutField] {
                field.isEditable = false
                field.isEnabled = false
            }
            checksView.isEditable = false
            checksView.textColor = NSColor.white.withAlphaComponent(0.45)
            workflowPopup.isEnabled = false
            mergeMethodPopup.isEnabled = false
        }
        view.setFrameSize(NSSize(width: Self.width, height: y))
        documentHeight = y

        let container = NSView(frame: NSRect(origin: .zero, size: Self.hostSize))
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

        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        container.addSubview(statusLabel)
        revertButton.bezelStyle = .rounded
        revertButton.target = self
        revertButton.action = #selector(revertAction(_:))
        revertButton.isEnabled = isWritable
        container.addSubview(revertButton)
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveAction(_:))
        saveButton.keyEquivalent = "\r"
        saveButton.isEnabled = isWritable
        container.addSubview(saveButton)
        return container
    }

    private func addLabel(_ text: String, y: CGFloat, in view: NSView) -> CGFloat {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.frame = NSRect(x: Self.labelX, y: y + 3, width: Self.fieldX - Self.labelX - 8, height: 18)
        view.addSubview(label)
        return y
    }

    private func addField(_ field: NSTextField, y: CGFloat, in view: NSView) -> CGFloat {
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.frame = NSRect(x: Self.fieldX, y: y, width: Self.fieldWidth, height: 24)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        view.addSubview(field)
        return y + 28
    }

    private func addChecksView(text: String, y: CGFloat, in view: NSView) -> CGFloat {
        let scroll = NSScrollView(frame: NSRect(x: Self.fieldX, y: y, width: Self.fieldWidth, height: 70))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        checksView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        checksView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        checksView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        checksView.isVerticallyResizable = true
        checksView.autoresizingMask = [.width]
        checksView.textContainer?.widthTracksTextView = true
        checksView.isRichText = false
        checksView.allowsUndo = true
        checksView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        checksView.textColor = NSColor.white.withAlphaComponent(0.9)
        checksView.insertionPointColor = .white
        checksView.isAutomaticQuoteSubstitutionEnabled = false
        checksView.isAutomaticDashSubstitutionEnabled = false
        checksView.isAutomaticTextReplacementEnabled = false
        checksView.isAutomaticSpellingCorrectionEnabled = false
        checksView.isContinuousSpellCheckingEnabled = false
        checksView.string = text
        checksView.delegate = self
        scroll.documentView = checksView
        view.addSubview(scroll)
        return y + 74
    }

    private func addWorkflowControls(
        saved: BoardConfig.PostMergeWorkflow, files: [String]?, y: CGFloat, in view: NSView
    ) -> CGFloat {
        var choices: [WorkflowChoice?] = [.unset]
        choices += (files ?? []).map { .file($0) }
        choices += [nil, .noWorkflow, .other]
        workflowChoices = choices
        // Menu items, not addItem(withTitle:), which drops an item whose
        // title is already there: indexes must match `workflowChoices`.
        for choice in choices {
            workflowPopup.menu?.addItem(
                choice.map { NSMenuItem(title: Self.title(of: $0), action: nil, keyEquivalent: "") } ?? .separator()
            )
        }
        let selected: WorkflowChoice
        switch saved {
        case .unset: selected = .unset
        case .noWorkflow: selected = .noWorkflow
        case .workflow(let file): selected = files?.contains(file) == true ? .file(file) : .other
        }
        workflowPopup.selectItem(at: choices.firstIndex(of: selected) ?? 0)
        workflowPopup.target = self
        workflowPopup.action = #selector(workflowChanged(_:))
        workflowPopup.frame = NSRect(x: Self.fieldX, y: y - 1, width: Self.fieldWidth, height: 26)
        view.addSubview(workflowPopup)

        if case .workflow(let file) = saved, selected == .other { workflowNameField.stringValue = file }
        workflowNameField.placeholderString = "With Other file…: its name, such as nightly.yml"
        workflowNameField.isEnabled = isWritable && selected == .other
        return addField(workflowNameField, y: y + 30, in: view)
    }

    private func addTimeoutRow(
        _ title: String, field: NSTextField, minutes: Int?, y: CGFloat, in view: NSView
    ) -> CGFloat {
        _ = addLabel(title, y: y, in: view)
        field.stringValue = minutes.map(String.init) ?? ""
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.alignment = .right
        field.usesSingleLineMode = true
        field.frame = NSRect(x: Self.fieldX, y: y, width: 60, height: 24)
        view.addSubview(field)
        let unit = NSTextField(labelWithString: "minutes")
        unit.font = .systemFont(ofSize: 12)
        unit.textColor = NSColor.white.withAlphaComponent(0.5)
        unit.frame = NSRect(x: Self.fieldX + 68, y: y + 3, width: 80, height: 18)
        view.addSubview(unit)
        return y + 30
    }

    @discardableResult
    private func addHint(_ text: String, y: CGFloat, in view: NSView) -> CGFloat {
        addWrappingLabel(text, x: Self.fieldX, y: y, width: Self.fieldWidth, size: 11, alpha: 0.4, in: view)
    }

    private func addWrappingLabel(
        _ text: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat, alpha: CGFloat, in view: NSView
    ) -> CGFloat {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = NSColor.white.withAlphaComponent(alpha)
        label.preferredMaxLayoutWidth = width
        let height = Self.wrappedHeight(of: label, width: width)
        label.frame = NSRect(x: x, y: y, width: width, height: height)
        view.addSubview(label)
        return y + height
    }

    private func addBanner(_ text: String, y: CGFloat, in view: NSView) -> CGFloat {
        let inset: CGFloat = 10
        let width = Self.width - 48
        bannerLabel.stringValue = text
        bannerLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        bannerLabel.textColor = NSColor.systemOrange
        bannerLabel.preferredMaxLayoutWidth = width - 2 * inset
        let height = Self.wrappedHeight(of: bannerLabel, width: width - 2 * inset)
        let box = NSView(frame: NSRect(x: 24, y: y, width: width, height: height + 2 * inset))
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        box.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.35).cgColor
        bannerLabel.frame = NSRect(x: inset, y: inset, width: width - 2 * inset, height: height)
        box.addSubview(bannerLabel)
        view.addSubview(box)
        return y + box.frame.height
    }

    private static func wrappedHeight(of label: NSTextField, width: CGFloat) -> CGFloat {
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        return ceil(label.cell?.cellSize(forBounds: bounds).height ?? 16)
    }

    // MARK: - Text

    static func bannerText(for status: BoardConfigStore.Loaded.Status) -> String? {
        switch status {
        case .missing, .loaded:
            return nil
        case .unreadable:
            return "board.json can’t be read. Save keeps a copy of it next to it "
                + "(board.corrupt.….json) before replacing it."
        case .readOnly(let reason):
            return reason.message
        }
    }

    static func repositoryHint(_ suggestions: BoardConfigSuggestions, saved: String? = nil) -> String {
        // Saved from another remote than the one gh takes as the base.
        if let saved, let suggested = suggestions.repository, case .shared = suggestions.source,
           saved.lowercased() != suggested.lowercased() {
            return "Saved as \(saved). gh would take \(suggested) as this space’s base repository."
        }
        switch suggestions.source {
        case .shared:
            return "This space’s pull requests live in \(suggestions.repository ?? "it") on GitHub."
        case .differing(let repositories):
            return "This space’s workspaces are in different repositories (\(repositories.joined(separator: ", "))): "
                + "type the repository whose pull requests the board shows."
        case .noRepository:
            return "No workspace of this space is in a git repository: type owner/name."
        }
    }

    static func baseBranchHint(_ suggestions: BoardConfigSuggestions) -> String {
        guard let checkout = suggestions.checkout else {
            return "No local checkout of this repository is open in the space: type the branch pull requests merge into."
        }
        let path = (checkout as NSString).abbreviatingWithTildeInPath
        guard suggestions.baseBranch != nil else {
            return "\(path) doesn’t know the remote’s default branch: type the branch pull requests merge into."
        }
        return "The remote’s default branch, as \(path) knows it."
    }

    static func workflowHint(_ suggestions: BoardConfigSuggestions) -> String {
        let purpose = "After each merge the queue waits for this workflow’s push run on the base branch. "
            + "None merges the next pull request right away."
        guard let checkout = suggestions.checkout else {
            return purpose + " No local checkout is known: choose Other file… and type its name."
        }
        let path = (checkout as NSString).abbreviatingWithTildeInPath
        let source = suggestions.workflowsRef.map { "\($0) in \(path)" } ?? path
        if suggestions.workflowFiles?.isEmpty != false {
            return purpose + " \(source) has no workflow file: choose Other file… to type one."
        }
        return purpose + " Files from .github/workflows of \(source)."
    }

    static func title(of choice: WorkflowChoice) -> String {
        switch choice {
        case .unset: return "Not set: choose one"
        case .file(let file): return file
        case .noWorkflow: return "None (merge the next PR right after a merge)"
        case .other: return "Other file…"
        }
    }

    static func title(of method: BoardConfig.MergeMethod) -> String {
        switch method {
        case .merge: return "Merge commit"
        case .squash: return "Squash"
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
