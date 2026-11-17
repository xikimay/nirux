import AppKit

// MARK: - Appearance (docs/design/glass-interface.md, 4.2)

extension NiruxShellView {
    static func currentInterfaceTransparency() -> InterfaceTransparency {
        Persistence.load()?.settings?.interfaceTransparency ?? .defaultValue
    }

    /// The level reaches the chrome (the command bar, the rail, the
    /// sidebar) and what floats over the work, which keeps its thick tint
    /// (`GlassView.Role.floating`). Panels opened later take it as they
    /// open.
    func applyInterfaceTransparency() {
        let level = interfaceTransparency
        commandBarToolbar?.bar.level = level
        sidebar.level = level
    }
}
