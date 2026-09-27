import AppKit

// MARK: - Settings Panel

extension NiruxApp {
    static let settingsWidth: CGFloat = 520
    static let settingsHeight: CGFloat = 680

    @objc func showSettings(_ sender: Any?) {
        if let existing = settingsPanel {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let width = Self.settingsWidth
        let height = Self.settingsHeight

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        panel.title = "Settings"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.15, alpha: 1)
        panel.isOpaque = true
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self

        let background = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.15, alpha: 1).cgColor

        let (modePopup, noFlickerCheck) = buildClaudeSection(in: background, width: width, height: height)
        settingsLaunchModePopup = modePopup
        settingsNoFlickerCheckbox = noFlickerCheck
        settingsCodexLaunchModePopup = buildCodexSection(in: background, width: width, height: height)
        settingsMissionHandoffsCheckbox = buildExperimentalSection(in: background, width: width, height: height)
        let telegramControls = buildTelegramSection(in: background, width: width, height: height)
        settingsTelegramEnabledCheckbox = telegramControls.enabled
        settingsTelegramTokenField = telegramControls.token
        settingsTelegramCompletionCheckbox = telegramControls.completion
        settingsTelegramAttentionCheckbox = telegramControls.attention
        settingsTelegramStatusLabel = telegramControls.status
        settingsTelegramPairButton = telegramControls.pair
        buildSettingsButtons(in: background, width: width)

        panel.contentView = background
        panel.center()

        settingsPanel = panel
        panel.makeKeyAndOrderFront(nil)
        refreshTelegramSettingsState()
    }

    private func buildClaudeSection(in background: NSView, width: CGFloat, height: CGFloat) -> (NSPopUpButton, NSButton) {
        let claudeLabel = NSTextField(labelWithString: "Claude Code")
        claudeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        claudeLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        claudeLabel.frame = NSRect(x: 24, y: height - 30, width: width - 48, height: 16)
        background.addSubview(claudeLabel)

        let modeLabel = NSTextField(labelWithString: "Launch mode")
        modeLabel.font = .systemFont(ofSize: 12)
        modeLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        modeLabel.frame = NSRect(x: 24, y: height - 58, width: 110, height: 18)
        background.addSubview(modeLabel)

        let modePopup = NSPopUpButton(frame: NSRect(x: 140, y: height - 62, width: width - 164, height: 26), pullsDown: false)
        for mode in ClaudeLaunchMode.allCases {
            modePopup.addItem(withTitle: mode.displayName)
            modePopup.lastItem?.representedObject = mode.rawValue
        }
        // Show the mode a launch would actually use, so an untouched Save
        // can't silently change it.
        let current = NiruxShellView.currentClaudeLaunchMode()
        if let idx = ClaudeLaunchMode.allCases.firstIndex(of: current) {
            modePopup.selectItem(at: idx)
        }
        background.addSubview(modePopup)

        let noFlickerLabel = NSTextField(labelWithString: "No-flicker mode")
        noFlickerLabel.font = .systemFont(ofSize: 12)
        noFlickerLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        noFlickerLabel.frame = NSRect(x: 40, y: height - 94, width: width - 64, height: 18)
        background.addSubview(noFlickerLabel)

        let noFlickerCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        noFlickerCheck.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        noFlickerCheck.frame = NSRect(x: 22, y: height - 94, width: 18, height: 18)
        if Persistence.load()?.settings?.claudeNoFlicker != false {
            noFlickerCheck.state = .on
        }
        background.addSubview(noFlickerCheck)

        let claudeHint = NSTextField(labelWithString:
            "Launch mode: --permission-mode (--dangerously-skip-permissions for Skip all).\n"
            + "No-flicker: sets CLAUDE_CODE_NO_FLICKER=1.")
        claudeHint.font = .systemFont(ofSize: 11)
        claudeHint.textColor = NSColor.white.withAlphaComponent(0.3)
        claudeHint.maximumNumberOfLines = 2
        claudeHint.frame = NSRect(x: 24, y: height - 134, width: width - 48, height: 28)
        background.addSubview(claudeHint)

        return (modePopup, noFlickerCheck)
    }

    private func buildCodexSection(in background: NSView, width: CGFloat, height: CGFloat) -> NSPopUpButton {
        let codexLabel = NSTextField(labelWithString: "Codex")
        codexLabel.font = .systemFont(ofSize: 12, weight: .medium)
        codexLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        codexLabel.frame = NSRect(x: 24, y: height - 172, width: width - 48, height: 16)
        background.addSubview(codexLabel)

        let modeLabel = NSTextField(labelWithString: "Launch mode")
        modeLabel.font = .systemFont(ofSize: 12)
        modeLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        modeLabel.frame = NSRect(x: 24, y: height - 200, width: 110, height: 18)
        background.addSubview(modeLabel)

        let modePopup = NSPopUpButton(frame: NSRect(x: 140, y: height - 204, width: width - 164, height: 26), pullsDown: false)
        for mode in CodexLaunchMode.allCases {
            modePopup.addItem(withTitle: mode.displayName)
            modePopup.lastItem?.representedObject = mode.rawValue
        }
        let current = NiruxShellView.currentCodexLaunchMode()
        if let idx = CodexLaunchMode.allCases.firstIndex(of: current) {
            modePopup.selectItem(at: idx)
        }
        background.addSubview(modePopup)

        let codexHint = NSTextField(labelWithString:
            "Default = no flags; Codex's own config applies.\n"
            + "Full Auto = no sandbox, never asks, web search. Workspace Write = sandboxed.")
        codexHint.font = .systemFont(ofSize: 11)
        codexHint.textColor = NSColor.white.withAlphaComponent(0.3)
        codexHint.maximumNumberOfLines = 2
        codexHint.frame = NSRect(x: 24, y: height - 242, width: width - 48, height: 28)
        background.addSubview(codexHint)

        return modePopup
    }

    private func buildExperimentalSection(in background: NSView, width: CGFloat, height: CGFloat) -> NSButton {
        let sectionLabel = NSTextField(labelWithString: "Experimental")
        sectionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        sectionLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        sectionLabel.frame = NSRect(x: 24, y: height - 560, width: width - 48, height: 16)
        background.addSubview(sectionLabel)

        let checkbox = NSButton(checkboxWithTitle: "Mission handoffs", target: nil, action: nil)
        checkbox.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        checkbox.font = .systemFont(ofSize: 12)
        checkbox.frame = NSRect(x: 22, y: height - 590, width: width - 44, height: 20)
        checkbox.state = Persistence.load()?.settings?.missionHandoffsEnabled == true ? .on : .off
        background.addSubview(checkbox)

        let hint = NSTextField(labelWithString:
            "Allows worktree agents to exchange questions, answers, and completion results. "
            + "New terminals pick up changes.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor.white.withAlphaComponent(0.3)
        hint.maximumNumberOfLines = 2
        hint.frame = NSRect(x: 24, y: height - 624, width: width - 48, height: 28)
        background.addSubview(hint)

        return checkbox
    }

    private struct TelegramSettingsControls {
        let enabled: NSButton
        let token: NSSecureTextField
        let completion: NSButton
        let attention: NSButton
        let status: NSTextField
        let pair: NSButton
    }

    private func buildTelegramSection(
        in background: NSView,
        width: CGFloat,
        height: CGFloat
    ) -> TelegramSettingsControls {
        let current = Persistence.load()?.settings ?? PersistedSettings()

        let heading = NSTextField(labelWithString: "Telegram Remote Access")
        heading.font = .systemFont(ofSize: 12, weight: .medium)
        heading.textColor = NSColor.white.withAlphaComponent(0.6)
        heading.frame = NSRect(x: 24, y: height - 280, width: width - 48, height: 16)
        background.addSubview(heading)

        let enabled = NSButton(
            checkboxWithTitle: "Enable Telegram Remote Access",
            target: self,
            action: #selector(settingsTelegramDraftChanged(_:))
        )
        enabled.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        enabled.font = .systemFont(ofSize: 12)
        enabled.state = current.telegramRemoteAccessEnabled ? .on : .off
        enabled.frame = NSRect(x: 22, y: height - 315, width: width - 44, height: 20)
        background.addSubview(enabled)

        let tokenLabel = NSTextField(labelWithString: "Bot token")
        tokenLabel.font = .systemFont(ofSize: 12)
        tokenLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        tokenLabel.frame = NSRect(x: 24, y: height - 350, width: 80, height: 18)
        background.addSubview(tokenLabel)

        let token = NSSecureTextField(frame: NSRect(x: 104, y: height - 354, width: width - 128, height: 24))
        token.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        token.placeholderString = (try? telegramTokenLoader()) != nil
            ? "Stored in macOS Keychain — leave blank to keep"
            : "Paste the token from @BotFather"
        background.addSubview(token)

        let tokenHint = NSTextField(wrappingLabelWithString:
            "Use a dedicated bot. The token is stored only in macOS Keychain; pairing IDs and preferences are stored in state.json.")
        tokenHint.font = .systemFont(ofSize: 10.5)
        tokenHint.textColor = NSColor.white.withAlphaComponent(0.3)
        tokenHint.maximumNumberOfLines = 2
        tokenHint.frame = NSRect(x: 24, y: height - 387, width: width - 48, height: 28)
        background.addSubview(tokenHint)

        let completion = NSButton(checkboxWithTitle: "Notify when an agent turn completes", target: nil, action: nil)
        completion.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        completion.font = .systemFont(ofSize: 12)
        completion.state = current.telegramNotifyOnCompletion ? .on : .off
        completion.frame = NSRect(x: 22, y: height - 416, width: width - 44, height: 20)
        background.addSubview(completion)

        let attention = NSButton(checkboxWithTitle: "Notify when an agent needs attention", target: nil, action: nil)
        attention.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        attention.font = .systemFont(ofSize: 12)
        attention.state = current.telegramNotifyOnAttention ? .on : .off
        attention.frame = NSRect(x: 22, y: height - 442, width: width - 44, height: 20)
        background.addSubview(attention)

        let status = NSTextField(wrappingLabelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = NSColor.white.withAlphaComponent(0.5)
        status.maximumNumberOfLines = 2
        status.frame = NSRect(x: 24, y: height - 486, width: width - 48, height: 34)
        background.addSubview(status)

        let pair = NSButton(frame: NSRect(x: 24, y: height - 526, width: 154, height: 28))
        pair.title = "Generate Pairing Code"
        pair.bezelStyle = .rounded
        pair.target = self
        pair.action = #selector(settingsTelegramPair(_:))
        background.addSubview(pair)

        let clearToken = NSButton(frame: NSRect(x: 188, y: height - 526, width: 104, height: 28))
        clearToken.title = "Clear Token"
        clearToken.bezelStyle = .rounded
        clearToken.target = self
        clearToken.action = #selector(settingsTelegramClearToken(_:))
        background.addSubview(clearToken)

        return TelegramSettingsControls(
            enabled: enabled,
            token: token,
            completion: completion,
            attention: attention,
            status: status,
            pair: pair
        )
    }

    private func buildSettingsButtons(in background: NSView, width: CGFloat) {
        let accent = NSColor.niruxAccent

        let saveButton = NSButton(frame: NSRect(x: width - 24 - 72, y: 18, width: 72, height: 28))
        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.isBordered = false
        saveButton.wantsLayer = true
        saveButton.layer?.cornerRadius = 6
        saveButton.layer?.backgroundColor = accent.cgColor
        saveButton.contentTintColor = .white
        saveButton.font = .systemFont(ofSize: 12, weight: .medium)
        saveButton.target = self
        saveButton.action = #selector(settingsSave(_:))
        saveButton.keyEquivalent = "\r"
        background.addSubview(saveButton)

        let cancelButton = NSButton(frame: NSRect(x: width - 24 - 72 - 80, y: 18, width: 72, height: 28))
        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.isBordered = false
        cancelButton.wantsLayer = true
        cancelButton.layer?.cornerRadius = 6
        cancelButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        cancelButton.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        cancelButton.font = .systemFont(ofSize: 12, weight: .medium)
        cancelButton.target = self
        cancelButton.action = #selector(settingsCancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        background.addSubview(cancelButton)
    }

    @objc func settingsSave(_ sender: NSButton) {
        guard persistSettingsFromPanel() else { return }
        closeSettingsPanel()
    }

    /// `telegramOnly` (pairing) leaves the other sections' drafts unsaved, so
    /// Cancel or closing the window still discards them.
    private func persistSettingsFromPanel(telegramOnly: Bool = false) -> Bool {
        let noFlicker = settingsNoFlickerCheckbox?.state == .on
        let missionHandoffsEnabled = settingsMissionHandoffsCheckbox?.state == .on
        let telegramEnabled = settingsTelegramEnabledCheckbox?.state == .on
        let enteredToken = settingsTelegramTokenField?.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let existingToken: String?
        do {
            existingToken = try telegramTokenLoader()
        } catch {
            showSettingsError("Could not update the Telegram token in Keychain: \(error.localizedDescription)")
            return false
        }
        if !enteredToken.isEmpty, !TelegramBotToken.isPlausible(enteredToken) {
            showSettingsError("The Telegram bot token does not match BotFather's token format.")
            return false
        }
        let effectiveToken = enteredToken.isEmpty ? existingToken : enteredToken
        if telegramEnabled, effectiveToken == nil {
            showSettingsError("Add a Telegram bot token before enabling Remote Access.")
            return false
        }
        let saved = Persistence.updateSettings(liveLayout: shell?.persistedState()) { settings in
            if !telegramOnly {
                // Without a readable popup selection, keep the saved mode.
                if let raw = settingsLaunchModePopup?.selectedItem?.representedObject as? String,
                   let mode = ClaudeLaunchMode(rawValue: raw) {
                    settings.claudeLaunchMode = mode
                }
                if let raw = settingsCodexLaunchModePopup?.selectedItem?.representedObject as? String,
                   let mode = CodexLaunchMode(rawValue: raw) {
                    settings.codexLaunchMode = mode
                }
                settings.claudeNoFlicker = noFlicker
                settings.missionHandoffsEnabled = missionHandoffsEnabled
            }
            settings.telegramRemoteAccessEnabled = telegramEnabled
            settings.telegramNotifyOnCompletion = settingsTelegramCompletionCheckbox?.state != .off
            settings.telegramNotifyOnAttention = settingsTelegramAttentionCheckbox?.state != .off
            if !enteredToken.isEmpty, enteredToken != existingToken {
                // A different bot has a different trust boundary and update stream.
                settings.telegramPairedUserID = nil
                settings.telegramPairedChatID = nil
                settings.telegramLastUpdateID = nil
            }
        }
        guard saved else {
            showSettingsError("Could not write the settings file. Check the disk and try again.", title: "Settings")
            return false
        }
        // Store a new token only once its pairing reset is on disk; otherwise
        // a retry would see it as unchanged and keep the old bot's pairing.
        var tokenSaveError: Error?
        if !enteredToken.isEmpty, enteredToken != existingToken {
            do {
                try telegramTokenSaver(enteredToken)
            } catch {
                tokenSaveError = error
            }
        }
        if !telegramOnly {
            shell?.workspaces.forEach { $0.missionHandoffsEnabled = missionHandoffsEnabled }
            if missionHandoffsEnabled {
                MissionEventCenter.shared.deliverPendingEvents()
            }
        }
        telegramRemoteAccessController?.reloadFromPersistence()
        if let tokenSaveError {
            refreshTelegramSettingsState()
            showSettingsError(
                "Other settings were saved, but the new Telegram token could not be stored in Keychain: "
                    + tokenSaveError.localizedDescription
            )
            return false
        }
        settingsTelegramTokenField?.stringValue = ""
        settingsTelegramTokenField?.placeholderString = effectiveToken == nil
            ? "Paste the token from @BotFather"
            : "Stored in macOS Keychain — leave blank to keep"
        refreshTelegramSettingsState()
        return true
    }

    @objc func settingsTelegramPair(_ sender: NSButton) {
        guard persistSettingsFromPanel(telegramOnly: true) else { return }
        if telegramRemoteAccessController?.displayState.isPaired == true {
            telegramRemoteAccessController?.unpair()
        } else {
            _ = telegramRemoteAccessController?.beginPairing()
        }
        refreshTelegramSettingsState()
    }

    @objc func settingsTelegramDraftChanged(_ sender: NSButton) {
        refreshTelegramSettingsState()
    }

    @objc func settingsTelegramClearToken(_ sender: NSButton) {
        do {
            try TelegramTokenStore.delete()
        } catch {
            showSettingsError("Could not remove the Telegram token from Keychain: \(error.localizedDescription)")
            return
        }
        Persistence.updateSettings(liveLayout: shell?.persistedState()) { settings in
            settings.telegramRemoteAccessEnabled = false
            settings.telegramPairedUserID = nil
            settings.telegramPairedChatID = nil
            settings.telegramLastUpdateID = nil
        }
        settingsTelegramEnabledCheckbox?.state = .off
        settingsTelegramTokenField?.stringValue = ""
        settingsTelegramTokenField?.placeholderString = "Paste the token from @BotFather"
        telegramRemoteAccessController?.reloadFromPersistence()
        refreshTelegramSettingsState()
    }

    func refreshTelegramSettingsState() {
        guard settingsPanel != nil else { return }
        let display = telegramRemoteAccessController?.displayState
        settingsTelegramStatusLabel?.stringValue = display?.statusText ?? "Remote Access is unavailable."
        settingsTelegramPairButton?.title = display?.isPaired == true
            ? "Unpair"
            : (display?.pairingCode == nil ? "Generate Pairing Code" : "Regenerate Code")
        let draftEnabled = settingsTelegramEnabledCheckbox?.state == .on
        settingsTelegramPairButton?.isEnabled = draftEnabled
            || (display?.enabled == true && display?.hasToken == true)
    }

    private func showSettingsError(_ message: String, title: String = "Telegram Remote Access") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let settingsPanel {
            alert.beginSheetModal(for: settingsPanel)
        } else {
            alert.runModal()
        }
    }

    /// `windowWillClose` drops the references, for every way the panel closes.
    private func closeSettingsPanel() {
        settingsPanel?.close()
    }

    /// Drops the panel and its controls so the next `showSettings` rebuilds
    /// from persisted state instead of re-showing abandoned edits.
    private func clearSettingsPanelReferences() {
        settingsPanel = nil
        settingsLaunchModePopup = nil
        settingsNoFlickerCheckbox = nil
        settingsCodexLaunchModePopup = nil
        settingsMissionHandoffsCheckbox = nil
        settingsTelegramEnabledCheckbox = nil
        settingsTelegramTokenField = nil
        settingsTelegramCompletionCheckbox = nil
        settingsTelegramAttentionCheckbox = nil
        settingsTelegramStatusLabel = nil
        settingsTelegramPairButton = nil
    }

    @objc func settingsCancel(_ sender: NSButton) {
        closeSettingsPanel()
    }
}

// Closing via the title bar discards edits, like Cancel.
extension NiruxApp: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, panel === settingsPanel else { return }
        clearSettingsPanelReferences()
    }
}
