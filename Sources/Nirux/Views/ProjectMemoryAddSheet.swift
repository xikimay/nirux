import AppKit

/// What "+ Add" asks for: a title, where the item goes (When relevant by
/// default: a Claude Code memory; or Always: a rule of the project brief),
/// a memory's type and description, and the text. Under the title, the file
/// a memory gets.
@MainActor
final class ProjectMemoryAddSheet: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
    /// What the sheet hands back.
    struct Item: Equatable {
        let title: String
        let scope: ProjectMemory.Scope
        let type: ProjectMemory.Kind
        let description: String
        let text: String
    }

    static let size = NSSize(width: 520, height: 400)
    static let addTitle = "Add"

    private(set) var window: NSWindow?
    let titleField = NSTextField()
    let fileLabel = NSTextField(labelWithString: "")
    let scopePopup = NSPopUpButton()
    let typePopup = NSPopUpButton()
    let descriptionField = NSTextField()
    let textView = NSTextView()
    private(set) var addButton: NSButton?
    private var onAdd: (Item) -> Void = { _ in }
    /// The memory folder's names, read once: the file a memory would get.
    private var takenNames: Set<String> = []
    private var scopes: [ProjectMemory.Scope] = [.whenRelevant, .always]

    /// Shows the sheet on `parent`; `onAdd` gets the item once the user adds
    /// it. Without `allowsMemory` (auto-memory off), only Always is offered.
    func begin(
        on parent: NSWindow, memoryFolder: URL, allowsMemory: Bool, filledWith item: Item? = nil,
        onAdd: @escaping (Item) -> Void
    ) {
        self.onAdd = onAdd
        takenNames = ProjectMemory.fileNames(in: memoryFolder)
        scopes = allowsMemory ? [.whenRelevant, .always] : [.always]
        let window = makeWindow()
        self.window = window
        if let item {
            titleField.stringValue = item.title
            scopePopup.selectItem(at: scopes.firstIndex(of: item.scope) ?? 0)
            typePopup.selectItem(at: ProjectMemory.Kind.allCases.firstIndex(of: item.type) ?? 0)
            descriptionField.stringValue = item.description
            textView.string = item.text
        }
        update()
        parent.beginSheet(window)
        window.makeFirstResponder(titleField)
    }

    /// What the form holds now.
    var item: Item {
        Item(
            title: titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            scope: scopes[safe: scopePopup.indexOfSelectedItem] ?? scopes[0],
            type: ProjectMemory.Kind.allCases[safe: typePopup.indexOfSelectedItem] ?? .project,
            description: descriptionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            text: textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    @objc func add() {
        let item = item
        guard isComplete(item) else { return NSSound.beep() }
        close()
        onAdd(item)
    }

    @objc func cancel() {
        close()
    }

    private func close() {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
        self.window = nil
    }

    /// A title and a text: Return in the title field never adds an empty
    /// item.
    private func isComplete(_ item: Item) -> Bool {
        !item.title.isEmpty && !item.text.isEmpty
    }

    /// The file a memory gets, the fields a rule doesn't use, the button.
    @objc func update() {
        let item = item
        let isMemory = item.scope == .whenRelevant
        typePopup.isEnabled = isMemory
        descriptionField.isEnabled = isMemory
        if isMemory {
            let name = try? ProjectMemory.newFileName(for: item.title, taken: takenNames)
            fileLabel.stringValue = name.map { "Claude Code memory: \($0)" } ?? "Its title names its file"
        } else {
            fileLabel.stringValue = "A rule of the project brief, in every session Nirux starts"
        }
        addButton?.isEnabled = isComplete(item)
    }

    func controlTextDidChange(_ obj: Notification) {
        update()
    }

    func textDidChange(_ notification: Notification) {
        update()
    }

    // MARK: - Construction

    private func makeWindow() -> NSWindow {
        let size = Self.size
        // A panel: ⌘Z reaches its fields (see PanelTextUndo).
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = Theme.appearance
        window.backgroundColor = Theme.Color.base
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let inset = Theme.Space.xl
        let labelWidth: CGFloat = 92
        let fieldX = inset + labelWidth
        let fieldWidth = size.width - fieldX - inset
        var y = size.height - inset - 22

        func label(_ text: String, at y: CGFloat) {
            let label = NSTextField(labelWithString: text)
            label.font = Theme.Font.body
            label.textColor = Theme.Color.textSecondary
            label.alignment = .right
            label.frame = NSRect(x: inset, y: y + 3, width: labelWidth - Theme.Space.sm, height: 16)
            content.addSubview(label)
        }

        label("Title", at: y)
        titleField.frame = NSRect(x: fieldX, y: y, width: fieldWidth, height: 22)
        titleField.placeholderString = "Release train"
        titleField.delegate = self
        content.addSubview(titleField)
        y -= 20
        fileLabel.font = Theme.Font.caption
        fileLabel.textColor = Theme.Color.textTertiary
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.frame = NSRect(x: fieldX, y: y, width: fieldWidth, height: 15)
        content.addSubview(fileLabel)

        y -= 34
        label("Applies", at: y)
        scopePopup.addItems(withTitles: scopes.map(\.title))
        scopePopup.target = self
        scopePopup.action = #selector(update)
        scopePopup.frame = NSRect(x: fieldX - 3, y: y - 2, width: 180, height: 26)
        content.addSubview(scopePopup)

        y -= 34
        label("Type", at: y)
        typePopup.addItems(withTitles: ProjectMemory.Kind.allCases.map(\.title))
        typePopup.selectItem(at: ProjectMemory.Kind.allCases.firstIndex(of: .project) ?? 0)
        typePopup.frame = NSRect(x: fieldX - 3, y: y - 2, width: 180, height: 26)
        content.addSubview(typePopup)

        y -= 34
        label("Description", at: y)
        descriptionField.frame = NSRect(x: fieldX, y: y, width: fieldWidth, height: 22)
        descriptionField.placeholderString = "One line: what it is about"
        content.addSubview(descriptionField)

        let buttonsHeight: CGFloat = 52
        y -= Theme.Space.md
        let scroll = NSScrollView(frame: NSRect(x: fieldX, y: buttonsHeight, width: fieldWidth, height: y - buttonsHeight))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = self
        // Agents read it as written: no curly quotes, no `—` for `--`.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = Theme.Font.body
        textView.textColor = Theme.Color.textPrimary
        textView.backgroundColor = Theme.Color.surface
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        content.addSubview(scroll)
        label("Text", at: y - 22)

        let add = NSButton(title: Self.addTitle, target: self, action: #selector(add))
        add.keyEquivalent = "\r"
        add.bezelStyle = .rounded
        add.sizeToFit()
        add.frame.size.width = max(add.frame.width, 88)
        add.frame.origin = NSPoint(x: size.width - inset - add.frame.width, y: 14)
        content.addSubview(add)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded
        cancel.sizeToFit()
        cancel.frame.size.width = max(cancel.frame.width, 88)
        cancel.frame.origin = NSPoint(x: add.frame.minX - Theme.Space.sm - cancel.frame.width, y: 14)
        content.addSubview(cancel)
        addButton = add

        window.contentView = content
        return window
    }
}
