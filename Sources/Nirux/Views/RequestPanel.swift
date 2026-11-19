import AppKit

/// Hosts the glass interface's inbox or the rail's callout over the main
/// window (docs/design/glass-interface.md, step 3.3): a borderless child
/// panel that draws nothing of its own (the view brings its glass), takes
/// the keyboard while it shows and closes on a click anywhere else. Keys
/// typed while it has the keyboard never reach a terminal: the key
/// interceptor routes only the main window's (`setupKeyInterceptor`).
@MainActor
final class RequestPanel {
    private final class Panel: NSPanel {
        var onPerformClose: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        /// ⌘W while it has the keyboard closes it, not the window behind.
        override func performClose(_ sender: Any?) { onPerformClose?() }
    }

    /// How it closed: the host gives the keyboard back to the terminal
    /// (Escape, the last answer), or a click elsewhere took it, or the host
    /// moves it itself (to a task).
    enum Closing {
        case byHost, byClickElsewhere, toTask
    }

    let panel: NSPanel
    /// Called once each time it closes: how, and whether it had the
    /// keyboard then (only then does the host give it back).
    var onClose: ((Closing, _ hadKeyboard: Bool) -> Void)?
    /// A click there leaves it open: its host acts on it (the bar's badge,
    /// which goes to the inbox's chosen request; the callout's own icon,
    /// which closes it).
    var keepsOpen: ((NSEvent) -> Bool)?
    /// Escape or ⌘. typed while it has the keyboard, on its release: the
    /// host closes it (the terminal then takes the keyboard back, which a
    /// held key's repeats must not reach). Whatever has the keyboard in it,
    /// a card's button included.
    var onEscape: (() -> Void)?
    /// A window of the host's that belongs with it (a reply popover one of
    /// its cards opened): taking the keyboard there doesn't close it.
    var ownsWindow: ((NSWindow) -> Bool)?
    /// Whether the mouse's button is down, whether a window has the
    /// keyboard, and which one has it; tests say (CI's app is active,
    /// a local run's isn't).
    var pressedMouseButtons: () -> Int = { NSEvent.pressedMouseButtons }
    var hasKeyboard: (NSWindow) -> Bool = { $0.isKeyWindow }
    var keyWindow: () -> NSWindow? = { NSApp.keyWindow }
    /// Another window whose clicks close it, besides the one it sits over
    /// (the toolbar's own window in full screen). Clicks in any other
    /// window (a reply popover a card opened, Settings) leave it open.
    var closesOnClicks: ((NSWindow) -> Bool)?
    /// A shortcut it lets through while it has the keyboard (⌘J, which
    /// acts on the open inbox; any key while a reply popover of a card
    /// types, whose keys come stamped with this window); any other ⌘
    /// shortcut closes it, then goes to the menu, so that what the shortcut
    /// moves (a workspace, a column, the find bar) gets the keyboard.
    var keepsShortcut: ((NSEvent) -> Bool)?
    /// The control it comes out of and goes back into, in screen
    /// coordinates (the bar's badge, the rail's icon); nil: it fades.
    var source: () -> NSRect? = { nil }
    /// Whether it may move (`PanelGrowth`); else it shows and goes at once.
    var animates: () -> Bool = { false }
    /// Tells a pending order out whether it still applies: a show since
    /// takes it back.
    private var closeGeneration = 0
    /// When a click it let through (`keepsOpen`) last came: the window
    /// behind takes the keyboard on that mouse-down, which must not close
    /// it before the click acts (the badge, the callout's own icon).
    private var keptClickAt: TimeInterval = -.infinity
    private var clickMonitor: Any?
    private var shortcutMonitor: Any?
    private var escapeMonitor: Any?
    /// Escape or ⌘. is down: its release closes.
    private var escapeIsDown = false
    private var resignObserver: NSObjectProtocol?
    private var keyObservers: [NSObjectProtocol] = []
    /// What takes the keyboard in it, again after a reply popover closed.
    private weak var responder: NSView?
    private(set) var isOpen = false

    init(content: NSView) {
        panel = Panel(contentRect: content.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // It closes instead (`close` on the app's deactivation): hidden
        // behind AppKit's back, it would come back stale.
        panel.hidesOnDeactivate = false
        panel.appearance = Theme.appearance
        panel.contentView = content
        (panel as? Panel)?.onPerformClose = { [weak self] in self?.close() }
    }

    /// The panel's shadow follows its rounded glass (the content's alpha):
    /// computed again once the content has drawn, after a show or a new
    /// level.
    func invalidateShadowWhenDrawn() {
        DispatchQueue.main.async { [weak panel] in panel?.invalidateShadow() }
    }

    /// Shows it at `frame` (screen coordinates) over `window`, `responder`
    /// taking the keyboard.
    func show(frame: NSRect, over window: NSWindow, responder: NSView) {
        closeGeneration += 1
        panel.ignoresMouseEvents = false
        panel.contentView?.layer?.removeAnimation(forKey: PanelGrowth.key)
        panel.setFrame(frame, display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(responder)
        if animates() { PanelGrowth.grow(panel, from: source()) } else { invalidateShadowWhenDrawn() }
        self.responder = responder
        isOpen = true
        if keyObservers.isEmpty { observeKey() }
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self, self.isOpen, let window = event.window, window !== self.panel,
                      window === self.panel.parent || self.closesOnClicks?(window) == true else { return event }
                if self.keepsOpen?(event) == true {
                    self.noteKeptClick()
                    return event
                }
                self.close(.byClickElsewhere)
                // The click goes on to what it landed on.
                return event
            }
        }
        escapeIsDown = false
        if escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self, self.isOpen, event.window === self.panel, Self.isEscape(event) else { return event }
                if event.type == .keyDown {
                    self.escapeIsDown = true
                } else if self.escapeIsDown {
                    self.escapeIsDown = false
                    self.onEscape?()
                }
                return nil
            }
        }
        if shortcutMonitor == nil {
            shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isOpen, event.window === self.panel, event.modifierFlags.contains(.command),
                      !["w", "."].contains(event.charactersIgnoringModifiers ?? ""), self.keepsShortcut?(event) != true
                else { return event }
                self.close()
                // To the menu, as the key interceptor routes ⌘ keys: the
                // terminal behind (Ghostty's own bindings) never takes a
                // key typed here, nor does anything when no menu item does.
                _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
                return nil
            }
        }
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.close(.byClickElsewhere) }
            }
        }
    }

    func close(_ closing: Closing = .byHost) {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        shortcutMonitor = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        guard isOpen else { return }
        isOpen = false
        let hadKeyboard = hasKeyboard(panel)
        if animates() {
            // Back into its control; nothing in it takes a click meanwhile.
            panel.ignoresMouseEvents = true
            let generation = closeGeneration
            PanelGrowth.shrink(panel, into: source()) { [weak self] in
                guard let self, self.closeGeneration == generation else { return }
                self.orderOut()
            }
        } else {
            orderOut()
        }
        onClose?(closing, hadKeyboard)
    }

    private func orderOut() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// It lost the keyboard to another window (Settings, the window behind
    /// after a drag off the badge): it closes, so that no key meant for it
    /// reaches a terminal while it still shows; not for a reply popover one
    /// of its cards opened. It got the keyboard back: its view takes it.
    private func observeKey() {
        let center = NotificationCenter.default
        keyObservers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            // Which window took the keyboard is known once the switch ends.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // A click it let through acts on it first; then, if it
                    // didn't close it (a press dragged off the badge), the
                    // same rule.
                    if ProcessInfo.processInfo.systemUptime - self.keptClickAt < 1 { return self.closeIfKeyboardElsewhereOncePressEnds() }
                    self.closeIfKeyboardElsewhere()
                }
            }
        })
        keyObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let responder = self.responder, let content = self.panel.contentView else { return }
                if (self.panel.firstResponder as? NSView)?.isDescendant(of: content) != true { self.panel.makeFirstResponder(responder) }
            }
        })
    }

    /// A click it let through (`keepsOpen`): the window behind takes the
    /// keyboard on its mouse-down, which must not close it before the
    /// click acts.
    func noteKeptClick() {
        keptClickAt = ProcessInfo.processInfo.systemUptime
    }

    /// Shown without the keyboard, which went to a window not its own: it
    /// closes, so that no key meant for it reaches a terminal while it
    /// still shows.
    private func closeIfKeyboardElsewhere() {
        guard isOpen, !hasKeyboard(panel) else { return }
        if let key = keyWindow(), owns(key) { return }
        close(.byClickElsewhere)
    }

    /// Once the press it let through ends (its action has run by then), the
    /// same rule: a press dragged off the badge leaves it without the
    /// keyboard, and nothing else would close it.
    private func closeIfKeyboardElsewhereOncePressEnds() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isOpen else { return }
                if self.pressedMouseButtons() & 1 != 0 { return self.closeIfKeyboardElsewhereOncePressEnds() }
                // After what the release does.
                DispatchQueue.main.async { MainActor.assumeIsolated { self.closeIfKeyboardElsewhere() } }
            }
        }
    }

    /// A window that hangs from it, or one its host says belongs with it.
    private func owns(_ window: NSWindow) -> Bool {
        var current: NSWindow? = window
        while let candidate = current {
            if candidate === panel { return true }
            current = candidate.parent
        }
        return ownsWindow?(window) == true
    }

    /// Escape, and ⌘. (the key bindings' Cancel).
    static func isEscape(_ event: NSEvent) -> Bool {
        event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == ".")
    }

    /// Moves it, keeping it open.
    func setFrame(_ frame: NSRect) {
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
    }
}
