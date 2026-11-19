import AppKit

/// Space Settings › Safety: what the space's Claude Code sessions get with
/// `--settings` (ClaudeSpaceSettings), each part on its own switch, then
/// where the user is still in the loop (LoopRecap) with the lines they can
/// add. Saved at once in defaults.json; the shell writes and sends the new
/// state back with `update(_:)`.
@MainActor
final class SpaceSettingsSafetyPane: NSObject {
    struct Model: Equatable {
        var on: Set<ClaudeSpaceSettings.Part> = Set(ClaudeSpaceSettings.Part.allCases.filter(\.isOnByDefault))
        var repositories: [ClaudeSpaceSettings.Repository] = []
        /// False while the space's defaults.json can't be written.
        var canChange = true
        /// Why defaults.json is used only in part (`SpaceDefaultsStore.Loaded.problem`).
        var problem: String?
        var periodDays = SpaceSettingsSafetyPane.periods[0]
        var recap: [LoopRecap.Group] = []
        /// The log reached its size limit (`SpaceLog.isFull`).
        var logFull = false
        var added: [ClaudeSpaceSettings.Line] = []
    }

    struct Actions {
        var set: @MainActor (ClaudeSpaceSettings.Part, Bool) -> Void = { _, _ in }
        var setPeriod: @MainActor (Int) -> Void = { _ in }
        var add: @MainActor (ClaudeSpaceSettings.Line) -> Void = { _ in }
        var remove: @MainActor (ClaudeSpaceSettings.Line) -> Void = { _ in }
    }

    nonisolated static let periods = [7, 30]
    /// The recap's lists scroll past a few rows: the window can't grow past
    /// a 13-inch screen.
    private static let maxRecapHeight: CGFloat = 170
    private static let maxAddedHeight: CGFloat = 80
    private static var contentWidth: CGFloat { width - insets.left - insets.right }

    static let width: CGFloat = 680
    private static let insets = NSEdgeInsets(top: 20, left: 28, bottom: 24, right: 28)
    private static var textWidth: CGFloat { width - insets.left - insets.right - 60 }

    let view = NSView()
    private(set) var switches: [ClaudeSpaceSettings.Part: NSSwitch] = [:]
    let repositoriesLabel = SpaceSettingsSafetyPane.detailLabel()
    /// The deny rules, in a list that scrolls past `maxRulesHeight`: the
    /// window can't grow past a 13-inch screen.
    let rulesScroll = NSScrollView()
    private static let maxRulesHeight: CGFloat = 112
    let problemLabel = NSTextField(wrappingLabelWithString: "")
    let periodPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let recapSummary = SpaceSettingsSafetyPane.secondaryLabel("")
    private let recapRows = NSStackView()
    let recapScroll = NSScrollView()
    private lazy var recapHeight = recapScroll.heightAnchor.constraint(equalToConstant: 0)
    private let addedRows = NSStackView()
    let addedScroll = NSScrollView()
    private lazy var addedHeight = addedScroll.heightAnchor.constraint(equalToConstant: 0)
    private let addedSection = NSStackView()
    private(set) var addButtons: [ClaudeSpaceSettings.Line: NSButton] = [:]
    private(set) var removeButtons: [ClaudeSpaceSettings.Line: NSButton] = [:]

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
        problemLabel.stringValue = model.problem?.asWarning ?? ""
        problemLabel.isHidden = model.problem == nil
        repositoriesLabel.stringValue = model.repositories.isEmpty
            ? "This space has no repository yet: add one in General."
            : model.repositories.map(Self.line).joined(separator: "\n")
        SettingsForm.select(model.periodDays, in: periodPopup)
        showRecap(model)
    }

    private func showRecap(_ model: Model) {
        let questions = model.recap.filter(\.isQuestion).map(\.count).reduce(0, +)
        let prompts = model.recap.filter { !$0.isQuestion }.map(\.count).reduce(0, +)
        recapSummary.stringValue = prompts + questions == 0
            ? "No permission prompt or question in the last \(model.periodDays) days."
            : "\(Self.counted(prompts, "permission prompt")) and \(Self.counted(questions, "question")) in this space’s "
                + "Claude sessions, by tool and command. A line you add goes into the settings file at the next launch; "
                + "nothing is added on its own."
        if model.logFull {
            recapSummary.stringValue += " The log is full: new prompts aren’t counted until older ones are past 30 days."
        }
        addButtons = [:]
        recapRows.setViews(model.recap.map { groupRow($0, added: model.added) }, in: .top)
        Self.fillWidth(recapRows)
        recapHeight.constant = model.recap.isEmpty ? 0 : min(recapRows.fittingSize.height, Self.maxRecapHeight)
        recapScroll.isHidden = model.recap.isEmpty
        removeButtons = [:]
        addedRows.setViews(model.added.map(addedRow), in: .top)
        Self.fillWidth(addedRows)
        addedHeight.constant = min(addedRows.fittingSize.height, Self.maxAddedHeight)
        addedSection.isHidden = model.added.isEmpty
    }

    static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    static func title(_ group: LoopRecap.Group) -> String {
        group.isQuestion ? "Questions" : group.tool + (group.target.map { " · \($0)" } ?? "")
    }

    /// "allow  Bash(swift build:*)".
    static func shown(_ line: ClaudeSpaceSettings.Line) -> String {
        switch line {
        case .allow(let rule): return "allow  " + rule
        case .environment(let entry): return "environment  " + entry
        }
    }

    private func groupRow(_ group: LoopRecap.Group, added: [ClaudeSpaceSettings.Line]) -> NSView {
        let title = NSTextField(labelWithString: Self.title(group))
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let count = Self.secondaryLabel(Self.counted(group.count, group.isQuestion ? "question" : "prompt"))
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        var views: [NSView] = [title, count, NSView()]
        if let line = group.proposal {
            let text = Self.detailLabel(Self.shown(line))
            text.lineBreakMode = .byTruncatingMiddle
            text.maximumNumberOfLines = 1
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.toolTip = line.text
            let isAdded = added.contains(line)
            let button = NSButton(title: isAdded ? "Added" : "Add", target: self, action: #selector(addClicked(_:)))
            button.controlSize = .small
            button.isEnabled = !isAdded && model.canChange
            button.setAccessibilityLabel("Add \(line.text)")
            addButtons[line] = button
            views += [text, button]
        } else if group.isQuestion || group.count >= LoopRecap.minimumPrompts {
            let note = Self.secondaryLabel(group.isQuestion ? "Claude asking you: nothing to allow" : "Nothing proposed: Nirux can’t tell it’s safe")
            note.textColor = .tertiaryLabelColor
            views.append(note)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    private func addedRow(_ line: ClaudeSpaceSettings.Line) -> NSView {
        let text = Self.detailLabel(Self.shown(line))
        text.lineBreakMode = .byTruncatingMiddle
        text.maximumNumberOfLines = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let button = NSButton(title: "Remove", target: self, action: #selector(removeClicked(_:)))
        button.controlSize = .small
        button.isEnabled = model.canChange
        button.setAccessibilityLabel("Remove \(line.text)")
        removeButtons[line] = button
        let row = NSStackView(views: [text, NSView(), button])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        return row
    }

    @objc func addClicked(_ sender: NSButton) {
        guard let line = addButtons.first(where: { $0.value === sender })?.key, model.canChange else { return }
        actions.add(line)
    }

    @objc func removeClicked(_ sender: NSButton) {
        guard let line = removeButtons.first(where: { $0.value === sender })?.key, model.canChange else { return }
        actions.remove(line)
    }

    @objc func periodChanged(_ sender: NSPopUpButton) {
        guard let days = sender.selectedItem?.representedObject as? Int, days != model.periodDays else { return }
        actions.setPeriod(days)
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
            return "Their common forms are refused in every permission mode, bypass included, even inside a longer "
                + "command line: .env files anywhere, ~/.ssh, and git commands that lose work. Shortened git options and "
                + "grouped flags get past them; in auto mode, its own safety check is still behind them."
        case .sandbox:
            return "Limits network access and writes outside the working folder: builds that fetch packages "
                + "or write caches may fail."
        }
    }

    private func build() {
        view.translatesAutoresizingMaskIntoConstraints = false
        problemLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        problemLabel.isSelectable = false
        problemLabel.preferredMaxLayoutWidth = Self.width - Self.insets.left - Self.insets.right
        var rows: [NSView] = [problemLabel]
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
                let lines = NSStackView(views: ClaudeSpaceSettings.denyRuleGroups.map { Self.detailLabel($0.joined(separator: "  ")) })
                lines.orientation = .vertical
                lines.spacing = 2
                let height = min(lines.fittingSize.height, Self.maxRulesHeight)
                Self.scroll(lines, in: rulesScroll, width: Self.textWidth, height: rulesScroll.heightAnchor.constraint(equalToConstant: height))
                texts.append(rulesScroll)
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
        rows.append(recapSection())
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

    private func recapSection() -> NSView {
        let title = NSTextField(labelWithString: "Where you’re still in the loop")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        for days in Self.periods {
            periodPopup.addItem(withTitle: "Last \(days) days")
            periodPopup.lastItem?.representedObject = days
        }
        periodPopup.controlSize = .small
        periodPopup.target = self
        periodPopup.action = #selector(periodChanged(_:))
        periodPopup.setAccessibilityLabel("Period")
        let head = NSStackView(views: [title, NSView(), periodPopup])
        head.orientation = .horizontal
        head.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        recapSummary.preferredMaxLayoutWidth = Self.contentWidth
        recapRows.spacing = 8
        addedRows.spacing = 8
        Self.scroll(recapRows, in: recapScroll, width: Self.contentWidth, height: recapHeight)
        Self.scroll(addedRows, in: addedScroll, width: Self.contentWidth, height: addedHeight)
        let header = NSTextField(labelWithString: "Lines you added")
        header.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        addedSection.setViews([header, addedScroll], in: .top)
        addedSection.orientation = .vertical
        addedSection.alignment = .leading
        addedSection.spacing = 8
        let section = NSStackView(views: [head, recapSummary, recapScroll, addedSection])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 10
        section.setCustomSpacing(14, after: recapSummary)
        section.setCustomSpacing(18, after: recapScroll)
        return section
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

extension SpaceSettingsSafetyPane {
    /// `rows` in `scroll`, `width` wide and as tall as `height` says.
    fileprivate static func scroll(_ rows: NSStackView, in scroll: NSScrollView, width: CGFloat, height: NSLayoutConstraint) {
        rows.orientation = .vertical
        rows.alignment = .leading
        fillWidth(rows)
        let document = SafetyFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        rows.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scroll.widthAnchor.constraint(equalToConstant: width),
            height
        ])
    }
}

extension SpaceSettingsSafetyPane {
    /// Each row as wide as the list: the clip's width, whichever scroller
    /// the user's setting shows. Call it again for rows set later.
    fileprivate static func fillWidth(_ rows: NSStackView) {
        for row in rows.arrangedSubviews { row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true }
    }
}

/// A scrolled list's document: rows from the top.
private final class SafetyFlippedView: NSView {
    override var isFlipped: Bool { true }
}
