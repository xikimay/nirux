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
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
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
    /// Called once each time it closes.
    var onClose: ((Closing) -> Void)?
    /// A click there leaves it open: its host acts on it (the bar's badge,
    /// which toggles the inbox).
    var keepsOpen: ((NSEvent) -> Bool)?
    private var clickMonitor: Any?

    init(content: NSView) {
        panel = Panel(contentRect: content.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = content
    }

    var isOpen: Bool { panel.isVisible }

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
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.isOpen, event.window !== self.panel, self.keepsOpen?(event) != true else { return event }
            self.close(.byClickElsewhere)
            // The click goes on to what it landed on.
            return event
        }
    }

    func close(_ closing: Closing = .byHost) {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard isOpen else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        onClose?(closing)
    }

    /// Moves it, keeping it open.
    func setFrame(_ frame: NSRect) {
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
    }
}
