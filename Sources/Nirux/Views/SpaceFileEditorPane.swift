import AppKit

/// A plain-text file of the space, edited inside Space Settings: the brief,
/// the task templates (a tab each) and a repository's setup script (a
/// sheet). Nothing is written before Save (⌘S). A file that doesn't exist
/// yet shows its template and is created at Save. While nothing is typed,
/// a change on disk (an agent editing the brief) shows at once; with text
/// typed, Save asks before replacing it.
@MainActor
final class SpaceFileEditorPane: NSObject, NSTextViewDelegate {
    /// What the file holds, as last read.
    enum Contents: Equatable {
        case missing
        case text(String)
        /// Not a small UTF-8 regular file: shown, never replaced.
        case unreadable(String)
    }

    struct Source {
        /// "brief", "task templates", "setup script": names it in messages.
        let documentName: String
        let explanation: String
        let read: () -> Contents
        /// Writes the text (creating the file and its folder).
        let write: (String) throws -> Void
        /// The text shown while the file doesn't exist.
        let template: () -> String
        /// What the text weighs, beside the buttons (the brief's size); nil
        /// shows nothing.
        var sizeNote: ((String) -> (text: String, color: NSColor, toolTip: String))? = nil
    }

    enum Mode {
        /// A tab: Revert and Save.
        case tab
        /// A sheet: Cancel and Save, which closes it.
        case sheet
    }

    static let size = NSSize(width: 680, height: 500)

    let view = NSView()
    let textView = NSTextView()
    let explanationLabel = NSTextField(wrappingLabelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let sizeLabel = NSTextField(labelWithString: "")
    let saveButton = NSButton(title: "Save", target: nil, action: nil)
    let revertButton = NSButton(title: "Revert", target: nil, action: nil)

    private(set) var source: Source
    let mode: Mode
    /// What the file held when the text on screen was last made from it.
    private(set) var contents: Contents = .missing
    /// Its own: the window's would undo one tab's typing from another.
    private let undo = UndoManager()
    /// The text as last loaded or saved: typing anything else makes the
    /// pane dirty.
    private var baseline = ""

    /// Saved; in a sheet, the sheet should close.
    var onSaved: (() -> Void)?
    /// Cancel in a sheet.
    var onCancel: (() -> Void)?
    /// Asks a question in a sheet on the pane's window. Tests replace it.
    var askInSheet: (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { alert, window, answer in
        alert.beginSheetModal(for: window, completionHandler: answer)
    }

    var documentName: String { source.documentName }
    var isWritable: Bool {
        if case .unreadable = contents { return false }
        return true
    }
    var isDirty: Bool { isWritable && textView.string != baseline }

    init(source: Source, mode: Mode = .tab) {
        self.source = source
        self.mode = mode
        super.init()
        build()
        load()
    }

    /// Another file (the space was renamed: its template changes).
    func replaceSource(_ source: Source) {
        self.source = source
        explanationLabel.stringValue = source.explanation
        if !isDirty { load() }
    }

    // MARK: - Loading and saving

    /// Shows what the file holds now, dropping typed text.
    func load(_ read: Contents? = nil) {
        contents = read ?? source.read()
        switch contents {
        case .missing:
            baseline = source.template()
            setStatus("")
        case .text(let text):
            baseline = text
            setStatus("")
        case .unreadable(let reason):
            baseline = ""
            setStatus(reason, color: .systemOrange)
        }
        textView.string = baseline
        textView.isEditable = isWritable
        undo.removeAllActions()
        updateButtons()
    }

    /// The size line, from the text on screen.
    private func updateSize() {
        guard let note = source.sizeNote?(textView.string) else {
            sizeLabel.stringValue = ""
            return
        }
        sizeLabel.stringValue = note.text
        sizeLabel.textColor = note.color
        sizeLabel.toolTip = note.toolTip
    }

    @objc func revert() {
        load()
    }

    /// Writes the text. A file changed on disk since it was read asks first
    /// (false then: nothing written yet). False when the write failed.
    @discardableResult
    func save() -> Bool {
        guard isWritable else { return false }
        let current = source.read()
        guard current == contents else {
            askToReplaceChangedFile()
            return false
        }
        return write()
    }

    private func write() -> Bool {
        let text = textView.string
        do {
            try source.write(text)
        } catch {
            setStatus("Couldn’t save the \(documentName): \(error.localizedDescription)", color: .systemRed)
            return false
        }
        contents = source.read()
        // A setup script with only comments is deleted: the template shows.
        if contents == .missing { textView.string = source.template() }
        baseline = textView.string
        setStatus("Saved.")
        updateButtons()
        onSaved?()
        return true
    }

    private func askToReplaceChangedFile() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "The \(documentName) changed on disk"
        alert.informativeText = "It changed since you opened it, perhaps edited by an agent. Replace it with your text, "
            + "or keep editing (Revert shows what it holds now)."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Keep Editing")
        askInSheet(alert, window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            _ = self.write()
        }
    }

    /// A change on disk: shown at once while nothing is typed, else said.
    func checkDisk() {
        let current = source.read()
        guard current != contents else { return }
        if isDirty {
            setStatus("The \(documentName) changed on disk: Save replaces it, Revert shows it.", color: .systemOrange)
        } else {
            load(current)
            setStatus("Updated: the file changed on disk.")
        }
    }

    @objc func saveAction(_ sender: Any?) {
        save()
    }

    @objc func revertAction(_ sender: Any?) {
        if mode == .sheet {
            onCancel?()
        } else {
            revert()
        }
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        undo
    }

    func textDidChange(_ notification: Notification) {
        if statusLabel.stringValue == "Saved." { setStatus("") }
        updateButtons()
    }

    private func updateButtons() {
        saveButton.isEnabled = isWritable && (mode == .sheet || isDirty || contents == .missing)
        revertButton.isEnabled = mode == .sheet || isDirty
    }

    private func setStatus(_ text: String, color: NSColor = .secondaryLabelColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
        statusLabel.toolTip = text.isEmpty ? nil : text
    }

    // MARK: - Construction

    private func build() {
        view.translatesAutoresizingMaskIntoConstraints = false

        explanationLabel.stringValue = source.explanation
        explanationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explanationLabel.textColor = .secondaryLabelColor
        explanationLabel.isSelectable = false
        explanationLabel.preferredMaxLayoutWidth = Self.size.width - 48

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        scroll.documentView = textView

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sizeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sizeLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        revertButton.title = mode == .sheet ? "Cancel" : "Revert"
        revertButton.bezelStyle = .rounded
        revertButton.target = self
        revertButton.action = #selector(revertAction(_:))
        if mode == .sheet { revertButton.keyEquivalent = "\u{1b}" }
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveAction(_:))
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command

        for subview in [explanationLabel, scroll, sizeLabel, statusLabel, revertButton, saveButton] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.size.width),
            view.heightAnchor.constraint(equalToConstant: Self.size.height),
            explanationLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            explanationLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            explanationLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: explanationLabel.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            scroll.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -14),
            saveButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            saveButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
            saveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
            revertButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            revertButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            revertButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
            sizeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            sizeLabel.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            // After the size, when the file has one.
            statusLabel.leadingAnchor.constraint(
                equalTo: source.sizeNote == nil ? view.leadingAnchor : sizeLabel.trailingAnchor,
                constant: source.sizeNote == nil ? 24 : 12
            ),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: revertButton.leadingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor)
        ])
    }
}

// MARK: - The space's files

extension SpaceFileEditorPane.Contents {
    /// `url` as the editor shows it: a small UTF-8 regular file, or a
    /// reason it isn't one. `followingLinks`: through a link to where it
    /// points (the brief is read that way at launch too).
    static func read(_ url: URL, maxBytes: Int = SpaceBrief.maxFileBytes, followingLinks: Bool = true) -> Self {
        switch BoardConfigStore.read(followingLinks ? url.resolvingSymlinksInPath() : url, maxBytes: maxBytes) {
        case .missing:
            return .missing
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                return .unreadable("\(url.lastPathComponent) isn’t UTF-8 text: Nirux won’t change it.")
            }
            return .text(text)
        case .tooLarge:
            return .unreadable("\(url.lastPathComponent) is larger than \(maxBytes / 1024) KB: Nirux won’t change it.")
        case .notARegularFile:
            return .unreadable("\(url.lastPathComponent) isn’t a regular file: Nirux won’t change it.")
        case .unreadableBytes:
            return .unreadable("\(url.lastPathComponent) can’t be read: Nirux won’t change it.")
        }
    }
}

extension SpaceFileEditorPane.Source {
    /// The space's brief (see SpaceBrief).
    static func brief(spaceID: String, spaceName: String, stateDirectory: URL = Persistence.stateDirectory) -> Self? {
        guard let url = SpaceBrief.briefURL(spaceID: spaceID, stateDirectory: stateDirectory) else { return nil }
        return Self(
            documentName: "brief",
            explanation: "Goals, priorities and workflow rules every Claude and Codex session started in this space reads. "
                + "New sessions get it once saved. Keep it short: it goes with every request. "
                + "Text inside <!-- --> isn’t sent.",
            read: { .read(url) },
            write: { try writeText($0, to: url) },
            template: { SpaceBrief.template(spaceName: spaceName) },
            sizeNote: { text in
                LearnedRuleSheet.sizeText(before: LearnedRules.characterCount(of: text), after: nil, max: SpaceBrief.maxCharacters, prefix: "")
            }
        )
    }

    /// The space's task templates (see TaskTemplates).
    static func taskTemplates(spaceID: String, spaceName: String, stateDirectory: URL = Persistence.stateDirectory) -> Self? {
        guard let url = TaskTemplates.fileURL(spaceID: spaceID, stateDirectory: stateDirectory) else { return nil }
        return Self(
            documentName: "task templates",
            explanation: "Ways of working New Task… offers, one “## Name” section each: the one picked goes into the "
                + "task’s handover, after its description. Until you save, New Task… offers these defaults.",
            read: { .read(url) },
            write: { try writeText($0, to: url) },
            template: { TaskTemplates.template(spaceName: spaceName) }
        )
    }

    /// A repository's setup script (see SpaceSetupScript).
    static func setupScript(url: URL, anchorName: String) -> Self {
        Self(
            documentName: "setup script",
            explanation: "Runs once, with /bin/sh -e and no input, in each new worktree of \(anchorName) that Nirux "
                + "makes for you, before the agent starts. Keep it idempotent. Saving only comments removes it.",
            // Never through a link: a new worktree doesn't run one either.
            read: { .read(url, maxBytes: SpaceSetupScript.maxFileBytes, followingLinks: false) },
            write: { try SpaceSetupScript.save($0, to: url) },
            template: { SpaceSetupScript.template(anchorName: anchorName) }
        )
    }

    /// Atomic, through a link to where it points (the user may keep the
    /// brief elsewhere).
    private static func writeText(_ text: String, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target, options: .atomic)
    }
}
