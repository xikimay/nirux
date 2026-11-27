import AppKit

extension NSTitlebarAccessoryViewController {
    /// A trailing accessory changed its width: the title bar lays out again,
    /// so the toolbar's centred item (the command bar) makes room or takes
    /// it back.
    func relayOutTitleBar() {
        view.superview?.needsLayout = true
        view.window?.contentView?.superview?.needsLayout = true
    }
}

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
    static let islandItemID = NSToolbarItem.Identifier("nirux.leadIsland")
    static let maximumBarWidth: CGFloat = 640
    static let minimumBarWidth: CGFloat = 280

    let bar: CommandBarView
    /// The Lead island, left of the bar while the space plans the day (`showIsland`).
    let island: LeadIslandView
    let toolbar: NSToolbar
    /// Made once: a second item handed the same bar would take it from the
    /// live one (full screen in or out, a toolbar sync), leaving an empty
    /// strip.
    private(set) lazy var barItem = Self.barItem(bar)
    private(set) lazy var islandItem = Self.islandItem(island)
    private var displayModeObservation: NSKeyValueObservation?

    init(bar: CommandBarView) {
        self.bar = bar
        island = LeadIslandView(level: bar.level)
        toolbar = NSToolbar(identifier: "nirux.main")
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        // The strip's menu would offer a text mode, a text item in the
        // bar's place: none on macOS 15, put back at once on 14.
        if #available(macOS 15, *) { toolbar.allowsDisplayModeCustomization = false }
        displayModeObservation = toolbar.observe(\.displayMode) { toolbar, _ in
            MainActor.assumeIsolated { if toolbar.displayMode != .iconOnly { toolbar.displayMode = .iconOnly } }
        }
        toolbar.centeredItemIdentifiers = [Self.islandItemID, Self.barItemID]
        // From 280 to 640 pt, as wide as the strip allows: the toolbar sizes
        // the item between those bounds (a preferred width above priority 50
        // would make it measure 640 and send the bar to the » menu in a
        // narrow window); the bar gives way inside, its detail first.
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: CommandBarView.height),
            bar.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maximumBarWidth),
            bar.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumBarWidth),
        ])
        island.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            island.heightAnchor.constraint(equalToConstant: CommandBarView.height),
            island.widthAnchor.constraint(lessThanOrEqualToConstant: LeadIslandView.maximumWidth),
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
        switch itemIdentifier {
        case Self.barItemID: return barItem
        case Self.islandItemID: return islandItem
        default: return nil
        }
    }

    /// The island with `content`, or none.
    func showIsland(_ content: LeadIslandView.Content?) {
        if let content { island.show(content) }
        let index = toolbar.items.firstIndex { $0.itemIdentifier == Self.islandItemID }
        if content != nil, index == nil {
            toolbar.insertItem(withItemIdentifier: Self.islandItemID, at: 0)
        } else if content == nil, let index {
            toolbar.removeItem(at: index)
        }
    }

    static func islandItem(_ island: LeadIslandView) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: islandItemID)
        item.view = island
        item.label = "Lead"
        item.isBordered = false
        if #available(macOS 26, *) { item.style = .plain }
        return item
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
        [Self.barItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.islandItemID, Self.barItemID]
    }
}
