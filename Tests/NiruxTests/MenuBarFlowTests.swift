import AppKit
import XCTest
@testable import Nirux

/// Runs the Space, Workspaces, Agent, Columns and Help menu items that used
/// to live only in the palette, through a NiruxApp bound to a real window
/// (see UIFlowHarness): each must reach the command its title names.
@MainActor
final class MenuBarFlowTests: XCTestCase {
    /// Space Settings… opens the window of the space in front.
    func testSpaceMenu() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let bar = MenuBar(shell: shell)

            // The sidebar's New Space… sheet; the space itself is made the
            // way its Create button does.
            bar.run(["Space", "New Space…"])
            harness.waitUntil("the New Space sheet") { shell.newSpacePanel?.panel?.isSheet == true }
            try XCTUnwrap(shell.newSpacePanel).cancelButton.performClick(nil)
            harness.waitUntil("the sheet to close") { harness.window.attachedSheet == nil }
            shell.createSpace(NewSpacePanel.Draft(name: "Menu", colorHex: WorkspaceProfile.palette[1].hex, anchors: []))
            let space = shell.activeProfileID
            XCTAssertNotEqual(space, WorkspaceProfile.defaultID)
            bar.run(["Space", "Space Settings…"])
            XCTAssertEqual(shell.spaceSettings?.spaceID, space)
            XCTAssertEqual(shell.spaceSettings?.selectedTab, .general)
            harness.submit("Menu Space", into: try XCTUnwrap(harness.waitForField(placeholder: "Space name")))
            XCTAssertEqual(shell.profiles.first { $0.id == space }?.name, "Menu Space")

            bar.run(["Space", "Previous Space"])
            XCTAssertEqual(shell.activeProfileID, WorkspaceProfile.defaultID)
            bar.run(["Space", "Space Settings…"])
            XCTAssertEqual(shell.spaceSettings?.spaceID, WorkspaceProfile.defaultID)
            shell.spaceSettings?.close()

            // ⌃⌘B, typed in a terminal, reaches the menu. No repository yet:
            // the board asks for one, and runs no gh.
            shell.projectBoardClient = ProjectBoardFlowTests.FakeGitHub(openPullRequests: "[]", runs: "[]")
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertNotNil(workspace.columns[safe: workspace.focusedIndex]?.pty)
            try harness.withApp { harness.press("b", keyCode: 0x0B, [.command, .control]) }
            XCTAssertEqual(workspace.columns[safe: workspace.focusedIndex]?.projectBoard?.projectID, WorkspaceProfile.defaultID)
            harness.waitUntil("Board Settings to open") { shell.boardSettingsPanel?.hostView != nil }
            XCTAssertEqual(shell.spaceSettings?.selectedTab, .board)
            shell.spaceSettings?.close()

            bar.run(["Space", "Session History…"])
            let history = try XCTUnwrap(shell.sessionHistoryPanel)
            XCTAssertTrue(history.isVisible)
            history.dismiss()

            bar.run(["Space", "Clean Up Merged Worktrees…"])
            let cleanup = try XCTUnwrap(shell.worktreeCleanupPanel)
            harness.waitUntil("the worktree inspected") {
                cleanup.candidates.contains { NiruxShellView.comparablePath($0.path) == NiruxShellView.comparablePath(harness.worktree) && $0.inspection != nil }
            }
            cleanup.dismiss()
        }
    }

    func testWorkspacesMenu() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let bar = MenuBar(shell: shell)

            // Lists the worktrees off the main thread, then opens the palette.
            bar.run(["Workspaces", "Open Worktree…"])
            harness.waitUntil("the worktree list") {
                shell.commandPalette?.isVisible == true
                    && shell.commandPalette?.filteredActions.map(\.title) == [harness.worktreeBranch]
            }
            shell.commandPalette?.dismiss()

            bar.run(["Workspaces", "New…"])
            harness.waitUntil("the sheet") { shell.newTaskPanel?.panel?.isSheet == true }
            let sheet = try XCTUnwrap(shell.newTaskPanel)
            harness.waitUntil("the space's info") { sheet.info != nil }
            sheet.cancelButton.performClick(nil)
            XCTAssertNil(shell.newTaskPanel)

            // The context of the workspace in front, not the first one.
            shell.addWorkspace(title: "second", cwd: harness.worktree)
            let second = try XCTUnwrap(shell.activeWorkspace)
            bar.run(["Workspaces", "View/Edit Context…"])
            let nextStep = try XCTUnwrap(harness.waitForField(placeholder: "What should happen next?"))
            nextStep.stringValue = "From the menu bar"
            try XCTUnwrap(nextStep.window?.contentView.flatMap { UIFlowHarness.button(titled: "Save Context", in: $0) })
                .performClick(nil)
            XCTAssertEqual(second.nextStep, "From the menu bar")
            XCTAssertEqual(shell.workspaces.filter { $0.nextStep == "From the menu bar" }.count, 1)
        }
    }

    func testAgentColumnsAndHelpMenus() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let bar = MenuBar(shell: shell)
            let workspace = try XCTUnwrap(shell.activeWorkspace)

            bar.run(["Agent", "New Claude Code"])
            bar.run(["Agent", "New Codex"])
            XCTAssertEqual(harness.agentLaunches.map { $0.split(separator: " ").prefix(2).joined(separator: " ") }, ["command claude", "command codex"])

            shell.branchReviewReader = BranchReviewPageTests.reader
            bar.run(["Agent", "Review Branch"])
            let review = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.branchReview)
            XCTAssertEqual(review.worktree, workspace.cwd)
            harness.waitUntil("the review to read its branch") { review.snapshot != nil }

            bar.run(["Agent", "Install Agent Skills"])
            XCTAssertEqual(harness.alerts, ["Agent Skills Installed"])

            bar.run(["Columns", "Open Editor"])
            let editor = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.editorColumn)
            harness.waitUntil("the editor to open README.md") { editor.activePath == harness.repo + "/README.md" }

            // Offered only with a Chromium browser to import from.
            XCTAssertFalse(bar.isEnabled(["Columns", "Import Browser Cookies"]))
            harness.cookieBrowsers = [.chrome]
            bar.run(["Columns", "Import Browser Cookies"])
            harness.waitUntil("the import result") { harness.alerts.last == "Cookies Imported" }
            XCTAssertEqual(harness.cookieImports, [.chrome])

            shell.onboardingState = .dismissed
            bar.run(["Help", "Getting Started"])
            XCTAssertEqual(shell.onboardingState, .pending)
        }
    }
}

// MARK: - The Lead (docs/spaces.md, "The Lead")

extension MenuBarFlowTests {
    /// ⌃⌘L starts the space's Lead (none in General), comes back to it from
    /// elsewhere, and never makes a second one. The Lead stays on top of its
    /// space, keeps its Missions with handoffs off, saves as the Lead, and
    /// closes from Space Settings › Lead only once the user confirms.
    func testLeadFromTheSpaceMenu() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let bar = MenuBar(shell: shell)
            shell.projectBoardClient = ProjectBoardFlowTests.FakeGitHub(openPullRequests: "[]", runs: "[]")
            XCTAssertFalse(bar.isEnabled(["Space", "Lead"]), "General has no Lead")
            XCTAssertTrue(Persistence.updateSettings(liveLayout: shell.persistedState()) { $0.missionHandoffsEnabled = false })

            shell.createSpace(NewSpacePanel.Draft(name: "Client", colorHex: WorkspaceProfile.palette[1].hex, anchors: []))
            let space = shell.activeProfileID
            // Validating names the item after what it does.
            XCTAssertTrue(bar.isEnabled(["Space", "Lead"]))
            bar.run(["Space", "Start a Lead"])
            let lead = try XCTUnwrap(shell.leadWorkspace(inSpace: space))
            XCTAssertTrue(shell.activeWorkspace === lead)
            XCTAssertEqual(lead.title, "Lead")
            XCTAssertEqual(harness.agentLaunches.last.map { $0.hasPrefix("command claude") }, true)
            XCTAssertEqual(harness.agentLaunches.last.map { $0.contains("Lead · Client") }, true, "names the session")
            XCTAssertEqual(lead.columns.compactMap { $0.projectBoard?.projectID }, [space], "the Board beside Claude")
            XCTAssertEqual(lead.focusedIndex, 0, "Claude keeps the keyboard")
            XCTAssertNotEqual(
                AgentSkillsInstaller.status(of: NiruxShellView.agentSkills, home: harness.home), .missing, "its skill"
            )
            let environment = lead.terminalEnvironment(agentUUID: UUID().uuidString)
            XCTAssertEqual(environment["NIRUX_LEAD"], "1")
            XCTAssertEqual(environment["NIRUX_MISSION_HANDOFFS"], "1", "its tasks report to it with handoffs off")
            // The Board, without settings yet, doesn't open them over Claude.
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            XCTAssertNil(shell.spaceSettings)

            shell.addWorkspace(title: "plain", cwd: harness.repo, profileID: space)
            let plain = try XCTUnwrap(shell.activeWorkspace)
            let plainEnvironment = plain.terminalEnvironment(agentUUID: UUID().uuidString)
            XCTAssertEqual(plainEnvironment["NIRUX_LEAD"], "", "blank, not inherited")
            XCTAssertNil(plainEnvironment["NIRUX_MISSION_HANDOFFS"])
            XCTAssertTrue(bar.isEnabled(["Space", "Start a Lead"]))
            bar.run(["Space", "Lead"])
            XCTAssertTrue(shell.activeWorkspace === lead)
            shell.startLead(spaceID: space)
            XCTAssertEqual(shell.workspaces.filter(\.isLead).count, 1)

            // On top of its space, for good.
            let index = { (workspace: WorkspaceState) in try XCTUnwrap(shell.workspaces.firstIndex { $0 === workspace }) }
            let store = shell.workspaceStore
            XCTAssertEqual(store.visibleWorkspaceIndices(in: space), [try index(lead), try index(plain)])
            XCTAssertFalse(store.moveWorkspace(at: try index(plain), delta: -1))
            XCTAssertFalse(store.moveWorkspace(at: try index(lead), delta: 1))
            XCTAssertFalse(store.setWorkspaceInactive(at: try index(lead), true))
            XCTAssertFalse(store.moveWorkspace(at: try index(lead), toProfile: WorkspaceProfile.defaultID))
            XCTAssertEqual(store.visibleWorkspaceIndices(in: space).first, try index(lead))
            let menuTitles = { (workspace: WorkspaceState) in
                shell.sidebar.workspaceActionMenu(workspaceIndex: try index(workspace), columnIndex: nil).items.map(\.title)
            }
            XCTAssertFalse(try menuTitles(lead).contains("Organize"))
            XCTAssertTrue(try menuTitles(plain).contains("Organize"))
            XCTAssertEqual(shell.persistedState().workspaces.filter(\.isLead).map(\.id), [lead.id])

            // Off asks first: cancelled, the Lead stays.
            shell.showSpaceSettings(profileID: space, tab: .lead)
            let pane = try XCTUnwrap(shell.spaceSettings?.lead)
            let flip = { (state: NSControl.StateValue) in
                pane.leadSwitch.state = state
                XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(pane.leadSwitch.action), to: pane.leadSwitch.target, from: pane.leadSwitch))
            }
            XCTAssertEqual(pane.leadSwitch.state, .on)
            try flip(.off)
            XCTAssertEqual(harness.alerts.last, "Close workspace “Lead”?")
            XCTAssertNotNil(shell.leadWorkspace(inSpace: space))
            XCTAssertEqual(pane.leadSwitch.state, .on)
            harness.alertResponses = [.alertSecondButtonReturn]
            try flip(.off)
            XCTAssertNil(shell.leadWorkspace(inSpace: space))
            XCTAssertEqual(pane.leadSwitch.state, .off)

            // On again at once: a new Lead, the only one saved while the
            // first is still on its way out.
            try flip(.on)
            let second = try XCTUnwrap(shell.leadWorkspace(inSpace: space))
            XCTAssertFalse(second === lead)
            XCTAssertEqual(pane.leadSwitch.state, .on)
            XCTAssertEqual(shell.persistedState().workspaces.filter(\.isLead).map(\.id), [second.id])
            harness.waitUntil("the first Lead's workspace to go") { !shell.workspaces.contains { $0 === lead } }
            shell.spaceSettings?.close()

            // Deleting its space leaves a plain workspace in General.
            XCTAssertTrue(store.deleteProfile(id: space))
            XCTAssertFalse(second.isLead)
            XCTAssertEqual(second.profileID, WorkspaceProfile.defaultID)
        }
    }

    /// An empty space offers its Lead; General doesn't.
    func testEmptySpaceStartsItsLead() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.projectBoardClient = ProjectBoardFlowTests.FakeGitHub(openPullRequests: "[]", runs: "[]")
            shell.createSpace(NewSpacePanel.Draft(name: "Empty", colorHex: WorkspaceProfile.palette[2].hex, anchors: []))
            let space = shell.activeProfileID
            let view = shell.emptySpaceView
            XCTAssertFalse(view.isHidden)
            XCTAssertFalse(view.startLeadButton.isHidden)
            view.startLeadButton.performClick(nil)
            let lead = try XCTUnwrap(shell.leadWorkspace(inSpace: space))
            XCTAssertTrue(shell.activeWorkspace === lead)
            XCTAssertTrue(view.isHidden)
        }
    }

    /// "Start a Lead" in the New Space sheet: the space opens on its Lead,
    /// with no plain workspace beside it.
    func testNewSpaceSheetStartsTheLead() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let bar = MenuBar(shell: shell)
            shell.projectBoardClient = ProjectBoardFlowTests.FakeGitHub(openPullRequests: "[]", runs: "[]")
            bar.run(["Space", "New Space…"])
            harness.waitUntil("the New Space sheet") { shell.newSpacePanel?.panel?.isSheet == true }
            let sheet = try XCTUnwrap(shell.newSpacePanel)
            XCTAssertEqual(sheet.leadSwitch.state, .off, "opt-in")
            // Without the suggested repository: nothing to offer to move.
            while !sheet.rows.isEmpty { sheet.remove(at: 0) }
            sheet.nameField.stringValue = "Led"
            sheet.leadSwitch.state = .on
            sheet.createButton.performClick(nil)
            let space = shell.activeProfileID
            XCTAssertEqual(shell.profiles.first { $0.id == space }?.name, "Led")
            let lead = try XCTUnwrap(shell.leadWorkspace(inSpace: space))
            XCTAssertTrue(shell.activeWorkspace === lead)
            XCTAssertEqual(shell.workspaceStore.visibleWorkspaceIndices(in: space).count, 1)
        }
    }

    /// A restored state keeps one Lead per space, none in General, and
    /// never a parked one.
    func testRestoreKeepsOneLeadPerSpace() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.createSpace(NewSpacePanel.Draft(name: "Client", colorHex: WorkspaceProfile.palette[1].hex, anchors: []))
            let space = shell.activeProfileID
            shell.saveState()
            var state = try XCTUnwrap(Persistence.load())
            func workspace(_ id: String, in spaceID: String, lead: Bool, inactive: Bool = false) -> PersistedWorkspace {
                PersistedWorkspace(
                    id: id, title: id, cwd: harness.repo,
                    columns: [PersistedColumn(
                        widthPreset: 0.5, cwd: harness.repo, columnType: .terminal, webViewURL: nil,
                        claudeLaunchMode: nil, codexLaunchMode: nil
                    )],
                    focusedColumnIndex: 0, profileID: spaceID, isInactive: inactive, isLead: lead
                )
            }
            state.workspaces = [
                workspace("plain", in: space, lead: false),
                workspace("first", in: space, lead: true, inactive: true),
                workspace("second", in: space, lead: true),
                workspace("general", in: WorkspaceProfile.defaultID, lead: true)
            ]
            state.activeWorkspaceIndex = 0
            state.activeWorkspaceID = nil
            XCTAssertTrue(Persistence.save(state))
            shell.restoreState()
            XCTAssertEqual(shell.workspaces.filter(\.isLead).map(\.id), ["first"])
            XCTAssertEqual(shell.leadWorkspace(inSpace: space)?.isInactive, false)
            XCTAssertEqual(shell.workspaceStore.visibleWorkspaceIndices(in: space).map { shell.workspaces[$0].id }, ["first", "plain", "second"])
        }
    }
}

/// The main menu of a NiruxApp bound to `shell`, run the way AppKit does:
/// a nil-target item goes to the app once it validates, a closure item to
/// its own target.
@MainActor
private struct MenuBar {
    let app: NiruxApp
    let menu: NSMenu

    init(shell: NiruxShellView) {
        app = NiruxApp()
        app.shell = shell
        menu = app.makeMainMenu()
    }

    /// The item at `path`: a top-level menu's title, then item titles.
    /// A submenu rebuilt on opening is rebuilt on the way.
    func item(_ path: [String]) -> NSMenuItem? {
        guard var current = menu.items.first(where: { $0.submenu?.title == path.first })?.submenu else { return nil }
        var found: NSMenuItem?
        for title in path.dropFirst() {
            current.delegate?.menuNeedsUpdate?(current)
            guard let item = current.items.first(where: { $0.title == title }) else { return nil }
            found = item
            if let submenu = item.submenu { current = submenu }
        }
        return found
    }

    func titles(of path: [String]) -> [String] {
        guard let submenu = item(path)?.submenu else { return [] }
        submenu.delegate?.menuNeedsUpdate?(submenu)
        return submenu.items.map(\.title)
    }

    func isEnabled(_ path: [String]) -> Bool {
        guard let item = item(path) else { return false }
        return item.target != nil || app.validateMenuItem(item)
    }

    func run(_ path: [String], file: StaticString = #filePath, line: UInt = #line) {
        let name = path.joined(separator: " ▸ ")
        guard let item = item(path), let action = item.action else {
            return XCTFail("no menu item \(name)", file: file, line: line)
        }
        XCTAssertTrue(isEnabled(path), "\(name) is disabled", file: file, line: line)
        XCTAssertTrue(NSApp.sendAction(action, to: item.target ?? app, from: item), "\(name) did nothing", file: file, line: line)
    }
}
