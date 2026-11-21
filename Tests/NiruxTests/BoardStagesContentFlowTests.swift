import AppKit
import XCTest
@testable import Nirux

/// What the Board as stages shows of a space, built from what the Board
/// read (docs/design/board-stages.md, sections 5 and 6): a real shell, git
/// for real in temporary repositories, a fake `gh` (`ProjectBoardFlowTests`).
/// The content is asked for directly, beside what the column shows.
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
       "isDraft": false, "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED", "url": "https://github.com/acme/widgets/pull/12", "title": "Sign in",
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
            openPullRequests: Self.pullRequests, mergedPullRequests: Self.merged, runs: ProjectBoardGitHubTests.postMergeRuns,
            openByRepository: ["acme/gadgets": "[]"]
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
            // Saved with its own capitals: the section is named as saved.
            try writeConfig(for: space, repository: "Acme/Widgets")

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
            waitUntil("the pull requests and the post-merge run are read, the worktrees listed, gadgets read too") {
                board.reads["legacy"]?.openPullRequests != nil && board.reads["legacy"]?.mergedPullRequests != nil
                    && board.local != nil && !board.view.stages.lineViews.isEmpty
                    && board.view.stages.content?.sections.first?.status?.toolTip?.contains("success") == true
                    && board.reads.values.contains { $0.name == "acme/gadgets" && $0.openPullRequests != nil }
            }
            let ids = { (title: String) in shell.workspaces.first { $0.title == title }?.id ?? "" }
            let loginTask = try XCTUnwrap(shell.workspaces.first { $0.id == ids("login") })
            loginTask.reviewRuns[.codeReview] = ReviewRun(head: String(repeating: "a", count: 40), at: 1, branch: "feat/login")
            let content = try stages(of: board, in: shell)

            // A click on a task's line focuses its workspace, at its most urgent agent column when one works there: as the
            // Board shows it.
            XCTAssertEqual(board.stagesTargets.focus[ids("login")], .focus(workspaceID: ids("login"), columnID: nil), "a shell: no agent")
            let column = UUID()
            var withAgent = shell.stagesInputs(
                of: board, members: shell.projectWorkspaces(of: board.projectID),
                workspaces: shell.projectBoardWorkspaces(shell.projectWorkspaces(of: board.projectID), of: board, snapshot: ProcessSnapshot(),
                                                         now: Date().timeIntervalSince1970, foregroundProcesses: [:]),
                readings: [:], order: .sidebar
            )
            let loginIndex = try XCTUnwrap(withAgent.workspaces.firstIndex { $0.id == ids("login") })
            let shown = withAgent.workspaces[loginIndex]
            withAgent.workspaces[loginIndex] = ProjectBoard.Workspace(
                id: shown.id, title: shown.title, folder: shown.folder, folderIsGone: shown.folderIsGone, isInactive: shown.isInactive,
                agent: ProjectBoard.Agent(state: .working(duration: nil), workspaceID: shown.id, columnID: column)
            )
            XCTAssertEqual(board.stagesContent(withAgent).targets.focus[ids("login")], .focus(workspaceID: ids("login"), columnID: column))

            // The space, what it holds (the Lead is no task), its Lead.
            XCTAssertEqual(content.header.name, "Board")
            XCTAssertEqual(content.header.summary, "2 repositories · 4 tasks", "the Lead apart, an archived task left out")
            XCTAssertEqual(content.header.lead?.text.hasPrefix("Lead · "), true, content.header.lead?.text ?? "")
            XCTAssertEqual(content.header.lead?.state, .idle, "a Lead with no agent at work")
            XCTAssertNil(content.message)
            XCTAssertEqual(content.runningQueues, [], "no queue runs")
            XCTAssertEqual(content.sections.map(\.title), ["Widgets", "gadgets", "No repository"])

            // The repository: its name and owner/name, its post-merge pill, its queue at rest, its menu.
            let widgets = try XCTUnwrap(content.sections.first)
            XCTAssertEqual([widgets.title, widgets.detail], ["Widgets", "Acme/Widgets"])
            XCTAssertEqual(widgets.status?.text.hasPrefix("nightly "), true, widgets.status?.text ?? "")
            XCTAssertEqual(widgets.status?.symbol, Theme.Symbol.checksPassed, "the run read: green")
            XCTAssertEqual(widgets.queue?.start?.title.hasPrefix("Start"), true, "Start…, or Start Dry Run… in a build that can't change GitHub")
            XCTAssertEqual(widgets.menu, [.boardSettings, .openMainCheckout(path: repo)])
            // Its tasks in the sidebar's order, the pull request without a task folded, its other worktrees with the Lead's first.
            XCTAssertEqual(widgets.lines.units.flatMap(\.lines).map(\.id), [ids("widgets"), ids("login"), ids("old")])
            XCTAssertEqual(widgets.lines.units.flatMap(\.lines).map(\.pullRequest), ["no PR yet", "#12", "no PR yet"])
            let loginPR = try XCTUnwrap(widgets.lines.units.flatMap(\.lines).first { $0.id == loginTask.id })
            XCTAssertEqual(loginPR.station, .merge)
            XCTAssertEqual(loginPR.state, .blocked)
            XCTAssertEqual(loginPR.phrase.text, "Merge blocked by GitHub")
            XCTAssertEqual(widgets.lines.withoutTask.flatMap(\.lines).map(\.title), ["Remote fix"])
            XCTAssertEqual(widgets.lines.otherWorktrees.map(\.title), ["Lead · lead/notes", "scratch"])
            XCTAssertEqual(widgets.lines.otherWorktrees.first?.menu.first, .focus(workspaceID: ids("Lead"), columnID: nil))

            // A workspace in no repository is a line there; one in another repository, a line of that repository's
            // section: read-only from its remote (not one of the space's repositories), no queue, no Board Settings.
            let noRepository = try XCTUnwrap(content.sections.first { $0.id == ProjectBoardController.noRepositoryID })
            XCTAssertEqual(noRepository.lines.units.flatMap(\.lines).map(\.id), [ids("notes")])
            XCTAssertNil(noRepository.queue)
            let gadgetsSection = try XCTUnwrap(content.sections.first { $0.title == "gadgets" })
            XCTAssertEqual(gadgetsSection.detail, "acme/gadgets")
            XCTAssertEqual(gadgetsSection.lines.units.flatMap(\.lines).map(\.id), [ids("gadget")])
            XCTAssertNil(gadgetsSection.queue)
            XCTAssertFalse(gadgetsSection.menu.contains(.boardSettings))
            XCTAssertEqual(gadgetsSection.status?.text, "Read-only")
            XCTAssertEqual(gadgetsSection.status?.toolTip, "Read-only, from origin: not one of this space’s repositories, so no merge queue here.")
            XCTAssertNil(content.sections.first { $0.kind == .otherWorkspaces }, "no Other workspaces")

            // Each task's row stands at its line's station: the Board's reading, read by the sidebar's pass.
            shell.updateSidebar(snapshot: ProcessSnapshot(entries: []))
            let lines = try stages(of: board, in: shell).sections.flatMap { $0.lines.units.flatMap(\.lines) }
            let rows = shell.sidebar.lastInfos.filter { info in lines.contains { $0.id == info.id } }
            XCTAssertFalse(rows.isEmpty)
            for row in rows {
                let line = try XCTUnwrap(lines.first { $0.id == row.id })
                XCTAssertEqual(row.station, line.rail == nil ? nil : line.station, line.title)
            }
            XCTAssertTrue(rows.contains { $0.station != nil }, "read just now: its stations stand")
            // An hour without a read (a Board not shown doesn't read): its stations have aged, the rows drop them.
            let later = board.freshSections(now: Date().addingTimeInterval(3_600), clock: ProjectBoard.clock() + 3_600)
            XCTAssertEqual(later, [])
            let aged = board.stagesContent(withAgent, now: Date().addingTimeInterval(3_600)).content
            XCTAssertEqual(aged.inputStatus, "Status incomplete")
            let loginLine = aged.sections.first?.lines.units.flatMap(\.lines).first { $0.id == ids("login") }
            XCTAssertEqual(loginLine?.phrase.text, "GitHub status outdated")
            shell.noteTaskStations(of: board, content: try stages(of: board, in: shell), fresh: later)
            XCTAssertTrue(rows.allSatisfy { shell.taskStations[$0.id] == nil })

            // Start says what the next one takes.
            shell.addToMergeQueue(12, board: board, section: "legacy")
            shell.addToMergeQueue(40, board: board, section: "legacy")
            XCTAssertEqual(try stages(of: board, in: shell).sections[0].queue?.start?.title.hasSuffix(" · 1"), true, "a merged one counts for none")
        }
    }

    /// A Board not drawn builds its stages again only when what they are
    /// built from changes: the shell's inputs, the day, what the Board read.
    /// One drawn builds them at every pass. Each build carries its `now`:
    /// the stages kept say when they were built.
    @MainActor
    func testABoardNotDrawnBuildsItsStagesOnlyWhenTheirInputsChange() throws {
        let client = ProjectBoardFlowTests.FakeGitHub(
            openPullRequests: Self.pullRequests, mergedPullRequests: "[]", runs: ProjectBoardGitHubTests.postMergeRuns
        )
        try withShell(client: client) { shell, space in
            let repo = root + "/widgets", login = root + "/widgets.feat-login"
            try BoardConfigSuggestionsTests.makeRepository(at: repo, remote: "https://github.com/acme/widgets.git")
            try git(["worktree", "add", "-q", "-b", "feat/login", login], at: repo)
            try writeConfig(for: space)
            shell.addWorkspace(title: "widgets", cwd: repo, profileID: space.id)
            shell.addWorkspace(title: "login", cwd: login, profileID: space.id)
            let index: @MainActor (String) throws -> Int = { title in try XCTUnwrap(shell.workspaces.firstIndex { $0.title == title }) }
            shell.switchToWorkspace(try index("widgets"))
            try runPaletteAction("Open Board", in: shell)
            let board = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id)?.board)
            waitUntil("#12 read, the worktrees listed") {
                board.reads["legacy"]?.openPullRequests != nil && board.local != nil && !board.view.stages.lineViews.isEmpty
            }
            let task = shell.workspaces[try index("login")]
            shell.switchToWorkspace(try index("login"))
            XCTAssertFalse(shell.isProjectBoardShown(board))

            // Noon: the next seconds stay the same day.
            let now = BoardStages.midnight(of: Date().timeIntervalSince1970) + 12 * 3_600
            let pass = NiruxShellView.SidebarPassReadings(infos: [], foregroundProcesses: [:], approvalHolds: [:], missionQuestions: [:])
            let builtAt: @MainActor (TimeInterval) -> TimeInterval? = { now in
                _ = shell.readProjectBoards(snapshot: ProcessSnapshot(entries: []), now: now, pass: pass)
                return board.builtStages.last?.content.now
            }
            let kept = try XCTUnwrap(builtAt(now))
            XCTAssertNotNil(shell.taskStations[task.id], "#12's station")
            XCTAssertEqual(builtAt(now + 1), kept, "nothing changed: the stages kept")
            XCTAssertNotNil(shell.taskStations[task.id], "and their stations")
            task.title = "login form"
            XCTAssertEqual(builtAt(now + 2), now + 2, "an input changed")
            let today = try XCTUnwrap(board.builtStages.last?.key.inputs)
            XCTAssertEqual(builtAt(now + 86_400), now + 86_400, "the next day, as Merged today ends")
            XCTAssertEqual(board.builtStages.last?.key.inputs, today, "the same inputs: the day alone built them again")

            shell.switchToWorkspace(try index("widgets"))
            XCTAssertTrue(shell.isProjectBoardShown(board))
            XCTAssertEqual(builtAt(now + 5), now + 5)
            XCTAssertEqual(builtAt(now + 6), now + 6, "drawn: built at every pass")

            // What the Board read counts too: the same inputs, once it read another space, build again.
            let inputs = try XCTUnwrap(board.builtStages.last?.key.inputs)
            board.switchProject(to: WorkspaceProfile.defaultID)
            XCTAssertEqual(board.keptStagesContent(inputs, now: Date(timeIntervalSince1970: now + 7)).now, now + 7)
            // Its board.json read lands here, not in a later test.
            waitUntil("General's board.json read") { board.loaded != nil }
        }
    }

    /// The table's messages in place of its rows are the stages' in place of
    /// their sections, Board Settings… offered where the settings can fix
    /// them.
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
            waitUntil("board.json is read") { board.loaded != nil }
            shell.spaceSettings?.close()
            let message = try stages(of: board, in: shell).message
            shell.renderProjectBoard(board)
            XCTAssertEqual(board.view.stages.content?.message, message, "what the column shows")
            XCTAssertEqual(message?.text, "Set this space’s repository in Board Settings… to list its branches and pull requests.")
            XCTAssertEqual(message?.offersSettings, true)

            XCTAssertEqual(try stages(of: board, in: shell).header.summary, "1 task", "no repository set: none counted")
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
            waitUntil("the read fails and the worktrees are listed") {
                board.reads.values.first?.errors.isEmpty == false && board.local != nil
            }
            XCTAssertEqual(try stages(of: board, in: shell).sections.map(\.id), ["legacy"], "no No repository, no Other workspaces: none")
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "widgets" })
            task.blocker = "Wait for the design review"
            let section = try XCTUnwrap(try stages(of: board, in: shell).sections.first)
            let line = try XCTUnwrap(section.lines.units.flatMap(\.lines).first { $0.id == task.id })
            XCTAssertEqual(line.state, .blocked)
            XCTAssertEqual(line.phrase.text, "Wait for the design review")
            XCTAssertEqual(line.phrase.detail, "GitHub status unavailable")
            let failed = try XCTUnwrap(section.status)
            XCTAssertEqual([failed.text, failed.toolTip], ["GitHub error", ProjectBoard.message(.notSignedIn(nil))])
            XCTAssertEqual(failed.tone, .error)
            // Nothing read, a pull request queued all the same: Start counts the list, as the table's.
            shell.addToMergeQueue(12, board: board, section: nil)
            XCTAssertEqual(try stages(of: board, in: shell).sections.first?.queue?.start?.title.hasSuffix(" · 1"), true)
            // Unless only its task knows it merged: none left to start. Its git context in, which names its root as /var
            // where git lists the worktree under /private/var.
            waitUntil("its git context") { shell.workspaces.first { $0.title == "widgets" }?.gitContext != nil }
            let start = try stages(of: board, in: shell) { readings in
                readings[shell.workspaces.first { $0.title == "widgets" }?.id ?? "", default: BoardStages.TaskReading()].mergedPullRequest = 12
            }.sections.first?.queue?.start
            XCTAssertEqual(start?.title.hasSuffix(" · 1"), false, start?.title ?? "")
            XCTAssertEqual(start?.isEnabled, false)
            XCTAssertEqual(start?.tooltip, "Add pull requests to the queue first.")
            // A space with that repository and no workspace in its checkout (the Board's in a plain folder): its section
            // still shows, and wears the read that failed in its pill; no message takes its place.
            let empty = shell.workspaceStore.createProfile(named: "Empty")
            try writeConfig(for: empty)
            let plain = root + "/plain-folder"
            try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
            shell.addWorkspace(title: "plain", cwd: plain, profileID: empty.id)
            shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0.title == "plain" }))
            try runPaletteAction("Open Board", in: shell)
            let emptyBoard = try XCTUnwrap(shell.projectBoardLocation(projectID: empty.id)?.board)
            waitUntil("the read fails again, for that space") {
                // As a status refresh would, on screen (this window never is).
                emptyBoard.tick(onScreen: true)
                return emptyBoard.loaded != nil && emptyBoard.local != nil && emptyBoard.reads.values.first?.errors.isEmpty == false
            }
            let emptyContent = try stages(of: emptyBoard, in: shell)
            XCTAssertNil(emptyContent.message)
            let emptyPill = try XCTUnwrap(emptyContent.sections.first?.status)
            XCTAssertEqual(emptyPill.tone, .error)
            XCTAssertEqual(emptyPill.toolTip?.contains(ProjectBoard.message(.notSignedIn(nil))), true, emptyPill.toolTip ?? "")

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
            waitUntil("its remote's pull requests are read") { unsaved.reads.values.first?.openPullRequests != nil && unsaved.local != nil }
            XCTAssertEqual(try stages(of: unsaved, in: shell).sections.first?.title, "gadgets-app", "its anchor's name")
            let pill = try XCTUnwrap(try stages(of: unsaved, in: shell).sections.first?.status)
            XCTAssertEqual(pill.text, "No settings")
            XCTAssertEqual(pill.toolTip, "Read-only, from origin: save Board Settings to use the merge queue.")
            XCTAssertEqual(try stages(of: unsaved, in: shell).sections.first?.menu.first, .boardSettings, "where the settings can set it up")

            // A third space whose board.json a newer Nirux saved: read-only, why under the pointer, no Board Settings… to offer.
            let locked = shell.workspaceStore.createProfile(named: "Locked")
            let tools = root + "/tools-app"
            try BoardConfigSuggestionsTests.makeRepository(at: tools, remote: "https://github.com/acme/tools.git")
            var toolsAnchor = try XCTUnwrap(FolderIdentity.identify(tools, timeout: 10)).anchor
            toolsAnchor.isDefault = true
            XCTAssertTrue(shell.workspaceStore.setAnchors([toolsAnchor], forProfile: locked.id))
            let store = try XCTUnwrap(BoardConfigStore(spaceID: locked.id))
            try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"schemaVersion": 3}"#.utf8).write(to: store.fileURL)
            shell.addWorkspace(title: "tool", cwd: tools, profileID: locked.id)
            // No remote of the space's is read for a read-only file: another repository's workspace has its section all
            // the same, and a second clone of its own repository none (under Other workspaces: its section reads nothing).
            let outside = root + "/outside-app", toolsCopy = root + "/tools-copy"
            try BoardConfigSuggestionsTests.makeRepository(at: outside, remote: "https://github.com/acme/outside.git")
            try BoardConfigSuggestionsTests.makeRepository(at: toolsCopy, remote: "git@github.com:acme/tools.git")
            shell.addWorkspace(title: "outside", cwd: outside, profileID: locked.id)
            shell.addWorkspace(title: "tools copy", cwd: toolsCopy, profileID: locked.id)
            shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0.title == "tool" }))
            try runPaletteAction("Open Board", in: shell)
            let readOnly = try XCTUnwrap(shell.projectBoardLocation(projectID: locked.id)?.board)
            waitUntil("board.json is read, the worktrees listed, the other repository placed") {
                readOnly.loaded != nil && readOnly.local != nil
                    && (try? stages(of: readOnly, in: shell).sections.map(\.title)) == ["tools-app", "outside-app", "Other workspaces"]
            }
            let lockedSection = try XCTUnwrap(try stages(of: readOnly, in: shell).sections.first)
            XCTAssertEqual(lockedSection.status?.text, "Read-only")
            XCTAssertEqual(lockedSection.status?.toolTip, BoardConfigStore.ReadOnlyReason.newerSchema(3).message)
            XCTAssertFalse(lockedSection.menu.contains(.boardSettings), "Board Settings can't save it")

            // One whose board.json is a folder: read-only without a config, its anchor's remote never read for it; another
            // repository's workspace has its section all the same.
            let folderSpace = shell.workspaceStore.createProfile(named: "Folder")
            let docs = root + "/docs-app"
            try BoardConfigSuggestionsTests.makeRepository(at: docs, remote: "https://github.com/acme/docs.git")
            var docsAnchor = try XCTUnwrap(FolderIdentity.identify(docs, timeout: 10)).anchor
            docsAnchor.isDefault = true
            XCTAssertTrue(shell.workspaceStore.setAnchors([docsAnchor], forProfile: folderSpace.id))
            let folderStore = try XCTUnwrap(BoardConfigStore(spaceID: folderSpace.id))
            try FileManager.default.createDirectory(at: folderStore.fileURL, withIntermediateDirectories: true)
            shell.addWorkspace(title: "doc", cwd: docs, profileID: folderSpace.id)
            shell.addWorkspace(title: "outside here", cwd: outside, profileID: folderSpace.id)
            shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0.title == "doc" }))
            try runPaletteAction("Open Board", in: shell)
            let folderBoard = try XCTUnwrap(shell.projectBoardLocation(projectID: folderSpace.id)?.board)
            waitUntil("the other repository placed beside a board.json read-only without a config") {
                (try? stages(of: folderBoard, in: shell).sections.map(\.title)) == ["docs-app", "outside-app"]
            }
            // A Refresh keeps its remote meanwhile (its section never blanks), and reads it again: a remote changed lands.
            _ = try BoardConfigSuggestionsTests.git(["remote", "set-url", "origin", "https://github.com/acme/outside-renamed.git"], at: outside)
            let outsideRead = { folderBoard.sections.first { $0.anchor?.name == "outside-app" }.flatMap { folderBoard.reads[$0.id] } }
            var blanked = false
            folderBoard.reload()
            waitUntil("the other repository read from its new remote after a Refresh") {
                folderBoard.tick(onScreen: true)
                if outsideRead() == nil { blanked = true }
                return client.calls.contains { $0.what == "pr open acme/outside-renamed" }
            }
            XCTAssertFalse(blanked, "its section kept its remote through the Refresh")

            // A fourth whose board.json names no valid GitHub repository: its settings are there, but invalid.
            let invalid = shell.workspaceStore.createProfile(named: "Invalid")
            let site = root + "/site-app"
            try BoardConfigSuggestionsTests.makeRepository(at: site, remote: "https://github.com/acme/site.git")
            var siteAnchor = try XCTUnwrap(FolderIdentity.identify(site, timeout: 10)).anchor
            siteAnchor.isDefault = true
            XCTAssertTrue(shell.workspaceStore.setAnchors([siteAnchor], forProfile: invalid.id))
            let invalidStore = try XCTUnwrap(BoardConfigStore(spaceID: invalid.id))
            try FileManager.default.createDirectory(at: invalidStore.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let commonDir = try XCTUnwrap(BoardSections.commonDir(of: siteAnchor))
            try Data(#"{"schemaVersion": 2, "repositories": [{"commonDir": "\#(commonDir)", "repository": "not a repository"}]}"#.utf8)
                .write(to: invalidStore.fileURL)
            shell.addWorkspace(title: "site", cwd: site, profileID: invalid.id)
            shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0.title == "site" }))
            try runPaletteAction("Open Board", in: shell)
            let invalidBoard = try XCTUnwrap(shell.projectBoardLocation(projectID: invalid.id)?.board)
            waitUntil("board.json is read and the worktrees listed") { invalidBoard.loaded != nil && invalidBoard.local != nil }
            let invalidSection = try XCTUnwrap(try stages(of: invalidBoard, in: shell).sections.first)
            XCTAssertEqual(invalidSection.status?.text, "Invalid settings")
            XCTAssertEqual(invalidSection.status?.toolTip, "Board Settings has no valid GitHub repository for it: set one to see its pull requests.")
            XCTAssertEqual(invalidSection.menu.first, .boardSettings, "the settings can fix it")
        }
    }

    @MainActor
    func testWaitingWorkspaceFollowsItsDependencyAcrossSectionsUntilRelease() throws {
        try withShell(client: ProjectBoardFlowTests.FakeGitHub(openPullRequests: "[]", runs: "[]")) { shell, space in
            let repo = root + "/widgets", docs = root + "/docs"
            try BoardConfigSuggestionsTests.makeRepository(at: repo, remote: "https://github.com/acme/widgets.git")
            try BoardConfigSuggestionsTests.makeRepository(at: docs, remote: "https://github.com/acme/docs.git")
            let widgets = try XCTUnwrap(FolderIdentity.identify(repo, timeout: 10)).anchor
            let guides = try XCTUnwrap(FolderIdentity.identify(docs, timeout: 10)).anchor
            let widgetsID = try XCTUnwrap(widgets.key), guidesID = try XCTUnwrap(guides.key)
            XCTAssertTrue(shell.workspaceStore.setAnchors([widgets, guides], forProfile: space.id))
            shell.addWorkspace(title: "Sign in", cwd: repo, profileID: space.id, workspaceID: "login")
            shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0.id == "login" }))
            let path = root + "/waiting/docs"
            let wait = BoardStagesLineTests.startWait(after: "login", repo: guidesID)
            shell.addWorkspace(title: "Write the guide", cwd: path, profileID: space.id, workspaceID: "guide",
                               waitingStart: wait, activate: false)
            let guide = try XCTUnwrap(shell.workspaces.first { $0.id == "guide" })
            try runPaletteAction("Open Board", in: shell)
            let board = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id)?.board)
            waitUntil("the Board lists both repositories") {
                board.local?.folders[docs] != nil && board.local?.folders[repo] != nil && board.sections.count == 2
            }
            func ids(_ content: BoardStagesView.Content, in section: String) -> [String] {
                content.sections.first { $0.id == section }?.lines.units.flatMap(\.lines).map(\.id) ?? []
            }
            for order in [BoardStages.Order.sidebar, .progress] {
                let content = try stages(of: board, in: shell, order: order)
                XCTAssertEqual(ids(content, in: widgetsID), ["login", "guide"])
                XCTAssertEqual(ids(content, in: guidesID), [])
                XCTAssertFalse(content.sections.contains { $0.id == ProjectBoardController.noRepositoryID })
            }
            XCTAssertFalse(board.workspaceFolders().contains(path))
            shell.renderProjectBoard(board)
            XCTAssertEqual(board.stagesTargets.focus["guide"], .focus(workspaceID: "guide", columnID: nil))
            XCTAssertNil(board.stagesTargets.folders["guide"])

            var failed = BoardStagesLineTests.startWait(after: "gone", repo: guidesID)
            failed.failure = "The dependency closed"
            guide.mergeWaits = [failed]
            let changed = try stages(of: board, in: shell)
            XCTAssertEqual(ids(changed, in: widgetsID), ["login"])
            XCTAssertEqual(ids(changed, in: guidesID), ["guide"])
            let orphan = try XCTUnwrap(changed.sections.first { $0.id == guidesID }?.lines.units.first?.lines.first)
            XCTAssertEqual(orphan.state, .needsYou)
            XCTAssertEqual(orphan.phrase.text, "Needs you · The dependency closed")
            XCTAssertTrue(orphan.menu.isEmpty)

            let unread = shell.makeProjectBoard(projectID: space.id, offersSettings: true)
            let beforeRead = try stages(of: unread, in: shell)
            XCTAssertEqual(beforeRead.message?.showsWaitingTasks, true)
            unread.view.stages.show(beforeRead)
            XCTAssertEqual(unread.view.stages.lineViews.map(\.line.id), ["guide"])
            XCTAssertEqual(unread.view.stages.lineViews.first?.line.state, .needsYou)

            guide.mergeWaits = []
            guide.beginTask(at: docs, mission: nil)
            let released = try stages(of: board, in: shell)
            XCTAssertEqual(ids(released, in: guidesID), ["guide"])
            XCTAssertEqual(released.sections.flatMap { $0.lines.units.flatMap(\.lines) }.filter { $0.id == "guide" }.count, 1)
        }
    }

    // MARK: - Helpers

    /// What the stages would show now, from the shell's own readings.
    @MainActor
    /// `change` changes the readings first.
    private func stages(
        of board: ProjectBoardController, in shell: NiruxShellView, order: BoardStages.Order = .sidebar,
        _ change: (inout [String: BoardStages.TaskReading]) -> Void = { _ in }
    ) throws -> BoardStagesView.Content {
        let now = Date().timeIntervalSince1970
        let members = shell.projectWorkspaces(of: board.projectID)
        let snapshot = ProcessSnapshot()
        let workspaces = shell.projectBoardWorkspaces(
            members, of: board, snapshot: snapshot, now: now, foregroundProcesses: shell.foregroundProcesses(of: members, snapshot: snapshot)
        )
        var readings = shell.boardReadings(
            ofSpace: board.projectID, foregroundProcesses: [:], approvalHolds: [:], missionQuestions: [:], snapshot: ProcessSnapshot(),
            now: now
        )
        change(&readings)
        return board.stagesContent(shell.stagesInputs(of: board, members: members, workspaces: workspaces, readings: readings, order: order)).content
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

    private func writeConfig(for space: WorkspaceProfile, repository: String = "acme/widgets") throws {
        let store = try XCTUnwrap(BoardConfigStore(spaceID: space.id))
        let config = BoardConfig(
            repository: repository, baseBranch: "main", requiredChecks: ["test"], postMergeWorkflow: .workflow("nightly.yml")
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
}
