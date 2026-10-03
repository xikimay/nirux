import AppKit
import XCTest
@testable import Nirux

/// The New Task… form beyond the happy path `testNewTaskCommand` runs:
/// the keyboard, a branch that exists, a fetch that fails, closing the form
/// while the task starts, another project, Codex.
@MainActor
final class NewTaskFlowTests: UIFlowTestCase {
    private func openForm(_ harness: UIFlowHarness) throws -> NewTaskPanel {
        harness.runPaletteCommand("New Task…")
        harness.waitUntil("the new task sheet") { harness.shell.newTaskPanel?.panel?.isSheet == true }
        let form = try XCTUnwrap(harness.shell.newTaskPanel)
        harness.waitUntil("the project's repository") { form.info != nil }
        return form
    }

    private func describe(_ text: String, in form: NewTaskPanel) {
        form.descriptionView.string = text
        form.descriptionView.didChangeText()
    }

    private func select(_ title: String, in popup: NSPopUpButton) {
        popup.selectItem(withTitle: title)
        popup.sendAction(popup.action, to: popup.target)
    }

    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow?) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
    }

    func testReturnAddsALineInTheTaskAndEscapeCancels() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let workspaceCount = shell.workspaces.count
            let form = try openForm(harness)
            let sheet = try XCTUnwrap(form.panel as? NewTaskSheet)
            describe("First line", in: form)
            sheet.makeFirstResponder(form.descriptionView)
            form.descriptionView.setSelectedRange(NSRange(location: form.descriptionView.string.count, length: 0))

            // A sheet can't be the key window in a test, where AppKit's
            // default button never answers Return: check the rule that keeps
            // Return from it in the description, as Board Settings does.
            let returnKey = try key("\r", code: 0x24, in: sheet)
            XCTAssertTrue(sheet.defaultButtonCell === form.startButton.cell)
            XCTAssertTrue(BoardSettingsSheet.leavesToTextView(
                returnKey, firstResponder: sheet.firstResponder, multilineView: sheet.multilineView
            ))
            XCTAssertFalse(sheet.performKeyEquivalent(with: returnKey))
            form.descriptionView.keyDown(with: returnKey)
            XCTAssertEqual(form.descriptionView.string, "First line\n")
            XCTAssertFalse(form.isStarting)

            XCTAssertTrue(sheet.performKeyEquivalent(with: try key("\u{1b}", code: 0x35, in: sheet)))
            XCTAssertNil(shell.newTaskPanel)
            XCTAssertNil(harness.window.attachedSheet)
            XCTAssertEqual(shell.workspaces.count, workspaceCount)
            XCTAssertFalse(FileManager.default.fileExists(atPath: harness.root + "/repo.feat-first-line"))
        }
    }

    func testAnExistingBranchKeepsTheFormOpenWithTheError() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let workspaceCount = shell.workspaces.count
            let form = try openForm(harness)

            // A branch typed by hand no longer follows the description.
            describe("Flow work", in: form)
            XCTAssertEqual(form.branch, "feat/flow-work")
            harness.type("Feat/Flow", into: form.branchField)
            describe("Other work", in: form)
            XCTAssertEqual(form.branch, "Feat/Flow")

            form.startButton.performClick(nil)
            harness.waitUntil("the error") { !form.isStarting }
            XCTAssertIdentical(harness.window.attachedSheet, form.panel)
            XCTAssertFalse(form.errorLabel.isHidden)
            XCTAssertEqual(form.errorLabel.stringValue, "\(harness.worktreeBranch) already exists: choose another branch name")
            XCTAssertEqual(shell.workspaces.count, workspaceCount)
            XCTAssertTrue(harness.agentLaunches.isEmpty)
            XCTAssertTrue(form.descriptionView.isEditable)
            XCTAssertTrue(form.startButton.isEnabled)
            // Typing goes on in the branch field.
            XCTAssertNotNil(form.branchField.currentEditor())

            // Cleared, it follows the description again; ⌘Return starts.
            harness.type("", into: form.branchField)
            XCTAssertEqual(form.branch, "feat/other-work")
            XCTAssertEqual(form.panel?.performKeyEquivalent(with: try key("\r", code: 0x24, modifiers: .command, in: form.panel)), true)
            harness.waitUntil("the task's workspace") { shell.workspaces.contains { $0.title == "Other work" } }
            XCTAssertNil(shell.newTaskPanel)
            XCTAssertTrue(FileManager.default.fileExists(atPath: harness.root + "/repo.feat-other-work/.claude-handover.md"))
        }
    }

    /// A fetch that fails stops the first Start: the form, closed meanwhile,
    /// comes back to say so, and the next Start goes from origin's branch
    /// as last fetched.
    func testAFailedFetchComesBackToTheClosedForm() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            try UIFlowHarness.git(["remote", "add", "origin", harness.root + "/gone.git"], at: harness.repo)
            try UIFlowHarness.git(["update-ref", "refs/remotes/origin/main", "HEAD"], at: harness.repo)
            let form = try openForm(harness)
            XCTAssertEqual(form.info?.target?.remoteBranchName, "origin/main")
            XCTAssertEqual(form.repositoryLabel.stringValue, "\(harness.repo)\nStarts from origin/main, fetched when the task starts.")
            describe("Offline work", in: form)

            form.startButton.performClick(nil)
            XCTAssertTrue(form.isStarting)
            XCTAssertEqual(form.cancelButton.title, "Close")
            form.cancelButton.performClick(nil)
            XCTAssertTrue(form.isHidden)
            XCTAssertNil(harness.window.attachedSheet)
            XCTAssertIdentical(shell.newTaskPanel, form)

            harness.waitUntil("the fetch to fail") { !form.isStarting }
            XCTAssertFalse(form.isHidden)
            XCTAssertIdentical(harness.window.attachedSheet, form.panel)
            XCTAssertTrue(form.errorLabel.stringValue.hasPrefix("Couldn’t fetch origin/main: fatal:"), form.errorLabel.stringValue)
            XCTAssertTrue(form.errorLabel.stringValue.hasSuffix("Start Task again to start from origin/main as last fetched."))
            XCTAssertFalse(FileManager.default.fileExists(atPath: harness.root + "/repo.feat-offline-work"))
            XCTAssertEqual(form.repositoryLabel.stringValue, "\(harness.repo)\nStarts from origin/main as last fetched: the fetch failed.")
            // Back while the user typed elsewhere: no field takes the keys,
            // and Return waits for an edit here before it starts the task.
            XCTAssertNil(form.branchField.currentEditor())
            XCTAssertIdentical(form.panel?.firstResponder, form.panel)
            XCTAssertEqual(form.startButton.keyEquivalent, "")
            describe("Offline work", in: form)
            XCTAssertEqual(form.startButton.keyEquivalent, "\r")

            form.startButton.performClick(nil)
            harness.waitUntil("the task's workspace") { shell.workspaces.contains { $0.title == "Offline work" } }
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let handover = try String(contentsOfFile: workspace.cwd + "/.claude-handover.md", encoding: .utf8)
            XCTAssertTrue(handover.contains("created from origin/main as last fetched: Nirux couldn’t fetch it"), handover)
        }
    }

    func testATaskInAnotherProjectWithCodex() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let repoWorkspace = try XCTUnwrap(shell.activeWorkspace)
            let notes = shell.workspaceStore.createProfile(named: "Notes")
            shell.addWorkspace(title: "notes", cwd: harness.home, profileID: notes.id)
            // The project is a folder of the repository: its tasks open there.
            let code = shell.workspaceStore.createProfile(named: "Code")
            shell.addWorkspace(title: "code", cwd: harness.worktree + "/docs", profileID: code.id)
            shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0 === repoWorkspace }))

            let form = try openForm(harness)
            XCTAssertEqual(form.projects.map(\.name), shell.profiles.map(\.name))
            XCTAssertEqual(form.selectedProjectID, WorkspaceProfile.defaultID)

            // No workspace of it is in a repository: nothing to start.
            select("Notes", in: form.projectPopup)
            harness.waitUntil("the Notes project's info") { form.info != nil }
            XCTAssertNil(form.info?.target)
            XCTAssertFalse(form.startButton.isEnabled)
            XCTAssertEqual(form.repositoryLabel.stringValue, NewTaskPanel.repositoryText(nil))

            // A linked worktree: its tasks go next to the main checkout.
            select("Code", in: form.projectPopup)
            harness.waitUntil("the Code project's info") { form.info != nil }
            XCTAssertEqual(form.info?.target?.repository, harness.repo)
            XCTAssertEqual(form.info?.target?.subdirectory, "docs")
            XCTAssertTrue(form.repositoryLabel.stringValue.hasPrefix("\(harness.repo), in docs\n"), form.repositoryLabel.stringValue)
            XCTAssertTrue(form.startButton.isEnabled)

            select("Codex", in: form.agentPopup)
            select("Investigation (no code)", in: form.templatePopup)
            describe("Why is the cache cold?", in: form)
            XCTAssertEqual(form.branch, "feat/why-is-the-cache-cold")
            // Closed while it starts: the workspace still opens.
            form.startButton.performClick(nil)
            form.cancelButton.performClick(nil)
            XCTAssertNil(harness.window.attachedSheet)
            harness.waitUntil("the task's workspace") { shell.workspaces.contains { $0.title == "Why is the cache cold?" } }
            XCTAssertNil(shell.newTaskPanel)

            let workspace = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertEqual(workspace.title, "Why is the cache cold?")
            XCTAssertEqual(workspace.profileID, code.id)
            XCTAssertEqual(shell.activeProfileID, code.id)
            let worktree = harness.root + "/repo.feat-why-is-the-cache-cold"
            XCTAssertEqual(NiruxShellView.comparablePath(workspace.cwd), NiruxShellView.comparablePath(worktree + "/docs"))
            // Where the agent starts, which its prompt names it from.
            let handover = try String(contentsOfFile: worktree + "/docs/.codex-handover.md", encoding: .utf8)
            XCTAssertTrue(handover.contains("(template “Investigation (no code)”)"), handover)
            XCTAssertTrue(handover.contains("The project lives in `docs` of this repository."), handover)
            for misplaced in ["/.codex-handover.md", "/.claude-handover.md", "/docs/.claude-handover.md"] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: worktree + misplaced), misplaced)
            }
            XCTAssertEqual(try UIFlowHarness.git(["status", "--porcelain"], at: worktree), "")
            let launch = try XCTUnwrap(harness.agentLaunches.last)
            XCTAssertTrue(launch.hasPrefix("command codex"), launch)
            XCTAssertTrue(launch.contains("Read .codex-handover.md for full context"), launch)
        }
    }
}
