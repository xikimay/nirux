import AppKit
import XCTest
@testable import Nirux

/// The ⌘N sheet beyond the happy path `testNewCommand` runs: the keyboard,
/// a branch that exists, a fetch that fails, closing the sheet while the
/// task starts, two repositories, nothing typed, a space without a
/// repository, General, Existing Branch…, and the worktrees agents ask for.
@MainActor
final class NewTaskFlowTests: UIFlowTestCase {
    /// A space anchored to the harness's repository, selected: its own
    /// workspace opens in the main checkout.
    static func anchoredSpace(_ harness: UIFlowHarness, also others: [SpaceAnchor] = []) throws -> WorkspaceProfile {
        let repository = try XCTUnwrap(FolderIdentity.identify(harness.repo, timeout: 10)).anchor
        let space = harness.shell.workspaceStore.createProfile(named: "Repo", anchors: [repository] + others, select: false)
        harness.shell.selectProfile(space.id)
        return space
    }

    private func openSheet(_ harness: UIFlowHarness, waitingForInfo: Bool = true) throws -> NewTaskPanel {
        harness.runPaletteCommand("New…")
        harness.waitUntil("the sheet") { harness.shell.newTaskPanel?.panel?.isSheet == true }
        let sheet = try XCTUnwrap(harness.shell.newTaskPanel)
        if waitingForInfo { harness.waitUntil("the repository's info") { sheet.info != nil } }
        return sheet
    }

    private func describe(_ text: String, in sheet: NewTaskPanel) {
        sheet.descriptionView.string = text
        sheet.descriptionView.didChangeText()
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

    func testReturnStartsShiftReturnAddsALineAndEscapeCancels() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            _ = try Self.anchoredSpace(harness)
            let workspaceCount = shell.workspaces.count

            // Escape cancels, creating nothing.
            var sheet = try openSheet(harness)
            var panel = try XCTUnwrap(sheet.panel as? NewTaskSheet)
            describe("Never started", in: sheet)
            XCTAssertTrue(panel.performKeyEquivalent(with: try key("\u{1b}", code: 0x35, in: panel)))
            XCTAssertNil(shell.newTaskPanel)
            XCTAssertNil(harness.window.attachedSheet)
            XCTAssertEqual(shell.workspaces.count, workspaceCount)

            sheet = try openSheet(harness)
            panel = try XCTUnwrap(sheet.panel as? NewTaskSheet)
            describe("First line", in: sheet)
            panel.makeFirstResponder(sheet.descriptionView)
            sheet.descriptionView.setSelectedRange(NSRange(location: sheet.descriptionView.string.count, length: 0))
            // A sheet can't be the key window in a test, where AppKit's
            // default button never answers Return: check the rule that
            // leaves Return, with or without ⇧, to the description.
            let returnKey = try key("\r", code: 0x24, in: panel)
            let shiftReturn = try key("\r", code: 0x24, modifiers: .shift, in: panel)
            XCTAssertTrue(panel.defaultButtonCell === sheet.startButton.cell)
            XCTAssertFalse(panel.performKeyEquivalent(with: shiftReturn))
            XCTAssertFalse(panel.performKeyEquivalent(with: returnKey))
            sheet.descriptionView.keyDown(with: shiftReturn)
            XCTAssertEqual(sheet.descriptionView.string.count, "First line".count + 1)
            XCTAssertEqual(sheet.descriptionView.string.last?.isNewline, true, sheet.descriptionView.string)
            XCTAssertFalse(sheet.isStarting)

            sheet.descriptionView.keyDown(with: returnKey)
            XCTAssertEqual(sheet.descriptionView.string.count, "First line".count + 1, "Return adds no line")
            harness.waitUntil("the task's workspace") { shell.workspaces.contains { $0.title == "First line" } }
            XCTAssertNil(shell.newTaskPanel)
            XCTAssertTrue(FileManager.default.fileExists(atPath: harness.root + "/repo.feat-first-line/.claude-handover.md"))
        }
    }

    func testAnExistingBranchKeepsTheSheetOpenWithTheError() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            _ = try Self.anchoredSpace(harness)
            let workspaceCount = shell.workspaces.count
            let sheet = try openSheet(harness)

            // A branch typed by hand no longer follows the description.
            describe("Flow work", in: sheet)
            XCTAssertEqual(sheet.branch, "feat/flow-work")
            XCTAssertTrue(sheet.branchField.isHidden)
            sheet.editBranchButton.performClick(nil)
            XCTAssertFalse(sheet.branchField.isHidden)
            XCTAssertTrue(sheet.editBranchButton.isHidden)
            harness.type("Feat/Flow", into: sheet.branchField)
            describe("Other work", in: sheet)
            XCTAssertEqual(sheet.branch, "Feat/Flow")

            sheet.startButton.performClick(nil)
            harness.waitUntil("the error") { !sheet.isStarting }
            XCTAssertIdentical(harness.window.attachedSheet, sheet.panel)
            XCTAssertFalse(sheet.errorLabel.isHidden)
            XCTAssertEqual(sheet.errorLabel.stringValue, "\(harness.worktreeBranch) already exists: choose another branch name")
            XCTAssertEqual(shell.workspaces.count, workspaceCount)
            XCTAssertTrue(harness.agentLaunches.isEmpty)
            XCTAssertTrue(sheet.descriptionView.isEditable)
            XCTAssertTrue(sheet.startButton.isEnabled)
            // Typing goes on in the branch field.
            XCTAssertNotNil(sheet.branchField.currentEditor())

            // Cleared, it follows the description again; ⌘Return starts.
            harness.type("", into: sheet.branchField)
            XCTAssertEqual(sheet.branch, "feat/other-work")
            XCTAssertEqual(sheet.panel?.performKeyEquivalent(with: try key("\r", code: 0x24, modifiers: .command, in: sheet.panel)), true)
            harness.waitUntil("the task's workspace") { shell.workspaces.contains { $0.title == "Other work" } }
            XCTAssertNil(shell.newTaskPanel)
            XCTAssertTrue(FileManager.default.fileExists(atPath: harness.root + "/repo.feat-other-work/.claude-handover.md"))
        }
    }

    /// A fetch that fails stops the first Start: the sheet, closed
    /// meanwhile, comes back to say so, and the next Start goes from
    /// origin's branch as last fetched.
    func testAFailedFetchComesBackToTheClosedSheet() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            try UIFlowHarness.git(["remote", "add", "origin", harness.root + "/gone.git"], at: harness.repo)
            try UIFlowHarness.git(["update-ref", "refs/remotes/origin/main", "HEAD"], at: harness.repo)
            _ = try Self.anchoredSpace(harness)
            let sheet = try openSheet(harness)
            XCTAssertEqual(sheet.info?.target?.remoteBranchName, "origin/main")
            describe("Offline work", in: sheet)
            XCTAssertEqual(sheet.lineLabel.stringValue, "feat/offline-work  ·  from origin/main")

            sheet.startButton.performClick(nil)
            XCTAssertTrue(sheet.isStarting)
            XCTAssertTrue(sheet.lineLabel.stringValue.hasPrefix("Fetching origin/main, then creating the worktree…"))
            XCTAssertEqual(sheet.cancelButton.title, "Close")
            sheet.cancelButton.performClick(nil)
            XCTAssertTrue(sheet.isHidden)
            XCTAssertNil(harness.window.attachedSheet)
            XCTAssertIdentical(shell.newTaskPanel, sheet)

            harness.waitUntil("the fetch to fail") { !sheet.isStarting }
            XCTAssertFalse(sheet.isHidden)
            XCTAssertIdentical(harness.window.attachedSheet, sheet.panel)
            XCTAssertTrue(sheet.errorLabel.stringValue.hasPrefix("Couldn’t fetch origin/main: fatal:"), sheet.errorLabel.stringValue)
            XCTAssertTrue(sheet.errorLabel.stringValue.hasSuffix("Start again to start from origin/main as last fetched."))
            XCTAssertFalse(FileManager.default.fileExists(atPath: harness.root + "/repo.feat-offline-work"))
            XCTAssertEqual(sheet.lineLabel.stringValue, "feat/offline-work  ·  from origin/main as last fetched")
            // Back while the user typed elsewhere: no field takes the keys,
            // and Return waits for an edit here before it starts the task.
            XCTAssertNil(sheet.branchField.currentEditor())
            XCTAssertIdentical(sheet.panel?.firstResponder, sheet.panel)
            XCTAssertEqual(sheet.startButton.keyEquivalent, "")
            describe("Offline work", in: sheet)
            XCTAssertEqual(sheet.startButton.keyEquivalent, "\r")

            sheet.startButton.performClick(nil)
            harness.waitUntil("the task's workspace") { shell.workspaces.contains { $0.title == "Offline work" } }
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let handover = try String(contentsOfFile: workspace.cwd + "/.claude-handover.md", encoding: .utf8)
            XCTAssertTrue(handover.contains("created from origin/main as last fetched: Nirux couldn’t fetch it"), handover)
        }
    }

    /// Two anchors: the popup picks one, the default first. A folder of the
    /// repository: its tasks open there.
    func testATaskInAFolderOfTheRepositoryWithCodex() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let notes = harness.root + "/notes"
            try FileManager.default.createDirectory(atPath: notes, withIntermediateDirectories: true)
            let docs = try XCTUnwrap((harness.repo + "/docs").realPath)
            let space = try Self.anchoredSpace(harness, also: [.folder(docs), .folder(notes)])
            let sheet = try openSheet(harness)
            XCTAssertFalse(sheet.repositoryPopup.isHidden)
            XCTAssertEqual(sheet.repositoryPopup.itemTitles, ["repo", "docs", "notes"])
            XCTAssertEqual(sheet.repositoryPopup.titleOfSelectedItem, "repo")
            XCTAssertEqual(sheet.info?.target?.repository, harness.repo)
            describe("Why is the cache cold?", in: sheet)

            // A folder in no repository: no task, but a shell still opens.
            select("notes", in: sheet.repositoryPopup)
            harness.waitUntil("the notes folder's info") { sheet.info != nil }
            XCTAssertNil(sheet.info?.target)
            XCTAssertFalse(sheet.startButton.isEnabled)
            XCTAssertEqual(sheet.lineLabel.stringValue, "“notes” isn’t in a git repository: tasks need one.")

            select("docs", in: sheet.repositoryPopup)
            harness.waitUntil("the docs folder's info") { sheet.info != nil }
            XCTAssertEqual(sheet.info?.target?.repository, harness.repo)
            XCTAssertEqual(sheet.info?.target?.subdirectory, "docs")
            XCTAssertTrue(sheet.startButton.isEnabled)

            select("Codex", in: sheet.agentPopup)
            select("Investigation (no code)", in: sheet.templatePopup)
            XCTAssertEqual(sheet.branch, "feat/why-is-the-cache-cold")
            // Closed while it starts: the workspace still opens.
            sheet.startButton.performClick(nil)
            sheet.cancelButton.performClick(nil)
            XCTAssertNil(harness.window.attachedSheet)
            harness.waitUntil("the task's workspace") { shell.workspaces.contains { $0.title == "Why is the cache cold?" } }
            XCTAssertNil(shell.newTaskPanel)

            let workspace = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertEqual(workspace.title, "Why is the cache cold?")
            XCTAssertEqual(workspace.profileID, space.id)
            let worktree = harness.root + "/repo.feat-why-is-the-cache-cold"
            XCTAssertEqual(NiruxShellView.comparablePath(workspace.cwd), NiruxShellView.comparablePath(worktree + "/docs"))
            // Where the agent starts, which its prompt names it from.
            let handover = try String(contentsOfFile: worktree + "/docs/.codex-handover.md", encoding: .utf8)
            XCTAssertTrue(handover.contains("(template “Investigation (no code)”)"), handover)
            XCTAssertTrue(handover.contains("The space works in `docs` of this repository."), handover)
            for misplaced in ["/.codex-handover.md", "/.claude-handover.md", "/docs/.claude-handover.md"] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: worktree + misplaced), misplaced)
            }
            XCTAssertEqual(try UIFlowHarness.git(["status", "--porcelain"], at: worktree), "")
            let launch = try XCTUnwrap(harness.agentLaunches.last)
            XCTAssertTrue(launch.hasPrefix("command codex"), launch)
            XCTAssertTrue(launch.contains("Read .codex-handover.md for full context"), launch)
        }
    }

    /// Return with nothing typed: a shell in the selected repository's main
    /// checkout, or the home folder without one, named after its folder.
    /// Never "ws N", and no agent.
    func testNothingTypedOpensAShell() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            var sheet = try openSheet(harness, waitingForInfo: false)
            XCTAssertEqual(sheet.headingLabel.stringValue, "New in \(WorkspaceProfile.defaultProfile.name)")
            XCTAssertTrue(sheet.repositoryPopup.isHidden, "General has no repository to pick")
            XCTAssertEqual(sheet.lineLabel.stringValue, "Nothing typed: Start opens a shell in ~.")
            XCTAssertTrue(sheet.startButton.isEnabled)
            sheet.startButton.performClick(nil)
            XCTAssertNil(shell.newTaskPanel)
            let home = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertEqual(home.cwd, harness.home)
            XCTAssertEqual(home.title, "~")
            XCTAssertEqual(home.profileID, WorkspaceProfile.defaultID)

            let space = try Self.anchoredSpace(harness)
            sheet = try openSheet(harness)
            XCTAssertEqual(sheet.lineLabel.stringValue, "Nothing typed: Start opens a shell in \(harness.repo).")
            describe("   \n ", in: sheet)
            sheet.startButton.performClick(nil)
            let plain = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertEqual(plain.cwd, harness.repo)
            XCTAssertEqual(plain.profileID, space.id)
            XCTAssertEqual(plain.title, "repo")
            XCTAssertTrue(harness.agentLaunches.isEmpty)
            XCTAssertFalse(shell.workspaces.contains { $0.title.hasPrefix("ws ") })
        }
    }

    /// A space without a repository offers the focused terminal's, and
    /// "Add Repository…" picks one over the sheet; either way the task can
    /// start once it is added.
    func testASpaceWithoutARepositoryOffersToAddOne() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let space = shell.workspaceStore.createProfile(named: "Empty", select: false)
            shell.addWorkspace(title: "in repo", cwd: harness.worktree, profileID: space.id)
            shell.selectProfile(space.id)
            let sheet = try openSheet(harness)
            XCTAssertNil(sheet.info?.target)
            XCTAssertFalse(sheet.repositoryPopup.isHidden)
            harness.waitUntil("the suggestion") { sheet.suggestion != nil }
            XCTAssertEqual(sheet.repositoryPopup.itemTitles, ["No Repository", "", "Add “repo”", "Add Repository…"])
            XCTAssertEqual(sheet.lineLabel.stringValue, "Nothing typed: Start opens a shell in ~.")
            describe("Wire the cache", in: sheet)
            XCTAssertEqual(sheet.lineLabel.stringValue, "This space has no repository yet: add one with the menu above.")
            XCTAssertFalse(sheet.startButton.isEnabled)

            // "Add Repository…" picks the folder over the sheet: the window
            // has one already. Cancelled, nothing changes.
            var pickedOver: NSWindow?
            shell.sideEffects.chooseFolder = { _, window, completion in
                pickedOver = window
                completion(nil)
            }
            select("Add Repository…", in: sheet.repositoryPopup)
            XCTAssertIdentical(pickedOver, sheet.panel)
            XCTAssertEqual(sheet.repositoryPopup.titleOfSelectedItem, "No Repository")

            select("Add “repo”", in: sheet.repositoryPopup)
            harness.waitUntil("the repository to join the space") { !sheet.repositories.isEmpty }
            XCTAssertEqual(shell.profiles.first { $0.id == space.id }?.anchors.map(\.name), ["repo"])
            XCTAssertTrue(sheet.repositoryPopup.isHidden, "one repository: nothing to choose")
            harness.waitUntil("the repository's info") { sheet.info?.target != nil }
            XCTAssertEqual(sheet.info?.target?.repository, harness.repo)
            XCTAssertTrue(sheet.startButton.isEnabled)
            sheet.startButton.performClick(nil)
            harness.waitUntil("the task's workspace") { shell.workspaces.contains { $0.title == "Wire the cache" } }
            XCTAssertEqual(shell.activeWorkspace?.profileID, space.id)
        }
    }

    /// General never has a repository: a task there points to New Space….
    func testGeneralOffersANewSpaceForATask() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let sheet = try openSheet(harness)
            describe("Wire the cache", in: sheet)
            XCTAssertEqual(
                sheet.lineLabel.stringValue,
                "\(WorkspaceProfile.defaultProfile.name) has no repository: tasks start in a space that has one."
            )
            XCTAssertFalse(sheet.startButton.isEnabled)
            XCTAssertFalse(sheet.newSpaceButton.isHidden)
            sheet.newSpaceButton.performClick(nil)
            XCTAssertNil(shell.newTaskPanel)
            harness.waitUntil("New Space…") { shell.newSpacePanel?.panel?.isSheet == true }
            // The focused terminal's repository, already in it.
            XCTAssertEqual(shell.newSpacePanel?.rows.map(\.anchor.name), ["repo"])
        }
    }

    /// Existing Branch… lists the selected repository's worktrees, its main
    /// checkout too, and goes back to the one the active workspace is in.
    func testExistingBranchListsTheRepositorysWorktrees() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            _ = try Self.anchoredSpace(harness)
            let active = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertEqual(active.cwd, harness.repo)
            let workspaceCount = shell.workspaces.count
            let sheet = try openSheet(harness)
            sheet.existingBranchButton.performClick(nil)
            XCTAssertNil(shell.newTaskPanel)
            let palette = try XCTUnwrap(shell.commandPalette)
            harness.waitUntil("the worktree list") {
                palette.isVisible && Set(palette.filteredActions.map(\.title)) == ["main", harness.worktreeBranch]
            }
            let main = try XCTUnwrap(palette.filteredActions.first { $0.title == "main" })
            XCTAssertTrue(main.subtitle.hasPrefix("Already open · "), main.subtitle)
            harness.type("main", into: try XCTUnwrap(palette.searchField))
            harness.press(.returnKey, in: palette.panel)
            XCTAssertIdentical(shell.activeWorkspace, active)
            XCTAssertEqual(shell.workspaces.count, workspaceCount)
        }
    }

    /// `nirux://new-worktree`: a new branch starts from origin's base
    /// branch, fetched, without tracking it; `from=head` from the
    /// requesting checkout's HEAD; a branch that exists opens as it is,
    /// without a fetch; a failed fetch says so and starts from origin's
    /// branch as last fetched; a failing hook says so; a branch that exists
    /// in another case is never taken for a new one.
    func testAnAgentsWorktreeStartsFromOriginFetched() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let origin = harness.root + "/origin.git"
            try UIFlowHarness.git(["init", "-q", "--bare", "-b", "main", origin], at: harness.root)
            try UIFlowHarness.git(["remote", "add", "origin", origin], at: harness.repo)
            try UIFlowHarness.git(["push", "-q", "origin", "main"], at: harness.repo)
            let local = try UIFlowHarness.git(["rev-parse", "HEAD"], at: harness.repo).trimmingCharacters(in: .whitespacesAndNewlines)
            // Origin moves on; this checkout hasn't fetched it.
            let ahead = try UIFlowHarness.git(
                ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "ahead"],
                at: harness.repo
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            try UIFlowHarness.git(["push", "-q", "origin", "\(ahead):refs/heads/main"], at: harness.repo)
            try UIFlowHarness.git(["update-ref", "refs/remotes/origin/main", local], at: harness.repo)
            try UIFlowHarness.git(["branch", "feat/existing"], at: harness.repo)
            // The requesting checkout is a commit ahead of the main one.
            try UIFlowHarness.git(
                ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "--allow-empty", "-m", "stacked"],
                at: harness.worktree
            )
            let requester = try UIFlowHarness.git(["rev-parse", "HEAD"], at: harness.worktree)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            @MainActor func openWorktree(_ branch: String, startsFromHead: Bool = false) throws -> WorkspaceState {
                shell.createWorktreeWorkspace(
                    branch: branch, repoRoot: harness.worktree, agent: nil,
                    profileID: WorkspaceProfile.defaultID, startsFromHead: startsFromHead
                )
                harness.waitUntil("\(branch)'s workspace") { shell.workspaces.contains { $0.title == branch } }
                return try XCTUnwrap(shell.workspaces.first { $0.title == branch })
            }
            @MainActor func head(_ workspace: WorkspaceState) throws -> String {
                try UIFlowHarness.git(["rev-parse", "HEAD"], at: workspace.cwd).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let fresh = try openWorktree("feat/from-origin")
            XCTAssertEqual(try head(fresh), ahead)
            XCTAssertThrowsError(try UIFlowHarness.git(["rev-parse", "--abbrev-ref", "feat/from-origin@{upstream}"], at: harness.repo))
            XCTAssertEqual(try head(try openWorktree("feat/stacked", startsFromHead: true)), requester)

            try UIFlowHarness.git(["remote", "set-url", "origin", harness.root + "/gone.git"], at: harness.repo)
            XCTAssertEqual(try head(try openWorktree("feat/existing")), local)
            XCTAssertNil(shell.toast, "no fetch for a branch that exists")
            XCTAssertEqual(try head(try openWorktree("feat/offline")), ahead, "origin/main as last fetched")
            XCTAssertEqual(shell.toast?.message.hasPrefix("Couldn’t fetch origin/main: “feat/offline” starts from it as last fetched."), true)

            // A post-checkout hook that fails leaves the worktree: it opens,
            // and git's error shows.
            try UIFlowHarness.git(["remote", "set-url", "origin", origin], at: harness.repo)
            let hooks = harness.root + "/hooks"
            try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
            try "#!/bin/sh\necho hook-refused >&2\nexit 3\n".write(toFile: hooks + "/post-checkout", atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks + "/post-checkout")
            try UIFlowHarness.git(["config", "core.hooksPath", hooks], at: harness.repo)
            XCTAssertEqual(try head(try openWorktree("feat/hooked")), ahead)
            @MainActor func texts(in view: NSView) -> [String] {
                ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts(in:))
            }
            harness.waitUntil("git's error") { harness.window.attachedSheet != nil }
            let shown = texts(in: try XCTUnwrap(harness.window.attachedSheet?.contentView))
            XCTAssertTrue(shown.contains("“feat/hooked” is open, but git reported a problem"), "\(shown)")
            XCTAssertTrue(shown.contains { $0.contains("hook-refused") }, "\(shown)")
            if let sheet = harness.window.attachedSheet { harness.window.endSheet(sheet) }
            harness.waitUntil("no sheet") { harness.window.attachedSheet == nil }

            // `Feat/Case` on origin's tip, asked for as `feat/case`: git
            // refuses it (the filesystem ignores case), and the user's branch
            // stays.
            try UIFlowHarness.git(["config", "--unset", "core.hooksPath"], at: harness.repo)
            try UIFlowHarness.git(["branch", "Feat/Case", ahead], at: harness.repo)
            shell.createWorktreeWorkspace(branch: "feat/case", repoRoot: harness.worktree, agent: nil, profileID: WorkspaceProfile.defaultID)
            harness.waitUntil("git's refusal") { harness.window.attachedSheet != nil }
            XCTAssertEqual(
                try UIFlowHarness.git(["rev-parse", "--verify", "refs/heads/Feat/Case"], at: harness.repo)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                ahead
            )
        }
    }
}
