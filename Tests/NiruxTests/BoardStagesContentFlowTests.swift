import AppKit
import XCTest
@testable import Nirux

/// What the Board as stages shows of a space, built from what the Board
/// read (docs/design/board-stages.md, sections 5 and 6): a real shell, git
/// for real in temporary repositories, a fake `gh` (`ProjectBoardFlowTests`).
/// The column still shows the table; the content is asked for.
final class BoardStagesContentFlowTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-board-stages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = try XCTUnwrap(base.path.realPath)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(atPath: root) }
        super.tearDown()
    }

    private static let pullRequests = """
    [
      {"number": 12, "state": "OPEN", "headRefName": "feat/login", "headRefOid": "\(String(repeating: "a", count: 40))",
       "headRepository": {"name": "widgets"}, "headRepositoryOwner": {"login": "acme"}, "baseRefName": "main",
       "isDraft": false, "mergeable": "MERGEABLE", "url": "https://github.com/acme/widgets/pull/12", "title": "Sign in",
       "statusCheckRollup": [{"__typename": "CheckRun", "name": "test", "workflowName": "Tests",
                              "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": "2026-09-27T23:05:04Z"}]},
      {"number": 13, "state": "OPEN", "headRefName": "fix/remote", "headRefOid": "\(String(repeating: "b", count: 40))",
       "headRepository": {"name": "widgets"}, "headRepositoryOwner": {"login": "acme"}, "baseRefName": "main",
       "isDraft": true, "mergeable": "UNKNOWN", "url": "https://github.com/acme/widgets/pull/13", "title": "Remote fix",
       "statusCheckRollup": []}
    ]
    """

    private static let merged = """
    [
      {"number": 40, "state": "MERGED", "headRefName": "old/work", "headRefOid": "\(String(repeating: "c", count: 40))",
       "headRepository": {"name": "widgets"}, "headRepositoryOwner": {"login": "acme"}, "baseRefName": "main",
       "isDraft": false, "mergeable": "UNKNOWN", "url": "https://github.com/acme/widgets/pull/40", "title": "Old work",
       "mergedAt": "2026-11-10T10:00:00Z", "statusCheckRollup": []}
    ]
    """

    @MainActor
    func testTheContentIsWhatTheTableListsAsStages() throws {
        let client = ProjectBoardFlowTests.FakeGitHub(
            openPullRequests: Self.pullRequests, mergedPullRequests: Self.merged, runs: ProjectBoardGitHubTests.postMergeRuns
        )
        try withShell(client: client) { shell, space in
            let repo = root + "/widgets"
            try BoardConfigSuggestionsTests.makeRepository(at: repo, remote: "https://github.com/acme/widgets.git")
            let login = root + "/widgets.feat-login", scratch = root + "/widgets.scratch", notes = root + "/widgets.lead-notes"
            try git(["worktree", "add", "-q", "-b", "feat/login", login], at: repo)
            try git(["worktree", "add", "-q", "-b", "scratch", scratch], at: repo)
            try git(["worktree", "add", "-q", "-b", "lead/notes", notes], at: repo)
            let gadgets = root + "/gadgets"
            try BoardConfigSuggestionsTests.makeRepository(at: gadgets, remote: "https://github.com/acme/gadgets.git")
            let folder = root + "/release-notes"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try writeConfig(for: space)

            shell.addWorkspace(title: "widgets", cwd: repo, profileID: space.id)
            shell.addWorkspace(title: "login", cwd: login, profileID: space.id)
            shell.addWorkspace(title: "Lead", cwd: notes, profileID: space.id, isLead: true)
            shell.addWorkspace(title: "gadget", cwd: gadgets, profileID: space.id)
            shell.addWorkspace(title: "notes", cwd: folder, profileID: space.id)
            shell.addWorkspace(title: "old", cwd: repo, profileID: space.id)
            try XCTUnwrap(shell.workspaces.first { $0.title == "old" }).isInactive = true
            shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0.title == "widgets" }))
            try runPaletteAction("Open Board", in: shell)
            let board = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id)?.board)
            try waitUntil("the pull requests and the post-merge run are read, the worktrees listed") {
                board.reads.values.first?.openPullRequests != nil && board.reads.values.first?.mergedPullRequests != nil
                    && board.local != nil && !board.view.rowViews.isEmpty
                    && board.view.header.status?.toolTip?.contains("success") == true
            }
            let ids = { (title: String) in shell.workspaces.first { $0.title == title }?.id ?? "" }
            let content = try stages(of: board, in: shell)

            // The space, what it holds (the Lead is no task), its Lead.
            XCTAssertEqual(content.header.name, "Board")
            XCTAssertEqual(content.header.summary, "1 repository · 4 tasks", "the Lead apart, an archived task left out")
            XCTAssertEqual(content.header.lead?.text.hasPrefix("Lead · "), true, content.header.lead?.text ?? "")
            XCTAssertEqual(content.header.lead?.state, .idle, "a Lead with no agent at work")
            XCTAssertNil(content.message)
            XCTAssertEqual(content.runningQueues, [], "no queue runs")
            XCTAssertEqual(content.sections.map(\.id), ["legacy", ProjectBoardController.noRepositoryID, BoardStagesView.Section.otherWorkspacesID])

            // The repository: its name and owner/name, its post-merge pill, its queue at rest, its menu.
            let widgets = try XCTUnwrap(content.sections.first)
            XCTAssertEqual([widgets.title, widgets.detail], ["widgets", "acme/widgets"])
            XCTAssertEqual(widgets.status?.text.hasPrefix("nightly "), true, widgets.status?.text ?? "")
            XCTAssertEqual(widgets.status?.symbol, Theme.Symbol.checksPassed, "the run read: green")
            XCTAssertEqual(widgets.queue?.start?.title.hasPrefix("Start"), true, "Start…, or Start Dry Run… in a build that can't change GitHub")
            XCTAssertEqual(widgets.menu, [.boardSettings, .openMainCheckout(path: repo)])
            // Its tasks in the sidebar's order, the pull request without a task folded, its other worktrees with the Lead's first.
            XCTAssertEqual(widgets.lines.units.flatMap(\.lines).map(\.id), [ids("widgets"), ids("login"), ids("old")])
            XCTAssertEqual(widgets.lines.units.flatMap(\.lines).map(\.pullRequest), ["no PR yet", "#12", "no PR yet"])
            XCTAssertEqual(widgets.lines.withoutTask.flatMap(\.lines).map(\.title), ["Remote fix"])
            XCTAssertEqual(widgets.lines.otherWorktrees.map(\.title), ["Lead · lead/notes", "scratch"])
            XCTAssertEqual(widgets.lines.otherWorktrees.first?.menu.first, .focus(workspaceID: ids("Lead"), columnID: nil))

            // A workspace in no repository is a line there; one in another repository is under Other workspaces.
            let noRepository = try XCTUnwrap(content.sections.first { $0.id == ProjectBoardController.noRepositoryID })
            XCTAssertEqual(noRepository.title, "No repository")
            XCTAssertEqual(noRepository.lines.units.flatMap(\.lines).map(\.id), [ids("notes")])
            XCTAssertNil(noRepository.queue)
            let others = try XCTUnwrap(content.sections.first { $0.id == BoardStagesView.Section.otherWorkspacesID })
            XCTAssertEqual(others.kind, .otherWorkspaces)
            XCTAssertEqual(others.lines.otherWorktrees.map(\.title), ["gadget"])
            XCTAssertEqual(others.lines.otherWorktrees.map(\.path), [gadgets])

            // The order switch, as asked; Start says what the next one takes.
            XCTAssertEqual(try stages(of: board, in: shell, order: .progress).order, .progress)
            shell.addToMergeQueue(12, board: board, section: nil)
            shell.addToMergeQueue(40, board: board, section: nil)
            XCTAssertEqual(try stages(of: board, in: shell).sections[0].queue?.start?.title.hasSuffix(" · 1"), true, "a merged one counts for none")
            // The queues that run keep their lines at the foot, as the table's queue lines name them; none runs here.
            XCTAssertEqual(shell.stagesInputs(of: board, members: [], workspaces: [], readings: [:], order: .sidebar).runningQueues, [])
            var inputs = shell.stagesInputs(of: board, members: [], workspaces: [], readings: [:], order: .sidebar)
            let orphan = BoardStagesView.RunningQueue(id: "orphan", title: "acme/old", status: "Running in another Nirux")
            inputs.runningQueues = [orphan]
            XCTAssertEqual(board.stagesContent(inputs).runningQueues, [orphan])
        }
    }

    /// The table's messages in place of its rows are the stages' in place of
    /// their sections, Board Settings… offered where the settings can fix
    /// them; a deleted space says so.
    @MainActor
    func testTheBoardSaysWhatTheTableSaysInPlaceOfItsRows() throws {
        let client = ProjectBoardFlowTests.FakeGitHub(openPullRequests: "[]", runs: ProjectBoardGitHubTests.postMergeRuns)
        try withShell(client: client) { shell, space in
            let folder = root + "/plain"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            shell.addWorkspace(title: "plain", cwd: folder, profileID: space.id)
            shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0.title == "plain" }))
            // No Board Settings sheet in a test.
            shell.sideEffects.runModal = { _ in .alertSecondButtonReturn }
            try runPaletteAction("Open Board", in: shell)
            let board = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id)?.board)
            try waitUntil("board.json is read") { board.loaded != nil }
            shell.spaceSettings?.close()
            let message = try stages(of: board, in: shell).message
            guard case .message(let table)? = board.view.content?.body else { return XCTFail("the table shows no message") }
            XCTAssertEqual(message?.text, table)
            XCTAssertEqual(message?.text, "Set this space’s repository in Board Settings… to list its branches and pull requests.")
            XCTAssertEqual(message?.offersSettings, true)

            XCTAssertEqual(try stages(of: board, in: shell).header.summary, "1 task", "no repository set: none counted")
            var inputs = shell.stagesInputs(of: board, members: [], workspaces: [], readings: [:], order: .sidebar)
            inputs.space = nil
            XCTAssertEqual(board.stagesContent(inputs).message,
                           BoardStagesView.Message(text: "This space was deleted. Pick another one in the ⋯ menu above."))
            XCTAssertEqual(board.stagesContent(inputs).header.name, "Deleted space")
        }
    }

    /// A repository's pill: what went wrong reading it, or why it has no
    /// saved settings, the reason under the pointer.
    @MainActor
    func testARepositorysPillSaysWhatWentWrongOrThatItHasNoSettings() throws {
        let client = ProjectBoardFlowTests.FakeGitHub(
            openPullRequests: "[]", runs: ProjectBoardGitHubTests.postMergeRuns, failures: ["acme/widgets": .notSignedIn(nil)]
        )
        try withShell(client: client) { shell, space in
            let repo = root + "/widgets"
            try BoardConfigSuggestionsTests.makeRepository(at: repo, remote: "https://github.com/acme/widgets.git")
            try writeConfig(for: space)
            shell.addWorkspace(title: "widgets", cwd: repo, profileID: space.id)
            shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0.title == "widgets" }))
            try runPaletteAction("Open Board", in: shell)
            let board = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id)?.board)
            try waitUntil("the read fails and the worktrees are listed") {
                board.reads.values.first?.errors.isEmpty == false && board.local != nil
            }
            XCTAssertEqual(try stages(of: board, in: shell).sections.map(\.id), ["legacy"], "no No repository, no Other workspaces: none")
            let failed = try XCTUnwrap(try stages(of: board, in: shell).sections.first?.status)
            XCTAssertEqual([failed.text, failed.toolTip], ["GitHub error", ProjectBoard.FetchError.notSignedIn(nil).message])
            XCTAssertEqual(failed.tone, .error)
            // Nothing read, a pull request queued all the same: Start counts the list, as the table's.
            shell.addToMergeQueue(12, board: board, section: nil)
            XCTAssertEqual(try stages(of: board, in: shell).sections.first?.queue?.start?.title.hasSuffix(" · 1"), true)

            // Another space, its repository anchored but not saved in Board Settings: read from its remote, read-only.
            let other = shell.workspaceStore.createProfile(named: "Gadgets")
            let gadgets = root + "/gadgets-app"
            try BoardConfigSuggestionsTests.makeRepository(at: gadgets, remote: "https://github.com/acme/gadgets.git")
            var anchor = try XCTUnwrap(FolderIdentity.identify(gadgets, timeout: 10)).anchor
            anchor.isDefault = true
            XCTAssertTrue(shell.workspaceStore.setAnchors([anchor], forProfile: other.id))
            shell.addWorkspace(title: "gadget", cwd: gadgets, profileID: other.id)
            shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0.title == "gadget" }))
            try runPaletteAction("Open Board", in: shell)
            let unsaved = try XCTUnwrap(shell.projectBoardLocation(projectID: other.id)?.board)
            try waitUntil("its remote's pull requests are read") { unsaved.reads.values.first?.openPullRequests != nil && unsaved.local != nil }
            XCTAssertEqual(try stages(of: unsaved, in: shell).sections.first?.title, "gadgets-app", "its anchor's name")
            let pill = try XCTUnwrap(try stages(of: unsaved, in: shell).sections.first?.status)
            XCTAssertEqual(pill.text, "No settings")
            XCTAssertEqual(pill.toolTip, "Read-only, from origin: save Board Settings to use the merge queue.")
            XCTAssertEqual(try stages(of: unsaved, in: shell).sections.first?.menu.first, .boardSettings, "where the settings can set it up")
        }
    }

    // MARK: - Helpers

    /// What the stages would show now, from the shell's own readings.
    @MainActor
    private func stages(
        of board: ProjectBoardController, in shell: NiruxShellView, order: BoardStages.Order = .sidebar
    ) throws -> BoardStagesView.Content {
        let now = Date().timeIntervalSince1970
        let members = shell.projectWorkspaces(of: board.projectID)
        let workspaces = shell.projectBoardWorkspaces(members, of: board, snapshot: ProcessSnapshot(), now: now)
        let readings = shell.boardReadings(
            ofSpace: board.projectID, foregroundProcesses: [:], approvalHolds: [:], missionQuestions: [:], snapshot: ProcessSnapshot(),
            now: now, comparable: board.comparableFolder
        )
        return board.stagesContent(shell.stagesInputs(of: board, members: members, workspaces: workspaces, readings: readings, order: order))
    }

    @MainActor
    private func withShell(client: ProjectBoardFlowTests.FakeGitHub, _ body: (NiruxShellView, WorkspaceProfile) throws -> Void) throws {
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
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = shell
        defer {
            shell.spaceSettings?.close()
            window.close()
        }
        // Its own space: the first workspace, in the home folder, stays out.
        try body(shell, shell.workspaceStore.createProfile(named: "Board"))
    }

    private func writeConfig(for space: WorkspaceProfile) throws {
        let store = try XCTUnwrap(BoardConfigStore(spaceID: space.id))
        let config = BoardConfig(
            repository: "acme/widgets", baseBranch: "main", requiredChecks: ["test"], postMergeWorkflow: .workflow("nightly.yml")
        )
        if case .failure(let error) = store.save(config) { XCTFail(error.message) }
    }

    @discardableResult
    private func git(_ arguments: [String], at directory: String) throws -> String {
        try BoardConfigSuggestionsTests.git(arguments, at: directory)
    }

    @MainActor
    private func runPaletteAction(_ title: String, in shell: NiruxShellView) throws {
        let actions = shell.columnPaletteActions() + shell.agentPaletteActions() + shell.workspacePaletteActions()
        try XCTUnwrap(actions.first { $0.title == title }, "no “\(title)” in the palette").action()
    }

    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 30, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), "timed out: \(what)")
    }
}
