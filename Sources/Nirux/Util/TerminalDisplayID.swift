import AppKit
import GhosttyKit
import GhosttyTerminal

/// Ghostty builds a terminal's surface while no display is active (a
/// locked Mac, its screen off) without the display link that paces its
/// drawing to the screen, and creates that link only once it is told the
/// surface's display (`ghostty_surface_set_display_id`), which
/// libghostty-spm never does. Until then the surface draws unpaced, which
/// Ghostty's doc for `window-vsync` ties to kernel panics (macOS 14.4+).
/// Nirux tells every terminal its display whenever displays may be back
/// (see `NiruxShellView.sendDisplayToTerminals`); a terminal that has its
/// link already only binds it to that display.
enum TerminalDisplayID {
    /// The display `view`'s window is on, else the main one.
    static func display(of view: NSView) -> CGDirectDisplayID {
        let number = view.window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.uint32Value ?? CGMainDisplayID()
    }

    /// False when the terminal has no surface yet (see
    /// `TerminalScreenText.withSurface`).
    @discardableResult
    static func send(_ display: CGDirectDisplayID, to session: InMemoryTerminalSession) -> Bool {
        TerminalScreenText.withSurface(session) { ghostty_surface_set_display_id($0, display) } != nil
    }
}
