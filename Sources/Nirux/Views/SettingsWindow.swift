import AppKit

/// Nirux's one Settings window (docs/design/glass-interface.md, 4.1): a
/// sidebar with Nirux's panes, then one space's (its colour square and name,
/// a popup to pick another space), and the pane picked on the right, as it
/// was in the toolbar tabs it replaces. Every control applies at once, except
/// in the space's text editors and Board form, which have Save: the space's
/// section asks about them before the window closes or shows another space.
///
/// Nirux's panes come from the app (`makeAppPanes`), the space's from the
/// shell (`SpaceSettingsSection`), which writes what they change.
///
/// It is a panel that doesn't float or hide: it doesn't keep Nirux running
/// once the main window closes, and keys typed in it never reach a terminal
/// (isOverlayActive).
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    /// A pane of Nirux's own: General, Agents, Notifications.
    struct AppPane {
        let id: String
        let title: String
        let symbol: String
        let view: NSView
    }

    /// The pane on the right.
    enum Selection: Equatable {
        case app(String)
        case space(SpaceSettingsSection.Tab)
    }

    /// A space the sidebar's popup offers.
    struct Space: Equatable {
        let id: String
        let name: String
        let colorHex: String
    }

    static let sidebarWidth: CGFloat = 200
    static let firstAppPane = "general"

    /// Nirux's panes, built each time the window opens (the app).
    var makeAppPanes: (() -> [AppPane])?
    /// The section of the space to show when the window opens without one
    /// (the shell: the active space's).
    var makeSpaceSection: (() -> SpaceSettingsSection?)?
    /// The spaces the popup offers.
    var spaces: () -> [Space] = { [] }
    /// A space picked in the popup (the shell shows it, or says why not).
    var onPickSpace: ((String) -> Void)?
    /// The window closed: the app drops its controls.
    var onAppClose: (() -> Void)?

    private(set) var panel: SettingsPanel?
    private(set) var appPanes: [AppPane] = []
    private(set) var space: SpaceSettingsSection?
    private(set) var selection: Selection?
    /// What the window shows when it opens with no pane asked for (⌘,).
    private(set) var lastSelection: Selection?
    let sidebar = SettingsSidebar()
    private let paneHost = NSView()
    private let divider = NSView()
    private weak var shownPane: NSView?

    var isVisible: Bool { panel?.isVisible == true }

    /// The pane shown now.
    var selectedView: NSView? { shownPane }

    /// Shows the window on `selection`, else on the pane last shown, else
    /// on Nirux's first; builds it the first time.
    func show(_ selection: Selection? = nil) {
        if panel == nil { build() }
        guard let panel else { return }
        select(selection ?? lastSelection.flatMap(available) ?? defaultSelection)
        if !panel.isVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
        space?.windowShown()
    }

    /// Shows `selection`'s pane, if the window has it.
    func select(_ selection: Selection) {
        guard let pane = view(for: selection) else { return }
        let changed = selection != self.selection
        self.selection = selection
        lastSelection = selection
        if changed || shownPane !== pane { place(pane) }
        sidebar.select(selection)
        updateTitle()
        fitToContent()
        if case .space(let tab) = selection { space?.tabShown(tab) }
    }

    /// The space's section, in place of the one shown (or none). The one it
    /// replaces is told (`SpaceSettingsSection.detach`); a space pane shown
    /// shows the same pane of the new space.
    func setSpace(_ section: SpaceSettingsSection?) {
        guard section !== space else { return }
        // Told while it still has the window: a sheet of its own ends there.
        space?.detach(windowClosed: false)
        space?.host = nil
        space = section
        section?.host = self
        guard panel != nil else { return }
        sidebar.reload(appPanes: appPanes, space: spaceHeader)
        if case .space(let tab)? = selection, section != nil {
            select(.space(tab))
        } else if case .space? = selection {
            select(defaultSelection)
        } else {
            sidebar.select(selection)
        }
        space?.windowShown()
    }

    /// The space's name, colour or the spaces changed: the sidebar and the
    /// title say them again.
    func spaceChanged() {
        guard panel != nil else { return }
        sidebar.updateSpace(spaceHeader)
        updateTitle()
    }

    /// Closes without asking: unsaved text is lost.
    func close() {
        panel?.close()
    }

    /// The window fits the pane shown again (a list grew, a banner showed).
    func fitToContent() {
        guard let panel, let pane = shownPane else { return }
        let size = contentSize(for: pane)
        var frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - frame.height)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true, animate: panel.isVisible && NSApp.isActive)
    }

    // MARK: - Building

    private var defaultSelection: Selection {
        appPanes.first.map { .app($0.id) } ?? .space(.general)
    }

    /// `selection`, if the window has its pane.
    private func available(_ selection: Selection) -> Selection? {
        view(for: selection) == nil ? nil : selection
    }

    private func view(for selection: Selection) -> NSView? {
        switch selection {
        case .app(let id): return appPanes.first { $0.id == id }?.view
        case .space(let tab): return space?.view(for: tab)
        }
    }

    private var spaceHeader: SettingsSidebar.SpaceHeader? {
        guard let space else { return nil }
        let all = spaces()
        let current = all.first { $0.id == space.spaceID } ?? Space(id: space.spaceID, name: space.title, colorHex: "")
        return SettingsSidebar.SpaceHeader(current: current, all: all.isEmpty ? [current] : all)
    }

    private func build() {
        appPanes = makeAppPanes?() ?? []
        if space == nil, let section = makeSpaceSection?() {
            space = section
            section.host = self
        }
        let panel = SettingsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior.insert(.fullScreenAuxiliary)
        panel.appearance = Theme.appearance
        panel.backgroundColor = Theme.Color.base
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.Color.base.cgColor
        sidebar.onSelect = { [weak self] selection in self?.select(selection) }
        sidebar.onPickSpace = { [weak self] id in
            guard let self else { return }
            self.onPickSpace?(id)
            // Refused (text typed and not saved): the popup says the space
            // shown again.
            self.sidebar.updateSpace(self.spaceHeader)
        }
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.Color.line.cgColor
        for view in [sidebar.view, divider, paneHost] { content.addSubview(view) }
        panel.contentView = content
        // ↑ and ↓ walk the panes at once.
        panel.initialFirstResponder = sidebar.table
        // The sidebar and the line keep their width, the pane's area takes
        // the rest; all follow the window's height as it fits each pane.
        let bounds = content.bounds
        sidebar.view.frame = NSRect(x: 0, y: 0, width: Self.sidebarWidth, height: bounds.height)
        sidebar.view.autoresizingMask = [.height]
        divider.frame = NSRect(x: Self.sidebarWidth, y: 0, width: 1, height: bounds.height)
        divider.autoresizingMask = [.height]
        paneHost.frame = NSRect(x: Self.sidebarWidth + 1, y: 0, width: bounds.width - Self.sidebarWidth - 1, height: bounds.height)
        paneHost.autoresizingMask = [.width, .height]
        self.panel = panel
        sidebar.reload(appPanes: appPanes, space: spaceHeader)
    }

    /// The pane's area: as wide as the widest pane, so the window keeps its
    /// width; as tall as the pane, or the sidebar's list.
    private func contentSize(for pane: NSView) -> NSSize {
        let panes = appPanes.map(\.view) + (space?.allViews ?? [])
        let width = panes.map { $0.fittingSize.width }.max() ?? pane.fittingSize.width
        let height = max(pane.fittingSize.height, sidebar.contentHeight)
        return NSSize(width: Self.sidebarWidth + 1 + ceil(width), height: ceil(height))
    }

    /// The pane at the top of its area, centred across it.
    private func place(_ pane: NSView) {
        shownPane?.removeFromSuperview()
        pane.translatesAutoresizingMaskIntoConstraints = false
        paneHost.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: paneHost.topAnchor),
            pane.centerXAnchor.constraint(equalTo: paneHost.centerXAnchor)
        ])
        shownPane = pane
    }

    private func updateTitle() {
        let title: String
        switch selection {
        case .app(let id)?: title = appPanes.first { $0.id == id }?.title ?? "Settings"
        case .space(let tab)?: title = "\(space?.title ?? "Space") — \(tab.title)"
        case nil: title = "Settings"
        }
        panel?.title = title
    }

    // MARK: - NSWindowDelegate

    /// Text typed in the space's panes and not saved asks first.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let space else { return true }
        return space.shouldClose(sender)
    }

    func windowWillClose(_ notification: Notification) {
        // Told while it still has the window: a sheet of its own ends there.
        space?.detach(windowClosed: true)
        space?.host = nil
        space = nil
        shownPane?.removeFromSuperview()
        shownPane = nil
        selection = nil
        appPanes = []
        panel?.delegate = nil
        panel = nil
        onAppClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        space?.windowBecameKey()
    }
}

/// Return in a multi-line text view (the Board's required checks, the
/// brief) types a line: a default button (the Board's Save) mustn't take
/// it first when AppKit offers Return as a key equivalent.
final class SettingsPanel: NSPanel {
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
