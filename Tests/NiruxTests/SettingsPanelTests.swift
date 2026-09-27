import AppKit
import XCTest
@testable import Nirux

/// Settings must show the launch mode new agents actually get and persist
/// only what the user explicitly saves; otherwise an untouched Save, a pairing
/// click, or a failed write can leave agents in a mode nobody chose.
final class SettingsPanelTests: XCTestCase {

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
    func testSavingUntouchedSettingsKeepsEffectiveLaunchModes() throws {
        try withIsolatedState {
            let app = try openSettings()
            app.settingsSave(NSButton())
            defer { close(app) }
            XCTAssertNil(app.settingsPanel, "Save did not complete")

            let settings = try XCTUnwrap(Persistence.load()?.settings)
            XCTAssertEqual(settings.claudeLaunchMode, .default)
            XCTAssertEqual(settings.codexLaunchMode, .default)
            XCTAssertEqual(NiruxShellView.currentCodexLaunchMode().cliArgs, [])
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

    @MainActor
    func testClosingSettingsWindowDiscardsUnsavedLaunchModes() throws {
        try withIsolatedState {
            let app = try openSettings()
            let firstPanel = try XCTUnwrap(app.settingsPanel)
            let bypassIndex = try XCTUnwrap(CodexLaunchMode.allCases.firstIndex(of: .bypass))
            app.settingsCodexLaunchModePopup?.selectItem(at: bypassIndex)

            firstPanel.performClose(nil)
            XCTAssertNil(app.settingsPanel)

            app.showSettings(nil)
            defer { close(app) }
            XCTAssertFalse(app.settingsPanel === firstPanel)
            XCTAssertEqual(selectedRawValue(app.settingsCodexLaunchModePopup), CodexLaunchMode.default.rawValue)
        }
    }

    @MainActor
    func testPairingSavesTelegramWithoutLaunchModeDrafts() throws {
        try withIsolatedState {
            let app = try openSettings()
            defer { close(app) }
            app.telegramTokenLoader = { "123456:stored-token" }
            let bypassIndex = try XCTUnwrap(CodexLaunchMode.allCases.firstIndex(of: .bypass))
            app.settingsCodexLaunchModePopup?.selectItem(at: bypassIndex)
            app.settingsTelegramEnabledCheckbox?.state = .on

            app.settingsTelegramPair(NSButton())

            let settings = try XCTUnwrap(Persistence.load()?.settings)
            XCTAssertTrue(settings.telegramRemoteAccessEnabled)
            XCTAssertNil(settings.codexLaunchMode)
            XCTAssertEqual(NiruxShellView.currentCodexLaunchMode(), .default)
        }
    }

    @MainActor
    func testSaveOverUnreadableStateKeepsTheWorkspacesOnScreen() throws {
        try withIsolatedState {
            let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
            shell.stopHeartbeat()
            let workspace = try XCTUnwrap(shell.workspaces.first)
            workspace.title = "on screen"
            // Undecodable, with no copy to recover from.
            try Data("{".utf8).write(to: Persistence.stateDirectory.appendingPathComponent("state.json"))
            XCTAssertNil(Persistence.load())
            let app = try openSettings()
            defer { close(app) }
            app.shell = shell
            let fullAutoIndex = try XCTUnwrap(CodexLaunchMode.allCases.firstIndex(of: .fullAuto))
            app.settingsCodexLaunchModePopup?.selectItem(at: fullAutoIndex)

            app.settingsSave(NSButton())

            XCTAssertNil(app.settingsPanel, "Save did not complete")
            let saved = try XCTUnwrap(Persistence.load())
            XCTAssertEqual(saved.workspaces.map(\.id), [workspace.id])
            XCTAssertEqual(saved.workspaces.first?.title, "on screen")
            XCTAssertEqual(saved.settings?.codexLaunchMode, .fullAuto)
        }
    }

    @MainActor
    func testSaveKeepsPanelOpenWhenStateCannotBeWritten() throws {
        try withIsolatedState(writable: false) {
            let app = try openSettings()
            defer { close(app) }

            app.settingsSave(NSButton())

            XCTAssertNotNil(app.settingsPanel)
            XCTAssertNotNil(app.settingsPanel?.attachedSheet)
        }
    }

    @MainActor
    func testFailedSaveLeavesStoredTelegramTokenUntouched() throws {
        try withIsolatedState(writable: false) {
            let app = try openSettings()
            defer { close(app) }
            var savedTokens: [String] = []
            app.telegramTokenLoader = { Self.oldToken }
            app.telegramTokenSaver = { savedTokens.append($0) }
            // Must pass validation, or Save would stop before the state write.
            XCTAssertTrue(TelegramBotToken.isPlausible(Self.newToken))
            app.settingsTelegramTokenField?.stringValue = Self.newToken

            app.settingsSave(NSButton())

            XCTAssertEqual(savedTokens, [])
            XCTAssertNotNil(app.settingsPanel)
        }
    }

    @MainActor
    func testNewTelegramTokenIsStoredAfterPairingReset() throws {
        try withIsolatedState {
            try savePairedState()
            let app = try openSettings()
            var pairingOnDiskWhenTokenSaved: Int64?
            var savedTokens: [String] = []
            app.telegramTokenLoader = { Self.oldToken }
            app.telegramTokenSaver = {
                pairingOnDiskWhenTokenSaved = Persistence.load()?.settings?.telegramPairedUserID
                savedTokens.append($0)
            }
            app.settingsTelegramTokenField?.stringValue = Self.newToken

            app.settingsSave(NSButton())
            defer { close(app) }

            XCTAssertEqual(savedTokens, [Self.newToken])
            XCTAssertNil(pairingOnDiskWhenTokenSaved)
            XCTAssertNil(app.settingsPanel)
        }
    }

    @MainActor
    func testKeychainFailureKeepsPanelOpenWithPairingCleared() throws {
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

            app.settingsSave(NSButton())

            XCTAssertNotNil(app.settingsPanel?.attachedSheet)
            XCTAssertEqual(app.settingsTelegramTokenField?.stringValue, Self.newToken)
            XCTAssertNil(Persistence.load()?.settings?.telegramPairedUserID)
            // The running bot must not keep the pairing that was just cleared.
            XCTAssertFalse(controller.displayState.isPaired)
        }
    }

    // MARK: - Helpers

    private static let oldToken = "123456:old-token-aaaaaaaaaaaaaaaa"
    private static let newToken = "654321:new-token-bbbbbbbbbbbbbbbb"

    private func savePairedState() throws {
        var state = PersistedState(workspaces: [], activeWorkspaceIndex: 0)
        state.settings = PersistedSettings(telegramPairedUserID: 42, telegramPairedChatID: 42)
        XCTAssertTrue(Persistence.save(state))
    }

    /// `writable: false` points NIRUX_STATE_DIR at a regular file so every
    /// state write fails.
    private func withIsolatedState(writable: Bool = true, _ body: () throws -> Void) throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-settings-panel-\(UUID().uuidString)")
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
    private func openSettings() throws -> NiruxApp {
        _ = NSApplication.shared
        let app = NiruxApp()
        // Keep Save off the real login keychain.
        app.telegramTokenLoader = { nil }
        app.telegramTokenSaver = { _ in XCTFail("Unexpected Keychain write") }
        app.showSettings(nil)
        _ = try XCTUnwrap(app.settingsPanel)
        return app
    }

    @MainActor
    private func close(_ app: NiruxApp) {
        if let sheet = app.settingsPanel?.attachedSheet {
            app.settingsPanel?.endSheet(sheet)
        }
        app.settingsPanel?.orderOut(nil)
        app.settingsPanel?.close()
    }

    @MainActor
    private func selectedRawValue(_ popup: NSPopUpButton?) -> String? {
        popup?.selectedItem?.representedObject as? String
    }
}
