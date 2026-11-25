import AppKit

/// The title bar limit's popover: every plan limit Nirux knows, each with
/// its meter, pace and reset; Antigravity's, which agy doesn't publish; when
/// the latest reading came; and the Usage window.
final class QuotaPopoverViewController: NSViewController {
    static let width: CGFloat = 320

    var onShowUsage: (() -> Void)?
    private let stack = NSStackView()
    /// What the rows last said: the same words keep the same views, so
    /// VoiceOver's place and a click in progress survive an update.
    private var shown: [String] = []

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.md
        stack.edgeInsets = NSEdgeInsets(top: Theme.Space.md, left: Theme.Space.lg, bottom: Theme.Space.md, right: Theme.Space.lg)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            container.widthAnchor.constraint(equalToConstant: Self.width)
        ])
        view = container
    }

    /// Every label's words, top down.
    var texts: [String] {
        func walk(_ view: NSView) -> [String] {
            if let field = view as? NSTextField { return [field.stringValue] }
            if let button = view as? NSButton { return [button.title] }
            return view.subviews.flatMap(walk)
        }
        return walk(view)
    }

    func update(limits: [QuotaLimit], now: TimeInterval, calendar: Calendar) {
        loadViewIfNeeded()
        let ordered = limits.sorted { ($0.agent == .claude ? 0 : 1, $0.length) < ($1.agent == .claude ? 0 : 1, $1.length) }
        let words = ordered.map { "\(UsageText.longName(of: $0)) \(Int($0.latest.usedPercent.rounded())) \(UsageText.detail($0, now: now, calendar: calendar).text)" }
            + [limits.map(\.latest.time).max().map { ClaudeUsageLimits.clockText($0, now: now, calendar: calendar) } ?? ""]
        guard words != shown || stack.arrangedSubviews.isEmpty else { return }
        shown = words
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for limit in ordered { stack.addArrangedSubview(row(limit, now: now, calendar: calendar)) }
        stack.addArrangedSubview(textRow(
            "Antigravity", value: "—",
            detail: "Not published: agy shows its quota only in its own /usage.", detailColor: Theme.Color.textTertiary
        ))
        stack.addArrangedSubview(footer(readAt: limits.map(\.latest.time).max(), now: now, calendar: calendar))
    }

    private func row(_ limit: QuotaLimit, now: TimeInterval, calendar: Calendar) -> NSView {
        let detail = UsageText.detail(limit, now: now, calendar: calendar)
        let row = textRow(
            UsageText.longName(of: limit), value: "\(Int(limit.latest.usedPercent.rounded()))%",
            detail: detail.text, detailColor: detail.tone == .runsOut ? Theme.Color.error : Theme.Color.textSecondary
        )
        let meter = QuotaMeterView()
        meter.limits = [limit]
        meter.now = now
        meter.translatesAutoresizingMaskIntoConstraints = false
        row.insertArrangedSubview(meter, at: 1)
        NSLayoutConstraint.activate([
            meter.heightAnchor.constraint(equalToConstant: QuotaMeterView.height(rows: 1)),
            meter.widthAnchor.constraint(equalTo: row.widthAnchor)
        ])
        return row
    }

    private func textRow(_ name: String, value: String, detail: String, detailColor: NSColor) -> NSStackView {
        let nameLabel = label(name, font: Theme.Font.caption, color: Theme.Color.textPrimary)
        let valueLabel = label(value, font: Theme.Font.captionDigits, color: Theme.Color.textPrimary)
        valueLabel.alignment = .right
        let top = NSStackView(views: [nameLabel, valueLabel])
        top.distribution = .fill
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = Theme.Font.caption
        detailLabel.textColor = detailColor
        detailLabel.preferredMaxLayoutWidth = Self.width - 2 * Theme.Space.lg
        let row = NSStackView(views: [top, detailLabel])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = Theme.Space.xs
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            top.widthAnchor.constraint(equalToConstant: Self.width - 2 * Theme.Space.lg),
            row.widthAnchor.constraint(equalToConstant: Self.width - 2 * Theme.Space.lg)
        ])
        return row
    }

    private func footer(readAt: TimeInterval?, now: TimeInterval, calendar: Calendar) -> NSView {
        let read = readAt.map { "Last reading at \(ClaudeUsageLimits.clockText($0, now: now, calendar: calendar))" } ?? "No reading yet"
        let note = label(read, font: Theme.Font.caption, color: Theme.Color.textTertiary)
        note.toolTip = "Read from the agents in Nirux. Use elsewhere (claude.ai, another Mac) counts from the next reading."
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let usage = NiruxButton(title: "Usage…", kind: .quiet, size: .small, target: self, action: #selector(showUsage))
        usage.toolTip = "Token usage over the last days (⇧⌘U)"
        let footer = NSStackView(views: [note, usage])
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.widthAnchor.constraint(equalToConstant: Self.width - 2 * Theme.Space.lg).isActive = true
        return footer
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        return label
    }

    @objc private func showUsage() {
        onShowUsage?()
    }
}
