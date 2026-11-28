import AppKit

// MARK: - The day plan's planned sessions (docs/design/plan.md)

/// A space's planned session.
struct PlannedLine: Hashable {
    let spaceID: String
    let id: String
}

extension NiruxShellView {
    /// A planned session's Start: the New sheet in its space, with its title and detail. A sheet already up takes
    /// it while it holds nothing, else says why.
    func startPlannedSession(_ lineID: String) {
        if let panel = newTaskPanel, !panel.isHidden, panel.planLine == lineID { return panel.focus() }
        guard plannedSessionProblem(lineID, inSpace: activeProfileID) == nil, let line = planLine(lineID, inSpace: activeProfileID) else {
            return NSSound.beep()
        }
        guard let panel = newTaskPanel, !panel.isHidden else {
            showNewPanel(spaceID: activeProfileID)?.prefill(planned: line)
            return
        }
        panel.focus()
        guard panel.space.id == activeProfileID, panel.planLine == nil,
              panel.descriptionView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return showTransientHint("Start or close the New sheet first.") }
        panel.prefill(planned: line)
    }

    func planLine(_ id: String, inSpace spaceID: String) -> Plan.Line? {
        planStore(ofSpace: spaceID)?.load().plan.line(id)
    }

    /// The planned sessions a start holds: being made, in the New sheet, or in a queued proposal.
    func heldPlanLines(inSpace spaceID: String) -> Set<String> {
        let sheet = [newTaskPanel].compactMap { $0 }.filter { !$0.isHidden && $0.space.id == spaceID }.compactMap(\.planLine)
        let queued = pendingLeadProposals.filter { $0.spaceID == spaceID }.compactMap(\.planLine)
        return Set(startingPlanLines.filter { $0.spaceID == spaceID }.map(\.id) + sheet + queued)
    }

    /// Why start_task's plan_line can't take its task; nil when it can.
    func plannedSessionProblem(_ lineID: String, inSpace spaceID: String) -> String? {
        guard let store = planStore(ofSpace: spaceID) else { return Self.dayPlanIsOff }
        let loaded = store.load()
        guard loaded.plan.line(lineID)?.isPlanned == true else {
            return loaded.readOnlyReason ?? "\(lineID) isn't a planned session of the day plan: read_plan lists them."
        }
        return heldPlanLines(inSpace: spaceID).contains(lineID) ? "\(lineID) is starting already." : nil
    }

    /// A change, then the planned sessions it released start as the Lead's start_task starts them, in the space's
    /// default repository: at once while the space starts tasks without asking, else in the New sheet. Without a Lead
    /// they wait for Start.
    func updatePlan<Result>(_ store: Plan.Store, inSpace spaceID: String, _ change: (inout Plan) throws -> Result) throws -> Result {
        let held = heldPlanLines(inSpace: spaceID)
        var released: [Plan.Line] = []
        let result = try store.update { plan in
            let waiting = Set(plan.released.map(\.id))
            let result = try change(&plan)
            released = plan.released.filter { !waiting.contains($0.id) && !held.contains($0.id) }
            return result
        }
        guard let space = profiles.first(where: { $0.id == spaceID }), let lead = leadMissionParent(inSpace: spaceID) else { return result }
        for line in released {
            let arguments = ["description": line.title + (line.detail.map { "\n\n" + $0 } ?? ""), "plan_line": line.id]
            let selection = TaskAgentSelection(agent: defaultTaskAgent(forSpace: spaceID), model: nil)
            leadStartTask(arguments, selection: selection, in: space, parent: lead) { [weak self] text, _ in
                self?.tellProposer(lead, "“\(line.title)” (\(line.id)) waited for a checked line: \(text)")
            }
        }
        return result
    }

    /// The task started from a planned session takes its line's place; the Lead hears when it can't.
    func linkPlanLine(_ lineID: String, toWorkspace workspaceID: String, title: String, inSpace spaceID: String) {
        guard let store = planStore(ofSpace: spaceID) else { return }
        do {
            try store.update { try $0.link(lineID, toWorkspace: workspaceID, by: .nirux) }
        } catch {
            NSLog("[Plan] \(lineID) didn't take its task: \(error)")
            guard let lead = leadMissionParent(inSpace: spaceID) else { return }
            tellProposer(lead, "“\(title)” started, but the day plan's \(lineID) didn't take it: \(error)")
        }
    }

    /// A waiting task closed before it started gives its planned session back.
    func unlinkPlanLine(of workspace: WorkspaceState) {
        guard let store = planStore(ofSpace: workspace.profileID) else { return }
        do {
            try store.update { plan in
                if plan.line(ofWorkspace: workspace.id) != nil { try plan.unlink(workspace.id, by: .nirux) }
            }
        } catch {
            NSLog("[Plan] the line of \(workspace.id) stays linked: \(error)")
        }
    }
}
