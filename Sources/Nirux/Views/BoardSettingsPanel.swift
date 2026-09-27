import AppKit

/// "Board Settings…" in a space's menu: the Project Board's config for that
/// space (see BoardConfig), in a sheet on the main window. Each field shows
/// what board.json holds, else what the space's checkouts suggest
/// (BoardConfigSuggestions), else the default. Nothing is written before
/// Save, and Save refuses invalid values. The post-merge workflow is never
/// preselected: it stays unset until the user picks a file or None. A file
/// this build must not rewrite is shown read-only, with the reason, and
/// Save disabled.
@MainActor
final class BoardSettingsPanel: NSObject, NSTextViewDelegate {
    struct Content {
        let spaceID: String
        let spaceName: String
        let filePath: String
        let loaded: BoardConfigStore.Loaded
        let suggestions: BoardConfigSuggestions
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
    var onDismiss: (() -> Void)?

    private(set) var panel: NSPanel?
    private weak var parentWindow: NSWindow?
    private(set) var spaceID: String?
    private(set) var isWritable = true

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
    let saveButton = NSButton(title: "Save", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    /// The choice behind each item of `workflowPopup`, by index; nil for a
    /// separator.
    private(set) var workflowChoices: [WorkflowChoice?] = []

    private let scrollView = NSScrollView()
    /// The fields' height: the sheet is as tall, up to `maxHeight`, and they
    /// scroll beyond it.
    private var documentHeight: CGFloat = 0
    private var maxHeight: CGFloat = .greatestFiniteMagnitude

    private static let width: CGFloat = 620
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

    func show(attachedTo window: NSWindow, content: Content) {
        parentWindow = window
        spaceID = content.spaceID
        isWritable = content.loaded.isWritable
        // A sheet hangs from the title bar: it must fit in the window and on
        // the screen, or Save ends up under the Dock.
        let screenHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? .greatestFiniteMagnitude
        maxHeight = max(320, min(window.contentLayoutRect.height, screenHeight) - 40)
        let panel = buildPanel(content)
        self.panel = panel
        layoutPanel()
        window.beginSheet(panel)
        panel.makeFirstResponder(isWritable ? repositoryField : cancelButton)
    }

    func focus() {
        panel?.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard let panel else { return }
        parentWindow?.endSheet(panel)
        panel.orderOut(nil)
        self.panel = nil
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

    @objc func saveAction(_ sender: Any?) {
        guard isWritable, panel != nil else { return }
        let config = draftConfig()
        let problems = config.problems
        guard problems.isEmpty else { return showError(problems.joined(separator: "\n")) }
        if let failure = onSave?(config) { return showError(failure) }
        dismiss()
    }

    @objc func cancelAction(_ sender: Any?) {
        dismiss()
    }

    @objc func workflowChanged(_ sender: Any?) {
        let isOther = selectedWorkflowChoice == .other
        workflowNameField.isEnabled = isWritable && isOther
        if isOther { panel?.makeFirstResponder(workflowNameField) }
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        layoutPanel()
    }

    /// The fields scroll above the buttons; an error shows between them,
    /// whole, and the sheet grows for it while it fits.
    private func layoutPanel() {
        guard let panel else { return }
        let errorHeight = errorLabel.isHidden ? 0 : Self.wrappedHeight(of: errorLabel, width: Self.width - 48)
        let bottom = Self.buttonsHeight + (errorLabel.isHidden ? 0 : errorHeight + 8)
        let height = min(documentHeight + bottom, max(maxHeight, bottom + 120))
        panel.setContentSize(NSSize(width: Self.width, height: height))
        scrollView.frame = NSRect(x: 0, y: bottom, width: Self.width, height: height - bottom)
        errorLabel.frame = NSRect(x: 24, y: Self.buttonsHeight - 4, width: Self.width - 48, height: errorHeight)
        cancelButton.frame = NSRect(x: Self.width - 222, y: 18, width: 96, height: 30)
        saveButton.frame = NSRect(x: Self.width - 120, y: 18, width: 96, height: 30)
    }

    /// Tab leaves the checks list instead of typing a tab into it.
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

    // MARK: - Construction

    private func buildPanel(_ content: Content) -> NSPanel {
        let saved = content.loaded.config
        let suggestions = content.suggestions
        // A read-only file shows what it holds and nothing else: suggestions
        // mustn't pass for its values. The hints still say what they are.
        let isUnread = saved == nil && !content.loaded.isWritable
        let suggested = content.loaded.isWritable ? suggestions : nil
        let view = FlippedView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        var y: CGFloat = 20

        let heading = NSTextField(labelWithString: "Board Settings · \(content.spaceName)")
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        heading.textColor = NSColor.white.withAlphaComponent(0.94)
        heading.lineBreakMode = .byTruncatingTail
        heading.frame = NSRect(x: 24, y: y, width: Self.width - 48, height: 22)
        view.addSubview(heading)
        y += 28

        let path = (content.filePath as NSString).abbreviatingWithTildeInPath
        y = addWrappingLabel(
            "The Project Board and its merge queue use these settings. They are kept in \(path), "
                + "never in the repository. Nothing is written before Save.",
            x: 24, y: y, width: Self.width - 48, size: 11.5, alpha: 0.5, in: view
        ) + 12

        if let banner = Self.bannerText(for: content.loaded.status) {
            y = addBanner(banner, y: y, in: view) + 14
        }

        y = addLabel("Repository", y: y, in: view)
        repositoryField.stringValue = isUnread ? "" : saved?.repository ?? suggested?.repository ?? ""
        repositoryField.placeholderString = "owner/name"
        y = addField(repositoryField, y: y, in: view)
        y = addHint(Self.repositoryHint(suggestions), y: y, in: view) + 10

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

        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: y + Self.buttonsHeight))
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

        cancelButton.title = isWritable ? "Cancel" : "Close"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelAction(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        container.addSubview(cancelButton)
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveAction(_:))
        saveButton.keyEquivalent = "\r"
        saveButton.isEnabled = isWritable
        container.addSubview(saveButton)

        let panel = NSPanel(
            contentRect: container.frame,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(red: 0.105, green: 0.105, blue: 0.14, alpha: 1)
        panel.isReleasedWhenClosed = false
        panel.autorecalculatesKeyViewLoop = true
        panel.contentView = container
        return panel
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

    static func repositoryHint(_ suggestions: BoardConfigSuggestions) -> String {
        switch suggestions.source {
        case .shared:
            return "This space’s workspaces push to \(suggestions.repository ?? "it")."
        case .differing(let repositories):
            return "This space’s workspaces push to different places (\(repositories.joined(separator: ", "))): "
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
