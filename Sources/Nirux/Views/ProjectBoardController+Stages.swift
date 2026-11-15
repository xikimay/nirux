import AppKit

// MARK: - The Board as stages' content (docs/design/board-stages.md, sections 5 and 6)

extension ProjectBoardController {
    /// What the shell holds of the space, beside what the controller read.
    struct StagesInputs {
        struct Space: Equatable {
            var name: String
            var color: NSColor
        }

        /// Nil only between a space deleted and its Boards following their
        /// workspaces to General.
        var space: Space?
        /// The space's workspaces, as the Board's rows take them.
        var workspaces: [ProjectBoard.Workspace]
        /// The space's tasks by workspace id, in the sidebar's order, the
        /// Lead left out.
        var tasks: [String]
        /// A sub-task's workspace id → the one it is listed under.
        var parents: [String: String] = [:]
        /// The space's Lead's workspace id.
        var lead: String?
        /// What each task's sidebar row reads, the Lead's too
        /// (`NiruxShellView.boardReadings`).
        var readings: [String: BoardStages.TaskReading] = [:]
        /// Each section's merge queue, by section id.
        var queues: [String: ProjectBoard.QueueState] = [:]
        /// The queues that run, here or in another Nirux
        /// (`NiruxShellView.projectBoardQueues`): a section's, or one left
        /// on a repository no section has.
        var runningQueues: [BoardStagesView.RunningQueue] = []
        /// The worktrees and folders a clean-up of which runs, by path.
        var cleaningUp: Set<String> = []
        var order: BoardStages.Order = .sidebar
    }

    /// What the Board's clicks act on, as it last showed them: what the
    /// lines and the menus don't carry.
    struct StagesTargets: Equatable {
        /// A task's line, by its id (its workspace's): Focus on its most
        /// urgent agent column, else on the workspace.
        var focus: [String: ProjectBoard.Action] = [:]
        /// A repository's line's worktree, by its id, for its "Clean up"
        /// link (a merged pull request's, so never a line without a
        /// repository); a merged task's too, which has left the list for
        /// "Merged today".
        var folders: [String: BoardStages.Folder] = [:]
        /// Open Main Checkout, by the checkout's path: Focus where a
        /// workspace is open there, else Open a shell there.
        var mainCheckouts: [String: ProjectBoard.Action] = [:]
        /// What each section's lines offer the queue's list now, by section
        /// id and pull request: a click acts only on an offer still made,
        /// and not refused (a draft since, a queue started).
        var offers: [String: [Int: BoardStages.QueueOffer]] = [:]
        /// The Retarget each section's lines offer now, by section id and
        /// pull request: as the offers, a click acts only on one still
        /// offered (not once the queue's list holds it), and not refused
        /// (a queue started since).
        var retargets: [String: [Int: Retarget]] = [:]

        struct Retarget: Equatable {
            /// The branch it bases the pull request on.
            var onto: String
            /// Why it does nothing for now; nil when it acts.
            var blocked: String?
        }
    }

    /// The id of the section of the workspaces in no repository.
    static let noRepositoryID = "no-repository"

    /// What the Board as stages shows of the space: its rows (`listedRows`),
    /// as stages. Its message (`bodyMessage`) takes the sections' place;
    /// the running queues' lines stay at its foot. With
    /// it, what its clicks act on (whoever shows it keeps them:
    /// `stagesTargets`).
    func stagesContent(_ inputs: StagesInputs, now: Date = Date()) -> (content: BoardStagesView.Content, targets: StagesTargets) {
        var targets = StagesTargets()
        let content = stagesContent(inputs, now: now, targets: &targets)
        return (content, targets)
    }

    private func stagesContent(_ inputs: StagesInputs, now: Date, targets: inout StagesTargets) -> BoardStagesView.Content {
        var content = BoardStagesView.Content(
            header: stagesHeader(inputs), order: inputs.order, sections: [], now: now.timeIntervalSince1970,
            runningQueues: inputs.runningQueues
        )
        if let message = bodyMessage() {
            content.message = BoardStagesView.Message(text: message.text, offersSettings: message.offersSettings)
            return content
        }
        guard let local else {
            content.message = BoardStagesView.Message(text: Self.listingWorktrees)
            return content
        }
        for workspace in inputs.workspaces {
            targets.focus[workspace.id] = Self.focus(workspace.agent, workspaces: [workspace.id])
        }
        let heads = Dictionary(
            local.repositories.flatMap(\.worktrees).compactMap { worktree in worktree.head.map { (worktree.path, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let others: [ProjectBoard.Row]
        switch listedRows(local: local, workspaces: inputs.workspaces) {
        case .one(let rows, _):
            // Its rows hold the Board's own workspace at least: a read that failed says so in the section's pill.
            guard let only = sections.first else { return content }
            others = rows.filter { $0.group == .otherRepository }
            content.sections = [stagesSection(
                only, rows: rows.filter { $0.group != .otherRepository }, inputs, heads: heads, now: now, targets: &targets
            )]
        case .sections(let bySection, let rest):
            others = rest
            content.sections = sections.map { stagesSection($0, rows: bySection[$0.id] ?? [], inputs, heads: heads, now: now, targets: &targets) }
        }
        // A workspace in no repository is a line there; one in another repository is no line (`sectionFacts`), but under
        // Other workspaces.
        let noRepository = BoardStages.section(
            BoardStages.sectionFacts(
                BoardStages.RepositoryReading(id: Self.noRepositoryID, rows: others, readsPullRequests: false, cleaningUp: inputs.cleaningUp),
                tasks: inputs.tasks, readings: inputs.readings, parents: inputs.parents
            ),
            order: inputs.order, now: now.timeIntervalSince1970
        )
        if !noRepository.units.isEmpty {
            content.sections.append(BoardStagesView.Section(id: Self.noRepositoryID, title: "No repository", lines: noRepository))
        }
        let entries = BoardStages.otherWorkspaces(others)
        if !entries.isEmpty {
            let id = BoardStagesView.Section.otherWorkspacesID
            content.sections.append(BoardStagesView.Section(
                id: id, title: "Other workspaces",
                lines: BoardStages.Section(id: id, units: [], withoutTask: [], merged: [], otherWorktrees: entries), kind: .otherWorkspaces
            ))
        }
        return content
    }

    /// The space: its colour and name, what it holds (its repositories,
    /// anchored or read; its tasks not archived, the Lead apart), its
    /// Lead's state and line, said as a line says a task at rest or at work.
    private func stagesHeader(_ inputs: StagesInputs) -> BoardStagesView.Header {
        // Another repository's read-only section only counts beside the Board's own rows (no message in their place).
        let repositories = sections.filter { ($0.anchor != nil || reads[$0.id] != nil) && (listsRows || !isExtra($0)) }.count
        let tasks = inputs.workspaces.filter { !$0.isInactive && $0.id != inputs.lead }.count
        let held = [
            repositories == 0 ? nil : "\(repositories) \(repositories == 1 ? "repository" : "repositories")",
            "\(tasks) \(tasks == 1 ? "task" : "tasks")"
        ]
        var header = BoardStagesView.Header(
            name: inputs.space?.name ?? "", color: inputs.space?.color ?? Theme.Color.textTertiary,
            summary: held.compactMap { $0 }.joined(separator: " · ")
        )
        if let lead = inputs.lead {
            let reading = inputs.readings[lead] ?? BoardStages.TaskReading()
            var facts = BoardStages.Facts(id: lead, title: "Lead")
            facts.hasRepository = false
            facts.activity = reading.activity
            facts.summary = reading.summary
            facts.statusLine = reading.statusLine
            facts.nextStep = reading.nextStep
            facts.blocker = reading.blocker
            facts.lastActivityAt = reading.lastActivityAt
            let line = BoardStages.line(facts)
            header.lead = BoardStagesView.Lead(state: line.state, text: "Lead · \(line.phrase.text)")
        }
        return header
    }

    /// One repository: its lines from what it read and what the tasks
    /// read, its header's pill, queue and menu.
    private func stagesSection(
        _ section: BoardSections.Section, rows: [ProjectBoard.Row], _ inputs: StagesInputs, heads: [String: String], now: Date,
        targets: inout StagesTargets
    ) -> BoardStagesView.Section {
        let reads = reads[section.id]
        let reading = BoardStages.RepositoryReading(
            id: section.id, rows: rows, readsPullRequests: reads?.openPullRequests != nil,
            requiredChecks: section.config?.requiredChecks ?? [], baseBranch: reads?.baseBranch ?? section.config?.baseBranch,
            queue: inputs.queues[section.id], merged: reads?.mergedPullRequests ?? [], heads: heads, cleaningUp: inputs.cleaningUp,
            gitHub: reads?.gitHub
        )
        let facts = BoardStages.sectionFacts(reading, tasks: inputs.tasks, readings: inputs.readings, parents: inputs.parents, lead: inputs.lead)
        Self.noteFolders(of: facts, in: &targets)
        var shown = BoardStagesView.Section(
            // A space without an anchor: its repository's name ("widgets"), `owner/name` beside it.
            id: section.id,
            title: (section.anchor == nil ? reads.flatMap(Self.savedName) : nil) ?? displayNames[section.id] ?? section.name ?? "Repository",
            detail: reads?.name,
            status: stagesStatus(section, now: now),
            lines: BoardStages.section(facts, order: inputs.order, now: now.timeIntervalSince1970)
        )
        for line in (shown.lines.units + shown.lines.withoutTask).flatMap(\.lines) {
            if let offer = line.offer { targets.offers[section.id, default: [:]][offer.number] = offer }
            // The menu's item: the phrase's link is only there while it acts.
            for case .retarget(.retarget(let number, let onto), let blocked) in line.menu {
                targets.retargets[section.id, default: [:]][number] = StagesTargets.Retarget(onto: onto, blocked: blocked)
            }
        }
        if let state = inputs.queues[section.id] {
            // The next Start's list, a merged one for none (as the queue, GitHub's lists or a task's line knows it),
            // whether or not the Board lists it (not read yet, closed, beyond the open pull requests read).
            let proposed = state.isLocked ? 0 : BoardStages.nextStartList(state, knownMerged: facts.knownMerged).count
            shown.queue = BoardStagesView.sectionQueue(state, proposed: proposed)
        }
        // Board Settings… where it can set the repository up and save it, as the table offered it.
        let offersSettings = !isReadOnly && canBeSetUp(section)
        shown.menu = offersSettings ? [.boardSettings] : []
        if let main = rows.first(where: { $0.group == .main }), let path = main.worktreePath {
            shown.menu.append(.openMainCheckout(path: path))
            // As the table's row of the main checkout: Focus, else Open.
            targets.mainCheckouts[path] = Self.focus(main.agent, workspaces: main.workspaces.map(\.id))
                ?? .open(path: path, title: main.branch ?? (path as NSString).lastPathComponent)
        }
        return shown
    }

    private static func focus(_ agent: ProjectBoard.Agent, workspaces: [String]) -> ProjectBoard.Action? {
        agent.focusTarget(workspaces: workspaces).map { .focus(workspaceID: $0.workspaceID, columnID: $0.columnID) }
    }

    private static func noteFolders(of facts: BoardStages.SectionFacts, in targets: inout StagesTargets) {
        for line in facts.lines {
            if let folder = line.folder { targets.folders[line.id] = folder }
        }
    }

    /// A repository's name as saved ("WidgetKit" of "Acme/WidgetKit"), not
    /// as compared (`GitHubRepository` lowercases it).
    private static func savedName(_ reads: RepositoryReads) -> String? {
        reads.name.split(separator: "/").last.map(String.init)
    }

    private var isReadOnly: Bool {
        if let loaded, case .readOnly = loaded.status { return true }
        return false
    }

    /// The header's pill: what went wrong reading the repository, else why
    /// it has no saved settings, the table's sentence under the pointer:
    /// "Read-only" when board.json can't be saved, "Invalid settings" when
    /// they name no valid GitHub repository, "No settings" where Board
    /// Settings can set it up, else "Not read" (its checkout gone, another
    /// section reading its repository); else its post-merge run.
    private func stagesStatus(_ section: BoardSections.Section, now: Date) -> ColumnHeaderView.Status? {
        if let reads = reads[section.id], let error = Self.errorText(reads) {
            return ColumnHeaderView.Status(error.title, tone: .error, symbol: Theme.Symbol.agentError, toolTip: error.message)
        }
        if let note = setupNote(section) {
            // Board Settings can't save it: why, as board.json's state says it.
            if let loaded, case .readOnly(let reason) = loaded.status {
                return ColumnHeaderView.Status("Read-only", tone: .neutral, toolTip: reason.message)
            }
            let word = isExtra(section) ? (reads[section.id] == nil ? "Not read" : "Read-only")
                : section.config != nil && reads[section.id] == nil ? "Invalid settings" : canBeSetUp(section) ? "No settings" : "Not read"
            return ColumnHeaderView.Status(word, tone: .neutral, toolTip: note)
        }
        return reads[section.id].flatMap { Self.runStatus($0, now: now) }
    }
}
