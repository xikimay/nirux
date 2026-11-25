import AppKit

/// The title bar limit's popover: every plan limit Nirux knows, each with
/// its meter, pace and reset; Antigravity's, which agy doesn't publish; the
/// tasks spending Claude's session, each with what its row offers; when the
/// latest reading came; and the Usage window.
final class QuotaPopoverViewController: NSViewController {
    static let width: CGFloat = 320

    var onShowUsage: (() -> Void)?
    /// A burning task's action, by its task ID.
    var onBurnAction: ((String, QuotaBurnRow.Action) -> Void)?
    private let stack = NSStackView()
    /// What the rows last said: the same words keep the same views, so
    /// VoiceOver's place and a click in progress survive an update.
    private var shown: [String] = []
    private var burnActions: [(String, QuotaBurnRow.Action)] = []

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

    func update(limits: [QuotaLimit], burn: [QuotaBurnRow] = [], now: TimeInterval, calendar: Calendar) {
        loadViewIfNeeded()
        let ordered = limits.sorted { ($0.agent == .claude ? 0 : 1, $0.length) < ($1.agent == .claude ? 0 : 1, $1.length) }
        let words = ordered.map { "\(UsageText.longName(of: $0)) \(Int($0.latest.usedPercent.rounded())) \(UsageText.detail($0, now: now, calendar: calendar).text)" }
            + [limits.map(\.latest.time).max().map { ClaudeUsageLimits.clockText($0, now: now, calendar: calendar) } ?? ""]
            + burn.map { String(describing: $0) }
        guard words != shown || stack.arrangedSubviews.isEmpty else { return }
        shown = words
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        burnActions = []
        for limit in ordered { stack.addArrangedSubview(row(limit, now: now, calendar: calendar)) }
        stack.addArrangedSubview(textRow(
            "Antigravity", value: "—",
            detail: "Not published: agy shows its quota only in its own /usage.", detailColor: Theme.Color.textTertiary
        ))
        if !burn.isEmpty {
            let heading = label("What spends your session · last 30 min", font: Theme.Font.captionEmphasized, color: Theme.Color.textSecondary)
            stack.addArrangedSubview(heading)
            for row in burn { stack.addArrangedSubview(burnRow(row)) }
        }
        stack.addArrangedSubview(footer(readAt: limits.map(\.latest.time).max(), now: now, calendar: calendar))
    }

    /// Its estimated points of the 5-hour window when calibrated, else its
    /// share of the spend; a bar of its share; why; its actions.
    private func burnRow(_ row: QuotaBurnRow) -> NSView {
        let view = textRow(row.title, value: burnValue(row), detail: row.cause ?? "", detailColor: Theme.Color.textSecondary)
        view.toolTip = "\(Int((row.share * 100).rounded()))% of Claude’s spend over 30 minutes: \(UsageText.tokens(row.tokens)) tokens "
            + UsageText.unitNote + (row.points == nil ? "" : ". Points of the 5-hour window are estimated from its readings.")
        let bar = QuotaShareBar()
        bar.share = row.share
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.insertArrangedSubview(bar, at: 1)
        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: QuotaMeterView.barHeight),
            bar.widthAnchor.constraint(equalTo: view.widthAnchor)
        ])
        if row.cause == nil { view.arrangedSubviews.last?.removeFromSuperview() }
        guard !row.actions.isEmpty else { return view }
        let buttons = row.actions.enumerated().map { offset, action in
            let button = NiruxButton(
                title: action.title, kind: offset == 0 ? .primary : .secondary, size: .small, target: self, action: #selector(takeBurnAction(_:))
            )
            button.tag = burnActions.count
            burnActions.append((row.workspaceID, action))
            return button
        }
        view.addArrangedSubview(NSStackView(views: buttons))
        return view
    }

    private func burnValue(_ row: QuotaBurnRow) -> String {
        row.points.map { "≈ \(max(1, Int($0.rounded())))%" } ?? "\(Int((row.share * 100).rounded()))% of it"
    }

    @objc private func takeBurnAction(_ sender: NSButton) {
        guard let (workspaceID, action) = burnActions[safe: sender.tag] else { return }
        onBurnAction?(workspaceID, action)
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
