import AppKit
import XCTest
@testable import Nirux

/// The Lead's space management and cross-space task moving tools
/// (NiruxShellView+LeadSpaces), in a real window on throwaway state.
@MainActor
final class LeadSpaceToolsTests: XCTestCase {
    private func makeGitRepo(named name: String, in root: String) throws -> String {
        let path = root + "/" + name
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try UIFlowHarness.git(["init", "-q"], at: path)
        return path
    }

    private func makePlainFolder(named name: String, in root: String) throws -> String {
        let path = root + "/" + name
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func startDryRunQueue(in shell: NiruxShellView, spaceID: String, root: String) -> MergeQueueController {
        var world = MQ.World()
        world.pullRequests[52] = MQ.pullRequest(52, head: MQ.sha("a"))
        world.checks[MQ.sha("a")] = MQ.checks(MQ.checkRun(id: 1, status: "IN_PROGRESS", conclusion: nil))
        shell.mergeQueueClient = FakeQueueClient(world: world, isDryRun: true)
        shell.mergeQueueLockFolder = URL(fileURLWithPath: root + "/locks")
        let queue = shell.mergeQueue(projectID: spaceID, repository: MQ.widgets)
        queue.beginActivity = { NSObject() }
        queue.endActivity = { _ in }
        XCTAssertNil(queue.start(settings: MQ.settings(), entries: [MQ.entry(52, head: MQ.sha("a"))]))
        return queue
    }

    func testListSpacesReportsSidebarOrderCountsAnchorsLeadAndQueue() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            let folder = try makePlainFolder(named: "docs", in: harness.root)
            let docsSpace = shell.workspaceStore.createProfile(
                named: "Docs", colorHex: "#E0AF68", anchors: [.folder(folder)], select: false
            )
            shell.addWorkspace(title: "Open task", cwd: harness.worktree, profileID: lead.space)
            shell.addWorkspace(title: "Archived task", cwd: harness.worktree, profileID: lead.space)
            let archivedIndex = try XCTUnwrap(shell.workspaces.firstIndex { $0.title == "Archived task" })
            shell.workspaceStore.setWorkspaceInactive(at: archivedIndex, true)

            let queue = startDryRunQueue(in: shell, spaceID: docsSpace.id, root: harness.root)
            defer {
                queue.stop()
                MergeQueueController.waitForFiles()
            }

            let reply = try harness.callLeadTool(LeadTools.listSpaces, [:], lead: lead)
            XCTAssertFalse(reply.isError, reply.text)
            let lines = reply.text.components(separatedBy: "\n")
            XCTAssertEqual(lines.first, "3 spaces:")

            let generalLine = try XCTUnwrap(lines.first { $0.contains("space:default") })
            XCTAssertTrue(generalLine.contains("“General”"), generalLine)
            XCTAssertTrue(generalLine.contains("default"), generalLine)
            XCTAssertTrue(generalLine.contains("no Lead"), generalLine)

            let toolsLine = try XCTUnwrap(lines.first { $0.contains("space:\(lead.space)") })
            XCTAssertTrue(toolsLine.contains("“Tools”"), toolsLine)
            XCTAssertTrue(toolsLine.contains("current space"), toolsLine)
            XCTAssertTrue(toolsLine.contains("1 open, 1 archived"), toolsLine)
            XCTAssertTrue(toolsLine.contains("Lead active"), toolsLine)
            XCTAssertTrue(toolsLine.contains("no merge queue"), toolsLine)

            let docsLine = try XCTUnwrap(lines.first { $0.contains("space:\(docsSpace.id)") })
            XCTAssertTrue(docsLine.contains("#E0AF68"), docsLine)
            XCTAssertTrue(docsLine.contains("0 open, 0 archived"), docsLine)
            XCTAssertTrue(docsLine.contains("no Lead"), docsLine)
            XCTAssertTrue(docsLine.contains("merge queue running"), docsLine)
            XCTAssertTrue(reply.text.contains("repo (repository, default:"), reply.text)
            XCTAssertTrue(reply.text.contains("docs (folder, default:"), reply.text)

            let generalIndex = try XCTUnwrap(lines.firstIndex { $0.contains("space:default") })
            let toolsIndex = try XCTUnwrap(lines.firstIndex { $0.contains("space:\(lead.space)") })
            let docsIndex = try XCTUnwrap(lines.firstIndex { $0.contains("space:\(docsSpace.id)") })
            XCTAssertLessThan(generalIndex, toolsIndex)
            XCTAssertLessThan(toolsIndex, docsIndex)
        }
    }

    func testCreateSpaceValidatesInputsAndPreservesUserFocus() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            shell.addWorkspace(title: "Active Work", cwd: harness.worktree, profileID: lead.space)
            let active = try XCTUnwrap(shell.workspaces.first { $0.title == "Active Work" })
            shell.workspaceStore.selectWorkspace(id: active.id)
            let expectedNextColor = shell.workspaceStore.unusedColorHex()

            // Valid creation with trimmed name and auto-assigned color; must NOT steal focus.
            let created = try harness.callLeadTool(LeadTools.createSpace, ["name": "  Platform  "], lead: lead)
            XCTAssertFalse(created.isError, created.text)
            XCTAssertTrue(created.text.contains("“Platform”"), created.text)
            let platform = try XCTUnwrap(shell.profiles.first { $0.name == "Platform" })
            XCTAssertEqual(platform.colorHex, expectedNextColor)
            XCTAssertTrue(created.text.contains("space:\(platform.id)"), created.text)
            XCTAssertEqual(shell.activeProfileID, lead.space, "must not yank active space")
            XCTAssertEqual(shell.activeWorkspace?.id, active.id, "must not yank active workspace")

            // Case-insensitive duplicate rejected.
            let duplicate = try harness.callLeadTool(LeadTools.createSpace, ["name": "platform"], lead: lead)
            XCTAssertTrue(duplicate.isError, duplicate.text)
            XCTAssertTrue(duplicate.text.contains("already exists"), duplicate.text)

            // Invalid color rejected.
            let badColor = try harness.callLeadTool(LeadTools.createSpace, ["name": "BadColor", "color": "not-hex"], lead: lead)
            XCTAssertTrue(badColor.isError, badColor.text)
            XCTAssertNil(shell.profiles.first { $0.name == "BadColor" })

            // Non-existent anchor path rejected.
            let missingAnchor = try harness.callLeadTool(LeadTools.createSpace, [
                "name": "Missing", "anchors": [harness.root + "/does-not-exist"]
            ], lead: lead)
            XCTAssertTrue(missingAnchor.isError, missingAnchor.text)
            XCTAssertNil(shell.profiles.first { $0.name == "Missing" })

            // Home directory is too broad for a folder anchor.
            let broadAnchor = try harness.callLeadTool(LeadTools.createSpace, [
                "name": "TooBroad", "anchors": [harness.home]
            ], lead: lead)
            XCTAssertTrue(broadAnchor.isError, broadAnchor.text)
            XCTAssertNil(shell.profiles.first { $0.name == "TooBroad" })

            // The repository of a space with a Lead stays there, move_anchors or not.
            let ownedConflict = try harness.callLeadTool(LeadTools.createSpace, [
                "name": "Steal", "anchors": [harness.repo], "move_anchors": true
            ], lead: lead)
            XCTAssertTrue(ownedConflict.isError, ownedConflict.text)
            XCTAssertTrue(ownedConflict.text.contains("only the user can move it"), ownedConflict.text)
            XCTAssertNil(shell.profiles.first { $0.name == "Steal" })

            // Valid git repository + plain folder anchors + explicit color.
            let secondRepo = try makeGitRepo(named: "backend", in: harness.root)
            let notesDir = try makePlainFolder(named: "notes", in: harness.root)
            let anchored = try harness.callLeadTool(LeadTools.createSpace, [
                "name": "Backend", "color": "#ff9e64", "anchors": [secondRepo, notesDir]
            ], lead: lead)
            XCTAssertFalse(anchored.isError, anchored.text)
            XCTAssertTrue(anchored.text.contains("with repository “backend”, folder “notes”"), anchored.text)
            let backend = try XCTUnwrap(shell.profiles.first { $0.name == "Backend" })
            XCTAssertEqual(backend.colorHex, "#FF9E64")
            XCTAssertEqual(backend.anchors.map(\.name), ["backend", "notes"])
            XCTAssertEqual(shell.activeProfileID, lead.space)
            XCTAssertEqual(shell.activeWorkspace?.id, active.id)

            // Another space's anchor moves only with move_anchors: true.
            let unasked = try harness.callLeadTool(LeadTools.createSpace, ["name": "Backend V2", "anchors": [secondRepo]], lead: lead)
            XCTAssertTrue(unasked.isError, unasked.text)
            XCTAssertTrue(unasked.text.contains("move_anchors"), unasked.text)
            let movedAnchor = try harness.callLeadTool(LeadTools.createSpace, [
                "name": "Backend V2", "anchors": [secondRepo], "move_anchors": true
            ], lead: lead)
            XCTAssertFalse(movedAnchor.isError, movedAnchor.text)
            let backendV2 = try XCTUnwrap(shell.profiles.first { $0.name == "Backend V2" })
            XCTAssertEqual(backendV2.anchors.map(\.name), ["backend"])
            XCTAssertEqual(shell.profiles.first { $0.id == backend.id }?.anchors.map(\.name), ["notes"])

            // A folder of a repository holding the home folder names that repository: too broad.
            try UIFlowHarness.git(["init", "-q"], at: harness.home)
            let inHome = try makePlainFolder(named: "notes", in: harness.home)
            let homeRepository = try harness.callLeadTool(LeadTools.createSpace, ["name": "Home", "anchors": [inHome]], lead: lead)
            XCTAssertTrue(homeRepository.isError, homeRepository.text)
            XCTAssertNil(shell.profiles.first { $0.name == "Home" })

            // Past the call's wait, nothing is created.
            shell.sideEffects.leadAnchorWait = 0
            let late = try harness.callLeadTool(LeadTools.createSpace, [
                "name": "Late", "anchors": [try makePlainFolder(named: "late", in: harness.root)]
            ], lead: lead)
            XCTAssertTrue(late.isError, late.text)
            XCTAssertNil(shell.profiles.first { $0.name == "Late" })
        }
    }

    func testEditSpaceRenamesRecolorsAndEditsAnchors() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            let extraRepo = try makeGitRepo(named: "api", in: harness.root)
            let docsDir = try makePlainFolder(named: "guides", in: harness.root)

            let created = try harness.callLeadTool(LeadTools.createSpace, ["name": "Alpha"], lead: lead)
            XCTAssertFalse(created.isError, created.text)
            let alpha = try XCTUnwrap(shell.profiles.first { $0.name == "Alpha" })
            shell.showSpaceSettings(profileID: alpha.id, tab: .general)

            // Rename + recolor + add anchors.
            let edited = try harness.callLeadTool(LeadTools.editSpace, [
                "space": "space:\(alpha.id)",
                "name": "Beta",
                "color": "#bb9af7",
                "add_anchors": [extraRepo, docsDir]
            ], lead: lead)
            XCTAssertFalse(edited.isError, edited.text)
            let updated = try XCTUnwrap(shell.profiles.first { $0.id == alpha.id })
            XCTAssertEqual(updated.name, "Beta")
            XCTAssertEqual(updated.colorHex, "#BB9AF7")
            XCTAssertEqual(updated.anchors.map(\.name), ["api", "guides"])
            XCTAssertEqual(shell.spaceSettings?.general.model.name, "Beta", "open Space Settings refreshes")

            // Remove anchor by name, then by path.
            let removedByName = try harness.callLeadTool(LeadTools.editSpace, [
                "space": "Beta", "remove_anchors": ["guides"]
            ], lead: lead)
            XCTAssertFalse(removedByName.isError, removedByName.text)
            XCTAssertEqual(shell.profiles.first { $0.id == alpha.id }?.anchors.map(\.name), ["api"])

            let removedByPath = try harness.callLeadTool(LeadTools.editSpace, [
                "space": "Beta", "remove_anchors": [extraRepo]
            ], lead: lead)
            XCTAssertFalse(removedByPath.isError, removedByPath.text)
            XCTAssertEqual(shell.profiles.first { $0.id == alpha.id }?.anchors, [])

            // Duplicate rename rejected.
            let dup = try harness.callLeadTool(LeadTools.editSpace, ["space": "Beta", "name": "tools"], lead: lead)
            XCTAssertTrue(dup.isError, dup.text)
            XCTAssertTrue(dup.text.contains("already exists"), dup.text)

            // Removing nonexistent anchor rejected.
            let missingRemove = try harness.callLeadTool(LeadTools.editSpace, [
                "space": "Beta", "remove_anchors": ["ghost"]
            ], lead: lead)
            XCTAssertTrue(missingRemove.isError, missingRemove.text)

            // Default space rules: cannot add anchors or rename to legacy "main", CAN rename to another valid name.
            let generalAnchor = try harness.callLeadTool(LeadTools.editSpace, [
                "space": "space:default", "add_anchors": [docsDir]
            ], lead: lead)
            XCTAssertTrue(generalAnchor.isError, generalAnchor.text)

            let legacyName = try harness.callLeadTool(LeadTools.editSpace, [
                "space": "General", "name": WorkspaceProfile.legacyDefaultName
            ], lead: lead)
            XCTAssertTrue(legacyName.isError, legacyName.text)

            // The Lead's own repository stays.
            let removeOwn = try harness.callLeadTool(LeadTools.editSpace, ["space": "Tools", "remove_anchors": ["repo"]], lead: lead)
            XCTAssertTrue(removeOwn.isError, removeOwn.text)
            XCTAssertTrue(removeOwn.text.contains("only the user"), removeOwn.text)
            XCTAssertEqual(shell.profiles.first { $0.id == lead.space }?.anchors.map(\.name), ["repo"])

            let renamedGeneral = try harness.callLeadTool(LeadTools.editSpace, [
                "space": "General", "name": "Personal"
            ], lead: lead)
            XCTAssertFalse(renamedGeneral.isError, renamedGeneral.text)
            XCTAssertEqual(shell.profiles.first { $0.id == WorkspaceProfile.defaultID }?.name, "Personal")
        }
    }

    func testDeleteSpaceGuardsAndTaskMigration() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()

            // Refuse deleting default space.
            let deleteDefault = try harness.callLeadTool(LeadTools.deleteSpace, ["space": "General"], lead: lead)
            XCTAssertTrue(deleteDefault.isError, deleteDefault.text)
            XCTAssertNotNil(shell.profiles.first { $0.id == WorkspaceProfile.defaultID })

            // Refuse deleting caller Lead's own space.
            let deleteSelf = try harness.callLeadTool(LeadTools.deleteSpace, ["space": "Tools"], lead: lead)
            XCTAssertTrue(deleteSelf.isError, deleteSelf.text)
            XCTAssertNotNil(shell.profiles.first { $0.id == lead.space })

            // Deleted once the user confirms it, its Space Settings closed.
            let empty = shell.workspaceStore.createProfile(named: "Temp", select: false)
            shell.showSpaceSettings(profileID: empty.id, tab: .general)
            let settingsOpen = try harness.callLeadTool(LeadTools.deleteSpace, ["space": "Temp"], lead: lead)
            XCTAssertTrue(settingsOpen.isError, settingsOpen.text)
            XCTAssertTrue(settingsOpen.text.contains("Space Settings"), settingsOpen.text)
            shell.spaceSettings?.close()
            waitUntil("Space Settings closed") { shell.spaceSettings == nil }
            // The space on screen stays, an empty one too.
            XCTAssertTrue(shell.workspaceStore.selectProfile(empty.id))
            let onScreen = try harness.callLeadTool(LeadTools.deleteSpace, ["space": "Temp"], lead: lead)
            XCTAssertTrue(onScreen.isError, onScreen.text)
            XCTAssertTrue(onScreen.text.contains("on screen"), onScreen.text)
            shell.workspaceStore.selectWorkspace(id: lead.workspace.id)
            let kept = try harness.callLeadTool(LeadTools.deleteSpace, ["space": "Temp"], lead: lead)
            XCTAssertTrue(kept.isError, kept.text)
            XCTAssertNotNil(shell.profiles.first { $0.id == empty.id }, "the user kept it")
            harness.alertResponses = [.alertSecondButtonReturn]
            let deletedEmpty = try harness.callLeadTool(LeadTools.deleteSpace, ["space": "Temp"], lead: lead)
            XCTAssertFalse(deletedEmpty.isError, deletedEmpty.text)
            XCTAssertNil(shell.profiles.first { $0.id == empty.id })
            XCTAssertTrue(shell.projectStore.deletedIDs.contains(empty.id))

            // Refuse deleting space with running merge queue.
            let queuedSpace = shell.workspaceStore.createProfile(named: "Queued", select: false)
            let queue = startDryRunQueue(in: shell, spaceID: queuedSpace.id, root: harness.root)
            let deleteQueued = try harness.callLeadTool(LeadTools.deleteSpace, ["space": "Queued"], lead: lead)
            XCTAssertTrue(deleteQueued.isError, deleteQueued.text)
            XCTAssertTrue(deleteQueued.text.contains("running merge queue"), deleteQueued.text)
            queue.stop()
            MergeQueueController.waitForFiles()

            // Refuse deleting space that has its own active Lead workspace.
            let ledSpace = shell.workspaceStore.createProfile(named: "OtherLed", select: false)
            shell.startLead(spaceID: ledSpace.id)
            shell.workspaceStore.selectWorkspace(id: lead.workspace.id)
            let deleteLed = try harness.callLeadTool(LeadTools.deleteSpace, ["space": "OtherLed"], lead: lead)
            XCTAssertTrue(deleteLed.isError, deleteLed.text)
            XCTAssertTrue(deleteLed.text.contains("has a Lead"), deleteLed.text)

            // Non-empty space refused without move_tasks_to and refused when move_tasks_to == space.
            let retiring = shell.workspaceStore.createProfile(named: "Retiring", select: false)
            let destination = shell.workspaceStore.createProfile(named: "ArchiveSpace", select: false)
            shell.addWorkspace(title: "Parent Task", cwd: harness.worktree, profileID: retiring.id)
            let parentTask = try XCTUnwrap(shell.workspaces.first { $0.title == "Parent Task" })
            shell.addWorkspace(title: "Child Task", cwd: harness.worktree, profileID: retiring.id, parentWorkspaceID: parentTask.id)
            shell.workspaceStore.selectWorkspace(id: lead.workspace.id)

            let noTarget = try harness.callLeadTool(LeadTools.deleteSpace, ["space": "Retiring"], lead: lead)
            XCTAssertTrue(noTarget.isError, noTarget.text)
            XCTAssertTrue(noTarget.text.contains("move_tasks_to"), noTarget.text)

            let selfTarget = try harness.callLeadTool(LeadTools.deleteSpace, [
                "space": "Retiring", "move_tasks_to": "Retiring"
            ], lead: lead)
            XCTAssertTrue(selfTarget.isError, selfTarget.text)

            // With move_tasks_to, migrates tasks (preserving hierarchy) and deletes space cleanly.
            harness.alertResponses = [.alertSecondButtonReturn]
            let migrated = try harness.callLeadTool(LeadTools.deleteSpace, [
                "space": "Retiring", "move_tasks_to": "space:\(destination.id)"
            ], lead: lead)
            XCTAssertFalse(migrated.isError, migrated.text)
            XCTAssertNil(shell.profiles.first { $0.id == retiring.id })
            let migratedTitles = shell.workspaceStore.visibleWorkspaceIndices(in: destination.id).map { shell.workspaces[$0].title }
            XCTAssertEqual(migratedTitles, ["Parent Task", "Child Task"])
            let child = try XCTUnwrap(shell.workspaces.first { $0.title == "Child Task" })
            XCTAssertEqual(child.parentWorkspaceID, parentTask.id)
            XCTAssertEqual(shell.activeWorkspace?.id, lead.workspace.id, "must not hijack focus")
            let asked = { (name: String) in "The Lead asks to delete the space \"\(name)\"" }
            XCTAssertEqual(harness.alerts, [asked("Temp"), asked("Temp"), asked("Retiring")], "asked once nothing refuses")
        }
    }

    func testMoveTaskToSpaceAndCrossSpaceListTasks() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            let spaceA = shell.workspaceStore.createProfile(named: "SpaceA", select: false)
            let spaceB = shell.workspaceStore.createProfile(named: "SpaceB", select: false)

            shell.addWorkspace(title: "FromLeadSpace", cwd: harness.worktree, profileID: lead.space)
            let fromLead = try XCTUnwrap(shell.workspaces.first { $0.title == "FromLeadSpace" })
            shell.addWorkspace(title: "FromLeadChild", cwd: harness.worktree, profileID: lead.space, parentWorkspaceID: fromLead.id)
            for (title, space) in [("InSpaceA", spaceA.id), ("BoardHolder", spaceB.id), ("ClosingTask", lead.space),
                                   ("OnScreen", lead.space), ("Reporting", lead.space), ("Held", lead.space)] {
                shell.addWorkspace(title: title, cwd: harness.worktree, profileID: space)
            }
            let named = { (title: String) in try XCTUnwrap(shell.workspaces.first { $0.title == title }) }
            let child = try named("FromLeadChild")
            let inA = try named("InSpaceA")
            let closing = try named("ClosingTask")
            closing.isClosing = true
            let onScreen = try named("OnScreen")
            XCTAssertTrue(shell.workspaceStore.selectWorkspace(id: onScreen.id))

            // Cross-space list_tasks by name and by space:<id>.
            let listA = try harness.callLeadTool(LeadTools.listTasks, ["space": "SpaceA"], lead: lead)
            XCTAssertFalse(listA.isError, listA.text)
            XCTAssertTrue(listA.text.contains("\nSpaceA: 1 task."), listA.text)
            XCTAssertTrue(listA.text.contains("“InSpaceA”"), listA.text)
            XCTAssertTrue(listA.text.contains(inA.leadTaskReference), listA.text)

            let listB = try harness.callLeadTool(LeadTools.listTasks, ["space": "space:\(spaceB.id)"], lead: lead)
            XCTAssertFalse(listB.isError, listB.text)
            XCTAssertTrue(listB.text.contains("\nSpaceB: 1 task."), listB.text)

            let listUnknown = try harness.callLeadTool(LeadTools.listTasks, ["space": "Nowhere"], lead: lead)
            XCTAssertTrue(listUnknown.isError, listUnknown.text)

            // The task on screen stays.
            let moveOnScreen = try harness.callLeadTool(LeadTools.moveTaskToSpace, ["task": "OnScreen", "to_space": "SpaceA"], lead: lead)
            XCTAssertTrue(moveOnScreen.isError, moveOnScreen.text)
            XCTAssertTrue(moveOnScreen.text.contains("on screen"), moveOnScreen.text)
            XCTAssertEqual(onScreen.profileID, lead.space)

            // A task moves with its sub-task, listed under it.
            let moved1 = try harness.callLeadTool(LeadTools.moveTaskToSpace, [
                "task": fromLead.leadTaskReference, "to_space": "SpaceA"
            ], lead: lead)
            XCTAssertFalse(moved1.isError, moved1.text)
            XCTAssertTrue(moved1.text.contains("and its sub-task"), moved1.text)
            XCTAssertEqual(child.profileID, spaceA.id)
            let titlesA = shell.workspaceStore.visibleWorkspaceIndices(in: spaceA.id).map { shell.workspaces[$0].title }
            XCTAssertEqual(titlesA, ["InSpaceA", "FromLeadSpace", "FromLeadChild"])

            // Its Board closes quietly in a space that has one (the Lead's): the screen stays as it was.
            let boardHolder = try named("BoardHolder")
            boardHolder.addProjectBoardColumn(shell.makeProjectBoard(projectID: spaceB.id, offersSettings: false))
            let movedBoard = try harness.callLeadTool(LeadTools.moveTaskToSpace, [
                "task": "BoardHolder", "from_space": "SpaceB", "to_space": "Tools"
            ], lead: lead)
            XCTAssertFalse(movedBoard.isError, movedBoard.text)
            XCTAssertFalse(boardHolder.columns.contains(where: \.isProjectBoard))
            XCTAssertTrue(shell.activeWorkspace === onScreen)
            XCTAssertNil(shell.toast)

            // Move between SpaceA and SpaceB via from_space.
            let moved2 = try harness.callLeadTool(LeadTools.moveTaskToSpace, [
                "task": "InSpaceA", "from_space": "SpaceA", "to_space": "space:\(spaceB.id)"
            ], lead: lead)
            XCTAssertFalse(moved2.isError, moved2.text)
            XCTAssertEqual(inA.profileID, spaceB.id)

            // No-op when already in destination space.
            let noop = try harness.callLeadTool(LeadTools.moveTaskToSpace, [
                "task": "InSpaceA", "from_space": "SpaceB", "to_space": "SpaceB"
            ], lead: lead)
            XCTAssertFalse(noop.isError, noop.text)
            XCTAssertTrue(noop.text.contains("already in"), noop.text)

            // A space with a Lead of its own keeps its tasks; list_tasks reads it as that Lead does.
            shell.startLead(spaceID: spaceB.id)
            XCTAssertTrue(shell.workspaceStore.selectWorkspace(id: onScreen.id))
            let otherLead = try XCTUnwrap(shell.leadWorkspace(inSpace: spaceB.id))
            XCTAssertNotNil(MissionStore.shared.create(MissionCreationRequest(
                id: UUID().uuidString, parentWorkspaceID: otherLead.id, parentAgentUUID: try XCTUnwrap(otherLead.columns.first?.agentUUID),
                childWorkspaceID: inA.id, childAgentUUID: UUID().uuidString, childAgentKind: "claude",
                branch: "feat/in-a", reportsToLead: true
            ), enabled: true))
            let fromLed = try harness.callLeadTool(LeadTools.moveTaskToSpace, [
                "task": "InSpaceA", "from_space": "SpaceB", "to_space": "SpaceA"
            ], lead: lead)
            XCTAssertTrue(fromLed.isError, fromLed.text)
            XCTAssertTrue(fromLed.text.contains("Lead of its own"), fromLed.text)
            XCTAssertEqual(inA.profileID, spaceB.id)
            let listLed = try harness.callLeadTool(LeadTools.listTasks, ["space": "SpaceB"], lead: lead)
            XCTAssertTrue(listLed.text.hasPrefix("As the Lead of “SpaceB” sees it"), listLed.text)
            let inALine = try XCTUnwrap(listLed.text.components(separatedBy: "\n").first { $0.contains("“InSpaceA”") })
            XCTAssertFalse(inALine.contains("not yours"), inALine)

            // A task reporting to the Lead would stop reaching it; a held message reads the space it lands in.
            let reporting = try named("Reporting")
            XCTAssertNotNil(MissionStore.shared.create(MissionCreationRequest(
                id: UUID().uuidString, parentWorkspaceID: lead.workspace.id, parentAgentUUID: lead.agentUUID,
                childWorkspaceID: reporting.id, childAgentUUID: UUID().uuidString, childAgentKind: "claude",
                branch: "feat/reporting", reportsToLead: true
            ), enabled: true))
            let held = try named("Held")
            held.mergeWaits = [MergeWait(
                id: "held", awaited: .init(workspaceID: fromLead.id, title: fromLead.title),
                action: .tell(message: "Merge origin/main"), createdAt: 0
            )]
            for (task, refusal) in [(reporting, "reports to"), (held, "waits for")] {
                let move = try harness.callLeadTool(LeadTools.moveTaskToSpace, ["task": task.title, "to_space": "SpaceA"], lead: lead)
                XCTAssertTrue(move.isError, move.text)
                XCTAssertTrue(move.text.contains(refusal), move.text)
                XCTAssertEqual(task.profileID, lead.space)
            }

            // Refuse moving Lead workspace.
            let moveLead = try harness.callLeadTool(LeadTools.moveTaskToSpace, [
                "task": lead.workspace.leadTaskReference, "to_space": "SpaceA"
            ], lead: lead)
            XCTAssertTrue(moveLead.isError, moveLead.text)
            XCTAssertTrue(moveLead.text.contains("Lead"), moveLead.text)
            XCTAssertEqual(lead.workspace.profileID, lead.space)

            // Refuse moving closing workspace.
            let moveClosing = try harness.callLeadTool(LeadTools.moveTaskToSpace, [
                "task": closing.leadTaskReference, "to_space": "SpaceA"
            ], lead: lead)
            XCTAssertTrue(moveClosing.isError, moveClosing.text)
            XCTAssertTrue(moveClosing.text.contains("closing"), moveClosing.text)
            XCTAssertEqual(closing.profileID, lead.space)

            // A task's agent can't look into another space unless its own lets it.
            let taskAgentUUID = try XCTUnwrap(inA.columns.first?.agentUUID)
            let subtaskList = try harness.callLeadTool(
                LeadTools.listTasks, ["space": "SpaceA"], from: inA, agentUUID: taskAgentUUID
            )
            XCTAssertTrue(subtaskList.isError, subtaskList.text)
            XCTAssertTrue(subtaskList.text.contains("doesn't let its tasks manage spaces"), subtaskList.text)
        }
    }
}
