import AppKit

/// One Project Board column: its project, what it read (docs/project-board.md,
/// section 6) and its view. Reads run off the main thread, on the schedule
/// of `ProjectBoard.RefreshSchedule`, and only while the board is on
/// screen; opening it, Refresh and a saved board.json read at once if it
/// is shown. The cache lives here, for the board's repository, and goes
/// with the board. The shell supplies the project's workspaces and their
/// agents at each render: they change by the second and cost no call.
@MainActor
final class ProjectBoardController {
    private(set) var projectID: String
    let view = ProjectBoardView(frame: .zero)
    private let client: any ProjectBoardGitHub

    /// board.json as last read; nil until it is.
    private(set) var loaded: BoardConfigStore.Loaded?
    private(set) var local: ProjectBoard.LocalSnapshot?
    private(set) var openPullRequests: [ProjectBoard.PullRequest]?
    private(set) var mergedPullRequests: [ProjectBoard.PullRequest]?
    /// The last post-merge run; `.some(nil)` when there is none yet.
    private(set) var postMergeRun: ProjectBoard.WorkflowRun??
    private(set) var errors: [ProjectBoard.Source: ProjectBoard.FetchError] = [:]
    /// Why the last Retarget failed: in the header until Refresh.
    private(set) var retargetFailure: String?
    private(set) var pullRequestsReadAt: Date?
    private(set) var schedule = ProjectBoard.RefreshSchedule()
    /// Bumped when what the reads depend on changes (the project, the
    /// repository, the base branch, the workflow): answers to earlier
    /// reads are dropped.
    private var generation = 0
    /// Bumped by each read of board.json: only the latest one applies.
    private var configRead = 0
    /// board.json is being read again: nothing else is read meanwhile, or
    /// it would be read with the config being replaced.
    private var isReadingConfig = false
    /// Reads landed since the last render: they are drawn once, together.
    private var isRenderScheduled = false
    /// A board opened from the palette on a project without a repository
    /// opens Board Settings, once.
    private var offersSettings: Bool

    /// The project's workspace folders, where the worktrees are listed.
    var workspaceFolders: () -> [String] = { [] }
    /// Whether the board is on screen now: shown, in the active app, in a
    /// window that isn't covered. Periodic reads need it.
    var isOnScreen: () -> Bool = { false }
    /// Whether its workspace is shown in the window. Opening the board,
    /// Refresh and a saved board.json read at once when it is.
    var isShown: () -> Bool = { false }
    /// Whether the board's project still exists: a deleted one's board
    /// reads nothing.
    var projectExists: () -> Bool = { true }
    /// Something was read: the shell renders the board again.
    var onRead: (() -> Void)?
    /// A board without a repository asks for Board Settings.
    var onNeedsSettings: (() -> Void)?

    init(projectID: String, client: any ProjectBoardGitHub, offersSettings: Bool) {
        self.projectID = projectID
        self.client = client
        self.offersSettings = offersSettings
    }

    /// The configured repository, spelled as saved and for comparisons.
    var repository: (name: String, gitHub: GitHubRepository)? {
        guard let config = loaded?.config, let name = config.repository, let gitHub = config.gitHubRepository else {
            return nil
        }
        return (name, gitHub)
    }

    /// A check of an open pull request runs: the latest run of each, as
    /// the Checks column counts them.
    var hasPendingChecks: Bool {
        (openPullRequests ?? []).contains { pullRequest in
            pullRequest.isFromConfiguredRepository
                && ProjectBoard.checkSummary(pullRequest.checks, required: []).hasPending
        }
    }

    // MARK: - Reading

    /// Shows another project: nothing read for the previous one stays.
    func switchProject(to projectID: String) {
        guard projectID != self.projectID else { return }
        self.projectID = projectID
        generation += 1
        schedule.reset()
        loaded = nil
        local = nil
        clearGitHubData()
        reload()
    }

    /// Refresh, a new project, board.json saved: read the config, then
    /// everything, at once if the board is shown. A read already running
    /// for the same config isn't started again: its answer is on its way.
    func reload() {
        configRead += 1
        let current = configRead
        schedule.makeEverythingDue()
        errors = [:]
        retargetFailure = nil
        guard let store = BoardConfigStore(spaceID: projectID) else {
            isReadingConfig = false
            loaded = BoardConfigStore.Loaded(config: nil, status: .unreadable)
            onRead?()
            return
        }
        isReadingConfig = true
        Self.readOffMain({ store.load() }, then: { [weak self] loaded in
            guard let self, self.configRead == current else { return }
            self.isReadingConfig = false
            self.apply(loaded)
        })
    }

    private func apply(_ newConfig: BoardConfigStore.Loaded) {
        let previous = loaded?.config
        let wasRead = loaded != nil
        loaded = newConfig
        let config = newConfig.config
        let repositoryChanged = previous?.gitHubRepository != config?.gitHubRepository
        let runChanged = previous?.baseBranch != config?.baseBranch
            || previous?.postMergeWorkflow != config?.postMergeWorkflow
        if wasRead, repositoryChanged || runChanged {
            // Reads still running answer for the config just replaced.
            generation += 1
            schedule.reset()
        }
        if repositoryChanged { clearGitHubData() }
        if runChanged { postMergeRun = nil }
        // Only a file that is missing, or saved without a repository: an
        // unreadable or read-only one says why instead.
        let asksForSettings = offersSettings && repository == nil
            && (newConfig.status == .missing || newConfig.status == .loaded)
        offersSettings = false
        onRead?()
        if asksForSettings { onNeedsSettings?() }
        tick(onScreen: isShown())
    }

    private func clearGitHubData() {
        openPullRequests = nil
        mergedPullRequests = nil
        postMergeRun = nil
        pullRequestsReadAt = nil
        errors = [:]
        retargetFailure = nil
    }

    /// Reads what is due. Called on every status refresh (the heartbeat),
    /// which reads only while the board is on screen.
    func tick(now: TimeInterval = ProjectBoard.clock(), onScreen: Bool? = nil) {
        guard loaded != nil, !isReadingConfig, projectExists() else { return }
        let due = schedule.due(
            now: now, onScreen: onScreen ?? isOnScreen(), hasPendingChecks: hasPendingChecks, available: availableSources
        )
        for source in due { read(source, now: now) }
    }

    /// The worktrees changed on disk (one was removed): list them again at
    /// the next tick.
    func expireWorktrees() {
        schedule.expire(.worktrees)
    }

    /// Nothing without a repository: the board only says to set one.
    private var availableSources: Set<ProjectBoard.Source> {
        guard repository != nil else { return [] }
        var sources: Set<ProjectBoard.Source> = [.worktrees, .openPullRequests, .mergedPullRequests]
        if let config = loaded?.config, config.baseBranch != nil, case .workflow = config.postMergeWorkflow {
            sources.insert(.postMergeRun)
        }
        return sources
    }

    private func read(_ source: ProjectBoard.Source, now: TimeInterval) {
        schedule.start(source, now: now)
        let current = generation
        let client = self.client
        switch source {
        case .worktrees:
            let folders = workspaceFolders()
            Self.readOffMain({ ProjectBoard.readLocal(folders: folders) }, then: { [weak self] snapshot in
                self?.finish(source, generation: current) { $0.local = snapshot }
            })
        case .openPullRequests, .mergedPullRequests:
            guard let repository else { return schedule.finish(source) }
            let list: ProjectBoard.PullRequestList = source == .openPullRequests ? .open : .merged
            Self.readOffMain({
                client.pullRequests(repository: repository.name, state: list).flatMap { data in
                    ProjectBoard.parsePullRequests(data, repository: repository.gitHub)
                        .map(Result.success) ?? .failure(.unreadable)
                }
            }, then: { [weak self] result in
                self?.finish(source, generation: current) { board in
                    board.errors[source] = result.failureValue
                    guard case .success(let pullRequests) = result else { return }
                    if list == .open {
                        // A pull request no longer open was likely merged:
                        // its branch reads "merged" now, not in 10 minutes.
                        let numbers = Set(pullRequests.map(\.number))
                        if board.openPullRequests?.contains(where: { !numbers.contains($0.number) }) == true {
                            board.schedule.expire(.mergedPullRequests)
                        }
                        board.openPullRequests = pullRequests
                        board.pullRequestsReadAt = Date()
                    } else {
                        board.mergedPullRequests = pullRequests
                    }
                }
            })
        case .postMergeRun:
            guard let repository, let config = loaded?.config, let branch = config.baseBranch,
                  case .workflow(let workflow) = config.postMergeWorkflow
            else { return schedule.finish(source) }
            Self.readOffMain({
                client.postMergeRuns(repository: repository.name, workflow: workflow, branch: branch).flatMap { data in
                    ProjectBoard.parseRuns(data).map { .success($0.first) } ?? .failure(.unreadable)
                }
            }, then: { [weak self] result in
                self?.finish(source, generation: current) { board in
                    board.errors[source] = result.failureValue
                    if case .success(let run) = result { board.postMergeRun = .some(run) }
                }
            })
        }
    }

    /// Retarget (docs/pr-stacks.md): bases pull request `number` on `base`,
    /// then reads the open pull requests again. Never sent twice: another
    /// click is the user's.
    func retarget(_ number: Int, onto base: String) {
        guard let repository else { return }
        let client = self.client
        let current = generation
        Self.readOffMain({ client.retarget(repository: repository.name, number: number, base: base) }, then: { [weak self] result in
            guard let self, current == self.generation else { return }
            self.retargetFailure = result.failureValue.map { "Retarget #\(number): \($0.message)" }
            self.schedule.expire(.openPullRequests)
            self.onRead?()
            self.tick(onScreen: self.isShown())
        })
    }

    private func finish(_ source: ProjectBoard.Source, generation: Int, _ store: (ProjectBoardController) -> Void) {
        // A read for an earlier project or config: its answer is moot.
        guard generation == self.generation else { return }
        schedule.finish(source)
        store(self)
        scheduleRender()
    }

    /// Answers landing together (the first reads, a Refresh) are drawn once.
    private func scheduleRender() {
        guard !isRenderScheduled else { return }
        isRenderScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRenderScheduled = false
            self.onRead?()
        }
    }

    /// Runs `work` off the main thread, then `completion` on it. Both are
    /// taken through this nonisolated function's `@Sendable` parameters, so
    /// neither closure inherits the caller's main-actor isolation: Swift 6.1
    /// traps a main-actor closure run on another thread (#48; see
    /// `NiruxShellView.runOffMain`).
    nonisolated static func readOffMain<Value: Sendable>(
        _ work: @escaping @Sendable () -> Value,
        then completion: @escaping @MainActor @Sendable (Value) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let value = work()
            DispatchQueue.main.async { @MainActor in
                completion(value)
            }
        }
    }

    // MARK: - Drawing

    /// The comparable form of a workspace folder, as the worktrees were
    /// listed (symlinks resolved).
    func comparableFolder(_ folder: String) -> String {
        local?.folders[folder] ?? URL(fileURLWithPath: folder).standardizedFileURL.path
    }

    /// What the view shows, with the project's workspaces as they are now.
    func content(
        workspaces: [ProjectBoard.Workspace],
        projects: [ProjectBoardView.Project],
        now: Date = Date()
    ) -> ProjectBoardView.Content {
        let project = projects.first { $0.id == projectID }
        let config = loaded?.config
        var header = ProjectBoardView.Header(
            projectName: project?.name ?? "Deleted project",
            repository: config?.repository,
            projects: projects,
            projectID: projectID,
            projectIsMissing: project == nil
        )
        if let config, config.baseBranch != nil, case .workflow(let workflow) = config.postMergeWorkflow, repository != nil {
            switch postMergeRun {
            case .some(let run): header.postMergeRun = ProjectBoardView.runStatus(run, workflow: workflow, now: now)
            case nil:
                let label = (workflow as NSString).deletingPathExtension
                header.postMergeRun = errors[.postMergeRun] == nil
                    ? ColumnHeaderView.Status("\(label) …", tone: .neutral, toolTip: "Reading the last \(label) run…") : nil
            }
        }
        let messages = Set(errors.values.map(\.message) + [retargetFailure].compactMap { $0 }).sorted()
        if !messages.isEmpty {
            header.status = messages.joined(separator: " ")
            header.statusIsError = true
        } else if let readAt = pullRequestsReadAt {
            header.status = "Updated \(ProjectBoard.clockTime(readAt, now: now))"
        } else if repository != nil {
            header.status = "Reading pull requests…"
        }

        let body: ProjectBoardView.Body
        if project == nil {
            body = .message("This project was deleted. Pick another one in the ⋯ menu above.")
        } else if let loaded, loaded.status == .unreadable {
            body = .message("board.json can’t be read: open Board Settings… to replace it.")
        } else if let loaded, case .readOnly(let reason) = loaded.status, repository == nil {
            body = .message(reason.message)
        } else if loaded == nil {
            body = .message("Reading board.json…")
        } else if repository == nil {
            body = .message("Set this project’s repository in Board Settings… to list its branches and pull requests.")
        } else if let local {
            let rows = ProjectBoard.rows(ProjectBoard.Sources(
                repository: repository?.gitHub,
                baseBranch: config?.baseBranch,
                local: local.repositories,
                workspaces: workspaces,
                openPullRequests: openPullRequests ?? [],
                mergedPullRequests: mergedPullRequests ?? []
            ))
            body = rows.isEmpty
                ? .message("No worktree and no open pull request yet. Open a workspace in a checkout of \(repository?.name ?? "the repository").")
                : .rows(rows)
        } else {
            body = .message("Listing worktrees…")
        }
        return ProjectBoardView.Content(
            header: header,
            body: body,
            requiredChecks: config?.requiredChecks ?? [],
            baseBranch: config?.baseBranch
        )
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
