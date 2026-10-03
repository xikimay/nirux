import AppKit
import XCTest
@testable import Nirux

/// Settings applies each change at once. It must show the launch mode new
/// agents actually get, and write only the setting the user changed:
/// otherwise opening it, touching one control, or a failed write can leave
/// agents in a mode nobody chose.
final class SettingsWindowTests: XCTestCase {

    @MainActor
    func testSettingsShowEffectiveLaunchModesWhenNothingIsSaved() throws {
        try withIsolatedState {
            let app = try openSettings()
            defer { close(app) }

            XCTAssertEqual(NiruxShellView.currentClaudeLaunchMode(), .default)
            XCTAssertEqual(NiruxShellView.currentCodexLaunchMode(), .default)
            XCTAssertEqual(selectedRawValue(app.settingsLaunchModePopup), ClaudeLaunchMode.default.rawValue)
            XCTAssertEqual(selectedRawValue(app.settingsCodexLaunchModePopup), CodexLaunchMode.default.rawValue)
        }
    }

    @MainActor
    func testOpeningAndClosingSettingsWritesNothing() throws {
        try withIsolatedState {
            let app = try openSettings()
            defer { close(app) }
            for index in app.settingsTabs.tabViewItems.indices {
                app.settingsTabs.selectedTabViewItemIndex = index
            }
            app.settingsWindow?.performClose(nil)
            XCTAssertNil(app.settingsWindow)
            XCTAssertNil(Persistence.load(), "nothing was chosen, so nothing is saved")
        }
    }

    @MainActor
    func testSettingsShowSavedLaunchModes() throws {
        try withIsolatedState {
            var state = PersistedState(workspaces: [], activeWorkspaceIndex: 0)
            state.settings = PersistedSettings(claudeLaunchMode: .acceptEdits, codexLaunchMode: .fullAuto)
            XCTAssertTrue(Persistence.save(state))

            let app = try openSettings()
            defer { close(app) }

            XCTAssertEqual(selectedRawValue(app.settingsLaunchModePopup), ClaudeLaunchMode.acceptEdits.rawValue)
            XCTAssertEqual(selectedRawValue(app.settingsCodexLaunchModePopup), CodexLaunchMode.fullAuto.rawValue)
        }
    }

    /// Every control saves at once, and only its own setting.
    @MainActor
    func testEachControlSavesOnlyItsOwnSetting() throws {
        try withIsolatedState {
            let app = try openSettings()
            defer { close(app) }
            let steps: [(key: String, change: () throws -> Void)] = [
                ("claudeLaunchMode", { try self.choose(ClaudeLaunchMode.plan.rawValue, in: app.settingsLaunchModePopup) }),
                ("claudeNoFlicker", { try self.click(app.settingsNoFlickerCheckbox) }),
                ("showClaudeUsageLimits", { try self.click(app.settingsUsageLimitsCheckbox) }),
                ("codexLaunchMode", { try self.choose(CodexLaunchMode.bypass.rawValue, in: app.settingsCodexLaunchModePopup) }),
                ("stuckAgentMinutes", { try self.choose(30, in: app.settingsStuckAgentPopup) }),
                ("keepMacAwakeWhileAgentsWork", { try self.click(app.settingsKeepAwakeCheckbox) }),
                ("agentResumeOnLaunch", {
                    try self.choose(AgentResumeOnLaunch.allAtOnce.rawValue, in: app.settingsAgentResumePopup)
                }),
                ("missionHandoffsEnabled", { try self.click(app.settingsMissionHandoffsCheckbox) }),
                ("telegramNotifyOnCompletion", { try self.click(app.settingsTelegramCompletionCheckbox) }),
                ("telegramNotifyOnAttention", { try self.click(app.settingsTelegramAttentionCheckbox) })
            ]
            for step in steps {
                let before = try savedSettings()
                try step.change()
                XCTAssertEqual(changedKeys(before, try savedSettings()), [step.key])
            }
            XCTAssertEqual(NiruxShellView.currentClaudeLaunchMode(), .plan)
            XCTAssertEqual(NiruxShellView.currentCodexLaunchMode(), .bypass)
            XCTAssertEqual(NiruxShellView.currentStuckAgentMinutes(), 30)
            XCTAssertNil(app.settingsWindow?.attachedSheet)
        }
    }

    @MainActor
    func testChangesReachTheRunningAppAtOnce() throws {
        try withIsolatedState {
            let shell = makeShell()
            let workspace = try XCTUnwrap(shell.workspaces.first)
            XCTAssertFalse(workspace.missionHandoffsEnabled)
            let controller = TelegramRemoteAccessController(
                sessions: { [] },
                sendPrompt: { _, _ in .sessionUnavailable },
                tokenLoader: { nil }
            )
            controller.reloadFromPersistence()
            defer { controller.shutdown() }
            let app = try openSettings()
            defer { close(app) }
            app.shell = shell
            app.telegramRemoteAccessController = controller

            try choose(30, in: app.settingsStuckAgentPopup)
            XCTAssertEqual(shell.stuckAgentWaitThreshold, NiruxShellView.stuckWaitThreshold(minutes: 30))
            try click(app.settingsMissionHandoffsCheckbox)
            XCTAssertTrue(workspace.missionHandoffsEnabled)
            try click(app.settingsTelegramCompletionCheckbox)
            XCTAssertFalse(controller.notifyOnCompletion)
            try click(app.settingsTelegramAttentionCheckbox)
            XCTAssertFalse(controller.notifyOnAttention)
        }
    }

    @MainActor
    func testChangeOverUnreadableStateKeepsTheWorkspacesOnScreen() throws {
        try withIsolatedState {
            let shell = makeShell()
            let workspace = try XCTUnwrap(shell.workspaces.first)
            workspace.title = "on screen"
            // Undecodable, with no copy to recover from.
            try Data("{".utf8).write(to: Persistence.stateDirectory.appendingPathComponent("state.json"))
            XCTAssertNil(Persistence.load())
            let app = try openSettings()
            defer { close(app) }
            app.shell = shell

            try choose(CodexLaunchMode.fullAuto.rawValue, in: app.settingsCodexLaunchModePopup)

            let saved = try XCTUnwrap(Persistence.load())
            XCTAssertEqual(saved.workspaces.map(\.id), [workspace.id])
            XCTAssertEqual(saved.workspaces.first?.title, "on screen")
            XCTAssertEqual(saved.settings?.codexLaunchMode, .fullAuto)
        }
    }

    @MainActor
    func testAFailedWritePutsTheControlBackAndSaysSo() throws {
        try withIsolatedState(writable: false) {
            let app = try openSettings()
            defer { close(app) }

            try choose(CodexLaunchMode.bypass.rawValue, in: app.settingsCodexLaunchModePopup)
            XCTAssertEqual(selectedRawValue(app.settingsCodexLaunchModePopup), CodexLaunchMode.default.rawValue)
            XCTAssertNotNil(app.settingsWindow?.attachedSheet)
            dismissSheet(app)
            XCTAssertNil(app.settingsWindow?.attachedSheet)

            try click(app.settingsKeepAwakeCheckbox)
            XCTAssertEqual(app.settingsKeepAwakeCheckbox?.state, .on)
            XCTAssertNotNil(app.settingsWindow?.attachedSheet)
            dismissSheet(app)

            // Nothing applies a setting that wasn't saved.
            app.claudeStatusLineInstaller = { _ in XCTFail("installed a status line that wasn't saved") }
            try click(app.settingsUsageLimitsCheckbox)
            XCTAssertEqual(app.settingsUsageLimitsCheckbox?.state, .off)
        }
    }

    // MARK: - Telegram

    @MainActor
    func testFailedWriteLeavesStoredTelegramTokenUntouched() throws {
        try withIsolatedState(writable: false) {
            let app = try openSettings()
            defer { close(app) }
            var savedTokens: [String] = []
            app.telegramTokenLoader = { Self.oldToken }
            app.telegramTokenSaver = { savedTokens.append($0) }
            // Must pass validation, or saving would stop before the state write.
            XCTAssertTrue(TelegramBotToken.isPlausible(Self.newToken))
            app.settingsTelegramTokenField?.stringValue = Self.newToken

            app.settingsTelegramSaveToken(nil)

            XCTAssertEqual(savedTokens, [])
            XCTAssertEqual(app.settingsTelegramTokenField?.stringValue, Self.newToken)
            XCTAssertNotNil(app.settingsWindow?.attachedSheet)
        }
    }

    @MainActor
    func testNewTelegramTokenIsStoredAfterPairingReset() throws {
        try withIsolatedState {
            try savePairedState()
            let app = try openSettings()
            defer { close(app) }
            var pairingOnDiskWhenTokenSaved: Int64?
            var savedTokens: [String] = []
            app.telegramTokenLoader = { Self.oldToken }
            app.telegramTokenSaver = {
                pairingOnDiskWhenTokenSaved = Persistence.load()?.settings?.telegramPairedUserID
                savedTokens.append($0)
            }
            app.settingsTelegramTokenField?.stringValue = Self.newToken

            try XCTUnwrap(button("Save Token", in: app)).performClick(nil)

            XCTAssertEqual(savedTokens, [Self.newToken])
            XCTAssertNil(pairingOnDiskWhenTokenSaved)
            XCTAssertEqual(app.settingsTelegramTokenField?.stringValue, "")
            XCTAssertNil(app.settingsWindow?.attachedSheet)
        }
    }

    /// Return in the field, pairing and closing Settings all store a token
    /// left in the field; one that can't be stored keeps Settings open.
    @MainActor
    func testATypedTokenIsStoredBeforeItCouldBeLost() throws {
        try withIsolatedState {
            var savedTokens: [String] = []
            let app = try openSettings()
            defer { close(app) }
            app.telegramTokenSaver = { savedTokens.append($0) }
            let field = try XCTUnwrap(app.settingsTelegramTokenField)

            field.stringValue = Self.newToken
            field.sendAction(field.action, to: field.target)
            XCTAssertEqual(savedTokens, [Self.newToken])

            field.stringValue = Self.oldToken
            app.settingsTelegramPair(NSButton())
            XCTAssertEqual(savedTokens, [Self.newToken, Self.oldToken], "pairing goes to the typed bot")

            field.stringValue = "not a token"
            app.settingsWindow?.performClose(nil)
            XCTAssertNotNil(app.settingsWindow?.attachedSheet, "says why it stays open")
            dismissSheet(app)

            field.stringValue = Self.newToken
            app.settingsWindow?.performClose(nil)
            XCTAssertNil(app.settingsWindow)
            XCTAssertEqual(savedTokens, [Self.newToken, Self.oldToken, Self.newToken])
        }
    }

    /// The pairing is forgotten on disk before the token leaves Keychain; a
    /// failed write leaves both as they were.
    @MainActor
    func testClearTokenWritesFirst() throws {
        try withIsolatedState(writable: false) {
            let app = try openSettings()
            defer { close(app) }
            var deletions = 0
            app.telegramTokenDeleter = { deletions += 1 }
            app.settingsTelegramEnabledCheckbox?.state = .on

            try XCTUnwrap(button("Clear Token", in: app)).performClick(nil)

            XCTAssertEqual(deletions, 0)
            XCTAssertEqual(app.settingsTelegramEnabledCheckbox?.state, .on)
            XCTAssertNotNil(app.settingsWindow?.attachedSheet)
        }
        try withIsolatedState {
            try savePairedState()
            let app = try openSettings()
            defer { close(app) }
            var deletions = 0
            var pairingOnDiskWhenDeleted: Int64?
            app.telegramTokenDeleter = {
                deletions += 1
                pairingOnDiskWhenDeleted = Persistence.load()?.settings?.telegramPairedUserID
            }

            try XCTUnwrap(button("Clear Token", in: app)).performClick(nil)

            XCTAssertEqual(deletions, 1)
            XCTAssertNil(pairingOnDiskWhenDeleted)
            XCTAssertEqual(Persistence.load()?.settings?.telegramRemoteAccessEnabled, false)
            XCTAssertNil(app.settingsWindow?.attachedSheet)
        }
    }

    @MainActor
    func testKeychainFailureKeepsTheTokenWithPairingCleared() throws {
        try withIsolatedState {
            try savePairedState()
            let controller = TelegramRemoteAccessController(
                sessions: { [] },
                sendPrompt: { _, _ in .sessionUnavailable },
                tokenLoader: { Self.oldToken }
            )
            controller.reloadFromPersistence()
            defer { controller.shutdown() }
            XCTAssertTrue(controller.displayState.isPaired)
            let app = try openSettings()
            defer { close(app) }
            app.telegramRemoteAccessController = controller
            app.telegramTokenLoader = { Self.oldToken }
            app.telegramTokenSaver = { _ in throw TelegramTokenStore.StoreError.keychain(errSecIO) }
            app.settingsTelegramTokenField?.stringValue = Self.newToken

            app.settingsTelegramSaveToken(nil)

            XCTAssertNotNil(app.settingsWindow?.attachedSheet)
            XCTAssertEqual(app.settingsTelegramTokenField?.stringValue, Self.newToken)
            XCTAssertNil(Persistence.load()?.settings?.telegramPairedUserID)
            // The running bot must not keep the pairing that was just cleared.
            XCTAssertFalse(controller.displayState.isPaired)
        }
    }

    @MainActor
    func testEnablingRemoteAccessNeedsAToken() throws {
        try withIsolatedState {
            let app = try openSettings()
            defer { close(app) }

            try click(app.settingsTelegramEnabledCheckbox)

            XCTAssertEqual(app.settingsTelegramEnabledCheckbox?.state, .off)
            XCTAssertNotNil(app.settingsWindow?.attachedSheet)
            XCTAssertNil(Persistence.load(), "nothing saved")
            dismissSheet(app)

            // A token typed in the field is stored first, then Remote Access turns on.
            var stored: String?
            app.telegramTokenLoader = { stored }
            app.telegramTokenSaver = { stored = $0 }
            app.settingsTelegramTokenField?.stringValue = Self.newToken
            try click(app.settingsTelegramEnabledCheckbox)

            XCTAssertEqual(stored, Self.newToken)
            XCTAssertEqual(app.settingsTelegramEnabledCheckbox?.state, .on)
            XCTAssertEqual(Persistence.load()?.settings?.telegramRemoteAccessEnabled, true)
        }
    }

    // MARK: - Sidebar approvals

    /// Opt-in: off until turned on, and receivers only wait on a running app
    /// that turned it on.
    @MainActor
    func testSidebarApprovalsApplyAtOnce() throws {
        try withIsolatedState {
            let hooks = AgentHookCenter.shared
            defer { hooks.approvalsEnabled = false }
            let app = try openSettings()
            defer { close(app) }
            XCTAssertEqual(app.settingsSidebarApprovalsCheckbox?.state, .off)
            XCTAssertFalse(PermissionApprovalChannel.standard.isAppListening())

            try click(app.settingsSidebarApprovalsCheckbox)
            XCTAssertEqual(Persistence.load()?.settings?.sidebarApprovalsEnabled, true)
            XCTAssertTrue(hooks.approvalsEnabled)
            XCTAssertTrue(PermissionApprovalChannel.standard.isAppListening(), "receivers see this app")

            try click(app.settingsSidebarApprovalsCheckbox)
            XCTAssertEqual(Persistence.load()?.settings?.sidebarApprovalsEnabled, false)
            XCTAssertFalse(hooks.approvalsEnabled)
            XCTAssertFalse(PermissionApprovalChannel.standard.isAppListening())
        }
    }

    // MARK: - Keep Mac awake

    /// On by default; turning it off releases a held assertion at once.
    @MainActor
    func testKeepMacAwakeIsOnByDefaultAndTurningItOffReleases() throws {
        try withIsolatedState {
            let harness = KeepAwakeHarness()
            harness.controller.update(workingAgentCount: 1)
            let app = try openSettings()
            defer { close(app) }
            app.keepAwakeController = harness.controller
            XCTAssertEqual(app.settingsKeepAwakeCheckbox?.state, .on)
            XCTAssertTrue(harness.controller.isActive)

            try click(app.settingsKeepAwakeCheckbox)

            XCTAssertEqual(Persistence.load()?.settings?.keepMacAwakeWhileAgentsWork, false)
            XCTAssertFalse(harness.controller.isActive)
            XCTAssertTrue(harness.assertions.held.isEmpty)
            close(app)

            let reopened = try openSettings()
            defer { close(reopened) }
            XCTAssertEqual(reopened.settingsKeepAwakeCheckbox?.state, .off)
        }
    }

    // MARK: - Resume agents on launch

    @MainActor
    func testResumeAgentsOnLaunchDefaultsToLazilyAndSaves() throws {
        try withIsolatedState {
            let app = try openSettings()
            XCTAssertEqual(app.settingsAgentResumePopup?.itemTitles, ["When their column shows", "All at once"])
            XCTAssertEqual(selectedRawValue(app.settingsAgentResumePopup), AgentResumeOnLaunch.lazily.rawValue)
            XCTAssertEqual(NiruxShellView.currentAgentResumeOnLaunch(), .lazily)

            try choose(AgentResumeOnLaunch.allAtOnce.rawValue, in: app.settingsAgentResumePopup)
            XCTAssertEqual(Persistence.load()?.settings?.agentResumeOnLaunch, .allAtOnce)
            XCTAssertEqual(NiruxShellView.currentAgentResumeOnLaunch(), .allAtOnce)
            close(app)

            let reopened = try openSettings()
            defer { close(reopened) }
            XCTAssertEqual(selectedRawValue(reopened.settingsAgentResumePopup), AgentResumeOnLaunch.allAtOnce.rawValue)
        }
    }

    /// A choice a newer build saved shows as the default; picking that, or
    /// changing another setting, keeps it.
    @MainActor
    func testANewerBuildsResumeChoiceSurvives() throws {
        try withIsolatedState {
            let stateFile = Persistence.stateDirectory.appendingPathComponent("state.json")
            try Data(#"{"workspaces":[],"activeWorkspaceIndex":0,"settings":{"agentResumeOnLaunch":"onIdle"}}"#.utf8)
                .write(to: stateFile)
            let app = try openSettings()
            defer { close(app) }
            XCTAssertEqual(selectedRawValue(app.settingsAgentResumePopup), AgentResumeOnLaunch.lazily.rawValue)

            try choose(AgentResumeOnLaunch.lazily.rawValue, in: app.settingsAgentResumePopup)
            try click(app.settingsNoFlickerCheckbox)

            XCTAssertEqual(Persistence.load()?.settings?.claudeNoFlicker, false, "the file was written again")
            XCTAssertTrue(try String(contentsOf: stateFile, encoding: .utf8).contains(#""agentResumeOnLaunch":"onIdle""#))
        }
    }

    // MARK: - Claude usage limits

    /// Opt-in: on, the status line is installed and the indicator shows at
    /// once; off, the status line goes back and the readings are forgotten.
    @MainActor
    func testUsageLimitsApplyAtOnce() throws {
        try withIsolatedState {
            let app = try openSettings()
            defer { close(app) }
            var installs: [Bool] = []
            app.claudeStatusLineInstaller = { installs.append($0) }
            let monitor = ClaudeUsageLimitsMonitor(
                url: Persistence.stateDirectory.appendingPathComponent("limits.json"), isReporting: { true }
            )
            app.usageLimitsMonitor = monitor
            XCTAssertEqual(app.settingsUsageLimitsCheckbox?.state, .off)

            try click(app.settingsUsageLimitsCheckbox)
            XCTAssertEqual(Persistence.load()?.settings?.showClaudeUsageLimits, true)
            XCTAssertEqual(installs, [true])
            XCTAssertTrue(monitor.isEnabled)

            try Data("{}".utf8).write(to: ClaudeUsageLimitsFile.url)
            try click(app.settingsUsageLimitsCheckbox)
            XCTAssertEqual(Persistence.load()?.settings?.showClaudeUsageLimits, false)
            XCTAssertEqual(installs, [true, false])
            XCTAssertFalse(monitor.isEnabled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ClaudeUsageLimitsFile.url.path), "off forgets the readings")
        }
    }

    /// The hint says what the option does to Claude Code's status line, or
    /// why it can't work with the user's own.
    @MainActor
    func testUsageLimitsHintExplainsTheStatusLine() throws {
        try withIsolatedState {
            let app = try openSettings(statusLine: .foreign)
            defer { close(app) }
            let agents = try XCTUnwrap(app.settingsTabs.tabViewItems.first { $0.label == "Agents" }?.viewController?.view)
            let texts = Self.descendants(of: agents).compactMap { ($0 as? NSTextField)?.stringValue }
            XCTAssertTrue(texts.contains(NiruxApp.usageLimitsHint(for: .foreign)))
            XCTAssertFalse(texts.contains(NiruxApp.usageLimitsHint(for: .none)))
        }
    }

    // MARK: - Window

    /// Toolbar tabs, Telegram last; the window fits each pane, so nothing is
    /// cut off whichever tab is picked.
    @MainActor
    func testTabsAndEachPaneFitsTheWindow() throws {
        try withIsolatedState {
            let app = try openSettings()
            defer { close(app) }
            let window = try XCTUnwrap(app.settingsWindow)
            // A panel never keeps Nirux running once the main window closes,
            // and keys typed in it never reach a terminal.
            XCTAssertTrue(window is NSPanel)
            let tabs = app.settingsTabs
            XCTAssertEqual(tabs.tabStyle, .toolbar)
            XCTAssertEqual(tabs.tabViewItems.map(\.label), ["General", "Agents", "Notifications", "Experimental", "Telegram"])
            XCTAssertTrue(tabs.tabViewItems.allSatisfy { $0.image != nil })

            // Tallest first, so a window that keeps the previous size would cut the next pane.
            let order = tabs.tabViewItems.indices.sorted {
                tabs.tabViewItems[$0].viewController!.view.fittingSize.height
                    > tabs.tabViewItems[$1].viewController!.view.fittingSize.height
            }
            let top = window.frame.maxY
            for index in order.reversed() + order {
                tabs.selectedTabViewItemIndex = index
                // Let AppKit run any resize it schedules on its own.
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5, "the top edge stays put")
                let pane = try XCTUnwrap(tabs.tabViewItems[index].viewController?.view)
                let content = try XCTUnwrap(window.contentView)
                content.layoutSubtreeIfNeeded()
                let label = tabs.tabViewItems[index].label
                XCTAssertEqual(window.title, label)
                XCTAssertEqual(content.bounds.height, pane.fittingSize.height, accuracy: 1, label)
                for control in Self.descendants(of: pane).compactMap({ $0 as? NSControl }) where !control.isHiddenOrHasHiddenAncestor {
                    let frame = control.convert(control.bounds, to: content)
                    XCTAssertTrue(content.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(label): \(control) is cut off")
                }
            }
        }
    }

    // MARK: - Helpers

    private static let oldToken = "123456:old-token-aaaaaaaaaaaaaaaa"
    private static let newToken = "654321:new-token-bbbbbbbbbbbbbbbb"

    @MainActor
    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func savePairedState() throws {
        var state = PersistedState(workspaces: [], activeWorkspaceIndex: 0)
        state.settings = PersistedSettings(telegramPairedUserID: 42, telegramPairedChatID: 42)
        XCTAssertTrue(Persistence.save(state))
    }

    /// The saved settings as JSON values, defaults when nothing is saved.
    private func savedSettings() throws -> [String: NSObject] {
        let data = try JSONEncoder().encode(Persistence.load()?.settings ?? PersistedSettings())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: NSObject])
    }

    private func changedKeys(_ before: [String: NSObject], _ after: [String: NSObject]) -> Set<String> {
        Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
    }

    /// `writable: false` points NIRUX_STATE_DIR at a regular file so every
    /// state write fails.
    private func withIsolatedState(writable: Bool = true, _ body: () throws -> Void) throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-settings-window-\(UUID().uuidString)")
        if writable {
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        } else {
            try Data("not a directory".utf8).write(to: stateDirectory)
        }
        let previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", stateDirectory.path, 1)
        defer {
            if let previousStateDirectory {
                setenv("NIRUX_STATE_DIR", previousStateDirectory, 1)
            } else {
                unsetenv("NIRUX_STATE_DIR")
            }
            try? FileManager.default.removeItem(at: stateDirectory)
        }
        try body()
    }

    @MainActor
    private func makeShell() -> NiruxShellView {
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        shell.stopHeartbeat()
        return shell
    }

    /// `statusLine` stands in for ~/.claude/settings.json's.
    @MainActor
    private func openSettings(statusLine: AgentHookInstaller.ClaudeStatusLineState = .none) throws -> NiruxApp {
        _ = NSApplication.shared
        let app = NiruxApp()
        // Keep Settings off the real login keychain and ~/.claude.
        app.claudeStatusLineStateReader = { statusLine }
        app.claudeStatusLineInstaller = { _ in }
        app.telegramTokenLoader = { nil }
        app.telegramTokenSaver = { _ in XCTFail("Unexpected Keychain write") }
        app.telegramTokenDeleter = { XCTFail("Unexpected Keychain delete") }
        app.showSettings(nil)
        _ = try XCTUnwrap(app.settingsWindow)
        return app
    }

    @MainActor
    private func close(_ app: NiruxApp) {
        dismissSheet(app)
        app.settingsWindow?.orderOut(nil)
        app.settingsWindow?.close()
    }

    @MainActor
    private func dismissSheet(_ app: NiruxApp) {
        if let sheet = app.settingsWindow?.attachedSheet {
            app.settingsWindow?.endSheet(sheet)
        }
    }

    /// Clicks it the way the user does: the state flips, then the action runs.
    @MainActor
    private func click(_ checkbox: NSButton?) throws {
        try XCTUnwrap(checkbox).performClick(nil)
    }

    @MainActor
    private func choose(_ value: Any, in popup: NSPopUpButton?) throws {
        let popup = try XCTUnwrap(popup)
        let index = popup.indexOfItem(withRepresentedObject: value)
        XCTAssertGreaterThanOrEqual(index, 0, "\(value) is not offered")
        popup.selectItem(at: index)
        popup.sendAction(popup.action, to: popup.target)
    }

    @MainActor
    private func button(_ title: String, in app: NiruxApp) -> NSButton? {
        app.settingsTabs.tabViewItems.compactMap(\.viewController?.view)
            .flatMap(Self.descendants(of:))
            .compactMap { $0 as? NSButton }
            .first { $0.title == title }
    }

    @MainActor
    private func selectedRawValue(_ popup: NSPopUpButton?) -> String? {
        popup?.selectedItem?.representedObject as? String
    }
}

private extension NiruxApp {
    var settingsTabs: NSTabViewController {
        // swiftlint:disable:next force_cast
        settingsWindow?.contentViewController as! NSTabViewController
    }
}
