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
                "Rename Workspace"
            ],
            "testOrganizeMenuItems": ["Organize"],
            "testNewSubtaskMenuItem": [SidebarView.newSubtaskTitle],
            "testCIFailureMenuItems": ["Ask Agent Why CI Failed", "Rerun Failed CI Jobs…"],
            "testReviewBranchMenuItem": ["Review Branch"],
            "testSpaceMenuItems": ["New Space…", "Space Settings…", "Delete Space…"]
        ],
        exemptions: [:]
    )

    override class var coverage: UIFlowCoverage? { menuCoverage }

    // MARK: - Menus

    /// Builds the menus with every item showing: two spaces, one with a
    /// repository, a workspace in a worktree with two columns, an inactive
    /// workspace.
    func testEverySidebarMenuItemHasAFlowTest() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let repository = try XCTUnwrap(FolderIdentity.identify(harness.repo, timeout: 10)).anchor
            shell.createSpace(NewSpacePanel.Draft(name: "flow", colorHex: WorkspaceProfile.palette[1].hex, anchors: [repository]))
            harness.waitUntil("the new space on screen") {
                shell.profiles.first { $0.id == shell.activeProfileID }?.name == "flow"
            }
            shell.addWorkspace(title: "inactive", cwd: harness.repo)
            let inactiveIndex = try XCTUnwrap(shell.workspaces.firstIndex { $0.title == "inactive" })
            shell.handleWorkspaceSidebarAction(.markInactive, workspaceIndex: inactiveIndex)
            shell.addWorkspace(title: "in worktree", cwd: harness.worktree)
            shell.addColumn()
            let worktreeIndex = try XCTUnwrap(shell.activeWorkspace.flatMap { active in
                shell.workspaces.firstIndex { $0 === active }
            })
            shell.workspaces[worktreeIndex].prInfo = Self.redPullRequest
            let gone = harness.root + "/gone"
            try FileManager.default.createDirectory(atPath: gone, withIntermediateDirectories: true)
            shell.addWorkspace(title: "gone", cwd: gone)
            let goneIndex = try XCTUnwrap(shell.workspaces.firstIndex { $0.title == "gone" })
            try FileManager.default.removeItem(atPath: gone)
            shell.updateSidebar()
            let picker = shell.sidebar.spacePickerMenu()
            let menus = [
                shell.sidebar.workspaceActionMenu(workspaceIndex: worktreeIndex, columnIndex: 1),
                shell.sidebar.workspaceActionMenu(workspaceIndex: inactiveIndex, columnIndex: nil),
                shell.sidebar.workspaceActionMenu(workspaceIndex: goneIndex, columnIndex: nil),
                picker
            ]
            // The spaces themselves, listed first: SidebarSpacePickerTests.
            let spaces = Set(picker.items.prefix(shell.sidebar.lastProfiles.count).map(ObjectIdentifier.init))
            let titles = menus.flatMap(\.items)
                .filter { !$0.isSeparatorItem && !spaces.contains(ObjectIdentifier($0)) }.map(\.title)
            Self.menuCoverage.checkEveryItemIsCovered(
                offered: Array(Set(titles)), testNames: UIFlowCoverage.testNames(of: Self.self)
            )
            // What the workspace's state offers first, then New Sub-task…
            // and Organize, then Rename, its context and Close.
            XCTAssertEqual(menus[0].items.map(\.title), [
                "Focus Column", "Close Column", "",
                "Review Branch", "Ask Agent Why CI Failed", "Rerun Failed CI Jobs…", "",
                "New Sub-task…", "Organize", "",
                "Rename Workspace", "View/Edit Context…", "",
                "Clean Up Worktree…", "Close Workspace"
            ])
            // The folder is gone: Clean Up comes up among the state actions,
            // and it is no task to start a sub-task of.
            XCTAssertEqual(menus[2].items.prefix(4).map(\.title), ["Review Branch", "Clean Up Worktree…", "", "Organize"])
        }
    }

    /// From the menu of a workspace in the background: that workspace
    /// comes to the front, with the review of its folder.
    func testReviewBranchMenuItem() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.branchReviewReader = BranchReviewPageTests.reader
            let first = try XCTUnwrap(shell.activeWorkspace)
            shell.addWorkspace(title: "in worktree", cwd: harness.worktree)
            let worktreeWorkspace = try XCTUnwrap(shell.activeWorkspace)
            shell.focusWorkspace(id: first.id)
            XCTAssertIdentical(shell.activeWorkspace, first)

            let index = try XCTUnwrap(shell.workspaces.firstIndex { $0 === worktreeWorkspace })
            harness.perform(["Review Branch"], in: shell.sidebar.workspaceActionMenu(workspaceIndex: index, columnIndex: nil))
            XCTAssertIdentical(shell.activeWorkspace, worktreeWorkspace)
            let review = try XCTUnwrap(worktreeWorkspace.columns[safe: worktreeWorkspace.focusedIndex]?.branchReview)
            XCTAssertEqual(review.worktree, harness.worktree)
            XCTAssertFalse(first.columns.contains(where: \.isBranchReview))
            harness.waitUntil("the review to read its branch") { review.snapshot != nil }
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

            // A column closing while a column's menu is open: its items act on
            // the column it was built for.
            shell.addColumn()
            shell.addColumn()
            let kept = workspace.columns[1]
            let target = workspace.columns[2]
            shell.updateSidebar()
            let columnMenu = try menu(for: workspace, column: 2)
            shell.closeColumn(workspaceIndex: try XCTUnwrap(shell.workspaces.firstIndex { $0 === workspace }), columnIndex: 0)
            harness.waitUntil("the first column to close") { workspace.columns.count == 2 }
            harness.perform(["Close Column"], in: columnMenu)
            harness.waitUntil("its column to close") { !workspace.columns.contains { $0 === target } }
            XCTAssertTrue(workspace.columns.contains { $0 === kept })

            shell.addWorkspace()
            let added = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertFalse(added === workspace)
            // No agent runs in it: it closes without asking.
            harness.perform(["Close Workspace"], in: try menu(for: added))
            harness.waitUntil("the workspace to close") { !shell.workspaces.contains { $0 === added } }

            // In the linked worktree: next to Close, then on top once its
            // pull request is merged; checked off the main thread and refused
            // (no GitHub remote), and nothing goes.
            shell.addWorkspace(title: "in worktree", cwd: harness.worktree)
            let worktreeWorkspace = try XCTUnwrap(shell.activeWorkspace)
            shell.refreshGitContextNow(for: worktreeWorkspace)
            harness.waitUntil("the worktree's git context") {
                worktreeWorkspace.gitContext.map { NiruxShellView.comparablePath($0.identity.repositoryRoot) }
                    == NiruxShellView.comparablePath(harness.worktree)
            }
            XCTAssertEqual(try menu(for: worktreeWorkspace).items.suffix(2).map(\.title), ["Clean Up Worktree…", "Close Workspace"])
            // Set and read in one run-loop turn: a git refresh can't clear it
            // in between.
            worktreeWorkspace.prInfo = PRInfo(
                number: 7, state: "MERGED", isDraft: false, ciStatus: nil, checks: [], reviewDecision: nil,
                mergeable: nil, url: "https://example.test/pull/7", additions: nil, deletions: nil, changedFiles: nil
            )
            let merged = try menu(for: worktreeWorkspace)
            XCTAssertEqual(merged.items.prefix(2).map(\.title), ["Review Branch", "Clean Up Worktree…"])
            XCTAssertEqual(merged.items.filter { $0.title == "Clean Up Worktree…" }.count, 1)
            harness.perform(["Clean Up Worktree…"], in: merged)
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

            // The store changes while a menu is open (a sub-task arrives under
            // a task above): its items act on the card it was built for.
            shell.addWorkspace(title: "task", cwd: harness.worktree)
            let task = try XCTUnwrap(shell.activeWorkspace)
            shell.addWorkspace(title: "below")
            let below = try XCTUnwrap(shell.activeWorkspace)
            shell.updateSidebar()
            let staleMenu = try menu(for: below)
            let builtAt = try XCTUnwrap(shell.workspaces.firstIndex { $0 === below })
            shell.addWorkspace(title: "sub-task", cwd: harness.repo, parentWorkspaceID: task.id)
            let subtask = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertTrue(shell.workspaces[builtAt] === subtask, "the sub-task took its index")
            harness.perform(["Close Workspace"], in: staleMenu)
            harness.waitUntil("the workspace to close") { !shell.workspaces.contains { $0 === below } }
            XCTAssertTrue(shell.workspaces.contains { $0 === subtask })

            // Built for a workspace of another space, with no card on screen:
            // found by id too when a workspace before it closes.
            let shownSpace = shell.activeProfileID
            let elsewhere = shell.workspaceStore.createProfile(named: "Elsewhere", select: false)
            shell.addWorkspace(title: "first in line")
            let firstInLine = try XCTUnwrap(shell.activeWorkspace)
            shell.addWorkspace(title: "away", profileID: elsewhere.id)
            let away = try XCTUnwrap(shell.workspaces.first { $0.title == "away" })
            shell.selectProfile(shownSpace)
            shell.addWorkspace(title: "next in line", profileID: shownSpace)
            let nextInLine = try XCTUnwrap(shell.workspaces.first { $0.title == "next in line" })
            shell.updateSidebar()
            XCTAssertFalse(shell.sidebar.lastInfos.contains { $0.id == away.id })
            let awayMenu = try menu(for: away)
            shell.handleWorkspaceSidebarAction(.close, workspaceIndex: try XCTUnwrap(shell.workspaces.firstIndex { $0 === firstInLine }))
            harness.waitUntil("the first in line to close") { !shell.workspaces.contains { $0 === firstInLine } }
            harness.perform(["Close Workspace"], in: awayMenu)
            harness.waitUntil("the workspace away to close") { !shell.workspaces.contains { $0 === away } }
            XCTAssertTrue(shell.workspaces.contains { $0 === nextInLine })
        }
    }

    /// A task's New Sub-task… opens ⌘N under it, in the repository the task
    /// works in: the task it starts, which needs a description, lists under
    /// it while "Sub-task of" stays checked. Only an active task outside
    /// General, in a space that has its repository, offers it: not the main
    /// checkout.
    func testNewSubtaskMenuItem() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let other = harness.root + "/other"
            try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
            try UIFlowHarness.git(["init", "-q", "-b", "main"], at: other)
            try UIFlowHarness.git(
                ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "--allow-empty", "-m", "init"], at: other
            )
            try UIFlowHarness.git(["worktree", "add", "-q", "-b", "feat/other", other + ".feat-other"], at: other)
            let otherRepository = try XCTUnwrap(FolderIdentity.identify(other, timeout: 10)).anchor
            let repository = try XCTUnwrap(FolderIdentity.identify(harness.repo, timeout: 10)).anchor
            let docs = try XCTUnwrap((harness.repo + "/docs").realPath)
            let space = try NewTaskFlowTests.anchoredSpace(harness, also: [otherRepository, .folder(docs)])
            let checkout = try XCTUnwrap(shell.activeWorkspace)
            shell.addWorkspace(title: "Parent", cwd: harness.worktree, profileID: space.id)
            let task = try XCTUnwrap(shell.activeWorkspace)
            @MainActor func index(_ workspace: WorkspaceState) throws -> Int {
                try XCTUnwrap(shell.workspaces.firstIndex { $0 === workspace })
            }
            @MainActor func offers(_ workspace: WorkspaceState) throws -> Bool {
                shell.updateSidebar()
                return shell.sidebar.workspaceActionMenu(workspaceIndex: try index(workspace), columnIndex: nil)
                    .items.contains { $0.title == SidebarView.newSubtaskTitle }
            }
            @MainActor func newSubtask(of parent: WorkspaceState) throws -> NewTaskPanel {
                shell.updateSidebar()
                harness.perform(
                    [SidebarView.newSubtaskTitle], in: shell.sidebar.workspaceActionMenu(workspaceIndex: try index(parent), columnIndex: nil)
                )
                let sheet = try XCTUnwrap(shell.newTaskPanel)
                harness.waitUntil("the repository's info") { sheet.info != nil }
                return sheet
            }
            @MainActor func start(_ description: String, in sheet: NewTaskPanel) throws -> WorkspaceState {
                let before = Set(shell.workspaces.map(ObjectIdentifier.init))
                let opened = { shell.workspaces.first { !before.contains(ObjectIdentifier($0)) } }
                sheet.descriptionView.string = description
                sheet.descriptionView.didChangeText()
                sheet.startButton.performClick(nil)
                harness.waitUntil("the new workspace") { opened() != nil }
                return try XCTUnwrap(opened())
            }

            var sheet = try newSubtask(of: task)
            XCTAssertEqual(sheet.headingLabel.stringValue, "New Sub-task in Repo")
            XCTAssertFalse(sheet.subtaskCheckbox.isHidden)
            XCTAssertEqual(sheet.subtaskCheckbox.title, "Sub-task of “Parent”")
            XCTAssertEqual(sheet.subtaskCheckbox.state, .on)
            XCTAssertTrue(sheet.existingBranchButton.isHidden, "a sub-task is new work")
            XCTAssertTrue(sheet.repositoryPopup.isHidden, "the task's repository")
            XCTAssertEqual(sheet.selectedRepositoryKey, repository.key)
            // A repository added meanwhile isn't where the sub-task starts.
            shell.refreshNewTaskPanelRepositories(selecting: otherRepository.key)
            XCTAssertEqual(sheet.selectedRepositoryKey, repository.key)
            XCTAssertFalse(sheet.startButton.isEnabled, "it needs a description")
            XCTAssertEqual(sheet.lineLabel.stringValue, "Describe the sub-task.")
            let child = try start("Child work", in: sheet)
            XCTAssertEqual(child.title, "Child work")
            XCTAssertEqual(shell.workspaceStore.activeParents(in: space.id)[try index(child)], try index(task))

            // Unchecked: a task of its own, in any repository. Checked
            // again: back in the task's.
            sheet = try newSubtask(of: task)
            sheet.subtaskCheckbox.performClick(nil)
            XCTAssertEqual(sheet.headingLabel.stringValue, "New in Repo")
            XCTAssertFalse(sheet.existingBranchButton.isHidden)
            XCTAssertFalse(sheet.repositoryPopup.isHidden)
            sheet.repositoryPopup.selectItem(at: sheet.repositoryPopup.indexOfItem(withRepresentedObject: otherRepository.key))
            sheet.repositoryPopup.sendAction(sheet.repositoryPopup.action, to: sheet.repositoryPopup.target)
            XCTAssertEqual(sheet.selectedRepositoryKey, otherRepository.key)
            sheet.subtaskCheckbox.performClick(nil)
            XCTAssertEqual(sheet.selectedRepositoryKey, repository.key)
            XCTAssertTrue(sheet.repositoryPopup.isHidden)
            sheet.subtaskCheckbox.performClick(nil)
            harness.waitUntil("the repository's info") { sheet.info != nil }
            let own = try start("Own work", in: sheet)
            XCTAssertNil(own.parentWorkspaceID)

            // A task in the space's other repository: its sub-task starts there.
            shell.addWorkspace(title: "Other task", cwd: other + ".feat-other", profileID: space.id)
            sheet = try newSubtask(of: try XCTUnwrap(shell.activeWorkspace))
            XCTAssertEqual(sheet.selectedRepositoryKey, otherRepository.key)
            sheet.cancelButton.performClick(nil)
            // A task in the folder of the repository the space has: there.
            try FileManager.default.createDirectory(atPath: harness.worktree + "/docs", withIntermediateDirectories: true)
            shell.addWorkspace(title: "Docs task", cwd: harness.worktree + "/docs", profileID: space.id)
            sheet = try newSubtask(of: try XCTUnwrap(shell.activeWorkspace))
            XCTAssertEqual(sheet.selectedRepositoryKey, SpaceAnchor.folder(docs).key)
            sheet.cancelButton.performClick(nil)
            // A space without the task's repository, only a folder holding
            // all of it: nowhere to start one.
            let solo = shell.workspaceStore.createProfile(named: "Solo", anchors: [.folder(harness.root)], select: false)
            shell.addWorkspace(title: "Stray task", cwd: other + ".feat-other", profileID: solo.id)
            XCTAssertFalse(try offers(try XCTUnwrap(shell.workspaces.first { $0.title == "Stray task" })), "not its repository")

            XCTAssertFalse(try offers(checkout), "the main checkout isn't a task")
            shell.handleWorkspaceSidebarAction(.markInactive, workspaceIndex: try index(own))
            XCTAssertFalse(try offers(own), "archived")
            shell.addWorkspace(title: "General task", cwd: harness.worktree, profileID: WorkspaceProfile.defaultID)
            let generalTask = try XCTUnwrap(shell.workspaces.first { $0.title == "General task" })
            shell.selectProfile(WorkspaceProfile.defaultID)
            XCTAssertFalse(try offers(generalTask), "General")

            // Its worktree removed, a task is none.
            let otherTask = try XCTUnwrap(shell.workspaces.first { $0.title == "Other task" })
            XCTAssertTrue(try offers(otherTask))
            try FileManager.default.removeItem(atPath: other + ".feat-other")
            XCTAssertFalse(try offers(otherTask), "worktree removed")
            // Its folder removed, in a worktree still there: none either.
            let docsTask = try XCTUnwrap(shell.workspaces.first { $0.title == "Docs task" })
            XCTAssertTrue(try offers(docsTask))
            try FileManager.default.removeItem(atPath: harness.worktree + "/docs")
            XCTAssertFalse(try offers(docsTask), "folder removed")
        }
    }

    /// The card's moves, in its Organize submenu: up and down the list, to
    /// Archived and back, to another space.
    func testOrganizeMenuItems() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.addWorkspace(title: "moving", cwd: harness.repo)
            let moving = try XCTUnwrap(shell.activeWorkspace)
            @MainActor func menu() throws -> NSMenu {
                let index = try XCTUnwrap(shell.workspaces.firstIndex { $0 === moving })
                return shell.sidebar.workspaceActionMenu(workspaceIndex: index, columnIndex: nil)
            }
            @MainActor func position() -> Int? { shell.visibleWorkspaceIndices.firstIndex { shell.workspaces[$0] === moving } }

            let before = try XCTUnwrap(position())
            harness.perform(["Organize", "Move Up"], in: try menu())
            XCTAssertEqual(position(), before - 1)
            harness.perform(["Organize", "Move Down"], in: try menu())
            XCTAssertEqual(position(), before)
            harness.perform(["Organize", "Archive"], in: try menu())
            XCTAssertTrue(moving.isInactive)
            harness.perform(["Organize", "Unarchive"], in: try menu())
            XCTAssertFalse(moving.isInactive)

            // With a second space to move to; the default space stays in front.
            let space = shell.workspaceStore.createProfile(named: "Other").id
            shell.selectProfile(WorkspaceProfile.defaultID)
            XCTAssertEqual(shell.activeProfileID, WorkspaceProfile.defaultID)
            let organize = try XCTUnwrap(try menu().items.first { $0.title == "Organize" }?.submenu)
            XCTAssertEqual(organize.items.map(\.title), ["Move Up", "Move Down", "Move to Space", "", "Archive"])
            let spaceName = try XCTUnwrap(shell.profiles.first { $0.id == space }).name
            harness.perform(["Organize", "Move to Space", spaceName], in: try menu())
            XCTAssertEqual(moving.profileID, space)
            XCTAssertEqual(shell.activeProfileID, WorkspaceProfile.defaultID)

            // Move Out of “<task>” lists a sub-task next to its task, after
            // its other sub-tasks: under that task's own task, else a task
            // of its own. The store keeps that order: archived, the task lets
            // them go where they were listed.
            shell.addWorkspace(title: "task", cwd: harness.worktree)
            let task = try XCTUnwrap(shell.activeWorkspace)
            @MainActor func open(_ title: String, under parent: WorkspaceState, in cwd: String? = nil) throws -> WorkspaceState {
                shell.addWorkspace(title: title, cwd: cwd ?? harness.repo, parentWorkspaceID: parent.id)
                return try XCTUnwrap(shell.activeWorkspace)
            }
            let first = try open("first", under: task)
            // A task too (in a worktree), to have one of its own.
            let second = try open("second", under: task, in: harness.worktree)
            let third = try open("third", under: second)
            XCTAssertEqual(third.parentWorkspaceID, second.id)
            shell.addWorkspace(title: "after", cwd: harness.repo)
            @MainActor func menu(for workspace: WorkspaceState) throws -> NSMenu {
                shell.updateSidebar()
                let index = try XCTUnwrap(shell.workspaces.firstIndex { $0 === workspace })
                return shell.sidebar.workspaceActionMenu(workspaceIndex: index, columnIndex: nil)
            }
            let titles = { shell.visibleWorkspaceIndices.map { shell.workspaces[$0].title }.filter { $0 != "moving" } }
            XCTAssertEqual(titles().suffix(5), ["task", "first", "second", "third", "after"])
            let firstOrganize = try XCTUnwrap(try menu(for: first).items.first { $0.title == "Organize" }?.submenu)
            XCTAssertEqual(
                firstOrganize.items.map(\.title),
                ["Move Up", "Move Down", SidebarView.moveOutTitle(parentTitle: "task"), "Move to Space", "", "Archive"]
            )
            harness.perform(["Organize", SidebarView.moveOutTitle(parentTitle: "second")], in: try menu(for: third))
            XCTAssertEqual(third.parentWorkspaceID, task.id)
            harness.perform(["Organize", SidebarView.moveOutTitle(parentTitle: "task")], in: try menu(for: first))
            XCTAssertNil(first.parentWorkspaceID)
            XCTAssertEqual(titles().suffix(5), ["task", "second", "third", "first", "after"])
            harness.perform(["Organize", "Archive"], in: try menu(for: task))
            XCTAssertEqual(titles().suffix(5), ["second", "third", "first", "after", "task"])

            // Out from under a task whose own task is archived: a task of its
            // own, not one that task would take back.
            let fourth = try open("fourth", under: second)
            harness.perform(["Organize", SidebarView.moveOutTitle(parentTitle: "second")], in: try menu(for: fourth))
            XCTAssertNil(fourth.parentWorkspaceID)
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
    /// rerun asks first, and only a confirmed one reaches GitHub.
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
            XCTAssertEqual(harness.alerts, ["Rerun the failed jobs of #52?"])

            // Confirmed: the double refuses, and the refusal shows.
            harness.perform(["Rerun Failed CI Jobs…"], in: shell.sidebar.workspaceActionMenu(workspaceIndex: index, columnIndex: nil))
            harness.waitUntil("the rerun's answer") { harness.alerts.count == 3 }
            XCTAssertEqual(harness.alerts.last, "Nirux couldn’t rerun the failed jobs")
        }
    }

    func testSpaceMenuItems() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            @MainActor func activeSpace() throws -> WorkspaceProfile {
                try XCTUnwrap(shell.profiles.first { $0.id == shell.activeProfileID })
            }

            // The focused terminal's repository is already in the sheet and
            // names the space. Creating it offers to move that repository's
            // workspace in from the default space, checked: it moves.
            harness.perform(["New Space…"], in: shell.sidebar.spacePickerMenu())
            harness.waitUntil("the New Space sheet") { shell.newSpacePanel?.panel?.isSheet == true }
            let sheet = try XCTUnwrap(shell.newSpacePanel)
            XCTAssertEqual(sheet.rows.map(\.anchor), [SpaceAnchor(kind: .gitRepository(commonDir: harness.repo + "/.git"), name: "repo", isDefault: true)])
            XCTAssertEqual(sheet.nameField.stringValue, "repo")
            let repoWorkspace = try XCTUnwrap(shell.activeWorkspace)
            sheet.createButton.performClick(nil)
            XCTAssertNil(harness.window.attachedSheet)
            harness.waitUntil("the new space on screen") { shell.activeProfileID != WorkspaceProfile.defaultID }
            XCTAssertEqual(harness.alerts.last, "Move workspaces to “repo”?")
            let space = try activeSpace()
            XCTAssertEqual(space.name, "repo")
            XCTAssertEqual(space.anchors.map(\.name), ["repo"])
            let spaceWorkspace = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertIdentical(spaceWorkspace, repoWorkspace)
            XCTAssertEqual(spaceWorkspace.profileID, space.id)

            // Space Settings opens on General: the name, the color, the
            // repositories; its tabs hold what the space menu used to.
            harness.perform(["Space Settings…"], in: shell.sidebar.spacePickerMenu())
            let settings = try XCTUnwrap(shell.spaceSettings)
            XCTAssertEqual(settings.spaceID, space.id)
            XCTAssertEqual(settings.selectedTab, .general)
            XCTAssertEqual(settings.panel?.title, "repo Settings")
            XCTAssertEqual(settings.general.model.rows.map(\.anchor.name), ["repo"])
            let nameField = try XCTUnwrap(harness.waitForField(placeholder: "Space name"))
            XCTAssertIdentical(nameField, settings.general.nameField)
            XCTAssertEqual(nameField.stringValue, space.name)
            harness.submit("Flow Space", into: nameField)
            XCTAssertEqual(try activeSpace().name, "Flow Space")
            XCTAssertEqual(settings.panel?.title, "Flow Space Settings")

            let color = try XCTUnwrap(WorkspaceProfile.palette.first {
                $0.hex.caseInsensitiveCompare(space.colorHex) != .orderedSame
            })
            let colors = settings.general.colorPopup
            colors.selectItem(at: try XCTUnwrap(colors.itemArray.firstIndex { $0.title == color.name }))
            NSApp.sendAction(try XCTUnwrap(colors.action), to: colors.target, from: colors)
            XCTAssertEqual(try activeSpace().colorHex.uppercased(), color.hex.uppercased())

            // The brief's tab shows its template until Save writes it, in
            // the state folder.
            shell.showSpaceSettings(profileID: space.id, tab: .brief)
            XCTAssertEqual(settings.selectedTab, .brief)
            let brief = try XCTUnwrap(SpaceBrief.briefURL(spaceID: space.id)).path
            XCTAssertTrue(brief.hasPrefix(harness.stateDirectory + "/"), brief)
            XCTAssertFalse(FileManager.default.fileExists(atPath: brief))
            XCTAssertTrue(settings.brief.textView.string.contains("Brief for the space \"Flow Space\""))
            settings.brief.textView.string += "Ship small PRs.\n"
            settings.brief.textDidChange(Notification(name: NSText.didChangeNotification))
            XCTAssertTrue(settings.brief.isDirty)
            settings.brief.saveButton.performClick(nil)
            XCTAssertFalse(settings.brief.isDirty)
            XCTAssertEqual(SpaceBrief.readBrief(at: URL(fileURLWithPath: brief)).flatMap(SpaceBrief.body(of:)), "Ship small PRs.")
            XCTAssertTrue(spaceWorkspace.columns.compactMap(\.editorColumn).isEmpty, "no editor column")

            // The templates' tab shows the defaults; saving them keeps them.
            shell.showSpaceSettings(profileID: space.id, tab: .templates)
            XCTAssertEqual(settings.selectedTab, .templates)
            let templates = try XCTUnwrap(TaskTemplates.fileURL(spaceID: space.id)).path
            XCTAssertTrue(templates.hasPrefix(harness.stateDirectory + "/"), templates)
            XCTAssertEqual(TaskTemplates.parse(settings.templates.textView.string), TaskTemplates.defaults)
            settings.templates.saveButton.performClick(nil)
            XCTAssertEqual(TaskTemplates.load(spaceID: space.id), TaskTemplates.defaults)
            XCTAssertTrue(FileManager.default.fileExists(atPath: templates))

            // Nothing known yet about the project's repository: no brief
            // rule, no CLAUDE.md, no memory in the test's home folder, where
            // the settings turn auto-memory off.
            try FileManager.default.createDirectory(atPath: harness.home + "/.claude", withIntermediateDirectories: true)
            try #"{"autoMemoryEnabled": false}"#.write(toFile: harness.home + "/.claude/settings.json", atomically: true, encoding: .utf8)
            shell.showSpaceSettings(profileID: space.id, tab: .memory)
            XCTAssertEqual(settings.selectedTab, .memory)
            harness.waitUntil("the memory panel") { shell.projectMemoryPanel?.isVisible == true }
            let memory = try XCTUnwrap(shell.projectMemoryPanel)
            XCTAssertEqual(memory.model?.location.projectRoot, harness.repo)
            XCTAssertEqual(
                memory.model?.location.directory.path,
                harness.home + "/.claude/projects/" + ProjectMemory.encodedProjectName(harness.repo) + "/memory"
            )
            XCTAssertEqual(memory.rows.count, 1, "the brief's rule")
            XCTAssertEqual(memory.noticeRow?.isHidden, false)
            XCTAssertEqual(memory.noticeLabel?.stringValue.hasPrefix("Auto-memory is off (autoMemoryEnabled is false in ~/.claude/settings.json)"), true)

            // board.json and the checkouts are read off the main thread,
            // then the form fills the Board tab; closing writes nothing.
            shell.showSpaceSettings(profileID: space.id, tab: .board)
            XCTAssertEqual(settings.selectedTab, .board)
            XCTAssertFalse(memory.isVisible, "another tab")
            harness.waitUntil("the board settings form") { shell.boardSettingsPanel?.hostView != nil }
            let board = try XCTUnwrap(shell.boardSettingsPanel)
            XCTAssertIdentical(board.hostView, settings.boardHost)
            XCTAssertEqual(board.spaceID, space.id)
            XCTAssertNil(harness.window.attachedSheet)
            settings.close()
            XCTAssertNil(shell.spaceSettings)
            XCTAssertNil(shell.boardSettingsPanel)
            XCTAssertFalse(memory.isVisible)
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(BoardConfigStore(spaceID: space.id)).fileURL.path))

            // Deleting asks first: Cancel keeps the space, confirming moves
            // its workspace to the default space.
            harness.alertResponses = [.alertFirstButtonReturn]
            harness.perform(["Delete Space…"], in: shell.sidebar.spacePickerMenu())
            XCTAssertEqual(harness.alerts.last, "Delete the space \"Flow Space\"?")
            XCTAssertTrue(shell.profiles.contains { $0.id == space.id })
            harness.alertResponses = [.alertSecondButtonReturn]
            harness.perform(["Delete Space…"], in: shell.sidebar.spacePickerMenu())
            XCTAssertFalse(shell.profiles.contains { $0.id == space.id })
            XCTAssertEqual(spaceWorkspace.profileID, WorkspaceProfile.defaultID)
        }
    }

    /// Space Settings' "Add Repository…" anchors the repository of the folder picked (a
    /// linked worktree here: the repository is named after its main
    /// checkout), offers its workspaces, and a plain workspace then opens in
    /// its main checkout. A new space with no repository offers it in its
    /// empty view too. A folder in no repository is added as a folder once
    /// the user agrees, never the home folder. Space Settings › General
    /// lists them, adds a folder of its own, makes one the default, removes
    /// one, and edits a repository's setup script.
    func testSpaceRepositories() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let repoWorkspace = try XCTUnwrap(shell.activeWorkspace)
            shell.createSpace(NewSpacePanel.Draft(name: "Repos", colorHex: WorkspaceProfile.palette[2].hex, anchors: []))
            let space = try XCTUnwrap(shell.profiles.first { $0.name == "Repos" })
            XCTAssertEqual(shell.activeProfileID, space.id)
            // Empty: it says what to do instead of opening a workspace.
            XCTAssertNil(shell.activeWorkspace)
            let emptyView = shell.emptySpaceView
            XCTAssertFalse(emptyView.isHidden)
            XCTAssertFalse(emptyView.addRepositoryButton.isHidden)
            @MainActor func anchors() -> [SpaceAnchor] { shell.profiles.first { $0.id == space.id }?.anchors ?? [] }
            @MainActor func addRepository() throws {
                shell.showSpaceSettings(profileID: space.id)
                try XCTUnwrap(shell.spaceSettings?.general).addRepositoryButton.performClick(nil)
            }

            harness.chosenFolders = [harness.worktree]
            emptyView.addRepositoryButton.performClick(nil)
            harness.waitUntil("the repository anchored") { !anchors().isEmpty }
            XCTAssertTrue(emptyView.addRepositoryButton.isHidden, "the space has one now")
            let repository = SpaceAnchor(kind: .gitRepository(commonDir: harness.repo + "/.git"), name: "repo", isDefault: true)
            XCTAssertEqual(anchors(), [repository])
            harness.waitUntil("the repository's workspace offered") { repoWorkspace.profileID == space.id }
            XCTAssertEqual(harness.alerts.last, "Move workspaces to “Repos”?")
            // Moved in, it takes the empty view's place.
            XCTAssertIdentical(shell.activeWorkspace, repoWorkspace)
            XCTAssertTrue(emptyView.isHidden)
            shell.addWorkspace(title: "plain")
            XCTAssertEqual(shell.activeWorkspace?.cwd, harness.repo)
            XCTAssertEqual(shell.activeWorkspace?.profileID, space.id)

            // The home folder would take in every folder under it: refused,
            // without asking.
            let alertCount = harness.alerts.count
            harness.chosenFolders = [harness.home]
            try addRepository()
            harness.waitUntil("the refusal") { shell.toast?.message.contains("can’t be a space’s folder") == true }
            XCTAssertEqual(harness.alerts.count, alertCount)
            XCTAssertEqual(anchors().count, 1)

            let notes = harness.root + "/notes"
            try FileManager.default.createDirectory(atPath: notes, withIntermediateDirectories: true)
            harness.chosenFolders = [notes]
            try addRepository()
            harness.waitUntil("the folder anchored") { anchors().count == 2 }
            XCTAssertEqual(harness.alerts.last, "“notes” isn’t in a git repository")
            XCTAssertEqual(anchors().last, SpaceAnchor(kind: .folder(path: notes), name: "notes"))

            shell.showSpaceSettings(profileID: space.id)
            let general = try XCTUnwrap(shell.spaceSettings?.general)
            XCTAssertEqual(general.model.rows.map(\.anchor.name), ["repo", "notes"])
            XCTAssertEqual(general.tableView.numberOfRows, 2)
            @MainActor func cell<View: NSView>(_ column: Int, _ row: Int, as type: View.Type) throws -> View {
                let view = try XCTUnwrap(general.tableView.view(atColumn: column, row: row, makeIfNecessary: true))
                return try XCTUnwrap(UIFlowHarness.descendant(of: view, as: type))
            }

            // A repository's setup script: a sheet on Space Settings, saved
            // 0600 in the state folder, then the row says Edit….
            let addScript = try cell(1, 0, as: NSButton.self)
            XCTAssertEqual(addScript.title, "Add…")
            addScript.performClick(nil)
            let sheet = try XCTUnwrap(shell.setupScriptSheet)
            XCTAssertIdentical(shell.spaceSettings?.panel?.attachedSheet, sheet.panel)
            XCTAssertTrue(sheet.editor.textView.string.hasPrefix("# Setup for new worktrees of repo."))
            sheet.editor.textView.string += "npm ci\n"
            sheet.editor.saveButton.performClick(nil)
            XCTAssertNil(shell.setupScriptSheet)
            let script = try XCTUnwrap(SpaceSetupScript.scriptToRun(spaceID: space.id, anchor: anchors()[0]))
            XCTAssertTrue(script.path.hasPrefix(harness.stateDirectory + "/"), script.path)
            let mode = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600)
            XCTAssertEqual(general.model.rows.first?.hasScript, true)
            XCTAssertEqual(try cell(1, 0, as: NSButton.self).title, "Edit…")

            // The default, then Remove.
            try cell(3, 1, as: NSButton.self).performClick(nil)
            XCTAssertEqual(anchors().map(\.isDefault), [false, true])
            general.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            XCTAssertTrue(general.removeButton.isEnabled)
            general.removeButton.performClick(nil)
            XCTAssertEqual(anchors(), [SpaceAnchor(kind: .folder(path: notes), name: "notes", isDefault: true)])
            XCTAssertEqual(general.model.rows.map(\.anchor.name), ["notes"])

            // Add Folder… anchors the folder itself, even inside a repository.
            let docs = harness.repo + "/docs"
            try FileManager.default.createDirectory(atPath: docs, withIntermediateDirectories: true)
            harness.chosenFolders = [docs]
            general.addFolderButton.performClick(nil)
            harness.waitUntil("the folder anchored") { anchors().count == 2 }
            XCTAssertEqual(anchors().last, SpaceAnchor(kind: .folder(path: docs), name: "docs"))
            XCTAssertEqual(general.model.rows.map(\.anchor.name), ["notes", "docs"])
            // The default space has no repositories: left empty, it offers
            // New… alone.
            shell.selectProfile(WorkspaceProfile.defaultID)
            XCTAssertNil(shell.activeWorkspace)
            XCTAssertFalse(emptyView.isHidden)
            XCTAssertTrue(emptyView.addRepositoryButton.isHidden)
        }
    }

    /// ⌥⌘N, pressed without ever opening the Space menu (from an empty
    /// space, from a terminal), goes to the space at that place in the
    /// picker, a space created meanwhile included; past the last space it
    /// does nothing.
    func testSpaceChordsSelectSpacesByPlace() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            try harness.withApp {
                shell.createSpace(NewSpacePanel.Draft(name: "Second", colorHex: WorkspaceProfile.palette[1].hex, anchors: []))
                harness.waitUntil("the new space on screen") {
                    shell.profiles.first { $0.id == shell.activeProfileID }?.name == "Second"
                }
                let second = shell.activeProfileID
                shell.updateSidebar()

                harness.press("1", keyCode: 0x12, [.command, .option])
                XCTAssertEqual(shell.activeProfileID, WorkspaceProfile.defaultID)
                harness.press("2", keyCode: 0x13, [.command, .option])
                XCTAssertEqual(shell.activeProfileID, second)
                harness.press("3", keyCode: 0x14, [.command, .option])
                XCTAssertEqual(shell.activeProfileID, second)
            }
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
            shell.showFind()
            XCTAssertTrue(column.isFindBarOpen)
            let bar = try XCTUnwrap(column.findBar)
            harness.type("flow", into: bar.field)
            XCTAssertEqual(column.terminalSearch?.needle, "flow")
            shell.findNextMatch()
            shell.findPreviousMatch()
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
            XCTAssertEqual(editor.workspaceCwd, harness.repo)

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
