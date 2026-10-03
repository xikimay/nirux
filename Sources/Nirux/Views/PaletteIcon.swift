import AppKit

/// What a palette row shows on its left, drawn by `PaletteIconView`.
enum PaletteIcon {
    /// An SF Symbol from the validated set: regular weight, tinted like
    /// secondary text, in the accent color on the selected row.
    case symbol(String)
    /// A small dot in a color it keeps when selected: a workspace's project.
    case dot(NSColor)
    /// An image drawn as is: an agent's app icon.
    case image(NSImage)

    /// The icon the sidebar shows for this agent: its app's, else its symbol.
    @MainActor
    static func agent(_ processName: String) -> PaletteIcon {
        if let image = SidebarRenderer.agentAppIcon(processName: processName) { return .image(image) }
        return .symbol(SidebarRenderer.agentSymbol(processName: processName) ?? "terminal")
    }
}

/// The icon slot of a palette row, or of a palette-style panel's field.
/// Decorative: rows and fields are read by their text.
final class PaletteIconView: NSImageView {
    private static let restTint = NSColor.secondaryLabelColor
    private var followsSelection = false

    convenience init(_ icon: PaletteIcon, frame: NSRect) {
        self.init(frame: frame)
        // The cell is what VoiceOver reaches.
        cell?.setAccessibilityElement(false)
        switch icon {
        case .symbol(let name):
            setSymbol(name, pointSize: 14)
            contentTintColor = Self.restTint
            followsSelection = true
        case .dot(let color):
            setSymbol("circle.fill", pointSize: 10)
            contentTintColor = color
        case .image(let image):
            self.image = image
            imageScaling = .scaleProportionallyUpOrDown
        }
    }

    func setSelected(_ selected: Bool) {
        guard followsSelection else { return }
        contentTintColor = selected ? Theme.Color.accent : Self.restTint
    }

    private func setSymbol(_ name: String, pointSize: CGFloat) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
        // An emoji or a misspelled name would draw nothing, silently.
        assert(image != nil, "No SF Symbol named \(name)")
        imageScaling = .scaleNone
    }
}
