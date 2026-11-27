import AppKit

// MARK: - The day plan's tools (PlanTools)

/// What the app does for the plan's tools: the Lead's act on its space's plan, a task's agent on its own
/// session's line only. Refused while the space's day plan is off.
extension NiruxShellView {
    func leadPlanTool(_ tool: String, _ arguments: [String: Any], in space: WorkspaceProfile, answer: @escaping LeadAnswer) {
        guard let store = planStore(ofSpace: space.id) else { return answer(Self.dayPlanIsOff, true) }
        let now = Date().timeIntervalSince1970
        do {
            switch tool {
            case PlanTools.readPlan:
                let loaded = store.load()
                answer(loaded.plan.text(tasks: planTaskName) + (loaded.readOnlyReason.map { "\n" + $0 } ?? ""), false)
            case PlanTools.addToPlan:
                if let value = arguments["task"], !(value is NSNull), !(value is String) {
                    throw Plan.Problem("task must name a task of this space, as list_tasks shows it.")
                }
                let task = try LeadTools.string(arguments, "task").map { name in
                    guard let workspace = spaceTask(name, in: space) else { throw Plan.Problem(noSpaceTask(name, in: space)) }
                    return Plan.Task(workspaceID: workspace.id, title: workspace.title)
                }
                answer(try store.update { try $0.add(arguments, task: task, newID: Self.newPlanID, at: now) }, false)
            default:
                answer(try store.update { try $0.check(arguments, by: .lead, at: now) }, false)
            }
        } catch {
            answer(String(describing: error), true)
        }
    }

    func taskSteps(_ arguments: [String: Any], from caller: WorkspaceState, answer: @escaping LeadAnswer) {
        guard let store = planStore(ofSpace: caller.profileID) else { return answer(Self.dayPlanIsOff, true) }
        let task = Plan.Task(workspaceID: caller.id, title: caller.title)
        do {
            let now = Date().timeIntervalSince1970
            answer(try store.update { try $0.steps(arguments, of: task, tasks: planTaskName, newID: Self.newPlanID, at: now) }, false)
        } catch {
            answer(String(describing: error), true)
        }
    }

    /// Nil while the space's day plan is off.
    private func planStore(ofSpace spaceID: String) -> Plan.Store? {
        guard SpaceDefaultsStore.defaults(forSpace: spaceID).plansTheDay else { return nil }
        return Plan.Store(spaceID: spaceID)
    }

    /// A session's task as read_plan names it; nil once it closed.
    private func planTaskName(_ workspaceID: String) -> String? {
        guard let task = workspaces.first(where: { $0.id == workspaceID && !$0.isClosing }) else { return nil }
        let pullRequest = task.prInfo.map { "PR #\($0.number) \($0.isDraft ? "draft" : $0.state.word)" }
        return ([task.gitBranch ?? task.title] + (pullRequest.map { [$0] } ?? [])).joined(separator: ", ")
    }

    static let dayPlanIsOff = "The day plan is off in this space."

    /// Letters only: an agent never passes one as a number.
    private static func newPlanID() -> String {
        String((0..<5).compactMap { _ in "abcdefghjkmnpqrstuvwxyz".randomElement() })
    }

}
