import AppKit
import CoreGraphics
import GhosttyTerminal

/// A column's terminal view. AppTerminalView builds Ghostty's surface, while
/// it has none, from the calls below: `onSurfaceBuildChance` runs before
/// each of them, so that the column picks the controller the surface is
/// built from, and after it (`true`), to see a build that failed (see
/// `ColumnState.matchTerminalVsyncToDisplays`).
final class ColumnTerminalView: TerminalView {
    var onSurfaceBuildChance: ((_ afterBuildAttempt: Bool) -> Void)?

    override func viewDidMoveToWindow() {
        onSurfaceBuildChance?(false)
        super.viewDidMoveToWindow()
        onSurfaceBuildChance?(true)
    }

    override func setFrameSize(_ newSize: NSSize) {
        onSurfaceBuildChance?(false)
        super.setFrameSize(newSize)
        onSurfaceBuildChance?(true)
    }

    override func layout() {
        onSurfaceBuildChance?(false)
        super.layout()
        onSurfaceBuildChance?(true)
    }

    override func viewDidChangeBackingProperties() {
        onSurfaceBuildChance?(false)
        super.viewDidChangeBackingProperties()
        onSurfaceBuildChance?(true)
    }

    /// AppTerminalView tries to build the surface in the calls above once
    /// the view is in a window, with a size.
    var canHaveSurface: Bool {
        window != nil && bounds.width > 0 && bounds.height > 0
    }

    /// The color scheme AppTerminalView gives its controller.
    var colorScheme: TerminalColorScheme {
        Theme.isDark(effectiveAppearance) ? .dark : .light
    }
}

enum Displays {
    /// Whether a display is active: none while every display sleeps (a
    /// locked Mac, its screen off). Unknown reads as active: a surface that
    /// then fails to build with vsync is built without it.
    static func anyActive() -> Bool {
        var count: UInt32 = 0
        return CGGetActiveDisplayList(0, nil, &count) != .success || count > 0
    }
}
