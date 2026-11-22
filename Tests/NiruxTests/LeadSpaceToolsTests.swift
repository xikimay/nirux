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

            // Anchor already owned by another space is rejected unless move_anchors: true.
            let ownedConflict = try harness.callLeadTool(LeadTools.createSpace, [
                "name": "Steal", "anchors": [harness.repo]
            ], lead: lead)
            XCTAssertTrue(ownedConflict.isError, ownedConflict.text)
            XCTAssertTrue(ownedConflict.text.contains("already belongs to"), ownedConflict.text)
            XCTAssertNil(shell.profiles.first { $0.name == "Steal" })

            // Valid git repository + plain folder anchors + explicit color.
            let secondRepo = try makeGitRepo(named: "backend", in: harness.root)
            let notesDir = try makePlainFolder(named: "notes", in: harness.root)
            let anchored = try harness.callLeadTool(LeadTools.createSpace, [
                "name": "Backend", "color": "#ff9e64", "anchors": [secondRepo, notesDir]
            ], lead: lead)
            XCTAssertFalse(anchored.isError, anchored.text)
            let backend = try XCTUnwrap(shell.profiles.first { $0.name == "Backend" })
            XCTAssertEqual(backend.colorHex, "#FF9E64")
            XCTAssertEqual(backend.anchors.map(\.name), ["backend", "notes"])
            XCTAssertEqual(shell.activeProfileID, lead.space)
            XCTAssertEqual(shell.activeWorkspace?.id, active.id)

            // Explicit move_anchors: true moves anchor cleanly.
            let movedAnchor = try harness.callLeadTool(LeadTools.createSpace, [
                "name": "Backend V2", "anchors": [secondRepo], "move_anchors": true
            ], lead: lead)
            XCTAssertFalse(movedAnchor.isError, movedAnchor.text)
            let backendV2 = try XCTUnwrap(shell.profiles.first { $0.name == "Backend V2" })
            XCTAssertEqual(backendV2.anchors.map(\.name), ["backend"])
            XCTAssertEqual(shell.profiles.first { $0.id == backend.id }?.anchors.map(\.name), ["notes"])
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

            // Delete empty space cleanly without modal alerts.
            let empty = shell.workspaceStore.createProfile(named: "Temp", select: false)
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
            let deleteLed = try harness.callLeadTool(LeadTools.deleteSpace, ["space": "OtherLed"], lead: lead)
            XCTAssertTrue(deleteLed.isError, deleteLed.text)
            XCTAssertTrue(deleteLed.text.contains("active Lead"), deleteLed.text)

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
        }
    }

    func testMoveTaskToSpaceAndCrossSpaceListTasks() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            let spaceA = shell.workspaceStore.createProfile(named: "SpaceA", select: false)
            let spaceB = shell.workspaceStore.createProfile(named: "SpaceB", select: false)

            shell.addWorkspace(title: "FromLeadSpace", cwd: harness.worktree, profileID: lead.space)
            shell.addWorkspace(title: "InSpaceA", cwd: harness.worktree, profileID: spaceA.id)
            shell.addWorkspace(title: "ClosingTask", cwd: harness.worktree, profileID: lead.space)
            let fromLead = try XCTUnwrap(shell.workspaces.first { $0.title == "FromLeadSpace" })
            let inA = try XCTUnwrap(shell.workspaces.first { $0.title == "InSpaceA" })
            let closing = try XCTUnwrap(shell.workspaces.first { $0.title == "ClosingTask" })
            closing.isClosing = true

            // Keep focus on the Lead workspace while moving other tasks.
            shell.workspaceStore.selectWorkspace(id: lead.workspace.id)

            // Cross-space list_tasks by name and by space:<id>.
            let listA = try harness.callLeadTool(LeadTools.listTasks, ["space": "SpaceA"], lead: lead)
            XCTAssertFalse(listA.isError, listA.text)
            XCTAssertTrue(listA.text.hasPrefix("SpaceA: 1 task."), listA.text)
            XCTAssertTrue(listA.text.contains("“InSpaceA”"), listA.text)
            XCTAssertTrue(listA.text.contains(inA.leadTaskReference), listA.text)

            let listB = try harness.callLeadTool(LeadTools.listTasks, ["space": "space:\(spaceB.id)"], lead: lead)
            XCTAssertFalse(listB.isError, listB.text)
            XCTAssertTrue(listB.text.hasPrefix("SpaceB: no task."), listB.text)

            let listUnknown = try harness.callLeadTool(LeadTools.listTasks, ["space": "Nowhere"], lead: lead)
            XCTAssertTrue(listUnknown.isError, listUnknown.text)

            // Move from caller Lead's space to SpaceA without yanking focus.
            let moved1 = try harness.callLeadTool(LeadTools.moveTaskToSpace, [
                "task": fromLead.leadTaskReference, "to_space": "SpaceA"
            ], lead: lead)
            XCTAssertFalse(moved1.isError, moved1.text)
            XCTAssertEqual(fromLead.profileID, spaceA.id)
            XCTAssertEqual(shell.activeWorkspace?.id, lead.workspace.id)
            XCTAssertEqual(shell.activeProfileID, lead.space)

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

            // Regular task agent cannot call list_tasks(space:) or move_task_to_space.
            let taskAgentUUID = try XCTUnwrap(inA.columns.first?.agentUUID)
            let subtaskList = try harness.callLeadTool(
                LeadTools.listTasks, ["space": "SpaceA"], from: inA, agentUUID: taskAgentUUID
            )
            XCTAssertTrue(subtaskList.isError, subtaskList.text)
        }
    }
}
