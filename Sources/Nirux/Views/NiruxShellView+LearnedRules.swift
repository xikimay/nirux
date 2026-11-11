import AppKit

// MARK: - Learned rules (docs/spaces.md, "Learned rules")

/// A rule the Lead proposes once it finds the same kind of defect twice
/// (`propose_rule`), shown on its row ("Rule proposed · Review") until the
/// user adds, edits or dismisses it in LearnedRuleSheet; and a rule the user
/// adds from a task's row. Only the user's click writes the brief.
extension NiruxShellView {
    // MARK: Proposals

    /// The space's proposals: read once, then kept by the app's own
    /// changes (the sidebar asks several times a second).
    func ruleProposals(inSpace spaceID: String) -> RuleProposalStore.Loaded {
        if let cached = ruleProposals[spaceID] { return cached }
        let loaded = RuleProposalStore(spaceID: spaceID)?.load() ?? RuleProposalStore.Loaded(proposals: [])
        ruleProposals[spaceID] = loaded
        return loaded
    }

    /// Waiting for the user, oldest first.
    func pendingRuleProposals(inSpace spaceID: String) -> [RuleProposal] {
        ruleProposals(inSpace: spaceID).pending
    }

    /// Reads the space's proposals again after a change.
    func reloadRuleProposals(inSpace spaceID: String) {
        ruleProposals[spaceID] = nil
        _ = ruleProposals(inSpace: spaceID)
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
                + "Say so in one line of your reply to them. Nirux types a line into your prompt once they decide. "
                + "Until then, keep telling tasks yourself."
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
        case .added(let at, let words):
            answer("The user added this rule on \(LearnedRules.dayText(Date(timeIntervalSince1970: at))) as "
                + "“\(words)”: it is in the brief, unless they took it out since. Don't propose it again.", true)
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
    func showRuleProposal(spaceID: String) {
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
        let brief = LearnedRules.readForAdding(at: briefURL)
        let sheet = LearnedRuleSheet(
            origin: origin, spaceName: space.name, briefText: brief.text, briefProblem: brief.problem, evidence: evidence
        )
        sheet.onAdd = { [weak self] rule, evidence in
            // Not `self?.… ?? …`: nil is what a rule added returns.
            guard let self else { return "Nirux closed meanwhile." }
            return self.addLearnedRule(rule, evidence: evidence, origin: origin, spaceID: spaceID)
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

    /// Writes the rule into the brief, then records the decision for its
    /// Lead to hear; nil once done, else why not.
    func addLearnedRule(_ rule: String, evidence: String, origin: LearnedRuleSheet.Origin, spaceID: String) -> String? {
        guard let space = profiles.first(where: { $0.id == spaceID }),
              let briefURL = SpaceBrief.briefURL(spaceID: spaceID),
              let store = RuleProposalStore(spaceID: spaceID)
        else { return "This space is gone." }
        // Its Save would replace the brief with the editor's text, rule gone.
        if let settings = spaceSettings, settings.spaceID == spaceID, settings.brief.isDirty {
            return "Save or revert your edits in Space Settings › Brief first."
        }
        // A decision that can't be recorded would leave it waiting, to be
        // added again: say why before writing.
        if case .proposal = origin, let reason = store.load().readOnlyReason { return reason }
        let outcome: LearnedRules.AddOutcome
        do {
            outcome = try LearnedRules.add(rule: rule, evidence: evidence, to: briefURL, spaceName: space.name)
        } catch {
            return error.localizedDescription
        }
        refreshSpaceSettingsBrief(spaceID: spaceID)
        if case .proposal(let proposal) = origin {
            let (words, wasInBrief): (String, Bool) = switch outcome {
            case .added: (LearnedRules.cleaned(rule, limit: LearnedRules.maxRuleLength), false)
            case .alreadyThere(let text): (LearnedRules.cleaned(LearnedRules.splitLearned(text).rule, limit: LearnedRules.maxRuleLength), true)
            }
            // Not recorded: its toast says why, and it shows again.
            guard decideRuleProposal(proposal, spaceID: spaceID, added: true, addedRule: words, wasInBrief: wasInBrief) != nil
            else { return nil }
            typeRuleDecisions()
        }
        if case .alreadyThere = outcome {
            showToast("The brief says this already: nothing was added.")
        } else {
            showToast("Added to the brief: sessions started from now on read it.")
        }
        return nil
    }

    func dismissRuleProposal(_ proposal: RuleProposal, spaceID: String) {
        guard decideRuleProposal(proposal, spaceID: spaceID, added: false) == true else { return }
        typeRuleDecisions()
    }

    /// True once recorded, false when it no longer waited (decided
    /// meanwhile), nil when it couldn't be recorded (a toast says so; it
    /// still shows).
    private func decideRuleProposal(
        _ proposal: RuleProposal, spaceID: String, added: Bool, addedRule: String? = nil, wasInBrief: Bool = false
    ) -> Bool? {
        defer { reloadRuleProposals(inSpace: spaceID) }
        do {
            let store = RuleProposalStore(spaceID: spaceID)
            return try store?.decide(proposal.id, added: added, addedRule: addedRule, wasInBrief: wasInBrief) != nil
        } catch {
            showToast("Couldn’t record that: \(error.localizedDescription)", tone: .error)
            return nil
        }
    }

    /// Space Settings › Brief shows the new text now, rather than at its
    /// next look at the disk.
    private func refreshSpaceSettingsBrief(spaceID: String) {
        guard let settings = spaceSettings, settings.spaceID == spaceID else { return }
        settings.brief.checkDisk()
    }

    // MARK: Telling the Lead

    /// Whether a column's prompt takes a line now, and typing it there:
    /// tests replace them.
    typealias RuleDecisionPromptCheck = @MainActor (ColumnState) -> Bool
    typealias RuleDecisionSend = @MainActor (ColumnState, String) -> Void

    /// Tells each space's Lead what the user decided about its rules, one
    /// decision per free prompt, oldest first. A decision stays in the file
    /// until it is told (`RuleProposal.leadToldAt`): a relaunch, a Lead
    /// busy for hours or started again doesn't lose it. Recorded before it
    /// is typed: one that can't be recorded is never typed, or it would
    /// come back at every turn end. Runs with the Mission messages (a turn
    /// end, a Mission event) and after a decision.
    func typeRuleDecisions(isFree: RuleDecisionPromptCheck? = nil, send: RuleDecisionSend? = nil) {
        var snapshot: ProcessSnapshot?
        for lead in workspaces where lead.isLead && !lead.isClosing {
            guard let decision = ruleProposals(inSpace: lead.profileID).toTell.first else { continue }
            // The terminal that proposed it, else the one the Lead's Claude
            // runs in now.
            let proposer = lead.columns.first { !$0.isClosing && $0.agentUUID != nil && $0.agentUUID == decision.leadAgentUUID }
            let agentUUID = proposer?.agentUUID ?? leadMissionParent(inSpace: lead.profileID)?.agentUUID
            guard let column = lead.columns.first(where: { $0.agentUUID != nil && $0.agentUUID == agentUUID }) else { continue }
            let free: Bool
            if let isFree {
                free = isFree(column)
            } else {
                let processes = snapshot ?? ProcessSnapshot()
                snapshot = processes
                free = column.pty?.acceptsMissionMessage(runningSince: Date().timeIntervalSince1970, snapshot: processes) == true
            }
            guard free else { continue }
            let text = Self.ruleDecisionText(decision)
            ruleProposals[lead.profileID] = nil
            do {
                try RuleProposalStore(spaceID: lead.profileID)?.markTold([decision.id])
            } catch {
                NiruxDebugLog.log("Learned rules: couldn't record that the Lead was told, so it isn't: \(error)")
                continue
            }
            if let send {
                send(column, text)
            } else if let input = TypedPromptSanitizer.terminalInput(for: text) {
                column.pty?.sendRaw(input)
            }
        }
    }

    /// The line a Lead gets about its rule.
    static func ruleDecisionText(_ decision: RuleProposal) -> String {
        let prefix = MissionPromptText.prefix
        if decision.wasInBrief == true {
            return "\(prefix) The user looked at the rule you proposed, “\(decision.rule)”: the space brief says it already, "
                + "as “\(decision.addedRule ?? decision.rule)”. Nothing was added."
        }
        if decision.addedAt != nil {
            return "\(prefix) The user added your rule to the space brief as: “\(decision.addedRule ?? decision.rule)”. Only "
                + "sessions started from now on read it: tell running tasks yourself if they need it."
        }
        return "\(prefix) The user dismissed the rule you proposed: “\(decision.rule)”. Don't propose it again."
    }
}
