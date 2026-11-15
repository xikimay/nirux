import AppKit

/// The main window's toolbar in the glass interface
/// (docs/design/glass-interface.md, step 3.1): empty and unified, with the
/// command bar as its centred item. AppKit sets it level with the window's
/// buttons, moves the window from the empty strip on either side, zooms on a
/// double-click there, and keeps the toolbar in full screen. The usage
/// limits and the keep-awake cup stay trailing title bar accessories, at its
/// right end.
@MainActor
final class CommandBarToolbar: NSObject, NSToolbarDelegate {
    static let barItemID = NSToolbarItem.Identifier("nirux.commandBar")
    static let maximumBarWidth: CGFloat = 640
    static let minimumBarWidth: CGFloat = 280

    let bar: CommandBarView
    let toolbar: NSToolbar

    init(bar: CommandBarView) {
        self.bar = bar
        toolbar = NSToolbar(identifier: "nirux.main")
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.barItemID]
        // As wide as the strip allows, from 280 to 640 pt: the bar gives way
        // inside (its detail first) as the window narrows.
        bar.translatesAutoresizingMaskIntoConstraints = false
        let preferred = bar.widthAnchor.constraint(equalToConstant: Self.maximumBarWidth)
        preferred.priority = .defaultLow
        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: CommandBarView.height),
            bar.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maximumBarWidth),
            bar.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumBarWidth),
            preferred,
        ])
    }

    /// Gives `window` the toolbar: its title bar grows to the toolbar's
    /// height, the content starts under it as before.
    func install(in window: NSWindow) {
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.barItemID else { return nil }
        return Self.barItem(bar)
    }

    /// The bar's item. On macOS 26 a toolbar item may sit on the system's
    /// glass; the bar draws its own (`GlassView`), so the item asks for none:
    /// not bordered, the plain style. (The SDK documents `isBordered` for
    /// items without a custom view; the first nightly on macOS 26 shows
    /// whether the system leaves the bar's item bare.)
    static func barItem(_ bar: CommandBarView) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: barItemID)
        item.view = bar
        item.label = "Command bar"
        item.isBordered = false
        item.visibilityPriority = .high
        if #available(macOS 26, *) { item.style = .plain }
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.barItemID, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.barItemID]
    }
}
