import AppKit

// MARK: - Settings Panel

extension NiruxApp {
    static let settingsWidth: CGFloat = 440
    static let settingsHeight: CGFloat = 310

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

        let background = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.15, alpha: 1).cgColor

        let (modePopup, noFlickerCheck) = buildClaudeSection(in: background, width: width, height: height)
        settingsLaunchModePopup = modePopup
        settingsNoFlickerCheckbox = noFlickerCheck
        settingsCodexLaunchModePopup = buildCodexSection(in: background, width: width, height: height)
        buildSettingsButtons(in: background, width: width)

        panel.contentView = background
        panel.center()

        settingsPanel = panel
        panel.makeKeyAndOrderFront(nil)
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
        let current = Persistence.load()?.settings?.claudeLaunchMode ?? .default
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
            "Launch mode: passed as --permission-mode (or --dangerously-skip-permissions for Bypass).\n"
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
        let current = Persistence.load()?.settings?.codexLaunchMode ?? CodexLaunchMode.niruxDefault
        if let idx = CodexLaunchMode.allCases.firstIndex(of: current) {
            modePopup.selectItem(at: idx)
        }
        background.addSubview(modePopup)

        let codexHint = NSTextField(labelWithString:
            "Full Auto = no sandbox + non-blocking + web search.\n"
            + "Workspace Write = old sandboxed mode.")
        codexHint.font = .systemFont(ofSize: 11)
        codexHint.textColor = NSColor.white.withAlphaComponent(0.3)
        codexHint.maximumNumberOfLines = 2
        codexHint.frame = NSRect(x: 24, y: height - 242, width: width - 48, height: 28)
        background.addSubview(codexHint)

        return modePopup
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
        // Save settings
        let claudeMode: ClaudeLaunchMode = {
            if let raw = settingsLaunchModePopup?.selectedItem?.representedObject as? String,
               let m = ClaudeLaunchMode(rawValue: raw) {
                return m
            }
            return .default
        }()
        let codexMode: CodexLaunchMode = {
            if let raw = settingsCodexLaunchModePopup?.selectedItem?.representedObject as? String,
               let m = CodexLaunchMode(rawValue: raw) {
                return m
            }
            return CodexLaunchMode.niruxDefault
        }()
        let noFlicker = settingsNoFlickerCheckbox?.state == .on
        var state = Persistence.load() ?? PersistedState(workspaces: [], activeWorkspaceIndex: 0)
        var settings = state.settings ?? PersistedSettings()
        settings.claudeLaunchMode = claudeMode
        settings.claudeNoFlicker = noFlicker
        settings.codexLaunchMode = codexMode
        state.settings = settings
        Persistence.save(state)

        settingsPanel?.close()
        settingsPanel = nil
        settingsLaunchModePopup = nil
        settingsNoFlickerCheckbox = nil
        settingsCodexLaunchModePopup = nil
    }

    @objc func settingsCancel(_ sender: NSButton) {
        settingsPanel?.close()
        settingsPanel = nil
        settingsLaunchModePopup = nil
        settingsNoFlickerCheckbox = nil
        settingsCodexLaunchModePopup = nil
    }
}
