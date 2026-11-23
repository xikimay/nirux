import Foundation

extension NiruxShellView {
    struct LeadQueueRepository {
        let section: BoardSections.Section
        let name: String
        let gitHub: GitHubRepository

        init?(_ section: BoardSections.Section) {
            guard let config = section.config, let name = config.repository, let gitHub = config.gitHubRepository else {
                return nil
            }
            self.section = section
            self.name = name
            self.gitHub = gitHub
        }
    }

    func leadQueueRepository(_ name: String?, sections: [BoardSections.Section], answer: LeadAnswer) -> LeadQueueRepository? {
        let repositories = sections.compactMap(LeadQueueRepository.init)
        let names = repositories.map(\.name).joined(separator: ", ")
        if repositories.isEmpty {
            answer("No GitHub repository is configured for the merge queue. Open Board Settings.", true)
        } else if let name {
            if let match = repositories.first(where: { $0.gitHub.ownerAndName.caseInsensitiveCompare(name) == .orderedSame }) {
                return match
            }
            let matches = repositories.filter { $0.section.name?.caseInsensitiveCompare(name) == .orderedSame }
            if matches.count == 1 { return matches[0] }
            answer("Choose a configured repository by owner/name: " + names, true)
        } else if repositories.count == 1 {
            return repositories[0]
        } else {
            answer("Say which repository: " + names + ". One queue per repository.", true)
        }
        return nil
    }

    func inspectOrStopLeadQueue(
        _ arguments: [String: Any], in space: WorkspaceProfile, parent: NewTask.MissionParent,
        stop: Bool, answer: @escaping LeadAnswer
    ) {
        let name = LeadTools.string(arguments, "repo")
        let board = projectBoardLocation(projectID: space.id)?.board
        let respond: @MainActor (BoardConfigStore.Loaded, [BoardSections.Section]) -> Void = { [self] loaded, sections in
            guard let caller = requestingTerminal(workspaceID: parent.workspaceID, agentUUID: parent.agentUUID),
                  caller.workspace.isLead, caller.workspace.profileID == space.id, !caller.column.isClosing else {
                return answer("This terminal no longer belongs to the space’s Lead.", true)
            }
            let defaults = SpaceDefaultsStore.defaults(forSpace: space.id)
            let enabled = defaults.leadCanStartMergeQueue
            if stop && !enabled {
                return answer("Lead auto-start is off. Click Stop on the Board or enable it in Space Settings › Lead.", true)
            }
            guard let repo = leadQueueRepository(name, sections: sections, answer: answer) else { return }
            let queue = mergeQueue(projectID: space.id, repository: repo.gitHub)
            queue.refreshSavedForLead()
            if stop {
                guard !queue.runsElsewhere else { return answer("The queue is running in another Nirux instance.", true) }
                guard queue.isRunning else { return answer("No queue is running here for " + repo.name + ".", true) }
                guard queue.engine?.phase != .stopping else { return answer("The queue is already stopping.", false) }
                queue.stop(byLead: true)
                return answer("Stopped by Lead. The queue stops before its next command. Any in-flight GitHub command finishes.", false)
            }
            let openPRs = board?.reads[repo.section.id]?.openPullRequests.map { Set($0.map(\.number)) }
            let problem = loaded.view(for: repo.section.slot).queueStartProblems.first
            let allowWithoutLocalReview = defaults.leadCanStartMergeQueueWithoutLocalReview
            Task { @MainActor in
                let summary = await queue.leadStatus(
                    openPRs: openPRs, enabled: enabled, allowWithoutLocalReview: allowWithoutLocalReview, settingsProblem: problem
                )
                answer(summary, false)
            }
        }
        if let board, let loaded = board.loaded { return respond(loaded, board.sections) }
        guard let store = BoardConfigStore(spaceID: space.id) else { return answer("Open Board Settings to configure a repository.", true) }
        let anchors = space.anchors
        MergeQueueDriver.runOffMain({
            let loaded = store.load()
            let needsRemotes = loaded.entries.contains { $0.slot == .legacy } && BoardSections.repositoryAnchors(anchors).count > 1
            let context = needsRemotes ? BoardSections.readContext(anchors: anchors) : BoardSections.Context(anchors: anchors)
            return (loaded, BoardSections.sections(loaded.entries, context: context))
        }, then: { respond($0.0, $0.1) })
    }
}
