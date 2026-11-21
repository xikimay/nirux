import AppKit

/// One Project Board column: its project, what it read (docs/design/project-board.md,
/// section 6) and its view. A project shows one section per repository
/// anchor (docs/design/spaces.md, S12), each with its config from board.json and
/// its own reads; a space without one shows its one repository, as before.
/// An anchor board.json has no config for shows its worktrees, and the pull
/// requests of the repository Board Settings would suggest for it (where
/// its pull requests live, `GitHubBaseRemote`) read-only: nothing is saved,
/// and its merge queue waits for Board Settings.
/// Reads run off the main thread, on the schedule of
/// `ProjectBoard.RefreshSchedule`, and only while the board is on screen;
/// opening it, Refresh and a saved board.json read at once if it is shown.
/// The cache lives here, for each section's repository, and goes with the
/// board. The shell supplies the project's workspaces and their agents at
/// each render: they change by the second and cost no call.
@MainActor
final class ProjectBoardController {
    /// What one configured section read from GitHub.
    struct RepositoryReads: Equatable, Sendable {
        /// As saved (or as its remote spells it), for `gh --repo` and display.
        var name: String
        let gitHub: GitHubRepository
        /// The anchor's remote it was read from, board.json having no
        /// config for it: no merge queue, no retarget. Nil when saved.
        var remoteName: String?
        var isFromRemote: Bool { remoteName != nil }
        var baseBranch: String?
        /// The post-merge workflow file; nil when unset or none.
        var workflow: String?
        var openPullRequests: [ProjectBoard.PullRequest]?
        var mergedPullRequests: [ProjectBoard.PullRequest]?
        /// The last post-merge run; `.some(nil)` when there is none yet.
        var postMergeRun: GitHub.WorkflowRun??
        var errors: [ProjectBoard.Source: GitHub.CLI.Failure] = [:]
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

        /// A section without a config: where its anchor's pull requests
        /// live, when that is on github.com.
        init?(baseRemote: BoardSections.BaseRemote) {
            guard case .gitHub(let repository, let baseBranch, let remote) = baseRemote,
                  let config = RepositoryReads(config: BoardConfig(repository: repository, baseBranch: baseBranch))
            else { return nil }
            self = config
            remoteName = remote
        }

        /// A check of an open pull request runs: the latest run of each, as
        /// the Checks station counts them.
        var hasPendingChecks: Bool {
            (openPullRequests ?? []).contains { pullRequest in
                pullRequest.isFromConfiguredRepository
                    && ProjectBoard.checkSummary(pullRequest.checks, required: []).hasPending
            }
        }

        func pullRequestsAreFresh(now: Date) -> Bool {
            let age = pullRequestsReadAt.map { now.timeIntervalSince($0) }
            let interval = ProjectBoard.RefreshSchedule.interval(of: .openPullRequests, hasPendingChecks: hasPendingChecks)
            return ProjectBoardController.stands(age: age, interval: interval)
        }

        var availableSources: Set<ProjectBoard.Source> {
            var sources: Set<ProjectBoard.Source> = [.openPullRequests, .mergedPullRequests]
            if baseBranch != nil, workflow != nil { sources.insert(.postMergeRun) }
            return sources
        }
    }

    private(set) var projectID: String
    let view = BoardColumnView(frame: .zero)
    /// What each task's sidebar row read at the last sidebar pass
    /// (`NiruxShellView.boardReadings`): a render between two passes (a
    /// read landing, a click) draws with it.
    var stagesReadings: [String: BoardStages.TaskReading]?
    /// What the Board's clicks act on, as it last showed them
    /// (`stagesContent`).
    var stagesTargets = StagesTargets()
    /// The stages last built, and what from.
    let builtStages = BuiltStages()
    private let client: any ProjectBoardGitHub

    /// board.json as last read; nil until it is.
    private(set) var loaded: BoardConfigStore.Loaded?
    /// The space's anchors and their remotes, read with board.json.
    private(set) var context = BoardSections.Context()
    /// One per repository anchor, else the space's one repository.
    private(set) var sections: [BoardSections.Section] = []
    /// The repositories of the space's workspaces that are no anchor of it
    /// (nor, without anchors, the one board.json names), as the worktrees
    /// listed them: a read-only section each, after the anchors' (no Board
    /// Settings, no merge queue), so every repository of the space shows.
    private(set) var extraRepositories: [SpaceAnchor] = []
    /// The sections `extraRepositories` made at the last `apply`: the ids
    /// of the read-only ones (one made an anchor since isn't).
    private(set) var extraIDs: Set<String> = []
    /// The sections that are the space's own: its anchors', or the one
    /// board.json names; `sections` without the read-only ones.
    private(set) var ownSections: [BoardSections.Section] = []
    /// The base remote of each repository the worktrees listed outside the
    /// space's own sections, by common dir: read before it is placed, it
    /// says which section its clones join. Emptied by a Refresh.
    private var listedRemotes: [String: BoardSections.BaseRemote] = [:]
    /// The generation a read of `listedRemotes` runs for: one at a time.
    private var runningListedRead: Int?
    /// The workspaces' folders the last listing listed: one with no
    /// workspace left lists them again (its repository's section goes).
    private var listedWorkspaceFolders: Set<String> = []
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
    /// The base remotes of the anchors without a config are read after
    /// board.json, once the board is shown: a section none is known for
    /// yet doesn't say why it has no pull requests.
    private(set) var isReadingRemotes = false
    /// The config read whose remotes wait for the board to be shown, or for
    /// the read under way.
    private var remotesDue: Int?
    /// The read of the base remotes under way: of this project and these
    /// anchors, another one waits for it, so that Refresh on a hung volume
    /// doesn't pile up blocked threads; of others (an anchor removed, the
    /// board switched to another space), it doesn't hold them up.
    private var runningRemoteRead: (generation: Int, anchors: Set<String>)?
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
        guard let id else { return soleSection }
        return sections.first { $0.id == id }
    }

    /// The section's saved repository, spelled as saved and for
    /// comparisons: the one its merge queue works on. Nil for a section
    /// read from its anchor's remote.
    func repository(of section: BoardSections.Section) -> (name: String, gitHub: GitHubRepository)? {
        reads[section.id].flatMap { $0.isFromRemote ? nil : ($0.name, $0.gitHub) }
    }

    /// board.json about this section's config, for its queue.
    func loaded(for section: BoardSections.Section) -> BoardConfigStore.Loaded? {
        loaded?.view(for: section.slot)
    }

    /// The one section that isn't a read-only one of another repository
    /// (`isExtra`), where it is the only one: a Board "with one repository".
    var soleSection: BoardSections.Section? {
        ownSections.count == 1 ? ownSections.first : nil
    }

    /// Some section has a GitHub repository, saved or its remote's: the
    /// board reads pull requests. Only a saved one has a merge queue
    /// (`repository(of:)`).
    var readsPullRequests: Bool { ownSections.contains { reads[$0.id] != nil } }

    /// The board lists rows: some section reads pull requests, or has an
    /// anchor whose worktrees show without them. Not with an unreadable
    /// board.json, which the board asks to replace. A repository that is no
    /// anchor of the space doesn't count: it only comes with the others.
    var listsRows: Bool {
        loaded?.status != .unreadable && (readsPullRequests || ownSections.contains { $0.anchor != nil })
    }

    // MARK: - Reading

    /// Shows another space, its workspace's once it moved there: nothing
    /// read for the previous one stays. `offersSettings`: as a Board opened
    /// there, it may ask for the space's settings.
    func switchProject(to projectID: String, offersSettings: Bool = false) {
        guard projectID != self.projectID else { return }
        self.projectID = projectID
        self.offersSettings = offersSettings
        generation += 1
        schedule.reset()
        loaded = nil
        requestedAnchors = nil
        context = BoardSections.Context()
        sections = []
        extraRepositories = []
        extraIDs = []
        ownSections = []
        listedRemotes = [:]
        runningListedRead = nil
        listedWorkspaceFolders = []
        local = nil
        reads = [:]
        // The old space's tasks: the new one's are read without the sidebar's pass until its next one.
        stagesReadings = nil
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
        // The other repositories' remotes are read again too, before they are placed again.
        listedRemotes = [:]
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
            isReadingRemotes = false
            apply(BoardConfigStore.Loaded(config: nil, status: .unreadable), context: BoardSections.Context(anchors: anchors))
            return
        }
        isReadingConfig = true
        Self.readOffMain({
            let loaded = store.load()
            // The anchors' remotes only place schema 1's config.
            let context = loaded.entries.contains { $0.slot == .legacy }
                ? BoardSections.readContext(anchors: anchors) : BoardSections.Context(anchors: anchors)
            return (loaded, context)
        }, then: { [weak self] read in
            guard let self, self.configRead == current else { return }
            self.isReadingConfig = false
            // A file this build can't use, or won't write, says why instead.
            let readsRemotes = read.0.status == .missing || read.0.status == .loaded
            var context = read.1
            // Until they are read again, the base remotes read before: a
            // Refresh doesn't empty a section meanwhile.
            if readsRemotes {
                context.baseRemotes = self.context.baseRemotes
            } else {
                // Another repository's section keeps its remote all the same: none of the space's is read.
                let extras = Set(self.extraRepositories.compactMap(BoardSections.commonDir(of:)))
                context.baseRemotes = self.context.baseRemotes.filter { extras.contains($0.key) }
            }
            self.isReadingRemotes = readsRemotes
            self.remotesDue = nil
            self.apply(read.0, context: context)
            if readsRemotes { self.readBaseRemotesWhenShown(configRead: current) }
            // Held back while board.json was read: placed now, or once the space's own remotes are read.
            if let local = self.local { self.noteExtraRepositories(in: local) }
        })
    }

    /// The base remotes of the anchors without a config: read after
    /// board.json, so that an anchor on a slow volume holds up no other
    /// read, and only once the board is shown (a board restored at launch
    /// behind another workspace runs no git for them), then applied with
    /// the config read last.
    private func readBaseRemotesWhenShown(configRead current: Int) {
        // Another repository's section has its remote from `readListedRemotes`.
        let unsaved = ownSections.filter { $0.config == nil && $0.commonDir != nil }
        guard !unsaved.isEmpty else {
            isReadingRemotes = false
            return
        }
        let anchors = Set(unsaved.compactMap(\.commonDir))
        let isRunning = runningRemoteRead.map { $0.generation == generation && $0.anchors == anchors } ?? false
        guard isShown(), !isRunning else {
            remotesDue = current
            return
        }
        let token = (generation: generation, anchors: anchors)
        runningRemoteRead = token
        Self.readOffMain({ BoardSections.readBaseRemotes(unsaved) }, then: { [weak self] remotes in
            guard let self else { return }
            if let running = self.runningRemoteRead, running.generation == token.generation, running.anchors == token.anchors {
                self.runningRemoteRead = nil
            }
            if self.configRead == current, let loaded = self.loaded {
                // Another read, started meanwhile for other repositories, still reads theirs.
                self.isReadingRemotes = self.runningRemoteRead != nil
                var context = self.context
                // What this read didn't cover stays (that other read read it), for the repositories still shown.
                let shown = Set(self.sections.compactMap(\.commonDir))
                context.baseRemotes = Self.merged(remotes, keeping: self.context.baseRemotes)
                    .merging(self.context.baseRemotes) { new, _ in new }
                    .filter { shown.contains($0.key) }
                self.apply(loaded, context: context, listsWorktreesAgain: false)
                // An anchor read from its remote takes its other clones by it now: placed again, at once.
                if let local = self.local { self.noteExtraRepositories(in: local) }
            }
            // board.json read again meanwhile: its remotes, now.
            if let due = self.remotesDue, due == self.configRead {
                self.remotesDue = nil
                self.readBaseRemotesWhenShown(configRead: due)
            }
        })
    }

    /// git couldn't answer this time, or didn't give the default branch:
    /// what was read before stays, so its section doesn't flip on a
    /// Refresh. A checkout gone is no such blip: it replaces it.
    nonisolated static func merged(
        _ new: [String: BoardSections.BaseRemote], keeping known: [String: BoardSections.BaseRemote]
    ) -> [String: BoardSections.BaseRemote] {
        var result = new
        for (commonDir, remote) in new {
            switch (remote, known[commonDir]) {
            case (.unread, let known?):
                result[commonDir] = known
            case (.gitHub(let repository, nil, let name), .gitHub(let knownRepository, let base?, let knownName)?)
                where repository == knownRepository && name == knownName:
                result[commonDir] = .gitHub(repository: repository, baseBranch: base, remote: name)
            default:
                break
            }
        }
        return result
    }

    private func apply(
        _ newConfig: BoardConfigStore.Loaded, context: BoardSections.Context, listsWorktreesAgain: Bool = true
    ) {
        let wasRead = loaded != nil
        let previousSections = sections.map(\.id)
        loaded = newConfig
        self.context = context
        // An unreadable file holds no config this build can use.
        let entries = newConfig.status == .unreadable ? [] : newConfig.entries
        sections = BoardSections.sections(entries, context: context)
        ownSections = sections
        let anchored = Set(sections.compactMap(\.commonDir))
        let extras = extraRepositories.compactMap { anchor in
            BoardSections.commonDir(of: anchor).flatMap { commonDir in
                anchored.contains(commonDir) ? nil : BoardSections.Section(slot: .anchor(commonDir: commonDir), anchor: anchor, config: nil)
            }
        }
        sections += extras
        extraIDs = Set(extras.map(\.id))
        displayNames = BoardSections.displayNames(sections)
        var newReads: [String: RepositoryReads] = [:]
        // Two sections never read one repository, as Board Settings never
        // saves one for two: a saved one keeps it, else the first remote.
        var taken = Set(sections.compactMap { $0.config?.gitHubRepository })
        for section in sections {
            let remote = section.commonDir.flatMap { context.baseRemotes[$0] }
            // A config, even without a valid repository, wins over the remote.
            var read = section.config.map { RepositoryReads(config: $0) } ?? remote.flatMap(RepositoryReads.init(baseRemote:))
            if section.config == nil, let gitHub = read?.gitHub, !taken.insert(gitHub).inserted { read = nil }
            guard var fresh = read else { continue }
            if var previous = reads[section.id], previous.gitHub == fresh.gitHub {
                // Saved since it was read from its remote: what it read stays.
                previous.remoteName = fresh.remoteName
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
        if wasRead, listsWorktreesAgain, Set(newReads.keys) != Set(reads.keys) || sections.map(\.id) != previousSections {
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

    /// The sections whose reading still stands: their pull requests read
    /// within two read intervals, or for one without GitHub, the worktrees
    /// listed. A Board not shown doesn't read: what it last read ages, and
    /// its tasks' rows show no station.
    func freshSections(now: Date = Date(), clock: TimeInterval = ProjectBoard.clock()) -> Set<String> {
        let interval = ProjectBoard.RefreshSchedule.interval
        let worktrees = Self.stands(age: schedule.lastStarted[.worktrees].map { clock - $0 }, interval: interval(.worktrees, false))
        let ids = sections.map(\.id) + Array(reads.keys) + [Self.noRepositoryID]
        return Set(ids.filter { id in
            guard let read = reads[id] else { return worktrees }
            return read.pullRequestsAreFresh(now: now)
        })
    }

    /// A reading made `age` seconds ago, of a source read every `interval`:
    /// it stands for two intervals. Never made, it doesn't.
    nonisolated static func stands(age: TimeInterval?, interval: TimeInterval) -> Bool {
        age.map { $0 <= 2 * interval } ?? false
    }

    /// Reads what is due. Called on every status refresh (the heartbeat),
    /// which reads only while the board is on screen.
    func tick(now: TimeInterval = ProjectBoard.clock(), onScreen: Bool? = nil) {
        guard loaded != nil, !isReadingConfig else { return }
        // Shown at last: the remotes that waited for it.
        if let due = remotesDue, due == configRead, isShown() {
            remotesDue = nil
            readBaseRemotesWhenShown(configRead: due)
        }
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

    /// A workspace closed or moved away since the last listing: list again,
    /// so that a repository's section goes with its last workspace.
    func expireWorktreesIfWorkspacesLeft(_ folders: [String]) {
        if !listedWorkspaceFolders.isSubset(of: folders) { schedule.expire(.worktrees) }
    }

    /// The workspaces' folders, then each repository anchor's main checkout
    /// (or its git dir, for a bare repository): its worktrees show even
    /// with no workspace open there. Not another repository's
    /// (`extraRepositories`): it shows while a workspace is in it.
    private var foldersToList: [String] {
        let anchors = ownSections.compactMap(\.checkoutFolder)
        let folders = workspaceFolders()
        return folders + anchors.filter { !folders.contains($0) }
    }

    private func readWorktrees(now: TimeInterval) {
        schedule.start(.worktrees, now: now)
        let current = generation
        let folders = foldersToList
        let workspaces = Set(workspaceFolders())
        Self.readOffMain({ ProjectBoard.readLocal(folders: folders) }, then: { [weak self] snapshot in
            guard let self, current == self.generation else { return }
            self.schedule.finish(.worktrees)
            self.local = snapshot
            self.listedWorkspaceFolders = workspaces
            self.noteExtraRepositories(in: snapshot)
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
                    ProjectBoard.parsePullRequests(data, repository: gitHub).map(Result.success) ?? .failure(.unreadable(output: data))
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
                    GitHub.parseWorkflowRuns(data).map { .success($0.first) } ?? .failure(.unreadable(output: data))
                }
            }, then: { [weak self] result in
                self?.finish(source, section: id, reads: repository, generation: current) { reads in
                    reads.errors[source] = result.failureValue
                    if case .success(let run) = result { reads.postMergeRun = .some(run) }
                }
            })
        }
    }

    /// Retarget (docs/design/pr-stacks.md): bases pull request `number` of the
    /// section's repository on `base`, then reads its open pull requests
    /// again. Never sent twice: another click is the user's.
    func retarget(_ number: Int, onto base: String, section id: String) {
        // Never on a repository only read from its remote: Board Settings first.
        guard let repository = reads[id], !repository.isFromRemote else { return }
        let client = self.client
        let name = repository.name
        let current = generation
        Self.readOffMain({ client.retarget(repository: name, number: number, base: base) }, then: { [weak self] result in
            guard let self, current == self.generation, self.reads[id]?.generation == repository.generation else { return }
            self.reads[id]?.retargetFailure = result.failureValue.map { "Retarget #\(number): \(ProjectBoard.message($0))" }
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

    /// The column's header: the space, the repository of a Board with one,
    /// and when the pull requests were read, or what went wrong reading
    /// them (Refresh's tooltip); the repository's header has the pill.
    func columnHeader(spaceName: String, now: Date = Date()) -> BoardColumnView.Header {
        let single = soleSection.flatMap { reads[$0.id] }
        return BoardColumnView.Header(
            spaceName: spaceName, repository: single?.name,
            status: single.flatMap { Self.errorText($0)?.message } ?? readStatus(now: now)
        )
    }

    /// When the pull requests were last read, or that they are being read.
    private func readStatus(now: Date) -> String? {
        if let readAt = reads.values.compactMap(\.pullRequestsReadAt).max() {
            return "Updated \(ProjectBoard.clockTime(readAt, now: now))"
        }
        return readsPullRequests ? "Reading pull requests…" : nil
    }

    /// What the Board says in place of what it lists, when it lists
    /// nothing: board.json unreadable, read-only or not read yet, no
    /// repository set. A message about the settings offers them under it.
    /// Nil: it lists (or lists its worktrees first).
    func bodyMessage() -> (text: String, offersSettings: Bool)? {
        if let loaded, loaded.status == .unreadable { return ("board.json can’t be read: open Board Settings… to replace it.", true) }
        // Board Settings can't save it.
        if let loaded, case .readOnly(let reason) = loaded.status, !listsRows { return (reason.message, false) }
        if loaded == nil { return ("Reading board.json…", false) }
        if !listsRows { return ("Set this space’s repository in Board Settings… to list its branches and pull requests.", true) }
        return nil
    }

    static let listingWorktrees = "Listing worktrees…"


    /// A section of a repository that is no anchor of the space
    /// (`extraRepositories`): read-only.
    func isExtra(_ section: BoardSections.Section) -> Bool {
        extraIDs.contains(section.id)
    }

    /// The repositories the worktrees listed that no section has: a section
    /// each from now on, read from their remotes as an anchor without
    /// settings is. Each repository's base remote is read before it is
    /// placed: its section reads its pull requests at once, and a clone
    /// naming the repository a section reads joins it, as an anchor's
    /// clones do. Not while board.json is read again, nor before the
    /// space's own remotes are known: an anchor's clone would show as
    /// another repository for a moment. The reads that land call it again.
    private func noteExtraRepositories(in snapshot: ProjectBoard.LocalSnapshot) {
        guard !isReadingConfig, let loaded else { return }
        let remote = { (commonDir: String) in self.context.baseRemotes[commonDir] ?? self.listedRemotes[commonDir] }
        // The space's own remotes, read for its sections without settings: their read lands and calls this again.
        let readsOwnRemotes = loaded.status == .missing || loaded.status == .loaded
        let ownPending = readsOwnRemotes && ownSections.contains { section in
            section.config == nil && section.commonDir.map { remote($0) == nil } ?? false
        }
        if ownPending { return }
        // A section of the space's that reads no GitHub repository (a file read-only, settings without a valid
        // repository): its remote is read here, only to know its clones.
        let ownUnread = ownSections.compactMap { section -> String? in
            guard reads[section.id]?.gitHub == nil, let commonDir = section.commonDir, remote(commonDir) == nil else { return nil }
            return commonDir
        }
        let anchored = Set(ownSections.compactMap(\.commonDir))
        // A section reading a repository takes its other clones by remote (`ProjectBoard.sectionRows`): the one
        // board.json names without anchors, an anchor's second checkout. Compared as the rows are, by owner and name.
        let taken = ownSections.compactMap { section in
            reads[section.id]?.gitHub ?? section.commonDir.flatMap(remote).flatMap(RepositoryReads.init(baseRemote:))?.gitHub
        }
        let isTaken = { (remotes: [GitHubRepository]) in
            remotes.contains { remote in taken.contains { $0.hasOwnerAndName(of: remote) } }
        }
        var listed = anchored
        // By their main checkout's path: the same clone names the section whatever the sidebar's order.
        let candidates = snapshot.repositories.compactMap { repository -> (String, ProjectBoard.LocalRepository)? in
            guard let commonDir = repository.commonDir, listed.insert(commonDir).inserted, !isTaken(repository.remotes) else { return nil }
            return (commonDir, repository)
        }.sorted { ($0.1.worktrees.first?.path ?? $0.0) < ($1.1.worktrees.first?.path ?? $1.0) }
        listedRemotes = listedRemotes.filter { listed.contains($0.key) }
        // Read again after a Refresh, before they are placed again: a remote changed since lands.
        let unread = candidates.map(\.0).filter { listedRemotes[$0] == nil } + ownUnread
        guard unread.isEmpty else {
            readListedRemotes(Set(unread))
            return
        }
        var found: [SpaceAnchor] = []
        var remotes: [String: BoardSections.BaseRemote] = [:]
        var placedRepositories: [GitHubRepository] = []
        let folders = workspaceFolders().map { snapshot.folders[$0] ?? $0 }
        for (commonDir, repository) in candidates {
            guard let read = listedRemotes[commonDir] else { continue }
            // Its section reads its base remote: a clone whose own base remote is that repository joins it.
            if let gitHub = RepositoryReads(baseRemote: read)?.gitHub {
                guard !placedRepositories.contains(where: { $0.hasOwnerAndName(of: gitHub) }) else { continue }
                placedRepositories.append(gitHub)
            }
            remotes[commonDir] = read
            found.append(SpaceAnchor.repository(commonDir: commonDir, topLevel: Self.topLevel(of: repository, holding: folders)))
        }
        guard found != extraRepositories || remotes.contains(where: { context.baseRemotes[$0.key] != $0.value }) else { return }
        // Gone, unless made one of the space's: its remote with it.
        let gone = Set(extraRepositories.compactMap(BoardSections.commonDir(of:)))
            .subtracting(found.compactMap(BoardSections.commonDir(of:))).subtracting(anchored)
        extraRepositories = found
        var placed = context
        placed.baseRemotes = placed.baseRemotes.merging(remotes) { _, read in read }.filter { !gone.contains($0.key) }
        apply(loaded, context: placed, listsWorktreesAgain: false)
    }

    /// The base remotes of these repositories (common dirs), into
    /// `listedRemotes`; the repositories placed again once read.
    private func readListedRemotes(_ commonDirs: Set<String>) {
        guard runningListedRead != generation else { return }
        runningListedRead = generation
        let current = generation
        let toRead = commonDirs.sorted().map { commonDir in
            let anchor = SpaceAnchor.repository(commonDir: commonDir, topLevel: nil)
            return BoardSections.Section(slot: .anchor(commonDir: commonDir), anchor: anchor, config: nil)
        }
        Self.readOffMain({ BoardSections.readBaseRemotes(toRead) }, then: { [weak self] remotes in
            guard let self, current == self.generation else { return }
            self.runningListedRead = nil
            // What a blip didn't answer stays as read before, here or for a section.
            var read = Self.merged(remotes, keeping: self.listedRemotes.merging(self.context.baseRemotes) { listed, _ in listed })
            // Never asked again and again: one git didn't answer for is unread.
            for commonDir in commonDirs where read[commonDir] == nil { read[commonDir] = .unread }
            self.listedRemotes.merge(read) { _, new in new }
            if let local = self.local { self.noteExtraRepositories(in: local) }
        })
    }

    /// The worktree of `repository` a workspace of the space is in (the
    /// innermost), else its first: what adding the repository from that
    /// workspace would name it (a bare repository's worktree, a
    /// submodule's checkout).
    static func topLevel(of repository: ProjectBoard.LocalRepository, holding folders: [String]) -> String? {
        let worktrees = repository.worktrees.filter { !$0.isBare }.map(\.path)
        for folder in folders {
            let holding = worktrees.filter { folder == $0 || folder.hasPrefix($0 + "/") }
            if let innermost = holding.max(by: { $0.count < $1.count }) { return innermost }
        }
        return repository.worktrees.first?.path
    }

    /// Board Settings is what would show its pull requests: not for a
    /// checkout gone, nor for the repository another section reads.
    func canBeSetUp(_ section: BoardSections.Section) -> Bool {
        if isExtra(section) { return false }
        if case .notARepository? = section.commonDir.flatMap({ context.baseRemotes[$0] }), reads[section.id] == nil {
            return false
        }
        return sectionSharingRemote(with: section) == nil
    }

    /// The other section reading the GitHub repository this one's remote
    /// names, which this one then doesn't read.
    private func sectionSharingRemote(with section: BoardSections.Section) -> BoardSections.Section? {
        guard section.config == nil, reads[section.id] == nil,
              case .gitHub(let name, _, _)? = section.commonDir.flatMap({ context.baseRemotes[$0] }),
              let gitHub = GitHubRepository(ownerAndName: name)
        else { return nil }
        return sections.first { other in
            other.id != section.id && (reads[other.id]?.gitHub == gitHub || other.config?.gitHubRepository == gitHub)
        }
    }

    /// Why a section has no saved repository, in a sentence; nil when it
    /// has one, or while its remote is being read.
    func setupNote(_ section: BoardSections.Section) -> String? {
        if isExtra(section) { return extraNote(section) }
        if let reads = reads[section.id] {
            return reads.remoteName.map { "Read-only, from \($0): save Board Settings to use the merge queue." }
        }
        if let loaded, case .readOnly(let reason) = loaded.status { return reason.message }
        guard section.config == nil else {
            return "Board Settings has no valid GitHub repository for it: set one to see its pull requests."
        }
        if let other = sectionSharingRemote(with: section) {
            let otherName = displayNames[other.id] ?? other.name ?? "another repository"
            return "Same GitHub repository as “\(otherName)”: its pull requests show there."
        }
        switch section.commonDir.flatMap({ context.baseRemotes[$0] }) {
        case .noRemote?:
            return "No remote: set its GitHub repository in Board Settings to see its pull requests."
        case .notGitHub(let host, let remote)?:
            let place = host.map { "\(remote) points to \($0), not github.com" } ?? "\(remote) isn’t on github.com"
            return "\(place): set its GitHub repository in Board Settings to see its pull requests."
        case .notARepository?:
            return "Its checkout is gone, or no longer a git repository: Refresh once it’s back, or remove it in Space Settings."
        case .unread?:
            return "Nirux couldn’t read its remotes: Refresh, or set its GitHub repository in Board Settings."
        case nil where isReadingRemotes:
            return nil
        case .gitHub?, nil:
            return "No GitHub repository: set it in Board Settings to see its pull requests."
        }
    }

    /// What a section of a repository that is no anchor of the space says:
    /// read-only, whatever its remote, and why it reads nothing when it does.
    private func extraNote(_ section: BoardSections.Section) -> String? {
        let notAnchor = "not one of this space’s repositories, so no merge queue here"
        if let reads = reads[section.id] { return "Read-only, from \(reads.remoteName ?? "its remote"): \(notAnchor)." }
        if let other = sectionSharingRemote(with: section) {
            let otherName = displayNames[other.id] ?? other.name ?? "another repository"
            return "Same GitHub repository as “\(otherName)”: its pull requests show there."
        }
        switch section.commonDir.flatMap({ context.baseRemotes[$0] }) {
        case .noRemote?: return "No remote: its pull requests don’t show (\(notAnchor))."
        case .notGitHub(let host, let remote)?:
            let place = host.map { "\(remote) points to \($0), not github.com" } ?? "\(remote) isn’t on github.com"
            return "\(place): its pull requests don’t show (\(notAnchor))."
        case .notARepository?: return "Its checkout is gone, or no longer a git repository."
        case .unread?: return "Nirux couldn’t read its remotes: Refresh to read them again."
        case nil where isReadingRemotes: return nil
        case .gitHub?, nil: return "No GitHub repository: its pull requests don’t show (\(notAnchor))."
        }
    }

    /// The rows of the Board's repositories, which the stages are made of:
    /// each section's, then the workspaces in none of their repositories
    /// (or in no repository).
    struct ListedRows {
        var bySection: [String: [ProjectBoard.Row]]
        var others: [ProjectBoard.Row]
    }

    func listedRows(local: ProjectBoard.LocalSnapshot, workspaces: [ProjectBoard.Workspace]) -> ListedRows {
        let extras = sections.filter(isExtra)
        // A space without a repository anchor: its one repository, found by remote, as before anchors; the
        // workspaces in another repository go to that repository's section when it has one.
        if let only = soleSection, only.anchor == nil, let repository = reads[only.id] {
            let rows = ProjectBoard.rows(ProjectBoard.Sources(
                repository: repository.gitHub,
                baseBranch: repository.baseBranch,
                local: local.repositories,
                workspaces: workspaces,
                openPullRequests: repository.openPullRequests ?? [],
                mergedPullRequests: repository.mergedPullRequests ?? []
            ))
            let outside = rows.filter { $0.group == .otherRepository }
            var listed = ListedRows(bySection: [only.id: rows.filter { $0.group != .otherRepository }], others: outside)
            guard !extras.isEmpty else { return listed }
            let outsideIDs = Set(outside.flatMap { $0.workspaces.map(\.id) })
            let (byExtra, rest) = ProjectBoard.sectionRows(
                extras.map(sources(of:)), local: local.repositories, workspaces: workspaces.filter { outsideIDs.contains($0.id) }
            )
            listed.bySection.merge(byExtra) { own, _ in own }
            listed.others = rest
            return listed
        }
        let (bySection, others) = ProjectBoard.sectionRows(sections.map(sources(of:)), local: local.repositories, workspaces: workspaces)
        return ListedRows(bySection: bySection, others: others)
    }

    /// What a section's rows are made of.
    private func sources(of section: BoardSections.Section) -> ProjectBoard.SectionSources {
        let repository = reads[section.id]
        return ProjectBoard.SectionSources(
            id: section.id, commonDir: section.commonDir, repository: repository?.gitHub,
            baseBranch: repository?.baseBranch ?? section.config?.baseBranch,
            openPullRequests: repository?.openPullRequests ?? [],
            mergedPullRequests: repository?.mergedPullRequests ?? []
        )
    }

    /// The post-merge run as a pill, while there is one to read.
    static func runStatus(_ reads: RepositoryReads, now: Date) -> ColumnHeaderView.Status? {
        guard reads.baseBranch != nil, let workflow = reads.workflow else { return nil }
        switch reads.postMergeRun {
        case .some(let run): return .postMergeRun(run, workflow: workflow, now: now)
        case nil:
            let label = GitHub.workflowLabel(workflow)
            return reads.errors[.postMergeRun] == nil
                ? ColumnHeaderView.Status("\(label) …", tone: .neutral, toolTip: "Reading the last \(label) run…") : nil
        }
    }

    /// What went wrong reading a section: "GitHub error" and the messages.
    static func errorText(_ reads: RepositoryReads) -> (title: String, message: String)? {
        let messages = (ProjectBoard.messages(of: reads.errors) + [reads.retargetFailure].compactMap { $0 }).sorted()
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
