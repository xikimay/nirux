import AppKit
import CoreGraphics
import GhosttyTerminal

/// A column's terminal view. AppTerminalView builds Ghostty's surface, while
/// it has none, from the calls below: `onSurfaceBuildChance` runs before and
/// after each of them, so that the column can pick the controller the
/// surface is built from (see `ColumnState.matchTerminalVsyncToDisplays`).
final class ColumnTerminalView: TerminalView {
    var onSurfaceBuildChance: (() -> Void)?

    override func viewDidMoveToWindow() {
        onSurfaceBuildChance?()
        super.viewDidMoveToWindow()
        onSurfaceBuildChance?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        // MUTATION M5: no call before
        super.setFrameSize(newSize)
        onSurfaceBuildChance?()
    }

    override func layout() {
        onSurfaceBuildChance?()
        super.layout()
        onSurfaceBuildChance?()
    }

    override func viewDidChangeBackingProperties() {
        onSurfaceBuildChance?()
        super.viewDidChangeBackingProperties()
        onSurfaceBuildChance?()
    }

    /// The color scheme AppTerminalView gives its controller.
    var colorScheme: TerminalColorScheme {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

enum Displays {
    /// Whether a display is active: none while every display sleeps (a
    /// locked Mac, its screen off). Unknown reads as none.
    static func anyActive() -> Bool {
        var count: UInt32 = 0
        return CGGetActiveDisplayList(0, nil, &count) == .success && count > 0
    }
}
