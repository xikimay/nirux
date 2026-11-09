import AppKit
import XCTest
@testable import Nirux

/// The Board in a real window, from "Open Board" to its
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
            try waitUntil("the pull requests are read") { Self.wasUpdated(board.view) }
            try waitUntil("the post-merge run is read") { board.view.header.status?.toolTip?.contains("success") == true }
            try waitUntil("the worktrees are listed") { !board.view.rowViews.isEmpty }

            XCTAssertEqual(board.view.header.context, "acme/widgets")
            XCTAssertEqual(Self.checkedProject(board.view), "Board")
            let run = try XCTUnwrap(board.view.header.status)
            XCTAssertTrue(run.text.hasPrefix("nightly "), run.text)
            XCTAssertEqual(run.symbol, Theme.Symbol.checksPassed)
            XCTAssertTrue(run.toolTip?.hasPrefix("nightly: success ") == true, run.toolTip ?? "")
            XCTAssertTrue(run.toolTip?.hasSuffix(", 43a9503") == true, run.toolTip ?? "")
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

            // "Open Board" again, from another workspace of the
            // space, brings the board back rather than opening another.
            try runPaletteAction("Open Board", in: shell)
            XCTAssertEqual(shell.activeWorkspace?.title, "widgets")
            XCTAssertEqual(shell.projectBoardLocations.count, 1)
            XCTAssertTrue(shell.activeWorkspace?.columns[shell.activeWorkspace?.focusedIndex ?? -1] === location.column)

            // Clean Up on a worktree no workspace is open in: the flow of
            // "Clean Up Worktree…", by folder.
            try click(try XCTUnwrap(board.view.otherWorktreesToggle))
            XCTAssertEqual(board.view.otherWorktreesToggle?.title, "▾ Other worktrees (1)")
            let scratchRow = try row("scratch", in: board)
            XCTAssertEqual(scratchRow.actions.map(\.title), ["Open", "Clean Up…"])
            var alerts: [NSAlert] = []
            shell.sideEffects.runModal = { alert in
                alerts.append(alert)
                return .alertFirstButtonReturn
            }
            try click(try XCTUnwrap(scratchRow.actions.last))
            try waitUntil("the worktree is checked") { !alerts.isEmpty }
            XCTAssertEqual(alerts.map(\.messageText), ["Can’t clean up widgets.scratch · scratch"], "the #46 notice, for that folder")
            // Stopped before gh either way: not pushed to GitHub, or no gh.
            let problems = alerts.first?.informativeText ?? ""
            XCTAssertTrue(problems.contains("pushed to a GitHub remote") || problems.contains("(gh) isn"), problems)
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

            try runPaletteAction("Open Board", in: shell)
            let board = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id)?.board)
            try waitUntil("Board Settings opens") { shell.boardSettingsPanel?.hostView != nil }
            let form = try XCTUnwrap(shell.boardSettingsPanel)
            XCTAssertEqual(form.spaceID, space.id)
            guard case .message(let message)? = board.view.content?.body else { return XCTFail("no message") }
            XCTAssertTrue(message.contains("Board Settings"), message)
            XCTAssertFalse(board.view.messageSettingsButton.isHidden, "Board Settings… under the message")
            XCTAssertEqual(client.calls, [], "no gh without a repository")

            XCTAssertEqual(form.repositoryField.stringValue, "acme/widgets")
            try click(form.saveButton)
            XCTAssertEqual(BoardConfigStore(spaceID: space.id)?.load().config?.repository, "acme/widgets")
            try waitUntil("the saved config is read, then the pull requests") {
                Self.wasUpdated(board.view) && !board.view.rowViews.isEmpty
            }
            XCTAssertEqual(board.view.rowViews.map(\.row.name), ["widgets", "feat/login", "fix/remote"],
                           "no worktree for either pull request")
            XCTAssertFalse(client.calls.contains { $0.what.hasPrefix("run") }, "no post-merge workflow chosen yet")
        }
    }

    /// A repository board.json has no config for (the user's spaces had
    /// none, and their Board looked empty): its worktrees and the pull
    /// requests of the repository Board Settings would suggest show,
    /// read-only, with no merge queue and nothing written. Here origin is
    /// a fork and main tracks upstream: both read upstream. Board Settings
    /// opens from the line that says so, and saving it sets the queue up.
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
                Self.wasUpdated(board.view) && board.view.rowViews.contains { $0.row.name == "login" }
            }
            XCTAssertNil(shell.boardSettingsPanel, "the board has rows: Board Settings doesn’t open over them")
            XCTAssertEqual(board.view.header.context, "acme/widgets")
            XCTAssertEqual(try row("login", in: board).pullRequest.stringValue, "#12 open")
            XCTAssertTrue(client.calls.contains { $0.what == "pr open acme/widgets" })
            XCTAssertFalse(client.calls.contains { $0.what.hasPrefix("run") }, "no post-merge workflow from origin")

            // Read-only: no queue, nothing written, and a line says so.
            XCTAssertTrue(board.view.queueLabel.isHidden)
            XCTAssertNil(try row("login", in: board).queueButton)
            let store = try XCTUnwrap(BoardConfigStore(spaceID: space.id))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
            XCTAssertEqual(board.view.noticeLines.map(\.label.stringValue), [
                "Read-only, from upstream: save Board Settings to use the merge queue."
            ])
            let notice = try XCTUnwrap(board.view.noticeLines.first)
            XCTAssertFalse(notice.settingsButton.isHidden)

            try click(notice.settingsButton)
            try waitUntil("Board Settings opens") { shell.boardSettingsPanel?.hostView != nil }
            let form = try XCTUnwrap(shell.boardSettingsPanel)
            XCTAssertEqual(form.repositoryField.stringValue, "acme/widgets")
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "opening the form writes nothing")
            try click(form.saveButton)
            try waitUntil("the saved settings set the queue up") { !board.view.queueLabel.isHidden }
            XCTAssertEqual(board.view.noticeLines.count, 0, "nothing left to say")
            XCTAssertNotNil(try row("login", in: board).queueButton)
        }
    }

    /// Why a repository shows no pull requests is said in plain words: gh
    /// signed out, once for every repository it stops, in red; origin on
    /// another host, or the repository another section reads, in their
    /// sections' headers. One Board Settings… opens on the first
    /// repository it can set up.
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

            let expected = [
                "front, back: gh isn’t signed in to GitHub: run gh auth login in a terminal, then Refresh.",
                "Not set up in Board Settings, so no merge queue: front, back, docs."
            ]
            try waitUntil("both answers said, every repository listed") {
                guard case .sections(let sections, _)? = board.view.content?.body else { return false }
                return board.view.noticeLines.map(\.label.stringValue) == expected && sections.allSatisfy { !$0.rows.isEmpty }
            }
            XCTAssertEqual(board.view.noticeLines.map(\.label.stringValue), expected)
            XCTAssertEqual(board.view.noticeLines.map(\.settingsButton.isHidden), [true, false])
            guard case .sections(let sections, _)? = board.view.content?.body, sections.count == 5 else {
                return XCTFail("not five sections")
            }
            XCTAssertEqual(sections.map(\.repository), ["acme/saved", "acme/front", "acme/back", nil, nil])
            XCTAssertEqual(
                sections[3].note,
                "origin points to gitlab.com, not github.com: set its GitHub repository in Board Settings to see its pull requests."
            )
            XCTAssertEqual(sections[4].note, "Same GitHub repository as “front”: its pull requests show there.")
            // Read-only shows in the header, after the repository.
            XCTAssertEqual(
                Self.sectionHeaders(in: board.view).map(\.detailLabel.stringValue).dropFirst().first,
                "acme/front · Read-only, from origin: save Board Settings to use the merge queue."
            )
            XCTAssertEqual(sections[3].rows.map(\.name), ["main"], "its main checkout all the same")
            XCTAssertFalse(client.calls.contains { $0.what.contains("docs") }, "no gh for a repository elsewhere")
            XCTAssertNil(shell.boardSettingsPanel)

            try click(try XCTUnwrap(board.view.noticeLines.last).settingsButton)
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
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(BoardConfigStore(spaceID: space.id)).fileURL.path))
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
            try runPaletteAction("Open Board", in: shell)
            let gadgetsBoard = try XCTUnwrap(shell.projectBoardLocation(projectID: other.id))

            shell.addWorkspace(title: "widgets", cwd: root, profileID: space.id)
            try runPaletteAction("Open Board", in: shell)
            let widgetsBoard = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id))
            XCTAssertEqual(shell.projectBoardLocations.count, 2)

            widgetsBoard.board.view.chooseProject(id: other.id)
            XCTAssertTrue(shell.activeWorkspace === gadgetsBoard.workspace, "that project's board comes to the front")
            XCTAssertEqual(widgetsBoard.board.projectID, space.id)

            widgetsBoard.board.view.chooseProject(id: third.id)
            XCTAssertEqual(widgetsBoard.board.projectID, third.id)
            XCTAssertEqual(Self.checkedProject(widgetsBoard.board.view), "Tools")

            _ = shell.workspaceStore.deleteProfile(id: third.id)
            shell.updateSidebar()
            shell.renderProjectBoard(widgetsBoard.board)
            XCTAssertEqual(Self.checkedProject(widgetsBoard.board.view), "Deleted space")
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
            try runPaletteAction("Open Board", in: shell)
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

    /// A space with two repositories (docs/spaces.md, S12): a section and a
    /// queue line for each, each read on its own repository, and a pull
    /// request queued and started in its own repository's queue only.
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

            try waitUntil("both repositories read, docs’ remote too") {
                guard case .sections(let sections, _)? = board.view.content?.body else { return false }
                return sections.map { $0.rows.compactMap(\.pullRequest?.number) } == [[12], [21], []]
                    && sections.last?.note != nil
            }
            guard case .sections(let sections, let others)? = board.view.content?.body else { return XCTFail("no sections") }
            XCTAssertEqual(sections.map(\.title), ["front", "back", "docs"], "the default repository first")
            XCTAssertEqual(sections.map(\.repository), ["acme/front", "acme/back", nil])
            XCTAssertEqual(sections[1].rows.map(\.name), ["main", "api"], "its main checkout too, without a workspace")
            XCTAssertEqual(sections[2].rows.map(\.name), ["main"], "found by its anchor alone")
            XCTAssertNotNil(sections[2].note, "it says to set its GitHub repository")
            XCTAssertEqual(others, [])
            XCTAssertEqual(board.view.header.context, space.name, "the header names the space, not one repository")
            XCTAssertEqual(board.view.queueLines.map(\.name.stringValue), ["front", "back"], "docs has no queue")
            XCTAssertTrue(board.view.queueLabel.isHidden, "no single queue line")
            XCTAssertTrue(client.calls.contains { $0.what == "pr open acme/back" })

            // Add #21 on back's row: back's queue only.
            let api = try XCTUnwrap(board.view.rowViews.first { $0.row.pullRequest?.number == 21 })
            XCTAssertEqual(api.section, sections[1].id)
            try click(try XCTUnwrap(api.queueButton))
            let backRepository = GitHubRepository(owner: "acme", name: "back")
            let frontRepository = GitHubRepository(owner: "acme", name: "front")
            XCTAssertEqual(shell.mergeQueue(projectID: space.id, repository: backRepository).selection, [21])
            XCTAssertEqual(shell.mergeQueue(projectID: space.id, repository: frontRepository).selection, [])
            try waitUntil("back's line offers Start") { board.view.queueLines.last?.startButton.isEnabled == true }
            XCTAssertFalse(try XCTUnwrap(board.view.queueLines.first).startButton.isEnabled, "front has nothing queued")

            try click(try XCTUnwrap(board.view.queueLines.last).startButton)
            let sheet = try XCTUnwrap(shell.mergeQueueConfirmation)
            XCTAssertEqual(sheet.repository, backRepository)
            sheet.dismiss()
        }
    }

    /// A queue still running on the repository Board Settings just replaced
    /// keeps a line of its own and its Stop, named after its repository;
    /// the rows keep the board's own queue.
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

            try waitUntil("a line shows the widgets queue") {
                shell.renderProjectBoard(board)
                return board.view.queueLines.map(\.name.stringValue) == ["acme/gadgets", "acme/widgets"]
            }
            XCTAssertEqual(board.repository?.name, "acme/gadgets")
            XCTAssertTrue(board.view.queueLabel.isHidden, "no single line")
            XCTAssertEqual(board.view.content?.queue?.isLocked, false, "the rows read gadgets' queue")
            let line = try XCTUnwrap(board.view.queueLines.last)
            XCTAssertTrue(line.label.stringValue.hasPrefix("Queue: "), line.label.stringValue)
            XCTAssertFalse(line.stopButton.isHidden)
            try click(line.stopButton)
            try waitUntil("the widgets queue stops") { !queue.isRunning }
            MergeQueueController.waitForFiles()
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
            shell.spaceSettings?.close()
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

    /// The repositories' headers, from the top.
    @MainActor
    static func sectionHeaders(in view: NSView) -> [SectionHeaderView] {
        let found = view.subviews.flatMap { subview -> [SectionHeaderView] in
            (subview as? SectionHeaderView).map { [$0] } ?? sectionHeaders(in: subview)
        }
        return found.sorted { $0.frame.minY < $1.frame.minY }
    }

    /// Refresh's tooltip says when the board last read GitHub.
    @MainActor
    static func wasUpdated(_ board: ProjectBoardView) -> Bool {
        board.refreshButton.toolTip?.hasPrefix("Refresh · Updated ") == true
    }

    /// The project the ⋯ menu's Project submenu checks.
    @MainActor
    static func checkedProject(_ board: ProjectBoardView) -> String? {
        let checked = board.projectMenu().items.filter { $0.state == .on }
        return checked.count == 1 ? checked[0].title : nil
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
