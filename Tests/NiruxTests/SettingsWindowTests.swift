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
            let settings = try XCTUnwrap(app.settingsController)
            for pane in settings.appPanes {
                settings.select(.app(pane.id))
            }
            app.settingsPanel?.performClose(nil)
            XCTAssertNil(app.settingsPanel)
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

    /// The menu leaves out `skipPermissions`, a duplicate of Bypass
    /// permissions, unless it is saved: then it stays selected and launches
    /// with its flag.
    @MainActor
    func testSkipPermissionsShowsOnlyWhenSaved() throws {
        try withIsolatedState {
            let app = try openSettings()
            defer { close(app) }
            let popup = try XCTUnwrap(app.settingsLaunchModePopup)
            XCTAssertEqual(popup.indexOfItem(withRepresentedObject: ClaudeLaunchMode.skipPermissions.rawValue), -1)
        }
        try withIsolatedState {
            var state = PersistedState(workspaces: [], activeWorkspaceIndex: 0)
            state.settings = try JSONDecoder().decode(
                PersistedSettings.self, from: Data(#"{"claudeLaunchMode":"skipPermissions"}"#.utf8)
            )
            XCTAssertTrue(Persistence.save(state))
            let app = try openSettings()
            defer { close(app) }
            XCTAssertEqual(selectedRawValue(app.settingsLaunchModePopup), ClaudeLaunchMode.skipPermissions.rawValue)
            XCTAssertEqual(
                NiruxShellView.claudeCommand(mode: NiruxShellView.currentClaudeLaunchMode(), niruxExecutable: nil),
                "command claude --dangerously-skip-permissions"
            )
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
                ("agentCirclingHint", { try self.click(app.settingsCirclingHintCheckbox) }),
                ("explainModel", { try self.choose("claude-sonnet-5-5", in: app.settingsExplainModelPopup) }),
                ("explainEffort", { try self.choose("high", in: app.settingsExplainEffortPopup) }),
                ("keepMacAwakeWhileAgentsWork", { try self.click(app.settingsKeepAwakeCheckbox) }),
                ("animatesInterface", { try self.click(app.settingsAnimationsCheckbox) }),
                ("agentResumeOnLaunch", {
                    try self.choose(AgentResumeOnLaunch.allAtOnce.rawValue, in: app.settingsAgentResumePopup)
                }),
                ("missionHandoffsEnabled", { try self.click(app.settingsMissionHandoffsCheckbox) }),
                ("alertOnlyWhenClaudeAsks", { try self.click(app.settingsAlertOnlyWhenClaudeAsksCheckbox) }),
                ("showTurnStatus", { try self.click(app.settingsTurnStatusCheckbox) }),
                ("showCatchUp", { try self.click(app.settingsCatchUpCheckbox) }),
                ("triageCIFailures", { try self.click(app.settingsTriageCIFailuresCheckbox) })
            ]
            for step in steps {
                let before = try savedSettings()
                try step.change()
                XCTAssertEqual(changedKeys(before, try savedSettings()), [step.key])
            }
            XCTAssertEqual(NiruxShellView.currentClaudeLaunchMode(), .plan)
            XCTAssertEqual(NiruxShellView.currentCodexLaunchMode(), .bypass)
            XCTAssertEqual(NiruxShellView.currentStuckAgentMinutes(), 30)
            XCTAssertNil(app.settingsPanel?.attachedSheet)
        }
    }

    /// The hint's setting comes with the state the shell restores, read
    /// once at launch.
    @MainActor
    func testTheCirclingHintSettingComesWithTheRestoredState() throws {
        try withIsolatedState {
            var state = PersistedState(workspaces: [], activeWorkspaceIndex: 0)
            state.settings = PersistedSettings()
            state.settings?.agentCirclingHint = false
            state.settings?.showTurnStatus = false
            state.settings?.showCatchUp = false
            XCTAssertTrue(Persistence.save(state))
            let shell = makeShell()
            XCTAssertTrue(shell.circlingHintEnabled, "the default, before the state is read")
            XCTAssertTrue(shell.turnStatusEnabled)
            XCTAssertTrue(shell.catchUpEnabled)
            shell.restoreState()
            XCTAssertFalse(shell.circlingHintEnabled)
            XCTAssertFalse(shell.turnStatusEnabled)
            XCTAssertFalse(shell.catchUpEnabled)
        }
    }

    @MainActor
    func testChangesReachTheRunningAppAtOnce() throws {
        try withIsolatedState {
            let shell = makeShell()
            let workspace = try XCTUnwrap(shell.workspaces.first)
            XCTAssertTrue(workspace.missionHandoffsEnabled, "on by default")
            let app = try openSettings()
            defer { close(app) }
            app.shell = shell

            try choose(30, in: app.settingsStuckAgentPopup)
            XCTAssertEqual(shell.stuckAgentWaitThreshold, NiruxShellView.stuckWaitThreshold(minutes: 30))
            XCTAssertEqual(app.settingsCirclingHintCheckbox?.state, .on)
            try click(app.settingsCirclingHintCheckbox)
            XCTAssertFalse(shell.circlingHintEnabled, "rows say Working again")
            try click(app.settingsMissionHandoffsCheckbox)
            XCTAssertFalse(workspace.missionHandoffsEnabled)
            let classifier = AgentHookCenter.shared.turnEndClassifier
            let makeClassifier = NiruxApp.makeTurnEndClassifier
            // Never the real `claude`.
            NiruxApp.makeTurnEndClassifier = { ClaudeTurnEndClassifier(checkSetup: { .unavailable }, runProcess: { _, _, _ in nil }) }
            defer {
                AgentHookCenter.shared.turnEndClassifier = classifier
                NiruxApp.makeTurnEndClassifier = makeClassifier
            }
            XCTAssertEqual(app.settingsAlertOnlyWhenClaudeAsksCheckbox?.state, .on)
            try click(app.settingsAlertOnlyWhenClaudeAsksCheckbox)
            XCTAssertNil(AgentHookCenter.shared.turnEndClassifier, "every turn end alerts")
            try click(app.settingsAlertOnlyWhenClaudeAsksCheckbox)
            XCTAssertNotNil(AgentHookCenter.shared.turnEndClassifier)
            // The status lines: no writer and no line on the rows, at once.
            let writer = AgentHookCenter.shared.turnStatusWriter
            let makeWriter = NiruxApp.makeTurnStatusWriter
            NiruxApp.makeTurnStatusWriter = { ClaudeTurnStatusWriter(checkSetup: { .unavailable }, runProcess: { _, _, _ in nil }) }
            defer {
                AgentHookCenter.shared.turnStatusWriter = writer
                NiruxApp.makeTurnStatusWriter = makeWriter
            }
            XCTAssertEqual(app.settingsTurnStatusCheckbox?.state, .on)
            try click(app.settingsTurnStatusCheckbox)
            XCTAssertNil(AgentHookCenter.shared.turnStatusWriter)
            XCTAssertFalse(shell.turnStatusEnabled, "rows say what they said before")
            workspace.awaitTurnStatus(turnEndedAt: 1)
            workspace.settleTurnStatus(.line("fix pushed"), turnEndedAt: 1)
            try click(app.settingsTurnStatusCheckbox)
            XCTAssertNotNil(AgentHookCenter.shared.turnStatusWriter)
            XCTAssertTrue(shell.turnStatusEnabled)
            XCTAssertNil(workspace.statusLine, "a line from before is forgotten: turns ended meanwhile without one")
            XCTAssertEqual(app.settingsCatchUpCheckbox?.state, .on)
            shell.catchUpState.workspaceIDs = [workspace.id]
            try click(app.settingsCatchUpCheckbox)
            XCTAssertFalse(shell.catchUpEnabled)
            XCTAssertEqual(shell.catchUpState.workspaceIDs, [], "the card goes at once")

            // The CI failure triage: off in the shell at once, and back on
            // with its model's account checked (a double: never the real
            // `claude`).
            let prepare = NiruxApp.prepareCITriageModel
            var prepared = 0
            NiruxApp.prepareCITriageModel = { prepared += 1 }
            defer { NiruxApp.prepareCITriageModel = prepare }
            shell.setCITriage(enabled: true)
            XCTAssertEqual(app.settingsTriageCIFailuresCheckbox?.state, .on)
            try click(app.settingsTriageCIFailuresCheckbox)
            XCTAssertFalse(shell.ciTriageCenter.isEnabled)
            XCTAssertEqual(prepared, 0)
            try click(app.settingsTriageCIFailuresCheckbox)
            XCTAssertTrue(shell.ciTriageCenter.isEnabled)
            XCTAssertEqual(prepared, 1)
            // Hook receivers are told while either option needs the agent's account.
            let me = try XCTUnwrap(ProcessInstance.running(pid: getpid()))
            let marker = TurnEndMarker.directory.appendingPathComponent("\(me.pid)-\(Int(me.startedAt)).json")
            func readsFinalMessages() throws -> Bool? {
                try JSONDecoder().decode(TurnEndMarker.self, from: Data(contentsOf: marker)).readsFinalMessages
            }
            XCTAssertEqual(try readsFinalMessages(), true)
            try click(app.settingsAlertOnlyWhenClaudeAsksCheckbox)
            XCTAssertEqual(try readsFinalMessages(), true, "the status lines still read them")
            try click(app.settingsTurnStatusCheckbox)
            XCTAssertEqual(try readsFinalMessages(), false, "the triage alone")
            try click(app.settingsTriageCIFailuresCheckbox)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "none")
            try click(app.settingsTurnStatusCheckbox)
            XCTAssertEqual(try readsFinalMessages(), true)
            try click(app.settingsTurnStatusCheckbox)
            try click(app.settingsAlertOnlyWhenClaudeAsksCheckbox)
            XCTAssertEqual(try readsFinalMessages(), true)
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
            XCTAssertNotNil(app.settingsPanel?.attachedSheet)
            dismissSheet(app)
            XCTAssertNil(app.settingsPanel?.attachedSheet)

            try click(app.settingsKeepAwakeCheckbox)
            XCTAssertEqual(app.settingsKeepAwakeCheckbox?.state, .on)
            XCTAssertNotNil(app.settingsPanel?.attachedSheet)
            dismissSheet(app)

            // Nothing applies a setting that wasn't saved.
            app.claudeStatusLineInstaller = { _ in XCTFail("installed a status line that wasn't saved") }
            try click(app.settingsUsageLimitsCheckbox)
            XCTAssertEqual(app.settingsUsageLimitsCheckbox?.state, .off)
        }
    }

    // MARK: - Sidebar approvals

    /// On by default, and receivers only wait on a running app that has it
    /// on.
    @MainActor
    func testSidebarApprovalsApplyAtOnce() throws {
        try withIsolatedState {
            let hooks = AgentHookCenter.shared
            defer { hooks.approvalsEnabled = false }
            let app = try openSettings()
            defer { close(app) }
            XCTAssertEqual(app.settingsSidebarApprovalsCheckbox?.state, .on)

            try click(app.settingsSidebarApprovalsCheckbox)
            XCTAssertEqual(Persistence.load()?.settings?.sidebarApprovalsEnabled, false)

            try click(app.settingsSidebarApprovalsCheckbox)
            XCTAssertEqual(Persistence.load()?.settings?.sidebarApprovalsEnabled, true)
            XCTAssertTrue(hooks.approvalsEnabled)
            XCTAssertTrue(PermissionApprovalChannel.standard.isAppListening(), "receivers see this app")

            try click(app.settingsSidebarApprovalsCheckbox)
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

    /// On by default; turning it off reaches the window at once, and stays
    /// off in a later Settings window.
    @MainActor
    func testAnimationsAreOnByDefaultAndTurningThemOffAppliesAtOnce() throws {
        try withIsolatedState {
            let shell = makeShell()
            XCTAssertTrue(shell.animatesInterface)
            let app = try openSettings()
            defer { close(app) }
            app.shell = shell
            XCTAssertEqual(app.settingsAnimationsCheckbox?.state, .on)

            try click(app.settingsAnimationsCheckbox)

            XCTAssertFalse(shell.animatesInterface)
            XCTAssertEqual(Persistence.load()?.settings?.animatesInterface, false)
            XCTAssertFalse(makeShell().animatesInterface, "a window opened later starts without them")
            close(app)

            let reopened = try openSettings()
            defer { close(reopened) }
            XCTAssertEqual(reopened.settingsAnimationsCheckbox?.state, .off)
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

    // MARK: - Appearance

    /// Settings › Appearance, second: four tiles, Opaque until the user
    /// picks (the default flips only with the user's OK). A pick applies to
    /// the window at once and is saved; VoiceOver reads a radio group. A level
    /// a newer build saved survives a save of another setting.
    @MainActor
    func testAppearancePicksTheInterfacesTransparency() throws {
        try withIsolatedState {
            let shell = makeShell()
            let app = try openSettings(shell: shell)
            defer { close(app) }
            let settings = try XCTUnwrap(app.settingsController)
            XCTAssertEqual(settings.appPanes.map(\.title), ["General", "Appearance", "Agents", "Notifications"])
            let picker = try XCTUnwrap(app.settingsTransparencyPicker)
            XCTAssertEqual(picker.selection, .opaque)
            XCTAssertEqual(picker.accessibilityRole(), .radioGroup)
            XCTAssertEqual(picker.tiles.map { $0.accessibilityLabel() ?? "" }, ["Opaque", "Tinted", "Glass", "Clear"])
            XCTAssertEqual(picker.tiles.map { $0.accessibilityValue() as? Int }, [1, 0, 0, 0])

            XCTAssertTrue(picker.tiles[2].accessibilityPerformPress())
            XCTAssertEqual(picker.selection, .glass)
            XCTAssertEqual(shell.interfaceTransparency, .glass, "at once")
            XCTAssertEqual(Persistence.load()?.settings?.interfaceTransparency, .glass)
            XCTAssertEqual(picker.tiles.map { $0.accessibilityValue() as? Int }, [0, 0, 1, 0])
            XCTAssertEqual(NiruxShellView.currentInterfaceTransparency(), .glass)
            XCTAssertNotNil(app.settingsAnimationsCheckbox, "Animate the interface moved here")
            // What the level shows and macOS's note are one block: the
            // section's gap below stays when the note hides.
            let summary = try XCTUnwrap(picker.superview?.subviews.compactMap { $0 as? TransparencySummary }.first)
            XCTAssertEqual(summary.line.stringValue, InterfaceTransparency.glass.summary)
            XCTAssertEqual((summary.superview as? NSStackView)?.customSpacing(after: summary), 22)
            XCTAssertFalse(summary.forcedOpaque.isBezeled, "a hint, as the others")

            let stateFile = Persistence.stateDirectory.appendingPathComponent("state.json")
            try Data(#"{"workspaces":[],"activeWorkspaceIndex":0,"settings":{"interfaceTransparency":"frosted"}}"#.utf8)
                .write(to: stateFile)
            XCTAssertEqual(NiruxShellView.currentInterfaceTransparency(), .opaque, "an unknown level reads as no choice")
            try click(app.settingsNoFlickerCheckbox)
            XCTAssertTrue(try String(contentsOf: stateFile, encoding: .utf8).contains(#""interfaceTransparency":"frosted""#))
        }
    }

    /// Appearance › Terminals: a slider from 60 to 100 %, by fives; a move
    /// reaches the shell at once, and is saved once the slider stays still.
    @MainActor
    func testTheTerminalsBackgroundSlider() throws {
        try withIsolatedState {
            let shell = makeShell()
            let app = try openSettings(shell: shell)
            defer { close(app) }
            let slider = try XCTUnwrap(app.settingsTerminalOpacitySlider)
            XCTAssertEqual(slider.doubleValue, 100)
            XCTAssertEqual(slider.minValue, 60)
            XCTAssertEqual(slider.numberOfTickMarks, 9)
            XCTAssertEqual(app.settingsTerminalOpacityLabel?.stringValue, "100%")
            @MainActor func move(to value: Double) {
                slider.doubleValue = value
                XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
            }
            move(to: 90)
            move(to: 80)
            let still = Date()
            XCTAssertEqual(app.settingsTerminalOpacityLabel?.stringValue, "80%")
            XCTAssertEqual(shell.terminalOpacity, 0.8, "the terminals follow every step")
            XCTAssertNil(Persistence.load()?.settings?.terminalOpacity, "nothing saved mid-gesture")
            waitUntil("80% saved", timeout: 10) { Persistence.load()?.settings?.terminalOpacity == 0.8 }
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(still), NiruxApp.terminalOpacitySaveDelay, "once the slider stayed still")
            move(to: 100)
            waitUntil("100% saves no choice", timeout: 10) { Persistence.load()?.settings?.terminalOpacity == nil }
        }
    }

    /// macOS's Reduce transparency or Increase contrast: the pane says Nirux
    /// draws opaque.
    func testTheForcedOpaqueNoteNamesWhatMacOSDoes() {
        XCTAssertNil(TransparencySummary.forcedOpaqueText(reducesTransparency: false, increasesContrast: false))
        XCTAssertEqual(
            TransparencySummary.forcedOpaqueText(reducesTransparency: true, increasesContrast: true),
            "Reduce transparency is on in System Settings › Accessibility › Display: Nirux draws opaque."
        )
        XCTAssertEqual(
            TransparencySummary.forcedOpaqueText(reducesTransparency: false, increasesContrast: true),
            "Increase contrast is on in System Settings › Accessibility › Display: Nirux draws opaque."
        )
    }

    // MARK: - Branch Review's Explain

    /// Opus 5.5 at medium unless chosen otherwise; Explain's next run takes
    /// the choice. A model set by hand stays selectable, unless it could
    /// pass for one of claude's options; an unknown effort reads as medium.
    @MainActor
    func testExplainModelAndEffort() throws {
        try withIsolatedState {
            let app = try openSettings()
            XCTAssertEqual(app.settingsExplainModelPopup?.itemTitles, ["Opus 5.5", "Sonnet 5.5"])
            XCTAssertEqual(app.settingsExplainEffortPopup?.itemTitles, ["Low", "Medium", "High", "Extra high", "Max"])
            XCTAssertEqual(selectedRawValue(app.settingsExplainModelPopup), "claude-opus-5-5")
            XCTAssertEqual(selectedRawValue(app.settingsExplainEffortPopup), "medium")

            // The shown default, picked again: nothing to write.
            try choose("claude-opus-5-5", in: app.settingsExplainModelPopup)
            XCTAssertNil(Persistence.load())
            try choose("claude-sonnet-5-5", in: app.settingsExplainModelPopup)
            try choose("xhigh", in: app.settingsExplainEffortPopup)
            XCTAssertEqual(BranchReview.ExplainSettings.saved().model, "claude-sonnet-5-5")
            XCTAssertEqual(BranchReview.ExplainSettings.saved().effort, "xhigh")
            // The default is saved as none: a later default reaches it.
            try choose("claude-opus-5-5", in: app.settingsExplainModelPopup)
            XCTAssertNil(Persistence.load()?.settings?.explainModel)
            XCTAssertEqual(BranchReview.ExplainSettings.saved().model, "claude-opus-5-5")
            close(app)

            // A dated id keeps its own item: a popup keeps one per title.
            var state = try XCTUnwrap(Persistence.load())
            state.settings?.explainModel = "claude-opus-5-5-20261001"
            XCTAssertTrue(Persistence.save(state))
            let reopened = try openSettings()
            XCTAssertEqual(reopened.settingsExplainModelPopup?.itemTitles, ["Opus 5.5", "Sonnet 5.5", "claude-opus-5-5-20261001"])
            XCTAssertEqual(selectedRawValue(reopened.settingsExplainModelPopup), "claude-opus-5-5-20261001")
            XCTAssertEqual(selectedRawValue(reopened.settingsExplainEffortPopup), "xhigh")
            close(reopened)

            // Unknown: the defaults show, and picking them keeps the value.
            state.settings?.explainModel = "a--dangerously-skip-permissions"
            state.settings?.explainEffort = "turbo"
            XCTAssertTrue(Persistence.save(state))
            let guarded = try openSettings()
            defer { close(guarded) }
            XCTAssertEqual(guarded.settingsExplainModelPopup?.itemTitles, ["Opus 5.5", "Sonnet 5.5"])
            XCTAssertEqual(selectedRawValue(guarded.settingsExplainEffortPopup), "medium")
            XCTAssertEqual(BranchReview.ExplainSettings.saved(), BranchReview.ExplainSettings())
            try choose("medium", in: guarded.settingsExplainEffortPopup)
            XCTAssertEqual(Persistence.load()?.settings?.explainEffort, "turbo")
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
            let agents = try XCTUnwrap(app.settingsController?.appPanes.first { $0.title == "Agents" }?.view)
            let texts = Self.descendants(of: agents).compactMap { ($0 as? NSTextField)?.stringValue }
            XCTAssertTrue(texts.contains(NiruxApp.usageLimitsHint(for: .foreign)))
            XCTAssertFalse(texts.contains(NiruxApp.usageLimitsHint(for: .none)))
        }
    }

    // MARK: - Window

    /// A sidebar of panes, Nirux's then the space's; the window keeps its
    /// width and fits each pane's height, top edge fixed, so nothing is cut
    /// off whichever pane is picked.
    @MainActor
    func testTheSidebarAndEachPaneFitTheWindow() throws {
        try withIsolatedState {
            let shell = makeShell()
            let app = try openSettings(shell: shell)
            defer { close(app) }
            let settings = try XCTUnwrap(app.settingsController)
            let window = try XCTUnwrap(app.settingsPanel)
            // A panel never keeps Nirux running once the main window closes,
            // and keys typed in it never reach a terminal.
            XCTAssertTrue(window is NSPanel)
            XCTAssertNil(window.toolbar, "no tabs")
            let panes = settings.sidebar.rows.compactMap(\.selection)
            XCTAssertEqual(panes.count, 4 + SpaceSettingsSection.Tab.allCases.count)

            // Tallest first, so a window that keeps the previous size would cut the next pane.
            @MainActor func height(_ selection: SettingsWindow.Selection) -> CGFloat {
                settings.select(selection)
                return settings.selectedView?.fittingSize.height ?? 0
            }
            let order = panes.sorted { height($0) > height($1) }
            settings.select(try XCTUnwrap(order.last))
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            // From the window's own fit: AppKit may narrow a panel as it
            // shows on a small screen (CI's), before the window fits again.
            settings.fitToContent()
            let top = window.frame.maxY
            let width = window.frame.width
            for selection in order.reversed() + order {
                settings.select(selection)
                // Let AppKit run any resize it schedules on its own.
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                let label = window.title
                XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5, "\(label): the top edge stays put")
                XCTAssertEqual(window.frame.width, width, accuracy: 0.5, "\(label): the width stays")
                let pane = try XCTUnwrap(settings.selectedView)
                let content = try XCTUnwrap(window.contentView)
                content.layoutSubtreeIfNeeded()
                XCTAssertEqual(
                    content.bounds.height, max(pane.fittingSize.height, settings.sidebar.contentHeight), accuracy: 1, label
                )
                for control in Self.descendants(of: pane).compactMap({ $0 as? NSControl }) where !control.isHiddenOrHasHiddenAncestor {
                    let frame = control.convert(control.bounds, to: content)
                    XCTAssertTrue(content.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(label): \(control) is cut off")
                }
            }
        }
    }

    /// On a screen narrower than the window (CI's 1024 pt), the widest pane
    /// (Memory's list) never makes AppKit widen the window back: it keeps
    /// its left side in view; a narrow pane stays centred in a wide window.
    @MainActor
    func testAWidePaneNeverWidensTheWindow() throws {
        try withIsolatedState {
            let shell = makeShell()
            let app = try openSettings(shell: shell)
            defer { close(app) }
            let settings = try XCTUnwrap(app.settingsController)
            let window = try XCTUnwrap(app.settingsPanel)
            settings.select(.app("general"))
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let general = try XCTUnwrap(settings.selectedView)
            let host = try XCTUnwrap(general.superview)
            XCTAssertEqual(general.frame.midX, host.bounds.midX, accuracy: 1, "centred")

            settings.select(.space(.memory))
            var frame = window.frame
            frame.size.width = 1024
            window.setFrame(frame, display: true)
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(window.frame.width, 1024, accuracy: 0.5, "the window keeps the screen's width")
            let memory = try XCTUnwrap(settings.selectedView)
            XCTAssertEqual(memory.frame.minX, 0, accuracy: 0.5, "its left side in view")
        }
    }

    /// One window: Nirux's panes, then the active space's; its title names
    /// the pane. Space Settings… shows a space in it, the popup another, the
    /// sidebar walks the panes, and ⌘, opens it again on the pane last
    /// shown.
    @MainActor
    func testOneWindowHoldsNiruxThenTheSpace() throws {
        try withIsolatedState {
            let shell = makeShell()
            let acme = shell.workspaceStore.createProfile(named: "Acme", select: true)
            let beta = shell.workspaceStore.createProfile(named: "Beta", select: false)
            let app = try openSettings(shell: shell)
            defer { close(app) }
            let settings = try XCTUnwrap(app.settingsController)
            XCTAssertIdentical(settings, shell.settingsWindow, "the shell's window, for the space's panes")
            let window = try XCTUnwrap(app.settingsPanel)
            XCTAssertEqual(settings.sidebar.rows.map(Self.title), [
                "Nirux", "General", "Appearance", "Agents", "Notifications",
                "Acme", "General", "Defaults", "Lead", "Brief", "Memory", "Board", "Templates"
            ])
            XCTAssertEqual(settings.selection, .app("general"), "Nirux's first pane")
            XCTAssertEqual(window.title, "General")
            XCTAssertEqual(shell.spaceSettings?.spaceID, acme.id, "the active space")
            XCTAssertNil(shell.spaceSettings?.selectedTab)

            // The sidebar walks the panes: ↓ and ↑ step over the space's
            // header; a click on a header, or below the rows, keeps the pane.
            let table = settings.sidebar.table
            let header = try XCTUnwrap(settings.sidebar.rows.firstIndex { if case .space = $0 { true } else { false } })
            table.selectRowIndexes([header - 1], byExtendingSelection: false)
            XCTAssertEqual(settings.selection, .app("notifications"))
            table.keyDown(with: try arrow(down: true, in: window))
            XCTAssertEqual(settings.selection, .space(.general), "↓ over the space's header")
            table.keyDown(with: try arrow(down: false, in: window))
            XCTAssertEqual(settings.selection, .app("notifications"), "↑ back over it")
            let picked = table.selectedRowIndexes
            XCTAssertEqual(settings.sidebar.tableView(table, selectionIndexesForProposedSelection: [0]), picked, "Nirux's header is no pane")
            XCTAssertEqual(settings.sidebar.tableView(table, selectionIndexesForProposedSelection: []), picked, "a click below the rows")
            XCTAssertEqual(settings.sidebar.tableView(table, selectionIndexesForProposedSelection: [header + 2]), [header + 2])
            let lead = try XCTUnwrap(settings.sidebar.rows.firstIndex { $0.selection == .space(.lead) })
            table.selectRowIndexes([lead], byExtendingSelection: false)
            XCTAssertEqual(settings.selection, .space(.lead))
            XCTAssertEqual(shell.spaceSettings?.selectedTab, .lead)
            XCTAssertEqual(window.title, "Acme — Lead")
            // Tab goes on from the sidebar into the pane shown (its name
            // field: with Full Keyboard Access off, only text and lists take
            // Tab).
            settings.select(.space(.general))
            window.makeFirstResponder(table)
            // With Full Keyboard Access on, the space's popup comes first.
            for _ in 0..<3 {
                guard let view = window.firstResponder as? NSView, view.isDescendant(of: settings.sidebar.view) else { break }
                window.selectNextKeyView(nil)
            }
            let focused = try XCTUnwrap(window.firstResponder as? NSView)
            XCTAssertTrue(focused.isDescendant(of: try XCTUnwrap(settings.selectedView)), "\(focused)")
            // A pane that loads (Memory, Board) takes the keyboard only if the
            // sidebar hasn't it.
            let pane = try XCTUnwrap(settings.selectedView)
            XCTAssertTrue(window.keyboardIsFree(for: pane), "its own field")
            window.makeFirstResponder(table)
            XCTAssertFalse(window.keyboardIsFree(for: pane), "the sidebar keeps it")
            window.makeFirstResponder(nil)
            XCTAssertTrue(window.keyboardIsFree(for: pane))
            settings.select(.space(.lead))

            // Space Settings… on another space: the same window, that space.
            shell.showSpaceSettings(profileID: beta.id)
            XCTAssertIdentical(app.settingsPanel, window)
            XCTAssertEqual(shell.spaceSettings?.spaceID, beta.id)
            XCTAssertEqual(settings.selection, .space(.general))
            XCTAssertEqual(window.title, "Beta — General")

            // The popup: back to Acme, on the pane shown; it lists a space
            // made while the window is open.
            settings.select(.space(.defaults))
            let popup = try spacePopup(settings)
            let gamma = shell.workspaceStore.createProfile(named: "Gamma", select: false)
            settings.sidebar.menuNeedsUpdate(try XCTUnwrap(popup.menu))
            XCTAssertEqual(popup.itemTitles, shell.profiles.map(\.name))
            XCTAssertTrue(popup.itemTitles.contains(gamma.name))
            XCTAssertEqual(popup.titleOfSelectedItem, "Beta")
            popup.selectItem(withTitle: "Acme")
            popup.sendAction(popup.action, to: popup.target)
            XCTAssertEqual(shell.spaceSettings?.spaceID, acme.id)
            XCTAssertEqual(settings.selection, .space(.defaults))
            XCTAssertEqual(try spacePopup(settings).titleOfSelectedItem, "Acme")
            // The space shown, picked again: nothing to do.
            var picks = 0
            let pick = settings.sidebar.onPickSpace
            settings.sidebar.onPickSpace = { picks += 1; pick?($0) }
            let same = try spacePopup(settings)
            same.selectItem(withTitle: "Acme")
            same.sendAction(same.action, to: same.target)
            XCTAssertEqual(picks, 0)
            settings.sidebar.onPickSpace = pick

            // Text typed and not saved keeps its space: the popup says so.
            let section = try XCTUnwrap(shell.spaceSettings)
            // Said in the window; the user dismisses it.
            section.askInSheet = { _, _, answer in answer(.alertFirstButtonReturn) }
            section.brief.textView.string += "Draft.\n"
            section.brief.textDidChange(Notification(name: NSText.didChangeNotification))
            let unsaved = try spacePopup(settings)
            unsaved.selectItem(withTitle: "Beta")
            unsaved.sendAction(unsaved.action, to: unsaved.target)
            XCTAssertIdentical(shell.spaceSettings, section)
            XCTAssertEqual(settings.selection, .space(.brief), "on the text not saved")
            XCTAssertEqual(try spacePopup(settings).titleOfSelectedItem, "Acme")
            section.brief.revert()

            // From one of Nirux's panes, the popup changes the space listed,
            // not the pane.
            settings.select(.app("notifications"))
            let fromNirux = try spacePopup(settings)
            fromNirux.selectItem(withTitle: "Beta")
            fromNirux.sendAction(fromNirux.action, to: fromNirux.target)
            XCTAssertEqual(shell.spaceSettings?.spaceID, beta.id)
            XCTAssertEqual(settings.selection, .app("notifications"))
            XCTAssertEqual(window.title, "Notifications")

            // A sheet of the space's panes keeps its space.
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            sheet.isReleasedWhenClosed = false
            /// As the space's panes put one up: recorded until it ends.
            @MainActor func beginSpaceSheet() throws {
                let ended = try XCTUnwrap(shell.spaceSettings).noteSheet(sheet, on: window)
                window.beginSheet(sheet) { _ in MainActor.assumeIsolated { ended() } }
            }
            try beginSpaceSheet()
            XCTAssertIdentical(window.attachedSheet, sheet)
            var refusal: (reason: String, window: NSWindow)?
            shell.spaceSettings?.askInSheet = { alert, parent, answer in
                refusal = (alert.messageText, parent)
                answer(.alertFirstButtonReturn)
            }
            shell.showSpaceSettings(profileID: acme.id)
            XCTAssertEqual(shell.spaceSettings?.spaceID, beta.id)
            XCTAssertIdentical(window.attachedSheet, sheet, "still up")
            XCTAssertEqual(refusal?.reason, "Finish what is open in this space’s settings first")
            XCTAssertIdentical(refusal?.window, sheet, "said in the window, over the sheet")
            window.endSheet(sheet)

            // Nirux's own sheet (the tasks folder's chooser) is no space's:
            // it neither keeps the space shown nor goes with it.
            let delta = shell.workspaceStore.createProfile(named: "Delta", select: false)
            let chooser = NSWindow(contentRect: sheet.frame, styleMask: [.titled], backing: .buffered, defer: false)
            chooser.isReleasedWhenClosed = false
            shell.sideEffects.chooseFolder = { _, parent, _ in parent?.beginSheet(chooser) }
            app.settingsChangeTasksFolder(NSButton())
            XCTAssertIdentical(window.attachedSheet, chooser)
            shell.showSpaceSettings(profileID: delta.id, tab: nil)
            XCTAssertEqual(shell.spaceSettings?.spaceID, delta.id, "Nirux's sheet keeps no space")
            shell.deleteSpace(profileID: delta.id)
            XCTAssertNotEqual(shell.spaceSettings?.spaceID, delta.id)
            XCTAssertIdentical(window.attachedSheet, chooser, "nor goes with one")
            window.endSheet(chooser)
            shell.showSpaceSettings(profileID: beta.id, tab: nil)

            // A question of the space's queued behind Nirux's sheet keeps
            // the space too.
            window.beginSheet(chooser)
            let queued = NSAlert()
            try XCTUnwrap(shell.spaceSettings).ask(queued, on: window) { _ in }
            shell.showSpaceSettings(profileID: acme.id, tab: nil)
            XCTAssertEqual(shell.spaceSettings?.spaceID, beta.id, "kept by its queued question")
            window.endSheet(chooser)
            if let up = window.attachedSheet { window.endSheet(up) }

            // The space shown is deleted: the window stays, on the active
            // space, Nirux's pane still shown; a sheet of its panes goes.
            try beginSpaceSheet()
            shell.deleteSpace(profileID: beta.id)
            XCTAssertNil(window.attachedSheet)
            XCTAssertIdentical(app.settingsPanel, window)
            XCTAssertEqual(shell.spaceSettings?.spaceID, acme.id)
            XCTAssertEqual(settings.selection, .app("notifications"))
            XCTAssertFalse(settings.sidebar.rows.map(Self.title).contains("Beta"))

            // A space's pane shows again only for that space.
            settings.select(.space(.lead))
            window.performClose(nil)
            XCTAssertTrue(shell.workspaceStore.selectProfile(gamma.id))
            app.showSettings(nil)
            XCTAssertEqual(shell.spaceSettings?.spaceID, gamma.id)
            XCTAssertEqual(settings.selection, .app("notifications"), "Nirux's pane last shown")

            // Space Settings… opens with the sidebar's keyboard; Space Memory…
            // with no list to show (no folder) leaves it there, never nowhere.
            app.settingsPanel?.performClose(nil)
            shell.showSpaceSettings(profileID: acme.id)
            let reopened = try XCTUnwrap(app.settingsPanel)
            XCTAssertIdentical(reopened.firstResponder, settings.sidebar.table)
            shell.showSpaceSettings(profileID: acme.id, tab: .memory)
            XCTAssertIdentical(reopened.firstResponder, settings.sidebar.table)

            // Closed, ⌘, opens it again on the pane last shown.
            settings.select(.app("agents"))
            app.settingsPanel?.performClose(nil)
            XCTAssertNil(app.settingsPanel)
            XCTAssertNil(shell.spaceSettings)
            app.showSettings(nil)
            XCTAssertEqual(settings.selection, .app("agents"))
            XCTAssertEqual(app.settingsPanel?.title, "Agents")
        }
    }

    /// Closing Settings leaves the keyboard of the main window where it was:
    /// typing in an editor, or in the sidebar, ⌘, then ⌘W, it still has it.
    /// With nothing holding it, the task's terminal takes it.
    @MainActor
    func testClosingSettingsLeavesTheMainWindowsKeyboard() throws {
        try withIsolatedState {
            let shell = makeShell()
            let main = NSWindow(contentRect: shell.frame, styleMask: [.titled], backing: .buffered, defer: false)
            main.isReleasedWhenClosed = false
            main.contentView = shell
            defer { main.close() }
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
            try XCTUnwrap(shell.activeWorkspace).containerView.addSubview(editor)
            XCTAssertTrue(main.makeFirstResponder(editor))
            let app = try openSettings(shell: shell)
            defer { close(app) }
            XCTAssertNotNil(shell.spaceSettings, "the active space's panes, in the window")
            app.settingsPanel?.performClose(nil)
            XCTAssertNil(app.settingsPanel)
            XCTAssertIdentical(main.firstResponder, editor)

            let sidebarField = NSTextView(frame: editor.frame)
            shell.sidebar.addSubview(sidebarField)
            XCTAssertTrue(main.makeFirstResponder(sidebarField))
            app.showSettings(nil)
            app.settingsPanel?.performClose(nil)
            XCTAssertIdentical(main.firstResponder, sidebarField, "the sidebar's field")

            main.makeFirstResponder(nil)
            app.showSettings(nil)
            app.settingsPanel?.performClose(nil)
            let focused = try XCTUnwrap(main.firstResponder as? NSView, "the task's terminal")
            XCTAssertTrue(focused.isDescendant(of: try XCTUnwrap(shell.activeWorkspace).containerView), "\(focused)")
        }
    }

    @MainActor
    private static func title(_ row: SettingsSidebar.Row) -> String {
        switch row {
        case .header(let title): return title
        case .space(let header): return header.current.name
        case .pane(_, let title, _): return title
        }
    }

    @MainActor
    private func arrow(down: Bool, in window: NSWindow) throws -> NSEvent {
        let character = String(UnicodeScalar(down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey)!)
        return try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: down ? 125 : 126
        ))
    }

    /// The popup on the space's header.
    @MainActor
    private func spacePopup(_ settings: SettingsWindow) throws -> NSPopUpButton {
        let index = try XCTUnwrap(settings.sidebar.rows.firstIndex { if case .space = $0 { true } else { false } })
        let cell = try XCTUnwrap(settings.sidebar.table.view(atColumn: 0, row: index, makeIfNecessary: true))
        return try XCTUnwrap(Self.descendants(of: cell).compactMap { $0 as? NSPopUpButton }.first)
    }

    // MARK: - Helpers

    @MainActor
    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
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
    private func openSettings(
        statusLine: AgentHookInstaller.ClaudeStatusLineState = .none, shell: NiruxShellView? = nil
    ) throws -> NiruxApp {
        _ = NSApplication.shared
        let app = NiruxApp()
        app.shell = shell
        // Keep Settings off ~/.claude.
        app.claudeStatusLineStateReader = { statusLine }
        app.claudeStatusLineInstaller = { _ in }
        app.showSettings(nil)
        _ = try XCTUnwrap(app.settingsPanel)
        return app
    }

    @MainActor
    private func close(_ app: NiruxApp) {
        dismissSheet(app)
        app.settingsPanel?.orderOut(nil)
        app.settingsPanel?.close()
    }

    @MainActor
    private func dismissSheet(_ app: NiruxApp) {
        if let sheet = app.settingsPanel?.attachedSheet {
            app.settingsPanel?.endSheet(sheet)
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
    private func selectedRawValue(_ popup: NSPopUpButton?) -> String? {
        popup?.selectedItem?.representedObject as? String
    }
}

