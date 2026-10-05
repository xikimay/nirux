import AppKit

// MARK: - Settings window

/// A standard macOS Settings window: one toolbar tab per topic, and every
/// control applies at once — no Save or Cancel. Each change writes only its
/// own setting, so opening Settings, or touching one control, never saves
/// another value nobody chose. A failed write puts the control back.
///
/// It is a panel that doesn't float or hide: like Nirux's other panels, it
/// doesn't keep the app running once the main window closes, keys typed in
/// it never reach a terminal (isOverlayActive), and Edit > Undo works in its
/// text field (PanelTextUndo).
extension NiruxApp {
    private static let settingsWriteFailure = "Could not write the settings file. Check the disk and try again."
    private static let storedTokenPlaceholder = "Stored in Keychain — paste one to replace it"
    private static let missingTokenPlaceholder = "Paste the token from @BotFather"

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
        tabs.addTabViewItem(settingsTab("Experimental", symbol: "testtube.2", experimentalPane()))
        tabs.addTabViewItem(settingsTab("Telegram", symbol: "paperplane", telegramPane()))

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
        refreshTelegramSettingsState()
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
                SettingsForm.header("Waiting dialogs"),
                SettingsForm.row("Flag a dialog waiting after", stuck),
                SettingsForm.hint(
                    "A permission or question dialog open this long marks its agent as stuck: "
                        + "a badge on its card and one notification."
                )
            ],
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
        let current = Persistence.load()?.settings ?? PersistedSettings()
        let completion = SettingsForm.checkbox(
            "Notify when an agent turn completes", target: self, action: #selector(settingsTelegramCompletionChanged(_:))
        )
        completion.state = current.telegramNotifyOnCompletion ? .on : .off
        settingsTelegramCompletionCheckbox = completion
        let attention = SettingsForm.checkbox(
            "Notify when an agent needs attention", target: self, action: #selector(settingsTelegramAttentionChanged(_:))
        )
        attention.state = current.telegramNotifyOnAttention ? .on : .off
        settingsTelegramAttentionCheckbox = attention

        return SettingsForm.pane([
            [
                SettingsForm.header("On this Mac"),
                SettingsForm.hint(
                    "Banners and sounds, shown while Nirux is in the background, follow System Settings › "
                        + "Notifications › Nirux."
                )
            ],
            [
                SettingsForm.header("Telegram"),
                completion,
                attention,
                SettingsForm.hint("Sent to the paired chat while Telegram Remote Access is on (Telegram tab).")
            ]
        ])
    }

    private func experimentalPane() -> NSView {
        let handoffs = SettingsForm.checkbox("Mission handoffs", target: self, action: #selector(settingsMissionHandoffsChanged(_:)))
        handoffs.state = Persistence.load()?.settings?.missionHandoffsEnabled == true ? .on : .off
        settingsMissionHandoffsCheckbox = handoffs
        let approvals = SettingsForm.checkbox(
            "Answer Claude permissions from the sidebar", target: self, action: #selector(settingsSidebarApprovalsChanged(_:))
        )
        approvals.state = NiruxShellView.currentSidebarApprovalsEnabled() ? .on : .off
        settingsSidebarApprovalsCheckbox = approvals

        return SettingsForm.pane([
            [
                handoffs,
                SettingsForm.hint(
                    "Allows worktree agents to exchange questions, answers, and completion results. "
                        + "New terminals pick up changes.",
                    under: handoffs
                )
            ],
            [
                approvals,
                SettingsForm.hint(
                    "Allow or deny once for columns you are not looking at: short commands, reads, "
                        + "web fetches and searches, shown in full. Never \"always allow\".",
                    under: approvals
                )
            ]
        ])
    }

    private func telegramPane() -> NSView {
        let enabled = SettingsForm.checkbox(
            "Enable Telegram Remote Access", target: self, action: #selector(settingsTelegramEnabledChanged(_:))
        )
        enabled.state = Persistence.load()?.settings?.telegramRemoteAccessEnabled == true ? .on : .off
        settingsTelegramEnabledCheckbox = enabled

        let token = NSSecureTextField(frame: .zero)
        token.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        token.placeholderString = (try? telegramTokenLoader()) != nil
            ? Self.storedTokenPlaceholder
            : Self.missingTokenPlaceholder
        // Return stores it; leaving the field doesn't.
        token.cell?.sendsActionOnEndEditing = false
        token.target = self
        token.action = #selector(settingsTelegramSaveToken(_:))
        settingsTelegramTokenField = token

        let saveToken = NSButton(title: "Save Token", target: self, action: #selector(settingsTelegramSaveToken(_:)))
        let clearToken = NSButton(title: "Clear Token", target: self, action: #selector(settingsTelegramClearToken(_:)))

        let status = NSTextField(wrappingLabelWithString: "")
        status.textColor = .secondaryLabelColor
        status.isSelectable = false
        status.preferredMaxLayoutWidth = SettingsForm.textWidth
        settingsTelegramStatusLabel = status

        let pair = NSButton(title: "Generate Pairing Code", target: self, action: #selector(settingsTelegramPair(_:)))
        settingsTelegramPairButton = pair

        return SettingsForm.pane([
            [
                SettingsForm.header("Telegram Remote Access"),
                enabled,
                SettingsForm.row("Bot token", token, trailing: saveToken),
                SettingsForm.hint(
                    "Use a dedicated bot. The token is stored only in macOS Keychain, with Return, Save Token or "
                        + "when Settings closes; pairing IDs and preferences are stored in state.json. Alerts are "
                        + "chosen in the Notifications tab."
                )
            ],
            [status, SettingsForm.buttons([pair, clearToken])]
        ])
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
            showSettingsError(Self.settingsWriteFailure, title: "Settings")
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

    // MARK: - Telegram

    @objc func settingsTelegramCompletionChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        guard saveSetting(revert: Self.toggledBack(sender), { $0.telegramNotifyOnCompletion = enabled }) else { return }
        telegramRemoteAccessController?.reloadFromPersistence()
    }

    @objc func settingsTelegramAttentionChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        guard saveSetting(revert: Self.toggledBack(sender), { $0.telegramNotifyOnAttention = enabled }) else { return }
        telegramRemoteAccessController?.reloadFromPersistence()
    }

    /// Turning it on stores a token typed in the field first, and needs one.
    @objc func settingsTelegramEnabledChanged(_ sender: NSButton) {
        let enabling = sender.state == .on
        if enabling {
            guard commitTelegramToken() else {
                sender.state = .off
                return
            }
            let token: String?
            do {
                token = try telegramTokenLoader()
            } catch {
                sender.state = .off
                showKeychainReadError(error)
                return
            }
            guard token != nil else {
                sender.state = .off
                showSettingsError("Add a Telegram bot token before enabling Remote Access.")
                return
            }
        }
        guard saveSetting(revert: Self.toggledBack(sender), { $0.telegramRemoteAccessEnabled = enabling }) else { return }
        telegramRemoteAccessController?.reloadFromPersistence()
        refreshTelegramSettingsState()
    }

    @objc func settingsTelegramSaveToken(_ sender: Any?) {
        commitTelegramToken()
    }

    /// Stores the token typed in the field, if any. A different bot has a
    /// different trust boundary and update stream: its pairing reset is on
    /// disk before the token reaches Keychain, so a retry after a Keychain
    /// failure still sees the token as new. The field keeps a token that
    /// wasn't stored.
    @discardableResult
    private func commitTelegramToken() -> Bool {
        guard let field = settingsTelegramTokenField else { return true }
        let entered = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entered.isEmpty else { return true }
        let existing: String?
        do {
            existing = try telegramTokenLoader()
        } catch {
            showKeychainReadError(error)
            return false
        }
        guard TelegramBotToken.isPlausible(entered) else {
            showSettingsError("The Telegram bot token does not match BotFather's token format.")
            return false
        }
        if entered != existing {
            let reset = Persistence.updateSettings(liveLayout: shell?.persistedState(), Self.forgetTelegramPairing)
            guard reset else {
                showSettingsError(Self.settingsWriteFailure, title: "Settings")
                return false
            }
            do {
                try telegramTokenSaver(entered)
            } catch {
                // The running bot must not keep the pairing just cleared.
                telegramRemoteAccessController?.reloadFromPersistence()
                refreshTelegramSettingsState()
                showSettingsError(
                    "The pairing was reset, but the new Telegram token could not be stored in Keychain: "
                        + error.localizedDescription
                )
                return false
            }
        }
        field.stringValue = ""
        field.placeholderString = Self.storedTokenPlaceholder
        telegramRemoteAccessController?.reloadFromPersistence()
        refreshTelegramSettingsState()
        return true
    }

    /// A token typed in the field is stored first: pairing goes to that bot.
    @objc func settingsTelegramPair(_ sender: NSButton) {
        guard commitTelegramToken() else { return }
        if telegramRemoteAccessController?.displayState.isPaired == true {
            telegramRemoteAccessController?.unpair()
        } else {
            _ = telegramRemoteAccessController?.beginPairing()
        }
        refreshTelegramSettingsState()
    }

    /// Turns Remote Access off and forgets the pairing on disk first: a
    /// failed write leaves the token and every control as they were.
    @objc func settingsTelegramClearToken(_ sender: NSButton) {
        let saved = Persistence.updateSettings(liveLayout: shell?.persistedState()) { settings in
            settings.telegramRemoteAccessEnabled = false
            Self.forgetTelegramPairing(&settings)
        }
        guard saved else {
            showSettingsError(Self.settingsWriteFailure, title: "Settings")
            return
        }
        settingsTelegramEnabledCheckbox?.state = .off
        telegramRemoteAccessController?.reloadFromPersistence()
        do {
            try telegramTokenDeleter()
        } catch {
            refreshTelegramSettingsState()
            showSettingsError("Could not remove the Telegram token from Keychain: \(error.localizedDescription)")
            return
        }
        settingsTelegramTokenField?.stringValue = ""
        settingsTelegramTokenField?.placeholderString = Self.missingTokenPlaceholder
        telegramRemoteAccessController?.reloadFromPersistence()
        refreshTelegramSettingsState()
    }

    /// A different bot has a different trust boundary and update stream.
    private static func forgetTelegramPairing(_ settings: inout PersistedSettings) {
        settings.telegramPairedUserID = nil
        settings.telegramPairedChatID = nil
        settings.telegramLastUpdateID = nil
    }

    func refreshTelegramSettingsState() {
        guard settingsWindow != nil else { return }
        let display = telegramRemoteAccessController?.displayState
        settingsTelegramStatusLabel?.stringValue = display?.statusText ?? "Remote Access is unavailable."
        settingsTelegramPairButton?.title = display?.isPaired == true
            ? "Unpair"
            : (display?.pairingCode == nil ? "Generate Pairing Code" : "Regenerate Code")
        settingsTelegramPairButton?.isEnabled = display?.enabled == true && display?.hasToken == true
        // A status that wraps to another line needs the room.
        (settingsWindow?.contentViewController as? SettingsTabViewController)?.fitWindowToSelectedPane(animated: true)
    }

    private func showKeychainReadError(_ error: Error) {
        showSettingsError("Could not read the Telegram token from Keychain: \(error.localizedDescription)")
    }

    private func showSettingsError(_ message: String, title: String = "Telegram Remote Access") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
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
        settingsAgentResumePopup = nil
        settingsLaunchModePopup = nil
        settingsNoFlickerCheckbox = nil
        settingsUsageLimitsCheckbox = nil
        settingsCodexLaunchModePopup = nil
        settingsMissionHandoffsCheckbox = nil
        settingsSidebarApprovalsCheckbox = nil
        settingsStuckAgentPopup = nil
        settingsExplainModelPopup = nil
        settingsExplainEffortPopup = nil
        settingsTelegramEnabledCheckbox = nil
        settingsTelegramTokenField = nil
        settingsTelegramCompletionCheckbox = nil
        settingsTelegramAttentionCheckbox = nil
        settingsTelegramStatusLabel = nil
        settingsTelegramPairButton = nil
    }
}

// The main window's close button quits Nirux: a running merge queue asks
// first. Settings stores a token left in its field as it closes, and stays
// open, saying why, when it can't.
extension NiruxApp: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === settingsWindow { return commitTelegramToken() }
        guard sender === mainWindow, let shell else { return true }
        return shell.mainWindowShouldClose()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        clearSettingsWindowReferences()
    }
}
