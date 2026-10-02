import AppKit
import XCTest
@testable import Nirux

/// Opens what the palette doesn't reach: every item of the sidebar's
/// workspace and space menus, the Getting Started card, the terminal find
/// bar, the editor's file picker and the confirmation of a `nirux://`
/// request. The menus are the ones right-click and the "⋯" button show,
/// run item by item; each test waits for the work its panel starts off the
/// main thread (see UIFlowHarness).
@MainActor
final class SidebarPanelFlowTests: UIFlowTestCase {
    /// The menu items each test runs, as `PaletteCommandFlowTests` lists
    /// the palette's commands: a new item without a test fails
    /// `testEverySidebarMenuItemHasAFlowTest`.
    static let menuCoverage = UIFlowCoverage(
        kind: .sidebarMenuItem,
        tests: [
            "testWorkspaceMenuItems": [
                "Focus Column", "Close Column", "Close Workspace", "Clean Up Worktree…", "View/Edit Context…",
                "Rename Workspace", "New Workspace", "Move Up", "Move Down", "Move to Inactive", "Move to Active"
            ],
            "testCIFailureMenuItems": ["Ask Agent Why CI Failed", "Rerun Failed CI Jobs…"],
            "testSpaceMenuItems": [
                "New Space", "Rename Space…", "Space Color", "Edit Space Brief…", "Board Settings…", "Move to Space",
                "Delete Space…"
            ]
        ],
        exemptions: [:]
    )

    override class var coverage: UIFlowCoverage? { menuCoverage }

    // MARK: - Menus

    /// Builds the menus with every item showing: two spaces, a workspace in
    /// a worktree with two columns, an inactive workspace.
    func testEverySidebarMenuItemHasAFlowTest() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.createProfileFromActiveContext()
            shell.addWorkspace(title: "inactive", cwd: harness.repo)
            let inactiveIndex = try XCTUnwrap(shell.workspaces.firstIndex { $0.title == "inactive" })
            shell.handleWorkspaceSidebarAction(.markInactive, workspaceIndex: inactiveIndex)
            shell.addWorkspace(title: "in worktree", cwd: harness.worktree)
            shell.addColumn()
            let worktreeIndex = try XCTUnwrap(shell.activeWorkspace.flatMap { active in
                shell.workspaces.firstIndex { $0 === active }
            })
            shell.workspaces[worktreeIndex].prInfo = Self.redPullRequest
            shell.updateSidebar()
            let menus = [
                shell.sidebar.workspaceActionMenu(workspaceIndex: worktreeIndex, columnIndex: 1),
                shell.sidebar.workspaceActionMenu(workspaceIndex: inactiveIndex, columnIndex: nil),
                shell.sidebar.spaceOptionsMenu()
            ]
            let titles = menus.flatMap(\.items).filter { !$0.isSeparatorItem }.map(\.title)
            Self.menuCoverage.checkEveryItemIsCovered(
                offered: Array(Set(titles)), testNames: UIFlowCoverage.testNames(of: Self.self)
            )
        }
    }

    func testWorkspaceMenuItems() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            @MainActor func menu(for workspace: WorkspaceState, column: Int? = nil) throws -> NSMenu {
                let index = try XCTUnwrap(shell.workspaces.firstIndex { $0 === workspace })
                return shell.sidebar.workspaceActionMenu(workspaceIndex: index, columnIndex: column)
            }

            harness.perform(["View/Edit Context…"], in: try menu(for: workspace))
            let nextStep = try XCTUnwrap(harness.waitForField(placeholder: "What should happen next?"))
            let contextPanel = try XCTUnwrap(nextStep.window)
            nextStep.stringValue = "Ship the harness"
            try XCTUnwrap(contextPanel.contentView.flatMap { UIFlowHarness.button(titled: "Save Context", in: $0) })
                .performClick(nil)
            XCTAssertEqual(workspace.nextStep, "Ship the harness")
            XCTAssertFalse(contextPanel.isVisible)

            harness.perform(["Rename Workspace"], in: try menu(for: workspace))
            let nameField = try XCTUnwrap(harness.waitForField(placeholder: "Workspace name"))
            harness.submit("from the menu", into: nameField)
            XCTAssertEqual(workspace.title, "from the menu")

            // Columns: focus the first, close the second.
            shell.addColumn()
            XCTAssertEqual(workspace.columns.count, 2)
            harness.perform(["Focus Column"], in: try menu(for: workspace, column: 0))
            XCTAssertEqual(workspace.focusedIndex, 0)
            harness.perform(["Close Column"], in: try menu(for: workspace, column: 1))
            harness.waitUntil("the column to close") { workspace.columns.count == 1 }

            // Opens one in the home folder, like ⌘N's default.
            let count = shell.workspaces.count
            harness.perform(["New Workspace"], in: try menu(for: workspace))
            XCTAssertEqual(shell.workspaces.count, count + 1)
            let added = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertFalse(added === workspace)
            @MainActor func position(_ workspace: WorkspaceState) -> Int? { shell.visibleWorkspaceIndices.firstIndex { shell.workspaces[$0] === workspace } }
            let before = try XCTUnwrap(position(added))
            harness.perform(["Move Up"], in: try menu(for: added))
            XCTAssertEqual(position(added), before - 1)
            harness.perform(["Move Down"], in: try menu(for: added))
            XCTAssertEqual(position(added), before)

            harness.perform(["Move to Inactive"], in: try menu(for: added))
            XCTAssertTrue(added.isInactive)
            harness.perform(["Move to Active"], in: try menu(for: added))
            XCTAssertFalse(added.isInactive)
            // No agent runs in it: it closes without asking.
            harness.perform(["Close Workspace"], in: try menu(for: added))
            harness.waitUntil("the workspace to close") { !shell.workspaces.contains { $0 === added } }

            // In the linked worktree: checked off the main thread, then
            // refused (no GitHub remote), and nothing goes.
            shell.addWorkspace(title: "in worktree", cwd: harness.worktree)
            let worktreeWorkspace = try XCTUnwrap(shell.activeWorkspace)
            harness.perform(["Clean Up Worktree…"], in: try menu(for: worktreeWorkspace))
            harness.waitUntil("the clean-up verdict") { !harness.alerts.isEmpty && shell.worktreeCleanupsInFlight.isEmpty }
            XCTAssertTrue(harness.alerts.last?.hasPrefix("Can’t clean up") == true, "\(harness.alerts)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: harness.worktree))
            XCTAssertTrue(shell.workspaces.contains { $0 === worktreeWorkspace })

            // A workspace whose folder is gone: confirmed, it closes.
            let gone = harness.root + "/gone"
            try FileManager.default.createDirectory(atPath: gone, withIntermediateDirectories: true)
            shell.addWorkspace(title: "gone", cwd: gone)
            let goneWorkspace = try XCTUnwrap(shell.activeWorkspace)
            try FileManager.default.removeItem(atPath: gone)
            harness.alertResponses = [.alertSecondButtonReturn]
            harness.perform(["Clean Up Worktree…"], in: try menu(for: goneWorkspace))
            harness.waitUntil("the gone folder's workspace to close") {
                !shell.workspaces.contains { $0 === goneWorkspace }
            }
            XCTAssertEqual(harness.alerts.last, "The folder of “gone” is gone")
        }
    }

    /// A pull request whose `test` job failed in a GitHub Actions run.
    static let redPullRequest = PRDetect.pullRequestInfo(from: [
        "number": 52, "state": "OPEN", "url": "https://github.com/acme/widgets/pull/52",
        "statusCheckRollup": [[
            "name": "test", "workflowName": "Tests", "status": "COMPLETED", "conclusion": "FAILURE",
            "startedAt": "2026-10-02T10:00:00Z", "detailsUrl": "https://github.com/acme/widgets/actions/runs/7/job/11"
        ]]
    ])

    /// Without an agent in the workspace, Why opens the failed check; a
    /// rerun asks first, and nothing reaches GitHub when cancelled.
    func testCIFailureMenuItems() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let index = try XCTUnwrap(shell.workspaces.firstIndex { $0 === workspace })
            workspace.prInfo = Self.redPullRequest
            shell.updateSidebar()

            harness.perform(["Ask Agent Why CI Failed"], in: shell.sidebar.workspaceActionMenu(workspaceIndex: index, columnIndex: nil))
            XCTAssertEqual(harness.openedURLs, [URL(string: "https://github.com/acme/widgets/actions/runs/7/job/11")])

            harness.alertResponses = [.alertSecondButtonReturn]
            harness.perform(["Rerun Failed CI Jobs…"], in: shell.sidebar.workspaceActionMenu(workspaceIndex: index, columnIndex: nil))
            XCTAssertEqual(harness.alerts.last, "Rerun the failed jobs of #52?")
        }
    }

    func testSpaceMenuItems() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            @MainActor func activeSpace() throws -> WorkspaceProfile {
                try XCTUnwrap(shell.profiles.first { $0.id == shell.activeProfileID })
            }

            harness.perform(["New Space"], in: shell.sidebar.spaceOptionsMenu())
            let space = try activeSpace()
            XCTAssertNotEqual(space.id, WorkspaceProfile.defaultID)
            let spaceWorkspace = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertEqual(spaceWorkspace.profileID, space.id)

            harness.perform(["Rename Space…"], in: shell.sidebar.spaceOptionsMenu())
            let nameField = try XCTUnwrap(harness.waitForField(placeholder: "Space name"))
            XCTAssertEqual(nameField.stringValue, space.name)
            harness.submit("Flow Space", into: nameField)
            XCTAssertEqual(try activeSpace().name, "Flow Space")

            let color = try XCTUnwrap(WorkspaceProfile.palette.first {
                $0.hex.caseInsensitiveCompare(space.colorHex) != .orderedSame
            })
            harness.perform(["Space Color", color.name], in: shell.sidebar.spaceOptionsMenu())
            XCTAssertEqual(try activeSpace().colorHex.uppercased(), color.hex.uppercased())

            // The brief opens in the workspace's editor, from the state folder.
            harness.perform(["Edit Space Brief…"], in: shell.sidebar.spaceOptionsMenu())
            let brief = try XCTUnwrap(SpaceBrief.briefURL(spaceID: space.id)).path
            XCTAssertTrue(brief.hasPrefix(harness.stateDirectory + "/"), brief)
            let editor = try XCTUnwrap(spaceWorkspace.columns.compactMap(\.editorColumn).first)
            harness.waitUntil("the brief in the editor") { editor.activePath == brief }

            // board.json and the checkouts are read off the main thread,
            // then the form opens as a sheet; Cancel writes nothing.
            harness.perform(["Board Settings…"], in: shell.sidebar.spaceOptionsMenu())
            harness.waitUntil("the board settings sheet") { shell.boardSettingsPanel?.panel?.isSheet == true }
            let board = try XCTUnwrap(shell.boardSettingsPanel)
            XCTAssertIdentical(harness.window.attachedSheet, board.panel)
            XCTAssertEqual(board.spaceID, space.id)
            board.cancelButton.performClick(nil)
            XCTAssertNil(shell.boardSettingsPanel)
            XCTAssertNil(harness.window.attachedSheet)
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(BoardConfigStore(spaceID: space.id)).fileURL.path))

            // A second workspace moves back to the default space; the first
            // keeps the space from being empty.
            shell.addWorkspace(title: "moving", cwd: harness.repo)
            let moving = try XCTUnwrap(shell.activeWorkspace)
            let movingIndex = try XCTUnwrap(shell.workspaces.firstIndex { $0 === moving })
            let defaultName = try XCTUnwrap(shell.profiles.first { $0.id == WorkspaceProfile.defaultID }).name
            harness.perform(
                ["Move to Space", defaultName],
                in: shell.sidebar.workspaceActionMenu(workspaceIndex: movingIndex, columnIndex: nil)
            )
            XCTAssertEqual(moving.profileID, WorkspaceProfile.defaultID)
            XCTAssertEqual(shell.activeProfileID, space.id)

            // Deleting asks first: Cancel keeps the space, confirming moves
            // its workspace to the default space.
            harness.alertResponses = [.alertFirstButtonReturn]
            harness.perform(["Delete Space…"], in: shell.sidebar.spaceOptionsMenu())
            XCTAssertEqual(harness.alerts.last, "Delete the space \"Flow Space\"?")
            XCTAssertTrue(shell.profiles.contains { $0.id == space.id })
            harness.alertResponses = [.alertSecondButtonReturn]
            harness.perform(["Delete Space…"], in: shell.sidebar.spaceOptionsMenu())
            XCTAssertFalse(shell.profiles.contains { $0.id == space.id })
            XCTAssertEqual(spaceWorkspace.profileID, WorkspaceProfile.defaultID)
        }
    }

    // MARK: - Panels

    func testGettingStartedCardButtons() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.showOnboardingChecklist()
            // Laid out once the sidebar is open at full width. Its width
            // animates, and an animation never lands while the screen is
            // locked: settle the frames once it has opened.
            harness.waitUntil("the sidebar to open") { shell.sidebar.isExpanded }
            shell.relayout(animated: false)
            harness.waitUntil("the Getting Started card") { shell.sidebar.onboardingCardView?.superview != nil }
            let card = try XCTUnwrap(shell.sidebar.onboardingCardView)
            @MainActor func button(_ label: String) throws -> OnboardingChecklistButton {
                try XCTUnwrap(
                    card.subviews.compactMap { $0 as? OnboardingChecklistButton }.first { $0.accessibilityLabel() == label },
                    label
                )
            }
            XCTAssertEqual(shell.sidebar.onboardingChecklist?.skills, .missing)

            XCTAssertTrue(try button("Install").accessibilityPerformPress())
            // The card turning green is the confirmation: no alert.
            XCTAssertEqual(harness.alerts, [])
            XCTAssertEqual(shell.sidebar.onboardingChecklist?.skills, .installed)
            XCTAssertTrue(FileManager.default.fileExists(atPath: harness.home + "/.claude/skills/nirux-worktree/SKILL.md"))

            // Offered while no agent CLI is on the PATH, as on CI.
            if shell.sidebar.onboardingChecklist?.agents.anyFound == false {
                XCTAssertTrue(try button("Check again").accessibilityPerformPress())
                XCTAssertEqual(shell.onboardingState, .pending)
            }
            XCTAssertTrue(try button("Hide Getting Started").accessibilityPerformPress())
            XCTAssertNotEqual(shell.onboardingState, .pending)
            XCTAssertNil(shell.sidebar.onboardingChecklist)
        }
    }

    func testTerminalFindBar() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let column = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex])

            // ⌘F, ⌘G and ⇧⌘G from the Edit menu.
            shell.showTerminalFind()
            XCTAssertTrue(column.isFindBarOpen)
            let bar = try XCTUnwrap(column.findBar)
            harness.type("flow", into: bar.field)
            XCTAssertEqual(column.terminalSearch?.needle, "flow")
            shell.findNextInTerminal()
            shell.findPreviousInTerminal()
            @MainActor func button(_ label: String) throws -> NSButton {
                try XCTUnwrap(bar.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == label }, label)
            }
            try button("Next Match").performClick(nil)
            try button("Previous Match").performClick(nil)
            try button("Close Find Bar").performClick(nil)
            XCTAssertFalse(column.isFindBarOpen)
        }
    }

    func testEditorFilePicker() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            shell.openEditorColumn()
            let editor = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.editorColumn)

            // What Monaco's ⌘P sends over the bridge. The folder is scanned
            // off the main thread.
            editor.onFilePickerRequest?(editor)
            let field = try XCTUnwrap(harness.waitForField(placeholder: "Find file in workspace…"))
            let table = try XCTUnwrap(field.window?.contentView.flatMap {
                UIFlowHarness.descendant(of: $0, as: NSTableView.self)
            })
            harness.waitUntil("the file list") { table.numberOfRows >= 2 }
            harness.type("search-target", into: field)
            XCTAssertEqual(table.numberOfRows, 1)
            harness.press(.returnKey, in: field.window)
            let target = harness.repo + "/" + UIFlowHarness.searchTarget
            harness.waitUntil("the picked file in the editor") { editor.activePath == target }
            XCTAssertFalse(field.window?.isVisible ?? true, "the picker stayed open")
        }
    }

    /// A request without a current launch ID waits for the user in a sheet
    /// on the main window; Cancel does nothing. The URL goes straight to
    /// the app delegate's handler, never through `open`, which would reach
    /// the installed Nirux. Confirm isn't run: it only arms while Nirux is
    /// the active app, which a test process can't be.
    func testNiruxURLConfirmationSheet() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let app = NiruxApp()
            app.shell = shell
            app.mainWindow = harness.window
            let workspaceCount = shell.workspaces.count
            var components = URLComponents()
            components.scheme = "nirux"
            components.host = "new-workspace"
            components.queryItems = [
                URLQueryItem(name: "cwd", value: harness.repo),
                URLQueryItem(name: "title", value: "from a link")
            ]
            let url = try XCTUnwrap(components.url)

            app.application(NSApp, open: [url])
            harness.waitUntil("the confirmation sheet") { harness.window.attachedSheet != nil }
            let sheet = try XCTUnwrap(harness.window.attachedSheet)
            let cancel = try XCTUnwrap(sheet.contentView.flatMap { UIFlowHarness.button(titled: "Cancel", in: $0) })
            cancel.performClick(nil)
            harness.waitUntil("the sheet to close") { harness.window.attachedSheet == nil }
            XCTAssertTrue(app.urlConfirmations.isIdle)
            XCTAssertEqual(shell.workspaces.count, workspaceCount)
            XCTAssertFalse(shell.workspaces.contains { $0.title == "from a link" })
        }
    }
}
