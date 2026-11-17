import AppKit

/// Space Settings › Safety: what the space's Claude Code sessions get with
/// `--settings` (ClaudeSpaceSettings), each part on its own switch, saved
/// at once in defaults.json. The shell writes and sends the new state back
/// with `update(_:)`.
@MainActor
final class SpaceSettingsSafetyPane: NSObject {
    struct Model: Equatable {
        var on: Set<ClaudeSpaceSettings.Part> = Set(ClaudeSpaceSettings.Part.allCases.filter(\.isOnByDefault))
        var repositories: [ClaudeSpaceSettings.Repository] = []
        /// False while the space's defaults.json can't be written.
        var canChange = true
    }

    struct Actions {
        var set: @MainActor (ClaudeSpaceSettings.Part, Bool) -> Void = { _, _ in }
    }

    static let width: CGFloat = 680
    private static let insets = NSEdgeInsets(top: 20, left: 28, bottom: 24, right: 28)
    private static var textWidth: CGFloat { width - insets.left - insets.right - 60 }

    let view = NSView()
    private(set) var switches: [ClaudeSpaceSettings.Part: NSSwitch] = [:]
    let repositoriesLabel = SpaceSettingsSafetyPane.detailLabel()

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
        for (part, control) in switches {
            control.state = model.on.contains(part) ? .on : .off
            control.isEnabled = model.canChange
        }
        repositoriesLabel.stringValue = model.repositories.isEmpty
            ? "This space has no repository yet: add one in General."
            : model.repositories.map(Self.line).joined(separator: "\n")
    }

    /// "github.com/owner/name · ~/Projects/name", or the path alone.
    static func line(_ repository: ClaudeSpaceSettings.Repository) -> String {
        (repository.remotes + [repository.path.abbreviatedPath()]).joined(separator: " · ")
    }

    @objc func switchChanged(_ sender: NSSwitch) {
        guard let part = switches.first(where: { $0.value === sender })?.key else { return }
        let wanted = sender.state == .on
        // What the file holds comes back with `update`.
        sender.state = model.on.contains(part) ? .on : .off
        guard wanted != model.on.contains(part), model.canChange else { return }
        actions.set(part, wanted)
    }

    // MARK: - Construction

    private static func title(_ part: ClaudeSpaceSettings.Part) -> String {
        switch part {
        case .trustRepositories: return "Trust this space’s repositories in auto mode"
        case .denyIrreversible: return "Refuse what can’t be undone"
        case .sandbox: return "Run commands in Claude Code’s sandbox"
        }
    }

    private static func hint(_ part: ClaudeSpaceSettings.Part) -> String {
        switch part {
        case .trustRepositories:
            return "Auto mode is told they are yours, so pushing a branch or opening a pull request there isn’t held up."
        case .denyIrreversible:
            return "Refused in every permission mode, bypass included, even inside a longer command line: "
                + ".env files, ~/.ssh, and git commands that lose work."
        case .sandbox:
            return "Limits network access and writes outside the working folder: builds that fetch packages "
                + "or write caches may fail."
        }
    }

    private func build() {
        view.translatesAutoresizingMaskIntoConstraints = false
        var rows: [NSView] = []
        var widths: [NSLayoutConstraint] = []
        for part in ClaudeSpaceSettings.Part.allCases {
            let control = NSSwitch()
            control.target = self
            control.action = #selector(switchChanged(_:))
            control.setAccessibilityLabel(Self.title(part))
            control.setAccessibilityHelp(Self.hint(part))
            switches[part] = control
            let title = NSTextField(labelWithString: Self.title(part))
            title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            title.setAccessibilityElement(false)
            let hint = Self.secondaryLabel(Self.hint(part))
            var texts: [NSView] = [title, hint]
            switch part {
            case .trustRepositories: texts.append(repositoriesLabel)
            case .denyIrreversible:
                texts.append(Self.detailLabel(ClaudeSpaceSettings.denyRuleGroups.map { $0.joined(separator: "  ") }.joined(separator: "\n")))
            case .sandbox: break
            }
            widths += texts.compactMap { ($0 as? NSTextField).map { $0.widthAnchor.constraint(lessThanOrEqualToConstant: Self.textWidth) } }
            let column = NSStackView(views: texts)
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 4
            column.setCustomSpacing(8, after: hint)
            let row = NSStackView(views: [control, column])
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = 12
            rows.append(row)
        }
        let footer = Self.secondaryLabel(
            "Passed with --settings to the space’s Claude Code sessions as they start, on top of your own Claude Code "
                + "settings, which Nirux leaves as they are. Codex, Gemini CLI and OpenCode don’t read them."
        )
        footer.preferredMaxLayoutWidth = Self.width - Self.insets.left - Self.insets.right
        rows.append(footer)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.setCustomSpacing(24, after: rows[rows.count - 2])
        stack.edgeInsets = Self.insets
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate(widths + [
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: Self.width)
        ])
    }

    private static func secondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.preferredMaxLayoutWidth = textWidth
        return label
    }

    /// Exact values (rules, repositories), selectable to copy.
    private static func detailLabel(_ text: String = "") -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = textWidth
        return label
    }
}
