import AppKit
import XCTest
@testable import Nirux

/// The Project Board in a real window, from "Open Project Board" to its
/// buttons. A fake `gh` client stands in for GitHub (the runners have
/// `gh`): the board calls it off the main thread and hops back, the path
/// where a closure isolated to the main actor trapped in the nightly
/// (#48). git runs for real, in temporary repositories. Clicks are
/// hit-tested by hand, since a window that is never shown (CI) drops
/// events sent with `sendEvent`.
final class ProjectBoardFlowTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-project-board-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = try XCTUnwrap(base.path.realPath)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(atPath: root) }
        super.tearDown()
    }

    /// Answers like `gh`, from whatever thread asks, and records each call.
    final class FakeGitHub: ProjectBoardGitHub, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [FakeGitHubCall] = []
        let openPullRequests: String
        let runs: String

        init(openPullRequests: String, runs: String) {
            self.openPullRequests = openPullRequests
            self.runs = runs
        }

        var calls: [FakeGitHubCall] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        private func record(_ what: String) {
            lock.lock()
            recorded.append(FakeGitHubCall(what: what, onMainThread: Thread.isMainThread))
            lock.unlock()
        }

        func pullRequests(repository: String, state: ProjectBoard.PullRequestList) -> Result<Data, ProjectBoard.FetchError> {
            record("pr \(state) \(repository)")
            return .success(Data((state == .open ? openPullRequests : "[]").utf8))
        }

        func postMergeRuns(repository: String, workflow: String, branch: String) -> Result<Data, ProjectBoard.FetchError> {
            record("run \(repository) \(workflow) \(branch)")
            return .success(Data(runs.utf8))
        }
    }

    private static let pullRequests = """
    [
      {"number": 12, "state": "OPEN", "headRefName": "feat/login", "headRefOid": "\(String(repeating: "a", count: 40))",
       "headRepository": {"name": "widgets"}, "headRepositoryOwner": {"login": "acme"}, "baseRefName": "main",
       "isDraft": false, "mergeable": "MERGEABLE", "url": "https://github.com/acme/widgets/pull/12",
       "statusCheckRollup": [{"__typename": "CheckRun", "name": "test", "workflowName": "Tests",
                              "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": "2026-09-27T23:05:04Z"}]},
      {"number": 13, "state": "OPEN", "headRefName": "fix/remote", "headRefOid": "\(String(repeating: "b", count: 40))",
       "headRepository": {"name": "widgets"}, "headRepositoryOwner": {"login": "acme"}, "baseRefName": "main",
       "isDraft": true, "mergeable": "UNKNOWN", "url": "https://github.com/acme/widgets/pull/13",
       "statusCheckRollup": []}
    ]
    """

    @MainActor
    private func makeClient() -> FakeGitHub {
        FakeGitHub(openPullRequests: Self.pullRequests, runs: ProjectBoardGitHubTests.postMergeRuns)
    }

    // MARK: - Flows

    @MainActor
    func testTheBoardOpensReadsOffTheMainThreadAndRunsItsButtons() throws {
        let client = makeClient()
        try withShell(client: client) { shell, space in
            let repo = root + "/widgets"
            try BoardConfigSuggestionsTests.makeRepository(at: repo, remote: "https://github.com/acme/widgets.git")
            let login = root + "/widgets.feat-login"
            let scratch = root + "/widgets.scratch"
            try git(["worktree", "add", "-q", "-b", "feat/login", login], at: repo)
            try git(["worktree", "add", "-q", "-b", "scratch", scratch], at: repo)
            // Pushed elsewhere than GitHub: its clean-up check stops before gh.
            try git(["remote", "add", "local", root + "/elsewhere.git"], at: repo)
            try git(["config", "branch.scratch.pushRemote", "local"], at: repo)
            try writeConfig(for: space, workflow: "nightly.yml")

            shell.addWorkspace(title: "widgets", cwd: repo, profileID: space.id)
            shell.addWorkspace(title: "login", cwd: login, profileID: space.id)
            try select("widgets", in: shell)

            try runPaletteAction("Open Project Board", in: shell)
            let location = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id))
            XCTAssertTrue(location.workspace === shell.activeWorkspace)
            XCTAssertTrue(location.column === shell.activeWorkspace?.columns[location.workspace.focusedIndex],
                          "the board opens next to the focused column, focused")
            let board = location.board
            try waitUntil("the pull requests are read") { board.view.statusLabel.stringValue.hasPrefix("Updated") }
            try waitUntil("the post-merge run is read") { board.view.runLabel.stringValue.contains("success") }
            try waitUntil("the worktrees are listed") { !board.view.rowViews.isEmpty }

            XCTAssertEqual(board.view.repositoryLabel.stringValue, "acme/widgets")
            XCTAssertEqual(board.view.projectPopup.titleOfSelectedItem, "Board")
            XCTAssertTrue(board.view.runLabel.stringValue.hasPrefix("nightly: success "))
            XCTAssertTrue(board.view.runLabel.stringValue.hasSuffix(", 43a9503"))
            XCTAssertEqual(board.view.rowViews.map(\.row.name), ["widgets", "login", "fix/remote"])
            let loginRow = try row("login", in: board)
            XCTAssertEqual(loginRow.pullRequest.stringValue, "#12 open")
            XCTAssertEqual(loginRow.checks.stringValue, "test ✓")
            XCTAssertEqual(loginRow.agent.stringValue, "—", "a shell, no agent")
            XCTAssertEqual(try row("fix/remote", in: board).pullRequest.stringValue, "#13 draft")
            XCTAssertEqual(board.view.otherWorktreesToggle?.title, "▸ Other worktrees (1)")

            XCTAssertFalse(client.calls.isEmpty)
            XCTAssertFalse(client.calls.contains(where: \.onMainThread), "gh never runs on the main thread")
            XCTAssertEqual(Set(client.calls.map(\.what)), [
                "pr open acme/widgets", "pr merged acme/widgets", "run acme/widgets nightly.yml main"
            ])

            // Refresh reads again, now.
            dropWorkspaceSnapshots(shell)
            let reads = client.calls.filter { $0.what == "pr open acme/widgets" }.count
            try click(board.view.refreshButton)
            try waitUntil("Refresh reads the pull requests again") {
                client.calls.filter { $0.what == "pr open acme/widgets" }.count > reads
            }

            // Focus goes to the row's workspace.
            try click(try XCTUnwrap(loginRow.actions.first { $0.title == "Focus" }))
            XCTAssertEqual(shell.activeWorkspace?.title, "login")

            // "Open Project Board" again, from another workspace of the
            // project, brings the board back rather than opening another.
            try runPaletteAction("Open Project Board", in: shell)
            XCTAssertEqual(shell.activeWorkspace?.title, "widgets")
            XCTAssertEqual(shell.projectBoardLocations.count, 1)
            XCTAssertTrue(shell.activeWorkspace?.columns[shell.activeWorkspace?.focusedIndex ?? -1] === location.column)

            // Clean Up on a worktree no workspace is open in: the flow of
            // "Clean Up Worktree…", by folder.
            try click(try XCTUnwrap(board.view.otherWorktreesToggle))
            XCTAssertEqual(board.view.otherWorktreesToggle?.title, "▾ Other worktrees (1)")
            let scratchRow = try row("scratch", in: board)
            XCTAssertEqual(scratchRow.actions.map(\.title), ["Open", "Clean Up…"])
            var checked: WorktreeCleanupCandidate?
            shell.worktreeCleanupPresenter = { checked = $0 }
            try click(try XCTUnwrap(scratchRow.actions.last))
            try waitUntil("the worktree is checked") { checked != nil }
            let candidate = try XCTUnwrap(checked)
            XCTAssertEqual(NiruxShellView.comparablePath(candidate.path), NiruxShellView.comparablePath(scratch))
            XCTAssertEqual(candidate.workspaces, [])
            XCTAssertEqual(candidate.report?.worktree.branch, "scratch")
            guard case .blocked(let problems) = candidate.availability else {
                return XCTFail("\(candidate.availability)")
            }
            // Stopped before gh either way: not pushed to GitHub, or no gh.
            XCTAssertTrue(problems.contains { $0.contains("pushed to a GitHub remote") || $0.contains("(gh) isn") },
                          "\(problems)")
            XCTAssertTrue(shell.worktreeCleanupsInFlight.isEmpty)
        }
    }

    /// No repository yet: the board asks for one and calls no gh. Saving
    /// Board Settings reloads it.
    @MainActor
    func testABoardWithoutRepositoryOpensBoardSettingsThenReadsOnceSaved() throws {
        let client = makeClient()
        try withShell(client: client) { shell, space in
            let repo = root + "/widgets"
            try BoardConfigSuggestionsTests.makeRepository(at: repo, remote: "https://github.com/acme/widgets.git")
            shell.addWorkspace(title: "widgets", cwd: repo, profileID: space.id)

            try runPaletteAction("Open Project Board", in: shell)
            let board = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id)?.board)
            try waitUntil("Board Settings opens") { shell.boardSettingsPanel?.panel != nil }
            let form = try XCTUnwrap(shell.boardSettingsPanel)
            XCTAssertEqual(form.spaceID, space.id)
            guard case .message(let message)? = board.view.content?.body else { return XCTFail("no message") }
            XCTAssertTrue(message.contains("Board Settings"), message)
            XCTAssertEqual(client.calls, [], "no gh without a repository")

            XCTAssertEqual(form.repositoryField.stringValue, "acme/widgets")
            try click(form.saveButton)
            XCTAssertNil(shell.boardSettingsPanel)
            try waitUntil("the saved config is read, then the pull requests") {
                board.view.statusLabel.stringValue.hasPrefix("Updated") && !board.view.rowViews.isEmpty
            }
            XCTAssertEqual(board.view.rowViews.map(\.row.name), ["widgets", "feat/login", "fix/remote"],
                           "no worktree for either pull request")
            XCTAssertFalse(client.calls.contains { $0.what.hasPrefix("run") }, "no post-merge workflow chosen yet")
        }
    }

    /// A saved board.json reloads the board, and nothing is read with the
    /// config it replaces, even when a status refresh comes in between.
    @MainActor
    func testASavedConfigIsReadBeforeAnythingElse() throws {
        let client = makeClient()
        try withShell(client: client) { shell, space in
            try writeConfig(for: space, workflow: "ci.yml")
            shell.addWorkspace(title: "widgets", cwd: root, profileID: space.id)
            try runPaletteAction("Open Project Board", in: shell)
            try waitUntil("the first post-merge run is read") {
                client.calls.contains { $0.what == "run acme/widgets ci.yml main" }
            }
            try waitUntil("every first read is back") {
                shell.projectBoardLocation(projectID: space.id)?.board.schedule.inFlight.isEmpty == true
            }
            let before = client.calls.count

            try writeConfig(for: space, workflow: "nightly.yml")
            // The save's reload is on its way; a status refresh lands while
            // board.json is being read, when every read is due.
            let board = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id)?.board)
            board.reload()
            shell.updateSidebar()
            try waitUntil("the new workflow's run is read") {
                client.calls.contains { $0.what == "run acme/widgets nightly.yml main" }
            }
            XCTAssertFalse(client.calls[before...].contains { $0.what.contains("ci.yml") },
                           "\(client.calls[before...].map(\.what))")
        }
    }

    /// Switching project from the header: one that has a board brings it to
    /// the front; another one is shown in place. A deleted project says so.
    @MainActor
    func testTheProjectMenuSwitchesOrFocusesAndADeletedProjectSaysSo() throws {
        let client = makeClient()
        try withShell(client: client) { shell, space in
            let other = shell.workspaceStore.createProfile(named: "Gadgets")
            let third = shell.workspaceStore.createProfile(named: "Tools")
            // Configured: no Board Settings sheet opens by itself.
            try writeConfig(for: space, workflow: "nightly.yml")
            try writeConfig(for: other, workflow: "nightly.yml")
            shell.addWorkspace(title: "gadgets", cwd: root, profileID: other.id)
            try runPaletteAction("Open Project Board", in: shell)
            let gadgetsBoard = try XCTUnwrap(shell.projectBoardLocation(projectID: other.id))

            shell.addWorkspace(title: "widgets", cwd: root, profileID: space.id)
            try runPaletteAction("Open Project Board", in: shell)
            let widgetsBoard = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id))
            XCTAssertEqual(shell.projectBoardLocations.count, 2)

            widgetsBoard.board.view.chooseProject(id: other.id)
            XCTAssertTrue(shell.activeWorkspace === gadgetsBoard.workspace, "that project's board comes to the front")
            XCTAssertEqual(widgetsBoard.board.projectID, space.id)
            XCTAssertEqual(widgetsBoard.board.view.projectPopup.titleOfSelectedItem, "Board", "its menu shows its project again")

            widgetsBoard.board.view.chooseProject(id: third.id)
            XCTAssertEqual(widgetsBoard.board.projectID, third.id)
            XCTAssertEqual(widgetsBoard.board.view.projectPopup.titleOfSelectedItem, "Tools")

            _ = shell.workspaceStore.deleteProfile(id: third.id)
            shell.updateSidebar()
            shell.renderProjectBoard(widgetsBoard.board)
            XCTAssertEqual(widgetsBoard.board.view.projectPopup.titleOfSelectedItem, "Deleted project")
            guard case .message(let message)? = widgetsBoard.board.view.content?.body else { return XCTFail("no message") }
            XCTAssertTrue(message.contains("deleted"), message)
        }
    }

    // MARK: - Persistence

    @MainActor
    func testTheBoardIsSavedAndRestoredOncePerProject() throws {
        let client = makeClient()
        var state: PersistedState?
        var spaceID = ""
        try withShell(client: client) { shell, space in
            spaceID = space.id
            // Configured: no Board Settings request outlives the test.
            try writeConfig(for: space, workflow: "nightly.yml")
            shell.addWorkspace(title: "widgets", cwd: root, profileID: space.id)
            try runPaletteAction("Open Project Board", in: shell)
            state = shell.persistedState()
        }
        var saved = try XCTUnwrap(state)
        let index = try XCTUnwrap(saved.workspaces.firstIndex { $0.title == "widgets" })
        let column = try XCTUnwrap(saved.workspaces[index].columns.first { $0.columnType == .projectBoard })
        XCTAssertEqual(column.boardProjectID, spaceID)
        XCTAssertEqual(column.cwd, root, "an older build opens a terminal in the workspace's folder")
        // A hand-edited state with a second board for the project.
        saved.workspaces[index].columns.append(column)

        try withShell(client: client, restoring: saved) { shell, _ in
            XCTAssertEqual(shell.projectBoardLocations.count, 1)
            let workspace = try XCTUnwrap(shell.workspaces.first { $0.title == "widgets" })
            XCTAssertEqual(workspace.columns.filter(\.isProjectBoard).count, 1)
            XCTAssertEqual(workspace.columns.count, 3, "the second board came back as a terminal")
            XCTAssertNotNil(workspace.columns.last?.pty)
            XCTAssertEqual(shell.projectBoardLocation(projectID: spaceID)?.board.projectID, spaceID)
        }
    }

    // MARK: - Helpers

    @MainActor
    private func withShell(
        client: FakeGitHub,
        restoring state: PersistedState? = nil,
        _ body: (NiruxShellView, WorkspaceProfile) throws -> Void
    ) throws {
        let stateDirectory = root + "/state"
        try FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", stateDirectory, 1)
        defer {
            if let previous { setenv("NIRUX_STATE_DIR", previous, 1) } else { unsetenv("NIRUX_STATE_DIR") }
        }
        _ = NSApplication.shared
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        shell.stopHeartbeat()
        shell.projectBoardClient = client
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
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
        if let state {
            XCTAssertTrue(Persistence.save(state))
            shell.restoreState()
            try body(shell, shell.profiles[0])
        } else {
            // Its own space: the first workspace, in the home folder, stays out.
            try body(shell, shell.workspaceStore.createProfile(named: "Board"))
        }
    }

    private func writeConfig(for space: WorkspaceProfile, workflow: String) throws {
        let store = try XCTUnwrap(BoardConfigStore(spaceID: space.id))
        let config = BoardConfig(
            repository: "acme/widgets", baseBranch: "main", requiredChecks: ["test"],
            postMergeWorkflow: .workflow(workflow)
        )
        if case .failure(let error) = store.save(config) { XCTFail(error.message) }
    }

    @discardableResult
    private func git(_ arguments: [String], at directory: String) throws -> String {
        try BoardConfigSuggestionsTests.git(arguments, at: directory)
    }

    /// `addWorkspace` slides a picture of the previous workspace away over
    /// the new one; the animation that removes it doesn't run in a window
    /// that isn't shown, and the picture would take the clicks.
    @MainActor
    private func dropWorkspaceSnapshots(_ shell: NiruxShellView) {
        shell.viewport.subviews.filter { $0 is NSImageView }.forEach { $0.removeFromSuperview() }
    }

    @MainActor
    private func select(_ title: String, in shell: NiruxShellView) throws {
        shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0.title == title }))
    }

    @MainActor
    private func runPaletteAction(_ title: String, in shell: NiruxShellView) throws {
        let actions = shell.columnPaletteActions() + shell.agentPaletteActions() + shell.workspacePaletteActions()
        try XCTUnwrap(actions.first { $0.title == title }, "no “\(title)” in the palette").action()
    }

    @MainActor
    private func row(_ name: String, in board: ProjectBoardController) throws -> ProjectBoardView.RowViews {
        try XCTUnwrap(board.view.rowViews.first { $0.row.name == name }, "no row “\(name)”")
    }

    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 30, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), "timed out: \(what)")
    }

    /// The button must be what the window hit-tests under the pointer, as
    /// AppKit finds it for a real click; then `performClick`, since a
    /// button's own tracking never ends in a window that isn't shown.
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

struct FakeGitHubCall: Equatable {
    let what: String
    let onMainThread: Bool
}
