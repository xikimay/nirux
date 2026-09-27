import AppKit
import XCTest
@testable import Nirux

/// Opens the panels the palette doesn't reach, from where the user does:
/// the sidebar's workspace and space menus, the Getting Started card, the
/// terminal find bar, the editor's file picker and the confirmation of a
/// `nirux://` request. Each waits for the work its panel starts off the
/// main thread (see UIFlowHarness).
@MainActor
final class SidebarPanelFlowTests: XCTestCase {
    func testWorkspaceMenuItems() throws {
        let harness = try UIFlowHarness()
        defer { harness.close() }
        let shell = harness.shell
        let workspace = try XCTUnwrap(shell.activeWorkspace)
        func menu(for workspace: WorkspaceState) throws -> NSMenu {
            let index = try XCTUnwrap(shell.workspaces.firstIndex { $0 === workspace })
            return shell.sidebar.workspaceActionMenu(workspaceIndex: index, columnIndex: nil)
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

        // A workspace in the linked worktree: its clean-up is checked off
        // the main thread, then refused (no GitHub remote), and nothing goes.
        shell.addWorkspace(title: "in worktree", cwd: harness.worktree)
        let worktreeWorkspace = try XCTUnwrap(shell.activeWorkspace)
        harness.perform(["Clean Up Worktree…"], in: try menu(for: worktreeWorkspace))
        harness.waitUntil("the clean-up verdict") {
            !harness.alerts.isEmpty && shell.worktreeCleanupsInFlight.isEmpty
        }
        XCTAssertTrue(harness.alerts.first?.hasPrefix("Can’t clean up") == true, "\(harness.alerts)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.worktree))

        harness.perform(["Move to Inactive"], in: try menu(for: worktreeWorkspace))
        XCTAssertTrue(worktreeWorkspace.isInactive)
        harness.perform(["Move to Active"], in: try menu(for: worktreeWorkspace))
        XCTAssertFalse(worktreeWorkspace.isInactive)

        // No agent runs in it: it closes without asking.
        harness.perform(["Close Workspace"], in: try menu(for: worktreeWorkspace))
        harness.waitUntil("the workspace to close") { !shell.workspaces.contains { $0 === worktreeWorkspace } }
        XCTAssertEqual(harness.alerts.count, 1)
    }

    func testSpaceMenuItems() throws {
        let harness = try UIFlowHarness()
        defer { harness.close() }
        let shell = harness.shell
        func activeSpace() throws -> WorkspaceProfile {
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

        // Deleting asks first: Cancel keeps the space.
        harness.alertResponses = [.alertFirstButtonReturn]
        harness.perform(["Delete Space…"], in: shell.sidebar.spaceOptionsMenu())
        XCTAssertEqual(harness.alerts.last, "Delete the space \"Flow Space\"?")
        XCTAssertTrue(shell.profiles.contains { $0.id == space.id })

        let spaceWorkspaceIndex = try XCTUnwrap(shell.workspaces.firstIndex { $0 === spaceWorkspace })
        let defaultName = try XCTUnwrap(shell.profiles.first { $0.id == WorkspaceProfile.defaultID }).name
        harness.perform(
            ["Move to Space", defaultName],
            in: shell.sidebar.workspaceActionMenu(workspaceIndex: spaceWorkspaceIndex, columnIndex: nil)
        )
        XCTAssertEqual(spaceWorkspace.profileID, WorkspaceProfile.defaultID)

        shell.selectProfile(space.id)
        harness.alertResponses = [.alertSecondButtonReturn]
        harness.perform(["Delete Space…"], in: shell.sidebar.spaceOptionsMenu())
        XCTAssertFalse(shell.profiles.contains { $0.id == space.id })
    }

    func testGettingStartedCardButtons() throws {
        let harness = try UIFlowHarness()
        defer { harness.close() }
        let shell = harness.shell
        shell.showOnboardingChecklist()
        // Laid out once the sidebar has opened.
        harness.waitUntil("the Getting Started card") { shell.sidebar.onboardingCardView?.superview != nil }
        let card = try XCTUnwrap(shell.sidebar.onboardingCardView)
        func button(_ label: String) throws -> OnboardingChecklistButton {
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

    func testTerminalFindBar() throws {
        let harness = try UIFlowHarness()
        defer { harness.close() }
        let shell = harness.shell
        let workspace = try XCTUnwrap(shell.activeWorkspace)
        let column = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex])

        shell.showTerminalFind()
        XCTAssertTrue(column.isFindBarOpen)
        let bar = try XCTUnwrap(column.findBar)
        harness.type("flow", into: bar.field)
        shell.findNextInTerminal()
        shell.findPreviousInTerminal()
        harness.press(.escape, in: shell.window)
        bar.onClose?()
        XCTAssertFalse(column.isFindBarOpen)
    }

    func testEditorFilePicker() throws {
        let harness = try UIFlowHarness()
        defer { harness.close() }
        let shell = harness.shell
        let workspace = try XCTUnwrap(shell.activeWorkspace)
        shell.openEditorColumn()
        let editor = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.editorColumn)

        // What Monaco's ⌘P sends over the bridge. The folder is scanned off
        // the main thread.
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

    /// A request without a current launch ID waits for the user in a sheet
    /// on the main window; Cancel does nothing. The URL goes straight to the
    /// app delegate's handler: never through `open`, which would reach the
    /// installed Nirux.
    func testNiruxURLConfirmationSheet() throws {
        let harness = try UIFlowHarness()
        defer { harness.close() }
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
