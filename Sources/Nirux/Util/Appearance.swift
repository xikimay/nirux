import AppKit

/// How much of the desktop shows through Nirux's chrome: the sidebar, the
/// command bar, the rail and what floats over the work. The four levels of
/// Settings › Appearance (docs/design/glass-interface.md); nothing reads
/// this yet. The terminals have their own opacity, apart from this.
enum InterfaceTransparency: String, CaseIterable, Codable, Sendable {
    case opaque, tinted, glass, clear

    static let `default`: InterfaceTransparency = .tinted

    /// The level to draw: what the user picked, unless macOS asks for less
    /// transparency. Reduce transparency and Increase contrast make every
    /// level opaque.
    func effective(reducesTransparency: Bool, increasesContrast: Bool) -> InterfaceTransparency {
        reducesTransparency || increasesContrast ? .opaque : self
    }

    /// Opacity of the window's own background over the desktop: 1 hides the
    /// desktop, lower lets it show, blurred, behind the chrome.
    var windowBackgroundAlpha: CGFloat {
        switch self {
        case .opaque: return 1
        case .tinted: return 0.80
        case .glass: return 0.56
        case .clear: return 0.30
        }
    }

    /// Opacity of the tint laid over the glass of the chrome. What floats
    /// over the work (a request, a menu) keeps a thick background whatever
    /// the level: no glass on glass.
    var chromeTintAlpha: CGFloat {
        switch self {
        case .opaque: return 0.86
        case .tinted: return 0.62
        case .glass: return 0.42
        case .clear: return 0.24
        }
    }

    /// The clearer of the two glass styles (`NSGlassEffectView.Style.clear`
    /// on macOS 26), for the most transparent level only.
    var usesClearGlass: Bool { self == .clear }
}
