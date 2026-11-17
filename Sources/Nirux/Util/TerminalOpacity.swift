import AppKit
import GhosttyTerminal

/// The terminals' background opacity (Settings › Appearance › Terminals,
/// docs/design/glass-interface.md, 4.3): 60 to 100 %, by fives, apart from
/// the interface's level. Below 100 % a terminal column shows the desktop
/// through a frost of its own, and Ghostty draws the terminal's background
/// at that opacity over it: "80 %" is 80 % over the desktop's blur, at any
/// interface level.
enum TerminalOpacity {
    static let range: ClosedRange<Double> = 0.6...1
    static let step = 0.05
    /// What text keeps against the background below 100 %, unless the
    /// user's Ghostty config sets its own `minimum-contrast`.
    static let minimumContrast = 3.0

    /// On a step, within the range.
    static func clamped(_ value: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, (value / step).rounded() * step))
    }

    /// The per-terminal override at `opacity`: none at 100 %. Cells a
    /// program paints its own background in (a TUI's) take the opacity too.
    static func configuration(_ opacity: Double, userSetsContrast: Bool) -> TerminalConfiguration {
        guard opacity < 1 else { return TerminalConfiguration() }
        let translucent = TerminalConfiguration().backgroundOpacity(opacity).custom("background-opacity-cells", "true")
        return userSetsContrast ? translucent : translucent.minimumContrast(minimumContrast)
    }

    /// Whether a rendered config sets `minimum-contrast` (the user's
    /// Ghostty config: Nirux's own lines never do).
    static func setsContrast(_ config: String) -> Bool {
        config.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("minimum-contrast") }
    }
}
