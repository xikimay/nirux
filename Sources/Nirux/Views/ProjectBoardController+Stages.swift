import AppKit

// MARK: - The Board as stages' content (docs/design/board-stages.md, sections 5 and 6)

extension ProjectBoardController {
    /// What the shell holds of the space, beside what the controller read.
    struct StagesInputs {
        struct Space: Equatable {
            var name: String
            var color: NSColor
        }

        /// Nil once the space was deleted.
        var space: Space?
        /// The space's workspaces, as the table's rows take them.
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
        /// Queues left running on a repository no section has: their lines
        /// at the foot.
        var orphanQueues: [BoardStagesView.RunningQueue] = []
        /// The worktrees and folders a clean-up of which runs, by path.
        var cleaningUp: Set<String> = []
        var order: BoardStages.Order = .sidebar
    }

    /// The id of the section of the workspaces in no repository.
    static let noRepositoryID = "no-repository"

    /// What the Board as stages shows of the space: what the table lists,
    /// as stages. Its message in place of the sections is the table's in
    /// place of its rows; the running queues' lines stay at its foot.
    func stagesContent(_ inputs: StagesInputs, now: Date = Date()) -> BoardStagesView.Content {
        var content = BoardStagesView.Content(
            header: stagesHeader(inputs), order: inputs.order, sections: [], now: now.timeIntervalSince1970,
            runningQueues: sections.compactMap { section in
                inputs.queues[section.id].flatMap { state in
                    let repository = repository(of: section)?.name
                    let title = section.anchor == nil ? repository : displayNames[section.id]
                    return BoardStagesView.runningQueue(
                        id: section.id, title: title ?? repository ?? "Repository", tooltip: repository, state: state
                    )
                }
            } + inputs.orphanQueues
        )
        if let message = bodyMessage(projectExists: inputs.space != nil) {
            content.message = BoardStagesView.Message(text: message.text, offersSettings: message.offersSettings)
            return content
        }
        guard let local else {
            content.message = BoardStagesView.Message(text: Self.listingWorktrees)
            return content
        }
        let heads = Dictionary(
            local.repositories.flatMap(\.worktrees).compactMap { worktree in worktree.head.map { (worktree.path, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let others: [ProjectBoard.Row]
        switch listedRows(local: local, workspaces: inputs.workspaces) {
        case .one(let rows, let repository):
            guard !rows.isEmpty, let only = sections.first else {
                content.message = BoardStagesView.Message(text: Self.nothingToList(in: repository))
                return content
            }
            others = rows.filter { $0.group == .otherRepository }
            content.sections = [stagesSection(only, rows: rows.filter { $0.group != .otherRepository }, inputs, heads: heads, now: now)]
        case .sections(let bySection, let rest):
            others = rest
            content.sections = sections.map { stagesSection($0, rows: bySection[$0.id] ?? [], inputs, heads: heads, now: now) }
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

    /// The space: its colour and name, what it holds, its Lead's state and
    /// line, said as a line says a task at rest or at work.
    private func stagesHeader(_ inputs: StagesInputs) -> BoardStagesView.Header {
        let repositories = sections.count
        let tasks = inputs.tasks.count
        var header = BoardStagesView.Header(
            name: inputs.space?.name ?? "Deleted space", color: inputs.space?.color ?? Theme.Color.textTertiary,
            summary: "\(repositories) \(repositories == 1 ? "repository" : "repositories") · \(tasks) \(tasks == 1 ? "task" : "tasks")"
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
        _ section: BoardSections.Section, rows: [ProjectBoard.Row], _ inputs: StagesInputs, heads: [String: String], now: Date
    ) -> BoardStagesView.Section {
        let reads = reads[section.id]
        let reading = BoardStages.RepositoryReading(
            id: section.id, rows: rows, readsPullRequests: reads?.openPullRequests != nil,
            requiredChecks: section.config?.requiredChecks ?? [], baseBranch: reads?.baseBranch ?? section.config?.baseBranch,
            queue: inputs.queues[section.id], merged: reads?.mergedPullRequests ?? [], heads: heads, cleaningUp: inputs.cleaningUp
        )
        let facts = BoardStages.sectionFacts(reading, tasks: inputs.tasks, readings: inputs.readings, parents: inputs.parents, lead: inputs.lead)
        var shown = BoardStagesView.Section(
            // A space without an anchor: its repository's name ("widgets"), `owner/name` beside it.
            id: section.id,
            title: section.anchor == nil ? reads?.gitHub.name ?? "Repository" : displayNames[section.id] ?? section.name ?? "Repository",
            detail: reads?.name,
            status: stagesStatus(section, now: now),
            lines: BoardStages.section(facts, order: inputs.order, now: now.timeIntervalSince1970)
        )
        if let state = inputs.queues[section.id] {
            // The next Start's list as the Board shows it: each pull request once, a merged one for none.
            let proposed = state.isLocked ? 0 : Set(facts.lines.compactMap { $0.queue.order == nil ? nil : $0.pullRequest?.number }).count
            shown.queue = BoardStagesView.sectionQueue(state, proposed: proposed)
        }
        shown.menu = [.boardSettings] + (rows.first { $0.group == .main }?.worktreePath.map { [.openMainCheckout(path: $0)] } ?? [])
        return shown
    }

    /// The header's pill: what went wrong reading the repository, else why
    /// it has no saved settings ("No settings", the reason under the
    /// pointer), else its post-merge run.
    private func stagesStatus(_ section: BoardSections.Section, now: Date) -> ColumnHeaderView.Status? {
        if let reads = reads[section.id], let error = Self.errorText(reads) {
            return ColumnHeaderView.Status(error.title, tone: .error, symbol: Theme.Symbol.agentError, toolTip: error.message)
        }
        if let note = setupNote(section) {
            return ColumnHeaderView.Status("No settings", tone: .neutral, toolTip: note)
        }
        return reads[section.id].flatMap { Self.runStatus($0, now: now) }
    }
}
