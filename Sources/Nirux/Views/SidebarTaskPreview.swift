import AppKit

@MainActor
final class SidebarTaskPreview {
    private weak var sidebar: SidebarView?
    private var pending: DispatchWorkItem?
    private(set) var workspaceID: String?
    private(set) var card: TaskPreviewCard?

    init(sidebar: SidebarView) { self.sidebar = sidebar }

    func enter(_ id: String) {
        if workspaceID == id {
            if card != nil { cancelPending() }
            return
        }
        dismiss()
        workspaceID = id
        schedule(after: 0.45) { $0.present() }
    }

    func leave(_ id: String) {
        guard workspaceID == id else { return }
        guard card != nil else { dismiss(); return }
        guard pending == nil else { return }
        schedule(after: 0.25) { preview in
            guard let card = preview.card, let window = card.window else { preview.dismiss(); return }
            if !card.bounds.contains(card.convert(window.mouseLocationOutsideOfEventStream, from: nil)) { preview.dismiss() }
        }
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    private func schedule(after delay: TimeInterval, _ action: @escaping @MainActor (SidebarTaskPreview) -> Void) {
        cancelPending()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pending = nil
            action(self)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func dismiss() {
        cancelPending()
        workspaceID = nil
        card?.removeFromSuperview()
        card = nil
    }

    func refresh() {
        if card != nil { present() }
    }

    private func present() {
        guard let sidebar, let id = workspaceID, let window = sidebar.window, let host = window.contentView,
              let info = sidebar.lastInfos.first(where: { $0.id == id }),
              let frame = sidebar.rowFrame(workspaceID: id), frame.intersects(sidebar.visibleRect)
        else { dismiss(); return }
        let anchor = host.convert(frame.intersection(sidebar.visibleRect), from: sidebar)
        let x = host.convert(sidebar.bounds, from: sidebar).maxX + 2
        let width = min(320, host.bounds.maxX - x - 4)
        guard width >= 150 else { dismiss(); return }
        let card = self.card ?? TaskPreviewCard()
        self.card = card
        if card.superview !== host { host.addSubview(card) }
        card.onEnter = { [weak self] in self?.cancelPending() }
        card.onLeave = { [weak self] in self?.leave(id) }
        card.onOpen = { [weak self, weak sidebar, weak card] in
            guard let self, self.card === card, workspaceID == id, let sidebar,
                  let current = sidebar.lastInfos.first(where: { $0.id == id }) else { return }
            dismiss()
            if let open = sidebar.onOpenTaskThread { open(id) }
            else { sidebar.clickRow(current.index) }
        }
        card.show(info, opensThread: sidebar.onOpenTaskThread != nil, width: width)
        let y = host.isFlipped ? anchor.minY : anchor.maxY - card.frame.height
        card.setFrameOrigin(NSPoint(x: x, y: min(max(host.bounds.minY, y), max(host.bounds.minY, host.bounds.maxY - card.frame.height))))
    }
}

@MainActor
final class TaskPreviewCard: NSView {
    var onEnter: (() -> Void)?
    var onLeave: (() -> Void)?
    var onOpen: (() -> Void)?
    private let title = NSTextField(wrappingLabelWithString: "")
    private let goal = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let next = NSTextField(wrappingLabelWithString: "")
    private let open = NSButton(title: "", target: nil, action: nil)
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.surface.cgColor
        layer?.cornerRadius = Theme.Radius.panel
        layer?.borderWidth = 1
        layer?.borderColor = Theme.Color.textTertiary.withAlphaComponent(0.45).cgColor
        title.font = Theme.Font.title
        title.textColor = Theme.Color.textPrimary
        for field in [title, goal, status, next] {
            if field !== title {
                field.font = Theme.Font.body
                field.textColor = Theme.Color.textSecondary
            }
            field.maximumNumberOfLines = 3
            field.cell?.truncatesLastVisibleLine = true
            addSubview(field)
        }
        open.target = self
        open.action = #selector(openTask)
        open.bezelStyle = .rounded
        addSubview(open)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Task preview")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ info: WorkspaceInfo, opensThread: Bool, width: CGFloat) {
        let row = info.rowSummary.status
        title.stringValue = info.title
        goal.stringValue = WorkspaceInfo.oneRunOfWords(info.purpose) ?? ""
        let nextLine = info.nextStepText.map(WorkspaceInfo.nextStepLine)
        status.stringValue = row.tone == .branch || row.text == nextLine ? info.phase.displayName : row.text
        next.stringValue = info.nextStepText.map { "Next · \($0)" } ?? ""
        var y = Theme.Space.md
        let inner = width - 2 * Theme.Space.md
        for field in [title, goal, status, next] {
            field.isHidden = field.stringValue.isEmpty
            guard !field.isHidden, let cell = field.cell else { continue }
            field.toolTip = field.stringValue
            let height = ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 128)).height)
            field.frame = NSRect(x: Theme.Space.md, y: y, width: inner, height: height)
            y += height + Theme.Space.xs
        }
        open.title = opensThread ? "Open task thread" : "Open task"
        open.sizeToFit()
        open.setFrameOrigin(NSPoint(x: Theme.Space.md, y: y))
        setFrameSize(NSSize(width: width, height: open.frame.maxY + Theme.Space.md))
    }

    @objc private func openTask() { onOpen?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInActiveApp, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onLeave?() }
}
