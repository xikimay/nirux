import AppKit

/// Space Settings › Lead (docs/design/spaces.md, "The Lead"): the switch that
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
        /// Where the Lead works, or would start.
        var place: Place
        /// "Starts tasks without asking" (`SpaceDefaults.leadStartsTasks`).
        var startsTasks = true
        /// False while the space's defaults.json can't be written.
        var canChangeStartsTasks = true
    }

    /// Where a Lead works: it starts tasks only from a repository's
    /// checkout.
    enum Place: Equatable {
        /// The main checkout of the space's repository with this name.
        case repository(String)
        /// One of the space's plain folders, by name; `repository`, one of
        /// its repositories, which could be the default instead.
        case folder(String, repository: String?)
        /// The home folder: the space has neither.
        case home
        /// A running Lead's folder that is none of the space's anchors any
        /// more (the repository moved, or was added after it started);
        /// `repository` names the one a new Lead would start in.
        case elsewhere(path: String, repository: String?)
    }

    struct Actions {
        var setLead: @MainActor (Bool) -> Void = { _ in }
        var setStartsTasks: @MainActor (Bool) -> Void = { _ in }
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
    let startsTasksSwitch = NSSwitch()
    private let startsTasksRow = NSStackView()
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
        descriptionLabel.stringValue = model.isGeneral ? Self.generalDescription
            : Self.description(place: model.place, spaceName: model.spaceName)
        leadSwitch.setAccessibilityHelp(descriptionLabel.stringValue)
        startsTasksSwitch.state = model.startsTasks ? .on : .off
        startsTasksSwitch.isEnabled = model.canChangeStartsTasks
        startsTasksRow.isHidden = model.isGeneral
        alwaysSection.isHidden = model.isGeneral
    }

    static let generalDescription = "General has no Lead: it takes the workspaces no other space claims, from every repository."

    /// What a Lead is and where it works; New Space… says the same
    /// (`spaceName` nil: the space has no name yet).
    static func description(place: Place, spaceName: String?) -> String {
        // The sheet adds repositories right above; Space Settings, in General.
        let addOne = "It starts tasks only from a repository" + (spaceName == nil ? "." : ": add one in General.")
        let at: String
        var advice: String?
        switch place {
        case .repository(let name):
            at = "on \(name)’s main checkout"
        case .folder(let name, let repository):
            at = "in \(name)"
            advice = repository.map {
                "It starts tasks only from a repository: make \($0) the default" + (spaceName == nil ? "." : " in General.")
            } ?? addOne
        case .home:
            at = "in your home folder"
            advice = addOne
        case .elsewhere(let path, let repository):
            at = "in \(path.abbreviatedPath())"
            advice = repository.map { "That is none of this space’s repositories: turn it off and on again to move it to \($0)." }
                ?? addOne
        }
        var text = "A workspace pinned at the top, \(at), with Claude and the Board. You talk to it; it starts "
            + "tasks and follows them."
        if let spaceName { text += " It works on \(spaceName) only." }
        if let advice { text += " " + advice }
        return text
    }

    @objc func startsTasksChanged(_ sender: NSSwitch) {
        let wanted = sender.state == .on
        // What the file holds comes back with `update`.
        sender.state = model.startsTasks ? .on : .off
        guard wanted != model.startsTasks, model.canChangeStartsTasks else { return }
        actions.setStartsTasks(wanted)
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

        startsTasksSwitch.target = self
        startsTasksSwitch.action = #selector(startsTasksChanged(_:))
        startsTasksSwitch.setAccessibilityLabel("Starts tasks without asking")
        let startsTitle = NSTextField(labelWithString: "Starts tasks without asking")
        startsTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        startsTitle.setAccessibilityElement(false)
        let startsHint = NSTextField(wrappingLabelWithString: "Off: it proposes each task and you click Start in a sheet like ⌘N.")
        startsHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        startsHint.textColor = .secondaryLabelColor
        startsHint.isSelectable = false
        startsHint.setAccessibilityElement(false)
        startsTasksSwitch.setAccessibilityHelp(startsHint.stringValue)
        let startsTexts = NSStackView(views: [startsTitle, startsHint])
        startsTexts.orientation = .vertical
        startsTexts.alignment = .leading
        startsTexts.spacing = 3
        startsTasksRow.setViews([startsTasksSwitch, startsTexts], in: .leading)
        startsTasksRow.orientation = .horizontal
        startsTasksRow.alignment = .top
        startsTasksRow.spacing = 12
        let switches = NSStackView(views: [switchRow, startsTasksRow])
        switches.orientation = .vertical
        switches.alignment = .leading
        switches.spacing = 16

        let header = NSTextField(labelWithString: "Always needs you")
        header.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        alwaysSection.orientation = .vertical
        alwaysSection.alignment = .leading
        alwaysSection.spacing = 8
        alwaysSection.addArrangedSubview(header)
        for item in Self.alwaysYours {
            alwaysSection.addArrangedSubview(Self.alwaysRow(item.what, item.how))
        }
        let hint = NSTextField(wrappingLabelWithString: "The Lead is told to leave these to you. Its own commands "
            + "follow the space’s Claude permission mode (Defaults tab).")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.isSelectable = false
        hint.preferredMaxLayoutWidth = Self.contentWidth
        alwaysSection.addArrangedSubview(hint)

        let stack = NSStackView(views: [switches, alwaysSection])
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
        // An image view's accessibility element is its cell.
        lock.cell?.setAccessibilityElement(false)
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
