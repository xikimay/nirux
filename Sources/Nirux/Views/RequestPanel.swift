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
        /// A key nothing takes (a letter typed by mistake) goes nowhere,
        /// without a beep.
        override func noResponder(for eventSelector: Selector) {}
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
    /// which toggles the inbox; the callout's own icon).
    var keepsOpen: ((NSEvent) -> Bool)?
    /// Another window whose clicks close it, besides the one it sits over
    /// (the toolbar's own window in full screen). Clicks in any other
    /// window (a reply popover a card opened, Settings) leave it open.
    var closesOnClicks: ((NSWindow) -> Bool)?
    private var clickMonitor: Any?
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

    /// Shows it at `frame` (screen coordinates) over `window`, `responder`
    /// taking the keyboard.
    func show(frame: NSRect, over window: NSWindow, responder: NSView) {
        panel.setFrame(frame, display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(responder)
        self.responder = responder
        isOpen = true
        if keyObservers.isEmpty { observeKey() }
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self, self.isOpen, let window = event.window, window !== self.panel,
                      window === self.panel.parent || self.closesOnClicks?(window) == true,
                      self.keepsOpen?(event) != true else { return event }
                self.close(.byClickElsewhere)
                // The click goes on to what it landed on.
                return event
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
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        guard isOpen else { return }
        isOpen = false
        let hadKeyboard = panel.isKeyWindow
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        onClose?(closing, hadKeyboard)
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
                    guard let self, self.isOpen, !self.panel.isKeyWindow else { return }
                    if let key = NSApp.keyWindow, self.owns(key) { return }
                    self.close(.byClickElsewhere)
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

    /// A window that hangs from it: a popover a card opened.
    private func owns(_ window: NSWindow) -> Bool {
        var current: NSWindow? = window
        while let candidate = current {
            if candidate === panel { return true }
            current = candidate.parent
        }
        return window.className.contains("Popover")
    }

    /// Moves it, keeping it open.
    func setFrame(_ frame: NSRect) {
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
    }
}
