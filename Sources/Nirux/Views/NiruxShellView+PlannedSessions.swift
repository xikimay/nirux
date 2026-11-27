import AppKit

// MARK: - The day plan's planned sessions (docs/design/plan.md)

/// A space's planned session.
struct PlannedLine: Hashable {
    let spaceID: String
    let id: String
}

extension NiruxShellView {
    /// A planned session's Start: the New sheet in its space, with its title and detail.
    func startPlannedSession(_ lineID: String) {
        guard plannedSessionProblem(lineID, inSpace: activeProfileID) == nil,
              let line = planStore(ofSpace: activeProfileID)?.load().plan.line(lineID)
        else { return NSSound.beep() }
        showNewPanel(spaceID: activeProfileID)?.prefill(planned: line)
    }

    /// Why start_task's plan_line can't take its task; nil when it can.
    func plannedSessionProblem(_ lineID: String, inSpace spaceID: String) -> String? {
        guard let store = planStore(ofSpace: spaceID) else { return Self.dayPlanIsOff }
        guard store.load().plan.line(lineID)?.isPlanned == true else {
            return "\(lineID) isn't a planned session of the day plan: read_plan lists them."
        }
        return startingPlanLines.contains(PlannedLine(spaceID: spaceID, id: lineID)) ? "\(lineID) is starting already." : nil
    }

    /// A change, then the planned sessions it released start as the Lead's start_task starts them, in the space's
    /// default repository: at once while the space starts tasks without asking, else in the New sheet. Without a Lead
    /// they wait for Start.
    func updatePlan<Result>(_ store: Plan.Store, inSpace spaceID: String, _ change: (inout Plan) throws -> Result) throws -> Result {
        var released: [Plan.Line] = []
        let result = try store.update { plan in
            let waiting = Set(plan.released.map(\.id))
            let result = try change(&plan)
            released = plan.released.filter { !waiting.contains($0.id) && !startingPlanLines.contains(PlannedLine(spaceID: spaceID, id: $0.id)) }
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
}
