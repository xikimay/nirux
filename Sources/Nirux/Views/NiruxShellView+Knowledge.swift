import AppKit

// MARK: - Knowledge bricks (docs/design/knowledge-bricks.md)

/// Each space's bricks rechecked where their base branch moved, every few
/// minutes and once a day in full; the Lead's proposals checked and kept
/// for the user; the user's decisions in Space Memory written. All writes
/// go through one queue, the bricks' files first, then their state, then
/// what agents get.
extension NiruxShellView {
    static let knowledgeInterval: TimeInterval = 300
    nonisolated static let knowledgeQueue = DispatchQueue(label: "Nirux.Knowledge", qos: .utility)

    func startKnowledgeWatch() {
        guard knowledgeTimer == nil else { return }
        knowledgeTimer = Timer.scheduledTimer(withTimeInterval: Self.knowledgeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recheckKnowledge() }
        }
        recheckKnowledge()
    }

    /// One pass per space at a time; a space without bricks costs a stat.
    func recheckKnowledge(spaceIDs: [String]? = nil) {
        for space in profiles where spaceIDs?.contains(space.id) ?? true {
            guard knowledgeChecks.insert(space.id).inserted else { continue }
            let spaceID = space.id
            let serves = SpaceDefaultsStore.defaults(forSpace: spaceID).servesKnowledge
            Self.knowledgeQueue.async {
                let pass = SpaceKnowledge.recheck(spaceID: spaceID, serves: serves)
                DispatchQueue.main.async { @MainActor [weak self] in
                    guard let self else { return }
                    knowledgeChecks.remove(spaceID)
                    if !pass.closed.isEmpty || !pass.suspected.isEmpty {
                        NiruxDebugLog.log("Knowledge: \(spaceID) closed \(pass.closed), suspected \(pass.suspected)")
                        knowledgeChanged(inSpace: spaceID)
                    }
                }
            }
        }
    }

    /// Space Memory shows the space's bricks as they are now.
    func knowledgeChanged(inSpace spaceID: String) {
        guard let settings = spaceSettings, settings.spaceID == spaceID, projectMemoryPanel?.isBusy != true else { return }
        loadProjectMemoryTab(spaceID: spaceID)
    }

    /// Runs `change` on the space's bricks on the knowledge queue, saves what
    /// it leaves and serves it; `completion` gets why it failed, or nil.
    func changeKnowledge(
        inSpace spaceID: String,
        _ change: @escaping @Sendable (inout KnowledgeStore.Loaded, KnowledgeStore, TimeInterval) throws -> Void,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        let serves = SpaceDefaultsStore.defaults(forSpace: spaceID).servesKnowledge
        Self.knowledgeQueue.async {
            let failure: String?
            if let store = SpaceKnowledge.store(spaceID: spaceID) {
                var loaded = store.load()
                let now = Date().timeIntervalSince1970
                do {
                    if let reason = loaded.readOnlyReason { throw ProjectMemory.WriteError.failed(reason) }
                    try change(&loaded, store, now)
                    try store.save(loaded.state, now: now)
                    try SpaceKnowledge.serve(loaded, in: store, serves: serves, now: now)
                    failure = nil
                } catch {
                    failure = error.localizedDescription
                }
            } else {
                failure = "This space can’t keep bricks."
            }
            DispatchQueue.main.async { @MainActor in completion(failure) }
        }
    }

    // MARK: Codex, at its start

    /// Codex's instructions for a launch in `workspace`: the brief file, or
    /// one of its own when bricks apply (SpaceKnowledge.codexInstructions);
    /// nil when the user's Codex config sets its own.
    func codexInstructionsFile(for workspace: WorkspaceState, launchDirectory: String) -> String? {
        let injection = spaceBriefInjection(for: workspace)
        guard !Self.codexConfigSetsDeveloperInstructions(launchDirectory: launchDirectory) else { return nil }
        guard SpaceDefaultsStore.defaults(forSpace: workspace.profileID).servesKnowledge,
              let file = SpaceKnowledge.codexInstructions(
                spaceID: workspace.profileID, task: workspace.id, launchDirectory: launchDirectory, withBrief: injection != nil
              )
        else { return injection?.codexInstructionsFile }
        return file
    }

    // MARK: propose_brick

    func leadProposeBrick(
        _ arguments: [String: Any], in space: WorkspaceProfile, parent: NewTask.MissionParent, answer: @escaping LeadAnswer
    ) {
        guard case .success(let proposal) = LeadTools.brickProposal(arguments) else {
            return answer(LeadTools.problem(tool: LeadTools.proposeBrick, arguments: arguments) ?? "Invalid arguments.", true)
        }
        let lead = workspaces.first { $0.id == parent.workspaceID }
        let anchors = space.anchors.filter(\.isKnown)
        var anchor: SpaceAnchor?
        if let name = proposal.repo {
            anchor = anchors.first { $0.name.caseInsensitiveCompare(name) == .orderedSame || name.lowercased().hasSuffix("/" + $0.name.lowercased()) }
            guard anchor != nil || anchors.isEmpty else {
                return answer("This space has no repository named \(name): \(anchors.map(\.name).joined(separator: ", ")).", true)
            }
        } else if anchors.count > 1 {
            return answer("Name the repository with repo: \(anchors.map(\.name).joined(separator: ", ")).", true)
        } else {
            anchor = anchors.first
        }
        let leadFolder = lead?.cwd
        let spaceID = space.id
        Self.knowledgeQueue.async {
            // A space without anchors: the Lead's own repository.
            guard let anchor = anchor ?? leadFolder.flatMap({ FolderIdentity.identify($0, timeout: 10)?.anchor }), let key = anchor.key,
                  let store = SpaceKnowledge.store(spaceID: spaceID)
            else {
                return DispatchQueue.main.async { answer("Nirux can’t tell which repository this brick is about: pass repo.", true) }
            }
            let now = Date().timeIntervalSince1970
            let brick = KnowledgeBrick(
                sentence: proposal.sentence, subject: proposal.subject, scope: .init(anchor: key, name: anchor.name, paths: proposal.paths),
                proofs: proposal.proofs, macOS: proposal.macOS ? SpaceKnowledge.macOS : nil, replaces: proposal.replaces,
                proposedBy: "the Lead"
            )
            var loaded = store.load()
            let reply: (String, Bool)
            if let refusal = loaded.refusal(of: brick, now: now, macOS: SpaceKnowledge.macOS) {
                reply = (Self.text(of: refusal), true)
            } else if let failure = SpaceKnowledge.proofProblem(of: brick, anchor: anchor, now: now) {
                reply = (failure, true)
            } else {
                loaded.state.proposals.append(BrickProposal(
                    brick: brick, proposedAt: now, leadWorkspaceID: parent.workspaceID, leadAgentUUID: parent.agentUUID
                ))
                do {
                    try store.save(loaded.state, now: now)
                    reply = ("Proposed to the user as \(brick.id): they validate or dismiss it in Space Settings › Memory "
                        + "(What agents know). Say so in one line of your reply to them. Until it is validated, no agent gets it.", false)
                } catch {
                    reply = ("Nirux couldn’t save the proposal: \(error.localizedDescription)", true)
                }
            }
            DispatchQueue.main.async { @MainActor [weak self] in
                answer(reply.0, reply.1)
                if !reply.1 { self?.knowledgeChanged(inSpace: spaceID) }
            }
        }
    }

    nonisolated static func text(of refusal: KnowledgeStore.Loaded.Refusal) -> String {
        switch refusal {
        case .invalid(let problem): return problem
        case .alreadyPending(let since):
            return "You proposed this brick on \(LearnedRules.dayText(Date(timeIntervalSince1970: since))): it waits for the user. Don’t propose it again."
        case .dismissed(let at):
            return "The user dismissed this brick on \(LearnedRules.dayText(Date(timeIntervalSince1970: at))): don’t propose it again."
        case .exists(let status):
            return status == .open ? "This brick stands already: agents get it." : "This brick is \(status.title): \(status.reason ?? "")"
        case .replacesUnknown(let id): return "No brick \(id) in this space to replace."
        case .tooManyPending: return "\(KnowledgeStore.maxPending) bricks wait for the user already: propose this one once they decide."
        case .full: return "This space has \(KnowledgeStore.maxBricks) bricks: replace one (replaces) or let the user close one first."
        case .readOnly(let reason): return reason
        }
    }
}
