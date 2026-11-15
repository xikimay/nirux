import AppKit

/// The Board's column: its header (the "Board" title, the repository or the
/// space, Refresh, the ⋯ menu with the space and Board Settings…), then the
/// Board as stages (`BoardStagesView`). The header has no pill: each
/// repository's header says its post-merge run, or what went wrong.
@MainActor
final class BoardColumnView: NSView {
    /// A space the ⋯ menu's Space submenu lists.
    struct Space: Equatable {
        let id: String
        let name: String
    }

    /// What a Board whose space was deleted names it.
    static let deletedSpace = "Deleted space"

    struct Header: Equatable {
        /// Nil once the space was deleted: the Space submenu says so.
        var spaceName: String?
        /// `owner/name` on a Board with one repository.
        var repository: String?
        /// When the pull requests were read, or what went wrong reading
        /// them: Refresh's tooltip.
        var status: String?
        /// The Space submenu.
        var spaces: [Space] = []
        var spaceID: String
    }

    let header = ColumnHeaderView()
    let refreshButton = ColumnHeaderButton(symbol: Theme.Symbol.reload, toolTip: "Refresh")
    let stages = BoardStagesView(frame: .zero)
    private(set) var shownHeader: Header?

    var onRefresh: (() -> Void)?
    var onSelectSpace: ((String) -> Void)?
    /// Board Settings… in the ⋯ menu: the repository the form showed last.
    var onBoardSettings: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.canvas.cgColor
        appearance = Theme.appearance
        header.icon = .symbol(Theme.Symbol.projectBoard)
        header.title = "Board"
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        header.trailingButtons = [refreshButton]
        header.menuProvider = { [weak self] in self?.headerMenu() ?? NSMenu() }
        [header, stages].forEach(addSubview)
        // Tab, from the column: Refresh, ⋯, then the Board's stops, back to Refresh (Full Keyboard Access).
        nextKeyView = refreshButton
        refreshButton.nextKeyView = header.menuButton
        header.menuButton.nextKeyView = stages.orderSwitch
        stages.keyLoopEnd = refreshButton
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(header content: Header, stages stagesContent: BoardStagesView.Content) {
        if content != shownHeader {
            shownHeader = content
            let spaceName = content.spaceName ?? Self.deletedSpace
            header.context = content.repository ?? spaceName
            header.titleToolTip = "Board · \(spaceName)"
            refreshButton.toolTip = ["Refresh", content.status].compactMap { $0 }.joined(separator: " · ")
        }
        stages.show(stagesContent)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        header.frame = NSRect(x: 0, y: 0, width: newSize.width, height: ColumnHeaderView.height)
        stages.frame = NSRect(
            x: 0, y: ColumnHeaderView.height, width: newSize.width, height: max(0, newSize.height - ColumnHeaderView.height)
        )
    }

    // MARK: - The ⋯ menu

    /// The space, Board Settings, then the column's items. Built as it
    /// opens: a read landing meanwhile can't change it.
    private func headerMenu() -> NSMenu {
        let menu = NSMenu()
        let spaceItem = menu.addItem(withTitle: "Space", action: nil, keyEquivalent: "")
        spaceItem.submenu = spaceMenu()
        menu.addItem(withTitle: "Board Settings…", action: #selector(settingsClicked), keyEquivalent: "").target = self
        menu.addItem(.separator())
        ColumnHeaderView.columnMenuItems().forEach(menu.addItem)
        return menu
    }

    /// The spaces, the Board's own checked; a deleted one first, checked.
    func spaceMenu() -> NSMenu {
        let menu = NSMenu(title: "Space")
        guard let content = shownHeader else { return menu }
        if content.spaceName == nil {
            menu.addItem(withTitle: Self.deletedSpace, action: nil, keyEquivalent: "").state = .on
        }
        for space in content.spaces {
            let item = menu.addItem(withTitle: space.name, action: #selector(spaceChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = space.id
            item.state = content.spaceName != nil && space.id == content.spaceID ? .on : .off
        }
        return menu
    }

    /// Picks the space as the menu would.
    func chooseSpace(id: String) {
        guard let item = spaceMenu().items.first(where: { $0.representedObject as? String == id }) else { return }
        spaceChosen(item)
    }

    @objc private func refreshClicked() { onRefresh?() }

    @objc private func settingsClicked() { onBoardSettings?() }

    @objc private func spaceChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelectSpace?(id)
    }
}
