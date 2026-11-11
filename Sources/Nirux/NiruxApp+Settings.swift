import AppKit

// MARK: - Settings window

/// A standard macOS Settings window: one toolbar tab per topic, and every
/// control applies at once — no Save or Cancel. Each change writes only its
/// own setting, so opening Settings, or touching one control, never saves
/// another value nobody chose. A failed write puts the control back.
///
/// It is a panel that doesn't float or hide: like Nirux's other panels, it
/// doesn't keep the app running once the main window closes, and keys typed
/// in it never reach a terminal (isOverlayActive).
extension NiruxApp {
    private static let settingsWriteFailure = "Could not write the settings file. Check the disk and try again."

    @objc func showSettings(_ sender: Any?) {
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let tabs = SettingsTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(settingsTab("General", symbol: "gearshape", generalPane()))
        tabs.addTabViewItem(settingsTab("Agents", symbol: "sparkles", agentsPane()))
        tabs.addTabViewItem(settingsTab("Notifications", symbol: "bell", notificationsPane()))

        // This initializer also titles the window after the tab picked.
        let window = NSPanel(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isFloatingPanel = false
        window.hidesOnDeactivate = false
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.toolbarStyle = .preference
        window.appearance = Theme.appearance
        window.backgroundColor = Theme.Color.base
        window.isReleasedWhenClosed = false
        window.delegate = self
        settingsWindow = window
        tabs.fitWindowToSelectedPane(animated: false)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func settingsTab(_ label: String, symbol: String, _ pane: NSView) -> NSTabViewItem {
        let controller = NSViewController()
        controller.view = pane
        controller.title = label
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }

    // MARK: - Panes

    private func generalPane() -> NSView {
        let keepAwake = SettingsForm.checkbox(
            "Keep Mac awake while agents work or a merge queue runs",
            target: self, action: #selector(settingsKeepAwakeChanged(_:))
        )
        keepAwake.state = NiruxShellView.currentKeepMacAwakeEnabled() ? .on : .off
        settingsKeepAwakeCheckbox = keepAwake

        let resume = SettingsForm.popup(target: self, action: #selector(settingsAgentResumeChanged(_:)))
        for choice in AgentResumeOnLaunch.allCases {
            resume.addItem(withTitle: choice.displayName)
            resume.lastItem?.representedObject = choice.rawValue
        }
        SettingsForm.select(NiruxShellView.currentAgentResumeOnLaunch().rawValue, in: resume)
        settingsAgentResumePopup = resume

        let animations = SettingsForm.checkbox(
            "Animate the interface", target: self, action: #selector(settingsAnimationsChanged(_:))
        )
        animations.state = NiruxShellView.currentAnimatesInterface() ? .on : .off
        settingsAnimationsCheckbox = animations

        let tasksFolder = NSTextField(labelWithString: settingsTasksFolderText())
        tasksFolder.lineBreakMode = .byTruncatingMiddle
        tasksFolder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        settingsTasksFolderLabel = tasksFolder
        let changeTasksFolder = NSButton(title: "Change…", target: self, action: #selector(settingsChangeTasksFolder(_:)))
        changeTasksFolder.bezelStyle = .rounded
        changeTasksFolder.setAccessibilityLabel("Change the folder of tasks without a repository")
        let tasksFolderControl = NSStackView(views: [tasksFolder, changeTasksFolder])
        tasksFolderControl.orientation = .horizontal
        tasksFolderControl.alignment = .firstBaseline
        tasksFolderControl.spacing = 8

        return SettingsForm.pane([
            [
                keepAwake,
                SettingsForm.hint(
                    "Prevents idle sleep while an agent is working or a merge queue runs, until a minute after the "
                        + "last one stops: a queue asleep stops polling GitHub. The display still sleeps, and closing a "
                        + "MacBook's lid still sleeps it (except in clamshell mode).",
                    under: keepAwake
                )
            ],
            [
                animations,
                SettingsForm.hint(
                    "A column's edge breathes in green while its agent works and pulses in amber when it waits for "
                        + "you, and a working task's row runs a line of light. Off, the same colors show without "
                        + "moving, as they do while macOS reduces motion.",
                    under: animations
                )
            ],
            [
                SettingsForm.row("Tasks without a repository", tasksFolderControl),
                SettingsForm.hint(
                    "Each one gets a new folder here, named after it, instead of a worktree. Nirux never deletes "
                        + "these folders."
                )
            ],
            [
                SettingsForm.row("Resume agents on launch", resume),
                SettingsForm.hint(
                    "When Nirux reopens your workspaces, each Claude Code or Codex column resumes once it shows on "
                        + "screen, or when you click Resume (Resume All Agents starts the rest). All at once resumes "
                        + "every agent with the window."
                )
            ]
        ])
    }

    private func agentsPane() -> NSView {
        let claudeMode = SettingsForm.popup(target: self, action: #selector(settingsClaudeLaunchModeChanged(_:)))
        for mode in ClaudeLaunchMode.allCases {
            claudeMode.addItem(withTitle: mode.displayName)
            claudeMode.lastItem?.representedObject = mode.rawValue
        }
        // The mode a launch would actually use, saved or not.
        SettingsForm.select(NiruxShellView.currentClaudeLaunchMode().rawValue, in: claudeMode)
        claudeMode.setAccessibilityLabel("Claude Code launch mode")
        settingsLaunchModePopup = claudeMode

        let noFlicker = SettingsForm.checkbox("No-flicker mode", target: self, action: #selector(settingsNoFlickerChanged(_:)))
        noFlicker.state = Persistence.load()?.settings?.claudeNoFlicker != false ? .on : .off
        settingsNoFlickerCheckbox = noFlicker

        let usageLimits = SettingsForm.checkbox(
            "Show plan usage limits in the title bar", target: self, action: #selector(settingsUsageLimitsChanged(_:))
        )
        usageLimits.state = Self.currentShowClaudeUsageLimits() ? .on : .off
        usageLimits.toolTip = "The 5-hour window and the weekly limit of a Claude Pro or Max plan, with their resets, "
            + "as Claude Code sessions in Nirux report them after each response."
        settingsUsageLimitsCheckbox = usageLimits

        let codexMode = SettingsForm.popup(target: self, action: #selector(settingsCodexLaunchModeChanged(_:)))
        for mode in CodexLaunchMode.allCases {
            codexMode.addItem(withTitle: mode.displayName)
            codexMode.lastItem?.representedObject = mode.rawValue
        }
        SettingsForm.select(NiruxShellView.currentCodexLaunchMode().rawValue, in: codexMode)
        codexMode.setAccessibilityLabel("Codex launch mode")
        settingsCodexLaunchModePopup = codexMode

        let stuck = SettingsForm.popup(target: self, action: #selector(settingsStuckAgentMinutesChanged(_:)))
        let current = NiruxShellView.currentStuckAgentMinutes()
        // A value set outside Settings stays selectable as it is.
        for minutes in Set(NiruxShellView.stuckAgentMinuteChoices + [current]).sorted() {
            stuck.addItem(withTitle: Self.stuckAgentChoiceTitle(minutes: minutes))
            stuck.lastItem?.representedObject = minutes
        }
        SettingsForm.select(current, in: stuck)
        settingsStuckAgentPopup = stuck

        // A tooltip, not a paragraph under it: the pane is as tall as a
        // 13-inch screen allows.
        let circling = SettingsForm.checkbox(
            "Hint when a working agent may be stuck", target: self, action: #selector(settingsCirclingHintChanged(_:))
        )
        circling.state = NiruxShellView.currentCirclingHintEnabled() ? .on : .off
        circling.toolTip = "A working Claude Code task's row says \"Stuck?\" in grey, in place of \"Working\", once 3 "
            + "of its commands ran past their time limit close together, or one command failed 5 times in a row. Counted on "
            + "your Mac from Claude Code's hooks: the agent isn't interrupted, and nothing alerts."
        circling.setAccessibilityHelp(circling.toolTip)
        settingsCirclingHintCheckbox = circling

        return SettingsForm.pane([
            [
                SettingsForm.header("Claude Code"),
                SettingsForm.row("Launch mode", claudeMode),
                noFlicker,
                SettingsForm.hint(
                    "Launch mode: --permission-mode (--dangerously-skip-permissions for Skip all). "
                        + "No-flicker: sets CLAUDE_CODE_NO_FLICKER=1."
                ),
                usageLimits,
                SettingsForm.hint(Self.usageLimitsHint(for: claudeStatusLineStateReader()), under: usageLimits)
            ],
            [
                SettingsForm.header("Codex"),
                SettingsForm.row("Launch mode", codexMode),
                SettingsForm.hint(
                    "Default = no flags; Codex's own config applies. "
                        + "Full Auto = no sandbox, never asks, web search. Workspace Write = sandboxed."
                )
            ],
            [
                SettingsForm.header("Stuck agents"),
                SettingsForm.row("Flag a dialog waiting after", stuck),
                SettingsForm.hint(
                    "A permission or question dialog open this long marks its agent as stuck: "
                        + "a badge on its card and one notification."
                ),
                circling
            ],
            missionsSection(),
            explainSection()
        ])
    }

    /// Branch Review's Explain: the model and effort its runs ask for.
    private func explainSection() -> [NSView] {
        let explain = BranchReview.ExplainSettings.saved()
        let explainModel = SettingsForm.popup(target: self, action: #selector(settingsExplainModelChanged(_:)))
        // A model set outside Settings stays selectable as it is.
        let models = BranchReview.ExplainSettings.models
        for model in models {
            explainModel.addItem(withTitle: BranchReview.ExplainSettings.displayName(of: model))
            explainModel.lastItem?.representedObject = model
        }
        // By its id: a dated id reads as an offered model's name, and a
        // popup keeps one item per title.
        if !models.contains(explain.model) {
            explainModel.addItem(withTitle: explain.model)
            explainModel.lastItem?.representedObject = explain.model
        }
        SettingsForm.select(explain.model, in: explainModel)
        explainModel.setAccessibilityLabel("Branch Review Explain model")
        settingsExplainModelPopup = explainModel

        let explainEffort = SettingsForm.popup(target: self, action: #selector(settingsExplainEffortChanged(_:)))
        for effort in BranchReview.ExplainSettings.efforts {
            explainEffort.addItem(withTitle: BranchReview.ExplainSettings.effortTitle(effort))
            explainEffort.lastItem?.representedObject = effort
        }
        SettingsForm.select(explain.effort, in: explainEffort)
        explainEffort.setAccessibilityLabel("Branch Review Explain effort")
        settingsExplainEffortPopup = explainEffort

        return [
            SettingsForm.header("Branch Review"),
            SettingsForm.row("Explain with", explainModel),
            SettingsForm.row("Effort", explainEffort),
            SettingsForm.hint(
                "Explain runs claude -p, reading a read-only copy of the branch, on the account claude is logged "
                    + "in with. Opus 5.5 at medium found the most in tests, in a minute or two. A higher effort takes "
                    + "longer and costs more: a run stops after 6 minutes or $3 at API prices, which Extra high and "
                    + "Max can reach on a large branch."
            )
        ]
    }

    private func notificationsPane() -> NSView {
        let current = PersistedSettings.effective(Persistence.load()?.settings)
        let onlyAsks = SettingsForm.checkbox(
            "Alert only when Claude asks something", target: self, action: #selector(settingsAlertOnlyWhenClaudeAsksChanged(_:))
        )
        onlyAsks.state = current.alertOnlyWhenClaudeAsks ? .on : .off
        settingsAlertOnlyWhenClaudeAsksCheckbox = onlyAsks
        let turnStatus = SettingsForm.checkbox(
            "Show a one-line status per task", target: self, action: #selector(settingsTurnStatusChanged(_:))
        )
        turnStatus.state = current.showTurnStatus ? .on : .off
        settingsTurnStatusCheckbox = turnStatus
        let catchUp = SettingsForm.checkbox(
            "Show what happened while you were away", target: self, action: #selector(settingsCatchUpChanged(_:))
        )
        catchUp.state = current.showCatchUp ? .on : .off
        settingsCatchUpCheckbox = catchUp
        let flakyCI = SettingsForm.checkbox(
            "Say when a CI failure looks flaky", target: self, action: #selector(settingsTriageCIFailuresChanged(_:))
        )
        flakyCI.state = current.triageCIFailures ? .on : .off
        settingsTriageCIFailuresCheckbox = flakyCI

        return SettingsForm.pane([
            [
                onlyAsks,
                SettingsForm.hint(
                    "When a Claude Code turn ends, Sonnet reads its last message (claude -p, on a Claude "
                        + "subscription only) and Nirux alerts only if it asks you something. When that check "
                        + "can't run, the turn alerts. Codex and other agents alert at every turn end.",
                    under: onlyAsks
                ),
                turnStatus,
                SettingsForm.hint(
                    "When a Claude Code turn ends, Sonnet reads its last message (claude -p, on a Claude "
                        + "subscription only) and writes where the task stands on its row, in a few words. "
                        + "Every turn's last message is sent, including the turns you watch.",
                    under: turnStatus
                ),
                catchUp,
                SettingsForm.hint(
                    "Back after 15 minutes or more away (another app, another macOS account, the screen locked "
                        + "or asleep), a card above the tasks lists those whose turn ended meanwhile. Nothing is sent.",
                    under: catchUp
                ),
                flakyCI,
                SettingsForm.hint(
                    "When a pull request's checks fail, Nirux reads the failed job's log with gh and says \"likely "
                        + "flaky\" when a rerun would probably pass: a job that never ran, a failed download, tests "
                        + "that passed on a rerun before. For failing tests the pull request doesn't edit, Sonnet "
                        + "reads their messages and source (claude -p, on a Claude subscription only, and only when "
                        + "the workspace's Claude Code runs on that account). XCTest and Swift build logs only. "
                        + "Nirux never reruns by itself.",
                    under: flakyCI
                ),
                SettingsForm.hint(
                    "Banners and sounds, shown while Nirux is in the background, follow System Settings › "
                        + "Notifications › Nirux."
                )
            ]
        ])
    }

    /// Missions and sidebar permission answers, which the Lead depends on:
    /// on by default (docs/spaces.md, "The Lead").
    private func missionsSection() -> [NSView] {
        let handoffs = SettingsForm.checkbox("Mission handoffs", target: self, action: #selector(settingsMissionHandoffsChanged(_:)))
        handoffs.state = NiruxShellView.currentMissionHandoffsEnabled() ? .on : .off
        settingsMissionHandoffsCheckbox = handoffs
        let approvals = SettingsForm.checkbox(
            "Answer Claude permissions from the sidebar", target: self, action: #selector(settingsSidebarApprovalsChanged(_:))
        )
        approvals.state = NiruxShellView.currentSidebarApprovalsEnabled() ? .on : .off
        settingsSidebarApprovalsCheckbox = approvals

        return [
            SettingsForm.header("Missions"),
            handoffs,
            SettingsForm.hint(
                "Worktree agents and the agent that started them exchange questions, answers, and results. "
                    + "A space’s Lead and its tasks always do. New terminals pick up changes.",
                under: handoffs
            ),
            approvals,
            SettingsForm.hint(
                "Allow or deny once for columns you are not looking at: short commands, reads, "
                    + "web fetches and searches, shown in full. Never \"always allow\".",
                under: approvals
            )
        ]
    }

    /// What turning the usage limits on does to Claude Code's status line,
    /// or why it can't work with the user's own.
    static func usageLimitsHint(for state: AgentHookInstaller.ClaudeStatusLineState) -> String {
        switch state {
        case .none, .nirux:
            return "Claude Code reports them only to its status line, so Nirux takes that place in sessions it hosts. "
                + "The line stays blank, and Claude Code then hides its \"? for shortcuts\" hint in every session."
        case .foreign:
            return "Claude Code reports them only to its status line, and yours is set in ~/.claude/settings.json: "
                + "Nirux leaves it as it is, so the limits can't show."
        case .unreadable:
            return "Claude Code reports them only to its status line, and ~/.claude/settings.json can't be read: "
                + "Nirux leaves it as it is, so the limits can't show."
        }
    }

    static func stuckAgentChoiceTitle(minutes: Int) -> String {
        switch minutes {
        case 0: return "Never"
        case 1: return "1 minute"
        case 60: return "1 hour"
        default: return minutes % 60 == 0 ? "\(minutes / 60) hours" : "\(minutes) minutes"
        }
    }

    // MARK: - Applying a change

    /// Writes one setting at once. A failed write puts the control back and
    /// says so; nothing else is written.
    @discardableResult
    private func saveSetting(revert: () -> Void, _ update: (inout PersistedSettings) -> Void) -> Bool {
        guard Persistence.updateSettings(liveLayout: shell?.persistedState(), update) else {
            revert()
            showSettingsError(Self.settingsWriteFailure)
            return false
        }
        return true
    }

    /// Built inside the action, after AppKit flipped the checkbox: puts back
    /// the state it had before the click.
    private static func toggledBack(_ checkbox: NSButton) -> () -> Void {
        let saved: NSControl.StateValue = checkbox.state == .on ? .off : .on
        return { checkbox.state = saved }
    }

    @objc func settingsKeepAwakeChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        guard saveSetting(revert: Self.toggledBack(sender), { $0.keepMacAwakeWhileAgentsWork = enabled }) else { return }
        keepAwakeController?.setEnabled(enabled)
    }

    @objc func settingsAnimationsChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        guard saveSetting(revert: Self.toggledBack(sender), { $0.animatesInterface = enabled }) else { return }
        shell?.animatesInterface = enabled
    }

    /// Where tasks without a repository get their folders, home as "~".
    private func settingsTasksFolderText() -> String {
        let folder = shell?.tasksFolder()
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(NewTask.defaultTasksFolderName)
        return (folder as NSString).abbreviatingWithTildeInPath
    }

    /// Picks the folder tasks without a repository get theirs in. Applies to
    /// the next task: those started keep their folders. Never one in a git
    /// repository: its tasks would read as that repository's. A new place
    /// isn't trusted yet: the ⌘N sheet says so again.
    @objc func settingsChangeTasksFolder(_ sender: NSButton) {
        guard let shell else { return }
        shell.sideEffects.chooseFolder("Choose", settingsWindow) { [weak self] path in
            guard let self, let path else { return }
            guard NewTask.isOutsideGit(path) else {
                return self.showSettingsError(
                    "“\((path as NSString).lastPathComponent)” is in a git repository. Pick a folder outside git for tasks without a repository."
                )
            }
            // The default stays the default: made again if it goes.
            let chosen = path == shell.defaultTasksFolder ? nil : path
            guard self.saveSetting(revert: {}, { $0.tasksFolder = chosen; $0.startedFolderTask = false }) else { return }
            self.settingsTasksFolderLabel?.stringValue = self.settingsTasksFolderText()
        }
    }

    /// Read at the next launch. Only a changed choice is written: a value a
    /// newer build saved shows as the default, and picking that keeps it.
    @objc func settingsAgentResumeChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let choice = AgentResumeOnLaunch(rawValue: raw)
        else { return }
        saveSetting(revert: { SettingsForm.select(NiruxShellView.currentAgentResumeOnLaunch().rawValue, in: sender) }) {
            if choice != $0.agentResumeOnLaunch ?? .defaultValue { $0.agentResumeOnLaunch = choice }
        }
    }

    @objc func settingsClaudeLaunchModeChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let mode = ClaudeLaunchMode(rawValue: raw) else { return }
        saveSetting(revert: { SettingsForm.select(NiruxShellView.currentClaudeLaunchMode().rawValue, in: sender) }) {
            $0.claudeLaunchMode = mode
        }
    }

    @objc func settingsNoFlickerChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        saveSetting(revert: Self.toggledBack(sender)) { $0.claudeNoFlicker = enabled }
    }

    /// Installs or takes back Nirux's Claude Code status line, and shows or
    /// hides the indicator (see applyUsageLimits).
    @objc func settingsUsageLimitsChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        guard saveSetting(revert: Self.toggledBack(sender), { $0.showClaudeUsageLimits = enabled }) else { return }
        applyUsageLimits(enabled: enabled)
    }

    @objc func settingsCodexLaunchModeChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let mode = CodexLaunchMode(rawValue: raw) else { return }
        saveSetting(revert: { SettingsForm.select(NiruxShellView.currentCodexLaunchMode().rawValue, in: sender) }) {
            $0.codexLaunchMode = mode
        }
    }

    @objc func settingsStuckAgentMinutesChanged(_ sender: NSPopUpButton) {
        guard let minutes = sender.selectedItem?.representedObject as? Int else { return }
        guard saveSetting(
            revert: { SettingsForm.select(NiruxShellView.currentStuckAgentMinutes(), in: sender) },
            { $0.stuckAgentMinutes = minutes }
        ) else { return }
        shell?.stuckAgentWaitThreshold = NiruxShellView.stuckWaitThreshold(minutes: minutes)
    }

    @objc func settingsCirclingHintChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        guard saveSetting(revert: Self.toggledBack(sender), { $0.agentCirclingHint = enabled }) else { return }
        shell?.circlingHintEnabled = enabled
        shell?.updateSidebar()
    }

    /// Only a changed choice is written, and the default as none: a later
    /// default reaches whoever didn't choose, and a value a newer build
    /// saved, which shows as the default, stays.
    @objc func settingsExplainModelChanged(_ sender: NSPopUpButton) {
        let saved = BranchReview.ExplainSettings.saved()
        guard let model = sender.selectedItem?.representedObject as? String, model != saved.model else { return }
        saveSetting(revert: { SettingsForm.select(saved.model, in: sender) }) {
            $0.explainModel = model == BranchReview.ExplainSettings.defaultModel ? nil : model
        }
    }

    @objc func settingsExplainEffortChanged(_ sender: NSPopUpButton) {
        let saved = BranchReview.ExplainSettings.saved()
        guard let effort = sender.selectedItem?.representedObject as? String, effort != saved.effort else { return }
        saveSetting(revert: { SettingsForm.select(saved.effort, in: sender) }) {
            $0.explainEffort = effort == BranchReview.ExplainSettings.defaultEffort ? nil : effort
        }
    }

    @objc func settingsMissionHandoffsChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        guard saveSetting(revert: Self.toggledBack(sender), { $0.missionHandoffsEnabled = enabled }) else { return }
        shell?.workspaces.forEach { $0.missionHandoffsEnabled = enabled }
        if enabled {
            MissionEventCenter.shared.deliverPendingEvents()
        }
    }

    @objc func settingsSidebarApprovalsChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        guard saveSetting(revert: Self.toggledBack(sender), { $0.sidebarApprovalsEnabled = enabled }) else { return }
        applySidebarApprovals(enabled: enabled)
    }

    /// Turning the option off hands every held request back to its
    /// terminal dialog.
    private func applySidebarApprovals(enabled: Bool) {
        let hooks = AgentHookCenter.shared
        let wasEnabled = hooks.approvalsEnabled
        hooks.applySidebarApprovals(enabled: enabled)
        if wasEnabled, !hooks.approvalsEnabled {
            shell?.releaseAllPermissionApprovals()
            shell?.updateSidebar()
        }
    }

    @objc func settingsAlertOnlyWhenClaudeAsksChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        guard saveSetting(revert: Self.toggledBack(sender), { $0.alertOnlyWhenClaudeAsks = enabled }) else { return }
        AgentHookCenter.shared.turnEndClassifier = Self.turnEndClassifier(enabled: enabled)
        Self.publishAccountMarker(
            readsFinalMessages: AgentHookCenter.shared.readsFinalMessages, triagesCI: Self.currentTriageCIFailures()
        )
    }

    static func currentAlertOnlyWhenClaudeAsks() -> Bool {
        PersistedSettings.effective(Persistence.load()?.settings).alertOnlyWhenClaudeAsks
    }

    @objc func settingsTurnStatusChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        guard saveSetting(revert: Self.toggledBack(sender), { $0.showTurnStatus = enabled }) else { return }
        AgentHookCenter.shared.turnStatusWriter = Self.turnStatusWriter(enabled: enabled)
        Self.publishAccountMarker(
            readsFinalMessages: AgentHookCenter.shared.readsFinalMessages, triagesCI: Self.currentTriageCIFailures()
        )
        shell?.setTurnStatus(enabled: enabled)
    }

    @objc func settingsCatchUpChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        guard saveSetting(revert: Self.toggledBack(sender), { $0.showCatchUp = enabled }) else { return }
        shell?.setCatchUp(enabled: enabled)
    }

    static func currentShowTurnStatus() -> Bool {
        PersistedSettings.effective(Persistence.load()?.settings).showTurnStatus
    }

    @objc func settingsTriageCIFailuresChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        guard saveSetting(revert: Self.toggledBack(sender), { $0.triageCIFailures = enabled }) else { return }
        applyCITriage(enabled: enabled, readsFinalMessages: AgentHookCenter.shared.readsFinalMessages)
    }

    static func currentTriageCIFailures() -> Bool {
        PersistedSettings.effective(Persistence.load()?.settings).triageCIFailures
    }

    /// The triage on or off in the shell, the model's setup checked ahead
    /// of the first failure, and the marker hook receivers read.
    func applyCITriage(enabled: Bool, readsFinalMessages: Bool) {
        shell?.setCITriage(enabled: enabled)
        Self.publishAccountMarker(readsFinalMessages: readsFinalMessages, triagesCI: enabled)
        if enabled { Self.prepareCITriageModel() }
    }

    /// Checks the account the triage's model would run on (`claude
    /// --help`, `claude auth status`, in the background); tests put a
    /// double here, so that turning the option on never runs the real
    /// `claude`.
    static var prepareCITriageModel: () -> Void = { CITriageModel.runner.account.prepare() }

    /// The classifier when the option is on, its setup checked ahead of
    /// the first turn end. The caller then publishes the marker that tells
    /// hook receivers whether to keep final messages.
    static func turnEndClassifier(enabled: Bool) -> (any TurnEndClassifier)? {
        enabled && ProcessInstance.running(pid: getpid()) != nil ? makeTurnEndClassifier() : nil
    }

    /// The status line writer when its option is on, as the classifier.
    static func turnStatusWriter(enabled: Bool) -> (any TurnStatusWriter)? {
        enabled && ProcessInstance.running(pid: getpid()) != nil ? makeTurnStatusWriter() : nil
    }

    /// The marker of this Nirux while an option needs what hook receivers
    /// know of the agent's account (`TurnEndMarker`); none otherwise.
    static func publishAccountMarker(readsFinalMessages: Bool, triagesCI: Bool) {
        let me = ProcessInstance.running(pid: getpid())
        guard let me, readsFinalMessages || triagesCI else {
            TurnEndMarker.withdraw(app: me)
            return
        }
        TurnEndMarker.publish(
            app: me, environment: ProcessInfo.processInfo.environment, readsFinalMessages: readsFinalMessages
        )
    }

    /// The classifier in use; tests put a double here, so that turning the
    /// option on never runs the real `claude`.
    static var makeTurnEndClassifier: () -> any TurnEndClassifier = {
        ClaudeTurnEndClassifier.shared.prepare()
        return ClaudeTurnEndClassifier.shared
    }

    /// The status line writer in use; tests put a double here.
    static var makeTurnStatusWriter: () -> any TurnStatusWriter = {
        ClaudeTurnStatusWriter.shared.prepare()
        return ClaudeTurnStatusWriter.shared
    }

    private func showSettingsError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Settings"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let settingsWindow {
            alert.beginSheetModal(for: settingsWindow)
        } else {
            alert.runModal()
        }
    }

    /// Drops the window and its controls; the next `showSettings` rebuilds
    /// them from persisted state.
    private func clearSettingsWindowReferences() {
        settingsWindow = nil
        settingsKeepAwakeCheckbox = nil
        settingsAnimationsCheckbox = nil
        settingsTasksFolderLabel = nil
        settingsAgentResumePopup = nil
        settingsLaunchModePopup = nil
        settingsNoFlickerCheckbox = nil
        settingsUsageLimitsCheckbox = nil
        settingsCodexLaunchModePopup = nil
        settingsMissionHandoffsCheckbox = nil
        settingsSidebarApprovalsCheckbox = nil
        settingsStuckAgentPopup = nil
        settingsCirclingHintCheckbox = nil
        settingsExplainModelPopup = nil
        settingsExplainEffortPopup = nil
        settingsAlertOnlyWhenClaudeAsksCheckbox = nil
        settingsTurnStatusCheckbox = nil
        settingsCatchUpCheckbox = nil
        settingsTriageCIFailuresCheckbox = nil
    }
}

// The main window's close button quits Nirux: a running merge queue asks
// first.
extension NiruxApp: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow, let shell else { return true }
        return shell.mainWindowShouldClose()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        clearSettingsWindowReferences()
    }
}
