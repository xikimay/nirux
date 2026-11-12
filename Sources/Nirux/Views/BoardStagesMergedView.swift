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

/// One pull request merged today: its dot, its title, then "#287 · 14:02".
/// The title is what gives way; a click opens its task while that one is
/// open here.
@MainActor
final class BoardStagesMergedEntryView: NSView {
    private(set) var pullRequest: BoardStages.Merged
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?
    private var isPressed = false

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
        for label in [titleLabel, detailLabel] {
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
        detailLabel.stringValue = "#\(pullRequest.number) · \(time)"
        setAccessibilityRole(pullRequest.lineID == nil ? .staticText : .button)
        setAccessibilityLabel(
            "\(pullRequest.title), #\(pullRequest.number), merged at \(time)" + (pullRequest.needsYou ? ", needs you" : "")
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The width it draws whole in.
    var fittingWidth: CGFloat {
        Self.dot + 6 + ColumnHeaderView.textWidth(titleLabel) + 4 + ColumnHeaderView.textWidth(detailLabel)
    }

    /// Amber while an agent of its task needs the user: never hidden.
    var dotColor: NSColor { pullRequest.needsYou ? Theme.Color.waiting : Theme.Color.done }

    override func layout() {
        super.layout()
        let titleX = Self.dot + 6
        let detailWidth = min(ColumnHeaderView.textWidth(detailLabel), max(0, bounds.width - titleX))
        let titleWidth = max(0, min(ColumnHeaderView.textWidth(titleLabel), bounds.width - titleX - 4 - detailWidth))
        titleLabel.frame = NSRect(x: titleX, y: 1, width: titleWidth, height: 16)
        detailLabel.frame = NSRect(x: titleLabel.frame.maxX + 4, y: 2, width: detailWidth, height: 15)
        // The entry takes the mouse for its words: a title that is cut
        // shows whole under the pointer.
        let whole = titleWidth < ColumnHeaderView.textWidth(titleLabel) ? pullRequest.title : nil
        if toolTip != whole { toolTip = whole }
    }

    override func draw(_ dirtyRect: NSRect) {
        dotColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: bounds.midY - Self.dot / 2, width: Self.dot, height: Self.dot)).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = event.clickCount == 1 && pullRequest.lineID != nil
    }

    override func mouseUp(with event: NSEvent) {
        defer { isPressed = false }
        if isPressed, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard pullRequest.lineID != nil else { return false }
        onClick?()
        return true
    }
}
