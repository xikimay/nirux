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
            XCTAssertNil(app.settingsWindow?.attachedSheet)
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
            XCTAssertTrue(Persistence.save(state))
            let shell = makeShell()
            XCTAssertTrue(shell.circlingHintEnabled, "the default, before the state is read")
            XCTAssertTrue(shell.turnStatusEnabled)
            shell.restoreState()
            XCTAssertFalse(shell.circlingHintEnabled)
            XCTAssertFalse(shell.turnStatusEnabled)
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
            try click(app.settingsTurnStatusCheckbox)
            XCTAssertNotNil(AgentHookCenter.shared.turnStatusWriter)
            XCTAssertTrue(shell.turnStatusEnabled)

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
            let agents = try XCTUnwrap(app.settingsTabs.tabViewItems.first { $0.label == "Agents" }?.viewController?.view)
            let texts = Self.descendants(of: agents).compactMap { ($0 as? NSTextField)?.stringValue }
            XCTAssertTrue(texts.contains(NiruxApp.usageLimitsHint(for: .foreign)))
            XCTAssertFalse(texts.contains(NiruxApp.usageLimitsHint(for: .none)))
        }
    }

    // MARK: - Window

    /// Toolbar tabs; the window fits each pane, so nothing is cut off
    /// whichever tab is picked.
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
            XCTAssertEqual(tabs.tabViewItems.map(\.label), ["General", "Agents", "Notifications"])
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
    private func openSettings(statusLine: AgentHookInstaller.ClaudeStatusLineState = .none) throws -> NiruxApp {
        _ = NSApplication.shared
        let app = NiruxApp()
        // Keep Settings off ~/.claude.
        app.claudeStatusLineStateReader = { statusLine }
        app.claudeStatusLineInstaller = { _ in }
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
