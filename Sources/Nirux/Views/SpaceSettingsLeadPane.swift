import AppKit

/// Space Settings › Lead (docs/spaces.md, "The Lead"): the switch that
/// starts or stops the space's Lead, where it works, and what it always
/// hands to the user. The switch applies at once; the shell starts or
/// closes the Lead (closing asks first when Claude runs there) and sends
/// the new state back with `update(_:)`.
@MainActor
final class SpaceSettingsLeadPane: NSObject {
    struct Model: Equatable {
        var spaceName: String
        /// General has no Lead.
        var isGeneral: Bool
        var hasLead: Bool
        /// Where the Lead works: its default repository's name, or nil
        /// without one (it opens in the home folder then).
        var repositoryName: String?
    }

    struct Actions {
        var setLead: @MainActor (Bool) -> Void = { _ in }
    }

    static let width: CGFloat = 680
    private static let insets = NSEdgeInsets(top: 20, left: 28, bottom: 24, right: 28)
    private static var contentWidth: CGFloat { width - insets.left - insets.right }
    /// What the Lead never does alone, and how it reaches the user instead.
    static let alwaysYours: [(what: String, how: String)] = [
        ("Merging a pull request", "your click in the merge queue"),
        ("Removing a worktree or a branch", "your click in Clean Up"),
        ("A task’s permission prompt it can’t judge", "sent to you, in amber")
    ]

    let view = NSView()
    let leadSwitch = NSSwitch()
    let titleLabel = NSTextField(labelWithString: "Lead workspace")
    let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let alwaysSection = NSStackView()

    private(set) var model: Model
    var actions = Actions()

    init(model: Model) {
        self.model = model
        super.init()
        build()
        update(model)
    }

    func update(_ model: Model) {
        self.model = model
        leadSwitch.state = model.hasLead ? .on : .off
        leadSwitch.isEnabled = !model.isGeneral
        descriptionLabel.stringValue = Self.description(of: model)
        leadSwitch.setAccessibilityHelp(descriptionLabel.stringValue)
        alwaysSection.isHidden = model.isGeneral
    }

    static func description(of model: Model) -> String {
        guard !model.isGeneral else {
            return "General has no Lead: it takes the workspaces no other space claims, from every repository."
        }
        let place = model.repositoryName.map { "on \($0)’s main checkout" } ?? "in your home folder"
        var text = "A workspace pinned at the top, \(place), with Claude and the Board. You talk to it; it starts "
            + "tasks and follows them. It sees only \(model.spaceName)."
        if model.repositoryName == nil {
            text += " Add a repository in General so it can start tasks."
        }
        return text
    }

    @objc func switchChanged(_ sender: NSSwitch) {
        let wanted = sender.state == .on
        // Back to what holds until the shell says otherwise: closing the
        // Lead may be cancelled.
        sender.state = model.hasLead ? .on : .off
        guard !model.isGeneral, wanted != model.hasLead else { return }
        actions.setLead(wanted)
    }

    // MARK: - Construction

    private func build() {
        view.translatesAutoresizingMaskIntoConstraints = false

        leadSwitch.target = self
        leadSwitch.action = #selector(switchChanged(_:))
        leadSwitch.setAccessibilityLabel("Lead workspace")
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.setAccessibilityElement(false)
        descriptionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.isSelectable = false
        descriptionLabel.setAccessibilityElement(false)
        let textWidth = Self.contentWidth - 60
        descriptionLabel.preferredMaxLayoutWidth = textWidth

        let texts = NSStackView(views: [titleLabel, descriptionLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 3
        let switchRow = NSStackView(views: [leadSwitch, texts])
        switchRow.orientation = .horizontal
        switchRow.alignment = .top
        switchRow.spacing = 12

        let header = NSTextField(labelWithString: "Always needs you")
        header.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        alwaysSection.orientation = .vertical
        alwaysSection.alignment = .leading
        alwaysSection.spacing = 8
        alwaysSection.addArrangedSubview(header)
        for item in Self.alwaysYours {
            alwaysSection.addArrangedSubview(Self.alwaysRow(item.what, item.how))
        }
        let hint = NSTextField(wrappingLabelWithString: "No tool of the Lead merges, removes a worktree or a branch, "
            + "or reaches another space.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.isSelectable = false
        hint.preferredMaxLayoutWidth = Self.contentWidth
        alwaysSection.addArrangedSubview(hint)

        let stack = NSStackView(views: [switchRow, alwaysSection])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.edgeInsets = Self.insets
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: Self.width),
            descriptionLabel.widthAnchor.constraint(equalToConstant: textWidth)
        ])
    }

    /// A lock, what the Lead never does, then how it comes to the user.
    private static func alwaysRow(_ what: String, _ how: String) -> NSView {
        let lock = NSImageView(image: NSImage(systemSymbolName: "lock", accessibilityDescription: nil) ?? NSImage())
        lock.contentTintColor = .secondaryLabelColor
        lock.setAccessibilityElement(false)
        let whatLabel = NSTextField(labelWithString: what)
        let howLabel = NSTextField(labelWithString: how)
        howLabel.textColor = .secondaryLabelColor
        howLabel.alignment = .right
        let row = NSStackView(views: [lock, whatLabel, NSView(), howLabel])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return row
    }
}
