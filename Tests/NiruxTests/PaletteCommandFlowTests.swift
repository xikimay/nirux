import AppKit
import XCTest
@testable import Nirux

/// Runs every command of the palette in a real window (see UIFlowHarness),
/// the way a user does: type its title, pick it, press Return. The nightly
/// once shipped a panel that crashed as it opened (#46) because no test
/// opened it; here, a new command without a test fails
/// `testEveryPaletteCommandHasAFlowTest`.
@MainActor
final class PaletteCommandFlowTests: UIFlowTestCase {
    /// The palette commands each test runs: all of them, and no other.
    /// Every command of the palette is listed here or exempted with the
    /// reason; keep the exemptions empty unless a command truly can't run
    /// in CI.
    static let commandCoverage = UIFlowCoverage(
        kind: .paletteCommand,
        tests: [
            "testTerminalColumnCommands": ["New Terminal", "Resize Column (Cycle Width)"],
            "testEditorCommands": ["Open Editor", "Toggle Editor Diff", "Search Workspace"],
            "testBrowserCommands": ["Open Browser", "Toggle Web Inspector"],
            "testImportBrowserCookies": ["Import Browser Cookies"],
            "testAgentCommands": ["Open Claude Code", "Open Codex"],
            "testNextWaitingAgentCommand": ["Next Waiting Agent"],
            "testWorkspaceCommands": [
                "New Workspace", "Rename Workspace", "Show/Hide Sidebar", "Show/Hide Inactive Workspaces"
            ],
            "testWorktreeCommands": ["Open Worktree", "New Worktree", "Clean Up Merged Worktrees…"],
            "testNewTaskCommand": ["New Task…"],
            "testProjectBoardCommand": ["Open Project Board"],
            "testSetupCommands": ["Show Getting Started", "Install Agent Skills", "Open Settings"]
        ],
        exemptions: [:]
    )

    override class var coverage: UIFlowCoverage? { commandCoverage }

    // MARK: - Guard

    func testEveryPaletteCommandHasAFlowTest() throws {
        try UIFlowHarness.run { harness in
            let titles = harness.paletteCommandTitles()
            XCTAssertEqual(titles.count, Set(titles).count, "two palette commands share a title: \(titles)")
            Self.commandCoverage.checkEveryItemIsCovered(offered: titles, testNames: UIFlowCoverage.testNames(of: Self.self))
        }
    }

    // MARK: - Columns

    func testTerminalColumnCommands() throws {
        try UIFlowHarness.run { harness in
            let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
            let columnCount = workspace.columns.count

            harness.runPaletteCommand("New Terminal")
            XCTAssertEqual(workspace.columns.count, columnCount + 1)
            let column = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex])
            XCTAssertNotNil(column.terminalView)
            XCTAssertIdentical(workspace.columns.last, column)

            let width = column.widthFraction
            harness.runPaletteCommand("Resize Column (Cycle Width)")
            XCTAssertNotEqual(column.widthFraction, width)
        }
    }

    func testEditorCommands() throws {
        try UIFlowHarness.run { harness in
            let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
            let readme = harness.repo + "/README.md"

            harness.runPaletteCommand("Open Editor")
            let editor = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.editorColumn)
            XCTAssertEqual(editor.workspaceCwd, harness.repo)
            harness.waitUntil("the editor to open README.md") { editor.activePath == readme }

            // README.md differs from HEAD: git reads the original off the
            // main thread.
            harness.runPaletteCommand("Toggle Editor Diff")
            harness.waitUntil("the diff of README.md") { editor.diffActivePath == readme }

            // rg or grep streams its results from a background queue.
            harness.runPaletteCommand("Search Workspace")
            let field = try XCTUnwrap(harness.waitForField(placeholder: "Search workspace…"))
            harness.type(UIFlowHarness.searchNeedle, into: field)
            let table = try XCTUnwrap(field.window?.contentView.flatMap {
                UIFlowHarness.descendant(of: $0, as: NSTableView.self)
            })
            harness.waitUntil("a search result") { table.numberOfRows > 0 && table.selectedRow == 0 }
            harness.press(.returnKey, in: field.window)
            let target = harness.repo + "/" + UIFlowHarness.searchTarget
            harness.waitUntil("the result to open in the editor") { editor.activePath == target }
            XCTAssertFalse(field.window?.isVisible ?? true, "the search panel stayed open")
            XCTAssertEqual(workspace.columns.compactMap(\.editorColumn).count, 1, "the result opened a second editor")
        }
    }

    func testBrowserCommands() throws {
        try UIFlowHarness.run { harness in
            let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
            let page = URL(fileURLWithPath: harness.repo + "/README.md").absoluteString

            harness.runPaletteCommand("Open Browser")
            let palette = try XCTUnwrap(harness.shell.commandPalette)
            XCTAssertEqual(palette.mode, .urlInput)
            XCTAssertTrue(palette.isVisible, "URL mode closed the palette")
            let field = try XCTUnwrap(palette.searchField)
            harness.type(page, into: field)
            harness.press(.returnKey, in: palette.panel)
            XCTAssertFalse(palette.isVisible)
            let web = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.webViewColumn)
            XCTAssertEqual(web.currentURL, page)
            // The history lives in the test's state folder.
            XCTAssertEqual(URLHistory.load().first, page)
            XCTAssertTrue(FileManager.default.fileExists(atPath: harness.stateDirectory + "/url_history.json"))

            // After a URL, the palette opens on the commands again.
            harness.shell.showCommandPalette()
            XCTAssertEqual(palette.mode, .actions)
            XCTAssertEqual(palette.searchField?.placeholderString, "Type a command or a workspace...")
            palette.dismiss()

            // Reaches the focused browser column; the inspector itself
            // doesn't open in a test process.
            harness.runPaletteCommand("Toggle Web Inspector")
            XCTAssertIdentical(workspace.columns[safe: workspace.focusedIndex]?.webViewColumn, web)
        }
    }

    func testImportBrowserCookies() throws {
        try UIFlowHarness.run { harness in
            harness.cookieBrowsers = [.chrome, .arc]
            XCTAssertEqual(harness.shell.importCookieSubtitle(), "From Chrome, Arc")
            // The browser choice: Arc, the second button.
            harness.alertResponses = [.alertSecondButtonReturn]

            harness.runPaletteCommand("Import Browser Cookies")
            harness.waitUntil("the import result") { harness.alerts.count == 2 }
            XCTAssertEqual(harness.alerts, ["Import Cookies", "Cookies Imported"])
            XCTAssertEqual(harness.cookieImports, [.arc])
        }
    }

    // MARK: - Agents

    func testAgentCommands() throws {
        try UIFlowHarness.run { harness in
            let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
            let columnCount = workspace.columns.count

            harness.runPaletteCommand("Open Claude Code")
            XCTAssertEqual(workspace.columns.count, columnCount + 1)
            XCTAssertEqual(harness.agentLaunches.count, 1)
            XCTAssertTrue(harness.agentLaunches.last?.hasPrefix("command claude") == true, "\(harness.agentLaunches)")

            harness.runPaletteCommand("Open Codex")
            XCTAssertEqual(workspace.columns.count, columnCount + 2)
            XCTAssertEqual(harness.agentLaunches.count, 2)
            XCTAssertTrue(harness.agentLaunches.last?.hasPrefix("command codex") == true, "\(harness.agentLaunches)")
        }
    }

    /// Goes to the agent blocked on the user (faked: a real one needs a
    /// `claude` in front). QuickSwitcherFlowTests walks the queue.
    func testNextWaitingAgentCommand() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let repo = try XCTUnwrap(shell.activeWorkspace)
            shell.addWorkspace(title: "second", cwd: harness.worktree)
            let waiting = try XCTUnwrap(shell.activeWorkspace?.columns.first)
            let wait = AgentWait(reason: .question(nil), since: Date().timeIntervalSince1970 - 60)
            shell.quickSwitch.agentWait = { column, _, _ in column === waiting ? wait : nil }
            shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0 === repo }))

            harness.runPaletteCommand("Next Waiting Agent")
            XCTAssertEqual(shell.activeWorkspace?.title, "second")
        }
    }

    // MARK: - Workspaces

    func testWorkspaceCommands() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let repoWorkspace = try XCTUnwrap(shell.activeWorkspace)

            harness.runPaletteCommand("New Workspace")
            let nameField = try XCTUnwrap(harness.waitForField(placeholder: "Name this workspace for the task"))
            harness.submit("second", into: nameField)
            let second = try XCTUnwrap(shell.workspaces.first { $0.title == "second" })
            XCTAssertIdentical(shell.activeWorkspace, second)

            shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0 === repoWorkspace }))
            harness.runPaletteCommand("Rename Workspace")
            let renameField = try XCTUnwrap(harness.waitForField(placeholder: "Workspace name"))
            XCTAssertEqual(renameField.stringValue, "repo")
            harness.submit("renamed", into: renameField)
            XCTAssertEqual(repoWorkspace.title, "renamed")
            XCTAssertTrue(repoWorkspace.titleIsManual)

            harness.runPaletteCommand("Show/Hide Sidebar")
            XCTAssertTrue(shell.isSidebarExpanded)
            harness.waitUntil("the sidebar to expand") { shell.sidebar.isExpanded }

            // The section only toggles with an inactive workspace to show.
            let secondIndex = try XCTUnwrap(shell.workspaces.firstIndex { $0 === second })
            harness.perform(["Move to Inactive"], in: shell.sidebar.workspaceActionMenu(workspaceIndex: secondIndex, columnIndex: nil))
            XCTAssertTrue(second.isInactive)
            XCTAssertTrue(shell.sidebar.isInactiveSectionCollapsed)
            harness.runPaletteCommand("Show/Hide Inactive Workspaces")
            XCTAssertFalse(shell.sidebar.isInactiveSectionCollapsed)
        }
    }

    func testWorktreeCommands() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell

            // Lists the worktrees off the main thread, then offers them in
            // the palette.
            harness.runPaletteCommand("Open Worktree")
            let palette = try XCTUnwrap(shell.commandPalette)
            harness.waitUntil("the worktree list") {
                palette.isVisible && palette.filteredActions.map(\.title) == [harness.worktreeBranch]
            }
            harness.press(.returnKey, in: palette.panel)
            let opened = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertEqual(opened.title, harness.worktreeBranch)
            XCTAssertEqual(NiruxShellView.comparablePath(opened.cwd), NiruxShellView.comparablePath(harness.worktree))

            // Picks a row of Open Worktree by its title; returns its subtitle.
            @MainActor func pickWorktree(_ title: String) throws -> String {
                harness.runPaletteCommand("Open Worktree")
                harness.waitUntil("\(title) in the worktree list") {
                    palette.isVisible && palette.actions.contains { $0.title == title }
                }
                harness.type(title, into: try XCTUnwrap(palette.searchField))
                let row = try XCTUnwrap(palette.filteredActions.first)
                XCTAssertEqual(row.title, title)
                harness.press(.returnKey, in: palette.panel)
                return row.subtitle
            }

            // Once it is open, it goes back to that workspace...
            let repoWorkspace = try XCTUnwrap(shell.workspaces.first { $0.cwd == harness.repo })
            shell.focusWorkspace(id: repoWorkspace.id)
            let workspaceCount = shell.workspaces.count
            XCTAssertTrue(try pickWorktree(harness.worktreeBranch).hasPrefix("Already open · "))
            XCTAssertTrue(shell.activeWorkspace === opened)
            // ...and, from the worktree, to the main checkout's.
            XCTAssertTrue(try pickWorktree("main").hasPrefix("Already open · "))
            XCTAssertTrue(shell.activeWorkspace === repoWorkspace)
            XCTAssertEqual(shell.workspaces.count, workspaceCount)
            // A worktree inside the main checkout, as Claude Code makes them:
            // its workspace is in it, not in the main checkout.
            let nested = harness.repo + "/.claude/worktrees/nested"
            try UIFlowHarness.git(["worktree", "add", "-q", "-b", "feat/nested", nested], at: harness.repo)
            XCTAssertFalse(try pickWorktree("feat/nested").hasPrefix("Already open"))
            let nestedWorkspace = try XCTUnwrap(shell.activeWorkspace)
            shell.focusWorkspace(id: repoWorkspace.id)
            XCTAssertTrue(try pickWorktree("feat/nested").hasPrefix("Already open · "))
            XCTAssertTrue(shell.activeWorkspace === nestedWorkspace)
            XCTAssertEqual(shell.workspaces.count, workspaceCount + 1)
            shell.focusWorkspace(id: repoWorkspace.id)

            // Creates the worktree off the main thread, then opens it with an
            // agent (the launch double).
            harness.runPaletteCommand("New Worktree")
            let branchField = try XCTUnwrap(harness.waitForField(placeholder: "Branch name (e.g. feat/my-feature)"))
            harness.submit("feat/new-flow", into: branchField)
            harness.waitUntil("the new worktree's workspace") {
                shell.workspaces.contains { $0.title == "feat/new-flow" }
            }
            let created = try XCTUnwrap(shell.workspaces.first { $0.title == "feat/new-flow" })
            XCTAssertTrue(FileManager.default.fileExists(atPath: created.cwd + "/.git"))
            XCTAssertTrue(harness.agentLaunches.last?.hasPrefix("command claude") == true, "\(harness.agentLaunches)")

            // Inspects each worktree on an OperationQueue (#46, #48).
            harness.runPaletteCommand("Clean Up Merged Worktrees…")
            let panel = try XCTUnwrap(shell.worktreeCleanupPanel)
            let expected = Set([harness.worktree, created.cwd].map(NiruxShellView.comparablePath))
            harness.waitUntil("both worktrees inspected") {
                let inspected = panel.candidates.filter { $0.inspection != nil }.map { NiruxShellView.comparablePath($0.path) }
                return expected.isSubset(of: Set(inspected))
            }
            panel.dismiss()
            XCTAssertNil(shell.worktreeCleanupPanel)
        }
    }

    /// Reads the project's repository and templates off the main thread,
    /// then creates the worktree and writes the handover off it too (see
    /// NewTaskFlowTests for the rest of the form).
    func testNewTaskCommand() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            harness.runPaletteCommand("New Task…")
            harness.waitUntil("the new task sheet") { shell.newTaskPanel?.panel?.isSheet == true }
            let form = try XCTUnwrap(shell.newTaskPanel)
            XCTAssertIdentical(harness.window.attachedSheet, form.panel)
            XCTAssertEqual(form.selectedProjectID, shell.activeProfileID)
            harness.waitUntil("the project's repository") { form.info != nil }
            XCTAssertEqual(form.info?.target?.repository, harness.repo)
            XCTAssertEqual(form.info?.templates, TaskTemplates.defaults)
            // No remote here: the checkout's HEAD.
            XCTAssertEqual(
                form.repositoryLabel.stringValue,
                "\(harness.repo)\nStarts from this checkout’s HEAD (main): origin has no default branch Nirux knows of."
            )

            // The branch follows the description, then the template.
            form.descriptionView.string = "Sidebar flickers on resize\n\nSeen with three columns."
            form.descriptionView.didChangeText()
            XCTAssertEqual(form.branch, "feat/sidebar-flickers-on-resize")
            form.templatePopup.selectItem(withTitle: "Bugfix")
            form.templatePopup.sendAction(form.templatePopup.action, to: form.templatePopup.target)
            XCTAssertEqual(form.branch, "fix/sidebar-flickers-on-resize")

            form.startButton.performClick(nil)
            harness.waitUntil("the task's workspace") {
                shell.workspaces.contains { $0.title == "Sidebar flickers on resize" }
            }
            XCTAssertNil(shell.newTaskPanel)
            XCTAssertNil(harness.window.attachedSheet)
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertEqual(workspace.title, "Sidebar flickers on resize")
            XCTAssertEqual(workspace.profileID, WorkspaceProfile.defaultID)
            XCTAssertEqual(
                NiruxShellView.comparablePath(workspace.cwd),
                NiruxShellView.comparablePath(harness.root + "/repo.fix-sidebar-flickers-on-resize")
            )
            XCTAssertEqual(GitWorktree.currentBranch(at: workspace.cwd), "fix/sidebar-flickers-on-resize")
            let handover = try String(contentsOfFile: workspace.cwd + "/.claude-handover.md", encoding: .utf8)
            XCTAssertTrue(handover.contains("## Task\n\nSidebar flickers on resize\n\nSeen with three columns.\n"), handover)
            XCTAssertTrue(handover.contains("## How to proceed (template “Bugfix”)\n\n1. Reproduce the bug first"), handover)
            // The repository ignores it: an agent's `git add -A` leaves it out.
            XCTAssertEqual(try UIFlowHarness.git(["status", "--porcelain"], at: workspace.cwd), "")
            // Named after the branch (#39), told to read the handover.
            let launch = try XCTUnwrap(harness.agentLaunches.last)
            XCTAssertTrue(launch.hasPrefix("command claude"), launch)
            XCTAssertTrue(launch.contains("'--name=fix/sidebar-flickers-on-resize'"), launch)
            XCTAssertTrue(launch.contains("Read .claude-handover.md for full context"), launch)
        }
    }

    // MARK: - Project Board

    func testProjectBoardCommand() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let client = ProjectBoardFlowTests.FakeGitHub(openPullRequests: "[]", runs: "[]")
            shell.projectBoardClient = client
            let workspace = try XCTUnwrap(shell.activeWorkspace)

            // No repository yet: the board asks for one, and runs no gh.
            harness.runPaletteCommand("Open Project Board")
            let board = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.projectBoard)
            XCTAssertEqual(board.projectID, workspace.profileID)
            harness.waitUntil("Board Settings to open") { shell.boardSettingsPanel?.panel != nil }
            shell.boardSettingsPanel?.dismiss()

            // From another column: the same board comes to the front.
            shell.addColumn()
            XCTAssertNil(workspace.columns[safe: workspace.focusedIndex]?.projectBoard)
            harness.runPaletteCommand("Open Project Board")
            XCTAssertIdentical(workspace.columns[safe: workspace.focusedIndex]?.projectBoard, board)
            XCTAssertEqual(workspace.columns.filter(\.isProjectBoard).count, 1)
            XCTAssertEqual(client.calls, [])
        }
    }

    // MARK: - Setup

    func testSetupCommands() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell

            harness.runPaletteCommand("Show Getting Started")
            XCTAssertEqual(shell.onboardingState, .pending)
            XCTAssertTrue(shell.isSidebarExpanded)
            // Read from the fake home, where nothing is installed yet.
            XCTAssertEqual(shell.sidebar.onboardingChecklist?.skills, .missing)

            harness.runPaletteCommand("Install Agent Skills")
            XCTAssertEqual(harness.alerts, ["Agent Skills Installed"])
            for root in AgentSkillsInstaller.roots(home: harness.home) {
                for name in NiruxShellView.agentSkills.keys {
                    let file = AgentSkillsInstaller.skillFile(root: root, name: name)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: file), "missing \(file)")
                }
            }
            XCTAssertEqual(shell.sidebar.onboardingChecklist?.skills, .installed)

            // The palette sends the action up the responder chain to the
            // app delegate.
            let app = NiruxApp()
            app.telegramTokenLoader = { nil }
            app.telegramTokenSaver = { _ in XCTFail("Unexpected Keychain write") }
            let previousDelegate = NSApp.delegate
            NSApp.delegate = app
            harness.runPaletteCommand("Open Settings")
            NSApp.delegate = previousDelegate
            let settings = try XCTUnwrap(app.settingsPanel)
            XCTAssertTrue(settings.isVisible)
            settings.orderOut(nil)
            settings.close()
        }
    }
}
