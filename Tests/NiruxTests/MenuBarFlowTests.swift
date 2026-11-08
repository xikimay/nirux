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

            bar.run(["Workspaces", "New Worktree…"])
            try XCTUnwrap(harness.waitForField(placeholder: "Branch name (e.g. feat/my-feature)")).window?.orderOut(nil)

            bar.run(["Workspaces", "New Task…"])
            harness.waitUntil("the new task sheet") { shell.newTaskPanel?.panel?.isSheet == true }
            let form = try XCTUnwrap(shell.newTaskPanel)
            harness.waitUntil("the space's repository") { form.info != nil }
            form.cancelButton.performClick(nil)
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
