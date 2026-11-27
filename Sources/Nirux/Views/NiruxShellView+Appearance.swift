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
        // One resolver for the window and its glass.
        let resolve = sideEffects.drawnTransparency
        commandBarToolbar?.bar.resolveLevel = resolve
        commandBarToolbar?.island.resolveLevel = resolve
        requestsState.inbox?.resolveLevel = resolve
        requestsState.callout?.resolveLevel = resolve
        commandBarToolbar?.bar.level = level
        commandBarToolbar?.island.level = level
        requestsState.inbox?.level = level
        requestsState.callout?.level = level
        requestsState.inboxPanel?.invalidateShadowWhenDrawn()
        requestsState.calloutPanel?.invalidateShadowWhenDrawn()
        sidebar.show(level: level, resolveLevel: resolve)
        railMayHaveChanged(animated: false)
        if let cover = titleBandCover {
            if barFloats { cover.show(drawnTransparency) } else { endUnderBar() }
        }
        layer?.backgroundColor = translucent ? NSColor.clear.cgColor : Theme.Color.canvas.cgColor
        applyTerminalOpacity()
    }

    /// The terminals' opacity drawn: the one picked, opaque where macOS asks
    /// (the same resolver as the interface's level).
    var drawnTerminalOpacity: Double { sideEffects.drawnTransparency(.clear).usesGlass ? terminalOpacity : 1 }

    /// Every terminal shows the opacity drawn, a new one too (called from
    /// each layout: a column already showing it is left alone); only the
    /// task on screen builds the desktop's blur. The window lets the desktop
    /// through when the interface does, or a terminal on screen does.
    func applyTerminalOpacity() {
        let opacity = drawnTerminalOpacity
        let active = activeWorkspace
        for workspace in workspaces {
            for column in workspace.columns where column.terminalView != nil {
                column.showTerminalOpacity(opacity, onScreen: workspace === active)
            }
        }
        let terminalOnScreen = active?.columns.contains { $0.terminalView != nil } ?? false
        (window?.contentView as? MainWindowContent)?.show(drawnTransparency, terminalsTranslucent: opacity < 1 && terminalOnScreen)
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
