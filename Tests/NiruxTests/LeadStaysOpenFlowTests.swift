import AppKit
import XCTest
@testable import Nirux

/// Only turning the Lead off in Space Settings › Lead closes it (S11):
/// ⌘W, Close Column, Close Workspace and a clean-up leave it, and its
/// Claude column, open.
@MainActor
final class LeadStaysOpenFlowTests: XCTestCase {
    func testOnlyTurningTheLeadOffClosesIt() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            let workspace = lead.workspace
            let claude = try XCTUnwrap(workspace.leadTerminal)
            XCTAssertEqual(workspace.columns.count, 2, "Claude and its Board")
            let index = { try XCTUnwrap(shell.workspaces.firstIndex { $0 === workspace }) }
            @MainActor func refuses(_ what: String, columns: Int, _ close: () throws -> Void) rethrows {
                let shown = shell.toastGeneration
                try close()
                XCTAssertGreaterThan(shell.toastGeneration, shown, "\(what): a toast says why")
                XCTAssertEqual(shell.toast?.message, NiruxShellView.leadStaysText, what)
                XCTAssertFalse(workspace.isClosing, what)
                XCTAssertEqual(workspace.openColumns.count, columns, what)
                XCTAssertTrue(workspace.columns.contains { $0 === claude }, what)
            }

            workspace.focusedIndex = 0
            refuses("⌘W on its Claude column", columns: 2) { shell.closeActiveColumn() }
            try refuses("the sidebar's Close Column on it", columns: 2) { shell.closeColumn(workspaceIndex: try index(), columnIndex: 0) }
            try refuses("Close Workspace", columns: 2) { shell.handleWorkspaceSidebarAction(.close, workspaceIndex: try index()) }
            XCTAssertEqual(harness.alerts, [], "nothing to confirm")
            shell.closeWorkspace(at: try index())
            XCTAssertFalse(workspace.isClosing, "no caller closes it but turning it off")

            // Its Board closes, then ⌘W on the column left is refused.
            workspace.focusedIndex = 1
            shell.closeActiveColumn()
            harness.waitUntil("its Board to close") { workspace.columns.count == 1 }
            refuses("⌘W on its last column", columns: 1) { shell.closeActiveColumn() }

            shell.stopLead(spaceID: lead.space)
            harness.waitUntil("turned off, the Lead to close") { !shell.workspaces.contains { $0 === workspace } }
        }
    }

    /// The Lead's Claude column keeps its role wherever columns move, and
    /// across a relaunch; a Lead saved before the role was kept takes its
    /// first terminal.
    func testTheLeadsClaudeColumnKeepsItsRoleWhenColumnsMove() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let lead = try harness.makeLead()
            let claude = try XCTUnwrap(lead.workspace.leadTerminal)
            lead.workspace.focusedIndex = 0
            shell.addColumn()
            shell.moveColumn(.left)
            let terminal = try XCTUnwrap(lead.workspace.columns.first)
            XCTAssertFalse(terminal === claude, "a shell moved before its Claude")
            XCTAssertIdentical(lead.workspace.leadTerminal, claude)
            XCTAssertEqual(shell.leadMissionParent(inSpace: lead.space)?.agentUUID, lead.agentUUID, "no Claude runs: its Claude column")
            lead.workspace.focusedIndex = 1
            shell.closeActiveColumn()
            XCTAssertEqual(shell.toast?.message, NiruxShellView.leadStaysText)
            XCTAssertTrue(lead.workspace.columns.contains { $0 === claude })

            shell.saveState()
            shell.restoreState()
            var restored = try XCTUnwrap(shell.leadWorkspace(inSpace: lead.space))
            XCTAssertEqual(restored.leadTerminal?.agentUUID, lead.agentUUID)
            XCTAssertEqual(restored.columns.first?.agentUUID, terminal.agentUUID)

            // Saved by a build before: the column its Claude resumes in, else its first terminal.
            var state = try XCTUnwrap(Persistence.load())
            let saved = try XCTUnwrap(state.workspaces.firstIndex { $0.id == lead.workspace.id })
            XCTAssertEqual(state.workspaces[saved].leadAgentUUID, lead.agentUUID)
            state.workspaces[saved].leadAgentUUID = nil
            XCTAssertTrue(Persistence.save(state))
            shell.restoreState()
            restored = try XCTUnwrap(shell.leadWorkspace(inSpace: lead.space))
            XCTAssertEqual(restored.leadTerminal?.agentUUID, terminal.agentUUID)
            let claudeColumn = try XCTUnwrap(state.workspaces[saved].columns.firstIndex { $0.agentUUID == lead.agentUUID })
            state.workspaces[saved].columns[claudeColumn].columnType = .claudeCode
            state.workspaces[saved].columns[claudeColumn].claudeSessionID = UUID().uuidString
            XCTAssertTrue(Persistence.save(state))
            shell.restoreState()
            restored = try XCTUnwrap(shell.leadWorkspace(inSpace: lead.space))
            XCTAssertEqual(restored.leadTerminal?.agentUUID, lead.agentUUID)
        }
    }

    /// A Lead whose folder is a linked worktree: its clean-up is blocked,
    /// saying why, even once the folder is gone; closing the worktree's
    /// workspaces leaves it open.
    func testCleanUpKeepsTheLeadsWorktree() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let space = shell.workspaceStore.createProfile(named: "Notes", select: true).id
            shell.addWorkspace(title: NiruxShellView.leadTitle, cwd: harness.worktree, profileID: space, isLead: true)
            let lead = try XCTUnwrap(shell.leadWorkspace(inSpace: space))
            var candidate = shell.worktreeCleanupCandidate(path: harness.worktree)
            XCTAssertEqual(candidate.workspaceIDs, [lead.id])
            candidate.inspection = .folderMissing
            XCTAssertEqual(candidate.availability, .blocked([
                "The Lead of “Notes” works in this folder: only turning it off in Space Settings › Lead closes it."
            ]))
            shell.closeWorkspaces(of: candidate)
            XCTAssertFalse(lead.isClosing)
        }
    }
}
