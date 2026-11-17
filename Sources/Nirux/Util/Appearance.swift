import AppKit

/// How much of the desktop shows through Nirux's chrome: the sidebar, the
/// command bar, the rail and what floats over the work. The four levels of
/// Settings › Appearance (docs/design/glass-interface.md). The glass view
/// brings the values each level draws with. The terminals have their own
/// opacity, apart from this.
///
/// Not `Codable` on purpose: persist it as an optional raw string, so that a
/// level from a newer build reads as no choice instead of making the whole
/// state file undecodable (see `Persistence`).
enum InterfaceTransparency: String, CaseIterable, Sendable {
    case opaque, tinted, glass, clear

    /// Until the energy bench and the user say Tinted.
    static let defaultValue = InterfaceTransparency.opaque

    /// The level to draw: what the user picked, unless macOS asks for less
    /// transparency. Reduce transparency and Increase contrast make every
    /// level opaque.
    func effective(reducesTransparency: Bool, increasesContrast: Bool) -> InterfaceTransparency {
        reducesTransparency || increasesContrast ? .opaque : self
    }

    /// `effective` with macOS's settings as they are now. Whatever draws with
    /// it also observes `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`
    /// and asks again, so turning Reduce transparency on takes effect at once.
    @MainActor func effectiveNow(workspace: NSWorkspace = .shared) -> InterfaceTransparency {
        effective(
            reducesTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increasesContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )
    }

    /// Opaque draws no glass at all: solid chrome, no blur, nothing of the
    /// desktop or the work behind it.
    var usesGlass: Bool { self != .opaque }

    /// The clearer of the two glass styles (`NSGlassEffectView.Style.clear`
    /// on macOS 26), for the most transparent level only.
    var usesClearGlass: Bool { self == .clear }
}
