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
        // starts the entries under it. Whatever their links: a clean-up
        // that ends doesn't move the block, nor what comes under it.
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
/// and "· Clean up" while its task's worktree is there. The title is what
/// gives way; a click opens its task while that one is open here, but on
/// "Clean up", a link of its own.
@MainActor
final class BoardStagesMergedEntryView: NSView, NSViewToolTipOwner {
    /// What a press and its release on an entry do, by where both land.
    enum Target: Equatable {
        case entry, cleanUp
    }

    private(set) var pullRequest: BoardStages.Merged
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    /// "· Clean up", a link; "· cleaning up…" while one runs.
    let linkLabel = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?
    var onCleanUp: (() -> Void)?
    /// What the mouse went down on: its release on the same is a click.
    private var pressed: Target?
    /// What the entry says under the pointer, by where.
    private var toolTips = BoardStagesToolTips()
    var hints: [(rect: NSRect, text: String)] { toolTips.places }
    /// Where a hand was last given to AppKit.
    private var registeredHandRects: [NSRect] = []

    private static let dot: CGFloat = 6
    /// Under this, a title that is cut gives the link's room back.
    private static let fewestTitle: CGFloat = 40
    /// The room of the link, the same whether a clean-up is offered or
    /// runs: the entries after it don't move under the pointer when one
    /// starts.
    static let linkRoom: CGFloat = {
        let label = NSTextField(labelWithString: "")
        label.font = Theme.Font.body
        return [BoardStages.Link.cleanUp.title, BoardStages.CleanUp.runningWords].map { words -> CGFloat in
            label.stringValue = "· \(words)"
            return ColumnHeaderView.textWidth(label)
        }.max() ?? 0
    }()

    override var isFlipped: Bool { true }

    init(_ pullRequest: BoardStages.Merged, now: TimeInterval) {
        self.pullRequest = pullRequest
        super.init(frame: .zero)
        titleLabel.font = Theme.Font.body
        titleLabel.textColor = Theme.Color.textSecondary
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = Theme.Color.textTertiary
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
        detailLabel.stringValue = "#\(pullRequest.number) · \(time)"
        // "· Clean up": joined as a phrase's link is, the words alone in the link's colour.
        let link = NSMutableAttributedString()
        if let words = linkWords {
            link.append(NSAttributedString(string: "· ", attributes: [.font: Theme.Font.body, .foregroundColor: Theme.Color.textTertiary]))
            link.append(NSAttributedString(string: words, attributes: [
                .font: Theme.Font.body, .foregroundColor: offersCleanUp ? Theme.Color.accent : Theme.Color.textTertiary
            ]))
        }
        linkLabel.attributedStringValue = link
        setAccessibilityRole(pullRequest.lineID == nil ? .staticText : .button)
        setAccessibilityLabel(
            (["\(pullRequest.title), #\(pullRequest.number), merged at \(time)"] + (pullRequest.needsYou ? ["needs you"] : [])
                + (linkWords.map { [$0] } ?? [])).joined(separator: ", ")
        )
    }

    /// "Clean up" is a link while the clean-up is offered, of a task
    /// that is open here: it is that task's worktree.
    private var offersCleanUp: Bool { pullRequest.cleanUp == .offered && pullRequest.lineID != nil }

    /// What follows the number and the time, if anything.
    private var linkWords: String? {
        if offersCleanUp { return BoardStages.Link.cleanUp.title }
        return pullRequest.cleanUp == .running ? BoardStages.CleanUp.runningWords : nil
    }

    /// It says something of a clean-up after its number and its time.
    var hasLink: Bool { linkWords != nil }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The width it draws whole in.
    var fittingWidth: CGFloat {
        Self.dot + 6 + ColumnHeaderView.textWidth(titleLabel) + 4 + ColumnHeaderView.textWidth(detailLabel) + (hasLink ? Self.linkRoom : 0)
    }

    /// Amber while an agent of its task needs the user: never hidden.
    var dotColor: NSColor { pullRequest.needsYou ? Theme.Color.waiting : Theme.Color.done }

    override func layout() {
        super.layout()
        let titleX = Self.dot + 6
        let whole = ColumnHeaderView.textWidth(titleLabel)
        // The number and the time give way last. The link shows whole or
        // not at all, and only while the title keeps some of itself.
        let detailWidth = min(ColumnHeaderView.textWidth(detailLabel), max(0, bounds.width - titleX - 4))
        let room = max(0, bounds.width - titleX - 4 - detailWidth)
        let linkWidth = hasLink && room - Self.linkRoom >= min(whole, Self.fewestTitle) ? Self.linkRoom : 0
        let titleWidth = min(whole, room - linkWidth)
        titleLabel.frame = NSRect(x: titleX, y: 1, width: titleWidth, height: 16)
        detailLabel.frame = NSRect(x: titleLabel.frame.maxX + 4, y: 2, width: detailWidth, height: 15)
        linkLabel.frame = NSRect(x: detailLabel.frame.maxX, y: 1, width: linkWidth, height: 16)
        linkLabel.isHidden = linkWidth == 0
        // The entry takes the mouse for its words. A title that is cut
        // shows whole under the pointer, wherever on the entry but on a
        // link, which says what its click does.
        var hints: [(rect: NSRect, text: String)] = []
        let link = offersCleanUp ? linkRect : nil
        if titleWidth < whole {
            hints.append((NSRect(x: 0, y: 0, width: link?.minX ?? bounds.width, height: bounds.height), pullRequest.title))
        }
        if let link { hints.append((link, BoardStages.Link.cleanUp.hint)) }
        toolTips.show(hints, on: self)
        if handRects != registeredHandRects { window?.invalidateCursorRects(for: self) }
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
        toolTips.text(at: point)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        toolTipText(at: point) ?? ""
    }

    /// A hand on the link, as far as the entry is in sight.
    var handRects: [NSRect] {
        guard offersCleanUp, let rect = linkRect?.intersection(rectInSight), !rect.isEmpty else { return [] }
        return [rect]
    }

    override func resetCursorRects() {
        registeredHandRects = handRects
        for rect in registeredHandRects { addCursorRect(rect, cursor: .pointingHand) }
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

    /// The entry is listed, and shows, where VoiceOver may reach it
    /// scrolled away: not one gone behind "+12 more", nor one that left
    /// the list.
    private var isShown: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

    /// The click is the mouse going up on what it went down on, as that
    /// still is, where the entry is in sight: not one gone behind "+12
    /// more", nor one that left the list.
    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let pressed, rectInSight.contains(point), target(at: point) == pressed else { return }
        switch pressed {
        case .entry: onClick?()
        case .cleanUp: onCleanUp?()
        }
    }

    /// As a click: only on an entry that shows.
    override func accessibilityPerformPress() -> Bool {
        guard pullRequest.lineID != nil, isShown else { return false }
        onClick?()
        return true
    }

    /// "Clean up" by name, and as a click: only while it is offered, on
    /// an entry that shows.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard offersCleanUp else { return nil }
        return [NSAccessibilityCustomAction(name: BoardStages.Link.cleanUp.title) { [weak self] in
            guard let self, self.offersCleanUp, self.isShown, let onCleanUp = self.onCleanUp else { return false }
            onCleanUp()
            return true
        }]
    }
}
