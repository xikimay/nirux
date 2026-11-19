import AppKit

// MARK: - The daily pass (docs/design/daily-pass.md)

/// The Lead's `record_review` and `daily_pass`: what its reviews found,
/// kept for the space (ReviewFindings), and what happened in the space
/// since its last pass (DailyPass), from Nirux's own records and GitHub.
extension NiruxShellView {
    /// Any task of the space, as `set_task_context` reaches them.
    func leadRecordReview(_ arguments: [String: Any], in space: WorkspaceProfile, lead leadID: String, answer: @escaping LeadAnswer) {
        let name = LeadTools.string(arguments, "task") ?? ""
        guard let task = spaceTask(name, in: space) else { return answer(noSpaceTask(name, in: space), true) }
        let title = MissionPromptText.quoted(task.title)
        if leadMission(of: task, lead: leadID) == nil, let refusal = leadRefusal(for: task, title: title) { return answer(refusal, true) }
        guard ReviewFindings.lines.fileURL(spaceID: space.id) != nil else { return answer("This space can’t keep review findings.", true) }
        guard case .success(let findings) = ReviewFindings.findings(arguments["findings"]) else {
            return answer("findings must list 1 to \(ReviewFindings.maxFindings) findings, each {kind, text}.", true)
        }
        let key = task.gitBranch ?? task.taskFolder ?? task.title
        ReviewFindings.record(findings, task: key, pullRequest: task.prInfo?.number, spaceID: space.id) { outcome in
            switch outcome {
            case .recorded(let entry, let kinds):
                answer(ReviewFindings.answer(for: entry, title: title, kinds: kinds), false)
            case .full:
                answer("The space’s review log is full: nothing was recorded. It frees up as reviews pass 30 days.", true)
            }
        }
    }

    /// Reads GitHub off the main thread, then answers the digest and marks
    /// its window read.
    func leadDailyPass(in space: WorkspaceProfile, lead: WorkspaceState, answer: @escaping LeadAnswer) {
        guard let briefURL = SpaceBrief.briefURL(spaceID: space.id) else { return answer("This space keeps no daily pass.", true) }
        let window = DailyPassState.load(spaceID: space.id).window(now: Date().timeIntervalSince1970)
        let members = Set(workspaces.filter { $0.profileID == space.id }.map(\.id))
        _ = MissionStore.shared.ensureLoaded()
        let missions = MissionStore.shared.missions.filter { mission in
            mission.parentWorkspaceID == lead.id || members.contains(mission.childWorkspaceID) || members.contains(mission.parentWorkspaceID)
        }
        let ciStore = ciTriageCenter.store
        let base = DailyPass.Facts(
            spaceName: space.name, window: window, findings: [], repositories: [], triagedRuns: [], flakyTests: [],
            missions: DailyPass.missionFacts(missions, window: window),
            proposals: RuleProposalStore(spaceID: space.id)?.load().proposals ?? [],
            briefRules: LearnedRules.learnedRules(in: LearnedRules.briefText(at: briefURL))
        )
        let folders = BoardSections.repositoryAnchors(space.anchors).compactMap(\.folder)
        let spaceID = space.id
        Self.readDailyPassSources(folders: folders, spaceID: spaceID, since: window.start) { repositories, findings in
            var facts = base
            facts.findings = findings
            facts.repositories = repositories
            (facts.triagedRuns, facts.flakyTests) = DailyPass.ciFacts(ciStore, repositories: repositories.map(\.name), window: window)
            do {
                try DailyPassState(start: window.start, end: window.end).save(spaceID: spaceID)
            } catch {
                NiruxDebugLog.log("Daily pass: couldn't record the window read, so the next pass reads it again: \(error)")
            }
            answer(DailyPass.digest(facts), false)
        }
    }

    /// The space's GitHub repositories (each repository's base remote) and
    /// what GitHub says of them since `since`, and its recorded reviews.
    nonisolated private static func readDailyPassSources(
        folders: [String], spaceID: String, since: TimeInterval,
        completion: @escaping @MainActor @Sendable ([DailyPass.RepositoryReport], [ReviewFindings.Entry]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var names: [String] = []
            for folder in folders {
                guard case .gitHub(let name, _) = GitHubBaseRemote.read(at: folder),
                      !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
                names.append(name)
            }
            let reports = DailyPass.readGitHub(names, since: since, read: DailyPass.installedGitHub)
            let findings = ReviewFindings.lines.queue.sync {
                ReviewFindings.lines.trim(spaceID: spaceID)
                return ReviewFindings.lines.load(spaceID: spaceID)
            }
            DispatchQueue.main.async { @MainActor in completion(reports, findings) }
        }
    }
}
