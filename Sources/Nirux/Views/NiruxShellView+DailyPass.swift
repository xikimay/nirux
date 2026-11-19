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
        let findings: [ReviewFindings.Finding]
        switch ReviewFindings.findings(arguments["findings"]) {
        case .success(let read): findings = read
        case .failure(let refusal): return answer(refusal.reason, true)
        }
        let review = ReviewFindings.Review(
            findings: findings, workspace: task.id, task: task.gitBranch ?? task.taskFolder ?? task.title, pullRequest: task.prInfo?.number
        )
        ReviewFindings.record(review, spaceID: space.id) { outcome in
            switch outcome {
            case .recorded(let entry, let kinds): answer(ReviewFindings.answer(for: entry, title: title, kinds: kinds), false)
            case .notRecorded(let reason): answer("Nothing was recorded. " + reason, true)
            }
        }
    }

    /// Reads GitHub off the main thread, then answers the digest and marks
    /// its window read, unless GitHub may answer next time.
    func leadDailyPass(in space: WorkspaceProfile, lead: WorkspaceState, answer: @escaping LeadAnswer) {
        guard let briefURL = SpaceBrief.briefURL(spaceID: space.id) else { return answer("This space keeps no daily pass.", true) }
        let (window, next) = DailyPassState.load(spaceID: space.id).reading(now: Date().timeIntervalSince1970)
        // Its workspaces closed since, by the sessions they held, too.
        let members = Set(workspaces.filter { $0.profileID == space.id }.map(\.id))
            .union(sessionLedger.sessions(inSpace: space.id).map(\.workspaceID))
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
        Self.readDailyPassSources(folders: folders, spaceID: spaceID, window: window) { [weak self] repositories, findings in
            var facts = base
            facts.findings = findings
            facts.repositories = repositories
            (facts.triagedRuns, facts.flakyTests) = DailyPass.ciFacts(ciStore, repositories: repositories.map(\.name), window: window)
            // A space deleted meanwhile keeps no file.
            if let next, !facts.readsAgain, self?.profiles.contains(where: { $0.id == spaceID }) == true {
                do {
                    try next.save(spaceID: spaceID)
                } catch {
                    NiruxDebugLog.log("Daily pass: couldn't record the window read, so the next pass reads it again: \(error)")
                }
            }
            answer(DailyPass.digest(facts), false)
        }
    }

    /// The space's GitHub repositories (each repository's base remote) and
    /// what GitHub says of them in the window, and its recorded reviews.
    nonisolated private static func readDailyPassSources(
        folders: [String], spaceID: String, window: DailyPass.Window,
        completion: @escaping @MainActor @Sendable ([DailyPass.RepositoryReport], [ReviewFindings.Entry]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var names: [String] = []
            for folder in folders {
                guard case .gitHub(let name, _) = GitHubBaseRemote.read(at: folder),
                      !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
                names.append(name)
            }
            let reports = DailyPass.readGitHub(names, window: window, read: DailyPass.installedGitHub)
            let findings = ReviewFindings.lines.queue.sync {
                ReviewFindings.lines.trim(spaceID: spaceID)
                return ReviewFindings.lines.load(spaceID: spaceID)
            }
            DispatchQueue.main.async { @MainActor in completion(reports, findings) }
        }
    }
}
