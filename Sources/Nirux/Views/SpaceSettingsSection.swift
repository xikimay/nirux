import AppKit

/// A space's settings (docs/design/spaces.md, S8): the space's panes of the
/// Settings window (`SettingsWindow`, docs/design/glass-interface.md, 4.1), in
/// place of the separate rename, brief, board, templates and memory panels.
/// A change applies at once, except in the text editors (Brief, Templates)
/// and the Board form, which have a Save button; text typed and not saved
/// asks before the window closes. The shell builds each pane's content and
/// does the writing (see NiruxShellView+SpaceSettings).
@MainActor
final class SpaceSettingsSection: NSObject {
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
    let boardHost = SpaceSettingsSection.fixedHost(size: BoardSettingsPanel.hostSize)
    let memoryHost = SpaceSettingsSection.fixedHost(size: ProjectMemoryPanel.panelSize)

    /// The Settings window showing it.
    weak var host: SettingsWindow?
    /// The window's panel, for sheets and the keyboard.
    var panel: NSPanel? { host?.panel }
    /// The space's name, in the window's title and sidebar.
    private(set) var title = ""
    /// Looks for changes made on disk (an agent editing the brief) while
    /// the window is open.
    private var diskTimer: Timer?

    /// A pane was picked (or shown first).
    var onTabShown: ((Tab) -> Void)?
    /// The window closed (`windowClosed`), or showed another space.
    var onClose: ((_ windowClosed: Bool) -> Void)?
    /// Asks a question in a sheet on the window; the answer comes back
    /// through the closure. Tests replace it.
    var askInSheet: (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { alert, window, answer in
        alert.beginSheetModal(for: window, completionHandler: answer)
    }

    var isVisible: Bool { host?.isVisible == true }

    private let memoryPlaceholder = SpaceSettingsSection.placeholderLabel()
    private let boardPlaceholder = SpaceSettingsSection.placeholderLabel()

    /// The space's pane shown; nil while one of Nirux's shows.
    var selectedTab: Tab? {
        guard let host, host.space === self, case .space(let tab)? = host.selection else { return nil }
        return tab
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

    /// Shows the window on `tab`. The shell made this section the window's
    /// (`SettingsWindow.setSpace`).
    func show(tab: Tab, title: String) {
        setTitle(title)
        host?.show(.space(tab))
    }

    func select(_ tab: Tab) {
        host?.select(.space(tab))
    }

    /// The space's name, in the window's title and sidebar.
    func setTitle(_ title: String) {
        self.title = title
        host?.spaceChanged()
    }

    /// Closes the window without asking: unsaved text is lost.
    func close() {
        host?.close()
    }

    /// The pane's view.
    func view(for tab: Tab) -> NSView {
        switch tab {
        case .general: return general.view
        case .defaults: return defaults.view
        case .lead: return lead.view
        case .brief: return brief.view
        case .memory: return memoryHost
        case .board: return boardHost
        case .templates: return templates.view
        }
    }

    var allViews: [NSView] { Tab.allCases.map(view(for:)) }

    /// The window shows one of its panes.
    func tabShown(_ tab: Tab) {
        switch tab {
        case .brief: brief.checkDisk()
        case .templates: templates.checkDisk()
        default: break
        }
        onTabShown?(tab)
    }

    /// The window fits the pane's content again (a list grew, a banner
    /// showed).
    func fitToContent() {
        host?.fitToContent()
    }

    /// The window came up with this section.
    func windowShown() {
        startWatchingDisk()
    }

    func windowBecameKey() {
        switch selectedTab {
        case .brief: brief.checkDisk()
        case .templates: templates.checkDisk()
        default: break
        }
    }

    /// The window closed, or shows another space now.
    func detach(windowClosed: Bool) {
        diskTimer?.invalidate()
        diskTimer = nil
        onClose?(windowClosed)
    }

    private func startWatchingDisk() {
        guard diskTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
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

    // MARK: - Closing

    /// Unsaved changes ask first, in a sheet on `window`: Save, Don't Save,
    /// or Cancel. True: nothing to ask, the window may close.
    func shouldClose(_ window: NSWindow) -> Bool {
        // A name or a value still being typed counts.
        window.makeFirstResponder(nil)
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
        askInSheet(alert, window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                // On its pane, which a question about it needs; one that
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
}
