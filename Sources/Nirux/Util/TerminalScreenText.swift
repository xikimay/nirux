import Foundation
import GhosttyKit
import GhosttyTerminal

/// A terminal's whole screen as plain text: the scrollback, then the rows
/// on screen. Soft-wrapped rows come back joined, one line per hard line
/// break, as Ghostty's own search sees them.
///
/// libghostty has the call (`ghostty_surface_read_text`), but
/// libghostty-spm only wraps it for the visible rows
/// (`InMemoryTerminalSession.readViewportText`) and keeps the surface
/// private. This reaches the surface by reflection, on the exact version
/// Package.swift pins: the session's `surfaceAccess` holds the surface and
/// the lock under which it is replaced or freed. The read holds that lock,
/// so the surface can't be freed under it; the terminal's output waits
/// meanwhile.
///
/// Call it off the main thread: Ghostty locks the terminal for the read.
/// A libghostty-spm whose layout differs makes `wholeScreen` return nil
/// (`TerminalScreenTextTests` then fails) and `read` falls back to the
/// visible rows.
enum TerminalScreenText {
    static func read(_ session: InMemoryTerminalSession) -> String? {
        wholeScreen(session) ?? session.readViewportText()
    }

    /// Nil when there is no surface yet, or when reflection finds no
    /// surface access shaped as expected.
    static func wholeScreen(_ session: InMemoryTerminalSession) -> String? {
        guard let access = property("surfaceAccess", of: session),
              let lock = property("condition", of: access) as? NSCondition
        else { return nil }
        lock.lock()
        defer { lock.unlock() }
        // Read under the lock: it guards every change of the surface.
        guard let surface = property("surface", of: access) as? ghostty_surface_t else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let bytes = text.text, text.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
    }

    private static func property(_ name: String, of subject: Any) -> Any? {
        Mirror(reflecting: subject).children.first { $0.label == name }?.value
    }
}
