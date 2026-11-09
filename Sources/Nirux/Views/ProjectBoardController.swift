import AppKit

/// One Project Board column: its project, what it read (docs/project-board.md,
/// section 6) and its view. A project shows one section per repository
/// anchor (docs/spaces.md, S12), each with its config from board.json and
/// its own reads; a space without one shows its one repository, as before.
/// An anchor board.json has no config for shows its worktrees, and the pull
/// requests of its `origin` read-only: nothing is saved, and its merge
/// queue waits for Board Settings.
/// Reads run off the main thread, on the schedule of
/// `ProjectBoard.RefreshSchedule`, and only while the board is on screen;
/// opening it, Refresh and a saved board.json read at once if it is shown.
/// The cache lives here, for each section's repository, and goes with the
/// board. The shell supplies the project's workspaces and their agents at
/// each render: they change by the second and cost no call.
@MainActor
final class ProjectBoardController {
    /// What one configured section read from GitHub.
    struct RepositoryReads: Sendable {
        /// As saved (or as origin spells it), for `gh --repo` and display.
        var name: String
        let gitHub: GitHubRepository
        /// Read from its anchor's origin, board.json having no config for
        /// it: no merge queue, no retarget.
        var isFromOrigin = false
        var baseBranch: String?
        /// The post-merge workflow file; nil when unset or none.
        var workflow: String?
        var openPullRequests: [ProjectBoard.PullRequest]?
        var mergedPullRequests: [ProjectBoard.PullRequest]?
        /// The last post-merge run; `.some(nil)` when there is none yet.
        var postMergeRun: ProjectBoard.WorkflowRun??
        var errors: [ProjectBoard.Source: ProjectBoard.FetchError] = [:]
        /// Why the last Retarget failed: shown until Refresh.
        var retargetFailure: String?
        var pullRequestsReadAt: Date?
        var schedule = ProjectBoard.RefreshSchedule()
        /// Bumped when the base branch or the workflow changes: answers to
        /// earlier reads are dropped.
        var generation = 0

        init?(config: BoardConfig) {
            guard let name = config.repository, let gitHub = config.gitHubRepository else { return nil }
            self.name = name
            self.gitHub = gitHub
            baseBranch = config.baseBranch
            if case .workflow(let file) = config.postMergeWorkflow { workflow = file }
        }

        /// A section without a config: its anchor's origin, when it is on
        /// github.com.
        init?(origin: BoardSections.Origin) {
            guard case .gitHub(let repository, let baseBranch) = origin,
                  let config = RepositoryReads(config: BoardConfig(repository: repository, baseBranch: baseBranch))
            else { return nil }
            self = config
            isFromOrigin = true
        }

        /// A check of an open pull request runs: the latest run of each, as
        /// the Checks column counts them.
        var hasPendingChecks: Bool {
            (openPullRequests ?? []).contains { pullRequest in
                pullRequest.isFromConfiguredRepository
                    && ProjectBoard.checkSummary(pullRequest.checks, required: []).hasPending
            }
        }

        var availableSources: Set<ProjectBoard.Source> {
            var sources: Set<ProjectBoard.Source> = [.openPullRequests, .mergedPullRequests]
            if baseBranch != nil, workflow != nil { sources.insert(.postMergeRun) }
            return sources
        }
    }

    private(set) var projectID: String
    let view = ProjectBoardView(frame: .zero)
    private let client: any ProjectBoardGitHub

    /// board.json as last read; nil until it is.
    private(set) var loaded: BoardConfigStore.Loaded?
    /// The space's anchors and their remotes, read with board.json.
    private(set) var context = BoardSections.Context()
    /// One per repository anchor, else the space's one repository.
    private(set) var sections: [BoardSections.Section] = []
    /// Each section's name, by id, told apart when two share one.
    private(set) var displayNames: [String: String] = [:]
    private(set) var local: ProjectBoard.LocalSnapshot?
    /// By section id, for each section with a valid repository.
    private(set) var reads: [String: RepositoryReads] = [:]
    /// When the worktrees are listed again (the other sources are each
    /// section's).
    private(set) var schedule = ProjectBoard.RefreshSchedule()
    /// Bumped when the project changes: answers to earlier reads are dropped.
    private var generation = 0
    /// The last generation given to a section's reads: never given twice,
    /// so an answer for a config replaced since is always dropped.
    private var lastReadGeneration = 0
    /// Bumped by each read of board.json: only the latest one applies.
    private var configRead = 0
    /// The anchors the last read of board.json placed its configs with.
    private var requestedAnchors: [SpaceAnchor]?
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
    /// The project's anchors as they are now: read with board.json.
    var spaceAnchors: () -> [SpaceAnchor] = { [] }
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

    /// The section with this id; with nil, the board's only section.
    func section(id: String?) -> BoardSections.Section? {
        guard let id else { return sections.count == 1 ? sections.first : nil }
        return sections.first { $0.id == id }
    }

    /// The section's saved repository, spelled as saved and for
    /// comparisons: the one its merge queue works on. Nil for a section
    /// read from its anchor's origin.
    func repository(of section: BoardSections.Section) -> (name: String, gitHub: GitHubRepository)? {
        reads[section.id].map { ($0.name, $0.gitHub) }
    }

    /// board.json about this section's config, for its queue.
    func loaded(for section: BoardSections.Section) -> BoardConfigStore.Loaded? {
        loaded?.view(for: section.slot)
    }

    /// The configured repository of a board with one section: what the
    /// column header names. Nil with several, or none.
    var repository: (name: String, gitHub: GitHubRepository)? {
        guard sections.count == 1, let only = sections.first else { return nil }
        return repository(of: only)
    }

    /// Some section has a GitHub repository, saved or its origin's: the
    /// board reads pull requests. Only a saved one has a merge queue
    /// (`repository(of:)`).
    var readsPullRequests: Bool { !reads.isEmpty }

    /// The board lists rows: some section reads pull requests, or has an
    /// anchor whose worktrees show without them. Not with an unreadable
    /// board.json, which the board asks to replace.
    var listsRows: Bool {
        loaded?.status != .unreadable && (readsPullRequests || sections.contains { $0.anchor != nil })
    }

    // MARK: - Reading

    /// Shows another project: nothing read for the previous one stays.
    func switchProject(to projectID: String) {
        guard projectID != self.projectID else { return }
        self.projectID = projectID
        generation += 1
        schedule.reset()
        loaded = nil
        requestedAnchors = nil
        context = BoardSections.Context()
        sections = []
        local = nil
        reads = [:]
        reload()
    }

    /// Refresh, a new project, board.json saved, the space's anchors
    /// changed: read the config and the anchors' remotes, then everything,
    /// at once if the board is shown. A read already running for the same
    /// config isn't started again: its answer is on its way.
    func reload() {
        configRead += 1
        let current = configRead
        schedule.makeEverythingDue()
        for id in reads.keys {
            reads[id]?.schedule.makeEverythingDue()
            // Its errors stay until the next answer replaces them: a line
            // saying gh is signed out doesn't blink, and the rows don't
            // move, at each Refresh.
            reads[id]?.retargetFailure = nil
        }
        let anchors = spaceAnchors()
        requestedAnchors = anchors
        guard let store = BoardConfigStore(spaceID: projectID) else {
            isReadingConfig = false
            apply(BoardConfigStore.Loaded(config: nil, status: .unreadable), context: BoardSections.Context(anchors: anchors))
            return
        }
        isReadingConfig = true
        Self.readOffMain({
            let loaded = store.load()
            // The anchors' remotes only place schema 1's config.
            var context = loaded.entries.contains { $0.slot == .legacy }
                ? BoardSections.readContext(anchors: anchors) : BoardSections.Context(anchors: anchors)
            // A file this build can't use, or won't write, says why instead.
            if loaded.status == .missing || loaded.status == .loaded {
                context.origins = BoardSections.readOrigins(BoardSections.sections(loaded.entries, context: context))
            }
            return (loaded, context)
        }, then: { [weak self] read in
            guard let self, self.configRead == current else { return }
            self.isReadingConfig = false
            self.apply(read.0, context: read.1)
        })
    }

    private func apply(_ newConfig: BoardConfigStore.Loaded, context newContext: BoardSections.Context) {
        var context = newContext
        // git couldn't read an origin this time: the one read before stays,
        // and its section keeps what it read.
        for (commonDir, origin) in context.origins where origin == .unread {
            if let known = self.context.origins[commonDir] { context.origins[commonDir] = known }
        }
        let wasRead = loaded != nil
        let previousSections = sections.map(\.id)
        loaded = newConfig
        self.context = context
        // An unreadable file holds no config this build can use.
        let entries = newConfig.status == .unreadable ? [] : newConfig.entries
        sections = BoardSections.sections(entries, context: context)
        displayNames = BoardSections.displayNames(sections)
        var newReads: [String: RepositoryReads] = [:]
        // Two sections never read one repository, as Board Settings never
        // saves one for two: a saved one keeps it, else the first origin.
        var taken = Set(sections.compactMap { $0.config?.gitHubRepository })
        for section in sections {
            let origin = section.commonDir.flatMap { context.origins[$0] }
            // A config, even without a valid repository, wins over origin.
            var read = section.config.map { RepositoryReads(config: $0) } ?? origin.flatMap(RepositoryReads.init(origin:))
            _ = taken
            guard var fresh = read else { continue }
            if var previous = reads[section.id], previous.gitHub == fresh.gitHub {
                // Saved since it was read from origin: what it read stays.
                previous.isFromOrigin = fresh.isFromOrigin
                previous.name = fresh.name
                if previous.baseBranch != fresh.baseBranch || previous.workflow != fresh.workflow {
                    // Reads still running answer for the config just replaced.
                    previous.generation = newReadGeneration()
                    previous.schedule.reset()
                    previous.postMergeRun = nil
                    previous.errors = [:]
                    previous.baseBranch = fresh.baseBranch
                    previous.workflow = fresh.workflow
                }
                newReads[section.id] = previous
            } else {
                // Another repository, or a new section: answers for the old
                // one are dropped.
                fresh.generation = newReadGeneration()
                newReads[section.id] = fresh
            }
        }
        // Other folders to list: an anchor added or removed, a section set up.
        if wasRead, Set(newReads.keys) != Set(reads.keys) || sections.map(\.id) != previousSections {
            schedule.expire(.worktrees)
        }
        reads = newReads
        // Only a board with nothing to list, its file missing or saved
        // without a repository: an unreadable or read-only one says why
        // instead.
        let asksForSettings = offersSettings && !listsRows
            && (newConfig.status == .missing || newConfig.status == .loaded)
        offersSettings = false
        onRead?()
        if asksForSettings { onNeedsSettings?() }
        tick(onScreen: isShown())
    }

    /// The space's anchors changed since board.json was last read (a
    /// repository added, removed or made the default): read it again.
    func reloadIfAnchorsChanged() {
        guard let requestedAnchors, spaceAnchors() != requestedAnchors else { return }
        reload()
    }

    private func newReadGeneration() -> Int {
        lastReadGeneration += 1
        return lastReadGeneration
    }

    /// Reads what is due. Called on every status refresh (the heartbeat),
    /// which reads only while the board is on screen.
    func tick(now: TimeInterval = ProjectBoard.clock(), onScreen: Bool? = nil) {
        guard loaded != nil, !isReadingConfig, projectExists() else { return }
        let onScreen = onScreen ?? isOnScreen()
        // Nothing without rows to list: the board only says to set one.
        guard listsRows else { return }
        let pending = reads.values.contains(where: \.hasPendingChecks)
        if !schedule.due(now: now, onScreen: onScreen, hasPendingChecks: pending, available: [.worktrees]).isEmpty {
            readWorktrees(now: now)
        }
        for (id, repository) in reads {
            let due = repository.schedule.due(
                now: now, onScreen: onScreen, hasPendingChecks: repository.hasPendingChecks,
                available: repository.availableSources
            )
            for source in due { read(source, section: id, now: now) }
        }
    }

    /// The worktrees changed on disk (one was removed): list them again at
    /// the next tick.
    func expireWorktrees() {
        schedule.expire(.worktrees)
    }

    /// The workspaces' folders, then each repository anchor's main checkout
    /// (or its git dir, for a bare repository): its worktrees show even
    /// with no workspace open there.
    private var foldersToList: [String] {
        let anchors = sections.compactMap(\.checkoutFolder)
        let folders = workspaceFolders()
        return folders + anchors.filter { !folders.contains($0) }
    }

    private func readWorktrees(now: TimeInterval) {
        schedule.start(.worktrees, now: now)
        let current = generation
        let folders = foldersToList
        Self.readOffMain({ ProjectBoard.readLocal(folders: folders) }, then: { [weak self] snapshot in
            guard let self, current == self.generation else { return }
            self.schedule.finish(.worktrees)
            self.local = snapshot
            self.scheduleRender()
        })
    }

    private func read(_ source: ProjectBoard.Source, section id: String, now: TimeInterval) {
        guard let repository = reads[id] else { return }
        reads[id]?.schedule.start(source, now: now)
        let current = generation
        let client = self.client
        let name = repository.name
        let gitHub = repository.gitHub
        switch source {
        case .worktrees:
            reads[id]?.schedule.finish(source)
        case .openPullRequests, .mergedPullRequests:
            let list: ProjectBoard.PullRequestList = source == .openPullRequests ? .open : .merged
            Self.readOffMain({
                client.pullRequests(repository: name, state: list).flatMap { data in
                    ProjectBoard.parsePullRequests(data, repository: gitHub).map(Result.success) ?? .failure(.unreadable)
                }
            }, then: { [weak self] result in
                self?.finish(source, section: id, reads: repository, generation: current) { reads in
                    reads.errors[source] = result.failureValue
                    guard case .success(let pullRequests) = result else { return }
                    if list == .open {
                        // A pull request no longer open was likely merged:
                        // its branch reads "merged" now, not in 10 minutes.
                        let numbers = Set(pullRequests.map(\.number))
                        if reads.openPullRequests?.contains(where: { !numbers.contains($0.number) }) == true {
                            reads.schedule.expire(.mergedPullRequests)
                        }
                        reads.openPullRequests = pullRequests
                        reads.pullRequestsReadAt = Date()
                    } else {
                        reads.mergedPullRequests = pullRequests
                    }
                }
            })
        case .postMergeRun:
            guard let branch = repository.baseBranch, let workflow = repository.workflow else {
                reads[id]?.schedule.finish(source)
                return
            }
            Self.readOffMain({
                client.postMergeRuns(repository: name, workflow: workflow, branch: branch).flatMap { data in
                    ProjectBoard.parseRuns(data).map { .success($0.first) } ?? .failure(.unreadable)
                }
            }, then: { [weak self] result in
                self?.finish(source, section: id, reads: repository, generation: current) { reads in
                    reads.errors[source] = result.failureValue
                    if case .success(let run) = result { reads.postMergeRun = .some(run) }
                }
            })
        }
    }

    /// Retarget (docs/pr-stacks.md): bases pull request `number` of the
    /// section's repository on `base`, then reads its open pull requests
    /// again. Never sent twice: another click is the user's.
    func retarget(_ number: Int, onto base: String, section id: String) {
        // Never on a repository only read from origin: Board Settings first.
        guard let repository = reads[id], !repository.isFromOrigin else { return }
        let client = self.client
        let name = repository.name
        let current = generation
        Self.readOffMain({ client.retarget(repository: name, number: number, base: base) }, then: { [weak self] result in
            guard let self, current == self.generation, self.reads[id]?.generation == repository.generation else { return }
            self.reads[id]?.retargetFailure = result.failureValue.map { "Retarget #\(number): \($0.message)" }
            self.reads[id]?.schedule.expire(.openPullRequests)
            self.onRead?()
            self.tick(onScreen: self.isShown())
        })
    }

    /// Stores an answer, unless it is for an earlier project or config of
    /// the section: then it is moot.
    private func finish(
        _ source: ProjectBoard.Source, section id: String, reads asked: RepositoryReads, generation: Int,
        _ store: (inout RepositoryReads) -> Void
    ) {
        guard generation == self.generation, var reads = self.reads[id], reads.generation == asked.generation else { return }
        reads.schedule.finish(source)
        store(&reads)
        self.reads[id] = reads
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
    /// The shell adds each queue.
    func content(
        workspaces: [ProjectBoard.Workspace],
        projects: [ProjectBoardView.Project],
        now: Date = Date()
    ) -> ProjectBoardView.Content {
        let project = projects.first { $0.id == projectID }
        let single = sections.count == 1 ? sections.first : nil
        let singleReads = single.flatMap { reads[$0.id] }
        var header = ProjectBoardView.Header(
            projectName: project?.name ?? "Deleted space",
            repository: single == nil ? nil : singleReads?.name,
            projects: projects,
            projectID: projectID,
            projectIsMissing: project == nil
        )
        if let singleReads {
            header.postMergeRun = Self.runStatus(singleReads, now: now)
            if let error = Self.errorText(singleReads) {
                header.status = error.message
                header.statusIsError = true
                header.errorTitle = error.title
            }
        }
        if !header.statusIsError {
            if let readAt = reads.values.compactMap(\.pullRequestsReadAt).max() {
                header.status = "Updated \(ProjectBoard.clockTime(readAt, now: now))"
            } else if readsPullRequests {
                header.status = "Reading pull requests…"
            }
        }

        let body: ProjectBoardView.Body
        var notices: [ProjectBoardView.Notice] = []
        // A message about the settings offers them under it.
        var messageOffersSettings = true
        if project == nil {
            body = .message("This space was deleted. Pick another one in the ⋯ menu above.")
            messageOffersSettings = false
        } else if let loaded, loaded.status == .unreadable {
            body = .message("board.json can’t be read: open Board Settings… to replace it.")
        } else if let loaded, case .readOnly(let reason) = loaded.status, !listsRows {
            // Board Settings can't save it.
            body = .message(reason.message)
            messageOffersSettings = false
        } else if loaded == nil {
            body = .message("Reading board.json…")
            messageOffersSettings = false
        } else if !listsRows {
            body = .message("Set this space’s repository in Board Settings… to list its branches and pull requests.")
        } else {
            notices = self.notices()
            messageOffersSettings = false
            body = local.map { self.body(local: $0, workspaces: workspaces, now: now) } ?? .message("Listing worktrees…")
        }
        var content = ProjectBoardView.Content(
            header: header,
            body: body,
            requiredChecks: single?.config?.requiredChecks ?? [],
            baseBranch: singleReads?.baseBranch ?? single?.config?.baseBranch
        )
        content.notices = notices
        if case .message = body { content.messageOffersSettings = messageOffersSettings }
        return content
    }

    /// The lines under the header: what went wrong reading GitHub, in plain
    /// words, one line per message; then why a repository has no saved
    /// settings, with Board Settings… on that repository.
    private func notices() -> [ProjectBoardView.Notice] {
        let several = sections.count > 1
        let name = { (section: BoardSections.Section) in self.displayNames[section.id] ?? section.name ?? "Repository" }
        var errors: [(message: String, names: [String])] = []
        for section in sections {
            guard let reads = reads[section.id], let message = Self.lastingError(reads) else { continue }
            if let index = errors.firstIndex(where: { $0.message == message }) {
                errors[index].names.append(name(section))
            } else {
                errors.append((message, [name(section)]))
            }
        }
        var notices = errors.map { error in
            ProjectBoardView.Notice(
                text: (several ? error.names.joined(separator: ", ") + ": " : "") + error.message, isError: true
            )
        }
        let unsaved = sections.filter { repository(of: $0) == nil }
        if let loaded, case .readOnly(let reason) = loaded.status {
            // Board Settings can't save it: why, without the button.
            if !unsaved.isEmpty { notices.append(ProjectBoardView.Notice(text: reason.message)) }
        } else if several {
            // One that shares another's repository can't be saved with it.
            let settable = unsaved.filter { sectionSharingOrigin(with: $0) == nil }
            if let first = settable.first {
                notices.append(ProjectBoardView.Notice(
                    text: "No saved GitHub repository in Board Settings: \(settable.map(name).joined(separator: ", ")).",
                    settingsSection: first.id
                ))
            }
        } else if let only = unsaved.first, let note = setupNote(only) {
            notices.append(ProjectBoardView.Notice(text: note, settingsSection: only.id))
        }
        return notices
    }

    /// What went wrong reading a section's open pull requests that the next
    /// read won't mend, or that leaves it without any: gh missing or signed
    /// out, or any error before the first answer. A failure after a good
    /// read stays in its pill, as a failed Retarget or merged read does:
    /// the rows don't move for a blip, and the line goes with the next good
    /// read of the open ones, a minute at most.
    private static func lastingError(_ reads: RepositoryReads) -> String? {
        guard let error = reads.errors[.openPullRequests] else { return nil }
        return reads.openPullRequests == nil || error == .ghMissing || error == .notSignedIn ? error.message : nil
    }

    /// The other section reading the GitHub repository this one's origin
    /// names, which this one then doesn't read.
    private func sectionSharingOrigin(with section: BoardSections.Section) -> BoardSections.Section? {
        guard section.config == nil, reads[section.id] == nil,
              case .gitHub(let name, _)? = section.commonDir.flatMap({ context.origins[$0] }),
              let gitHub = GitHubRepository(ownerAndName: name)
        else { return nil }
        return sections.first { other in
            other.id != section.id && (reads[other.id]?.gitHub == gitHub || other.config?.gitHubRepository == gitHub)
        }
    }

    /// Why a section has no saved repository, in a sentence; nil when it
    /// has one.
    private func setupNote(_ section: BoardSections.Section) -> String? {
        if let reads = reads[section.id] {
            return reads.isFromOrigin ? "Read-only, from origin: save Board Settings to use the merge queue." : nil
        }
        if let loaded, case .readOnly(let reason) = loaded.status { return reason.message }
        guard section.config == nil else {
            return "Board Settings has no valid GitHub repository for it: set one to see its pull requests."
        }
        if let other = sectionSharingOrigin(with: section) {
            let otherName = displayNames[other.id] ?? other.name ?? "another repository"
            return "Same GitHub repository as “\(otherName)”: its pull requests show there."
        }
        switch section.commonDir.flatMap({ context.origins[$0] }) {
        case .missing?:
            return "No remote named origin: set its GitHub repository in Board Settings to see its pull requests."
        case .notGitHub(let host)?:
            let place = host.map { "origin points to \($0), not github.com" } ?? "origin isn’t on github.com"
            return "\(place): set its GitHub repository in Board Settings to see its pull requests."
        case .unread?:
            return "Nirux couldn’t read its origin remote: Refresh, or set its GitHub repository in Board Settings."
        case .gitHub?, nil:
            return "No GitHub repository: set it in Board Settings to see its pull requests."
        }
    }

    private func body(local: ProjectBoard.LocalSnapshot, workspaces: [ProjectBoard.Workspace], now: Date) -> ProjectBoardView.Body {
        // A space without a repository anchor: its one repository, found
        // by remote, as before anchors.
        if sections.count == 1, let only = sections.first, only.anchor == nil, let repository = reads[only.id] {
            let rows = ProjectBoard.rows(ProjectBoard.Sources(
                repository: repository.gitHub,
                baseBranch: repository.baseBranch,
                local: local.repositories,
                workspaces: workspaces,
                openPullRequests: repository.openPullRequests ?? [],
                mergedPullRequests: repository.mergedPullRequests ?? []
            ))
            return rows.isEmpty
                ? .message("No worktree and no open pull request yet. Open a workspace in a checkout of \(repository.name).")
                : .rows(rows)
        }
        let (bySection, others) = ProjectBoard.sectionRows(sections.map { section in
            let repository = reads[section.id]
            return ProjectBoard.SectionSources(
                id: section.id, commonDir: section.commonDir, repository: repository?.gitHub,
                baseBranch: repository?.baseBranch ?? section.config?.baseBranch,
                openPullRequests: repository?.openPullRequests ?? [],
                mergedPullRequests: repository?.mergedPullRequests ?? []
            )
        }, local: local.repositories, workspaces: workspaces)
        if sections.count == 1, let only = sections.first {
            return .rows((bySection[only.id] ?? []) + others)
        }
        return .sections(sections.map { section in
            var content = ProjectBoardView.Section(
                id: section.id,
                title: displayNames[section.id] ?? section.name ?? "Repository",
                rows: bySection[section.id] ?? [],
                requiredChecks: section.config?.requiredChecks ?? [],
                baseBranch: reads[section.id]?.baseBranch ?? section.config?.baseBranch
            )
            if let repository = reads[section.id] {
                content.repository = repository.name
                content.status = Self.errorText(repository).map {
                    ColumnHeaderView.Status($0.title, tone: .error, symbol: Theme.Symbol.agentError, toolTip: $0.message)
                } ?? Self.runStatus(repository, now: now)
            }
            content.note = setupNote(section)
            return content
        }, others: others)
    }

    /// The post-merge run as a pill, while there is one to read.
    private static func runStatus(_ reads: RepositoryReads, now: Date) -> ColumnHeaderView.Status? {
        guard reads.baseBranch != nil, let workflow = reads.workflow else { return nil }
        switch reads.postMergeRun {
        case .some(let run): return ProjectBoardView.runStatus(run, workflow: workflow, now: now)
        case nil:
            let label = (workflow as NSString).deletingPathExtension
            return reads.errors[.postMergeRun] == nil
                ? ColumnHeaderView.Status("\(label) …", tone: .neutral, toolTip: "Reading the last \(label) run…") : nil
        }
    }

    /// What went wrong reading a section: "GitHub error" and the messages.
    private static func errorText(_ reads: RepositoryReads) -> (title: String, message: String)? {
        let messages = Set(reads.errors.values.map(\.message) + [reads.retargetFailure].compactMap { $0 }).sorted()
        guard !messages.isEmpty else { return nil }
        return ("GitHub error", messages.joined(separator: " "))
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
