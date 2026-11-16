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
    /// What the window shows when it opens with no pane asked for (⌘,): the
    /// pane last shown, if it was a space's, only for that space.
    private(set) var lastSelection: Selection?
    private var lastSpaceID: String?
    /// Nirux's pane last shown, for a space's that can't show again.
    private var lastAppSelection: Selection?
    /// The widest pane's width, measured once per set of panes.
    private var paneWidth: CGFloat?
    let sidebar = SettingsSidebar()
    private let paneHost = NSView()
    private let divider = NSView()
    private weak var shownPane: NSView?

    var isVisible: Bool { panel?.isVisible == true }

    /// The pane shown now.
    var selectedView: NSView? { shownPane }

    /// Shows the window on `selection`, else on the pane last shown, else
    /// on Nirux's first; builds it the first time. A pane asked for by name
    /// (Space Memory…, Board settings) may take the keyboard; otherwise the
    /// sidebar has it, so ↑ and ↓ walk the panes.
    func show(_ selection: Selection? = nil) {
        if panel == nil { build() }
        guard let panel else { return }
        select(selection ?? remembered ?? defaultSelection)
        if !panel.isVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
        // After the window is up, which hands the sidebar the keyboard: the
        // pane asked for takes it once its content comes.
        if selection != nil { panel.makeFirstResponder(nil) }
        space?.windowShown()
    }

    /// The pane last shown, if the window can show it: a space's only for
    /// that same space.
    private var remembered: Selection? {
        guard let last = lastSelection else { return nil }
        if case .space = last, lastSpaceID != space?.spaceID { return lastAppSelection.flatMap(available) }
        return available(last)
    }

    /// Shows `selection`'s pane, if the window has it.
    func select(_ selection: Selection) {
        guard let pane = view(for: selection) else { return }
        let changed = selection != self.selection
        self.selection = selection
        lastSelection = selection
        if case .space = selection { lastSpaceID = space?.spaceID } else { lastAppSelection = selection }
        if changed || shownPane !== pane { place(pane) }
        sidebar.select(selection)
        updateTitle()
        fitToContent()
        if case .space(let tab) = selection { space?.tabShown(tab) }
    }

    /// The space's section, in place of the one shown (or none). The one it
    /// replaces is told (`SpaceSettingsSection.detach`). A space's pane
    /// shown goes with it: the caller shows the pane it wants
    /// (`SpaceSettingsSection.show`), once, for the new space.
    func setSpace(_ section: SpaceSettingsSection?) {
        guard section !== space else { return }
        // Told while it still has the window: a sheet of its own ends there.
        space?.detach(windowClosed: false)
        space?.host = nil
        space = section
        section?.host = self
        paneWidth = nil
        guard panel != nil else { return }
        if case .space? = selection {
            shownPane?.removeFromSuperview()
            shownPane = nil
            selection = nil
        }
        if section != nil, sidebar.hasSpace {
            sidebar.updateSpace(spaceHeader)
        } else {
            sidebar.reload(appPanes: appPanes, space: spaceHeader)
        }
        sidebar.select(selection)
        if section == nil, selection == nil { select(lastAppSelection.flatMap(available) ?? defaultSelection) }
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
        var size = contentSize(for: pane)
        // Never wider than the screen: a pane wider than its area then keeps
        // its left side in view (see `place`).
        if let screen = (panel.screen ?? NSScreen.main)?.visibleFrame {
            size.width = min(size.width, screen.width)
        }
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
        paneWidth = nil
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
        sidebar.spaces = { [weak self] in self?.spaces() ?? [] }
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
        // ↑ and ↓ walk the panes at once; Tab goes on into the pane shown.
        panel.initialFirstResponder = sidebar.table
        panel.autorecalculatesKeyViewLoop = true
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
        let width = paneWidth ?? {
            let panes = appPanes.map(\.view) + (space?.allViews ?? [])
            let measured = ceil(panes.map { $0.fittingSize.width }.max() ?? pane.fittingSize.width)
            paneWidth = measured
            return measured
        }()
        let height = max(pane.fittingSize.height, sidebar.contentHeight)
        return NSSize(width: Self.sidebarWidth + 1 + width, height: ceil(height))
    }

    /// The pane at the top of its area, centred across it; wider than its
    /// area (a narrow screen), its left side stays in view.
    private func place(_ pane: NSView) {
        shownPane?.removeFromSuperview()
        pane.translatesAutoresizingMaskIntoConstraints = false
        paneHost.addSubview(pane)
        let centred = pane.centerXAnchor.constraint(equalTo: paneHost.centerXAnchor)
        centred.priority = .defaultHigh
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: paneHost.topAnchor),
            pane.leadingAnchor.constraint(greaterThanOrEqualTo: paneHost.leadingAnchor),
            centred
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

extension NSWindow {
    /// Whether a pane in `host` may take the keyboard: nothing has it, or
    /// something of the pane's own (the Settings sidebar keeps it).
    func keyboardIsFree(for host: NSView) -> Bool {
        guard let responder = firstResponder, responder !== self else { return true }
        guard let view = responder as? NSView else { return false }
        return view.isDescendant(of: host)
    }
}
