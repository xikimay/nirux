import AppKit

/// The line closing a section: "MERGED TODAY", then the pull requests
/// merged since midnight: those whose task needs the user, then the
/// others, the newest first. Two rows at most, then "+12 more": a day of
/// twenty merges doesn't push the next repository off the Board.
@MainActor
final class BoardStagesMergedView: NSView {
    let caption = NSTextField(labelWithString: "")
    /// One per pull request, in the order shown.
    private(set) var entries: [BoardStagesMergedEntryView] = []
    /// "+12 more": shows every pull request merged today.
    let moreButton = NSButton(title: "", target: nil, action: nil)
    var onOpen: ((String) -> Void)?
    /// "Clean up" was clicked on an entry: its task's line.
    var onCleanUp: ((String) -> Void)?
    var onUnfold: (() -> Void)?
    private var isUnfolded = false

    private static let rowHeight: CGFloat = 22
    private static let foldedRows = 2

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        caption.attributedStringValue = NSAttributedString(string: "MERGED TODAY", attributes: [
            .font: Theme.Font.label, .foregroundColor: Theme.Color.textTertiary, .kern: Theme.Font.labelKern
        ])
        moreButton.isBordered = false
        moreButton.target = self
        moreButton.action = #selector(moreClicked)
        [caption, moreButton].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A pull request still listed keeps its entry, by its number.
    func show(_ merged: [BoardStages.Merged], now: TimeInterval, isUnfolded: Bool) {
        self.isUnfolded = isUnfolded
        // Amber is never behind "+12 more".
        let inOrder = merged.filter(\.needsYou) + merged.filter { !$0.needsYou }
        var kept = Dictionary(entries.map { ($0.pullRequest.number, $0) }, uniquingKeysWith: { first, _ in first })
        entries = inOrder.map { pullRequest in
            if let entry = kept.removeValue(forKey: pullRequest.number) {
                entry.show(pullRequest, now: now)
                return entry
            }
            let entry = BoardStagesMergedEntryView(pullRequest, now: now)
            entry.onClick = { [weak self, weak entry] in
                if let line = entry?.pullRequest.lineID { self?.onOpen?(line) }
            }
            entry.onCleanUp = { [weak self, weak entry] in
                if let line = entry?.pullRequest.lineID { self?.onCleanUp?(line) }
            }
            return entry
        }
        subviews = [caption] + entries + [moreButton]
    }

    /// Lays the entries out for `width`, each row starting under the
    /// first entry, and says how tall that is.
    func height(for width: CGFloat) -> CGFloat {
        let pad = BoardStagesView.Metrics.padding
        caption.frame = NSRect(x: pad, y: 14, width: ColumnHeaderView.textWidth(caption), height: 13)
        // A Board too narrow for the caption and an entry side by side
        // starts the entries under it.
        let isWide = width - 2 * pad - caption.frame.width - 18 >= 160
        let left = isWide ? caption.frame.maxX + 18 : pad
        let limit = width - pad
        let firstRow = isWide ? 0 : 1
        var x = left
        var row = firstRow
        var shown: [BoardStagesMergedEntryView] = []
        for entry in entries {
            let entryWidth = min(entry.fittingWidth, max(0, limit - left))
            if x + entryWidth > limit, x > left {
                x = left
                row += 1
            }
            guard isUnfolded || row - firstRow < Self.foldedRows else { break }
            entry.frame = NSRect(x: x, y: 12 + CGFloat(row) * Self.rowHeight, width: entryWidth, height: 18)
            shown.append(entry)
            x += entryWidth + 18
        }
        // What didn't fit waits behind "+N more": after the last entry
        // shown, or in its place when the row has no room left.
        moreButton.isHidden = shown.count == entries.count
        if !moreButton.isHidden {
            func fit() -> CGFloat {
                // More of them need the user than two rows hold: it says so.
                let hidden = entries.dropFirst(shown.count)
                let waiting = hidden.filter(\.pullRequest.needsYou).count
                let needs = waiting == 0 ? nil : "\(waiting) \(waiting == 1 ? "needs" : "need") you"
                moreButton.attributedTitle = NSAttributedString(
                    string: (["+\(hidden.count) more"] + (needs.map { [$0] } ?? [])).joined(separator: " · "),
                    attributes: [.font: Theme.Font.body, .foregroundColor: waiting == 0 ? Theme.Color.textTertiary : Theme.Color.waiting]
                )
                moreButton.setAccessibilityLabel(
                    (["\(hidden.count) more pull requests merged today"] + (needs.map { [$0] } ?? [])).joined(separator: ", ")
                )
                return ceil(moreButton.fittingSize.width)
            }
            var moreWidth = fit()
            var origin = shown.last.map { NSPoint(x: $0.frame.maxX + 18, y: $0.frame.minY) }
                ?? NSPoint(x: left, y: 12 + CGFloat(firstRow) * Self.rowHeight)
            while let last = shown.last, shown.count > 1, origin.x + moreWidth > limit {
                origin = last.frame.origin
                shown.removeLast()
                moreWidth = fit()
            }
            moreButton.frame = NSRect(x: origin.x, y: origin.y, width: moreWidth, height: 18)
        }
        let visible = Set(shown.map(ObjectIdentifier.init))
        for entry in entries { entry.isHidden = !visible.contains(ObjectIdentifier(entry)) }
        let bottom = max(shown.last?.frame.maxY ?? 0, moreButton.isHidden ? 0 : moreButton.frame.maxY, caption.frame.maxY)
        return bottom + 6
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.Color.line.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    @objc private func moreClicked() { onUnfold?() }
}

/// One pull request merged today: its dot, its title, then "#287 · 14:02",
/// and "Clean up" while its worktree is there. The title is what gives
/// way; a click opens its task while that one is open here, but on "Clean
/// up", a link of its own.
@MainActor
final class BoardStagesMergedEntryView: NSView, NSViewToolTipOwner {
    /// What a press and its release on an entry do, by where both land.
    enum Target: Equatable {
        case entry, cleanUp
    }

    private(set) var pullRequest: BoardStages.Merged
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    /// "Clean up", a link; "cleaning up…" while one runs.
    let linkLabel = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?
    var onCleanUp: (() -> Void)?
    /// What the mouse went down on: its release on the same is a click.
    private var pressed: Target?
    /// What the title and the link say under the pointer, by where.
    private(set) var hints: [(rect: NSRect, text: String)] = []
    private var toolTips: [(rect: NSRect, tag: NSView.ToolTipTag)] = []

    private static let dot: CGFloat = 6

    override var isFlipped: Bool { true }

    init(_ pullRequest: BoardStages.Merged, now: TimeInterval) {
        self.pullRequest = pullRequest
        super.init(frame: .zero)
        titleLabel.font = Theme.Font.body
        titleLabel.textColor = Theme.Color.textSecondary
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = Theme.Color.textTertiary
        linkLabel.font = Theme.Font.body
        linkLabel.lineBreakMode = .byTruncatingTail
        for label in [titleLabel, detailLabel, linkLabel] {
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        setAccessibilityElement(true)
        apply(now: now)
    }

    /// Shows another state of the pull request, in the same view.
    func show(_ pullRequest: BoardStages.Merged, now: TimeInterval) {
        guard pullRequest != self.pullRequest else { return }
        self.pullRequest = pullRequest
        apply(now: now)
        needsLayout = true
        needsDisplay = true
    }

    private func apply(now: TimeInterval) {
        let time = ProjectBoard.clockTime(Date(timeIntervalSince1970: pullRequest.mergedAt), now: Date(timeIntervalSince1970: now))
        titleLabel.stringValue = pullRequest.title
        if offersCleanUp {
            linkLabel.stringValue = BoardStages.Link.cleanUp.title
            linkLabel.textColor = Theme.Color.accent
        } else {
            linkLabel.stringValue = pullRequest.cleanUp == .running ? "cleaning up…" : ""
            linkLabel.textColor = Theme.Color.textTertiary
        }
        // "#287 · 14:02 · Clean up": joined as a phrase's link is.
        detailLabel.stringValue = "#\(pullRequest.number) · \(time)" + (linkLabel.stringValue.isEmpty ? "" : " ·")
        setAccessibilityRole(pullRequest.lineID == nil ? .staticText : .button)
        setAccessibilityLabel(
            "\(pullRequest.title), #\(pullRequest.number), merged at \(time)" + (pullRequest.needsYou ? ", needs you" : "")
                + (pullRequest.cleanUp == .running ? ", cleaning up" : "")
        )
    }

    /// "Clean up" is a link while the clean-up is offered, of a task
    /// that is open here: it is that task's worktree.
    private var offersCleanUp: Bool { pullRequest.cleanUp == .offered && pullRequest.lineID != nil }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The width it draws whole in.
    var fittingWidth: CGFloat {
        Self.dot + 6 + ColumnHeaderView.textWidth(titleLabel) + 4 + ColumnHeaderView.textWidth(detailLabel) + linkWidth
    }

    /// What "Clean up" takes after the number and the time: its two
    /// margins are the space between them.
    private var linkWidth: CGFloat { linkLabel.stringValue.isEmpty ? 0 : ColumnHeaderView.textWidth(linkLabel) }

    /// Amber while an agent of its task needs the user: never hidden.
    var dotColor: NSColor { pullRequest.needsYou ? Theme.Color.waiting : Theme.Color.done }

    override func layout() {
        super.layout()
        let titleX = Self.dot + 6
        // The title gives way first, then "Clean up", the number and the time last.
        let detailWidth = min(ColumnHeaderView.textWidth(detailLabel), max(0, bounds.width - titleX))
        let link = min(linkWidth, max(0, bounds.width - titleX - detailWidth))
        let titleWidth = max(0, min(ColumnHeaderView.textWidth(titleLabel), bounds.width - titleX - 4 - detailWidth - link))
        titleLabel.frame = NSRect(x: titleX, y: 1, width: titleWidth, height: 16)
        detailLabel.frame = NSRect(x: titleLabel.frame.maxX + 4, y: 2, width: detailWidth, height: 15)
        linkLabel.frame = NSRect(x: detailLabel.frame.maxX, y: 1, width: link, height: 16)
        linkLabel.isHidden = link == 0
        // The entry takes the mouse for its words: a title that is cut
        // shows whole under the pointer, and the link says what its
        // click does. A place that stays keeps its registration.
        hints = []
        if titleWidth < ColumnHeaderView.textWidth(titleLabel) { hints.append((titleLabel.frame, pullRequest.title)) }
        if offersCleanUp, let rect = linkRect { hints.append((rect, BoardStages.Link.cleanUp.hint)) }
        let rects = hints.map(\.rect)
        for gone in toolTips where !rects.contains(gone.rect) { removeToolTip(gone.tag) }
        toolTips = rects.map { rect in toolTips.first { $0.rect == rect } ?? (rect, addToolTip(rect, owner: self, userData: nil)) }
        window?.invalidateCursorRects(for: self)
    }

    /// The link's place, the entry's height; nil where it has no room.
    private var linkRect: NSRect? {
        linkLabel.isHidden ? nil : NSRect(x: linkLabel.frame.minX, y: 0, width: linkLabel.frame.width, height: bounds.height)
    }

    /// What a click at `point` does.
    func target(at point: NSPoint) -> Target {
        offersCleanUp && linkRect?.contains(point) == true ? .cleanUp : .entry
    }

    /// What the pointer shows at `point`, if anything.
    func toolTipText(at point: NSPoint) -> String? {
        hints.first { $0.rect.contains(point) }?.text
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        toolTipText(at: point) ?? ""
    }

    /// A hand on the link, as far as the entry is in sight.
    var handRects: [NSRect] {
        guard offersCleanUp, let rect = linkRect?.intersection(bounds.intersection(visibleRect)), !rect.isEmpty else { return [] }
        return [rect]
    }

    override func resetCursorRects() {
        for rect in handRects { addCursorRect(rect, cursor: .pointingHand) }
    }

    override func draw(_ dirtyRect: NSRect) {
        dotColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: bounds.midY - Self.dot / 2, width: Self.dot, height: Self.dot)).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        pressed = event.clickCount == 1 ? target(at: convert(event.locationInWindow, from: nil)) : nil
    }

    /// The click is the mouse going up on what it went down on, as that
    /// still is, on an entry that still shows: one gone behind "+12
    /// more" meanwhile opens nothing.
    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let pressed, !isHiddenOrHasHiddenAncestor, bounds.contains(point), target(at: point) == pressed else { return }
        switch pressed {
        case .entry: onClick?()
        case .cleanUp: onCleanUp?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard pullRequest.lineID != nil else { return false }
        onClick?()
        return true
    }

    /// "Clean up" by name, and as a click: only while it is offered.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard offersCleanUp else { return nil }
        return [NSAccessibilityCustomAction(name: BoardStages.Link.cleanUp.title) { [weak self] in
            guard let self, self.offersCleanUp, let onCleanUp = self.onCleanUp else { return false }
            onCleanUp()
            return true
        }]
    }
}
