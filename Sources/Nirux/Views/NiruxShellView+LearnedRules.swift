import AppKit

// MARK: - Learned rules (docs/spaces.md, "Learned rules")

/// A rule the Lead proposes once it finds the same kind of defect twice
/// (`propose_rule`), shown on its row ("Rule proposed · Review") until the
/// user adds, edits or dismisses it in LearnedRuleSheet; and a rule the user
/// adds from a task's row. Only the user's click writes the brief.
extension NiruxShellView {
    // MARK: Pending proposals

    /// The space's proposals waiting for the user, oldest first: read once,
    /// then kept by the app's own changes.
    func pendingRuleProposals(inSpace spaceID: String) -> [RuleProposal] {
        if let cached = pendingRuleProposals[spaceID] { return cached }
        let pending = RuleProposalStore(spaceID: spaceID)?.load().pending ?? []
        pendingRuleProposals[spaceID] = pending
        return pending
    }

    /// Reads the space's proposals again after a change.
    func reloadRuleProposals(inSpace spaceID: String) {
        pendingRuleProposals[spaceID] = nil
        _ = pendingRuleProposals(inSpace: spaceID)
        updateSidebar()
    }

    // MARK: propose_rule

    func leadProposeRule(
        _ arguments: [String: Any], in space: WorkspaceProfile, parent: NewTask.MissionParent, answer: @escaping LeadAnswer
    ) {
        guard let store = RuleProposalStore(spaceID: space.id),
              let briefURL = SpaceBrief.briefURL(spaceID: space.id)
        else { return answer("This space can't keep proposed rules.", true) }
        let briefText = LearnedRules.briefText(at: briefURL)
        let outcome = store.propose(
            rule: arguments["rule"] as? String ?? "", evidence: arguments["evidence"] as? String ?? "",
            briefText: briefText, lead: (parent.workspaceID, parent.agentUUID)
        )
        switch outcome {
        case .proposed(let proposal):
            reloadRuleProposals(inSpace: space.id)
            let bullet = LearnedRules.line(rule: proposal.rule, evidence: proposal.evidence, date: Date())
            var text = "Proposed to the user: your row in the sidebar says “Rule proposed”, and they add, edit or dismiss it. "
                + "Nirux types a line into your prompt once they decide. Until then, keep telling tasks yourself."
            if LearnedRules.characterCount(of: briefText) + bullet.count > LearnedRules.longBriefCharacters {
                text += " The brief is long already: the user may want an older rule out first."
            }
            answer(text, false)
        case .inBrief(let day):
            answer("The space brief says this already" + (day.map { " (learned \($0))" } ?? "")
                + ": sessions started since have it. A task that missed it started before, or didn't read it: tell it.", true)
        case .alreadyPending(let since):
            answer("You proposed this rule on \(LearnedRules.dayText(Date(timeIntervalSince1970: since))): "
                + "it waits for the user. Don't propose it again.", true)
        case .dismissed(let at):
            answer("The user dismissed this rule on \(LearnedRules.dayText(Date(timeIntervalSince1970: at))): "
                + "don't propose it again. If it keeps coming back, say so in this conversation.", true)
        case .tooMany:
            answer("\(RuleProposalStore.maxPending) of your rules already wait for the user: propose this one once they "
                + "decide (Nirux tells you), or mention it in this conversation.", true)
        case .refused(let reason):
            answer(reason, true)
        }
    }

    // MARK: The sheet

    /// The Lead row's "Review": its space's oldest proposal.
    func showRuleProposal(workspaceIndex: Int) {
        guard workspaces.indices.contains(workspaceIndex) else { return }
        let spaceID = workspaces[workspaceIndex].profileID
        // Decided meanwhile from another window: read the file again.
        reloadRuleProposals(inSpace: spaceID)
        guard let proposal = pendingRuleProposals(inSpace: spaceID).first else { return }
        showLearnedRuleSheet(origin: .proposal(proposal), spaceID: spaceID, evidence: proposal.evidence)
    }

    /// "Add a Rule to the Brief…" on a task's row: where it was learned
    /// filled with the task's pull request, else its branch.
    func showAddRuleSheet(for workspace: WorkspaceState) {
        let evidence = workspace.prInfo.map { "#\($0.number)" } ?? workspace.gitBranch ?? ""
        showLearnedRuleSheet(origin: .user, spaceID: workspace.profileID, evidence: evidence)
    }

    private func showLearnedRuleSheet(origin: LearnedRuleSheet.Origin, spaceID: String, evidence: String) {
        guard let window, let space = profiles.first(where: { $0.id == spaceID }),
              let briefURL = SpaceBrief.briefURL(spaceID: spaceID)
        else { return }
        guard window.attachedSheet == nil, learnedRuleSheet?.isOpen != true else {
            return showToast("Close the open sheet first.", tone: .error)
        }
        let sheet = LearnedRuleSheet(
            origin: origin, spaceName: space.name, briefText: LearnedRules.briefText(at: briefURL), evidence: evidence
        )
        sheet.onAdd = { [weak self] rule, evidence in
            self?.addLearnedRule(rule, evidence: evidence, origin: origin, spaceID: spaceID) ?? "Nirux closed meanwhile."
        }
        sheet.onDismiss = { [weak self] in
            guard case .proposal(let proposal) = origin else { return }
            self?.dismissRuleProposal(proposal, spaceID: spaceID)
        }
        // Kept once closed (an action of its own may still run): the next
        // sheet replaces it.
        learnedRuleSheet = sheet
        sheet.begin(on: window)
    }

    /// Writes the rule into the brief, then takes the proposal out and
    /// tells its Lead; nil once done, else why not.
    func addLearnedRule(_ rule: String, evidence: String, origin: LearnedRuleSheet.Origin, spaceID: String) -> String? {
        guard let space = profiles.first(where: { $0.id == spaceID }),
              let briefURL = SpaceBrief.briefURL(spaceID: spaceID)
        else { return "This space is gone." }
        // Added meanwhile (by hand, or a decision that failed half way):
        // not twice.
        let alreadyThere = LearnedRules.existingRule(matching: rule, in: LearnedRules.briefText(at: briefURL)) != nil
        if !alreadyThere {
            do {
                try LearnedRules.add(rule: rule, evidence: evidence, to: briefURL, spaceName: space.name)
            } catch {
                return error.localizedDescription
            }
        }
        if case .proposal(let proposal) = origin {
            decideRuleProposal(proposal, spaceID: spaceID, added: true)
            queueRuleNotice(for: proposal, spaceID: spaceID, text: "\(MissionPromptText.prefix) The user added your rule to the "
                + "space brief as: “\(LearnedRules.cleaned(rule, limit: LearnedRules.maxRuleLength))”. Only sessions started "
                + "from now on read it: tell running tasks yourself if they need it.")
        }
        refreshSpaceSettingsBrief(spaceID: spaceID)
        showToast(alreadyThere ? "The brief says this already." : "Added to the brief: sessions started from now on read it.")
        return nil
    }

    func dismissRuleProposal(_ proposal: RuleProposal, spaceID: String) {
        guard decideRuleProposal(proposal, spaceID: spaceID, added: false) else { return }
        queueRuleNotice(for: proposal, spaceID: spaceID, text: "\(MissionPromptText.prefix) The user dismissed the rule you "
            + "proposed: “\(proposal.rule)”. Don't propose it again.")
    }

    /// False when it couldn't be recorded (it still shows) or was decided
    /// meanwhile.
    @discardableResult
    private func decideRuleProposal(_ proposal: RuleProposal, spaceID: String, added: Bool) -> Bool {
        defer { reloadRuleProposals(inSpace: spaceID) }
        do {
            return try RuleProposalStore(spaceID: spaceID)?.decide(proposal.id, added: added) != nil
        } catch {
            showToast("Couldn’t record that: \(error.localizedDescription)", tone: .error)
            return false
        }
    }

    /// Space Settings › Brief shows the new text now, rather than at its
    /// next look at the disk.
    private func refreshSpaceSettingsBrief(spaceID: String) {
        guard let settings = spaceSettings, settings.spaceID == spaceID else { return }
        settings.brief.checkDisk()
    }

    /// For the Lead that proposed it, else the space's Lead now; typed
    /// once its prompt is free.
    private func queueRuleNotice(for proposal: RuleProposal, spaceID: String, text: String) {
        let proposer = proposal.leadWorkspaceID.flatMap { id in workspaces.first { $0.id == id && $0.isLead && !$0.isClosing } }
        let lead = proposer ?? leadWorkspace(inSpace: spaceID)
        guard let lead,
              let column = lead.columns.first(where: { $0.agentUUID != nil && $0.agentUUID == proposal.leadAgentUUID })
                ?? lead.columns.first(where: { $0.agentUUID != nil }),
              let agentUUID = column.agentUUID
        else { return }
        pendingLeadNotices.append(LeadNotice(
            workspaceID: lead.id, agentUUID: agentUUID, text: text, queuedAt: Date().timeIntervalSince1970
        ))
        typeLeadNotices()
    }
}
