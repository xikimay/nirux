import AppKit

extension InterfaceTransparency {
    /// `effective` with macOS's settings as they are now. Whatever draws with
    /// it also observes `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`
    /// and asks again, so turning Reduce transparency on takes effect at once.
    @MainActor func effectiveNow(workspace: NSWorkspace = .shared) -> InterfaceTransparency {
        effective(
            reducesTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increasesContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )
    }
}
