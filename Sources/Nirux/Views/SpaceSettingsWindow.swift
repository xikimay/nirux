import AppKit

/// Space Settings (docs/design/spaces.md, S8): one window per space with a toolbar
/// tab per topic, in place of the separate rename, brief, board, templates
/// and memory panels. Like Nirux Settings, a change applies at once, except
/// in the text editors (Brief, Templates) and the Board form, which have a
/// Save button. The shell builds each tab's content and does the writing
/// (see NiruxShellView+SpaceSettings).
///
/// It is a panel that doesn't float or hide, like Settings: it doesn't keep
/// Nirux running once the main window closes, and keys typed in it never
/// reach a terminal (isOverlayActive).
@MainActor
final class SpaceSettingsWindow: NSObject, NSWindowDelegate {
    enum Tab: String, CaseIterable {
        case general, defaults, lead, brief, memory, board, templates

        var title: String {
            switch self {
            case .general: return "General"
            case .defaults: return "Defaults"
            case .lead: return "Lead"
            case .brief: return "Brief"
            case .memory: return "Memory"
            case .board: return "Board"
            case .templates: return "Templates"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .defaults: return "slider.horizontal.3"
            case .lead: return "sparkle"
            case .brief: return "text.alignleft"
            case .memory: return "brain"
            case .board: return "rectangle.split.3x1"
            case .templates: return "doc.on.doc"
            }
        }
    }

    let spaceID: String
    let general: SpaceSettingsGeneralPane
    let defaults: SpaceSettingsDefaultsPane
    let lead: SpaceSettingsLeadPane
    let brief: SpaceFileEditorPane
    let templates: SpaceFileEditorPane
    /// Filled by the shell when the tab first shows: the Board form reads
    /// git, the memory list reads files.
    let boardHost = SpaceSettingsWindow.fixedHost(size: BoardSettingsPanel.hostSize)
    let memoryHost = SpaceSettingsWindow.fixedHost(size: ProjectMemoryPanel.panelSize)

    private(set) var panel: SpaceSettingsPanel?
    private let tabs = SettingsTabViewController()
    /// Looks for changes made on disk (an agent editing the brief) while
    /// the window is open.
    private var diskTimer: Timer?

    /// A tab was picked (or shown first).
    var onTabShown: ((Tab) -> Void)?
    /// The window closed.
    var onClose: (() -> Void)?
    /// Asks a question in a sheet on the window; the answer comes back
    /// through the closure. Tests replace it.
    var askInSheet: (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { alert, window, answer in
        alert.beginSheetModal(for: window, completionHandler: answer)
    }

    var isVisible: Bool { panel?.isVisible == true }

    private let memoryPlaceholder = SpaceSettingsWindow.placeholderLabel()
    private let boardPlaceholder = SpaceSettingsWindow.placeholderLabel()

    var selectedTab: Tab? {
        Tab.allCases[safe: tabs.selectedTabViewItemIndex]
    }

    /// The Board tab's form and the setup script sheet, while shown (the
    /// shell makes them).
    weak var boardForm: BoardSettingsPanel?
    /// The repository the Board tab shows, by section id (docs/design/spaces.md,
    /// S12); nil for the default one.
    var boardRepository: String?
    /// The Board tab was asked to read again while it was reading: it reads
    /// once that read lands, with this status by its buttons.
    var pendingBoardReload: String??
    weak var setupScriptEditor: SpaceFileEditorPane?
    weak var memoryPanel: ProjectMemoryPanel?

    /// Something typed and not saved, which closing would lose.
    struct UnsavedPart {
        let name: String
        let tab: Tab
        let save: @MainActor () -> Bool
    }

    var unsavedParts: [UnsavedPart] {
        var parts: [UnsavedPart] = []
        for (pane, tab) in [(brief, Tab.brief), (templates, .templates)] where pane.isDirty {
            parts.append(UnsavedPart(name: pane.documentName, tab: tab, save: { pane.save() }))
        }
        if let editor = setupScriptEditor, editor.isDirty {
            parts.append(UnsavedPart(name: editor.documentName, tab: .general, save: { editor.save() }))
        }
        if let form = boardForm, form.isDirty {
            parts.append(UnsavedPart(name: "board settings", tab: .board, save: { form.save() }))
        }
        if let memory = memoryPanel, memory.shows(in: memoryHost) {
            if memory.hasUnsavedEdit {
                // The write takes a moment: the window stays until it ends
                // (an agent may have changed the file, which it then says).
                parts.append(UnsavedPart(name: "memory item", tab: .memory, save: {
                    memory.saveEditing()
                    return memory.editing == nil
                }))
            }
            if memory.addSheet != nil {
                parts.append(UnsavedPart(name: "new memory item", tab: .memory, save: { false }))
            }
        }
        if defaults.hasUnsavedRows {
            parts.append(UnsavedPart(name: "environment variables", tab: .defaults, save: { [defaults] in defaults.saveRows() }))
        }
        return parts
    }

    var hasUnsavedChanges: Bool { !unsavedParts.isEmpty }

    init(spaceID: String, general: SpaceSettingsGeneralPane, defaults: SpaceSettingsDefaultsPane,
         lead: SpaceSettingsLeadPane, brief: SpaceFileEditorPane, templates: SpaceFileEditorPane) {
        self.spaceID = spaceID
        self.general = general
        self.defaults = defaults
        self.lead = lead
        self.brief = brief
        self.templates = templates
        super.init()
    }

    /// Shows the window on `tab`, building it the first time.
    func show(tab: Tab, title: String) {
        if panel == nil { build() }
        guard let panel else { return }
        setTitle(title)
        select(tab)
        if !panel.isVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
        startWatchingDisk()
    }

    func select(_ tab: Tab) {
        guard let index = Tab.allCases.firstIndex(of: tab) else { return }
        if tabs.selectedTabViewItemIndex != index {
            tabs.selectedTabViewItemIndex = index
        } else {
            tabShown(tab)
        }
    }

    /// The window's title follows its content view controller's.
    func setTitle(_ title: String) {
        tabs.title = title
        panel?.title = title
    }

    /// Closes without asking: unsaved text is lost.
    func close() {
        panel?.close()
    }

    private func build() {
        tabs.tabStyle = .toolbar
        // The window keeps the space's name as its title.
        tabs.canPropagateSelectedChildViewControllerTitle = false
        let views: [Tab: NSView] = [
            .general: general.view, .defaults: defaults.view, .lead: lead.view, .brief: brief.view,
            .memory: memoryHost, .board: boardHost, .templates: templates.view
        ]
        for tab in Tab.allCases {
            let controller = NSViewController()
            controller.view = views[tab] ?? NSView()
            controller.title = tab.title
            let item = NSTabViewItem(viewController: controller)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        let panel = SpaceSettingsPanel(contentViewController: tabs)
        // After the init, which picks the first tab: `show` says which tab
        // shows, once.
        tabs.onSelect = { [weak self] index in
            guard let self, let tab = Tab.allCases[safe: index] else { return }
            self.tabShown(tab)
        }
        panel.styleMask = [.titled, .closable]
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior.insert(.fullScreenAuxiliary)
        panel.toolbarStyle = .preference
        panel.appearance = Theme.appearance
        panel.backgroundColor = Theme.Color.base
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        self.panel = panel
        tabs.fitWindowToSelectedPane(animated: false)
    }

    private func tabShown(_ tab: Tab) {
        switch tab {
        case .brief: brief.checkDisk()
        case .templates: templates.checkDisk()
        default: break
        }
        onTabShown?(tab)
    }

    /// The window fits the tab's content again (a list grew, a banner
    /// showed).
    func fitToContent() {
        tabs.fitWindowToSelectedPane(animated: true)
    }

    private func startWatchingDisk() {
        guard diskTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel?.isVisible == true else { return }
                switch self.selectedTab {
                case .brief: self.brief.checkDisk()
                case .templates: self.templates.checkDisk()
                default: break
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        diskTimer = timer
    }

    // MARK: - Placeholders

    /// Said in the Memory tab instead of the list (no folder to read).
    func showMemoryPlaceholder(_ text: String) {
        showPlaceholder(memoryPlaceholder, text, in: memoryHost)
    }

    func hideMemoryPlaceholder() {
        memoryPlaceholder.removeFromSuperview()
    }

    /// Said in the Board tab while its form loads, or why it can't.
    func showBoardPlaceholder(_ text: String) {
        showPlaceholder(boardPlaceholder, text, in: boardHost)
    }

    func hideBoardPlaceholder() {
        boardPlaceholder.removeFromSuperview()
    }

    private func showPlaceholder(_ label: NSTextField, _ text: String, in host: NSView) {
        label.stringValue = text
        guard label.superview !== host else { return }
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -80)
        ])
    }

    private static func placeholderLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    /// A fixed-size view a tab's content fills (the window fits each tab to
    /// its content).
    private static func fixedHost(size: NSSize) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: size.width),
            host.heightAnchor.constraint(equalToConstant: size.height)
        ])
        return host
    }

    // MARK: - NSWindowDelegate

    /// Unsaved changes ask first: Save, Don't Save, or Cancel.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // A name or a value still being typed counts.
        sender.makeFirstResponder(nil)
        let parts = unsavedParts
        guard !parts.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = parts.count == 1 ? "Save the changes to the \(parts[0].name)?" : "Save your changes?"
        alert.informativeText = parts.count == 1
            ? "Your changes are lost if you don’t save them."
            : "The \(parts.map(\.name).joined(separator: ", ")) have changes that are lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save").hasDestructiveAction = true
        askInSheet(alert, sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                // On its tab, which a question about it needs; one that
                // fails (a problem, a file changed on disk) keeps the window
                // open there, saying why.
                for part in parts {
                    self.select(part.tab)
                    if !part.save() { return }
                }
                self.close()
            case .alertThirdButtonReturn:
                self.close()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        diskTimer?.invalidate()
        diskTimer = nil
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        switch selectedTab {
        case .brief: brief.checkDisk()
        case .templates: templates.checkDisk()
        default: break
        }
    }
}

/// Return in a multi-line text view (the Board's required checks, the
/// brief) types a line: a default button (the Board's Save) mustn't take
/// it first when AppKit offers Return as a key equivalent.
final class SpaceSettingsPanel: NSPanel {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let multiline = (firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? nil : $0 }
        if MultilineReturn.leavesToTextView(event, firstResponder: firstResponder, multilineView: multiline) { return false }
        return super.performKeyEquivalent(with: event)
    }
}

/// Return in a multi-line text view types a line, ahead of a default button.
enum MultilineReturn {
    /// Return or Enter, without modifiers, while `multilineView` has the focus.
    @MainActor
    static func leavesToTextView(_ event: NSEvent, firstResponder: NSResponder?, multilineView: NSTextView?) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard let multilineView, firstResponder === multilineView, modifiers.isEmpty else { return false }
        return event.charactersIgnoringModifiers == "\r" || event.charactersIgnoringModifiers == "\u{3}"
    }
}
