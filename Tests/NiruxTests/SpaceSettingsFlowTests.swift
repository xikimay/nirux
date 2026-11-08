import AppKit
import XCTest
@testable import Nirux

/// Space Settings and the space's defaults through the shell (docs/spaces.md,
/// S8; docs/projects.md, section 5): what launches and shells get, the
/// setup script typed before the agent, and the window's tabs.
@MainActor
final class SpaceSettingsFlowTests: XCTestCase {
    private func anchoredSpace(_ harness: UIFlowHarness, named name: String = "Web") throws -> WorkspaceProfile {
        let repository = try XCTUnwrap(FolderIdentity.identify(harness.repo, timeout: 10)).anchor
        return harness.shell.workspaceStore.createProfile(named: name, anchors: [repository], select: false)
    }

    private func save(_ defaults: SpaceDefaults, for space: WorkspaceProfile) throws {
        _ = try XCTUnwrap(SpaceDefaultsStore(spaceID: space.id)).save(defaults).get()
    }

    private func workspace(_ harness: UIFlowHarness, _ title: String) -> WorkspaceState? {
        harness.shell.workspaces.first { $0.title == title && !$0.isClosing }
    }

    // MARK: - Launches and shells

    /// The space's modes beat Settings' for a fresh launch; its variables
    /// reach new shells under Nirux's own, and never a workspace opened
    /// from outside Nirux.
    func testTheSpaceDefaultsReachLaunchesAndShells() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let space = try anchoredSpace(harness)
            try save(SpaceDefaults(
                claudeLaunchMode: .plan, codexLaunchMode: .readOnly,
                environment: [
                    .init(name: "API_URL", value: "http://localhost:4000"),
                    .init(name: "NIRUX_WORKSPACE_ID", value: "spoofed")
                ]
            ), for: space)

            shell.addWorkspace(title: "claude", cwd: harness.repo, agent: .claude, profileID: space.id)
            harness.waitUntil("the Claude launch") { harness.agentLaunches.contains { $0.hasPrefix("command claude") } }
            XCTAssertTrue(harness.agentLaunches.last?.contains("--permission-mode plan") == true, harness.agentLaunches.last ?? "")
            let claude = try XCTUnwrap(workspace(harness, "claude"))
            shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0 === claude }))
            shell.openCodex()
            let codexFlags = CodexLaunchMode.readOnly.cliArgs.joined(separator: " ")
            XCTAssertTrue(harness.agentLaunches.last?.hasPrefix("command codex " + codexFlags) == true, harness.agentLaunches.last ?? "")

            let environment = claude.terminalEnvironment(agentUUID: "A-1")
            XCTAssertEqual(environment["API_URL"], "http://localhost:4000")
            XCTAssertEqual(environment["NIRUX_WORKSPACE_ID"], claude.id, "never replaced")

            // A space without defaults: Settings' mode, no variable.
            shell.addWorkspace(title: "general", cwd: harness.root, agent: .claude, profileID: WorkspaceProfile.defaultID)
            XCTAssertFalse(harness.agentLaunches.last?.contains("--permission-mode plan") == true)
            XCTAssertNil(try XCTUnwrap(workspace(harness, "general")).terminalEnvironment(agentUUID: "A-2")["API_URL"])

            // From outside Nirux, in the same space: none of it, after a
            // relaunch too.
            shell.openRequestedWorkspace(
                title: "outside", cwd: harness.worktree, agent: nil, requestedSpaceID: nil, startedOutsideNirux: true
            )
            harness.waitUntil("the request's workspace") { workspace(harness, "outside") != nil }
            let outside = try XCTUnwrap(workspace(harness, "outside"))
            XCTAssertEqual(outside.profileID, space.id)
            XCTAssertNil(outside.terminalEnvironment(agentUUID: "A-3")["API_URL"])
            let persisted = try XCTUnwrap(shell.persistedState().workspaces.first { $0.id == outside.id })
            XCTAssertTrue(persisted.startedOutsideNirux)
        }
    }

    /// A worktree Nirux makes runs its repository's script, then the agent;
    /// one asked for from outside Nirux, or an existing worktree opened,
    /// doesn't. Without an agent the script runs alone.
    func testTheSetupScriptRunsBeforeTheAgentInNewWorktreesOnly() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let space = try anchoredSpace(harness)
            let anchor = try XCTUnwrap(space.anchors.first)
            let script = try XCTUnwrap(SpaceSetupScript.url(spaceID: space.id, anchor: anchor))
            try SpaceSetupScript.save("touch .setup-ran", to: script)
            let prefix = "/bin/sh '\(script.path)'"

            shell.createWorktreeWorkspace(branch: "feat/setup", repoRoot: harness.repo, agent: .claude)
            harness.waitUntil("the worktree's workspace") { workspace(harness, "feat/setup") != nil }
            XCTAssertEqual(workspace(harness, "feat/setup")?.profileID, space.id)
            let typed = try XCTUnwrap(harness.agentLaunches.last)
            // xctest isn't Nirux: no executable to report a failure with.
            XCTAssertTrue(typed.hasPrefix(prefix + "; command claude"), typed)

            shell.createWorktreeWorkspace(branch: "feat/bare", repoRoot: harness.repo, agent: nil)
            harness.waitUntil("the second worktree's workspace") { workspace(harness, "feat/bare") != nil }
            XCTAssertEqual(harness.agentLaunches.last, prefix)

            let count = harness.agentLaunches.count
            shell.createWorktreeWorkspace(branch: "feat/outside", repoRoot: harness.repo, agent: .claude, startedOutsideNirux: true)
            harness.waitUntil("the outside worktree's workspace") { workspace(harness, "feat/outside") != nil }
            XCTAssertEqual(harness.agentLaunches.count, count + 1)
            XCTAssertTrue(harness.agentLaunches.last?.hasPrefix("command claude") == true, harness.agentLaunches.last ?? "")

            shell.openRoutedWorkspace(title: "existing", cwd: harness.worktree, agent: .claude, startedFromSpaceID: space.id)
            harness.waitUntil("the existing worktree's workspace") { workspace(harness, "existing") != nil }
            XCTAssertTrue(harness.agentLaunches.last?.hasPrefix("command claude") == true, harness.agentLaunches.last ?? "")
        }
    }

    /// `--setup-failed` for a workspace: its card turns red and a
    /// notification goes out; an unknown id does nothing.
    func testASetupFailureNotifies() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.addWorkspace(title: "failing", cwd: harness.repo)
            let failing = try XCTUnwrap(workspace(harness, "failing"))
            shell.addWorkspace(title: "other", cwd: harness.repo)

            shell.setupScriptFailed(workspaceID: UUID().uuidString)
            XCTAssertEqual(harness.setupFailures, [])
            shell.setupScriptFailed(workspaceID: failing.id)
            XCTAssertEqual(harness.setupFailures, [failing.id])
            XCTAssertEqual(failing.notification, .error)
        }
    }

    /// New Task… preselects the space's agent until the user picks one.
    func testNewTaskPreselectsTheSpaceAgent() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let space = try anchoredSpace(harness, named: "Codex Space")
            try save(SpaceDefaults(agent: .codex), for: space)
            shell.selectProfile(space.id)
            shell.showNewTaskPanel()
            let form = try XCTUnwrap(shell.newTaskPanel)
            XCTAssertEqual(form.selectedAgent, .codex)

            form.projectPopup.selectItem(withTitle: try XCTUnwrap(shell.profiles.first { $0.id == WorkspaceProfile.defaultID }).name)
            form.projectChanged(nil)
            XCTAssertEqual(form.selectedAgent, .claude, "General sets none")

            form.agentPopup.selectItem(withTitle: "Codex")
            form.agentPopup.sendAction(form.agentPopup.action, to: form.agentPopup.target)
            form.projectPopup.selectItem(withTitle: "Codex Space")
            form.projectChanged(nil)
            form.projectPopup.selectItem(withTitle: try XCTUnwrap(shell.profiles.first { $0.id == WorkspaceProfile.defaultID }).name)
            form.projectChanged(nil)
            XCTAssertEqual(form.selectedAgent, .codex, "the user's pick stays")
            form.dismiss()
        }
    }

    // MARK: - The window

    /// Each change on the Defaults tab is written at once; a variable with
    /// a problem isn't, until it's fixed.
    func testTheDefaultsTabWritesEachValidChange() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let space = try anchoredSpace(harness)
            let store = try XCTUnwrap(SpaceDefaultsStore(spaceID: space.id))
            shell.showSpaceSettings(profileID: space.id, tab: .defaults)
            let settings = try XCTUnwrap(shell.spaceSettings)
            XCTAssertEqual(settings.selectedTab, .defaults)
            let pane = settings.defaults
            XCTAssertTrue(pane.claudePopup.titleOfSelectedItem?.hasPrefix("Same as Settings") == true)

            @MainActor func pick(_ raw: String, in popup: NSPopUpButton) {
                popup.selectItem(at: popup.indexOfItem(withRepresentedObject: raw))
                popup.sendAction(popup.action, to: popup.target)
            }
            pick(ClaudeLaunchMode.plan.rawValue, in: pane.claudePopup)
            XCTAssertEqual(store.load().defaults.claudeLaunchMode, .plan)
            pick(NiruxApp.WorkspaceAgent.codex.rawValue, in: pane.agentPopup)
            XCTAssertEqual(store.load().defaults.agent, .codex)
            pick(SpaceSettingsDefaultsPane.settingsChoice, in: pane.claudePopup)
            XCTAssertNil(store.load().defaults.claudeLaunchMode)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int, 0o600)

            // Typed in the cell's field, then the field left, as AppKit does
            // it: Add Variable starts editing the new row's name.
            @MainActor func edit(_ column: Int, row: Int, to text: String) throws {
                let cell = try XCTUnwrap(pane.tableView.view(atColumn: column, row: row, makeIfNecessary: true))
                let field = try XCTUnwrap(UIFlowHarness.descendant(of: cell, as: NSTextField.self))
                if let editor = field.currentEditor() as? NSTextView {
                    editor.string = text
                    XCTAssertEqual(pane.view.window?.makeFirstResponder(nil), true)
                } else {
                    field.stringValue = text
                    pane.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
                }
            }
            pane.addVariable(nil)
            try edit(0, row: 0, to: "1BAD")
            XCTAssertFalse(pane.problemsLabel.isHidden)
            XCTAssertEqual(store.load().defaults.environment, [], "not written")
            try edit(0, row: 0, to: "API_URL")
            try edit(1, row: 0, to: "http://localhost:4000")
            XCTAssertTrue(pane.problemsLabel.isHidden)
            XCTAssertEqual(store.load().defaults.environment, [.init(name: "API_URL", value: "http://localhost:4000")])
            XCTAssertEqual(store.load().defaults.agent, .codex, "kept")

            pane.addVariable(nil)
            try edit(0, row: 1, to: "NIRUX_PROFILE_ID")
            XCTAssertTrue(pane.problemsLabel.stringValue.contains("reserved"), pane.problemsLabel.stringValue)
            XCTAssertEqual(store.load().defaults.environment.count, 1)
            pane.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            pane.removeButton.performClick(nil)
            XCTAssertTrue(pane.problemsLabel.isHidden)
            XCTAssertEqual(store.load().defaults.environment.count, 1)

            // A blank row goes, written or not.
            pane.addVariable(nil)
            try edit(0, row: 1, to: "")
            XCTAssertEqual(pane.rows.count, 1)
        }
    }

    /// One space at a time: typed text that isn't saved keeps the window on
    /// its space, and closing asks about it.
    func testUnsavedTextKeepsTheWindowAndClosingAsks() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let first = try anchoredSpace(harness, named: "First")
            let second = shell.workspaceStore.createProfile(named: "Second", select: false)
            shell.showSpaceSettings(profileID: first.id, tab: .brief)
            let settings = try XCTUnwrap(shell.spaceSettings)
            var questions: [String] = []
            var answer = NSApplication.ModalResponse.alertSecondButtonReturn
            settings.askInSheet = { alert, _, reply in
                questions.append(alert.messageText)
                reply(answer)
            }
            settings.brief.textView.string += "Draft.\n"
            settings.brief.textDidChange(Notification(name: NSText.didChangeNotification))
            XCTAssertTrue(settings.hasUnsavedText)

            shell.showSpaceSettings(profileID: second.id)
            XCTAssertIdentical(shell.spaceSettings, settings)
            XCTAssertEqual(settings.spaceID, first.id)
            XCTAssertTrue(shell.toast?.message.contains("Save or revert") == true)

            let panel = try XCTUnwrap(settings.panel)
            XCTAssertFalse(settings.windowShouldClose(panel), "Cancel")
            XCTAssertEqual(questions, ["Save the changes to the brief?"])
            XCTAssertIdentical(shell.spaceSettings, settings)

            answer = .alertThirdButtonReturn
            XCTAssertFalse(settings.windowShouldClose(panel))
            XCTAssertNil(shell.spaceSettings, "Don’t Save closes")
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(SpaceBrief.briefURL(spaceID: first.id)).path))

            shell.showSpaceSettings(profileID: second.id, tab: .general)
            XCTAssertEqual(shell.spaceSettings?.spaceID, second.id)
            XCTAssertEqual(shell.spaceSettings?.general.model.isGeneral, false)
            XCTAssertFalse(shell.spaceSettings?.general.addRepositoryButton.superview?.isHiddenOrHasHiddenAncestor ?? true)
            shell.showSpaceSettings(profileID: WorkspaceProfile.defaultID)
            XCTAssertEqual(shell.spaceSettings?.general.model.isGeneral, true)
            XCTAssertTrue(shell.spaceSettings?.general.addRepositoryButton.isHiddenOrHasHiddenAncestor ?? false, "General has none")
        }
    }

    /// The brief's tab follows the file while nothing is typed; with text
    /// typed, Save asks before replacing what an agent wrote.
    func testTheBriefTabFollowsTheFileUntilTextIsTyped() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let space = try anchoredSpace(harness)
            let brief = try XCTUnwrap(SpaceBrief.briefURL(spaceID: space.id))
            try FileManager.default.createDirectory(at: brief.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "First rule.\n".write(to: brief, atomically: true, encoding: .utf8)
            shell.showSpaceSettings(profileID: space.id, tab: .brief)
            let pane = try XCTUnwrap(shell.spaceSettings?.brief)
            var answer = NSApplication.ModalResponse.alertSecondButtonReturn
            pane.askInSheet = { _, _, reply in reply(answer) }
            XCTAssertEqual(pane.textView.string, "First rule.\n")
            XCTAssertFalse(pane.saveButton.isEnabled, "nothing to save")

            try "Agent's rule.\n".write(to: brief, atomically: true, encoding: .utf8)
            pane.checkDisk()
            XCTAssertEqual(pane.textView.string, "Agent's rule.\n")

            pane.textView.string = "Mine.\n"
            pane.textDidChange(Notification(name: NSText.didChangeNotification))
            try "Agent again.\n".write(to: brief, atomically: true, encoding: .utf8)
            pane.checkDisk()
            XCTAssertEqual(pane.textView.string, "Mine.\n", "typed text stays")
            XCTAssertFalse(pane.save(), "Keep Editing")
            XCTAssertEqual(try String(contentsOf: brief, encoding: .utf8), "Agent again.\n")
            answer = .alertFirstButtonReturn
            XCTAssertFalse(pane.save(), "asked first; Replace writes")
            XCTAssertEqual(try String(contentsOf: brief, encoding: .utf8), "Mine.\n")
            XCTAssertFalse(pane.isDirty)

            pane.textView.string = "Thrown away.\n"
            pane.textDidChange(Notification(name: NSText.didChangeNotification))
            pane.revertButton.performClick(nil)
            XCTAssertEqual(pane.textView.string, "Mine.\n")
        }
    }
}
