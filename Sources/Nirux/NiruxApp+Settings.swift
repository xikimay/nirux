import AppKit

// MARK: - Settings Panel

extension NiruxApp {
    static let settingsWidth: CGFloat = 520
    /// The General section sits on top; the others keep their layout below.
    static let generalSectionHeight: CGFloat = 98
    /// The usage limits rows close the Claude Code section; the sections
    /// below it keep their layout, that much lower.
    static let usageLimitsRowsHeight: CGFloat = 74
    static let settingsHeight: CGFloat = 784 + generalSectionHeight + usageLimitsRowsHeight

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

        let general = buildGeneralSection(in: background, width: width, height: height)
        settingsKeepAwakeCheckbox = general.keepAwake
        settingsAgentResumePopup = general.agentResume
        // The sections below lay out from this top.
        let sectionsTop = height - Self.generalSectionHeight
        let (modePopup, noFlickerCheck) = buildClaudeSection(in: background, width: width, height: sectionsTop)
        settingsLaunchModePopup = modePopup
        settingsNoFlickerCheckbox = noFlickerCheck
        settingsStuckAgentPopup = buildStuckAgentRow(in: background, width: width, height: sectionsTop)
        settingsUsageLimitsCheckbox = buildUsageLimitsRows(in: background, width: width, height: sectionsTop)
        let lowerSectionsTop = sectionsTop - Self.usageLimitsRowsHeight
        settingsCodexLaunchModePopup = buildCodexSection(in: background, width: width, height: lowerSectionsTop)
        let experimental = buildExperimentalSection(in: background, width: width, height: lowerSectionsTop)
        settingsMissionHandoffsCheckbox = experimental.missionHandoffs
        settingsSidebarApprovalsCheckbox = experimental.sidebarApprovals
        let telegramControls = buildTelegramSection(in: background, width: width, height: lowerSectionsTop)
        settingsTelegramEnabledCheckbox = telegramControls.enabled
        settingsTelegramTokenField = telegramControls.token
        settingsTelegramCompletionCheckbox = telegramControls.completion
        settingsTelegramAttentionCheckbox = telegramControls.attention
        settingsTelegramStatusLabel = telegramControls.status
        settingsTelegramPairButton = telegramControls.pair

        panel.contentView = settingsContent(background, in: panel)
        panel.center()

        settingsPanel = panel
        panel.makeKeyAndOrderFront(nil)
        refreshTelegramSettingsState()
    }

    /// The Save/Cancel row: the buttons sit 18 pt from its bottom.
    private static let settingsButtonRowHeight: CGFloat = 64

    /// The panel's content, with the Save/Cancel row added. When the screen
    /// can't show all of it (a 13" display with the Dock, say), the sections
    /// scroll, opening at the top, above a Save/Cancel row that stays put.
    private func settingsContent(_ background: NSView, in panel: NSPanel) -> NSView {
        let size = background.frame.size
        let chrome = NSWindow.frameRect(forContentRect: background.frame, styleMask: panel.styleMask).height - size.height
        guard let visibleHeight = settingsVisibleHeight(), visibleHeight - chrome < size.height else {
            buildSettingsButtons(in: background, width: size.width)
            return background
        }
        let fittedHeight = max(visibleHeight - chrome, 240)
        // A scroller that takes room (a mouse attached) widens the panel.
        let scrollerWidth = NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            : 0
        let fittedSize = NSSize(width: size.width + scrollerWidth, height: fittedHeight)
        panel.setContentSize(fittedSize)
        let container = NSView(frame: NSRect(origin: .zero, size: fittedSize))
        let buttonRowHeight = Self.settingsButtonRowHeight
        let buttonRow = NSView(frame: NSRect(x: 0, y: 0, width: fittedSize.width, height: buttonRowHeight))
        buildSettingsButtons(in: buttonRow, width: fittedSize.width)
        container.addSubview(buttonRow)

        let scrollHeight = fittedHeight - buttonRowHeight
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: buttonRowHeight, width: fittedSize.width, height: scrollHeight))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.15, alpha: 1)
        scrollView.documentView = background
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: size.height - scrollHeight))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        container.addSubview(scrollView)
        return container
    }

    private func buildGeneralSection(
        in background: NSView, width: CGFloat, height: CGFloat
    ) -> (keepAwake: NSButton, agentResume: NSPopUpButton) {
        let sectionLabel = NSTextField(labelWithString: "General")
        sectionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        sectionLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        sectionLabel.frame = NSRect(x: 24, y: height - 30, width: width - 48, height: 16)
        background.addSubview(sectionLabel)

        let keepAwake = NSButton(
            checkboxWithTitle: "Keep Mac awake while agents work or a merge queue runs", target: nil, action: nil
        )
        keepAwake.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        keepAwake.font = .systemFont(ofSize: 12)
        keepAwake.frame = NSRect(x: 22, y: height - 58, width: width - 44, height: 20)
        keepAwake.state = NiruxShellView.currentKeepMacAwakeEnabled() ? .on : .off
        keepAwake.toolTip = "Prevents idle sleep while an agent is working or a merge queue runs, until a minute after "
            + "the last one stops: a queue asleep stops polling GitHub. The display still sleeps, and closing a "
            + "MacBook's lid still sleeps it (except in clamshell mode)."
        background.addSubview(keepAwake)

        let resumeLabel = NSTextField(labelWithString: "Resume agents on launch")
        resumeLabel.font = .systemFont(ofSize: 12)
        resumeLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        resumeLabel.frame = NSRect(x: 24, y: height - 88, width: 200, height: 18)
        background.addSubview(resumeLabel)

        let resumePopup = NSPopUpButton(frame: NSRect(x: 230, y: height - 92, width: width - 254, height: 26), pullsDown: false)
        for choice in AgentResumeOnLaunch.allCases {
            resumePopup.addItem(withTitle: choice.displayName)
            resumePopup.lastItem?.representedObject = choice.rawValue
        }
        resumePopup.selectItem(at: resumePopup.indexOfItem(
            withRepresentedObject: NiruxShellView.currentAgentResumeOnLaunch().rawValue
        ))
        resumePopup.toolTip = "When Nirux reopens your workspaces, each Claude Code or Codex column resumes once it "
            + "shows on screen, or when you click Resume (Resume All Agents starts the rest). All at once resumes "
            + "every agent with the window."
        background.addSubview(resumePopup)

        return (keepAwake, resumePopup)
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
        claudeHint.frame = NSRect(x: 24, y: height - 168, width: width - 48, height: 28)
        background.addSubview(claudeHint)

        return (modePopup, noFlickerCheck)
    }

    private func buildCodexSection(in background: NSView, width: CGFloat, height: CGFloat) -> NSPopUpButton {
        let codexLabel = NSTextField(labelWithString: "Codex")
        codexLabel.font = .systemFont(ofSize: 12, weight: .medium)
        codexLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        codexLabel.frame = NSRect(x: 24, y: height - 206, width: width - 48, height: 16)
        background.addSubview(codexLabel)

        let modeLabel = NSTextField(labelWithString: "Launch mode")
        modeLabel.font = .systemFont(ofSize: 12)
        modeLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        modeLabel.frame = NSRect(x: 24, y: height - 234, width: 110, height: 18)
        background.addSubview(modeLabel)

        let modePopup = NSPopUpButton(frame: NSRect(x: 140, y: height - 238, width: width - 164, height: 26), pullsDown: false)
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
        codexHint.frame = NSRect(x: 24, y: height - 276, width: width - 48, height: 28)
        background.addSubview(codexHint)

        return modePopup
    }

    private func buildExperimentalSection(
        in background: NSView,
        width: CGFloat,
        height: CGFloat
    ) -> (missionHandoffs: NSButton, sidebarApprovals: NSButton) {
        let sectionLabel = NSTextField(labelWithString: "Experimental")
        sectionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        sectionLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        sectionLabel.frame = NSRect(x: 24, y: height - 594, width: width - 48, height: 16)
        background.addSubview(sectionLabel)

        let checkbox = NSButton(checkboxWithTitle: "Mission handoffs", target: nil, action: nil)
        checkbox.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        checkbox.font = .systemFont(ofSize: 12)
        checkbox.frame = NSRect(x: 22, y: height - 624, width: width - 44, height: 20)
        checkbox.state = Persistence.load()?.settings?.missionHandoffsEnabled == true ? .on : .off
        background.addSubview(checkbox)

        let hint = NSTextField(wrappingLabelWithString:
            "Allows worktree agents to exchange questions, answers, and completion results. "
            + "New terminals pick up changes.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor.white.withAlphaComponent(0.3)
        hint.maximumNumberOfLines = 2
        hint.frame = NSRect(x: 24, y: height - 658, width: width - 48, height: 28)
        background.addSubview(hint)

        let approvals = NSButton(checkboxWithTitle: "Answer Claude permissions from the sidebar", target: nil, action: nil)
        approvals.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        approvals.font = .systemFont(ofSize: 12)
        approvals.frame = NSRect(x: 22, y: height - 694, width: width - 44, height: 20)
        approvals.state = NiruxShellView.currentSidebarApprovalsEnabled() ? .on : .off
        background.addSubview(approvals)

        let approvalsHint = NSTextField(wrappingLabelWithString:
            "Allow or deny once for columns you are not looking at: short commands, reads, "
            + "web fetches and searches, shown in full. Never \"always allow\".")
        approvalsHint.font = .systemFont(ofSize: 11)
        approvalsHint.textColor = NSColor.white.withAlphaComponent(0.3)
        approvalsHint.maximumNumberOfLines = 2
        approvalsHint.frame = NSRect(x: 24, y: height - 728, width: width - 48, height: 28)
        background.addSubview(approvalsHint)

        return (checkbox, approvals)
    }

    /// Claude Code section, under No-flicker: when a dialog left open marks
    /// its agent as stuck.
    private func buildStuckAgentRow(in background: NSView, width: CGFloat, height: CGFloat) -> NSPopUpButton {
        let label = NSTextField(labelWithString: "Flag a dialog waiting after")
        label.font = .systemFont(ofSize: 12)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.frame = NSRect(x: 24, y: height - 126, width: 200, height: 18)
        background.addSubview(label)

        let popup = NSPopUpButton(frame: NSRect(x: 230, y: height - 130, width: width - 254, height: 26), pullsDown: false)
        let current = NiruxShellView.currentStuckAgentMinutes()
        // A value set outside Settings stays selectable as it is.
        for minutes in Set(NiruxShellView.stuckAgentMinuteChoices + [current]).sorted() {
            popup.addItem(withTitle: Self.stuckAgentChoiceTitle(minutes: minutes))
            popup.lastItem?.representedObject = minutes
        }
        popup.selectItem(at: popup.indexOfItem(withRepresentedObject: current))
        popup.toolTip = "A permission or question dialog open this long marks its agent as stuck: "
            + "a badge on its card and one notification."
        background.addSubview(popup)
        return popup
    }

    /// Claude Code section, under its hint: the plan usage limits in the
    /// title bar, with what turning it on does to Claude Code's status line.
    private func buildUsageLimitsRows(in background: NSView, width: CGFloat, height: CGFloat) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: "Show plan usage limits in the title bar", target: nil, action: nil)
        checkbox.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        checkbox.font = .systemFont(ofSize: 12)
        checkbox.frame = NSRect(x: 22, y: height - 196, width: width - 44, height: 20)
        checkbox.state = Self.currentShowClaudeUsageLimits() ? .on : .off
        checkbox.toolTip = "The 5-hour window and the weekly limit of a Claude Pro or Max plan, with their resets, "
            + "as Claude Code sessions in Nirux report them after each response."
        background.addSubview(checkbox)

        let hint = NSTextField(wrappingLabelWithString: Self.usageLimitsHint(for: claudeStatusLineStateReader()))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor.white.withAlphaComponent(0.3)
        hint.maximumNumberOfLines = 3
        hint.frame = NSRect(x: 24, y: height - 244, width: width - 48, height: 42)
        hint.setAccessibilityIdentifier("usageLimitsHint")
        background.addSubview(hint)
        return checkbox
    }

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
        heading.frame = NSRect(x: 24, y: height - 314, width: width - 48, height: 16)
        background.addSubview(heading)

        let enabled = NSButton(
            checkboxWithTitle: "Enable Telegram Remote Access",
            target: self,
            action: #selector(settingsTelegramDraftChanged(_:))
        )
        enabled.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        enabled.font = .systemFont(ofSize: 12)
        enabled.state = current.telegramRemoteAccessEnabled ? .on : .off
        enabled.frame = NSRect(x: 22, y: height - 349, width: width - 44, height: 20)
        background.addSubview(enabled)

        let tokenLabel = NSTextField(labelWithString: "Bot token")
        tokenLabel.font = .systemFont(ofSize: 12)
        tokenLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        tokenLabel.frame = NSRect(x: 24, y: height - 384, width: 80, height: 18)
        background.addSubview(tokenLabel)

        let token = NSSecureTextField(frame: NSRect(x: 104, y: height - 388, width: width - 128, height: 24))
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
        tokenHint.frame = NSRect(x: 24, y: height - 421, width: width - 48, height: 28)
        background.addSubview(tokenHint)

        let completion = NSButton(checkboxWithTitle: "Notify when an agent turn completes", target: nil, action: nil)
        completion.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        completion.font = .systemFont(ofSize: 12)
        completion.state = current.telegramNotifyOnCompletion ? .on : .off
        completion.frame = NSRect(x: 22, y: height - 450, width: width - 44, height: 20)
        background.addSubview(completion)

        let attention = NSButton(checkboxWithTitle: "Notify when an agent needs attention", target: nil, action: nil)
        attention.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        attention.font = .systemFont(ofSize: 12)
        attention.state = current.telegramNotifyOnAttention ? .on : .off
        attention.frame = NSRect(x: 22, y: height - 476, width: width - 44, height: 20)
        background.addSubview(attention)

        let status = NSTextField(wrappingLabelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = NSColor.white.withAlphaComponent(0.5)
        status.maximumNumberOfLines = 2
        status.frame = NSRect(x: 24, y: height - 520, width: width - 48, height: 34)
        background.addSubview(status)

        let pair = NSButton(frame: NSRect(x: 24, y: height - 560, width: 154, height: 28))
        pair.title = "Generate Pairing Code"
        pair.bezelStyle = .rounded
        pair.target = self
        pair.action = #selector(settingsTelegramPair(_:))
        background.addSubview(pair)

        let clearToken = NSButton(frame: NSRect(x: 188, y: height - 560, width: 104, height: 28))
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
        let sidebarApprovalsEnabled = settingsSidebarApprovalsCheckbox?.state == .on
        let showUsageLimits = settingsUsageLimitsCheckbox.map { $0.state == .on }
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
                settings.sidebarApprovalsEnabled = sidebarApprovalsEnabled
                if let minutes = settingsStuckAgentPopup?.selectedItem?.representedObject as? Int {
                    settings.stuckAgentMinutes = minutes
                }
                applyGeneralDrafts(to: &settings)
                if let showUsageLimits { settings.showClaudeUsageLimits = showUsageLimits }
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
            applySavedAgentSettings(missionHandoffsEnabled: missionHandoffsEnabled, sidebarApprovalsEnabled: sidebarApprovalsEnabled)
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

    /// The General section's choices. Without a control, the saved choice
    /// (keep awake: on by default) stands.
    private func applyGeneralDrafts(to settings: inout PersistedSettings) {
        if let keepAwake = settingsKeepAwakeCheckbox { settings.keepMacAwakeWhileAgentsWork = keepAwake.state == .on }
        // Only a changed choice: a value a newer build saved shows as the
        // default, and an untouched Save keeps it.
        if let raw = settingsAgentResumePopup?.selectedItem?.representedObject as? String,
           let choice = AgentResumeOnLaunch(rawValue: raw),
           choice != settings.agentResumeOnLaunch ?? .defaultValue {
            settings.agentResumeOnLaunch = choice
        }
    }

    /// The saved agent options take effect in the running app.
    private func applySavedAgentSettings(missionHandoffsEnabled: Bool, sidebarApprovalsEnabled: Bool) {
        shell?.workspaces.forEach { $0.missionHandoffsEnabled = missionHandoffsEnabled }
        if missionHandoffsEnabled {
            MissionEventCenter.shared.deliverPendingEvents()
        }
        applySidebarApprovals(enabled: sidebarApprovalsEnabled)
        shell?.stuckAgentWaitThreshold = NiruxShellView.stuckWaitThreshold(minutes: NiruxShellView.currentStuckAgentMinutes())
        // Without the checkbox, the saved choice stands.
        if let keepAwake = settingsKeepAwakeCheckbox { keepAwakeController?.setEnabled(keepAwake.state == .on) }
        if let usageLimits = settingsUsageLimitsCheckbox { applyUsageLimits(enabled: usageLimits.state == .on) }
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
        settingsKeepAwakeCheckbox = nil
        settingsUsageLimitsCheckbox = nil
        settingsAgentResumePopup = nil
        settingsLaunchModePopup = nil
        settingsNoFlickerCheckbox = nil
        settingsCodexLaunchModePopup = nil
        settingsMissionHandoffsCheckbox = nil
        settingsSidebarApprovalsCheckbox = nil
        settingsStuckAgentPopup = nil
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

// Closing via the title bar discards edits, like Cancel. The main window's
// close button quits Nirux: a running merge queue asks first.
extension NiruxApp: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow, let shell else { return true }
        return shell.mainWindowShouldClose()
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, panel === settingsPanel else { return }
        clearSettingsPanelReferences()
    }
}
