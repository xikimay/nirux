import AppKit

/// The Lead island (docs/design/plan.md): a glass capsule beside the command bar with the Lead's line now and how
/// many to-dos wait for the user. A press opens its panel (`LeadIslandPanel`).
final class LeadIslandView: NSView {
    struct Content: Equatable {
        /// The Lead's first open line; nil: nothing planned for it.
        var now: String?
        var forYou: Int
    }

    static let maximumWidth: CGFloat = 320
    private static let inset = Theme.Space.md
    private static let gap = Theme.Space.sm
    /// Between the capsule and the command bar.
    private static let margin = Theme.Space.sm

    var onPress: (() -> Void)?

    var level: InterfaceTransparency {
        get { glass.level }
        set { glass.level = newValue }
    }
    var resolveLevel: @MainActor (InterfaceTransparency) -> InterfaceTransparency {
        get { glass.resolveLevel }
        set { glass.resolveLevel = newValue }
    }

    private(set) var content: Content?
    private let glass: GlassView
    let star = NSTextField(labelWithString: "✦")
    let nowLabel = NSTextField(labelWithString: "")
    let forYouLabel = NSTextField(labelWithString: "")
    let button = NiruxButton(title: "", kind: .quiet)

    init(level: InterfaceTransparency) {
        glass = GlassView(role: .chrome, level: level, cornerRadius: CommandBarView.height / 2)
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: CommandBarView.height))
        addSubview(glass)
        star.font = Theme.Font.caption
        star.textColor = Theme.Color.accent
        nowLabel.font = Theme.Font.body
        nowLabel.lineBreakMode = .byTruncatingTail
        forYouLabel.font = Theme.Font.captionDigits
        forYouLabel.textColor = Theme.Color.textSecondary
        for label in [star, nowLabel, forYouLabel] {
            label.setAccessibilityElement(false)
            label.cell?.setAccessibilityElement(false)
            glass.contentView.addSubview(label)
        }
        glass.contentView.addSubview(button)
        button.target = self
        button.action = #selector(pressed)
        button.toolTip = "The Lead's day"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ content: Content) {
        guard content != self.content else { return }
        self.content = content
        nowLabel.stringValue = content.now ?? "Nothing planned for the Lead"
        nowLabel.textColor = content.now == nil ? Theme.Color.textTertiary : Theme.Color.textPrimary
        forYouLabel.stringValue = content.forYou > 0 ? "\(content.forYou) for you" : ""
        button.setAccessibilityLabel((["Lead", nowLabel.stringValue] + (forYouLabel.stringValue.isEmpty ? [] : [forYouLabel.stringValue])).joined(separator: ", "))
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let words = [star, nowLabel, forYouLabel].filter { !$0.stringValue.isEmpty }
        let width = words.reduce(Self.inset * 2) { $0 + ceil($1.attributedStringValue.size().width) + 4 } + Self.gap * CGFloat(words.count - 1)
        return NSSize(width: min(Self.maximumWidth, width + Self.margin), height: CommandBarView.height)
    }

    override func layout() {
        super.layout()
        glass.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - Self.margin), height: bounds.height)
        let height = bounds.height
        let bounds = glass.bounds
        func place(_ label: NSTextField, x: CGFloat, width: CGFloat) {
            let lineHeight = ceil(label.fittingSize.height)
            label.frame = NSRect(x: x, y: (height - lineHeight) / 2, width: max(0, width), height: lineHeight)
        }
        let starWidth = ceil(star.attributedStringValue.size().width) + 4
        let forYouWidth = forYouLabel.stringValue.isEmpty ? 0 : ceil(forYouLabel.attributedStringValue.size().width) + 4
        place(star, x: Self.inset, width: starWidth)
        place(forYouLabel, x: bounds.width - Self.inset - forYouWidth, width: forYouWidth)
        let nowX = Self.inset + starWidth + Self.gap
        place(nowLabel, x: nowX, width: bounds.width - Self.inset - forYouWidth - (forYouWidth > 0 ? Self.gap : 0) - nowX)
        button.frame = bounds.insetBy(dx: Theme.Space.xs, dy: Theme.Space.xs)
    }

    @objc func pressed() { onPress?() }

    /// The capsule, without its gap to the bar.
    var capsuleRect: NSRect { glass.frame }
}

/// The island's panel: the Lead's line now, the user's to-dos with Done, then the Lead's next lines and the planned
/// sessions, each saying what it waits for.
final class LeadIslandPanel: NSViewController {
    static let width: CGFloat = 340

    var onDone: ((String) -> Void)?
    private let island: Plan.Island
    /// The title of the line a planned session waits for, while unchecked.
    private let waitsFor: (String) -> String?

    init(island: Plan.Island, waitsFor: @escaping (String) -> String?) {
        self.island = island
        self.waitsFor = waitsFor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.sm
        stack.edgeInsets = NSEdgeInsets(top: Theme.Space.md, left: Theme.Space.md, bottom: Theme.Space.md, right: Theme.Space.md)
        stack.addArrangedSubview(header("Now · Lead"))
        if let now = island.now {
            stack.addArrangedSubview(row(now, trailing: nil))
        } else {
            stack.addArrangedSubview(SidebarPlanRowRenderer.label("Nothing planned for the Lead", font: Theme.Font.body, color: Theme.Color.textTertiary))
        }
        if !island.forYou.isEmpty {
            stack.addArrangedSubview(header("For you"))
            for todo in island.forYou {
                let done = NiruxButton(title: "Done", kind: .secondary, size: .small)
                done.setAccessibilityLabel("Done: \(todo.title)")
                done.target = self
                done.action = #selector(donePressed(_:))
                done.identifier = NSUserInterfaceItemIdentifier(todo.id)
                stack.addArrangedSubview(row(todo, trailing: done))
            }
        }
        if !island.next.isEmpty {
            stack.addArrangedSubview(header("Next"))
            for line in island.next { stack.addArrangedSubview(row(line, trailing: chip(line.isPlanned ? "planned" : "Lead"))) }
        }
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -Theme.Space.md * 2).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        view = stack
    }

    private func header(_ text: String) -> NSTextField {
        SidebarPlanRowRenderer.label(text, font: Theme.Font.captionEmphasized, color: Theme.Color.textTertiary)
    }

    private func chip(_ text: String) -> SidebarBadgeView {
        let color = text == "Lead" ? Theme.Color.accent : Theme.Color.textTertiary
        let chip = SidebarBadgeView(text: text, textColor: color, fillColor: Theme.Color.tint(color, 0.16), font: Theme.Font.caption)
        chip.cornerRadius = Theme.Radius.card
        chip.widthAnchor.constraint(equalToConstant: ceil(chip.fittingWidth)).isActive = true
        return chip
    }

    private func row(_ line: Plan.Line, trailing: NSView?) -> NSStackView {
        let mark = SidebarPlanMark(kind: line.kind, isChecked: false)
        mark.widthAnchor.constraint(equalToConstant: 12).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 12).isActive = true
        let waits = line.after.flatMap(waitsFor).map { " · after “\($0)”" } ?? ""
        let title = SidebarPlanRowRenderer.label(line.title + waits, font: Theme.Font.body, color: Theme.Color.textPrimary)
        title.toolTip = SidebarPlanRowRenderer.origin(of: line)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [mark, title] + (trailing.map { [$0] } ?? []))
        row.orientation = .horizontal
        row.spacing = Theme.Space.sm
        row.alignment = .centerY
        return row
    }

    @objc private func donePressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onDone?(id)
    }
}
