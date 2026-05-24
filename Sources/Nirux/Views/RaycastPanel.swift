import AppKit

/// Shared Raycast-style panel factory used by NameInputPanel, URLInputPanel, and
/// WorktreePanel. Each of these was hand-rolling an identical NSPanel +
/// rounded-container + icon + text-field + Escape-monitor setup (~25 lines of
/// duplicated boilerplate across 3 files); this factory collapses that into
/// one place so the panels only describe what's unique to them.
@MainActor
enum RaycastPanel {

    struct Config {
        /// Outer panel size (matches the container).
        let width: CGFloat
        let height: CGFloat
        /// Emoji or SF-symbol-style glyph rendered in the left-hand icon slot.
        let icon: String
        /// Placeholder shown in the text field when empty.
        let placeholder: String
        /// Y coordinate of the icon's 24×24 frame (defaults to vertical center).
        var iconY: CGFloat?
        /// Y coordinate of the text field's 28-tall frame (defaults to
        /// vertical center). Override when the panel stacks additional rows
        /// below the field (e.g. WorktreePanel's status line).
        var fieldY: CGFloat?
    }

    /// Built panel plus the pieces callers typically need to keep references
    /// to. Return order mirrors the local variables the legacy panel classes
    /// used so migration is mechanical.
    struct Built {
        let panel: NSPanel
        let container: NSView
        let field: NSTextField
    }

    /// Create a ready-to-show floating panel. The caller is responsible for
    /// retaining `panel`/`field` and for calling `show(_:relativeTo:)` to
    /// position + order it front.
    ///
    /// The Escape-key monitor is attached inside the factory and captures a
    /// weak reference to the returned panel; pressing Escape while the panel
    /// is visible calls `orderOut(nil)`.
    static func build(
        _ config: Config,
        fieldTarget: AnyObject,
        fieldAction: Selector
    ) -> Built {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: config.width, height: config.height),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.becomesKeyOnlyIfNeeded = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovable = false
        panel.level = .floating
        panel.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1)
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: config.width, height: config.height))
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.backgroundColor = NSColor(red: 0.14, green: 0.14, blue: 0.18, alpha: 1).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor

        let icon = NSTextField(labelWithString: config.icon)
        icon.font = .systemFont(ofSize: 16)
        let iconY = config.iconY ?? (config.height - 24) / 2
        icon.frame = NSRect(x: 12, y: iconY, width: 24, height: 24)
        container.addSubview(icon)

        let textField = NSTextField()
        textField.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textField.textColor = .white
        textField.backgroundColor = .clear
        textField.isBezeled = false
        textField.focusRingType = .none
        textField.drawsBackground = false
        textField.placeholderString = config.placeholder
        let fieldY = config.fieldY ?? (config.height - 28) / 2
        textField.frame = NSRect(x: 42, y: fieldY, width: config.width - 54, height: 28)
        textField.target = fieldTarget
        textField.action = fieldAction
        container.addSubview(textField)

        panel.contentView = container

        // Dismiss on Escape. `weak panel` so we don't keep the panel alive
        // beyond its owner.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak panel] event in
            guard let panel, panel.isVisible else { return event }
            if event.keyCode == 0x35 { // Escape
                panel.orderOut(nil)
                return nil
            }
            return event
        }

        return Built(panel: panel, container: container, field: textField)
    }

    /// Center the panel horizontally on `window` and position it at 65% of
    /// the window's vertical extent (the Raycast sweet spot).
    static func show(_ panel: NSPanel, relativeTo window: NSWindow, size: NSSize) {
        let wFrame = window.frame
        let x = wFrame.origin.x + (wFrame.width - size.width) / 2
        let y = wFrame.origin.y + wFrame.height * 0.65
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
    }
}
