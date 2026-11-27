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
        var startsMergeQueue = false
        var startsMergeQueueWithoutLocalReview = false
        var agent = CodingAgent.claude
        /// "Daily pass" (`SpaceDefaults.leadDailyPass`) and the hour it is
        /// due after.
        var dailyPass = true
        var dailyPassHour = DailyPass.defaultHour
        /// "Review checklist" (`SpaceDefaults.reviewChecklist`).
        var reviewChecklist = true
        /// "Group task results" (`SpaceDefaults.leadGroupsResults`).
        var groupsResults = true
        /// "Fresh start after an idle hour" (`SpaceDefaults.leadFreshStart`).
        var freshStart = true
        /// "Day plan (preview)" (`SpaceDefaults.dayPlan`).
        var dayPlan = false
        /// "Last pass: …", nil before the first.
        var lastPass: String?
        /// False while the space's defaults.json can't be written.
        var canChangeDefaults = true
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
        var setAgent: @MainActor (CodingAgent) -> Void = { _ in }
        var restartLead: @MainActor () -> Void = {}
        var setStartsTasks: @MainActor (Bool) -> Void = { _ in }
        var setStartsMergeQueue: @MainActor (Bool) -> Void = { _ in }
        var setStartsMergeQueueWithoutLocalReview: @MainActor (Bool) -> Void = { _ in }
        var setDailyPass: @MainActor (Bool) -> Void = { _ in }
        var setDailyPassHour: @MainActor (Int) -> Void = { _ in }
        var setReviewChecklist: @MainActor (Bool) -> Void = { _ in }
        var setGroupsResults: @MainActor (Bool) -> Void = { _ in }
        var setFreshStart: @MainActor (Bool) -> Void = { _ in }
        var setDayPlan: @MainActor (Bool) -> Void = { _ in }
    }

    static let width: CGFloat = 680
    private static let insets = NSEdgeInsets(top: 20, left: 28, bottom: 24, right: 28)
    private static var contentWidth: CGFloat { width - insets.left - insets.right }
    /// What the Lead never does alone, and how it reaches the user instead.
    static let alwaysYours: [(what: String, how: String)] = [
        ("Removing a worktree or a branch", "your click in Clean Up"),
        ("A task’s permission prompt it can’t judge", "sent to you, in amber")
    ]

    let view = NSView()
    let leadSwitch = NSSwitch()
    let titleLabel = NSTextField(labelWithString: "Lead workspace")
    let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    let restartButton = NSButton(title: NiruxShellView.restartLeadTitle, target: nil, action: nil)
    let agentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let agentRow = NSStackView()
    let startsTasksSwitch = NSSwitch()
    private let startsTasksRow = NSStackView()
    let startsMergeQueueSwitch = NSSwitch()
    private let startsMergeQueueRow = NSStackView()
    let startsMergeQueueWithoutLocalReviewSwitch = NSSwitch()
    private let startsMergeQueueWithoutLocalReviewRow = NSStackView()
    private let mergeQueueSection = NSStackView()
    let manualMergeRow = alwaysRow("Merging a pull request", "your click in the merge queue")
    let dailyPassSwitch = NSSwitch()
    let dailyPassHourPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let lastPassLabel = NSTextField(labelWithString: "")
    private let dailyPassRow = NSStackView()
    let reviewChecklistSwitch = NSSwitch()
    private let reviewChecklistRow = NSStackView()
    let groupResultsSwitch = NSSwitch()
    private let groupResultsRow = NSStackView()
    let freshStartSwitch = NSSwitch()
    private let freshStartRow = NSStackView()
    let dayPlanSwitch = NSSwitch()
    private let dayPlanRow = NSStackView()
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
        agentPopup.selectItem(withTitle: model.agent.productName)
        agentRow.isHidden = model.isGeneral
        agentPopup.isEnabled = model.canChangeDefaults
        restartButton.isHidden = !model.hasLead
        startsTasksSwitch.state = model.startsTasks ? .on : .off
        startsTasksSwitch.isEnabled = model.canChangeDefaults
        startsTasksRow.isHidden = model.isGeneral
        startsMergeQueueSwitch.state = model.startsMergeQueue ? .on : .off
        startsMergeQueueSwitch.isEnabled = model.canChangeDefaults
        startsMergeQueueWithoutLocalReviewSwitch.state = model.startsMergeQueueWithoutLocalReview ? .on : .off
        startsMergeQueueWithoutLocalReviewSwitch.isEnabled = model.canChangeDefaults && model.startsMergeQueue
        mergeQueueSection.isHidden = model.isGeneral
        manualMergeRow.isHidden = model.startsMergeQueue
        dailyPassSwitch.state = model.dailyPass ? .on : .off
        dailyPassSwitch.isEnabled = model.canChangeDefaults
        dailyPassHourPopup.selectItem(at: model.dailyPassHour)
        dailyPassHourPopup.isEnabled = model.canChangeDefaults && model.dailyPass
        lastPassLabel.stringValue = model.lastPass ?? "No pass yet."
        dailyPassRow.isHidden = model.isGeneral
        reviewChecklistSwitch.state = model.reviewChecklist ? .on : .off
        reviewChecklistSwitch.isEnabled = model.canChangeDefaults
        reviewChecklistRow.isHidden = model.isGeneral
        groupResultsSwitch.state = model.groupsResults ? .on : .off
        groupResultsSwitch.isEnabled = model.canChangeDefaults
        groupResultsRow.isHidden = model.isGeneral
        freshStartSwitch.state = model.freshStart ? .on : .off
        freshStartSwitch.isEnabled = model.canChangeDefaults
        freshStartRow.isHidden = model.isGeneral
        dayPlanSwitch.state = model.dayPlan ? .on : .off
        dayPlanSwitch.isEnabled = model.canChangeDefaults
        dayPlanRow.isHidden = model.isGeneral
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
        var text = "A workspace pinned at the top, \(at), with the Lead agent and the Board. You talk to it; it starts "
            + "tasks and follows them."
        if let spaceName { text += " It works on \(spaceName) only." }
        if let advice { text += " " + advice }
        return text
    }

    @objc func agentChanged(_ sender: NSPopUpButton) {
        let agent = CodingAgent.launchable[safe: sender.indexOfSelectedItem]
        sender.selectItem(withTitle: model.agent.productName)
        guard !model.isGeneral, model.canChangeDefaults, let agent, agent != model.agent else { return }
        actions.setAgent(agent)
    }

    @objc func startsTasksChanged(_ sender: NSSwitch) {
        let wanted = sender.state == .on
        // What the file holds comes back with `update`.
        sender.state = model.startsTasks ? .on : .off
        guard wanted != model.startsTasks, model.canChangeDefaults else { return }
        actions.setStartsTasks(wanted)
    }

    @objc func groupResultsChanged(_ sender: NSSwitch) {
        let wanted = sender.state == .on
        sender.state = model.groupsResults ? .on : .off
        guard !model.isGeneral, model.canChangeDefaults, wanted != model.groupsResults else { return }
        actions.setGroupsResults(wanted)
    }

    @objc func dayPlanChanged(_ sender: NSSwitch) {
        let wanted = sender.state == .on
        sender.state = model.dayPlan ? .on : .off
        guard !model.isGeneral, model.canChangeDefaults, wanted != model.dayPlan else { return }
        actions.setDayPlan(wanted)
    }

    @objc func freshStartChanged(_ sender: NSSwitch) {
        let wanted = sender.state == .on
        sender.state = model.freshStart ? .on : .off
        guard !model.isGeneral, model.canChangeDefaults, wanted != model.freshStart else { return }
        actions.setFreshStart(wanted)
    }

    @objc func startsMergeQueueChanged(_ sender: NSSwitch) {
        let wanted = sender.state == .on
        sender.state = model.startsMergeQueue ? .on : .off
        guard !model.isGeneral, model.canChangeDefaults, wanted != model.startsMergeQueue else { return }
        actions.setStartsMergeQueue(wanted)
    }

    @objc func startsMergeQueueWithoutLocalReviewChanged(_ sender: NSSwitch) {
        let wanted = sender.state == .on
        sender.state = model.startsMergeQueueWithoutLocalReview ? .on : .off
        guard !model.isGeneral, model.canChangeDefaults, model.startsMergeQueue,
              wanted != model.startsMergeQueueWithoutLocalReview else { return }
        actions.setStartsMergeQueueWithoutLocalReview(wanted)
    }

    @objc func dailyPassChanged(_ sender: NSSwitch) {
        let wanted = sender.state == .on
        // What the file holds comes back with `update`.
        sender.state = model.dailyPass ? .on : .off
        guard wanted != model.dailyPass, model.canChangeDefaults else { return }
        actions.setDailyPass(wanted)
    }

    @objc func reviewChecklistChanged(_ sender: NSSwitch) {
        let wanted = sender.state == .on
        sender.state = model.reviewChecklist ? .on : .off
        guard !model.isGeneral, model.canChangeDefaults, wanted != model.reviewChecklist else { return }
        actions.setReviewChecklist(wanted)
    }

    @objc func dailyPassHourChanged(_ sender: NSPopUpButton) {
        let hour = sender.indexOfSelectedItem
        sender.selectItem(at: model.dailyPassHour)
        guard (0...23).contains(hour), hour != model.dailyPassHour, model.canChangeDefaults else { return }
        actions.setDailyPassHour(hour)
    }

    @objc func restartClicked(_ sender: NSButton) {
        actions.restartLead()
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

        restartButton.bezelStyle = .rounded
        restartButton.controlSize = .small
        restartButton.target = self
        restartButton.action = #selector(restartClicked(_:))
        restartButton.toolTip = "End the Lead’s current session and start a fresh conversation with the space’s launch options"
        let texts = NSStackView(views: [titleLabel, descriptionLabel, restartButton])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 3
        let switchRow = NSStackView(views: [leadSwitch, texts])
        switchRow.orientation = .horizontal
        switchRow.alignment = .top
        switchRow.spacing = 12

        buildSwitchRow(startsTasksRow, control: startsTasksSwitch, action: #selector(startsTasksChanged(_:)),
                       title: "Starts tasks without asking", hint: "Off: it proposes each task and you click Start in a sheet like ⌘N.")
        buildSwitchRow(startsMergeQueueRow, control: startsMergeQueueSwitch, action: #selector(startsMergeQueueChanged(_:)),
                       title: "Allow Lead to start the merge queue",
                       hint: "The Lead can start a queue when every check passes. Workflow changes, conflicts and dry-run builds still need your review and confirmation.")
        buildSwitchRow(startsMergeQueueWithoutLocalReviewRow, control: startsMergeQueueWithoutLocalReviewSwitch,
                       action: #selector(startsMergeQueueWithoutLocalReviewChanged(_:)),
                       title: "Allow without local code review",
                       hint: "Skip the local /code-review requirement for Lead auto-start. GitHub checks, mergeability, workflow safety and post-merge health still apply.",
                       indent: 28)
        mergeQueueSection.setViews([startsMergeQueueRow, startsMergeQueueWithoutLocalReviewRow], in: .leading)
        mergeQueueSection.orientation = .vertical
        mergeQueueSection.alignment = .leading
        mergeQueueSection.spacing = 10
        buildDailyPassRow()
        buildSwitchRow(reviewChecklistRow, control: reviewChecklistSwitch, action: #selector(reviewChecklistChanged(_:)),
                       title: "Review checklist",
                       hint: "Each /code-review or /premortem gets, as its reviewer starts, the kinds of finding the Lead "
                           + "recorded in two tasks or more over the last 30 days, with their pull requests. Claude Code only.")
        buildSwitchRow(groupResultsRow, control: groupResultsSwitch, action: #selector(groupResultsChanged(_:)),
                       title: "Group task results",
                       hint: "Results its tasks report within 3 minutes reach the Lead together, in one message: it wakes once "
                           + "for them. Questions never wait.")
        buildSwitchRow(freshStartRow, control: freshStartSwitch, action: #selector(freshStartChanged(_:)),
                       title: "Fresh start after an idle hour",
                       hint: "With 200k of context or more, a Claude Lead idle for an hour starts a new conversation: "
                           + "its next message would write the whole context again. Its tasks, questions and brief stay.")
        buildSwitchRow(dayPlanRow, control: dayPlanSwitch, action: #selector(dayPlanChanged(_:)),
                       title: "Day plan (preview)",
                       hint: "The day planned with the Lead: in the sidebar, features that fold, to-dos, the Lead's lines and "
                           + "planned sessions; in the title bar, the Lead's island, where Done checks a to-do. Still being built: "
                           + "nothing else is edited yet. Agents running now get its tools "
                           + "when they next start.")
        agentPopup.addItems(withTitles: CodingAgent.launchable.map(\.productName))
        agentPopup.target = self
        agentPopup.action = #selector(agentChanged(_:))
        agentPopup.setAccessibilityLabel("Lead agent")
        agentPopup.toolTip = "Default agent when the Lead is stopped"
        agentRow.setViews([NSTextField(labelWithString: "Agent"), agentPopup], in: .leading)
        let switches = NSStackView(views: [
            switchRow, agentRow, startsTasksRow, mergeQueueSection, dailyPassRow, reviewChecklistRow, freshStartRow, groupResultsRow,
            dayPlanRow
        ])
        switches.orientation = .vertical
        switches.alignment = .leading
        switches.spacing = 16

        let header = NSTextField(labelWithString: "Always needs you")
        header.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        alwaysSection.orientation = .vertical
        alwaysSection.alignment = .leading
        alwaysSection.spacing = 8
        alwaysSection.addArrangedSubview(header)
        alwaysSection.addArrangedSubview(manualMergeRow)
        for item in Self.alwaysYours {
            alwaysSection.addArrangedSubview(Self.alwaysRow(item.what, item.how))
        }
        let hint = NSTextField(wrappingLabelWithString: "The Lead is told to leave these to you. Its own commands "
            + "follow the selected agent’s permissions.")
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

    private func buildSwitchRow(
        _ row: NSStackView, control: NSSwitch, action: Selector, title: String, hint: String, indent: CGFloat = 0
    ) {
        control.target = self
        control.action = action
        control.setAccessibilityLabel(title)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.setAccessibilityElement(false)
        let hintLabel = NSTextField(wrappingLabelWithString: hint)
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.preferredMaxLayoutWidth = Self.contentWidth - 60 - indent
        hintLabel.isSelectable = false
        hintLabel.setAccessibilityElement(false)
        control.setAccessibilityHelp(hintLabel.stringValue)
        let labels = NSStackView(views: [titleLabel, hintLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        row.setViews([control, labels], in: .leading)
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        if indent > 0 { row.edgeInsets = NSEdgeInsets(top: 0, left: indent, bottom: 0, right: 0) }
    }

    /// "Daily pass", its hour, and when the last one ran.
    private func buildDailyPassRow() {
        dailyPassSwitch.target = self
        dailyPassSwitch.action = #selector(dailyPassChanged(_:))
        dailyPassSwitch.setAccessibilityLabel("Daily pass")
        let title = NSTextField(labelWithString: "Daily pass")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        title.setAccessibilityElement(false)
        let hint = NSTextField(wrappingLabelWithString: "Once a day, once the Lead and you are idle, it reads the space’s day "
            + "and proposes the rules that would have spared its friction. Nothing reaches the brief without you.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.isSelectable = false
        hint.preferredMaxLayoutWidth = Self.contentWidth - 60
        hint.setAccessibilityElement(false)
        dailyPassSwitch.setAccessibilityHelp(hint.stringValue)
        dailyPassHourPopup.addItems(withTitles: (0...23).map { String(format: "%02d:00", $0) })
        dailyPassHourPopup.controlSize = .small
        dailyPassHourPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        dailyPassHourPopup.target = self
        dailyPassHourPopup.action = #selector(dailyPassHourChanged(_:))
        dailyPassHourPopup.setAccessibilityLabel("Daily pass after")
        let after = NSTextField(labelWithString: "After")
        after.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        after.textColor = .secondaryLabelColor
        after.setAccessibilityElement(false)
        lastPassLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        lastPassLabel.textColor = .secondaryLabelColor
        lastPassLabel.lineBreakMode = .byTruncatingTail
        let hour = NSStackView(views: [after, dailyPassHourPopup, lastPassLabel])
        hour.orientation = .horizontal
        hour.alignment = .firstBaseline
        hour.spacing = 6
        let texts = NSStackView(views: [title, hint, hour])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 3
        dailyPassRow.setViews([dailyPassSwitch, texts], in: .leading)
        dailyPassRow.orientation = .horizontal
        dailyPassRow.alignment = .top
        dailyPassRow.spacing = 12
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
