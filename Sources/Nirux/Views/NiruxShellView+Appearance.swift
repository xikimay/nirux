import AppKit

// MARK: - Appearance (docs/design/glass-interface.md, 4.2)

extension NiruxShellView {
    static func currentInterfaceTransparency() -> InterfaceTransparency {
        Persistence.load()?.settings?.interfaceTransparency ?? .defaultValue
    }

    /// The level drawn: the one picked, made opaque where macOS asks.
    var drawnTransparency: InterfaceTransparency { sideEffects.drawnTransparency(interfaceTransparency) }

    /// The level reaches the chrome (the command bar, the rail, the
    /// sidebar) and what floats over the work, which keeps its thick tint
    /// (`GlassView.Role.floating`): the inbox and the callout, kept once
    /// made; ⌘P takes the bar's as it opens. Above Opaque the window lets
    /// the desktop through (`MainWindowContent`), and the canvas and the
    /// sidebar let its frost show.
    func applyInterfaceTransparency() {
        let level = interfaceTransparency
        let translucent = drawnTransparency.usesGlass
        commandBarToolbar?.bar.level = level
        requestsState.inbox?.level = level
        requestsState.callout?.level = level
        requestsState.inboxPanel?.invalidateShadowWhenDrawn()
        requestsState.calloutPanel?.invalidateShadowWhenDrawn()
        sidebar.level = level
        sidebar.layer?.backgroundColor = translucent ? NSColor.clear.cgColor : Theme.Color.base.cgColor
        layer?.backgroundColor = translucent ? NSColor.clear.cgColor : Theme.Color.canvas.cgColor
        (window?.contentView as? MainWindowContent)?.show(drawnTransparency)
    }

    /// Reduce transparency and Increase contrast make the window opaque at
    /// once, and back (the glass views follow on their own).
    func wireAppearance() {
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyInterfaceTransparency() }
        }
        // The shell's bag of workspace observers, dropped with it.
        agentLights.observers.add(token, on: center)
    }

    /// The shell a window holds: Nirux's main window's.
    static func of(_ window: NSWindow?) -> NiruxShellView? {
        window?.contentView as? NiruxShellView ?? (window?.contentView as? MainWindowContent)?.shell
    }
}
