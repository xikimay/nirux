import Foundation

/// The terminals' background opacity (Settings › Appearance › Terminals,
/// docs/design/glass-interface.md, 4.3): 60 to 100 %, by fives, apart from
/// the interface's level. Below 100 % a terminal column shows the desktop
/// through a frost of its own, and Ghostty draws the terminal's background
/// at that opacity over it: "80 %" is 80 % over the desktop's blur, at any
/// interface level.
public enum TerminalOpacity {
    public static let range: ClosedRange<Double> = 0.6...1
    public static let step = 0.05
    /// What text keeps against the background below 100 %, unless the
    /// user's Ghostty config sets its own `minimum-contrast`.
    public static let minimumContrast = 3.0

    /// On an exact step (0.6, not 0.6000000000000001), within the range.
    public static func clamped(_ value: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, (value * 20).rounded() / 20))
    }

    /// Whether a rendered config sets `minimum-contrast` (the user's
    /// Ghostty config: Nirux's own lines never do).
    public static func setsContrast(_ config: String) -> Bool {
        config.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("minimum-contrast") }
    }
}
