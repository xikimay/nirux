import AppKit

/// The Settings window's sidebar (`SettingsWindow`): "Nirux" and its panes,
/// then the space's colour square and name, a popup to pick another space,
/// and the space's panes. A table, so ↑ and ↓ walk the panes and VoiceOver
/// reads them as a list; the pane shown lies on the selection's glass, as a
/// task row does in the main sidebar.
@MainActor
final class SettingsSidebar: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// The space shown and the spaces the popup offers.
    struct SpaceHeader: Equatable {
        let current: SettingsWindow.Space
        let all: [SettingsWindow.Space]
    }

    enum Row: Equatable {
        case header(String)
        case space(SpaceHeader)
        case pane(SettingsWindow.Selection, title: String, symbol: String)

        var selection: SettingsWindow.Selection? {
            if case .pane(let selection, _, _) = self { return selection }
            return nil
        }
    }

    static let paneRowHeight: CGFloat = 28
    static let headerRowHeight: CGFloat = 30
    private static let insets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
    private static let rowGap: CGFloat = 2

    let view = NSScrollView()
    let table = NSTableView()
    private(set) var rows: [Row] = []
    /// A pane picked with the mouse or ↑ ↓.
    var onSelect: ((SettingsWindow.Selection) -> Void)?
    /// A space picked in the popup.
    var onPickSpace: ((String) -> Void)?
    /// While the window selects a row itself: no pick to report.
    private var isSelecting = false

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = Theme.Color.base
        table.intercellSpacing = NSSize(width: 0, height: Self.rowGap)
        table.selectionHighlightStyle = .regular
        table.focusRingType = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Settings")
        view.documentView = table
        view.drawsBackground = true
        view.backgroundColor = Theme.Color.base
        view.hasVerticalScroller = false
        view.automaticallyAdjustsContentInsets = false
        view.contentInsets = Self.insets
    }

    /// The rows for these panes and that space.
    func reload(appPanes: [SettingsWindow.AppPane], space: SpaceHeader?) {
        var rows: [Row] = []
        if !appPanes.isEmpty {
            rows.append(.header("Nirux"))
            rows += appPanes.map { .pane(.app($0.id), title: $0.title, symbol: $0.symbol) }
        }
        if let space {
            rows.append(.space(space))
            rows += SpaceSettingsSection.Tab.allCases.map { .pane(.space($0), title: $0.title, symbol: $0.symbol) }
        }
        self.rows = rows
        table.reloadData()
    }

    /// The space's name, colour or the spaces changed.
    func updateSpace(_ header: SpaceHeader?) {
        guard let header, let index = rows.firstIndex(where: { if case .space = $0 { true } else { false } }) else { return }
        rows[index] = .space(header)
        table.reloadData(forRowIndexes: [index], columnIndexes: [0])
    }

    /// Puts the selection on `selection`'s row, reporting nothing.
    func select(_ selection: SettingsWindow.Selection?) {
        isSelecting = true
        defer { isSelecting = false }
        guard let selection, let index = rows.firstIndex(where: { $0.selection == selection }) else {
            table.deselectAll(nil)
            return
        }
        if table.selectedRow != index { table.selectRowIndexes([index], byExtendingSelection: false) }
        table.scrollRowToVisible(index)
    }

    /// The height the rows take, with the insets around them.
    var contentHeight: CGFloat {
        let rowsHeight = rows.reduce(CGFloat(0)) { $0 + height(of: $1) + Self.rowGap }
        return rowsHeight + Self.insets.top + Self.insets.bottom
    }

    private func height(of row: Row) -> CGFloat {
        if case .pane = row { return Self.paneRowHeight }
        return Self.headerRowHeight
    }

    // MARK: - NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows.indices.contains(row) ? height(of: rows[row]) : Self.paneRowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].selection != nil
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SettingsSidebarRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .header(let title): return Self.headerCell(title)
        case .space(let header): return spaceCell(header)
        case .pane(_, let title, let symbol): return Self.paneCell(title: title, symbol: symbol)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSelecting, let selection = rows[safe: table.selectedRow]?.selection else { return }
        onSelect?(selection)
    }

    // MARK: - Cells

    private static func headerCell(_ title: String) -> NSView {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: title)
        label.font = Theme.Font.caption
        label.textColor = Theme.Color.textTertiary
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -5)
        ])
        cell.setAccessibilityRole(.staticText)
        return cell
    }

    private func spaceCell(_ header: SpaceHeader) -> NSView {
        let cell = NSTableCellView()
        let square = NSView()
        square.wantsLayer = true
        square.layer?.cornerRadius = Theme.Radius.spaceMark
        square.layer?.backgroundColor = SidebarView.profileColor(hex: header.current.colorHex).cgColor
        square.translatesAutoresizingMaskIntoConstraints = false
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.isBordered = false
        popup.font = Theme.Font.caption
        popup.contentTintColor = Theme.Color.textSecondary
        for space in header.all {
            popup.addItem(withTitle: space.name)
            popup.lastItem?.representedObject = space.id
        }
        popup.selectItem(at: header.all.firstIndex { $0.id == header.current.id } ?? 0)
        popup.target = self
        popup.action = #selector(spacePicked(_:))
        popup.setAccessibilityLabel("Space")
        popup.toolTip = "The space whose settings show"
        popup.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(square)
        cell.addSubview(popup)
        NSLayoutConstraint.activate([
            square.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 18),
            square.widthAnchor.constraint(equalToConstant: 9),
            square.heightAnchor.constraint(equalToConstant: 9),
            square.centerYAnchor.constraint(equalTo: popup.centerYAnchor),
            popup.leadingAnchor.constraint(equalTo: square.trailingAnchor, constant: 4),
            popup.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            popup.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -1)
        ])
        return cell
    }

    @objc private func spacePicked(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        onPickSpace?(id)
    }

    private static func paneCell(title: String, symbol: String) -> NSView {
        let cell = NSTableCellView()
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = Theme.Color.textSecondary
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.cell?.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = Theme.Font.body
        label.textColor = Theme.Color.textPrimary
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(label)
        cell.imageView = icon
        cell.textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

/// A sidebar row: the pane shown lies on the selection's glass (a
/// translucent fill, a `line` rim, `lineStrong` along its top), as the
/// selected task row does.
final class SettingsSidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 8, dy: 0).insetBy(dx: 0.5, dy: 0.5)
        let radius = Theme.Radius.control
        let pane = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        Theme.Color.selectionGlass.setFill()
        pane.fill()
        Theme.Color.line.setStroke()
        pane.lineWidth = 1
        pane.stroke()
        Theme.Color.lineStrong.setFill()
        // The table is flipped: the top edge is at minY.
        NSRect(x: rect.minX + radius, y: rect.minY + 0.5, width: max(0, rect.width - 2 * radius), height: 1).fill()
    }
}
