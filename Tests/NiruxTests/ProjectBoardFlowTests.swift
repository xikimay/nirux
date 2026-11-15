import AppKit
import XCTest
@testable import Nirux

/// The Board in a real window, from "Open Board" to its clicks: its
/// lines, their menus, its headers' (docs/design/board-stages.md). A fake
/// `gh` client stands in for GitHub (the runners have `gh`): the board
/// calls it off the main thread and hops back, the path where a closure
/// isolated to the main actor trapped in the nightly (#48). git runs for
/// real, in temporary repositories. Clicks are hit-tested by hand
/// (`BoardStagesClicks`), since a window that is never shown (CI) drops
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
        let mergedPullRequests: String
        let runs: String
        /// Open pull requests by `owner/name`, for a board with several
        /// repositories; the others get `openPullRequests`.
        let openByRepository: [String: String]
        /// What gh answers instead for these `owner/name`.
        let failures: [String: ProjectBoard.FetchError]

        init(
            openPullRequests: String, mergedPullRequests: String = "[]", runs: String,
            openByRepository: [String: String] = [:], failures: [String: ProjectBoard.FetchError] = [:]
        ) {
            self.openPullRequests = openPullRequests
            self.mergedPullRequests = mergedPullRequests
            self.runs = runs
            self.openByRepository = openByRepository
            self.failures = failures
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
            if let failure = failures[repository] { return .failure(failure) }
            let open = openByRepository[repository] ?? openPullRequests
            return .success(Data((state == .open ? open : mergedPullRequests).utf8))
        }

        func postMergeRuns(repository: String, workflow: String, branch: String) -> Result<Data, ProjectBoard.FetchError> {
            record("run \(repository) \(workflow) \(branch)")
            return .success(Data(runs.utf8))
        }

        private var failure: ProjectBoard.FetchError?
        /// What the next retargets answer, when GitHub refuses them.
        var retargetFailure: ProjectBoard.FetchError? {
            get { lock.lock(); defer { lock.unlock() }; return failure }
            set { lock.lock(); failure = newValue; lock.unlock() }
        }

        func retarget(repository: String, number: Int, base: String) -> Result<Data, ProjectBoard.FetchError> {
            record("retarget \(repository) #\(number) \(base)")
            return retargetFailure.map { .failure($0) } ?? .success(Data(base.utf8))
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

            try runPaletteAction("Open Board", in: shell)
            let location = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id))
            XCTAssertTrue(location.workspace === shell.activeWorkspace)
            XCTAssertTrue(location.column === shell.activeWorkspace?.columns[location.workspace.focusedIndex],
                          "the board opens next to the focused column, focused")
            let board = location.board
            try waitUntil("the pull requests are read") { BoardStagesClicks.wasUpdated(board) }
            try waitUntil("the post-merge run is read") {
                board.view.stages.content?.sections.first?.status?.toolTip?.contains("success") == true
            }
            try waitUntil("the worktrees are listed") { !board.view.stages.lineViews.isEmpty }

            XCTAssertEqual(board.view.header.context, "acme/widgets")
            XCTAssertNil(board.view.header.status, "the repository's header has the pill")
            XCTAssertEqual(board.view.header.titleToolTip, "Board · Board")
            let widgets = try BoardStagesClicks.section("widgets", in: board)
            XCTAssertEqual(widgets.detail, "acme/widgets")
            let run = try XCTUnwrap(board.view.stages.sectionHeader(section: widgets.id)?.pill.status)
            XCTAssertTrue(run.text.hasPrefix("nightly "), run.text)
            XCTAssertEqual(run.symbol, Theme.Symbol.checksPassed)
            XCTAssertTrue(run.toolTip?.hasPrefix("nightly: success ") == true, run.toolTip ?? "")
            XCTAssertTrue(run.toolTip?.hasSuffix(", 43a9503") == true, run.toolTip ?? "")
            XCTAssertEqual(board.view.stages.lineViews.map(\.line.title), ["widgets", "login"], "the tasks, in the sidebar's order")
            let loginLine = try BoardStagesClicks.line("login", in: board).line
            XCTAssertEqual(loginLine.pullRequest, "#12")
            XCTAssertEqual(loginLine.phrase.text, "No code review yet", "its checks passed")
            XCTAssertTrue(loginLine.tooltips.stations[.checks]?.contains("test") == true, "\(loginLine.tooltips.stations)")
            XCTAssertEqual(widgets.lines.withoutTask.flatMap(\.lines).map(\.pullRequest), ["#13"], "no worktree for #13")
            XCTAssertEqual(widgets.lines.otherWorktrees.map(\.title), ["scratch"])
            // A click acts on what the Board shows now: an offer held under the pointer since refused (#13 is a draft)
            // changes nothing.
            shell.mergeQueueLockFolder = URL(fileURLWithPath: root + "/locks")
            shell.performBoardOffer(BoardStages.QueueOffer(change: .add, number: 13), section: widgets.id, board: board)
            XCTAssertEqual(shell.mergeQueue(projectID: space.id, repository: GitHubRepository(owner: "acme", name: "widgets")).selection, [])

            XCTAssertFalse(client.calls.isEmpty)
            XCTAssertFalse(client.calls.contains(where: \.onMainThread), "gh never runs on the main thread")
            XCTAssertEqual(Set(client.calls.map(\.what)), [
                "pr open acme/widgets", "pr merged acme/widgets", "run acme/widgets nightly.yml main"
            ])

            // Refresh reads again, now.
            dropWorkspaceSnapshots(shell)
            let reads = client.calls.filter { $0.what == "pr open acme/widgets" }.count
            try BoardStagesClicks.click(board.view.refreshButton)
            try waitUntil("Refresh reads the pull requests again") {
                client.calls.filter { $0.what == "pr open acme/widgets" }.count > reads
            }

            // From the keyboard (Full Keyboard Access): Tab from the column reaches the lines in their order; Space opens
            // the task.
            BoardStagesKeyboard.isFullAccess = { true }
            defer { BoardStagesKeyboard.isFullAccess = { NSApp.isFullKeyboardAccessEnabled } }
            let window = try XCTUnwrap(board.view.window)
            // Shift-Tab from the column, which a click on the Board gives the keyboard: the last line.
            window.makeFirstResponder(board.view)
            XCTAssertEqual(try BoardStagesClicks.tabToNextLine(in: window, backward: true).line.title, "login")
            window.makeFirstResponder(board.view)
            XCTAssertEqual(try BoardStagesClicks.tabToNextLine(in: window).line.title, "widgets")
            let focused = try BoardStagesClicks.tabToNextLine(in: window)
            XCTAssertEqual(focused.line.title, "login")
            // Round the loop back to the first line: the column, where it ends, is no stop.
            var steps = 0
            repeat {
                window.selectNextKeyView(nil)
                steps += 1
                XCTAssertFalse(window.firstResponder === board.view, "the column is no stop")
            } while (window.firstResponder as? BoardStagesLineView)?.line.title != "widgets" && steps < 30
            XCTAssertLessThan(steps, 30)
            try BoardStagesClicks.type(" ", 49, on: focused)
            XCTAssertEqual(shell.activeWorkspace?.title, "login")
            try select("widgets", in: shell)
            dropWorkspaceSnapshots(shell)
            BoardStagesKeyboard.isFullAccess = { NSApp.isFullKeyboardAccessEnabled }

            // A click on the line opens its task.
            try BoardStagesClicks.open(try BoardStagesClicks.line("login", in: board))
            XCTAssertEqual(shell.activeWorkspace?.title, "login")

            // "Open Board" again, from another workspace of the
            // space, brings the board back rather than opening another.
            try runPaletteAction("Open Board", in: shell)
            XCTAssertEqual(shell.activeWorkspace?.title, "widgets")
            XCTAssertEqual(shell.projectBoardLocations.count, 1)
            XCTAssertTrue(shell.activeWorkspace?.columns[shell.activeWorkspace?.focusedIndex ?? -1] === location.column)

            // Clean Up… on a worktree no workspace is open in: the flow of
            // "Clean Up Worktree…", by folder.
            let fold = try XCTUnwrap(board.view.stages.worktreesFold(section: widgets.id))
            try BoardStagesClicks.click(fold)
            board.view.stages.layoutSubtreeIfNeeded()
            let scratchEntry = try XCTUnwrap(board.view.stages.worktreeViews.first { $0.worktree?.path == scratch })
            XCTAssertEqual([scratchEntry.openButton.title, scratchEntry.cleanUpButton.title], ["Open", "Clean Up…"])
            var alerts: [NSAlert] = []
            shell.sideEffects.runModal = { alert in
                alerts.append(alert)
                return .alertFirstButtonReturn
            }
            try BoardStagesClicks.click(scratchEntry.cleanUpButton)
            try waitUntil("the worktree is checked") { !alerts.isEmpty }
            XCTAssertEqual(alerts.map(\.messageText), ["Can’t clean up widgets.scratch · scratch"], "the #46 notice, for that folder")
            // Stopped before gh either way: not pushed to GitHub, or no gh.
            let problems = alerts.first?.informativeText ?? ""
            XCTAssertTrue(problems.contains("pushed to a GitHub remote") || problems.contains("(gh) isn"), problems)
            XCTAssertTrue(shell.worktreeCleanupsInFlight.isEmpty)

            // Open, there: a workspace in that worktree.
            try BoardStagesClicks.click(scratchEntry.openButton)
            try waitUntil("a workspace opens there") { shell.activeWorkspace?.cwd == scratch }
            XCTAssertEqual(shell.activeWorkspace?.profileID, space.id)
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

            try runPaletteAction("Open Board", in: shell)
            let board = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id)?.board)
            // The class's first test: the first window, git and Settings window of its process take 10 s on a healthy
            // runner, and took over 30 s once with eight other test processes beside it.
            try waitUntil("Board Settings opens", timeout: 90) { shell.boardSettingsPanel?.hostView != nil }
            let form = try XCTUnwrap(shell.boardSettingsPanel)
            XCTAssertEqual(form.spaceID, space.id)
            let message = try XCTUnwrap(board.view.stages.content?.message, "no message")
            XCTAssertTrue(message.text.contains("Board Settings"), message.text)
            XCTAssertTrue(message.offersSettings)
            XCTAssertEqual(client.calls, [], "no gh without a repository")
            // Closed, Board Settings… under the message opens it again.
            shell.spaceSettings?.close()
            try waitUntil("Board Settings closes") { shell.spaceSettings == nil }
            dropWorkspaceSnapshots(shell)
            try BoardStagesClicks.click(board.view.stages.messageView.settingsButton)
            try waitUntil("Board Settings opens again") { shell.spaceSettings != nil && shell.boardSettingsPanel?.hostView != nil }
            let reopened = try XCTUnwrap(shell.boardSettingsPanel)
            XCTAssertFalse(reopened === form)

            XCTAssertEqual(reopened.repositoryField.stringValue, "acme/widgets")
            try click(reopened.saveButton)
            XCTAssertEqual(BoardConfigStore(spaceID: space.id)?.load().config?.repository, "acme/widgets")
            try waitUntil("the saved config is read, then the pull requests") {
                BoardStagesClicks.wasUpdated(board) && !board.view.stages.lineViews.isEmpty
            }
            XCTAssertEqual(board.view.stages.lineViews.map(\.line.title), ["widgets"])
            XCTAssertEqual(try BoardStagesClicks.section("widgets", in: board).lines.withoutTask.flatMap(\.lines).map(\.pullRequest),
                           ["#12", "#13"], "no worktree for either pull request")
            XCTAssertFalse(client.calls.contains { $0.what.hasPrefix("run") }, "no post-merge workflow chosen yet")
        }
    }

    /// A repository board.json has no config for (the user's spaces had
    /// none, and their Board looked empty): its worktrees and the pull
    /// requests of the repository Board Settings would suggest show,
    /// read-only, with no merge queue and nothing written. Here origin is
    /// a fork and main tracks upstream: both read upstream. Its pill says
    /// so, Board Settings opens from its menu, and saving it sets the
    /// queue up.
    @MainActor
    func testARepositoryWithoutSettingsShowsItsRemoteReadOnly() throws {
        let client = makeClient()
        try withShell(client: client) { shell, space in
            shell.mergeQueueClient = FakeQueueClient(isDryRun: true)
            shell.mergeQueueLockFolder = URL(fileURLWithPath: root + "/locks")
            let repo = root + "/widgets"
            try BoardConfigSuggestionsTests.makeRepository(at: repo, remote: "https://github.com/me/widgets.git")
            try git(["remote", "add", "upstream", "https://github.com/acme/widgets.git"], at: repo)
            try git(["update-ref", "refs/remotes/upstream/main", "HEAD"], at: repo)
            try git(["symbolic-ref", "refs/remotes/upstream/HEAD", "refs/remotes/upstream/main"], at: repo)
            try git(["config", "branch.main.remote", "upstream"], at: repo)
            try git(["config", "branch.main.merge", "refs/heads/main"], at: repo)
            let login = root + "/widgets.feat-login"
            try git(["worktree", "add", "-q", "-b", "feat/login", login], at: repo)
            var anchor = try XCTUnwrap(FolderIdentity.identify(repo, timeout: 10)).anchor
            anchor.isDefault = true
            XCTAssertTrue(shell.workspaceStore.setAnchors([anchor], forProfile: space.id))
            shell.addWorkspace(title: "login", cwd: login, profileID: space.id)
            try select("login", in: shell)

            try runPaletteAction("Open Board", in: shell)
            let board = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id)?.board)
            dropWorkspaceSnapshots(shell)
            try waitUntil("origin’s pull requests are read") {
                BoardStagesClicks.wasUpdated(board) && board.view.stages.lineViews.contains { $0.line.title == "login" }
            }
            XCTAssertNil(shell.boardSettingsPanel, "the board has lines: Board Settings doesn’t open over them")
            XCTAssertEqual(board.view.header.context, "acme/widgets")
            XCTAssertEqual(try BoardStagesClicks.line("login", in: board).line.pullRequest, "#12")
            XCTAssertTrue(client.calls.contains { $0.what == "pr open acme/widgets" })
            XCTAssertFalse(client.calls.contains { $0.what.hasPrefix("run") }, "no post-merge workflow from origin")

            // Read-only: no queue, nothing written, and the repository's pill says so.
            var section = try XCTUnwrap(board.view.stages.content?.sections.first)
            XCTAssertNil(section.queue)
            XCTAssertNil(try BoardStagesClicks.line("login", in: board).line.offer, "its Merge station does nothing")
            let store = try XCTUnwrap(BoardConfigStore(spaceID: space.id))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
            XCTAssertEqual(section.status?.text, "No settings")
            XCTAssertEqual(section.status?.toolTip, "Read-only, from upstream: save Board Settings to use the merge queue.")
            let header = try XCTUnwrap(board.view.stages.sectionHeader(section: section.id))
            XCTAssertEqual(header.pill.status?.text, "No settings")

            try BoardStagesClicks.choose("Board Settings…", in: header.contextMenu())
            try waitUntil("Board Settings opens") { shell.boardSettingsPanel?.hostView != nil }
            let form = try XCTUnwrap(shell.boardSettingsPanel)
            XCTAssertEqual(shell.spaceSettings?.boardRepository, section.id, "on that repository")
            XCTAssertEqual(form.repositoryField.stringValue, "acme/widgets")
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "opening the form writes nothing")
            try click(form.saveButton)
            try waitUntil("the saved settings set the queue up") { board.view.stages.content?.sections.first?.queue != nil }
            section = try XCTUnwrap(board.view.stages.content?.sections.first)
            XCTAssertNotEqual(section.status?.text, "No settings", "nothing left to say")
            XCTAssertNotNil(try BoardStagesClicks.line("login", in: board).line.offer)
        }
    }

    /// Why a repository shows no pull requests is said in plain words, in
    /// its header's pill, under the pointer: gh signed out, in red; origin
    /// on another host, or the repository another section reads. Board
    /// Settings… is in the menu of each repository it can set up, and opens
    /// on it.
    @MainActor
    func testTheBoardSaysWhyItShowsNoPullRequests() throws {
        let client = FakeGitHub(
            openPullRequests: "[]", runs: "[]", failures: ["acme/front": .notSignedIn(nil), "acme/back": .notSignedIn(nil)]
        )
        try withShell(client: client) { shell, space in
            shell.mergeQueueClient = FakeQueueClient(isDryRun: true)
            shell.mergeQueueLockFolder = URL(fileURLWithPath: root + "/locks")
            let remotes = [
                "saved": "https://github.com/acme/saved.git", "front": "git@github.com:acme/front.git",
                "back": "https://github.com/acme/back.git", "docs": "https://gitlab.com/acme/docs.git",
                "copy": "https://github.com/acme/front.git"
            ]
            var anchors: [SpaceAnchor] = []
            for name in ["saved", "front", "back", "docs", "copy"] {
                try BoardConfigSuggestionsTests.makeRepository(at: root + "/" + name, remote: remotes[name])
                var anchor = try XCTUnwrap(FolderIdentity.identify(root + "/" + name, timeout: 10)).anchor
                anchor.isDefault = name == "saved"
                anchors.append(anchor)
            }
            XCTAssertTrue(shell.workspaceStore.setAnchors(anchors, forProfile: space.id))
            let saved = BoardConfig(repository: "acme/saved", baseBranch: "main", requiredChecks: ["test"], postMergeWorkflow: .noWorkflow)
            XCTAssertNoThrow(try XCTUnwrap(BoardConfigStore(spaceID: space.id)).save(entries: [
                BoardConfigStore.Entry(slot: .anchor(commonDir: try XCTUnwrap(BoardSections.commonDir(of: anchors[0]))), config: saved)
            ]).get())
            shell.addWorkspace(title: "front", cwd: root + "/front", profileID: space.id)
            try select("front", in: shell)
            try runPaletteAction("Open Board", in: shell)
            let board = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id)?.board)
            dropWorkspaceSnapshots(shell)

            let signedOut = "gh isn’t signed in to GitHub: run gh auth login in a terminal, then Refresh."
            let pills = { (board.view.stages.content?.sections ?? []).map { [$0.title, $0.status?.text ?? "-", $0.status?.toolTip ?? "-"] } }
            let expected = [
                ["saved", "-", "-"],
                ["front", "GitHub error", signedOut], ["back", "GitHub error", signedOut],
                ["docs", "No settings",
                 "origin points to gitlab.com, not github.com: set its GitHub repository in Board Settings to see its pull requests."],
                ["copy", "Not read", "Same GitHub repository as “front”: its pull requests show there."]
            ]
            try waitUntil("both answers said, every repository listed") { pills() == expected }
            XCTAssertEqual(pills(), expected)
            let sections = try XCTUnwrap(board.view.stages.content?.sections)
            XCTAssertEqual(sections.map(\.detail), ["acme/saved", "acme/front", "acme/back", nil, nil])
            // Board Settings… where it can set the repository up; Open Main Checkout everywhere, a main checkout without
            // a workspace being no line.
            XCTAssertEqual(sections.map { $0.menu.map(\.title) }, [
                ["Board Settings…", "Open Main Checkout"], ["Board Settings…", "Open Main Checkout"],
                ["Board Settings…", "Open Main Checkout"], ["Board Settings…", "Open Main Checkout"], ["Open Main Checkout"]
            ])
            XCTAssertEqual(board.view.stages.sectionHeader(section: sections[1].id)?.pill.status?.tone, .error)
            XCTAssertFalse(client.calls.contains { $0.what.contains("docs") }, "no gh for a repository elsewhere")
            XCTAssertNil(shell.boardSettingsPanel)

            try BoardStagesClicks.choose("Board Settings…", in: board.view.stages.sectionHeader(section: sections[1].id)?.contextMenu())
            try waitUntil("Board Settings opens on front") {
                shell.boardSettingsPanel?.hostView != nil && shell.spaceSettings?.boardRepository == sections[1].id
            }
            XCTAssertEqual(shell.boardSettingsPanel?.repositoryField.stringValue, "acme/front")
        }
    }

    /// Board Settings… on a repository brings an open form to it, even one
    /// added to the space after the form opened, which its pop-up doesn't
    /// list.
    @MainActor
    func testBoardSettingsSwitchesAnOpenFormToTheRepositoryAsked() throws {
        try withShell(client: makeClient()) { shell, space in
            let front = root + "/front"
            let back = root + "/back"
            try BoardConfigSuggestionsTests.makeRepository(at: front, remote: "https://github.com/acme/front.git")
            try BoardConfigSuggestionsTests.makeRepository(at: back, remote: "https://github.com/acme/back.git")
            var frontAnchor = try XCTUnwrap(FolderIdentity.identify(front, timeout: 10)).anchor
            frontAnchor.isDefault = true
            let backAnchor = try XCTUnwrap(FolderIdentity.identify(back, timeout: 10)).anchor
            let frontKey = try XCTUnwrap(frontAnchor.key)
            let backKey = try XCTUnwrap(backAnchor.key)
            XCTAssertTrue(shell.workspaceStore.setAnchors([frontAnchor], forProfile: space.id))
            shell.showBoardSettings(profileID: space.id)
            try waitUntil("front’s form") { shell.boardSettingsPanel?.repositoryField.stringValue == "acme/front" }
            XCTAssertEqual(shell.boardSettingsPanel?.repositoryChoices.count, 0, "one repository: no pop-up")
            // On the repository it shows already, the form stays as it is.
            let frontForm = shell.boardSettingsPanel
            shell.showBoardSettings(profileID: space.id, repository: frontKey)
            XCTAssertIdentical(shell.boardSettingsPanel, frontForm, "not read again")

            XCTAssertTrue(shell.workspaceStore.setAnchors([frontAnchor, backAnchor], forProfile: space.id))
            shell.showBoardSettings(profileID: space.id, repository: backKey)
            try waitUntil("back’s form") {
                shell.spaceSettings?.boardRepository == backKey
                    && shell.boardSettingsPanel?.repositoryField.stringValue == "acme/back"
            }
            XCTAssertEqual(shell.boardSettingsPanel?.repositoryChoices.map(\.id), [frontKey, backKey])
        }
    }

    /// Board Settings won't save, for one repository, the GitHub repository
    /// another one of the space shows read-only: it would take it from it.
    /// The one showing it saves it, then saves it again.
    @MainActor
    func testSavingWhatAnotherRepositoryShowsIsRefused() throws {
        try withShell(client: makeClient()) { shell, space in
            let front = root + "/front"
            let copy = root + "/copy"
            try BoardConfigSuggestionsTests.makeRepository(at: front, remote: "https://github.com/acme/front.git")
            try BoardConfigSuggestionsTests.makeRepository(at: copy, remote: "https://github.com/acme/front.git")
            var frontAnchor = try XCTUnwrap(FolderIdentity.identify(front, timeout: 10)).anchor
            frontAnchor.isDefault = true
            let copyAnchor = try XCTUnwrap(FolderIdentity.identify(copy, timeout: 10)).anchor
            let copyKey = try XCTUnwrap(copyAnchor.key)
            XCTAssertTrue(shell.workspaceStore.setAnchors([frontAnchor, copyAnchor], forProfile: space.id))
            shell.showBoardSettings(profileID: space.id, repository: copyKey)
            try waitUntil("copy’s form") {
                shell.spaceSettings?.boardRepository == copyKey
                    && shell.boardSettingsPanel?.repositoryField.stringValue == "acme/front"
            }
            let form = try XCTUnwrap(shell.boardSettingsPanel)
            try click(form.saveButton)
            XCTAssertFalse(form.errorLabel.isHidden)
            XCTAssertEqual(
                form.errorLabel.stringValue,
                "“front” of this space shows acme/front already, read-only: set it up there, or use another GitHub repository here."
            )
            let store = try XCTUnwrap(BoardConfigStore(spaceID: space.id))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))

            let frontKey = try XCTUnwrap(frontAnchor.key)
            shell.showBoardSettings(profileID: space.id, repository: frontKey)
            try waitUntil("front’s form") {
                shell.spaceSettings?.boardRepository == frontKey && shell.boardSettingsPanel !== form
                    && shell.boardSettingsPanel?.repositoryField.stringValue == "acme/front"
            }
            for round in ["saved", "saved again"] {
                let frontForm = try XCTUnwrap(shell.boardSettingsPanel)
                try click(frontForm.saveButton)
                XCTAssertTrue(frontForm.errorLabel.isHidden, "\(round): \(frontForm.errorLabel.stringValue)")
                try waitUntil("front \(round)") { shell.boardSettingsPanel !== frontForm && shell.boardSettingsPanel?.hostView != nil }
                XCTAssertEqual(store.load().entries.map(\.config.repository), ["acme/front"], round)
            }
        }
    }

    /// A repository whose checkout is gone says so, without Board
    /// Settings…: settings can't bring it back.
    @MainActor
    func testAGoneCheckoutSaysSoWithoutBoardSettings() throws {
        try withShell(client: makeClient()) { shell, space in
            let repo = root + "/widgets"
            try BoardConfigSuggestionsTests.makeRepository(at: repo, remote: "https://github.com/acme/widgets.git")
            var anchor = try XCTUnwrap(FolderIdentity.identify(repo, timeout: 10)).anchor
            anchor.isDefault = true
            XCTAssertTrue(shell.workspaceStore.setAnchors([anchor], forProfile: space.id))
            try FileManager.default.removeItem(atPath: repo)
            shell.addWorkspace(title: "home", cwd: root, profileID: space.id)
            try select("home", in: shell)
            try runPaletteAction("Open Board", in: shell)
            let board = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id)?.board)
            try waitUntil("the reason") { board.view.stages.content?.sections.first?.status != nil }
            let section = try XCTUnwrap(board.view.stages.content?.sections.first)
            XCTAssertEqual(section.status?.text, "Not read")
            XCTAssertEqual(
                section.status?.toolTip,
                "Its checkout is gone, or no longer a git repository: Refresh once it’s back, or remove it in Space Settings."
            )
            XCTAssertEqual(section.menu, [], "no Board Settings…: settings can't bring it back")
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
            try runPaletteAction("Open Board", in: shell)
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
            // As a status refresh would, on screen (this window never is).
            board.tick(onScreen: true)
            try waitUntil("the new workflow's run is read") {
                client.calls.contains { $0.what == "run acme/widgets nightly.yml main" }
            }
            XCTAssertFalse(client.calls[before...].contains { $0.what.contains("ci.yml") },
                           "\(client.calls[before...].map(\.what))")
        }
    }

    /// A Board shows its workspace's space: moved, it shows the new one;
    /// moved into a space that has its Board, it closes (a shell stays where
    /// it was alone) and that one comes to the front; its space deleted, it
    /// goes to General with its workspace.
    @MainActor
    func testABoardShowsItsWorkspacesSpace() throws {
        let client = makeClient()
        try withShell(client: client) { shell, space in
            let other = shell.workspaceStore.createProfile(named: "Gadgets")
            let third = shell.workspaceStore.createProfile(named: "Tools")
            // Configured: no Board Settings sheet opens by itself.
            for configured in [space, other, third] { try writeConfig(for: configured, workflow: "nightly.yml") }
            shell.addWorkspace(title: "gadgets", cwd: root, profileID: other.id)
            try runPaletteAction("Open Board", in: shell)
            let gadgets = try XCTUnwrap(shell.projectBoardLocation(projectID: other.id))
            shell.addWorkspace(title: "widgets", cwd: root, profileID: space.id)
            try runPaletteAction("Open Board", in: shell)
            let widgets = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id))
            XCTAssertFalse(widgets.board.view.header.currentMenu().items.contains { $0.title == "Space" }, "no space to pick")

            // To Tools, which has no Board: the Board shows Tools, its tasks.
            shell.addWorkspace(title: "tools task", cwd: root, profileID: third.id)
            let toolsTask = try XCTUnwrap(shell.workspaces.first { $0.title == "tools task" })
            try select("widgets", in: shell)
            XCTAssertEqual(widgets.board.stagesReadings.map { Set($0.keys) }, [widgets.workspace.id])
            shell.moveWorkspaceToSpace(workspaceID: widgets.workspace.id, profileID: third.id)
            XCTAssertEqual(widgets.board.projectID, third.id)
            XCTAssertEqual(widgets.board.stagesReadings.map { Set($0.keys) }, [toolsTask.id, widgets.workspace.id])
            XCTAssertEqual(widgets.board.view.stages.content?.header.name, "Tools")
            XCTAssertEqual(widgets.board.view.header.titleToolTip, "Board · Tools")

            // To Gadgets, which has its Board: this one closes, that one comes to the front.
            shell.moveWorkspaceToSpace(workspaceID: widgets.workspace.id, profileID: other.id)
            XCTAssertEqual(shell.projectBoardLocations.map(\.board.projectID), [other.id])
            XCTAssertFalse(widgets.workspace.columns.contains(where: \.isProjectBoard))
            XCTAssertFalse(widgets.workspace.columns.isEmpty)
            XCTAssertTrue(shell.activeWorkspace === gadgets.workspace)
            XCTAssertEqual(shell.toast?.message, "This space has its Board already")

            // A Board alone in its workspace leaves a shell there.
            shell.addWorkspace(title: "solo", cwd: root, profileID: third.id)
            try runPaletteAction("Open Board", in: shell)
            let solo = try XCTUnwrap(shell.projectBoardLocation(projectID: third.id))
            let shellColumn = try XCTUnwrap(solo.workspace.columns.firstIndex { !$0.isProjectBoard })
            solo.workspace.closeColumn(at: shellColumn)
            XCTAssertEqual(solo.workspace.columns.count, 1)
            shell.moveWorkspaceToSpace(workspaceID: solo.workspace.id, profileID: other.id)
            XCTAssertEqual(solo.workspace.columns.count, 1)
            XCTAssertNotNil(solo.workspace.columns.first?.pty, "a shell in its folder")
            XCTAssertEqual(shell.projectBoardLocations.map(\.board.projectID), [other.id])

            // Gadgets deleted: its workspaces go to General, and its Board shows General.
            shell.deleteSpace(profileID: other.id)
            XCTAssertEqual(gadgets.board.projectID, WorkspaceProfile.defaultID)
            let general = try XCTUnwrap(shell.profiles.first { $0.id == WorkspaceProfile.defaultID }?.name)
            XCTAssertEqual(gadgets.board.view.header.titleToolTip, "Board · \(general)")
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
            try runPaletteAction("Open Board", in: shell)
            state = shell.persistedState()
        }
        var saved = try XCTUnwrap(state)
        let index = try XCTUnwrap(saved.workspaces.firstIndex { $0.title == "widgets" })
        let column = try XCTUnwrap(saved.workspaces[index].columns.first { $0.columnType == .projectBoard })
        XCTAssertEqual(column.boardProjectID, spaceID)
        XCTAssertEqual(column.cwd, root, "an older build opens a terminal in the workspace's folder")
        // A hand-edited state with a second board for the project; the first saved on another space by an older
        // build, whose header could switch it.
        saved.workspaces[index].columns.append(column)
        let first = try XCTUnwrap(saved.workspaces[index].columns.firstIndex { $0.columnType == .projectBoard })
        saved.workspaces[index].columns[first].boardProjectID = "another-space"

        try withShell(client: client, restoring: saved) { shell, _ in
            XCTAssertEqual(shell.projectBoardLocations.count, 1)
            let workspace = try XCTUnwrap(shell.workspaces.first { $0.title == "widgets" })
            XCTAssertEqual(workspace.columns.filter(\.isProjectBoard).count, 1)
            XCTAssertEqual(workspace.columns.count, 3, "the second board came back as a terminal")
            XCTAssertNotNil(workspace.columns.last?.pty)
            XCTAssertEqual(shell.projectBoardLocations.map(\.board.projectID), [spaceID], "its workspace's space")
        }
    }

    /// A space with two repositories (docs/design/spaces.md, S12): a section
    /// for each, each read on its own repository with its queue in its
    /// header, and a pull request queued and started in its own
    /// repository's queue only.
    @MainActor
    func testEachRepositoryOfTheSpaceHasItsSectionAndItsQueue() throws {
        let pullRequest = { (number: Int, branch: String, repository: String) in
            """
            [{"number": \(number), "state": "OPEN", "headRefName": "\(branch)", "headRefOid": "\(String(repeating: "a", count: 40))",
              "headRepository": {"name": "\(repository)"}, "headRepositoryOwner": {"login": "acme"}, "baseRefName": "main",
              "isDraft": false, "mergeable": "MERGEABLE", "url": "https://github.com/acme/\(repository)/pull/\(number)",
              "statusCheckRollup": []}]
            """
        }
        let client = FakeGitHub(openPullRequests: "[]", runs: "[]", openByRepository: [
            "acme/front": pullRequest(12, "feat/login", "front"),
            "acme/back": pullRequest(21, "feat/api", "back")
        ])
        try withShell(client: client) { shell, space in
            shell.mergeQueueClient = FakeQueueClient(isDryRun: true)
            shell.mergeQueueLockFolder = URL(fileURLWithPath: root + "/locks")
            let front = root + "/front"
            let back = root + "/back"
            let docs = root + "/docs"
            try BoardConfigSuggestionsTests.makeRepository(at: front, remote: "https://github.com/acme/front.git")
            try BoardConfigSuggestionsTests.makeRepository(at: back, remote: "git@github.com:acme/back.git")
            // No remote and no config: only its anchor puts it in its section.
            try BoardConfigSuggestionsTests.makeRepository(at: docs, remote: nil)
            try git(["worktree", "add", "-q", "-b", "feat/login", root + "/front.login"], at: front)
            try git(["worktree", "add", "-q", "-b", "feat/api", root + "/back.api"], at: back)
            var frontAnchor = try XCTUnwrap(FolderIdentity.identify(front, timeout: 10)).anchor
            frontAnchor.isDefault = true
            let backAnchor = try XCTUnwrap(FolderIdentity.identify(back, timeout: 10)).anchor
            let docsAnchor = try XCTUnwrap(FolderIdentity.identify(docs, timeout: 10)).anchor
            XCTAssertTrue(shell.workspaceStore.setAnchors([frontAnchor, backAnchor, docsAnchor], forProfile: space.id))
            let config = { (name: String) in
                BoardConfig(repository: "acme/\(name)", baseBranch: "main", requiredChecks: ["test"], postMergeWorkflow: .noWorkflow)
            }
            let store = try XCTUnwrap(BoardConfigStore(spaceID: space.id))
            XCTAssertNoThrow(try store.save(entries: [
                BoardConfigStore.Entry(slot: .anchor(commonDir: try XCTUnwrap(BoardSections.commonDir(of: frontAnchor))), config: config("front")),
                BoardConfigStore.Entry(slot: .anchor(commonDir: try XCTUnwrap(BoardSections.commonDir(of: backAnchor))), config: config("back"))
            ]).get())

            shell.addWorkspace(title: "login", cwd: root + "/front.login", profileID: space.id)
            shell.addWorkspace(title: "api", cwd: root + "/back.api", profileID: space.id)
            try select("login", in: shell)
            try runPaletteAction("Open Board", in: shell)
            let board = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id)?.board)
            dropWorkspaceSnapshots(shell)

            let lines = { (board.view.stages.content?.sections ?? []).map { $0.lines.units.flatMap(\.lines).map(\.pullRequest) } }
            try waitUntil("both repositories read, docs’ remote too") {
                lines() == [["#12"], ["#21"], []] && board.view.stages.content?.sections.last?.status != nil
            }
            let sections = try XCTUnwrap(board.view.stages.content?.sections)
            XCTAssertEqual(sections.map(\.title), ["front", "back", "docs"], "the default repository first")
            XCTAssertEqual(sections.map(\.detail), ["acme/front", "acme/back", nil])
            XCTAssertEqual(sections[2].status?.text, "No settings", "it says to set its GitHub repository")
            XCTAssertEqual(board.view.header.context, space.name, "the header names the space, not one repository")
            XCTAssertEqual(sections.map { $0.queue != nil }, [true, true, false], "docs has no queue")
            XCTAssertTrue(client.calls.contains { $0.what == "pr open acme/back" })

            // A click on #21's Merge station: back's queue only.
            try BoardStagesClicks.pressMerge(try BoardStagesClicks.line("api", in: board))
            let backRepository = GitHubRepository(owner: "acme", name: "back")
            let frontRepository = GitHubRepository(owner: "acme", name: "front")
            XCTAssertEqual(shell.mergeQueue(projectID: space.id, repository: backRepository).selection, [21])
            XCTAssertEqual(shell.mergeQueue(projectID: space.id, repository: frontRepository).selection, [])
            // A line held in place under the pointer may show another repository's pull request by now: its number
            // never goes to this section's queue.
            shell.performBoardOffer(BoardStages.QueueOffer(change: .add, number: 21), section: sections[0].id, board: board)
            XCTAssertEqual(shell.mergeQueue(projectID: space.id, repository: frontRepository).selection, [])
            let backHeader = try XCTUnwrap(board.view.stages.sectionHeader(section: sections[1].id))
            let frontHeader = try XCTUnwrap(board.view.stages.sectionHeader(section: sections[0].id))
            try waitUntil("back's header offers Start") { backHeader.startButton.isEnabled }
            XCTAssertEqual(backHeader.startButton.title, "Start Dry Run… · 1")
            XCTAssertFalse(frontHeader.startButton.isEnabled, "front has nothing queued")

            try BoardStagesClicks.click(backHeader.startButton)
            let sheet = try XCTUnwrap(shell.mergeQueueConfirmation)
            XCTAssertEqual(sheet.repository, backRepository)
            sheet.dismiss()

            // Back's main checkout has no workspace: Open Main Checkout opens a shell there.
            try BoardStagesClicks.choose("Open Main Checkout", in: backHeader.contextMenu())
            try waitUntil("a workspace opens there") { shell.activeWorkspace?.cwd == back }
            XCTAssertEqual(shell.activeWorkspace?.profileID, space.id)
        }
    }

    /// A queue still running on the repository Board Settings just replaced
    /// keeps its line at the Board's foot, with its Stop, named after its
    /// repository; the repository's header shows the Board's own queue.
    @MainActor
    func testAQueueLeftOnAnotherRepositoryKeepsItsStop() throws {
        try withShell(client: makeClient()) { shell, space in
            var world = MQ.World()
            world.pullRequests[52] = MQ.pullRequest(52, head: MQ.sha("a"))
            world.checks[MQ.sha("a")] = MQ.checks(MQ.checkRun(id: 1, status: "IN_PROGRESS", conclusion: nil))
            shell.mergeQueueClient = FakeQueueClient(world: world, isDryRun: true)
            shell.mergeQueueLockFolder = URL(fileURLWithPath: root + "/locks")
            let repo = root + "/widgets"
            try BoardConfigSuggestionsTests.makeRepository(at: repo, remote: "https://github.com/acme/widgets.git")
            try writeConfig(for: space, workflow: "nightly.yml")
            shell.addWorkspace(title: "widgets", cwd: repo, profileID: space.id)
            try select("widgets", in: shell)
            try runPaletteAction("Open Board", in: shell)
            let board = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id)?.board)
            dropWorkspaceSnapshots(shell)

            let queue = shell.mergeQueue(projectID: space.id, repository: MQ.widgets)
            queue.beginActivity = { NSObject() }
            queue.endActivity = { _ in }
            XCTAssertNil(queue.start(settings: MQ.settings(), entries: [MQ.entry(52, head: MQ.sha("a"))]))
            let gadgets = BoardConfig(repository: "acme/gadgets", baseBranch: "main", requiredChecks: ["test"],
                                      postMergeWorkflow: .noWorkflow)
            XCTAssertNoThrow(try XCTUnwrap(BoardConfigStore(spaceID: space.id)).save(gadgets).get())

            try waitUntil("a line at the foot shows the widgets queue") {
                shell.renderProjectBoard(board)
                return board.view.stages.runningQueueViews.map(\.queue.title) == ["acme/widgets"]
                    && board.view.stages.content?.sections.first?.detail == "acme/gadgets"
            }
            XCTAssertEqual(board.repository?.name, "acme/gadgets")
            let section = try XCTUnwrap(board.view.stages.content?.sections.first)
            XCTAssertNotNil(section.queue, "gadgets' queue, in its header")
            XCTAssertNil(section.queue?.stop, "which doesn't run")
            let line = try XCTUnwrap(board.view.stages.runningQueueViews.first)
            BoardStagesClicks.layOut(line)
            XCTAssertEqual(line.queue.tooltip, "Its queue runs, but it isn’t one of this board’s repositories now.")
            XCTAssertFalse(line.stopButton.isHidden)
            try BoardStagesClicks.click(line.stopButton)
            try waitUntil("the widgets queue stops") { !queue.isRunning }
            MergeQueueController.waitForFiles()
        }
    }

    // MARK: - What the stages add

    /// The line's menu, the repository's, the Lead in the space's header,
    /// the Lead's worktree and the order switch each run what they say.
    @MainActor
    func testTheMenusTheLeadAndTheOrderRunWhatTheySay() throws {
        try withShell(client: makeClient()) { shell, space in
            let repo = root + "/widgets"
            try BoardConfigSuggestionsTests.makeRepository(at: repo, remote: "https://github.com/acme/widgets.git")
            let login = root + "/widgets.feat-login"
            let notes = root + "/widgets.lead-notes"
            try git(["worktree", "add", "-q", "-b", "feat/login", login], at: repo)
            try git(["worktree", "add", "-q", "-b", "lead/notes", notes], at: repo)
            try writeConfig(for: space, workflow: "nightly.yml")
            shell.addWorkspace(title: "widgets", cwd: repo, profileID: space.id)
            shell.addWorkspace(title: "Lead", cwd: notes, profileID: space.id, isLead: true)
            shell.addWorkspace(title: "login", cwd: login, profileID: space.id)
            try select("login", in: shell)
            try runPaletteAction("Open Board", in: shell)
            let board = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id)?.board)
            dropWorkspaceSnapshots(shell)
            try waitUntil("the pull requests are read") {
                BoardStagesClicks.wasUpdated(board) && board.view.stages.lineViews.contains { $0.line.pullRequest == "#12" }
            }
            var opened: [URL] = []
            shell.sideEffects.openURL = { opened.append($0) }

            // The line's menu: its pull request on GitHub.
            try BoardStagesClicks.choose("Open Pull Request", in: try BoardStagesClicks.line("login", in: board).contextMenu())
            XCTAssertEqual(opened, [URL(string: "https://github.com/acme/widgets/pull/12")])

            // The repository's menu: its main checkout's workspace.
            let section = try BoardStagesClicks.section("widgets", in: board)
            try BoardStagesClicks.choose("Open Main Checkout", in: board.view.stages.sectionHeader(section: section.id)?.contextMenu())
            XCTAssertEqual(shell.activeWorkspace?.title, "widgets")

            // The Lead, in the space's header: its workspace.
            try select("login", in: shell)
            dropWorkspaceSnapshots(shell)
            XCTAssertEqual(board.view.stages.content?.header.lead?.text, "Lead · No activity yet")
            try BoardStagesClicks.click(board.view.stages.leadButton)
            XCTAssertEqual(shell.activeWorkspace?.title, "Lead")

            // The Lead's linked worktree, under Other worktrees: Focus.
            try select("login", in: shell)
            dropWorkspaceSnapshots(shell)
            XCTAssertEqual(section.lines.otherWorktrees.map(\.title), ["Lead · lead/notes"])
            try BoardStagesClicks.click(try XCTUnwrap(board.view.stages.worktreesFold(section: section.id)))
            board.view.stages.layoutSubtreeIfNeeded()
            let lead = try XCTUnwrap(board.view.stages.worktreeViews.first { $0.worktree?.path == notes })
            XCTAssertEqual(lead.openButton.title, "Focus")
            try BoardStagesClicks.click(lead.openButton)
            XCTAssertEqual(shell.activeWorkspace?.title, "Lead")

            // A task's line clicked once it departed (held faded under the pointer): its workspace where it went, else
            // the table's word that it was closed.
            try select("login", in: shell)
            board.view.stages.onTaskGone?(try XCTUnwrap(shell.workspaces.first { $0.title == "widgets" }?.id))
            XCTAssertEqual(shell.activeWorkspace?.title, "widgets")
            board.view.stages.onTaskGone?("a workspace closed since")
            XCTAssertEqual(shell.toast?.message, "That workspace was closed")

            // The order switch: every Board shown takes it (a hidden one when it shows next), and it is saved.
            try select("login", in: shell)
            XCTAssertEqual(board.view.stages.content?.order, .sidebar)
            let orderSwitch = board.view.stages.orderSwitch
            orderSwitch.selectedSegment = 1
            _ = (orderSwitch.target as? NSObject)?.perform(orderSwitch.action, with: orderSwitch)
            XCTAssertEqual(shell.boardOrder, .progress)
            XCTAssertEqual(board.view.stages.content?.order, .progress)
            XCTAssertEqual(orderSwitch.selectedSegment, 1)
            XCTAssertEqual(Persistence.load()?.settings?.boardOrder, .progress)
            // Hidden while another Board's switch went back, it still shows the old order: its switch on the order set
            // draws it in it at once.
            shell.boardOrder = .sidebar
            orderSwitch.selectedSegment = 0
            _ = (orderSwitch.target as? NSObject)?.perform(orderSwitch.action, with: orderSwitch)
            XCTAssertEqual(board.view.stages.content?.order, .sidebar)
            XCTAssertEqual(orderSwitch.selectedSegment, 0)
        }
    }

    /// The Board reads its tasks as the sidebar's pass read them (a question
    /// to the Lead, which reading again would note twice), and keeps that
    /// reading for a render between two passes; the next pass replaces it.
    @MainActor
    func testTheBoardReadsTheSidebarsPassAndKeepsItBetweenPasses() throws {
        try withShell(client: makeClient()) { shell, space in
            let repo = root + "/widgets"
            try BoardConfigSuggestionsTests.makeRepository(at: repo, remote: "https://github.com/acme/widgets.git")
            let login = root + "/widgets.feat-login"
            try git(["worktree", "add", "-q", "-b", "feat/login", login], at: repo)
            try writeConfig(for: space, workflow: "nightly.yml")
            shell.addWorkspace(title: "widgets", cwd: repo, profileID: space.id)
            shell.addWorkspace(title: "login", cwd: login, profileID: space.id)
            try select("widgets", in: shell)
            try runPaletteAction("Open Board", in: shell)
            let board = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id)?.board)
            try waitUntil("the login task's line") { BoardStagesClicks.shownLine("login", in: board) != nil }
            let column = try XCTUnwrap(shell.workspaces.first { $0.title == "login" }?.columns.first)
            let question = SidebarMissionQuestion(questionID: "q", parentTitle: "Lead", text: "Which base?", handOff: nil)
            let pass = NiruxShellView.SidebarPassReadings(
                infos: [], foregroundProcesses: [:], approvalHolds: [:], missionQuestions: [ObjectIdentifier(column): question]
            )
            let phrase = { BoardStagesClicks.shownLine("login", in: board)?.line.phrase.text }

            shell.renderProjectBoard(board, pass: pass)
            XCTAssertEqual(phrase(), "Asking Lead")
            shell.renderProjectBoard(board)
            XCTAssertEqual(phrase(), "Asking Lead", "between two passes: the last pass's reading")
            shell.updateSidebar()
            XCTAssertNotEqual(phrase(), "Asking Lead", "the next pass's")
        }
    }

    /// Resume after an error answers that failed turn only, and one that
    /// names none does nothing; after an exit, it opens the conversation
    /// again: the table's Resume. A restored agent is the sidebar's.
    func testResumeAfterAnErrorOrAnExitIsTheTablesResume() {
        let column = UUID()
        let resume = { (kind: BoardStages.Resume.Kind, failedAt: TimeInterval?) in
            NiruxShellView.resumeAction(BoardStages.Resume(kind: kind, column: column, failedAt: failedAt), workspaceID: "w")
        }
        XCTAssertEqual(resume(.afterError, 700), .resumeFailed(workspaceID: "w", columnID: column, failedAt: 700))
        XCTAssertNil(resume(.afterError, nil))
        XCTAssertEqual(resume(.afterExit, nil), .resumeExited(workspaceID: "w", columnID: column))
        XCTAssertNil(resume(.afterRelaunch, nil))
    }

    /// "Clean up" on a "Merged today" entry: the task's line has left the
    /// list, and the clean-up checks its worktree, as the table's Clean Up…
    /// did.
    @MainActor
    func testMergedTodaysCleanUpChecksItsTasksWorktree() throws {
        // Now: a minute earlier may be yesterday, just after midnight.
        let mergedAt = ISO8601DateFormatter().string(from: Date())
        let merged = """
        [{"number": 12, "state": "MERGED", "headRefName": "feat/login", "headRefOid": "\(String(repeating: "a", count: 40))",
          "headRepository": {"name": "widgets"}, "headRepositoryOwner": {"login": "acme"}, "baseRefName": "main",
          "url": "https://github.com/acme/widgets/pull/12", "title": "Sign in", "mergedAt": "\(mergedAt)", "statusCheckRollup": []}]
        """
        let repo = root + "/widgets"
        try BoardConfigSuggestionsTests.makeRepository(at: repo, remote: "https://github.com/acme/widgets.git")
        let login = root + "/widgets.feat-login"
        try git(["worktree", "add", "-q", "-b", "feat/login", login], at: repo)
        // Pushed elsewhere than GitHub: its clean-up check stops before gh.
        try git(["remote", "add", "local", root + "/elsewhere.git"], at: repo)
        try git(["config", "branch.feat/login.pushRemote", "local"], at: repo)
        // Its worktree is still at the merged head: the task's pull request.
        let head = try git(["rev-parse", "HEAD"], at: login).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = FakeGitHub(
            openPullRequests: "[]", mergedPullRequests: merged.replacingOccurrences(of: String(repeating: "a", count: 40), with: head),
            runs: ProjectBoardGitHubTests.postMergeRuns
        )
        try withShell(client: client) { shell, space in
            try writeConfig(for: space, workflow: "nightly.yml")
            shell.addWorkspace(title: "widgets", cwd: repo, profileID: space.id)
            shell.addWorkspace(title: "Sign in", cwd: login, profileID: space.id)
            try select("widgets", in: shell)
            try runPaletteAction("Open Board", in: shell)
            let board = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id)?.board)
            dropWorkspaceSnapshots(shell)
            let section = { try BoardStagesClicks.section("widgets", in: board) }
            try waitUntil("#12 merged today") {
                BoardStagesClicks.shownSection("widgets", in: board)?.lines.merged.map(\.number) == [12]
                    && board.view.stages.lineViews.count == 1
            }
            XCTAssertEqual(board.view.stages.lineViews.map(\.line.title), ["widgets"], "its task's line left the list")
            let entry = try XCTUnwrap(board.view.stages.mergedView(section: try section().id)?.entries.first)
            XCTAssertEqual(entry.pullRequest.lineID, shell.workspaces.first { $0.title == "Sign in" }?.id)
            XCTAssertTrue(entry.hasLink)

            var alerts: [NSAlert] = []
            shell.sideEffects.runModal = { alert in
                alerts.append(alert)
                return .alertFirstButtonReturn
            }
            try BoardStagesClicks.pressCleanUp(entry)
            try waitUntil("the worktree is checked") { !alerts.isEmpty }
            XCTAssertEqual(alerts.map(\.messageText), ["Can’t clean up widgets.feat-login · feat/login"], "that task's worktree")
            XCTAssertTrue(shell.worktreeCleanupsInFlight.isEmpty)
        }
    }

    /// Resume in a line's menu starts an agent restored at launch that
    /// hasn't resumed, where it is, as the sidebar's Resume does.
    @MainActor
    func testResumeFromTheBoardStartsARestoredAgent() throws {
        let thread = "3c2b1a09-8f7e-4d6c-9b5a-493827160504"
        let notes = root + "/notes"
        try FileManager.default.createDirectory(atPath: notes, withIntermediateDirectories: true)
        var state = PersistedState(
            workspaces: [
                PersistedWorkspace(id: "board", title: "board", cwd: root, columns: [PersistedColumn(
                    widthPreset: 1, cwd: root, columnType: .projectBoard, webViewURL: nil, claudeLaunchMode: nil, codexLaunchMode: nil,
                    boardProjectID: WorkspaceProfile.defaultID
                )], focusedColumnIndex: 0),
                PersistedWorkspace(id: "notes", title: "notes", cwd: notes, columns: [PersistedColumn(
                    widthPreset: 1, cwd: notes, columnType: .codex, webViewURL: nil, claudeLaunchMode: nil, codexLaunchMode: .default,
                    codexSessionID: thread, agentUUID: UUID().uuidString
                )], focusedColumnIndex: 0)
            ],
            activeWorkspaceIndex: 0
        )
        // The order the user chose last time, too.
        var settings = PersistedSettings()
        settings.boardOrder = .progress
        state.settings = settings
        var launches: [String] = []
        try withShell(client: makeClient(), restoring: state, before: { shell in
            shell.sideEffects.startRestoredAgent = { _, command in launches.append(command) }
            XCTAssertNoThrow(try self.writeConfig(for: WorkspaceProfile.defaultProfile, workflow: "nightly.yml"))
        }) { shell, _ in
            let board = try XCTUnwrap(shell.projectBoardLocation(projectID: WorkspaceProfile.defaultID)?.board)
            try waitUntil("the notes task's line") { board.view.stages.lineViews.contains { $0.line.title == "notes" } }
            XCTAssertEqual(launches, [], "off screen, it waits")
            XCTAssertEqual(shell.boardOrder, .progress)
            XCTAssertEqual(board.view.stages.content?.order, .progress)
            let line = try BoardStagesClicks.line("notes", in: board)
            XCTAssertEqual(try BoardStagesClicks.section("No repository", in: board).lines.units.flatMap(\.lines).map(\.title),
                           ["board", "notes"])
            try BoardStagesClicks.choose("Resume", in: line.contextMenu())
            XCTAssertEqual(launches, ["command codex resume '\(thread)'"])
            XCTAssertEqual(shell.activeWorkspace?.title, "board", "the workspace on screen stays")
        }
    }

    // MARK: - Helpers

    /// `before` runs on the shell before it restores `state`.
    @MainActor
    private func withShell(
        client: FakeGitHub,
        restoring state: PersistedState? = nil,
        before: (NiruxShellView) throws -> Void = { _ in },
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
            shell.spaceSettings?.close()
            window.close()
        }
        try before(shell)
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
        contentView.layoutSubtreeIfNeeded()
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
