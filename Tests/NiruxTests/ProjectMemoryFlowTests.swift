import AppKit
import XCTest
@testable import Nirux

/// What the Project Memory panel writes (see ProjectMemory+Writing), in a
/// real window on throwaway state (see UIFlowHarness): the memory in the
/// test's home folder, the brief in its state folder.
@MainActor
final class ProjectMemoryFlowTests: XCTestCase {
    /// From the panel: a brief rule moved to the memory and a memory moved
    /// to the brief (its file to the harness's Trash, its index line gone),
    /// a rule edited, a memory added, then deleted once confirmed; each
    /// read back and selected.
    func testProjectMemoryWrites() throws {
        try UIFlowHarness.run { harness in
            let memory = harness.home + "/.claude/projects/" + ProjectMemory.encodedProjectName(harness.repo) + "/memory"
            try FileManager.default.createDirectory(atPath: memory, withIntermediateDirectories: true)
            try "- [Flow rules](flow-rules.md) — how flows run\n".write(toFile: memory + "/MEMORY.md", atomically: true, encoding: .utf8)
            try "---\nname: flow-rules\ndescription: How flows run\nmetadata:\n  type: feedback\n---\n\nFlows run headless.\n"
                .write(toFile: memory + "/flow-rules.md", atomically: true, encoding: .utf8)
            let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
            let brief = try XCTUnwrap(SpaceBrief.ensureBriefFile(spaceID: workspace.profileID, spaceName: "Flow"))
            try "- **Ship small.** One PR per change.\n".write(to: brief, atomically: true, encoding: .utf8)
            @MainActor func text(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

            harness.shell.showProjectMemory()
            harness.waitUntil("the memory panel") { harness.shell.projectMemoryPanel?.isVisible == true }
            let panel = try XCTUnwrap(harness.shell.projectMemoryPanel)
            let preview = try XCTUnwrap(panel.preview)
            @MainActor func titles() -> [String] { panel.rows.compactMap { panel.model?.knowledge.entries[safe: $0]?.title } }
            @MainActor func pick(_ title: String) throws {
                let row = try XCTUnwrap(titles().firstIndex(of: title), "\(title) in \(titles())")
                panel.tableView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            @MainActor func switchTo(_ scope: ProjectMemory.Scope) {
                preview.scopeControl.selectedSegment = scope == .always ? 0 : 1
                XCTAssertTrue(preview.scopeControl.sendAction(preview.scopeControl.action, to: preview.scopeControl.target))
            }
            XCTAssertEqual(titles(), ["Ship small", "Flow rules"])

            // Always → When relevant: a memory, the rule out of the brief.
            XCTAssertEqual(panel.selectedEntry?.title, "Ship small")
            XCTAssertFalse(preview.scopeControl.isHidden)
            switchTo(.whenRelevant)
            harness.waitUntil("the rule as a memory") { panel.model?.knowledge.count(.whenRelevant) == 2 }
            XCTAssertEqual(panel.selectedEntry?.scope, .whenRelevant)
            XCTAssertEqual(panel.selectedEntry?.title, "Ship small")
            XCTAssertTrue(FileManager.default.fileExists(atPath: memory + "/ship-small.md"))
            XCTAssertFalse(text(brief.path).contains("Ship small"))
            XCTAssertTrue(text(memory + "/MEMORY.md").contains("](ship-small.md)"))

            // When relevant → Always: in the brief, the file and its line
            // gone.
            try pick("Flow rules")
            switchTo(.always)
            harness.waitUntil("the memory as a rule") { panel.model?.knowledge.count(.always) == 1 }
            XCTAssertEqual(harness.alerts.last, "Move “Flow rules” to Always?")
            XCTAssertEqual(panel.selectedEntry?.title, "Flow rules")
            XCTAssertEqual(panel.selectedEntry?.scope, .always)
            XCTAssertTrue(text(brief.path).contains("- **Flow rules** Flows run headless."))
            XCTAssertFalse(FileManager.default.fileExists(atPath: memory + "/flow-rules.md"))
            XCTAssertFalse(text(memory + "/MEMORY.md").contains("flow-rules.md"))

            // Edited as written; nothing else can be picked meanwhile, and
            // Escape leaves it.
            let table = try XCTUnwrap(panel.tableView)
            try XCTUnwrap(panel.editButton).performClick(nil)
            XCTAssertTrue(preview.isEditing)
            XCTAssertEqual(preview.textView.string, "**Flow rules** Flows run headless.")
            XCTAssertFalse(panel.tableView(table, shouldSelectRow: 0))
            XCTAssertEqual(panel.searchField?.isEnabled, false)
            harness.press(.escape, in: panel.searchField?.window)
            XCTAssertFalse(preview.isEditing)
            XCTAssertEqual(panel.searchField?.isEnabled, true)
            XCTAssertTrue(panel.isVisible)

            // The brief changed under the edit: refused, the edit kept as
            // typed, why said in the panel.
            try XCTUnwrap(panel.editButton).performClick(nil)
            preview.textView.string = "**Flow rules** typed over a stale rule."
            let briefText = text(brief.path)
            try ("- Added by hand.\n" + briefText).write(to: brief, atomically: true, encoding: .utf8)
            try XCTUnwrap(panel.saveButton).performClick(nil)
            harness.waitUntil("the refused save") { !panel.isWriting }
            XCTAssertTrue(preview.isEditing)
            XCTAssertEqual(preview.textView.string, "**Flow rules** typed over a stale rule.")
            XCTAssertEqual(panel.errorLabel?.stringValue, "brief.md changed since the panel read it: look again and retry")
            // Cancelled, the panel shows the brief as it is now.
            try XCTUnwrap(panel.cancelButton).performClick(nil)
            XCTAssertEqual(titles().first, "Added by hand")
            XCTAssertEqual(panel.selectedEntry?.title, "Flow rules")

            try XCTUnwrap(panel.editButton).performClick(nil)
            preview.textView.string = "**Flow rules** Flows run headless, in CI too."
            try XCTUnwrap(panel.saveButton).performClick(nil)
            harness.waitUntil("the edited rule") { text(brief.path).contains("in CI too.") }
            harness.waitUntil("the edited rule read back") { panel.selectedEntry?.detail == "Flows run headless, in CI too." }

            // Added: a memory by default.
            try XCTUnwrap(panel.addButton).performClick(nil)
            let sheet = try XCTUnwrap(panel.addSheet)
            sheet.titleField.stringValue = "Added fact"
            sheet.descriptionField.stringValue = "Written from the panel"
            sheet.textView.string = "Facts get added."
            sheet.update()
            XCTAssertEqual(sheet.fileLabel.stringValue, "Claude Code memory: added-fact.md")
            sheet.add()
            harness.waitUntil("the added memory") { panel.selectedEntry?.title == "Added fact" }
            XCTAssertTrue(text(memory + "/added-fact.md").contains("Facts get added."))

            // Deleted once confirmed.
            try XCTUnwrap(panel.deleteButton).performClick(nil)
            harness.waitUntil("the deleted memory") { !titles().contains("Added fact") }
            XCTAssertEqual(harness.alerts.last, "Delete “Added fact”?")
            XCTAssertFalse(FileManager.default.fileExists(atPath: memory + "/added-fact.md"))
            XCTAssertFalse(text(memory + "/MEMORY.md").contains("added-fact.md"))
            XCTAssertTrue(panel.isVisible)

            // A delete that fails says why, and never brings back the sheet
            // of the item added before.
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: memory)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: memory) }
            try pick("Ship small")
            try XCTUnwrap(panel.deleteButton).performClick(nil)
            harness.waitUntil("the refused delete") { !panel.isWriting && panel.errorLabel?.stringValue.isEmpty == false }
            XCTAssertNil(panel.addSheet)
            XCTAssertEqual(panel.selectedEntry?.title, "Ship small")
            XCTAssertTrue(FileManager.default.fileExists(atPath: memory + "/ship-small.md"))
        }
    }
}
