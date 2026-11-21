import AppKit

/// The scrollable body of the pinned task card. The card owns its title, placement and dismissal.
@MainActor
final class TaskThreadContentView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    typealias Read = (String, String, @escaping @MainActor (TaskThread.Timeline?) -> Void) -> Void

    private final class Item: NSObject {
        let line: TaskThread.Timeline.Line
        let section: TaskThread.Timeline.Stage?
        let children: [Item]

        init(_ line: TaskThread.Timeline.Line, section: TaskThread.Timeline.Stage? = nil, children: [Item] = []) {
            self.line = line
            self.section = section
            self.children = children
        }
    }

    var onDismiss: (() -> Void)?
    private var escapeMonitor: Any?
    let outline = NSOutlineView()
    private var items: [Item] = []
    private var workspaceID: String?
    private var spaceID: String?
    private var request: UUID?
    private var displayed: TaskThread.Timeline?
    var isReading: Bool { request != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let scroll = NSScrollView(frame: bounds)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.style = .plain
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.usesAutomaticRowHeights = true
        let column = NSTableColumn(identifier: .init("thread"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel("Task thread")
        scroll.documentView = outline
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        if let newWindow {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak newWindow] event in
                guard let newWindow, event.window === newWindow, RequestPanel.isEscape(event),
                      let dismiss = self?.onDismiss else { return event }
                dismiss()
                return nil
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func show(workspaceID: String, spaceID: String, read: Read) {
        let token = UUID()
        request = token
        let changed = self.workspaceID != workspaceID || self.spaceID != spaceID
        self.workspaceID = workspaceID
        self.spaceID = spaceID
        if changed {
            displayed = nil
            replace(with: [message("Loading thread…")])
            outline.scroll(.zero)
        }
        read(workspaceID, spaceID) { [weak self] timeline in
            guard let self, request == token else { return }
            request = nil
            if let timeline, timeline == displayed { return }
            displayed = timeline
            guard let timeline else { return replace(with: [message("Thread unavailable")]) }
            let expanded = items.compactMap { outline.isItemExpanded($0) ? $0.section : nil }
            let sections = timeline.sections.map { section in
                let children = section.entries.map { Item($0) }
                let last = section.entries.last
                let preview = last.map { $0.text.isEmpty ? $0.label : $0.text } ?? ""
                let line = TaskThread.Timeline.Line(label: section.stage.rawValue, text: preview, time: last?.time)
                return Item(line, section: section.stage, children: children)
            }
            let rows = timeline.current.map { Item($0) } + sections
            replace(with: rows.isEmpty ? [message("No recorded events.")] : rows)
            for item in sections where item.section.map(expanded.contains) == true { outline.expandItem(item) }
        }
    }

    private func message(_ text: String) -> Item { Item(.init(label: text, text: "")) }

    private func replace(with rows: [Item]) {
        items = rows
        outline.reloadData()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Item)?.children.count ?? items.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? Item)?.children ?? items)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Item)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item else { return nil }
        let id = NSUserInterfaceItemIdentifier("thread-line")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? ThreadLineCell ?? ThreadLineCell()
        cell.identifier = id
        cell.update(item.line, foldedPreview: item.section != nil)
        return cell
    }
}

@MainActor
private final class ThreadLineCell: NSTableCellView {
    private let label = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.xs),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.sm),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.xs),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.xs)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(_ line: TaskThread.Timeline.Line, foldedPreview: Bool) {
        let color = line.needsUser ? StateIcon(mark: .needsYou).color : Theme.Color.textPrimary
        let text = NSMutableAttributedString(string: line.label, attributes: [.font: Theme.Font.bodyEmphasized, .foregroundColor: color])
        if let time = line.time {
            text.append(NSAttributedString(string: "   " + DailyPass.clock(time), attributes: [
                .font: Theme.Font.captionDigits, .foregroundColor: Theme.Color.textTertiary
            ]))
        }
        if !line.text.isEmpty {
            let detail = foldedPreview ? String(line.text.prefix(140)).components(separatedBy: .newlines).joined(separator: " ") : line.text
            text.append(NSAttributedString(string: "\n" + detail, attributes: [.font: Theme.Font.body, .foregroundColor: Theme.Color.textSecondary]))
        }
        label.maximumNumberOfLines = foldedPreview ? 2 : 0
        label.lineBreakMode = foldedPreview ? .byTruncatingTail : .byWordWrapping
        label.attributedStringValue = text
        setAccessibilityLabel(text.string)
    }
}

extension NiruxShellView {
    func refreshPinnedTaskThread() {
        guard let body = sidebar.taskPreview.pinnedBody, !body.isReading,
              let id = sidebar.taskPreview.workspaceID else { return }
        body.show(workspaceID: id, spaceID: activeProfileID, read: readThreadTimeline)
    }

    func readThreadTimeline(workspaceID: String, spaceID: String, completion: @escaping @MainActor (TaskThread.Timeline?) -> Void) {
        readTaskThread(workspaceID: workspaceID, spaceID: spaceID, render: TaskThread.Timeline.init, completion: completion)
    }
}
