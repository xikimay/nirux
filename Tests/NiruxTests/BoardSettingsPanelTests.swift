import AppKit
import XCTest
@testable import Nirux

/// "Board Settings…" from a space's menu to board.json: what the form shows,
/// what Save writes, and what it refuses. Clicks are hit-tested by hand,
/// since a window that is never shown (CI) drops events sent with
/// `sendEvent`.
final class BoardSettingsPanelTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-board-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = try XCTUnwrap(base.path.realPath)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(atPath: root) }
        super.tearDown()
    }

    // MARK: - Opening

    @MainActor
    func testTheSpaceMenuOpensTheFormFilledWithSuggestionsAndWritesNothing() throws {
        try withShell { shell, space in
            let repo = root + "/widgets"
            try BoardConfigSuggestionsTests.makeRepository(
                at: repo, remote: "https://github.com/acme/widgets.git", workflows: ["nightly.yml", "tests.yml"]
            )
            shell.addWorkspace(title: "widgets", cwd: repo, profileID: space.id)

            let titles = try spaceMenu(shell, space).items.map(\.title)
            let briefIndex = try XCTUnwrap(titles.firstIndex(of: "Edit Space Brief…"))
            XCTAssertEqual(titles[briefIndex + 1], "Board Settings…")

            let form = try open(shell, space)
            XCTAssertEqual(form.repositoryField.stringValue, "acme/widgets")
            XCTAssertEqual(form.baseBranchField.stringValue, "main")
            XCTAssertEqual(form.checksView.string, "test")
            XCTAssertEqual(form.checksTimeoutField.stringValue, "30")
            XCTAssertEqual(form.postMergeTimeoutField.stringValue, "30")
            XCTAssertEqual(form.mergeMethodPopup.titleOfSelectedItem, "Merge commit")
            XCTAssertEqual(form.workflowChoices, [.unset, .file("nightly.yml"), .file("tests.yml"), nil, .noWorkflow, .other])
            XCTAssertEqual(form.selectedWorkflowChoice, .unset, "never preselected")
            XCTAssertFalse(form.workflowNameField.isEnabled)
            XCTAssertTrue(form.saveButton.isEnabled)
            XCTAssertNil(form.bannerLabel.superview, "no banner")
            XCTAssertFalse(FileManager.default.fileExists(atPath: try store(space).fileURL.path))

            try click(form.cancelButton)
            XCTAssertNil(shell.boardSettingsPanel)
            XCTAssertFalse(FileManager.default.fileExists(atPath: try store(space).fileURL.path))
        }
    }

    // MARK: - Saving

    @MainActor
    func testSaveWritesWhatWasEntered() throws {
        try withShell { shell, space in
            let repo = root + "/widgets"
            try BoardConfigSuggestionsTests.makeRepository(
                at: repo, remote: "git@github.com:acme/widgets.git", workflows: ["nightly.yml"]
            )
            shell.addWorkspace(title: "widgets", cwd: repo, profileID: space.id)
            let form = try open(shell, space)

            form.checksView.string = "test\n\n  CodeQL / Analyze (swift)  \ntest\n"
            try choose(.file("nightly.yml"), in: form)
            form.mergeMethodPopup.selectItem(withTitle: "Squash")
            form.checksTimeoutField.stringValue = " 45 "
            form.postMergeTimeoutField.stringValue = "20"
            try click(form.saveButton)

            XCTAssertNil(shell.boardSettingsPanel, "Save closes the form")
            let loaded = try store(space).load()
            XCTAssertEqual(loaded.status, .loaded)
            XCTAssertEqual(loaded.config, BoardConfig(
                repository: "acme/widgets",
                baseBranch: "main",
                requiredChecks: ["test", "CodeQL / Analyze (swift)"],
                postMergeWorkflow: .workflow("nightly.yml"),
                mergeMethod: .squash,
                checksTimeoutMinutes: 45,
                postMergeTimeoutMinutes: 20
            ))
            XCTAssertEqual(loaded.queueStartProblems, [])
        }
    }

    @MainActor
    func testAWorkflowLeftUnchosenIsSavedUnset() throws {
        try withShell { shell, space in
            let repo = root + "/widgets"
            try BoardConfigSuggestionsTests.makeRepository(
                at: repo, remote: "https://github.com/acme/widgets", workflows: ["nightly.yml"]
            )
            shell.addWorkspace(title: "widgets", cwd: repo, profileID: space.id)
            let form = try open(shell, space)

            try click(form.saveButton)

            XCTAssertNil(shell.boardSettingsPanel)
            let loaded = try store(space).load()
            XCTAssertEqual(loaded.config?.postMergeWorkflow, .unset)
            XCTAssertFalse(loaded.canStartQueue)
            let text = try String(contentsOf: try store(space).fileURL, encoding: .utf8)
            XCTAssertFalse(text.contains("postMergeWorkflow"))
        }
    }

    /// No checkout: the name is typed. None is a choice of its own.
    @MainActor
    func testWithoutACheckoutTheWorkflowIsTypedOrNone() throws {
        try withShell { shell, space in
            let plain = root + "/plain"
            try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
            shell.addWorkspace(title: "plain", cwd: plain, profileID: space.id)
            let form = try open(shell, space)
            XCTAssertEqual(form.repositoryField.stringValue, "")
            XCTAssertEqual(form.baseBranchField.stringValue, "")
            XCTAssertEqual(form.workflowChoices, [.unset, nil, .noWorkflow, .other])

            form.repositoryField.stringValue = "acme/widgets"
            form.baseBranchField.stringValue = "develop"
            try choose(.other, in: form)
            XCTAssertTrue(form.workflowNameField.isEnabled)
            form.workflowNameField.stringValue = "release.yaml"
            try click(form.saveButton)
            XCTAssertEqual(try store(space).load().config?.postMergeWorkflow, .workflow("release.yaml"))

            let reopened = try open(shell, space)
            XCTAssertEqual(reopened.selectedWorkflowChoice, .other)
            XCTAssertEqual(reopened.workflowNameField.stringValue, "release.yaml")
            XCTAssertEqual(reopened.repositoryField.stringValue, "acme/widgets", "the saved value")
            try choose(.noWorkflow, in: reopened)
            XCTAssertFalse(reopened.workflowNameField.isEnabled)
            try click(reopened.saveButton)
            XCTAssertEqual(try store(space).load().config?.postMergeWorkflow, .noWorkflow)
        }
    }

    @MainActor
    func testInvalidValuesAreRefusedAndNothingIsWritten() throws {
        try withShell { shell, space in
            let form = try open(shell, space)
            form.repositoryField.stringValue = "acme widgets"
            form.baseBranchField.stringValue = ""
            form.checksView.string = "\n  \n"
            form.checksTimeoutField.stringValue = "0"
            form.postMergeTimeoutField.stringValue = "soon"

            try click(form.saveButton)

            XCTAssertTrue(shell.boardSettingsPanel === form, "the form stays open")
            XCTAssertFalse(form.errorLabel.isHidden)
            let lines = form.errorLabel.stringValue.components(separatedBy: "\n")
            XCTAssertEqual(lines.count, 4, form.errorLabel.stringValue)
            XCTAssertTrue(lines[0].contains("owner/name"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: try store(space).fileURL.path))
            try click(form.cancelButton)
        }
    }

    @MainActor
    func testAPastedGitHubURLIsSavedAsOwnerAndName() throws {
        try withShell { shell, space in
            let form = try open(shell, space)
            form.repositoryField.stringValue = "https://github.com/Acme/Widgets.git"
            form.baseBranchField.stringValue = "main"
            try click(form.saveButton)

            XCTAssertNil(shell.boardSettingsPanel)
            XCTAssertEqual(try store(space).load().config?.repository, "Acme/Widgets")
        }
    }

    /// Another Nirux saved the file while the form was open.
    @MainActor
    func testAFileSavedElsewhereMeanwhileIsNotOverwritten() throws {
        try withShell { shell, space in
            let form = try open(shell, space)
            form.repositoryField.stringValue = "acme/mine"
            form.baseBranchField.stringValue = "main"
            let theirs = BoardConfig(repository: "acme/theirs", baseBranch: "main")
            XCTAssertNoThrow(try store(space).save(theirs).get())

            try click(form.saveButton)

            XCTAssertTrue(shell.boardSettingsPanel === form)
            XCTAssertTrue(form.errorLabel.stringValue.contains("changed since"), form.errorLabel.stringValue)
            XCTAssertEqual(try store(space).load().config, theirs)
            try click(form.cancelButton)
        }
    }

    /// On a short window the fields scroll and the buttons stay in view;
    /// every problem shows between them.
    @MainActor
    func testTheSheetFitsTheWindowAndShowsEveryProblem() throws {
        try withShell(height: 560) { shell, space in
            let form = try open(shell, space)
            let panel = try XCTUnwrap(form.panel)
            let window = try XCTUnwrap(shell.window)
            XCTAssertLessThanOrEqual(panel.frame.height, window.contentLayoutRect.height)
            let content = try XCTUnwrap(panel.contentView)
            XCTAssertTrue(content.bounds.contains(form.saveButton.frame))

            form.repositoryField.stringValue = String(repeating: "not a repository ", count: 12)
            form.baseBranchField.stringValue = ""
            form.checksView.string = ""
            form.checksTimeoutField.stringValue = "0"
            try choose(.other, in: form)
            form.workflowNameField.stringValue = "nightly"
            try click(form.saveButton)

            XCTAssertEqual(form.errorLabel.stringValue.components(separatedBy: "\n").count, 5)
            XCTAssertTrue(content.bounds.contains(form.errorLabel.frame))
            XCTAssertGreaterThanOrEqual(
                form.errorLabel.frame.height,
                form.errorLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: form.errorLabel.frame.width,
                                                                  height: .greatestFiniteMagnitude)).height ?? 0
            )
            XCTAssertFalse(form.errorLabel.frame.intersects(form.saveButton.frame))
            XCTAssertTrue(content.bounds.contains(form.saveButton.frame))
            try click(form.cancelButton)
        }
    }

    /// Opened while the delete confirmation was up: the space goes, the
    /// form with it.
    @MainActor
    func testDeletingTheSpaceClosesItsForm() throws {
        try withShell { shell, space in
            _ = try open(shell, space)
            shell.deleteSpace(profileID: space.id)
            XCTAssertNil(shell.boardSettingsPanel)
        }
    }

    /// Save is the default button, which answers Return in the fields; in
    /// the checks list Return adds a line, so the sheet never hands it to
    /// Save as a key equivalent. (A window that is never shown doesn't press
    /// its default button, so the rule is checked rather than a key press.)
    @MainActor
    func testReturnInTheChecksListIsLeftToTheList() throws {
        try withShell { shell, space in
            let form = try open(shell, space)
            let panel = try XCTUnwrap(form.panel as? BoardSettingsSheet)
            XCTAssertTrue(panel.defaultButtonCell === form.saveButton.cell, "Save is the default button")
            XCTAssertTrue(panel.multilineView === form.checksView)
            // Read here: the nested function's XCTUnwrap autoclosure isn't
            // on the main actor for CI's Swift 6.1.
            let windowNumber = panel.windowNumber
            func key(_ characters: String, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
                try XCTUnwrap(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: keyCode
                ))
            }
            let rule = BoardSettingsSheet.leavesToTextView
            XCTAssertTrue(rule(try key("\r", 36), form.checksView, form.checksView))
            XCTAssertTrue(rule(try key("\u{3}", 76), form.checksView, form.checksView))
            XCTAssertFalse(rule(try key("\r", 36), form.baseBranchField, form.checksView), "a field saves")
            XCTAssertFalse(rule(try key("\r", 36, .command), form.checksView, form.checksView))
            XCTAssertFalse(rule(try key("a", 0), form.checksView, form.checksView))

            panel.makeFirstResponder(form.checksView)
            XCTAssertFalse(panel.performKeyEquivalent(with: try key("\r", 36)))
            XCTAssertTrue(shell.boardSettingsPanel === form, "not saved")
            try click(form.cancelButton)
        }
    }

    // MARK: - Files this build can't write

    @MainActor
    func testANewerFileIsShownReadOnlyWithSaveDisabled() throws {
        try withShell { shell, space in
            let original = """
            {"schemaVersion": 2, "repository": "acme/widgets", "baseBranch": "main", "postMergeWorkflow": "none"}
            """
            try write(original, for: space)
            let form = try open(shell, space)

            XCTAssertNotNil(form.bannerLabel.superview)
            XCTAssertTrue(form.bannerLabel.stringValue.contains("newer Nirux"), form.bannerLabel.stringValue)
            XCTAssertEqual(form.repositoryField.stringValue, "acme/widgets")
            XCTAssertEqual(form.selectedWorkflowChoice, .noWorkflow)
            XCTAssertFalse(form.saveButton.isEnabled)
            XCTAssertFalse(form.repositoryField.isEditable)
            XCTAssertFalse(form.checksView.isEditable)
            XCTAssertFalse(form.workflowPopup.isEnabled)

            try click(form.saveButton)
            form.saveAction(nil)
            XCTAssertTrue(shell.boardSettingsPanel === form)
            XCTAssertEqual(try String(contentsOf: try store(space).fileURL, encoding: .utf8), original)
            try click(form.cancelButton)
        }
    }

    /// The disabled fields show the file, never suggestions it doesn't hold.
    @MainActor
    func testAReadOnlyFileShowsOnlyWhatItHolds() throws {
        try withShell { shell, space in
            let repo = root + "/widgets"
            try BoardConfigSuggestionsTests.makeRepository(at: repo, remote: "https://github.com/acme/widgets")
            shell.addWorkspace(title: "widgets", cwd: repo, profileID: space.id)
            try write(#"{"requiredChecks": ["build"], "reviewers": 2}"#, for: space)

            let form = try open(shell, space)

            XCTAssertTrue(form.bannerLabel.stringValue.contains("reviewers"), form.bannerLabel.stringValue)
            XCTAssertEqual(form.repositoryField.stringValue, "")
            XCTAssertEqual(form.baseBranchField.stringValue, "")
            XCTAssertEqual(form.checksView.string, "build")
            XCTAssertEqual(form.cancelButton.title, "Close")
            try click(form.cancelButton)
        }
    }

    @MainActor
    func testAnUnsupportedMergeMethodIsShownAsItIs() throws {
        try withShell { shell, space in
            try write(#"{"repository": "acme/widgets", "mergeMethod": "rebase"}"#, for: space)
            let form = try open(shell, space)
            XCTAssertEqual(form.mergeMethodPopup.titleOfSelectedItem, "rebase (not supported)")
            XCTAssertFalse(form.mergeMethodPopup.isEnabled)
            XCTAssertFalse(form.saveButton.isEnabled)
            try click(form.cancelButton)
        }
    }

    @MainActor
    func testAnUnreadableFileIsKeptAsideWhenSaved() throws {
        try withShell { shell, space in
            try write("{ not json", for: space)
            let form = try open(shell, space)
            XCTAssertTrue(form.bannerLabel.stringValue.contains("board.corrupt"), form.bannerLabel.stringValue)
            XCTAssertTrue(form.saveButton.isEnabled)

            form.repositoryField.stringValue = "acme/widgets"
            form.baseBranchField.stringValue = "main"
            try click(form.saveButton)

            XCTAssertNil(shell.boardSettingsPanel)
            let folder = try store(space).fileURL.deletingLastPathComponent()
            let copies = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                .filter { $0.hasPrefix("board.corrupt.") }
            XCTAssertEqual(copies.count, 1)
            guard copies.count == 1 else { return }
            XCTAssertEqual(
                try String(contentsOf: folder.appendingPathComponent(copies[0]), encoding: .utf8), "{ not json"
            )
            XCTAssertEqual(try store(space).load().config?.repository, "acme/widgets")
        }
    }

    // MARK: - Helpers

    @MainActor
    private func withShell(height: CGFloat = 800, _ body: (NiruxShellView, WorkspaceProfile) throws -> Void) throws {
        let stateDirectory = root + "/state"
        try FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true)
        let previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", stateDirectory, 1)
        defer {
            if let previousStateDirectory {
                setenv("NIRUX_STATE_DIR", previousStateDirectory, 1)
            } else {
                unsetenv("NIRUX_STATE_DIR")
            }
        }

        _ = NSApplication.shared
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: height))
        shell.stopHeartbeat()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = shell
        defer {
            shell.boardSettingsPanel?.dismiss()
            window.close()
        }
        // Its own space: the first workspace, in the home folder, stays out.
        let space = shell.workspaceStore.createProfile(named: "Board")
        try body(shell, space)
    }

    @MainActor
    private func store(_ space: WorkspaceProfile) throws -> BoardConfigStore {
        try XCTUnwrap(BoardConfigStore(spaceID: space.id))
    }

    @MainActor
    private func write(_ text: String, for space: WorkspaceProfile) throws {
        let url = try store(space).fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @MainActor
    private func spaceMenu(_ shell: NiruxShellView, _ space: WorkspaceProfile) throws -> NSMenu {
        let menu = NSMenu()
        shell.sidebar.addSpaceManagementItems(to: menu, for: ProfileInfo(
            id: space.id, name: space.name, colorHex: space.colorHex,
            isActive: false, workspaceCount: 1, hasAttention: false
        ))
        return menu
    }

    /// Picks "Board Settings…" in the space's menu and waits for the form.
    @MainActor
    private func open(_ shell: NiruxShellView, _ space: WorkspaceProfile) throws -> BoardSettingsPanel {
        let menu = try spaceMenu(shell, space)
        let index = menu.indexOfItem(withTitle: "Board Settings…")
        XCTAssertGreaterThanOrEqual(index, 0)
        menu.performActionForItem(at: index)
        let deadline = Date().addingTimeInterval(30)
        while shell.boardSettingsPanel?.panel == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let form = try XCTUnwrap(shell.boardSettingsPanel)
        XCTAssertNotNil(form.panel)
        return form
    }

    /// As a pick in the pop-up menu: selects the item and sends its action.
    @MainActor
    private func choose(_ choice: BoardSettingsPanel.WorkflowChoice, in form: BoardSettingsPanel) throws {
        let index = try XCTUnwrap(form.workflowChoices.firstIndex(of: choice))
        form.workflowPopup.selectItem(at: index)
        form.workflowPopup.sendAction(form.workflowPopup.action, to: form.workflowPopup.target)
    }

    /// The button must be what the window hit-tests under the pointer, as
    /// AppKit finds it for a real click. The click itself is `performClick`:
    /// a button's `mouseDown` tracks the mouse until a mouse-up that a
    /// window never shown (CI) doesn't deliver, so it would never fire.
    @MainActor
    private func click(_ button: NSButton) throws {
        let window = try XCTUnwrap(button.window)
        let contentView = try XCTUnwrap(window.contentView)
        let frameView = try XCTUnwrap(contentView.superview)
        let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let hitView = try XCTUnwrap(contentView.hitTest(frameView.convert(location, from: nil)))
        XCTAssertTrue(hitView === button, "\(hitView) is under the pointer, not \(button.title)")
        (hitView as? NSButton)?.performClick(nil)
    }
}
